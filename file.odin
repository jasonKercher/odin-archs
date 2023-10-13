package os2test

import "core:os/os2"
import "core:sys/unix"
import "core:runtime"
import "core:fmt"

basic_file_write :: proc() {
	f := _file_create_write("basic.txt", "hello os2")
	assume_ok(os2.close(f))
	assume_ok(os2.remove("basic.txt"))
}

no_exist_file_err :: proc() {
	f, err := os2.open("file-that-does-not-exist.txt")
	assert(err != nil)
	os2.print_error(err, "file-that-does-not-exist.txt")
}

double_close_err :: proc() {
	f := _file_create_write("double_close.txt", "close")
	assume_ok(os2.close(f))
	assert(os2.close(f) != nil)
	assume_ok(os2.remove("double_close.txt"))
}

read_random :: proc() {
	s := "01234567890abcdef"
	f := _file_create_write("random.txt", s)
	assume_ok(os2.close(f))

	err: os2.Error
	f, err = os2.open("random.txt")

	// full read
	n: int
	buf: [64]u8
	n, err = os2.read(f, buf[:])
	assume_ok(err)
	assert(n == len(s))
	assert(string(buf[:n]) == s)

	// using read_at
	for i := 1; i < len(s); i += 1 {
		sub := s[i:]
		n, err = os2.read_at(f, buf[:], i64(i))
		assume_ok(err)
		assert(n == len(sub))
		assert(string(buf[:n]) == sub)
	}

	// using seek
	for i := 1; i < len(s); i += 1 {
		sub := s[i:]
		os2.seek(f, i64(i), .Start)
		n, err = os2.read(f, buf[:])
		assume_ok(err)
		assert(n == len(sub))
		assert(string(buf[:n]) == sub)
	}
}


_file_create_write :: proc(name, contents: string) -> (f: ^os2.File) {
	err: os2.Error
	f, err = os2.create(name)
	assume_ok(err)
	n: int
	n, err = os2.write(f, transmute([]u8)contents)
	assume_ok(err)
	assert(n == len(contents))
	return
}


