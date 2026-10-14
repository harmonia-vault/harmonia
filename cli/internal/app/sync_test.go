package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// fakeDevice 造一台已接入的设备和模拟服务器；puts 收集写入的变量密文。
func fakeDevice(t *testing.T, name string) (*state.Dir, *state.DeviceKeys, map[string]string) {
	t.Helper()
	t.Setenv("HARMONIA_HOME", t.TempDir())
	keys := state.NewDeviceKeys()
	keys.ID = hc.NewID()
	puts := map[string]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/v1/auth/challenge":
			w.Write([]byte(`{"nonce":"n"}`))
		case r.URL.Path == "/api/v1/auth/device-session":
			w.Write([]byte(`{"token":"t","expiresAt":4102444800000}`))
		case r.URL.Path == "/api/v1/sync":
			json.NewEncoder(w).Encode(map[string]any{
				"seq":  3,
				"self": map[string]any{"id": keys.ID, "kind": "client", "name": name},
			})
		case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/api/v1/environments/"):
			var body struct{ Value string }
			json.NewDecoder(r.Body).Decode(&body)
			puts[r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]] = body.Value
			w.Write([]byte(`{"seq":2}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	d, err := state.Open()
	if err != nil {
		t.Fatal(err)
	}
	if err := d.SaveConfig(&state.Config{Server: srv.URL, AccountID: hc.NewID(), DeviceID: keys.ID, DeviceName: "旧名字"}); err != nil {
		t.Fatal(err)
	}
	if err := d.SaveKeys(keys.Saved()); err != nil {
		t.Fatal(err)
	}
	return d, keys, puts
}

// 只改值时保留原来的备注，只改备注时保留原来的值；不存在的变量不能只给备注。
func TestSetVariablesKeepsTheOtherPart(t *testing.T) {
	d, keys, puts := fakeDevice(t, "电脑")
	envKey := hc.Random(32)
	sealed, _ := hc.Seal(envKey, keys.Box.Pub[:])
	ct, _ := hc.EncryptVar(envKey, "E", 1, "A", hc.Entry{Value: "旧值", Note: "旧备注"})
	cache := &state.Cache{
		Environments: []api.Environment{{ID: "E", Name: "dev", KeyVersion: "1", Role: "rw", Active: true}},
		Envelopes:    []api.Envelope{{EnvID: "E", KeyVersion: "1", Sealed: hc.B64(sealed)}},
		Variables:    map[string]map[string]state.CachedVar{"E": {"A": {Value: ct, KeyVersion: 1}}},
	}
	if err := d.SaveCache(cache); err != nil {
		t.Fatal(err)
	}
	a, err := Load(true)
	if err != nil {
		t.Fatal(err)
	}
	value, note := "新值", "  新备注\n第二行  "
	if err := a.SetVariables(context.Background(), "dev", map[string]VarChange{"A": {Value: &value}}); err != nil {
		t.Fatal(err)
	}
	if e, err := hc.DecryptVar(envKey, "E", 1, "A", puts["A"]); err != nil || e.Value != "新值" || e.Note != "旧备注" {
		t.Fatalf("只改值：%+v %v", e, err)
	}
	if err := d.SaveCache(cache); err != nil {
		t.Fatal(err)
	}
	if err := a.SetVariables(context.Background(), "dev", map[string]VarChange{"A": {Note: &note}}); err != nil {
		t.Fatal(err)
	}
	if e, err := hc.DecryptVar(envKey, "E", 1, "A", puts["A"]); err != nil || e.Value != "旧值" || e.Note != "新备注\n第二行" {
		t.Fatalf("只改备注：%+v %v", e, err)
	}
	if err := a.SetVariables(context.Background(), "dev", map[string]VarChange{"B": {Note: &note}}); err == nil {
		t.Fatal("不存在的变量只给备注应当报错")
	}
	long := strings.Repeat("字", MaxNoteLen+1)
	if err := a.SetVariables(context.Background(), "dev", map[string]VarChange{"A": {Note: &long}}); err == nil {
		t.Fatal("备注超长应当报错")
	}
}

// 设备名在手机上改过之后，同步要把本机记录的设备名一起更新。
func TestSyncPicksUpNewDeviceName(t *testing.T) {
	d, _, _ := fakeDevice(t, "新名字")
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
