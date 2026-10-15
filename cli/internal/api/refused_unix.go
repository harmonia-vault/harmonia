//go:build !windows

package api

import (
	"errors"
	"syscall"
)

// refused 判断是否是连接被拒绝（地址上没有程序在监听）。
func refused(err error) bool { return errors.Is(err, syscall.ECONNREFUSED) }
