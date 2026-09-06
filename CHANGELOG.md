# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases are named after the **upstream e2fsprogs version** they package:
`v1.47.4` is e2fsprogs 1.47.4, cross-built to run on the Raspberry Pi.

## [Unreleased]

### Changed

- More detail in the documentation.

## [1.47.4] - 2026-09-04

### Added

- The whole build: fetch the e2fsprogs release, verify it against both
  kernel.org's `sha256sums.asc` and the digest committed in `checksums/`,
  cross-build every program the package installs and pack them as one release
  asset.
- **All** the programs, not a subset — 22 of them plus 9 alternate names, in
  upstream's own Linux layout: `/sbin` for what a system needs before `/usr` is
  mounted, `/usr/sbin` and `/usr/bin` for the rest, and `/etc/mke2fs.conf`,
  without which `mke2fs` will not run.
- The libraries are linked statically into each program, so every one of them
  depends on musl alone; `stage-check` reads all 22 back and asserts it.
- CI on every commit and branch, and a manual release workflow.

### Fixed

- The first CI run failed at `toolchain-check`: Debian's `gcc` only
  *recommends* `libc6-dev`, and both workflows install with
  `--no-install-recommends`, so `cc` was present, ran, linked a static binary —
  and then could not find `<stdio.h>`. Both package lists now name `libc6-dev`,
  and `assert_build_cc` preprocesses a one-line program so the failure names
  the missing package in a second instead of surfacing inside the build.

### Notes

- `--disable-subset` disables nothing: it is the only use of `SUBSET_CMT` in
  the tree, and all it removes is the `install-libs` line at the end of the
  top-level `install` target. Without it a plain `make install` also installs
  the headers, static libraries and `.pc` files — which is what `WITH_DEVEL`
  is for.
- `--enable-symlink-install` is about `strip`, not tidiness: upstream hard-links
  `mkfs.ext4` and friends, and binutils `strip` renames a temporary file over
  the original, which breaks the link and leaves four separate copies.

[Unreleased]: https://github.com/Sepia-OS/e2fsprogs/compare/v1.47.4...HEAD
[1.47.4]: https://github.com/Sepia-OS/e2fsprogs/releases/tag/v1.47.4
