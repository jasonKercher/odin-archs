package main

import "core:fmt"

main :: proc() {
	when ODIN_ARCH == .amd64 {
		fmt.println("hello from amd64")
	} else when ODIN_ARCH == .arm64 {
		fmt.println("hello from arm64")
	} else when ODIN_ARCH == .arm32 {
		fmt.println("hello from arm32")
	} else when ODIN_ARCH == .i386 {
		fmt.println("hello from i386")
	}
}

