//go:build !windows

package main

import (
	"context"
	"os"
	"os/exec"
	"runtime"
	"syscall"
)

// notFoundHint 是找不到要运行的命令时补充的说明。
const notFoundHint = ""

// replaceProcess 用要运行的命令替换当前进程，信号和退出码都直接属于它。
func replaceProcess(bin string, args, env []string) error {
	return syscall.Exec(bin, args, env)
}

// background 为后台服务做系统相关的准备；macOS、Linux 上由 systemd、launchd 负责启停，不需要准备。
func background(ctx context.Context, _ []string) (context.Context, func(), error) {
	return ctx, func() {}, nil
}

// openBrowser 用系统默认浏览器打开地址。
func openBrowser(url string) error {
	if runtime.GOOS == "darwin" {
		return exec.Command("open", url).Start()
	}
	if os.Getenv("DISPLAY") == "" && os.Getenv("WAYLAND_DISPLAY") == "" {
		return exec.ErrNotFound
	}
	return exec.Command("xdg-open", url).Start()
}

// newProgramName 是升级时新版本的临时文件名，与 harmonia 放在同一个目录。
const newProgramName = ".harmonia-new"

// swapProgram 把旧版本保留为 .old，再用新版本原子替换。
func swapProgram(tmp, bin string) error {
	_ = os.Remove(bin + ".old")
	if err := os.Link(bin, bin+".old"); err != nil {
		if data, err := os.ReadFile(bin); err == nil {
			_ = os.WriteFile(bin+".old", data, 0o755)
		}
	}
	return os.Rename(tmp, bin)
}

// removeProgram 在卸载时删除 harmonia 本身和保留的旧版本。
func removeProgram(bin string) {
	_ = os.Remove(bin)
	_ = os.Remove(bin + ".old")
}

// relaunchDaemon 在后台服务升级后调用。systemd（Restart=always）和 launchd（KeepAlive）会在退出后
// 自动用新程序重新启动，这里不需要做什么。
func relaunchDaemon(func(string, ...any)) error { return nil }
