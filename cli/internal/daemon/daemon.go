// Package daemon 是后台服务：保持推送连接，收到变化后同步并更新 env.sh。
package daemon

import (
	"context"
	"errors"
	"log"
	"os"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

const (
	fullSyncInterval = 5 * time.Minute
	refreshInterval  = time.Minute
	// 还没有接入账号时只是读一下本机的配置文件，隔得短一些，harmonia login 完成后很快就能连上服务器。
	notPairedWait = 3 * time.Second
)

// ErrUpgraded 表示程序已经升级，后台服务退出，由系统（或调用方）用新程序重新启动。
var ErrUpgraded = errors.New("已升级到新版本")

// Hooks 允许后台服务挂接检查更新。
type Hooks struct {
	// Check 检查更新，并在需要时升级：每天调用一次，自动更新刚开启时也调用；force 为 true 表示
	// 手机要求更新，不论自动更新是否开启都升级。返回 true 表示程序已被替换。
	Check func(ctx context.Context, logf func(string, ...any), force bool) bool
}

// Logf 在后台服务的日志里追加一行，用于 Run 结束之后（例如升级后重新启动新程序）的记录。
func Logf(format string, args ...any) {
	if d, err := state.Open(); err == nil {
		openLog(d).Printf(format, args...)
	}
}

func openLog(d *state.Dir) *log.Logger {
	path := d.File("daemon.log")
	if fi, err := os.Stat(path); err == nil && fi.Size() > 1<<20 {
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return log.New(os.Stderr, "", log.LstdFlags)
	}
	return log.New(f, "", log.LstdFlags)
}

// Run 持续运行直到 ctx 结束。
func Run(ctx context.Context, hooks Hooks) error {
	d, err := state.Open()
	if err != nil {
		return err
	}
	logger := openLog(d)
	logf := logger.Printf
	logf("后台服务启动")
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	u := newUpdater(hooks.Check, logf, cancel)
	if hooks.Check != nil {
		go u.daily(ctx)
	}
	for ctx.Err() == nil {
		a, err := app.Load(true)
		if err != nil {
			if !errors.Is(err, app.ErrNotPaired) {
				logf("读取本机状态失败：%v", err)
			}
			sleep(ctx, notPairedWait)
			continue
		}
		session(ctx, a, logf, u)
		sleep(ctx, time.Second)
	}
	if u.upgraded.Load() {
		return ErrUpgraded
	}
	logf("后台服务停止")
	return nil
}

// session 在一个已接入的状态下运行，直到设备被移除、退出登录或 ctx 结束。
func session(ctx context.Context, a *app.App, logf func(string, ...any), u *updater) {
	updateCtx := ctx // 升级不随本轮会话结束而中断
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	trigger := make(chan struct{}, 1)
	poke := func() {
		select {
		case trigger <- struct{}{}:
		default:
		}
	}
	revoked := make(chan struct{})
	go func() {
		backoff := time.Second
		for ctx.Err() == nil {
			connected := time.Now()
			err := a.Client.Listen(ctx, func(ev api.Event) {
				switch ev.Type {
				case "changed":
					poke()
				case "update":
					u.run(updateCtx, true)
				}
			})
			if errors.Is(err, api.ErrRevoked) {
				close(revoked)
				return
			}
			if ctx.Err() != nil {
				return
			}
			if time.Since(connected) > time.Minute {
				backoff = time.Second
			}
			logf("推送连接断开（%v），%s 后重连", err, backoff)
			sleep(ctx, backoff)
			poke() // 重连后补一次同步
			if backoff < time.Minute {
				backoff *= 2
			}
		}
	}()
	syncNow := func() bool {
		err := a.Sync(ctx)
		switch {
		case err == nil:
			if cache, err := a.Dir.Cache(); err == nil {
				u.observeAuto(updateCtx, cache.AutoUpdate)
			}
			return true
		case errors.Is(err, app.ErrRevokedLocal):
			logf("本设备已被移除，本机数据已清除")
			return false
		default:
			logf("同步失败：%v", err)
			return true
		}
	}
	if !syncNow() {
		return
	}
	full := time.NewTicker(fullSyncInterval)
	refresh := time.NewTicker(refreshInterval)
	defer full.Stop()
	defer refresh.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-revoked:
			_ = a.HandleRevoked(api.ErrRevoked)
			logf("本设备已被移除，本机数据已清除")
			return
		case <-trigger:
			if !syncNow() {
				return
			}
		case <-full.C:
			if !syncNow() {
				return
			}
		case <-refresh.C:
			// 退出登录后（keys 被删除）结束本轮，回到等待接入状态。
			if cfg, err := a.Dir.Config(); err != nil || !cfg.Paired() || cfg.DeviceID != a.Config.DeviceID {
				return
			}
			if _, err := a.RefreshEnvFile(); err != nil {
				logf("更新变量文件失败：%v", err)
			}
		}
	}
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
