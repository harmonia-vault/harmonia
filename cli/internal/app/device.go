package app

import (
	"os"
	"strings"
)

// DefaultDeviceName 返回这台电脑默认使用的设备名（主机名）。
func DefaultDeviceName() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "电脑"
	}
	h = strings.TrimSuffix(h, ".local")
	if len([]rune(h)) > 64 {
		h = string([]rune(h)[:64])
	}
	return h
}
