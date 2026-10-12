package sysenv

import (
	"errors"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// Registry 是注册表中当前用户的一组环境变量；Path 是 HKEY_CURRENT_USER 下的位置。
type Registry struct{ Path string }

// User 是当前用户的环境变量，也就是“系统属性 → 环境变量”里的用户变量。
var User = Registry{Path: "Environment"}

func (r Registry) open(access uint32) (registry.Key, error) {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, r.Path, access)
	return k, err
}

func (r Registry) Get(name string) (string, uint32, bool, error) {
	k, err := r.open(registry.QUERY_VALUE)
	if err != nil {
		return "", 0, false, err
	}
	defer k.Close()
	value, kind, err := k.GetStringValue(name)
	switch {
	case errors.Is(err, registry.ErrNotExist):
		return "", 0, false, nil
	case errors.Is(err, registry.ErrUnexpectedType):
		return "", 0, false, ErrNotString
	case err != nil:
		return "", 0, false, err
	}
	return value, kind, true, nil
}

func (r Registry) Set(name, value string, kind uint32) error {
	k, err := r.open(registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if kind == KindExpand {
		return k.SetExpandStringValue(name, value)
	}
	return k.SetStringValue(name, value)
}

func (r Registry) Delete(name string) error {
	k, err := r.open(registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if err := k.DeleteValue(name); err != nil && !errors.Is(err, registry.ErrNotExist) {
		return err
	}
	return nil
}

var sendMessageTimeout = windows.NewLazySystemDLL("user32.dll").NewProc("SendMessageTimeoutW")

// Notify 通知系统“环境变量已变化”，资源管理器等程序收到后，之后启动的程序就能读到新值。
// 每个窗口最多等 1 秒，没有响应的窗口直接跳过。
func Notify() {
	const (
		hwndBroadcast   = 0xffff
		wmSettingChange = 0x001a
		abortIfHung     = 0x0002
	)
	what, _ := windows.UTF16PtrFromString("Environment")
	var result uintptr
	sendMessageTimeout.Call(hwndBroadcast, wmSettingChange, 0, uintptr(unsafe.Pointer(what)),
		abortIfHung, 1000, uintptr(unsafe.Pointer(&result)))
}

// RemoveFromPath 把一个目录从用户的 Path 中去掉（卸载时使用），保留其余条目和原来的类型。
func RemoveFromPath(dir string) error {
	value, kind, ok, err := User.Get("Path")
	if err != nil || !ok {
		return err
	}
	same := func(entry string) bool {
		expanded, err := registry.ExpandString(entry)
		if err != nil {
			expanded = entry
		}
		return strings.EqualFold(strings.TrimRight(expanded, `\`), strings.TrimRight(dir, `\`))
	}
	var kept []string
	for _, entry := range strings.Split(value, ";") {
		if !same(entry) {
			kept = append(kept, entry)
		}
	}
	if len(kept) == len(strings.Split(value, ";")) {
		return nil
	}
	if err := User.Set("Path", strings.Join(kept, ";"), kind); err != nil {
		return err
	}
	Notify()
	return nil
}
