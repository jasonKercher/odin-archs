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


#g_all_archs=(amd64 386 arm arm64)
g_all_archs=(arm)

g_repo_url='https://github.com/jasonKercher/Odin'
g_repo_branch='more-os2'

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

	if ! { podman ps --noheading | grep -wqs "$container_name"; }; then
		podman start "$container_name"
		error_catch 'failed to start container'
	fi

	# butterfly meme: is this recursion?
	podman exec $user --privileged -it "$container_name" ./build.sh "$@"
	error_catch "failed to container exec ./build.sh $*"
}

_create_container() {
	if [ -z "$1" ]; then
		error_raise '_create_container expects architecture argument'
	fi

	local arch="$1"

	if ! { podman images --noheading | grep -wqs "odin_${arch}"; }; then
		./run.sh make "$arch"
		error_catch "run.sh failed"
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
	if $is_local; then
		return
	fi

	shift
	local archs="$@"
	if [ "$#" -eq 0 ]; then
		archs="${g_all_archs[@]}"
	fi
	for arch in "${archs[@]}"; do
		_create_container "$arch"
		error_catch '_create_container failed'
	done
}

# If we are calling this from within a container. We
# are installing extra things that we cannot get from
# apt like Odin!
cmd_compile() {
	if [ "$container" != podman ]; then
		1>&2 echo 'not in expected container??'
		exit 1
	fi

	shift
	arch="$1"

	if ! command -v odin; then
		if [ ! -d Odin ]; then
			git clone -b "$g_repo_branch" "$g_repo_url"
		fi

		cd Odin || exit 2
		make || exit 2

		sudo mv -va $(pwd)/Odin/odin /usr/bin/
		sudo mv -va $(pwd)/Odin/core /usr/bin/

		cd .. || exit 2
	fi
	exit
}

_update() {
	local arch="$1"

	# remove container if it already exists
	if { podman ps --noheading -a | grep -wqs "odin_${arch}_install_compile"; }; then
		podman rm odin_${arch}_install_compile
	fi

	podman run -dit \
		--workdir /home/rocko/vol \
		--name odin_${arch}_install_compile \
		--user root:root \
		--volume ./:/home/rocko/vol \
		odin_${arch}_no_compile

	# run this script in the container to install odin
	podman exec odin_${arch}_install_compile ./run.sh compile
	error_catch "podman failed to update odin_${arch}_install_compile"

	# commit the new container as an image with odin installed
	# Now, we have all the dependencies ready.  We can now
	# clean up the intermediate container and image.
	podman commit odin_${arch}_install_compile odin_${arch}
	podman stop odin_${arch}_install_compile
}

cmd_update() {
	shift
	local archs="$@"
	if [ "$#" -eq 0 ]; then
		archs="${g_all_archs[@]}"
	fi
	for arch in "${archs[@]}"; do
		_update "$arch"
	done
}

cmd_base() {
	local arch="$1"

	local user=odinite
	# NOTE: these should not map to an existing host user or group
	# TODO: maybe add some smarts here...
	local uid=7272
	local gid=7272
	local container="base_${arch}"

	echo "BUILDING container ${container}..."

	if [ -z "$arch" ]; then
		1>&2 echo "missing argument"
	fi

	# If the original container already exists, we don't need to create it
	if ! { buildah containers --noheading | grep -wqs $container; }; then
		buildah from --arch "$arch" --name $container debian
	fi

	# method not sane because of set -x
	if buildah mount | grep -wqs $container; then
		mountpoint=$(buildah mount | grep -w $container | cut -d' ' -f2)
	else
		mountpoint=$(buildah mount ${container})
	fi


	buildah run $container apt update
	buildah run $container apt -y dist-upgrade
	buildah run $container apt -y install sudo locales

	buildah run $container apt -y install git build-essential llvm clang make vim-nox

	# reduce size of container by clearing out apt caches
	buildah run $container apt clean && \
	buildah run $container apt autoremove && \
	buildah run $container rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

	# create user/setup environment
	if [ ! -d  ${mountpoint}/home/${user}/vol ]; then
		mkdir -p ${mountpoint}/home/${user}/vol
	fi

	if ! grep -qs $user ${mountpoint}/etc/passwd; then
		echo "${user}:x:${uid}:${gid}:${user},,,:/home/${user}:/bin/bash" >> ${mountpoint}/etc/passwd
	fi

	if ! grep -qs $user ${mountpoint}/etc/group; then
		echo "${user}:x:${uid}:" >> ${mountpoint}/etc/group
	fi

	echo "${user} ALL=(ALL) NOPASSWD: ALL" > ${mountpoint}/etc/sudoers.d/${user} && \
	chmod 0440 ${mountpoint}/etc/sudoers.d/${user}
	chown ${uid}:${gid} -R ${mountpoint}/home/${user}

	# Configure ccache.
	buildah config --env USE_CCACHE=1 $container
	buildah config --env CCACHE_DIR=/root/.ccache $container

	# Set the locale
	buildah run $container locale-gen en_US.UTF-8
	buildah config --env LANG=en_US.UTF-8 $container

	# more configuration stuff
	buildah config --env HOME=/home/${user} $container
	buildah config --env USER=${user} $container
	buildah config --user ${user} $container
	buildah config --workingdir /home/${user}/vol $container

	# build original image
	buildah commit $container odin_${arch}_no_compile:latest
	buildah unmount $container
}

cmd_make() {
	if [ -n "$BUILDAH_ISOLATION" ]; then
		1>&2 echo 'already in buildah unshare environment??'
		exit 1
	fi

	shift
	local archs="$@"
	if [ "$#" -eq 0 ]; then
		archs="${g_all_archs[@]}"
	fi
	for arch in "${archs[@]}"; do
		if ! { podman ps --noheading -a | grep -wqs "odin_${arch}_no_compile"; }; then
			buildah unshare ./run.sh base "$arch"
		fi
		_update "$arch"
		buildah rm "base_${arch}"
	done
}

cmd_run() {
	# lol
	odin run . "$@"
}

cmd_all() {
	cmd_init

	shift
	local archs="$@"
	if [ "$#" -eq 0 ]; then
		archs="${g_all_archs[@]}"
	fi
	for arch in "${archs[@]}"; do
		cmd_run "$arch"
		error_catch 'cmd_run failed'
	done
}

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
	init:    check dependencies and initialize images
	make:    build container and build odin in container
	compile: just rebuild compiler
	base:    rebuild the base container
	run:     run tests on specified platform
	all:     perform all commands from start to finish

	HELP

	exit $ret
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
	init)     cmd_init "$@";;
	make)     cmd_make "$@";;
	base)     cmd_base "$@";;
	compile)  cmd_compile "$@";;
	update)   cmd_update "$@";;
	run)      cmd_run "$@";;
	all)      cmd_all "$@";;
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
