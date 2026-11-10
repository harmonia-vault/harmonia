package vault

import (
	"fmt"
	"slices"
	"sort"
	"strings"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// Target 是写入或删除变量时指定的位置：一个环境，或者一个变量库（设计文档 17.2）。
type Target struct {
	Env       *api.Environment
	VaultID   string
	VaultName string
	// SameName 是与环境同名的变量库（例如新建变量库时一起创建的同名环境）。
	// 环境里没有要新增的变量时改写到它，免得“改用变量库”的提示又匹配回环境。
	SameName *api.VaultName
}

// Label 是给用户看的位置名称。
func (t Target) Label() string {
	if t.Env != nil {
		return "环境“" + t.Env.Name + "”"
	}
	return "变量库“" + t.VaultName + "”"
}

// Dest 是变量真正写入的地方：变量库和其中的原名。Env 是提供写权限的环境，Name 是变量在其中的名字，
// 新增变量时为空。Env 没有开启本机解密时，经手机批准写入（设计文档 17.4）。
type Dest struct {
	VaultID string
	Source  string
	Env     *api.Environment
	Name    string
}

// Remote 表示这次写入要经手机批准。
func (d Dest) Remote() bool { return !d.Env.LocalDecrypt }

// ApprovalItem 是这次写入在批准请求里的一项：修改用环境里的名字，新增带变量库。
func (d Dest) ApprovalItem() api.ApprovalItem {
	if d.Name == "" {
		return api.ApprovalItem{EnvironmentID: d.Env.ID, Name: d.Source, VaultID: d.VaultID}
	}
	return api.ApprovalItem{EnvironmentID: d.Env.ID, Name: d.Name}
}

// FindVault 按 ID 或名称（不区分大小写）查找这台设备的环境引用到的变量库。
func FindVault(c *state.Cache, nameOrID string) (*api.VaultName, error) {
	var match []api.VaultName
	for _, v := range c.VaultNames {
		if v.ID == nameOrID {
			return &v, nil
		}
		if strings.EqualFold(v.Name, nameOrID) {
			match = append(match, v)
		}
	}
	switch len(match) {
	case 1:
		return &match[0], nil
	case 0:
		return nil, nil
	default:
		return nil, fmt.Errorf("有多个名为“%s”的变量库，请改用变量库 ID", nameOrID)
	}
}

// ResolveTarget 解析写入的位置：先按环境匹配，再按变量库匹配；vaultOnly 时只认变量库。
func ResolveTarget(c *state.Cache, nameOrID string, vaultOnly bool) (Target, error) {
	if !vaultOnly {
		if env, err := Find(c, nameOrID); err == nil {
			same, _ := FindVault(c, nameOrID)
			return Target{Env: env, SameName: same}, nil
		}
	}
	v, err := FindVault(c, nameOrID)
	if err != nil {
		return Target{}, err
	}
	if v != nil {
		return Target{VaultID: v.ID, VaultName: v.Name}, nil
	}
	if vaultOnly {
		return Target{}, fmt.Errorf("找不到变量库“%s”。%s", nameOrID, creatableHint(c, 0))
	}
	_, err = Find(c, nameOrID)
	return Target{}, err
}

// writableEnvs 是这台设备有读写权限、未到期的环境；可以在本机解密的排在前面。
func writableEnvs(c *state.Cache, nowMs int64) []api.Environment {
	var out []api.Environment
	for _, e := range Ordered(c) {
		if e.Role == "rw" && !Expired(e, nowMs) {
			out = append(out, e)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].LocalDecrypt && !out[j].LocalDecrypt })
	return out
}

// creatableHint 列出这台设备可以新增变量的变量库。
func creatableHint(c *state.Cache, nowMs int64) string {
	var names []string
	for _, e := range writableEnvs(c, nowMs) {
		for _, id := range e.CreateVaults {
			if n := vaultName(c, id); !slices.Contains(names, n) {
				names = append(names, n)
			}
		}
	}
	if len(names) == 0 {
		return "这台设备现在不能新增变量：需要在管理设备上为它授予读写权限，并让环境以“全部变量”的方式引用一个变量库"
	}
	return "可以新增变量的变量库：“" + strings.Join(names, "”“") + "”，写成 harmonia var set <变量库> <变量名>"
}

func vaultName(c *state.Cache, id string) string {
	for _, v := range c.VaultNames {
		if v.ID == id {
			return v.Name
		}
	}
	return id
}

// CheckWritable 检查这台设备能否修改这个环境里的变量（与具体变量无关的部分）。
func CheckWritable(env *api.Environment, nowMs int64) error {
	if Expired(*env, nowMs) {
		return fmt.Errorf("这台设备对环境“%s”的授权已到期，请在管理设备上重新授权", env.Name)
	}
	if env.Role != "rw" {
		return fmt.Errorf("这台设备对环境“%s”只有只读权限，不能修改。可以在管理设备上调整权限", env.Name)
	}
	return nil
}

// WriteDest 检查能否修改（或新增、删除）这个变量，返回它在变量库里的位置。
// 写环境时只能修改环境里已有的变量；新增变量必须指定变量库（设计文档 17.2）。
func WriteDest(c *state.Cache, t Target, name string, nowMs int64) (Dest, error) {
	if t.Env != nil {
		env := t.Env
		if err := CheckWritable(env, nowMs); err != nil {
			return Dest{}, err
		}
		for _, it := range env.Items {
			if it.Name == name {
				return Dest{VaultID: it.VaultID, Source: it.Source, Env: env, Name: name}, nil
			}
		}
		if t.SameName != nil {
			return WriteDest(c, Target{VaultID: t.SameName.ID, VaultName: t.SameName.Name}, name, nowMs)
		}
		return Dest{}, fmt.Errorf("环境“%s”里没有 %s。新增变量需要指定变量库。%s", env.Name, name, creatableHint(c, nowMs))
	}
	for _, e := range writableEnvs(c, nowMs) {
		for _, it := range e.Items {
			if it.VaultID == t.VaultID && it.Source == name {
				return Dest{VaultID: t.VaultID, Source: name, Env: &e, Name: it.Name}, nil
			}
		}
		if slices.Contains(e.CreateVaults, t.VaultID) {
			return Dest{VaultID: t.VaultID, Source: name, Env: &e}, nil
		}
	}
	return Dest{}, fmt.Errorf("这台设备不能修改变量库“%s”里的 %s：需要在管理设备上为引用这个变量的环境授予读写权限。%s", t.VaultName, name, creatableHint(c, nowMs))
}
