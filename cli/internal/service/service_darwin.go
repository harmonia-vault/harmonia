package service

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const label = "org.harmoniavault.harmonia"

func decode(out []byte) string { return string(out) }

func plistPath() string { return filepath.Join(home(), "Library", "LaunchAgents", label+".plist") }

func target() string { return fmt.Sprintf("gui/%d/%s", os.Getuid(), label) }

func escapeXML(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;")
	return r.Replace(s)
}

// Install 安装并启动后台服务。bin 为 harmonia 可执行文件的绝对路径，dataDir 为本机数据目录。
func Install(bin, dataDir string) (*Result, error) {
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
	_, _ = run("launchctl", "bootout", target())
	if out, err := run("launchctl", "bootstrap", domain, p); err != nil {
		return nil, fmt.Errorf("启动后台服务失败：%s", out)
	}
	return &Result{Path: p, Notes: []string{"macOS 上后台服务在登录后运行。"}}, nil
}

// Uninstall 停止并删除后台服务。
func Uninstall() error {
	_, _ = run("launchctl", "bootout", target())
	if err := os.Remove(plistPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// Restart 重启后台服务（升级后使用）；未安装时忽略。
func Restart() error {
	if !Check().Installed {
		return nil
	}
	if out, err := run("launchctl", "kickstart", "-k", target()); err != nil {
		return fmt.Errorf("重启后台服务失败：%s", out)
	}
	return nil
}

func Check() Status {
	s := Status{Supported: true, Path: plistPath()}
	_, err := os.Stat(s.Path)
	s.Installed = err == nil
	out, err := run("launchctl", "print", target())
	s.Running = err == nil && strings.Contains(out, "state = running")
	return s
}
