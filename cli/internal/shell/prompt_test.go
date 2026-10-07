package shell

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

const testPrompt = "__TEST_PROMPT__"

type shellSession struct {
	t     *testing.T
	input io.WriteCloser
	lines chan string
}

// 真实交互 Shell 的提示符是同步点，测试进程在两条命令之间模拟后台写入。
func startShell(t *testing.T, name, dir string) *shellSession {
	t.Helper()
	bin, err := exec.LookPath(name)
	if err != nil {
		t.Skipf("%s 不可用", name)
	}
	args := []string{"-d", "-f", "-i"}
	if name == "bash" {
		check := exec.Command(bin, "--noprofile", "--norc", "-c", `(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) ))`)
		if check.Run() != nil {
			t.Skip("交互式刷新需要 Bash 5.1+；mise run test-shell-linux 验证最低版本")
		}
		args = []string{"--noprofile", "--norc", "--noediting", "-i"}
	}
	cmd := exec.Command(bin, args...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + dir, "ZDOTDIR=" + dir, "HISTFILE=/dev/null", "TERM=dumb", "LC_ALL=C"}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stdout, cmd.Stderr = w, w
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	w.Close()
	s := &shellSession{t: t, input: input, lines: make(chan string, 32)}
	go func() {
		defer close(s.lines)
		scanner := bufio.NewScanner(r)
		for scanner.Scan() {
			s.lines <- scanner.Text()
		}
	}()
	t.Cleanup(func() {
		input.Close()
		cmd.Process.Kill()
		cmd.Wait()
		r.Close()
	})
	s.run("PS1=$'" + testPrompt + "\\n'; PS2=''; set +o history")
	return s
}

func (s *shellSession) run(command string) string {
	s.t.Helper()
	if _, err := io.WriteString(s.input, command+"\n"); err != nil {
		s.t.Fatal(err)
	}
	var out []string
	timeout := time.NewTimer(5 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case line, ok := <-s.lines:
			if !ok {
				s.t.Fatalf("Shell 提前退出：%s", strings.Join(out, "\n"))
			}
			if strings.HasSuffix(line, testPrompt) {
				return strings.Join(out, "\n")
			}
			// Bash 从管道读取交互命令时会回显输入，这不是命令输出。
			if line == command {
				continue
			}
			out = append(out, line)
		case <-timeout.C:
			s.t.Fatalf("未等到命令提示符：%s", strings.Join(out, "\n"))
		}
	}
}

func writeEnv(t *testing.T, path string, vars map[string]string) {
	t.Helper()
	if err := state.WriteAtomic(path, Render(vars)); err != nil {
		t.Fatal(err)
	}
}

func TestPromptRefresh(t *testing.T) {
	for _, name := range []string{"bash", "zsh"} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			env := filepath.Join(dir, "env.sh")
			if err := Install(filepath.Join(dir, "rc"), env); err != nil {
				t.Fatal(err)
			}
			writeEnv(t, env, map[string]string{"TOKEN": "first", "RESTORE": "managed", "LOCAL": "managed", "EMPTY": "managed"})
			s := startShell(t, name, dir)
			s.run(`export RESTORE='use typeset foo'; LOCAL='local before'; EMPTY=''; unset TOKEN`)
			if out := s.run(". " + Quote(IntegrationFile(env))); out != "" {
				t.Fatalf("加载集成失败：%s", out)
			}
			if got := s.run(`printf '%s|%s\n' "$TOKEN" "$RESTORE"`); got != "first|managed" {
				t.Fatalf("初次加载：%q", got)
			}
			// 重复加载必须保留原值；文件未变化时保留用户手动修改。
			s.run(". " + Quote(IntegrationFile(env)))
			s.run(`export TOKEN=manual`)
			if got := s.run(`printf '%s\n' "$TOKEN"`); got != "manual" {
				t.Fatalf("手动值被覆盖：%q", got)
			}
			writeEnv(t, env, map[string]string{"TOKEN": "second", "ADDED": "new"})
			if got := s.run(`printf '%s\n' "$TOKEN"`); got != "manual" {
				t.Fatalf("在提示符之前提前刷新：%q", got)
			}
			if got := s.run(`printf '%s|%s|%s|%s|%s\n' "$TOKEN" "$ADDED" "$RESTORE" "$LOCAL" "${EMPTY-unset}"`); got != "second|new|use typeset foo|local before|" {
				t.Fatalf("更新与清理：%q", got)
			}
			if got := s.run(`sh -c 'printf "%s|%s|%s\n" "$RESTORE" "${LOCAL-unset}" "${EMPTY-unset}"'`); got != "use typeset foo|unset|unset" {
				t.Fatalf("未恢复导出属性：%q", got)
			}
			if err := (&state.Dir{Path: dir}).Wipe(); err != nil {
				t.Fatal(err)
			}
			s.run("")
			if got := s.run(`printf '%s|%s\n' "${TOKEN-unset}" "${ADDED-unset}"`); got != "unset|unset" {
				t.Fatalf("退出后仍有变量：%q", got)
			}
			s.run(`RESTORE=manual_after_removal`)
			writeEnv(t, env, map[string]string{"TOKEN": "again"})
			s.run("")
			if got := s.run(`printf '%s\n' "$RESTORE"`); got != "manual_after_removal" {
				t.Fatalf("已移除的变量仍被托管：%q", got)
			}
			if err := os.Remove(env); err != nil {
				t.Fatal(err)
			}
			s.run("")
			if got := s.run(`printf '%s\n' "${TOKEN-unset}"`); got != "unset" {
				t.Fatalf("文件移除后仍有变量：%q", got)
			}
		})
	}
}

func TestPromptRestoresPath(t *testing.T) {
	for _, name := range []string{"bash", "zsh"} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			env := filepath.Join(dir, "env.sh")
			if err := os.WriteFile(filepath.Join(dir, "probe"), []byte("#!/bin/sh\nprintf 'original-command\\n'\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := Install(filepath.Join(dir, "rc"), env); err != nil {
				t.Fatal(err)
			}
			writeEnv(t, env, map[string]string{"PATH": "/nonexistent-harmonia-test"})
			s := startShell(t, name, dir)
			s.run("export PATH=" + Quote(dir))
			s.run(". " + Quote(IntegrationFile(env)))
			if got := s.run(`printf '%s\n' "$PATH"`); got != "/nonexistent-harmonia-test" {
				t.Fatalf("PATH 未应用：%q", got)
			}
			writeEnv(t, env, nil)
			s.run("")
			if got := s.run("probe"); got != "original-command" {
				t.Fatalf("恢复 PATH 后无法执行原命令：%q", got)
			}
		})
	}
}

func TestPromptValuesAndExistingHooks(t *testing.T) {
	for _, name := range []string{"bash", "zsh"} {
		for _, array := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/array=%v", name, array), func(t *testing.T) {
				dir := t.TempDir()
				env := filepath.Join(dir, "env.sh")
				if err := Install(filepath.Join(dir, "rc"), env); err != nil {
					t.Fatal(err)
				}
				s := startShell(t, name, dir)
				s.run(`KEEP=mine; __test_seen=0; __test_hook() { __test_seen=$?; }`)
				if name == "bash" {
					if array {
						s.run(`PROMPT_COMMAND=(__test_hook)`)
					} else {
						s.run(`PROMPT_COMMAND='__test_hook'`)
					}
				} else if !array {
					s.run(`autoload -Uz add-zsh-hook; add-zsh-hook precmd __test_hook`)
				}
				value := "quote ' \" $HOME $(touch " + filepath.Join(dir, "pwned") + ") `false`\nexport KEEP='forged'\nlast\n"
				writeEnv(t, env, map[string]string{"TOKEN": value})
				s.run(". " + Quote(IntegrationFile(env)))
				s.run(". " + Quote(IntegrationFile(env)))
				if name == "zsh" {
					if array {
						s.run(`add-zsh-hook precmd __test_hook`)
					}
					s.run(`__test_after() { __test_after_ran=yes; }; add-zsh-hook precmd __test_after`)
				}
				if got := s.run(`printf '%sEND\n' "$TOKEN"`); got != value+"END" {
					t.Fatalf("值被改变：%q", got)
				}
				if _, err := os.Stat(filepath.Join(dir, "pwned")); !os.IsNotExist(err) {
					t.Fatal("变量值被执行")
				}
				writeEnv(t, env, nil)
				s.run("__test_after_ran=no; false")
				if got := s.run(`printf '%s|%s\n' "$?" "$__test_seen"`); got != "1|1" {
					t.Fatalf("命令退出状态或已有提示符受影响：%q", got)
				}
				if name == "zsh" {
					s.run("__test_after_ran=no; false")
					if got := s.run(`printf '%s\n' "$__test_after_ran"`); got != "yes" {
						t.Fatalf("失败命令阻断了后续提示符钩子：%q", got)
					}
				}
				if got := s.run(`printf '%s|%s\n' "${TOKEN-unset}" "$KEEP"`); got != "unset|mine" {
					t.Fatalf("多行值被误认成托管变量：%q", got)
				}
			})
		}
	}
}

func TestInstallReplacesMarkedBlock(t *testing.T) {
	dir := t.TempDir()
	env := filepath.Join(dir, "env.sh")
	rc := filepath.Join(dir, "rc")
	old := "# user before\n" + beginMark + "\n. /old/env.sh\n" + endMark + "\n# user after\n"
	if err := os.WriteFile(rc, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	if Installed(rc, env) {
		t.Fatal("旧标记被误认成当前集成")
	}
	if err := Install(rc, env); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(rc)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(data), "# user before\n"+block(env)+"# user after\n"; got != want {
		t.Fatalf("标记外的配置被改变：%q", got)
	}
	if !Installed(rc, env) {
		t.Fatal("更新后的集成未被识别")
	}
	if err := os.Remove(IntegrationFile(env)); err != nil {
		t.Fatal(err)
	}
	if Installed(rc, env) {
		t.Fatal("脚本缺失仍显示已安装")
	}
}
