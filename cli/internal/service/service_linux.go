package service

import (
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
)

const unitName = "harmonia.service"

func decode(out []byte) string { return string(out) }

func unitPath() string {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		base = filepath.Join(home(), ".config")
	}
	return filepath.Join(base, "systemd", "user", unitName)
}

// Install 安装并启动后台服务。bin 为 harmonia 可执行文件的绝对路径，dataDir 为本机数据目录。
func Install(bin, dataDir string) (*Result, error) {
	unit := fmt.Sprintf(`[Unit]
Description=Harmonia 环境变量同步
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=%q daemon
Environment=HARMONIA_HOME=%s
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
`, bin, dataDir)
	p := unitPath()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(p, []byte(unit), 0o644); err != nil {
		return nil, err
	}
	if out, err := run("systemctl", "--user", "daemon-reload"); err != nil {
		return nil, fmt.Errorf("systemctl --user 不可用（%s）。请确认系统使用 systemd 并已登录用户会话", out)
	}
	if out, err := run("systemctl", "--user", "enable", "--now", unitName); err != nil {
		return nil, fmt.Errorf("启动后台服务失败：%s", out)
	}
	res := &Result{Path: p}
	u, _ := user.Current()
	if u != nil {
		if _, err := run("loginctl", "enable-linger", u.Username); err != nil {
			res.LingerUser = u.Username
		}
	}
	return res, nil
}

// Uninstall 停止并删除后台服务。
func Uninstall() error {
	_, _ = run("systemctl", "--user", "disable", "--now", unitName)
	if err := os.Remove(unitPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	_, _ = run("systemctl", "--user", "daemon-reload")
	return nil
}

// Restart 重启后台服务（升级后使用）；未安装时忽略。
func Restart() error {
	if !Check().Installed {
		return nil
	}
	if out, err := run("systemctl", "--user", "restart", unitName); err != nil {
		return fmt.Errorf("重启后台服务失败：%s", out)
	}
	return nil
}

func Check() Status {
	s := Status{Supported: true, Path: unitPath()}
	_, err := os.Stat(s.Path)
	s.Installed = err == nil
	out, _ := run("systemctl", "--user", "is-active", unitName)
	s.Running = out == "active"
	return s
}
