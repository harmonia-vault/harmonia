package api

import (
	"context"
	"fmt"
	"net/url"
)

type Instance struct {
	Product      string `json:"product"`
	Version      string `json:"version"`
	Protocol     int    `json:"protocol"`
	Registration struct {
		Open              bool `json:"open"`
		EmailVerification bool `json:"emailVerification"`
	} `json:"registration"`
}

type Prelogin struct {
	KdfSalt string `json:"kdfSalt"`
}

type Session struct {
	Token     string `json:"token"`
	ExpiresAt int64  `json:"expiresAt"`
	AccountID string `json:"accountId"`
}

type Account struct {
	AccountID   string `json:"accountId"`
	Email       string `json:"email"`
	Initialized bool   `json:"initialized"`
	RootPub     string `json:"rootPub"`
}

type PairingRequest struct {
	ID        string `json:"id"`
	Secret    string `json:"secret"`
	ExpiresAt int64  `json:"expiresAt"`
}

type Environment struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	KeyVersion string `json:"keyVersion"`
	Role       string `json:"role"`
	ExpiresAt  int64  `json:"expiresAt"`
	// Active 与 Position 是授权上的激活状态和顺序（越小越靠前，同名变量由靠前的环境提供）。
	Active   bool `json:"active"`
	Position int  `json:"position"`
}

// ActivationItem 是提交激活状态时的一项，整个列表按顺序排列。
type ActivationItem struct {
	EnvID  string `json:"envId"`
	Active bool   `json:"active"`
}

type Envelope struct {
	EnvID      string `json:"envId"`
	KeyVersion string `json:"keyVersion"`
	Sealed     string `json:"sealed"`
	Sig        string `json:"sig"`
}

type Variable struct {
	EnvID      string `json:"envId"`
	Name       string `json:"name"`
	Value      string `json:"value"`
	KeyVersion string `json:"keyVersion"`
	Deleted    bool   `json:"deleted"`
	Seq        int64  `json:"seq"`
}

type Sync struct {
	Seq  int64 `json:"seq"`
	Self struct {
		ID               string `json:"id"`
		Kind             string `json:"kind"`
		Name             string `json:"name"`
		RotationRequired bool   `json:"rotationRequired"`
	} `json:"self"`
	Environments []Environment `json:"environments"`
	Envelopes    []Envelope    `json:"envelopes"`
	Variables    []Variable    `json:"variables"`
}

func (c *Client) Instance(ctx context.Context) (*Instance, error) {
	var out Instance
	if err := c.Public(ctx, "GET", "/api/v1/instance", nil, &out); err != nil {
		return nil, err
	}
	if out.Product != "harmonia" {
		return nil, fmt.Errorf("这个地址不是 Harmonia 服务")
	}
	if out.Protocol != 1 {
		return nil, fmt.Errorf("服务器版本（%s）与本机 CLI 不兼容，请升级 CLI 或服务器", out.Version)
	}
	return &out, nil
}

func (c *Client) Prelogin(ctx context.Context, email string) (*Prelogin, error) {
	var out Prelogin
	return &out, c.Public(ctx, "GET", "/api/v1/auth/prelogin?email="+url.QueryEscape(email), nil, &out)
}

// Login 用密码登录；服务端要求邮件验证码时返回 code_required 错误（带 Flow），再带上 flow 和 code 调用一次。
func (c *Client) Login(ctx context.Context, email, authKey, flow, code string) (*Session, error) {
	body := map[string]string{"email": email, "authKey": authKey}
	if flow != "" {
		body["flow"], body["code"] = flow, code
	}
	var out Session
	return &out, c.Public(ctx, "POST", "/api/v1/auth/login", body, &out)
}

func (c *Client) Account(ctx context.Context, token string) (*Account, error) {
	var out Account
	return &out, c.WithToken(ctx, token, "GET", "/api/v1/account", nil, &out)
}

func (c *Client) CreatePairing(ctx context.Context, token string, body map[string]any) (*PairingRequest, error) {
	var out PairingRequest
	return &out, c.WithToken(ctx, token, "POST", "/api/v1/pairings", body, &out)
}

func (c *Client) PairingStatus(ctx context.Context, id, secret string) (string, error) {
	var out struct{ Status string }
	err := c.do(ctx, "GET", "/api/v1/pairings/"+id+"/status", nil, &out, reqOpts{headers: map[string]string{"x-pairing-secret": secret}})
	return out.Status, err
}

// SetActivation 按顺序提交本机全部授权环境的激活状态。
func (c *Client) SetActivation(ctx context.Context, envs []ActivationItem) error {
	return c.Device(ctx, "PUT", "/api/v1/devices/self/activation", map[string]any{"envs": envs}, nil, nil)
}

func (c *Client) Sync(ctx context.Context, since int64) (*Sync, error) {
	var out Sync
	return &out, c.Device(ctx, "GET", fmt.Sprintf("/api/v1/sync?since=%d", since), nil, &out, nil)
}

func (c *Client) PutVariable(ctx context.Context, envID, name, value, keyVersion, idemKey string) error {
	body := map[string]string{"value": value, "keyVersion": keyVersion}
	return c.Device(ctx, "PUT", "/api/v1/environments/"+envID+"/variables/"+name, body, nil, map[string]string{"idempotency-key": idemKey})
}

func (c *Client) DeleteVariable(ctx context.Context, envID, name, idemKey string) error {
	return c.Device(ctx, "DELETE", "/api/v1/environments/"+envID+"/variables/"+name, nil, nil, map[string]string{"idempotency-key": idemKey})
}

func (c *Client) RevokeSelf(ctx context.Context) error {
	return c.Device(ctx, "POST", "/api/v1/devices/self/revoke", map[string]any{}, nil, nil)
}
