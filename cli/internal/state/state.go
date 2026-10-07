// Package state 管理本机数据目录（默认 ~/.harmonia，可用 HARMONIA_HOME 覆盖）。
// 目录权限 0700、文件 0600，写入采用临时文件 + 原子替换。
package state

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
)

type Config struct {
	Server     string `json:"server"`
	AccountID  string `json:"accountId"`
	Email      string `json:"email"`
	RootPub    string `json:"rootPub"`
	DeviceID   string `json:"deviceId"`
	DeviceName string `json:"deviceName"`
	LastSync   int64  `json:"lastSync"`
}

// Paired 表示本机已接入账号。
func (c *Config) Paired() bool { return c.DeviceID != "" }

type Keys struct {
	SignSeed string `json:"signSeed"`
	BoxSeed  string `json:"boxSeed"`
}

type CachedVar struct {
	Value      string `json:"value"`
	KeyVersion int    `json:"keyVersion"`
}

type Cache struct {
	Seq          int64                           `json:"seq"`
	Environments []api.Environment               `json:"environments"`
	Envelopes    []api.Envelope                  `json:"envelopes"`
	Variables    map[string]map[string]CachedVar `json:"variables"`
}

// Overrides：环境 ID → 变量名 → 本机值。
type Overrides map[string]map[string]string

type Dir struct{ Path string }

func Open() (*Dir, error) {
	p := os.Getenv("HARMONIA_HOME")
	if p == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		p = filepath.Join(home, ".harmonia")
	}
	if err := os.MkdirAll(p, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(p, 0o700); err != nil {
		return nil, err
	}
	return &Dir{Path: p}, nil
}

func (d *Dir) File(name string) string { return filepath.Join(d.Path, name) }

// EnvFile 是供 shell 读取的变量文件。
func (d *Dir) EnvFile() string { return d.File("env.sh") }

// Lock 在整个数据目录上加排他锁，返回解锁函数。
func (d *Dir) Lock() (func(), error) {
	f, err := os.OpenFile(d.File("lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}

// WriteAtomic 以 0600 原子写入文件。
func WriteAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func (d *Dir) readJSON(name string, v any) error {
	data, err := os.ReadFile(d.File(name))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, v); err != nil {
		return errors.New("本机数据文件 " + name + " 已损坏，可以运行 harmonia logout 后重新接入")
	}
	return nil
}

func (d *Dir) writeJSON(name string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return WriteAtomic(d.File(name), data)
}

func (d *Dir) Config() (*Config, error) {
	var c Config
	return &c, d.readJSON("config.json", &c)
}

func (d *Dir) SaveConfig(c *Config) error { return d.writeJSON("config.json", c) }

func (d *Dir) Keys() (*Keys, error) {
	var k Keys
	return &k, d.readJSON("keys.json", &k)
}

func (d *Dir) SaveKeys(k *Keys) error { return d.writeJSON("keys.json", k) }

func (d *Dir) Cache() (*Cache, error) {
	c := Cache{Variables: map[string]map[string]CachedVar{}}
	if err := d.readJSON("cache.json", &c); err != nil {
		return nil, err
	}
	if c.Variables == nil {
		c.Variables = map[string]map[string]CachedVar{}
	}
	return &c, nil
}

func (d *Dir) SaveCache(c *Cache) error { return d.writeJSON("cache.json", c) }

func (d *Dir) Overrides() (Overrides, error) {
	o := Overrides{}
	return o, d.readJSON("overrides.json", &o)
}

func (d *Dir) SaveOverrides(o Overrides) error { return d.writeJSON("overrides.json", o) }

// Wipe 删除账号相关的全部本机数据（密钥、缓存、覆盖值、变量文件），保留服务器地址。
func (d *Dir) Wipe() error {
	for _, name := range []string{"keys.json", "cache.json", "overrides.json"} {
		if err := os.Remove(d.File(name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := WriteAtomic(d.EnvFile(), []byte(EnvFileHeader+"\n")); err != nil {
		return err
	}
	c, err := d.Config()
	if err != nil {
		c = &Config{}
	}
	return d.SaveConfig(&Config{Server: c.Server, Email: c.Email})
}

// EnvFileHeader 是变量文件的固定开头。
const EnvFileHeader = "# 由 Harmonia 自动生成，请勿手动修改；修改会在下一次同步时被覆盖。\n# keys:"

// DeviceKeys 由保存的种子还原设备密钥，并实现 api.Signer。
type DeviceKeys struct {
	ID   string
	Sign hc.SignKey
	Box  hc.BoxKey
}

func NewDeviceKeys() *DeviceKeys {
	return &DeviceKeys{Sign: hc.SignKeyFromSeed(hc.Random(32)), Box: hc.BoxKeyFromSeed(hc.Random(32))}
}

func (k *Keys) Device(id string) (*DeviceKeys, error) {
	s, err1 := hc.UnB64(k.SignSeed)
	b, err2 := hc.UnB64(k.BoxSeed)
	if err1 != nil || err2 != nil || len(s) != 32 || len(b) != 32 {
		return nil, errors.New("本机密钥文件已损坏，请运行 harmonia logout 后重新接入")
	}
	return &DeviceKeys{ID: id, Sign: hc.SignKeyFromSeed(s), Box: hc.BoxKeyFromSeed(b)}, nil
}

func (k *DeviceKeys) Saved() *Keys {
	return &Keys{SignSeed: hc.B64(k.Sign.Seed), BoxSeed: hc.B64(k.Box.Seed)}
}

func (k *DeviceKeys) DeviceID() string { return k.ID }

func (k *DeviceKeys) SignAuth(nonce string) string {
	return hc.B64(k.Sign.Sign(hc.AuthMsg(k.ID, nonce)))
}
