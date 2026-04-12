# Libreboot Secure Best Practice — ThinkPad T480

คู่มือ security practice แบบ practical สำหรับ Libreboot บน ThinkPad T480
ครอบคลุมตั้งแต่ firmware จนถึง OS layer

**Hardware:** ThinkPad T480, Intel i7-8550U (Kaby Lake-R)
**Firmware:** Libreboot (coreboot) — SeaGRUB payload
**Flash:** 16MB SPI NOR, IFD platform `sklkbl`
**OS:** GNU Guix System (linux-libre)

---

## สารบัญ

1. [Threat Model](#1-threat-model)
2. [Boot Chain Analysis](#2-boot-chain-analysis)
3. [ชั้นที่ 1 — SPI Flash Write Protection](#3-ชั้นที่-1--spi-flash-write-protection)
4. [ชั้นที่ 2 — GRUB GPG Signature Verification](#4-ชั้นที่-2--grub-gpg-signature-verification)
5. [ชั้นที่ 3 — LUKS Encrypted Root](#5-ชั้นที่-3--luks-encrypted-root)
6. [ชั้นที่ 4 — Disk Partition Layout](#6-ชั้นที่-4--disk-partition-layout)
7. [ชั้นที่ 5 — Kernel Hardening](#7-ชั้นที่-5--kernel-hardening)
8. [ชั้นที่ 6 — Network Hardening](#8-ชั้นที่-6--network-hardening)
9. [ชั้นที่ 7 — Supply Chain Integrity](#9-ชั้นที่-7--supply-chain-integrity)
10. [ชั้นที่ 8 — Physical Security](#10-ชั้นที่-8--physical-security)
11. [สรุป Full Stack Protection](#11-สรุป-full-stack-protection)
12. [Checklist](#12-checklist)

---

## 1. Threat Model

### ผู้โจมตีที่คำนึงถึง

| ระดับ | ตัวอย่าง | ความสามารถ |
|-------|---------|-----------|
| Remote attacker | Malware, exploit ผ่าน network | root access บน OS |
| ISP / Network operator | MITM, DNS hijack | ดักฟัง/แก้ไข traffic ที่ไม่เข้ารหัส |
| Physical access (brief) | Evil maid, border control | เข้าถึงเครื่องชั่วคราว แก้ไข disk/firmware |
| State-level | Compromised CA, BGP hijack | MITM ระดับ TLS, supply chain tampering |

### สิ่งที่ต้องป้องกัน

| ทรัพย์สิน | ภัยคุกคาม | ชั้นป้องกัน |
|-----------|----------|------------|
| Firmware (SPI flash) | Bootkit, persistent rootkit | SPI Write Protection |
| Kernel + initrd (/boot) | Tampered kernel, backdoored initrd | GRUB GPG Verification |
| Root filesystem | Offline data theft | LUKS Encryption |
| Network traffic | MITM, surveillance | VPN + nftables kill switch |
| Supply chain (packages) | Poisoned substitutes, tampered sources | sec_scan.sh, Guix verification |
| Hardware | RF leak, rogue wireless | Physical removal, RF analysis |

---

## 2. Boot Chain Analysis

### SeaGRUB Boot Flow

```
SPI Flash ROM (16MB)                         Disk (/dev/sda)
┌─────────────────────────┐          ┌─────────────────────────┐
│                         │          │                         │
│  coreboot               │          │  /dev/sda1 — /boot      │
│    ↓                    │          │    grub/grub.cfg         │
│  SeaBIOS (payload)      │─ boot ──→│    vmlinuz-*             │
│    ↓                    │  from    │    initrd-*              │
│  GRUB (img/grub2 CBFS)  │  disk    │                         │
│    grub_default.cfg     │          │  /dev/sda2 — /           │
│    scan.cfg             │          │    (root filesystem)     │
│    keymap.gkb           │          │                         │
│                         │          │                         │
└─────────────────────────┘          └─────────────────────────┘
   ↑ Write Protectable                  ↑ ไม่มี HW Write Protection
```

### จุดอ่อนใน boot chain

| จุด | อยู่ที่ | Write Protectable? | ความเสี่ยง |
|-----|--------|-------------------|-----------|
| coreboot | SPI flash | ได้ (HW WP) | ต่ำ ถ้าเปิด WP |
| SeaBIOS | SPI flash (CBFS) | ได้ (HW WP) | ต่ำ ถ้าเปิด WP |
| GRUB payload | SPI flash (CBFS) | ได้ (HW WP) | ต่ำ ถ้าเปิด WP |
| grub.cfg on disk | /boot partition | **ไม่ได้** | **สูง** — แก้ได้จาก root |
| kernel (vmlinuz) | /boot partition | **ไม่ได้** | **สูง** — แก้ได้จาก root |
| initrd | /boot partition | **ไม่ได้** | **สูง** — แก้ได้จาก root |

### ทำไมเอา /boot ลง SPI Flash ไม่ได้

- CBFS size = `0xEEC000` (~15.4 MB) — coreboot + payloads ใช้เกือบหมด
- linux-libre kernel + Guix initrd = 30-80 MB ขึ้นไป
- ทุกครั้งที่ `guix system reconfigure` ได้ kernel/initrd ใหม่ → ต้อง flash ROM ใหม่
- **ทางแก้: ใช้ GRUB GPG signature verification แทน** (ชั้นที่ 2)

---

## 3. ชั้นที่ 1 — SPI Flash Write Protection

ป้องกัน firmware ใน ROM ถูกเขียนทับ (bootkit, persistent rootkit)

### 3 วิธี เรียงจากปลอดภัยน้อยไปมาก

| วิธี | ความปลอดภัย | ต้อง build ใหม่ | ต้องบัดกรี | bypass จาก OS |
|------|------------|----------------|-----------|---------------|
| SMM_BWP | ปานกลาง | ใช่ | ไม่ | ยาก (ต้อง SMM exploit) |
| SPI HW WP | สูงมาก | ไม่ | ใช่ | ไม่ได้ |
| Full Stack | สูงสุด | ใช่ | ใช่ | ไม่ได้ |

### วิธีที่ 1: SMM_BWP (Software — ไม่ต้องบัดกรี)

แก้ config 2 ไฟล์ใน `config/coreboot/t480_vfsp_16mb/config/`:

**ไฟล์:** `libgfxinit_corebootfb` และ `libgfxinit_txtmode`

```diff
# บรรทัด 244 — เปิด SMM Write Protection
- # CONFIG_BOOTMEDIA_SMM_BWP is not set
+ CONFIG_BOOTMEDIA_SMM_BWP=y

# บรรทัด 532 — ปิด unlock flash regions (บังคับ IFD permissions)
- CONFIG_UNLOCK_FLASH_REGIONS=y
+ # CONFIG_UNLOCK_FLASH_REGIONS is not set

# บรรทัด 531 — ล็อค ME region
- # CONFIG_LOCK_MANAGEMENT_ENGINE is not set
+ CONFIG_LOCK_MANAGEMENT_ENGINE=y
```

Build และ flash:

```bash
guix shell -m manifest.scm
./mk -b coreboot t480_vfsp_16mb
sudo flashprog -p internal -w bin/t480_vfsp_16mb/<rom_file>.rom
```

### วิธีที่ 2: SPI Hardware WP (ต้องบัดกรี — แนะนำ)

1. ตั้ง Block Protection บน SPI flash:
   ```bash
   sudo flashprog -p internal --wp-enable --wp-range 0x000000 0x1000000
   ```

2. บัดกรีขา /WP (pin 3) ของ SPI flash chip ลง GND (pin 4):
   ```
   SPI Flash SOIC-8:
     Pin 1: /CS
     Pin 2: DO
     Pin 3: /WP  ←── ต่อลง GND
     Pin 4: GND  ←── จุดนี้
     Pin 5: DI
     Pin 6: CLK
     Pin 7: /HOLD
     Pin 8: VCC
   ```

3. ทดสอบ:
   ```bash
   sudo flashprog -p internal --wp-status
   # ต้องแสดง: write protection is enabled
   ```

### วิธีที่ 3: Full Stack (แนะนำสูงสุด)

รวมวิธี 1 + 2:

1. แก้ config เปิด SMM_BWP + ปิด UNLOCK_FLASH_REGIONS + เปิด LOCK_ME
2. Build + flash ROM ใหม่
3. ตั้ง SPI Block Protection bits
4. บัดกรี /WP → GND

**ผลลัพธ์ — ป้องกัน 3 ชั้น:**

| ชั้น | กลไก | ป้องกัน |
|------|-------|--------|
| Hardware | /WP pin + BP bits + SRP | chip ปฏิเสธเขียนโดยตรง |
| Firmware | SMM_BWP handler | OS เขียน flash ไม่ได้ |
| Chipset | IFD region permissions | host อ่าน/เขียนได้เฉพาะ BIOS region |

### ตรวจสอบสถานะ WP

```bash
# SPI flash status
sudo flashprog -p internal --wp-status

# BIOS_CNTL register (PCI 0:1f.0 offset 0xdc)
BIOS_CNTL=$(sudo setpci -s 0:1f.0 dc.b)
VAL=$((16#${BIOS_CNTL}))
echo "BIOSWE  (bit 0) = $(( (VAL >> 0) & 1 ))  (0=protected)"
echo "BLE     (bit 1) = $(( (VAL >> 1) & 1 ))  (1=locked)"
echo "SMM_BWP (bit 5) = $(( (VAL >> 5) & 1 ))  (1=SMM protects)"

# IFD region access test (ME region ต้องอ่านไม่ได้ถ้า lock ทำงาน)
sudo flashprog -p internal -r /tmp/me_test.bin --ifd -i me 2>&1 | tail -3
```

### เมื่อต้องการ update firmware

1. ถอดขา /WP ออกจาก GND (ถ้าใช้ HW WP)
2. `sudo flashprog -p internal --wp-disable`
3. Flash ROM ใหม่
4. เปิด WP กลับ + ต่อขา /WP ลง GND อีกครั้ง

---

## 4. ชั้นที่ 2 — GRUB GPG Signature Verification

ป้องกัน kernel/initrd/grub.cfg บน disk ถูกแก้ไข
**สำคัญ:** ชั้นนี้ต้องทำร่วมกับ SPI WP (ชั้นที่ 1) ถ้าไม่ WP attacker แก้ GRUB ใน ROM เพื่อปิด verify ได้

### เปรียบเทียบกับ UEFI Secure Boot ของ Vendor

ชั้นนี้คือ **Verified Boot** — concept เดียวกับ UEFI Secure Boot ของ vendor ทุกประการ
แต่ต่างกันในจุดสำคัญที่สุด: **ใครถือกุญแจ**

| | UEFI Secure Boot (Vendor) | GRUB GPG + SPI WP (Libreboot) |
|---|---|---|
| **Root of Trust** | Microsoft CA + OEM key ใน UEFI firmware | **GPG public key ของคุณ** ใน SPI ROM |
| **ใครเลือกว่า boot อะไรได้** | Microsoft อนุมัติผ่าน MS CA | **คุณ sign เอง** ด้วย private key |
| **เปลี่ยน key** | ยาก (OEM ล็อค, ต้อง MOK Manager) | ได้ — flash ROM ใหม่ |
| **Crypto** | x509 certificates, PKCS#7 | GPG/PGP detached signatures |
| **ป้องกัน tampered kernel** | ได้ | ได้ |
| **Boot unsigned OS** | ไม่ได้ (ต้องปิด Secure Boot) | ไม่ได้ (ต้อง sign หรือปิด verify) |
| **Trust chain ป้องกัน HW** | ไม่ได้ (firmware เขียนทับได้) | **ได้** (SPI flash write-protected) |

**Trust chain เปรียบเทียบ:**

```
Vendor Secure Boot:
  Microsoft root CA  →  signs shim  →  signs GRUB  →  signs kernel
       ↑
    คุณไม่ได้ควบคุม
    Microsoft ตัดสินว่าเครื่องคุณ boot อะไรได้

GRUB GPG + Libreboot:
  GPG private key ของคุณ  →  signs grub.cfg  →  signs kernel  →  signs initrd
       ↑
    คุณถือเอง (เก็บใน air-gapped USB)

  GPG public key ฝังใน ROM ที่ write-protected
       ↑
    คุณบัดกรี /WP pin เอง — ไม่มีใครแก้ได้นอกจากเข้าถึง hardware
```

**สรุป:** Libreboot ไม่ได้ปฏิเสธ verified boot — ปฏิเสธการให้ vendor ถือกุญแจแทนเจ้าของเครื่อง
GRUB GPG + SPI WP คือ verified boot ที่ **user เป็น root of trust** ไม่ใช่ Microsoft

### GRUB modules ที่พร้อมอยู่แล้วใน ROM

จาก `config/data/grub/module/xhci_nvme` — modules เหล่านี้ถูก build เข้า GRUB payload แล้ว:

| Module | หน้าที่ |
|--------|--------|
| `pgp` | PGP signature verification |
| `pubkey` | Public key handling |
| `gcry_rsa` | RSA cryptographic operations |
| `gcry_sha512` | SHA-512 hashing |
| `hashsum` | Hash verification |
| `password_pbkdf2` | GRUB password protection |

**ไม่ต้อง rebuild GRUB** — module พร้อมใช้งานอยู่แล้ว

### ขั้นตอน Setup

#### 4.1 สร้าง GPG keypair สำหรับ sign boot files

```bash
# สร้าง keypair (เก็บ private key ให้ปลอดภัย — ใน USB แยก หรือ air-gapped machine)
gpg --gen-key
# เลือก: RSA 4096, ไม่หมดอายุ, ชื่อ "Libreboot Boot Signer"

# Export public key
gpg --export "Libreboot Boot Signer" > ~/boot-sign.pub
```

#### 4.2 สร้าง grub.cfg สำหรับฝังใน CBFS

สร้างไฟล์ `grub-secure.cfg`:

```grub
# Enforce GPG signature verification
set check_signatures=enforce
# ป้องกันใครปิด verify ผ่าน GRUB command line
set superusers="root"
password_pbkdf2 root <PBKDF2_HASH>

# Trust public key
trust (cbfsdisk)/boot-sign.pub

# Boot — GRUB จะ verify .sig ของทุกไฟล์ที่โหลด
set root='(ahci0,1)'
configfile /grub/grub.cfg
# GRUB จะหา /grub/grub.cfg.sig อัตโนมัติ
```

สร้าง PBKDF2 hash:

```bash
grub-mkpasswd-pbkdf2
# ใส่ password → copy hash มาใส่ใน grub-secure.cfg
```

#### 4.3 ฝัง public key + grub.cfg ลง CBFS

```bash
# อ่าน ROM ปัจจุบัน
sudo flashprog -p internal -r current.rom

# เพิ่ม public key ลง CBFS
cbfstool current.rom add -f ~/boot-sign.pub -n boot-sign.pub -t raw

# เพิ่ม grub.cfg ลง CBFS (GRUB ใน ROM จะอ่านไฟล์นี้ก่อน disk)
cbfstool current.rom add -f grub-secure.cfg -n grub.cfg -t raw

# Flash กลับ
sudo flashprog -p internal -w current.rom
```

#### 4.4 Sign boot files ทุกครั้งที่ reconfigure

```bash
#!/bin/bash
# sign-boot.sh — รันหลัง guix system reconfigure ทุกครั้ง

BOOT="/boot"

# Sign ทุกไฟล์ใน /boot ที่ GRUB จะโหลด
for f in "${BOOT}"/grub/grub.cfg \
         "${BOOT}"/gnu/store/*/bzImage \
         "${BOOT}"/gnu/store/*/initrd.cpio.gz; do
    if [ -f "$f" ]; then
        gpg --detach-sign "$f"
        echo "Signed: $f"
    fi
done
```

#### 4.5 Boot flow หลังเปิด GPG verification

```
GRUB (ROM, write-protected)
  ↓
load grub.cfg จาก CBFS → set check_signatures=enforce
  ↓
trust boot-sign.pub (จาก CBFS)
  ↓
load /boot/grub/grub.cfg → ตรวจ /boot/grub/grub.cfg.sig ← ต้อง PASS
  ↓
load vmlinuz → ตรวจ vmlinuz.sig ← ต้อง PASS
  ↓
load initrd → ตรวจ initrd.sig ← ต้อง PASS
  ↓
boot!
```

**ถ้า signature ไม่ตรง → GRUB ปฏิเสธ boot → attacker ทำอะไรไม่ได้**
(เพราะ GRUB + public key + verify policy อยู่ใน ROM ที่ write-protected)

---

## 5. ชั้นที่ 3 — LUKS Encrypted Root

ป้องกัน offline data theft (ขโมย disk, evil maid อ่าน filesystem)

### Partition layout สำหรับ LUKS

```
/dev/sda1   /boot   ext2   1 GiB    (ไม่เข้ารหัส — GRUB ต้องอ่านได้)
/dev/sda2   LUKS → /  ext4  ที่เหลือ   (เข้ารหัสทั้ง partition)
```

### GRUB modules ที่รองรับ (มีอยู่ใน ROM แล้ว)

- `luks`, `luks2` — LUKS container unlock
- `argon2` — Argon2 KDF (สำหรับ LUKS2)
- `cryptodisk` — encrypted disk support
- `lvm` — LVM (ถ้าใช้ LVM on LUKS)

### Setup ใน Guix System config

```scheme
(mapped-devices
  (list (mapped-device
          (source (uuid "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
          (target "cryptroot")
          (type luks-device-mapping))))

(file-systems
  (cons* (file-system
           (mount-point "/")
           (device "/dev/mapper/cryptroot")
           (type "ext4")
           (dependencies mapped-devices))
         (file-system
           (mount-point "/boot")
           (device (uuid "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" 'ext2))
           (type "ext2"))
         %base-file-systems))
```

### สร้าง LUKS partition

```bash
# Format ด้วย LUKS2 + Argon2id (แนะนำ)
cryptsetup luksFormat --type luks2 \
  --pbkdf argon2id \
  --hash sha512 \
  --key-size 512 \
  --iter-time 5000 \
  /dev/sda2

# เปิด
cryptsetup luksOpen /dev/sda2 cryptroot

# Format root
mkfs.ext4 /dev/mapper/cryptroot
```

### ข้อจำกัด

- `/boot` ยังคง **ไม่เข้ารหัส** — kernel/initrd อ่านได้
- ดังนั้นต้องใช้ร่วมกับ GRUB GPG verification (ชั้นที่ 2)
- GRUB ใน ROM รองรับ `luks` + `luks2` → ถอดรหัส root ตอน boot ได้

---

## 6. ชั้นที่ 4 — Disk Partition Layout

### Layout สำหรับ Libreboot (SeaGRUB)

```
┌──────────────────────────────────────────┐
│              /dev/sda (MBR)              │
├──────────┬───────────────────────────────┤
│ sda1     │ sda2                          │
│ /boot    │ LUKS → /                      │
│ ext2     │ ext4                           │
│ 1 GiB    │ ส่วนที่เหลือ                    │
│ boot flag│                               │
├──────────┼───────────────────────────────┤
│ไม่ encrypt│ encrypted                     │
│GRUB อ่านได้│ ต้อง passphrase               │
└──────────┴───────────────────────────────┘
```

### ทำไม /boot ต้องเป็น ext2

| Filesystem | Journal | GRUB อ่านได้ | เหมาะกับ /boot |
|-----------|---------|-------------|---------------|
| ext2 | ไม่มี | ได้ 100% | **แนะนำ** |
| ext4 | มี | ได้ (ปกติ) | ใช้ได้ |
| btrfs | มี | ได้ | ใช้ได้ |
| xfs | มี | ได้ | ใช้ได้ |

ext2 แนะนำเพราะ:
- ไม่มี journal → ลด complexity ที่ GRUB ต้อง parse
- GRUB payload ใน ROM มี module `ext2` พร้อมอยู่ (รองรับทั้ง ext2/ext3/ext4)
- boot partition ไม่ต้องการ journal (เขียนไม่บ่อย, ขนาดเล็ก)

### ทำไมใช้ MBR ไม่ใช่ GPT

- SeaGRUB: SeaBIOS → GRUB — SeaBIOS ทำงานกับ MBR boot ได้ดี
- GRUB ใน ROM มีทั้ง `part_msdos` (MBR) และ `part_gpt` → ใช้ GPT ก็ได้
- MBR เรียบง่ายกว่า, ไม่ต้องมี EFI partition

---

## 7. ชั้นที่ 5 — Kernel Hardening

### Boot parameters (ทดสอบแล้วบน linux-libre 6.18.x)

```scheme
(kernel-arguments
  (append (list
            "slab_nomerge"                ;; ป้องกัน slab overflow cross-cache
            "init_on_alloc=1"             ;; zero-fill เมื่อ allocate
            "init_on_free=1"              ;; zero-fill เมื่อ free
            "page_alloc.shuffle=1"        ;; สุ่ม page allocation
            "randomize_kstack_offset=on"  ;; สุ่ม kernel stack offset
            "vsyscall=none"               ;; ปิด vsyscall (ROP target)
            "loglevel=4")                 ;; แสดง warnings
          %default-kernel-arguments))
```

**หมายเหตุ:** `debugfs=off` ทำให้ boot ค้างบน linux-libre 6.18.21 — อย่าใช้

### Sysctl hardening

```scheme
(sysctl-service-type config =>
  (sysctl-configuration
    (settings
      '(;; Anti-MITM & Anti-Spoofing
        ("net.ipv4.tcp_syncookies" . "1")
        ("net.ipv4.conf.all.rp_filter" . "1")
        ("net.ipv4.conf.default.rp_filter" . "1")
        ("net.ipv4.conf.all.accept_redirects" . "0")
        ("net.ipv4.conf.default.accept_redirects" . "0")
        ("net.ipv6.conf.all.accept_redirects" . "0")
        ("net.ipv6.conf.default.accept_redirects" . "0")
        ("net.ipv4.conf.all.send_redirects" . "0")
        ("net.ipv4.conf.default.send_redirects" . "0")
        ("net.ipv4.conf.all.accept_source_route" . "0")
        ("net.ipv4.conf.default.accept_source_route" . "0")
        ("net.ipv6.conf.all.accept_source_route" . "0")
        ("net.ipv6.conf.default.accept_source_route" . "0")
        ("net.ipv4.conf.all.log_martians" . "1")
        ("net.ipv4.conf.default.log_martians" . "1")
        ("net.ipv4.icmp_echo_ignore_broadcasts" . "1")
        ("net.ipv4.icmp_ignore_bogus_error_responses" . "1")
        ("net.ipv4.tcp_rfc1337" . "1")
        ("net.ipv4.ip_forward" . "0")
        ("net.ipv6.conf.all.forwarding" . "0")

        ;; Anti-Exploitation
        ("kernel.kptr_restrict" . "2")        ;; ซ่อน kernel addresses
        ("kernel.dmesg_restrict" . "1")       ;; dmesg เฉพาะ root
        ("kernel.perf_event_paranoid" . "3")  ;; ปิด perf (side-channel)
        ("kernel.yama.ptrace_scope" . "1")    ;; จำกัด ptrace
        ("kernel.unprivileged_bpf_disabled" . "1")
        ("net.core.bpf_jit_harden" . "2")
        ("kernel.kexec_load_disabled" . "1")  ;; ปิด kexec (rootkit)
        ("kernel.sysrq" . "0")               ;; ปิด magic SysRq
        ("kernel.randomize_va_space" . "2")   ;; ASLR full

        ;; Filesystem
        ("fs.protected_hardlinks" . "1")
        ("fs.protected_symlinks" . "1")
        ("fs.protected_fifos" . "2")
        ("fs.protected_regular" . "2")
        ("fs.suid_dumpable" . "0")))))
```

---

## 8. ชั้นที่ 6 — Network Hardening

### nftables Firewall — VPN Kill Switch

Policy: **ไม่มี VPN = ออกเน็ตไม่ได้** (ป้องกัน traffic leak ไปทาง ISP โดยตรง)

```
chain output {
  type filter hook output priority filter; policy drop;   ← default DROP

  oif lo accept                    # loopback
  oifname "tun*" accept            # VPN tunnel
  oifname "wg*" accept             # WireGuard
  ct state established,related accept

  # DHCP, local network — จำเป็น
  udp sport 68 udp dport 67 accept
  ip daddr 192.168.0.0/16 accept

  # DNS เฉพาะ Quad9 (encrypted, malware blocking)
  udp dport 53 ip daddr 9.9.9.9 accept
  udp dport 53 ip daddr 149.112.112.112 accept

  # HTTPS — สำหรับ VPN API + essential services
  tcp dport 443 accept

  # VPN establishment ports
  udp dport 51820 accept           # WireGuard
  udp dport { 443, 1194 } accept   # OpenVPN

  counter drop                     # !! KILL SWITCH !!
}
```

### ทำไมต้อง Kill Switch

- ถ้า VPN หลุด → traffic ปกติจะออกตรงไป ISP ทันที (DNS leak, IP leak)
- Kill switch บังคับให้ทุก traffic ต้องผ่าน VPN tunnel เท่านั้น
- ISP เห็นแค่ encrypted tunnel ไปยัง VPN server

---

## 9. ชั้นที่ 7 — Supply Chain Integrity

### Threat: Poisoned packages / tampered sources

ใช้ `sec_scan.sh` ตรวจสอบ:

```bash
guix shell -m manifest.scm -- ./sec_scan.sh
```

### สิ่งที่ sec_scan.sh ตรวจ

| ชั้น | วิธีตรวจ |
|------|---------|
| Guix channel | Signed commits, channel introduction |
| Guix substitutes | `guix challenge`, narinfo signature verification |
| TLS/CA chain | Certificate pinning, CT log cross-check |
| GNAT binary | Multi-source hash comparison |
| Git repos | Cross-mirror verification (compare tree hashes) |
| Tarballs | SHA-512 re-verification จาก independent mirror |
| Software Heritage | Immutable third-party archive cross-check |
| DNS | DNS-over-HTTPS consistency check |
| Reproducibility | `guix challenge` spot-check |
| /gnu/store | Verify store items against narinfo |

### Guix daemon hardening

```scheme
(guix-service-type config =>
  (guix-configuration
    (inherit config)
    ;; เฉพาะ official substitute servers
    (substitute-urls
      '("https://ci.guix.gnu.org"
        "https://bordeaux.guix.gnu.org"))
    ;; เก็บ derivations สำหรับ audit ย้อนหลัง
    (extra-options '("--gc-keep-derivations=yes"
                    "--gc-keep-outputs=yes"))))
```

---

## 10. ชั้นที่ 8 — Physical Security

### Hardware ที่ถอดออกแล้ว (จาก RF Leak Analysis)

| Component | สถานะ | หมายเหตุ |
|-----------|-------|---------|
| WiFi card | **ถอดออก** | ไม่พบ hardware ใน PCI |
| Bluetooth | **ถอดออก** | ไม่พบ hardware ใน PCI |
| Intel ME | **Neutered** | me_cleaner ตัดเหลือ 2MB, Boot Guard ปิดผ่าน deguard |
| Microphone | ตรวจสอบ | ปิดใน BIOS/OS ถ้าไม่ใช้ |
| Camera | ตรวจสอบ | ปิดหรือปิดทับ ถ้าไม่ใช้ |

### Intel ME status

```
ME firmware: 11.6.0.1126 (neutered → 2MB SKU)
Boot Guard: disabled (deguard)
PCI 00:16.0: ไม่มี (ME interface ถูกปิด)
MEI kernel module: ไม่ได้โหลด
```

### ThunderBolt

- Intel JHL6240 Alpine Ridge LP มี flash chip แยก 1MB
- **ไม่เกี่ยวกับ main SPI flash** — WP ของ main flash ไม่ครอบคลุม TB
- ถ้าไม่ใช้ ThunderBolt → ปิดใน coreboot config หรือปิด port physically

### Physical access mitigation

| มาตรการ | ป้องกัน |
|---------|--------|
| SPI HW WP (บัดกรี) | firmware tampering จาก OS |
| GRUB GPG verify | boot file tampering |
| LUKS | offline disk read |
| Tamper-evident seal บน screws | ตรวจจับว่าเคยเปิดฝา |
| BIOS password (GRUB password) | ป้องกัน boot menu tampering |

---

## 11. สรุป Full Stack Protection

```
┌─────────────────────────────────────────────────────────┐
│                    Physical Layer                        │
│  WiFi/BT ถอดออก, ME neutered, tamper-evident seals     │
├─────────────────────────────────────────────────────────┤
│                    Firmware Layer                        │
│  SPI HW WP + SMM_BWP + IFD lock                        │
│  → ROM เขียนทับไม่ได้                                    │
├─────────────────────────────────────────────────────────┤
│                    Boot Verification                    │
│  GRUB GPG signature (public key + policy ใน ROM)       │
│  → kernel/initrd/grub.cfg ถูกแก้ไม่ได้โดยไม่ถูกจับ       │
├─────────────────────────────────────────────────────────┤
│                    Disk Encryption                       │
│  LUKS2 + Argon2id                                       │
│  → offline data theft ป้องกันได้                          │
├─────────────────────────────────────────────────────────┤
│                    OS Hardening                          │
│  Kernel params + sysctl + nftables                      │
│  → exploitation + network attack ยากขึ้น                 │
├─────────────────────────────────────────────────────────┤
│                    Network Layer                         │
│  VPN kill switch + Tor                                   │
│  → ISP/network MITM ป้องกันได้                           │
├─────────────────────────────────────────────────────────┤
│                    Supply Chain                          │
│  sec_scan.sh + Guix substitute verification             │
│  → poisoned package ตรวจจับได้                           │
└─────────────────────────────────────────────────────────┘
```

### แต่ละชั้นป้องกันอะไร

| Attack | Physical | Firmware WP | GRUB GPG | LUKS | OS Hardening | Network | Supply Chain |
|--------|----------|-------------|----------|------|-------------|---------|-------------|
| Bootkit (flash ROM) | | **X** | | | | | |
| Evil maid (แก้ kernel) | | | **X** | | | | |
| Disk theft (อ่าน data) | | | | **X** | | | |
| Remote exploit | | | | | **X** | | |
| ISP MITM | | | | | | **X** | |
| Poisoned package | | | | | | | **X** |
| RF surveillance | **X** | | | | | | |
| Hardware implant | **X** | | | | | | |

---

## 12. Checklist

### ระดับ 1 — พื้นฐาน (ทำทันที)

- [ ] แยก /boot (ext2) + / (ext4) partition
- [ ] Kernel hardening parameters ใน config.scm
- [ ] Sysctl hardening ใน config.scm
- [ ] nftables firewall (อย่างน้อย INPUT: drop)
- [ ] Guix substitute servers เฉพาะ official
- [ ] ถอด WiFi/Bluetooth card

### ระดับ 2 — แนะนำ (ทำเร็วที่สุด)

- [ ] เปิด SMM_BWP + ปิด UNLOCK_FLASH_REGIONS + เปิด LOCK_ME
- [ ] Build + flash ROM ใหม่
- [ ] LUKS encrypted root partition
- [ ] VPN + nftables kill switch
- [ ] รัน sec_scan.sh ตรวจ supply chain

### ระดับ 3 — ป้องกันสูงสุด (ต้องบัดกรี)

- [ ] SPI flash HW WP (บัดกรี /WP → GND)
- [ ] GRUB GPG signature verification
- [ ] ฝัง public key + verify policy ลง CBFS
- [ ] สร้าง sign-boot.sh script รันหลัง reconfigure ทุกครั้ง
- [ ] Tamper-evident seals บนตัวเครื่อง
- [ ] เก็บ GPG private key ใน air-gapped USB แยก

---

## ไฟล์อ้างอิงใน repo

| ไฟล์ | เนื้อหา |
|------|--------|
| `T480_WRITE_PROTECTION.md` | รายละเอียด SPI WP ทั้ง 3 วิธี + คำสั่ง flashprog |
| `RFLeakAnalysis.md` | ผลวิเคราะห์ RF + สถานะ ME/WiFi/BT |
| `SEC-SCAN.md` | ผล sec_scan.sh + supply chain audit |
| `sec_scan.sh` | Script ตรวจ supply chain integrity |
| `/etc/config.scm` | System config ปัจจุบัน (hardened) |
| `config/coreboot/t480_vfsp_16mb/` | coreboot config สำหรับ T480 |
| `config/data/grub/module/xhci_nvme` | GRUB module list (มี pgp, pubkey, crypto) |
| `config/grub/xhci_nvme/config/payload` | GRUB boot scan logic |
| `guix-installer/` | Installer USB + config สำหรับ Libreboot |
