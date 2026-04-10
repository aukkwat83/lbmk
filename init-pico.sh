#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# One-time setup for building pico-serprog (Raspberry Pi Pico firmware)
# from this lbmk tree on Guix System.
#
# MUST BE SOURCED — not executed — because it modifies PATH/CC/CXX of
# your current shell. Running as a subprocess (./init-pico.sh) cannot
# propagate env vars back to the parent.
#
#   guix shell -m manifest-pico.scm
#   source ./init-pico.sh     # or:  . ./init-pico.sh
#   ./mk -b pico-serprog
#
# Why this exists:
#   libreboot's ./init.sh installs a cc/gcc/c99 wrapper in ~/.local/bin
#   that exec's the downloaded GNAT gcc (for coreboot's Ada support).
#   That GNAT gcc dynamically links libzstd.so.1, which is NOT in the
#   pico shell profile — so any host C compile in the pico build
#   (notably pico-sdk's elf2uf2 sub-project) fails with:
#     cc1: error while loading shared libraries: libzstd.so.1
#
#   Simply stripping ~/.local/bin from PATH is unreliable: .bashrc
#   re-prepends it on every new bash invocation, and the user may
#   source this script inconsistently.
#
#   Robust fix: create a project-local wrapper directory
#   (cache/pico-bin/) containing cc/gcc/c++/g++ scripts that exec the
#   ABSOLUTE path of Guix's gcc-toolchain@15. Prepend that dir to PATH
#   so it wins over anything in ~/.local/bin. Absolute paths mean the
#   wrappers don't care what PATH looks like downstream.

# --- Detect whether we were sourced or executed ---
_pico_sourced=0
(return 0 2>/dev/null) && _pico_sourced=1

if [ "$_pico_sourced" -eq 0 ]; then
    printf "ERROR: init-pico.sh must be SOURCED, not executed.\n" >&2
    printf "Run one of:\n" >&2
    printf "  source ./init-pico.sh\n" >&2
    printf "  . ./init-pico.sh\n" >&2
    exit 1
fi

# Sourced from here on — use `return`, don't `set -e`.

_pico_pwd="$PWD"
_pico_wrap_dir="$_pico_pwd/cache/pico-bin"
_pico_build_dir="$_pico_pwd/src/pico-serprog/build"

# --- Nuke any stale pico-serprog build tree ---
# CMake bakes the detected C compiler into CMakeCache.txt as an
# absolute path on first configure. If a previous run picked the
# broken ~/.local/bin/cc (libreboot's GNAT wrapper), every subsequent
# ./mk -b pico-serprog will KEEP using that cached compiler regardless
# of PATH / CC env vars, because TryCompile reads it straight from
# CMAKE_C_COMPILER in the cache. The only reliable cure is to blow
# the build tree away before each init.
if [ -d "$_pico_build_dir" ]; then
    printf "Removing stale build tree: %s\n" "$_pico_build_dir"
    rm -rf "$_pico_build_dir"
fi

# --- Sanity: must be inside the pico guix shell ---
if [ -z "${GUIX_ENVIRONMENT:-}" ]; then
    printf "ERROR: GUIX_ENVIRONMENT is not set.\n" >&2
    printf "Enter the pico guix shell first:\n" >&2
    printf "  guix shell -m manifest-pico.scm\n" >&2
    return 1
fi

# Resolve REAL gcc/g++ from the pico Guix profile, bypassing whatever
# PATH currently looks like (in particular, bypassing ~/.local/bin).
_pico_guix_gcc="$GUIX_ENVIRONMENT/bin/gcc"
_pico_guix_gxx="$GUIX_ENVIRONMENT/bin/g++"

if [ ! -x "$_pico_guix_gcc" ]; then
    printf "ERROR: no gcc at %s\n" "$_pico_guix_gcc" >&2
    printf "Is gcc-toolchain@15 really in manifest-pico.scm?\n" >&2
    return 1
fi
if [ ! -x "$_pico_guix_gxx" ]; then
    printf "ERROR: no g++ at %s\n" "$_pico_guix_gxx" >&2
    return 1
fi

# Also need arm-none-eabi-gcc from the same profile.
_pico_arm_gcc="$GUIX_ENVIRONMENT/bin/arm-none-eabi-gcc"
if [ ! -x "$_pico_arm_gcc" ]; then
    printf "ERROR: no arm-none-eabi-gcc at %s\n" "$_pico_arm_gcc" >&2
    printf "Is arm-none-eabi-nano-toolchain in manifest-pico.scm?\n" >&2
    return 1
fi
_pico_arm_root="$GUIX_ENVIRONMENT"   # pico-sdk wants $PICO_TOOLCHAIN_PATH/bin/...

# Sanity-run the host gcc so we catch libzstd-style dynamic link
# errors IMMEDIATELY, while we still have a clear error to report.
if ! "$_pico_guix_gcc" --version >/dev/null 2>&1; then
    printf "ERROR: %s does not run:\n" "$_pico_guix_gcc" >&2
    "$_pico_guix_gcc" --version >&2 || true
    return 1
fi

printf "Guix gcc            : %s\n" "$_pico_guix_gcc"
printf "Guix g++            : %s\n" "$_pico_guix_gxx"
printf "arm-none-eabi-gcc   : %s\n" "$_pico_arm_gcc"
printf "PICO_TOOLCHAIN_PATH : %s\n" "$_pico_arm_root"
"$_pico_guix_gcc" --version | head -1
"$_pico_arm_gcc" --version | head -1

# --- Create wrapper dir with cc/gcc/c++/g++ pointing at absolute paths ---
# These wrappers use the full store path of Guix gcc — no PATH lookup,
# so nothing downstream can redirect them to libreboot's GNAT wrapper.
mkdir -p "$_pico_wrap_dir"

_pico_write_wrap() {
    # $1 = wrapper name in cache/pico-bin/
    # $2 = absolute path to target binary
    cat > "$_pico_wrap_dir/$1" <<EOF
#!/bin/sh
exec "$2" "\$@"
EOF
    chmod +x "$_pico_wrap_dir/$1"
}
_pico_write_wrap cc  "$_pico_guix_gcc"
_pico_write_wrap gcc "$_pico_guix_gcc"
_pico_write_wrap c++ "$_pico_guix_gxx"
_pico_write_wrap g++ "$_pico_guix_gxx"

# --- Prepend wrapper dir to PATH (ONE copy only, no duplicates) ---
case ":$PATH:" in
    *":$_pico_wrap_dir:"*) ;;                      # already first-ish, leave it
    *) export PATH="$_pico_wrap_dir:$PATH" ;;
esac

# Also export CC / CXX absolutely, so any tool that reads them bypasses
# PATH entirely (belt and braces).
export CC="$_pico_guix_gcc"
export CXX="$_pico_guix_gxx"
export PICO_TOOLCHAIN_PATH="$_pico_arm_root"

# --- Replay helper (for a fresh shell that just wants env applied) ---
# We write an `eval`-able pico-env into the wrapper dir itself so it
# lives and dies with this checkout (not in ~/.local/bin, which is
# libreboot territory).
cat > "$_pico_wrap_dir/pico-env" <<EOF
#!/bin/sh
# Lightweight env replay helper. Auto-generated by init-pico.sh.
# Usage from a fresh pico shell:  eval "\$($_pico_wrap_dir/pico-env)"
printf 'export CC=%s\n'  "$_pico_guix_gcc"
printf 'export CXX=%s\n' "$_pico_guix_gxx"
printf 'export PICO_TOOLCHAIN_PATH=%s\n' "$_pico_arm_root"
printf 'case ":\$PATH:" in *":$_pico_wrap_dir:"*) ;; *) export PATH="$_pico_wrap_dir:\$PATH" ;; esac\n'
EOF
chmod +x "$_pico_wrap_dir/pico-env"

# --- Post-apply sanity checks ---
printf "\n--- env applied to current shell ---\n"
printf "CC                = %s\n" "$CC"
printf "CXX               = %s\n" "$CXX"
printf "PICO_TOOLCHAIN_PATH = %s\n" "$PICO_TOOLCHAIN_PATH"
printf "cc  (via PATH) -> %s\n" "$(command -v cc  2>/dev/null || echo '(not found)')"
printf "gcc (via PATH) -> %s\n" "$(command -v gcc 2>/dev/null || echo '(not found)')"
printf "arm-none-eabi-gcc -> %s\n" "$(command -v arm-none-eabi-gcc 2>/dev/null || echo '(not found)')"

# The wrapper dir must win over ~/.local/bin. Verify resolution.
case "$(command -v cc 2>/dev/null)" in
    "$_pico_wrap_dir/cc") : ;;
    *)
        printf "\nWARNING: 'cc' does NOT resolve to our wrapper.\n" >&2
        printf "         Expected: %s/cc\n" "$_pico_wrap_dir" >&2
        printf "         Got     : %s\n"   "$(command -v cc 2>/dev/null)" >&2
        return 1
        ;;
esac

# Actually run cc through the wrapper to prove the end-to-end chain
# works (this would have caught the libzstd failure at init time).
if ! cc --version >/dev/null 2>&1; then
    printf "\nERROR: cc (via wrapper) does not run.\n" >&2
    cc --version >&2 || true
    return 1
fi
printf "cc  : "; cc --version | head -1

# Clean up locals (but keep wrap_dir reachable via the exported PATH).
unset _pico_sourced _pico_pwd _pico_wrap_dir _pico_build_dir \
      _pico_guix_gcc _pico_guix_gxx _pico_arm_gcc _pico_arm_root \
      _pico_write_wrap

printf "\ninit-pico complete.\n"
printf "Now build with:  ./mk -b pico-serprog\n"
