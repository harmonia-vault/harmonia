// Package api 是 docs/protocol.md 第 3 节的 HTTP 客户端。
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Error 是服务端返回的错误。
type Error struct {
	Status  int
	Code    string
	Message string
}

func (e *Error) Error() string {
	if e.Message != "" {
		return e.Message
	}
	return fmt.Sprintf("服务器返回错误（%d %s）", e.Status, e.Code)
}

// ErrRevoked 表示本设备已被移除，调用方应清除本地数据。
var ErrRevoked = errors.New("这台设备已被移除")

func IsCode(err error, code string) bool {
	var e *Error
	return errors.As(err, &e) && e.Code == code
}

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
	for k, v := range o.headers {
		req.Header.Set(k, v)
	}
	res, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("无法连接服务器：%w", err)
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
		return &Error{Status: res.StatusCode, Code: e.Error, Message: e.Message}
	}
	if out != nil {
		if err := json.Unmarshal(data, out); err != nil {
			return errors.New("服务器响应格式不对，请确认地址是 Harmonia 服务")
		}
	}
	return nil
}

// Public 调用不需要会话的接口。
func (c *Client) Public(ctx context.Context, method, path string, body, out any) error {
	return c.do(ctx, method, path, body, out, reqOpts{})
}

// WithToken 使用指定令牌（密码会话、恢复会话）调用。
func (c *Client) WithToken(ctx context.Context, token, method, path string, body, out any) error {
	return c.do(ctx, method, path, body, out, reqOpts{token: token})
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
