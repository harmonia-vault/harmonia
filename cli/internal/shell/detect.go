package shell

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// Detect 优先使用终端提供的 SHELL；后台服务没有它时查询系统登录 Shell。
func Detect() (string, error) {
	return detect(os.Getenv("SHELL"), loginShell)
}

func detect(value string, lookup func() (string, error)) (string, error) {
	if value == "" {
		var err error
		value, err = lookup()
		if err != nil {
			return "", fmt.Errorf("无法识别登录终端，请运行 harmonia shell install --shell bash 或 --shell zsh：%w", err)
		}
	}
	name := filepath.Base(value)
	if name != "bash" && name != "zsh" {
		return "", fmt.Errorf("暂不支持 %s，请使用 Bash 或 Zsh 后运行 harmonia shell install", name)
	}
	return name, nil
}

func loginShell() (string, error) {
	if runtime.GOOS == "darwin" {
		u, err := user.Current()
		if err != nil {
			return "", err
		}
		out, err := exec.Command("/usr/bin/dscl", ".", "-read", "/Users/"+u.Username, "UserShell").Output()
		if err != nil {
			return "", err
		}
		_, value, ok := strings.Cut(string(out), ":")
		if !ok {
			return "", fmt.Errorf("系统没有返回登录终端")
		}
		return strings.TrimSpace(value), nil
	}
	out, err := exec.Command("getent", "passwd", strconv.Itoa(os.Getuid())).Output()
	if err != nil {
		return "", err
	}
	fields := strings.Split(strings.TrimSpace(string(out)), ":")
	if len(fields) != 7 {
		return "", fmt.Errorf("系统没有返回登录终端")
	}
	return fields[6], nil
}
