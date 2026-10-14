package manager

import (
	"context"
	"errors"
	"fmt"
	"slices"
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

// VarInfo 是列表里的一个变量：名称、值的长度（字符数）和备注，不含值本身。
// Broken 表示这个变量解不开，只能删除或重新写入。
type VarInfo struct {
	Name   string `json:"name"`
	Length int    `json:"length"`
	Note   string `json:"note"`
	Broken bool   `json:"broken,omitempty"`
}

// Vars 列出一个环境里的全部变量，按名称排序。
func (s *Session) Vars(envID string) ([]VarInfo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	vals, broken, err := s.entriesLocked(envID)
	if err != nil {
		return nil, err
	}
	out := make([]VarInfo, 0, len(vals)+len(broken))
	for n, e := range vals {
		out = append(out, VarInfo{Name: n, Length: utf8.RuneCountInString(e.Value), Note: e.Note})
	}
	for _, n := range broken {
		out = append(out, VarInfo{Name: n, Broken: true})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// Value 解密一个变量的值。
func (s *Session) Value(envID, name string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	vals, broken, err := s.entriesLocked(envID)
	if err != nil {
		return "", err
	}
	e, ok := vals[name]
	if !ok && slices.Contains(broken, name) {
		return "", errors.New("变量 " + name + " 无法解密，可以删除它，或重新填写值后保存")
	}
	if !ok {
		return "", errors.New("变量 " + name + " 不存在，可能已在其他设备上删除")
	}
	return e.Value, nil
}

func (s *Session) entriesLocked(envID string) (map[string]hc.Entry, []string, error) {
	if _, err := s.envLocked(envID); err != nil {
		return nil, nil, err
	}
	return vault.Entries(s.cache, s.keys, envID)
}

// Diff 比较要写入的变量与环境里现有的值和备注。names 给出顺序。
func (s *Session) Diff(envID string, changes map[string]app.VarChange, names []string) ([]DiffItem, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.diffLocked(envID, changes, names)
}

func (s *Session) diffLocked(envID string, changes map[string]app.VarChange, names []string) ([]DiffItem, error) {
	cur, broken, err := s.entriesLocked(envID)
	if err != nil {
		return nil, err
	}
	out := make([]DiffItem, 0, len(names))
	for _, n := range names {
		status := "new"
		if slices.Contains(broken, n) {
			status = "changed"
		} else if old, ok := cur[n]; ok {
			status = "same"
			if next := apply(old, changes[n]); next != old {
				status = "changed"
			}
		}
		out = append(out, DiffItem{Name: n, Status: status})
	}
	return out, nil
}

// apply 返回修改后的变量：没有给出的部分沿用原来的。
func apply(e hc.Entry, ch app.VarChange) hc.Entry {
	if ch.Value != nil {
		e.Value = *ch.Value
	}
	if ch.Note != nil {
		e.Note = *ch.Note
	}
	return e
}

// SetVars 把一批变量写入环境，逐个调用变量接口；返回每个变量的结果。必须在线。
// 没有给出备注的变量保留原来的备注。
func (s *Session) SetVars(ctx context.Context, envID string, changes map[string]app.VarChange) ([]Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.setLocked(ctx, envID, changes)
}

func (s *Session) setLocked(ctx context.Context, envID string, changes map[string]app.VarChange) ([]Result, error) {
	cur, broken, err := s.entriesLocked(envID)
	if err != nil {
		return nil, err
	}
	key, kv, err := vault.EnvKey(s.cache, s.keys, envID)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(changes))
	for n := range changes {
		names = append(names, n)
	}
	sort.Strings(names)
	return s.each(ctx, names, func(name string) error {
		if err := app.ValidateName(name); err != nil {
			return err
		}
		ch := changes[name]
		old, exists := cur[name]
		if ch.Value == nil && !exists {
			if slices.Contains(broken, name) {
				return errors.New("变量无法解密，请填写值后重新保存")
			}
			return errors.New("变量不存在，可能已在其他设备上删除")
		}
		if ch.Note != nil {
			note, err := app.NormalizeNote(*ch.Note)
			if err != nil {
				return err
			}
			ch.Note = &note
		}
		e := apply(old, ch)
		if len(e.Value) > hc.MaxValueLen {
			return errors.New("值超过 64 KB")
		}
		ct, err := hc.EncryptVar(key, envID, kv, name, e)
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

// selected 取出来源环境里选中的变量（连同备注）；已经不存在的名称被忽略。
func (s *Session) selected(from string, names []string) (map[string]app.VarChange, []string, error) {
	src, _, err := s.entriesLocked(from)
	if err != nil {
		return nil, nil, err
	}
	vars := map[string]app.VarChange{}
	var kept []string
	for _, n := range names {
		if e, ok := src[n]; ok {
			vars[n] = app.VarChange{Value: &e.Value, Note: &e.Note}
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
