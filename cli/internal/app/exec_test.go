package app

import (
	"slices"
	"testing"
)

func TestExecEnvReplacesExisting(t *testing.T) {
	got := ExecEnv([]string{"PATH=/bin", "KEY=old", "HOME=/h"}, map[string]string{"KEY": "new", "B": "2"}, nil, false)
	want := []string{"PATH=/bin", "HOME=/h", "B=2", "KEY=new"}
	if !slices.Equal(got, want) {
		t.Fatalf("同名变量应只保留新值：%v", got)
	}
}

func TestExecEnvDropsOtherEnvironments(t *testing.T) {
	// 开启了 Shell 集成的终端里已有两个环境的变量，--env 只选了第一个。
	environ := []string{"PATH=/env-b/bin", "OPENAI_API_KEY=sk-a", "DB_URL=postgres://b", "MINE=1", "TOKEN=my-own"}
	known := map[string]map[string]bool{
		"OPENAI_API_KEY": {"sk-a": true},
		"DB_URL":         {"postgres://b": true},
		"PATH":           {"/env-b/bin": true},
		"TOKEN":          {"from-env-b": true},
	}
	got := ExecEnv(environ, map[string]string{"OPENAI_API_KEY": "sk-a"}, known, false)
	// 其他环境写入的 DB_URL 去掉；PATH 是系统必需的，保留；TOKEN 是用户自己的值，保留。
	want := []string{"PATH=/env-b/bin", "MINE=1", "TOKEN=my-own", "OPENAI_API_KEY=sk-a"}
	if !slices.Equal(got, want) {
		t.Fatalf("应只去掉其他环境写入的变量：%v", got)
	}
}

func TestExecEnvFoldCase(t *testing.T) {
	environ := []string{"=C:=C:\\", "Path=C:\\env", "api_key=old", "Db_Url=x"}
	known := map[string]map[string]bool{"PATH": {"C:\\env": true}, "DB_URL": {"x": true}}
	got := ExecEnv(environ, map[string]string{"API_KEY": "new"}, known, true)
	want := []string{"=C:=C:\\", "Path=C:\\env", "API_KEY=new"}
	if !slices.Equal(got, want) {
		t.Fatalf("Windows 上应不区分大小写，保留以等号开头的条目和系统变量：%v", got)
	}
	if got := ExecEnv([]string{"api_key=old"}, map[string]string{"API_KEY": "new"}, nil, false); len(got) != 2 {
		t.Fatalf("区分大小写时不应去掉：%v", got)
	}
}
