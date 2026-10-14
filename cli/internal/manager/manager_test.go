package manager

import (
	"errors"
	"reflect"
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/app"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

func TestParseDotenv(t *testing.T) {
	text := "\xEF\xBB\xBF# 注释\r\n" +
		"PLAIN=value with spaces   \r\n" +
		"export EXPORTED=1\n" +
		"INLINE=abc # 行尾注释\n" +
		"HASH=abc#不是注释\n" +
		"EMPTY=\n" +
		"SINGLE='原样 $HOME \\n'\n" +
		"DOUBLE=\"a\\nb \\\"q\\\" \\$x \\\\ \\z\" # 注释\n" +
		"MULTI=\"第一行\n第二行\"\n" +
		"PLAIN=later\n" +
		"1BAD=x\n" +
		"没有等号\n" +
		"OPEN='没有闭合\n"
	vars, names, errs := ParseDotenv(text)
	want := map[string]string{
		"PLAIN": "later", "EXPORTED": "1", "INLINE": "abc", "HASH": "abc#不是注释", "EMPTY": "",
		"SINGLE": "原样 $HOME \\n", "DOUBLE": "a\nb \"q\" $x \\ \\z", "MULTI": "第一行\n第二行",
	}
	if !reflect.DeepEqual(vars, want) {
		t.Errorf("变量不对：\n得到 %q\n期望 %q", vars, want)
	}
	if got := []string{"PLAIN", "EXPORTED", "INLINE", "HASH", "EMPTY", "SINGLE", "DOUBLE", "MULTI"}; !reflect.DeepEqual(names, got) {
		t.Errorf("顺序不对：%v", names)
	}
	var lines []int
	for _, e := range errs {
		lines = append(lines, e.Line)
	}
	if !reflect.DeepEqual(lines, []int{12, 13, 14}) {
		t.Errorf("出错的行不对：%v（%v）", lines, errs)
	}
}

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

// newSession 造一个已经同步过的会话：两个环境，各有几个变量，另有一台手机和一台授权了 a 的电脑。
func newSession(t *testing.T) *Session {
	keys := state.NewDeviceKeys()
	keys.ID = hc.NewID()
	root := hc.SignKeyFromSeed(hc.Random(32))
	s := Open(nil, &state.ManagerFile{Server: "http://localhost:1", RootPub: hc.B64(root.Pub), DeviceID: keys.ID}, keys)
	s.root = root
	for i, env := range []struct {
		id   string
		vars map[string]string
	}{{"a", map[string]string{"SAME": "1", "DIFF": "old", "ONLY_A": "值"}}, {"b", map[string]string{"SAME": "1", "DIFF": "new", "NOTE": "n"}}} {
		key := hc.Random(32)
		sealed, _ := hc.Seal(key, keys.Box.Pub[:])
		s.cache.Environments = append(s.cache.Environments, api.Environment{ID: env.id, Name: env.id, KeyVersion: "1", Role: "rw", Position: i})
		s.cache.Envelopes = append(s.cache.Envelopes, api.Envelope{EnvID: env.id, KeyVersion: "1", Sealed: hc.B64(sealed)})
		s.cache.Variables[env.id] = map[string]state.CachedVar{}
		for n, v := range env.vars {
			ct, _ := hc.EncryptVar(key, env.id, 1, n, hc.Entry{Value: v})
			s.cache.Variables[env.id][n] = state.CachedVar{Value: ct, KeyVersion: 1}
		}
	}
	// 这台电脑对 a 的授权一直有效，对 b 的授权已经到期。
	laptop := api.Device{ID: "laptop", Kind: "client", Grants: []api.DeviceGrant{{EnvID: "a"}, {EnvID: "b", ExpiresAt: 1}}}
	s.info = &api.ManagerInfo{Devices: []api.Device{{ID: "phone", Kind: "manager"}, {ID: keys.ID, Kind: "manager"}, laptop}}
	return s
}

func TestSessionViews(t *testing.T) {
	s := newSession(t)
	envs := s.Envs()
	if len(envs) != 2 || envs[0].Count != 3 || envs[0].Devices != 3 || envs[1].Devices != 2 {
		t.Fatalf("环境概况不对：%+v", envs)
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
		t.Fatal("不存在的环境应当报错")
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
		t.Fatal("复制到同一个环境应当报错")
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
