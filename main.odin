package os2test

import "core:fmt"
import "core:os/os2"

main :: proc() {
	fmt.println("running tests...")

	context.allocator = os2.heap_allocator()

	basic_file_write()
	read_random()
	no_exist_file_err()
	double_close_err()
	symlinks()
	permissions()
	file_times()

	fmt.println("tests pass !!")
}

