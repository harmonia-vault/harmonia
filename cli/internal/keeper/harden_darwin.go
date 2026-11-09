package keeper

import "golang.org/x/sys/unix"

// harden 关闭崩溃转储。macOS 本身不允许普通程序读取其他进程的内存。
func harden() {
	_ = unix.Setrlimit(unix.RLIMIT_CORE, &unix.Rlimit{})
}
