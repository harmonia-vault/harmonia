package api

import (
	"context"
	"net/http"
	"strings"

	"github.com/coder/websocket"
)

// ManagerKey 是同步结果里的一台管理设备，写入请求为每一台各加密一份（docs/protocol.md 3.4、3.9）。
type ManagerKey struct {
	ID      string `json:"id"`
	SignPub string `json:"signPub"`
	BoxPub  string `json:"boxPub"`
	Cert    string `json:"cert"`
}

// ApprovalItem 是批准请求里的一个变量：环境 ID 和环境里的名字；新增变量时带变量库。
type ApprovalItem struct {
	EnvironmentID string `json:"environmentId"`
	Name          string `json:"name"`
	VaultID       string `json:"vaultId,omitempty"`
}

// ApprovalDetail 是批准请求的内容，签名和请求码都按它序列化后的原文计算。
type ApprovalDetail struct {
	Kind      string         `json:"kind"`
	DeviceID  string         `json:"deviceId"`
	CreatedAt int64          `json:"createdAt"`
	EphPub    string         `json:"ephPub,omitempty"`
	Command   string         `json:"command"`
	Cwd       string         `json:"cwd"`
	Items     []ApprovalItem `json:"items"`
	Delete    []ApprovalItem `json:"delete,omitempty"`
}

// ApprovalResult 是批准读取请求的结果：加密给临时公钥的内容和 root 签名。
type ApprovalResult struct {
	Sealed string `json:"sealed"`
	Sig    string `json:"sig"`
}

// Authorization 是一项正在生效的授权（服务端的记录，只用于显示和结束）。
type Authorization struct {
	ID        string         `json:"id"`
	DeviceID  string         `json:"deviceId"`
	Items     []ApprovalItem `json:"items"`
	Scope     string         `json:"scope"`
	ExpiresAt int64          `json:"expiresAt"`
}

// CreateApproval 提交批准请求，返回请求的到期时间。
func (c *Client) CreateApproval(ctx context.Context, id, detail, payload, sig string) (int64, error) {
	body := map[string]string{"id": id, "detail": detail, "sig": sig}
	if payload != "" {
		body["payload"] = payload
	}
	var out struct{ ExpiresAt int64 }
	err := c.Device(ctx, "POST", "/api/v1/approvals", body, &out, nil)
	return out.ExpiresAt, err
}

// WaitApproval 保持等待连接直到请求有结果（docs/protocol.md 3.9）：连上后调用 onReady。
// 连接意外断开时返回错误，由调用方用 ApprovalStatus 再查一次。
func (c *Client) WaitApproval(ctx context.Context, id string, onReady func()) (Event, error) {
	token, err := c.DeviceToken(ctx)
	if err != nil {
		return Event{}, err
	}
	wsURL := "ws" + strings.TrimPrefix(c.Base, "http") + "/api/v1/approvals/" + id + "/events"
	h := http.Header{}
	h.Set("authorization", "Bearer "+token)
	conn, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPHeader: h, HTTPClient: c.HTTP})
	if err != nil {
		return Event{}, err
	}
	defer conn.CloseNow()
	conn.SetReadLimit(4 << 20)
	onReady()
	return waitResult(ctx, conn)
}

// ApprovalStatus 查询请求的状态：pending、approved、rejected、expired 或 cancelled。
func (c *Client) ApprovalStatus(ctx context.Context, id string) (Event, error) {
	var out struct {
		Status string
		Result *ApprovalResult
	}
	err := c.Device(ctx, "GET", "/api/v1/approvals/"+id+"/status", nil, &out, nil)
	return Event{Type: out.Status, Result: out.Result}, err
}

// Authorizations 列出这台设备正在生效的授权。
func (c *Client) Authorizations(ctx context.Context) ([]Authorization, error) {
	var out struct{ Authorizations []Authorization }
	err := c.Device(ctx, "GET", "/api/v1/authorizations", nil, &out, nil)
	return out.Authorizations, err
}

// EndAuthorization 结束一项授权。
func (c *Client) EndAuthorization(ctx context.Context, id string) error {
	return c.Device(ctx, "POST", "/api/v1/authorizations/"+id+"/end", map[string]string{}, nil, nil)
}
