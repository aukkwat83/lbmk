# Pro and Con of Libreboot — ThinkPad T480 + Hardened Guix System

วิเคราะห์ข้อได้เปรียบ-เสียเปรียบของ Libreboot เทียบกับ Vendor Firmware (Lenovo UEFI)
บน Guix System ที่ผ่านการ hardening อย่างหนักเหมือนกันทั้งสองฝั่ง

**เครื่อง:** ThinkPad T480, Intel i7-8550U (Kaby Lake-R), 16MB SPI NOR
**Firmware:** Libreboot (coreboot 25.12) — SeaGRUB payload
**OS:** GNU Guix System, linux-libre 6.18.x

---

## ข้อเท็จจริงก่อน — Libreboot บน T480 ไม่ได้ blob-free

Libreboot แทนที่ Lenovo UEFI ด้วย coreboot + SeaBIOS/GRUB
แต่ยังต้องใช้ binary blob จาก Intel:

| Blob | Libreboot | Vendor (Lenovo UEFI) |
|------|-----------|---------------------|
| Intel ME | **2MB neutered** (me_cleaner + deguard) | Full ~5MB (ทำงานเต็ม) |
| FSP-M (Memory Init) | ใช้ (`Fsp_M.fd`) | ใช้ (อยู่ใน UEFI) |
| FSP-S (Silicon Init) | ใช้ (`Fsp_S.fd`) | ใช้ (อยู่ใน UEFI) |
| CPU Microcode | ใช้ (rev `0xf6`) | ใช้ (อาจ rev ใหม่กว่า) |
| GbE NIC config | ใช้ | ใช้ |
| VBT (Video BIOS Table) | ใช้ | ใช้ |
| ThunderBolt firmware | ใช้ (1MB, Lenovo extracted) | ใช้ |

สิ่งที่ต่างจริง: **UEFI → coreboot**, **ME full → ME neutered**, **Boot Guard → disabled**

---

## PRO — ข้อได้เปรียบของ Libreboot

### 1. Intel ME Neutered — ลด attack surface ที่ใหญ่ที่สุด

```
Libreboot:  ME neutered 2MB, soft-disabled, PCI 00:16.x หายไปจากระบบ
Vendor:     ME full ~5MB, ทำงานตลอด, มี network stack แยกจาก OS
```

| ผลกระทบ | Libreboot | Vendor |
|---------|-----------|--------|
| ME network stack | **ไม่มี** | มี — bypass nftables ได้ทั้งหมด |
| AMT remote access | **ไม่ได้** | ทำได้แม้ OS ปิด |
| ME attack surface | **แทบไม่มี** | CVE ออกเป็นระยะ |
| ผลต่อ VPN kill switch | **nftables ป้องกัน 100%** | ME อาจ leak traffic ข้าม firewall |

nftables kill switch ใน Guix hardened config ทำงานที่ OS level
แต่ Intel ME มี network stack แยกที่ทำงานระดับ firmware — bypass ได้ทั้งหมด
**Libreboot ตัดปัญหานี้ออกโดยสิ้นเชิง**

ไม่มี side effect — ME neutered ไม่มีข้อเสียใน daily use

---

### 2. Firmware Source Code — Audit ได้

| | Libreboot | Vendor |
|---|---|---|
| Firmware source | coreboot (GPLv2, อ่านได้) | Lenovo UEFI (closed binary) |
| Build reproducible | ได้ (lbmk) | ไม่ได้ |
| Patch ได้เอง | ได้ | ไม่ได้ |
| รู้ว่า firmware ทำอะไร | ส่วนใหญ่ (ยกเว้น FSP) | ไม่รู้เลย |

coreboot source อยู่ใน repo ที่คุณ build เอง (`./mk -b coreboot t480_vfsp_16mb`)
สามารถแก้ config, patch, ตรวจ diff ก่อน flash ทุกครั้ง

---

### 3. Verified Boot ที่ User ถือ Key

```
Vendor:     Microsoft root CA  →  signs shim  →  signs GRUB  →  signs kernel
            คุณไม่ได้ควบคุม root of trust

Libreboot:  GPG private key ของคุณ  →  signs grub.cfg + kernel + initrd
            Public key ฝังใน ROM ที่ HW write-protected
            คุณควบคุมทุกชั้น
```

| | Libreboot (GRUB GPG) | Vendor (UEFI Secure Boot) |
|---|---|---|
| Root of trust | GPG key ของคุณ | Microsoft CA |
| เปลี่ยน key | Flash ROM ใหม่ | ยาก (MOK Manager) |
| ใครตัดสินว่า boot อะไรได้ | คุณ | Microsoft |
| Trust chain ป้องกัน HW | ได้ (SPI WP) | ไม่ชัด |

---

### 4. SPI Flash Write Protection — ป้องกัน Firmware Tampering

Libreboot เปิดทาง hardware write protection 3 ชั้น:

| ชั้น | กลไก | Vendor ทำได้? |
|------|-------|-------------|
| Hardware | /WP pin บัดกรีลง GND | ไม่รู้วิธี (Lenovo ไม่เปิดเผย) |
| Firmware | SMM_BWP handler | Lenovo อาจทำอยู่แต่ verify ไม่ได้ |
| Chipset | IFD region lock | Lenovo อาจทำอยู่แต่ verify ไม่ได้ |

Libreboot ให้คุณ **ตรวจสอบและควบคุม WP ทุกชั้นด้วยตัวเอง**

---

### 5. ปิด HyperThreading — Hardware-Level Side-Channel Mitigation

```
CONFIG_FSP_HYPERTHREADING is not set    ← ปิดไว้ใน Libreboot config
Logical CPUs: 4 (ปกติ 8)
```

| Vulnerability | Libreboot (SMT off) | Vendor (SMT on default) |
|---------------|--------------------|-----------------------|
| MDS | **Hardware mitigated** | Software mitigation + performance cost |
| L1TF | **Hardware mitigated** | Software mitigation + performance cost |
| MMIO Stale Data | **Hardware mitigated** | Software mitigation + performance cost |
| Spectre v2 (SMT variant) | **ไม่มี attack vector** | ต้อง mitigation |

ปิด SMT = ตัดปัญหา cross-thread side-channel ที่ hardware level
ไม่ต้องพึ่ง software mitigation ที่อาจไม่ครอบคลุมทุก variant

---

### 6. ไม่มี TPM — ไม่มี Remote Attestation

| ผลดีของไม่มี TPM | |
|---|---|
| Remote attestation | **ไม่ได้** — ไม่มีใครตรวจเครื่องคุณจากภายนอก |
| Privacy | **ดีกว่า** — ไม่มี hardware ที่ prove identity ของเครื่อง |
| DRM enforcement | **ไม่ได้** — ไม่มี TPM-backed DRM |
| Attack surface | **น้อยกว่า** — TPM เป็น closed hardware อีกชิ้น |

---

### 7. Boot Guard Disabled — คุณ Flash Firmware เองได้

```
ME11bootguard="y"    ← deguard ปิด Boot Guard
```

| | Libreboot | Vendor |
|---|---|---|
| Flash firmware เอง | **ได้** (`flashprog -p internal`) | Lenovo ล็อค — ต้องใช้ official update |
| ใช้ firmware อื่น | **ได้** | ไม่ได้ (Boot Guard block) |
| Vendor lock-in | **ไม่มี** | มี |

---

## CON — ข้อเสียเปรียบของ Libreboot

### 1. CPU Microcode Update ช้ากว่า

```
Microcode ปัจจุบัน: rev 0xf6 (ฝังใน ROM)
```

| | Libreboot | Vendor |
|---|---|---|
| Update method | Rebuild ROM + reflash | Lenovo push ผ่าน LVFS |
| Response time | รอ coreboot merge microcode ใหม่ | Lenovo ออก update ภายในสัปดาห์ |
| Auto-update | **ไม่มี** | มี |

ถ้า Intel ออก microcode แก้ vulnerability ใหม่ → Libreboot ต้องรอ + rebuild + reflash เอง
ระหว่างรอ เครื่องอาจ vulnerable ต่อ CPU bug ใหม่

**Mitigation:** SMT off ลด attack surface ของ side-channel ได้มากอยู่แล้ว

---

### 2. Performance ลดลง ~20-30% (SMT off)

| Workload | SMT on (Vendor default) | SMT off (Libreboot) | ผลต่าง |
|----------|------------------------|--------------------|---------| 
| Single-thread | ไม่ต่าง | ไม่ต่าง | 0% |
| Multi-thread compile | 8 threads | 4 threads | **-20-30%** |
| `./mk -b coreboot` | เร็วกว่า | **ช้ากว่า** | ช้าขึ้นเท่าตัว (crossgcc) |
| Desktop/browsing | ไม่ค่อยต่าง | ไม่ค่อยต่าง | ~0-5% |

งาน compile-heavy (build Libreboot, Guix package build) ได้รับผลกระทบมากที่สุด

---

### 3. ไม่มี TPM — LUKS ไม่สะดวก

| | Libreboot (ไม่มี TPM) | Vendor (TPM 2.0) |
|---|---|---|
| LUKS unlock | **พิมพ์ passphrase ทุกครั้ง** | TPM auto-unseal + PIN |
| Measured boot | **ไม่มี** | PCR measurements ใน TPM |
| Key storage | ไม่มี hardware-backed | TPM-sealed key |
| Disk encryption UX | **ไม่สะดวก** | สะดวกกว่า |

ทุกครั้งที่ boot ต้องพิมพ์ LUKS passphrase เอง ไม่มี TPM auto-unlock

---

### 4. Suspend/Resume อาจไม่เสถียร

```
CONFIG_HAVE_ACPI_RESUME=y    ← รองรับ S3
CONFIG_ACPI_S1_NOT_SUPPORTED=y
```

| | Libreboot | Vendor |
|---|---|---|
| S3 (suspend to RAM) | รองรับ แต่อาจมี quirks | Lenovo ทดสอบมาอย่างดี |
| S0ix (modern standby) | **ไม่รองรับ** | อาจรองรับ |
| Wake on LAN | **อาจไม่ทำงาน** | ทำงาน |
| Resume stability | **อาจมี edge case** | เสถียร |

coreboot + FSP combination อาจมี ACPI quirk ที่ Lenovo UEFI จัดการได้ดีกว่า
เพราะ Lenovo ทดสอบ suspend/resume บน hardware จริงกับ UEFI ของตัวเอง

---

### 5. ThunderBolt — Subsystem ID ผิดปกติ + ไม่มี Security Level Control

จาก RF Leak Analysis:

```
Subsystem ID: 2222:1111    ← ผิดปกติ (ค่า Lenovo มาตรฐาน: 17aa:xxxx)
Controller: active ตลอดแม้ไม่มีอุปกรณ์ต่อ
```

| | Libreboot | Vendor |
|---|---|---|
| TB security level | **ไม่มี BIOS option** | None / User / Secure / DPonly |
| DMA protection | **ต้อง config kernel เอง** | BIOS option |
| Subsystem ID | **2222:1111 (ผิดปกติ)** | 17aa:xxxx (ปกติ) |
| RF emission | **สูงกว่า** (active ตลอด) | ควบคุมได้จาก BIOS |

ThunderBolt เป็น DMA attack vector — ไม่มี BIOS-level security level ทำให้ต้องพึ่ง
kernel-level mitigation (`thunderbolt` module blacklist หรือ IOMMU) แทน

---

### 6. Firmware Maintenance — ต้องทำเอง

| งาน | Libreboot | Vendor |
|-----|-----------|--------|
| Security update | Rebuild + reflash **เอง** | Auto ผ่าน LVFS |
| Config change | แก้ config + rebuild + reflash | BIOS setup menu |
| Recovery จาก brick | External programmer (serprog) | Lenovo recovery ผ่าน USB |
| Knowledge required | **สูง** (coreboot, flashprog, บัดกรี) | ต่ำ |

ทุกครั้งที่ต้องการเปลี่ยน firmware setting (เช่น เปิด WP, เปลี่ยน GRUB config)
ต้อง rebuild ROM → flash ใหม่ แทนที่จะแค่เข้า BIOS setup

---

### 7. FSP ยังเป็น Black Box

```
FSP-M: vendorfiles/kabylake/Fsp_M.fd    ← closed binary, init memory controller
FSP-S: vendorfiles/kabylake/Fsp_S.fd    ← closed binary, init PLL, clock, PCH
```

FSP ควบคุม:
- Memory controller initialization
- PLL / clock dividers / spread spectrum
- PCH power management
- CPU power states

**เท่ากันทั้งสองฝั่ง** — ทั้ง Libreboot และ Vendor ใช้ FSP blob ตัวเดียวกัน
แต่สิ่งนี้ทำให้ Libreboot **ไม่ได้ blob-free จริง** บน T480
จุดที่ audit ไม่ได้ (FSP, microcode) ยังคงมีอยู่เหมือนกัน

---

## สรุป

### Libreboot ชนะ

| หมวด | เหตุผล |
|------|--------|
| ME attack surface | Neutered vs full — ต่างกันมาก |
| Network isolation | nftables ป้องกันได้จริง 100% |
| Key ownership | User GPG key vs Microsoft CA |
| Firmware auditability | coreboot source vs closed UEFI |
| Side-channel mitigation | SMT off = hardware-level fix |
| SPI write protection | ควบคุมเองทุกชั้น |
| Vendor lock-in | ไม่มี — Boot Guard disabled |

### Vendor ชนะ

| หมวด | เหตุผล |
|------|--------|
| CPU vuln response | Microcode update เร็วกว่า |
| Multi-thread performance | SMT on = +20-30% |
| Suspend/resume | ทดสอบมาดีกว่า |
| ThunderBolt security | BIOS-level options |
| TPM features | Measured boot, sealed LUKS |
| Disk encryption UX | TPM auto-unseal |
| Maintenance effort | Auto-update, BIOS menu |

### Trade-off ตามระดับ Threat Model

| Threat Model | แนะนำ | เหตุผล |
|---|---|---|
| State-level adversary | **Libreboot** | ME neutered + user key + SPI WP คุ้มกับ effort |
| Corporate espionage | **Libreboot** | Firmware audit + network isolation สำคัญ |
| Targeted attack | Libreboot หรือ Vendor | ขึ้นอยู่กับ priority: security vs convenience |
| Random attacker | **Vendor + hardened Guix** | เพียงพอ ด้วย effort น้อยกว่ามาก |
| General privacy | **Libreboot** | ME neutered + ไม่มี TPM attestation |

---

## ไฟล์อ้างอิง

| ไฟล์ | เนื้อหา |
|------|--------|
| `libre_boot_secure_best_practice.md` | Full security practice guide 8 ชั้น |
| `T480_WRITE_PROTECTION.md` | SPI Write Protection 3 วิธี |
| `RFLeakAnalysis.md` | RF + ME + ThunderBolt analysis |
| `config/coreboot/t480_vfsp_16mb/config/libgfxinit_corebootfb` | coreboot config (SMT, TPM, FSP, ME, WP) |
| `config/data/grub/module/xhci_nvme` | GRUB modules (pgp, pubkey, crypto) |
| `sec_scan.sh` | Supply chain integrity verification |
