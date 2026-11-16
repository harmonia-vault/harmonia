//go:build !windows

package app

import (
	"bytes"
	"errors"
	"os"

	"github.com/harmonia-vault/harmonia/cli/internal/shell"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// publish 把生效的变量写入 env.sh，返回是否有变化。没有开启 Shell 集成时不保留明文副本，删除 env.sh。
func publish(d *state.Dir, cache *state.Cache, vars map[string]string) (bool, error) {
	if !cache.ShellEnabled {
		return removeEnvFile(d)
	}
	if err := shell.Ready(d.EnvFile()); err != nil {
		changed, cleanupErr := removeEnvFile(d)
		return changed, errors.Join(err, cleanupErr)
	}
	data := shell.Render(vars)
	old, _ := os.ReadFile(d.EnvFile())
	if bytes.Equal(old, data) {
		return false, nil
	}
	return true, state.WriteAtomic(d.EnvFile(), data)
}

// unpublish 删除 env.sh，已启用 Shell 集成的终端在下一次提示符出现时恢复原状。
func unpublish(d *state.Dir) error {
	_, err := removeEnvFile(d)
	return err
}

func removeEnvFile(d *state.Dir) (bool, error) {
	err := os.Remove(d.EnvFile())
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

// systemVariable 判断变量是否是系统自带的、导入时不应列出；macOS、Linux 的名单在 ImportCandidates 中。
func systemVariable(string) bool { return false }
