// 给 AI 助手的使用说明：输出、保存成技能文件，升级后覆盖，卸载时删除。
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
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
	content := skill.Render(version)
	for _, p := range targets {
		if err = skill.Write(p, content); err != nil {
			err = fmt.Errorf("无法写入 %s：%w", p, err)
			break
		}
		fmt.Println("已写入 " + p)
		if !slices.Contains(s.SkillFiles, p) {
			s.SkillFiles = append(s.SkillFiles, p)
		}
	}
	return errors.Join(err, saveSettings(s))
}

// refreshSkills 在升级后用新程序的使用说明覆盖保存过的技能文件；用户已经删掉的不再写回。
func refreshSkills(bin string) {
	s := loadSettings()
	var kept []string
	for _, p := range s.SkillFiles {
		if _, err := os.Stat(p); err == nil {
			kept = append(kept, p)
		}
	}
	if len(kept) > 0 {
		if out, err := exec.Command(bin, "skill").Output(); err != nil {
			fmt.Println("没能更新技能文件，可以运行 harmonia skill install 重试。")
		} else {
			for _, p := range kept {
				if err := skill.Write(p, out); err != nil {
					fmt.Printf("无法更新 %s：%v。可以运行 harmonia skill install 重试。\n", p, err)
				} else {
					fmt.Println("已更新技能文件 " + p)
				}
			}
		}
	}
	if len(kept) != len(s.SkillFiles) {
		s.SkillFiles = kept
		_ = saveSettings(s)
	}
	fmt.Println("如果是 AI 助手在操作，请运行 harmonia skill 重新读取使用说明。")
}

// removeSkills 在卸载时删除保存过的技能文件。
func removeSkills() {
	for _, p := range loadSettings().SkillFiles {
		if err := skill.Remove(p); err != nil {
			fmt.Printf("无法删除 %s，请手动删除。\n", p)
		}
	}
}
