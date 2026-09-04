# e2fsprogs

This repository builds and provides the `e2fsprogs` package for SepiaOS.

The result is the **complete** e2fsprogs program set cross-compiled for
**aarch64**, linked **dynamically** against musl, and installed into `/sbin`,
`/usr/sbin`, `/usr/bin` and `/etc` on the device — `mke2fs`, `e2fsck`,
`tune2fs`, `resize2fs`, `debugfs`, `dumpe2fs`, `badblocks`, `blkid`, `fsck`,
`e2image`, `filefrag`, `chattr` and the rest. It is the filesystem toolset that
goes on the card beside the compiler from [llvm](https://github.com/Sepia-OS/llvm)
and the build driver from [make](https://github.com/Sepia-OS/make): together
they let a Pi create, check, resize and inspect its own ext2/3/4 filesystems.

> [rootfs](https://github.com/Sepia-OS/rootfs) already cross-builds **one** of
> these programs, `resize2fs`, because first boot has to grow the root
> partition and busybox has no applet for it. This repository is the whole
> package; `rootfs` builds e2fsprogs twice for its own reasons (host `mke2fs`
> and `debugfs` create the image itself) and that is not what this is.

The sources are the release tarball from kernel.org, pinned to a version and
checked twice: against upstream's own `sha256sums.asc`, and against a digest
recorded in [checksums/](checksums) so the pin still means something offline.

The build is compiled with the same musl-targeting cross-toolchain that
[llvm](https://github.com/Sepia-OS/llvm) and [make](https://github.com/Sepia-OS/make)
use, against the same musl version that
[rootfs](https://github.com/Sepia-OS/rootfs) ships. Nothing needs root, and
nothing is written outside `build/`.

## Prerequisites

`gmake` (GNU Make ≥ 4.0), `curl`, `tar`, `xz` — and, unlike the sibling
repositories, **a C compiler for the build machine as well**.

```sh
brew install make xz                          # macOS (cc comes from the Xcode CLT)
sudo apt install make curl xz-utils gcc       # Debian / Ubuntu
```

e2fsprogs compiles and *runs* helper programs during its build: `util/subst`
generates config files, `lib/ext2fs` generates its CRC32c table, and
`configure` itself runs `util/parse-types.sh` through `BUILD_CC`. Those run on
the machine doing the building, so a host compiler is not optional here. Set
`BUILD_CC` if yours is not called `cc`.

> **On macOS, run `gmake`, not `make`.** `/usr/bin/make` is GNU Make 3.81,
> which compares file timestamps only to the whole second and will silently
> reuse a stale object after a fast edit. The Makefile refuses to run on it.

The cross-toolchain is downloaded automatically — messense on macOS, bootlin
on Linux, because no single vendor publishes a musl-targeting aarch64
toolchain for both hosts. Point `CROSS_COMPILE` at one you already have to skip
the download.

## Quick start

```sh
gmake toolchain-check    # prove the compiler builds C against musl
gmake e2fsprogs          # cross-build the programs
gmake stage-check        # prove every one is aarch64 and needs only musl
gmake dist               # pack them as a release asset
```

Run `gmake help` for the full list.

## Targets

| Target | What it does |
|---|---|
| `help` | targets and variables (the default goal) |
| `toolchain` | fetch and verify the musl-targeting cross-compiler |
| `toolchain-check` | compile and link C against musl, dynamically and statically, and prove the host compiler works |
| `sysroot` | build musl into `build/sysroot`, plus the Linux UAPI headers |
| `sysroot-check` | prove C links dynamically against that sysroot |
| `sources` | fetch, verify and unpack the e2fsprogs release tarball |
| `verify-downloads` | check the sources and musl against the recorded digests |
| `e2fsprogs` | `configure` out of tree and build every program directory |
| `stage` | upstream's `make install` into a staged tree, then strip it |
| `stage-check` | assert aarch64, the musl loader, a dependency on nothing but musl, and that the layout is intact |
| `dist` | pack the staged tree into `dist/` with `SHA256SUMS` |
| `*-info` | what version, from where, how big |
| `clean` / `distclean` | drop `build/` / also drop `downloads/` and `dist/` |

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `E2FSPROGS_VERSION` | `1.47.4` | upstream release to build |
| `MUSL_VERSION` | `1.2.6` | target musl — must match what `rootfs` ships |
| `PREFIX` | `/usr` | prefix for the non-essential programs |
| `ROOT_PREFIX` | *(empty)* | prefix for `/sbin`, `/bin` and `/etc` |
| `CONFIGURE_FLAGS` | see `gmake help` | passed to upstream's `configure` |
| `CROSS_COMPILE` | *(empty)* | use a musl cross-toolchain you already have |
| `BUILD_CC` | `cc` | host compiler for the build-time helpers |
| `WITH_STRIP` | `1` | strip the staged programs |
| `WITH_DEVEL` | `0` | also ship headers, static libraries and `.pc` files |
| `WITH_MANPAGES` | `0` | also ship man pages |
| `WITH_E2SCRUB` | `0` | also ship the `e2scrub` scripts |
| `DIST_TAG` | *(empty)* | release tag to name the asset after |
| `JOBS` | host CPUs | parallelism for the builds |

## What ships

Twenty-two programs and nine alternate names, in upstream's own Linux layout —
the ones a system needs before `/usr` is mounted in `/sbin`, the rest under
`/usr`:

```
sbin/badblocks      sbin/e2image        sbin/logsave        usr/bin/chattr
sbin/blkid          sbin/e2undo         sbin/mke2fs         usr/bin/lsattr
sbin/debugfs        sbin/fsck           sbin/resize2fs      usr/bin/uuidgen
sbin/dumpe2fs       sbin/e2fsck         sbin/tune2fs
usr/sbin/e2freefrag  usr/sbin/e4crypt   usr/sbin/e4defrag
usr/sbin/filefrag    usr/sbin/mklost+found  usr/sbin/uuidd  usr/lib/e2initrd_helper

sbin/mkfs.ext2  sbin/mkfs.ext3  sbin/mkfs.ext4     -> mke2fs
sbin/fsck.ext2  sbin/fsck.ext3  sbin/fsck.ext4     -> e2fsck
sbin/e2label    sbin/findfs                        -> tune2fs
sbin/e2mmpstatus                                   -> dumpe2fs

etc/mke2fs.conf                                    mke2fs will not run without it
usr/share/licenses/e2fsprogs/NOTICE                GPLv2, LGPLv2, MIT and BSD
usr/share/licenses/e2fsprogs/COPYING.libuuid
```

The libraries — `libext2fs`, `libcom_err`, `libe2p`, `libss`, `libblkid`,
`libuuid` — are **static**, so every program carries the parts it uses and
depends on musl alone. `stage-check` reads all twenty-two back and asserts it.
The alternative, ELF shared libraries, would save about 2 MiB and turn a single
missing `.so` into a card where nothing in the package runs at all.

`fuse2fs` is the one program upstream can build that is not here: it needs
libfuse, which the card does not have.

musl is deliberately **not** in the asset: the device's libc comes from
`rootfs`, and a second copy on the card is two libcs disagreeing. `stage-check`
asserts that too.

A local build produces `dist/sepiaos-e2fsprogs-<version>-aarch64-musl.tar.xz`
(644 KB for 1.47.4, from a 5.7 MiB stripped tree) and its `SHA256SUMS`, which
is what `rootfs` is expected to unpack into the root filesystem — siblings
consume each other's published releases, never each other's build trees.

```sh
sha256sum -c SHA256SUMS
tar -C / -xf sepiaos-e2fsprogs-1.47.4-aarch64-musl.tar.xz
```
