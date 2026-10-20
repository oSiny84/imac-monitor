package recordings

import (
	"os"
	"syscall"
	"unsafe"
)

// Windows development/test equivalent. Production macOS uses flock, matching Swift.
var lockFileEx = syscall.NewLazyDLL("kernel32.dll").NewProc("LockFileEx")
var unlockFileEx = syscall.NewLazyDLL("kernel32.dll").NewProc("UnlockFileEx")

func tryProtectionLock(file *os.File) (bool, error) {
	var overlapped syscall.Overlapped
	result, _, err := lockFileEx.Call(file.Fd(), 0x1|0x2, 0, 1, 0, uintptr(unsafe.Pointer(&overlapped)))
	if result != 0 {
		return true, nil
	}
	if err == syscall.Errno(33) {
		return false, nil
	} // ERROR_LOCK_VIOLATION
	return false, err
}

func releaseProtectionLock(file *os.File) {
	var overlapped syscall.Overlapped
	_, _, _ = unlockFileEx.Call(file.Fd(), 0, 1, 0, uintptr(unsafe.Pointer(&overlapped)))
}
