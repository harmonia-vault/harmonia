package skill

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestRenderFillsVersion(t *testing.T) {
	out := string(Render("1.2.3"))
	if !strings.HasPrefix(out, "---\nname: harmonia\ndescription: ") {
		t.Fatalf("缺少技能头部：%q", out[:min(len(out), 60)])
	}
	if !strings.Contains(out, "本说明对应 harmonia 1.2.3。") {
		t.Fatal("没有写入版本号")
	}
	if strings.Contains(out, "{{") {
		t.Fatal("还有未替换的占位符")
	}
}

func TestTargets(t *testing.T) {
	home := t.TempDir()
	if got := Targets(home, nil); len(got) != 0 {
		t.Fatalf("没有 AI 工具目录时不应写入：%v", got)
	}
	if err := os.Mkdir(filepath.Join(home, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	claude := filepath.Join(home, ".claude", "skills", "harmonia", "SKILL.md")
	custom := filepath.Join(home, "my", "harmonia", "SKILL.md")
	got := Targets(home, []string{claude, custom})
	if !slices.Equal(got, []string{claude, custom}) {
		t.Fatalf("应写入已有的工具目录和保存过的位置，且不重复：%v", got)
	}
	if err := os.Mkdir(filepath.Join(home, ".agents"), 0o755); err != nil {
		t.Fatal(err)
	}
	agents := filepath.Join(home, ".agents", "skills", "harmonia", "SKILL.md")
	if got := Targets(home, nil); !slices.Equal(got, []string{claude, agents}) {
		t.Fatalf("两个工具目录都存在时都要写入：%v", got)
	}
}

func TestWriteAndRemove(t *testing.T) {
	base := t.TempDir()
	path := File(filepath.Join(base, "skills"))
	if err := Write(path, []byte("v1")); err != nil {
		t.Fatal(err)
	}
	if err := Write(path, []byte("v2")); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); string(data) != "v2" {
		t.Fatalf("应覆盖为新内容：%q", data)
	}
	if err := Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Dir(path)); !os.IsNotExist(err) {
		t.Fatal("空的 harmonia 目录应一并删除")
	}
	if _, err := os.Stat(filepath.Join(base, "skills")); err != nil {
		t.Fatal("不应删除技能目录本身")
	}
	if err := Remove(path); err != nil {
		t.Fatalf("文件已不存在时不应报错：%v", err)
	}

	// 用户在 harmonia 目录里放了别的文件时保留目录。
	if err := Write(path, []byte("v1")); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(filepath.Dir(path), "notes.md")
	if err := os.WriteFile(other, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(other); err != nil {
		t.Fatal("目录里还有其他文件时不应删除")
	}
}

func TestStub(t *testing.T) {
	stub, full := string(Stub()), string(Render("1.2.3"))
	header := full[:strings.Index(full, "\n---\n")+len("\n---\n")]
	if !strings.HasPrefix(stub, header) {
		t.Fatalf("入口文件的头部应与完整说明相同：%q", stub[:min(len(stub), 80)])
	}
	if !strings.Contains(stub, "harmonia skill") || strings.Contains(stub, "{{") {
		t.Fatal("入口文件应让 AI 助手运行 harmonia skill，且不含占位符")
	}
	if strings.Contains(stub, "1.2.3") || strings.Count(stub, "\n---\n") != 1 {
		t.Fatal("入口文件不应带版本号，也不应带上完整说明的正文")
	}
	if strings.Contains(stub, "\r") {
		t.Fatal("应统一为 LF 换行")
	}
}
