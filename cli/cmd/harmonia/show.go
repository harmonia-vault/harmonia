// 展示类命令与输出：接入状态、环境列表、变量列表。
package main

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

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
	printTable(os.Stdout, "", [][]string{
		{"账号", a.Config.Email},
		{"服务器", a.Config.Server},
		{"本机", a.Config.DeviceName},
		{"上次同步", ago(a.Config.LastSync)},
		{"后台服务", serviceSummary()},
		{"Shell 集成", shellSummary(a.Dir)},
		{"版本", fmt.Sprintf("%s（%s渠道）", version, updateChannel().Label())},
	})
	if hint := updateHint(); hint != "" {
		fmt.Println("\n" + hint)
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
	fmt.Println("环境（同名变量由排在前面的环境提供）")
	rows := [][]string{{"", "名称", "权限", "变量", "有效期", "状态"}}
	for i, e := range vault.Ordered(cache) {
		state := "未启用"
		if e.Active {
			state = "已启用"
		}
		rows = append(rows, []string{
			fmt.Sprint(i + 1), e.Name, roleNames[e.Role], fmt.Sprint(len(cache.Variables[e.ID])), expiry(e.ExpiresAt), state,
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
	ov, _ := a.Dir.Overrides()
	for i, e := range envs {
		if i > 0 {
			fmt.Println()
		}
		fmt.Printf("%s（%s）\n", e.Name, roleNames[e.Role])
		vals, err := vault.Values(cache, a.Keys, e.ID)
		if err != nil {
			fmt.Println("  " + sentence(err.Error()))
			continue
		}
		names := make([]string, 0, len(vals))
		for n := range vals {
			names = append(names, n)
		}
		sort.Strings(names)
		if len(names) == 0 {
			fmt.Println("  （没有变量）")
			continue
		}
		var rows [][]string
		for _, n := range names {
			v := vals[n]
			if !show {
				v = mask(v)
			}
			note := ""
			if _, ok := ov[e.ID][n]; ok {
				note = "（本机覆盖）"
			}
			rows = append(rows, []string{n, v, note})
		}
		printTable(os.Stdout, "  ", rows)
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
			groups = append(groups, group{fmt.Sprintf("已无法访问的环境 %s（覆盖值不生效）", id), m})
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
