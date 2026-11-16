package app

import (
	"context"
	"errors"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/shell"
)

// SetShellEnabled 修改手机与本机共用的开关，再同步应用。
func (a *App) SetShellEnabled(ctx context.Context, on bool) error {
	if err := a.Client.Device(ctx, "PATCH", "/api/v1/devices/self", map[string]any{"shellEnabled": on}, nil, nil); err != nil {
		return a.HandleRevoked(err)
	}
	return a.Sync(ctx)
}

// 上报执行结果而不回传路径、变量或底层错误；详细错误仍由本机命令输出。
func (a *App) reportShellState(ctx context.Context, on bool, applyErr error, previous *api.ShellState) error {
	result := api.ShellState{Enabled: on}
	if applyErr != nil {
		message := "无法更新自动加载的变量，请在电脑上运行 harmonia sync 查看原因并重试。"
		if errors.Is(applyErr, shell.ErrNotReady) {
			message = "请在电脑上运行 harmonia shell install 完成配置，再运行 harmonia sync。"
		}
		result.Error = &message
	}
	if previous != nil && previous.Enabled == result.Enabled && sameShellError(previous.Error, result.Error) {
		return nil
	}
	return a.Client.Device(ctx, "POST", "/api/v1/devices/self/shell-state", result, nil, nil)
}

func sameShellError(a, b *string) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}
