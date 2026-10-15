// 给 AI 助手的使用说明：输出、保存成技能文件，升级后覆盖，卸载时删除。
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"

	"github.com/harmonia-vault/harmonia/cli/internal/skill"
)

func cmdSkill(_ context.Context, args []string) error {
	f, err := parseFlags(args, "dir=")
	if err != nil {
		return err
	}
	usage := errors.New("用法：harmonia skill [install [--dir 目录]]")
	if len(f.args) == 0 && f.values["dir"] == "" {
		// 输出要原样交给 AI 助手，顺带更新保存过的技能文件时不打印任何内容。
		syncSkillFiles(nil)
		_, err := os.Stdout.Write(skill.Render(version))
		return err
	}
	if len(f.args) != 1 || f.args[0] != "install" {
		return usage
	}
	s := loadSettings()
	var targets []string
	if d := f.values["dir"]; d != "" {
		abs, err := filepath.Abs(d)
		if err != nil {
			return err
		}
		targets = []string{skill.File(abs)}
	} else {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		targets = skill.Targets(home, s.SkillFiles)
		if len(targets) == 0 {
			return errors.New("没有找到 ~/.claude 或 ~/.agents。请用 --dir 指定 AI 工具的技能目录，或运行 harmonia skill 直接查看使用说明")
		}
	}
	content := skill.Stub()
	for _, p := range targets {
		if err = skill.Write(p, content); err != nil {
			err = fmt.Errorf("无法写入 %s：%w", p, err)
			break
		}
		fmt.Println("已写入 " + p + "（入口文件：让 AI 助手每次使用前运行 harmonia skill 读取当时的说明，升级后不会过期）")
		if !slices.Contains(s.SkillFiles, p) {
			s.SkillFiles = append(s.SkillFiles, p)
		}
	}
	return errors.Join(err, saveSettings(s))
}

// syncSkillFiles 把保存过的技能文件更新为当前的入口文件，内容相同的不动；用户已经删掉的不再写回。
// 早期版本保存的是完整说明，会在这里换成入口文件。say 为 nil 时不输出。
func syncSkillFiles(say func(string)) {
	s := loadSettings()
	stub := skill.Stub()
	var kept []string
	for _, p := range s.SkillFiles {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		kept = append(kept, p)
		if bytes.Equal(data, stub) {
			continue
		}
		if err := skill.Write(p, stub); err != nil {
			if say != nil {
				say(fmt.Sprintf("无法更新技能文件 %s：%v。可以运行 harmonia skill install 重试。", p, err))
			}
		} else if say != nil {
			say("已更新技能文件 " + p)
		}
	}
	if len(kept) != len(s.SkillFiles) {
		s.SkillFiles = kept
		_ = saveSettings(s)
	}
}

// removeSkills 在卸载时删除保存过的技能文件。
func removeSkills() {
	for _, p := range loadSettings().SkillFiles {
		if err := skill.Remove(p); err != nil {
			fmt.Printf("无法删除 %s，请手动删除。\n", p)
		}
	}
}
