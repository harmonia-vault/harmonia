package shell

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEnsurePreparesWithoutChangingDeviceSettings(t *testing.T) {
	for _, name := range []string{"bash", "zsh"} {
		t.Run(name, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			t.Setenv("USERPROFILE", home)
			t.Setenv("SHELL", "/bin/"+name)
			t.Setenv("ZDOTDIR", home)
			env := filepath.Join(home, "env.sh")
			cache := filepath.Join(home, "cache.json")
			for _, settings := range []string{`{"shellEnabled":false}`, `{"shellEnabled":true}`} {
				if err := os.WriteFile(cache, []byte(settings), 0o600); err != nil {
					t.Fatal(err)
				}
				if err := Ensure(env); err != nil {
					t.Fatal(err)
				}
				if err := Ready(env); err != nil {
					t.Fatal(err)
				}
				if _, err := os.Stat(env); !os.IsNotExist(err) {
					t.Fatal("准备步骤不应生成变量文件")
				}
				got, err := os.ReadFile(cache)
				if err != nil || string(got) != settings {
					t.Fatalf("不应修改设备设置：%s %v", got, err)
				}
			}
		})
	}
}

func TestEnsureRefreshesSavedSymlinkWithoutChangingItsTarget(t *testing.T) {
	root := t.TempDir()
	env := filepath.Join(root, "env.sh")
	actual := filepath.Join(root, "dotfile")
	link := filepath.Join(root, ".zshenv")
	content := "# user\n" + SourceLine(env)
	if err := os.WriteFile(actual, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(actual, link); err != nil {
		t.Skip(err)
	}
	if err := Prepare(env, []Target{{Shell: "zsh", Path: link}}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(IntegrationFile(env), []byte("# previous script\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", "/bin/bash")
	t.Setenv("ZDOTDIR", t.TempDir())
	if err := Ensure(env); err != nil {
		t.Fatal(err)
	}
	if err := Ready(env); err != nil {
		t.Fatalf("没有按记录的位置刷新：%v", err)
	}
	got, err := os.ReadFile(actual)
	if err != nil || string(got) != content {
		t.Fatalf("改写了符号链接目标：%s %v", got, err)
	}
	if _, err := os.Readlink(link); err != nil {
		t.Fatal(err)
	}
}
