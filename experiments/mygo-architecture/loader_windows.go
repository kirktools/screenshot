package main

import (
	"fmt"
	"syscall"
	"unsafe"
)

const libraryName = "StitchCoreABI.dll"

func loadLibrary(path string) (uintptr, error) {
	text, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	load := syscall.NewLazyDLL("kernel32.dll").NewProc("LoadLibraryExW")
	// 仅从指定库目录与系统默认安全目录解析依赖，排除当前工作目录。
	handle, _, err := load.Call(uintptr(unsafe.Pointer(text)), 0, 0x100|0x1000)
	if handle == 0 {
		return 0, fmt.Errorf("native library load failed: %w", err)
	}
	return handle, nil
}
