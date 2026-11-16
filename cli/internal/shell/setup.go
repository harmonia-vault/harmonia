package shell

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"

	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

var ErrNotReady = errors.New("Shell 集成尚未配置，请运行 harmonia shell install 完成配置后重试")

func setupFile(envFile string) string { return filepath.Join(filepath.Dir(envFile), "shell.json") }

func configuredTargets(envFile string) ([]Target, error) {
	data, err := os.ReadFile(setupFile(envFile))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var targets []Target
	err = json.Unmarshal(data, &targets)
	return targets, err
}

// Prepare 只安装加载入口并记住路径；后台服务不会重新猜测终端配置位置。
func Prepare(envFile string, targets []Target) error {
	saved, err := configuredTargets(envFile)
	if err != nil {
		return err
	}
	var installErr error
	for _, target := range targets {
		if err := Install(target.Path, envFile); err != nil {
			installErr = errors.Join(installErr, fmt.Errorf("%s: %w", target.Path, err))
		}
		if !slices.Contains(saved, target) {
			saved = append(saved, target)
		}
	}
	data, err := json.Marshal(saved)
	if err != nil {
		return err
	}
	return errors.Join(installErr, state.WriteAtomic(setupFile(envFile), data))
}

// Ready 检查安装时记录的加载入口，手动配置的符号链接也按实际内容检查。
func Ready(envFile string) error {
	targets, err := configuredTargets(envFile)
	if err != nil {
		return err
	}
	if len(targets) == 0 {
		return ErrNotReady
	}
	for _, target := range targets {
		if !Installed(target.Path, envFile) {
			return ErrNotReady
		}
	}
	return nil
}

// Remove 清除完整卸载时的本机加载设置，关闭开关不调用它。
func Remove(envFile string) ([]string, error) {
	targets, err := configuredTargets(envFile)
	if err != nil {
		return nil, err
	}
	var manual []string
	for _, target := range targets {
		if err := Uninstall(target.Path); errors.Is(err, ErrSymlink) {
			manual = append(manual, target.Path)
		} else if err != nil {
			return manual, fmt.Errorf("无法移除 %s 中的加载设置，请检查文件后重试：%w", target.Path, err)
		}
	}
	if err := RemoveFiles(envFile); err != nil {
		return manual, err
	}
	err = os.Remove(setupFile(envFile))
	if errors.Is(err, os.ErrNotExist) {
		return manual, nil
	}
	return manual, err
}
