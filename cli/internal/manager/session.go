package manager

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

// ErrNotManager 表示这台电脑在手机上被批准成了普通设备，没有管理功能。
var ErrNotManager = errors.New("这台电脑没有被批准为管理设备")

// Session 是解锁后的管理身份。全部数据只在内存里，丢弃它即锁定。
type Session struct {
	File   *state.ManagerFile
	dir    *state.Dir
	keys   *state.DeviceKeys
	client *api.Client

	mu    sync.Mutex
	cache *state.Cache
	info  *api.ManagerInfo
	root  hc.SignKey
}

// Open 用已解开的设备密钥建立会话；调用方随后要先 Sync 一次。
func Open(d *state.Dir, f *state.ManagerFile, keys *state.DeviceKeys) *Session {
	c := api.New(f.Server)
	c.AccountID = f.AccountID
	c.Signer = keys
	return &Session{File: f, dir: d, keys: keys, client: c, cache: emptyCache()}
}

func emptyCache() *state.Cache {
	return &state.Cache{Variables: map[string]map[string]state.CachedVar{}}
}

// Sync 拉取增量并校验：环境钥封装必须由账号根密钥签名，账号根密钥必须与本机钉住的公钥一致。
// 本机已被移除时返回 api.ErrRevoked；被批准成普通设备时返回 ErrNotManager。
func (s *Session) Sync(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.syncLocked(ctx)
}

func (s *Session) syncLocked(ctx context.Context) error {
	since := s.cache.Seq
	res, err := s.client.Sync(ctx, since)
	if err != nil {
		return err
	}
	if res.Seq < since {
		since = 0
		if res, err = s.client.Sync(ctx, 0); err != nil {
			return err
		}
	}
	if res.Self.Kind != "manager" || res.Manager == nil {
		return ErrNotManager
	}
	sealed, err := hc.UnB64(res.Manager.RootSealed)
	if err != nil {
		return errors.New("服务器下发的账号密钥格式不对，已停止。请确认服务器地址是否正确")
	}
	seed, err := s.keys.Box.Open(sealed)
	if err != nil || len(seed) != 32 {
		return errors.New("无法解开账号密钥，已停止。请在手机上移除这台电脑的管理身份后重新管理登录")
	}
	root := hc.SignKeyFromSeed(seed)
	if hc.B64(root.Pub) != s.File.RootPub {
		return errors.New("账号密钥与本机记录不一致，已停止。请确认服务器地址是否正确")
	}
	next := s.cache
	if since == 0 {
		next = emptyCache()
	}
	if err := vault.Apply(next, res, since, s.File.RootPub, s.File.DeviceID); err != nil {
		return err
	}
	s.cache, s.info, s.root = next, res.Manager, root
	// 设备名可以在手机上修改，以服务器为准。
	if res.Self.Name != "" && res.Self.Name != s.File.DeviceName {
		updated := *s.File
		updated.DeviceName = res.Self.Name
		if err := s.dir.SaveManager(&updated); err != nil {
			return err
		}
		*s.File = updated
	}
	return nil
}

// Seq 是当前数据对应的服务端序号，页面据此判断是否需要刷新。
func (s *Session) Seq() int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cache.Seq
}

// Listen 保持推送连接，其他设备有修改时同步并调用 onChange；连接断开或出错时返回。
func (s *Session) Listen(ctx context.Context, onChange func()) error {
	return s.client.Listen(ctx, func(api.Event) {
		if s.Sync(ctx) == nil {
			onChange()
		}
	})
}

// Logout 通知服务端移除这个管理身份。它是账号里最后一台管理设备时，需要 confirmLast 才会移除。
func (s *Session) Logout(ctx context.Context, confirmLast bool) error {
	err := s.client.RevokeSelfManager(ctx, confirmLast)
	if errors.Is(err, api.ErrRevoked) {
		return nil
	}
	return err
}

// ---- 环境 ----

type EnvInfo struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Count int    `json:"count"`
	// Devices 是能读到这个环境的设备数：全部管理设备，加上授权没有到期的其他设备。
	Devices int `json:"devices"`
}

// Envs 按创建先后列出全部环境。
func (s *Session) Envs() []EnvInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().UnixMilli()
	managers, granted := 0, map[string]int{}
	for _, d := range s.info.Devices {
		if d.Kind == "manager" {
			managers++
			continue
		}
		for _, g := range d.Grants {
			if g.ExpiresAt == 0 || g.ExpiresAt > now {
				granted[g.EnvID]++
			}
		}
	}
	out := []EnvInfo{}
	for _, e := range vault.Ordered(s.cache) {
		out = append(out, EnvInfo{ID: e.ID, Name: e.Name, Count: len(s.cache.Variables[e.ID]), Devices: managers + granted[e.ID]})
	}
	return out
}

func (s *Session) envLocked(id string) (*api.Environment, error) {
	for i := range s.cache.Environments {
		if s.cache.Environments[i].ID == id {
			return &s.cache.Environments[i], nil
		}
	}
	return nil, errors.New("这个环境不存在，可能已在其他设备上删除")
}

func envName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if n := len([]rune(name)); n < 1 || n > 64 {
		return "", errors.New("环境名需要 1 到 64 个字符")
	}
	return name, nil
}

// envelope 把环境钥封装给一个接收者，并用账号根密钥签名。
func (s *Session) envelope(envID, recipient string, boxPub, key []byte) (api.NewEnvelope, error) {
	sealed, err := hc.Seal(key, boxPub)
	if err != nil {
		return api.NewEnvelope{}, err
	}
	return api.NewEnvelope{
		Recipient: recipient, KeyVersion: "1", Sealed: hc.B64(sealed),
		Sig: hc.B64(s.root.Sign(hc.EnvelopeMsg(envID, 1, recipient, sealed))),
	}, nil
}

// CreateEnv 新建环境：生成环境钥，封装给全部管理设备（先校验设备证书）和恢复码。
func (s *Session) CreateEnv(ctx context.Context, name string) (string, error) {
	name, err := envName(name)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.syncLocked(ctx); err != nil {
		return "", err
	}
	rootPub, _ := hc.UnB64(s.File.RootPub)
	id, key := hc.NewID(), hc.Random(32)
	var envelopes []api.NewEnvelope
	for _, d := range s.info.Devices {
		if d.Kind != "manager" {
			continue
		}
		cert, err1 := hc.UnB64(d.Cert)
		boxPub, err2 := hc.UnB64(d.BoxPub)
		if err1 != nil || err2 != nil || !hc.Verify(rootPub, hc.DeviceCertMsg(d.ID, d.Kind, d.SignPub, d.BoxPub), cert) {
			return "", errors.New("管理设备“" + d.Name + "”的证书无效，已停止新建环境。请确认服务器地址是否正确")
		}
		e, err := s.envelope(id, d.ID, boxPub, key)
		if err != nil {
			return "", err
		}
		envelopes = append(envelopes, e)
	}
	recPub, err := hc.UnB64(s.info.Recovery.BoxPub)
	if err != nil {
		return "", errors.New("服务器下发的恢复公钥格式不对，已停止新建环境")
	}
	e, err := s.envelope(id, "recovery", recPub, key)
	if err != nil {
		return "", err
	}
	if err := s.client.CreateEnvironment(ctx, id, name, append(envelopes, e)); err != nil {
		return "", err
	}
	return id, s.syncLocked(ctx)
}

func (s *Session) RenameEnv(ctx context.Context, id, name string) error {
	name, err := envName(name)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.client.RenameEnvironment(ctx, id, name); err != nil {
		return err
	}
	return s.syncLocked(ctx)
}

func (s *Session) DeleteEnv(ctx context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.client.DeleteEnvironment(ctx, id); err != nil {
		return err
	}
	return s.syncLocked(ctx)
}
