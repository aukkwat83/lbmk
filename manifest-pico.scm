;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Standalone Guix manifest for building pico-serprog from the lbmk
;; tree. This manifest is SELF-CONTAINED — it does NOT depend on the
;; main manifest.scm and does NOT need to be combined with it.
;;
;; Usage:
;;   guix shell -m manifest-pico.scm
;;   ./init-pico.sh       # one-time: export PICO_TOOLCHAIN_PATH
;;   eval "$(pico-env)"
;;   ./mk -b pico-serprog
;;
;; What's included:
;;   - arm-none-eabi gcc + newlib-nano (for pico-sdk --specs=nano.specs)
;;   - arm-none-eabi gdb (optional, small)
;;   - cmake / make / pkg-config / python / perl / git (pico-sdk +
;;     lbmk's ./mk need these to clone, configure, and compile)
;;   - host gcc-toolchain (for any small host-side tools pico-sdk may
;;     build, e.g. pioasm)
;;   - coreutils / findutils / sed / grep / bash / tar / gzip / xz
;;     so the shell is usable in `guix shell --pure` mode

(use-modules (gnu packages)
             (gnu packages base)
             (gnu packages bash)
             (gnu packages cmake)
             (gnu packages commencement)
             (gnu packages compression)
             (gnu packages embedded)
             (gnu packages perl)
             (gnu packages pkg-config)
             (gnu packages python)
             (gnu packages tls)
             (gnu packages version-control))

(packages->manifest
 (list
  ;; --- Bare-metal ARM toolchain ---
  ;; Returns package: arm-none-eabi-nano-toolchain@12.3.rel1
  ;; (binutils + gcc + newlib + newlib-nano)
  (make-arm-none-eabi-nano-toolchain-12.3.rel1)
  (make-gdb-arm-none-eabi)

  ;; --- Host build tools pico-sdk + ./mk need ---
  (specification->package "gcc-toolchain@15")
  gnu-make
  cmake
  pkg-config
  python
  perl
  git

  ;; --- TLS / certs (git clone over https, guix substitutes) ---
  (specification->package "nss-certs")

  ;; --- Shell + basic userspace for --pure mode ---
  (specification->package "bash")
  (specification->package "coreutils")
  (specification->package "findutils")
  (specification->package "grep")
  (specification->package "sed")
  (specification->package "tar")
  (specification->package "gzip")
  (specification->package "xz")
  (specification->package "which")))
