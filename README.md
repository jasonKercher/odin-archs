Use `run.sh` to compile and run the odin compiler under different architectures.

This works by cloning a local copy of the compiler and mounting the current directory
as a volume in the container.  Architecture is controlled by the `${g_archs}`
variable in `run.sh` which can be treated as an array.  This can be set externally:

```sh
g_archs=arm64 ./run.sh init
```

or by the `-A|--arch` command line option:

```sh
./run.sh --arch="arm64 amd64" make
```

Available architectures:
* amd64
* arm64
* arm
* i386
* native

Native will run outside of a container. Currently, arm and i386 do not appear
to build the compiler.

The `init` command will build the container needed to run a specific architecture.

The `make` command will build the odin compiler inside of a container.

The `odin` command, will execute the compiler with your provided arguments inside a container

Example:

```sh
ps1 :) ./run.sh -A "arm64 native amd64" odin run example.odin -file
hello from arm64
hello from amd64
hello from amd64
```

### Dependencies
* podman
* buildah
* qemu-user-static (or whatever your package manager calls it)
