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
	{"shell install [--shell zsh|bash] [--yes]", "在 shell 启动文件中加载变量；默认按当前 shell，--yes 不再确认"},
	{"shell uninstall [--shell zsh|bash]", "移除 shell 启动文件中的加载设置；默认移除全部，都移除后删除本机的变量文件"},
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
	if len(on) == 0 && app.ShellEnabled(d) {
		return "已开启，但启动文件里没有加载设置（例如启动文件是符号链接），请手动添加；运行 harmonia shell install 查看要添加的内容"
	}
	if len(on) == 0 {
		return "未安装（运行 harmonia shell install）"
	}
	return "已安装：" + strings.Join(on, "、")
}

func cmdShell(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "shell=", "yes")
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
	if f.args[0] == "uninstall" {
		return uninstallShell(d, sh)
	}
	if sh == "" {
		sh = shell.Detect()
	}
	targets, err := shellTargets(sh)
	if err != nil {
		return err
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
	// 先写入集成脚本（它是“已开启”的标记），再写出变量文件。
	for _, t := range targets {
		if err := shell.Install(t.Path, d.EnvFile()); errors.Is(err, shell.ErrSymlink) {
			fmt.Printf("未修改符号链接 %s。请在它指向的文件中添加或替换上面的加载设置。\n", t.Path)
		} else if err != nil {
			return err
		}
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
	printShellReady(d.EnvFile())
	return nil
}

// uninstallShell 移除启动文件中的加载设置（sh 为空时 zsh、bash 都移除）。没有启动文件再加载时，
// 删除集成脚本和变量文件，本机不再留下变量的明文副本。
func uninstallShell(d *state.Dir, sh string) error {
	shells := []string{"zsh", "bash"}
	if sh != "" {
		if _, err := shellTargets(sh); err != nil {
			return err
		}
		shells = []string{sh}
	}
	for _, name := range shells {
		ts, _ := shellTargets(name)
		for _, t := range ts {
			if err := shell.Uninstall(t.Path); errors.Is(err, shell.ErrSymlink) {
				fmt.Printf("%s 是符号链接，请手动删除其中 Harmonia 的那几行。\n", t.Path)
			} else if err != nil {
				return err
			}
		}
	}
	for _, name := range []string{"zsh", "bash"} {
		ts, _ := shellTargets(name)
		for _, t := range ts {
			if fi, err := os.Lstat(t.Path); err == nil && fi.Mode()&os.ModeSymlink == 0 && shell.Referenced(t.Path) {
				fmt.Printf("已移除 %s 的加载设置。%s 中还有加载设置，变量文件暂时保留；运行 harmonia shell uninstall 全部移除。\n", sh, t.Path)
				return nil
			}
		}
	}
	if err := shell.RemoveFiles(d.EnvFile()); err != nil {
		return err
	}
	fmt.Println("已移除 Shell 集成，并删除了本机的变量文件。已打开的终端会在下一次命令提示符出现时清理变量，新开的终端不再加载。")
	return nil
}

func printShellReady(envFile string) {
	fmt.Println("当前终端运行以下命令启用变量自动更新：")
	fmt.Printf("  . %s\n", shell.Quote(shell.IntegrationFile(envFile)))
	fmt.Println("变量同步后，按一次空回车即可在当前终端使用新值。")
}

// removeIntegration 在卸载时移除各个 shell 启动文件中的加载设置和变量文件。
func removeIntegration(a *app.App) error {
	for _, sh := range []string{"zsh", "bash"} {
		ts, _ := shellTargets(sh)
		for _, t := range ts {
			if err := shell.Uninstall(t.Path); errors.Is(err, shell.ErrSymlink) {
				fmt.Printf("%s 是符号链接，请手动删除其中 Harmonia 的那几行。\n", t.Path)
			}
		}
	}
	return shell.RemoveFiles(a.Dir.EnvFile())
}

// shellNotes 是 harmonia status 中补充说明的内容；Shell 集成没有需要说明的。
func shellNotes(*app.App) []string { return nil }
