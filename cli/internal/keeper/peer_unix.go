//go:build !windows

package keeper

import (
	"os"
	"os/exec"
	"syscall"

	"golang.org/x/sys/unix"
)

// sessionAlive 判断终端会话还在：会话首进程（ID 与会话 ID 相同）仍在运行。
func sessionAlive(sid int) bool {
	got, err := unix.Getsid(sid)
	return err == nil && got == sid
}

// SupportsTerminal 表示能区分终端会话，支持“仅这个终端”。
const SupportsTerminal = true

// start 在新的会话里启动保管进程，不随当前终端关闭而退出。
func start(bin string) error {
	cmd := exec.Command(bin, "keeper")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Env = os.Environ()
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}
