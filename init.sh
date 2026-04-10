#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# One-time setup for building Libreboot on Guix System.
# Run inside: guix shell -m manifest.scm
#
# Usage: ./init.sh

set -e

if ! command -v gcc >/dev/null 2>&1 || ! command -v patchelf >/dev/null 2>&1; then
    printf "ERROR: Run this inside guix shell:\n" >&2
    printf "  guix shell -m manifest.scm -- ./init.sh\n" >&2
    exit 1
fi

BIN_DIR="$HOME/.local/bin"

GNAT_VERSION="15.2.0-1"
GNAT_DIR="$HOME/.local/lib/gnat-${GNAT_VERSION}"
GNAT_TARBALL="gnat-x86_64-linux-${GNAT_VERSION}.tar.gz"
GNAT_URL="https://github.com/alire-project/GNAT-FSF-builds/releases/download/gnat-${GNAT_VERSION}/${GNAT_TARBALL}"
GNAT_SHA256="4640d4b369833947ab1a156753f4db0ecd44b0f14410b5b2bc2a14df496604bb"

mkdir -p "$BIN_DIR"

# --- Simple wrappers ---

create_wrapper() {
    local name="$1" body="$2"
    printf '%s\n' "$body" > "$BIN_DIR/$name"
    chmod +x "$BIN_DIR/$name"
    printf "Created %s/%s\n" "$BIN_DIR" "$name"
}

command -v python >/dev/null 2>&1 || \
    create_wrapper python '#!/bin/sh
exec python3 "$@"'

# --- Download and patch GNAT ---

if [ ! -d "${GNAT_DIR}/bin" ]; then
    printf "Downloading GNAT %s...\n" "$GNAT_VERSION"
    _tmpdir="$(mktemp -d)"
    trap 'rm -rf "$_tmpdir"' EXIT

    wget -O "$_tmpdir/${GNAT_TARBALL}" "$GNAT_URL"

    printf "Verifying checksum...\n"
    echo "${GNAT_SHA256}  $_tmpdir/${GNAT_TARBALL}" | sha256sum -c -

    printf "Extracting to %s...\n" "$GNAT_DIR"
    rm -rf "${GNAT_DIR}"
    mkdir -p "${GNAT_DIR}"
    tar xf "$_tmpdir/${GNAT_TARBALL}" -C "${GNAT_DIR}" --strip-components=1

    rm -rf "$_tmpdir"
    trap - EXIT
fi

# --- Patch ELF interpreters for Guix System ---
# Pre-compiled ELF binaries use /lib64/ld-linux-x86-64.so.2 which
# doesn't exist on Guix. Patch them to use the Guix glibc interpreter.

GUIX_GLIBC="$(dirname "$(dirname "$(gcc -print-file-name=crt1.o)")")"
LD_LINUX="${GUIX_GLIBC}/lib/ld-linux-x86-64.so.2"
if [ ! -f "$LD_LINUX" ]; then
    printf "ERROR: Cannot find ld-linux-x86-64.so.2\n" >&2
    exit 1
fi

patch_count=0
patch_elf_interp() {
    local dir="$1" f magic interp
    [ -d "$dir" ] || return 0
    for f in $(find "$dir" -type f ! -type l 2>/dev/null); do
        magic="$(head -c4 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' ')"
        [ "$magic" = "7f454c46" ] || continue
        interp="$(patchelf --print-interpreter "$f" 2>/dev/null)" || continue
        # Skip if already pointing to the correct interpreter
        [ "$interp" = "$LD_LINUX" ] && continue
        patchelf --set-interpreter "$LD_LINUX" "$f" 2>/dev/null && \
            patch_count=$((patch_count + 1)) || true
    done
}

# GNAT binaries
patch_elf_interp "${GNAT_DIR}/bin"
patch_elf_interp "${GNAT_DIR}/libexec"

# coreboot tools (cbfstool, ifdtool, rmodtool, etc.)
for _elfdir in "${PWD}"/elf/coreboot/*/; do
    patch_elf_interp "$_elfdir"
done

# libreboot-utils
patch_elf_interp "${PWD}/util/libreboot-utils"

if [ "$patch_count" -gt 0 ]; then
    printf "Patched %d ELF files\n" "$patch_count"
fi

# --- gcc/cc/c99 wrappers with Ada (gnat1) support ---
# Guix gcc has no Ada frontend, so `gcc -print-prog-name=gnat1` fails.
# coreboot's buildgcc uses that check (hostcc_has_gnat1) to decide
# whether to enable Ada in crossgcc. We symlink ONLY gnat1 into an
# isolated directory and use -B to point there, so gcc finds gnat1
# but still uses its own cc1/cc1plus (avoiding GNAT library issues).

# Resolve the real Guix gcc, skipping any wrapper we may have created
# in a previous run. Search the guix profile/environment paths directly.
_guix_gcc=""
for _d in "$GUIX_ENVIRONMENT" "$GUIX_PROFILE" "$HOME/.guix-profile" "/run/current-system/profile"; do
    if [ -n "$_d" ] && [ -x "$_d/bin/gcc" ]; then
        _guix_gcc="$_d/bin/gcc"
        break
    fi
done
if [ -z "$_guix_gcc" ]; then
    # Fallback: find gcc not in BIN_DIR
    _guix_gcc="$(PATH="$(echo "$PATH" | tr ':' '\n' | grep -v "^${BIN_DIR}$" | tr '\n' ':')" command -v gcc)"
fi
if [ -z "$_guix_gcc" ] || [ ! -x "$_guix_gcc" ]; then
    printf "ERROR: Cannot find Guix gcc\n" >&2
    exit 1
fi
_gnat1_path="$("${GNAT_DIR}/bin/gcc" -print-prog-name=gnat1 2>/dev/null)"
_gnat1_shim="${HOME}/.local/lib/gnat1-shim"
mkdir -p "$_gnat1_shim"
ln -sf "$_gnat1_path" "$_gnat1_shim/gnat1"

cat > "$BIN_DIR/gcc" <<EOF
#!/bin/sh
exec "${_guix_gcc}" -B "${_gnat1_shim}/" "\$@"
EOF
chmod +x "$BIN_DIR/gcc"

cat > "$BIN_DIR/cc" <<EOF
#!/bin/sh
exec "${_guix_gcc}" -B "${_gnat1_shim}/" "\$@"
EOF
chmod +x "$BIN_DIR/cc"

cat > "$BIN_DIR/c99" <<EOF
#!/bin/sh
exec "${_guix_gcc}" -B "${_gnat1_shim}/" -std=c99 "\$@"
EOF
chmod +x "$BIN_DIR/c99"
printf "Created gcc/cc/c99 wrappers with Ada support (-B %s)\n" "$_gnat1_shim"

# --- GNAT wrappers ---
# gnatmake etc. call gcc internally, so prepend GNAT_DIR/bin to PATH
# so they find the GNAT gcc (with Ada frontend). LD_LIBRARY_PATH uses
# LIBRARY_PATH from guix shell at runtime.

for bin in "${GNAT_DIR}/bin/gnat"*; do
    [ -x "$bin" ] || continue
    name="$(basename "$bin")"
    cat > "$BIN_DIR/$name" <<EOF
#!/bin/sh
export PATH="${GNAT_DIR}/bin:\$PATH"
export LD_LIBRARY_PATH="\${LIBRARY_PATH:+\$LIBRARY_PATH:}${GNAT_DIR}/lib:${GNAT_DIR}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "${bin}" "\$@"
EOF
    chmod +x "$BIN_DIR/$name"
done
printf "Created GNAT wrappers in %s\n" "$BIN_DIR"

# --- Rebuild sbase for Guix System ---
# sbase ships pre-compiled ELF binaries (sha512sum etc.) that use
# the standard /lib/ld-linux interpreter, which doesn't exist on Guix.
# Rebuild from source so the binaries work natively.

_sbase_dir="${PWD}/util/sbase"
if [ -d "$_sbase_dir" ] && ! "$_sbase_dir/sha512sum" </dev/null 2>/dev/null; then
    printf "Rebuilding sbase for Guix System...\n"
    make -C "$_sbase_dir" clean 2>/dev/null || true
    make -C "$_sbase_dir" CC="${_guix_gcc}" -j"$(nproc)"
    printf "sbase rebuilt.\n"
fi

# --- Unifont for GRUB ---
# Copy (not symlink) unifont so it survives Guix store garbage collection,
# then patch mkhelper.cfg with --with-unifont so GRUB's configure finds it.
# This avoids modifying the original config/data/grub/mkhelper.cfg in git.

fonts_dir="${PWD}/cache/fonts-misc"
mkdir -p "$fonts_dir"
if [ ! -f "$fonts_dir/unifont.pcf.gz" ]; then
    pcf_file="$(find /gnu/store -maxdepth 5 -name 'unifont.pcf.gz' \
        -path '*font-gnu-unifont*' 2>/dev/null | head -1)"
    if [ -n "$pcf_file" ] && [ -f "$pcf_file" ]; then
        cp "$pcf_file" "$fonts_dir/unifont.pcf.gz"
        printf "Copied unifont to %s\n" "$fonts_dir"
    else
        printf "ERROR: unifont.pcf.gz not found. Are you in guix shell -m manifest.scm?\n" >&2
        exit 1
    fi
fi

_grub_cfg="config/data/grub/mkhelper.cfg"
_unifont_arg="--with-unifont=${PWD}/cache/fonts-misc/unifont.pcf.gz"
if ! grep -q -- '--with-unifont' "$_grub_cfg"; then
    sed -i "s|autoconfargs=\"|autoconfargs=\"${_unifont_arg} |" "$_grub_cfg"
    printf "Patched %s with unifont path\n" "$_grub_cfg"
fi

# --- Detect path change and clean stale build trees ---
# GRUB's ./configure and coreboot crossgcc bake absolute paths into
# Makefiles. If the project directory changed, those builds are stale.

_init_state="${PWD}/cache/.init_path"
_old_path=""
[ -f "$_init_state" ] && _old_path="$(cat "$_init_state")"

if [ -n "$_old_path" ] && [ "$_old_path" != "$PWD" ]; then
    printf "Project path changed: %s -> %s\n" "$_old_path" "$PWD"

    printf "Cleaning stale GRUB build trees...\n"
    rm -rf "${PWD}"/src/grub/*/

    printf "Cleaning stale crossgcc (baked paths)...\n"
    for _cbdir in "${PWD}"/src/coreboot/*/; do
        [ -d "$_cbdir/util/crossgcc/xgcc" ] && rm -rf "$_cbdir/util/crossgcc/xgcc"
    done
    rm -f "${PWD}"/elf/coreboot/*/xgcc_*_was_compiled

    # Re-patch mkhelper.cfg with new path
    sed -i "s|--with-unifont=[^ ]*|--with-unifont=${PWD}/cache/fonts-misc/unifont.pcf.gz|" "$_grub_cfg"
    printf "Updated unifont path in %s\n" "$_grub_cfg"
fi
printf '%s' "$PWD" > "$_init_state"

# --- Ensure coreboot crossgcc has Ada support ---
# If crossgcc was built without Ada (--enable-languages=c only),
# remove the flag file so lbmk rebuilds it with GNAT in PATH.

for _xgcc_flag in "${PWD}"/elf/coreboot/*/xgcc_*_was_compiled; do
    [ -f "$_xgcc_flag" ] || continue

    # Derive the coreboot tree name from flag path
    _cb_tree="$(basename "$(dirname "$_xgcc_flag")")"
    _xgcc_gcc="${PWD}/src/coreboot/${_cb_tree}/util/crossgcc/xgcc/bin/i386-elf-gcc"

    if [ -x "$_xgcc_gcc" ]; then
        _xgcc_langs="$("$_xgcc_gcc" -v 2>&1 | grep -o 'enable-languages=[^ ]*' || true)"
        case "$_xgcc_langs" in
            *ada*) ;;  # Ada present, all good
            *)
                printf "crossgcc in coreboot/%s lacks Ada support, removing to trigger rebuild...\n" "$_cb_tree"
                rm -rf "${PWD}/src/coreboot/${_cb_tree}/util/crossgcc/xgcc"
                rm -f "$_xgcc_flag"
                ;;
        esac
    fi
done

# --- Fake ccache shim ---
# lbmk's include/rom.sh hardcodes "CONFIG_CCACHE=y" into the coreboot
# .config on every build. Removing it from .config doesn't help — it
# gets re-added. Instead, provide a no-op ccache wrapper that just
# exec's its arguments, so coreboot's toolchain.mk PATH check passes
# and the build proceeds without actually caching anything.

if ! command -v ccache >/dev/null 2>&1 || \
   [ "$(readlink -f "$(command -v ccache 2>/dev/null)")" = "$BIN_DIR/ccache" ]; then
    cat > "$BIN_DIR/ccache" <<'CCACHE_EOF'
#!/bin/sh
# No-op ccache shim: just run the wrapped command without caching.
exec "$@"
CCACHE_EOF
    chmod +x "$BIN_DIR/ccache"
    printf "Created no-op ccache shim at %s\n" "$BIN_DIR/ccache"
fi

# --- SSL certificates for guix shell ---
# guix shell --pure mode may not set SSL paths, so create a helper
# that can be sourced from shell profile or before builds.

_ssl_helper="$BIN_DIR/guix-ssl-env"
cat > "$_ssl_helper" <<'SSLEOF'
#!/bin/sh
# Source this to set SSL cert paths inside guix shell.
# Usage: eval "$(guix-ssl-env)"
_certs=""
for _d in "$GUIX_ENVIRONMENT" "$GUIX_PROFILE" "$HOME/.guix-profile" "/run/current-system/profile"; do
    if [ -f "$_d/etc/ssl/certs/ca-certificates.crt" ]; then
        _certs="$_d/etc/ssl/certs"
        break
    fi
done
if [ -n "$_certs" ]; then
    printf 'export SSL_CERT_DIR="%s"\n' "$_certs"
    printf 'export SSL_CERT_FILE="%s/ca-certificates.crt"\n' "$_certs"
    printf 'export GIT_SSL_CAINFO="%s/ca-certificates.crt"\n' "$_certs"
fi
SSLEOF
chmod +x "$_ssl_helper"
printf "Created %s\n" "$_ssl_helper"

# --- Check PATH ---

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        printf "\nWARNING: %s is not in your PATH.\n" "$BIN_DIR"
        printf "Add to your shell profile:\n"
        printf "  export PATH=\"%s:\$PATH\"\n" "$BIN_DIR"
        printf "  eval \"\$(guix-ssl-env)\"\n"
        ;;
esac

printf "\nInit complete.\n"
gnat --version | head -1
printf "gcc: "; gcc --version | head -1
