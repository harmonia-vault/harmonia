package app

import (
	"os"
	"strings"
)

func defaultDeviceName() string {
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
