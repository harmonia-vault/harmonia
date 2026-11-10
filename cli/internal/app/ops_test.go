package app

import (
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// 授权被撤销或环境被删除后，同步时删除它留下的覆盖值；仍能访问的环境（包括授权到期的）保留（设计文档 19.2）。
func TestPruneOverridesOfInaccessibleEnvironments(t *testing.T) {
	t.Setenv("HARMONIA_HOME", t.TempDir())
	d, err := state.Open()
	if err != nil {
		t.Fatal(err)
	}
	if err := d.SaveOverrides(state.Overrides{"env-gone": {"A": "1"}, "env-kept": {"B": "2"}}); err != nil {
		t.Fatal(err)
	}
	a := &App{Dir: d}
	cache := &state.Cache{Environments: []api.Environment{{ID: "env-kept", Name: "开发", ExpiresAt: 1}}}
	if err := a.pruneOverridesLocked(cache); err != nil {
		t.Fatal(err)
	}
	ov, err := d.Overrides()
	if err != nil {
		t.Fatal(err)
	}
	if len(ov) != 1 || ov["env-kept"]["B"] != "2" {
		t.Fatalf("覆盖值不对：%v", ov)
	}
	if err := d.SaveCache(cache); err != nil {
		t.Fatal(err)
	}
	if _, err := a.SetOverride("env-gone", "A", nil); err == nil {
		t.Fatal("不应该再能按环境 ID 指定环境")
	}
}
