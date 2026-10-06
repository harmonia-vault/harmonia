package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/service"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
	"github.com/harmonia-vault/harmonia/cli/internal/update"
)

type updateCache struct {
	Latest    string `json:"latest"`
	CheckedAt int64  `json:"checkedAt"`
}

func updateCachePath() string {
	d, err := state.Open()
	if err != nil {
		return ""
	}
	return d.File("update.json")
}

// updateHint 只读取后台服务缓存的检查结果，不发起网络请求。
func updateHint() string {
	data, err := os.ReadFile(updateCachePath())
	if err != nil {
		return ""
	}
	var c updateCache
	if json.Unmarshal(data, &c) != nil || !update.Newer(c.Latest, version) {
		return ""
	}
	return fmt.Sprintf("有新版本 %s 可用，运行 harmonia update 升级。", c.Latest)
}

// dailyUpdateCheck 由后台服务每天调用一次。
func dailyUpdateCheck(ctx context.Context, logf func(string, ...any)) {
	if version == "dev" {
		return
	}
	select {
	case <-ctx.Done():
		return
	case <-time.After(time.Duration(time.Now().UnixNano()%600) * time.Second):
	}
	m, err := update.Fetch(ctx)
	if err != nil {
		logf("检查更新失败：%v", err)
		return
	}
	data, _ := json.Marshal(updateCache{Latest: m.Version, CheckedAt: time.Now().UnixMilli()})
	_ = state.WriteAtomic(updateCachePath(), data)
}

func cmdUpdate(ctx context.Context, args []string) error {
	f, err := parseFlags(args)
	if err != nil {
		return err
	}
	fmt.Println("正在检查更新……")
	m, err := update.Fetch(ctx)
	if err != nil {
		return err
	}
	if !update.Newer(m.Version, version) {
		fmt.Printf("已是最新版本（%s）。\n", version)
		return nil
	}
	fmt.Printf("发现新版本 %s（当前 %s）。\n", m.Version, version)
	if m.Notes != "" {
		fmt.Println(m.Notes)
	}
	if f.bools["check"] {
		return nil
	}
	key := fmt.Sprintf("cli-%s-%s", runtime.GOOS, runtime.GOARCH)
	asset, ok := m.Assets[key]
	if !ok {
		return fmt.Errorf("新版本没有提供 %s/%s 的安装包", runtime.GOOS, runtime.GOARCH)
	}
	bin, err := executable()
	if err != nil {
		return err
	}
	fmt.Println("正在下载……")
	data, err := update.Download(ctx, asset)
	if err != nil {
		return err
	}
	tmp := filepath.Join(filepath.Dir(bin), ".harmonia-new")
	if err := os.WriteFile(tmp, data, 0o755); err != nil {
		return fmt.Errorf("无法写入 %s：%w", filepath.Dir(bin), err)
	}
	defer os.Remove(tmp)
	out, err := exec.Command(tmp, "version").Output()
	if err != nil || !strings.Contains(string(out), m.Version) {
		return errors.New("新版本自检失败，已放弃升级，当前版本保持不变")
	}
	_ = os.Remove(bin + ".old")
	if err := os.Link(bin, bin+".old"); err != nil {
		_ = copyFile(bin, bin+".old")
	}
	if err := os.Rename(tmp, bin); err != nil {
		return fmt.Errorf("替换程序失败：%w", err)
	}
	if err := service.Restart(); err != nil {
		fmt.Println("注意：", err)
	}
	fmt.Printf("已升级到 %s。旧版本保留在 %s.old。\n", m.Version, bin)
	return nil
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o755)
}
