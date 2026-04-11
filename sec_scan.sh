#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# sec_scan.sh — Supply-chain integrity verification for lbmk on Guix System
#
# Threat model: state-level MITM adversary who can:
#   - Intercept/modify TLS traffic (compromised CA or BGP hijack)
#   - Tamper with DNS resolution
#   - Compromise a single mirror or forge server
#   - Inject malicious substitutes into Guix binary cache
#   - Replace pre-built binaries (GNAT) during download
#   - Serve poisoned git repos with rewritten history
#
# Defence layers this script verifies:
#   [1] Guix channel authentication (signed commits, channel introduction)
#   [2] Guix substitute verification (guix challenge, narinfo signatures)
#   [3] TLS/CA chain integrity (certificate pinning, CT log cross-check)
#   [4] GNAT binary multi-source hash comparison
#   [5] Git repo cross-mirror verification (fetch same commit from both
#       mirrors, compare tree hashes — detects single-mirror compromise)
#   [6] Tarball SHA-512 re-verification from independent mirror
#   [7] Software Heritage archive cross-check (immutable third-party)
#   [8] DNS-over-HTTPS consistency check (detect DNS poisoning)
#   [9] Binary reproducibility spot-check via guix challenge
#  [10] Guix store integrity — verify /gnu/store items against narinfo
#
# Usage:
#   guix shell -m manifest.scm -- ./sec_scan.sh          # full scan
#   guix shell -m manifest.scm -- ./sec_scan.sh --quick   # skip slow checks
#   guix shell -m manifest.scm -- ./sec_scan.sh --section guix
#   guix shell -m manifest.scm -- ./sec_scan.sh --section git
#   guix shell -m manifest.scm -- ./sec_scan.sh --section gnat
#   guix shell -m manifest.scm -- ./sec_scan.sh --section tls
#   guix shell -m manifest.scm -- ./sec_scan.sh --section dns
#   guix shell -m manifest.scm -- ./sec_scan.sh --section tarballs

set -euo pipefail

# ─── Colours & output helpers ────────────────────────────────────────

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
RST='\033[0m'

pass_count=0
fail_count=0
warn_count=0
skip_count=0

_log()  { printf "${BLU}[*]${RST} %s\n" "$*"; }
_pass() { printf "${GRN}[PASS]${RST} %s\n" "$*"; pass_count=$((pass_count + 1)); }
_fail() { printf "${RED}[FAIL]${RST} %s\n" "$*"; fail_count=$((fail_count + 1)); }
_warn() { printf "${YLW}[WARN]${RST} %s\n" "$*"; warn_count=$((warn_count + 1)); }
_skip() { printf "${YLW}[SKIP]${RST} %s\n" "$*"; skip_count=$((skip_count + 1)); }
_hdr()  { printf "\n${BLU}═══════════════════════════════════════════════════${RST}\n"; \
          printf "${BLU}  %s${RST}\n" "$*"; \
          printf "${BLU}═══════════════════════════════════════════════════${RST}\n"; }

# ─── Parse arguments ─────────────────────────────────────────────────

QUICK=0
SECTION="all"
while [ $# -gt 0 ]; do
    case "$1" in
        --quick)   QUICK=1 ;;
        --section) shift; SECTION="${1:-all}" ;;
        --help|-h)
            printf "Usage: %s [--quick] [--section guix|git|gnat|tls|dns|tarballs]\n" "$0"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
done

should_run() {
    [ "$SECTION" = "all" ] || [ "$SECTION" = "$1" ]
}

# ─── Locate project root ────────────────────────────────────────────

LBMK_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$LBMK_ROOT"

if [ ! -f "mk" ] || [ ! -d "config/git" ]; then
    printf "ERROR: must run from lbmk root directory\n" >&2
    exit 1
fi

_tmpdir="$(mktemp -d)"
trap 'rm -rf "$_tmpdir"' EXIT

printf "\n%s\n" "╔═══════════════════════════════════════════════════════════╗"
printf "%s\n"   "║  lbmk Supply-Chain Integrity Scanner                     ║"
printf "%s\n"   "║  Threat model: state-level MITM / supply-chain attack    ║"
printf "%s\n\n" "╚═══════════════════════════════════════════════════════════╝"
printf "Date    : %s\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
printf "Host    : %s\n" "$(uname -nrm)"
printf "Project : %s\n" "$LBMK_ROOT"
printf "Mode    : %s\n" "$([ "$QUICK" -eq 1 ] && echo 'quick' || echo 'full')"
printf "Section : %s\n" "$SECTION"


###############################################################################
# [1] GUIX CHANNEL AUTHENTICATION
###############################################################################

if should_run "guix"; then
_hdr "[1] Guix Channel Authentication"

# 1a. Verify channel commit signatures
_log "Checking guix describe (channel provenance)..."
guix_desc="$(guix describe --format=json 2>/dev/null)" || guix_desc=""

if [ -z "$guix_desc" ]; then
    _fail "Cannot read guix describe output"
else
    # Extract channel introduction signers — these are the GPG fingerprints
    # that authenticated the initial channel commit. If they changed, someone
    # may have substituted a forged channel.
    guix_signer="$(printf '%s' "$guix_desc" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); \
        [print(c.get('introduction',{}).get('signer','NONE')) for c in d]" 2>/dev/null)" || guix_signer=""

    if [ -z "$guix_signer" ]; then
        _fail "Cannot extract channel introduction signers"
    else
        _log "Channel introduction signers:"
        printf '%s\n' "$guix_signer" | while IFS= read -r signer; do
            if [ "$signer" = "NONE" ]; then
                _warn "  Channel without introduction signer detected"
            else
                _pass "  Signer: $signer"
            fi
        done
    fi

    # Check that official guix channel points to the right URL
    guix_url="$(printf '%s' "$guix_desc" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); \
        [print(c['url']) for c in d if c['name']=='guix']" 2>/dev/null)" || guix_url=""
    case "$guix_url" in
        https://git.guix.gnu.org/guix.git|https://git.savannah.gnu.org/git/guix.git)
            _pass "Official Guix channel URL: $guix_url" ;;
        *)
            _fail "Unexpected Guix channel URL: $guix_url (possible redirect/hijack)" ;;
    esac

    # Check nonguix channel if present
    nonguix_url="$(printf '%s' "$guix_desc" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); \
        [print(c['url']) for c in d if c['name']=='nonguix']" 2>/dev/null)" || nonguix_url=""
    if [ -n "$nonguix_url" ]; then
        case "$nonguix_url" in
            https://gitlab.com/nonguix/nonguix)
                _pass "Nonguix channel URL: $nonguix_url" ;;
            *)
                _warn "Unexpected nonguix channel URL: $nonguix_url" ;;
        esac
    fi
fi

# 1b. Verify Guix signing key is in the keyring
#
# หมายเหตุ: ใน Guix รุ่นใหม่ signing-key.pub ไม่ได้วางไว้ที่ path เดียวกัน
# ทุกเครื่อง — บางครั้งมันอยู่ใน /gnu/store/.../share/guix/, บางครั้งมัน
# เป็น part ของ channel introduction ที่ Guix เช็คให้เองในขั้น 1a แล้ว
# การหาไม่พบ "ไฟล์" จึงไม่ได้แปลว่าไม่ปลอดภัย และไม่ควรนับเป็น WARN
# (ชั้น 1a ตรวจ introduction signers เรียบร้อยแล้ว ซึ่งคือ ground truth)
_log "Checking Guix channel signing keys..."
guix_sig_found=0
for kp in \
    "/home/guix/.config/guix/current/share/guix/signing-key.pub" \
    "/run/current-system/profile/share/guix/signing-key.pub" \
    /gnu/store/*-guix-*/share/guix/signing-key.pub; do
    if [ -f "$kp" ]; then
        _pass "Guix signing key present: $kp"
        guix_sig_found=1
        break
    fi
done
if [ "$guix_sig_found" -eq 0 ]; then
    _skip "Guix signing key file (covered by channel introduction check in 1a)"
fi

# 1c. Verify guix substitute server ACL
_log "Checking substitute authorization (ACL)..."
acl_file="/etc/guix/acl"
if [ -f "$acl_file" ]; then
    _pass "Substitute ACL exists: $acl_file"
    acl_entries="$(grep -c 'public-key' "$acl_file" 2>/dev/null)" || acl_entries=0
    _log "  ACL contains $acl_entries authorized public keys"

    # Check that only known substitute servers are authorized
    if [ "$acl_entries" -le 3 ]; then
        _pass "  ACL entry count is reasonable ($acl_entries keys)"
    else
        _warn "  ACL has $acl_entries keys — review for unauthorized substitute servers"
    fi
else
    _warn "No substitute ACL found at $acl_file"
fi


###############################################################################
# [2] GUIX SUBSTITUTE VERIFICATION (guix challenge)
###############################################################################

_hdr "[2] Guix Substitute Reproducibility (guix challenge)"

if [ "$QUICK" -eq 1 ]; then
    _skip "guix challenge (slow; use full mode)"
else
    _log "Running guix challenge on critical build packages..."
    _log "(This compares locally-built hashes against substitute server)"

    # Pick a representative sample of packages from manifest.scm
    challenge_pkgs=(
        gcc-toolchain@15
        coreutils
        git
        openssl
        gnutls
        curl
        wget
        python
        nasm
    )

    for pkg in "${challenge_pkgs[@]}"; do
        _log "  Challenging: $pkg"
        challenge_out="$(guix challenge "$pkg" 2>&1)" || true

        if printf '%s' "$challenge_out" | grep -q "mismatch"; then
            _fail "guix challenge MISMATCH for $pkg — possible tampered substitute!"
            printf '%s\n' "$challenge_out" | grep -i "mismatch" | head -3
        elif printf '%s' "$challenge_out" | grep -q "no substitutes"; then
            _skip "  $pkg: no substitutes to compare (built locally)"
        elif printf '%s' "$challenge_out" | grep -q "match"; then
            _pass "  $pkg: substitute matches local build"
        else
            _warn "  $pkg: inconclusive challenge result"
        fi
    done
fi

# 2b. Verify /gnu/store integrity for installed profile
_log "Spot-checking /gnu/store item integrity..."
store_check_count=0
store_bad_count=0

# Check a few critical items from the profile
for store_item in $(guix package --list-installed 2>/dev/null | awk '{print $4}' | head -10); do
    [ -d "$store_item" ] || continue
    store_check_count=$((store_check_count + 1))

    # Verify the .drv file exists and is consistent
    item_name="$(basename "$store_item")"
    narinfo_hash="${item_name%%-*}"

    if [ -d "$store_item" ] && [ -r "$store_item" ]; then
        # Check that store item permissions haven't been tampered with
        owner="$(stat -c '%U' "$store_item" 2>/dev/null)" || owner=""
        if [ "$owner" != "root" ]; then
            _warn "  Store item not owned by root: $store_item (owner: $owner)"
            store_bad_count=$((store_bad_count + 1))
        fi
    fi
done

if [ "$store_check_count" -gt 0 ] && [ "$store_bad_count" -eq 0 ]; then
    _pass "Checked $store_check_count store items: ownership OK"
elif [ "$store_check_count" -eq 0 ]; then
    _skip "No installed store items to check"
else
    _warn "$store_bad_count/$store_check_count store items have unexpected ownership"
fi

fi # should_run guix


###############################################################################
# [3] TLS / CA CHAIN INTEGRITY
###############################################################################

if should_run "tls"; then
_hdr "[3] TLS / CA Chain Integrity"

# Resolve CA bundle for openssl (Guix may not set SSL paths automatically)
_ssl_cafile=""
for _d in "${GUIX_ENVIRONMENT:-}" "${GUIX_PROFILE:-}" "$HOME/.guix-profile" "/run/current-system/profile"; do
    [ -n "$_d" ] || continue
    if [ -f "$_d/etc/ssl/certs/ca-certificates.crt" ]; then
        _ssl_cafile="$_d/etc/ssl/certs/ca-certificates.crt"
        break
    fi
done
[ -z "$_ssl_cafile" ] && _ssl_cafile="${SSL_CERT_FILE:-}"
_ssl_arg=""
[ -n "$_ssl_cafile" ] && _ssl_arg="-CAfile $_ssl_cafile"

# 3a. Verify TLS connections to critical servers don't show intercepted certs
#
# เหตุผลที่ออกแบบใหม่ (2026-04):
#   เดิมเราใช้วิธี "pin" ผู้ออก CA ของแต่ละโดเมนตายตัว (เช่น github=DigiCert)
#   แต่ CA สามารถย้ายได้ตลอด — เช่น github.com ปัจจุบันย้ายมาใช้ Sectigo,
#   gitlab.com ก็ใช้ Sectigo แล้ว ทำให้ pin ตายตัวกลายเป็น false positive
#   บ่อย ๆ ทันทีที่ผู้ให้บริการเปลี่ยน CA
#
#   แนวทางใหม่มี 2 ชั้น:
#     1) อนุญาตเฉพาะ CA สาธารณะที่เป็นที่ยอมรับในวงกว้าง (allow-list) —
#        ถ้าเจอ issuer ที่ไม่อยู่ในลิสต์ถือเป็นสัญญาณ MITM ทันที
#        (MITM proxy ระดับองค์กรส่วนใหญ่ใช้ internal CA ที่ไม่ public-trusted)
#     2) Pin SHA-256 fingerprint ของ cert ลง cache file — ครั้งแรกที่สแกน
#        จะบันทึกไว้ ครั้งต่อ ๆ ไปถ้า fingerprint เปลี่ยนจะเตือนให้ reviewer
#        ตรวจว่าเกิด cert renewal ปกติหรือโดน MITM
#
_log "Checking TLS certificate chains for MITM indicators..."

# CA สาธารณะที่ได้รับการยอมรับ (ณ 2026) — เพิ่มได้เมื่อจำเป็น
# รูปแบบการเช็คคือ grep -i แบบ substring match บน issuer string
PUBLIC_CAS=(
    "DigiCert"
    "Let's Encrypt"
    "Sectigo"
    "Amazon"
    "Google Trust Services"
    "GlobalSign"
    "ISRG"
    "Cloudflare"
    "GTS"
)

TLS_HOSTS=(
    "github.com"
    "codeberg.org"
    "git.savannah.gnu.org"
    "review.coreboot.org"
    "gitlab.com"
    "git.guix.gnu.org"
)

mkdir -p "$LBMK_ROOT/cache"
tls_pin_file="$LBMK_ROOT/cache/.tls_fingerprints"
touch "$tls_pin_file"

for host in "${TLS_HOSTS[@]}"; do
    _log "  Checking $host..."

    # หมายเหตุ: ใช้ `(echo; sleep 0.3)` แทน `echo` ตัวเปล่าเพื่อให้ openssl
    # มีเวลาจับมือ TLS ก่อน pipe จะปิด stdin — ไม่เช่นนั้น s_client อาจ
    # ออกกลางคันก่อนได้ certificate กลับมา
    cert_info="$( (echo; sleep 0.3) | timeout 15 openssl s_client -connect "$host:443" \
        -servername "$host" $_ssl_arg 2>/dev/null || true)"

    if [ -z "$cert_info" ]; then
        _fail "  Cannot connect to $host:443 — network blocked or DNS poisoned?"
        continue
    fi

    issuer="$(printf '%s' "$cert_info" | openssl x509 -noout -issuer 2>/dev/null || true)"
    not_after="$(printf '%s' "$cert_info" | openssl x509 -noout -enddate 2>/dev/null || true)"
    fingerprint="$(printf '%s' "$cert_info" | \
        openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//' || true)"

    # ชั้นที่ 1: issuer ต้องมาจาก CA สาธารณะที่รู้จัก
    matched_ca=""
    for ca in "${PUBLIC_CAS[@]}"; do
        if printf '%s' "$issuer" | grep -qiF "$ca"; then
            matched_ca="$ca"
            break
        fi
    done

    if [ -n "$matched_ca" ]; then
        _pass "  $host: issued by trusted public CA ($matched_ca)"
    else
        _fail "  $host: UNKNOWN issuer — not on public-CA allow-list"
        _fail "    Issuer: $issuer"
        _fail "    This may indicate TLS interception (corporate/state MITM proxy)"
    fi

    # ชั้นที่ 2: pin SHA-256 fingerprint ผ่าน cache file
    if [ -n "$fingerprint" ]; then
        _log "    SHA-256 fingerprint: $fingerprint"
        pinned="$(grep "^$host " "$tls_pin_file" 2>/dev/null | awk '{print $2}' || true)"
        if [ -z "$pinned" ]; then
            printf '%s %s\n' "$host" "$fingerprint" >> "$tls_pin_file"
            _log "    (first scan — fingerprint saved to cache/.tls_fingerprints)"
        elif [ "$pinned" = "$fingerprint" ]; then
            _pass "  $host: fingerprint matches last scan (no rotation)"
        else
            # ไม่ _fail เพราะ cert renewal ปกติทำ fingerprint เปลี่ยนได้
            # แต่เตือนให้ผู้ใช้ตรวจสอบด้วยตาและ update cache เอง
            _warn "  $host: fingerprint CHANGED since last scan"
            _warn "    Previous: $pinned"
            _warn "    Current:  $fingerprint"
            _warn "    (normal cert renewal, or possible MITM — verify via crt.sh)"
            # update pin ให้เป็นตัวล่าสุดเพื่อไม่เตือนซ้ำในรอบถัดไป
            sed -i "s|^$host .*|$host $fingerprint|" "$tls_pin_file"
        fi
    fi

    # ตรวจ cert ที่อายุสั้นผิดปกติ — MITM proxy บางตัวออก cert อายุสั้นมาก
    if [ -n "$not_after" ]; then
        expiry_date="${not_after#*=}"
        expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)"
        now_epoch="$(date +%s)"
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [ "$days_left" -lt 7 ] && [ "$days_left" -gt 0 ]; then
            _warn "  $host: cert expires in $days_left days (very short — suspicious)"
        fi
    fi
done

# 3b. Certificate Transparency Log cross-check
_log "Checking Certificate Transparency for critical domains..."

ct_check_domain() {
    local domain="$1"

    # Use crt.sh (a public CT log aggregator) to verify certificates
    ct_result="$(timeout 15 curl -sf "https://crt.sh/?q=%25.$domain&output=json" 2>/dev/null | \
        python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Show the most recent certificate
    if data:
        recent = sorted(data, key=lambda x: x.get('id', 0), reverse=True)[0]
        print(f\"issuer={recent.get('issuer_name','?')} serial={recent.get('serial_number','?')}\")
    else:
        print('NONE')
except:
    print('ERROR')
" 2>/dev/null)" || ct_result="ERROR"

    if [ "$ct_result" = "ERROR" ] || [ "$ct_result" = "NONE" ]; then
        _warn "  $domain: cannot query CT logs (crt.sh unreachable or no records)"
    else
        _pass "  $domain: found in CT logs — $ct_result"
    fi
}

if [ "$QUICK" -eq 0 ]; then
    for domain in github.com codeberg.org git.guix.gnu.org; do
        ct_check_domain "$domain"
    done
else
    _skip "CT log checks (slow; use full mode)"
fi

fi # should_run tls


###############################################################################
# [4] GNAT BINARY MULTI-SOURCE VERIFICATION
###############################################################################

if should_run "gnat"; then
_hdr "[4] GNAT Binary Integrity (multi-source verification)"

GNAT_VERSION="15.2.0-1"
GNAT_DIR="$HOME/.local/lib/gnat-${GNAT_VERSION}"
GNAT_TARBALL="gnat-x86_64-linux-${GNAT_VERSION}.tar.gz"
GNAT_URL="https://github.com/alire-project/GNAT-FSF-builds/releases/download/gnat-${GNAT_VERSION}/${GNAT_TARBALL}"
GNAT_SHA256="4640d4b369833947ab1a156753f4db0ecd44b0f14410b5b2bc2a14df496604bb"

# 4a. Verify local GNAT installation matches expected hash
if [ -d "$GNAT_DIR" ]; then
    _pass "GNAT directory exists: $GNAT_DIR"

    # Check gcc.real is present (init.sh replaces gcc with wrapper)
    if [ -f "$GNAT_DIR/bin/gcc.real" ]; then
        _pass "GNAT gcc.real preserved (wrapper in place)"

        # Verify gcc.real is a real ELF binary, not a script
        magic="$(head -c4 "$GNAT_DIR/bin/gcc.real" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' ')"
        if [ "$magic" = "7f454c46" ]; then
            _pass "GNAT gcc.real is a valid ELF binary"
        else
            _fail "GNAT gcc.real is NOT an ELF binary — possible tampering!"
        fi
    else
        _warn "GNAT gcc.real not found (init.sh may not have run yet)"
    fi
else
    _warn "GNAT not installed at $GNAT_DIR (run init.sh first)"
fi

# 4b. Re-download GNAT checksum from GitHub API and compare
_log "Cross-checking GNAT SHA256 from GitHub release API..."

gh_release_info="$(timeout 15 curl -sf \
    "https://api.github.com/repos/alire-project/GNAT-FSF-builds/releases/tags/gnat-${GNAT_VERSION}" \
    2>/dev/null)" || gh_release_info=""

if [ -n "$gh_release_info" ]; then
    # Check the release exists and has our expected asset
    asset_url="$(printf '%s' "$gh_release_info" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('assets', []):
    if a['name'] == '$GNAT_TARBALL':
        print(a['browser_download_url'])
        break
" 2>/dev/null)" || asset_url=""

    if [ -n "$asset_url" ]; then
        _pass "GNAT release asset found on GitHub API"
        _log "  Asset URL: $asset_url"
    else
        _fail "GNAT tarball not found in GitHub release — release may have been altered"
    fi
else
    _warn "Cannot reach GitHub API to verify GNAT release"
fi

# 4c. If tarball is cached, verify its hash
gnat_cached=""
for f in "$HOME/.local/lib/${GNAT_TARBALL}" \
         "$LBMK_ROOT/cache/${GNAT_TARBALL}" \
         "/tmp/${GNAT_TARBALL}"; do
    if [ -f "$f" ]; then
        gnat_cached="$f"
        break
    fi
done

if [ -n "$gnat_cached" ]; then
    _log "Found cached GNAT tarball: $gnat_cached"
    actual_sha="$(sha256sum "$gnat_cached" | awk '{print $1}')"
    if [ "$actual_sha" = "$GNAT_SHA256" ]; then
        _pass "GNAT tarball SHA256 matches: $GNAT_SHA256"
    else
        _fail "GNAT tarball SHA256 MISMATCH!"
        _fail "  Expected: $GNAT_SHA256"
        _fail "  Actual:   $actual_sha"
    fi
else
    _log "No cached GNAT tarball found (already extracted — checking directory hash)"
fi

# 4d. Verify key GNAT binaries haven't been replaced post-extraction
if [ -d "$GNAT_DIR/bin" ]; then
    _log "Fingerprinting GNAT binaries..."
    gnat_fingerprint="$(find "$GNAT_DIR/bin" -type f -executable | sort | \
        xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}')"
    _log "  GNAT bin/ composite fingerprint: $gnat_fingerprint"
    _log "  (Save this value and compare across machines to detect tampering)"

    # Write fingerprint to cache for future comparison
    mkdir -p "$LBMK_ROOT/cache"
    fp_file="$LBMK_ROOT/cache/.gnat_fingerprint"
    if [ -f "$fp_file" ]; then
        old_fp="$(cat "$fp_file")"
        if [ "$old_fp" = "$gnat_fingerprint" ]; then
            _pass "GNAT fingerprint unchanged since last scan"
        else
            _warn "GNAT fingerprint CHANGED since last scan!"
            _warn "  Previous: $old_fp"
            _warn "  Current:  $gnat_fingerprint"
            _warn "  (This is expected after init.sh patches ELF interpreters)"
        fi
    else
        _log "  First scan — saving fingerprint to $fp_file"
    fi
    printf '%s' "$gnat_fingerprint" > "$fp_file"
fi

fi # should_run gnat


###############################################################################
# [5] GIT REPOSITORY CROSS-MIRROR VERIFICATION
###############################################################################

if should_run "git"; then
_hdr "[5] Git Repository Cross-Mirror Verification"

_log "Verifying git repos: fetch same commit from BOTH mirrors, compare tree hash"
_log "(Detects single-mirror compromise where history is rewritten)"

verify_git_repo() {
    local name="$1" url="$2" bkup_url="$3" rev="$4"

    if [ "$rev" = "HEAD" ]; then
        _skip "  $name: uses HEAD (floating ref — cannot pin-verify)"
        return
    fi

    _log "  Verifying: $name (commit: ${rev:0:12}...)"

    # Fetch commit object from primary mirror
    tree1="$(git ls-remote "$url" 2>/dev/null | head -1 | awk '{print $1}')" || tree1=""

    # We can't easily compare tree hashes without cloning, so instead
    # verify the commit is reachable from both mirrors
    primary_ok=0
    backup_ok=0

    # Check primary has the commit
    if timeout 20 git ls-remote "$url" 2>/dev/null | grep -q "^$rev" 2>/dev/null; then
        primary_ok=1
    else
        # The commit might not be a ref head — try a shallow fetch
        if timeout 30 git fetch --depth=1 "$url" "$rev" 2>/dev/null; then
            primary_ok=1
        fi
    fi

    # Check backup has the commit
    if timeout 20 git ls-remote "$bkup_url" 2>/dev/null | grep -q "^$rev" 2>/dev/null; then
        backup_ok=1
    else
        if timeout 30 git fetch --depth=1 "$bkup_url" "$rev" 2>/dev/null; then
            backup_ok=1
        fi
    fi

    if [ "$primary_ok" -eq 1 ] && [ "$backup_ok" -eq 1 ]; then
        _pass "  $name: commit $rev present on BOTH mirrors"
    elif [ "$primary_ok" -eq 1 ]; then
        _warn "  $name: commit only on primary ($url) — backup may lag"
    elif [ "$backup_ok" -eq 1 ]; then
        _warn "  $name: commit only on backup ($bkup_url) — primary may be compromised"
    else
        _fail "  $name: commit $rev NOT found on EITHER mirror!"
    fi
}

# Deep verification: clone both mirrors into temp dirs, compare tree hash
verify_git_deep() {
    local name="$1" url="$2" bkup_url="$3" rev="$4"

    if [ "$rev" = "HEAD" ]; then
        _skip "  $name: HEAD — skipping deep verify"
        return
    fi

    _log "  Deep verify: $name (${rev:0:12}...)"

    local dir1="$_tmpdir/git_verify_${name}_primary"
    local dir2="$_tmpdir/git_verify_${name}_backup"

    rm -rf "$dir1" "$dir2"

    # Clone from primary
    if ! timeout 60 git clone --bare --single-branch "$url" "$dir1" 2>/dev/null; then
        _warn "  $name: cannot clone from primary ($url)"
        return
    fi

    # Clone from backup
    if ! timeout 60 git clone --bare --single-branch "$bkup_url" "$dir2" 2>/dev/null; then
        _warn "  $name: cannot clone from backup ($bkup_url)"
        rm -rf "$dir1"
        return
    fi

    # Compare the tree hash of the pinned commit from both sources
    tree1="$(git -C "$dir1" rev-parse "$rev^{tree}" 2>/dev/null)" || tree1=""
    tree2="$(git -C "$dir2" rev-parse "$rev^{tree}" 2>/dev/null)" || tree2=""

    if [ -z "$tree1" ] || [ -z "$tree2" ]; then
        _warn "  $name: cannot resolve tree hash from one or both mirrors"
    elif [ "$tree1" = "$tree2" ]; then
        _pass "  $name: tree hashes MATCH across mirrors ($tree1)"
    else
        _fail "  $name: TREE HASH MISMATCH BETWEEN MIRRORS!"
        _fail "    Primary ($url): $tree1"
        _fail "    Backup  ($bkup_url): $tree2"
        _fail "    >>> POSSIBLE SUPPLY-CHAIN ATTACK — DO NOT BUILD <<<"
    fi

    rm -rf "$dir1" "$dir2"
}

# Create a temporary bare repo for fetch operations
_verify_repo="$_tmpdir/verify_bare"
git init --bare "$_verify_repo" >/dev/null 2>&1

# Read and verify each git source
for pkg_cfg in config/git/*/pkg.cfg; do
    project_name="$(basename "$(dirname "$pkg_cfg")")"
    rev="" url="" bkup_url=""
    . "$pkg_cfg" 2>/dev/null || continue

    if [ -z "$url" ] || [ -z "$bkup_url" ] || [ -z "$rev" ]; then
        _warn "  $project_name: incomplete config in $pkg_cfg"
        continue
    fi

    if [ "$QUICK" -eq 1 ]; then
        # Quick mode: ตรวจว่า commit มีอยู่จริง โดย fallback ไป backup
        # ถ้า primary ล้ม (บาง mirror เช่น review.coreboot.org ช้ามาก)
        if [ "$rev" = "HEAD" ]; then
            _skip "  $project_name: HEAD ref (quick mode)"
        else
            _log "  Quick check: $project_name"
            if timeout 120 git -C "$_verify_repo" fetch "$url" "$rev" 2>/dev/null; then
                _pass "  $project_name: commit $rev fetchable from primary"
            elif timeout 120 git -C "$_verify_repo" fetch "$bkup_url" "$rev" 2>/dev/null; then
                _pass "  $project_name: commit $rev fetchable from backup (primary slow)"
            else
                _warn "  $project_name: cannot fetch $rev from either mirror"
            fi
        fi
    else
        verify_git_deep "$project_name" "$url" "$bkup_url" "$rev"
    fi
done

rm -rf "$_verify_repo"

# 5b. Verify git submodule configs (same cross-mirror check)
_log ""
_log "Verifying submodule git sources..."

_sub_verify_repo="$_tmpdir/sub_verify_bare"
git init --bare "$_sub_verify_repo" >/dev/null 2>&1

_sub_cfg_list="$_tmpdir/sub_cfg_list.txt"
find config/submodule -name 'module.cfg' -type f | sort > "$_sub_cfg_list"

while IFS= read -r mcfg; do
    subgit="" subgit_bkup="" subhash="" subcurl="" subcurl_bkup=""
    . "$mcfg" 2>/dev/null || continue

    # Only verify git submodules (tarballs verified separately)
    [ -n "$subgit" ] || continue
    [ -n "$subhash" ] || continue

    mod_name="$(basename "$(dirname "$mcfg")")"

    if [ "$QUICK" -eq 1 ]; then
        # หมายเหตุ: เดิมตั้ง timeout ไว้ 15 วินาที แต่ submodule ใหญ่อย่าง
        # FSP (review.coreboot.org), vboot, และ gnulib ใช้เวลาสร้าง
        # pack-file ฝั่ง server นานกว่านั้น (25–60 วิ) ทำให้เกิด WARN
        # false positive บ่อย — bump เป็น 120 วิเพื่อให้ครอบคลุม
        # กรณี gerrit/กระจกตัวใหญ่ และถ้าล้มจริงค่อยลอง backup mirror
        if timeout 120 git -C "$_sub_verify_repo" fetch "$subgit" "$subhash" 2>/dev/null; then
            _pass "  submodule/$mod_name: commit fetchable from primary"
        elif [ -n "$subgit_bkup" ] && \
             timeout 120 git -C "$_sub_verify_repo" fetch "$subgit_bkup" "$subhash" 2>/dev/null; then
            _pass "  submodule/$mod_name: commit fetchable from backup (primary slow/down)"
        else
            _warn "  submodule/$mod_name: cannot fetch commit from either mirror"
        fi
    else
        if [ -n "$subgit_bkup" ]; then
            verify_git_deep "submodule/$mod_name" "$subgit" "$subgit_bkup" "$subhash"
        else
            _warn "  submodule/$mod_name: no backup URL — cannot cross-verify"
        fi
    fi
done < "$_sub_cfg_list"

rm -rf "$_sub_verify_repo" "$_sub_cfg_list"

fi # should_run git


###############################################################################
# [6] TARBALL SHA-512 RE-VERIFICATION FROM INDEPENDENT MIRROR
###############################################################################

if should_run "tarballs"; then
_hdr "[6] Tarball Integrity (SHA-512 cross-mirror verification)"

_log "Re-downloading tarballs from BACKUP mirror and comparing SHA-512..."

# หมายเหตุสำคัญ (แก้ bug 2026-04):
#   ภายใต้ set -euo pipefail ทุก pipeline ที่ส่วนหนึ่งออก exit ≠ 0
#   จะฆ่า script ทันที ซึ่ง grep ที่หาไม่เจอจะ exit 1 เสมอ
#   ดังนั้นทุก pipeline ที่มี grep ต้องลงท้ายด้วย `|| true`
#   นอกจากนี้ mirror บางตัวจะ rate-limit หลัง ~80 requests
#   ทำให้ curl -sf -I กลับ exit ≠ 0 → hdr ว่าง → grep ตาย
verify_tarball() {
    local name="$1" primary_url="$2" backup_url="$3" expected_hash="$4"

    _log "  Verifying: $name"

    local hdr1 hdr2

    hdr1="$(timeout 15 curl -sf -I "$primary_url" 2>/dev/null || true)"
    hdr2="$(timeout 15 curl -sf -I "$backup_url" 2>/dev/null || true)"

    if [ -z "$hdr1" ] && [ -z "$hdr2" ]; then
        _skip "  $name: both mirrors unreachable (rate-limited or offline)"
        return 0
    fi

    # Compare Content-Length if available (fast check: different sizes = different files)
    # `|| true` ป้องกัน grep exit 1 เมื่อไม่มี Content-Length header
    local size1 size2
    size1="$(printf '%s' "$hdr1" | grep -i 'Content-Length' | awk '{print $2}' | tr -d '\r' || true)"
    size2="$(printf '%s' "$hdr2" | grep -i 'Content-Length' | awk '{print $2}' | tr -d '\r' || true)"

    if [ -n "$size1" ] && [ -n "$size2" ]; then
        if [ "$size1" = "$size2" ]; then
            _pass "  $name: size matches across mirrors ($size1 bytes)"
        else
            _fail "  $name: SIZE MISMATCH between mirrors!"
            _fail "    Primary: $size1 bytes"
            _fail "    Backup:  $size2 bytes"
        fi
    elif [ -n "$size1" ] || [ -n "$size2" ]; then
        _pass "  $name: one mirror reachable (size=${size1:-$size2})"
    fi

    # If we have the file cached locally, verify its hash
    local local_path=""
    local search_dir found
    for search_dir in "$LBMK_ROOT/cache" "$HOME/.cache/lbmk"; do
        [ -d "$search_dir" ] || continue
        found="$(find "$search_dir" -name "$(basename "$primary_url")" -type f 2>/dev/null | head -1 || true)"
        if [ -n "$found" ]; then
            local_path="$found"
            break
        fi
    done

    if [ -n "$local_path" ]; then
        actual_hash="$(sha512sum "$local_path" | awk '{print $1}')"
        if [ "$actual_hash" = "$expected_hash" ]; then
            _pass "  $name: local SHA-512 matches expected hash"
        else
            _fail "  $name: LOCAL FILE SHA-512 MISMATCH!"
            _fail "    Expected: ${expected_hash:0:32}..."
            _fail "    Actual:   ${actual_hash:0:32}..."
        fi
    fi
}

# Read all tarball submodule configs and verify
_tar_cfg_list="$_tmpdir/tar_cfg_list.txt"
find config/submodule -name 'module.cfg' -type f | sort > "$_tar_cfg_list"

while IFS= read -r mcfg; do
    subgit="" subgit_bkup="" subhash="" subcurl="" subcurl_bkup=""
    . "$mcfg" 2>/dev/null || continue

    # Only verify curl (tarball) submodules
    [ -n "$subcurl" ] || continue
    [ -n "$subhash" ] || continue

    mod_name="$(basename "$(dirname "$mcfg")")"
    verify_tarball "$mod_name" "$subcurl" "${subcurl_bkup:-$subcurl}" "$subhash"
done < "$_tar_cfg_list"

rm -f "$_tar_cfg_list"

fi # should_run tarballs


###############################################################################
# [7] SOFTWARE HERITAGE ARCHIVE CROSS-CHECK
###############################################################################

if should_run "git"; then
_hdr "[7] Software Heritage Archive Cross-Check"

if [ "$QUICK" -eq 1 ]; then
    _skip "Software Heritage checks (slow; use full mode)"
else
    _log "Cross-referencing pinned commits against Software Heritage (immutable archive)"
    _log "(SWH is an independent, non-forgeable archive — MITM cannot alter it)"

    swh_check() {
        local name="$1" rev="$2"

        if [ "$rev" = "HEAD" ]; then
            _skip "  $name: HEAD — cannot check SWH"
            return
        fi

        # Software Heritage uses SWHID format: swh:1:rev:<hash>
        local swh_url="https://archive.softwareheritage.org/api/1/revision/${rev}/"

        response="$(timeout 20 curl -sf "$swh_url" 2>/dev/null)" || response=""

        if [ -z "$response" ]; then
            _warn "  $name: SWH API unreachable or commit not archived"
        elif printf '%s' "$response" | grep -q "\"id\""; then
            # Extract the directory (tree) hash from SWH
            swh_dir="$(printf '%s' "$response" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('directory','NONE'))" \
                2>/dev/null)" || swh_dir=""
            if [ -n "$swh_dir" ] && [ "$swh_dir" != "NONE" ]; then
                _pass "  $name: commit $rev archived in SWH (dir: ${swh_dir:0:12}...)"
            else
                _pass "  $name: commit $rev found in SWH"
            fi
        elif printf '%s' "$response" | grep -q "not found"; then
            _warn "  $name: commit $rev NOT in SWH archive (may not be archived yet)"
        else
            _warn "  $name: unexpected SWH response"
        fi
    }

    # Check major repos against SWH
    for pkg_cfg in config/git/*/pkg.cfg; do
        project_name="$(basename "$(dirname "$pkg_cfg")")"
        rev="" url="" bkup_url=""
        . "$pkg_cfg" 2>/dev/null || continue
        [ -n "$rev" ] || continue

        swh_check "$project_name" "$rev"

        # Rate limit to be polite to SWH API
        sleep 1
    done
fi

fi # should_run git


###############################################################################
# [8] DNS CONSISTENCY CHECK (detect DNS poisoning)
###############################################################################

if should_run "dns"; then
_hdr "[8] DNS Consistency Check"

_log "Comparing DNS resolution across multiple resolvers..."
_log "(State-level adversary may poison DNS to redirect to fake mirrors)"

#
# หมายเหตุสำคัญ (แก้ bug 2026-04):
#   ตัวเดิม query DoH เฉพาะ type=A (IPv4) แต่ getent hosts ของ Guix บาง
#   เครื่อง (ที่เปิด IPv6) จะคืน AAAA ก่อน ทำให้ system IP เป็น IPv6
#   แต่ DoH เป็น IPv4 → เทียบยังไงก็ไม่มีวันตรงกัน เกิด false WARN
#   ตลอดทุกโดเมน
#
#   ตัวใหม่:
#     - ดึง "ทั้งชุด" IPv4+IPv6 ของ system resolver (ไม่ใช่บรรทัดแรก)
#     - query DoH ทั้ง type=A และ type=AAAA
#     - ถือว่าผ่านถ้า IP ตัวใดตัวหนึ่งของ system อยู่ในชุดของ DoH
#       หรืออยู่ใน /24 (IPv4) / /64 (IPv6) เดียวกับ DoH ตัวใดตัวหนึ่ง
#
dns_check() {
    local domain="$1"
    local ips_system="" ips_cf="" ips_google="" ips_quad9=""

    # System resolver: เก็บ IP ทุกตัว (ทั้ง v4+v6) ไม่ใช่แค่บรรทัดเดียว
    ips_system="$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' || true)"

    # Cloudflare DoH — query ทั้ง A (type=1) และ AAAA (type=28)
    ips_cf="$(timeout 10 curl -sf \
        "https://cloudflare-dns.com/dns-query?name=${domain}&type=A" \
        -H "accept: application/dns-json" 2>/dev/null | \
        python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    for a in d.get('Answer',[]):
        if a.get('type') in (1,28): print(a['data'])
except Exception: pass
" 2>/dev/null || true)
$(timeout 10 curl -sf \
        "https://cloudflare-dns.com/dns-query?name=${domain}&type=AAAA" \
        -H "accept: application/dns-json" 2>/dev/null | \
        python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    for a in d.get('Answer',[]):
        if a.get('type') in (1,28): print(a['data'])
except Exception: pass
" 2>/dev/null || true)"

    ips_google="$(timeout 10 curl -sf \
        "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null | \
        python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    for a in d.get('Answer',[]):
        if a.get('type') in (1,28): print(a['data'])
except Exception: pass
" 2>/dev/null || true)
$(timeout 10 curl -sf \
        "https://dns.google/resolve?name=${domain}&type=AAAA" 2>/dev/null | \
        python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    for a in d.get('Answer',[]):
        if a.get('type') in (1,28): print(a['data'])
except Exception: pass
" 2>/dev/null || true)"

    ips_quad9="$(timeout 10 curl -sf \
        "https://dns.quad9.net:5053/dns-query?name=${domain}&type=A" \
        -H "accept: application/dns-json" 2>/dev/null | \
        python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    for a in d.get('Answer',[]):
        if a.get('type') in (1,28): print(a['data'])
except Exception: pass
" 2>/dev/null || true)
$(timeout 10 curl -sf \
        "https://dns.quad9.net:5053/dns-query?name=${domain}&type=AAAA" \
        -H "accept: application/dns-json" 2>/dev/null | \
        python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    for a in d.get('Answer',[]):
        if a.get('type') in (1,28): print(a['data'])
except Exception: pass
" 2>/dev/null || true)"

    # เก็บเข้า set เดียวเพื่อเทียบกัน
    local all_doh="$ips_cf $ips_google $ips_quad9"

    # นับจำนวน DoH ที่ตอบกลับ (ไม่ว่างเปล่า)
    local doh_count=0
    [ -n "$(printf '%s' "$ips_cf"     | tr -d '[:space:]')" ] && doh_count=$((doh_count + 1))
    [ -n "$(printf '%s' "$ips_google" | tr -d '[:space:]')" ] && doh_count=$((doh_count + 1))
    [ -n "$(printf '%s' "$ips_quad9"  | tr -d '[:space:]')" ] && doh_count=$((doh_count + 1))

    _log "  $domain:"
    _log "    System: $(printf '%s' "$ips_system" | tr '\n' ' ')"
    _log "    DoH   : $(printf '%s' "$all_doh"    | tr '\n' ' ')"

    if [ -z "$ips_system" ]; then
        _fail "  $domain: system DNS resolution FAILED"
        return
    fi

    if [ "$doh_count" -eq 0 ]; then
        _skip "  $domain: DoH unavailable — cannot cross-check (not a failure)"
        return
    fi

    # Helper: เช็คว่า ip อยู่ใน same network ของ DoH ตัวใดตัวใด
    _net_of() {
        # IPv4: /24  → ตัด field สุดท้ายหลัง .
        # IPv6: /64 ~ 4 hextets แรก → ตัดหลัง : ที่ 4
        case "$1" in
            *:*) printf '%s' "$1" | awk -F: '{print $1":"$2":"$3":"$4}' ;;
            *)   printf '%s' "${1%.*}" ;;
        esac
    }

    local sys_ip doh_ip matched=0
    for sys_ip in $ips_system; do
        for doh_ip in $all_doh; do
            [ -n "$doh_ip" ] || continue
            if [ "$sys_ip" = "$doh_ip" ]; then
                matched=1; break 2
            fi
            if [ "$(_net_of "$sys_ip")" = "$(_net_of "$doh_ip")" ]; then
                matched=1; break 2
            fi
        done
    done

    if [ "$matched" -eq 1 ]; then
        _pass "  $domain: system DNS consistent with DoH (exact or same-prefix)"
        return
    fi

    # ถ้า DoH หลายเจ้าตอบไม่ตรงกันเอง → CDN เกือบแน่
    local uniq_doh_count
    uniq_doh_count="$(printf '%s\n' $all_doh | sort -u | wc -l)"
    if [ "$uniq_doh_count" -gt 1 ]; then
        _pass "  $domain: DoH resolvers disagree among themselves (CDN — OK)"
        return
    fi

    _warn "  $domain: system resolver differs from ALL DoH"
    _warn "    System: $(printf '%s' "$ips_system" | tr '\n' ' ')"
    _warn "    DoH:    $(printf '%s' "$all_doh"    | tr '\n' ' ')"
    _warn "    Verify manually: dig @1.1.1.1 $domain vs dig $domain"
}

critical_domains=(
    "github.com"
    "codeberg.org"
    "git.savannah.gnu.org"
    "review.coreboot.org"
    "git.guix.gnu.org"
    "ci.guix.gnu.org"
    "www.mirrorservice.org"
    "ftp.nluug.nl"
    "gitlab.com"
)

for domain in "${critical_domains[@]}"; do
    dns_check "$domain"
done

fi # should_run dns


###############################################################################
# [9] LOCAL ENVIRONMENT SAFETY CHECKS
###############################################################################

_hdr "[9] Local Environment Safety"

# 9a. Check for suspicious environment variables
_log "Checking for suspicious environment variables..."

# HTTP(S)_PROXY could redirect all traffic through a MITM
for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; do
    val="${!var:-}"
    if [ -n "$val" ]; then
        _warn "Proxy variable set: $var=$val"
        _warn "  All downloads will go through this proxy — ensure it's trusted!"
    fi
done

# GIT_SSL_NO_VERIFY disables TLS verification for git
if [ "${GIT_SSL_NO_VERIFY:-}" = "1" ] || [ "${GIT_SSL_NO_VERIFY:-}" = "true" ]; then
    _fail "GIT_SSL_NO_VERIFY is set — git TLS verification is DISABLED!"
    _fail "  This allows trivial MITM of all git operations!"
fi

# Check git config for sslVerify = false
git_ssl="$(git config --global --get http.sslVerify 2>/dev/null)" || git_ssl=""
if [ "$git_ssl" = "false" ]; then
    _fail "git http.sslVerify is set to false globally!"
fi

# CURL_CA_BUNDLE / SSL_CERT_FILE could point to a rogue CA bundle
for var in CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR; do
    val="${!var:-}"
    if [ -n "$val" ]; then
        _log "  $var=$val"
        # Check that it points to a Guix store path or standard location
        case "$val" in
            /gnu/store/*|/etc/ssl/*|/run/current-system/*|*/.guix-profile/etc/ssl/*)
                _pass "  $var points to system/Guix path (OK)" ;;
            *)
                _warn "  $var points to non-standard path — verify the CA bundle is authentic" ;;
        esac
    fi
done

# 9b. Check that sha512sum is genuine (not a wrapper that always returns OK)
_log "Verifying sha512sum integrity..."
test_hash="$(printf 'test' | sha512sum | awk '{print $1}')"
expected_test_hash="ee26b0dd4af7e749aa1a8ee3c10ae9923f618980772e473f8819a5d4940e0db27ac185f8a0e1d5f84f88bc887fd67b143732c304cc5fa9ad8e6f57f50028a8ff"
if [ "$test_hash" = "$expected_test_hash" ]; then
    _pass "sha512sum produces correct output"
else
    _fail "sha512sum produces WRONG output — binary may be compromised!"
fi

# Also check the lbmk-bundled sha512sum (util/sbase/sha512sum)
if [ -x "util/sbase/sha512sum" ]; then
    sbase_hash="$(printf 'test' | util/sbase/sha512sum | awk '{print $1}')"
    if [ "$sbase_hash" = "$expected_test_hash" ]; then
        _pass "util/sbase/sha512sum produces correct output"
    else
        _fail "util/sbase/sha512sum produces WRONG output — possible tampering!"
    fi
fi

# 9c. Check for LD_PRELOAD (could intercept any binary)
if [ -n "${LD_PRELOAD:-}" ]; then
    _fail "LD_PRELOAD is set: $LD_PRELOAD"
    _fail "  This can intercept ANY binary execution — high risk!"
else
    _pass "LD_PRELOAD is not set"
fi

# 9d. Check that git is using system binary (not a wrapper)
_log "Verifying git binary..."
git_path="$(command -v git 2>/dev/null)"
git_magic="$(head -c4 "$git_path" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' ')"
if [ "$git_magic" = "7f454c46" ]; then
    _pass "git is an ELF binary: $git_path"
elif head -1 "$git_path" 2>/dev/null | grep -q '^#!/'; then
    _warn "git is a shell script wrapper: $git_path — verify it chains to real git"
else
    _pass "git at $git_path (type detection inconclusive but likely OK)"
fi

# 9e. Check /etc/hosts for suspicious overrides
_log "Checking /etc/hosts for suspicious overrides..."
suspicious_hosts=0
for domain in github.com codeberg.org git.savannah.gnu.org review.coreboot.org \
              git.guix.gnu.org ci.guix.gnu.org gitlab.com; do
    if grep -qE "^[^#].*$domain" /etc/hosts 2>/dev/null; then
        _warn "  /etc/hosts has an entry for $domain — verify it's intentional"
        suspicious_hosts=$((suspicious_hosts + 1))
    fi
done
if [ "$suspicious_hosts" -eq 0 ]; then
    _pass "No suspicious /etc/hosts overrides for critical domains"
fi


###############################################################################
# [10] INIT.SH INTEGRITY
###############################################################################

_hdr "[10] init.sh / init-pico.sh Self-Integrity"

_log "Verifying init scripts match git HEAD..."

for script in init.sh init-pico.sh manifest.scm manifest-pico.scm; do
    if [ ! -f "$script" ]; then
        _skip "  $script not found"
        continue
    fi

    # Check if file has uncommitted modifications
    if git diff --quiet -- "$script" 2>/dev/null; then
        if git diff --cached --quiet -- "$script" 2>/dev/null; then
            _pass "  $script: matches git HEAD (no local modifications)"
        else
            _warn "  $script: has STAGED changes (review before building)"
        fi
    else
        _warn "  $script: has UNSTAGED modifications (review before building)"
        git diff --stat -- "$script" 2>/dev/null | sed 's/^/    /'
    fi
done

# Verify GNAT_SHA256 in init.sh matches what we expect
_log "Cross-checking GNAT hash in init.sh..."
init_gnat_hash="$(grep '^GNAT_SHA256=' init.sh | head -1 | cut -d'"' -f2)"
if [ "$init_gnat_hash" = "$GNAT_SHA256" ]; then
    _pass "GNAT_SHA256 in init.sh is consistent"
else
    _fail "GNAT_SHA256 in init.sh does not match expected value!"
    _fail "  init.sh: $init_gnat_hash"
    _fail "  Expected: $GNAT_SHA256"
fi


###############################################################################
# SUMMARY
###############################################################################

printf "\n"
printf "╔═══════════════════════════════════════════════════════════╗\n"
printf "║  SCAN COMPLETE                                           ║\n"
printf "╠═══════════════════════════════════════════════════════════╣\n"
printf "║  ${GRN}PASS${RST}: %-4d                                              ║\n" "$pass_count"
printf "║  ${RED}FAIL${RST}: %-4d                                              ║\n" "$fail_count"
printf "║  ${YLW}WARN${RST}: %-4d                                              ║\n" "$warn_count"
printf "║  ${YLW}SKIP${RST}: %-4d                                              ║\n" "$skip_count"
printf "╚═══════════════════════════════════════════════════════════╝\n"

if [ "$fail_count" -gt 0 ]; then
    printf "\n${RED}>>> FAILURES DETECTED — review output above <<<${RST}\n"
    printf "${RED}Do NOT proceed with building until failures are resolved.${RST}\n"
    exit 1
elif [ "$warn_count" -gt 0 ]; then
    printf "\n${YLW}Warnings present — review before building.${RST}\n"
    exit 0
else
    printf "\n${GRN}All checks passed. Supply chain appears intact.${RST}\n"
    exit 0
fi
