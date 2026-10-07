// 终端输出排版：按显示宽度对齐（中文等全角字符占两列），以及分组的帮助信息。
package main

import (
	"fmt"
	"io"
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
		{"login [服务器地址]", "登录并发起配对，在管理设备上批准后完成接入"},
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
		{"var set <环境> <变量名> [值]", "写入变量，不给值时交互输入"},
		{"var rm <环境> <变量名>", "删除变量"},
		{"import --env <环境>", "从当前终端的环境变量中勾选导入"},
	}},
	{"本机覆盖", [][2]string{
		{"override set <环境> <变量名> [值]", "设置只在这台设备生效的值"},
		{"override rm <环境> <变量名>", "移除本机覆盖"},
		{"override list", "列出本机覆盖"},
	}},
	{"使用变量", [][2]string{
		{"exec [--env a,b] -- <命令...>", "带上变量运行命令；--env 按列出的顺序，靠前的优先"},
		{"export [--format sh|dotenv|json]", "输出当前生效的变量"},
	}},
	{"安装与维护", [][2]string{
		{"shell install|uninstall", "在 shell 启动文件中加载变量（--shell zsh|bash 指定 shell）"},
		{"service install|uninstall|status", "管理后台同步服务"},
		{"update [--check]", "检查并升级 harmonia"},
		{"update channel [stable|beta]", "查看或切换更新渠道（正式版 / 测试版）"},
		{"logout", "退出账号并清除本机数据"},
		{"uninstall", "退出账号、移除服务与 shell 集成，并删除 harmonia"},
		{"version", "显示版本"},
	}},
}

func printHelp(out io.Writer) {
	fmt.Fprintln(out, "Harmonia（和弦）：在手机上管理环境变量，同步到这台电脑。")
	fmt.Fprintln(out)
	fmt.Fprintln(out, "用法：harmonia <命令> [参数]")
	// 所有分组共用一个命令列宽，说明文字从同一列开始。
	w := 0
	for _, g := range helpGroups {
		for _, c := range g.cmds {
			w = max(w, width(c[0]))
		}
	}
	for _, g := range helpGroups {
		fmt.Fprintln(out)
		fmt.Fprintln(out, g.title)
		for _, c := range g.cmds {
			fmt.Fprintf(out, "  %s  %s\n", pad(c[0], w), c[1])
		}
	}
}
