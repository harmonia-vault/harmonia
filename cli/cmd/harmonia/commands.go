package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/mdp/qrterminal/v3"

	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/daemon"
	"github.com/harmonia-vault/harmonia/cli/internal/service"
	"github.com/harmonia-vault/harmonia/cli/internal/shell"
	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

type terminalPrompt struct{}

func (terminalPrompt) AskCode(message string) (string, error) {
	fmt.Fprintln(os.Stderr, message)
	return prompt("邮件中的验证码：")
}

func (terminalPrompt) ShowPairing(qr, code string, expiresAt time.Time) {
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "请在管理设备上打开 Harmonia，进入“设备 → 添加设备”，扫描下面的二维码：")
	fmt.Fprintln(os.Stderr)
	qrterminal.GenerateWithConfig(qr, qrterminal.Config{
		Level: qrterminal.L, Writer: os.Stderr, HalfBlocks: true,
		BlackChar: qrterminal.BLACK_BLACK, WhiteChar: qrterminal.WHITE_WHITE,
		BlackWhiteChar: qrterminal.BLACK_WHITE, WhiteBlackChar: qrterminal.WHITE_BLACK, QuietZone: 2,
	})
	fmt.Fprintln(os.Stderr)
	fmt.Fprintf(os.Stderr, "无法扫码时，可以在管理设备上手动输入核对码：%s\n", code)
	fmt.Fprintf(os.Stderr, "请确认管理设备上显示的设备名称与本机一致。配对请求 %s 前有效。\n", expiresAt.Format("15:04"))
}

func (terminalPrompt) Waiting() {
	fmt.Fprintln(os.Stderr, "\n正在等待管理设备批准……（按 Ctrl+C 取消）")
}

func cmdLogin(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "email", "name")
	if err != nil {
		return err
	}
	a, err := app.Load(false)
	if err != nil {
		return err
	}
	in := app.LoginInput{Email: f.values["email"], DeviceName: f.values["name"]}
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
	if f.bools["password-stdin"] {
		in.Password, err = prompt("")
	} else {
		in.Password, err = promptSecret("密码：")
	}
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "正在登录……")
	a, n, err := app.Login(ctx, in, terminalPrompt{})
	if err != nil {
		return err
	}
	fmt.Printf("\n已接入账号，这台设备可以访问 %d 个环境。\n", n)
	fmt.Println("接下来：")
	fmt.Println("  harmonia env list                     查看环境（授权的环境默认已启用）")
	if !shellInstalledAny(a.Dir) {
		fmt.Println("  harmonia shell install                新开的终端自动带上变量")
	}
	if s := service.Check(); s.Supported && !s.Installed {
		fmt.Println("  harmonia service install              安装后台服务，实时同步")
	}
	return nil
}

func ago(ms int64) string {
	if ms == 0 {
		return "从未"
	}
	d := time.Since(time.UnixMilli(ms))
	switch {
	case d < time.Minute:
		return "刚刚"
	case d < time.Hour:
		return fmt.Sprintf("%d 分钟前", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%d 小时前", int(d.Hours()))
	}
	return fmt.Sprintf("%d 天前", int(d.Hours()/24))
}

var roleNames = map[string]string{"ro": "只读", "rw": "读写", "admin": "管理"}

func expiry(ms int64) string {
	if ms == 0 {
		return "长期"
	}
	t := time.UnixMilli(ms)
	if time.Now().After(t) {
		return "已到期"
	}
	return t.Format("2006-01-02 15:04") + " 到期"
}

func cmdStatus(ctx context.Context, args []string) error {
	a, err := app.Load(false)
	if err != nil {
		return err
	}
	if !a.Config.Paired() {
		fmt.Println("本机还没有接入账号。运行 harmonia login 开始。")
		return nil
	}
	fmt.Printf("账号：%s（%s）\n", a.Config.Email, a.Config.Server)
	fmt.Printf("本机：%s\n", a.Config.DeviceName)
	fmt.Printf("上次同步：%s\n", ago(a.Config.LastSync))
	fmt.Printf("后台服务：%s\n", serviceSummary())
	fmt.Printf("Shell 集成：%s\n", shellSummary(a.Dir))
	fmt.Printf("版本：%s（%s渠道）\n", version, updateChannel().Label())
	if hint := updateHint(); hint != "" {
		fmt.Println(hint)
	}
	fmt.Println()
	return printEnvs(a)
}

func printEnvs(a *app.App) error {
	cache, err := a.Dir.Cache()
	if err != nil {
		return err
	}
	if len(cache.Environments) == 0 {
		fmt.Println("这台设备还没有任何环境的访问权限。可以在管理设备上为它授权。")
		return nil
	}
	envs := vault.Ordered(cache)
	fmt.Println("环境（按顺序排列，同名变量由排在前面的环境提供）：")
	for i, e := range envs {
		state := "未启用"
		if e.Active {
			state = "已启用"
		}
		fmt.Printf("  %d. %-20s %-4s %-6s %-22s %s\n", i+1, e.Name, roleNames[e.Role], fmt.Sprintf("%d 个变量", len(cache.Variables[e.ID])), expiry(e.ExpiresAt), state)
	}
	if cs := vault.Conflicts(cache, a.Keys, vault.ActiveIDs(cache), time.Now().UnixMilli()); len(cs) > 0 {
		fmt.Println("\n同名变量：")
		for _, c := range cs {
			fmt.Printf("  %s：使用“%s”中的值（同时出现在“%s”）\n", c.Name, c.Envs[0], strings.Join(c.Envs[1:], "”“"))
		}
	}
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
		fmt.Printf("已启用环境“%s”。新开的终端或 harmonia exec 会带上其中的变量。\n", env.Name)
		if !shellInstalledAny(a.Dir) {
			fmt.Println("提示：还没有安装 shell 集成，运行 harmonia shell install 让新终端自动加载。")
		}
	case "deactivate":
		env, err := a.Deactivate(ctx, f.args[1])
		if err != nil {
			return err
		}
		fmt.Printf("已停用环境“%s”。新开的终端将不再带上其中的变量。\n", env.Name)
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
func cmdVar(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "env")
	if err != nil {
		return err
	}
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	if len(f.args) == 0 || f.args[0] == "list" {
		return listVars(a, f.values["env"], f.bools["show"])
	}
	switch f.args[0] {
	case "set":
		if len(f.args) < 3 {
			return errors.New("用法：harmonia var set <环境> <变量名> [值]")
		}
		value := ""
		if len(f.args) >= 4 {
			value = f.args[3]
		} else if value, err = promptSecret(fmt.Sprintf("%s 的值：", f.args[2])); err != nil {
			return err
		}
		if err := a.SetVariables(ctx, f.args[1], map[string]string{f.args[2]: value}); err != nil {
			return err
		}
		fmt.Printf("已写入 %s。\n", f.args[2])
	case "rm":
		if len(f.args) != 3 {
			return errors.New("用法：harmonia var rm <环境> <变量名>")
		}
		if err := a.DeleteVariable(ctx, f.args[1], f.args[2]); err != nil {
			return err
		}
		fmt.Printf("已删除 %s。\n", f.args[2])
	default:
		return fmt.Errorf("未知操作：%s", f.args[0])
	}
	return nil
}

func mask(v string) string {
	if len(v) <= 4 {
		return "****"
	}
	return v[:2] + strings.Repeat("*", 6) + v[len(v)-2:]
}

func listVars(a *app.App, envName string, show bool) error {
	cache, err := a.Dir.Cache()
	if err != nil {
		return err
	}
	envs := cache.Environments
	if envName != "" {
		e, err := vault.Find(cache, envName)
		if err != nil {
			return err
		}
		envs = envs[:0:0]
		envs = append(envs, *e)
	}
	ov, _ := a.Dir.Overrides()
	for _, e := range envs {
		vals, err := vault.Values(cache, a.Keys, e.ID)
		fmt.Printf("%s（%s）\n", e.Name, roleNames[e.Role])
		if err != nil {
			fmt.Printf("  %v\n", err)
			continue
		}
		names := make([]string, 0, len(vals))
		for n := range vals {
			names = append(names, n)
		}
		sort.Strings(names)
		if len(names) == 0 {
			fmt.Println("  （没有变量）")
		}
		for _, n := range names {
			v := vals[n]
			if !show {
				v = mask(v)
			}
			note := ""
			if _, ok := ov[e.ID][n]; ok {
				note = "  [本机覆盖]"
			}
			fmt.Printf("  %s=%s%s\n", n, v, note)
		}
	}
	return nil
}

func cmdImport(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "env")
	if err != nil {
		return err
	}
	if f.values["env"] == "" {
		return errors.New("用法：harmonia import --env <环境>")
	}
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	cands := app.ImportCandidates()
	names := make([]string, 0, len(cands))
	for n := range cands {
		names = append(names, n)
	}
	sort.Strings(names)
	if len(names) == 0 {
		fmt.Println("当前终端没有可以导入的变量。")
		return nil
	}
	fmt.Println("当前终端中的变量：")
	for i, n := range names {
		fmt.Printf("  %3d  %s=%s\n", i+1, n, mask(cands[n]))
	}
	ans, err := prompt("输入要导入的编号（用逗号或空格分隔，直接回车取消）：")
	if err != nil || ans == "" {
		fmt.Println("已取消。")
		return nil
	}
	picked := map[string]string{}
	for _, tok := range strings.FieldsFunc(ans, func(r rune) bool { return r == ',' || r == ' ' || r == '，' }) {
		i, err := strconv.Atoi(tok)
		if err != nil || i < 1 || i > len(names) {
			return fmt.Errorf("编号“%s”不对", tok)
		}
		picked[names[i-1]] = cands[names[i-1]]
	}
	if err := a.SetVariables(ctx, f.values["env"], picked); err != nil {
		return err
	}
	fmt.Printf("已导入 %d 个变量。\n", len(picked))
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
		if len(ov) == 0 {
			fmt.Println("没有本机覆盖值。")
		}
		cache, _ := a.Dir.Cache()
		for envID, m := range ov {
			name := envID
			if e, err := vault.Find(cache, envID); err == nil {
				name = e.Name
			}
			for n, v := range m {
				fmt.Printf("%s  %s=%s\n", name, n, mask(v))
			}
		}
		return nil
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

// effective 返回要注入的变量；envs 非空时只使用这些环境（后列出的优先）。
func effective(ctx context.Context, a *app.App, envs string) (map[string]string, error) {
	sctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	if err := a.Sync(sctx); err != nil {
		if errors.Is(err, app.ErrRevokedLocal) {
			cancel()
			return nil, err
		}
		fmt.Fprintln(os.Stderr, "harmonia：暂时无法连接服务器，使用本机缓存的变量。")
	}
	cancel()
	if envs != "" {
		// 按列出的顺序合并，同名变量由排在前面的环境提供。
		var ids []string
		for _, name := range strings.Split(envs, ",") {
			e, err := a.Env(strings.TrimSpace(name))
			if err != nil {
				return nil, err
			}
			ids = append(ids, e.ID)
		}
		cache, err := a.Dir.Cache()
		if err != nil {
			return nil, err
		}
		ov, _ := a.Dir.Overrides()
		vars, skipped := vault.Merge(cache, a.Keys, ids, ov, time.Now().UnixMilli())
		for _, s := range skipped {
			fmt.Fprintln(os.Stderr, "harmonia：", s)
		}
		return vars, nil
	}
	vars, skipped, err := a.Effective()
	for _, s := range skipped {
		fmt.Fprintln(os.Stderr, "harmonia：", s)
	}
	return vars, err
}

func cmdExec(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "env")
	if err != nil {
		return err
	}
	cmdArgs := append(f.args, f.rest...)
	if len(cmdArgs) == 0 {
		return errors.New("用法：harmonia exec [--env a,b] -- <命令...>")
	}
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	vars, err := effective(ctx, a, f.values["env"])
	if err != nil {
		return err
	}
	env := os.Environ()
	for k, v := range vars {
		env = append(env, k+"="+v)
	}
	bin, err := exec.LookPath(cmdArgs[0])
	if err != nil {
		return fmt.Errorf("找不到命令 %s", cmdArgs[0])
	}
	return syscall.Exec(bin, cmdArgs, env)
}

func cmdExport(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "format", "env")
	if err != nil {
		return err
	}
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	vars, err := effective(ctx, a, f.values["env"])
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
	return daemon.Run(ctx, daemon.Hooks{Daily: dailyUpdateCheck})
}
