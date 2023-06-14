package os2test

import "core:os/os2"

assume_ok :: proc(err: os2.Error, loc := #caller_location) {
	if err == nil {
		return
	}
	os2.print_error(err, "unexpected error")
	panic("test failed", loc)
}

