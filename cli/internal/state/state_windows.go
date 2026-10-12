package state

import (
	"errors"
	"os"
	"time"

	"golang.org/x/sys/windows"
)

// restrict 让数据目录只允许本人、系统和管理员访问，并且不再继承上级目录的权限；
// 目录中的文件沿用这份权限。
func restrict(dir string) error {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return err
	}
	sd, err := windows.SecurityDescriptorFromString(
		"D:PAI(A;OICI;FA;;;" + user.User.Sid.String() + ")(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
}

func lockFile(f *os.File) error {
	return windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, new(windows.Overlapped))
}

func unlockFile(f *os.File) {
	windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, new(windows.Overlapped))
}

// replaceFile 替换目标文件。目标正被其他程序读取（例如杀毒软件扫描）时系统会拒绝替换，稍等再试。
func replaceFile(from, to string) error {
	var err error
	for wait := 10 * time.Millisecond; wait < time.Second; wait *= 2 {
		err = os.Rename(from, to)
		if err == nil || !(errors.Is(err, windows.ERROR_ACCESS_DENIED) || errors.Is(err, windows.ERROR_SHARING_VIOLATION)) {
			return err
		}
		time.Sleep(wait)
	}
	return err
}
