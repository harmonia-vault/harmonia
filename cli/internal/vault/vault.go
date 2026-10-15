// Package vault 把同步结果写入本机缓存，并计算最终生效的环境变量。
package vault

import (
	"errors"
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// Apply 合并一次同步响应。since=0 表示全量。
func Apply(c *state.Cache, s *api.Sync, since int64, rootPub string, deviceID string) error {
	root, err := hc.UnB64(rootPub)
	if err != nil {
		return errors.New("本机记录的账号公钥已损坏")
	}
	for _, e := range s.Envelopes {
		sealed, err1 := hc.UnB64(e.Sealed)
		sig, err2 := hc.UnB64(e.Sig)
		kv, err3 := strconv.Atoi(e.KeyVersion)
		if err1 != nil || err2 != nil || err3 != nil || !hc.Verify(root, hc.EnvelopeMsg(e.EnvID, kv, deviceID, sealed), sig) {
			return errors.New("服务器下发的环境密钥签名无效，已停止同步。请确认服务器地址是否正确")
		}
	}
	visible := map[string]bool{}
	for _, e := range s.Environments {
		visible[e.ID] = true
	}
	if since == 0 {
		c.Variables = map[string]map[string]state.CachedVar{}
	}
	for id := range c.Variables {
		if !visible[id] {
			delete(c.Variables, id)
		}
	}
	for _, v := range s.Variables {
		if !visible[v.EnvID] {
			continue
		}
		m := c.Variables[v.EnvID]
		if m == nil {
			m = map[string]state.CachedVar{}
			c.Variables[v.EnvID] = m
		}
		if v.Deleted {
			delete(m, v.Name)
			continue
		}
		kv, _ := strconv.Atoi(v.KeyVersion)
		m[v.Name] = state.CachedVar{Value: v.Value, KeyVersion: kv}
	}
	c.Environments = s.Environments
	c.Envelopes = s.Envelopes
	c.Seq = s.Seq
	return nil
}

// Find 按名称（不区分大小写）或 ID 查找可访问的环境。
func Find(c *state.Cache, nameOrID string) (*api.Environment, error) {
	var match []api.Environment
	for _, e := range c.Environments {
		if e.ID == nameOrID {
			return &e, nil
		}
		if strings.EqualFold(e.Name, nameOrID) {
			match = append(match, e)
		}
	}
	switch len(match) {
	case 1:
		return &match[0], nil
	case 0:
		return nil, notFound(c, nameOrID)
	default:
		return nil, fmt.Errorf("有多个名为“%s”的环境，请改用环境 ID", nameOrID)
	}
}

// notFound 说明环境为什么找不到：列出这台设备能访问的环境，并说明没被授权时怎么办。
func notFound(c *state.Cache, nameOrID string) error {
	if len(c.Environments) == 0 {
		return fmt.Errorf("找不到环境“%s”：这台设备还没有任何环境的访问权限。请在管理设备上为这台设备授权", nameOrID)
	}
	var names []string
	for _, e := range Ordered(c) {
		names = append(names, "“"+e.Name+"”")
	}
	return fmt.Errorf("找不到环境“%s”。这台设备能访问的环境：%s。名字没写错的话，需要在管理设备上为这台设备授权这个环境", nameOrID, strings.Join(names, "、"))
}

// Expired 判断授权是否已到期（离线时同样生效）。
func Expired(e api.Environment, nowMs int64) bool { return e.ExpiresAt != 0 && e.ExpiresAt <= nowMs }

// EnvKey 解开某个环境的环境钥。
func EnvKey(c *state.Cache, k *state.DeviceKeys, envID string) ([]byte, int, error) {
	for _, e := range c.Envelopes {
		if e.EnvID != envID {
			continue
		}
		sealed, err := hc.UnB64(e.Sealed)
		if err != nil {
			return nil, 0, err
		}
		key, err := k.Box.Open(sealed)
		if err != nil || len(key) != 32 {
			return nil, 0, errors.New("无法解开环境密钥，请在管理设备上重新授权这台设备")
		}
		kv, _ := strconv.Atoi(e.KeyVersion)
		return key, kv, nil
	}
	return nil, 0, errors.New("这台设备没有这个环境的密钥，请在管理设备上重新授权这台设备")
}

// Entries 解密一个环境的全部变量（值和备注）。解不开的变量不放进结果，名称按顺序列在 broken 里，
// 它们仍然可以删除或重新写入。
func Entries(c *state.Cache, k *state.DeviceKeys, envID string) (map[string]hc.Entry, []string, error) {
	key, _, err := EnvKey(c, k, envID)
	if err != nil {
		return nil, nil, err
	}
	out := map[string]hc.Entry{}
	var broken []string
	for name, v := range c.Variables[envID] {
		e, err := hc.DecryptVar(key, envID, v.KeyVersion, name, v.Value)
		if err != nil {
			broken = append(broken, name)
			continue
		}
		out[name] = e
	}
	sort.Strings(broken)
	return out, broken, nil
}

// Values 解密一个环境的全部变量的值；解不开的变量不放进结果，名称列在 broken 里，其余照常使用。
func Values(c *state.Cache, k *state.DeviceKeys, envID string) (map[string]string, []string, error) {
	entries, broken, err := Entries(c, k, envID)
	if err != nil {
		return nil, nil, err
	}
	out := make(map[string]string, len(entries))
	for name, e := range entries {
		out[name] = e.Value
	}
	return out, broken, nil
}

// Ordered 返回按顺序排列的环境副本（靠前的提供同名变量）。
func Ordered(c *state.Cache) []api.Environment {
	envs := append([]api.Environment(nil), c.Environments...)
	sort.SliceStable(envs, func(i, j int) bool { return envs[i].Position < envs[j].Position })
	return envs
}

// ActiveIDs 返回激活的环境，按顺序排列。
func ActiveIDs(c *state.Cache) []string {
	var ids []string
	for _, e := range Ordered(c) {
		if e.Active {
			ids = append(ids, e.ID)
		}
	}
	return ids
}

// Merge 按顺序合并环境：同名变量由排在前面的环境提供；本地覆盖值先替换所在环境中的值。
// 未授权、已到期或密钥解不开的环境，以及解不开的变量被跳过，并在 skipped 中逐条说明原因和处理办法。
func Merge(c *state.Cache, k *state.DeviceKeys, ids []string, ov state.Overrides, nowMs int64) (map[string]string, []string) {
	picks := make([]Pick, len(ids))
	for i, id := range ids {
		picks[i] = Pick{EnvID: id}
	}
	out, skipped, _ := merge(c, k, picks, ov, nowMs, false)
	return out, skipped
}

// Pick 是 --env 的一项：整个环境，或者环境中的一个变量（Var 非空）。
type Pick struct {
	EnvID string
	Var   string
}

// ParsePick 解析 --env 的一项：整串是环境名称或 ID 时取整个环境；否则按最后一个“:”
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
func Select(c *state.Cache, k *state.DeviceKeys, picks []Pick, ov state.Overrides, nowMs int64) (map[string]string, []string, error) {
	return merge(c, k, picks, ov, nowMs, true)
}

func merge(c *state.Cache, k *state.DeviceKeys, picks []Pick, ov state.Overrides, nowMs int64, strict bool) (map[string]string, []string, error) {
	var ids []string
	seen := map[string]bool{}
	for _, p := range picks {
		if !seen[p.EnvID] {
			seen[p.EnvID] = true
			ids = append(ids, p.EnvID)
		}
	}
	srcs, problems := sources(c, k, ids, ov, nowMs)
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
		if _, ok := c.Variables[e.ID][name]; ok && e.ID != env.ID {
			others = append(others, e.Name)
		}
	}
	if len(others) > 0 {
		return fmt.Errorf("环境“%s”里没有变量 %s，“%s”里有，可以写成 --env %s:%s", env.Name, name, strings.Join(others, "”“"), others[0], name)
	}
	return fmt.Errorf("环境“%s”里没有变量 %s。运行 harmonia var list --env %s 查看这个环境的变量，或用 harmonia var set %s %s 写入", env.Name, name, env.Name, env.Name, name)
}

// Conflict 表示一个变量同时出现在多个环境中；Envs 按顺序排列，第一个生效。
type Conflict struct {
	Name string
	Envs []string
}

// Conflicts 列出按 ids 顺序合并时，同名变量分别来自哪些环境（环境名）。
func Conflicts(c *state.Cache, k *state.DeviceKeys, ids []string, nowMs int64) []Conflict {
	by := map[string][]string{}
	srcs, _ := sources(c, k, ids, nil, nowMs)
	for _, src := range srcs {
		for name := range src.vals {
			by[name] = append(by[name], src.env.Name)
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

type source struct {
	env    *api.Environment
	vals   map[string]string
	broken []string
}

// Unavailable 说明这个环境为什么拿不到变量（授权到期、密钥解不开），以及怎么处理；能用时返回空。
func Unavailable(c *state.Cache, k *state.DeviceKeys, env api.Environment, nowMs int64) string {
	if Expired(env, nowMs) {
		return fmt.Sprintf("这台设备对环境“%s”的授权已于 %s 到期，请在管理设备上重新授权", env.Name, time.UnixMilli(env.ExpiresAt).Format("2006-01-02 15:04"))
	}
	if _, _, err := EnvKey(c, k, env.ID); err != nil {
		return fmt.Sprintf("环境“%s”：%v", env.Name, err)
	}
	return ""
}

// sources 按 ids 顺序解出各环境的变量（已套用本地覆盖）；拿不到的环境不放进结果，原因记在 problems 里。
func sources(c *state.Cache, k *state.DeviceKeys, ids []string, ov state.Overrides, nowMs int64) ([]source, map[string]string) {
	problems := map[string]string{}
	var out []source
	for _, id := range ids {
		var env *api.Environment
		for i := range c.Environments {
			if c.Environments[i].ID == id {
				env = &c.Environments[i]
			}
		}
		if env == nil {
			problems[id] = fmt.Sprintf("环境 %s 已不可访问（授权可能已被撤销）", id)
			continue
		}
		if p := Unavailable(c, k, *env, nowMs); p != "" {
			problems[id] = p
			continue
		}
		vals, broken, err := Values(c, k, id)
		if err != nil {
			problems[id] = fmt.Sprintf("环境“%s”：%v", env.Name, err)
			continue
		}
		for name, v := range ov[id] {
			if _, ok := vals[name]; ok {
				vals[name] = v
			}
		}
		out = append(out, source{env: env, vals: vals, broken: broken})
	}
	return out, problems
}

// Known 返回这台设备能访问的每个环境（含已停用、已到期的）给各变量的值，以及本机覆盖值：
// 变量名 → 值的集合。用于 harmonia exec --env 时认出终端里由 Harmonia 写入的变量。解不开的环境跳过。
func Known(c *state.Cache, k *state.DeviceKeys, ov state.Overrides) map[string]map[string]bool {
	out := map[string]map[string]bool{}
	add := func(name, v string) {
		if out[name] == nil {
			out[name] = map[string]bool{}
		}
		out[name][v] = true
	}
	for _, env := range c.Environments {
		vals, _, err := Values(c, k, env.ID)
		if err != nil {
			continue
		}
		for name, v := range vals {
			add(name, v)
		}
	}
	for _, vars := range ov {
		for name, v := range vars {
			add(name, v)
		}
	}
	return out
}
