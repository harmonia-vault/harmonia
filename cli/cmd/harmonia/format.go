// 终端输出排版：按显示宽度对齐（中文等全角字符占两列），以及分组的帮助信息。
package main

import (
	"fmt"
	"io"
	"slices"
	"strings"
	"unicode/utf8"
)

// wide 判断字符在终端中是否占两列（东亚全角字符）。
func wide(r rune) bool {
	return r >= 0x1100 && (r <= 0x115F || // 谚文字母
		(r >= 0x2E80 && r <= 0x303E) || // 中日韩部首、符号与标点
		(r >= 0x3041 && r <= 0x33FF) || // 假名、注音、中日韩兼容字符
		(r >= 0x3400 && r <= 0x4DBF) || // 中日韩统一表意文字扩展 A
		(r >= 0x4E00 && r <= 0x9FFF) || // 中日韩统一表意文字
		(r >= 0xA000 && r <= 0xA4CF) || // 彝文
		(r >= 0xAC00 && r <= 0xD7A3) || // 谚文音节
		(r >= 0xF900 && r <= 0xFAFF) || // 中日韩兼容表意文字
		(r >= 0xFE30 && r <= 0xFE4F) || // 中日韩兼容形式
		(r >= 0xFF00 && r <= 0xFF60) || // 全角 ASCII 与标点
		(r >= 0xFFE0 && r <= 0xFFE6) ||
		(r >= 0x20000 && r <= 0x3FFFD))
}

// width 返回字符串在终端中占的列数。
func width(s string) int {
	n := 0
	for _, r := range s {
		if wide(r) {
			n += 2
		} else {
			n++
		}
	}
	return n
}

// pad 在右侧补空格，使字符串占满 w 列。
func pad(s string, w int) string {
	if d := w - width(s); d > 0 {
		return s + strings.Repeat(" ", d)
	}
	return s
}

// printTable 按列对齐输出：每行以 indent 开头，列之间空两格，最后一列不补齐。
func printTable(out io.Writer, indent string, rows [][]string) {
	var widths []int
	for _, row := range rows {
		for i, cell := range row {
			if i >= len(widths) {
				widths = append(widths, 0)
			}
			widths[i] = max(widths[i], width(cell))
		}
	}
	for _, row := range rows {
		cells := make([]string, len(row))
		for i, cell := range row {
			if i < len(row)-1 {
				cell = pad(cell, widths[i])
			}
			cells[i] = cell
		}
		fmt.Fprintln(out, strings.TrimRight(indent+strings.Join(cells, "  "), " "))
	}
}

// sentence 让一句话以句末标点结尾，用于错误信息。
func sentence(s string) string {
	r, _ := utf8.DecodeLastRuneInString(s)
	if strings.ContainsRune("。！？.!?", r) {
		return s
	}
	return s + "。"
}

// helpGroups 是 harmonia help 的内容，按用途分组。
var helpGroups = []struct {
	title string
	cmds  [][2]string
}{
	{"接入与同步", [][2]string{
		{"login [服务器地址] [--email 邮箱] [--code 配对码] [--name 设备名]", "发起配对，在管理设备上核对并批准后完成接入；配对码可以留空，改用扫码；设备名默认用主机名"},
		{"status", "查看接入状态、环境和后台服务"},
		{"sync", "立即同步"},
	}},
	{"环境", [][2]string{
		{"env list", "列出环境、顺序和同名变量"},
		{"env activate <环境>", "启用环境（授权的环境默认已启用）"},
		{"env deactivate <环境>", "停用环境"},
		{"env order <环境>...", "把这些环境依次移到最前面，同名变量由靠前的提供"},
	}},
	{"变量", [][2]string{
		{"var list [--env 环境] [--show]", "列出变量，默认隐藏值"},
		{"var set <环境> <变量名> [值] [--note 备注]", "写入变量，不给值时交互输入；只给 --note 时只改备注"},
		{"var rm <环境> <变量名>", "删除变量"},
		{"import --env <环境>", "从当前终端的环境变量中勾选导入"},
	}},
	{"本机覆盖", [][2]string{
		{"override set <环境> <变量名> [值]", "设置只在这台设备生效的值"},
		{"override rm <环境> <变量名>", "移除本机覆盖"},
		{"override list", "列出本机覆盖"},
	}},
	{"使用变量", [][2]string{
		{"exec [--env a,b] -- <命令...>", "带上变量运行命令；--env 只用这些环境（可重复给出），靠前的优先"},
		{"export [--env a,b] [--format sh|dotenv|json]", "输出当前生效的变量；--env 只用这些环境，靠前的优先"},
	}},
	{"管理登录（让这台电脑成为管理设备，需要在手机上批准）", [][2]string{
		{"manager [--port 端口] [--no-open]", "在浏览器里打开本机管理页面：管理登录、环境和变量的批量管理"},
		{"manager login", "同上，直接进入管理登录"},
		{"manager logout [--yes]", "退出管理登录，删除这台电脑上的管理密钥；--yes 不再确认"},
		{"manager status", "查看是否已管理登录"},
	}},
	{"安装与维护", slices.Concat(shellHelp, [][2]string{
		{"service install|uninstall|status", "管理后台同步服务"},
		{"update [--check]", "检查并升级 harmonia"},
		{"update channel [stable|beta]", "查看或切换更新渠道（正式版 / 测试版）"},
		{"skill [install [--dir 目录]]", "输出给 AI 助手的使用说明；install 保存成技能文件"},
		{"logout [--yes]", "退出账号并清除本机数据（不影响管理登录）；--yes 不再确认"},
		{"uninstall [--yes]", uninstallSummary + "；--yes 不再确认"},
		{"version", "显示版本"},
	})},
}

// helpWrap 是命令列的最大宽度：更长的命令单独占一行，说明换到下一行，免得把所有说明挤到右边。
const helpWrap = 44

// printCommands 按共用的命令列宽输出若干条命令和说明。
func printCommands(out io.Writer, cmds [][2]string, w int) {
	for _, c := range cmds {
		if width(c[0]) > w {
			fmt.Fprintf(out, "  %s\n  %s  %s\n", c[0], pad("", w), c[1])
		} else {
			fmt.Fprintf(out, "  %s  %s\n", pad(c[0], w), c[1])
		}
	}
}

// commandWidth 返回命令列的宽度：不超过 helpWrap 的命令中最宽的那个。
func commandWidth(cmds [][2]string) int {
	w := 0
	for _, c := range cmds {
		if n := width(c[0]); n <= helpWrap {
			w = max(w, n)
		}
	}
	return w
}

func printHelp(out io.Writer) {
	fmt.Fprintln(out, "Harmonia（和弦）：在手机上管理环境变量，同步到这台电脑。")
	fmt.Fprintln(out)
	fmt.Fprintln(out, "用法：harmonia <命令> [参数]")
	// 所有分组共用一个命令列宽，说明文字从同一列开始。
	var all [][2]string
	for _, g := range helpGroups {
		all = append(all, g.cmds...)
	}
	w := commandWidth(all)
	for _, g := range helpGroups {
		fmt.Fprintln(out)
		fmt.Fprintln(out, g.title)
		printCommands(out, g.cmds, w)
	}
	fmt.Fprintln(out)
	fmt.Fprintln(out, "在命令后加 --help 查看这条命令的用法，例如 harmonia var --help。")
}

// printCommandHelp 输出一条命令（例如 var）的用法；帮助里没有这条命令时输出全部帮助。
func printCommandHelp(out io.Writer, name string) {
	var cmds [][2]string
	for _, g := range helpGroups {
		for _, c := range g.cmds {
			if strings.Fields(c[0])[0] == name {
				cmds = append(cmds, [2]string{"harmonia " + c[0], c[1]})
			}
		}
	}
	if len(cmds) == 0 {
		printHelp(out)
		return
	}
	fmt.Fprintln(out, "用法：")
	printCommands(out, cmds, commandWidth(cmds))
}
