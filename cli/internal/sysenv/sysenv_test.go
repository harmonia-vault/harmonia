package sysenv

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

type entry struct {
	value string
	kind  uint32
}

// fake 模拟注册表：变量名不区分大小写，保留第一次写入时的写法。
type fake struct {
	values map[string]entry
	odd    map[string]bool // 不是字符串类型的值
	fail   string          // 写入这个名字时失败
}

func (f *fake) Get(name string) (string, uint32, bool, error) {
	if f.odd[strings.ToUpper(name)] {
		return "", 0, false, ErrNotString
	}
	e, ok := f.values[strings.ToUpper(name)]
	return e.value, e.kind, ok, nil
}

func (f *fake) Set(name, value string, kind uint32) error {
	if name == f.fail {
		return errors.New("写入失败")
	}
	f.values[strings.ToUpper(name)] = entry{value, kind}
	return nil
}

func (f *fake) Delete(name string) error {
	delete(f.values, strings.ToUpper(name))
	return nil
}

func newFake(pairs ...string) *fake {
	f := &fake{values: map[string]entry{}, odd: map[string]bool{}}
	for i := 0; i < len(pairs); i += 2 {
		f.values[strings.ToUpper(pairs[i])] = entry{pairs[i+1], KindString}
	}
	return f
}

func apply(t *testing.T, f *fake, rec *Record, want map[string]string) bool {
	t.Helper()
	changed, err := Apply(f, rec, want, func() error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	return changed
}

func TestApplyTakesOverAndRestores(t *testing.T) {
	f := newFake("EXISTING", "mine", "OTHER", "untouched")
	f.values["EXPAND"] = entry{`%USERPROFILE%\bin`, KindExpand}
	rec := &Record{}

	if !apply(t, f, rec, map[string]string{"EXISTING": "h1", "EXPAND": "h2", "NEW": "h3"}) {
		t.Fatal("第一次写入应当有变化")
	}
	want := map[string]entry{"EXISTING": {"h1", KindString}, "EXPAND": {"h2", KindString}, "NEW": {"h3", KindString}, "OTHER": {"untouched", KindString}}
	if !reflect.DeepEqual(f.values, want) {
		t.Fatalf("写入后：%v", f.values)
	}
	if apply(t, f, rec, map[string]string{"EXISTING": "h1", "EXPAND": "h2", "NEW": "h3"}) {
		t.Fatal("内容没有变化时不应报告变化")
	}

	// 值更新时原状不能被 Harmonia 自己写入的值盖掉。
	apply(t, f, rec, map[string]string{"EXISTING": "h1b", "EXPAND": "h2", "NEW": "h3"})
	if rec.Managed["EXISTING"] != (Original{Had: true, Value: "mine", Kind: KindString}) {
		t.Fatalf("原状被改动：%+v", rec.Managed["EXISTING"])
	}

	// 用户在托管期间手动修改，下一次写入时被覆盖。
	f.values["NEW"] = entry{"manual", KindString}
	if !apply(t, f, rec, map[string]string{"EXISTING": "h1b", "EXPAND": "h2", "NEW": "h3"}) || f.values["NEW"].value != "h3" {
		t.Fatal("手动修改应当被覆盖")
	}

	if !apply(t, f, rec, nil) {
		t.Fatal("恢复应当有变化")
	}
	restored := map[string]entry{"EXISTING": {"mine", KindString}, "EXPAND": {`%USERPROFILE%\bin`, KindExpand}, "OTHER": {"untouched", KindString}}
	if !reflect.DeepEqual(f.values, restored) {
		t.Fatalf("恢复后：%v", f.values)
	}
	if len(rec.Managed) != 0 {
		t.Fatalf("恢复后仍有托管记录：%v", rec.Managed)
	}
}

func TestApplyIgnoresCaseOfNames(t *testing.T) {
	f := newFake("Token", "mine")
	rec := &Record{}
	apply(t, f, rec, map[string]string{"TOKEN": "h"})
	// 改了大小写的同一个名字仍然是同一个托管变量，不能把 Harmonia 的值记成原状。
	apply(t, f, rec, map[string]string{"token": "h2"})
	if len(rec.Managed) != 1 || rec.Managed["TOKEN"].Value != "mine" {
		t.Fatalf("托管记录：%v", rec.Managed)
	}
	apply(t, f, rec, nil)
	if f.values["TOKEN"].value != "mine" {
		t.Fatalf("恢复后：%v", f.values)
	}
}

func TestApplySavesOriginalBeforeWriting(t *testing.T) {
	f := newFake("A", "mine")
	f.fail = "A"
	rec := &Record{}
	var saved []Original
	_, err := Apply(f, rec, map[string]string{"A": "h"}, func() error {
		saved = append(saved, rec.Managed["A"])
		return nil
	})
	if err == nil {
		t.Fatal("写入失败应当返回错误")
	}
	if len(saved) != 1 || saved[0].Value != "mine" {
		t.Fatalf("写入之前没有保存原状：%v", saved)
	}
	// 之后恢复不会丢掉原来的值。
	f.fail = ""
	apply(t, f, rec, nil)
	if f.values["A"].value != "mine" {
		t.Fatalf("恢复后：%v", f.values)
	}
}

func TestApplyLeavesNonStringValuesAlone(t *testing.T) {
	f := newFake()
	f.odd["ODD"] = true
	rec := &Record{}
	apply(t, f, rec, map[string]string{"ODD": "h", "OK": "v"})
	if _, ok := f.values["ODD"]; ok || len(rec.Managed) != 1 {
		t.Fatalf("不是字符串类型的值不应被接管：%v %v", f.values, rec.Managed)
	}
}

func TestSelect(t *testing.T) {
	vars := map[string]string{
		"OPENAI_API_KEY": "sk-1", "Path": "x", "TEMP": "y", "EMPTY": "",
		"Token": "a", "TOKEN": "b", "LONG": strings.Repeat("x", MaxValue+1), "MAX": strings.Repeat("好", MaxValue),
	}
	want, skipped := Select(vars, false)
	if !reflect.DeepEqual(sortedKeys(want), []string{"MAX", "OPENAI_API_KEY", "TOKEN"}) {
		t.Fatalf("可写入：%v", sortedKeys(want))
	}
	var names []string
	for _, s := range skipped {
		names = append(names, s.Name)
	}
	if !reflect.DeepEqual(names, []string{"EMPTY", "LONG", "Path", "TEMP", "Token"}) {
		t.Fatalf("跳过：%v", names)
	}
	want, _ = Select(vars, true)
	if want["Path"] != "x" || want["TEMP"] != "y" {
		t.Fatalf("开启“写入系统变量”后应当包含系统变量：%v", sortedKeys(want))
	}
}
