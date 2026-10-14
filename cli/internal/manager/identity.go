// Package manager 实现电脑上的管理身份（docs/rewrite-plan.md 第 16 节）：口令保护的设备密钥、
// 管理登录，以及解锁后对环境和变量的管理。它不在本机保存任何缓存，解锁期间的数据只在内存里。
package manager

import (
	"encoding/json"
	"errors"

	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/passphrase"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// ErrWrongPassphrase 表示口令解不开本机的管理密钥。
var ErrWrongPassphrase = errors.New("口令不对，请重新输入")

var (
	slotAAD   = []string{"harmonia.local-slot", "passphrase"}
	configAAD = []string{"harmonia.local", "manager"}
)

// protect 用新口令保护一组设备密钥，把口令槽和管理配置写入 f。
func protect(f *state.ManagerFile, pass string, keys *state.DeviceKeys) error {
	plain, err := json.Marshal(keys.Saved())
	if err != nil {
		return err
	}
	dek := hc.Random(32)
	if f.Config, err = hc.SealLocal(dek, plain, configAAD...); err != nil {
		return err
	}
	return writeSlot(f, pass, dek)
}

func writeSlot(f *state.ManagerFile, pass string, dek []byte) (err error) {
	salt := hc.Random(16)
	f.Salt = hc.B64(salt)
	f.Slot, err = hc.SealLocal(hc.PassphraseKey(pass, salt), dek, slotAAD...)
	return err
}

func openSlot(f *state.ManagerFile, pass string) ([]byte, error) {
	salt, err := hc.UnB64(f.Salt)
	if err != nil || len(salt) != 16 {
		return nil, errors.New("本机的管理登录数据已损坏，请运行 harmonia manager logout 后重新管理登录")
	}
	dek, err := hc.OpenLocal(hc.PassphraseKey(pass, salt), f.Slot, slotAAD...)
	if err != nil {
		return nil, ErrWrongPassphrase
	}
	return dek, nil
}

// Unlock 用口令解开管理身份的设备密钥。口令是否正确只看口令槽能否解开，不检查口令规则。
func Unlock(f *state.ManagerFile, pass string) (*state.DeviceKeys, error) {
	dek, err := openSlot(f, pass)
	if err != nil {
		return nil, err
	}
	plain, err := hc.OpenLocal(dek, f.Config, configAAD...)
	if err != nil {
		return nil, errors.New("本机的管理登录数据已损坏，请运行 harmonia manager logout 后重新管理登录")
	}
	var k state.Keys
	if err := json.Unmarshal(plain, &k); err != nil {
		return nil, errors.New("本机的管理登录数据已损坏，请运行 harmonia manager logout 后重新管理登录")
	}
	return k.Device(f.DeviceID)
}

// ChangePassphrase 用旧口令解开本机数据密钥，再用新口令重写口令槽；设备密钥不变。
func ChangePassphrase(d *state.Dir, f *state.ManagerFile, old, next string) error {
	dek, err := openSlot(f, old)
	if err != nil {
		return err
	}
	if err := passphrase.Validate(next); err != nil {
		return err
	}
	updated := *f
	if err := writeSlot(&updated, next, dek); err != nil {
		return err
	}
	if err := d.SaveManager(&updated); err != nil {
		return err
	}
	*f = updated
	return nil
}
