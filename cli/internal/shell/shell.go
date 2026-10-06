// Package shell 生成 env.sh，并在 shell 启动文件末尾添加或移除 source 行。
package shell

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

var validName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// Quote 用单引号字面量安全转义，值中的 $()、反引号、换行都不会被执行。
func Quote(v string) string { return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'" }

// Render 生成 env.sh 内容。
func Render(vars map[string]string) []byte {
	names := make([]string, 0, len(vars))
	for n := range vars {
		if validName.MatchString(n) {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	var b strings.Builder
	b.WriteString(state.EnvFileHeader)
	for _, n := range names {
		fmt.Fprintf(&b, "export %s=%s\n", n, Quote(vars[n]))
	}
	return []byte(b.String())
}

// Dotenv 生成 .env 格式（双引号转义）。
func Dotenv(vars map[string]string) string {
	names := make([]string, 0, len(vars))
	for n := range vars {
		names = append(names, n)
	}
	sort.Strings(names)
	var b strings.Builder
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`, "$", `\$`)
	for _, n := range names {
		fmt.Fprintf(&b, "%s=\"%s\"\n", n, r.Replace(vars[n]))
	}
	return b.String()
}

const (
	beginMark = "# >>> harmonia >>>"
	endMark   = "# <<< harmonia <<<"
)

// Target 是一个要修改的启动文件。
type Target struct {
	Shell string
	Path  string
}

// Targets 返回指定 shell 需要修改的启动文件。
func Targets(home, sh string) ([]Target, error) {
	switch sh {
	case "zsh":
		zdot := os.Getenv("ZDOTDIR")
		if zdot == "" {
			zdot = home
		}
		return []Target{{"zsh", filepath.Join(zdot, ".zshenv")}}, nil
	case "bash":
		t := []Target{{"bash", filepath.Join(home, ".bashrc")}}
		// 登录 shell 读 ~/.bash_profile（或 ~/.profile），确保它也会加载 env.sh。
		profile := filepath.Join(home, ".bash_profile")
		if _, err := os.Stat(profile); err != nil {
			profile = filepath.Join(home, ".profile")
		}
		return append(t, Target{"bash", profile}), nil
	}
	return nil, fmt.Errorf("暂不支持 %s，目前支持 zsh 和 bash", sh)
}

// Detect 根据 $SHELL 猜测当前 shell。
func Detect() string {
	base := filepath.Base(os.Getenv("SHELL"))
	if base == "bash" || base == "zsh" {
		return base
	}
	return "zsh"
}

func block(envFile string) string {
	return fmt.Sprintf("%s\n[ -f %s ] && . %s\n%s\n", beginMark, Quote(envFile), Quote(envFile), endMark)
}

// ErrSymlink 表示启动文件是符号链接（例如由 dotfiles 工具管理），需要用户手动添加。
var ErrSymlink = errors.New("启动文件是符号链接")

// Installed 判断启动文件里是否已有 Harmonia 的 source 行。
func Installed(path string) bool {
	data, err := os.ReadFile(path)
	return err == nil && strings.Contains(string(data), beginMark)
}

// Install 在文件末尾追加 source 行；已存在时不重复添加。
func Install(path, envFile string) error {
	if fi, err := os.Lstat(path); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		return ErrSymlink
	}
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	text := string(data)
	if strings.Contains(text, beginMark) {
		return nil
	}
	if text != "" && !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	mode := os.FileMode(0o644)
	if fi, err := os.Stat(path); err == nil {
		mode = fi.Mode().Perm()
	}
	return writeKeepMode(path, text+"\n"+block(envFile), mode)
}

// Uninstall 按标记删除 source 行。
func Uninstall(path string) error {
	if fi, err := os.Lstat(path); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		return ErrSymlink
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	text := string(data)
	start := strings.Index(text, beginMark)
	if start < 0 {
		return nil
	}
	end := strings.Index(text[start:], endMark)
	if end < 0 {
		return errors.New("启动文件中的 Harmonia 标记不完整，请手动删除")
	}
	end += start + len(endMark)
	if end < len(text) && text[end] == '\n' {
		end++
	}
	if start > 0 && text[start-1] == '\n' && start > 1 && text[start-2] == '\n' {
		start--
	}
	fi, _ := os.Stat(path)
	return writeKeepMode(path, text[:start]+text[end:], fi.Mode().Perm())
}

// SourceLine 是需要用户手动添加时显示的内容。
func SourceLine(envFile string) string { return block(envFile) }

func writeKeepMode(path, content string, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".harmonia-rc-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
