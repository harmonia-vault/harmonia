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

	"github.com/harmonia-vault/harmonia/cli/internal/api"
)

// version 在构建时通过 -ldflags "-X main.version=..." 写入。
var version = "dev"

type flags struct {
	values map[string]string
	lists  map[string][]string // 可以重复给出的选项，按出现顺序
	bools  map[string]bool
	args   []string
	rest   []string // "--" 之后的参数
}

// usageError 是用法上的错误，输出时提示查看这条命令的帮助。
type usageError string

func (e usageError) Error() string { return string(e) }

// parseFlags 解析参数，允许选项出现在位置参数之后。spec 列出这条命令认识的选项，
// 以“=”结尾的需要取值；其他选项一律报错，避免拼错的选项被悄悄忽略。
func parseFlags(args []string, spec ...string) (*flags, error) {
	f := &flags{values: map[string]string{}, lists: map[string][]string{}, bools: map[string]bool{}}
	known := map[string]bool{} // 选项名 → 是否需要取值
	for _, s := range spec {
		name, valued := strings.CutSuffix(s, "=")
		known[name] = valued
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
		valued, ok := known[name]
		switch {
		case !ok:
			return nil, usageError(fmt.Sprintf("不认识的选项 %s", a))
		case !valued:
			if hasVal {
				return nil, usageError(fmt.Sprintf("选项 --%s 不需要值", name))
			}
			f.bools[name] = true
			continue
		case !hasVal:
			if i+1 >= len(args) {
				return nil, usageError(fmt.Sprintf("选项 --%s 需要一个值", name))
			}
			i++
			val = args[i]
		}
		f.values[name] = val
		f.lists[name] = append(f.lists[name], val)
	}
	return f, nil
}

// wantsHelp 判断命令参数里（“--”之前）是否要求查看帮助。
func wantsHelp(args []string) bool {
	for _, a := range args {
		if a == "--" {
			return false
		}
		if a == "-h" || a == "--help" {
			return true
		}
	}
	return false
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
	api.Version = version
	args := os.Args[1:]
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		printHelp(os.Stdout)
		return
	}
	if args[0] == "help" {
		if len(args) < 2 {
			printHelp(os.Stdout)
		} else {
			printCommandHelp(os.Stdout, args[1])
		}
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
		"skill":     cmdSkill,
		"manager":   cmdManager,
		"logout":    cmdLogout,
		"uninstall": cmdUninstall,
		"version":   func(context.Context, []string) error { fmt.Println("harmonia", version); return nil },
	}
	fn, ok := commands[args[0]]
	if !ok {
		fmt.Fprintf(os.Stderr, "未知命令：%s。运行 harmonia help 查看全部命令。\n", args[0])
		os.Exit(2)
	}
	// 查看帮助不执行命令本身：例如 update --help 不应当开始升级。
	if wantsHelp(args[1:]) {
		printCommandHelp(os.Stdout, args[0])
		return
	}
	err := fn(ctx, args[1:])
	dailyHint(args[0])
	if err != nil {
		msg := sentence(err.Error())
		if errors.As(err, new(usageError)) {
			msg += fmt.Sprintf("运行 harmonia %s --help 查看用法。", args[0])
		}
		fmt.Fprintln(os.Stderr, "错误："+msg)
		if args[0] == "exec" {
			// 和要运行的命令自己的退出码区分开（同 env、docker 的习惯）。
			os.Exit(125)
		}
		os.Exit(1)
	}
}
