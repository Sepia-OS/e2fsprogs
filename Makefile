# SepiaOS - e2fsprogs for the target
#
# Downloads the e2fsprogs sources and cross-builds every program the package
# installs - mke2fs, e2fsck, tune2fs, resize2fs, debugfs, dumpe2fs, badblocks,
# blkid, chattr and the rest - to run *on* the Pi, linked dynamically against
# musl, for installation into the SepiaOS root filesystem. It is the
# filesystem toolset that goes on the card beside the compiler from ../llvm and
# the build driver from ../make.
#
#   make toolchain-check    prove the cross-compiler builds C against musl
#   make e2fsprogs          cross-build the programs
#   make stage-check        prove every product is aarch64 and needs only musl
#   make help               every target
#
# No root, no containers: everything is a download plus a cross-build, so the
# same recipes work on macOS and Linux.

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

# Make 3.81 (still /usr/bin/make on macOS) compares timestamps only to the
# second and silently reuses stale outputs after a fast edit.
ifeq ($(filter 4.% 5.%,$(MAKE_VERSION)),)
$(error GNU Make >= 4.0 required, found $(MAKE_VERSION). On macOS: brew install make, then run gmake)
endif

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

# --retry-all-errors is load-bearing rather than decoration: ../llvm measured
# four consecutive single-shot fetches of the musl tarball failing from
# debian:trixie-slim, two with a TLS handshake error, which plain --retry does
# not class as transient and therefore will not retry.
CURL   := curl --fail --silent --show-error --location \
                --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo "sha256sum" || echo "shasum -a 256")

DL_DIR    := downloads
BUILD_DIR := build
DIST_DIR  := dist
CHECKSUMS := checksums

HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# Homebrew sets CPPFLAGS and LDFLAGS in the developer's shell on macOS, and
# configure reads them straight onto *cross* compile lines. ../llvm found
# -I/opt/homebrew/opt/include and -L/opt/homebrew/opt/lib in a real target
# link: nothing broke, because nothing was found there, but a host header or
# library that *was* found would have gone into a target binary silently.
# Scrubbed rather than trusted.
SCRUB_ENV := env -u CPPFLAGS -u LDFLAGS -u CFLAGS -u CXXFLAGS \
                 -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH

# Overriding a variable on the command line changes what gets built but touches
# no file, so Make cannot see it: without this, `gmake WITH_DEVEL=1 stage`
# would report "Nothing to be done" and hand back the runtime-only tree. Each
# expensive tree therefore carries a signature of the settings that determine
# its contents, rewritten only when it actually changes so that it works as an
# ordinary prerequisite. Same idiom as ../make and ../boot's CONFIG_SIG.
.PHONY: FORCE
FORCE:

# $(1) stamp path, $(2) signature
define config_stamp_rule
$(1): FORCE
	@mkdir -p $$(@D)
	@printf '%s\n' '$(2)' | cmp -s - $$@ || printf '%s\n' '$(2)' > $$@
endef

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The upstream release to build. Newer:
# https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/
#
# Pinned rather than resolved, unlike ../rootfs, which asks the release index
# for the latest: a release asset has to say which version it is, and CI has to
# build the same thing twice. ../rootfs's resolver is right for a tool it
# builds and throws away; this one is packaged.
E2FSPROGS_VERSION ?= 1.47.4
E2FS_BASE         := https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs

# Where the package lands on the device. Upstream's Linux layout, which is what
# the empty root prefix buys: the programs a system needs before /usr is
# mounted go in /sbin (e2fsck, mke2fs, tune2fs, resize2fs, ...), the rest in
# /usr/sbin and /usr/bin, and mke2fs.conf in /etc. On SepiaOS / and /usr are
# the same filesystem, so this is convention rather than necessity - but it is
# the convention every other e2fsprogs on earth follows, and a card whose
# `which mke2fs` matches the manual is worth more than a tidier tarball.
PREFIX      ?= /usr
ROOT_PREFIX ?=

# What configure derives from the two above, spelled out here because the
# checks and the documentation need to name the directories, and an empty
# ROOT_PREFIX makes them /sbin, /bin and /etc.
ROOT_SBIN = $(ROOT_PREFIX)/sbin
ROOT_BIN  = $(ROOT_PREFIX)/bin
ROOT_ETC  = $(ROOT_PREFIX)/etc

# The triple the product is built for, fixed rather than taken from whichever
# compiler built it. ../llvm and ../make pin the same one for the same reason:
# the two toolchain vendors disagree about their own name (messense says
# aarch64-unknown-linux-musl, bootlin says aarch64-buildroot-linux-musl).
TARGET_TRIPLE := aarch64-unknown-linux-musl

# e2scrub is a pair of shell scripts, not programs: they drive lvm2 to take a
# snapshot and fsck it, and they want bash, lvm2, udev and either systemd or
# cron. SepiaOS has none of those, so shipping them would put two commands on
# the card that cannot do anything but fail. Off by default; the flag exists
# because "all the programs" is this repository's job and someone may disagree.
WITH_E2SCRUB ?= 0

# The headers, static libraries and pkg-config files (libext2fs, libcom_err,
# libe2p, libss, libblkid, libuuid). Off by default - this is the runtime
# package - but the card carries clang from ../llvm and make from ../make, so
# there is a real reason to want them there, which is why it is a flag rather
# than a deletion.
WITH_DEVEL ?= 0

# Man pages. Off because nothing on the card reads them: busybox's `man` is a
# shell script wrapper around a pager that SepiaOS does not install either.
WITH_MANPAGES ?= 0

# Measured on 1.47.4: the unstripped tree is 4.9 MiB, stripped 3.3 MiB. There
# is no debugger on the device to want the symbols.
WITH_STRIP ?= 1

# --disable-nls keeps gettext out of a userland that is musl and busybox and
# has no locale data. --disable-fuse2fs drops the one program that needs a
# library the card does not have (libfuse); everything else upstream can build
# is built. --enable-fsck adds the fsck wrapper, which is off by default
# upstream because most distributions take util-linux's instead - SepiaOS has
# no util-linux, so this is the only fsck there would be.
#
# --enable-libuuid and --enable-libblkid ask for e2fsprogs' own copies rather
# than letting configure decide from what it finds in the sysroot: the answer
# would then depend on what happens to be in build/sysroot, and the sysroot is
# musl and nothing else.
#
# --without-udev-rules-dir, --without-crond-dir and --without-systemd-unit-dir
# are not about e2scrub being off. Left to themselves they probe the *build
# host* - pkg-config for udev, /etc/cron.d for cron - so a Debian container
# would install crontabs and udev rules that a macOS box would not, and the two
# release assets would differ by build host. Answered here instead.
#
# --disable-backtrace because musl has no execinfo.h, and --disable-rpath
# because a DT_RUNPATH pointing at the build machine's sysroot is nonsense on
# the card.
#
# --disable-subset does not disable anything. It is the *only* use of
# SUBSET_CMT in the whole tree, and all it comments out is the
# `$(MAKE) install-libs` line at the end of the top-level install target. Left
# alone - the flag is neither given nor defaulted to "no" by configure - a
# plain `make install` therefore also installs the headers, the six static
# libraries, the .pc files and compile_et/mk_cmds. That is what WITH_DEVEL is
# for, so it is turned off here and turned back on by calling install-libs.
#
# --enable-symlink-install is the one flag here that is about *this* build
# rather than about the card. mke2fs is installed once and then linked to
# mkfs.ext2, mkfs.ext3, mkfs.ext4; e2fsck to fsck.ext2, fsck.ext3, fsck.ext4;
# tune2fs to e2label and findfs; dumpe2fs to e2mmpstatus. Upstream's default is
# `ln -f` - hard links - and binutils `strip` does not edit in place: it writes
# a temporary file and renames it over the original, which *breaks* the link
# and leaves four separate 400 KB copies of e2fsck where there was one. This
# turns them into `ln -sf` symlinks, which strip cannot break, tar records as
# symlinks, and which resolve inside the staged tree as well as on the device
# because the link target is a bare name in the same directory.
CONFIGURE_FLAGS ?= --host=$(TARGET_TRIPLE) --prefix=$(PREFIX) \
                   --with-root-prefix='$(ROOT_PREFIX)' \
                   --disable-nls --disable-fuse2fs --enable-fsck \
                   --enable-libuuid --enable-libblkid \
                   --disable-backtrace --disable-rpath \
                   --disable-subset --enable-symlink-install \
                   --without-udev-rules-dir --without-crond-dir \
                   --without-systemd-unit-dir

# ---------------------------------------------------------------------------
# Cross-toolchain
#
# The musl-*targeting* toolchain, which is the whole point: these binaries have
# to link against the libc that is actually on the card. ../rootfs deliberately
# takes the *gnu* variant of the same release, because it builds musl from
# source and a baked-in musl would make that step a no-op - do not follow it
# here.
#
# Two vendors, because no single one publishes a musl-targeting aarch64
# toolchain for both hosts: messense publishes darwin-hosted builds only,
# bootlin (Buildroot) publishes Linux-hosted x86_64 builds only. So macOS is
# the development host and Linux is the release host, matching ../rootfs,
# ../llvm and ../make. TARGET_TRIPLE above is what keeps the product identical
# either way.
# ---------------------------------------------------------------------------

ifeq ($(HOST_OS),Darwin)
  TC_VENDOR      := messense
  TC_VERSION_DEF := 15.2.0
  TC_PREFIX      := aarch64-unknown-linux-musl-
  ifeq ($(HOST_ARCH),arm64)
    TC_HOST := aarch64-darwin
  else ifeq ($(HOST_ARCH),x86_64)
    TC_HOST := x86_64-darwin
  endif
  TC_ARCHIVE  = aarch64-unknown-linux-musl-$(TC_HOST).tar.gz
  TC_BASE    := https://github.com/messense/homebrew-macos-cross-toolchains/releases/download
  TC_URL      = $(TC_BASE)/v$(TC_VERSION)/$(TC_ARCHIVE)
  TC_SUMS     = $(TC_ARCHIVE).sha256
  TC_SUMS_URL = $(TC_URL).sha256
else ifeq ($(HOST_OS),Linux)
  TC_VENDOR      := bootlin
  TC_VERSION_DEF := 2025.08-1
  # bootlin names its tools aarch64-linux-*, not after the full triple.
  TC_PREFIX      := aarch64-linux-
  ifeq ($(HOST_ARCH),x86_64)
    TC_HOST := x86_64
  endif
  TC_ARCHIVE  = aarch64--musl--stable-$(TC_VERSION).tar.xz
  TC_BASE    := https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs
  TC_URL      = $(TC_BASE)/$(TC_ARCHIVE)
  TC_SUMS     = aarch64--musl--stable-$(TC_VERSION).sha256
  TC_SUMS_URL = $(TC_BASE)/$(TC_SUMS)
endif

TC_VERSION ?= $(TC_VERSION_DEF)

# Point this at a musl cross-toolchain you already have and nothing is
# downloaded - the escape hatch for a host neither vendor covers, and the way
# to build against a sibling's already-extracted toolchain.
CROSS_COMPILE ?=

DL_TC     := $(DL_DIR)/toolchain
TC_DIR     = $(DL_TC)/$(TC_VENDOR)-$(TC_VERSION)-$(TC_HOST)
TC_STAMP   = $(TC_DIR)/.extracted
CROSS      = $(or $(CROSS_COMPILE),$(abspath $(TC_DIR))/bin/$(TC_PREFIX))
TOOLCHAIN_DEP = $(if $(CROSS_COMPILE),,$(TC_STAMP))

TC_GOALS := toolchain toolchain-info toolchain-check sysroot sysroot-info \
            sysroot-check e2fsprogs build-info stage stage-check stage-info dist
ifneq ($(filter $(TC_GOALS),$(MAKECMDGOALS)),)
  ifeq ($(CROSS_COMPILE),)
    ifeq ($(TC_HOST),)
      $(error No prebuilt musl-targeting aarch64 toolchain is published for $(HOST_OS)/$(HOST_ARCH) (macOS: messense, Linux/x86_64: bootlin). Set CROSS_COMPILE to one you have)
    endif
  endif
endif

# e2fsprogs is one of the packages that needs a compiler for the *build*
# machine as well as one for the target, and it is not optional: util/subst is
# compiled and then run to generate config files, lib/ext2fs generates its
# CRC32c table with a program it compiles and runs, and configure itself runs
# util/parse-types.sh through BUILD_CC. ../make needs no host compiler at all,
# so its CI installs none - do not copy that package list here.
BUILD_CC ?= cc

define assert_build_cc
	command -v $(BUILD_CC) >/dev/null 2>&1 || { \
	  echo "  FAIL     no host compiler ($(BUILD_CC)). e2fsprogs compiles and runs" >&2; \
	  echo "           helper programs on the build machine, so one is required." >&2; \
	  echo "           macOS: xcode-select --install. Debian: apt-get install gcc." >&2; \
	  echo "           Or set BUILD_CC to the host compiler you have." >&2; \
	  exit 1; }
endef

# ---------------------------------------------------------------------------
# Step 1 - the cross-toolchain
# ---------------------------------------------------------------------------

.PHONY: toolchain
toolchain: $(TOOLCHAIN_DEP) ## Fetch the musl-targeting aarch64 cross-compiler
	@$(call assert_cross_compiler)
	@echo "  READY    $(if $(CROSS_COMPILE),CROSS_COMPILE -> $(CROSS)gcc,$(TC_VENDOR) $(TC_VERSION) -> $(TC_DIR))"

# Nothing under $(TC_DIR) is a prerequisite: release archives are immutable, so
# once a version is unpacked it is never unpacked again. Change TC_VERSION and
# the path changes with it.
$(TC_STAMP):
	@command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
	@mkdir -p $(DL_TC)
	@if [ ! -f $(DL_TC)/$(TC_ARCHIVE) ]; then \
	   echo "  FETCH    $(TC_ARCHIVE) (78 MiB bootlin, 132 MiB messense)"; \
	   $(CURL) -o $(DL_TC)/$(TC_ARCHIVE).part "$(TC_URL)"; \
	   mv -f $(DL_TC)/$(TC_ARCHIVE).part $(DL_TC)/$(TC_ARCHIVE); \
	 fi
	@if [ ! -f $(DL_TC)/$(TC_SUMS) ]; then \
	   $(CURL) -o $(DL_TC)/$(TC_SUMS).part "$(TC_SUMS_URL)"; \
	   mv -f $(DL_TC)/$(TC_SUMS).part $(DL_TC)/$(TC_SUMS); \
	 fi
	@echo "  VERIFY   $(TC_ARCHIVE)"
	@( cd $(DL_TC) && $(SHA256) --check --quiet $(TC_SUMS) ) || { \
	   echo "  FAIL     $(TC_ARCHIVE) does not match upstream's digest; delete $(DL_TC) and retry" >&2; \
	   exit 1; }
	@echo "  UNPACK   $(TC_ARCHIVE) -> $(TC_DIR)"
	@rm -rf $(TC_DIR)
	@mkdir -p $(TC_DIR)
	@tar -xf $(DL_TC)/$(TC_ARCHIVE) -C $(TC_DIR) --strip-components=1
	@touch $@
	@$(call assert_cross_compiler)

# A cross-compiler for the wrong host arch extracts happily and then fails to
# exec; one for the wrong target compiles happily and produces the wrong
# binaries. -dumpmachine catches both in one cheap call - and here it must say
# musl, because a gnu toolchain would link these programs against glibc.
define assert_cross_compiler
	command -v $(CROSS)gcc >/dev/null 2>&1 || { \
	  echo "  FAIL     no $(CROSS)gcc" >&2; exit 1; }; \
	m=$$($(CROSS)gcc -dumpmachine) || { \
	  echo "  FAIL     $(CROSS)gcc will not run on $(HOST_OS)/$(HOST_ARCH)" >&2; exit 1; }; \
	case "$$m" in \
	  aarch64-*linux-musl*) ;; \
	  aarch64-*linux*) echo "  FAIL     $(CROSS)gcc targets $$m - that is a gnu toolchain, so it would link e2fsprogs against glibc" >&2; exit 1;; \
	  *) echo "  FAIL     $(CROSS)gcc targets $$m, not aarch64 linux musl" >&2; exit 1;; \
	esac
endef

.PHONY: toolchain-info
toolchain-info: $(TOOLCHAIN_DEP) ## Show the cross-compiler in use
	@echo "  host     $(HOST_OS) $(HOST_ARCH)"
	@echo "  source   $(if $(CROSS_COMPILE),CROSS_COMPILE override,$(TC_VENDOR) $(TC_VERSION))"
	@echo "  prefix   $(CROSS)"
	@echo "  target   $$($(CROSS)gcc -dumpmachine)"
	@$(CROSS)gcc --version | sed -n '1s/^/  gcc      /p'
	@$(CROSS)ld --version | sed -n '1s/^/  ld       /p'
	@echo "  sysroot  $$($(CROSS)gcc -print-sysroot)"
	@echo "  build cc $(BUILD_CC) ($$($(BUILD_CC) --version 2>/dev/null | sed -n 1p))"

TC_CHECK_DIR := $(BUILD_DIR)/toolchain-check

# e2fsprogs is C, so this only has to prove C - but it proves it dynamically
# *and* statically, because a toolchain that can only do one of them fails much
# later, in the middle of a build. The host compiler is checked here too: it is
# needed before the first object is compiled, and finding that out from a
# missing util/subst two minutes in is a worse error message.
.PHONY: toolchain-check
toolchain-check: $(TOOLCHAIN_DEP) ## Prove the cross-compiler builds C against musl
	@$(call assert_cross_compiler)
	@$(call assert_build_cc)
	@mkdir -p $(TC_CHECK_DIR)
	@printf '%s\n' \
	  '#include <stdio.h>' \
	  '#include <stdlib.h>' \
	  'int main(void) { printf("sepiaos\n"); return EXIT_SUCCESS; }' \
	  > $(TC_CHECK_DIR)/t.c
	@$(CROSS)gcc -O2 -o $(TC_CHECK_DIR)/t.dyn $(TC_CHECK_DIR)/t.c \
	  || { echo "  FAIL     C does not compile for musl dynamically" >&2; exit 1; }
	@echo "  OK       dynamic  $$($(CROSS)readelf -d $(TC_CHECK_DIR)/t.dyn | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
	@$(CROSS)gcc -O2 -static -o $(TC_CHECK_DIR)/t.static $(TC_CHECK_DIR)/t.c \
	  || { echo "  FAIL     C does not link statically against musl" >&2; exit 1; }
	@echo "  OK       static   $$(wc -c < $(TC_CHECK_DIR)/t.static | tr -d ' ') bytes"
	@$(BUILD_CC) -O2 -o $(TC_CHECK_DIR)/t.host $(TC_CHECK_DIR)/t.c \
	  || { echo "  FAIL     $(BUILD_CC) does not build a host program" >&2; exit 1; }
	@$(TC_CHECK_DIR)/t.host > /dev/null \
	  || { echo "  FAIL     a program built by $(BUILD_CC) does not run here" >&2; exit 1; }
	@echo "  OK       host     $(BUILD_CC) builds and runs a program on this machine"
	@echo "  READY    $(if $(CROSS_COMPILE),CROSS_COMPILE,$(TC_VENDOR) $(TC_VERSION)) builds C against musl"

# ---------------------------------------------------------------------------
# Step 2 - the target sysroot
#
# musl is built here rather than read out of ../rootfs/build/sysroot: sibling
# repositories consume each other's *published releases*, never each other's
# build trees, which is what keeps each of them buildable alone and in CI.
#
# The version is pinned to whatever rootfs ships, because these binaries are
# dynamically linked and have to run against the musl that is on the device.
#
#   CAUTION: rootfs resolves musl as "latest" by default, so it can move out
#   from under this pin, and ../llvm and ../make pin the same version for the
#   same reason. When rootfs moves, move all three.
#
# The cross-toolchain has musl 1.2.5 baked into its own sysroot, which is not
# what ships, so --sysroot points at this tree instead.
# ---------------------------------------------------------------------------

MUSL_VERSION ?= 1.2.6
MUSL_BASE    := https://musl.libc.org/releases
MUSL_ARCHIVE  = musl-$(MUSL_VERSION).tar.gz
MUSL_URL      = $(MUSL_BASE)/$(MUSL_ARCHIVE)
MUSL_SUMS     = $(CHECKSUMS)/musl-$(MUSL_VERSION).sha256

DL_MUSL    := $(DL_DIR)/musl
MUSL_DIR   := $(BUILD_DIR)/musl
MUSL_SRC    = $(MUSL_DIR)/musl-$(MUSL_VERSION)
MUSL_STAMP  = $(MUSL_DIR)/.installed
SYSROOT    := $(BUILD_DIR)/sysroot

MUSL_CFG := $(MUSL_DIR)/.config
MUSL_SIG  = $(MUSL_VERSION)|$(TC_VENDOR)|$(TC_VERSION)|$(CROSS_COMPILE)
$(eval $(call config_stamp_rule,$(MUSL_CFG),$(MUSL_SIG)))

.PHONY: sysroot
sysroot: $(MUSL_STAMP) ## Build the musl sysroot the target binaries link against
	@echo "  READY    musl $(MUSL_VERSION) -> $(SYSROOT)"

# configure and make are noisy and only interesting when they fail, so the
# output goes to a log and the tail of it is what surfaces on an error.
$(MUSL_STAMP): $(TOOLCHAIN_DEP) $(MUSL_CFG) Makefile
	@$(call assert_cross_compiler)
	@mkdir -p $(DL_MUSL) $(MUSL_DIR) $(CHECKSUMS)
	@if [ ! -f $(DL_MUSL)/$(MUSL_ARCHIVE) ]; then \
	   echo "  FETCH    $(MUSL_ARCHIVE)"; \
	   $(CURL) -o $(DL_MUSL)/$(MUSL_ARCHIVE).part "$(MUSL_URL)"; \
	   mv -f $(DL_MUSL)/$(MUSL_ARCHIVE).part $(DL_MUSL)/$(MUSL_ARCHIVE); \
	 fi
	@if [ -f $(MUSL_SUMS) ]; then \
	   echo "  VERIFY   $(MUSL_ARCHIVE)"; \
	   ( cd $(DL_MUSL) && $(SHA256) --check --quiet $(abspath $(MUSL_SUMS)) ) || { \
	     echo "  FAIL     $(MUSL_ARCHIVE) does not match $(MUSL_SUMS)" >&2; exit 1; }; \
	 else \
	   ( cd $(DL_MUSL) && $(SHA256) $(MUSL_ARCHIVE) ) > $(MUSL_SUMS); \
	   echo "  RECORD   $(MUSL_SUMS) - first fetch of this version, commit it"; \
	 fi
	@echo "  UNPACK   $(MUSL_ARCHIVE)"
	@rm -rf $(MUSL_SRC)
	@tar -xf $(DL_MUSL)/$(MUSL_ARCHIVE) -C $(MUSL_DIR)
	@echo "  CONFIG   musl $(MUSL_VERSION) (static + shared)"
	@( cd $(MUSL_SRC) && $(SCRUB_ENV) ./configure --prefix=/usr --syslibdir=/lib \
	       --enable-static --enable-shared --disable-wrapper \
	       CROSS_COMPILE=$(CROSS) ) > $(MUSL_SRC)/configure.log 2>&1 || { \
	   tail -20 $(MUSL_SRC)/configure.log >&2; \
	   echo "  FAIL     configure (full log: $(MUSL_SRC)/configure.log)" >&2; exit 1; }
	@echo "  BUILD    musl $(MUSL_VERSION) (-j$(JOBS))"
	@$(MAKE) --no-print-directory -C $(MUSL_SRC) -j$(JOBS) > $(MUSL_SRC)/build.log 2>&1 || { \
	   tail -30 $(MUSL_SRC)/build.log >&2; \
	   echo "  FAIL     build (full log: $(MUSL_SRC)/build.log)" >&2; exit 1; }
	@echo "  INSTALL  -> $(SYSROOT)"
	@rm -rf $(SYSROOT)/usr/include $(SYSROOT)/usr/lib $(SYSROOT)/lib/ld-musl-*
	@mkdir -p $(SYSROOT)
	@$(MAKE) --no-print-directory -C $(MUSL_SRC) install DESTDIR=$(abspath $(SYSROOT)) \
	   >> $(MUSL_SRC)/build.log 2>&1 || { \
	   tail -30 $(MUSL_SRC)/build.log >&2; \
	   echo "  FAIL     install (full log: $(MUSL_SRC)/build.log)" >&2; exit 1; }
	@$(call install_uapi_headers)
	@touch $@

# musl installs libc headers and nothing else, which is not a usable sysroot:
# anything that talks to the kernel needs the Linux UAPI headers too, and
# e2fsprogs needs more of them than most - linux/fs.h, linux/fiemap.h,
# linux/falloc.h, linux/fsmap.h, linux/loop.h and linux/blkzoned.h are all
# reached by the programs built here. They come from the cross-toolchain's own
# sysroot rather than being downloaded, so this costs nothing and cannot drift
# from the compiler. Same approach as ../rootfs, ../llvm and ../make.
define install_uapi_headers
	set -e; \
	k=$$($(CROSS)gcc -print-sysroot)/usr/include; \
	[ -d "$$k" ] || { echo "  FAIL     $(CROSS)gcc has no sysroot to take UAPI headers from" >&2; exit 1; }; \
	i=$(abspath $(SYSROOT))/usr/include; mkdir -p "$$i"; \
	for d in linux asm asm-generic mtd rdma sound video drm misc scsi xen; do \
	  if [ -d "$$k/$$d" ]; then rm -rf "$$i/$$d"; cp -R "$$k/$$d" "$$i/$$d"; fi; \
	done; \
	[ -f $(abspath $(SYSROOT))/usr/include/linux/fiemap.h ] \
	  || { echo "  FAIL     no Linux UAPI headers landed in $(SYSROOT)" >&2; exit 1; }
endef

# musl stamps its version into libc.so as a bare "1.2.6" line. Read in two
# steps rather than one pipeline: under `set -o pipefail` a `grep -m1` exits
# early, SIGPIPEs its producer and fails the pipeline *after* printing the
# answer, so a trailing `|| echo unknown` fires too and both lines appear.
# `strings` is not available (binutils is absent from debian:trixie-slim) and
# BSD `tr` cannot read NUL bytes, so `grep -a -o` is the portable probe.
define musl_version_of
$(shell LC_ALL=C grep -a -o -E '1\.[0-9]+\.[0-9]+' $(1) 2>/dev/null | sed -n '1p')
endef

.PHONY: sysroot-info
sysroot-info: $(MUSL_STAMP) ## Show the sysroot's musl version and layout
	@echo "  sysroot  $(SYSROOT)"
	@echo "  pinned   $(MUSL_VERSION)"
	@v='$(call musl_version_of,$(SYSROOT)/usr/lib/libc.so)'; \
	 if [ -z "$$v" ]; then \
	   echo "  built    unknown - could not read a version out of libc.so"; \
	 elif [ "$$v" != "$(MUSL_VERSION)" ]; then \
	   echo "  FAIL     the sysroot holds $$v, not the pinned $(MUSL_VERSION)" >&2; exit 1; \
	 else \
	   echo "  built    $$v"; \
	 fi
	@ls -l $(SYSROOT)/lib/ld-musl-aarch64.so.1 | sed 's/^/  loader   /'

.PHONY: sysroot-check
sysroot-check: $(MUSL_STAMP) ## Prove C links dynamically against this sysroot
	@mkdir -p $(TC_CHECK_DIR)
	@printf '%s\n' \
	  '#include <stdio.h>' \
	  'int main(void) { printf("sepiaos\n"); return 0; }' > $(TC_CHECK_DIR)/s.c
	@$(CROSS)gcc --sysroot=$(abspath $(SYSROOT)) -O2 -o $(TC_CHECK_DIR)/s.dyn $(TC_CHECK_DIR)/s.c \
	  || { echo "  FAIL     C does not link dynamically against $(SYSROOT)" >&2; exit 1; }
	@$(call assert_target_elf,$(TC_CHECK_DIR)/s.dyn,the test binary)
	@echo "  READY    C links dynamically against musl $(MUSL_VERSION)"

# ---------------------------------------------------------------------------
# Step 3 - the e2fsprogs sources
#
# kernel.org publishes a `sha256sums.asc` beside each release whose digest
# lines are already in `sha256sum --check` format, so - unlike ../make, which
# has to record its own digest because GNU publishes only a GPG signature -
# the tarball is checked against upstream's own file. The digest is *also*
# recorded under checksums/ and committed, so the pin means something without
# a network and a rewritten upstream file cannot pass silently.
# ---------------------------------------------------------------------------

E2FS_ARCHIVE  = e2fsprogs-$(E2FSPROGS_VERSION).tar.gz
E2FS_URL      = $(E2FS_BASE)/v$(E2FSPROGS_VERSION)/$(E2FS_ARCHIVE)
E2FS_ASC_URL  = $(E2FS_BASE)/v$(E2FSPROGS_VERSION)/sha256sums.asc
E2FS_SUMS     = $(CHECKSUMS)/e2fsprogs-$(E2FSPROGS_VERSION).sha256

DL_SRC     := $(DL_DIR)/e2fsprogs
# Unpacked under build/, not downloads/: the tarball in downloads/ is the
# immutable thing and re-unpacking from it costs a second. The build itself is
# out-of-tree, so nothing writes into this directory after it is unpacked.
SRC_DIR    := $(BUILD_DIR)/src
E2FS_SRC    = $(SRC_DIR)/e2fsprogs-$(E2FSPROGS_VERSION)
SRC_STAMP   = $(E2FS_SRC)/.unpacked

.PHONY: sources
sources: $(SRC_STAMP) ## Download, verify and unpack the e2fsprogs sources
	@echo "  READY    e2fsprogs $(E2FSPROGS_VERSION) -> $(E2FS_SRC)"

$(SRC_STAMP):
	@command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
	@mkdir -p $(DL_SRC) $(SRC_DIR) $(CHECKSUMS)
	@if [ ! -f $(DL_SRC)/$(E2FS_ARCHIVE) ]; then \
	   echo "  FETCH    $(E2FS_ARCHIVE)"; \
	   $(CURL) -o $(DL_SRC)/$(E2FS_ARCHIVE).part "$(E2FS_URL)"; \
	   mv -f $(DL_SRC)/$(E2FS_ARCHIVE).part $(DL_SRC)/$(E2FS_ARCHIVE); \
	 fi
	@if [ ! -f $(DL_SRC)/sha256sums-$(E2FSPROGS_VERSION).asc ]; then \
	   $(CURL) -o $(DL_SRC)/sha256sums-$(E2FSPROGS_VERSION).asc.part "$(E2FS_ASC_URL)" || { \
	     echo "  FAIL     no upstream digests for $(E2FS_ARCHIVE) - refusing an unverifiable tarball" >&2; \
	     exit 1; }; \
	   mv -f $(DL_SRC)/sha256sums-$(E2FSPROGS_VERSION).asc.part $(DL_SRC)/sha256sums-$(E2FSPROGS_VERSION).asc; \
	 fi
	@echo "  VERIFY   $(E2FS_ARCHIVE) against upstream's sha256sums.asc"
	@( cd $(DL_SRC) && grep -F "  $(E2FS_ARCHIVE)" sha256sums-$(E2FSPROGS_VERSION).asc \
	     | $(SHA256) --check --quiet - ) || { \
	   echo "  FAIL     $(E2FS_ARCHIVE) does not match upstream's digest; delete $(DL_SRC) and retry" >&2; \
	   exit 1; }
	@if [ -f $(E2FS_SUMS) ]; then \
	   echo "  VERIFY   $(E2FS_ARCHIVE) against $(E2FS_SUMS)"; \
	   ( cd $(DL_SRC) && $(SHA256) --check --quiet $(abspath $(E2FS_SUMS)) ) || { \
	     echo "  FAIL     $(E2FS_ARCHIVE) does not match the committed pin $(E2FS_SUMS)" >&2; exit 1; }; \
	 else \
	   ( cd $(DL_SRC) && $(SHA256) $(E2FS_ARCHIVE) ) > $(E2FS_SUMS); \
	   echo "  RECORD   $(E2FS_SUMS) - first fetch of this version, commit it"; \
	 fi
	@echo "  UNPACK   $(E2FS_ARCHIVE) -> $(E2FS_SRC)"
	@rm -rf $(E2FS_SRC)
	@mkdir -p $(E2FS_SRC)
	@tar -xf $(DL_SRC)/$(E2FS_ARCHIVE) -C $(E2FS_SRC) --strip-components=1
	@$(call assert_source_version)
	@touch $@

# The unpacked tree has to be the version that was pinned. A mismatch means the
# tarball, the digest and E2FSPROGS_VERSION disagree, and everything after this
# would build something other than what the manifest claims. version.h is the
# file the programs themselves print from, so it is the one to ask.
define assert_source_version
	set -e; \
	v=$$(sed -n 's/^#define E2FSPROGS_VERSION[ 	]*"\(.*\)"/\1/p' $(E2FS_SRC)/version.h | sed -n '1p'); \
	[ -n "$$v" ] || { echo "  FAIL     no E2FSPROGS_VERSION in $(E2FS_SRC)/version.h" >&2; exit 1; }; \
	[ "$$v" = "$(E2FSPROGS_VERSION)" ] || { \
	  echo "  FAIL     the tree declares $$v but E2FSPROGS_VERSION is $(E2FSPROGS_VERSION)" >&2; exit 1; }; \
	[ -x $(E2FS_SRC)/configure ] || { \
	  echo "  FAIL     no executable configure in the tree" >&2; exit 1; }
endef

.PHONY: sources-info
sources-info: $(SRC_STAMP) ## Show the source version and where it came from
	@echo "  version  $(E2FSPROGS_VERSION)"
	@echo "  archive  $(DL_SRC)/$(E2FS_ARCHIVE)"
	@echo "  source   $(E2FS_SRC)"
	@echo "  size     $$(du -sh $(E2FS_SRC) | cut -f1)"
	@sed -n 's/^#define E2FSPROGS_DATE[ 	]*"\(.*\)"/  released \1/p' $(E2FS_SRC)/version.h
	@sed 's/^/  sha256   /' $(E2FS_SUMS)

.PHONY: verify-downloads
verify-downloads: ## Check the sources against the recorded digest
	@test -f $(E2FS_SUMS) || { echo "No $(E2FS_SUMS); run 'make sources' first." >&2; exit 1; }
	@( cd $(DL_SRC) && $(SHA256) --check --quiet $(abspath $(E2FS_SUMS)) )
	@echo "  OK       $(E2FS_SUMS)"
	@test -f $(MUSL_SUMS) || { echo "No $(MUSL_SUMS); run 'make sysroot' first." >&2; exit 1; }
	@( cd $(DL_MUSL) && $(SHA256) --check --quiet $(abspath $(MUSL_SUMS)) )
	@echo "  OK       $(MUSL_SUMS)"

# ---------------------------------------------------------------------------
# Step 4 - configure and build
#
# Out of tree, in build/target: the source tree stays exactly as it was
# unpacked, so `clean` can drop the build without re-fetching, and a
# half-finished configure cannot leave the sources in a state the next one
# inherits. ../rootfs builds e2fsprogs out of tree for the same reason.
#
# CC, AR, RANLIB and STRIP are passed explicitly rather than left to autoconf's
# --host search. Autoconf would look for $(TARGET_TRIPLE)-ar on PATH, which is
# not there (the toolchain lives under downloads/) and is not even the right
# name on Linux, where bootlin calls its tools aarch64-linux-*. It would then
# silently fall back to the *host's* ar and produce an archive the aarch64 link
# cannot use.
#
# BUILD_CC is passed for the opposite reason: it must be the *host's* compiler,
# and configure would otherwise take the first `gcc` or `cc` it finds on PATH,
# which is the right answer only by luck.
#
# `progs`, not `all`: `all` also descends into tests/progs and tests/fuzz.
# Those are test harnesses, upstream installs none of them, and - as ../rootfs
# records - several of them do not cross-link at all. PROG_SUBDIRS is
# overridden on the command line rather than patched, and the same override is
# given to `install` so the two agree about what exists.
# ---------------------------------------------------------------------------

TARGET_CFLAGS  ?= -O2 --sysroot=$(abspath $(SYSROOT))
TARGET_LDFLAGS ?= --sysroot=$(abspath $(SYSROOT))

OBJ_DIR     := $(BUILD_DIR)/target
BUILD_STAMP  = $(OBJ_DIR)/.built
CONFIG_LOG   = $(OBJ_DIR)/configure.log
BUILD_LOG    = $(OBJ_DIR)/build.log

E2FS_PROG_SUBDIRS = e2fsck debugfs misc resize $(if $(filter 1,$(WITH_E2SCRUB)),scrub)

BUILD_CFG := $(BUILD_DIR)/.config
BUILD_SIG  = $(E2FSPROGS_VERSION)|$(TARGET_TRIPLE)|$(PREFIX)|$(ROOT_PREFIX)|$(CONFIGURE_FLAGS)|$(TARGET_CFLAGS)|$(TARGET_LDFLAGS)|$(MUSL_VERSION)|$(TC_VENDOR)|$(TC_VERSION)|$(CROSS_COMPILE)|$(BUILD_CC)|$(WITH_E2SCRUB)
$(eval $(call config_stamp_rule,$(BUILD_CFG),$(BUILD_SIG)))

.PHONY: e2fsprogs
e2fsprogs: $(BUILD_STAMP) ## Cross-build the e2fsprogs programs for the target
	@echo "  READY    e2fsprogs $(E2FSPROGS_VERSION) -> $(OBJ_DIR)"

# The build directory is wiped first. config.cache and the generated Makefiles
# hold the *previous* configuration, and a reconfigure on top of them is how a
# changed CONFIGURE_FLAGS silently produces the old package.
$(BUILD_STAMP): $(SRC_STAMP) $(MUSL_STAMP) $(BUILD_CFG) Makefile
	@$(call assert_cross_compiler)
	@$(call assert_build_cc)
	@rm -rf $(OBJ_DIR)
	@mkdir -p $(OBJ_DIR)
	@echo "  CONFIG   e2fsprogs $(E2FSPROGS_VERSION) for $(TARGET_TRIPLE)"
	@( cd $(OBJ_DIR) && $(SCRUB_ENV) $(abspath $(E2FS_SRC))/configure $(CONFIGURE_FLAGS) \
	       CC="$(CROSS)gcc" AR="$(CROSS)ar" RANLIB="$(CROSS)ranlib" \
	       STRIP="$(CROSS)strip" BUILD_CC="$(BUILD_CC)" \
	       CFLAGS="$(TARGET_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)" ) \
	     > $(CONFIG_LOG) 2>&1 || { \
	   tail -30 $(CONFIG_LOG) >&2; \
	   echo "  FAIL     configure (full log: $(CONFIG_LOG))" >&2; exit 1; }
	@echo "  BUILD    $(words $(E2FS_PROG_SUBDIRS)) program directories (-j$(JOBS))"
	@$(MAKE) --no-print-directory -C $(OBJ_DIR) -j$(JOBS) \
	     PROG_SUBDIRS='$(E2FS_PROG_SUBDIRS)' progs > $(BUILD_LOG) 2>&1 || { \
	   tail -30 $(BUILD_LOG) >&2; \
	   echo "  FAIL     build (full log: $(BUILD_LOG))" >&2; exit 1; }
	@$(call assert_built_programs)
	@touch $@

# A cross-build succeeds just as happily having produced binaries for the build
# host, and nothing downstream would notice until the card did. The four named
# here are the ones the system cannot boot or be maintained without, so if any
# of them is missing the build did not do what it claims.
define assert_built_programs
	set -e; \
	for p in misc/mke2fs e2fsck/e2fsck resize/resize2fs debugfs/debugfs misc/tune2fs; do \
	  [ -f $(OBJ_DIR)/$$p ] || { \
	    echo "  FAIL     $$p was not built" >&2; exit 1; }; \
	done
endef

# $(1) file, $(2) what to call it in a message
define assert_target_elf
	set -e; \
	$(CROSS)readelf -h $(1) | grep -q AArch64 \
	  || { echo "  FAIL     $(2) is not aarch64" >&2; exit 1; }; \
	$(CROSS)readelf -l $(1) | grep -q 'ld-musl-aarch64.so.1' \
	  || { echo "  FAIL     $(2) does not use the musl loader - is it static?" >&2; exit 1; }; \
	echo "  OK       $(2): aarch64, musl loader, needs $$($(CROSS)readelf -d $(1) | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
endef

.PHONY: build-info
build-info: $(BUILD_STAMP) ## Show the built programs and what they need
	@echo "  build    $(OBJ_DIR)"
	@echo "  version  $(E2FSPROGS_VERSION)"
	@echo "  programs $$(find $(OBJ_DIR) -type f -perm -u+x ! -name '*.sh' ! -name 'config.status' | wc -l | tr -d ' ') executables built"
	@echo "  machine  $$($(CROSS)readelf -h $(OBJ_DIR)/misc/mke2fs | sed -n 's/ *Machine: *//p')"
	@echo "  loader   $$($(CROSS)readelf -l $(OBJ_DIR)/misc/mke2fs | sed -n 's/.*program interpreter: \(.*\)\]/\1/p')"
	@echo "  needs    $$($(CROSS)readelf -d $(OBJ_DIR)/misc/mke2fs | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
	@echo "  mke2fs   $$(wc -c < $(OBJ_DIR)/misc/mke2fs | tr -d ' ') bytes (unstripped)"

# ---------------------------------------------------------------------------
# Step 5 - stage the install tree
#
# Upstream's own `make install` under DESTDIR, so the layout is upstream's and
# not a list of files this repository would have to keep in step with a new
# release. Nothing is written outside build/.
#
# What upstream's install does *not* put in the tree by default is its headers
# and static libraries: the top-level install target reaches the libraries
# through install-shlibs, which is an empty rule unless ELF shared libraries
# were built. `make install-libs` is the target that installs them, so
# WITH_DEVEL is one extra call rather than a prune.
#
# The libraries are static on purpose - no --enable-elf-shlibs. Every program
# then carries the parts of libext2fs it uses and depends on musl alone, which
# is the invariant the siblings hold to and the one thing that cannot be got
# wrong later: a card missing one .so is a card where nothing in this package
# runs at all. The cost is ~3.3 MiB stripped for the whole toolset.
#
# NOTICE and lib/uuid/COPYING travel with it: e2fsprogs is GPLv2 with LGPLv2,
# MIT and BSD-licensed libraries, and this ships binaries of all of it.
# ---------------------------------------------------------------------------

STAGE_DIR   := $(BUILD_DIR)/stage
STAGE_STAMP  = $(STAGE_DIR)/.staged
LICENSE_DIR  = $(STAGE_DIR)$(PREFIX)/share/licenses/e2fsprogs

STAGE_CFG := $(STAGE_DIR)/.config
STAGE_SIG  = $(PREFIX)|$(ROOT_PREFIX)|$(WITH_STRIP)|$(WITH_MANPAGES)|$(WITH_DEVEL)|$(WITH_E2SCRUB)|$(E2FSPROGS_VERSION)
$(eval $(call config_stamp_rule,$(STAGE_CFG),$(STAGE_SIG)))

.PHONY: stage
stage: $(STAGE_STAMP) ## Install the programs into a staged tree
	@echo "  READY    staged $$(du -sh $(STAGE_DIR) | cut -f1) -> $(STAGE_DIR)"

# The staged tree is wiped and rebuilt rather than updated in place, so a
# renamed or removed file cannot survive into a later build - ../boot rebuilds
# its image for the same reason. $(STAGE_CFG) lives inside it, so it is written
# after the wipe, not before. It also keeps the tree free of the
# `mke2fs.conf.e2fsprogs-new` upstream leaves when it finds an mke2fs.conf it
# did not write.
$(STAGE_STAMP): $(BUILD_STAMP) $(STAGE_CFG)
	@rm -rf $(STAGE_DIR)
	@mkdir -p $(STAGE_DIR)
	@printf '%s\n' '$(STAGE_SIG)' > $(STAGE_CFG)
	@echo "  INSTALL  -> $(STAGE_DIR)"
	@$(MAKE) --no-print-directory -C $(OBJ_DIR) \
	     PROG_SUBDIRS='$(E2FS_PROG_SUBDIRS)' \
	     install DESTDIR=$(abspath $(STAGE_DIR)) >> $(BUILD_LOG) 2>&1 || { \
	   tail -30 $(BUILD_LOG) >&2; \
	   echo "  FAIL     install (full log: $(BUILD_LOG))" >&2; exit 1; }
ifeq ($(WITH_DEVEL),1)
	@echo "  INSTALL  headers, static libraries and pkg-config files"
	@$(MAKE) --no-print-directory -C $(OBJ_DIR) \
	     install-libs DESTDIR=$(abspath $(STAGE_DIR)) >> $(BUILD_LOG) 2>&1 || { \
	   tail -30 $(BUILD_LOG) >&2; \
	   echo "  FAIL     install-libs (full log: $(BUILD_LOG))" >&2; exit 1; }
endif
	@rm -rf $(STAGE_DIR)$(PREFIX)/share/info
ifneq ($(WITH_MANPAGES),1)
	@rm -rf $(STAGE_DIR)$(PREFIX)/share/man
endif
	@mkdir -p $(LICENSE_DIR)
	@cp $(E2FS_SRC)/NOTICE $(LICENSE_DIR)/NOTICE
	@cp $(E2FS_SRC)/lib/uuid/COPYING $(LICENSE_DIR)/COPYING.libuuid
ifeq ($(WITH_STRIP),1)
	@$(call strip_stage)
endif
	@find $(STAGE_DIR) -type d -empty -delete
	@touch $@

# `file` is not in debian:trixie-slim and BSD and GNU `file` word their answers
# differently anyway, so the ELF magic is read directly. Symlinks are skipped
# by -type f, which is what --enable-symlink-install buys: the eight or so
# alternate names are links, so each program is stripped exactly once and no
# link is broken by the rename strip does internally.
define strip_stage
	set -e; \
	n=0; \
	while read -r f; do \
	  case "$$(od -An -N4 -tx1 "$$f" | tr -d ' ')" in \
	    7f454c46) ;; \
	    *) continue;; \
	  esac; \
	  $(CROSS)strip "$$f" || { echo "  FAIL     could not strip $$f" >&2; exit 1; }; \
	  n=$$((n+1)); \
	done < <(find $(STAGE_DIR) -type f); \
	echo "  STRIP    $$n programs"
endef

.PHONY: stage-check
stage-check: $(STAGE_STAMP) ## Verify every staged program is aarch64 and needs only musl
	@$(call assert_stage_elfs)
	@$(call assert_stage_layout)
	@$(call assert_no_libc)
	@echo "  READY    staged tree is self-contained apart from musl"

# The whole point of the linkage choice: these binaries may depend on the
# device's musl and on nothing else. ../llvm learned the hard way that a
# DT_NEEDED nobody checked - libatomic.so.1, recorded without a single symbol
# referenced - kills every program at exec on a card that does not have it.
#
# Every ELF in the tree is read, not a sample: this package installs around
# thirty programs from six source directories, and one of them linking
# differently from the rest is exactly the failure this is for.
define assert_stage_elfs
	set -e; \
	n=0; \
	while read -r f; do \
	  case "$$(od -An -N4 -tx1 "$$f" | tr -d ' ')" in \
	    7f454c46) ;; \
	    *) continue;; \
	  esac; \
	  $(CROSS)readelf -h "$$f" | grep -q AArch64 \
	    || { echo "  FAIL     $$f is not aarch64" >&2; exit 1; }; \
	  $(CROSS)readelf -l "$$f" | grep -q 'ld-musl-aarch64.so.1' \
	    || { echo "  FAIL     $$f does not use the musl loader" >&2; exit 1; }; \
	  bad=""; \
	  for lib in $$($(CROSS)readelf -d "$$f" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do \
	    case "$$lib" in libc.so*) ;; *) bad="$$bad $$lib";; esac; \
	  done; \
	  [ -z "$$bad" ] || { \
	    echo "  FAIL     $$f needs$$bad, which nothing on the card provides" >&2; exit 1; }; \
	  n=$$((n+1)); \
	done < <(find $(STAGE_DIR) -type f); \
	[ "$$n" -gt 20 ] || { \
	  echo "  FAIL     only $$n programs in the staged tree - the install did not run" >&2; exit 1; }; \
	echo "  OK       $$n programs: aarch64, musl loader, musl and nothing else"
endef

# The alternate names are symlinks rather than files, so a check that only
# reads ELFs would not notice them going missing - and `mkfs.ext4` disappearing
# is the kind of regression a card discovers at first boot. mke2fs.conf matters
# for the same reason: without it mke2fs has no filesystem profiles and refuses
# to create anything.
define assert_stage_layout
	set -e; \
	for p in $(ROOT_SBIN)/mke2fs $(ROOT_SBIN)/e2fsck $(ROOT_SBIN)/tune2fs \
	         $(ROOT_SBIN)/resize2fs $(ROOT_SBIN)/dumpe2fs $(ROOT_SBIN)/badblocks \
	         $(ROOT_SBIN)/debugfs $(ROOT_SBIN)/blkid $(ROOT_SBIN)/fsck \
	         $(PREFIX)/sbin/filefrag $(PREFIX)/sbin/uuidd \
	         $(PREFIX)/bin/chattr $(PREFIX)/bin/lsattr $(PREFIX)/bin/uuidgen; do \
	  [ -f $(STAGE_DIR)$$p ] || { echo "  FAIL     $$p is missing from the staged tree" >&2; exit 1; }; \
	done; \
	for l in $(ROOT_SBIN)/mkfs.ext4 $(ROOT_SBIN)/fsck.ext4 $(ROOT_SBIN)/e2label; do \
	  [ -L $(STAGE_DIR)$$l ] || { echo "  FAIL     $$l is not a symlink in the staged tree" >&2; exit 1; }; \
	  [ -f $(STAGE_DIR)$$l ] || { echo "  FAIL     $$l points nowhere" >&2; exit 1; }; \
	done; \
	[ -f $(STAGE_DIR)$(ROOT_ETC)/mke2fs.conf ] || { \
	  echo "  FAIL     $(ROOT_ETC)/mke2fs.conf is missing; mke2fs cannot run without it" >&2; exit 1; }; \
	[ -f $(LICENSE_DIR)/NOTICE ] || { \
	  echo "  FAIL     NOTICE is not staged; this ships GPL binaries" >&2; exit 1; }; \
	echo "  OK       programs, alternate names, mke2fs.conf and the licences are in place"
endef

# musl reaching the asset would be a packaging mistake with a long fuse: it
# would install over rootfs's own libc and its loader, and the mismatch would
# only surface as something odd at runtime on the device.
define assert_no_libc
	set -e; \
	found=$$(find $(STAGE_DIR) \( -name 'libc.so*' -o -name 'ld-musl-*' \) -print); \
	if [ -n "$$found" ]; then \
	  echo "  FAIL     musl is in the staged tree; only e2fsprogs ships:" >&2; \
	  printf '           %s\n' $$found >&2; exit 1; \
	fi; \
	echo "  OK       e2fsprogs only - no libc, no loader"
endef

.PHONY: stage-info
stage-info: $(STAGE_STAMP) ## Show what the staged tree contains
	@echo "  stage    $(STAGE_DIR)"
	@echo "  size     $$(du -sh $(STAGE_DIR) | cut -f1)"
	@echo "  stripped $(if $(filter 1,$(WITH_STRIP)),yes,no)"
	@echo "  devel    $(if $(filter 1,$(WITH_DEVEL)),yes,no)"
	@echo "  manpages $(if $(filter 1,$(WITH_MANPAGES)),yes,no)"
	@echo "  e2scrub  $(if $(filter 1,$(WITH_E2SCRUB)),yes,no)"
	@find $(STAGE_DIR) \( -type f -o -type l \) ! -name '.staged' ! -name '.config' \
	  | sort | sed "s|$(STAGE_DIR)/|  file     |"

# ---------------------------------------------------------------------------
# Step 6 - the release asset
#
# The staged tree, tarred and compressed: exactly what rootfs unpacks into the
# root filesystem. Sibling repositories consume each other's *published
# releases* rather than each other's build trees, so this is the supported way
# out of here - nothing should read build/ across the filesystem.
# ---------------------------------------------------------------------------

# Set by the release workflow so the published file names the release it came
# from; empty for a local build, which names the e2fsprogs version alone.
DIST_TAG   ?=
DIST_ASSET  = sepiaos-e2fsprogs-$(E2FSPROGS_VERSION)-aarch64-musl$(if $(DIST_TAG),-$(DIST_TAG)).tar.xz
DIST_SUMS  := SHA256SUMS

.PHONY: dist
dist: $(STAGE_STAMP) ## Pack the staged tree into dist/ as a release asset
	@$(call assert_no_libc)
	@mkdir -p $(DIST_DIR)
	@echo "  PACK     $(DIST_ASSET)"
	@tar -C $(STAGE_DIR) --exclude=./.staged --exclude=./.config -cf - . \
	  | xz -9 -T0 -c > $(DIST_DIR)/$(DIST_ASSET).part
	@mv -f $(DIST_DIR)/$(DIST_ASSET).part $(DIST_DIR)/$(DIST_ASSET)
	@( cd $(DIST_DIR) && $(SHA256) $(DIST_ASSET) > $(DIST_SUMS) )
	@echo "  READY    $$(du -h $(DIST_DIR)/$(DIST_ASSET) | cut -f1) -> $(DIST_DIR)/$(DIST_ASSET)"

.PHONY: dist-info
dist-info: ## Show the packed asset and its digest
	@test -f $(DIST_DIR)/$(DIST_ASSET) \
	  || { echo "No $(DIST_DIR)/$(DIST_ASSET); run 'make dist' first." >&2; exit 1; }
	@echo "  asset    $(DIST_DIR)/$(DIST_ASSET)"
	@du -h $(DIST_DIR)/$(DIST_ASSET) | sed 's/^/  size     /' | cut -f1,2
	@sed 's/^/  sha256   /' $(DIST_DIR)/$(DIST_SUMS)
	@tar -tf $(DIST_DIR)/$(DIST_ASSET) | sort | sed 's|^\./|  contents |'

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build output (keeps downloads)
	rm -rf $(BUILD_DIR)

.PHONY: distclean
distclean: clean ## Also remove downloaded sources and the toolchain
	rm -rf $(DL_DIR) $(DIST_DIR)

# Read one variable's value, for scripts and CI: make -s print-DIST_ASSET
print-%:
	@echo '$($*)'

.PHONY: help
help: ## Show this help
	@echo "SepiaOS e2fsprogs build"
	@echo
	@echo "Targets:"
	@grep -hE '^[a-zA-Z0-9_-]+([ ]+[a-zA-Z0-9_-]+)*:.*?## ' $(MAKEFILE_LIST) \
	  | sed 's/:.*## /|/' \
	  | awk -F'|' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables:"
	@printf "  %-18s %s\n" \
	  "E2FSPROGS_VERSION" "upstream e2fsprogs release (default $(E2FSPROGS_VERSION))" \
	  "MUSL_VERSION"      "target musl - must match what rootfs ships (default $(MUSL_VERSION))" \
	  "PREFIX"            "prefix for the non-essential programs (default $(PREFIX))" \
	  "ROOT_PREFIX"       "prefix for /sbin, /bin and /etc (default empty)" \
	  "CONFIGURE_FLAGS"   "passed to upstream's configure" \
	  "CROSS_COMPILE"     "use a musl cross-toolchain you already have" \
	  "BUILD_CC"          "host compiler for the build-time helpers (default $(BUILD_CC))" \
	  "WITH_STRIP"        "strip the staged programs (default $(WITH_STRIP))" \
	  "WITH_DEVEL"        "also ship headers, static libraries and .pc files (default $(WITH_DEVEL))" \
	  "WITH_MANPAGES"     "also ship man pages (default $(WITH_MANPAGES))" \
	  "WITH_E2SCRUB"      "also ship the e2scrub scripts (default $(WITH_E2SCRUB))" \
	  "DIST_TAG"          "release tag to name the asset after" \
	  "JOBS"              "parallelism for the builds (default $(JOBS))"
	@echo
	@echo "Examples:"
	@echo "  make toolchain-check                 prove the compiler works"
	@echo "  make e2fsprogs                       cross-build the programs"
	@echo "  make stage-check                     prove the result is shippable"
	@echo "  make WITH_DEVEL=1 dist               pack the libraries and headers too"
	@echo "  make CROSS_COMPILE=/path/to/aarch64-unknown-linux-musl- e2fsprogs"
