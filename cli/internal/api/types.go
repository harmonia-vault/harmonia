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

// Account 是匿名查询账号的结果（docs/protocol.md 3.2）。
type Account struct {
	AccountID   string `json:"accountId"`
	Initialized bool   `json:"initialized"`
	RootPub     string `json:"rootPub"`
}

type PairingRequest struct {
	ID        string `json:"id"`
	Secret    string `json:"secret"`
	ExpiresAt int64  `json:"expiresAt"`
	// Authorized 表示请求由配对码创建，会推送到管理设备上。
	Authorized bool `json:"authorized"`
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
		// SystemVars 是这台设备的“写入系统变量”开关，只有 Windows 上使用。
		SystemVars bool `json:"systemVars"`
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

// Lookup 按邮箱匿名查询账号；邮箱没有注册时返回 not_found 错误。
func (c *Client) Lookup(ctx context.Context, email string) (*Account, error) {
	var out Account
	return &out, c.Public(ctx, "GET", "/api/v1/accounts/lookup?email="+url.QueryEscape(email), nil, &out)
}

// CreatePairing 发起配对请求，不需要会话：账号由 AccountID 请求头指定。
func (c *Client) CreatePairing(ctx context.Context, body map[string]any) (*PairingRequest, error) {
	var out PairingRequest
	return &out, c.Public(ctx, "POST", "/api/v1/pairings", body, &out)
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
