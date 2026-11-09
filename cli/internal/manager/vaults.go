package manager

import (
	"context"
	"errors"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
)

// VaultInfo 是列表里的一个变量库；Envs 是引用它的环境名。
type VaultInfo struct {
	ID    string   `json:"id"`
	Name  string   `json:"name"`
	Count int      `json:"count"`
	Envs  []string `json:"envs"`
}

// Vaults 按创建先后列出全部变量库。
func (s *Session) Vaults() []VaultInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []VaultInfo{}
	for _, v := range s.info.Vaults {
		info := VaultInfo{ID: v.ID, Name: v.Name, Count: len(s.cache.Variables[v.ID]), Envs: []string{}}
		for _, e := range s.info.Environments {
			for _, r := range e.Refs {
				if r.VaultID == v.ID {
					info.Envs = append(info.Envs, e.Name)
				}
			}
		}
		out = append(out, info)
	}
	return out
}

func (s *Session) vaultLocked(id string) (*api.ManagerVault, error) {
	for i := range s.info.Vaults {
		if s.info.Vaults[i].ID == id {
			return &s.info.Vaults[i], nil
		}
	}
	return nil, errors.New("这个变量库不存在，可能已在其他设备上删除")
}

// CreateVault 新建变量库：生成库钥，封装给全部管理设备（先校验设备证书）和恢复码，返回变量库 ID。
func (s *Session) CreateVault(ctx context.Context, name string) (string, error) {
	name, err := label(name, "变量库名")
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.syncLocked(ctx); err != nil {
		return "", err
	}
	id, key := hc.NewID(), hc.Random(32)
	var envelopes []api.NewEnvelope
	for _, d := range s.info.Devices {
		if d.Kind != "manager" {
			continue
		}
		boxPub, err := s.verifiedBoxPub(d)
		if err != nil {
			return "", err
		}
		e, err := s.envelope(id, 1, d.ID, boxPub, key)
		if err != nil {
			return "", err
		}
		envelopes = append(envelopes, e)
	}
	recPub, err := hc.UnB64(s.info.Recovery.BoxPub)
	if err != nil {
		return "", errors.New("服务器下发的恢复公钥格式不对，已停止新建变量库")
	}
	e, err := s.envelope(id, 1, "recovery", recPub, key)
	if err != nil {
		return "", err
	}
	if err := s.client.CreateVault(ctx, id, name, append(envelopes, e)); err != nil {
		return "", err
	}
	return id, s.syncLocked(ctx)
}

func (s *Session) RenameVault(ctx context.Context, id, name string) error {
	name, err := label(name, "变量库名")
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.client.RenameVault(ctx, id, name); err != nil {
		return err
	}
	return s.syncLocked(ctx)
}

// DeleteVault 删除变量库和其中的变量；引用它的环境里，这条引用变成“已失效”。
func (s *Session) DeleteVault(ctx context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.client.DeleteVault(ctx, id); err != nil {
		return err
	}
	return s.syncLocked(ctx)
}
