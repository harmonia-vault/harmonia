package main

// 检查结果的本机缓存、升级步骤、后台服务的自动升级与每天一次的更新提示（docs/rewrite-plan.md 5.11）。

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

	"golang.org/x/term"

	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/service"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
	"github.com/harmonia-vault/harmonia/cli/internal/update"
)

func loadUpdateCache() update.Cache {
	var c update.Cache
	if data, err := os.ReadFile(stateFile("update.json")); err == nil {
		_ = json.Unmarshal(data, &c)
	}
	return c
}

func saveUpdateCache(c update.Cache) {
	data, _ := json.Marshal(c)
	_ = state.WriteAtomic(stateFile("update.json"), data)
}

// saveChecked 记下一次检查的结果，保留提示时间。
func saveChecked(ch update.Channel, latest string) {
	c := loadUpdateCache()
	c.Channel, c.Latest, c.CheckedAt = string(ch), latest, time.Now().UnixMilli()
	if !update.Newer(latest, version) {
		c.Failed, c.FailedAt = "", 0
	}
	saveUpdateCache(c)
}

// installVersion 下载新版本，验证签名和哈希，运行它的 version 自检，再替换当前程序。返回程序路径。
func installVersion(ctx context.Context, m *update.Manifest) (string, error) {
	key := fmt.Sprintf("cli-%s-%s", runtime.GOOS, runtime.GOARCH)
	asset, ok := m.Assets[key]
	if !ok {
		return "", fmt.Errorf("新版本没有提供 %s/%s 的安装包", runtime.GOOS, runtime.GOARCH)
	}
	bin, err := executable()
	if err != nil {
		return "", err
	}
	data, err := update.Download(ctx, asset)
	if err != nil {
		return "", err
	}
	tmp := filepath.Join(filepath.Dir(bin), newProgramName)
	if err := os.WriteFile(tmp, data, 0o755); err != nil {
		return "", fmt.Errorf("无法写入 %s：%w", filepath.Dir(bin), err)
	}
	defer os.Remove(tmp)
	out, err := exec.Command(tmp, "version").Output()
	if err != nil || !strings.Contains(string(out), m.Version) {
		return "", errors.New("新版本自检失败，已放弃升级，当前版本保持不变")
	}
	if err := swapProgram(tmp, bin); err != nil {
		return "", fmt.Errorf("替换程序失败：%w", err)
	}
	return bin, nil
}

// autoUpdateOn 读取本机缓存里的“自动更新”开关（随同步更新）。
func autoUpdateOn() bool {
	d, err := state.Open()
	if err != nil {
		return false
	}
	c, err := d.Cache()
	return err == nil && c.AutoUpdate
}

// backgroundCheck 由后台服务调用：检查更新，并在需要时升级。force 为 true 表示手机要求更新，
// 不论自动更新是否开启都升级。返回 true 表示程序已被替换，后台服务应当退出，由系统用新程序重新启动。
func backgroundCheck(ctx context.Context, logf func(string, ...any), force bool) bool {
	if version == "dev" {
		return false
	}
	ch := updateChannel()
	m, err := update.Fetch(ctx, ch)
	if err != nil {
		logf("检查更新失败：%v", err)
		return false
	}
	saveChecked(ch, m.Version)
	if !update.Newer(m.Version, version) {
		if force {
			logf("收到更新请求，已是最新版本（%s）", version)
		}
		return false
	}
	if !force && !autoUpdateOn() {
		return false
	}
	reason := "自动更新"
	if force {
		reason = "收到更新请求"
	}
	logf("%s：开始升级到 %s（当前 %s）", reason, m.Version, version)
	if _, err := installVersion(ctx, m); err != nil {
		c := loadUpdateCache()
		c.Failed, c.FailedAt = err.Error(), time.Now().UnixMilli()
		saveUpdateCache(c)
		logf("升级失败：%v", err)
		return false
	}
	logf("已升级到 %s，后台服务将以新版本重新启动", m.Version)
	return true
}

// autoUpdateSummary 是 status 和 update auto 里显示的开关状态。
func autoUpdateSummary(a *app.App) string {
	c, err := a.Dir.Cache()
	switch {
	case err != nil || !c.AutoUpdate:
		return "未开启（运行 harmonia update auto on 开启）"
	case !service.Check().Installed:
		return "已开启，但没有安装后台服务，不会生效（运行 harmonia service install）"
	}
	return "已开启"
}

// updateNotes 是 status 里关于更新的说明：有新版本，或者上次自动升级失败。
func updateNotes() []string {
	c := loadUpdateCache()
	ch := updateChannel()
	var notes []string
	if latest := c.Available(ch, version); latest != "" {
		notes = append(notes, fmt.Sprintf("有新版本 %s 可用，运行 harmonia update 升级。", latest))
		if c.Failed != "" {
			notes = append(notes, fmt.Sprintf("后台服务上次自动升级失败（%s）：%s。可以运行 harmonia update 手动升级。",
				time.UnixMilli(c.FailedAt).Format("01-02 15:04"), sentence(c.Failed)))
		}
	}
	return notes
}

// noHint 是不在输出之后提示新版本的命令：它们自己处理更新，或者输出要原样交给别处。
var noHint = map[string]bool{"update": true, "version": true, "skill": true, "daemon": true, "status": true, "uninstall": true, "logout": true}

// dailyHint 在 stderr 是终端时每天最多提示一次有新版本；脚本、管道和 AI 助手调用时不提示。
// 自动更新已开启并且装了后台服务时交给后台服务，不提示。
func dailyHint(command string) {
	if noHint[command] || !term.IsTerminal(int(os.Stderr.Fd())) {
		return
	}
	c := loadUpdateCache()
	ch := updateChannel()
	now := time.Now()
	if !c.ShouldHint(ch, version, now) {
		return
	}
	if autoUpdateOn() && service.Check().Installed {
		return
	}
	c.HintedAt = now.UnixMilli()
	saveUpdateCache(c)
	fmt.Fprintf(os.Stderr, "\nharmonia：有新版本 %s 可用（当前 %s），运行 harmonia update 升级，或运行 harmonia update auto on 开启自动更新。\n",
		c.Latest, version)
}

// startStaleCheck 在本机的检查结果过期时（通常是没有安装后台服务）在后台检查一次更新，
// 和读取前的同步同时进行。返回的函数等待检查结束，最多等到 ctx 结束；失败时不提示。
func startStaleCheck(ctx context.Context) (wait func()) {
	ch := updateChannel()
	if version == "dev" || !loadUpdateCache().Stale(ch, time.Now()) {
		return func() {}
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		if m, err := update.Fetch(ctx, ch); err == nil {
			saveChecked(ch, m.Version)
		}
	}()
	return func() {
		select {
		case <-done:
		case <-ctx.Done():
		}
	}
}
