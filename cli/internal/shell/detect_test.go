package shell

import (
	"errors"
	"testing"
)

func TestDetectUsesTerminalOrLoginShell(t *testing.T) {
	got, err := detect("/usr/local/bin/bash", func() (string, error) { t.Fatal("有 SHELL 时不应查询系统"); return "", nil })
	if err != nil || got != "bash" {
		t.Fatalf("终端选择错误：%s %v", got, err)
	}
	for _, name := range []string{"bash", "zsh"} {
		got, err := detect("", func() (string, error) { return "/bin/" + name, nil })
		if err != nil || got != name {
			t.Fatalf("后台登录终端选择错误：%s %v", got, err)
		}
	}
	if _, err := detect("/bin/fish", func() (string, error) { return "/bin/zsh", nil }); err == nil {
		t.Fatal("不应把其他终端当作 Zsh")
	}
	if _, err := detect("", func() (string, error) { return "", errors.New("lookup failed") }); err == nil {
		t.Fatal("查询失败不应猜测终端")
	}
}
