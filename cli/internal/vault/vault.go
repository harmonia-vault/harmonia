// Package vault 把同步结果写入本机缓存，并计算最终生效的环境变量。
package vault

import (
	"errors"
	"fmt"
	"maps"
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
		if err1 != nil || err2 != nil || err3 != nil || !hc.Verify(root, hc.EnvelopeMsg(e.VaultID, kv, deviceID, sealed), sig) {
			return errors.New("服务器下发的环境密钥签名无效，已停止同步。请确认服务器地址是否正确")
		}
	}
	var managers []api.ManagerKey
	for _, m := range s.Managers {
		cert, err := hc.UnB64(m.Cert)
		if err != nil || !hc.Verify(root, hc.DeviceCertMsg(m.ID, "manager", m.SignPub, m.BoxPub), cert) {
			return errors.New("服务器下发的管理设备证书无效，已停止同步。请确认服务器地址是否正确")
		}
		managers = append(managers, m)
	}
	// Variables 按变量库保存（键是变量库里的原名）；只保存能在本机解密的变量库。
	visible := map[string]bool{}
	for _, v := range s.Vaults {
		visible[v.ID] = true
	}
	if since == 0 || s.Full {
		c.Variables = map[string]map[string]state.CachedVar{}
	}
	for id := range c.Variables {
		if !visible[id] {
			delete(c.Variables, id)
		}
	}
	for _, v := range s.Variables {
		if !visible[v.VaultID] {
			continue
		}
		m := c.Variables[v.VaultID]
		if m == nil {
			m = map[string]state.CachedVar{}
			c.Variables[v.VaultID] = m
		}
		if v.Deleted {
			delete(m, v.Name)
			continue
		}
		kv, _ := strconv.Atoi(v.KeyVersion)
		m[v.Name] = state.CachedVar{Value: v.Value, KeyVersion: kv}
	}
	c.Environments = s.Environments
	c.VaultNames = s.VaultNames
	c.Envelopes = s.Envelopes
	c.Managers = managers
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

// VaultKey 解开某个变量库的库钥。
func VaultKey(c *state.Cache, k *state.DeviceKeys, vaultID string) ([]byte, int, error) {
	for _, e := range c.Envelopes {
		if e.VaultID != vaultID {
			continue
		}
		sealed, err := hc.UnB64(e.Sealed)
		if err != nil {
			return nil, 0, err
		}
		key, err := k.Box.Open(sealed)
		if err != nil || len(key) != 32 {
			return nil, 0, errors.New("无法解开变量库的密钥，请在管理设备上重新授权这台设备")
		}
		kv, _ := strconv.Atoi(e.KeyVersion)
		return key, kv, nil
	}
	return nil, 0, errors.New("这台设备没有这个变量库的密钥，请在管理设备上重新授权这台设备")
}

// VaultEntries 解密本机缓存里某个变量库的变量（键是变量库里的原名）。只包含这台设备能在本机解密的变量。
func VaultEntries(c *state.Cache, k *state.DeviceKeys, vaultID string) (map[string]hc.Entry, []string, error) {
	key, _, err := VaultKey(c, k, vaultID)
	if err != nil {
		return nil, nil, err
	}
	out := map[string]hc.Entry{}
	var broken []string
	for name, v := range c.Variables[vaultID] {
		e, err := hc.DecryptVar(key, vaultID, v.KeyVersion, name, v.Value)
		if err != nil {
			broken = append(broken, name)
			continue
		}
		out[name] = e
	}
	sort.Strings(broken)
	return out, broken, nil
}

// ErrNeedApproval 说明这个环境没有开启本机解密，变量值要经手机批准才能拿到。
type ErrNeedApproval struct{ Env string }

func (e *ErrNeedApproval) Error() string {
	return fmt.Sprintf("环境“%s”的变量要在手机上批准后才能使用，harmonia exec、export 会自动请求", e.Env)
}

// Entries 解密一个环境的全部变量（值和备注），键是环境里的名字。解不开的变量不放进结果，
// 名称按顺序列在 broken 里，它们仍然可以删除或重新写入。
func Entries(c *state.Cache, k *state.DeviceKeys, envID string) (map[string]hc.Entry, []string, error) {
	env := byID(c, envID)
	if env == nil {
		return nil, nil, fmt.Errorf("环境 %s 已不可访问（授权可能已被撤销）", envID)
	}
	if !env.LocalDecrypt {
		return nil, nil, &ErrNeedApproval{Env: env.Name}
	}
	decrypted := map[string]map[string]hc.Entry{}
	out := map[string]hc.Entry{}
	var broken []string
	for _, it := range env.Items {
		vals, ok := decrypted[it.VaultID]
		if !ok {
			var err error
			if vals, _, err = VaultEntries(c, k, it.VaultID); err != nil {
				return nil, nil, err
			}
			decrypted[it.VaultID] = vals
		}
		if e, ok := vals[it.Source]; ok {
			out[it.Name] = e
		} else if _, cached := c.Variables[it.VaultID][it.Source]; cached {
			broken = append(broken, it.Name)
		}
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

func byID(c *state.Cache, envID string) *api.Environment {
	for i := range c.Environments {
		if c.Environments[i].ID == envID {
			return &c.Environments[i]
		}
	}
	return nil
}

// HasItem 判断环境里有没有这个名字的变量。
func HasItem(env *api.Environment, name string) bool {
	for _, it := range env.Items {
		if it.Name == name {
			return true
		}
	}
	return false
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
	if !env.LocalDecrypt {
		return (&ErrNeedApproval{Env: env.Name}).Error()
	}
	for _, it := range env.Items {
		if _, _, err := VaultKey(c, k, it.VaultID); err != nil {
			return fmt.Sprintf("环境“%s”：%v", env.Name, err)
		}
	}
	return ""
}

// sources 按 ids 顺序解出各环境的变量（已套用本地覆盖）；拿不到的环境不放进结果，原因记在 problems 里。
// 没有开启本机解密的环境用 remote 里经手机批准取得的值。
func sources(c *state.Cache, k *state.DeviceKeys, ids []string, ov state.Overrides, remote Remote, nowMs int64) ([]source, map[string]string) {
	problems := map[string]string{}
	var out []source
	for _, id := range ids {
		env := byID(c, id)
		if env == nil {
			problems[id] = fmt.Sprintf("环境 %s 已不可访问（授权可能已被撤销）", id)
			continue
		}
		var vals map[string]string
		var broken []string
		got, fromRemote := remote[id]
		if fromRemote && !env.LocalDecrypt && !Expired(*env, nowMs) {
			vals = maps.Clone(got)
		} else if p := Unavailable(c, k, *env, nowMs); p != "" {
			problems[id] = p
			continue
		} else {
			var err error
			if vals, broken, err = Values(c, k, id); err != nil {
				problems[id] = fmt.Sprintf("环境“%s”：%v", env.Name, err)
				continue
			}
		}
		// 有本机覆盖值的变量不会向手机请求，所以经手机批准的环境按环境里的名字套用。
		for name, v := range ov[id] {
			if _, ok := vals[name]; ok || (fromRemote && HasItem(env, name)) {
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
