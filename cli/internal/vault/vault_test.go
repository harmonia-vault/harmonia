package vault

import (
	"strings"
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

type fixture struct {
	root  hc.SignKey
	dev   *state.DeviceKeys
	cache *state.Cache
}

func newFixture(t *testing.T) *fixture {
	f := &fixture{root: hc.SignKeyFromSeed(hc.Random(32)), dev: state.NewDeviceKeys()}
	f.dev.ID = hc.NewID()
	f.cache = &state.Cache{Variables: map[string]map[string]state.CachedVar{}}
	return f
}

func (f *fixture) sync(t *testing.T, since int64, envs map[string]map[string]string, extra ...api.Variable) *api.Sync {
	s := &api.Sync{Seq: since + 1}
	for id, vars := range envs {
		key := hc.Random(32)
		sealed, _ := hc.Seal(key, f.dev.Box.Pub[:])
		s.Environments = append(s.Environments, api.Environment{ID: id, Name: id, KeyVersion: "1", Role: "rw"})
		s.Envelopes = append(s.Envelopes, api.Envelope{EnvID: id, KeyVersion: "1", Sealed: hc.B64(sealed),
			Sig: hc.B64(f.root.Sign(hc.EnvelopeMsg(id, 1, f.dev.ID, sealed)))})
		for n, v := range vars {
			ct, _ := hc.EncryptVar(key, id, 1, n, hc.Entry{Value: v})
			s.Variables = append(s.Variables, api.Variable{EnvID: id, Name: n, Value: ct, KeyVersion: "1"})
		}
	}
	s.Variables = append(s.Variables, extra...)
	return s
}

func TestApplyMergeOverride(t *testing.T) {
	f := newFixture(t)
	s := f.sync(t, 0, map[string]map[string]string{
		"low":  {"A": "low-a", "B": "low-b"},
		"high": {"A": "high-a", "C": "high-c"},
	})
	if err := Apply(f.cache, s, 0, hc.B64(f.root.Pub), f.dev.ID); err != nil {
		t.Fatal(err)
	}
	acts := []string{"high", "low"}
	ov := state.Overrides{"low": {"B": "local-b", "NOT_IN_CLOUD": "x"}, "high": {"A": "local-a"}}
	got, skipped := Merge(f.cache, f.dev, acts, ov, 0)
	want := map[string]string{"A": "local-a", "B": "local-b", "C": "high-c"}
	if len(skipped) != 0 || len(got) != len(want) {
		t.Fatalf("got %v skipped %v", got, skipped)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: got %q want %q", k, got[k], v)
		}
	}

	// 失去 high 的访问权：其变量与缓存被清除。
	f.cache.Environments = f.cache.Environments[:0]
	s2 := &api.Sync{Seq: 5}
	for _, e := range s.Environments {
		if e.ID == "low" {
			s2.Environments = append(s2.Environments, e)
		}
	}
	for _, e := range s.Envelopes {
		if e.EnvID == "low" {
			s2.Envelopes = append(s2.Envelopes, e)
		}
	}
	s2.Variables = []api.Variable{{EnvID: "low", Name: "B", Deleted: true}}
	if err := Apply(f.cache, s2, 1, hc.B64(f.root.Pub), f.dev.ID); err != nil {
		t.Fatal(err)
	}
	got, skipped = Merge(f.cache, f.dev, acts, ov, 0)
	if _, ok := f.cache.Variables["high"]; ok || len(skipped) != 1 || got["A"] != "low-a" || got["B"] != "" {
		t.Fatalf("after revoke: %v %v", got, skipped)
	}
}

func TestActiveOrderAndConflicts(t *testing.T) {
	f := newFixture(t)
	s := f.sync(t, 0, map[string]map[string]string{
		"a": {"K": "from-a", "ONLY_A": "1"},
		"b": {"K": "from-b"},
		"c": {"K": "from-c"},
	})
	if err := Apply(f.cache, s, 0, hc.B64(f.root.Pub), f.dev.ID); err != nil {
		t.Fatal(err)
	}
	pos := map[string]int{"b": 0, "a": 1, "c": 2}
	for i := range f.cache.Environments {
		e := &f.cache.Environments[i]
		e.Position, e.Active = pos[e.ID], e.ID != "c"
	}
	ids := ActiveIDs(f.cache)
	if len(ids) != 2 || ids[0] != "b" || ids[1] != "a" {
		t.Fatalf("active ids: %v", ids)
	}
	if got, _ := Merge(f.cache, f.dev, ids, nil, 0); got["K"] != "from-b" || got["ONLY_A"] != "1" {
		t.Fatalf("merge: %v", got)
	}
	cs := Conflicts(f.cache, f.dev, ids, 0)
	if len(cs) != 1 || cs[0].Name != "K" || len(cs[0].Envs) != 2 || cs[0].Envs[0] != "b" {
		t.Fatalf("conflicts: %+v", cs)
	}
}

func TestExpiredEnvironmentSkippedOffline(t *testing.T) {
	f := newFixture(t)
	s := f.sync(t, 0, map[string]map[string]string{"e": {"K": "v"}})
	s.Environments[0].ExpiresAt = 1000
	Apply(f.cache, s, 0, hc.B64(f.root.Pub), f.dev.ID)
	acts := []string{"e"}
	if got, _ := Merge(f.cache, f.dev, acts, nil, 999); got["K"] != "v" {
		t.Error("should be valid before expiry")
	}
	if got, skipped := Merge(f.cache, f.dev, acts, nil, 1000); len(got) != 0 || len(skipped) != 1 {
		t.Error("should be skipped after expiry")
	}
}

func TestForgedEnvelopeRejected(t *testing.T) {
	f := newFixture(t)
	s := f.sync(t, 0, map[string]map[string]string{"e": {}})
	other := hc.SignKeyFromSeed(hc.Random(32))
	if err := Apply(f.cache, s, 0, hc.B64(other.Pub), f.dev.ID); err == nil {
		t.Fatal("envelope signed by a different root must be rejected")
	}
}

func TestKnownIncludesAllEnvironmentsAndOverrides(t *testing.T) {
	f := newFixture(t)
	s := f.sync(t, 0, map[string]map[string]string{
		"low":  {"A": "low-a", "B": "low-b"},
		"high": {"A": "high-a"},
	})
	if err := Apply(f.cache, s, 0, hc.B64(f.root.Pub), f.dev.ID); err != nil {
		t.Fatal(err)
	}
	got := Known(f.cache, f.dev, state.Overrides{"low": {"B": "local-b"}})
	if !got["A"]["low-a"] || !got["A"]["high-a"] || !got["B"]["low-b"] || !got["B"]["local-b"] || len(got) != 2 {
		t.Fatalf("应包含每个环境的值和本机覆盖值：%v", got)
	}
}

// --env 的各项可以是整个环境（名称或 ID），也可以是“环境:变量名”；按列出的顺序合并，靠前的优先。
func TestSelectPicks(t *testing.T) {
	f := newFixture(t)
	s := f.sync(t, 0, map[string]map[string]string{
		"env-a": {"A": "a-a", "SHARED": "a-shared"},
		"env-b": {"B": "b-b"},
		"env-c": {"API_KEY": "c-key", "DB_URL": "c-db", "SHARED": "c-shared", "OTHER": "c-other"},
	})
	if err := Apply(f.cache, s, 0, hc.B64(f.root.Pub), f.dev.ID); err != nil {
		t.Fatal(err)
	}
	// 名称与 ID 不同，确认两种写法都能用；名称里带冒号时整串优先当作环境。
	for i := range f.cache.Environments {
		switch f.cache.Environments[i].ID {
		case "env-a":
			f.cache.Environments[i].Name = "开发"
		case "env-c":
			f.cache.Environments[i].Name = "生产"
		case "env-b":
			f.cache.Environments[i].Name = "测试:旧"
		}
	}
	parse := func(items ...string) []Pick {
		t.Helper()
		var out []Pick
		for _, item := range items {
			p, err := ParsePick(f.cache, item)
			if err != nil {
				t.Fatalf("%s：%v", item, err)
			}
			out = append(out, p)
		}
		return out
	}
	check := func(got, want map[string]string) {
		t.Helper()
		if len(got) != len(want) {
			t.Fatalf("got %v want %v", got, want)
		}
		for k, v := range want {
			if got[k] != v {
				t.Errorf("%s: got %q want %q", k, got[k], v)
			}
		}
	}

	if p := parse("测试:旧")[0]; p.EnvID != "env-b" || p.Var != "" {
		t.Fatalf("名称带冒号的环境应整个选中：%+v", p)
	}
	got, _, err := Select(f.cache, f.dev, parse("开发", "测试:旧", "生产:API_KEY", "env-c:DB_URL", "env-c:SHARED"), state.Overrides{"env-c": {"API_KEY": "local"}}, 0)
	if err != nil {
		t.Fatal(err)
	}
	check(got, map[string]string{"A": "a-a", "SHARED": "a-shared", "B": "b-b", "API_KEY": "local", "DB_URL": "c-db"})

	// 指定的变量写在前面时优先于整个环境里的同名变量。
	got, _, err = Select(f.cache, f.dev, parse("生产:SHARED", "开发"), nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	check(got, map[string]string{"SHARED": "c-shared", "A": "a-a"})

	if _, _, err := Select(f.cache, f.dev, parse("生产:MISSING"), nil, 0); err == nil || !strings.Contains(err.Error(), "var list --env 生产") {
		t.Fatalf("变量不存在时应报错并提示查看：%v", err)
	}
	for _, bad := range []string{"生产:", "没有:API_KEY", "没有"} {
		if _, err := ParsePick(f.cache, bad); err == nil {
			t.Errorf("%s 应该报错", bad)
		}
	}

	// 指定的变量不在这个环境里、但在别的环境里时，指出在哪里。
	if _, _, err := Select(f.cache, f.dev, parse("开发:API_KEY"), nil, 0); err == nil || !strings.Contains(err.Error(), "--env 生产:API_KEY") {
		t.Fatalf("应指出其他环境里有这个变量：%v", err)
	}
	if _, err := ParsePick(f.cache, "没有"); err == nil || !strings.Contains(err.Error(), "“开发”") || !strings.Contains(err.Error(), "授权") {
		t.Fatalf("找不到环境时应列出能访问的环境并说明授权：%v", err)
	}

	// 明确指定的环境授权已到期时报错，不悄悄跳过（不论是整个环境还是其中的变量）。
	for i := range f.cache.Environments {
		if f.cache.Environments[i].ID == "env-c" {
			f.cache.Environments[i].ExpiresAt = 1
		}
	}
	for _, items := range [][]string{{"生产:API_KEY", "开发"}, {"开发", "生产"}} {
		if _, _, err := Select(f.cache, f.dev, parse(items...), nil, 10); err == nil || !strings.Contains(err.Error(), "到期") {
			t.Fatalf("%v：应报授权到期：%v", items, err)
		}
	}
}

// 解不开的变量只影响它自己：不指定时跳过并说明，其余照常；明确指定时报错。
func TestBrokenVariableOnlyAffectsItself(t *testing.T) {
	f := newFixture(t)
	s := f.sync(t, 0, map[string]map[string]string{"e": {"GOOD": "ok"}},
		api.Variable{EnvID: "e", Name: "BAD", Value: hc.B64(hc.Random(60)), KeyVersion: "1"})
	if err := Apply(f.cache, s, 0, hc.B64(f.root.Pub), f.dev.ID); err != nil {
		t.Fatal(err)
	}
	got, skipped := Merge(f.cache, f.dev, []string{"e"}, nil, 0)
	if got["GOOD"] != "ok" || len(got) != 1 || len(skipped) != 1 || !strings.Contains(skipped[0], "BAD") {
		t.Fatalf("got %v skipped %v", got, skipped)
	}
	if _, _, err := Select(f.cache, f.dev, []Pick{{EnvID: "e", Var: "GOOD"}}, nil, 0); err != nil {
		t.Fatalf("只取能解开的变量不应报错：%v", err)
	}
	for _, p := range []Pick{{EnvID: "e"}, {EnvID: "e", Var: "BAD"}} {
		if _, _, err := Select(f.cache, f.dev, []Pick{p}, nil, 0); err == nil || !strings.Contains(err.Error(), "var rm") {
			t.Fatalf("%+v：应报无法解密并给出处理办法：%v", p, err)
		}
	}
}
