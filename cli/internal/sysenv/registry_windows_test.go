package sysenv

import (
	"fmt"
	"os"
	"testing"

	"golang.org/x/sys/windows/registry"
)

// 在测试专用的注册表位置上核对读写与类型，不碰真正的用户环境变量。
func TestRegistryStore(t *testing.T) {
	path := fmt.Sprintf(`Software\HarmoniaTest\%d`, os.Getpid())
	t.Cleanup(func() { registry.DeleteKey(registry.CURRENT_USER, path) })
	st := Registry{Path: path}

	if _, _, ok, err := st.Get("MISSING"); ok || err != nil {
		t.Fatalf("不存在的变量：ok=%v err=%v", ok, err)
	}
	value := "a%USERNAME%b 中文\n第二行 \"引号\""
	if err := st.Set("Mixed_Case", value, KindString); err != nil {
		t.Fatal(err)
	}
	got, kind, ok, err := st.Get("MIXED_CASE")
	if err != nil || !ok || got != value || kind != KindString {
		t.Fatalf("读回：%q kind=%d ok=%v err=%v", got, kind, ok, err)
	}
	if err := st.Set("EXPAND", `%USERPROFILE%\bin`, KindExpand); err != nil {
		t.Fatal(err)
	}
	if got, kind, _, _ := st.Get("EXPAND"); got != `%USERPROFILE%\bin` || kind != KindExpand {
		t.Fatalf("可展开的字符串应当原样读回：%q kind=%d", got, kind)
	}

	k, _, err := registry.CreateKey(registry.CURRENT_USER, path, registry.SET_VALUE)
	if err != nil {
		t.Fatal(err)
	}
	k.SetDWordValue("NUMBER", 1)
	k.Close()
	if _, _, _, err := st.Get("NUMBER"); err != ErrNotString {
		t.Fatalf("不是字符串类型的值：%v", err)
	}

	rec := &Record{}
	if _, err := Apply(st, rec, map[string]string{"Mixed_Case": "h", "NEW": "n"}, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	if _, err := Apply(st, rec, nil, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	if got, _, _, _ := st.Get("Mixed_Case"); got != value {
		t.Fatalf("恢复后：%q", got)
	}
	if _, _, ok, _ := st.Get("NEW"); ok {
		t.Fatal("原来没有的变量恢复后应当被删除")
	}
	if err := st.Delete("MISSING"); err != nil {
		t.Fatalf("删除不存在的变量不应报错：%v", err)
	}
}
