// harmonia manager：电脑上的管理登录和本机管理页面（docs/rewrite-plan.md 第 16 节）。
package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"

	"golang.org/x/term"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/manager"
	"github.com/harmonia-vault/harmonia/cli/internal/managerui"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

const managerUsage = "用法：harmonia manager [ui] [--port 端口] [--no-open] | login | logout | status"

func cmdManager(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "port")
	if err != nil {
		return err
	}
	sub := "ui"
	if len(f.args) > 0 {
		sub = f.args[0]
	}
	d, err := state.Open()
	if err != nil {
		return err
	}
	switch sub {
	case "ui", "login":
		return managerPage(ctx, d, f, sub == "login")
	case "logout":
		return managerLogout(ctx, d, f.bools["yes"])
	case "status":
		fmt.Println("管理登录：" + managerSummary(d))
		return nil
	}
	return errors.New(managerUsage)
}

// managerSummary 说明这台电脑是否有管理登录，不需要口令。
func managerSummary(d *state.Dir) string {
	m, err := d.Manager()
	switch {
	case err != nil:
		return "数据已损坏（运行 harmonia manager logout 后重新管理登录）"
	case m == nil:
		return "未登录（运行 harmonia manager 开始）"
	}
	return fmt.Sprintf("已登录，账号 %s，设备名“%s”", m.Email, m.DeviceName)
}

// managerPage 在回环地址上打开管理页面，直到按 Ctrl+C。
func managerPage(ctx context.Context, d *state.Dir, f *flags, login bool) error {
	port := 0
	if v, ok := f.values["port"]; ok {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 65535 {
			return errors.New("--port 需要 1 到 65535 之间的端口号")
		}
		port = n
	}
	if m, _ := d.Manager(); login && m != nil {
		fmt.Printf("这台电脑已经管理登录了账号 %s，直接打开管理页面。\n", m.Email)
	}
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return fmt.Errorf("无法在本机监听端口：%w。可以用 --port 换一个端口", err)
	}
	srv := managerui.New(ctx, d, ln)
	url := srv.URL()
	fmt.Println("管理页面：" + url)
	fmt.Println("这个地址只能打开一次，只在这台电脑上有效。5 分钟没有操作会自动锁定；用完后按 Ctrl+C 结束。")
	_, p, _ := net.SplitHostPort(ln.Addr().String())
	switch {
	case f.bools["no-open"]:
	case os.Getenv("SSH_CONNECTION") != "":
		fmt.Printf("你是通过 SSH 登录的。请在自己的电脑上运行 ssh -L %s:127.0.0.1:%s <这台机器>，再用浏览器打开上面的地址。\n", p, p)
	case openBrowser(url) != nil:
		fmt.Println("没能自动打开浏览器，请手动打开上面的地址。")
	default:
		fmt.Println("已在浏览器中打开。")
	}
	return srv.Serve(ln)
}

// managerLogout 退出管理登录。口令只在终端里输入；直接回车（或没有终端）时只删除本机的管理密钥。
func managerLogout(ctx context.Context, d *state.Dir, yes bool) error {
	m, err := d.Manager()
	if err == nil && m == nil {
		fmt.Println("这台电脑没有管理登录。")
		return nil
	}
	if err != nil {
		// 数据已损坏，解不开也认不出是哪台设备，只能删除。
		if !yes && !confirm("本机的管理登录数据已损坏。将删除它，之后请在手机的“设备”页移除这台电脑的管理身份。确认？") {
			fmt.Println("已取消。")
			return nil
		}
		return d.RemoveManager()
	}
	if !yes && !confirm(fmt.Sprintf("将退出账号 %s 的管理登录，并删除这台电脑上的管理密钥。确认？", m.Email)) {
		fmt.Println("已取消。")
		return nil
	}
	local := func(why string) error {
		if err := d.RemoveManager(); err != nil {
			return err
		}
		fmt.Printf("%s已删除这台电脑上的管理密钥。请在手机的“设备”页移除“%s”。\n", why, m.DeviceName)
		return nil
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return local("")
	}
	fmt.Fprint(os.Stderr, "管理口令（忘记口令时直接回车，只删除这台电脑上的管理密钥）：")
	raw, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return err
	}
	if len(raw) == 0 {
		return local("")
	}
	keys, err := manager.Unlock(m, string(raw))
	if err != nil {
		return err
	}
	sess := manager.Open(d, m, keys)
	err = sess.Logout(ctx, false)
	if api.IsCode(err, "conflict") {
		if !confirm("这是账号里唯一的管理设备。退出后只能用恢复码找回账号。仍然退出？") {
			fmt.Println("已取消。")
			return nil
		}
		err = sess.Logout(ctx, true)
	}
	if err != nil {
		return fmt.Errorf("没能通知服务器：%w。请联网后再试；或者重新运行本命令并在询问口令时直接回车，只删除这台电脑上的管理密钥", err)
	}
	if err := d.RemoveManager(); err != nil {
		return err
	}
	fmt.Println("已退出管理登录，这台电脑的管理身份已从账号中移除。")
	return nil
}
