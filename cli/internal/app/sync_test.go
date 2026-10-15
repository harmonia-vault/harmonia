package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// vaultServer 是一个有状态的模拟服务器：一个环境 E（名称 dev），按批量写入接口保存变量，同步时全部返回。
type vaultServer struct {
	mu      sync.Mutex
	name    string
	envs    []api.Environment
	envKey  []byte
	sealed  api.Envelope
	vars    map[string]string // 变量名 → 密文
	seq     int64
	batches int
	// tamper 不为 nil 时，批量写入后由它改写保存的密文（模拟别的设备同时修改）。
	tamper func(name, ct string) string
}

func (s *vaultServer) handler(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case r.URL.Path == "/api/v1/auth/challenge":
		w.Write([]byte(`{"nonce":"n"}`))
	case r.URL.Path == "/api/v1/auth/device-session":
		w.Write([]byte(`{"token":"t","expiresAt":4102444800000}`))
	case r.URL.Path == "/api/v1/sync":
		vars := []api.Variable{}
		for n, v := range s.vars {
			vars = append(vars, api.Variable{EnvID: "E", Name: n, Value: v, KeyVersion: "1"})
		}
		envelopes := []api.Envelope{}
		if len(s.envs) > 0 {
			envelopes = append(envelopes, s.sealed)
		}
		json.NewEncoder(w).Encode(map[string]any{
			"seq":          s.seq,
			"self":         map[string]any{"id": "D", "kind": "client", "name": s.name},
			"environments": s.envs, "envelopes": envelopes, "variables": vars,
		})
	case r.Method == "PATCH" && r.URL.Path == "/api/v1/environments/E/variables":
		var body struct {
			Set    []api.VarWrite
			Delete []string
		}
		json.NewDecoder(r.Body).Decode(&body)
		s.batches++
		s.seq++
		for _, v := range body.Set {
			if s.tamper != nil {
				v.Value = s.tamper(v.Name, v.Value)
			}
			s.vars[v.Name] = v.Value
		}
		for _, n := range body.Delete {
			delete(s.vars, n)
		}
		w.Write([]byte(`{"seq":1}`))
	default:
		http.NotFound(w, r)
	}
}

// fakeDevice 造一台已接入的设备和模拟服务器；服务器上已有环境 dev，其中 A=旧值（备注“旧备注”）。
func fakeDevice(t *testing.T, name string) (*state.Dir, *vaultServer) {
	t.Helper()
	t.Setenv("HARMONIA_HOME", t.TempDir())
	keys := state.NewDeviceKeys()
	keys.ID = "D"
	root := hc.SignKeyFromSeed(hc.Random(32))
	envKey := hc.Random(32)
	sealed, _ := hc.Seal(envKey, keys.Box.Pub[:])
	ct, _ := hc.EncryptVar(envKey, "E", 1, "A", hc.Entry{Value: "旧值", Note: "旧备注"})
	fs := &vaultServer{
		name:   name,
		envs:   []api.Environment{{ID: "E", Name: "dev", KeyVersion: "1", Role: "rw", Active: true}},
		envKey: envKey,
		sealed: api.Envelope{EnvID: "E", KeyVersion: "1", Sealed: hc.B64(sealed), Sig: hc.B64(root.Sign(hc.EnvelopeMsg("E", 1, "D", sealed)))},
		vars:   map[string]string{"A": ct},
		seq:    1,
	}
	srv := httptest.NewServer(http.HandlerFunc(fs.handler))
	t.Cleanup(srv.Close)
	d, err := state.Open()
	if err != nil {
		t.Fatal(err)
	}
	cfg := &state.Config{Server: srv.URL, AccountID: hc.NewID(), RootPub: hc.B64(root.Pub), DeviceID: keys.ID, DeviceName: "旧名字"}
	if err := d.SaveConfig(cfg); err != nil {
		t.Fatal(err)
	}
	if err := d.SaveKeys(keys.Saved()); err != nil {
		t.Fatal(err)
	}
	return d, fs
}

func (s *vaultServer) entry(t *testing.T, name string) hc.Entry {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	e, err := hc.DecryptVar(s.envKey, "E", 1, name, s.vars[name])
	if err != nil {
		t.Fatalf("解不开 %s：%v", name, err)
	}
	return e
}

func set1(t *testing.T, a *App, name string, ch VarChange) VarResult {
	t.Helper()
	res, err := a.SetVariables(context.Background(), "dev", map[string]VarChange{name: ch}, false)
	if err != nil {
		t.Fatal(err)
	}
	return res[0]
}

// 只改值时保留原来的备注，只改备注时保留原来的值；不存在的变量不能只给备注。写入后回读校验。
func TestSetVariablesKeepsTheOtherPart(t *testing.T) {
	_, fs := fakeDevice(t, "电脑")
	a, err := Load(true)
	if err != nil {
		t.Fatal(err)
	}
	value, note := "新值", "  新备注\n第二行  "
	if r := set1(t, a, "A", VarChange{Value: &value}); r.Status != Written {
		t.Fatalf("只改值：%+v", r)
	}
	if e := fs.entry(t, "A"); e.Value != "新值" || e.Note != "旧备注" {
		t.Fatalf("只改值：%+v", e)
	}
	if r := set1(t, a, "A", VarChange{Note: &note}); r.Status != Written {
		t.Fatalf("只改备注：%+v", r)
	}
	if e := fs.entry(t, "A"); e.Value != "新值" || e.Note != "新备注\n第二行" {
		t.Fatalf("只改备注：%+v", e)
	}
	if r := set1(t, a, "B", VarChange{Note: &note}); r.Status != Failed {
		t.Fatal("不存在的变量只给备注应当失败")
	}
	long := strings.Repeat("字", MaxNoteLen+1)
	if r := set1(t, a, "A", VarChange{Note: &long}); r.Status != Failed {
		t.Fatal("备注超长应当失败")
	}
}

// 导入跳过没变的变量（重跑等于续传），其余一次批量写入；不合法的项单独失败，不影响其他项。
func TestImportSkipsUnchangedAndBatches(t *testing.T) {
	_, fs := fakeDevice(t, "电脑")
	a, err := Load(true)
	if err != nil {
		t.Fatal(err)
	}
	vals := map[string]string{"A": "旧值", "B": "b", "C": "c", "1BAD": "x"}
	changes := map[string]VarChange{}
	for n, v := range vals {
		changes[n] = VarChange{Value: &v}
	}
	res, err := a.SetVariables(context.Background(), "dev", changes, true)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, r := range res {
		got[r.Name] = r.Status
	}
	want := map[string]string{"1BAD": Failed, "A": Unchanged, "B": Written, "C": Written}
	if len(got) != len(want) {
		t.Fatalf("结果不对：%v", got)
	}
	for n, s := range want {
		if got[n] != s {
			t.Fatalf("%s 应为 %s：%v", n, s, got)
		}
	}
	if fs.batches != 1 {
		t.Fatalf("应当只调用一次批量写入：%d", fs.batches)
	}
	if e := fs.entry(t, "A"); e.Note != "旧备注" {
		t.Fatal("没变的变量不应被改写")
	}
	// 重跑：全部未变化，不再写入。
	delete(changes, "1BAD")
	res, err = a.SetVariables(context.Background(), "dev", changes, true)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range res {
		if r.Status != Unchanged {
			t.Fatalf("重跑时 %s 应为未变化：%+v", r.Name, r)
		}
	}
	if fs.batches != 1 {
		t.Fatalf("重跑不应写入：%d", fs.batches)
	}
}

// 回读的内容和写入的不一致（例如别的设备同时改了它）时报告失败。
func TestSetVariablesReadbackMismatch(t *testing.T) {
	_, fs := fakeDevice(t, "电脑")
	a, err := Load(true)
	if err != nil {
		t.Fatal(err)
	}
	fs.tamper = func(name, _ string) string {
		ct, _ := hc.EncryptVar(fs.envKey, "E", 1, name, hc.Entry{Value: "别人写的"})
		return ct
	}
	value := "我写的"
	r := set1(t, a, "A", VarChange{Value: &value})
	if r.Status != Failed || !strings.Contains(r.Err.Error(), "不一致") {
		t.Fatalf("应当发现回读不一致：%+v", r)
	}
}

// 写入后检查不带 --env 的 exec 是否真能拿到这个值。
func TestShadowing(t *testing.T) {
	d, _ := fakeDevice(t, "电脑")
	a, err := Load(true)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	cache, _ := d.Cache()
	cache.Environments = append([]api.Environment{{ID: "F", Name: "prod", Role: "rw", Active: true, Position: -1}}, cache.Environments...)
	cache.Variables["F"] = map[string]state.CachedVar{"A": {Value: "x", KeyVersion: 1}}
	d.SaveCache(cache)
	d.SaveOverrides(state.Overrides{"E": {"A": "本机"}})
	notes, err := a.Shadowing("dev", "A")
	if err != nil || len(notes) != 2 || !strings.Contains(notes[0], "覆盖") || !strings.Contains(notes[1], "prod") {
		t.Fatalf("提示不对：%q %v", notes, err)
	}
	cache.Environments[1].Active = false
	d.SaveCache(cache)
	if notes, _ := a.Shadowing("dev", "A"); len(notes) != 1 || !strings.Contains(notes[0], "没有启用") {
		t.Fatalf("环境未启用时应当提示：%q", notes)
	}
}

// 设备名在手机上改过之后，同步要把本机记录的设备名一起更新。
func TestSyncPicksUpNewDeviceName(t *testing.T) {
	d, _ := fakeDevice(t, "新名字")
	a, err := Load(true)
	if err != nil {
		t.Fatal(err)
	}
	if err := a.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	cfg, err := d.Config()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DeviceName != "新名字" || a.Config.DeviceName != "新名字" {
		t.Fatalf("设备名没有更新：%q / %q", cfg.DeviceName, a.Config.DeviceName)
	}
}
