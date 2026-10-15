package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/mdp/qrterminal/v3"

	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/daemon"
	"github.com/harmonia-vault/harmonia/cli/internal/service"
	"github.com/harmonia-vault/harmonia/cli/internal/shell"
)

type terminalPrompt struct{}

func (terminalPrompt) ShowPairing(qr, code, name string, expiresAt time.Time, authorized bool) {
	fmt.Fprintln(os.Stderr)
	if authorized {
		fmt.Fprintln(os.Stderr, "已用配对码发起请求。管理设备上的 Harmonia 在前台时会直接弹出批准页，也可以在“设备”页的待批准列表中找到它。")
		fmt.Fprintln(os.Stderr, "批准前请在管理设备上核对下面的核对码，或扫描二维码：")
	} else {
		fmt.Fprintln(os.Stderr, "在管理设备上打开 Harmonia，进入“设备 → 添加设备”，扫描下面的二维码：")
	}
	qrterminal.GenerateWithConfig(qr, qrterminal.Config{
		Level: qrterminal.L, Writer: os.Stderr, HalfBlocks: true,
		BlackChar: qrterminal.BLACK_BLACK, WhiteChar: qrterminal.WHITE_WHITE,
		BlackWhiteChar: qrterminal.BLACK_WHITE, WhiteBlackChar: qrterminal.WHITE_BLACK, QuietZone: 2,
	})
	fmt.Fprintf(os.Stderr, "无法扫码时，选择“输入核对码”。核对码：%s\n", code)
	fmt.Fprintf(os.Stderr, "批准前请确认显示的设备名是“%s”。请求 5 分钟内（%s 前）有效。\n", name, expiresAt.Format("15:04"))
}

func (terminalPrompt) Waiting() {
	fmt.Fprintln(os.Stderr, "\n正在等待批准……（按 Ctrl+C 取消）")
}

func cmdLogin(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "email=", "name=", "code=")
	if err != nil {
		return err
	}
	a, err := app.Load(false)
	if err != nil {
		return err
	}
	in := app.LoginInput{Email: f.values["email"], DeviceName: f.values["name"]}
	// 这台电脑已有管理登录时，日常登录沿用它的服务器和账号。
	if m, _ := a.Dir.Manager(); m != nil && a.Config.Server == "" {
		a.Config.Server, a.Config.Email = m.Server, m.Email
	}
	if len(f.args) > 0 {
		in.Server = f.args[0]
	} else if a.Config.Server != "" {
		in.Server = a.Config.Server
	} else if in.Server, err = prompt("服务器地址："); err != nil {
		return err
	}
	if in.Email == "" {
		def := a.Config.Email
		label := "邮箱："
		if def != "" {
			label = fmt.Sprintf("邮箱（%s）：", def)
		}
		if in.Email, err = prompt(label); err != nil {
			return err
		}
		if in.Email == "" {
			in.Email = def
		}
	}
	if code, ok := f.values["code"]; ok {
		in.PairingCode = code
	} else {
		// 读不到输入（例如在脚本中运行）时按留空处理，改用扫码。
		in.PairingCode, _ = prompt("配对码（在管理设备的“设备 → 添加设备 → 生成配对码”中获取；直接回车改用扫码）：")
	}
	fmt.Fprintln(os.Stderr, "正在发起配对……")
	a, n, err := app.Login(ctx, in, terminalPrompt{})
	if err != nil {
		return err
	}
	if n == 0 {
		fmt.Println("\n已接入账号。" + noEnvNotice)
	} else {
		fmt.Printf("\n已接入账号，这台设备可以访问 %d 个环境，授权的环境默认已启用。\n", n)
	}
	next := [][]string{{"harmonia env list", "查看环境和变量来源"}}
	if !shellInstalledAny(a) {
		next = append(next, []string{"harmonia shell install", shellInstallHint})
	}
	if s := service.Check(); s.Supported && !s.Installed {
		next = append(next, []string{"harmonia service install", "安装后台服务，实时同步"})
	}
	fmt.Println("\n接下来")
	printTable(os.Stdout, "  ", next)
	return nil
}

func cmdSync(ctx context.Context, args []string) error {
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	if err := a.Sync(ctx); err != nil {
		return err
	}
	fmt.Println("已同步。")
	return nil
}

func cmdEnv(ctx context.Context, args []string) error {
	f, err := parseFlags(args)
	if err != nil {
		return err
	}
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	if len(f.args) == 0 || f.args[0] == "list" {
		if err := refresh(ctx, a); err != nil {
			return err
		}
		return printEnvs(a)
	}
	usage := errors.New("用法：harmonia env list | activate <环境> | deactivate <环境> | order <环境>...")
	if len(f.args) < 2 || (f.args[0] != "order" && len(f.args) != 2) {
		return usage
	}
	switch f.args[0] {
	case "activate":
		env, err := a.Activate(ctx, f.args[1])
		if err != nil {
			return err
		}
		fmt.Printf("已启用环境“%s”。\n", env.Name)
		if !shellInstalledAny(a) {
			fmt.Println(shellOffNotice)
		}
	case "deactivate":
		env, err := a.Deactivate(ctx, f.args[1])
		if err != nil {
			return err
		}
		fmt.Printf("已停用环境“%s”。\n", env.Name)
	case "order":
		if err := a.Order(ctx, f.args[1:]); err != nil {
			return err
		}
		return printEnvs(a)
	default:
		return usage
	}
	return nil
}
func cmdOverride(ctx context.Context, args []string) error {
	f, err := parseFlags(args)
	if err != nil {
		return err
	}
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	if len(f.args) == 0 || f.args[0] == "list" {
		ov, err := a.Dir.Overrides()
		if err != nil {
			return err
		}
		return printOverrides(a, ov)
	}
	if len(f.args) < 3 {
		return errors.New("用法：harmonia override set|rm <环境> <变量名> [值]")
	}
	switch f.args[0] {
	case "set":
		value := ""
		if len(f.args) >= 4 {
			value = f.args[3]
		} else if value, err = promptSecret(fmt.Sprintf("%s 的本机值：", f.args[2])); err != nil {
			return err
		}
		env, err := a.SetOverride(f.args[1], f.args[2], &value)
		if err != nil {
			return err
		}
		fmt.Printf("已为环境“%s”的 %s 设置本机覆盖值，只在这台设备生效。\n", env.Name, f.args[2])
	case "rm":
		env, err := a.SetOverride(f.args[1], f.args[2], nil)
		if err != nil {
			return err
		}
		fmt.Printf("已移除环境“%s”中 %s 的本机覆盖值。\n", env.Name, f.args[2])
	default:
		return fmt.Errorf("未知操作：%s", f.args[0])
	}
	return nil
}

// envList 展开 --env 的取值：可以用逗号分隔，也可以重复给出，按出现顺序排列。
func envList(f *flags) []string {
	var out []string
	for _, v := range f.lists["env"] {
		for _, item := range strings.Split(v, ",") {
			if item = strings.TrimSpace(item); item != "" {
				out = append(out, item)
			}
		}
	}
	return out
}

// refresh 用较短的超时同步一次，让授权的变化（例如被撤销）在没有后台服务时也能生效；
// 同步失败时说明具体原因和缓存是多久前的，然后继续使用本机缓存。
func refresh(ctx context.Context, a *app.App) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	checked := startStaleCheck(ctx)
	err := a.Sync(ctx)
	checked()
	if err != nil {
		if errors.Is(err, app.ErrRevokedLocal) {
			return err
		}
		when := "使用上次同步（" + ago(a.Config.LastSync) + "）的本机缓存"
		if a.Config.LastSync == 0 {
			when = "本机还没有同步过，没有缓存可用"
		}
		fmt.Fprintf(os.Stderr, "harmonia：同步失败（%s），%s。\n", strings.TrimRight(err.Error(), "。."), when)
	}
	return nil
}

// effective 返回要注入的变量；envs 非空时只使用这些环境或变量（先列出的优先）。
func effective(ctx context.Context, a *app.App, envs []string) (map[string]string, error) {
	if err := refresh(ctx, a); err != nil {
		return nil, err
	}
	if len(envs) > 0 {
		vars, skipped, err := a.Select(envs)
		for _, s := range skipped {
			fmt.Fprintln(os.Stderr, "harmonia："+sentence(s))
		}
		return vars, err
	}
	// 没有任何环境时照常继续，只说明拿不到变量的原因。
	if cache, err := a.Dir.Cache(); err == nil && len(cache.Environments) == 0 {
		fmt.Fprintln(os.Stderr, "harmonia：这台设备还没有任何环境的访问权限，没有可以提供的变量。可以在管理设备上为它授权。")
	}
	vars, skipped, err := a.Effective()
	for _, s := range skipped {
		fmt.Fprintln(os.Stderr, "harmonia："+sentence(s))
	}
	return vars, err
}

func cmdExec(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "env=")
	if err != nil {
		return usageError(err.Error() + "。要传给命令的选项请写在 -- 之后，例如 harmonia exec -- npm test --watch")
	}
	cmdArgs := append(f.args, f.rest...)
	if len(cmdArgs) == 0 {
		return errors.New("用法：harmonia exec [--env a,b,c:变量名] -- <命令...>")
	}
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	envs := envList(f)
	vars, err := effective(ctx, a, envs)
	if err != nil {
		return err
	}
	// 指定了 --env 时，终端里由其他环境写入的变量（例如开启了 Shell 集成）不传给命令。
	var known map[string]map[string]bool
	if len(envs) > 0 {
		if known, err = a.Known(); err != nil {
			return err
		}
	}
	env := app.ExecEnv(os.Environ(), vars, known, runtime.GOOS == "windows")
	bin, err := exec.LookPath(cmdArgs[0])
	if err != nil {
		return fmt.Errorf("找不到命令 %s%s", cmdArgs[0], notFoundHint)
	}
	// 命令运行后本进程不再回来（或直接以它的退出码结束），更新提示只能放在前面。
	dailyHint("exec")
	return replaceProcess(bin, cmdArgs, env)
}

func cmdExport(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "format=", "env=", "all")
	if err != nil {
		return err
	}
	envs := envList(f)
	switch {
	case len(envs) == 0 && !f.bools["all"]:
		return usageError("export 输出的是明文，需要指明范围：--all 输出全部启用环境的变量，--env 环境[,环境:变量名] 只输出指定的")
	case len(envs) > 0 && f.bools["all"]:
		return usageError("--all 和 --env 只能选一个")
	}
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	vars, err := effective(ctx, a, envs)
	if err != nil {
		return err
	}
	switch f.values["format"] {
	case "", "sh":
		os.Stdout.Write(shell.Render(vars))
	case "dotenv":
		fmt.Print(shell.Dotenv(vars))
	case "json":
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(vars)
	default:
		return errors.New("--format 只能是 sh、dotenv 或 json")
	}
	return nil
}

func cmdDaemon(ctx context.Context, args []string) error {
	ctx, done, err := background(ctx, args)
	if err != nil {
		return err
	}
	defer done()
	// 新程序启动时把保存过的技能文件换成当前的入口文件（早期版本保存的是完整说明）。
	syncSkillFiles(func(s string) { fmt.Fprintln(os.Stderr, s) })
	err = daemon.Run(ctx, daemon.Hooks{Check: backgroundCheck})
	if errors.Is(err, daemon.ErrUpgraded) {
		// 退出后由系统用新程序重新启动；Windows 的计划任务不会马上重启，由这里先启动新程序。
		done()
		if err := relaunchDaemon(daemon.Logf); err != nil {
			daemon.Logf("没能启动新版本的后台服务（%v），系统稍后会重新启动它", err)
		}
		return nil
	}
	return err
}
