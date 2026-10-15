package manager

import (
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/app"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
)

// ParseError 是批量导入时某一行的问题；Line 从 1 开始。
type ParseError struct {
	Line    int    `json:"line"`
	Message string `json:"message"`
}

// ParseDotenv 解析 .env 格式的文本：每行 名称=值，支持 # 注释、export 前缀、单引号（原样）、
// 双引号（\n、\t、\"、\\、\$ 转义）和跨行的引号值。同名变量以后出现的为准。names 按首次出现的顺序排列。
func ParseDotenv(text string) (vars map[string]string, names []string, errs []ParseError) {
	vars = map[string]string{}
	text = strings.ReplaceAll(strings.TrimPrefix(text, "\xEF\xBB\xBF"), "\r\n", "\n")
	lines := strings.Split(text, "\n")
	for i := 0; i < len(lines); i++ {
		start := i + 1
		fail := func(msg string) { errs = append(errs, ParseError{Line: start, Message: msg}) }
		line := strings.TrimSpace(lines[i])
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if rest, ok := strings.CutPrefix(line, "export "); ok {
			line = strings.TrimSpace(rest)
		}
		name, raw, ok := strings.Cut(line, "=")
		if !ok {
			fail("这一行不是“名称=值”的格式")
			continue
		}
		name, raw = strings.TrimSpace(name), strings.TrimLeft(raw, " \t")
		var value string
		switch {
		case strings.HasPrefix(raw, `"`), strings.HasPrefix(raw, `'`):
			quote := raw[0]
			body := raw[1:]
			end := closing(body, quote)
			for end < 0 && i+1 < len(lines) {
				i++
				body += "\n" + lines[i]
				end = closing(body, quote)
			}
			if end < 0 {
				fail("引号没有闭合")
				continue
			}
			if tail := strings.TrimSpace(body[end+1:]); tail != "" && !strings.HasPrefix(tail, "#") {
				fail("引号后面有多余的内容")
				continue
			}
			value = body[:end]
			if quote == '"' {
				value = unescape(value)
			}
		default:
			if at := strings.Index(raw, " #"); at >= 0 {
				raw = raw[:at]
			}
			value = strings.TrimRight(raw, " \t")
		}
		if err := app.ValidateName(name); err != nil {
			fail(err.Error())
			continue
		}
		if len(value) > hc.MaxValueLen {
			fail("变量 " + name + " 的值超过 64 KB")
			continue
		}
		if _, seen := vars[name]; !seen {
			names = append(names, name)
		}
		vars[name] = value
	}
	return vars, names, errs
}

// closing 返回结束引号的位置；双引号里被反斜杠转义的引号不算。没有找到时返回 -1。
func closing(s string, quote byte) int {
	for i := 0; i < len(s); i++ {
		if quote == '"' && s[i] == '\\' {
			i++
			continue
		}
		if s[i] == quote {
			return i
		}
	}
	return -1
}

func unescape(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 == len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		switch s[i] {
		case 'n':
			b.WriteByte('\n')
		case 'r':
			b.WriteByte('\r')
		case 't':
			b.WriteByte('\t')
		case '\\', '"', '$':
			b.WriteByte(s[i])
		default:
			b.WriteByte('\\')
			b.WriteByte(s[i])
		}
	}
	return b.String()
}
