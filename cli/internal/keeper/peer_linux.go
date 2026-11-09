package keeper

import (
	"errors"
	"net"
	"os"

	"golang.org/x/sys/unix"
)

// peerSession 核对连接的另一端是同一用户，返回它所在的终端会话 ID（SO_PEERCRED → getsid）。
func peerSession(conn net.Conn) (int, error) {
	raw, err := conn.(*net.UnixConn).SyscallConn()
	if err != nil {
		return 0, err
	}
	var cred *unix.Ucred
	var serr error
	err = raw.Control(func(fd uintptr) {
		cred, serr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	})
	if err != nil {
		return 0, err
	}
	if serr != nil {
		return 0, serr
	}
	if cred.Uid != uint32(os.Getuid()) {
		return 0, errors.New("请求方不是同一个用户")
	}
	return unix.Getsid(int(cred.Pid))
}

// harden 让同一用户的其他程序读不到保管进程的内存、也不能调试它（不可转储），并尽量锁定内存不进交换区。
func harden() {
	_ = unix.Prctl(unix.PR_SET_DUMPABLE, 0, 0, 0, 0)
	_ = unix.Setrlimit(unix.RLIMIT_CORE, &unix.Rlimit{})
	// 锁定内存的上限不够时，锁定以后新分配的内存会失败，所以只在不限量时锁定。
	var lim unix.Rlimit
	if unix.Getrlimit(unix.RLIMIT_MEMLOCK, &lim) == nil && lim.Cur == unix.RLIM_INFINITY {
		_ = unix.Mlockall(unix.MCL_CURRENT | unix.MCL_FUTURE)
	}
}
