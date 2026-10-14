package app

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// PairingPrompt 负责向用户展示配对信息。
type PairingPrompt interface {
	// ShowPairing 显示二维码和核对码；authorized 表示请求由配对码创建，管理设备会直接弹出批准页。
	ShowPairing(qr, code, deviceName string, expiresAt time.Time, authorized bool)
	Waiting()
}

type LoginInput struct {
	Server string
	Email  string
	// PairingCode 是管理设备上生成的配对码；为空时是扫码方式（docs/protocol.md 3.2）。
	PairingCode string
	DeviceName  string
}

// Login 查询账号后发起配对，等待管理设备核对并批准。账号没有密码。
func Login(ctx context.Context, in LoginInput, prompt PairingPrompt) (*App, int, error) {
	server, err := api.NormalizeServer(in.Server)
	if err != nil {
		return nil, 0, err
	}
	email := strings.ToLower(strings.TrimSpace(in.Email))
	if email == "" {
		return nil, 0, errors.New("请输入注册 Harmonia 时使用的邮箱")
	}
	d, err := state.Open()
	if err != nil {
		return nil, 0, err
	}
	cfg, err := d.Config()
	if err != nil {
		return nil, 0, err
	}
	if cfg.Paired() {
		return nil, 0, fmt.Errorf("本机已接入账号 %s。如需切换账号，请先运行 harmonia logout", cfg.Email)
	}
	c := api.New(server)
	if _, err := c.Instance(ctx); err != nil {
		return nil, 0, err
	}
	acct, err := c.Lookup(ctx, email)
	if api.IsCode(err, "not_found") {
		return nil, 0, errors.New("这个邮箱还没有注册。请先在 Harmonia App 中用它注册并完成设置，或检查邮箱是否输错")
	}
	if err != nil {
		return nil, 0, err
	}
	if !acct.Initialized {
		return nil, 0, errors.New("这个账号还没有在手机上完成设置。请先在 Harmonia App 中输入这个邮箱，完成设置后再运行 harmonia login")
	}
	if m, err := d.Manager(); err != nil {
		return nil, 0, err
	} else if m != nil && (m.Server != server || m.AccountID != acct.AccountID || m.RootPub != acct.RootPub) {
		return nil, 0, fmt.Errorf("这台电脑已经管理登录了账号 %s（%s）。日常登录和管理登录必须是同一个账号；如需更换，请先运行 harmonia manager logout", m.Email, m.Server)
	}
	if cfg.AccountID == acct.AccountID && cfg.RootPub != "" && cfg.RootPub != acct.RootPub {
		return nil, 0, errors.New("服务器返回的账号公钥与本机之前记录的不一致，已停止。请确认服务器地址是否正确")
	}
	c.AccountID = acct.AccountID

	keys := state.NewDeviceKeys()
	signPub, boxPub := hc.B64(keys.Sign.Pub), hc.B64(keys.Box.Pub[:])
	name := in.DeviceName
	if name == "" {
		name = DefaultDeviceName()
	}
	body := map[string]any{
		"name": name, "platform": runtime.GOOS, "signPub": signPub, "boxPub": boxPub, "rootPub": acct.RootPub,
		"canManage": false, // 日常登录不具备管理功能；管理登录见 internal/manager
	}
	if code := strings.TrimSpace(in.PairingCode); code != "" {
		body["code"] = code
	}
	req, err := c.CreatePairing(ctx, body)
	if err != nil {
		return nil, 0, err
	}
	fp := hc.PairingFingerprint(req.ID, signPub, boxPub, acct.RootPub)
	status, err := c.WaitPairing(ctx, req.ID, req.Secret, func() {
		prompt.ShowPairing(hc.PairingQR(req.ID, fp), hc.PairingCode(fp), name, time.UnixMilli(req.ExpiresAt), req.Authorized)
		prompt.Waiting()
	})
	if ctx.Err() != nil {
		return nil, 0, errors.New("已取消配对")
	}
	if err != nil {
		// 等待连接意外断开：可能刚好已被批准，查一次最终状态。
		status, _ = c.PairingStatus(ctx, req.ID, req.Secret)
	}
	switch status {
	case "approved":
	case "rejected":
		return nil, 0, errors.New("这次配对被拒绝或已作废。如需重试，请重新运行 harmonia login")
	case "expired":
		return nil, 0, errors.New("配对请求已过期（5 分钟），请重新运行 harmonia login")
	default:
		return nil, 0, errors.New("与服务器的连接中断，这次配对已作废。请检查网络后重新运行 harmonia login")
	}

	keys.ID = req.ID
	if err := d.SaveKeys(keys.Saved()); err != nil {
		return nil, 0, err
	}
	cfg = &state.Config{
		Server: server, AccountID: acct.AccountID, Email: email, RootPub: acct.RootPub,
		DeviceID: req.ID, DeviceName: name,
	}
	if err := d.SaveConfig(cfg); err != nil {
		return nil, 0, err
	}
	if err := d.SaveCache(&state.Cache{Variables: map[string]map[string]state.CachedVar{}}); err != nil {
		return nil, 0, err
	}
	c.Signer = keys
	a := &App{Dir: d, Config: cfg, Keys: keys, Client: c}
	if err := a.Sync(ctx); err != nil {
		return a, 0, fmt.Errorf("已接入账号，但首次同步失败：%w", err)
	}
	cache, _ := d.Cache()
	return a, len(cache.Environments), nil
}

// Logout 通知服务器移除本机，然后清除本机数据。离线时只清除本机数据。
func (a *App) Logout(ctx context.Context) (online bool, err error) {
	if a.Client != nil && a.Keys != nil {
		ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		rerr := a.Client.RevokeSelf(ctx)
		online = rerr == nil || errors.Is(rerr, api.ErrRevoked)
	}
	unlock, err := a.Dir.Lock()
	if err != nil {
		return online, err
	}
	defer unlock()
	return online, a.wipe()
}
