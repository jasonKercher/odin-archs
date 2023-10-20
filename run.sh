#!/bin/bash

#############################################################
# Automated method of testing Odin from multiple archs
#############################################################

# if [ "$distro" = Ubuntu ] && [ "$majmin" = 16.04 ]; then
# 	is_local=true
# 	if [ -n "$clean_path" ]; then
# 		export PATH=$clean_path
# 	fi
# fi

_print_msg_help_exit() {
	local ret=0

	# if a message is provided, print and exit 2
	if [ -n "$1" ]; then
		eprintln "ERROR: $*"
		ret=2
	fi

	cat <<- HELP

	usage: $_script_name [-h] command

	available commands:
	init:  check dependencies and initialize images
	run:   run tests on specified platform
	all:   perform all commands from start to finish

	HELP

	exit $ret
}

_dep_check() {
	local dep="$1"

	if ! command -v "$dep" >> /dev/null; then
		eprintln "Missing dependency: $dep"
		error_raise "Use your distro's package manager to install."
	fi
}

# execute fuction in this script from within the container.
_container_call() {
	if [ "$1" = '--root' ]; then
		user='-u root:root'
		shift
	fi

	# running natively or already in container; just call the function
	if $is_local || [ "$container" = podman ]; then
		"$@"
		return
	fi

	local container_name="$1"
	shift

	if ! { podman ps --noheading | grep -wqs "$1"; }; then
		podman start "$container_name"
		error_catch 'failed to start container'
	fi

	# butterfly meme: is this recursion?
	podman exec $user --privileged -it "$container_name" ./build.sh "$@"
	error_catch "failed to container exec ./build.sh $*"
}

_create_container() {
	if [ -z "$1" ]; then
		raise_error '_create_container expects architecture argument'
	fi

	local arch="$1"

	if ! { podman images --noheading | grep -wqs "odin_${arch}"; }; then
		./make_image.sh make "$arch"
		error_catch "make_image.sh failed"
	fi

	# create the container(s) if it does not exist yet
	if ! { podman ps --noheading -a | grep -wqs "odin_${arch}_container"; }; then
		uid=$(id -u)
		gid=$(id -g)

		podman run -dit \
			--workdir /home/odinite/vol \
			--name "odin_${arch}_container" \
			--user $uid:$gid \
			--userns keep-id \
			--volume ./:/home/odinite/vol \
			"odin_${arch}"
		error_catch 'podman run failed'
	fi
}

cmd_init() {
	if ! $is_local; then
		# This build requires buildah + podman to containerize the build.
		# Also requires qemu-user or something...
		_dep_check buildah
		_dep_check podman
	fi

	# build the image if it doesn't exist...
	if ! $is_local; then
		_create_container i386
		#_create_container arm
		#_create_container arm32
	fi
}

cmd_update() {
	./make_image.sh update i386
	./make_image.sh update arm
	./make_image.sh update arm64
}

cmd_run() {
	odin run .
}

cmd_all() {
	cmd_init
	cmd_run amd64 # Assumed our arch
	_container_call cmd_run i386
	_container_call cmd_run arm
	_container_call cmd_run arm64
}

# main
{
	set -o pipefail  # this should be default behavior...

	is_local=false

	distro=$(lsb_release -a 2>> /dev/null | grep 'Distributor ID' | cut -f2)
	majmin=$(lsb_release -a 2>> /dev/null | grep 'Release' | cut -f2)
	maj=$(cut -d. -f1 <<< "$majmin")

	_script_name="$0"
	_project_root=$(dirname "$0")
	. "${_project_root}/error.sh"

	cd "$_project_root"
	error_catch 'cd failed to project root'

	_project_root=$(pwd)/

	while getopts ':c:h' opt; do
		case "$opt" in
		h)
			_print_msg_help_exit;;
		c)
			cmd=${OPTARG};;
		*)
			_print_msg_help_exit "$OPTARG: invalid argument";;
		esac
	done
	shift $((OPTIND-1))

	if [ -z "$cmd" ]; then
		cmd="$1"
		shift
	fi

	if [ -z "$cmd" ]; then
		_print_msg_help_exit 'no command provided'
	fi

	case "${cmd,,}" in
	init) cmd_init "$@";;
	run)  cmd_run "$@";;
	all)  cmd_all "$@";;
	*)
		# Run internal function by name. Since we can only issue a single
		# command at a time via podman exec, it's cleaner to just allow
		# this script to be run from within the container and execute
		# those functions directly.
		if ! declare -F "$cmd"; then
			error_raise "$cmd is not a defined function"
		fi
		"$cmd" "$@"
		error_catch "function failed: $cmd $*"
	esac
}
