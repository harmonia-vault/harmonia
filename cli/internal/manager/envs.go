package manager

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/refs"
	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

// EnvInfo 是列表里的一个环境。
type EnvInfo struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Count int    `json:"count"`
	// Devices 是能读到这个环境的设备数：全部管理设备，加上授权没有到期的其他设备。
	Devices int `json:"devices"`
	// Problems 是需要处理的问题数：被遮住的同名变量和已失效的引用。
	Problems int `json:"problems"`
}

// RefView 是环境详情里的一条引用，带上变量库名。
type RefView struct {
	api.Ref
	VaultName string `json:"vaultName"`
}

// EnvDetail 是环境详情：引用、最终的变量和被遮住的同名变量。
type EnvDetail struct {
	EnvInfo
	Refs     []RefView     `json:"refs"`
	Items    []api.EnvItem `json:"items"`
	Shadowed []api.EnvItem `json:"shadowed"`
}

func (s *Session) devicesLocked(envID string) int {
	now := time.Now().UnixMilli()
	n := 0
	for _, d := range s.info.Devices {
		if d.Kind == "manager" {
			n++
			continue
		}
		for _, g := range d.Grants {
			if g.EnvironmentID == envID && (g.ExpiresAt == 0 || g.ExpiresAt > now) {
				n++
			}
		}
	}
	return n
}

func (s *Session) envInfoLocked(e api.ManagerEnv) EnvInfo {
	info := EnvInfo{ID: e.ID, Name: e.Name, Devices: s.devicesLocked(e.ID)}
	if ce := s.cachedEnvLocked(e.ID); ce != nil {
		info.Count = len(ce.Items)
		info.Problems = len(ce.Shadowed)
	}
	for _, r := range e.Refs {
		if r.Missing {
			info.Problems++
		}
	}
	return info
}

func (s *Session) cachedEnvLocked(id string) *api.Environment {
	for i := range s.cache.Environments {
		if s.cache.Environments[i].ID == id {
			return &s.cache.Environments[i]
		}
	}
	return nil
}

// Envs 按创建先后列出全部环境。
func (s *Session) Envs() []EnvInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []EnvInfo{}
	for _, e := range s.info.Environments {
		out = append(out, s.envInfoLocked(e))
	}
	return out
}

func (s *Session) envLocked(id string) (*api.ManagerEnv, error) {
	for i := range s.info.Environments {
		if s.info.Environments[i].ID == id {
			return &s.info.Environments[i], nil
		}
	}
	return nil, errors.New("这个环境不存在，可能已在其他设备上删除")
}

func (s *Session) vaultNameLocked(id string) string {
	if v, err := s.vaultLocked(id); err == nil {
		return v.Name
	}
	return ""
}

// Env 返回一个环境的详情。
func (s *Session) Env(id string) (*EnvDetail, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	e, err := s.envLocked(id)
	if err != nil {
		return nil, err
	}
	out := &EnvDetail{EnvInfo: s.envInfoLocked(*e), Refs: []RefView{}, Items: []api.EnvItem{}, Shadowed: []api.EnvItem{}}
	for _, r := range e.Refs {
		if r.Items == nil {
			r.Items = []api.RefItem{}
		}
		out.Refs = append(out.Refs, RefView{Ref: r, VaultName: s.vaultNameLocked(r.VaultID)})
	}
	if ce := s.cachedEnvLocked(id); ce != nil {
		out.Items = append(out.Items, ce.Items...)
		out.Shadowed = append(out.Shadowed, ce.Shadowed...)
	}
	return out, nil
}

// VaultVarNames 是变量库里现存的变量名，按名称排序；编辑环境时用来勾选和预览。
func (s *Session) VaultVarNames(vaultID string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.vaultLocked(vaultID); err != nil {
		return nil, err
	}
	return s.namesLocked(vaultID), nil
}

func (s *Session) namesLocked(vaultID string) []string {
	out := []string{}
	for n := range s.cache.Variables[vaultID] {
		out = append(out, n)
	}
	slices.Sort(out)
	return out
}

// Preview 按当前数据展开一组引用，并找出保存时会被拒绝的重名；编辑环境时实时显示。
func (s *Session) Preview(rs []api.Ref) (items, shadowed []api.EnvItem, dup []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	items, shadowed = refs.Expand(rs, s.namesLocked)
	return items, shadowed, refs.Duplicates(rs, s.namesLocked)
}

// checkRefs 在提交前检查引用：重名在本机就指出，省得往返服务器。
func (s *Session) checkRefsLocked(rs []api.Ref) ([]api.Ref, error) {
	out := make([]api.Ref, len(rs))
	for i, r := range rs {
		r.Missing = false
		if r.Items == nil {
			r.Items = []api.RefItem{}
		}
		out[i] = r
	}
	if dup := refs.Duplicates(out, s.namesLocked); len(dup) > 0 {
		return nil, errors.New("环境里有重名的变量：" + strings.Join(dup, "、") + "。请给其中一个改名，或取消勾选")
	}
	return out, nil
}

// CreateEnv 新建环境。新环境还没有授权给任何设备，不需要封装。
func (s *Session) CreateEnv(ctx context.Context, name string, rs []api.Ref) (string, error) {
	name, err := label(name, "环境名")
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if rs, err = s.checkRefsLocked(rs); err != nil {
		return "", err
	}
	id := hc.NewID()
	if err := s.client.CreateEnvironment(ctx, id, name, rs); err != nil {
		return "", err
	}
	return id, s.syncLocked(ctx)
}

// SaveEnv 整体替换环境的名字和引用。对开启了本机解密的授权，在同一个请求里附上
// 引用到的变量库的封装（先校验设备证书），服务端据此补上新引用的变量库、删掉不再用到的（设计文档 17.2）。
func (s *Session) SaveEnv(ctx context.Context, id, name string, rs []api.Ref) error {
	name, err := label(name, "环境名")
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.syncLocked(ctx); err != nil {
		return err
	}
	if _, err := s.envLocked(id); err != nil {
		return err
	}
	if rs, err = s.checkRefsLocked(rs); err != nil {
		return err
	}
	envelopes, err := s.localEnvelopesLocked(id, rs)
	if err != nil {
		return err
	}
	if err := s.client.PutEnvironment(ctx, id, name, rs, envelopes); err != nil {
		return err
	}
	return s.syncLocked(ctx)
}

// localEnvelopesLocked 为被授权这个环境、开启了本机解密的设备，封装引用到的每个现存变量库的库钥。
func (s *Session) localEnvelopesLocked(envID string, rs []api.Ref) ([]api.NewEnvelope, error) {
	var out []api.NewEnvelope
	for _, d := range s.info.Devices {
		if !slices.ContainsFunc(d.Grants, func(g api.DeviceGrant) bool { return g.EnvironmentID == envID && g.LocalDecrypt }) {
			continue
		}
		boxPub, err := s.verifiedBoxPub(d)
		if err != nil {
			return nil, err
		}
		for _, r := range rs {
			if _, err := s.vaultLocked(r.VaultID); err != nil {
				continue // 已失效的引用不需要封装
			}
			key, kv, err := vault.VaultKey(s.cache, s.keys, r.VaultID)
			if err != nil {
				return nil, err
			}
			e, err := s.envelope(r.VaultID, kv, d.ID, boxPub, key)
			if err != nil {
				return nil, err
			}
			out = append(out, e)
		}
	}
	return out, nil
}

// DeleteEnv 删除环境和设备对它的授权，变量库不受影响。
func (s *Session) DeleteEnv(ctx context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.client.DeleteEnvironment(ctx, id); err != nil {
		return err
	}
	return s.syncLocked(ctx)
}
