package app

import (
	"context"
	"errors"
	"fmt"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
)

// SetAutoUpdate 修改这台设备的“自动更新”开关（保存在服务端，需要联网），再同步一次让它生效。
func (a *App) SetAutoUpdate(ctx context.Context, on bool) error {
	return a.patchSelf(ctx, map[string]any{"autoUpdate": on})
}

// patchSelf 修改这台设备在服务端的开关，再同步一次，本机缓存随之更新。
func (a *App) patchSelf(ctx context.Context, body map[string]any) error {
	err := a.Client.Device(ctx, "PATCH", "/api/v1/devices/self", body, nil, nil)
	var apiErr *api.Error
	if errors.As(err, &apiErr) && !errors.Is(err, api.ErrRevoked) && (apiErr.Status == 400 || apiErr.Status == 403 || apiErr.Status == 404) {
		return fmt.Errorf("服务器还不支持这个开关，请先把服务端更新到最新版本（%w）", err)
	}
	if err != nil {
		return a.HandleRevoked(err)
	}
	return a.Sync(ctx)
}
