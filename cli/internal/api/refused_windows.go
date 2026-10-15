package api

import (
	"errors"

	"golang.org/x/sys/windows"
)

// refused 判断是否是连接被拒绝（地址上没有程序在监听）；Windows 上是 WSAECONNREFUSED。
func refused(err error) bool { return errors.Is(err, windows.WSAECONNREFUSED) }
