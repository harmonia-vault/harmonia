//go:build !windows

package state

import (
	"os"
	"syscall"
)

func restrict(dir string) error { return os.Chmod(dir, 0o700) }

func lockFile(f *os.File) error { return syscall.Flock(int(f.Fd()), syscall.LOCK_EX) }

func unlockFile(f *os.File) { syscall.Flock(int(f.Fd()), syscall.LOCK_UN) }

func replaceFile(from, to string) error { return os.Rename(from, to) }
