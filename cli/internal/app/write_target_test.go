package app

import (
	"context"
	"strings"
	"testing"
)

func TestWriteAndDeleteWithSameEnvironmentAndVaultID(t *testing.T) {
	_, fs := fakeDevice(t, "电脑")
	fs.envs[0].ID, fs.envs[0].Name = "E", "共享"
	fs.rename = map[string]string{"A": "ALIAS"}
	a, err := Load(true)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	set := func(name string, vaultOnly bool, change VarChange) VarResult {
		t.Helper()
		res, err := a.SetVariables(ctx, "E", vaultOnly, map[string]VarChange{name: change}, false)
		if err != nil || len(res) != 1 {
			t.Fatalf("写入失败：%+v %v", res, err)
		}
		return res[0]
	}
	value, note := "从环境修改", "从环境改备注"
	if r := set("ALIAS", false, VarChange{Value: &value}); r.Status != Written {
		t.Fatalf("通过环境 ID 应能修改别名变量：%+v", r)
	}
	if r := set("ALIAS", false, VarChange{Note: &note}); r.Status != Written {
		t.Fatalf("通过环境 ID 应能只修改备注：%+v", r)
	}
	if got := fs.entry(t, "A"); got.Value != value || got.Note != note {
		t.Fatalf("应更新原变量并保留其值：%+v", got)
	}
	value = "从变量库修改"
	if r := set("A", false, VarChange{Value: &value}); r.Status != Failed {
		t.Fatalf("默认环境目标不能用原名绕过环境别名：%+v", r)
	}
	if r := set("A", true, VarChange{Value: &value}); r.Status != Written {
		t.Fatalf("显式变量库目标应能按原名修改：%+v", r)
	}
	if notice := a.WriteNotice("E", "A", true, true); !strings.Contains(notice, "删除变量库“共享”里的 A") {
		t.Fatalf("删除提示必须定位到显式变量库：%q", notice)
	}
	if err := a.DeleteVariable(ctx, "E", "A", false); err == nil {
		t.Fatal("默认环境目标删除时不能退回变量库原名")
	}
	if got := fs.entry(t, "A"); got.Value != value {
		t.Fatalf("失败的环境删除不应影响原变量：%+v", got)
	}
	if err := a.DeleteVariable(ctx, "E", "A", true); err != nil {
		t.Fatal(err)
	}
	if _, ok := fs.vars["A"]; ok {
		t.Fatal("显式变量库删除应删除原变量")
	}
}
