// Package service 把后台服务安装为用户级服务：Linux 使用 systemd --user，macOS 使用 LaunchAgent。
package service

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	unitName = "harmonia.service"
	label    = "org.harmoniavault.harmonia"
)

type Status struct {
	Supported bool
	Installed bool
	Running   bool
	Path      string
}

// Result 描述安装结果中需要提示用户的事项。
type Result struct {
	Path  string
	Notes []string
}

func home() string {
	h, _ := os.UserHomeDir()
	return h
}

func unitPath() string {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		base = filepath.Join(home(), ".config")
	}
	return filepath.Join(base, "systemd", "user", unitName)
}

func plistPath() string { return filepath.Join(home(), "Library", "LaunchAgents", label+".plist") }

func run(name string, args ...string) (string, error) {
	var out bytes.Buffer
	cmd := exec.Command(name, args...)
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	return strings.TrimSpace(out.String()), err
}

func escapeXML(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;")
	return r.Replace(s)
}

// Install 安装并启动后台服务。bin 为 harmonia 可执行文件的绝对路径，dataDir 为本机数据目录。
func Install(bin, dataDir string) (*Result, error) {
	switch runtime.GOOS {
	case "linux":
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
			if out, err := run("loginctl", "enable-linger", u.Username); err != nil {
				res.Notes = append(res.Notes,
					fmt.Sprintf("未能开启开机自启（loginctl enable-linger 失败：%s）。不登录时服务不会运行；可以让管理员执行：sudo loginctl enable-linger %s", out, u.Username))
			}
		}
		return res, nil
	case "darwin":
		plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key><array><string>%s</string><string>daemon</string></array>
  <key>EnvironmentVariables</key><dict><key>HARMONIA_HOME</key><string>%s</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
`, label, escapeXML(bin), escapeXML(dataDir))
		p := plistPath()
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(p, []byte(plist), 0o644); err != nil {
			return nil, err
		}
		domain := fmt.Sprintf("gui/%d", os.Getuid())
		_, _ = run("launchctl", "bootout", domain+"/"+label)
		if out, err := run("launchctl", "bootstrap", domain, p); err != nil {
			return nil, fmt.Errorf("启动后台服务失败：%s", out)
		}
		return &Result{Path: p, Notes: []string{"macOS 上后台服务在登录后运行。"}}, nil
	}
	return nil, fmt.Errorf("暂不支持在 %s 上安装后台服务", runtime.GOOS)
}

// Uninstall 停止并删除后台服务。
func Uninstall() error {
	switch runtime.GOOS {
	case "linux":
		_, _ = run("systemctl", "--user", "disable", "--now", unitName)
		if err := os.Remove(unitPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		_, _ = run("systemctl", "--user", "daemon-reload")
		return nil
	case "darwin":
		_, _ = run("launchctl", "bootout", fmt.Sprintf("gui/%d/%s", os.Getuid(), label))
		if err := os.Remove(plistPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	return nil
}

// Restart 重启后台服务（升级后使用）；未安装时忽略。
func Restart() error {
	if !Check().Installed {
		return nil
	}
	switch runtime.GOOS {
	case "linux":
		if out, err := run("systemctl", "--user", "restart", unitName); err != nil {
			return fmt.Errorf("重启后台服务失败：%s", out)
		}
	case "darwin":
		if out, err := run("launchctl", "kickstart", "-k", fmt.Sprintf("gui/%d/%s", os.Getuid(), label)); err != nil {
			return fmt.Errorf("重启后台服务失败：%s", out)
		}
	}
	return nil
}

func Check() Status {
	switch runtime.GOOS {
	case "linux":
		s := Status{Supported: true, Path: unitPath()}
		_, err := os.Stat(s.Path)
		s.Installed = err == nil
		out, _ := run("systemctl", "--user", "is-active", unitName)
		s.Running = out == "active"
		return s
	case "darwin":
		s := Status{Supported: true, Path: plistPath()}
		_, err := os.Stat(s.Path)
		s.Installed = err == nil
		out, err := run("launchctl", "print", fmt.Sprintf("gui/%d/%s", os.Getuid(), label))
		s.Running = err == nil && strings.Contains(out, "state = running")
		return s
	}
	return Status{}
}
