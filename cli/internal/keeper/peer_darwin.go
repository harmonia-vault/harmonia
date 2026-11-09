package keeper

import (
	"errors"
	"net"
	"os"

	"golang.org/x/sys/unix"
)

// peerSession 核对连接的另一端是同一用户，返回它所在的终端会话 ID（LOCAL_PEERPID → getsid）。
func peerSession(conn net.Conn) (int, error) {
	raw, err := conn.(*net.UnixConn).SyscallConn()
	if err != nil {
		return 0, err
	}
	var uid uint32
	var pid int
	var serr error
	err = raw.Control(func(fd uintptr) {
		var cred *unix.Xucred
		if cred, serr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED); serr != nil {
			return
		}
		uid = cred.Uid
		pid, serr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
	})
	if err != nil {
		return 0, err
	}
	if serr != nil {
		return 0, serr
	}
	if uid != uint32(os.Getuid()) {
		return 0, errors.New("请求方不是同一个用户")
	}
	return unix.Getsid(pid)
}
