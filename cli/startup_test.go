//go:build !windows

package installer_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/shell"
)

func TestNewProgramPreparesIntegrationOnFirstUse(t *testing.T) {
	binary := installerBinary(t)
	for _, command := range []string{"status", "daemon"} {
		t.Run(command, func(t *testing.T) {
			home := t.TempDir()
			data := filepath.Join(home, ".harmonia")
			bin := filepath.Join(home, "harmonia")
			if err := os.WriteFile(bin, binary, 0o700); err != nil {
				t.Fatal(err)
			}
			env := []string{"HOME=" + home, "HARMONIA_HOME=" + data, "ZDOTDIR=" + home, "SHELL=/bin/bash", "PATH=" + os.Getenv("PATH")}
			// 旧更新器只对新二进制执行 version 自检，再替换；自检不修改终端配置。
			for _, args := range [][]string{{"version"}, {"help"}, {"status", "--help"}} {
				cmd := exec.Command(bin, args...)
				cmd.Env = env
				if out, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("%v: %v %s", args, err, out)
				}
				if _, err := os.Stat(filepath.Join(home, ".bashrc")); !os.IsNotExist(err) {
					t.Fatal("信息查询不应配置终端")
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, bin, command)
			cmd.Env = env
			out, err := cmd.CombinedOutput()
			if command == "status" && err != nil {
				t.Fatalf("首次运行失败：%v %s", err, out)
			}
			if command == "daemon" && ctx.Err() == nil {
				t.Fatalf("后台服务提前退出：%v %s", err, out)
			}
			envFile := filepath.Join(data, "env.sh")
			if err := shell.Ready(envFile); err != nil {
				t.Fatalf("新程序未自动准备集成：%v %s", err, out)
			}
			if _, err := os.Stat(envFile); !os.IsNotExist(err) {
				t.Fatal("未开启时不应生成变量文件")
			}
		})
	}
}
