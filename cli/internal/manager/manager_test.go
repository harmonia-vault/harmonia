package manager

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/app"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/refs"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

func TestProtectUnlockChange(t *testing.T) {
	t.Setenv("HARMONIA_HOME", t.TempDir())
	d, err := state.Open()
	if err != nil {
		t.Fatal(err)
	}
	keys := state.NewDeviceKeys()
	keys.ID = hc.NewID()
	f := &state.ManagerFile{Server: "http://localhost:1", AccountID: hc.NewID(), Email: "a@example.com", RootPub: "x", DeviceID: keys.ID, DeviceName: "电脑（管理）"}
	if err := protect(f, "Hqzv-mtkw 7", keys); err != nil {
		t.Fatal(err)
	}
	if err := d.SaveManager(f); err != nil {
		t.Fatal(err)
	}
	loaded, err := d.Manager()
	if err != nil || loaded == nil {
		t.Fatalf("读不回管理身份：%v", err)
	}
	got, err := Unlock(loaded, "Hqzv-mtkw 7")
	if err != nil || got.ID != keys.ID || hc.B64(got.Sign.Seed) != hc.B64(keys.Sign.Seed) || hc.B64(got.Box.Seed) != hc.B64(keys.Box.Seed) {
		t.Fatalf("解开的密钥不对：%v", err)
	}
	if _, err := Unlock(loaded, "hqzv-mtkw 7"); !errors.Is(err, ErrWrongPassphrase) {
		t.Fatalf("口令不对时应当报错，实际：%v", err)
	}
	if err := ChangePassphrase(d, loaded, "wrong-Old-1", "Nw9_another_K"); !errors.Is(err, ErrWrongPassphrase) {
		t.Fatalf("旧口令不对时不应能修改：%v", err)
	}
	if err := ChangePassphrase(d, loaded, "Hqzv-mtkw 7", "password1"); err == nil {
		t.Fatal("新口令太常见时不应能修改")
	}
	if err := ChangePassphrase(d, loaded, "Hqzv-mtkw 7", "Nw9_another_K"); err != nil {
		t.Fatal(err)
	}
	again, _ := d.Manager()
	if _, err := Unlock(again, "Hqzv-mtkw 7"); !errors.Is(err, ErrWrongPassphrase) {
		t.Fatal("修改后旧口令不应再能解开")
	}
	// 解锁不检查口令规则：这里直接写入一个不合规的口令，仍然要能解开。
	if err := writeSlot(again, "short", mustDEK(t, again, "Nw9_another_K")); err != nil {
		t.Fatal(err)
	}
	if _, err := Unlock(again, "short"); err != nil {
		t.Fatalf("已经设置的口令即使不符合现在的规则也要能解开：%v", err)
	}
	if err := d.RemoveManager(); err != nil {
		t.Fatal(err)
	}
	if m, err := d.Manager(); m != nil || err != nil {
		t.Fatalf("删除后不应还有管理身份：%v %v", m, err)
	}
}

func mustDEK(t *testing.T, f *state.ManagerFile, pass string) []byte {
	dek, err := openSlot(f, pass)
	if err != nil {
		t.Fatal(err)
	}
	return dek
}

// newSession 造一个已经同步过的会话：两个变量库 a、b，各有几个变量；环境 ea 引用 a 的全部变量，
// 环境 mix 勾选 a 的 ONLY_A（改名为 RENAMED）并引用 b 的全部变量。另有一台手机和一台授权了 ea 的电脑。
func newSession(t *testing.T) *Session {
	keys := state.NewDeviceKeys()
	keys.ID = hc.NewID()
	root := hc.SignKeyFromSeed(hc.Random(32))
	s := Open(nil, &state.ManagerFile{Server: "http://localhost:1", RootPub: hc.B64(root.Pub), DeviceID: keys.ID}, keys)
	s.root = root
	s.info = &api.ManagerInfo{}
	for _, v := range []struct {
		id   string
		vars map[string]string
	}{{"a", map[string]string{"SAME": "1", "DIFF": "old", "ONLY_A": "值"}}, {"b", map[string]string{"SAME": "1", "DIFF": "new", "NOTE": "n"}}} {
		key := hc.Random(32)
		sealed, _ := hc.Seal(key, keys.Box.Pub[:])
		s.info.Vaults = append(s.info.Vaults, api.ManagerVault{ID: v.id, Name: "库" + v.id, KeyVersion: "1"})
		s.cache.Envelopes = append(s.cache.Envelopes, api.Envelope{VaultID: v.id, KeyVersion: "1", Sealed: hc.B64(sealed)})
		s.cache.Variables[v.id] = map[string]state.CachedVar{}
		for n, val := range v.vars {
			ct, _ := hc.EncryptVar(key, v.id, 1, n, hc.Entry{Value: val})
			s.cache.Variables[v.id][n] = state.CachedVar{Value: ct, KeyVersion: 1}
		}
	}
	s.info.Environments = []api.ManagerEnv{
		{ID: "ea", Name: "只有 a", Refs: []api.Ref{{VaultID: "a", Scope: "all", Writable: true}}},
		{ID: "mix", Name: "混合", Refs: []api.Ref{
			{VaultID: "a", Scope: "pick", Items: []api.RefItem{{Name: "ONLY_A", As: "RENAMED"}}},
			{VaultID: "b", Scope: "all"},
			{VaultID: "gone", Scope: "all", Missing: true},
		}},
	}
	for i, e := range s.info.Environments {
		items, shadowed := refs.Expand(e.Refs, s.namesLocked)
		s.cache.Environments = append(s.cache.Environments, api.Environment{ID: e.ID, Name: e.Name, Role: "rw", LocalDecrypt: true, Position: i, Items: items, Shadowed: shadowed})
	}
	// 这台电脑对 ea 的授权一直有效，对 mix 的授权已经到期。
	laptop := api.Device{ID: "laptop", Kind: "client", Grants: []api.DeviceGrant{{EnvironmentID: "ea"}, {EnvironmentID: "mix", ExpiresAt: 1}}}
	s.info.Devices = []api.Device{{ID: "phone", Kind: "manager"}, {ID: keys.ID, Kind: "manager"}, laptop}
	return s
}

func TestSessionViews(t *testing.T) {
	s := newSession(t)
	envs := s.Envs()
	if len(envs) != 2 || envs[0].Count != 3 || envs[0].Devices != 3 || envs[1].Devices != 2 || envs[1].Count != 4 || envs[1].Problems != 1 {
		t.Fatalf("环境概况不对：%+v", envs)
	}
	vaults := s.Vaults()
	if len(vaults) != 2 || vaults[0].Count != 3 || !reflect.DeepEqual(vaults[0].Envs, []string{"只有 a", "混合"}) || !reflect.DeepEqual(vaults[1].Envs, []string{"混合"}) {
		t.Fatalf("变量库概况不对：%+v", vaults)
	}
	d, err := s.Env("mix")
	if err != nil || len(d.Refs) != 3 || d.Refs[0].VaultName != "库a" || d.Refs[2].VaultName != "" || !d.Refs[2].Missing || d.Items[0].Name != "RENAMED" {
		t.Fatalf("环境详情不对：%+v %v", d, err)
	}
	vars, err := s.Vars("a")
	if err != nil || len(vars) != 3 || vars[0].Name != "DIFF" || vars[1].Name != "ONLY_A" || vars[1].Length != 1 {
		t.Fatalf("变量列表不对：%+v %v", vars, err)
	}
	if v, err := s.Value("a", "ONLY_A"); err != nil || v != "值" {
		t.Fatalf("取值不对：%q %v", v, err)
	}
	if _, err := s.Value("a", "NOPE"); err == nil {
		t.Fatal("不存在的变量应当报错")
	}
	if _, err := s.Vars("gone"); err == nil {
		t.Fatal("不存在的变量库应当报错")
	}
	str := func(v string) *string { return &v }
	diff, err := s.Diff("b", map[string]app.VarChange{
		"SAME": {Value: str("1")}, "DIFF": {Value: str("old")}, "NEW": {Value: str("x")}, "NOTE": {Note: str("备注")},
	}, []string{"SAME", "DIFF", "NEW", "NOTE"})
	want := []DiffItem{{"SAME", "same"}, {"DIFF", "changed"}, {"NEW", "new"}, {"NOTE", "changed"}}
	if err != nil || !reflect.DeepEqual(diff, want) {
		t.Fatalf("对比不对：%+v %v", diff, err)
	}
	cp, err := s.CopyDiff("a", "b", []string{"SAME", "DIFF", "ONLY_A", "MISSING"})
	want = []DiffItem{{"SAME", "same"}, {"DIFF", "changed"}, {"ONLY_A", "new"}}
	if err != nil || !reflect.DeepEqual(cp, want) {
		t.Fatalf("复制对比不对：%+v %v", cp, err)
	}
	if _, err := s.CopyDiff("a", "a", []string{"SAME"}); err == nil {
		t.Fatal("复制到同一个变量库应当报错")
	}

	// 解不开的变量单独标出，其他变量照常可用；它只能删除或重新写入。
	s.cache.Variables["b"]["BROKEN"] = state.CachedVar{Value: hc.B64(hc.Random(48)), KeyVersion: 1}
	vars, err = s.Vars("b")
	if err != nil || len(vars) != 4 || vars[0] != (VarInfo{Name: "BROKEN", Broken: true}) {
		t.Fatalf("解不开的变量没有单独标出：%+v %v", vars, err)
	}
	if _, err := s.Value("b", "BROKEN"); err == nil {
		t.Fatal("解不开的变量取值应当报错")
	}
	diff, err = s.Diff("b", map[string]app.VarChange{"BROKEN": {Value: str("x")}}, []string{"BROKEN"})
	if err != nil || diff[0].Status != "changed" {
		t.Fatalf("重新写入解不开的变量：%+v %v", diff, err)
	}
}

// 编辑环境时的预览：重名在本机就指出，保存前拒绝。
func TestPreviewAndDuplicateCheck(t *testing.T) {
	s := newSession(t)
	both := []api.Ref{{VaultID: "a", Scope: "all"}, {VaultID: "b", Scope: "all"}}
	items, shadowed, dup := s.Preview(both)
	if len(items) != 4 || len(shadowed) != 2 || !reflect.DeepEqual(dup, []string{"DIFF", "SAME"}) {
		t.Fatalf("预览不对：%v %v %v", items, shadowed, dup)
	}
	if _, err := s.checkRefsLocked(both); err == nil || !strings.Contains(err.Error(), "DIFF、SAME") {
		t.Fatalf("重名应在提交前拒绝：%v", err)
	}
	renamed := []api.Ref{{VaultID: "a", Scope: "all", Items: []api.RefItem{{Name: "DIFF", As: "OLD_DIFF"}, {Name: "SAME", As: "SAME_A"}}}, {VaultID: "b", Scope: "all"}}
	if got, err := s.checkRefsLocked(renamed); err != nil || got[1].Items == nil {
		t.Fatalf("改名后应能保存：%v", err)
	}
}
