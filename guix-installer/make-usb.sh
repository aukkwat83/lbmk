#!/bin/bash
# =============================================================================
# make-usb.sh — สร้าง Guix System Installer USB สำหรับ Libreboot
# =============================================================================
#
# สคริปต์นี้จะ:
#   1. ดาวน์โหลด Guix System installer ISO (ถ้ายังไม่มี)
#   2. เขียน ISO ลง USB flash drive
#   3. สร้าง partition เพิ่มบน USB สำหรับเก็บ config + install script
#
# ใช้งาน:
#   sudo ./make-usb.sh /dev/sdX
#
# คำเตือน: ข้อมูลทั้งหมดบน USB จะถูกลบ!
# =============================================================================

set -euo pipefail

# --- สี ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Guix installer version ---
GUIX_VERSION="1.4.0"
GUIX_ISO="guix-system-install-${GUIX_VERSION}.x86_64-linux.iso"
GUIX_ISO_URL="https://ftp.gnu.org/gnu/guix/${GUIX_ISO}"
GUIX_SIG_URL="${GUIX_ISO_URL}.sig"

# --- GPG signing key (Ludovic Courtès — Guix release manager) ---
# https://guix.gnu.org/manual/en/html_node/USB-Stick-and-DVD-Installation.html
GUIX_KEY_FINGERPRINT="3CE464558A84FDC69DB40CFB090B11993D9AEBB5"
GUIX_KEY_URL="https://sv.gnu.org/people/viewgpg.php?user_id=15145"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================================
# Functions
# =============================================================================

die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

usage() {
    cat <<'USAGE'
Usage: sudo ./make-usb.sh /dev/sdX

  /dev/sdX    USB flash drive device (e.g., /dev/sdc)

สคริปต์จะ:
  1. ดาวน์โหลด Guix System installer ISO
  2. เขียน ISO ลง USB
  3. เพิ่ม partition สำหรับ config + install script

คำเตือน: ข้อมูลทั้งหมดบน USB จะถูกลบ!
USAGE
    exit 1
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "ต้องรันด้วย sudo หรือ root"
    fi
}

check_device() {
    local dev="$1"

    if [ ! -b "$dev" ]; then
        die "$dev ไม่ใช่ block device"
    fi

    # ป้องกันเขียนลง system disk
    local root_dev
    root_dev="$(findmnt -no SOURCE / | sed 's/[0-9]*$//' | sed 's/p$//')"
    if [ "$dev" = "$root_dev" ]; then
        die "ห้ามเขียนลง system disk ($root_dev)!"
    fi

    # แสดงข้อมูล device
    echo ""
    echo -e "${YELLOW}=== USB Device ===${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$dev"
    echo ""

    echo -e "${RED}คำเตือน: ข้อมูลทั้งหมดบน $dev จะถูกลบ!${NC}"
    read -rp "พิมพ์ YES เพื่อยืนยัน: " confirm
    if [ "$confirm" != "YES" ]; then
        die "ยกเลิกโดยผู้ใช้"
    fi
}

import_guix_key() {
    local gnupg_dir="$1"

    info "นำเข้า Guix signing key (${GUIX_KEY_FINGERPRINT:0:16}...)..."

    # ลองดาวน์โหลดจาก GNU Savannah ก่อน
    if wget -qO - "$GUIX_KEY_URL" | gpg --homedir "$gnupg_dir" --import - 2>/dev/null; then
        ok "นำเข้า signing key จาก sv.gnu.org สำเร็จ"
        return 0
    fi

    # fallback: ลองจาก keyserver
    info "ลองดาวน์โหลดจาก keyserver แทน..."
    if gpg --homedir "$gnupg_dir" --keyserver hkps://keys.openpgp.org \
           --recv-keys "$GUIX_KEY_FINGERPRINT" 2>/dev/null; then
        ok "นำเข้า signing key จาก keyserver สำเร็จ"
        return 0
    fi

    return 1
}

verify_iso() {
    local iso_path="$1"
    local sig_path="${iso_path}.sig"

    # สร้าง temporary GPG homedir เพื่อไม่ยุ่งกับ keyring ของผู้ใช้
    local gnupg_tmp
    gnupg_tmp="$(mktemp -d)"
    chmod 700 "$gnupg_tmp"
    trap "rm -rf '$gnupg_tmp'" RETURN

    # ดาวน์โหลด signature ถ้ายังไม่มี
    if [ ! -f "$sig_path" ]; then
        info "ดาวน์โหลด GPG signature..."
        wget -q -O "$sig_path" "$GUIX_SIG_URL" \
            || die "ดาวน์โหลด GPG signature ไม่สำเร็จ"
    fi

    # นำเข้า signing key
    import_guix_key "$gnupg_tmp" \
        || die "ไม่สามารถนำเข้า Guix signing key ได้ — ตรวจสอบการเชื่อมต่อ internet"

    # ตรวจสอบว่า key ที่ได้มาตรง fingerprint ที่คาดไว้
    if ! gpg --homedir "$gnupg_tmp" --fingerprint "$GUIX_KEY_FINGERPRINT" >/dev/null 2>&1; then
        die "Signing key ไม่ตรงกับ fingerprint ที่คาดไว้ — อาจถูกปลอมแปลง!"
    fi

    # Verify signature
    info "ตรวจสอบ GPG signature..."
    if gpg --homedir "$gnupg_tmp" --verify "$sig_path" "$iso_path" 2>/dev/null; then
        ok "GPG signature ถูกต้อง — ISO มาจาก GNU Guix โดยตรง"
    else
        die "GPG signature ไม่ถูกต้อง! ISO อาจถูกแก้ไขหรือเสียหาย — หยุดทำงาน"
    fi
}

download_iso() {
    local iso_path="${SCRIPT_DIR}/${GUIX_ISO}"

    if [ -f "$iso_path" ]; then
        info "พบ ISO อยู่แล้ว: $iso_path"
        verify_iso "$iso_path"
        return
    fi

    info "ดาวน์โหลด Guix System installer ISO..."
    info "URL: ${GUIX_ISO_URL}"

    wget -c -O "$iso_path" "$GUIX_ISO_URL" \
        || die "ดาวน์โหลด ISO ไม่สำเร็จ"

    verify_iso "$iso_path"

    ok "ดาวน์โหลดสำเร็จ: $iso_path"
}

write_iso_to_usb() {
    local dev="$1"
    local iso_path="${SCRIPT_DIR}/${GUIX_ISO}"

    # Unmount ทุก partition ก่อน
    info "Unmount ทุก partition บน $dev..."
    umount "${dev}"* 2>/dev/null || true

    info "เขียน ISO ลง $dev (อาจใช้เวลาหลายนาที)..."
    dd if="$iso_path" of="$dev" bs=4M status=progress oflag=sync \
        || die "เขียน ISO ไม่สำเร็จ"

    sync
    ok "เขียน ISO สำเร็จ"
}

add_config_partition() {
    local dev="$1"

    info "รอให้ kernel อ่าน partition table ใหม่..."
    partprobe "$dev" 2>/dev/null || true
    sleep 2

    # หาขนาด ISO เพื่อคำนวณตำแหน่งเริ่มต้น partition ใหม่
    local iso_path="${SCRIPT_DIR}/${GUIX_ISO}"
    local iso_size_bytes
    iso_size_bytes="$(stat -c %s "$iso_path")"
    # ปัดขึ้นเป็น MiB + เว้นว่าง 16 MiB
    local start_mib=$(( (iso_size_bytes / 1048576) + 16 ))

    info "สร้าง partition สำหรับ config files (เริ่มที่ ${start_mib} MiB)..."

    # สร้าง partition ใหม่ต่อท้าย ISO ด้วย sfdisk
    local start_sectors=$(( start_mib * 2048 ))
    local size_sectors=$(( 512 * 2048 ))
    echo "${start_sectors},${size_sectors},L" | sfdisk --append "$dev" \
        || die "สร้าง partition ไม่สำเร็จ"

    partprobe "$dev" 2>/dev/null || true
    sleep 2

    # หา partition ใหม่ที่สร้าง
    local config_part
    # ลองหา partition ล่าสุด
    config_part="$(lsblk -lnpo NAME "$dev" | tail -1)"

    if [ -z "$config_part" ] || [ "$config_part" = "$dev" ]; then
        die "ไม่พบ config partition ที่สร้างใหม่"
    fi

    info "Format config partition: $config_part"
    mkfs.ext2 -L "GUIX-CONFIG" "$config_part" \
        || die "Format ไม่สำเร็จ"

    # Mount และ copy config files
    local mount_point="/tmp/guix-config-$$"
    mkdir -p "$mount_point"
    mount "$config_part" "$mount_point" \
        || die "Mount ไม่สำเร็จ"

    info "Copy config files..."
    cp "${SCRIPT_DIR}/libreboot-system.scm" "$mount_point/"
    cp "${SCRIPT_DIR}/install.sh" "$mount_point/"
    chmod +x "$mount_point/install.sh"

    # สร้าง README
    cat > "$mount_point/README.txt" <<'README'
Guix System Installer for Libreboot
====================================

หลังจาก boot เข้า Guix installer แล้ว:

1. ตั้งค่า network:
   ifconfig ens0 up
   dhclient ens0

2. Mount config partition นี้:
   mkdir -p /tmp/config
   mount /dev/sdX3 /tmp/config    # แก้ sdX3 ตามจริง

3. รัน install script:
   cd /tmp/config
   ./install.sh /dev/sdY           # sdY = target disk ที่จะติดตั้ง

4. Reboot:
   reboot

README

    sync
    umount "$mount_point"
    rmdir "$mount_point"

    ok "Config partition สร้างเสร็จ (label: GUIX-CONFIG)"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN} Guix Installer USB — Libreboot Edition ${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo ""

    if [ $# -lt 1 ]; then
        usage
    fi

    local target_dev="$1"

    check_root
    check_device "$target_dev"

    echo ""
    info "=== Step 1/3: ดาวน์โหลด ISO ==="
    download_iso

    echo ""
    info "=== Step 2/3: เขียน ISO ลง USB ==="
    write_iso_to_usb "$target_dev"

    echo ""
    info "=== Step 3/3: เพิ่ม Config Partition ==="
    add_config_partition "$target_dev"

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN} USB Installer สร้างเสร็จ!              ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo "ขั้นตอนถัดไป:"
    echo "  1. Boot จาก USB นี้ (Libreboot -> SeaBIOS -> USB)"
    echo "  2. เชื่อมต่อ network ใน installer"
    echo "  3. Mount config partition:"
    echo "     mkdir -p /tmp/config"
    echo "     mount LABEL=GUIX-CONFIG /tmp/config"
    echo "  4. รัน install script:"
    echo "     /tmp/config/install.sh /dev/sdX"
    echo ""
    echo "Partition layout บน USB:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$target_dev"
    echo ""
}

main "$@"
