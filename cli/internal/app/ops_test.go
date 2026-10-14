package app

import (
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// 授权被撤销后环境已不在缓存里，留下的覆盖值仍能按环境 ID 移除，但不能再设置。
func TestRemoveOverrideOfInaccessibleEnvironment(t *testing.T) {
	t.Setenv("HARMONIA_HOME", t.TempDir())
	d, err := state.Open()
	if err != nil {
		t.Fatal(err)
	}
	if err := d.SaveOverrides(state.Overrides{"env-gone": {"A": "1", "B": "2"}}); err != nil {
		t.Fatal(err)
	}
	a := &App{Dir: d}
	if _, err := a.SetOverride("env-gone", "A", nil); err != nil {
		t.Fatalf("移除失败：%v", err)
	}
	value := "3"
	if _, err := a.SetOverride("env-gone", "B", &value); err == nil {
		t.Fatal("不应该能给无法访问的环境设置覆盖值")
	}
	if _, err := a.SetOverride("env-gone", "MISSING", nil); err == nil {
		t.Fatal("没有这个覆盖值时应该报错")
	}
	ov, err := d.Overrides()
	if err != nil {
		t.Fatal(err)
	}
	if len(ov["env-gone"]) != 1 || ov["env-gone"]["B"] != "2" {
		t.Fatalf("覆盖值不对：%v", ov)
	}
	if _, err := a.SetOverride("env-gone", "B", nil); err != nil {
		t.Fatal(err)
	}
	if ov, _ = d.Overrides(); len(ov) != 0 {
		t.Fatalf("最后一个覆盖值移除后应该不留空记录：%v", ov)
	}
}
