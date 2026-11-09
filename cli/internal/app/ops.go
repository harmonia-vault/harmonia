package app

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/approval"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

var varName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,127}$`)

// ValidateName 校验变量名。
func ValidateName(name string) error {
	if !varName.MatchString(name) {
		return fmt.Errorf("变量名“%s”不合法：只能包含字母、数字和下划线，且不能以数字开头", name)
	}
	if strings.HasPrefix(strings.ToUpper(name), "__HARMONIA_") {
		return errors.New("以 __HARMONIA_ 开头的变量名为保留名称")
	}
	return nil
}

// Env 按名称或 ID 查找可访问的环境。
func (a *App) Env(nameOrID string) (*api.Environment, error) {
	cache, err := a.Dir.Cache()
	if err != nil {
		return nil, err
	}
	return vault.Find(cache, nameOrID)
}

// MaxNoteLen 是备注的最大字符数（docs/protocol.md 第 1 节）。
const MaxNoteLen = 200

// NormalizeNote 去除备注首尾的空白并检查长度。
func NormalizeNote(note string) (string, error) {
	note = strings.TrimSpace(note)
	if utf8.RuneCountInString(note) > MaxNoteLen {
		return "", fmt.Errorf("备注最长 %d 个字，请缩短后重试", MaxNoteLen)
	}
	return note, nil
}

// VarChange 是对一个变量的修改：Value 或 Note 为 nil 时沿用原来的。
type VarChange struct {
	Value *string `json:"value"`
	Note  *string `json:"note"`
}

// 写入一个变量的结果。
const (
	Written   = "written"   // 已写入，并且回读校验一致
	Approved  = "approved"  // 已在手机上批准，由手机写入（没有开启本机解密的环境，电脑上无法回读）
	Unchanged = "unchanged" // 和现有的值、备注相同，跳过
	Failed    = "failed"    // 失败，原因见 Err
)

// VarResult 是写入一个变量的结果。
type VarResult struct {
	Name   string
	Status string
	Err    error
}

// UnverifiedError 表示变量已经写入云端，但写入后的同步没有完成，没能回读校验。
type UnverifiedError struct{ Err error }

func (e *UnverifiedError) Error() string {
	return "已写入云端，但回读校验没有完成（" + e.Err.Error() + "）。稍后运行 harmonia sync 确认"
}

func (e *UnverifiedError) Unwrap() error { return e.Err }

// digest 是变量内容的 SHA-256，只用于在内存里比较写入的和回读的是否一致。
func digest(e hc.Entry) [2][32]byte {
	return [2][32]byte{sha256.Sum256([]byte(e.Value)), sha256.Sum256([]byte(e.Note))}
}

// SetVariables 把变量写入云端。target 是环境或变量库（vaultOnly 时只认变量库）：写环境时用环境里的名字，
// 写回它所在的变量库；新增变量必须指定变量库（设计文档 17.2）。先同步取得最新状态；skipSame 时跳过
// 值和备注都没变的变量（导入时，重跑等于从断点继续）；其余按变量库分批写入。写入后再同步一次，
// 从本机缓存解密回读，核对 SHA-256。返回每个变量的结果，按名称排序；回读前的同步失败时同时返回
// *UnverifiedError。必须在线。
func (a *App) SetVariables(ctx context.Context, target string, vaultOnly bool, changes map[string]VarChange, skipSame bool) ([]VarResult, error) {
	if err := a.Sync(ctx); err != nil {
		return nil, err
	}
	cache, err := a.Dir.Cache()
	if err != nil {
		return nil, err
	}
	t, err := vault.ResolveTarget(cache, target, vaultOnly)
	if err != nil {
		return nil, err
	}
	if t.Env != nil {
		if err := vault.CheckWritable(t.Env, nowMs()); err != nil {
			return nil, err
		}
	}
	names := make([]string, 0, len(changes))
	for n := range changes {
		names = append(names, n)
	}
	sort.Strings(names)
	results := make([]VarResult, len(names))
	type group struct {
		key   []byte
		kv    int
		cur   map[string]hc.Entry
		bad   []string
		items []BatchItem
		idx   []int
	}
	groups := map[string]*group{}
	dests := make([]vault.Dest, len(names))
	var remoteSet []approval.SetItem
	var remoteIdx []int
	for i, n := range names {
		results[i].Name = n
		fail := func(err error) { results[i].Status, results[i].Err = Failed, err }
		if err := ValidateName(n); err != nil {
			fail(err)
			continue
		}
		d, err := vault.WriteDest(cache, t, n, nowMs())
		if err != nil {
			fail(err)
			continue
		}
		dests[i] = d
		if d.Remote() {
			item, err := remoteChange(d, n, changes[n])
			if err != nil {
				fail(err)
				continue
			}
			remoteSet = append(remoteSet, item)
			remoteIdx = append(remoteIdx, i)
			continue
		}
		g := groups[d.VaultID]
		if g == nil {
			g = &group{}
			if g.key, g.kv, err = vault.VaultKey(cache, a.Keys, d.VaultID); err == nil {
				g.cur, g.bad, err = vault.VaultEntries(cache, a.Keys, d.VaultID)
			}
			if err != nil {
				fail(err)
				continue
			}
			groups[d.VaultID] = g
		}
		ch := changes[n]
		e, exists := g.cur[d.Source]
		if ch.Value == nil && !exists {
			if slices.Contains(g.bad, d.Source) {
				fail(fmt.Errorf("变量 %s 无法解密，请同时给出它的值，重新写入", n))
			} else {
				fail(fmt.Errorf("变量 %s 不存在，请同时给出它的值", n))
			}
			continue
		}
		old := e
		if ch.Value != nil {
			e.Value = *ch.Value
		}
		if ch.Note != nil {
			if e.Note, err = NormalizeNote(*ch.Note); err != nil {
				fail(err)
				continue
			}
		}
		if len(e.Value) > hc.MaxValueLen {
			fail(fmt.Errorf("变量 %s 的值超过 64 KB", n))
			continue
		}
		if skipSame && exists && digest(old) == digest(e) {
			results[i].Status = Unchanged
			continue
		}
		g.items = append(g.items, BatchItem{Name: d.Source, Entry: e})
		g.idx = append(g.idx, i)
	}
	want := map[int]hc.Entry{}
	for vaultID, g := range groups {
		if len(g.items) == 0 {
			continue
		}
		errs, err := WriteBatch(ctx, a.Client, vaultID, g.key, g.kv, g.items)
		if err != nil {
			return nil, a.HandleRevoked(err)
		}
		for j, i := range g.idx {
			if errs[j] != nil {
				results[i].Status, results[i].Err = Failed, fmt.Errorf("写入 %s 失败：%w", names[i], errs[j])
				continue
			}
			results[i].Status = Written
			want[i] = g.items[j].Entry
		}
	}
	if len(remoteSet) > 0 {
		err := a.writeRemote(ctx, cache, remoteSet, nil)
		if errors.Is(err, ErrRevokedLocal) {
			return nil, err
		}
		for _, i := range remoteIdx {
			if err != nil {
				results[i].Status, results[i].Err = Failed, err
			} else {
				results[i].Status = Approved
			}
		}
	}
	if len(want) == 0 && len(remoteSet) == 0 {
		return results, nil
	}
	if err := a.Sync(ctx); err != nil {
		if errors.Is(err, ErrRevokedLocal) {
			return nil, err
		}
		return results, &UnverifiedError{err}
	}
	if cache, err = a.Dir.Cache(); err != nil {
		return results, &UnverifiedError{err}
	}
	got := map[string]map[string]hc.Entry{}
	for i, w := range want {
		d := dests[i]
		if got[d.VaultID] == nil {
			if got[d.VaultID], _, err = vault.VaultEntries(cache, a.Keys, d.VaultID); err != nil {
				return results, &UnverifiedError{err}
			}
		}
		if g, ok := got[d.VaultID][d.Source]; !ok || digest(g) != digest(w) {
			results[i].Status = Failed
			results[i].Err = fmt.Errorf("%s 已写入，但回读的内容和写入的不一致，可能另一台设备同时修改了它。运行 harmonia var list 查看", results[i].Name)
		}
	}
	return results, nil
}

// DeleteVariable 删除变量：target 是环境（用环境里的名字）或变量库（用原名），从变量库里删除原变量。
func (a *App) DeleteVariable(ctx context.Context, target, name string) error {
	if err := a.Sync(ctx); err != nil {
		return err
	}
	cache, err := a.Dir.Cache()
	if err != nil {
		return err
	}
	t, err := vault.ResolveTarget(cache, target, false)
	if err != nil {
		return err
	}
	if t.Env != nil && !vault.HasItem(t.Env, name) {
		return fmt.Errorf("环境“%s”里没有 %s，运行 harmonia var list --env %s 查看", t.Env.Name, name, t.Env.Name)
	}
	d, err := vault.WriteDest(cache, t, name, nowMs())
	if err != nil {
		return err
	}
	if d.Remote() {
		if d.Name == "" {
			return fmt.Errorf("这台设备的环境里看不到变量库“%s”的 %s，无法删除", t.VaultName, name)
		}
		if err := a.writeRemote(ctx, cache, nil, []api.ApprovalItem{d.ApprovalItem()}); err != nil {
			return err
		}
	} else if err := a.Client.DeleteVariable(ctx, d.VaultID, d.Source, hc.NewID()); err != nil {
		return a.HandleRevoked(err)
	}
	return a.Sync(ctx)
}

// Activate、Deactivate 与 Order 修改本机的激活状态和顺序：先同步取得最新授权，
// 提交到服务端（需要联网），再同步一次让 env.sh 生效。
func (a *App) Activate(ctx context.Context, nameOrID string) (*api.Environment, error) {
	return a.setActive(ctx, nameOrID, true)
}

func (a *App) Deactivate(ctx context.Context, nameOrID string) (*api.Environment, error) {
	return a.setActive(ctx, nameOrID, false)
}

func (a *App) setActive(ctx context.Context, nameOrID string, active bool) (*api.Environment, error) {
	if err := a.Sync(ctx); err != nil {
		return nil, err
	}
	env, err := a.Env(nameOrID)
	if err != nil {
		return nil, err
	}
	return env, a.submitActivation(ctx, func(envs []api.Environment) []api.Environment {
		for i := range envs {
			if envs[i].ID == env.ID {
				envs[i].Active = active
			}
		}
		return envs
	})
}

// Order 把给定的环境按顺序移到最前面，其余环境保持原有顺序。
func (a *App) Order(ctx context.Context, namesOrIDs []string) error {
	if err := a.Sync(ctx); err != nil {
		return err
	}
	first := make([]*api.Environment, 0, len(namesOrIDs))
	seen := map[string]bool{}
	for _, n := range namesOrIDs {
		env, err := a.Env(n)
		if err != nil {
			return err
		}
		if seen[env.ID] {
			return fmt.Errorf("环境“%s”重复出现", env.Name)
		}
		seen[env.ID] = true
		first = append(first, env)
	}
	return a.submitActivation(ctx, func(envs []api.Environment) []api.Environment {
		out := make([]api.Environment, 0, len(envs))
		for _, f := range first {
			for _, e := range envs {
				if e.ID == f.ID {
					out = append(out, e)
				}
			}
		}
		for _, e := range envs {
			if !seen[e.ID] {
				out = append(out, e)
			}
		}
		return out
	})
}

func (a *App) submitActivation(ctx context.Context, change func([]api.Environment) []api.Environment) error {
	cache, err := a.Dir.Cache()
	if err != nil {
		return err
	}
	envs := change(vault.Ordered(cache))
	items := make([]api.ActivationItem, len(envs))
	for i, e := range envs {
		items[i] = api.ActivationItem{EnvID: e.ID, Active: e.Active}
	}
	if err := a.Client.SetActivation(ctx, items); err != nil {
		return a.HandleRevoked(err)
	}
	return a.Sync(ctx)
}

// SetOverride 为已存在的云端变量设置仅本机生效的值；value=nil 表示移除，
// 这时也接受已无法访问的环境的 ID。
func (a *App) SetOverride(envNameOrID, name string, value *string) (*api.Environment, error) {
	env, err := a.Env(envNameOrID)
	if err != nil {
		if value != nil {
			return nil, err
		}
		// 环境已无法访问（例如授权被撤销）时，仍可以按环境 ID 移除留下的覆盖值。
		ov, oerr := a.Dir.Overrides()
		if oerr != nil {
			return nil, oerr
		}
		if _, ok := ov[envNameOrID][name]; !ok {
			return nil, err
		}
		env = &api.Environment{ID: envNameOrID, Name: envNameOrID}
	}
	if !vault.HasItem(env, name) && value != nil {
		return nil, fmt.Errorf("环境“%s”中没有变量 %s。本机覆盖只能用于云端已有的变量", env.Name, name)
	}
	unlock, err := a.Dir.Lock()
	if err != nil {
		return nil, err
	}
	ov, err := a.Dir.Overrides()
	if err == nil {
		if value == nil {
			delete(ov[env.ID], name)
			if len(ov[env.ID]) == 0 {
				delete(ov, env.ID)
			}
		} else {
			if ov[env.ID] == nil {
				ov[env.ID] = map[string]string{}
			}
			ov[env.ID][name] = *value
		}
		err = a.Dir.SaveOverrides(ov)
	}
	unlock()
	if err != nil {
		return nil, err
	}
	_, err = a.RefreshEnvFile()
	return env, err
}

// ImportCandidates 返回当前进程环境中可以导入的变量（排除系统与 shell 自带的变量）。
func ImportCandidates() map[string]string {
	skip := map[string]bool{}
	for _, n := range strings.Fields(`PATH HOME USER LOGNAME SHELL PWD OLDPWD TERM TERM_PROGRAM TERM_PROGRAM_VERSION
		TERM_SESSION_ID LANG LANGUAGE TMPDIR SHLVL _ COLORTERM DISPLAY EDITOR VISUAL PAGER LESS MANPATH INFOPATH
		SSH_AUTH_SOCK SSH_CLIENT SSH_CONNECTION SSH_TTY XPC_FLAGS XPC_SERVICE_NAME __CF_USER_TEXT_ENCODING
		COMMAND_MODE HOSTNAME MAIL OSTYPE TZ HISTFILE HISTSIZE SAVEHIST PS1 PS2 PROMPT RPROMPT ZDOTDIR
		XDG_RUNTIME_DIR XDG_SESSION_ID XDG_SESSION_TYPE XDG_DATA_DIRS XDG_CONFIG_DIRS DBUS_SESSION_BUS_ADDRESS
		MOTD_SHOWN HARMONIA_HOME WT_SESSION WT_PROFILE_ID`) {
		skip[n] = true
	}
	out := map[string]string{}
	for _, kv := range os.Environ() {
		name, value, ok := strings.Cut(kv, "=")
		if !ok || skip[name] || strings.HasPrefix(name, "LC_") || strings.HasPrefix(name, "MISE_") ||
			strings.HasPrefix(name, "__") || ValidateName(name) != nil || systemVariable(name) {
			continue
		}
		out[name] = value
	}
	return out
}
