package os2test

import "core:fmt"

main :: proc() {
	fmt.println("running tests...")

	basic_file_write()
	read_random()
	no_exist_file_err()
	double_close_err()
	symlinks()
	permissions()
	file_times()

	fmt.println("tests pass !!")
}

