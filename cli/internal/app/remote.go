package app

import (
	"context"
	"fmt"
	"os"
	"slices"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/approval"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/keeper"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

// requester 以这台设备的身份发起批准请求；command 是要运行的命令，和当前目录一起显示在手机上。
func (a *App) requester(command []string) (*approval.Requester, error) {
	root, err := hc.UnB64(a.Config.RootPub)
	if err != nil {
		return nil, fmt.Errorf("本机记录的账号公钥已损坏")
	}
	cwd, _ := os.Getwd()
	return &approval.Requester{
		Server:  a.Client,
		Keys:    a.Keys,
		RootPub: root,
		Command: command,
		Cwd:     cwd,
		Out:     os.Stderr,
		Now:     time.Now,
	}, nil
}

// Resolve 计算要交给命令的变量：items 为空时用激活的环境（拿不到的跳过并在 skipped 中说明），
// 否则按 --env 的各项依次合并（见 vault.Select）。没有开启本机解密的环境，先向保管进程要这次用到的变量，
// 缺的合成一个请求发给手机批准（设计文档 17.4）。
func (a *App) Resolve(ctx context.Context, items []string, command []string) (map[string]string, []string, error) {
	cache, err := a.Dir.Cache()
	if err != nil {
		return nil, nil, err
	}
	ov, err := a.Dir.Overrides()
	if err != nil {
		return nil, nil, err
	}
	strict := len(items) > 0
	picks := vault.EnvPicks(vault.ActiveIDs(cache))
	if strict {
		picks = picks[:0]
		for _, item := range items {
			p, err := vault.ParsePick(cache, item)
			if err != nil {
				return nil, nil, err
			}
			picks = append(picks, p)
		}
	}
	remote, err := a.remote(ctx, cache, picks, ov, command)
	if err != nil {
		return nil, nil, err
	}
	if strict {
		return vault.Select(cache, a.Keys, picks, ov, remote, nowMs())
	}
	vars, skipped := vault.Merge(cache, a.Keys, vault.ActiveIDs(cache), ov, remote, nowMs())
	return vars, skipped, nil
}

// remote 取得 picks 中要经手机批准的变量。
func (a *App) remote(ctx context.Context, cache *state.Cache, picks []vault.Pick, ov state.Overrides, command []string) (vault.Remote, error) {
	out := vault.Remote{}
	for _, p := range picks {
		if env, err := vault.Find(cache, p.EnvID); err == nil && !env.LocalDecrypt && !vault.Expired(*env, nowMs()) {
			out[env.ID] = map[string]string{}
		}
	}
	items := vault.Needed(cache, picks, ov, nowMs())
	if len(items) == 0 {
		return out, nil
	}
	// 保管进程出了问题时照常向手机请求。
	held, _ := keeper.Get(a.Dir.Path, items)
	have := map[[2]string]bool{}
	for _, v := range held {
		out[v.EnvironmentID][v.Name] = v.Value
		have[[2]string{v.EnvironmentID, v.Name}] = true
	}
	var missing []api.ApprovalItem
	for _, it := range items {
		if !have[[2]string{it.EnvironmentID, it.Name}] {
			missing = append(missing, it)
		}
	}
	if len(missing) == 0 {
		return out, nil
	}
	r, err := a.requester(command)
	if err != nil {
		return nil, err
	}
	g, err := r.Read(ctx, missing)
	if err != nil {
		return nil, a.HandleRevoked(err)
	}
	vals := make([]keeper.Value, len(g.Values))
	for i, v := range g.Values {
		out[v.EnvironmentID][v.Name] = v.Plain.Value
		vals[i] = keeper.Value{EnvironmentID: v.EnvironmentID, Name: v.Name, Value: v.Plain.Value}
	}
	if g.Scope != approval.ScopeOnce {
		bin, err := os.Executable()
		if err == nil {
			err = keeper.Put(a.Dir.Path, bin, keeper.Auth{ID: g.RequestID, Scope: g.Scope, ExpiresAt: g.ExpiresAt, Values: vals})
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "harmonia：没能把批准的变量交给保管进程（%v），下次使用时需要重新批准。\n", err)
		}
	}
	return out, nil
}

// Authorizations 是这台电脑上正在生效的授权：保管进程持有的，以及服务端还记着、但保管进程没有持有的
// （例如断网时关机，没能通知到服务器）。后一种在服务端结束。离线时只列出保管进程持有的。
func (a *App) Authorizations(ctx context.Context) ([]keeper.Auth, error) {
	held, err := keeper.List(a.Dir.Path)
	if err != nil {
		return nil, err
	}
	list, err := a.Client.Authorizations(ctx)
	if err != nil {
		return held, nil
	}
	kept := map[string]bool{}
	for _, h := range held {
		kept[h.ID] = true
	}
	for _, s := range list {
		if !kept[s.ID] {
			_ = a.Client.EndAuthorization(ctx, s.ID)
		}
	}
	return held, nil
}

// Lock 结束这台电脑上的全部授权，返回结束的数量。
func (a *App) Lock(ctx context.Context) (int, error) {
	ended, err := keeper.Lock(a.Dir.Path)
	if err != nil {
		return 0, err
	}
	n := len(ended)
	// 保管进程没有在运行、但服务端还记着的授权也一并结束。
	if list, err := a.Client.Authorizations(ctx); err == nil {
		for _, s := range list {
			if a.Client.EndAuthorization(ctx, s.ID) == nil && !slices.Contains(ended, s.ID) {
				n++
			}
		}
	}
	return n, nil
}

// ServeKeeper 运行保管进程（harmonia keeper，由 CLI 在需要时启动）。
func (a *App) ServeKeeper(ctx context.Context, logf func(string, ...any)) error {
	return keeper.Serve(ctx, a.Dir.Path, keeper.Hooks{
		Listen:         a.Client.Listen,
		End:            a.Client.EndAuthorization,
		Authorizations: a.Client.Authorizations,
		Logf:           logf,
	})
}

// remoteChange 把对一个变量的修改转成写入请求的一项：电脑上没有库钥，读不到原来的值，
// 所以只修改备注时值沿用原值，由手机合并；新增变量必须给出值。
func remoteChange(d vault.Dest, name string, ch VarChange) (approval.SetItem, error) {
	plain := map[string]string{}
	if ch.Value != nil {
		if len(*ch.Value) > hc.MaxValueLen {
			return approval.SetItem{}, fmt.Errorf("变量 %s 的值超过 64 KB", name)
		}
		plain["value"] = *ch.Value
	} else if d.Name == "" {
		return approval.SetItem{}, fmt.Errorf("变量 %s 不存在，请同时给出它的值", name)
	}
	if ch.Note != nil {
		note, err := NormalizeNote(*ch.Note)
		if err != nil {
			return approval.SetItem{}, err
		}
		plain["note"] = note
	}
	return approval.SetItem{ApprovalItem: d.ApprovalItem(), Plain: plain}, nil
}

// maxApprovalItems 是一个批准请求最多包含的变量数（docs/protocol.md 3.9）。
const maxApprovalItems = 200

// writeRemote 经手机批准写入或删除没有开启本机解密的环境里的变量；超过 200 个时分成几个请求。
func (a *App) writeRemote(ctx context.Context, cache *state.Cache, set []approval.SetItem, del []api.ApprovalItem) error {
	// 手机上显示的命令只到子命令为止：后面的参数里可能有变量的值。
	command := os.Args[:min(len(os.Args), 2)]
	if len(os.Args) > 2 && os.Args[1] == "var" {
		command = os.Args[:3]
	}
	r, err := a.requester(command)
	if err != nil {
		return err
	}
	for len(set) > 0 || len(del) > 0 {
		n := min(len(set), maxApprovalItems)
		m := min(len(del), maxApprovalItems-n)
		if err := r.Write(ctx, cache.Managers, set[:n], del[:m]); err != nil {
			return a.HandleRevoked(err)
		}
		set, del = set[n:], del[m:]
	}
	return nil
}
