package keeper

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
)

// SocketPath 是保管进程在数据目录里的本机套接字（数据目录只允许本人访问）。
func SocketPath(dir string) string { return filepath.Join(dir, "keeper.sock") }

type request struct {
	Op    string             `json:"op"`
	Items []api.ApprovalItem `json:"items,omitempty"`
	Auth  *Auth              `json:"auth,omitempty"`
}

type response struct {
	Values []Value  `json:"values,omitempty"`
	Auths  []Auth   `json:"auths,omitempty"`
	Ended  []string `json:"ended,omitempty"`
	Error  string   `json:"error,omitempty"`
}

// errNotRunning 表示保管进程没有在运行。
var errNotRunning = errors.New("保管进程没有在运行")

func call(dir string, req request) (*response, error) {
	conn, err := net.DialTimeout("unix", SocketPath(dir), 2*time.Second)
	if err != nil {
		return nil, errNotRunning
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return nil, err
	}
	var res response
	if err := json.NewDecoder(conn).Decode(&res); err != nil {
		return nil, errors.New("保管进程没有回应，可以运行 harmonia lock 后重试")
	}
	if res.Error != "" {
		return nil, errors.New(res.Error)
	}
	return &res, nil
}

// Get 向保管进程要 items 中这个终端能用的变量；保管进程没有在运行时返回空。
func Get(dir string, items []api.ApprovalItem) ([]Value, error) {
	res, err := call(dir, request{Op: "get", Items: items})
	if errors.Is(err, errNotRunning) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return res.Values, nil
}

// Put 把一项授权交给保管进程；没有在运行时用 bin 启动它。
func Put(dir, bin string, a Auth) error {
	req := request{Op: "put", Auth: &a}
	_, err := call(dir, req)
	if !errors.Is(err, errNotRunning) {
		return err
	}
	if err := start(bin); err != nil {
		return err
	}
	for i := 0; i < 50; i++ {
		time.Sleep(100 * time.Millisecond)
		if _, err = call(dir, req); !errors.Is(err, errNotRunning) {
			return err
		}
	}
	return errors.New("保管进程没能启动")
}

// List 列出保管进程持有的授权；没有在运行时返回空。
func List(dir string) ([]Auth, error) {
	res, err := call(dir, request{Op: "list"})
	if errors.Is(err, errNotRunning) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return res.Auths, nil
}

// Lock 结束保管进程持有的全部授权（保管进程随即退出），返回结束的授权 ID。
func Lock(dir string) ([]string, error) {
	res, err := call(dir, request{Op: "lock"})
	if errors.Is(err, errNotRunning) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return res.Ended, nil
}

// Hooks 是保管进程要用到的服务端操作，由调用方提供。
type Hooks struct {
	// Listen 保持推送连接，收到授权结束（authorization-ended）时通知保管进程；设备被撤销时返回 api.ErrRevoked。
	Listen func(ctx context.Context, onEvent func(api.Event)) error
	// End 在服务端结束一项授权；Authorizations 列出服务端记录的这台设备的授权。
	End            func(ctx context.Context, id string) error
	Authorizations func(ctx context.Context) ([]api.Authorization, error)
	Logf           func(format string, args ...any)
}

// startGrace 是保管进程启动后等待第一项授权的时间。
const startGrace = 30 * time.Second

// Serve 运行保管进程，直到没有任何授权、执行了 harmonia lock、设备被撤销或 ctx 结束。
// 退出时尽力在服务端结束自己持有的授权。已经有保管进程在运行时直接返回。
func Serve(ctx context.Context, dir string, h Hooks) error {
	harden()
	if _, err := call(dir, request{Op: "list"}); err == nil {
		return nil
	}
	path := SocketPath(dir)
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	_ = os.Chmod(path, 0o600)
	k := &keeper{store: NewStore(), hooks: h}
	ctx, k.stop = context.WithCancel(ctx)
	defer func() {
		ln.Close()
		_ = os.Remove(path)
		k.endAtServer(k.store.EndAll())
		k.wg.Wait()
	}()
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	go k.listen(ctx)
	go k.tick(ctx)
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go k.handle(conn)
	}
}

type keeper struct {
	store      *Store
	hooks      Hooks
	stop       context.CancelFunc
	wg         sync.WaitGroup
	reconciled sync.Once
}

func nowMs() int64 { return time.Now().UnixMilli() }

func (k *keeper) handle(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	reply := func(res response) { _ = json.NewEncoder(conn).Encode(res) }
	session, err := peerSession(conn)
	if err != nil {
		reply(response{Error: "无法确认请求来自哪个程序：" + err.Error()})
		return
	}
	var req request
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		reply(response{Error: "请求格式不对"})
		return
	}
	switch req.Op {
	case "get":
		reply(response{Values: k.store.Get(req.Items, session, nowMs())})
	case "put":
		if req.Auth == nil {
			reply(response{Error: "请求格式不对"})
			return
		}
		a := *req.Auth
		a.Session = session
		k.store.Put(a)
		reply(response{})
		k.reconciled.Do(func() { k.async(k.reconcile) })
	case "list":
		reply(response{Auths: k.store.List()})
	case "lock":
		ended := k.store.EndAll()
		k.endAtServer(ended)
		reply(response{Ended: ended})
		k.stop()
	default:
		reply(response{Error: "不认识的操作"})
	}
}

func (k *keeper) async(f func()) {
	k.wg.Add(1)
	go func() {
		defer k.wg.Done()
		f()
	}()
}

// endAtServer 尽力在服务端结束这些授权，让手机上不再显示。
func (k *keeper) endAtServer(ids []string) {
	if len(ids) == 0 {
		return
	}
	k.async(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		for _, id := range ids {
			if err := k.hooks.End(ctx, id); err != nil {
				k.hooks.Logf("没能在服务器上结束授权 %s：%v", id, err)
			}
		}
	})
}

// reconcile 结束服务端记录、但保管进程没有持有的授权（例如断网时关机，之前的保管进程没能通知到）。
func (k *keeper) reconcile() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	list, err := k.hooks.Authorizations(ctx)
	if err != nil {
		return
	}
	for _, a := range list {
		if !k.store.Held(a.ID) {
			_ = k.hooks.End(ctx, a.ID)
		}
	}
}

// tick 每 5 秒结束到期的授权和终端已经关闭的授权；没有任何授权时退出。
func (k *keeper) tick(ctx context.Context) {
	started := time.Now()
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			k.endAtServer(k.store.Prune(nowMs(), sessionAlive))
			if k.store.Empty() && time.Since(started) > startGrace {
				k.stop()
				return
			}
		}
	}
}

// listen 保持推送连接：手机上结束授权、授权因变量或环境变化结束时丢掉它；设备被撤销时丢掉全部并退出。
func (k *keeper) listen(ctx context.Context) {
	for ctx.Err() == nil {
		err := k.hooks.Listen(ctx, func(ev api.Event) {
			if ev.Type == "authorization-ended" {
				k.store.End(ev.ID)
			}
		})
		if errors.Is(err, api.ErrRevoked) {
			k.store.EndAll()
			k.stop()
			return
		}
		select {
		case <-ctx.Done():
		case <-time.After(5 * time.Second):
		}
	}
}
