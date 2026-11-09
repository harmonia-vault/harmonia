package approval

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// phone 模拟服务端和管理设备：核对请求签名，按 decide 返回结果。
type phone struct {
	t       *testing.T
	dev     *state.DeviceKeys
	root    hc.SignKey
	manager hc.BoxKey
	decide  func(id string, d api.ApprovalDetail, payload string) api.Event
	dropped bool
	status  api.Event
	id      string
	detail  string
}

func (p *phone) CreateApproval(_ context.Context, id, detail, payload, sig string) (int64, error) {
	s, _ := hc.UnB64(sig)
	if !hc.Verify(p.dev.Sign.Pub, hc.ApprovalRequestMsg(id, p.dev.ID, detail, payload), s) {
		p.t.Fatal("请求签名不对")
	}
	p.id, p.detail = id, detail
	var d api.ApprovalDetail
	if err := json.Unmarshal([]byte(detail), &d); err != nil {
		p.t.Fatal(err)
	}
	p.status = p.decide(id, d, payload)
	return 0, nil
}

func (p *phone) WaitApproval(_ context.Context, _ string, onReady func()) (api.Event, error) {
	onReady()
	if p.dropped {
		return api.Event{}, errors.New("连接断开")
	}
	return p.status, nil
}

func (p *phone) ApprovalStatus(context.Context, string) (api.Event, error) { return p.status, nil }

// grant 按协议 3.9 生成批准结果：加密给临时公钥、root 签名。
func (p *phone) grant(d api.ApprovalDetail, g Grant) api.Event {
	plain, _ := json.Marshal(g)
	eph, _ := hc.UnB64(d.EphPub)
	sealed, _ := hc.Seal(plain, eph)
	return api.Event{Type: "approved", Result: &api.ApprovalResult{
		Sealed: hc.B64(sealed),
		Sig:    hc.B64(p.root.Sign(hc.ApprovalGrantMsg(g.RequestID, sealed))),
	}}
}

func setup(t *testing.T) (*phone, *Requester, *bytes.Buffer) {
	dev := state.NewDeviceKeys()
	dev.ID = hc.NewID()
	p := &phone{t: t, dev: dev, root: hc.SignKeyFromSeed(hc.Random(32)), manager: hc.BoxKeyFromSeed(hc.Random(32))}
	out := &bytes.Buffer{}
	r := &Requester{Server: p, Keys: dev, RootPub: p.root.Pub, Command: []string{"npm", "run", strings.Repeat("x", 2000)},
		Cwd: "/home/me/blog", Out: out, Now: time.Now}
	return p, r, out
}

var items = []api.ApprovalItem{{EnvironmentID: "env", Name: "LLM_KEY"}, {EnvironmentID: "env", Name: "MODEL"}}

func values(id string) []Value {
	return []Value{
		{EnvironmentID: "env", Name: "LLM_KEY", VaultID: "v", Source: "OPENAI_API_KEY", Plain: Plain{Value: "sk-1"}},
		{EnvironmentID: "env", Name: "MODEL", VaultID: "v", Source: "MODEL", Plain: Plain{Value: "m"}},
	}
}

func TestReadApproved(t *testing.T) {
	p, r, out := setup(t)
	p.decide = func(id string, d api.ApprovalDetail, payload string) api.Event {
		if d.Kind != "read" || payload != "" || len([]rune(d.Command)) != maxShown || d.DeviceID != p.dev.ID {
			t.Fatalf("%+v", d)
		}
		return p.grant(d, Grant{RequestID: id, Scope: ScopeTerminal, ExpiresAt: 99, Values: values(id)})
	}
	g, err := r.Read(context.Background(), items)
	if err != nil || g.Scope != ScopeTerminal || g.Values[0].Plain.Value != "sk-1" {
		t.Fatalf("%+v %v", g, err)
	}
	if !strings.Contains(out.String(), "核对请求码 "+hc.ApprovalCode(p.detail)) {
		t.Fatal(out.String())
	}
}

func TestReadRejectsBadGrant(t *testing.T) {
	cases := map[string]func(p *phone, id string, d api.ApprovalDetail) api.Event{
		"不是 root 签名": func(p *phone, id string, d api.ApprovalDetail) api.Event {
			p.root = hc.SignKeyFromSeed(hc.Random(32))
			return p.grant(d, Grant{RequestID: id, Scope: ScopeOnce, Values: values(id)})
		},
		"请求 ID 不同": func(p *phone, id string, d api.ApprovalDetail) api.Event {
			return p.grant(d, Grant{RequestID: "other", Scope: ScopeOnce, Values: values(id)})
		},
		"多给了变量": func(p *phone, id string, d api.ApprovalDetail) api.Event {
			v := append(values(id), Value{EnvironmentID: "env", Name: "EXTRA"})
			return p.grant(d, Grant{RequestID: id, Scope: ScopeOnce, Values: v})
		},
		"少给了变量": func(p *phone, id string, d api.ApprovalDetail) api.Event {
			return p.grant(d, Grant{RequestID: id, Scope: ScopeOnce, Values: values(id)[:1]})
		},
		"范围不认识": func(p *phone, id string, d api.ApprovalDetail) api.Event {
			return p.grant(d, Grant{RequestID: id, Scope: "forever", Values: values(id)})
		},
	}
	for name, bad := range cases {
		p, r, _ := setup(t)
		p.decide = func(id string, d api.ApprovalDetail, _ string) api.Event { return bad(p, id, d) }
		if _, err := r.Read(context.Background(), items); !errors.Is(err, errBadGrant) {
			t.Errorf("%s：%v", name, err)
		}
	}
}

func TestReadOutcomes(t *testing.T) {
	for typ, want := range map[string]error{"rejected": ErrRejected, "expired": ErrExpired, "cancelled": ErrLost} {
		p, r, _ := setup(t)
		p.decide = func(string, api.ApprovalDetail, string) api.Event { return api.Event{Type: typ} }
		if _, err := r.Read(context.Background(), items); !errors.Is(err, want) {
			t.Errorf("%s：%v", typ, err)
		}
	}
	// 等待连接断开时再查一次状态，结果已经出来就照常使用。
	p, r, _ := setup(t)
	p.dropped = true
	p.decide = func(id string, d api.ApprovalDetail, _ string) api.Event {
		return p.grant(d, Grant{RequestID: id, Scope: ScopeOnce, Values: values(id)})
	}
	if _, err := r.Read(context.Background(), items); err != nil {
		t.Fatal(err)
	}
}

func TestWriteSealsForEachManager(t *testing.T) {
	p, r, out := setup(t)
	other := hc.BoxKeyFromSeed(hc.Random(32))
	managers := []api.ManagerKey{{ID: "m1", BoxPub: hc.B64(p.manager.Pub[:])}, {ID: "m2", BoxPub: hc.B64(other.Pub[:])}}
	set := []SetItem{{ApprovalItem: api.ApprovalItem{EnvironmentID: "env", Name: "NEW", VaultID: "v"}, Plain: map[string]string{"value": "x"}}}
	del := []api.ApprovalItem{{EnvironmentID: "env", Name: "OLD"}}
	p.decide = func(id string, d api.ApprovalDetail, payload string) api.Event {
		if d.Kind != "write" || d.EphPub != "" || len(d.Items) != 1 || d.Items[0].VaultID != "v" || d.Delete[0].Name != "OLD" {
			t.Fatalf("%+v", d)
		}
		var pl struct {
			Sealed []struct{ ManagerID, Sealed string }
		}
		if err := json.Unmarshal([]byte(payload), &pl); err != nil || len(pl.Sealed) != 2 {
			t.Fatalf("%s %v", payload, err)
		}
		for i, key := range []hc.BoxKey{p.manager, other} {
			sealed, _ := hc.UnB64(pl.Sealed[i].Sealed)
			plain, err := key.Open(sealed)
			var content struct {
				RequestID string
				Set       []SetItem
			}
			if err != nil || json.Unmarshal(plain, &content) != nil || content.RequestID != id || content.Set[0].Plain["value"] != "x" {
				t.Fatalf("管理设备 %d 解不开写入内容：%v", i, err)
			}
		}
		return api.Event{Type: "approved"}
	}
	if err := r.Write(context.Background(), managers, set, del); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "已请求手机批准写入") {
		t.Fatal(out.String())
	}
	if err := r.Write(context.Background(), nil, set, nil); err == nil {
		t.Fatal("没有管理设备时不能发起写入请求")
	}
}
