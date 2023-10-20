#!/bin/bash -e

# This is done in 2 steps. First, we make a basic image with all dependencies
#
# Next, we load up this intermediate container and compile odin on it. Then,
# we commit that container to a new image. The odin_${arch} image =]

set -o pipefail

g_repo_url='https://github.com/jasonKercher/Odin'
g_repo_branch='more-os2'

. error.sh

_update() {
	local arch="$1"

	# remove container if it already exists
	if { podman ps --noheading -a | grep -wqs "odin_${arch}_install_extras"; }; then
		podman rm odin_${arch}_install_extras
	fi

	podman run -dit \
		--workdir /home/rocko/vol \
		--name odin_${arch}_install_extras \
		--user root:root \
		--volume ./:/home/rocko/vol \
		odin_${arch}_no_extras

	# run this script in the container to install odin
	podman exec odin_${arch}_install_extras ./make_image.sh extras
	catch_error "podman failed to update odin_${arch}_install_extras"

	# commit the new container as an image with odin installed
	# Now, we have all the dependencies ready.  We can now
	# clean up the intermediate container and image.
	podman commit odin_${arch}_install_extras odin_${arch}
	podman stop odin_${arch}_install_extras
}

if [ "$1" = make ]; then
	if [ -n "$BUILDAH_ISOLATION" ]; then
		1>&2 echo 'already in buildah unshare environment??'
		exit 1
	fi

	shift
	arch="$1"

	buildah unshare ./make_image.sh make_original "$arch"

	_update "$arch"
	
	# also clean up the original buildah container
	buildah rm "original_container_${arch}"
	exit
fi

if [ "$1" = update ]; then
	shift
	_update "$1"
	exit $?
fi

# If we are calling this from within a container. We
# are installing extra things that we cannot get from
# apt like Odin!
if [ "$1" = extras ]; then
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
fi

if [ "$1" != make_original ]; then
	1>&2 echo "unexpected argument: $1"
	exit 1
fi

shift
arch="$1"

user=odinite
# NOTE: these should not map to an existing host user or group
# TODO: maybe add some smarts here...
uid=7272
gid=7272

container="original_container_${arch}"

if [ -z "$arch" ]; then
	1>&2 echo "missing argument"
fi

# If the original container already exists, we don't need to create it
if ! { buildah containers --noheading | grep -wqs $container; }; then
	case "$arch" in
	i386)  image_arch=386;;
	arm)   image_arch=arm;;
	arm64) image_arch=arm64;;
	esac

	buildah from --arch "$image_arch" --name $container debian
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
buildah commit $container odin_${arch}_no_extras:latest
buildah unmount $container
