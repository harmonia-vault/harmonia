//go:build !windows

// macOS、Linux 上让终端读到变量的办法：在 shell 启动文件中加载 env.sh，并在提示符出现前刷新。
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/shell"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// 各处提到这项功能时用的文字。
const (
	shellLabel       = "Shell 集成"
	shellInstallHint = "在终端中自动加载和更新变量"
	shellOffNotice   = "提示：运行 harmonia shell install 启用终端变量。"
	logoutNotice     = "已启用 Shell 集成的终端会在下一次命令提示符出现时清理变量。"
	uninstallSummary = "退出账号、移除后台服务和 shell 集成，并删除 harmonia"
)

var shellHelp = [][2]string{
	{"shell install|uninstall", "在 shell 启动文件中加载变量（--shell zsh|bash 指定 shell）"},
}

func shellTargets(sh string) ([]shell.Target, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	return shell.Targets(home, sh)
}

func shellInstalledAny(a *app.App) bool {
	d := a.Dir
	for _, sh := range []string{"zsh", "bash"} {
		ts, _ := shellTargets(sh)
		for _, t := range ts {
			if shell.Installed(t.Path, d.EnvFile()) {
				return true
			}
		}
	}
	return false
}

func shellSummary(a *app.App) string {
	d := a.Dir
	var on []string
	for _, sh := range []string{"zsh", "bash"} {
		ts, _ := shellTargets(sh)
		for _, t := range ts {
			if shell.Installed(t.Path, d.EnvFile()) {
				on = append(on, t.Path)
			}
		}
	}
	if len(on) == 0 {
		return "未安装（运行 harmonia shell install）"
	}
	return "已安装：" + strings.Join(on, "、")
}

func cmdShell(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "shell")
	if err != nil {
		return err
	}
	if len(f.args) > 0 && f.args[0] == "system-vars" {
		return errors.New("这个开关只在 Windows 上使用；macOS 和 Linux 的 Shell 集成会加载全部变量")
	}
	if len(f.args) != 1 || (f.args[0] != "install" && f.args[0] != "uninstall") {
		return errors.New("用法：harmonia shell install|uninstall [--shell zsh|bash]")
	}
	d, err := state.Open()
	if err != nil {
		return err
	}
	sh := f.values["shell"]
	if sh == "" {
		sh = shell.Detect()
	}
	targets, err := shellTargets(sh)
	if err != nil {
		return err
	}
	if f.args[0] == "uninstall" {
		for _, t := range targets {
			if err := shell.Uninstall(t.Path); errors.Is(err, shell.ErrSymlink) {
				fmt.Printf("%s 是符号链接，请手动删除其中 Harmonia 的那几行。\n", t.Path)
			} else if err != nil {
				return err
			}
		}
		fmt.Println("已移除 shell 集成。新开的终端将不再加载 Harmonia 的变量。")
		return nil
	}
	installed := true
	for _, t := range targets {
		installed = installed && shell.Installed(t.Path, d.EnvFile())
	}
	if installed {
		printShellReady(d.EnvFile())
		return nil
	}
	fmt.Println("将更新以下文件中的 Harmonia 变量加载设置（支持 Bash 5.1+、Zsh 5.0+）：")
	for _, t := range targets {
		fmt.Println("  " + t.Path)
	}
	fmt.Print("\n" + shell.SourceLine(d.EnvFile()) + "\n")
	if !f.bools["yes"] && !confirmYes("安装 Shell 集成？") {
		fmt.Println("已取消。需要时重新运行 harmonia shell install。")
		return nil
	}
	a, err := app.Load(false)
	if err != nil {
		return err
	}
	if a.Keys != nil {
		if _, err := a.RefreshEnvFile(); err != nil {
			return err
		}
	} else if err := state.WriteAtomic(d.EnvFile(), shell.Render(nil)); err != nil {
		return err
	}
	for _, t := range targets {
		if err := shell.Install(t.Path, d.EnvFile()); errors.Is(err, shell.ErrSymlink) {
			fmt.Printf("未修改符号链接 %s。请在它指向的文件中添加或替换上面的加载设置。\n", t.Path)
		} else if err != nil {
			return err
		}
	}
	printShellReady(d.EnvFile())
	return nil
}

func printShellReady(envFile string) {
	fmt.Println("当前终端运行以下命令启用变量自动更新：")
	fmt.Printf("  . %s\n", shell.Quote(shell.IntegrationFile(envFile)))
	fmt.Println("变量同步后，按一次空回车即可在当前终端使用新值。")
}

// removeIntegration 在卸载时移除各个 shell 启动文件中的加载设置。
func removeIntegration(*app.App) error {
	for _, sh := range []string{"zsh", "bash"} {
		ts, _ := shellTargets(sh)
		for _, t := range ts {
			if err := shell.Uninstall(t.Path); errors.Is(err, shell.ErrSymlink) {
				fmt.Printf("%s 是符号链接，请手动删除其中 Harmonia 的那几行。\n", t.Path)
			}
		}
	}
	return nil
}

// shellNotes 是 harmonia status 中补充说明的内容；Shell 集成没有需要说明的。
func shellNotes(*app.App) []string { return nil }
