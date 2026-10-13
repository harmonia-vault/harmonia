package app

import (
	"sort"
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/sysenv"
	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

// 系统和 shell 自身离不开的变量，harmonia exec --env 时即使值与某个环境相同也不去掉。
// Windows 的部分沿用 sysenv 的清单。
var essential = map[string]bool{
	"HOME": true, "USER": true, "LOGNAME": true, "SHELL": true, "PWD": true, "TMPDIR": true,
	"LANG": true, "TERM": true,
}

func isEssential(name string) bool { return essential[strings.ToUpper(name)] || sysenv.IsSystem(name) }

// ExecEnv 组装 harmonia exec 子进程的环境变量。
//
// 先去掉 environ 中与 vars 同名的条目：同一个名字出现两次时，多数程序读到的是第一个，
// 会拿到当前终端里的旧值。known 非 nil 时（指定了 --env），再去掉值与某个环境相同的变量，
// 也就是 Shell 集成或用户环境变量写入的其他环境的变量，这样命令只拿到指定环境的变量；
// 用户自己设的不同值和系统必需的变量保留。foldCase 用于 Windows，环境变量名不区分大小写。
func ExecEnv(environ []string, vars map[string]string, known map[string]map[string]bool, foldCase bool) []string {
	key := func(name string) string {
		if foldCase {
			return strings.ToUpper(name)
		}
		return name
	}
	replaced := map[string]bool{}
	for name := range vars {
		replaced[key(name)] = true
	}
	values := map[string]map[string]bool{}
	for name, vs := range known {
		k := key(name)
		if values[k] == nil {
			values[k] = map[string]bool{}
		}
		for v := range vs {
			values[k][v] = true
		}
	}
	out := make([]string, 0, len(environ)+len(vars))
	for _, kv := range environ {
		name, value, _ := strings.Cut(kv, "=")
		// Windows 上有“=C:”这类以等号开头的条目，原样保留。
		if name != "" && (replaced[key(name)] || (values[key(name)][value] && !isEssential(name))) {
			continue
		}
		out = append(out, kv)
	}
	names := make([]string, 0, len(vars))
	for name := range vars {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		out = append(out, name+"="+vars[name])
	}
	return out
}

// Known 返回这台设备能访问的每个环境给各变量的值（含本机覆盖），见 vault.Known。
func (a *App) Known() (map[string]map[string]bool, error) {
	cache, err := a.Dir.Cache()
	if err != nil {
		return nil, err
	}
	ov, err := a.Dir.Overrides()
	if err != nil {
		return nil, err
	}
	return vault.Known(cache, a.Keys, ov), nil
}
