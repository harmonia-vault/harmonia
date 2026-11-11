package vault

import (
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// Merge 按顺序合并环境：同名变量由排在前面的环境提供；本地覆盖值先替换所在环境中的值。
// 未授权、已到期或密钥解不开的环境，以及解不开的变量被跳过，并在 skipped 中逐条说明原因和处理办法。
func Merge(c *state.Cache, k *state.DeviceKeys, ids []string, ov state.Overrides, remote Remote, nowMs int64) (map[string]string, []string) {
	out, skipped, _ := merge(c, k, EnvPicks(ids), ov, remote, nowMs, false)
	return out, skipped
}

// EnvPicks 把环境 ID 转成取整个环境的 Pick。
func EnvPicks(ids []string) []Pick {
	picks := make([]Pick, len(ids))
	for i, id := range ids {
		picks[i] = Pick{EnvID: id}
	}
	return picks
}

// Pick 是 --env 的一项：整个环境，或者环境中的一个变量（Var 非空）。
type Pick struct {
	EnvID string
	Var   string
}

// ParsePick 解析 --env 的一项：整串是环境名称或完整 ID 时取整个环境；否则按最后一个“:”
// 拆成环境和变量名（变量名不含“:”），只取这个变量。
func ParsePick(c *state.Cache, item string) (Pick, error) {
	env, err := Find(c, item)
	if err == nil {
		return Pick{EnvID: env.ID}, nil
	}
	i := strings.LastIndex(item, ":")
	if i < 0 {
		return Pick{}, err
	}
	name := strings.TrimSpace(item[i+1:])
	if name == "" {
		return Pick{}, fmt.Errorf("“%s”缺少变量名，只取一个变量时写成 环境:变量名", item)
	}
	env, err = Find(c, strings.TrimSpace(item[:i]))
	if err != nil {
		return Pick{}, err
	}
	return Pick{EnvID: env.ID, Var: name}, nil
}

// Select 按 picks 的顺序合并：同名变量由排在前面的一项提供，规则同 Merge。picks 是用户明确指定的，
// 指定的环境拿不到（授权到期、密钥解不开）、其中有变量解不开，或指定的变量不存在时返回错误，说明原因和处理办法。
// remote 是经手机批准取得的、没有开启本机解密的环境的变量（见 Needed）。
func Select(c *state.Cache, k *state.DeviceKeys, picks []Pick, ov state.Overrides, remote Remote, nowMs int64) (map[string]string, []string, error) {
	return merge(c, k, picks, ov, remote, nowMs, true)
}

// Remote 是经手机批准取得的变量：环境 ID → 环境里的名字 → 值。
type Remote map[string]map[string]string

// Needed 列出按 picks 合并时，要经手机批准取得的变量：没有开启本机解密、没有到期的环境里用到的变量，
// 有本机覆盖值的除外。
func Needed(c *state.Cache, picks []Pick, ov state.Overrides, nowMs int64) []api.ApprovalItem {
	var out []api.ApprovalItem
	seen := map[[2]string]bool{}
	add := func(env *api.Environment, name string) {
		key := [2]string{env.ID, name}
		if _, overridden := ov[env.ID][name]; overridden || seen[key] {
			return
		}
		seen[key] = true
		out = append(out, api.ApprovalItem{EnvironmentID: env.ID, Name: name})
	}
	for _, p := range picks {
		env := ByID(c, p.EnvID)
		if env == nil || env.LocalDecrypt || Expired(*env, nowMs) {
			continue
		}
		for _, it := range env.Items {
			if p.Var == "" || p.Var == it.Name {
				add(env, it.Name)
			}
		}
	}
	return out
}

func merge(c *state.Cache, k *state.DeviceKeys, picks []Pick, ov state.Overrides, remote Remote, nowMs int64, strict bool) (map[string]string, []string, error) {
	var ids []string
	seen := map[string]bool{}
	for _, p := range picks {
		if !seen[p.EnvID] {
			seen[p.EnvID] = true
			ids = append(ids, p.EnvID)
		}
	}
	srcs, problems := sources(c, k, ids, ov, remote, nowMs)
	byID := map[string]source{}
	for _, src := range srcs {
		byID[src.env.ID] = src
	}
	var skipped []string
	for _, id := range ids {
		if p, ok := problems[id]; ok {
			if strict {
				return nil, nil, errors.New(p)
			}
			skipped = append(skipped, p+"，已跳过")
		}
	}
	out := map[string]string{}
	add := func(name, v string) {
		if _, ok := out[name]; !ok {
			out[name] = v
		}
	}
	for _, p := range picks {
		src, ok := byID[p.EnvID]
		if !ok {
			continue
		}
		if p.Var == "" {
			for _, name := range src.broken {
				msg := brokenNote(src.env, name)
				if strict {
					return nil, nil, errors.New(msg)
				}
				skipped = append(skipped, msg)
			}
			for name, v := range src.vals {
				add(name, v)
			}
			continue
		}
		v, ok := src.vals[p.Var]
		if !ok && slices.Contains(src.broken, p.Var) {
			return nil, nil, errors.New(brokenNote(src.env, p.Var))
		}
		if !ok {
			return nil, nil, missingVar(c, src.env, p.Var)
		}
		add(p.Var, v)
	}
	return out, skipped, nil
}

func brokenNote(env *api.Environment, name string) string {
	return fmt.Sprintf("环境“%s”的变量 %s 无法解密，可以用 harmonia var rm %s %s 删除，或在管理设备上重新写入", env.Name, name, env.Name, name)
}

// missingVar 说明指定的变量不在这个环境里；能访问的其他环境里有同名变量时一并指出。
func missingVar(c *state.Cache, env *api.Environment, name string) error {
	var others []string
	for _, e := range Ordered(c) {
		if e.ID != env.ID && HasItem(&e, name) {
			others = append(others, e.Name)
		}
	}
	if len(others) > 0 {
		return fmt.Errorf("环境“%s”里没有变量 %s，“%s”里有，可以写成 --env %s:%s", env.Name, name, strings.Join(others, "”“"), others[0], name)
	}
	return fmt.Errorf("环境“%s”里没有变量 %s。运行 harmonia var list --env %s 查看这个环境的变量", env.Name, name, env.Name)
}

// Conflict 表示一个变量同时出现在多个环境中；Envs 按顺序排列，第一个生效。
type Conflict struct {
	Name string
	Envs []string
}

// Conflicts 列出按 ids 顺序合并时，同名变量分别来自哪些环境（环境名）。只看变量名，已到期的环境不算。
func Conflicts(c *state.Cache, ids []string, nowMs int64) []Conflict {
	by := map[string][]string{}
	for _, id := range ids {
		env := ByID(c, id)
		if env == nil || Expired(*env, nowMs) {
			continue
		}
		for _, it := range env.Items {
			by[it.Name] = append(by[it.Name], env.Name)
		}
	}
	var out []Conflict
	for name, envs := range by {
		if len(envs) > 1 {
			out = append(out, Conflict{Name: name, Envs: envs})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}
