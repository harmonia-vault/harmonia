// Package approval 向管理设备发起批准请求并等待结果（docs/protocol.md 3.9，设计文档 17.4）：
// 读取请求取回加密给临时公钥、由 root 签名的变量；写入请求把新的值分别加密给每一台管理设备。
package approval

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// Server 是发起和等待批准请求要用到的服务端接口。
type Server interface {
	CreateApproval(ctx context.Context, id, detail, payload, sig string) (int64, error)
	WaitApproval(ctx context.Context, id string, onReady func()) (api.Event, error)
	ApprovalStatus(ctx context.Context, id string) (api.Event, error)
}

// Requester 以这台设备的身份发起请求。Command 和 Cwd 只用于在手机上显示。
type Requester struct {
	Server  Server
	Keys    *state.DeviceKeys
	RootPub []byte
	Command []string
	Cwd     string
	Out     io.Writer
	Now     func() time.Time
}

var (
	ErrRejected = errors.New("手机上拒绝了这次请求")
	ErrExpired  = errors.New("2 分钟内没有在手机上批准，请重新运行。需要无人值守运行时，可以在手机上这台电脑这个环境的授权里展开“高级”，开启“无人值守使用”")
	ErrLost     = errors.New("等待批准时与服务器的连接断开了，请检查网络后重新运行")
	ErrCanceled = errors.New("已取消等待手机批准")
	errBadGrant = errors.New("手机返回的批准结果无法验证，已丢弃。请确认服务器地址是否正确，然后重新运行")
)

// Plain 是协议 2.6 的变量明文。
type Plain struct {
	Value string `json:"value"`
	Note  string `json:"note,omitempty"`
}

// Value 是批准结果里的一个变量。
type Value struct {
	EnvironmentID string `json:"environmentId"`
	Name          string `json:"name"`
	VaultID       string `json:"vaultId"`
	Source        string `json:"source"`
	Plain         Plain  `json:"plain"`
}

// Grant 是验证过签名、解开后的批准结果。
type Grant struct {
	RequestID string  `json:"requestId"`
	Scope     string  `json:"scope"`
	ExpiresAt int64   `json:"expiresAt"`
	Values    []Value `json:"values"`
}

// 授权范围。
const (
	ScopeOnce     = "once"
	ScopeTerminal = "terminal"
	ScopeAll      = "all"
)

// maxShown 是命令和目录在请求里的最大长度（字符）。
const maxShown = 1000

func truncate(s string) string {
	if utf8.RuneCountInString(s) <= maxShown {
		return s
	}
	return string([]rune(s)[:maxShown-1]) + "…"
}

func (r *Requester) detail(kind string, ephPub string, items, del []api.ApprovalItem) (string, error) {
	d := api.ApprovalDetail{
		Kind:      kind,
		DeviceID:  r.Keys.ID,
		CreatedAt: r.Now().UnixMilli(),
		EphPub:    ephPub,
		Command:   truncate(strings.Join(r.Command, " ")),
		Cwd:       truncate(r.Cwd),
		Items:     items,
		Delete:    del,
	}
	b, err := json.Marshal(d)
	return string(b), err
}

// submit 签名并提交请求，输出请求码，等待到有结果为止。
func (r *Requester) submit(ctx context.Context, id, what, detail, payload string) (*api.ApprovalResult, error) {
	sig := r.Keys.Sign.Sign(hc.ApprovalRequestMsg(id, r.Keys.ID, detail, payload))
	if _, err := r.Server.CreateApproval(ctx, id, detail, payload, hc.B64(sig)); err != nil {
		return nil, err
	}
	ev, err := r.Server.WaitApproval(ctx, id, func() {
		fmt.Fprintf(r.Out, "harmonia：已请求手机批准%s，请在手机上核对请求码 %s 后批准。最多等待 2 分钟，Ctrl+C 取消。\n", what, hc.ApprovalCode(detail))
	})
	if err != nil {
		if ctx.Err() != nil {
			return nil, ErrCanceled
		}
		// 连接意外断开：结果可能已经出来了，再查一次。
		if ev, err = r.Server.ApprovalStatus(ctx, id); err != nil {
			return nil, ErrLost
		}
	}
	switch ev.Type {
	case "approved":
		if ev.Result == nil {
			return &api.ApprovalResult{}, nil
		}
		return ev.Result, nil
	case "rejected":
		return nil, ErrRejected
	case "expired":
		return nil, ErrExpired
	}
	return nil, ErrLost
}

// Read 请求读取 items 中的变量，返回验证过的结果：root 签名正确、请求 ID 一致、变量和请求的一一对应。
func (r *Requester) Read(ctx context.Context, items []api.ApprovalItem) (*Grant, error) {
	eph := hc.BoxKeyFromSeed(hc.Random(32))
	detail, err := r.detail("read", hc.B64(eph.Pub[:]), items, nil)
	if err != nil {
		return nil, err
	}
	id := hc.NewID()
	res, err := r.submit(ctx, id, "", detail, "")
	if err != nil {
		return nil, err
	}
	return openGrant(r.RootPub, eph, id, items, res)
}

func openGrant(rootPub []byte, eph hc.BoxKey, id string, items []api.ApprovalItem, res *api.ApprovalResult) (*Grant, error) {
	sealed, err1 := hc.UnB64(res.Sealed)
	sig, err2 := hc.UnB64(res.Sig)
	if err1 != nil || err2 != nil {
		return nil, errBadGrant
	}
	plain, err := eph.Open(sealed)
	if err != nil {
		return nil, errBadGrant
	}
	var g Grant
	if json.Unmarshal(plain, &g) != nil {
		return nil, errBadGrant
	}
	if g.RequestID != id || !hc.Verify(rootPub, hc.ApprovalGrantMsg(id, sealed), sig) {
		return nil, errBadGrant
	}
	if g.Scope != ScopeOnce && g.Scope != ScopeTerminal && g.Scope != ScopeAll {
		return nil, errBadGrant
	}
	want := map[[2]string]bool{}
	for _, it := range items {
		want[[2]string{it.EnvironmentID, it.Name}] = true
	}
	for _, v := range g.Values {
		key := [2]string{v.EnvironmentID, v.Name}
		if !want[key] {
			return nil, errBadGrant
		}
		delete(want, key)
	}
	if len(want) > 0 {
		return nil, errBadGrant
	}
	return &g, nil
}

// SetItem 是写入请求里要写的一个变量：Plain 中省略的备注沿用原值。
type SetItem struct {
	api.ApprovalItem
	Plain map[string]string `json:"plain"`
}

// Write 请求写入 set、删除 del：写入内容为每一台管理设备各加密一份。批准后由手机写入，这里只等结果。
func (r *Requester) Write(ctx context.Context, managers []api.ManagerKey, set []SetItem, del []api.ApprovalItem) error {
	if len(managers) == 0 {
		return errors.New("这台设备还没有同步到管理设备，无法发起写入请求。请运行 harmonia sync 后重试")
	}
	items := make([]api.ApprovalItem, len(set))
	for i, s := range set {
		items[i] = s.ApprovalItem
	}
	detail, err := r.detail("write", "", items, del)
	if err != nil {
		return err
	}
	id := hc.NewID()
	content, err := json.Marshal(struct {
		RequestID string    `json:"requestId"`
		Set       []SetItem `json:"set"`
	}{id, set})
	if err != nil {
		return err
	}
	type sealedCopy struct {
		ManagerID string `json:"managerId"`
		Sealed    string `json:"sealed"`
	}
	copies := make([]sealedCopy, 0, len(managers))
	for _, m := range managers {
		pub, err := hc.UnB64(m.BoxPub)
		if err != nil {
			return err
		}
		sealed, err := hc.Seal(content, pub)
		if err != nil {
			return err
		}
		copies = append(copies, sealedCopy{m.ID, hc.B64(sealed)})
	}
	payload, err := json.Marshal(map[string]any{"sealed": copies})
	if err != nil {
		return err
	}
	_, err = r.submit(ctx, id, "写入", detail, string(payload))
	return err
}
