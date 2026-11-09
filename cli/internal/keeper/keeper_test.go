package keeper

import (
	"context"
	"os"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
)

var (
	key   = api.ApprovalItem{EnvironmentID: "e", Name: "KEY"}
	model = api.ApprovalItem{EnvironmentID: "e", Name: "MODEL"}
)

func auth(id, scope string, expires int64, session int, vals ...Value) Auth {
	return Auth{ID: id, Scope: scope, ExpiresAt: expires, Session: session, Values: vals}
}

func TestStoreScopeAndExpiry(t *testing.T) {
	s := NewStore()
	s.Put(auth("a", "terminal", 0, 7, Value{"e", "KEY", "k-terminal"}))
	s.Put(auth("b", "all", 100, 0, Value{"e", "MODEL", "m"}))
	if got := s.Get([]api.ApprovalItem{key, model}, 7, 50); len(got) != 2 || got[0].Value != "k-terminal" {
		t.Fatalf("同一终端两项都能用：%+v", got)
	}
	if got := s.Get([]api.ApprovalItem{key, model}, 8, 50); len(got) != 1 || got[0].Name != "MODEL" {
		t.Fatalf("其他终端只能用“所有程序”的：%+v", got)
	}
	if got := s.Get([]api.ApprovalItem{model}, 7, 100); len(got) != 0 {
		t.Fatalf("到期后不能再用：%+v", got)
	}
	ended := s.Prune(100, func(sid int) bool { return sid != 7 })
	if !slices.Equal(ended, []string{"a", "b"}) || !s.Empty() {
		t.Fatalf("到期的和终端已关闭的都结束：%v", ended)
	}
	s.Put(auth("c", "all", 0, 0, Value{"e", "KEY", "long"}))
	if ended := s.Prune(1<<60, func(int) bool { return false }); len(ended) != 0 {
		t.Fatalf("长期的“所有程序”授权不会自己结束：%v", ended)
	}
	if list := s.List(); len(list) != 1 || list[0].Values != nil || list[0].Items[0] != key {
		t.Fatalf("列出授权时不带值：%+v", list)
	}
}

type fakeServer struct {
	mu     sync.Mutex
	ended  []string
	server []api.Authorization
	events chan api.Event
}

func (f *fakeServer) hooks() Hooks {
	return Hooks{
		Listen: func(ctx context.Context, on func(api.Event)) error {
			for {
				select {
				case <-ctx.Done():
					return ctx.Err()
				case ev := <-f.events:
					if ev.Type == "revoked" {
						return api.ErrRevoked
					}
					on(ev)
				}
			}
		},
		End: func(_ context.Context, id string) error {
			f.mu.Lock()
			defer f.mu.Unlock()
			f.ended = append(f.ended, id)
			return nil
		},
		Authorizations: func(context.Context) ([]api.Authorization, error) { return f.server, nil },
		Logf:           func(string, ...any) {},
	}
}

func (f *fakeServer) endedIDs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Sorted(slices.Values(f.ended))
}

func eventually(t *testing.T, cond func() bool) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("超时")
}

// 通过本机套接字保存、读取、结束授权；手机上结束的授权随推送丢掉；lock 后保管进程退出并在服务端结束。
func TestServeOverSocket(t *testing.T) {
	// Unix 套接字路径有长度限制，用短路径。
	dir, err := os.MkdirTemp("", "hk")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	f := &fakeServer{events: make(chan api.Event, 4), server: []api.Authorization{{ID: "stale"}, {ID: "one"}}}
	done := make(chan error, 1)
	go func() { done <- Serve(context.Background(), dir, f.hooks()) }()
	eventually(t, func() bool { _, err := call(dir, request{Op: "list"}); return err == nil })

	if got, err := Get(dir, []api.ApprovalItem{key}); err != nil || len(got) != 0 {
		t.Fatalf("%v %v", got, err)
	}
	if err := Put(dir, "unused", auth("one", "terminal", 0, 0, Value{"e", "KEY", "secret"})); err != nil {
		t.Fatal(err)
	}
	if err := Put(dir, "unused", auth("two", "all", 0, 0, Value{"e", "MODEL", "m"})); err != nil {
		t.Fatal(err)
	}
	// 同一个测试进程属于同一个会话，“仅这个终端”的授权也能用。
	if got, err := Get(dir, []api.ApprovalItem{key, model}); err != nil || len(got) != 2 || got[0].Value != "secret" {
		t.Fatalf("%+v %v", got, err)
	}
	// 第一次保存后，结束服务端记着、但保管进程没有持有的授权。
	eventually(t, func() bool { return slices.Equal(f.endedIDs(), []string{"stale"}) })

	f.events <- api.Event{Type: "authorization-ended", ID: "one"}
	eventually(t, func() bool { list, _ := List(dir); return len(list) == 1 && list[0].ID == "two" })

	ended, err := Lock(dir)
	if err != nil || !slices.Equal(ended, []string{"two"}) {
		t.Fatalf("%v %v", ended, err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("lock 后保管进程没有退出")
	}
	if !slices.Equal(f.endedIDs(), []string{"stale", "two"}) {
		t.Fatalf("%v", f.endedIDs())
	}
	if list, err := List(dir); err != nil || list != nil {
		t.Fatalf("退出后列表为空：%v %v", list, err)
	}
}

func TestServeExitsWhenRevoked(t *testing.T) {
	dir, err := os.MkdirTemp("", "hk")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	f := &fakeServer{events: make(chan api.Event, 1)}
	done := make(chan error, 1)
	go func() { done <- Serve(context.Background(), dir, f.hooks()) }()
	eventually(t, func() bool { _, err := call(dir, request{Op: "list"}); return err == nil })
	if err := Put(dir, "unused", auth("x", "all", 0, 0, Value{"e", "KEY", "s"})); err != nil {
		t.Fatal(err)
	}
	f.events <- api.Event{Type: "revoked"}
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("设备被撤销后保管进程没有退出")
	}
}
