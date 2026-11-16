//go:build !windows

package app

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/shell"
)

func TestShellSwitchSyncAndLocalDecrypt(t *testing.T) {
	d, server := fakeDevice(t, "测试电脑")
	a, err := Load(true)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := shell.Prepare(d.EnvFile(), []shell.Target{{Shell: "zsh", Path: filepath.Join(t.TempDir(), ".zshenv")}}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(d.EnvFile()); !os.IsNotExist(err) {
		t.Fatal("预装后不应生成变量文件")
	}
	if err := a.SetShellEnabled(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(d.EnvFile())
	if err != nil || !strings.Contains(string(data), "export A='旧值'") {
		t.Fatalf("未注入允许本机解密的环境：%s %v", data, err)
	}
	if server.shellState == nil || server.shellState.Error != nil || !server.shellState.Enabled {
		t.Fatalf("未回报开启结果：%+v", server.shellState)
	}
	// 服务端取消本机解密后，即使缓存里仍有密文与钥匙，自动加载也不能使用。
	server.envs[0].LocalDecrypt = false
	if err := a.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(d.EnvFile())
	if err != nil || strings.Contains(string(data), "export A=") {
		t.Fatalf("注入了需批准的环境：%s %v", data, err)
	}
	if err := a.SetShellEnabled(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(d.EnvFile()); !os.IsNotExist(err) {
		t.Fatal("关闭后变量文件未删除")
	}
	if err := shell.Ready(d.EnvFile()); err != nil {
		t.Fatalf("关闭后加载入口未保留：%v", err)
	}
	if server.shellState == nil || server.shellState.Enabled || server.shellState.Error != nil {
		t.Fatalf("未回报关闭结果：%+v", server.shellState)
	}
	server.envs[0].LocalDecrypt = true
	if err := a.SetShellEnabled(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(d.EnvFile())
	if err != nil || !strings.Contains(string(data), "export A='旧值'") {
		t.Fatalf("无法再次开启：%s %v", data, err)
	}
}

func TestShellUnpreparedReportsFailureAndCanTurnOff(t *testing.T) {
	d, server := fakeDevice(t, "测试电脑")
	a, err := Load(true)
	if err != nil {
		t.Fatal(err)
	}
	err = a.SetShellEnabled(context.Background(), true)
	if !errors.Is(err, shell.ErrNotReady) {
		t.Fatalf("缺少加载入口应失败：%v", err)
	}
	if server.shellState == nil || server.shellState.Error == nil {
		t.Fatal("没有回报失败")
	}
	if _, err := os.Stat(d.EnvFile()); !os.IsNotExist(err) {
		t.Fatal("未配置时不应留下明文变量")
	}
	if err := a.SetShellEnabled(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if server.shellState.Error != nil {
		t.Fatal("缺少入口不应阻止关闭")
	}
}

func TestShellMissingEntryClearsPreviouslyPublishedValues(t *testing.T) {
	d, server := fakeDevice(t, "测试电脑")
	a, err := Load(true)
	if err != nil {
		t.Fatal(err)
	}
	rc := filepath.Join(t.TempDir(), ".zshenv")
	if err := shell.Prepare(d.EnvFile(), []shell.Target{{Shell: "zsh", Path: rc}}); err != nil {
		t.Fatal(err)
	}
	if err := a.SetShellEnabled(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(d.EnvFile()); err != nil {
		t.Fatal(err)
	}
	// dotfiles 更新移除入口，同时手机取消本机解密；旧终端已经加载过脚本。
	if err := os.WriteFile(rc, []byte("# replaced\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	server.envs[0].LocalDecrypt = false
	if err := a.Sync(context.Background()); !errors.Is(err, shell.ErrNotReady) {
		t.Fatalf("应报告入口缺失：%v", err)
	}
	if _, err := os.Stat(d.EnvFile()); !os.IsNotExist(err) {
		t.Fatal("加载入口失效后仍保留旧变量")
	}
	if server.shellState == nil || server.shellState.Error == nil {
		t.Fatal("手机没有收到处理提示")
	}
}
