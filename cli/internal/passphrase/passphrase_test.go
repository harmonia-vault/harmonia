package passphrase

import (
	"strings"
	"testing"
)

func TestValidate(t *testing.T) {
	ok := []string{"Hqzvmtkw", "hqzv-mtkw", "tr0ub4dor&3", "correct horse battery", "HQZVMTK7", "4815162342!", strings.Repeat("aB", 64)}
	for _, p := range ok {
		if err := Validate(p); err != nil {
			t.Errorf("%q 应当通过：%v", p, err)
		}
	}
	bad := map[string]string{
		"Abc1234":                "至少需要 8 个字符",
		strings.Repeat("aB", 65): "最长 128 个字符",
		"abcdefgh":               "至少两类",
		"12345678":               "至少两类",
		"!@#$%^&*":               "至少两类",
		"口令口令口令abc1":             "只能使用",
		"abcd\tefg1":             "只能使用",
		" abcdefg1":              "空格开头或结尾",
		"abcdefg1 ":              "空格开头或结尾",
		"password1":              "太常见",
		"Password1":              "太常见",
		"PASSWORD1":              "太常见",
		"Password":               "太常见",
		"qwerty123":              "太常见",
	}
	for p, want := range bad {
		err := Validate(p)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q 应当因“%s”被拒绝，实际：%v", p, want, err)
		}
	}
}

func TestCommonListShape(t *testing.T) {
	lines := strings.Split(strings.TrimSuffix(strings.ReplaceAll(commonList, "\r\n", "\n"), "\n"), "\n")
	if len(lines) < 30000 {
		t.Fatalf("常见口令表只有 %d 条，文件可能不完整", len(lines))
	}
	for i, l := range lines {
		if len(l) < MinLen || l != strings.ToLower(l) {
			t.Fatalf("第 %d 行 %q 不是 8 位以上的小写条目", i+1, l)
		}
		if i > 0 && lines[i-1] >= l {
			t.Fatalf("第 %d 行没有按顺序排列或有重复", i+1)
		}
	}
}
