package daemon

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeCheck 记录每次检查的 force，并在 release 收到值之前阻塞，用来模拟检查进行中。
type fakeCheck struct {
	mu      sync.Mutex
	calls   []bool
	started chan bool
	release chan bool // 送入的值作为这次检查的返回值（是否已升级）
}

func newFakeCheck() *fakeCheck {
	return &fakeCheck{started: make(chan bool, 10), release: make(chan bool)}
}

func (f *fakeCheck) check(_ context.Context, _ func(string, ...any), force bool) bool {
	f.mu.Lock()
	f.calls = append(f.calls, force)
	f.mu.Unlock()
	f.started <- force
	return <-f.release
}

func waitStarted(t *testing.T, f *fakeCheck) bool {
	t.Helper()
	select {
	case force := <-f.started:
		return force
	case <-time.After(2 * time.Second):
		t.Fatal("检查没有开始")
		return false
	}
}

func waitIdle(t *testing.T, u *updater) {
	t.Helper()
	for i := 0; i < 200 && u.running.Load(); i++ {
		time.Sleep(5 * time.Millisecond)
	}
	if u.running.Load() {
		t.Fatal("检查没有结束")
	}
}

func newTestUpdater(f *fakeCheck) (*updater, *time.Time, *atomic.Bool) {
	cancelled := &atomic.Bool{}
	u := newUpdater(f.check, func(string, ...any) {}, func() { cancelled.Store(true) })
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	u.now = func() time.Time { return now }
	return u, &now, cancelled
}

func TestUpdaterForceGap(t *testing.T) {
	f := newFakeCheck()
	u, now, _ := newTestUpdater(f)
	ctx := context.Background()

	u.run(ctx, true)
	if !waitStarted(t, f) {
		t.Error("手机要求的更新应当是 force")
	}
	f.release <- false
	waitIdle(t, u)

	*now = now.Add(30 * time.Second)
	u.run(ctx, true) // 1 分钟内的第二次请求被忽略
	time.Sleep(20 * time.Millisecond)
	if len(f.started) != 0 || u.running.Load() {
		t.Fatal("1 分钟内的更新请求应当忽略")
	}

	*now = now.Add(31 * time.Second)
	u.run(ctx, true)
	waitStarted(t, f)
	f.release <- false
	waitIdle(t, u)
}

func TestUpdaterPendingRequest(t *testing.T) {
	f := newFakeCheck()
	u, _, _ := newTestUpdater(f)
	ctx := context.Background()

	u.run(ctx, false) // 每天的检查
	if waitStarted(t, f) {
		t.Error("每天的检查不是 force")
	}
	u.run(ctx, true)  // 检查进行中收到更新请求
	u.run(ctx, false) // 进行中的普通检查直接忽略
	f.release <- false
	if !waitStarted(t, f) {
		t.Error("进行中收到的更新请求应当在结束后以 force 处理")
	}
	f.release <- false
	waitIdle(t, u)
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.calls) != 2 {
		t.Errorf("应当只检查两次，实际 %v", f.calls)
	}
}

func TestUpdaterUpgradeStops(t *testing.T) {
	f := newFakeCheck()
	u, _, cancelled := newTestUpdater(f)
	ctx := context.Background()

	u.run(ctx, true)
	waitStarted(t, f)
	f.release <- true
	waitIdle(t, u)
	if !u.upgraded.Load() || !cancelled.Load() {
		t.Fatal("升级成功后应当结束后台服务")
	}
	u.run(ctx, false)
	time.Sleep(20 * time.Millisecond)
	if len(f.started) != 0 {
		t.Error("已经升级后不再检查")
	}
}

func TestUpdaterObserveAuto(t *testing.T) {
	f := newFakeCheck()
	u, _, _ := newTestUpdater(f)
	ctx := context.Background()

	u.observeAuto(ctx, true) // 刚启动时只记下状态
	u.observeAuto(ctx, true)
	time.Sleep(20 * time.Millisecond)
	if len(f.started) != 0 {
		t.Fatal("开关没有变化时不检查")
	}
	u.observeAuto(ctx, false)
	u.observeAuto(ctx, true) // 从关闭变为开启
	if waitStarted(t, f) {
		t.Error("开启自动更新后的检查不是 force，由开关决定是否升级")
	}
	f.release <- false
	waitIdle(t, u)
}
