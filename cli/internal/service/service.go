// Package service 把后台服务安装为用户级服务：Linux 使用 systemd --user，macOS 使用 LaunchAgent，
// Windows 使用当前用户的计划任务。各系统的实现在对应的 service_<系统>.go 中。
package service

import (
	"bytes"
	"os"
	"os/exec"
	"strings"
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
	// LingerUser 非空表示没能为该用户开启 linger（不登录时服务不会运行），需要管理员权限开启。
	LingerUser string
}

func home() string {
	h, _ := os.UserHomeDir()
	return h
}

func run(name string, args ...string) (string, error) {
	var out bytes.Buffer
	cmd := exec.Command(name, args...)
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	return strings.TrimSpace(decode(out.Bytes())), err
}
