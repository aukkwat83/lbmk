#!/bin/bash
# =============================================================================
# install.sh — ติดตั้ง Guix System สำหรับ Libreboot (SeaGRUB)
# =============================================================================
#
# สคริปต์นี้จะ:
#   1. แบ่ง partition: /boot (ext2, 1 GiB) + / (ext4, ส่วนที่เหลือ)
#   2. Format ทั้งสอง partition
#   3. สร้าง config จาก template พร้อม UUID จริง
#   4. Mount และรัน guix system init
#
# Boot chain ของ Libreboot SeaGRUB:
#   [Libreboot ROM] -> SeaBIOS -> GRUB (MBR) -> linux-libre (/boot)
#
# ใช้งาน (ในตัว Guix installer):
#   ./install.sh /dev/sdX
#
# =============================================================================

set -euo pipefail

# --- สี ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/libreboot-system.scm"
MOUNT_POINT="/mnt"

# --- Partition sizes ---
BOOT_SIZE="1GiB"

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
Usage: ./install.sh /dev/sdX

  /dev/sdX    Target disk สำหรับติดตั้ง Guix System

Partition layout ที่จะสร้าง:
  sdX1  /boot  ext2  1 GiB   (GRUB + kernel, ไม่มี journal)
  sdX2  /      ext4  ที่เหลือ  (root filesystem)

คำเตือน: ข้อมูลทั้งหมดบน disk เป้าหมายจะถูกลบ!
USAGE
    exit 1
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "ต้องรันด้วย root (sudo)"
    fi
}

check_template() {
    if [ ! -f "$TEMPLATE" ]; then
        die "ไม่พบ template: $TEMPLATE"
    fi
}

check_device() {
    local dev="$1"

    if [ ! -b "$dev" ]; then
        die "$dev ไม่ใช่ block device"
    fi

    # ป้องกันเขียนลง USB installer
    if findmnt -no SOURCE /tmp/config 2>/dev/null | grep -q "$dev"; then
        die "$dev คือ USB installer — ห้ามติดตั้งทับ!"
    fi

    echo ""
    echo -e "${BOLD}=== Target Disk ===${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$dev"
    echo ""
    echo -e "${BOLD}Partition layout ที่จะสร้าง:${NC}"
    echo "  ${dev}1  /boot  ext2  ${BOOT_SIZE}  (GRUB + kernel)"
    echo "  ${dev}2  /      ext4  ที่เหลือทั้งหมด"
    echo ""
    echo -e "${RED}คำเตือน: ข้อมูลทั้งหมดบน $dev จะถูกลบ!${NC}"
    read -rp "พิมพ์ YES เพื่อยืนยัน: " confirm
    if [ "$confirm" != "YES" ]; then
        die "ยกเลิกโดยผู้ใช้"
    fi
}

# --- Step 1: Partition ---
do_partition() {
    local dev="$1"

    info "=== Step 1/5: แบ่ง Partition ==="

    # Unmount ทุกอย่างก่อน
    umount "${dev}"* 2>/dev/null || true
    umount "${MOUNT_POINT}/boot" 2>/dev/null || true
    umount "${MOUNT_POINT}" 2>/dev/null || true

    info "สร้าง MBR partition table บน $dev..."
    parted -s "$dev" mklabel msdos

    info "สร้าง /boot partition (ext2, ${BOOT_SIZE})..."
    parted -s "$dev" mkpart primary ext2 1MiB "$BOOT_SIZE"
    parted -s "$dev" set 1 boot on

    info "สร้าง / partition (ext4, ที่เหลือทั้งหมด)..."
    parted -s "$dev" mkpart primary ext4 "$BOOT_SIZE" 100%

    partprobe "$dev" 2>/dev/null || true
    sleep 2

    ok "แบ่ง partition สำเร็จ"
    parted -s "$dev" print
}

# --- Step 2: Format ---
do_format() {
    local dev="$1"

    info "=== Step 2/5: Format Partition ==="

    # หา partition names (รองรับทั้ง sdX1 และ nvme0n1p1)
    local part1 part2
    if [ -b "${dev}1" ]; then
        part1="${dev}1"
        part2="${dev}2"
    elif [ -b "${dev}p1" ]; then
        part1="${dev}p1"
        part2="${dev}p2"
    else
        die "ไม่พบ partition (ลองแล้ว ${dev}1 และ ${dev}p1)"
    fi

    info "Format /boot (ext2, no journal) — $part1"
    mkfs.ext2 -L "boot" "$part1"

    info "Format / (ext4) — $part2"
    mkfs.ext4 -L "guixroot" "$part2"

    ok "Format สำเร็จ"

    # Export partition paths สำหรับ steps ถัดไป
    export BOOT_PART="$part1"
    export ROOT_PART="$part2"
}

# --- Step 3: Generate config ---
do_generate_config() {
    info "=== Step 3/5: สร้าง System Config ==="

    # อ่าน UUID จาก partition ที่เพิ่ง format
    local boot_uuid root_uuid
    boot_uuid="$(blkid -s UUID -o value "$BOOT_PART")"
    root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"

    if [ -z "$boot_uuid" ] || [ -z "$root_uuid" ]; then
        die "ไม่สามารถอ่าน UUID ได้ (boot=$boot_uuid, root=$root_uuid)"
    fi

    info "Boot UUID: $boot_uuid"
    info "Root UUID: $root_uuid"
    info "Boot disk: $1"

    # สร้าง config จาก template
    local config_path="${MOUNT_POINT}/etc/config.scm"
    mkdir -p "${MOUNT_POINT}/etc"

    sed -e "s|__BOOT_UUID__|${boot_uuid}|g" \
        -e "s|__ROOT_UUID__|${root_uuid}|g" \
        -e "s|__BOOT_DISK__|${1}|g" \
        "$TEMPLATE" > "$config_path"

    ok "Config สร้างเสร็จ: $config_path"

    echo ""
    echo -e "${BOLD}=== Config ที่สร้าง ===${NC}"
    echo -e "${CYAN}Bootloader:${NC} grub-bootloader -> $1"
    echo -e "${CYAN}/boot:${NC}      ext2  UUID=$boot_uuid"
    echo -e "${CYAN}/:${NC}          ext4  UUID=$root_uuid"
    echo ""
}

# --- Step 4: Mount ---
do_mount() {
    info "=== Step 4/5: Mount Partition ==="

    # Mount root
    mount "$ROOT_PART" "$MOUNT_POINT"
    ok "Mounted / -> $MOUNT_POINT"

    # สร้างและ mount boot
    mkdir -p "${MOUNT_POINT}/boot"
    mount "$BOOT_PART" "${MOUNT_POINT}/boot"
    ok "Mounted /boot -> ${MOUNT_POINT}/boot"
}

# --- Step 5: Install ---
do_install() {
    info "=== Step 5/5: ติดตั้ง Guix System ==="

    local config_path="${MOUNT_POINT}/etc/config.scm"

    echo ""
    echo -e "${BOLD}จะรัน: guix system init ${config_path} ${MOUNT_POINT}${NC}"
    echo ""
    echo "กระบวนการนี้จะ:"
    echo "  - ดาวน์โหลด packages ทั้งหมดที่ต้องการ"
    echo "  - ติดตั้ง system ลงใน $MOUNT_POINT"
    echo "  - ติดตั้ง GRUB bootloader ลง MBR"
    echo ""
    echo "อาจใช้เวลานาน (ขึ้นอยู่กับความเร็วเน็ต)"
    echo ""
    read -rp "กด Enter เพื่อเริ่มติดตั้ง (Ctrl+C เพื่อยกเลิก)..."

    # ตรวจสอบ network ก่อนติดตั้ง
    if ! guix describe >/dev/null 2>&1; then
        warn "ไม่สามารถเชื่อมต่อ Guix daemon ได้"
        warn "ตรวจสอบว่า:"
        warn "  1. อยู่ใน Guix installer environment"
        warn "  2. herd start cow-store /mnt (ถ้ายังไม่ได้ทำ)"
    fi

    # เปิด cow-store เพื่อให้ installer ใช้ RAM สำหรับ /gnu/store
    herd start cow-store "$MOUNT_POINT" 2>/dev/null || true

    # ติดตั้ง!
    guix system init "$config_path" "$MOUNT_POINT"

    ok "ติดตั้งสำเร็จ!"
}

# --- Cleanup ---
do_cleanup() {
    echo ""
    info "Unmounting..."
    umount "${MOUNT_POINT}/boot" 2>/dev/null || true
    umount "${MOUNT_POINT}" 2>/dev/null || true
    ok "Unmount เรียบร้อย"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Guix System Installer — Libreboot (SeaGRUB)   ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo ""
    echo "Boot chain: Libreboot ROM -> SeaBIOS -> GRUB (MBR) -> linux-libre"
    echo "Partition:  /boot (ext2, 1G) + / (ext4)"
    echo ""

    if [ $# -lt 1 ]; then
        usage
    fi

    local target_dev="$1"

    check_root
    check_template
    check_device "$target_dev"

    # Trap เพื่อ cleanup ถ้าเกิด error
    trap do_cleanup EXIT

    echo ""
    do_partition "$target_dev"

    echo ""
    do_format "$target_dev"

    echo ""
    do_mount

    echo ""
    do_generate_config "$target_dev"

    echo ""
    do_install

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ติดตั้งสำเร็จ!                                  ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo ""
    echo "ขั้นตอนถัดไป:"
    echo "  1. ถอด USB installer"
    echo "  2. reboot"
    echo "  3. Libreboot -> SeaBIOS จะ boot จาก disk โดยอัตโนมัติ"
    echo ""
    echo "หลังจาก boot เข้าระบบแล้ว:"
    echo "  - ตั้งรหัสผ่าน root:  passwd"
    echo "  - ตั้งรหัสผ่าน user:  passwd guix"
    echo "  - Config อยู่ที่:     /etc/config.scm"
    echo "  - Reconfigure:       sudo guix system reconfigure /etc/config.scm"
    echo ""
}

main "$@"
