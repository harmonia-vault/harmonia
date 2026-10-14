package manager

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"sync/atomic"
	"unicode/utf8"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/app"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

// Result 是批量操作中一个变量的结果；Error 为空表示成功。
type Result struct {
	Name  string `json:"name"`
	Error string `json:"error,omitempty"`
}

// DiffItem 说明把一个变量写入某个环境会发生什么：new（新增）、changed（修改）、same（不变）。
type DiffItem struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}

// VarInfo 是列表里的一个变量：只有名称和值的长度（字符数），不含值本身。
type VarInfo struct {
	Name   string `json:"name"`
	Length int    `json:"length"`
}

// Vars 列出一个环境里的全部变量，按名称排序。
func (s *Session) Vars(envID string) ([]VarInfo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	vals, err := s.valuesLocked(envID)
	if err != nil {
		return nil, err
	}
	out := make([]VarInfo, 0, len(vals))
	for n, v := range vals {
		out = append(out, VarInfo{Name: n, Length: utf8.RuneCountInString(v)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// Value 解密一个变量的值。
func (s *Session) Value(envID, name string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	vals, err := s.valuesLocked(envID)
	if err != nil {
		return "", err
	}
	v, ok := vals[name]
	if !ok {
		return "", errors.New("变量 " + name + " 不存在，可能已在其他设备上删除")
	}
	return v, nil
}

func (s *Session) valuesLocked(envID string) (map[string]string, error) {
	if _, err := s.envLocked(envID); err != nil {
		return nil, err
	}
	return vault.Values(s.cache, s.keys, envID)
}

// Diff 比较要写入的变量与环境里现有的值。names 给出顺序。
func (s *Session) Diff(envID string, vars map[string]string, names []string) ([]DiffItem, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.diffLocked(envID, vars, names)
}

func (s *Session) diffLocked(envID string, vars map[string]string, names []string) ([]DiffItem, error) {
	cur, err := s.valuesLocked(envID)
	if err != nil {
		return nil, err
	}
	out := make([]DiffItem, 0, len(names))
	for _, n := range names {
		status := "new"
		if old, ok := cur[n]; ok {
			status = "changed"
			if old == vars[n] {
				status = "same"
			}
		}
		out = append(out, DiffItem{Name: n, Status: status})
	}
	return out, nil
}

// SetVars 把一批变量写入环境，逐个调用变量接口；返回每个变量的结果。必须在线。
func (s *Session) SetVars(ctx context.Context, envID string, vars map[string]string) ([]Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.setLocked(ctx, envID, vars)
}

func (s *Session) setLocked(ctx context.Context, envID string, vars map[string]string) ([]Result, error) {
	if _, err := s.envLocked(envID); err != nil {
		return nil, err
	}
	key, kv, err := vault.EnvKey(s.cache, s.keys, envID)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(vars))
	for n := range vars {
		names = append(names, n)
	}
	sort.Strings(names)
	return s.each(ctx, names, func(name string) error {
		if err := app.ValidateName(name); err != nil {
			return err
		}
		if len(vars[name]) > hc.MaxValueLen {
			return errors.New("值超过 64 KB")
		}
		ct, err := hc.EncryptValue(key, envID, kv, name, vars[name])
		if err != nil {
			return err
		}
		return s.client.PutVariable(ctx, envID, name, ct, fmt.Sprint(kv), hc.NewID())
	})
}

// DeleteVars 删除一批变量。
func (s *Session) DeleteVars(ctx context.Context, envID string, names []string) ([]Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.envLocked(envID); err != nil {
		return nil, err
	}
	return s.each(ctx, names, func(name string) error {
		return s.client.DeleteVariable(ctx, envID, name, hc.NewID())
	})
}

// each 对每个名称执行一次写入（最多 4 个同时进行），收集各自的结果，最后同步一次。
// 本机已被移除时整体返回 api.ErrRevoked。
func (s *Session) each(ctx context.Context, names []string, do func(name string) error) ([]Result, error) {
	out := make([]Result, len(names))
	var (
		wg      sync.WaitGroup
		revoked atomic.Bool
		slots   = make(chan struct{}, 4)
	)
	for i, name := range names {
		wg.Add(1)
		slots <- struct{}{}
		go func() {
			defer func() { <-slots; wg.Done() }()
			out[i].Name = name
			if err := do(name); err != nil {
				out[i].Error = err.Error()
				if errors.Is(err, api.ErrRevoked) {
					revoked.Store(true)
				}
			}
		}()
	}
	wg.Wait()
	if revoked.Load() {
		return nil, api.ErrRevoked
	}
	return out, s.syncLocked(ctx)
}

// selected 取出来源环境里选中的变量；已经不存在的名称被忽略。
func (s *Session) selected(from string, names []string) (map[string]string, []string, error) {
	src, err := s.valuesLocked(from)
	if err != nil {
		return nil, nil, err
	}
	vars := map[string]string{}
	var kept []string
	for _, n := range names {
		if v, ok := src[n]; ok {
			vars[n] = v
			kept = append(kept, n)
		}
	}
	return vars, kept, nil
}

// CopyDiff 说明把所选变量从一个环境复制到另一个环境会发生什么。
func (s *Session) CopyDiff(from, to string, names []string) ([]DiffItem, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if from == to {
		return nil, errors.New("请选择另一个环境")
	}
	vars, kept, err := s.selected(from, names)
	if err != nil {
		return nil, err
	}
	return s.diffLocked(to, vars, kept)
}

// Copy 把所选变量复制到另一个环境：在本机解密后用目标环境的密钥重新加密，明文不经过浏览器。
func (s *Session) Copy(ctx context.Context, from, to string, names []string) ([]Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if from == to {
		return nil, errors.New("请选择另一个环境")
	}
	vars, _, err := s.selected(from, names)
	if err != nil {
		return nil, err
	}
	return s.setLocked(ctx, to, vars)
}
