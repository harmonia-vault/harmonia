package app

import (
	"fmt"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

// WriteNotice 是写入前要让用户确认的提示：修改或删除已有变量时，写的是变量库里的原变量，
// 引用它的所有环境都会看到变化（设计文档 17.2）。新增变量、或无法确定位置时返回空，由写入时报错。
func (a *App) WriteNotice(target, name string, del bool) string {
	cache, err := a.Dir.Cache()
	if err != nil {
		return ""
	}
	t, err := vault.ResolveTarget(cache, target, false)
	if err != nil {
		return ""
	}
	d, err := vault.WriteDest(cache, t, name, nowMs())
	if err != nil {
		return ""
	}
	// 没有开启本机解密时没有变量的密文，按环境里有没有这个变量判断是不是修改已有变量。
	if _, ok := cache.Variables[d.VaultID][d.Source]; !ok && (!d.Remote() || d.Name == "") {
		return ""
	}
	verb := "修改"
	if del {
		verb = "删除"
	}
	return fmt.Sprintf("将%s变量库“%s”里的 %s，所有引用它的环境都会看到这个变化", verb, vaultName(cache, d.VaultID), d.Source)
}

func vaultName(c *state.Cache, id string) string {
	for _, v := range c.VaultNames {
		if v.ID == id {
			return v.Name
		}
	}
	return id
}

// Shadowing 检查不带 --env 的 harmonia exec 能不能拿到刚写入的变量：环境没有启用、有本机覆盖值、
// 被排在前面的环境的同名变量遮住时，各返回一句提示和处理办法。target 是写入时指定的环境或变量库；
// 写的是变量库时，检查这台设备上包含这个变量的每个环境。
func (a *App) Shadowing(target, name string) ([]string, error) {
	cache, err := a.Dir.Cache()
	if err != nil {
		return nil, err
	}
	t, err := vault.ResolveTarget(cache, target, false)
	if err != nil {
		return nil, err
	}
	ov, err := a.Dir.Overrides()
	if err != nil {
		return nil, err
	}
	if t.Env != nil {
		return shadowNotes(cache, ov, *t.Env, name), nil
	}
	var notes []string
	for _, e := range vault.Ordered(cache) {
		for _, it := range e.Items {
			if it.VaultID == t.VaultID && it.Source == name {
				notes = append(notes, shadowNotes(cache, ov, e, it.Name)...)
			}
		}
	}
	return notes, nil
}

func shadowNotes(cache *state.Cache, ov state.Overrides, env api.Environment, name string) []string {
	if !env.Active {
		return []string{fmt.Sprintf("环境“%s”没有启用，不带 --env 的 harmonia exec 拿不到 %s。运行 harmonia env activate %s 启用，或用 harmonia exec --env %s 指定它", env.Name, name, env.ID, env.ID)}
	}
	var notes []string
	if _, ok := ov[env.ID][name]; ok {
		notes = append(notes, fmt.Sprintf("这台设备为环境“%s”的 %s 设置了本机覆盖值，harmonia exec 拿到的是覆盖值。运行 harmonia override rm %s %s 移除", env.Name, name, env.ID, name))
	}
	now := nowMs()
	for _, e := range vault.Ordered(cache) {
		if e.ID == env.ID {
			break
		}
		if !e.Active || vault.Expired(e, now) {
			continue
		}
		if vault.HasItem(&e, name) {
			notes = append(notes, fmt.Sprintf("排在前面的环境“%s”也有 %s，不带 --env 的 harmonia exec 拿到的是“%s”中的值。运行 harmonia env order %s 把“%s”移到最前面", e.Name, name, e.Name, env.ID, env.Name))
			break
		}
	}
	return notes
}
