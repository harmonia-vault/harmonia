// Windows 上让程序读到变量的办法：把变量写入用户环境变量（docs/rewrite-plan.md 15.3）。
// 命令沿用 shell 这个名字，与 macOS、Linux 保持一致。
package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/sysenv"
)

// 各处提到这项功能时用的文字。
const (
	shellLabel       = "用户环境变量"
	shellOnNote      = "已开启写入用户环境变量：变量明文存在注册表里，这台电脑上你运行的任何程序都能读到。不需要时运行 harmonia shell uninstall 关闭，改用 harmonia exec -- <命令>。"
	logoutNotice     = "写入用户环境变量的内容已经恢复原状。已经打开的终端和程序里还留有旧值，关闭后即消失。"
	uninstallSummary = "退出账号、移除后台服务、把写入的用户环境变量恢复原状，并删除 harmonia"
)

var shellHelp = [][2]string{
	{"shell install [--yes]", "把变量写入 Windows 的用户环境变量（变量对所有程序可见，一般用 exec 即可）；--yes 不再确认"},
	{"shell uninstall", "停止写入，把用户环境变量恢复原状"},
	{"shell system-vars [on|off] [--yes]", "查看或设置是否写入 Path、TEMP 这类系统自身使用的变量（默认不写入）"},
}

func shellInstalledAny(a *app.App) bool {
	st, err := a.SystemEnv()
	return err == nil && st.Enabled
}

func shellSummary(a *app.App) string {
	st, err := a.SystemEnv()
	switch {
	case err != nil:
		return "无法读取（" + err.Error() + "）"
	case !st.Enabled:
		return "未开启"
	}
	return fmt.Sprintf("已开启，写入 %d 个变量", st.Written)
}

// shellNotes 是 harmonia status 中补充说明的内容：开启时提醒变量对所有程序可见，并列出没有写入的变量。
func shellNotes(a *app.App) []string {
	st, err := a.SystemEnv()
	if err != nil || !st.Enabled {
		return nil
	}
	return append([]string{"", shellOnNote}, skippedNotes(st.Skipped)...)
}

// skippedNotes 列出没有写入用户环境变量的变量和原因。
func skippedNotes(skipped []sysenv.Skip) []string {
	if len(skipped) == 0 {
		return nil
	}
	notes := []string{"", "以下变量没有写入用户环境变量（harmonia exec 不受影响）："}
	for _, s := range skipped {
		notes = append(notes, fmt.Sprintf("  %s：%s", s.Name, s.Reason))
	}
	return notes
}

func cmdShell(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "yes")
	if err != nil {
		return err
	}
	usage := errors.New("用法：harmonia shell install|uninstall，或 harmonia shell system-vars on|off")
	if len(f.args) == 0 {
		return usage
	}
	a, err := app.Load(false)
	if err != nil {
		return err
	}
	switch {
	case f.args[0] == "install" && len(f.args) == 1:
		return shellInstall(a, f.bools["yes"])
	case f.args[0] == "uninstall" && len(f.args) == 1:
		if err := a.SetSystemEnv(false); err != nil {
			return err
		}
		fmt.Println("已关闭，写入用户环境变量的内容已经恢复原状。已经打开的终端和程序里还留有旧值，关闭后即消失。")
		return nil
	case f.args[0] == "system-vars" && len(f.args) <= 2:
		return shellSystemVars(ctx, a, f.args[1:], f.bools["yes"])
	}
	return usage
}

func shellInstall(a *app.App, yes bool) error {
	st, err := a.SystemEnv()
	if err != nil {
		return err
	}
	if !st.Enabled {
		fmt.Println("将把 Harmonia 同步的变量写入 Windows 的用户环境变量（“系统属性 → 环境变量”里的用户变量）：")
		fmt.Println("  · 变量明文存在注册表里，之后你启动的任何程序都能读到；已经打开的终端和程序需要重开。")
		fmt.Println("  · 已有的同名用户变量会先记下原值，变量删除、环境停用、退出登录或卸载时恢复。")
		fmt.Println("  · Path、TEMP 这类系统自身使用的变量默认不写入。")
		fmt.Println("多数情况下用 harmonia exec -- <命令> 只把变量交给要用的程序就够了。")
		if !yes && !confirm("仍要开启？") {
			fmt.Println("没有开启。用 harmonia exec -- <命令> 运行需要变量的程序。")
			return nil
		}
	}
	if err := a.SetSystemEnv(true); err != nil {
		return err
	}
	if !a.Config.Paired() {
		fmt.Println("已开启。接入账号后，变量会自动写入用户环境变量。")
		return nil
	}
	if st, err = a.SystemEnv(); err != nil {
		return err
	}
	fmt.Printf("已开启，写入了 %d 个变量。新开一个终端即可使用；变量同步后同样要新开终端。\n", st.Written)
	for _, note := range skippedNotes(st.Skipped) {
		fmt.Println(note)
	}
	return nil
}

func shellSystemVars(ctx context.Context, a *app.App, args []string, yes bool) error {
	if !a.Config.Paired() {
		return app.ErrNotPaired
	}
	if len(args) == 0 {
		st, err := a.SystemEnv()
		if err != nil {
			return err
		}
		state := "关闭"
		if st.SystemVars {
			state = "开启"
		}
		fmt.Printf("写入系统变量：%s。修改：harmonia shell system-vars on|off（也可以在管理设备的设备详情里修改）\n", state)
		return nil
	}
	if args[0] != "on" && args[0] != "off" {
		return errors.New("用法：harmonia shell system-vars on|off")
	}
	on := args[0] == "on"
	if on && !yes {
		fmt.Println("开启后，账号里名为 Path、TEMP、USERPROFILE 之类的变量会写入这台电脑的用户环境变量。")
		fmt.Println("写错会影响这台电脑上的所有程序；原来的值会先记下，关闭开关或变量删除后恢复。")
		if !confirm("确认开启？") {
			fmt.Println("已取消。")
			return nil
		}
	}
	if err := a.SetSystemVars(ctx, on); err != nil {
		return err
	}
	if on {
		fmt.Println("已开启写入系统变量。")
	} else {
		fmt.Println("已关闭写入系统变量，已经写入的系统变量恢复为原来的值。")
	}
	if !shellInstalledAny(a) {
		fmt.Println("写入用户环境变量没有开启，这个开关现在不起作用；harmonia exec 不受它影响。")
	}
	return nil
}

// removeIntegration 在卸载时把写入用户环境变量的内容恢复原状。
func removeIntegration(a *app.App) error {
	return a.SetSystemEnv(false)
}
