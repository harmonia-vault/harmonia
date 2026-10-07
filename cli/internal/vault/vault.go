// Package vault 把同步结果写入本机缓存，并计算最终生效的环境变量。
package vault

import (
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"

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
		return nil, fmt.Errorf("找不到环境“%s”。运行 harmonia env list 查看可用的环境", nameOrID)
	default:
		return nil, fmt.Errorf("有多个名为“%s”的环境，请改用环境 ID", nameOrID)
	}
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
			return nil, 0, errors.New("无法解开环境密钥，可能需要在管理设备上重新授权这台设备")
		}
		kv, _ := strconv.Atoi(e.KeyVersion)
		return key, kv, nil
	}
	return nil, 0, errors.New("这台设备没有这个环境的密钥")
}

// Values 解密一个环境的全部变量。
func Values(c *state.Cache, k *state.DeviceKeys, envID string) (map[string]string, error) {
	key, _, err := EnvKey(c, k, envID)
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for name, v := range c.Variables[envID] {
		plain, err := hc.DecryptValue(key, envID, v.KeyVersion, name, v.Value)
		if err != nil {
			return nil, fmt.Errorf("变量 %s 解密失败，可能数据已损坏", name)
		}
		out[name] = plain
	}
	return out, nil
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
// 未授权、已到期或已删除的环境被跳过，并在 skipped 中说明。
func Merge(c *state.Cache, k *state.DeviceKeys, ids []string, ov state.Overrides, nowMs int64) (map[string]string, []string) {
	out := map[string]string{}
	var skipped []string
	for _, src := range sources(c, k, ids, ov, nowMs, &skipped) {
		for name, v := range src.vals {
			if _, ok := out[name]; !ok {
				out[name] = v
			}
		}
	}
	return out, skipped
}

// Conflict 表示一个变量同时出现在多个环境中；Envs 按顺序排列，第一个生效。
type Conflict struct {
	Name string
	Envs []string
}

// Conflicts 列出按 ids 顺序合并时，同名变量分别来自哪些环境（环境名）。
func Conflicts(c *state.Cache, k *state.DeviceKeys, ids []string, nowMs int64) []Conflict {
	by := map[string][]string{}
	for _, src := range sources(c, k, ids, nil, nowMs, nil) {
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
	env  *api.Environment
	vals map[string]string
}

// sources 按 ids 顺序解出各环境的变量（已套用本地覆盖），跳过的原因写入 skipped（可为 nil）。
func sources(c *state.Cache, k *state.DeviceKeys, ids []string, ov state.Overrides, nowMs int64, skipped *[]string) []source {
	note := func(s string) {
		if skipped != nil {
			*skipped = append(*skipped, s)
		}
	}
	var out []source
	for _, id := range ids {
		var env *api.Environment
		for i := range c.Environments {
			if c.Environments[i].ID == id {
				env = &c.Environments[i]
			}
		}
		if env == nil {
			note(fmt.Sprintf("环境 %s 已不可访问，已跳过", id))
			continue
		}
		if Expired(*env, nowMs) {
			note(fmt.Sprintf("环境“%s”的授权已到期，已跳过", env.Name))
			continue
		}
		vals, err := Values(c, k, id)
		if err != nil {
			note(fmt.Sprintf("环境“%s”：%v", env.Name, err))
			continue
		}
		for name, v := range ov[id] {
			if _, ok := vals[name]; ok {
				vals[name] = v
			}
		}
		out = append(out, source{env: env, vals: vals})
	}
	return out
}
