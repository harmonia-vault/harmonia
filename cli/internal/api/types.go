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

// Environment 是这台设备被授权的一个环境，Items 是服务端按引用展开的最终名字（docs/protocol.md 3.4）。
type Environment struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Role      string `json:"role"`
	ExpiresAt int64  `json:"expiresAt"`
	// LocalDecrypt 表示这个环境允许在本机解密：设备持有它引用的变量库的钥匙。
	LocalDecrypt bool `json:"localDecrypt"`
	// Active 与 Position 是授权上的激活状态和顺序（越小越靠前，同名变量由靠前的环境提供）。
	Active   bool      `json:"active"`
	Position int       `json:"position"`
	Items    []EnvItem `json:"items"`
	Shadowed []EnvItem `json:"shadowed"`
	// CreateVaults 是可以通过这个环境新增变量的变量库（全部变量、可以修改的引用）。
	CreateVaults []string `json:"createVaults"`
}

// EnvItem 是环境里的一个变量：Name 是环境里的名字，Source 是变量库里的原名。
type EnvItem struct {
	Name     string `json:"name"`
	VaultID  string `json:"vaultId"`
	Source   string `json:"source"`
	Writable bool   `json:"writable"`
}

// VaultName 是这台设备的环境引用到的变量库的名字。
type VaultName struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// Vault 是这台设备可以在本机解密的变量库。
type Vault struct {
	ID         string `json:"id"`
	KeyVersion string `json:"keyVersion"`
}

// ActivationItem 是提交激活状态时的一项，整个列表按顺序排列。
type ActivationItem struct {
	EnvID  string `json:"environmentId"`
	Active bool   `json:"active"`
}

type Envelope struct {
	VaultID    string `json:"vaultId"`
	KeyVersion string `json:"keyVersion"`
	Sealed     string `json:"sealed"`
	Sig        string `json:"sig"`
}

type Variable struct {
	VaultID    string `json:"vaultId"`
	Name       string `json:"name"`
	Value      string `json:"value"`
	KeyVersion string `json:"keyVersion"`
	Deleted    bool   `json:"deleted"`
	Seq        int64  `json:"seq"`
}

type Sync struct {
	Seq int64 `json:"seq"`
	// Full 表示 Variables 是范围内的完整列表，客户端用它整体替换缓存。
	Full bool `json:"full"`
	Self struct {
		ID               string `json:"id"`
		Kind             string `json:"kind"`
		Name             string `json:"name"`
		RotationRequired bool   `json:"rotationRequired"`
		// SystemVars 是这台设备的“写入系统变量”开关，只有 Windows 上使用。
		SystemVars bool `json:"systemVars"`
		// AutoUpdate 是这台设备的“自动更新”开关，由后台服务执行。
		AutoUpdate bool `json:"autoUpdate"`
	} `json:"self"`
	Environments []Environment `json:"environments"`
	VaultNames   []VaultName   `json:"vaultNames"`
	Vaults       []Vault       `json:"vaults"`
	Envelopes    []Envelope    `json:"envelopes"`
	Variables    []Variable    `json:"variables"`
	// Manager 只返回给管理设备。
	Manager *ManagerInfo `json:"manager"`
}

// ManagerInfo 是同步结果中只有管理设备能拿到的部分（docs/protocol.md 3.4）。
type ManagerInfo struct {
	RootSealed string `json:"rootSealed"`
	Recovery   struct {
		BoxPub string `json:"boxPub"`
	} `json:"recovery"`
	Vaults       []ManagerVault `json:"vaults"`
	Environments []ManagerEnv   `json:"environments"`
	Devices      []Device       `json:"devices"`
}

// ManagerVault 是账号里的一个变量库。
type ManagerVault struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	KeyVersion string `json:"keyVersion"`
}

// ManagerEnv 是账号里的一个环境和它的引用。
type ManagerEnv struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Refs []Ref  `json:"refs"`
}

// Ref 是环境对一个变量库的引用（docs/protocol.md 3.2）。Missing 只出现在同步结果里，表示变量库已被删除。
type Ref struct {
	VaultID  string    `json:"vaultId"`
	Scope    string    `json:"scope"`
	Writable bool      `json:"writable"`
	Items    []RefItem `json:"items"`
	Missing  bool      `json:"missing,omitempty"`
}

// RefItem 是引用里的一个变量：Name 是变量库里的原名，As 是在环境里的新名字（空表示不改名）。
type RefItem struct {
	Name string `json:"name"`
	As   string `json:"as,omitempty"`
}

type Device struct {
	ID      string        `json:"id"`
	Name    string        `json:"name"`
	Kind    string        `json:"kind"`
	SignPub string        `json:"signPub"`
	BoxPub  string        `json:"boxPub"`
	Cert    string        `json:"cert"`
	Grants  []DeviceGrant `json:"grants"`
}

// DeviceGrant 是一台设备对一个环境的授权；ExpiresAt 为 0 表示一直有效。
type DeviceGrant struct {
	EnvironmentID string `json:"environmentId"`
	Role          string `json:"role"`
	ExpiresAt     int64  `json:"expiresAt"`
	LocalDecrypt  bool   `json:"localDecrypt"`
}

// NewEnvelope 是提交的一份库钥封装；Recipient 是设备 ID 或 recovery。
type NewEnvelope struct {
	Recipient  string `json:"recipient"`
	KeyVersion string `json:"keyVersion"`
	Sealed     string `json:"sealed"`
	Sig        string `json:"sig"`
}

// Protocol 是这个 CLI 使用的协议版本（docs/protocol.md），发布清单的 protocol 也由它生成。
const Protocol = 1

// InstanceInfo 读取服务器的实例信息，不检查兼容性（升级前预检用）。
func (c *Client) InstanceInfo(ctx context.Context) (*Instance, error) {
	var out Instance
	if err := c.Public(ctx, "GET", "/api/v1/instance", nil, &out); err != nil {
		return nil, err
	}
	if out.Product != "harmonia" {
		return nil, fmt.Errorf("这个地址不是 Harmonia 服务")
	}
	return &out, nil
}

// Instance 读取实例信息，并确认服务器的协议版本和本机 CLI 一致。
func (c *Client) Instance(ctx context.Context) (*Instance, error) {
	out, err := c.InstanceInfo(ctx)
	if err != nil {
		return nil, err
	}
	if out.Protocol != Protocol {
		return nil, fmt.Errorf("服务器版本（%s）与本机 CLI 不兼容，请升级 CLI 或服务器", out.Version)
	}
	return out, nil
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

// SetActivation 按顺序提交本机全部授权环境的激活状态。整体替换，重试是安全的。
func (c *Client) SetActivation(ctx context.Context, envs []ActivationItem) error {
	return c.DeviceWrite(ctx, "PUT", "/api/v1/devices/self/activation", map[string]any{"envs": envs}, nil, nil)
}

func (c *Client) Sync(ctx context.Context, since int64) (*Sync, error) {
	var out Sync
	return &out, c.Device(ctx, "GET", fmt.Sprintf("/api/v1/sync?since=%d", since), nil, &out, nil)
}

// VarWrite 是批量写入的一项：名称和密文。
type VarWrite struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// PatchVariables 批量写入和删除一个变量库里的变量（docs/protocol.md 3.2）：整批生效或整批拒绝。
func (c *Client) PatchVariables(ctx context.Context, vaultID, keyVersion string, set []VarWrite, del []string, idemKey string) error {
	if set == nil {
		set = []VarWrite{}
	}
	if del == nil {
		del = []string{}
	}
	body := map[string]any{"keyVersion": keyVersion, "set": set, "delete": del}
	return c.DeviceWrite(ctx, "PATCH", "/api/v1/vaults/"+vaultID+"/variables", body, nil, map[string]string{"idempotency-key": idemKey})
}

func (c *Client) DeleteVariable(ctx context.Context, vaultID, name, idemKey string) error {
	return c.DeviceWrite(ctx, "DELETE", "/api/v1/vaults/"+vaultID+"/variables/"+name, nil, nil, map[string]string{"idempotency-key": idemKey})
}

func (c *Client) RevokeSelf(ctx context.Context) error {
	return c.Device(ctx, "POST", "/api/v1/devices/self/revoke", map[string]any{}, nil, nil)
}

// RevokeSelfManager 让管理设备本机退出；confirmLast 用于确认它是账号里最后一台管理设备。
func (c *Client) RevokeSelfManager(ctx context.Context, confirmLast bool) error {
	return c.Device(ctx, "POST", "/api/v1/devices/self/revoke", map[string]any{"confirmLast": confirmLast}, nil, nil)
}

// CreateVault 新建变量库，envelopes 覆盖全部管理设备和恢复码。
func (c *Client) CreateVault(ctx context.Context, id, name string, envelopes []NewEnvelope) error {
	body := map[string]any{"id": id, "name": name, "envelopes": envelopes}
	return c.Device(ctx, "POST", "/api/v1/vaults", body, nil, nil)
}

func (c *Client) RenameVault(ctx context.Context, id, name string) error {
	return c.Device(ctx, "PATCH", "/api/v1/vaults/"+id, map[string]string{"name": name}, nil, nil)
}

func (c *Client) DeleteVault(ctx context.Context, id string) error {
	return c.Device(ctx, "DELETE", "/api/v1/vaults/"+id, nil, nil, nil)
}

func (c *Client) CreateEnvironment(ctx context.Context, id, name string, refs []Ref) error {
	body := map[string]any{"id": id, "name": name, "refs": refs}
	return c.Device(ctx, "POST", "/api/v1/environments", body, nil, nil)
}

// PutEnvironment 整体替换环境的名字和引用；envelopes 是新引用的变量库给开启本机解密的设备的封装。
func (c *Client) PutEnvironment(ctx context.Context, id, name string, refs []Ref, envelopes []NewEnvelope) error {
	if envelopes == nil {
		envelopes = []NewEnvelope{}
	}
	body := map[string]any{"name": name, "refs": refs, "envelopes": envelopes}
	return c.Device(ctx, "PUT", "/api/v1/environments/"+id, body, nil, nil)
}

func (c *Client) DeleteEnvironment(ctx context.Context, id string) error {
	return c.Device(ctx, "DELETE", "/api/v1/environments/"+id, nil, nil, nil)
}
