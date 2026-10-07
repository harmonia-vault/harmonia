package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
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

// SetVariables 把变量写入云端，成功后同步到本机。必须在线。
func (a *App) SetVariables(ctx context.Context, envNameOrID string, vars map[string]string) error {
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
	names := make([]string, 0, len(vars))
	for n := range vars {
		if err := ValidateName(n); err != nil {
			return err
		}
		if len(vars[n]) > hc.MaxValueLen {
			return fmt.Errorf("变量 %s 的值超过 64 KB", n)
		}
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		ct, err := hc.EncryptValue(key, env.ID, kv, n, vars[n])
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

// Activate 激活环境并设置优先级。
func (a *App) Activate(nameOrID string, priority int) (*api.Environment, error) {
	env, err := a.Env(nameOrID)
	if err != nil {
		return nil, err
	}
	return env, a.UpdateConfig(func(c *state.Config) error {
		for i := range c.Activations {
			if c.Activations[i].EnvID == env.ID {
				c.Activations[i].Priority = priority
				return nil
			}
		}
		c.Activations = append(c.Activations, state.Activation{EnvID: env.ID, Priority: priority})
		return nil
	})
}

func (a *App) Deactivate(nameOrID string) (*api.Environment, error) {
	env, err := a.Env(nameOrID)
	if err != nil {
		return nil, err
	}
	return env, a.UpdateConfig(func(c *state.Config) error {
		out := c.Activations[:0]
		for _, x := range c.Activations {
			if x.EnvID != env.ID {
				out = append(out, x)
			}
		}
		c.Activations = out
		return nil
	})
}

// SetOverride 为已存在的云端变量设置仅本机生效的值；value=nil 表示移除。
func (a *App) SetOverride(envNameOrID, name string, value *string) (*api.Environment, error) {
	env, err := a.Env(envNameOrID)
	if err != nil {
		return nil, err
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
		MOTD_SHOWN HARMONIA_HOME`) {
		skip[n] = true
	}
	out := map[string]string{}
	for _, kv := range os.Environ() {
		name, value, ok := strings.Cut(kv, "=")
		if !ok || skip[name] || strings.HasPrefix(name, "LC_") || strings.HasPrefix(name, "MISE_") ||
			strings.HasPrefix(name, "__") || ValidateName(name) != nil {
			continue
		}
		out[name] = value
	}
	return out
}
