package shell

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenderIsSafeForShell(t *testing.T) {
	vars := map[string]string{
		"A": "plain",
		"B": "it's $(echo pwned) `id` \"q\"\nline2",
		"C": "",
	}
	dir := t.TempDir()
	f := filepath.Join(dir, "env.sh")
	if err := os.WriteFile(f, Render(vars), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, sh := range []string{"sh", "bash", "zsh"} {
		if _, err := exec.LookPath(sh); err != nil {
			continue
		}
		out, err := exec.Command(sh, "-c", `. "$1"; printf '%s|%s|%s' "$A" "$B" "${C-unset}"`, sh, f).Output()
		if err != nil {
			t.Fatal(sh, err)
		}
		want := "plain|" + vars["B"] + "|"
		if string(out) != want {
			t.Errorf("%s: got %q want %q", sh, out, want)
		}
	}
}

func TestInstallUninstallKeepsUserContent(t *testing.T) {
	dir := t.TempDir()
	rc := filepath.Join(dir, ".zshenv")
	orig := "export FOO=mine\nalias ll='ls -l'"
	os.WriteFile(rc, []byte(orig), 0o640)
	if err := Install(rc, "/tmp/x/env.sh"); err != nil {
		t.Fatal(err)
	}
	if err := Install(rc, "/tmp/x/env.sh"); err != nil { // 重复安装不重复添加
		t.Fatal(err)
	}
	data, _ := os.ReadFile(rc)
	if strings.Count(string(data), beginMark) != 1 || !strings.HasPrefix(string(data), orig) {
		t.Fatalf("unexpected rc: %q", data)
	}
	if fi, _ := os.Stat(rc); fi.Mode().Perm() != 0o640 {
		t.Errorf("mode changed: %v", fi.Mode())
	}
	if !Installed(rc) {
		t.Error("should be installed")
	}
	if err := Uninstall(rc); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(rc)
	if strings.TrimRight(string(data), "\n") != orig {
		t.Fatalf("uninstall left %q", data)
	}
	link := filepath.Join(dir, ".bashrc")
	os.Symlink(rc, link)
	if err := Install(link, "/x"); err != ErrSymlink {
		t.Errorf("symlink should be refused, got %v", err)
	}
}

func TestSourceOrderRestoresUserValue(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	dir := t.TempDir()
	env := filepath.Join(dir, "env.sh")
	rc := filepath.Join(dir, "rc")
	os.WriteFile(rc, []byte("export TOKEN=user-value\n"), 0o644)
	Install(rc, env)
	run := func() string {
		out, _ := exec.Command("bash", "-c", `. "$1"; printf %s "$TOKEN"`, "bash", rc).Output()
		return string(out)
	}
	os.WriteFile(env, Render(map[string]string{"TOKEN": "managed"}), 0o600)
	if got := run(); got != "managed" {
		t.Errorf("managed value should win, got %q", got)
	}
	os.WriteFile(env, Render(map[string]string{}), 0o600)
	if got := run(); got != "user-value" {
		t.Errorf("user value should come back, got %q", got)
	}
}
