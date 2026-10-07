package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/service"
	"github.com/harmonia-vault/harmonia/cli/internal/shell"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

func shellTargets(sh string) ([]shell.Target, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	return shell.Targets(home, sh)
}

func shellInstalledAny(d *state.Dir) bool {
	for _, sh := range []string{"zsh", "bash"} {
		ts, _ := shellTargets(sh)
		for _, t := range ts {
			if shell.Installed(t.Path) {
				return true
			}
		}
	}
	return false
}

func shellSummary(d *state.Dir) string {
	var on []string
	for _, sh := range []string{"zsh", "bash"} {
		ts, _ := shellTargets(sh)
		for _, t := range ts {
			if shell.Installed(t.Path) {
				on = append(on, t.Path)
			}
		}
	}
	if len(on) == 0 {
		return "未安装（运行 harmonia shell install）"
	}
	return "已安装：" + strings.Join(on, "、")
}

func serviceSummary() string {
	s := service.Check()
	switch {
	case !s.Supported:
		return "当前系统不支持"
	case !s.Installed:
		return "未安装（运行 harmonia service install）"
	case s.Running:
		return "运行中"
	}
	return "已安装但未运行（运行 harmonia service install 重新启动）"
}

func cmdShell(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "shell")
	if err != nil {
		return err
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
	if _, err := os.Stat(d.EnvFile()); errors.Is(err, os.ErrNotExist) {
		if err := state.WriteAtomic(d.EnvFile(), []byte(state.EnvFileHeader)); err != nil {
			return err
		}
	}
	fmt.Println("将在以下文件末尾添加一段加载 Harmonia 变量的代码：")
	for _, t := range targets {
		fmt.Println("  " + t.Path)
	}
	fmt.Print("\n" + shell.SourceLine(d.EnvFile()) + "\n")
	if !f.bools["yes"] && !confirm("确认添加？") {
		fmt.Println("已取消。也可以把上面的内容手动加到启动文件末尾。")
		return nil
	}
	for _, t := range targets {
		if err := shell.Install(t.Path, d.EnvFile()); errors.Is(err, shell.ErrSymlink) {
			fmt.Printf("%s 是符号链接（可能由 dotfiles 工具管理），没有自动修改。请手动把上面的内容加到它指向的文件末尾。\n", t.Path)
		} else if err != nil {
			return err
		}
	}
	fmt.Println("已安装。新开的终端会自动带上已启用环境中的变量；已打开的终端可以运行：")
	fmt.Printf("  . %s\n", shell.Quote(d.EnvFile()))
	return nil
}

func executable() (string, error) {
	p, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(p)
}

func cmdService(ctx context.Context, args []string) error {
	if len(args) != 1 {
		return errors.New("用法：harmonia service install|uninstall|status")
	}
	switch args[0] {
	case "install":
		bin, err := executable()
		if err != nil {
			return err
		}
		d, err := state.Open()
		if err != nil {
			return err
		}
		res, err := service.Install(bin, d.Path)
		if err != nil {
			return err
		}
		fmt.Printf("后台服务已安装并启动（%s）。它会保持与服务器的连接，变化会实时写入本机。\n", res.Path)
		for _, n := range res.Notes {
			fmt.Println("注意：" + n)
		}
	case "uninstall":
		if err := service.Uninstall(); err != nil {
			return err
		}
		fmt.Println("后台服务已停止并移除。")
	case "status":
		fmt.Println("后台服务：" + serviceSummary())
	default:
		return fmt.Errorf("未知操作：%s", args[0])
	}
	return nil
}

func cmdLogout(ctx context.Context, args []string) error {
	a, err := app.Load(false)
	if err != nil {
		return err
	}
	if !a.Config.Paired() {
		fmt.Println("本机没有接入账号。")
		return nil
	}
	f, _ := parseFlags(args)
	if !f.bools["yes"] && !confirm(fmt.Sprintf("将退出账号 %s，并清除本机保存的密钥和变量。确认？", a.Config.Email)) {
		fmt.Println("已取消。")
		return nil
	}
	online, err := a.Logout(ctx)
	if err != nil {
		return err
	}
	if online {
		fmt.Println("已退出账号，这台设备已从账号中移除，本机数据已清除。")
	} else {
		fmt.Println("已清除本机数据。暂时无法连接服务器，请在管理设备上手动移除这台设备。")
	}
	fmt.Println("新开的终端将不再带上 Harmonia 的变量。")
	return nil
}

func cmdUninstall(ctx context.Context, args []string) error {
	f, _ := parseFlags(args)
	if !f.bools["yes"] && !confirm("将退出账号、移除后台服务和 shell 集成，并删除 harmonia 本身。确认？") {
		fmt.Println("已取消。")
		return nil
	}
	a, err := app.Load(false)
	if err != nil {
		return err
	}
	if a.Config.Paired() {
		if online, err := a.Logout(ctx); err != nil {
			return err
		} else if !online {
			fmt.Println("暂时无法连接服务器，请在管理设备上手动移除这台设备。")
		}
	}
	if err := service.Uninstall(); err != nil {
		return err
	}
	for _, sh := range []string{"zsh", "bash"} {
		ts, _ := shellTargets(sh)
		for _, t := range ts {
			if err := shell.Uninstall(t.Path); errors.Is(err, shell.ErrSymlink) {
				fmt.Printf("%s 是符号链接，请手动删除其中 Harmonia 的那几行。\n", t.Path)
			}
		}
	}
	if err := os.RemoveAll(a.Dir.Path); err != nil {
		return err
	}
	if bin, err := executable(); err == nil {
		_ = os.Remove(bin)
		_ = os.Remove(bin + ".old")
	}
	fmt.Println("Harmonia 已卸载。")
	return nil
}
