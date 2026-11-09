package keeper

import (
	"net"
	"os"
	"os/exec"
	"syscall"

	"golang.org/x/sys/windows"
)

// peerSession 在 Windows 上不区分终端：套接字所在的数据目录只允许本人访问。
func peerSession(net.Conn) (int, error) { return 0, nil }

func sessionAlive(int) bool { return true }

// SupportsTerminal 表示能区分终端会话。Windows 上只提供“这台电脑上的所有程序”（设计文档 17.5）。
const SupportsTerminal = false

func harden() {}

// start 在后台启动保管进程，不弹出窗口，不随当前控制台关闭而退出。
func start(bin string) error {
	cmd := exec.Command(bin, "keeper")
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP | windows.DETACHED_PROCESS,
	}
	cmd.Env = os.Environ()
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}
