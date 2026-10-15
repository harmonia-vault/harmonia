package app

import (
	"reflect"
	"testing"
)

func TestParseDotenv(t *testing.T) {
	text := "\xEF\xBB\xBF# 注释\r\n" +
		"PLAIN=value with spaces   \r\n" +
		"export EXPORTED=1\n" +
		"INLINE=abc # 行尾注释\n" +
		"HASH=abc#不是注释\n" +
		"EMPTY=\n" +
		"SINGLE='原样 $HOME \\n'\n" +
		"DOUBLE=\"a\\nb \\\"q\\\" \\$x \\\\ \\z\" # 注释\n" +
		"MULTI=\"第一行\n第二行\"\n" +
		"PLAIN=later\n" +
		"1BAD=x\n" +
		"没有等号\n" +
		"OPEN='没有闭合\n"
	vars, names, errs := ParseDotenv(text)
	want := map[string]string{
		"PLAIN": "later", "EXPORTED": "1", "INLINE": "abc", "HASH": "abc#不是注释", "EMPTY": "",
		"SINGLE": "原样 $HOME \\n", "DOUBLE": "a\nb \"q\" $x \\ \\z", "MULTI": "第一行\n第二行",
	}
	if !reflect.DeepEqual(vars, want) {
		t.Errorf("变量不对：\n得到 %q\n期望 %q", vars, want)
	}
	if got := []string{"PLAIN", "EXPORTED", "INLINE", "HASH", "EMPTY", "SINGLE", "DOUBLE", "MULTI"}; !reflect.DeepEqual(names, got) {
		t.Errorf("顺序不对：%v", names)
	}
	var lines []int
	for _, e := range errs {
		lines = append(lines, e.Line)
	}
	if !reflect.DeepEqual(lines, []int{12, 13, 14}) {
		t.Errorf("出错的行不对：%v（%v）", lines, errs)
	}
}
