package managerui

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/manager"
)

const revokedNotice = "这台电脑的管理身份已被其他管理设备移除，本机的管理密钥已清除。如需继续管理，请重新管理登录。"

func reply(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": code, "message": sentence(msg)})
}

func sentence(s string) string {
	if r, _ := utf8.DecodeLastRuneInString(s); strings.ContainsRune("。！？.!?", r) {
		return s
	}
	return s + "。"
}

// handle 解析 JSON 请求体后调用 fn；fn 返回的值作为响应。
func handle[In any](s *Server, fn func(ctx context.Context, w http.ResponseWriter, in In) (any, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var in In
		if r.Method != http.MethodGet {
			if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
				fail(w, http.StatusBadRequest, "bad_request", "请求内容不对，或者超过了 8 MB")
				return
			}
			s.touch()
		}
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
		defer cancel()
		out, err := fn(ctx, w, in)
		var he *httpError
		switch {
		case errors.As(err, &he):
			fail(w, he.status, he.code, he.msg)
		case err != nil:
			fail(w, http.StatusBadRequest, "failed", err.Error())
		case out != nil:
			reply(w, out)
		default:
			reply(w, map[string]bool{"ok": true})
		}
	}
}

type httpError struct {
	status    int
	code, msg string
}

func (e *httpError) Error() string { return e.msg }

var errLocked = &httpError{http.StatusConflict, "locked", "已锁定，请重新输入管理口令"}

// session 返回当前解锁的会话。
func (s *Server) session() (*manager.Session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sess == nil {
		return nil, errLocked
	}
	return s.sess, nil
}

// dropIfGone 在本机的管理身份已被移除（或其实不是管理设备）时清除本机的管理密钥并锁定。
func (s *Server) dropIfGone(sess *manager.Session, err error) bool {
	if !errors.Is(err, api.ErrRevoked) && !errors.Is(err, manager.ErrNotManager) {
		return false
	}
	_ = s.dir.RemoveManager()
	s.mu.Lock()
	if s.sess == sess {
		s.lockLocked()
	}
	s.notice = revokedNotice
	s.mu.Unlock()
	return true
}

// op 包装需要解锁的操作，统一处理“已被移除”。
func op[In any](s *Server, fn func(ctx context.Context, sess *manager.Session, in In) (any, error)) http.HandlerFunc {
	return handle(s, func(ctx context.Context, _ http.ResponseWriter, in In) (any, error) {
		sess, err := s.session()
		if err != nil {
			return nil, err
		}
		out, err := fn(ctx, sess, in)
		if s.dropIfGone(sess, err) {
			return nil, &httpError{http.StatusConflict, "revoked", revokedNotice}
		}
		return out, err
	})
}

type stateOut struct {
	Phase   string           `json:"phase"` // login、pairing、locked、unlocked、broken
	Rev     int64            `json:"rev"`
	Notice  string           `json:"notice,omitempty"`
	Account *manager.Account `json:"account,omitempty"`
	Pairing *pairingOut      `json:"pairing,omitempty"`
}

type pairingOut struct {
	QR         string `json:"qr"` // 二维码的 SVG
	Code       string `json:"code"`
	DeviceName string `json:"deviceName"`
	ExpiresAt  int64  `json:"expiresAt"`
	Authorized bool   `json:"authorized"`
}

// state 汇总页面要显示的阶段；notice 只返回一次。
func (s *Server) state() (*stateOut, error) {
	file, ferr := s.dir.Manager()
	s.mu.Lock()
	defer s.mu.Unlock()
	out := &stateOut{Rev: s.rev, Notice: s.notice}
	s.notice = ""
	switch {
	case s.pending != nil:
		p := s.pending.p
		out.Phase = "pairing"
		out.Pairing = &pairingOut{QR: qrSVG(p.QR), Code: p.Code, DeviceName: p.DeviceName, ExpiresAt: p.ExpiresAt, Authorized: p.Authorized}
	case ferr != nil:
		out.Phase, out.Notice = "broken", sentence(ferr.Error())
	case file == nil:
		out.Phase = "login"
		acct, err := manager.Suggest(s.dir)
		if err != nil {
			return nil, err
		}
		out.Account = acct
	default:
		out.Phase = "locked"
		if s.sess != nil {
			out.Phase = "unlocked"
		}
		out.Account = &manager.Account{Server: file.Server, Email: file.Email, DeviceName: file.DeviceName, Fixed: true}
	}
	return out, nil
}

// none 是没有内容的请求体。
type none struct{}

func (s *Server) routes(mux *http.ServeMux) {
	stateFn := func(context.Context, http.ResponseWriter, none) (any, error) { return s.state() }

	mux.HandleFunc("POST /api/session", handle(s, func(_ context.Context, _ http.ResponseWriter, in struct{ Code string }) (any, error) {
		token, ok := s.exchange(in.Code)
		if !ok {
			return nil, &httpError{http.StatusForbidden, "session", "这个地址已经用过或不完整。请重新运行 harmonia manager，用它新打开的页面"}
		}
		return map[string]string{"token": token}, nil
	}))
	mux.HandleFunc("GET /api/state", handle(s, stateFn))
	// 页面每隔几秒报告一次自己还开着；active 表示这段时间里用户有过操作。
	mux.HandleFunc("POST /api/ping", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Active bool }
		_ = json.NewDecoder(r.Body).Decode(&in)
		s.mu.Lock()
		s.lastBeat = time.Now()
		if in.Active {
			s.lastActive = s.lastBeat
		}
		s.mu.Unlock()
		st, err := s.state()
		if err != nil {
			fail(w, http.StatusInternalServerError, "failed", err.Error())
			return
		}
		reply(w, st)
	})

	mux.HandleFunc("POST /api/login", handle(s, s.login))
	mux.HandleFunc("POST /api/login/cancel", handle(s, func(context.Context, http.ResponseWriter, none) (any, error) {
		s.mu.Lock()
		s.cancelPendingLocked()
		s.mu.Unlock()
		return s.state()
	}))
	mux.HandleFunc("POST /api/unlock", handle(s, s.unlock))
	mux.HandleFunc("POST /api/lock", handle(s, func(context.Context, http.ResponseWriter, none) (any, error) {
		s.mu.Lock()
		s.lockLocked()
		s.mu.Unlock()
		return s.state()
	}))
	mux.HandleFunc("POST /api/passphrase", op(s, func(_ context.Context, sess *manager.Session, in struct{ Old, New string }) (any, error) {
		s.unlockMu.Lock()
		defer s.unlockMu.Unlock()
		return nil, manager.ChangePassphrase(s.dir, sess.File, in.Old, in.New)
	}))
	mux.HandleFunc("POST /api/logout", op(s, s.logout))
	s.dataRoutes(mux)
}

func (s *Server) login(ctx context.Context, _ http.ResponseWriter, in manager.LoginInput) (any, error) {
	s.mu.Lock()
	busy := s.pending != nil
	s.mu.Unlock()
	if busy {
		return nil, errors.New("已经有一次管理登录在等待批准")
	}
	p, err := manager.Begin(ctx, s.dir, in)
	if err != nil {
		return nil, err
	}
	wctx, cancel := context.WithCancel(s.base)
	pl := &pendingLogin{p: p, cancel: cancel}
	s.mu.Lock()
	s.pending = pl
	s.mu.Unlock()
	go func() {
		defer cancel()
		sess, err := p.Wait(wctx, s.dir)
		s.mu.Lock()
		current := s.pending == pl
		if current {
			s.pending = nil
			if err != nil {
				s.notice = sentence(err.Error())
			}
		}
		s.mu.Unlock()
		if err == nil {
			s.adopt(sess)
		}
	}()
	return s.state()
}

func (s *Server) unlock(ctx context.Context, _ http.ResponseWriter, in struct{ Passphrase string }) (any, error) {
	file, err := s.dir.Manager()
	if err != nil {
		return nil, err
	}
	if file == nil {
		return nil, errors.New("这台电脑还没有管理登录")
	}
	s.unlockMu.Lock()
	keys, err := manager.Unlock(file, in.Passphrase)
	s.unlockMu.Unlock()
	if errors.Is(err, manager.ErrWrongPassphrase) {
		return nil, &httpError{http.StatusBadRequest, "wrong_passphrase", err.Error()}
	}
	if err != nil {
		return nil, err
	}
	sess := manager.Open(s.dir, file, keys)
	if err := sess.Sync(ctx); err != nil {
		if s.dropIfGone(sess, err) {
			return nil, &httpError{http.StatusConflict, "revoked", revokedNotice}
		}
		return nil, err
	}
	s.adopt(sess)
	return s.state()
}

// logout 再验证一次口令后通知服务端移除这个管理身份，然后删除本机的管理密钥。
func (s *Server) logout(ctx context.Context, sess *manager.Session, in struct {
	Passphrase  string
	ConfirmLast bool
}) (any, error) {
	s.unlockMu.Lock()
	_, err := manager.Unlock(sess.File, in.Passphrase)
	s.unlockMu.Unlock()
	if errors.Is(err, manager.ErrWrongPassphrase) {
		return nil, &httpError{http.StatusBadRequest, "wrong_passphrase", err.Error()}
	}
	if err != nil {
		return nil, err
	}
	if err := sess.Logout(ctx, in.ConfirmLast); err != nil {
		if api.IsCode(err, "conflict") && !in.ConfirmLast {
			return nil, &httpError{http.StatusConflict, "last_manager", "这是账号里唯一的管理设备。退出后只能用恢复码找回账号"}
		}
		return nil, err
	}
	if err := s.dir.RemoveManager(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	s.lockLocked()
	s.notice = "已退出管理登录，这台电脑的管理身份已从账号中移除。"
	s.mu.Unlock()
	return s.state()
}
