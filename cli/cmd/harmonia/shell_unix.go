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
	shellCost        = "开启后，你打开的每个终端都带着全部变量，这个用户运行的任何程序都能读到；本机还会留一份明文变量文件。多数情况下用 harmonia exec -- <命令> 只把变量交给要用的程序就够了。"
	shellOnNote      = "Shell 集成已开启：变量对这个用户的所有程序可见，本机留有明文变量文件。不需要时运行 harmonia shell uninstall 关闭，改用 harmonia exec -- <命令>。"
	logoutNotice     = "已启用 Shell 集成的终端会在下一次命令提示符出现时清理变量。"
	uninstallSummary = "退出账号、移除后台服务和 shell 集成，并删除 harmonia"
)

var shellHelp = [][2]string{
	{"shell install [--shell zsh|bash] [--yes]", "让每个终端自动带上变量（变量对所有程序可见，一般用 exec 即可）；默认按当前 shell，--yes 不再确认"},
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
		return "未开启"
	}
	return "已开启：" + strings.Join(on, "、")
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
	if !f.bools["yes"] {
		fmt.Println(shellCost)
		fmt.Println()
	}
	fmt.Println("将更新以下文件中的 Harmonia 变量加载设置（支持 Bash 5.1+、Zsh 5.0+）：")
	for _, t := range targets {
		fmt.Println("  " + t.Path)
	}
	fmt.Print("\n" + shell.SourceLine(d.EnvFile()) + "\n")
	if !f.bools["yes"] && !confirm("仍要开启 Shell 集成？") {
		fmt.Println("没有开启。用 harmonia exec -- <命令> 运行需要变量的程序。")
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

// shellNotes 是 harmonia status 中补充说明的内容：开启时提醒变量对所有程序可见。
// 以 shell.sh 为准：只有它存在时才会写出明文变量文件。
func shellNotes(a *app.App) []string {
	if !app.ShellEnabled(a.Dir) {
		return nil
	}
	return []string{"", shellOnNote}
}
