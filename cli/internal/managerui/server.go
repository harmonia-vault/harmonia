// Package managerui 是 harmonia manager 打开的本机管理页面（docs/rewrite-plan.md 16.5）：
// 只在回环地址上提供页面和接口，加解密都在本进程内完成，浏览器只负责显示和提交操作。
package managerui

import (
	"context"
	"crypto/subtle"
	"embed"
	"errors"
	"io/fs"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/manager"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

//go:embed static
var staticFiles embed.FS

const (
	// IdleLimit 是没有操作多久后锁定；BeatLimit 是多久收不到页面心跳就认为页面已关闭。
	IdleLimit = 5 * time.Minute
	BeatLimit = 30 * time.Second
)

// Server 持有管理页面的全部状态。解开的密钥只在 sess 里，锁定即丢弃。
type Server struct {
	dir  *state.Dir
	host string // 监听的地址，如 127.0.0.1:53124
	base context.Context

	// unlockMu 让口令尝试逐个进行：每次口令派生要占用 256 MiB 内存。
	unlockMu sync.Mutex

	mu         sync.Mutex
	accessCode string // 一次性访问码，换取令牌后清空
	token      string
	sess       *manager.Session
	stopSess   context.CancelFunc
	pending    *pendingLogin
	notice     string // 下一次查询状态时显示一次的提示
	rev        int64  // 数据每变化一次加一，页面据此刷新
	lastActive time.Time
	lastBeat   time.Time
}

type pendingLogin struct {
	p      *manager.Pending
	cancel context.CancelFunc
	err    string // 等待结束且没有成功时的说明
}

// New 在 listener 上准备服务；ctx 结束时锁定并停止全部后台任务。
func New(ctx context.Context, dir *state.Dir, ln net.Listener) *Server {
	return &Server{dir: dir, host: ln.Addr().String(), base: ctx, accessCode: hc.B64(hc.Random(24))}
}

// URL 是要在浏览器里打开的地址。访问码放在 # 之后，不会出现在请求里。
func (s *Server) URL() string { return "http://" + s.host + "/#" + s.accessCode }

// Serve 提供页面和接口，直到 ctx 结束。
func (s *Server) Serve(ln net.Listener) error {
	assets, err := fs.Sub(staticFiles, "static")
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	s.routes(mux)
	mux.Handle("GET /", http.FileServerFS(assets))
	srv := &http.Server{Handler: s.guard(mux), ReadHeaderTimeout: 10 * time.Second}
	go s.watch()
	go func() {
		<-s.base.Done()
		s.mu.Lock()
		s.lockLocked()
		s.cancelPendingLocked()
		s.mu.Unlock()
		srv.Close()
	}()
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// guard 是全部请求的访问控制：只接受发给本机监听地址的同源请求，接口还要带会话令牌。
func (s *Server) guard(next http.Handler) http.Handler {
	_, port, _ := net.SplitHostPort(s.host)
	hosts := map[string]bool{"127.0.0.1:" + port: true, "localhost:" + port: true}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		// Host 不是本机监听地址时，可能是别的域名被解析到了 127.0.0.1（DNS 重绑定）。
		if !hosts[r.Host] {
			http.Error(w, "只能通过 harmonia manager 打印的地址访问。", http.StatusForbidden)
			return
		}
		if o := r.Header.Get("Origin"); o != "" && !hosts[strings.TrimPrefix(o, "http://")] {
			http.Error(w, "不接受来自其他网站的请求。", http.StatusForbidden)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/api/") {
			if r.Method != http.MethodGet && !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
				fail(w, http.StatusUnsupportedMediaType, "bad_request", "请求格式不对。")
				return
			}
			if r.URL.Path != "/api/session" && !s.authorized(r) {
				fail(w, http.StatusUnauthorized, "session", "这个页面的会话已失效，请重新运行 harmonia manager。")
				return
			}
			r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) authorized(r *http.Request) bool {
	got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	s.mu.Lock()
	defer s.mu.Unlock()
	return ok && s.token != "" && subtle.ConstantTimeCompare([]byte(got), []byte(s.token)) == 1
}

// exchange 用一次性访问码换取会话令牌；访问码随即作废。
func (s *Server) exchange(code string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.accessCode == "" || subtle.ConstantTimeCompare([]byte(code), []byte(s.accessCode)) != 1 {
		return "", false
	}
	s.accessCode = ""
	s.token = hc.B64(hc.Random(32))
	s.lastBeat, s.lastActive = time.Now(), time.Now()
	return s.token, true
}

// watch 每秒检查一次：没有操作满 5 分钟，或 30 秒收不到页面心跳（页面已关闭），就锁定；
// 页面关闭时正在等待批准的管理登录一并取消。
func (s *Server) watch() {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-s.base.Done():
			return
		case now := <-t.C:
			s.mu.Lock()
			gone := s.token != "" && now.Sub(s.lastBeat) > BeatLimit
			if s.sess != nil && (gone || now.Sub(s.lastActive) > IdleLimit) {
				s.lockLocked()
				if !gone {
					s.notice = "5 分钟没有操作，已锁定。"
				}
			}
			if gone {
				s.cancelPendingLocked()
			}
			s.mu.Unlock()
		}
	}
}

// touch 记录一次用户操作。
func (s *Server) touch() {
	s.mu.Lock()
	s.lastActive, s.lastBeat = time.Now(), time.Now()
	s.mu.Unlock()
}

// lockLocked 丢弃解锁的会话和其中的密钥，停止推送连接。
func (s *Server) lockLocked() {
	if s.stopSess != nil {
		s.stopSess()
	}
	s.sess, s.stopSess = nil, nil
	s.rev++
}

func (s *Server) cancelPendingLocked() {
	if s.pending != nil {
		s.pending.cancel()
		s.pending = nil
	}
}

// adopt 把解锁的会话设为当前会话，并在后台保持推送连接。
func (s *Server) adopt(sess *manager.Session) {
	ctx, cancel := context.WithCancel(s.base)
	s.mu.Lock()
	s.lockLocked()
	s.sess, s.stopSess = sess, cancel
	s.lastActive, s.lastBeat = time.Now(), time.Now()
	s.mu.Unlock()
	go s.follow(ctx, sess)
}

// follow 保持推送连接，其他设备有修改时让页面刷新；连接断开后等一会儿重连并补一次同步。
func (s *Server) follow(ctx context.Context, sess *manager.Session) {
	bump := func() {
		s.mu.Lock()
		s.rev++
		s.mu.Unlock()
	}
	for wait := time.Second; ctx.Err() == nil; {
		started := time.Now()
		err := sess.Listen(ctx, bump)
		if ctx.Err() != nil {
			return
		}
		if s.dropIfGone(sess, err) {
			return
		}
		if time.Since(started) > time.Minute {
			wait = time.Second
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
		wait = min(wait*2, 30*time.Second)
		if err := sess.Sync(ctx); err == nil {
			bump()
		} else if s.dropIfGone(sess, err) {
			return
		}
	}
}
