// 变量命令：列出、写入、删除和批量导入。
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/app"
	"golang.org/x/term"
)

func cmdVar(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "env=", "note=", "show", "yes")
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
		return listVars(a, f.values["env"], f.bools["show"])
	}
	switch f.args[0] {
	case "set":
		if len(f.args) < 3 || len(f.args) > 4 {
			return errors.New("用法：harmonia var set <变量库|环境> <变量名> [值] [--note 备注] [--yes]。新增变量要指定变量库")
		}
		target, name := f.args[1], f.args[2]
		if !confirmWrite(a, target, name, false, f.bools["yes"]) {
			fmt.Println("已取消。")
			return nil
		}
		var ch app.VarChange
		if note, ok := f.values["note"]; ok {
			ch.Note = &note
		}
		if len(f.args) == 4 {
			ch.Value = &f.args[3]
		} else if ch.Note == nil {
			value, err := promptSecret(fmt.Sprintf("%s 的值：", name))
			if err != nil {
				return err
			}
			ch.Value = &value
		}
		res, err := a.SetVariables(ctx, target, false, map[string]app.VarChange{name: ch}, false)
		if err != nil && res == nil {
			return err
		}
		if res[0].Status == app.Failed {
			return res[0].Err
		}
		if err != nil {
			return err
		}
		fmt.Printf("已写入 %s，回读校验一致。\n", name)
		notes, err := a.Shadowing(target, name)
		if err != nil {
			return err
		}
		for _, n := range notes {
			fmt.Println("注意：" + sentence(n))
		}
	case "rm":
		if len(f.args) != 3 {
			return errors.New("用法：harmonia var rm <变量库|环境> <变量名> [--yes]")
		}
		if !confirmWrite(a, f.args[1], f.args[2], true, f.bools["yes"]) {
			fmt.Println("已取消。")
			return nil
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

// confirmWrite 在终端里修改或删除已有变量前确认：写的是变量库里的原变量，会影响所有引用它的环境。
// 给了 --yes 或不在终端里运行时不询问，只提示。
func confirmWrite(a *app.App, target, name string, del, yes bool) bool {
	notice := a.WriteNotice(target, name, del)
	if notice == "" {
		return true
	}
	if yes || !term.IsTerminal(int(os.Stdin.Fd())) {
		fmt.Fprintln(os.Stderr, "注意："+sentence(notice))
		return true
	}
	return confirmYes(notice + "。继续吗？")
}

func cmdImport(ctx context.Context, args []string) error {
	f, err := parseFlags(args, "vault=", "file=", "format=", "json")
	if err != nil {
		return err
	}
	if f.values["vault"] == "" {
		return errors.New("用法：harmonia import --vault <变量库> [--file 文件|-] [--format dotenv|json] [--json]")
	}
	a, err := app.Load(true)
	if err != nil {
		return err
	}
	var vars map[string]string
	if file, ok := f.values["file"]; ok {
		if vars, err = readImportFile(file, f.values["format"]); err != nil {
			return err
		}
		if len(vars) == 0 {
			fmt.Println("文件里没有变量。")
			return nil
		}
	} else {
		if f.values["format"] != "" {
			return usageError("--format 只能和 --file 一起使用")
		}
		if vars = pickFromTerminal(); vars == nil {
			return nil
		}
	}
	changes := make(map[string]app.VarChange, len(vars))
	for n, v := range vars {
		changes[n] = app.VarChange{Value: &v}
	}
	res, err := a.SetVariables(ctx, f.values["vault"], true, changes, true)
	if res == nil {
		return err
	}
	var unverified *app.UnverifiedError
	if err != nil && !errors.As(err, &unverified) {
		return err
	}
	failed := printImportResults(res, f.bools["json"], unverified)
	if unverified != nil {
		return err
	}
	if failed > 0 {
		return fmt.Errorf("有 %d 个变量没有写入。处理后重新运行同一条命令即可，已写入的会显示未变化", failed)
	}
	return nil
}

// readImportFile 读取要导入的文件（“-”表示标准输入）。format 为空时按内容判断：以“{”开头的是 JSON。
// 有解析不了的内容时整份不导入。
func readImportFile(path, format string) (map[string]string, error) {
	var (
		data []byte
		err  error
	)
	if path == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		data, err = os.ReadFile(path)
	}
	if err != nil {
		return nil, fmt.Errorf("读取 %s 失败：%w", path, err)
	}
	text := string(data)
	if format == "" {
		format = "dotenv"
		if strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(text, "\xEF\xBB\xBF")), "{") {
			format = "json"
		}
	}
	switch format {
	case "json":
		var raw map[string]any
		if err := json.Unmarshal([]byte(strings.TrimPrefix(text, "\xEF\xBB\xBF")), &raw); err != nil {
			return nil, fmt.Errorf("JSON 格式不对（%v），没有写入任何变量。需要一个对象，键是变量名，值是字符串", err)
		}
		vars := make(map[string]string, len(raw))
		var bad []string
		for n, v := range raw {
			s, ok := v.(string)
			if !ok {
				bad = append(bad, n)
				continue
			}
			vars[n] = s
		}
		if len(bad) > 0 {
			sort.Strings(bad)
			return nil, fmt.Errorf("%s 的值不是字符串，没有写入任何变量", strings.Join(bad, "、"))
		}
		return vars, nil
	case "dotenv":
		vars, _, errs := app.ParseDotenv(text)
		if len(errs) > 0 {
			for _, e := range errs {
				fmt.Fprintf(os.Stderr, "  第 %d 行：%s\n", e.Line, e.Message)
			}
			return nil, fmt.Errorf("文件中有 %d 处无法识别，没有写入任何变量。修正后重新运行", len(errs))
		}
		return vars, nil
	}
	return nil, usageError("--format 只能是 dotenv 或 json")
}

// pickFromTerminal 列出当前终端里的变量，让用户勾选要导入的；取消时返回 nil。
func pickFromTerminal() map[string]string {
	cands := app.ImportCandidates()
	names := make([]string, 0, len(cands))
	for n := range cands {
		names = append(names, n)
	}
	sort.Strings(names)
	if len(names) == 0 {
		fmt.Println("当前终端没有可以导入的变量。要从文件导入，使用 --file。")
		return nil
	}
	fmt.Println("当前终端中的变量：")
	for i, n := range names {
		fmt.Printf("  %3d  %s=%s\n", i+1, n, mask(cands[n]))
	}
	for {
		ans, err := prompt("输入要导入的编号（用逗号或空格分隔，直接回车取消）：")
		if err != nil || ans == "" {
			fmt.Println("已取消。")
			return nil
		}
		picked := map[string]string{}
		var bad string
		for _, tok := range strings.FieldsFunc(ans, func(r rune) bool { return r == ',' || r == ' ' || r == '，' }) {
			i, err := strconv.Atoi(tok)
			if err != nil || i < 1 || i > len(names) {
				bad = tok
				break
			}
			picked[names[i-1]] = cands[names[i-1]]
		}
		if bad == "" {
			return picked
		}
		fmt.Printf("编号“%s”不对，请重新输入。\n", bad)
	}
}

var statusText = map[string]string{app.Written: "已写入", app.Unchanged: "未变化", app.Failed: "失败"}

// printImportResults 逐条输出导入结果，返回失败的个数。
func printImportResults(res []app.VarResult, asJSON bool, unverified *app.UnverifiedError) int {
	count := map[string]int{}
	for _, r := range res {
		count[r.Status]++
	}
	if asJSON {
		type item struct {
			Name   string `json:"name"`
			Status string `json:"status"`
			Error  string `json:"error,omitempty"`
		}
		out := struct {
			Results  []item `json:"results"`
			Verified bool   `json:"verified"`
		}{Results: []item{}, Verified: unverified == nil}
		for _, r := range res {
			it := item{Name: r.Name, Status: r.Status}
			if r.Err != nil {
				it.Error = sentence(r.Err.Error())
			}
			out.Results = append(out.Results, it)
		}
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		enc.Encode(out)
		return count[app.Failed]
	}
	rows := make([][]string, 0, len(res))
	for _, r := range res {
		row := []string{statusText[r.Status], r.Name}
		if r.Err != nil {
			row = append(row, sentence(r.Err.Error()))
		}
		rows = append(rows, row)
	}
	printTable(os.Stdout, "  ", rows)
	check := "，已回读校验"
	if unverified != nil {
		check = ""
	}
	fmt.Printf("已写入 %d 个%s；未变化 %d 个；失败 %d 个。\n", count[app.Written], check, count[app.Unchanged], count[app.Failed])
	return count[app.Failed]
}
