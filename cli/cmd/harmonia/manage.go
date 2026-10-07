package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"golang.org/x/term"

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
			if shell.Installed(t.Path, d.EnvFile()) {
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

// enableLinger 在没能开启开机自启时询问是否用 sudo 开启：systemd 用户服务默认只在用户登录期间运行，
// 开启 linger 后不登录也会运行，但普通用户（例如通过 SSH 登录时）通常没有权限自己开启。
func enableLinger(user string) {
	fmt.Println("\n开机自启还没有开启：当前用户没有权限开启，退出登录或重启后服务不会运行，直到下次登录。")
	cmd := "sudo loginctl enable-linger " + user
	if term.IsTerminal(int(os.Stdin.Fd())) && confirmYes("是否用 sudo 开启？需要输入 sudo 密码。") {
		c := exec.Command("sudo", "loginctl", "enable-linger", user)
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		if c.Run() == nil {
			fmt.Println("已开启开机自启，不登录也会运行。")
			return
		}
		fmt.Println("没有开启成功。")
	}
	fmt.Printf("之后可以运行：%s\n", cmd)
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
		if res.LingerUser != "" {
			enableLinger(res.LingerUser)
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
	fmt.Println("已启用 Shell 集成的终端会在下一次命令提示符出现时清理变量。")
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
