package state

import (
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func open(t *testing.T) *Dir {
	t.Helper()
	t.Setenv("HARMONIA_HOME", t.TempDir())
	d, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// 数据目录只允许本人、系统和管理员访问，并且不继承上级目录的权限。
func TestDirIsRestricted(t *testing.T) {
	d := open(t)
	sd, err := windows.GetNamedSecurityInfo(d.Path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	// 三项的先后由系统决定，只核对内容。
	got := sd.String()
	for _, who := range []string{"SY", "BA", user.User.Sid.String()} {
		if !strings.Contains(got, "(A;OICI;FA;;;"+who+")") {
			t.Fatalf("访问控制列表缺少 %s：%s", who, got)
		}
	}
	if !strings.HasPrefix(got, "D:PAI(") || strings.Count(got, "(") != 3 {
		t.Fatalf("访问控制列表应当不继承上级目录，并且只有三项：%s", got)
	}
	// 目录里新建的文件沿用同样的三项权限，没有别的。
	if err := WriteAtomic(d.File("keys.json"), []byte("{}")); err != nil {
		t.Fatal(err)
	}
	sd, err = windows.GetNamedSecurityInfo(d.File("keys.json"), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	if got := sd.String(); strings.Count(got, "(A;") != 3 || !strings.Contains(got, user.User.Sid.String()) {
		t.Fatalf("文件的访问控制列表：%s", got)
	}
}

func TestLockIsExclusive(t *testing.T) {
	d := open(t)
	unlock, err := d.Lock()
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan struct{})
	go func() {
		u, err := d.Lock()
		if err == nil {
			u()
		}
		close(got)
	}()
	select {
	case <-got:
		t.Fatal("第一把锁还没有释放，第二把就拿到了")
	case <-time.After(200 * time.Millisecond):
	}
	unlock()
	select {
	case <-got:
	case <-time.After(5 * time.Second):
		t.Fatal("释放之后第二把锁仍然拿不到")
	}
}

func TestWriteAtomicReplacesExisting(t *testing.T) {
	d := open(t)
	for _, content := range []string{"first", "second"} {
		if err := WriteAtomic(d.File("cache.json"), []byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	if data, _ := os.ReadFile(d.File("cache.json")); string(data) != "second" {
		t.Fatalf("内容：%q", data)
	}
}
