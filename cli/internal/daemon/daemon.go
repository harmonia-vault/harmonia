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
	notPairedWait    = 30 * time.Second
)

// Hooks 允许后台服务挂接额外的周期任务（例如检查更新）。
type Hooks struct {
	Daily func(ctx context.Context, logf func(string, ...any))
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
	lastDaily := time.Time{}
	for ctx.Err() == nil {
		if hooks.Daily != nil && time.Since(lastDaily) > 24*time.Hour {
			lastDaily = time.Now()
			go hooks.Daily(ctx, logf)
		}
		a, err := app.Load(true)
		if err != nil {
			if !errors.Is(err, app.ErrNotPaired) {
				logf("读取本机状态失败：%v", err)
			}
			sleep(ctx, notPairedWait)
			continue
		}
		session(ctx, a, logf)
		sleep(ctx, time.Second)
	}
	logf("后台服务停止")
	return nil
}

// session 在一个已接入的状态下运行，直到设备被移除、退出登录或 ctx 结束。
func session(ctx context.Context, a *app.App, logf func(string, ...any)) {
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
				if ev.Type == "changed" {
					poke()
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
