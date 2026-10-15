package daemon

import (
	"context"
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"
)

const (
	checkInterval = 24 * time.Hour
	// checkJitter 是每天检查前的随机等待上限，避免大量电脑同时访问更新源。
	checkJitter = 10 * time.Minute
	// forceGap 是两次处理手机更新请求之间的最短间隔（docs/rewrite-plan.md 5.11）。
	forceGap = time.Minute
)

// updater 调度检查更新：同一时间只运行一次检查；运行中收到的更新请求等这次结束后再处理。
type updater struct {
	check  func(ctx context.Context, logf func(string, ...any), force bool) bool
	logf   func(string, ...any)
	cancel context.CancelFunc // 升级成功后结束后台服务
	now    func() time.Time

	running  atomic.Bool
	pending  atomic.Bool // 检查运行期间收到了更新请求
	upgraded atomic.Bool

	mu         sync.Mutex
	lastForced time.Time
	auto       *bool // 上一次看到的自动更新开关，还没看到过时为 nil
}

func newUpdater(check func(context.Context, func(string, ...any), bool) bool, logf func(string, ...any), cancel context.CancelFunc) *updater {
	return &updater{check: check, logf: logf, cancel: cancel, now: time.Now}
}

// run 开始一次检查；force 表示手机要求更新。
func (u *updater) run(ctx context.Context, force bool) {
	if u.check == nil || u.upgraded.Load() {
		return
	}
	if force {
		u.mu.Lock()
		if !u.lastForced.IsZero() && u.now().Sub(u.lastForced) < forceGap {
			u.mu.Unlock()
			u.logf("1 分钟内已经处理过更新请求，这次忽略")
			return
		}
		u.lastForced = u.now()
		u.mu.Unlock()
	}
	if u.running.CompareAndSwap(false, true) {
		go u.loop(ctx, force)
		return
	}
	if !force {
		return
	}
	// 正在检查：记下请求，由那次检查结束后接着处理。它可能恰好在这时结束，所以再确认一次。
	u.pending.Store(true)
	if !u.running.Load() && u.pending.Swap(false) && u.running.CompareAndSwap(false, true) {
		go u.loop(ctx, true)
	}
}

func (u *updater) loop(ctx context.Context, force bool) {
	for {
		if u.check(ctx, u.logf, force) {
			u.upgraded.Store(true)
			u.cancel()
			u.running.Store(false)
			return
		}
		u.running.Store(false)
		if ctx.Err() != nil || !u.pending.Swap(false) || !u.running.CompareAndSwap(false, true) {
			return
		}
		force = true
	}
}

// observeAuto 在每次同步后调用：自动更新从关闭变为开启时立即检查一次。
// 后台服务刚启动时只记下状态，由每天的检查处理。
func (u *updater) observeAuto(ctx context.Context, on bool) {
	u.mu.Lock()
	turnedOn := u.auto != nil && !*u.auto && on
	u.auto = &on
	u.mu.Unlock()
	if turnedOn {
		u.logf("自动更新已开启，检查一次更新")
		u.run(ctx, false)
	}
}

// daily 每 24 小时检查一次，每次之前随机等待一段时间。
func (u *updater) daily(ctx context.Context) {
	for ctx.Err() == nil {
		sleep(ctx, rand.N(checkJitter))
		u.run(ctx, false)
		sleep(ctx, checkInterval)
	}
}
