// Package api 是 docs/protocol.md 第 3 节的 HTTP 客户端。
package api

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Error 是服务端返回的错误。
type Error struct {
	Status  int
	Code    string
	Message string
	// RetryAfter 是被限流时服务端给出的等待时间。
	RetryAfter time.Duration
}

func (e *Error) Error() string {
	if e.Message != "" {
		return e.Message
	}
	return fmt.Sprintf("服务器返回错误（%d %s）", e.Status, e.Code)
}

// NetError 表示没有连上服务器（请求可能没有发出，也可能发出后没有收到响应）。
type NetError struct{ Err error }

func (e *NetError) Error() string { return "无法连接服务器：" + netReason(e.Err) }

func (e *NetError) Unwrap() error { return e.Err }

// netReason 把网络错误说成一句人话：地址解析不了、超时、证书不对、被拒绝。
func netReason(err error) string {
	var dns *net.DNSError
	var cert *tls.CertificateVerificationError
	var ne net.Error
	switch {
	case errors.As(err, &dns):
		return fmt.Sprintf("无法解析地址 %s，请检查网络或服务器地址", dns.Name)
	case errors.As(err, &cert):
		return "服务器证书验证失败，请确认服务器地址，或检查网络中是否有代理替换了证书"
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &ne) && ne.Timeout():
		return "连接超时，请检查网络"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "连接被拒绝，服务器可能没有运行"
	case errors.Is(err, context.Canceled):
		return "已取消"
	}
	return err.Error()
}

// IsNetwork 判断错误是否是没有连上服务器。
func IsNetwork(err error) bool {
	var ne *NetError
	return errors.As(err, &ne)
}

// ErrRevoked 表示本设备已被移除，调用方应清除本地数据。
var ErrRevoked = errors.New("这台设备已被移除")

func IsCode(err error, code string) bool {
	var e *Error
	return errors.As(err, &e) && e.Code == code
}

// Version 是本机 CLI 的版本，由 main 在启动时写入。它随每个请求上报，只用于在管理设备上显示。
var Version string

// Signer 用设备签名钥对登录挑战签名。
type Signer interface {
	DeviceID() string
	SignAuth(nonce string) string
}

type Client struct {
	Base      string
	AccountID string
	HTTP      *http.Client
	Signer    Signer

	mu      sync.Mutex
	token   string
	expires time.Time
}

func New(base string) *Client {
	return &Client{Base: strings.TrimRight(base, "/"), HTTP: &http.Client{Timeout: 30 * time.Second}}
}

// NormalizeServer 校验并规范化服务器地址。
func NormalizeServer(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", errors.New("服务器地址格式不对，例如 https://vault.example.com")
	}
	local := u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1"
	if u.Scheme != "https" && !(u.Scheme == "http" && local) {
		return "", errors.New("服务器地址必须使用 https://")
	}
	return strings.TrimRight(u.Scheme+"://"+u.Host+u.Path, "/"), nil
}

type reqOpts struct {
	token   string
	headers map[string]string
}

func (c *Client) do(ctx context.Context, method, path string, body, out any, o reqOpts) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.Base+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")
	if o.token != "" {
		req.Header.Set("authorization", "Bearer "+o.token)
	}
	if c.AccountID != "" {
		req.Header.Set("x-harmonia-account", c.AccountID)
	}
	if Version != "" {
		req.Header.Set("x-harmonia-version", Version)
	}
	for k, v := range o.headers {
		req.Header.Set(k, v)
	}
	res, err := c.HTTP.Do(req)
	if err != nil {
		return &NetError{err}
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if res.StatusCode != http.StatusOK {
		var e struct{ Error, Message string }
		if json.Unmarshal(data, &e) != nil || e.Error == "" {
			return &Error{Status: res.StatusCode, Code: "http", Message: fmt.Sprintf("服务器返回了意外的响应（HTTP %d），请确认地址是 Harmonia 服务。", res.StatusCode)}
		}
		if e.Error == "device_revoked" {
			return ErrRevoked
		}
		out := &Error{Status: res.StatusCode, Code: e.Error, Message: e.Message}
		if secs, err := strconv.Atoi(res.Header.Get("retry-after")); err == nil && secs >= 0 {
			out.RetryAfter = time.Duration(secs) * time.Second
		}
		return out
	}
	if out != nil {
		if err := json.Unmarshal(data, out); err != nil {
			return errors.New("服务器响应格式不对，请确认地址是 Harmonia 服务")
		}
	}
	return nil
}

// Public 调用不需要会话的接口；设置了 AccountID 时带上账号请求头。
func (c *Client) Public(ctx context.Context, method, path string, body, out any) error {
	return c.do(ctx, method, path, body, out, reqOpts{})
}

// DeviceToken 返回有效的设备会话令牌，必要时重新登录。
func (c *Client) DeviceToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" && time.Until(c.expires) > time.Minute {
		return c.token, nil
	}
	if c.Signer == nil {
		return "", errors.New("本机还没有接入账号，请先运行 harmonia login")
	}
	var ch struct{ Nonce string }
	if err := c.do(ctx, "POST", "/api/v1/auth/challenge", map[string]string{"deviceId": c.Signer.DeviceID()}, &ch, reqOpts{}); err != nil {
		return "", err
	}
	var s struct {
		Token     string
		ExpiresAt int64
	}
	body := map[string]string{"deviceId": c.Signer.DeviceID(), "nonce": ch.Nonce, "signature": c.Signer.SignAuth(ch.Nonce)}
	if err := c.do(ctx, "POST", "/api/v1/auth/device-session", body, &s, reqOpts{}); err != nil {
		return "", err
	}
	c.token, c.expires = s.Token, time.UnixMilli(s.ExpiresAt)
	return c.token, nil
}

// retryWindow 是写请求短时重试的总时长（docs/protocol.md 第 3 节）。
var retryWindow = 10 * time.Second

// retryable 判断写请求失败后是否值得重试：没连上、服务器内部错误、被限流。
func retryable(err error) (bool, time.Duration) {
	var e *Error
	switch {
	case IsNetwork(err):
		return true, 0
	case errors.As(err, &e) && e.Code == "rate_limited":
		return true, e.RetryAfter
	case errors.As(err, &e) && e.Status >= 500:
		return true, 0
	}
	return false, 0
}

// DeviceWrite 以设备身份发送幂等的写请求：遇到网络错误、5xx 或限流时，在 retryWindow 内退避重试，
// 每次发送的都是同一个请求（包括幂等键），服务端不会重复写入。不在本机排队稍后重放。
func (c *Client) DeviceWrite(ctx context.Context, method, path string, body, out any, headers map[string]string) error {
	deadline := time.Now().Add(retryWindow)
	wait := 500 * time.Millisecond
	for {
		err := c.Device(ctx, method, path, body, out, headers)
		ok, after := retryable(err)
		if err == nil || !ok || ctx.Err() != nil {
			return err
		}
		if after > wait {
			wait = after
		}
		if time.Now().Add(wait).After(deadline) {
			return err
		}
		select {
		case <-ctx.Done():
			return err
		case <-time.After(wait):
		}
		wait *= 2
	}
}

// Device 以设备身份调用；会话过期时自动重新登录一次。
func (c *Client) Device(ctx context.Context, method, path string, body, out any, headers map[string]string) error {
	for attempt := 0; ; attempt++ {
		token, err := c.DeviceToken(ctx)
		if err != nil {
			return err
		}
		err = c.do(ctx, method, path, body, out, reqOpts{token: token, headers: headers})
		if attempt == 0 && IsCode(err, "unauthorized") {
			c.mu.Lock()
			c.token = ""
			c.mu.Unlock()
			continue
		}
		return err
	}
}
