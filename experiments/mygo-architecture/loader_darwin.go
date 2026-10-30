package main

import "github.com/ebitengine/purego"

const libraryName = "libStitchCoreABI.dylib"

func loadLibrary(path string) (uintptr, error) {
	return purego.Dlopen(path, purego.RTLD_NOW|purego.RTLD_LOCAL)
}
