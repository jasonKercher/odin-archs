#!/bin/bash

#############################################################
# Automated method of testing Odin from multiple archs
#############################################################

# Allow external declaration
if [ -z "$g_archs" ]; then
	declare -a g_archs=()
fi

g_repo_url='https://github.com/odin-lang/Odin.git'
g_repo_branch='master'
g_extra_packages=(llvm-13 clang-13 make vim-nox)

_dep_check() {
	local dep="$1"

	if ! command -v "$dep" >> /dev/null; then
		eprintln "Missing dependency: $dep"
		error_raise "Use your distro's package manager to install."
	fi
}

_container_kill() {
	local container_name="$1"
	shift
	# running natively or already in container, do nothing
	if [ "$container_name" = odin_native ] || [ "$container" = podman ]; then
		return
	fi

	if { podman ps --noheading | grep -wqs "$container_name"; }; then
		podman kill "$container_name"
	fi
}

# execute fuction in this script from within the container.
_container_call() {
	local is_root
	if [ "$1" = '--root' ]; then
		is_root=true
		shift
	fi

	local container_name="$1"
	shift

	# running natively or already in container; just call the function
	if [ "$container_name" = odin_native ] || [ "$container" = podman ]; then
		"$@"
		return
	fi

	if ! { podman ps --noheading | grep -wqs "$container_name"; }; then
		podman start "$container_name"
		error_catch 'failed to start container'
	fi
	local user
	$is_root && user='-u root:root'

	podman exec $user --privileged -it "$container_name" "$@"
	error_catch "failed to container exec $*"
}

_clean() {
	podman kill "odin_${arch}"
	podman rm "odin_${arch}"
	podman rmi "odin_${arch}_image"
	buildah rm "base_${arch}"
	rm "Odin/odin-${arch}"
}

cmd_clean() {
	for arch in "${g_archs[@]}"; do
		_clean "$arch"
		error_catch 'clean failed'
	done
}

_base() {
	local arch="${g_archs[0]}"
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
		buildah from --cap-add SYS_PTRACE --arch "$arch" --name $container debian
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

	buildah run $container apt -y install git build-essential "${g_extra_packages[@]}"

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
	buildah commit $container odin_${arch}_image:latest
	buildah unmount $container
}

_create_container() {
	if [ -z "$1" ]; then
		error_raise '_create_container expects architecture argument'
	fi

	local arch="$1"

	if ! { podman images --noheading | grep -wqs "odin_${arch}_image"; }; then
		./run.sh --arch="$arch" _base
		error_catch "run.sh failed"
	fi

	# create the container(s) if it does not exist yet
	if ! { podman ps --noheading -a | grep -wqs "odin_${arch}"; }; then
		uid=$(id -u)
		gid=$(id -g)

		podman run -dit \
			--cap-add=SYS_PTRACE \
			--workdir /home/odinite/vol \
			--name "odin_${arch}" \
			--user $uid:$gid \
			--userns keep-id \
			--volume ./:/home/odinite/vol \
			"odin_${arch}_image"
		error_catch '_create_container: podman run failed'
	fi
}

cmd_init() {
	for arch in "${g_archs[@]}"; do
		if [ "$arch" != native ]; then
			# This build requires buildah + podman to containerize the build.
			# Also requires qemu-user or something...
			_dep_check buildah
			_dep_check podman
			_create_container "$arch"
			error_catch '_create_container failed'
		fi
	done
}

# If we are calling this from within a container. We
# are installing extra things that we cannot get from
# apt like Odin!
_llvm_check() {
	if ! command -v clang++; then
		sudo ln -sv "$(which clang++-13)" /usr/bin/clang++
	fi
	if ! command -v clang; then
		sudo ln -sv "$(which clang-13)" /usr/bin/clang
	fi
	if ! command -v llvm-link; then
		sudo ln -sv "$(which llvm-link-13)" /usr/bin/llvm-link
	fi
	if ! command -v llvm-config; then
		sudo ln -sv "$(which llvm-config-13)" /usr/bin/llvm-config
	fi
}

_compile() {
	cd Odin || exit 2

	# It do be dubious
	git config --global --add safe.directory /home/odinite/vol/Odin

	make
	error_catch "failed to build odin"
	cp -v odin "odin-${g_archs[0]}"
	cd ..
	exit
}

cmd_make() {
	if [ -n "$BUILDAH_ISOLATION" ]; then
		1>&2 echo 'already in buildah unshare environment??'
		exit 1
	fi

	if [ ! -d Odin ]; then
		git clone -b "$g_repo_branch" "$g_repo_url"
	fi

	for arch in "${g_archs[@]}"; do
		if [ "$arch" != native ] && ! { podman ps --noheading -a | grep -wqs "odin_${arch}"; }; then
			error_raise "missing odin container.  Try '$0 -A \"$arch\" init'"
		fi

		_container_call --root "odin_${arch}" ./run.sh --arch="$arch" _llvm_check
		error_catch "function _llvm_check failed"

		_container_call "odin_${arch}" ./run.sh --arch="$arch" _compile
		error_catch "function _compile failed"
	done
}

# Cross compile options
#linux_i386
#linux_amd64
#linux_arm64
#linux_arm32

cmd_odin() {
	for arch in "${g_archs[@]}"; do
		_container_call "odin_${arch}" "Odin/odin-${arch}" "$@"
		# error_catch ??
	done
}

cmd_all() {
	cmd_init
	error_catch 'cmd_init failed'

	cmd_make
	error_catch 'cmd_make failed'

	cmd_odin "$@"
	error_catch 'cmd_odin failed'
}

_print_msg_help_exit() {
	local ret=0

	# if a message is provided, print and exit 2
	if [ -n "$1" ]; then
		eprintln "ERROR: $*"
		ret=2
	fi

	cat <<- HELP

	usage: $_script_name [-h] [-A arch] command

	available commands:
	clean:   clean up images and containers
	init:    check dependencies and create container
	make:    build the odin compiler inside container
	odin:    run odin compiler within container
	all:     perform all commands from start to finish

	options:
	name       argument     description
	--help|-h  <none>       print this
	-A         ARCH         one of native,amd64,i386,arm,arm64
	                        where native does not run in a container
	                        This overrides \${g_archs}

	HELP
	exit $ret
}

# main
{
	set -o pipefail  # this should be default behavior...

	distro=$(lsb_release -a 2>> /dev/null | grep 'Distributor ID' | cut -f2)
	majmin=$(lsb_release -a 2>> /dev/null | grep 'Release' | cut -f2)
	maj=$(cut -d. -f1 <<< "$majmin")

	_script_name="$0"
	_project_root=$(dirname "$0")
	. "${_project_root}/error.sh"

	cd "$_project_root"
	error_catch 'cd failed to project root'

	_project_root=$(pwd)/

	while getopts ':-:c:A:h' opt; do
		if [ "$opt" = "-" ]; then
			opt="${OPTARG%%=*}"
			OPTARG="${OPTARG#$opt}"
			OPTARG="${OPTARG#=}"
		fi

		case "$opt" in
		A | arch) g_archs=($OPTARG);;
		h | help) _print_msg_help_exit;;
		c | cmd)  cmd=${OPTARG};;
		\?)       exit 2;;
		*)        _print_msg_help_exit "$OPTARG: invalid argument";;
		esac
	done
	shift $((OPTIND-1))

	if [ "${#g_archs[@]}" -eq 0 ]; then
		_print_msg_help_exit "No architecture defined; set \${g_archs} or use -A|--arch option"
	fi

	if [ -z "$cmd" ]; then
		cmd="$1"
		shift
	fi

	if [ -z "$cmd" ]; then
		_print_msg_help_exit 'no command provided'
	fi

	case "${cmd,,}" in
	clean) cmd_clean "$@";;
	init)  cmd_init "$@";;
	make)  cmd_make "$@";;
	odin)  cmd_odin "$@";;
	all)   cmd_all "$@";;
	*)
		# Run internal function by name. Since we can only issue a single
		# command at a time via podman exec, it's cleaner to just allow
		# this script to be run from within the container and execute
		# those functions directly.
		if ! declare -F "$cmd" >> /dev/null; then
			error_raise "$cmd is not a defined function"
		fi
		if [ $# -eq 0 ]; then
			printf '\nRUN [%s]\n\n' "$cmd"
		else
			printf '\nRUN [%s %s]\n\n' "$cmd" "$*"
		fi
		"$cmd" "$@"
		error_catch "function failed: $cmd $*"
	esac
}
