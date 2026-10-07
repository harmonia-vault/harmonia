// Package app 组织本机状态、API 客户端与同步，供各命令和后台服务共用。
package app

import (
	"bytes"
	"context"
	"errors"
	"os"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/shell"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

var ErrNotPaired = errors.New("本机还没有接入账号，请先运行 harmonia login")

// ErrRevokedLocal 在设备被移除并已清除本机数据后返回。
var ErrRevokedLocal = errors.New("这台设备已被移除，本机数据已清除。如需继续使用，请重新运行 harmonia login")

type App struct {
	Dir    *state.Dir
	Config *state.Config
	Keys   *state.DeviceKeys
	Client *api.Client
}

// Load 读取本机状态。requirePaired=true 时要求已接入账号。
func Load(requirePaired bool) (*App, error) {
	d, err := state.Open()
	if err != nil {
		return nil, err
	}
	cfg, err := d.Config()
	if err != nil {
		return nil, err
	}
	a := &App{Dir: d, Config: cfg}
	if cfg.Server != "" {
		a.Client = api.New(cfg.Server)
		a.Client.AccountID = cfg.AccountID
	}
	if !cfg.Paired() {
		if requirePaired {
			return nil, ErrNotPaired
		}
		return a, nil
	}
	k, err := d.Keys()
	if err != nil {
		return nil, err
	}
	a.Keys, err = k.Device(cfg.DeviceID)
	if err != nil {
		return nil, err
	}
	a.Client.Signer = a.Keys
	return a, nil
}

func nowMs() int64 { return time.Now().UnixMilli() }

// Sync 拉取增量并更新缓存和 env.sh；设备被移除时清除本机数据。
func (a *App) Sync(ctx context.Context) error {
	unlock, err := a.Dir.Lock()
	if err != nil {
		return err
	}
	defer unlock()
	cache, err := a.Dir.Cache()
	if err != nil {
		return err
	}
	since := cache.Seq
	res, err := a.Client.Sync(ctx, since)
	if errors.Is(err, api.ErrRevoked) {
		return a.wipeLocked()
	}
	if err != nil {
		return err
	}
	if res.Seq < since {
		// 服务器序号倒退（例如账号被重置后重建），做一次全量同步。
		since = 0
		if res, err = a.Client.Sync(ctx, 0); err != nil {
			return err
		}
	}
	if err := vault.Apply(cache, res, since, a.Config.RootPub, a.Config.DeviceID); err != nil {
		return err
	}
	if err := a.Dir.SaveCache(cache); err != nil {
		return err
	}
	cfg, err := a.Dir.Config()
	if err != nil {
		return err
	}
	cfg.LastSync = nowMs()
	a.Config = cfg
	if err := a.Dir.SaveConfig(cfg); err != nil {
		return err
	}
	_, err = a.writeEnvLocked(cache)
	return err
}

// HandleRevoked 在任意请求返回“设备已移除”时清除本机数据。
func (a *App) HandleRevoked(err error) error {
	if !errors.Is(err, api.ErrRevoked) {
		return err
	}
	unlock, lerr := a.Dir.Lock()
	if lerr != nil {
		return lerr
	}
	defer unlock()
	return a.wipeLocked()
}

func (a *App) wipeLocked() error {
	if err := a.Dir.Wipe(); err != nil {
		return err
	}
	return ErrRevokedLocal
}

// Effective 计算当前生效的变量。
func (a *App) Effective() (map[string]string, []string, error) {
	cache, err := a.Dir.Cache()
	if err != nil {
		return nil, nil, err
	}
	ov, err := a.Dir.Overrides()
	if err != nil {
		return nil, nil, err
	}
	vars, skipped := vault.Merge(cache, a.Keys, vault.ActiveIDs(cache), ov, nowMs())
	return vars, skipped, nil
}

// RefreshEnvFile 重新计算并写入 env.sh（例如激活环境或授权到期后）。返回是否有变化。
func (a *App) RefreshEnvFile() (bool, error) {
	unlock, err := a.Dir.Lock()
	if err != nil {
		return false, err
	}
	defer unlock()
	cache, err := a.Dir.Cache()
	if err != nil {
		return false, err
	}
	return a.writeEnvLocked(cache)
}

func (a *App) writeEnvLocked(cache *state.Cache) (bool, error) {
	ov, err := a.Dir.Overrides()
	if err != nil {
		return false, err
	}
	if a.Keys == nil {
		return false, nil
	}
	vars, _ := vault.Merge(cache, a.Keys, vault.ActiveIDs(cache), ov, nowMs())
	data := shell.Render(vars)
	old, _ := os.ReadFile(a.Dir.EnvFile())
	if bytes.Equal(old, data) {
		return false, nil
	}
	return true, state.WriteAtomic(a.Dir.EnvFile(), data)
}
