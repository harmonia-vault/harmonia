//go:build !windows

package installer_test

import (
	"crypto/sha256"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// 使用本地发布包运行完整安装脚本，再由真实 Shell 验证命令查找。
// 所有启动文件和程序都在临时目录中，不接触用户配置或后台服务。
type installFixture struct {
	home, dest, zdot, root string
	env                    []string
}

func newInstallFixture(t *testing.T, shell string, custom bool) installFixture {
	t.Helper()
	root := t.TempDir()
	home := filepath.Join(root, "user 'quoted' $name")
	if err := os.Mkdir(home, 0o700); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(home, ".local", "bin")
	zdot := home
	if custom {
		dest = filepath.Join(root, "bin 'quoted' $(touch injected) `touch injected2`")
		zdot = filepath.Join(root, "zsh config")
	}
	binary := []byte("#!/bin/sh\nprintf '%s\\n' 'harmonia installer-test'\n")
	asset := filepath.Join(root, "harmonia")
	if err := os.WriteFile(asset, binary, 0o600); err != nil {
		t.Fatal(err)
	}
	assetURL := (&url.URL{Scheme: "file", Path: asset}).String()
	manifest := fmt.Sprintf(`{
  "version": "installer-test",
  "assets": {
    "cli-%s-%s": {
      "url": %q,
      "sha256": "%x"
    }
  }
}
`, runtime.GOOS, runtime.GOARCH, assetURL, sha256.Sum256(binary))
	if err := os.WriteFile(filepath.Join(root, "stable.json"), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	env := []string{
		"HOME=" + home, "SHELL=" + shell,
		"PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
		"HARMONIA_YES=0", "HARMONIA_FEED=" + (&url.URL{Scheme: "file", Path: root}).String(),
		"TERM=dumb", "LC_ALL=C", "HISTFILE=/dev/null",
	}
	if custom {
		env = append(env, "HARMONIA_BIN_DIR="+dest, "ZDOTDIR="+zdot)
	}
	return installFixture{home: home, dest: dest, zdot: zdot, root: root, env: env}
}

func (f installFixture) run(t *testing.T) string {
	t.Helper()
	script, err := os.ReadFile("install.sh")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("/bin/sh")
	cmd.Dir, cmd.Env, cmd.Stdin = f.root, f.env, strings.NewReader(string(script))
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("安装失败：%v\n%s", err, out)
	}
	return string(out)
}

func (f installFixture) checkShell(t *testing.T, shell string, args []string, prefix string) {
	t.Helper()
	command := prefix + `printf '__COMMAND__%s\n' "$(command -v harmonia)"; harmonia version; printf '__PATH__%s\n' "$PATH"`
	cmd := exec.Command(shell, append(args, command)...)
	cmd.Dir, cmd.Env = f.root, f.env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("Shell 启动失败：%v\n%s", err, out)
	}
	text := string(out)
	if !strings.Contains(text, "__COMMAND__"+filepath.Join(f.dest, "harmonia")+"\n") ||
		!strings.Contains(text, "\nharmonia installer-test\n") {
		t.Fatalf("未运行已安装的命令：%s", out)
	}
	pathFound := false
	for _, line := range strings.Split(text, "\n") {
		if path, ok := strings.CutPrefix(line, "__PATH__"); ok {
			pathFound = true
			count := 0
			for _, entry := range filepath.SplitList(path) {
				if entry == f.dest {
					count++
				}
			}
			if count != 1 {
				t.Fatalf("安装目录在 PATH 中出现 %d 次：%s", count, path)
			}
		}
	}
	if !pathFound {
		t.Fatalf("未输出 PATH：%s", out)
	}
}

func TestInstallerPath(t *testing.T) {
	for _, tc := range []struct {
		name, shell, login string
		custom             bool
	}{
		{name: "zsh", shell: "zsh"},
		{name: "zsh-custom", shell: "zsh", custom: true},
		{name: "bash-new", shell: "bash"},
		{name: "bash-profile", shell: "bash", login: ".profile"},
		{name: "bash-login", shell: "bash", login: ".bash_login"},
		{name: "bash-profile-priority", shell: "bash", login: ".bash_profile"},
		{name: "bash-custom", shell: "bash", custom: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			shell, err := exec.LookPath(tc.shell)
			if err != nil {
				t.Skipf("%s 不可用", tc.shell)
			}
			f := newInstallFixture(t, shell, tc.custom)
			files := []string{filepath.Join(f.zdot, ".zshrc")}
			if tc.shell == "bash" {
				login := tc.login
				if login == "" {
					login = ".profile"
				}
				files = []string{filepath.Join(f.home, ".bashrc"), filepath.Join(f.home, login)}
			}
			const original = "# 用户配置\nexport INSTALLER_KEEP=original"
			// 新安装保留无换行结尾的 rc；有登录配置时保留其原文和权限。
			if err := os.MkdirAll(filepath.Dir(files[0]), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(files[0], []byte(original), 0o640); err != nil {
				t.Fatal(err)
			}
			lower := map[string]string{}
			if tc.login != "" {
				active := false
				for _, name := range []string{".bash_profile", ".bash_login", ".profile"} {
					active = active || name == tc.login
					if active {
						path := filepath.Join(f.home, name)
						if err := os.WriteFile(path, []byte(original), 0o640); err != nil {
							t.Fatal(err)
						}
						if name != tc.login {
							lower[path] = original
						}
					}
				}
			}
			out := f.run(t)
			var activation string
			for _, line := range strings.Split(out, "\n") {
				if strings.HasPrefix(line, "  export PATH=") {
					activation = strings.TrimSpace(line)
				}
			}
			if activation == "" || strings.Index(out, activation) > strings.Index(out, "下一步：") {
				t.Fatalf("登录前没有当前终端的生效命令：%s", out)
			}
			var before []string
			for _, file := range files {
				data, err := os.ReadFile(file)
				if err != nil {
					t.Fatal(err)
				}
				before = append(before, string(data))
				if (file == files[0] || tc.login != "") && !strings.HasPrefix(string(data), original) {
					t.Fatalf("原配置被改写：%s", file)
				}
			}
			f.run(t)
			for i, file := range files {
				data, _ := os.ReadFile(file)
				if string(data) != before[i] {
					t.Fatalf("重复安装改变了配置：%s", file)
				}
			}
			info, err := os.Stat(files[0])
			if err != nil || info.Mode().Perm() != 0o640 {
				t.Fatalf("原配置权限未保留：%v", err)
			}
			for file, original := range lower {
				data, _ := os.ReadFile(file)
				if string(data) != original {
					t.Fatalf("修改了未生效的登录文件：%s", file)
				}
			}
			// 新开的登录、非登录终端都能运行；再次加载也不能重复 PATH。
			f.env = append(f.env, "INSTALLER_RC="+files[0])
			for _, args := range [][]string{{"-ic"}, {"-lic"}} {
				f.checkShell(t, shell, args, "")
				f.checkShell(t, shell, args, `. "$INSTALLER_RC"; . "$INSTALLER_RC"; `)
			}
			// 按安装提示直接启用已有终端，不依赖启动文件。
			args := []string{"-f", "-c"}
			if tc.shell == "bash" {
				args = []string{"--noprofile", "--norc", "-c"}
			}
			f.checkShell(t, shell, args, activation+"; ")
			for _, name := range []string{"injected", "injected2"} {
				if _, err := os.Stat(filepath.Join(f.root, name)); !os.IsNotExist(err) {
					t.Fatalf("安装目录被当作代码执行：%s", name)
				}
			}
		})
	}
}

func TestInstallerPersistsInheritedPath(t *testing.T) {
	for _, name := range []string{"bash", "zsh"} {
		t.Run(name, func(t *testing.T) {
			shell, err := exec.LookPath(name)
			if err != nil {
				t.Skipf("%s 不可用", name)
			}
			f := newInstallFixture(t, shell, false)
			// 当前进程临时带有安装目录，也必须为后续独立终端保存配置。
			cleanEnv := append([]string(nil), f.env...)
			for i, value := range f.env {
				if strings.HasPrefix(value, "PATH=") {
					f.env[i] = "PATH=" + f.dest + ":" + strings.TrimPrefix(value, "PATH=")
				}
			}
			f.run(t)
			f.checkShell(t, shell, []string{"-ic"}, "")
			f.env = cleanEnv
			f.checkShell(t, shell, []string{"-ic"}, "")
		})
	}
}
