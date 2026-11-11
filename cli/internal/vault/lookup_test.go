package vault

import (
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

func TestFindEnvironmentByIDAndName(t *testing.T) {
	c := &state.Cache{Environments: []api.Environment{
		{ID: "other", Name: "EnvID"},
		{ID: "EnvID", Name: "Production"},
	}}
	for input, wantID := range map[string]string{
		"EnvID": "EnvID", "production": "EnvID", " PRODUCTION ": "EnvID", "envid": "other",
	} {
		env, err := Find(c, input)
		if err != nil || env.ID != wantID {
			t.Fatalf("%q 应选择 %s：%+v %v", input, wantID, env, err)
		}
	}
	c.Environments = c.Environments[1:]
	c.Environments[0].Name = "已改名"
	if env, err := Find(c, "EnvID"); err != nil || env.Name != "已改名" {
		t.Fatalf("改名后 ID 仍应有效：%+v %v", env, err)
	}
	for _, missing := range []string{"envid", "Production", "Env"} {
		if _, err := Find(c, missing); err == nil {
			t.Errorf("不应匹配 ID 大小写变体、旧名称或不完整 ID：%s", missing)
		}
	}
}

func TestFindVaultByIDAndName(t *testing.T) {
	c := &state.Cache{VaultNames: []api.VaultName{
		{ID: "other", Name: "VaultID"},
		{ID: "VaultID", Name: "Shared"},
		{ID: "duplicate", Name: "Shared"},
	}}
	if v, err := FindVault(c, " VaultID "); err != nil || v.ID != "VaultID" {
		t.Fatalf("完整 ID 应先于名称匹配：%+v %v", v, err)
	}
	if _, err := FindVault(c, "shared"); err == nil {
		t.Fatal("变量库同名时应要求使用 ID")
	}
	c.VaultNames = c.VaultNames[1:2]
	if v, err := FindVault(c, "SHARED"); err != nil || v.ID != "VaultID" {
		t.Fatalf("名称应不区分大小写：%+v %v", v, err)
	}
	if v, err := FindVault(c, "vaultid"); err != nil || v != nil {
		t.Fatalf("ID 应区分大小写：%+v %v", v, err)
	}
}
