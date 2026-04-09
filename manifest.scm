;; SPDX-License-Identifier: GPL-3.0-or-later
;; Guix manifest for building Libreboot (lbmk) - T480 SeaGRUB
;;
;; Usage:
;;   guix shell -m manifest.scm
;;   source setup-gnat.sh    # downloads & patches GNAT Ada compiler
;;   ./mk -b coreboot t480_vfsp_16mb

(use-modules (gnu packages)
             (gnu packages admin)
             (gnu packages algebra)
             (gnu packages assembly)
             (gnu packages autotools)
             (gnu packages base)
             (gnu packages bison)
             (gnu packages bootloaders)
             (gnu packages ccache)
             (gnu packages cdrom)
             (gnu packages cmake)
             (gnu packages compression)
             (gnu packages commencement)
             (gnu packages curl)
             (gnu packages disk)
             (gnu packages documentation)
             (gnu packages efi)
             (gnu packages elf)
             (gnu packages embedded)
             (gnu packages flex)
             (gnu packages fonts)
             (gnu packages fontutils)
             (gnu packages gawk)
             (gnu packages gcc)
             (gnu packages gdb)
             (gnu packages gettext)
             (gnu packages libftdi)
             (gnu packages libusb)
             (gnu packages linux)
             (gnu packages m4)
             (gnu packages man)
             (gnu packages mtools)
             (gnu packages ncurses)
             (gnu packages pciutils)
             (gnu packages perl)
             (gnu packages pkg-config)
             (gnu packages python)
             (gnu packages python-build)
             (gnu packages python-crypto)
             (gnu packages python-xyz)
             (gnu packages sdl)
             (gnu packages swig)
             (gnu packages texinfo)
             (gnu packages tls)
             (gnu packages version-control)
             (gnu packages wget))

(packages->manifest
 (list
  ;; Core build tools (version 15.2.0 to match GNAT FSF 15.2.0)
  (specification->package "gcc-toolchain@15")
  gnu-make
  cmake
  pkg-config
  bc
  m4
  bison
  flex
  gawk
  perl
  python

  ;; Autotools
  (specification->package "autoconf@2.72")
  autoconf-archive
  automake
  libtool
  help2man

  ;; Version control
  git

  ;; Compression
  lz4
  xz
  zlib
  (specification->package "7zip")
  (specification->package "zstd")
  sharutils
  unzip
  innoextract

  ;; Crypto / TLS
  openssl
  gnutls

  ;; Network
  curl
  wget

  ;; ACPI
  acpica

  ;; Assembly
  nasm

  ;; Libraries
  ncurses
  freetype
  sdl2
  libftdi
  libusb
  libjaylink
  libgpiod
  fuse
  elfutils

  ;; Firmware tools
  efitools
  pciutils
  dtc

  ;; Font (pcf output needed for GRUB's unifont.pcf.gz)
  (list font-gnu-unifont "pcf")

  ;; SWIG
  swig

  ;; Python packages
  python-pycryptodome
  python-pyelftools
  python-setuptools

  ;; Disk tools
  mtools
  e2fsprogs
  parted

  ;; ISO creation
  cdrtools

  ;; Debugging
  gdb

  ;; Caching
  ccache

  ;; Documentation
  doxygen
  texinfo

  ;; patchelf - needed for GNAT binary patching
  (specification->package "patchelf")

  ;; file command (for ELF detection)
  (specification->package "file")

  ;; Shell and coreutils (needed for --pure mode)
  (specification->package "bash")
  (specification->package "coreutils")
  (specification->package "grep")
  (specification->package "sed")
  (specification->package "findutils")
  (specification->package "diffutils")
  (specification->package "patch")
  (specification->package "which")
  (specification->package "tar")
  (specification->package "gzip")
  (specification->package "nss-certs")

  ;; Misc
  util-linux
  (specification->package "gettext")
  ))
