package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"golang.org/x/term"

	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/service"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

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
	f, err := parseFlags(args, "yes")
	if err != nil {
		return err
	}
	a, err := app.Load(false)
	if err != nil {
		return err
	}
	if !a.Config.Paired() {
		fmt.Println("本机没有接入账号。")
		return nil
	}
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
	fmt.Println(logoutNotice)
	return nil
}

func cmdUninstall(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "yes")
	if err != nil {
		return err
	}
	if !f.bools["yes"] && !confirm("将"+uninstallSummary+"本身。确认？") {
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
	if m, merr := a.Dir.Manager(); m != nil || merr != nil {
		// 通知不到服务器也要继续卸载：数据目录随后整个删除。
		if err := managerLogout(ctx, a.Dir, true); err != nil {
			fmt.Println(sentence(err.Error()))
			if m != nil {
				fmt.Printf("卸载后请在手机的“设备”页移除“%s”。\n", m.DeviceName)
			}
		}
	}
	if err := service.Uninstall(); err != nil {
		return err
	}
	if err := removeIntegration(a); err != nil {
		return err
	}
	removeSkills()
	if err := os.RemoveAll(a.Dir.Path); err != nil {
		return err
	}
	if bin, err := executable(); err == nil {
		removeProgram(bin)
	}
	fmt.Println("Harmonia 已卸载。")
	return nil
}
