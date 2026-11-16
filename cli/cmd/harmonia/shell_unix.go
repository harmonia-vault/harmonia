//go:build !windows

// macOS、Linux 上让终端读到变量的办法：在 shell 启动文件中加载 env.sh，并在提示符出现前刷新。
package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/shell"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// 各处提到这项功能时用的文字。
const (
	shellLabel       = "Shell 集成"
	shellCost        = "开启后，你打开的每个终端都带着允许本机解密的环境中的变量，这个用户运行的任何程序都能读到；本机还会留一份明文变量文件。多数情况下用 harmonia exec -- <命令> 只把变量交给要用的程序就够了。"
	shellOnNote      = "Shell 集成已开启：变量对这个用户的所有程序可见，本机留有明文变量文件。不需要时运行 harmonia shell off 关闭，改用 harmonia exec -- <命令>。"
	logoutNotice     = "已启用 Shell 集成的终端会在下一次命令提示符出现时清理变量。"
	uninstallSummary = "退出账号、移除后台服务和 shell 集成，并删除 harmonia"
)

var shellHelp = [][2]string{
	{"shell install [--shell zsh|bash]", "准备终端的变量加载设置，不开启自动加载"},
	{"shell on [--yes]", "开启 Shell 集成；也可以在手机设备详情中开启"},
	{"shell off", "关闭 Shell 集成并清理自动加载的变量"},
}

func shellSummary(a *app.App) string {
	cache, err := a.Dir.Cache()
	if err != nil {
		return "无法读取（" + err.Error() + "）"
	}
	if !cache.ShellEnabled {
		return "未开启"
	}
	if err := shell.Ready(a.Dir.EnvFile()); err != nil {
		return "尚未生效：" + err.Error()
	}
	return "已开启"
}

func cmdShell(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "shell=", "yes")
	if err != nil {
		return err
	}
	if len(f.args) != 1 {
		return errors.New("用法：harmonia shell install [--shell zsh|bash]，或 harmonia shell on|off")
	}
	if f.args[0] == "install" {
		return prepareShell(f.values["shell"])
	}
	if f.args[0] != "on" && f.args[0] != "off" {
		return errors.New("用法：harmonia shell install，或 harmonia shell on|off")
	}
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	on := f.args[0] == "on"
	if on {
		if err := ensureShellIntegration(); err != nil {
			return err
		}
	}
	if on && !f.bools["yes"] {
		fmt.Println(shellCost)
		if !confirm("开启 Shell 集成？") {
			fmt.Println("没有开启。")
			return nil
		}
	}
	if err := a.SetShellEnabled(ctx, on); err != nil {
		return err
	}
	if on {
		fmt.Println("已开启 Shell 集成，已加载集成的终端按一次回车后生效。")
	} else {
		fmt.Println("已关闭 Shell 集成，已加载集成的终端按一次回车后清理变量。")
	}
	return nil
}

func prepareShell(sh string) error {
	d, err := state.Open()
	if err != nil {
		return err
	}
	unlock, err := d.Lock()
	if err != nil {
		return err
	}
	defer unlock()
	if sh == "" {
		err = shell.Ensure(d.EnvFile())
	} else {
		home, homeErr := os.UserHomeDir()
		if homeErr != nil {
			return homeErr
		}
		targets, targetErr := shell.Targets(home, sh)
		if targetErr != nil {
			return targetErr
		}
		err = shell.Prepare(d.EnvFile(), targets)
	}
	if errors.Is(err, shell.ErrSymlink) {
		fmt.Println("启动文件是符号链接，请在对应文件中添加以下加载设置：")
		fmt.Print(shell.SourceLine(d.EnvFile()) + "\n")
	}
	if err != nil {
		return err
	}
	fmt.Println("已准备好 Shell 集成，可在手机的设备详情中开启。")
	fmt.Println("当前终端重新打开，或运行以下命令加载：")
	fmt.Printf("  . %s\n", shell.Quote(shell.IntegrationFile(d.EnvFile())))
	return nil
}

func removeIntegration(a *app.App) error {
	manual, err := shell.Remove(a.Dir.EnvFile())
	for _, path := range manual {
		fmt.Printf("%s 是符号链接，请手动删除其中 Harmonia 的加载设置。\n", path)
	}
	return err
}

func shellNotes(a *app.App) []string {
	cache, err := a.Dir.Cache()
	if err != nil || !cache.ShellEnabled {
		return nil
	}
	return append([]string{"", shellOnNote}, approvalNote(a, "Shell 集成")...)
}
