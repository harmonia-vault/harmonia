package app

import (
	"fmt"

	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

// Shadowing 检查不带 --env 的 harmonia exec 拿到的是不是这个环境里的 name：环境没有启用、
// 有本机覆盖值、被排在前面的环境的同名变量遮住时，各返回一句提示和处理办法。
func (a *App) Shadowing(envNameOrID, name string) ([]string, error) {
	cache, err := a.Dir.Cache()
	if err != nil {
		return nil, err
	}
	env, err := vault.Find(cache, envNameOrID)
	if err != nil {
		return nil, err
	}
	if !env.Active {
		return []string{fmt.Sprintf("环境“%s”没有启用，不带 --env 的 harmonia exec 拿不到 %s。运行 harmonia env activate %s 启用，或用 harmonia exec --env %s 指定它", env.Name, name, env.ID, env.ID)}, nil
	}
	var notes []string
	ov, err := a.Dir.Overrides()
	if err != nil {
		return nil, err
	}
	if _, ok := ov[env.ID][name]; ok {
		notes = append(notes, fmt.Sprintf("这台设备为 %s 设置了本机覆盖值，harmonia exec 拿到的是覆盖值。运行 harmonia override rm %s %s 移除", name, env.ID, name))
	}
	now := nowMs()
	for _, e := range vault.Ordered(cache) {
		if e.ID == env.ID {
			break
		}
		if !e.Active || vault.Expired(e, now) {
			continue
		}
		if _, ok := cache.Variables[e.ID][name]; ok {
			notes = append(notes, fmt.Sprintf("排在前面的环境“%s”也有 %s，不带 --env 的 harmonia exec 拿到的是“%s”中的值。运行 harmonia env order %s 把“%s”移到最前面", e.Name, name, e.Name, env.ID, env.Name))
			break
		}
	}
	return notes, nil
}
