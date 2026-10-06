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
	Channel   string `json:"channel"`
	Latest    string `json:"latest"`
	CheckedAt int64  `json:"checkedAt"`
}

// settings 是与账号无关的本机设置，退出登录时保留。
type settings struct {
	UpdateChannel string `json:"updateChannel"`
}

func stateFile(name string) string {
	d, err := state.Open()
	if err != nil {
		return ""
	}
	return d.File(name)
}

func loadSettings() settings {
	var s settings
	if data, err := os.ReadFile(stateFile("settings.json")); err == nil {
		_ = json.Unmarshal(data, &s)
	}
	return s
}

// updateChannel 返回当前更新渠道；测试版程序默认使用测试版渠道。
func updateChannel() update.Channel {
	if s := loadSettings().UpdateChannel; s != "" {
		if ch, err := update.ParseChannel(s); err == nil {
			return ch
		}
	}
	if update.IsPrerelease(version) {
		return update.Beta
	}
	return update.Stable
}

// updateHint 只读取后台服务缓存的检查结果，不发起网络请求。
func updateHint() string {
	data, err := os.ReadFile(stateFile("update.json"))
	if err != nil {
		return ""
	}
	var c updateCache
	if json.Unmarshal(data, &c) != nil || c.Channel != string(updateChannel()) || !update.Newer(c.Latest, version) {
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
	ch := updateChannel()
	m, err := update.Fetch(ctx, ch)
	if err != nil {
		logf("检查更新失败：%v", err)
		return
	}
	data, _ := json.Marshal(updateCache{Channel: string(ch), Latest: m.Version, CheckedAt: time.Now().UnixMilli()})
	_ = state.WriteAtomic(stateFile("update.json"), data)
}

func cmdUpdateChannel(args []string) error {
	if len(args) == 0 {
		ch := updateChannel()
		fmt.Printf("当前更新渠道：%s（%s）\n", ch.Label(), ch)
		fmt.Println("切换：harmonia update channel stable|beta")
		return nil
	}
	ch, err := update.ParseChannel(args[0])
	if err != nil {
		return err
	}
	data, _ := json.Marshal(settings{UpdateChannel: string(ch)})
	if err := state.WriteAtomic(stateFile("settings.json"), data); err != nil {
		return err
	}
	_ = os.Remove(stateFile("update.json"))
	fmt.Printf("已切换到%s渠道。", ch.Label())
	if ch == update.Beta {
		fmt.Println("测试版会先收到新功能，也可能不够稳定。运行 harmonia update 检查更新。")
	} else {
		fmt.Println("只会收到正式版本。")
		if update.IsPrerelease(version) {
			fmt.Printf("当前装的是测试版 %s，等正式版发布更高的版本后会提示升级。\n", version)
		}
	}
	return nil
}

func cmdUpdate(ctx context.Context, args []string) error {
	if len(args) > 0 && args[0] == "channel" {
		return cmdUpdateChannel(args[1:])
	}
	f, err := parseFlags(args)
	if err != nil {
		return err
	}
	ch := updateChannel()
	fmt.Printf("正在检查更新（%s渠道）……\n", ch.Label())
	m, err := update.Fetch(ctx, ch)
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
