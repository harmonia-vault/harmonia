package app

import (
	"context"

	"github.com/harmonia-vault/harmonia/cli/internal/state"
	"github.com/harmonia-vault/harmonia/cli/internal/sysenv"
)

func sysenvFile(d *state.Dir) string { return d.File("sysenv.json") }

// publish 让用户环境变量与生效的变量一致，返回是否有变化。开关关闭时只恢复之前写入的变量。
func publish(d *state.Dir, cache *state.Cache, vars map[string]string) (bool, error) {
	rec, err := sysenv.Load(sysenvFile(d))
	if err != nil {
		return false, err
	}
	var want map[string]string
	if rec.Enabled {
		want, _ = sysenv.Select(vars, cache.SystemVars)
	}
	changed, err := sysenv.Apply(sysenv.User, rec, want, func() error { return rec.Save(sysenvFile(d)) })
	if changed {
		sysenv.Notify()
	}
	return changed, err
}

// unpublish 把写入的用户环境变量全部恢复成接管之前的样子。
func unpublish(d *state.Dir) error {
	_, err := publish(d, &state.Cache{}, nil)
	return err
}

// SystemEnv 是“写入用户环境变量”的现状。
type SystemEnv struct {
	Enabled    bool
	SystemVars bool // 这台设备的“写入系统变量”开关
	Written    int
	Skipped    []sysenv.Skip
}

// SystemEnv 返回开关状态，以及按当前生效的变量会写入多少个、哪些不会写入。
func (a *App) SystemEnv() (*SystemEnv, error) {
	rec, err := sysenv.Load(sysenvFile(a.Dir))
	if err != nil {
		return nil, err
	}
	out := &SystemEnv{Enabled: rec.Enabled}
	if a.Keys == nil {
		return out, nil
	}
	cache, err := a.Dir.Cache()
	if err != nil {
		return nil, err
	}
	vars, _, err := a.Effective()
	if err != nil {
		return nil, err
	}
	want, skipped := sysenv.Select(vars, cache.SystemVars)
	out.SystemVars, out.Written, out.Skipped = cache.SystemVars, len(want), skipped
	return out, nil
}

// SetSystemEnv 开启或关闭“写入用户环境变量”。关闭时把写入的变量恢复原状；还没有接入账号时只记下开关。
func (a *App) SetSystemEnv(on bool) error {
	unlock, err := a.Dir.Lock()
	if err != nil {
		return err
	}
	defer unlock()
	rec, err := sysenv.Load(sysenvFile(a.Dir))
	if err != nil {
		return err
	}
	rec.Enabled = on
	if err := rec.Save(sysenvFile(a.Dir)); err != nil {
		return err
	}
	if a.Keys == nil {
		return unpublish(a.Dir)
	}
	cache, err := a.Dir.Cache()
	if err != nil {
		return err
	}
	_, err = a.writeEnvLocked(cache)
	return err
}

// SetSystemVars 修改这台设备的“写入系统变量”开关（保存在服务端，需要联网），再同步一次让它生效。
func (a *App) SetSystemVars(ctx context.Context, on bool) error {
	return a.patchSelf(ctx, map[string]any{"systemVars": on})
}

// systemVariable 判断变量是否是 Windows 自带的，导入时不列出。
func systemVariable(name string) bool { return sysenv.IsSystem(name) }
