package service

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf16"

	"golang.org/x/sys/windows"

	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

// 后台服务是当前用户的计划任务：登录时启动，以普通权限运行，注册和删除都不需要管理员权限
// （docs/rewrite-plan.md 15.4）。任务通过 conhost --headless 启动 harmonia daemon，这样没有窗口。
const (
	taskName  = "Harmonia"
	taskLabel = "计划任务“" + taskName + "”"
)

// decode 把系统命令的输出（当前代码页）转成 UTF-8，错误信息才能正常显示。
func decode(out []byte) string {
	if len(out) == 0 {
		return ""
	}
	n, err := windows.MultiByteToWideChar(windows.GetACP(), 0, &out[0], int32(len(out)), nil, 0)
	if err != nil || n == 0 {
		return string(out)
	}
	wide := make([]uint16, n)
	if _, err := windows.MultiByteToWideChar(windows.GetACP(), 0, &out[0], int32(len(out)), &wide[0], n); err != nil {
		return string(out)
	}
	return string(utf16.Decode(wide))
}

// 后台服务运行期间持有一个以数据目录命名的事件：它存在就表示正在运行，
// CLI 把它置为有信号就是要求后台服务退出。
func eventName(dataDir string) *uint16 {
	sum := sha256.Sum256([]byte(strings.ToLower(filepath.Clean(dataDir))))
	name, _ := windows.UTF16PtrFromString(`Local\Harmonia-` + hex.EncodeToString(sum[:8]))
	return name
}

// Hold 由后台服务在启动时调用。返回的通道在 CLI 要求停止时关闭；release 在退出时调用。
func Hold(dataDir string) (stop <-chan struct{}, release func(), err error) {
	h, err := windows.CreateEvent(nil, 1, 0, eventName(dataDir))
	if errors.Is(err, windows.ERROR_ALREADY_EXISTS) {
		windows.CloseHandle(h)
		return nil, nil, errors.New("后台服务已经在运行，不需要再启动一个")
	}
	if err != nil {
		return nil, nil, err
	}
	ch := make(chan struct{})
	go func() {
		windows.WaitForSingleObject(h, windows.INFINITE)
		close(ch)
	}()
	return ch, func() { windows.CloseHandle(h) }, nil
}

func running(dataDir string) bool {
	h, err := windows.OpenEvent(windows.SYNCHRONIZE, false, eventName(dataDir))
	if err != nil {
		return false
	}
	windows.CloseHandle(h)
	return true
}

// stop 要求后台服务退出并等它结束，最多等 10 秒。
func stop(dataDir string) error {
	h, err := windows.OpenEvent(windows.EVENT_MODIFY_STATE, false, eventName(dataDir))
	if err != nil {
		return nil
	}
	windows.SetEvent(h)
	windows.CloseHandle(h)
	for i := 0; i < 100; i++ {
		if !running(dataDir) {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("后台服务没有在 10 秒内停止，请稍后重试")
}

// start 运行计划任务并确认后台服务已经起来。
func start(dataDir string) error {
	var out string
	var err error
	for i := 0; i < 3; i++ {
		// 上一次运行可能还没有完全结束，这时系统会忽略新的启动请求，所以先结束再启动。
		_, _ = run("schtasks", "/end", "/tn", taskName)
		if out, err = run("schtasks", "/run", "/tn", taskName); err != nil {
			return fmt.Errorf("启动后台服务失败：%s", out)
		}
		for j := 0; j < 30; j++ {
			if running(dataDir) {
				return nil
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	return errors.New("后台服务没有启动成功，请查看数据目录中的 daemon.log")
}

func escapeXML(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;")
	return r.Replace(s)
}

// Install 安装并启动后台服务。bin 为 harmonia.exe 的绝对路径，dataDir 为本机数据目录。
func Install(bin, dataDir string) (*Result, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, err
	}
	sid := user.User.Sid.String()
	system, err := windows.GetSystemDirectory()
	if err != nil {
		return nil, err
	}
	// 两个触发条件：登录时启动；另外每 10 分钟检查一次，后台服务不在运行就重新启动
	//（正在运行时系统忽略新的启动请求）。
	task := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Harmonia 环境变量同步</Description></RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>%[1]s</UserId></LogonTrigger>
    <TimeTrigger>
      <Repetition><Interval>PT10M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>%[1]s</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>%[2]s</Command><Arguments>%[3]s</Arguments></Exec>
  </Actions>
</Task>
`, sid, escapeXML(filepath.Join(system, "conhost.exe")),
		escapeXML(fmt.Sprintf(`--headless "%s" daemon --home "%s"`, bin, dataDir)))
	file, err := os.CreateTemp("", "harmonia-task-*.xml")
	if err != nil {
		return nil, err
	}
	defer os.Remove(file.Name())
	// schtasks 只认 UTF-16（带字节序标记）的任务定义。
	encoded := []byte{0xff, 0xfe}
	for _, u := range utf16.Encode([]rune(task)) {
		encoded = append(encoded, byte(u), byte(u>>8))
	}
	_, err = file.Write(encoded)
	if cerr := file.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return nil, err
	}
	if err := stop(dataDir); err != nil {
		return nil, err
	}
	if out, err := run("schtasks", "/create", "/tn", taskName, "/xml", file.Name(), "/f"); err != nil {
		return nil, fmt.Errorf("注册计划任务失败：%s", out)
	}
	if err := start(dataDir); err != nil {
		return nil, err
	}
	return &Result{Path: taskLabel, Notes: []string{"Windows 上后台服务在登录后运行。"}}, nil
}

// Uninstall 删除计划任务并停止后台服务。先删除任务，免得它在停止之后又被启动。
func Uninstall() error {
	d, err := state.Open()
	if err != nil {
		return err
	}
	if Check().Installed {
		if out, err := run("schtasks", "/delete", "/tn", taskName, "/f"); err != nil {
			return fmt.Errorf("删除计划任务失败：%s", out)
		}
	}
	return stop(d.Path)
}

// Restart 重启后台服务（升级后使用）；未安装时忽略。
func Restart() error {
	if !Check().Installed {
		return nil
	}
	d, err := state.Open()
	if err != nil {
		return err
	}
	if err := stop(d.Path); err != nil {
		return err
	}
	return start(d.Path)
}

func Check() Status {
	s := Status{Supported: true, Path: taskLabel}
	_, err := run("schtasks", "/query", "/tn", taskName)
	s.Installed = err == nil
	if d, err := state.Open(); err == nil {
		s.Running = running(d.Path)
	}
	return s
}
