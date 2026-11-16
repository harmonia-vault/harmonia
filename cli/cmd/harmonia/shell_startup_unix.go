//go:build !windows

package main

import (
	"context"
	"fmt"
	"os/exec"
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/shell"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

func ensureShellIntegration() error {
	d, err := state.Open()
	if err != nil {
		return err
	}
	unlock, err := d.Lock()
	if err != nil {
		return err
	}
	defer unlock()
	return shell.Ensure(d.EnvFile())
}

// 新程序执行自己的准备步骤，避免用旧版本的加载脚本覆盖新版本。
func prepareUpdatedShell(ctx context.Context, bin string) error {
	out, err := exec.CommandContext(ctx, bin, "shell", "install").CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s：%w", strings.TrimSpace(string(out)), err)
	}
	return nil
}
