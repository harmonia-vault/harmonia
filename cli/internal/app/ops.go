package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
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

func (a *App) writableEnv(nameOrID string) (*api.Environment, error) {
	env, err := a.Env(nameOrID)
	if err != nil {
		return nil, err
	}
	if vault.Expired(*env, nowMs()) {
		return nil, fmt.Errorf("这台设备对环境“%s”的授权已到期，请在管理设备上重新授权", env.Name)
	}
	if env.Role == "ro" {
		return nil, fmt.Errorf("这台设备对环境“%s”只有只读权限，不能修改。可以在管理设备上调整权限", env.Name)
	}
	return env, nil
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

// SetVariables 把变量写入云端，成功后同步到本机。必须在线。
func (a *App) SetVariables(ctx context.Context, envNameOrID string, changes map[string]VarChange) error {
	env, err := a.writableEnv(envNameOrID)
	if err != nil {
		return err
	}
	cache, err := a.Dir.Cache()
	if err != nil {
		return err
	}
	key, kv, err := vault.EnvKey(cache, a.Keys, env.ID)
	if err != nil {
		return err
	}
	var (
		current map[string]hc.Entry
		broken  []string
	)
	entries := make(map[string]hc.Entry, len(changes))
	names := make([]string, 0, len(changes))
	for n, ch := range changes {
		if err := ValidateName(n); err != nil {
			return err
		}
		if (ch.Value == nil || ch.Note == nil) && current == nil {
			if current, broken, err = vault.Entries(cache, a.Keys, env.ID); err != nil {
				return err
			}
		}
		e, exists := current[n]
		if ch.Value == nil && !exists {
			if slices.Contains(broken, n) {
				return fmt.Errorf("变量 %s 无法解密，请同时给出它的值，重新写入", n)
			}
			return fmt.Errorf("变量 %s 不存在，请同时给出它的值", n)
		}
		if ch.Value != nil {
			e.Value = *ch.Value
		}
		if ch.Note != nil {
			if e.Note, err = NormalizeNote(*ch.Note); err != nil {
				return err
			}
		}
		if len(e.Value) > hc.MaxValueLen {
			return fmt.Errorf("变量 %s 的值超过 64 KB", n)
		}
		entries[n] = e
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		ct, err := hc.EncryptVar(key, env.ID, kv, n, entries[n])
		if err != nil {
			return err
		}
		if err := a.Client.PutVariable(ctx, env.ID, n, ct, fmt.Sprint(kv), hc.NewID()); err != nil {
			return a.HandleRevoked(fmt.Errorf("写入 %s 失败：%w", n, err))
		}
	}
	return a.Sync(ctx)
}

func (a *App) DeleteVariable(ctx context.Context, envNameOrID, name string) error {
	env, err := a.writableEnv(envNameOrID)
	if err != nil {
		return err
	}
	if err := a.Client.DeleteVariable(ctx, env.ID, name, hc.NewID()); err != nil {
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
	cache, err := a.Dir.Cache()
	if err != nil {
		return nil, err
	}
	if _, ok := cache.Variables[env.ID][name]; !ok && value != nil {
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
