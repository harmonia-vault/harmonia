// harmonia 命令行：接入账号、同步环境变量并注入到 shell 或子进程。
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"golang.org/x/term"
)

// version 在构建时通过 -ldflags "-X main.version=..." 写入。
var version = "dev"

const usage = `Harmonia（和弦）：在手机上管理环境变量，同步到这台电脑。

用法：
  harmonia login [服务器地址]              登录账号并发起配对，在管理设备上批准后完成接入
  harmonia status                         查看接入状态、环境和后台服务
  harmonia sync                           立即同步

  harmonia env list                       列出可访问的环境
  harmonia env activate <环境> [--priority N]  在本机启用环境（数值大的优先）
  harmonia env deactivate <环境>          在本机停用环境

  harmonia var list [--env 环境] [--show]  列出变量（默认隐藏值）
  harmonia var set <环境> <变量名> [值]     写入变量（不给值时交互输入）
  harmonia var rm <环境> <变量名>          删除变量
  harmonia import --env <环境>             从当前终端的环境变量中勾选导入

  harmonia override set <环境> <变量名> [值]  设置仅本机生效的值
  harmonia override rm <环境> <变量名>
  harmonia override list

  harmonia exec [--env a,b] -- <命令...>   带上变量运行命令
  harmonia export [--format sh|dotenv|json]  输出当前生效的变量

  harmonia shell install|uninstall [--shell zsh|bash]  在 shell 启动文件中加载变量
  harmonia service install|uninstall|status  管理后台同步服务

  harmonia update [--check]               检查并升级 harmonia
  harmonia update channel [stable|beta]   查看或切换更新渠道（正式版 / 测试版）
  harmonia logout                         退出账号并清除本机数据
  harmonia uninstall                      退出账号、移除服务与 shell 集成并删除 harmonia
  harmonia version
`

type flags struct {
	values map[string]string
	bools  map[string]bool
	args   []string
	rest   []string // "--" 之后的参数
}

// parseFlags 解析参数，允许选项出现在位置参数之后。valued 列出需要取值的选项。
func parseFlags(args []string, valued ...string) (*flags, error) {
	f := &flags{values: map[string]string{}, bools: map[string]bool{}}
	needs := map[string]bool{}
	for _, v := range valued {
		needs[v] = true
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			f.rest = args[i+1:]
			break
		}
		if !strings.HasPrefix(a, "-") || a == "-" {
			f.args = append(f.args, a)
			continue
		}
		name, val, hasVal := strings.Cut(strings.TrimLeft(a, "-"), "=")
		if needs[name] {
			if !hasVal {
				if i+1 >= len(args) {
					return nil, fmt.Errorf("选项 --%s 需要一个值", name)
				}
				i++
				val = args[i]
			}
			f.values[name] = val
		} else {
			f.bools[name] = true
		}
	}
	return f, nil
}

var stdin = bufio.NewReader(os.Stdin)

func prompt(label string) (string, error) {
	fmt.Fprint(os.Stderr, label)
	line, err := stdin.ReadString('\n')
	if err != nil && line == "" {
		return "", errors.New("没有读取到输入")
	}
	return strings.TrimSpace(line), nil
}

func promptSecret(label string) (string, error) {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return prompt(label)
	}
	fmt.Fprint(os.Stderr, label)
	b, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	return string(b), err
}

func confirm(label string) bool {
	ans, err := prompt(label + "（y/N）")
	return err == nil && (strings.EqualFold(ans, "y") || strings.EqualFold(ans, "yes"))
}

// confirmYes 用于安装类操作：直接回车视为同意，读不到输入时视为不同意。
func confirmYes(label string) bool {
	ans, err := prompt(label + "（Y/n）")
	return err == nil && !strings.EqualFold(ans, "n") && !strings.EqualFold(ans, "no")
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	args := os.Args[1:]
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		fmt.Print(usage)
		return
	}
	commands := map[string]func(context.Context, []string) error{
		"login":     cmdLogin,
		"status":    cmdStatus,
		"sync":      cmdSync,
		"env":       cmdEnv,
		"var":       cmdVar,
		"import":    cmdImport,
		"override":  cmdOverride,
		"exec":      cmdExec,
		"export":    cmdExport,
		"shell":     cmdShell,
		"service":   cmdService,
		"daemon":    cmdDaemon,
		"update":    cmdUpdate,
		"logout":    cmdLogout,
		"uninstall": cmdUninstall,
		"version":   func(context.Context, []string) error { fmt.Println("harmonia", version); return nil },
	}
	fn, ok := commands[args[0]]
	if !ok {
		fmt.Fprintf(os.Stderr, "未知命令：%s\n\n%s", args[0], usage)
		os.Exit(2)
	}
	if err := fn(ctx, args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "错误：", err)
		os.Exit(1)
	}
}
