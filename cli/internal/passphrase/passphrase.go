// Package passphrase 检查管理口令是否符合规则（docs/rewrite-plan.md 16.4）。
// 规则和常见口令表只在设置、修改口令时使用；解锁时只看口令能否解开密钥。
package passphrase

import (
	_ "embed"
	"errors"
	"strings"
	"sync"
)

const (
	MinLen = 8
	MaxLen = 128
)

//go:embed common-passwords.txt
var commonList string

var (
	commonOnce sync.Once
	common     map[string]struct{}
)

// isCommon 判断口令（不区分大小写）是否在常见口令表中。
func isCommon(p string) bool {
	commonOnce.Do(func() {
		lines := strings.Split(commonList, "\n")
		common = make(map[string]struct{}, len(lines))
		for _, l := range lines {
			if l != "" {
				common[l] = struct{}{}
			}
		}
	})
	_, ok := common[strings.ToLower(p)]
	return ok
}

// Validate 检查新口令：长度、可用字符、四类字符中至少两类、不在常见口令表中。
func Validate(p string) error {
	if len(p) < MinLen {
		return errors.New("口令至少需要 8 个字符")
	}
	if len(p) > MaxLen {
		return errors.New("口令最长 128 个字符")
	}
	var upper, lower, digit, symbol bool
	for _, r := range p {
		switch {
		case r >= 'A' && r <= 'Z':
			upper = true
		case r >= 'a' && r <= 'z':
			lower = true
		case r >= '0' && r <= '9':
			digit = true
		case r >= 0x20 && r <= 0x7E:
			symbol = true
		default:
			return errors.New("口令只能使用英文字母、数字和键盘上的符号")
		}
	}
	if p[0] == ' ' || p[len(p)-1] == ' ' {
		return errors.New("口令不能以空格开头或结尾")
	}
	classes := 0
	for _, has := range []bool{upper, lower, digit, symbol} {
		if has {
			classes++
		}
	}
	if classes < 2 {
		return errors.New("口令需要包含大写字母、小写字母、数字、符号中的至少两类")
	}
	if isCommon(p) {
		return errors.New("这个口令太常见，请换一个")
	}
	return nil
}
