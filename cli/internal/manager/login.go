package manager

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/app"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/passphrase"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// LoginInput 是管理登录填写的内容。这台电脑已有日常登录时，Server 和 Email 沿用它的，不用填写。
type LoginInput struct {
	Server      string
	Email       string
	DeviceName  string
	PairingCode string
	Passphrase  string
}

// Account 说明管理登录会使用哪个账号：这台电脑已有日常登录时，两者必须是同一个账号。
type Account struct {
	Server     string `json:"server"`
	Email      string `json:"email"`
	DeviceName string `json:"deviceName"`
	// Fixed 表示服务器和邮箱沿用日常登录的，不能修改。
	Fixed bool `json:"fixed"`
}

const nameSuffix = "（管理）"

// Suggest 给出管理登录页面的默认值。
func Suggest(d *state.Dir) (*Account, error) {
	cfg, err := d.Config()
	if err != nil {
		return nil, err
	}
	base := cfg.DeviceName
	if base == "" {
		base = app.DefaultDeviceName()
	}
	if r := []rune(base); len(r) > 64-len([]rune(nameSuffix)) {
		base = string(r[:64-len([]rune(nameSuffix))])
	}
	return &Account{Server: cfg.Server, Email: cfg.Email, DeviceName: base + nameSuffix, Fixed: cfg.Paired()}, nil
}

// Pending 是已经发起、正在等待手机批准的管理登录。设备密钥在批准前只在内存里。
type Pending struct {
	QR         string
	Code       string
	DeviceName string
	ExpiresAt  int64
	// Authorized 表示请求由配对码创建，管理设备会直接弹出批准页。
	Authorized bool

	client *api.Client
	req    *api.PairingRequest
	keys   *state.DeviceKeys
	file   *state.ManagerFile
	pass   string
}

// Begin 检查口令和账号，然后以“具备管理功能”发起配对请求。
func Begin(ctx context.Context, d *state.Dir, in LoginInput) (*Pending, error) {
	if m, err := d.Manager(); err != nil {
		return nil, err
	} else if m != nil {
		return nil, fmt.Errorf("这台电脑已经管理登录了账号 %s", m.Email)
	}
	if err := passphrase.Validate(in.Passphrase); err != nil {
		return nil, err
	}
	cfg, err := d.Config()
	if err != nil {
		return nil, err
	}
	server, email := in.Server, strings.ToLower(strings.TrimSpace(in.Email))
	if cfg.Paired() {
		server, email = cfg.Server, cfg.Email
	}
	if server, err = api.NormalizeServer(server); err != nil {
		return nil, err
	}
	if email == "" {
		return nil, errors.New("请输入注册 Harmonia 时使用的邮箱")
	}
	name := strings.TrimSpace(in.DeviceName)
	if n := len([]rune(name)); n < 1 || n > 64 {
		return nil, errors.New("设备名需要 1 到 64 个字符")
	}
	c := api.New(server)
	if _, err := c.Instance(ctx); err != nil {
		return nil, err
	}
	acct, err := c.Lookup(ctx, email)
	if api.IsCode(err, "not_found") {
		return nil, errors.New("这个邮箱还没有注册。请先在 Harmonia App 中用它注册并完成设置，或检查邮箱是否输错")
	}
	if err != nil {
		return nil, err
	}
	if !acct.Initialized {
		return nil, errors.New("这个账号还没有在手机上完成设置。请先在 Harmonia App 中完成设置")
	}
	if cfg.Paired() && (cfg.AccountID != acct.AccountID || cfg.RootPub != acct.RootPub) {
		return nil, errors.New("服务器返回的账号与这台电脑日常登录时记录的不一致，已停止。请确认服务器地址是否正确")
	}
	c.AccountID = acct.AccountID

	keys := state.NewDeviceKeys()
	signPub, boxPub := hc.B64(keys.Sign.Pub), hc.B64(keys.Box.Pub[:])
	body := map[string]any{
		"name": name, "platform": runtime.GOOS, "signPub": signPub, "boxPub": boxPub, "rootPub": acct.RootPub,
		"canManage": true,
	}
	if code := strings.TrimSpace(in.PairingCode); code != "" {
		body["code"] = code
	}
	req, err := c.CreatePairing(ctx, body)
	if api.IsCode(err, "unauthorized") {
		return nil, errors.New("配对码不对或已过期。可以在手机上重新生成，或留空改用扫码")
	}
	if err != nil {
		return nil, err
	}
	fp := hc.PairingFingerprint(req.ID, signPub, boxPub, acct.RootPub)
	return &Pending{
		QR: hc.PairingQR(req.ID, fp), Code: hc.PairingCode(fp), DeviceName: name,
		ExpiresAt: req.ExpiresAt, Authorized: req.Authorized,
		client: c, req: req, keys: keys, pass: in.Passphrase,
		file: &state.ManagerFile{
			Server: server, AccountID: acct.AccountID, Email: email, RootPub: acct.RootPub,
			DeviceID: req.ID, DeviceName: name,
		},
	}, nil
}

// Wait 保持等待连接直到手机批准、拒绝或请求过期；ctx 结束即离开，请求随之作废。
// 批准后用口令加密保存设备密钥，并确认自己确实被批准成了管理设备。
func (p *Pending) Wait(ctx context.Context, d *state.Dir) (*Session, error) {
	status, err := p.client.WaitPairing(ctx, p.req.ID, p.req.Secret, func() {})
	if ctx.Err() != nil {
		return nil, errors.New("已取消这次管理登录")
	}
	if err != nil {
		// 等待连接意外断开：可能刚好已被批准，查一次最终状态。
		status, _ = p.client.PairingStatus(ctx, p.req.ID, p.req.Secret)
	}
	switch status {
	case "approved":
	case "rejected":
		return nil, errors.New("这次请求在手机上被拒绝了。如需重试，请重新发起")
	case "expired":
		return nil, errors.New("请求已过期（5 分钟），请重新发起")
	default:
		return nil, errors.New("与服务器的连接中断，这次请求已作废。请检查网络后重新发起")
	}
	p.keys.ID = p.req.ID
	if err := protect(p.file, p.pass, p.keys); err != nil {
		return nil, err
	}
	p.pass = ""
	if err := d.SaveManager(p.file); err != nil {
		return nil, err
	}
	s := Open(p.file, p.keys)
	sctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	err = s.Sync(sctx)
	if errors.Is(err, ErrNotManager) {
		_ = s.client.RevokeSelf(sctx)
		_ = d.RemoveManager()
		return nil, errors.New("手机把这台电脑批准成了普通设备。请重新发起，并在手机的批准页保持“作为管理设备”开启")
	}
	if errors.Is(err, api.ErrRevoked) {
		_ = d.RemoveManager()
		return nil, errors.New("这台电脑的管理身份刚刚被移除了，请重新发起")
	}
	if err != nil {
		return nil, fmt.Errorf("已完成管理登录，但首次同步失败：%w。请稍后输入口令重试", err)
	}
	return s, nil
}
