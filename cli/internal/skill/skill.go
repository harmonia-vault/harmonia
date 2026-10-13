// Package skill 提供给 AI 助手的使用说明（技能文件），以及把它保存到各个 AI 工具技能目录的规则。
package skill

import (
	_ "embed"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

//go:embed SKILL.md
var text string

// Render 返回填入版本号的使用说明。
func Render(version string) []byte {
	return []byte(strings.ReplaceAll(text, "{{version}}", version))
}

// File 返回技能目录下 Harmonia 的技能文件路径。
func File(dir string) string { return filepath.Join(dir, "harmonia", "SKILL.md") }

// toolDirs 是默认写入的 AI 工具目录，相对于用户主目录；工具目录存在时写入其中的 skills。
var toolDirs = []string{".claude", ".agents"}

// Targets 返回不指定目录时要写入的技能文件：已安装的 AI 工具的默认位置，加上之前保存过的位置。
func Targets(home string, saved []string) []string {
	var out []string
	for _, d := range toolDirs {
		if fi, err := os.Stat(filepath.Join(home, d)); err == nil && fi.IsDir() {
			out = append(out, File(filepath.Join(home, d, "skills")))
		}
	}
	for _, p := range saved {
		if !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	return out
}

// Write 写入技能文件，所在目录不存在时创建。
func Write(path string, content []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return state.WriteAtomic(path, content)
}

// Remove 删除技能文件；所在的 harmonia 目录因此变空时一并删除。文件已不存在不算错误。
func Remove(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	dir := filepath.Dir(path)
	if entries, err := os.ReadDir(dir); err == nil && len(entries) == 0 {
		_ = os.Remove(dir)
	}
	return nil
}
