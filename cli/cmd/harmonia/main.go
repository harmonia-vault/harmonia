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
		printHelp(os.Stdout)
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
		fmt.Fprintf(os.Stderr, "未知命令：%s。运行 harmonia help 查看全部命令。\n", args[0])
		os.Exit(2)
	}
	if err := fn(ctx, args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "错误："+sentence(err.Error()))
		os.Exit(1)
	}
}
