package shell

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestPrepareTracksCustomConfigAndRequiresEveryEntry(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	zdot := filepath.Join(root, "custom-zsh")
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(zdot, 0o700); err != nil {
		t.Fatal(err)
	}
	env := filepath.Join(root, "env.sh")
	t.Setenv("ZDOTDIR", zdot)
	targets, err := Targets(home, "zsh")
	if err != nil {
		t.Fatal(err)
	}
	if err := Prepare(env, targets); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZDOTDIR", home)
	if err := Ready(env); err != nil {
		t.Fatalf("不应使用后台服务的 ZDOTDIR：%v", err)
	}
	if _, err := os.Stat(env); !os.IsNotExist(err) {
		t.Fatal("预装不应写出变量")
	}
	if err := os.WriteFile(filepath.Join(home, ".bash_login"), []byte("# keep\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	bash, err := Targets(home, "bash")
	if err != nil {
		t.Fatal(err)
	}
	if bash[1].Path != filepath.Join(home, ".bash_login") {
		t.Fatalf("没有使用实际登录文件：%v", bash)
	}
	if err := Prepare(env, bash); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(targets[0].Path); err != nil {
		t.Fatal(err)
	}
	if !errors.Is(Ready(env), ErrNotReady) {
		t.Fatal("其中一个入口丢失时不应回报成功")
	}
}

func TestPrepareSymlinkNeedsManualEntry(t *testing.T) {
	root := t.TempDir()
	actual := filepath.Join(root, "dotfile")
	link := filepath.Join(root, ".zshenv")
	env := filepath.Join(root, "env.sh")
	if err := os.WriteFile(actual, []byte("# user\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(actual, link); err != nil {
		t.Skip(err)
	}
	if err := Prepare(env, []Target{{Shell: "zsh", Path: link}}); !errors.Is(err, ErrSymlink) {
		t.Fatalf("不应改写符号链接：%v", err)
	}
	if !errors.Is(Ready(env), ErrNotReady) {
		t.Fatal("手动配置完成前不应生效")
	}
	if err := os.WriteFile(actual, []byte("# user\n"+SourceLine(env)), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Ready(env); err != nil {
		t.Fatalf("手动配置后应可用：%v", err)
	}
}

func TestRemoveKeepsSymlinkAndCompletesCleanup(t *testing.T) {
	root := t.TempDir()
	actual := filepath.Join(root, "dotfile")
	link := filepath.Join(root, ".zshenv")
	env := filepath.Join(root, "env.sh")
	if err := os.WriteFile(actual, []byte("# user\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(actual, link); err != nil {
		t.Skip(err)
	}
	if err := Prepare(env, []Target{{Shell: "zsh", Path: link}}); !errors.Is(err, ErrSymlink) {
		t.Fatal(err)
	}
	content := "# user\n" + SourceLine(env)
	if err := os.WriteFile(actual, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(env, Render(map[string]string{"TOKEN": "demo-only"}), 0o600); err != nil {
		t.Fatal(err)
	}
	manual, err := Remove(env)
	if err != nil || len(manual) != 1 || manual[0] != link {
		t.Fatalf("应继续卸载并返回手动清理位置：%v %v", manual, err)
	}
	for _, path := range []string{env, IntegrationFile(env), setupFile(env)} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("没有清理 %s", path)
		}
	}
	got, err := os.ReadFile(actual)
	if err != nil || string(got) != content {
		t.Fatalf("不应改动用户的 dotfile：%s %v", got, err)
	}
	if _, err := os.Readlink(link); err != nil {
		t.Fatalf("不应删除符号链接：%v", err)
	}
}
