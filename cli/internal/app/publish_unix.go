//go:build !windows

package app

import (
	"bytes"
	"os"

	"github.com/harmonia-vault/harmonia/cli/internal/shell"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// publish 把生效的变量写入 env.sh，返回是否有变化。
func publish(d *state.Dir, _ *state.Cache, vars map[string]string) (bool, error) {
	data := shell.Render(vars)
	old, _ := os.ReadFile(d.EnvFile())
	if bytes.Equal(old, data) {
		return false, nil
	}
	return true, state.WriteAtomic(d.EnvFile(), data)
}

// unpublish 清空 env.sh，已启用 Shell 集成的终端随后清理变量。
func unpublish(d *state.Dir) error {
	return state.WriteAtomic(d.EnvFile(), []byte(state.EnvFileHeader+"\n"))
}

// systemVariable 判断变量是否是系统自带的、导入时不应列出；macOS、Linux 的名单在 ImportCandidates 中。
func systemVariable(string) bool { return false }
