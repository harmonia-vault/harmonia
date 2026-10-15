//go:build !windows

package app

import (
	"os"
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/shell"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// 没有开启 Shell 集成时不生成 env.sh，已有的删除；开启后才写出变量。
func TestPublishOnlyWithShellIntegration(t *testing.T) {
	t.Setenv("HARMONIA_HOME", t.TempDir())
	d, err := state.Open()
	if err != nil {
		t.Fatal(err)
	}
	vars := map[string]string{"TOKEN": "secret"}
	if err := os.WriteFile(d.EnvFile(), shell.Render(vars), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := publish(d, nil, vars); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(d.EnvFile()); !os.IsNotExist(err) {
		t.Fatal("没有开启 Shell 集成时留下了 env.sh")
	}
	if err := os.WriteFile(shell.IntegrationFile(d.EnvFile()), []byte("# x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if changed, err := publish(d, nil, vars); err != nil || !changed {
		t.Fatalf("开启后应写出 env.sh：%v %v", changed, err)
	}
	if err := unpublish(d); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(d.EnvFile()); !os.IsNotExist(err) {
		t.Fatal("退出后 env.sh 应当删除")
	}
}
