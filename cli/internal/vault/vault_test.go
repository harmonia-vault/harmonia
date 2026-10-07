package vault

import (
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
			ct, _ := hc.EncryptValue(key, id, 1, n, v)
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
