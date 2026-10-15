// 展示类命令与输出：接入状态、环境列表、变量列表。
package main

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
	"github.com/harmonia-vault/harmonia/cli/internal/vault"
)

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

const noEnvNotice = "这台设备还没有任何环境的访问权限。可以在管理设备上为它授权。"

var roleNames = map[string]string{"ro": "只读", "rw": "读写"}

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
		if m, err := a.Dir.Manager(); m != nil || err != nil {
			fmt.Println("管理登录：" + managerSummary(a.Dir))
		}
		return nil
	}
	if err := refresh(ctx, a); err != nil {
		return err
	}
	printTable(os.Stdout, "", [][]string{
		{"账号", a.Config.Email},
		{"服务器", a.Config.Server},
		{"本机", a.Config.DeviceName},
		{"上次同步", ago(a.Config.LastSync)},
		{"管理登录", managerSummary(a.Dir)},
		{"后台服务", serviceSummary()},
		{shellLabel, shellSummary(a)},
		{"版本", fmt.Sprintf("%s（%s渠道）", version, updateChannel().Label())},
		{"自动更新", autoUpdateSummary(a)},
	})
	for _, note := range shellNotes(a) {
		fmt.Println(note)
	}
	if notes := updateNotes(); len(notes) > 0 {
		fmt.Println("\n" + strings.Join(notes, "\n"))
	}
	fmt.Println()
	if err := printEnvs(a); err != nil {
		return err
	}
	if problems := statusProblems(a); len(problems) > 0 {
		fmt.Println("\n需要处理")
		for _, p := range problems {
			fmt.Println("  - " + sentence(p))
		}
	}
	return nil
}

// envHealth 返回环境的健康状况（显示在环境表里），有问题时附上一句原因和处理办法。
func envHealth(a *app.App, cache *state.Cache, e api.Environment) (string, string) {
	if p := vault.Unavailable(cache, a.Keys, e, time.Now().UnixMilli()); p != "" {
		if vault.Expired(e, time.Now().UnixMilli()) {
			return "授权已到期", p
		}
		return "密钥解不开", p
	}
	_, broken, err := vault.Entries(cache, a.Keys, e.ID)
	if err != nil {
		return "密钥解不开", fmt.Sprintf("环境“%s”：%v", e.Name, err)
	}
	if len(broken) > 0 {
		return fmt.Sprintf("%d 个变量解不开", len(broken)), fmt.Sprintf("环境“%s”的变量 %s 无法解密：可以用 harmonia var rm %s <变量名> 删除，或在管理设备上重新写入",
			e.Name, strings.Join(broken, "、"), e.Name)
	}
	return "正常", ""
}

// statusProblems 用本机缓存找出需要处理的问题：环境和变量解不开、授权到期、失效的本机覆盖值、长时间没有同步。
func statusProblems(a *app.App) []string {
	cache, err := a.Dir.Cache()
	if err != nil {
		return []string{err.Error()}
	}
	var out []string
	for _, e := range vault.Ordered(cache) {
		if _, p := envHealth(a, cache, e); p != "" {
			out = append(out, p)
		}
	}
	ov, _ := a.Dir.Overrides()
	ids := make([]string, 0, len(ov))
	for id := range ov {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		env, err := vault.Find(cache, id)
		if err != nil {
			out = append(out, fmt.Sprintf("本机覆盖值所在的环境 %s 已无法访问，覆盖值不生效：用 harmonia override rm %s <变量名> 移除", id, id))
			continue
		}
		var gone []string
		for name := range ov[id] {
			if _, ok := cache.Variables[id][name]; !ok {
				gone = append(gone, name)
			}
		}
		sort.Strings(gone)
		for _, name := range gone {
			out = append(out, fmt.Sprintf("环境“%s”里已经没有 %s，本机覆盖值不生效：用 harmonia override rm %s %s 移除", env.Name, name, env.Name, name))
		}
	}
	if a.Config.LastSync != 0 && time.Since(time.UnixMilli(a.Config.LastSync)) > 24*time.Hour {
		out = append(out, fmt.Sprintf("上次同步是 %s，变量和授权可能不是最新的：运行 harmonia sync；安装后台服务（harmonia service install）可以一直保持同步", ago(a.Config.LastSync)))
	}
	return out
}

func printEnvs(a *app.App) error {
	cache, err := a.Dir.Cache()
	if err != nil {
		return err
	}
	if len(cache.Environments) == 0 {
		fmt.Println(noEnvNotice)
		return nil
	}
	fmt.Println("环境（同名变量由排在前面的环境提供）")
	rows := [][]string{{"", "名称", "权限", "变量", "有效期", "状态", "健康", "ID"}}
	for i, e := range vault.Ordered(cache) {
		state := "未启用"
		if e.Active {
			state = "已启用"
		}
		health, _ := envHealth(a, cache, e)
		rows = append(rows, []string{
			fmt.Sprint(i + 1), e.Name, roleNames[e.Role], fmt.Sprint(len(cache.Variables[e.ID])), expiry(e.ExpiresAt), state, health, e.ID,
		})
	}
	printTable(os.Stdout, "  ", rows)
	if cs := vault.Conflicts(cache, a.Keys, vault.ActiveIDs(cache), time.Now().UnixMilli()); len(cs) > 0 {
		fmt.Println("\n同名变量")
		rows = rows[:0]
		for _, c := range cs {
			rows = append(rows, []string{c.Name, fmt.Sprintf("使用“%s”中的值，同时出现在“%s”", c.Envs[0], strings.Join(c.Envs[1:], "”“"))})
		}
		printTable(os.Stdout, "  ", rows)
	}
	return nil
}

func mask(v string) string {
	if len(v) <= 4 {
		return "****"
	}
	return v[:2] + strings.Repeat("*", 6) + v[len(v)-2:]
}

// noteLine 是列表里显示的备注：多行备注只显示第一行。
func noteLine(note string) string {
	first, rest, more := strings.Cut(note, "\n")
	first = strings.TrimSpace(first)
	if more && strings.TrimSpace(rest) != "" {
		first += " …"
	}
	return first
}

func listVars(a *app.App, envName string, show bool) error {
	cache, err := a.Dir.Cache()
	if err != nil {
		return err
	}
	envs := vault.Ordered(cache)
	if envName != "" {
		e, err := vault.Find(cache, envName)
		if err != nil {
			return err
		}
		envs = envs[:0]
		envs = append(envs, *e)
	}
	if len(envs) == 0 {
		fmt.Println(noEnvNotice)
		return nil
	}
	ov, _ := a.Dir.Overrides()
	for i, e := range envs {
		if i > 0 {
			fmt.Println()
		}
		fmt.Printf("%s（%s）\n", e.Name, roleNames[e.Role])
		vals, broken, err := vault.Entries(cache, a.Keys, e.ID)
		if err != nil {
			fmt.Println("  " + sentence(err.Error()))
			continue
		}
		names := make([]string, 0, len(vals))
		for n := range vals {
			names = append(names, n)
		}
		sort.Strings(names)
		if len(names) == 0 && len(broken) == 0 {
			fmt.Println("  （没有变量）")
			continue
		}
		var rows [][]string
		for _, n := range broken {
			rows = append(rows, []string{n, "（无法解密）", "", ""})
		}
		for _, n := range names {
			v := vals[n].Value
			if !show {
				v = mask(v)
			}
			mark := ""
			if _, ok := ov[e.ID][n]; ok {
				mark = "（本机覆盖）"
			}
			rows = append(rows, []string{n, v, noteLine(vals[n].Note), mark})
		}
		printTable(os.Stdout, "  ", rows)
		if len(broken) > 0 {
			fmt.Printf("  无法解密的变量可以用 harmonia var rm %s <变量名> 删除，或用 harmonia var set 重新写入。\n", e.Name)
		}
	}
	return nil
}

// printOverrides 按环境顺序列出本机覆盖值；已无法访问的环境单独列在最后。
func printOverrides(a *app.App, ov state.Overrides) error {
	if len(ov) == 0 {
		fmt.Println("没有本机覆盖值。")
		return nil
	}
	cache, err := a.Dir.Cache()
	if err != nil {
		return err
	}
	type group struct {
		title string
		vals  map[string]string
	}
	var groups []group
	seen := map[string]bool{}
	for _, e := range vault.Ordered(cache) {
		if len(ov[e.ID]) > 0 {
			groups = append(groups, group{e.Name, ov[e.ID]})
			seen[e.ID] = true
		}
	}
	for id, m := range ov {
		if !seen[id] && len(m) > 0 {
			groups = append(groups, group{fmt.Sprintf("已无法访问的环境 %s（覆盖值不生效，可以用 harmonia override rm %s <变量名> 移除）", id, id), m})
		}
	}
	for i, g := range groups {
		if i > 0 {
			fmt.Println()
		}
		fmt.Println(g.title)
		names := make([]string, 0, len(g.vals))
		for n := range g.vals {
			names = append(names, n)
		}
		sort.Strings(names)
		rows := make([][]string, 0, len(names))
		for _, n := range names {
			rows = append(rows, []string{n, mask(g.vals[n])})
		}
		printTable(os.Stdout, "  ", rows)
	}
	return nil
}
