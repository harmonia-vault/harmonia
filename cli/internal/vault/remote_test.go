package vault

import (
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// approvalFixture：local 可以在本机解密；remote 没有开启本机解密，引用变量库 shared（TOKEN 改名为 LLM_TOKEN）。
func approvalFixture(t *testing.T) *fixture {
	f := newFixture(t)
	s := f.sync(t, 0, map[string]map[string]string{"local": {"A": "local-a", "K": "local-k"}})
	s.Environments[0].Position = 1
	s.Environments[0].Active = true
	s.Environments = append(s.Environments, api.Environment{
		ID: "remote", Name: "远程", Role: "rw", Active: true, Position: 0, CreateVaults: []string{"shared"},
		Items: []api.EnvItem{
			{Name: "LLM_TOKEN", VaultID: "shared", Source: "TOKEN"},
			{Name: "K", VaultID: "shared", Source: "K"},
			{Name: "RO", VaultID: "shared", Source: "RO"},
		},
	})
	s.VaultNames = append(s.VaultNames, api.VaultName{ID: "shared", Name: "共享"})
	if err := Apply(f.cache, s, 0, hc.B64(f.root.Pub), f.dev.ID); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestNeededAndRemoteMerge(t *testing.T) {
	f := approvalFixture(t)
	ov := state.Overrides{"remote": {"RO": "local-ro"}}
	ids := ActiveIDs(f.cache)
	items := Needed(f.cache, EnvPicks(ids), ov, 0)
	if len(items) != 2 || items[0].Name != "LLM_TOKEN" || items[1].Name != "K" {
		t.Fatalf("有本机覆盖值的变量不请求：%+v", items)
	}
	if got := Needed(f.cache, []Pick{{EnvID: "remote", Var: "K"}, {EnvID: "local"}}, nil, 0); len(got) != 1 || got[0].Name != "K" {
		t.Fatalf("只取一个变量时只请求它：%+v", got)
	}
	// 没有批准结果时跳过这个环境并说明原因；有结果时远程环境排在前面，提供同名变量。
	vars, skipped := Merge(f.cache, f.dev, ids, ov, nil, 0)
	if len(skipped) != 1 || vars["K"] != "local-k" {
		t.Fatalf("%v %v", vars, skipped)
	}
	remote := Remote{"remote": {"LLM_TOKEN": "tok", "K": "remote-k"}}
	vars, skipped = Merge(f.cache, f.dev, ids, ov, remote, 0)
	if len(skipped) != 0 || vars["K"] != "remote-k" || vars["LLM_TOKEN"] != "tok" || vars["RO"] != "local-ro" || vars["A"] != "local-a" {
		t.Fatalf("%v %v", vars, skipped)
	}
	got, _, err := Select(f.cache, f.dev, []Pick{{EnvID: "remote", Var: "LLM_TOKEN"}}, nil, remote, 0)
	if err != nil || len(got) != 1 || got["LLM_TOKEN"] != "tok" {
		t.Fatalf("%v %v", got, err)
	}
	// 到期的环境不请求。
	f.cache.Environments[1].ExpiresAt = 5
	if got := Needed(f.cache, EnvPicks(ids), nil, 10); len(got) != 0 {
		t.Fatalf("%+v", got)
	}
	// 冲突只看变量名，远程环境也算。
	f.cache.Environments[1].ExpiresAt = 0
	if cs := Conflicts(f.cache, ids, 0); len(cs) != 1 || cs[0].Name != "K" || cs[0].Envs[0] != "远程" {
		t.Fatalf("%+v", cs)
	}
}

func TestRemoteWriteDest(t *testing.T) {
	f := approvalFixture(t)
	env, _ := ResolveTarget(f.cache, "远程", false)
	d, err := WriteDest(f.cache, env, "LLM_TOKEN", 0)
	if err != nil || !d.Remote() || d.ApprovalItem() != (api.ApprovalItem{EnvironmentID: "remote", Name: "LLM_TOKEN"}) || d.Source != "TOKEN" {
		t.Fatalf("%+v %v", d, err)
	}
	if d, err := WriteDest(f.cache, env, "RO", 0); err != nil || d.Source != "RO" {
		t.Fatalf("读写授权能改环境里的任何变量：%+v %v", d, err)
	}
	if _, err := WriteDest(f.cache, env, "MISSING", 0); err == nil {
		t.Fatal("环境里没有的变量不能通过环境写")
	}
	vault, _ := ResolveTarget(f.cache, "共享", false)
	d, err = WriteDest(f.cache, vault, "TOKEN", 0)
	if err != nil || d.Name != "LLM_TOKEN" {
		t.Fatalf("写变量库时用原名，批准请求里用环境里的名字：%+v %v", d, err)
	}
	d, err = WriteDest(f.cache, vault, "NEW_ONE", 0)
	if err != nil || d.ApprovalItem() != (api.ApprovalItem{EnvironmentID: "remote", Name: "NEW_ONE", VaultID: "shared"}) {
		t.Fatalf("新增变量带变量库：%+v %v", d, err)
	}
}
