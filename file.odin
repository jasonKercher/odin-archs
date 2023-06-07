package os2test

import "core:os/os2"
import "core:sys/unix"
import "core:runtime"
import "core:fmt"

main :: proc() {
	basic_file_write()
	double_close_err()
}

_assume_ok :: proc(err: os2.Error, loc := #caller_location) {
	if err == nil {
		return
	}
	os2.print_error(err, "unexpected error")
	panic("test failed", loc)
}

_file_create_and_write :: proc(name: string) -> (f: ^os2.File, err: os2.Error) {
	n: int

	f = os2.create(name) or_return
	_assume_ok(err)
	
	s := "hello os2\n"
	n = os2.write(f, transmute([]u8)s) or_return
	assert(n == len(s))

	return
}

basic_file_write :: proc() {
	f, err := _file_create_and_write("basic.txt")
	_assume_ok(err)
	_assume_ok(os2.close(f))
	_assume_ok(os2.remove("basic.txt"))
}

double_close_err :: proc() {
	f, err := _file_create_and_write("double_close.txt")
	_assume_ok(err)

	// close without destroying
	fd := os2.fd(f)
	res := unix.sys_close(int(fd))
	assert(res == 0)

	// leaks
	err = os2.close(f)
	v, ok := err.(os2.Platform_Error)
	assert(v == os2.Platform_Error(unix.EBADF))

	// unleak
	delete(f.impl.name, f.impl.allocator)
	free(f, f.impl.allocator)

	_assume_ok(os2.remove("double_close.txt"))
}
