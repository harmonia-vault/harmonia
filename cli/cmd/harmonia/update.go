package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/service"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
	"github.com/harmonia-vault/harmonia/cli/internal/update"
)

// settings 是与账号无关的本机设置，退出登录时保留。
type settings struct {
	UpdateChannel string   `json:"updateChannel,omitempty"`
	SkillFiles    []string `json:"skillFiles,omitempty"` // harmonia skill install 写入过的技能文件
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

func saveSettings(s settings) error {
	data, _ := json.Marshal(s)
	return state.WriteAtomic(stateFile("settings.json"), data)
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
	s := loadSettings()
	s.UpdateChannel = string(ch)
	if err := saveSettings(s); err != nil {
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
	if len(args) > 0 && args[0] == "auto" {
		return cmdUpdateAuto(ctx, args[1:])
	}
	f, err := parseFlags(args, "check")
	if err != nil {
		return err
	}
	if len(f.args) > 0 {
		return usageError("不认识的参数 " + f.args[0])
	}
	ch := updateChannel()
	fmt.Printf("正在检查更新（%s渠道）……\n", ch.Label())
	m, err := update.Fetch(ctx, ch)
	if err != nil {
		return err
	}
	saveChecked(ch, m.Version)
	if !update.Newer(m.Version, version) {
		fmt.Printf("已是最新版本（%s）。\n", version)
		return nil
	}
	fmt.Printf("发现新版本 %s（当前 %s）。\n", m.Version, version)
	if m.Notes != "" {
		fmt.Println(m.Notes)
	}
	switch err := checkProtocol(ctx, m); {
	case errors.Is(err, errUnverified):
		fmt.Println("注意：" + sentence(err.Error()) + "1.0 之前各版本之间不保证兼容，升级后如果连不上服务器，请同时更新服务器。")
	case err != nil:
		return err
	}
	if f.bools["check"] {
		return nil
	}
	fmt.Println("正在下载……")
	bin, err := installVersion(ctx, m)
	if err != nil {
		return err
	}
	if err := service.Restart(); err != nil {
		fmt.Println("注意：", err)
	}
	fmt.Printf("已升级到 %s。旧版本保留在 %s.old。\n", m.Version, bin)
	syncSkillFiles(func(s string) { fmt.Println(s) })
	fmt.Println("如果是 AI 助手在操作，请运行 harmonia skill 重新读取使用说明。")
	return nil
}

func cmdUpdateAuto(ctx context.Context, args []string) error {
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	if len(args) == 0 {
		if err := refresh(ctx, a); err != nil {
			return err
		}
		fmt.Printf("自动更新：%s。修改：harmonia update auto on|off（也可以在手机的设备详情里修改）\n", autoUpdateSummary(a))
		return nil
	}
	if len(args) > 1 || (args[0] != "on" && args[0] != "off") {
		return usageError("用法：harmonia update auto [on|off]")
	}
	on := args[0] == "on"
	if err := a.SetAutoUpdate(ctx, on); err != nil {
		return err
	}
	if !on {
		fmt.Println("已关闭自动更新。有新版本时会提示，运行 harmonia update 升级。")
		return nil
	}
	fmt.Println("已开启自动更新：后台服务每天检查一次，发现新版本直接升级。")
	if !service.Check().Installed {
		fmt.Println("这台电脑还没有安装后台服务，自动更新不会生效。运行 harmonia service install 安装。")
	}
	return nil
}

// errUnverified 表示升级前没能连上服务器，无法确认新版本和服务器兼容。
var errUnverified = errors.New("没能连上服务器，无法确认新版本和服务器兼容")

// checkProtocol 是升级前的兼容预检：向这台电脑接入的服务器（日常身份和管理登录）查询协议版本，
// 和新版本清单里的 protocol 比较。不一致时返回说明错误；连不上服务器时返回 errUnverified；
// 没有接入任何服务器时不需要检查。1.0 之前各版本之间不保证兼容，1.0 起它是兼容闸。
func checkProtocol(ctx context.Context, m *update.Manifest) error {
	if m.Protocol == 0 {
		return nil
	}
	d, err := state.Open()
	if err != nil {
		return err
	}
	servers := map[string]bool{}
	if cfg, err := d.Config(); err == nil && cfg.Paired() {
		servers[cfg.Server] = true
	}
	if mf, err := d.Manager(); err == nil && mf != nil {
		servers[mf.Server] = true
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	unverified := false
	for server := range servers {
		inst, err := api.New(server).InstanceInfo(ctx)
		if err != nil {
			unverified = true
			continue
		}
		if inst.Protocol != m.Protocol {
			return fmt.Errorf("新版本 %s 使用协议 %d，服务器 %s 使用协议 %d（服务器版本 %s），升级后将无法使用。请先更新服务器，再运行 harmonia update",
				m.Version, m.Protocol, server, inst.Protocol, inst.Version)
		}
	}
	if unverified {
		return errUnverified
	}
	return nil
}
