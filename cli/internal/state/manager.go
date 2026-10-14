package state

import (
	"errors"
	"os"
)

// ManagerFile 是电脑上的管理身份（docs/protocol.md 2.5）。它与日常身份各自独立，所以自己记录服务器和账号。
// Salt、Slot、Config 之外的字段是明文，只用于连接服务器和提示用户。
type ManagerFile struct {
	Server     string `json:"server"`
	AccountID  string `json:"accountId"`
	Email      string `json:"email"`
	RootPub    string `json:"rootPub"`
	DeviceID   string `json:"deviceId"`
	DeviceName string `json:"deviceName"`
	Salt       string `json:"salt"`
	// Slot 是用口令派生的密钥加密的本机数据密钥；Config 是用本机数据密钥加密的设备密钥。
	Slot   string `json:"slot"`
	Config string `json:"config"`
}

const managerFile = "manager.json"

// Manager 读取管理身份；没有管理登录时返回 nil。
func (d *Dir) Manager() (*ManagerFile, error) {
	if _, err := os.Stat(d.File(managerFile)); errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	var m ManagerFile
	if err := d.readJSON(managerFile, &m); err != nil {
		return nil, errors.New("本机的管理登录数据已损坏，请运行 harmonia manager logout 后重新管理登录")
	}
	if m.DeviceID == "" || m.Slot == "" || m.Config == "" {
		return nil, errors.New("本机的管理登录数据已损坏，请运行 harmonia manager logout 后重新管理登录")
	}
	return &m, nil
}

func (d *Dir) SaveManager(m *ManagerFile) error { return d.writeJSON(managerFile, m) }

func (d *Dir) RemoveManager() error {
	if err := os.Remove(d.File(managerFile)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}
