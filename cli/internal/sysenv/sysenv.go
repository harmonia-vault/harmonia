// Package sysenv 把合并后的变量写入 Windows 的用户环境变量，并在不再托管时恢复原状
// （docs/rewrite-plan.md 15.3）。这个文件是与系统无关的规则：哪些变量可以写入、
// 接管前怎样记录原状、什么时候恢复；注册表读写在 registry_windows.go。
package sysenv

import (
	"encoding/json"
	"errors"
	"maps"
	"os"
	"slices"
	"strings"
	"unicode/utf16"

	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// 注册表里环境变量的两种类型：普通字符串，以及会展开 %NAME% 的字符串。
const (
	KindString = 1
	KindExpand = 2
)

// MaxValue 是 Windows 对单个环境变量长度的限制（按 UTF-16 计）。
const MaxValue = 32767

// ErrNotString 表示同名的值不是字符串类型，Windows 不把它当作环境变量，Harmonia 也不去动它。
var ErrNotString = errors.New("不是字符串类型")

// Store 读写用户环境变量。
type Store interface {
	// Get 返回变量的值和类型；不存在时 ok 为 false。
	Get(name string) (value string, kind uint32, ok bool, err error)
	Set(name, value string, kind uint32) error
	Delete(name string) error
}

// Original 是 Harmonia 接管之前某个变量的状态。
type Original struct {
	Had   bool   `json:"had"`
	Value string `json:"value,omitempty"`
	Kind  uint32 `json:"kind,omitempty"`
}

// Record 保存在数据目录的 sysenv.json 中。
type Record struct {
	// Enabled 是“写入用户环境变量”的开关，退出登录后保留。
	Enabled bool `json:"enabled"`
	// Managed 是 Harmonia 正在托管的变量名，以及它们被接管之前的状态。
	Managed map[string]Original `json:"managed"`
}

// Skip 是一个没有写入的变量及原因。
type Skip struct{ Name, Reason string }

// 系统自身使用的变量名，“写入系统变量”开关关闭时不写入。
var system = func() map[string]bool {
	m := map[string]bool{}
	for _, n := range strings.Fields(`PATH PATHEXT TEMP TMP USERNAME USERPROFILE USERDOMAIN USERDOMAIN_ROAMINGPROFILE
		USERDNSDOMAIN HOMEDRIVE HOMEPATH HOMESHARE APPDATA LOCALAPPDATA PROGRAMDATA ALLUSERSPROFILE PUBLIC
		PROGRAMFILES PROGRAMW6432 COMMONPROGRAMFILES COMMONPROGRAMW6432 SYSTEMROOT SYSTEMDRIVE WINDIR COMSPEC OS
		COMPUTERNAME LOGONSERVER SESSIONNAME CLIENTNAME NUMBER_OF_PROCESSORS PROCESSOR_ARCHITECTURE
		PROCESSOR_ARCHITEW6432 PROCESSOR_IDENTIFIER PROCESSOR_LEVEL PROCESSOR_REVISION PSMODULEPATH DRIVERDATA
		ONEDRIVE ONEDRIVECONSUMER ONEDRIVECOMMERCIAL`) {
		m[n] = true
	}
	return m
}()

// IsSystem 判断变量名是否是 Windows 自身使用的。Windows 的变量名不区分大小写。
func IsSystem(name string) bool { return system[strings.ToUpper(name)] }

// Select 从合并结果中选出可以写入用户环境变量的部分，其余的连同原因一起返回。
// systemVars 是这台设备的“写入系统变量”开关。
func Select(vars map[string]string, systemVars bool) (map[string]string, []Skip) {
	want := map[string]string{}
	taken := map[string]string{}
	var skipped []Skip
	for _, n := range sortedKeys(vars) {
		v := vars[n]
		reason := ""
		switch {
		case !systemVars && IsSystem(n):
			reason = "是系统自身使用的变量，默认不写入；确实需要时运行 harmonia shell system-vars on"
		case v == "":
			reason = "值为空，Windows 的环境变量不能为空"
		case strings.ContainsRune(v, 0) || len(utf16.Encode([]rune(v))) > MaxValue:
			reason = "值超出了 Windows 对环境变量的限制"
		case taken[strings.ToUpper(n)] != "":
			reason = "与 " + taken[strings.ToUpper(n)] + " 只有大小写不同，Windows 把它们当成同一个变量"
		}
		if reason != "" {
			skipped = append(skipped, Skip{n, reason})
			continue
		}
		taken[strings.ToUpper(n)] = n
		want[n] = v
	}
	return want, skipped
}

// Apply 让用户环境变量与 want 一致：不再托管的变量恢复成接管前的样子，新接管的变量先记下原状再写入。
// save 用来保存 rec；新接管的记录在写入之前保存，恢复的记录在恢复之后删除，中途失败时原状不会丢。
// 返回用户环境变量是否有变化。
func Apply(st Store, rec *Record, want map[string]string, save func() error) (bool, error) {
	if rec.Managed == nil {
		rec.Managed = map[string]Original{}
	}
	wanted := map[string]bool{}
	for n := range want {
		wanted[strings.ToUpper(n)] = true
	}
	managed := map[string]bool{}
	changed, dirty := false, false
	for _, n := range sortedKeys(rec.Managed) {
		if wanted[strings.ToUpper(n)] {
			managed[strings.ToUpper(n)] = true
			continue
		}
		o := rec.Managed[n]
		var err error
		if o.Had {
			err = st.Set(n, o.Value, o.Kind)
		} else {
			err = st.Delete(n)
		}
		if err != nil {
			return changed, err
		}
		delete(rec.Managed, n)
		changed, dirty = true, true
	}
	if dirty {
		if err := save(); err != nil {
			return changed, err
		}
	}
	var write []string
	dirty = false
	for _, n := range sortedKeys(want) {
		if !managed[strings.ToUpper(n)] {
			value, kind, ok, err := st.Get(n)
			if errors.Is(err, ErrNotString) {
				continue
			}
			if err != nil {
				return changed, err
			}
			rec.Managed[n] = Original{Had: ok, Value: value, Kind: kind}
			dirty = true
		}
		write = append(write, n)
	}
	if dirty {
		if err := save(); err != nil {
			return changed, err
		}
	}
	for _, n := range write {
		value, kind, ok, err := st.Get(n)
		if err == nil && ok && value == want[n] && kind == KindString {
			continue
		}
		if err := st.Set(n, want[n], KindString); err != nil {
			return changed, err
		}
		changed = true
	}
	return changed, nil
}

func sortedKeys[V any](m map[string]V) []string {
	return slices.Sorted(maps.Keys(m))
}

// Load 读取记录；文件不存在时返回空记录（开关关闭）。
func Load(path string) (*Record, error) {
	rec := &Record{Managed: map[string]Original{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return rec, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, rec); err != nil {
		return nil, errors.New("本机记录的用户环境变量原状（sysenv.json）已损坏，请在“系统属性 → 环境变量”中检查用户变量后删除这个文件")
	}
	if rec.Managed == nil {
		rec.Managed = map[string]Original{}
	}
	return rec, nil
}

// Save 保存记录。
func (r *Record) Save(path string) error {
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	return state.WriteAtomic(path, data)
}
