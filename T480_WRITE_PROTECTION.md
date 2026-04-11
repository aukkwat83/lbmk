# ThinkPad T480 Write Protection Guide (Libreboot/LBMK)

## สถานะปัจจุบัน

Libreboot config สำหรับ T480 (`config/coreboot/t480_vfsp_16mb/`) มีการ **ปิด WP ทั้งหมด** ไว้โดยเจตนา:

| Config Option | ค่าปัจจุบัน | ความหมาย |
|---|---|---|
| `CONFIG_BOOTMEDIA_SMM_BWP` | **not set** (ปิด) | ไม่มี SMM write protection |
| `CONFIG_UNLOCK_FLASH_REGIONS` | **y** (เปิด) | IFD regions ถูกปลดล็อค |
| `CONFIG_LOCK_MANAGEMENT_ENGINE` | **not set** (ปิด) | ME region ไม่ถูกล็อค |

**Chipset:** Intel Skylake/Kaby Lake (SKL/KBL)
**Flash chip:** SPI NOR 16MB
**IFD platform:** `sklkbl`

ผลลัพธ์คือ ใครก็ตามที่มี root access สามารถ `flashprog -p internal` เขียนทับ firmware ได้ทั้งหมด

---

## วิธีเปิด Write Protection

### วิธีที่ 1: SPI Flash Chip Hardware WP (แนะนำ — ป้องกันระดับ hardware)

วิธีนี้ป้องกันได้แน่นอนที่สุด เพราะทำที่ตัวชิป SPI โดยตรง ไม่มีซอฟต์แวร์ใด bypass ได้

**ขั้นตอน:**

1. **Flash Libreboot ลง T480 ให้เรียบร้อยก่อน**

2. **ตั้ง Block Protection bits บน SPI flash chip** ผ่าน flashprog:
   ```bash
   # ดูสถานะ status register ปัจจุบัน
   flashprog -p internal --wp-status

   # เปิด write protection ทั้งชิป
   flashprog -p internal --wp-enable --wp-range 0x000000 0x1000000
   ```
   - `BP0, BP1, BP2` — กำหนดขอบเขตที่ป้องกัน (ตั้งทั้งชิป = 16MB = `0x1000000`)
   - `SRP0/SRP1` — ล็อค status register ไม่ให้แก้ไขจาก software

3. **ต่อขา /WP pin ของ SPI flash chip ลง GND**
   - ต้องเปิดเครื่อง ถอดฝาหลัง เข้าถึงตัว SPI flash chip บน mainboard
   - บัดกรีลวดจากขา /WP (pin 3 บน SPI 8-pin SOIC) ลง GND (pin 4)
   - หรือใช้ jumper/switch เพื่อให้สลับ on/off ได้สะดวก

4. **ทดสอบ** — boot เข้า OS แล้วลอง:
   ```bash
   # ต้อง fail ถ้า WP ทำงานถูกต้อง
   flashprog -p internal --wp-status
   flashprog -p internal -w test.rom  # ต้องเขียนไม่ได้
   ```

**เมื่อต้องการอัปเดต firmware:**
1. ถอดขา /WP ออกจาก GND
2. ปิด write protection: `flashprog -p internal --wp-disable`
3. Flash firmware ใหม่
4. เปิด WP กลับ + ต่อขา /WP ลง GND อีกครั้ง

---

### วิธีที่ 2: เปิด CONFIG_BOOTMEDIA_SMM_BWP (Software WP — ต้อง build ใหม่)

ป้องกันระดับ firmware ผ่าน System Management Mode (SMM) ไม่ต้องบัดกรี แต่มีโอกาสถูก bypass ได้ถ้า attacker มี exploit ระดับ SMM

**ขั้นตอน:**

1. **แก้ไข coreboot config** — แก้ทั้ง 2 ไฟล์:

   `config/coreboot/t480_vfsp_16mb/config/libgfxinit_corebootfb` บรรทัด 244:
   ```diff
   - # CONFIG_BOOTMEDIA_SMM_BWP is not set
   + CONFIG_BOOTMEDIA_SMM_BWP=y
   ```

   `config/coreboot/t480_vfsp_16mb/config/libgfxinit_txtmode` (แก้เหมือนกัน)

2. **(แนะนำ) ปิด UNLOCK_FLASH_REGIONS** — บรรทัด 532:
   ```diff
   - CONFIG_UNLOCK_FLASH_REGIONS=y
   + # CONFIG_UNLOCK_FLASH_REGIONS is not set
   ```
   เพื่อให้ IFD region permissions มีผลบังคับ (host จะเขียนได้เฉพาะ BIOS region)

3. **(แนะนำ) เปิด LOCK_MANAGEMENT_ENGINE** — บรรทัด 531:
   ```diff
   - # CONFIG_LOCK_MANAGEMENT_ENGINE is not set
   + CONFIG_LOCK_MANAGEMENT_ENGINE=y
   ```

4. **Build coreboot ใหม่:**
   ```bash
   ./mk build coreboot t480_vfsp_16mb
   ```

5. **Flash ROM ที่ build ใหม่ลงเครื่อง**

**ผลลัพธ์:**
- เมื่อ OS พยายามเขียน flash → chipset สร้าง SMI → SMM handler บล็อคการเขียน
- `flashprog -p internal` จะเขียนไม่ได้จาก OS

**ข้อจำกัด:**
- ป้องกันได้เฉพาะ software-level — ถ้า attacker มี SMM exploit ก็ bypass ได้
- ยังเขียนได้ผ่าน external programmer (serprog)

---

### วิธีที่ 3: Full Stack Protection (ป้องกันสูงสุด)

รวมทุกชั้นเข้าด้วยกัน:

**ขั้นตอน:**

1. **แก้ coreboot config ตามวิธีที่ 2** (เปิด SMM_BWP, ปิด UNLOCK_FLASH_REGIONS, เปิด LOCK_ME)

2. **Build และ flash firmware ใหม่**

3. **ตั้ง SPI status register protection ตามวิธีที่ 1**

4. **บัดกรีขา /WP ลง GND ตามวิธีที่ 1**

**ผลลัพธ์ — ป้องกัน 3 ชั้น:**

| ชั้น | กลไก | ป้องกันอะไร |
|------|-------|------------|
| **Hardware (SPI chip)** | /WP pin + BP bits + SRP | ชิปปฏิเสธการเขียนโดยตรง ไม่มี software bypass ได้ |
| **Firmware (SMM)** | CONFIG_BOOTMEDIA_SMM_BWP | SMM handler บล็อคการเขียนจาก OS |
| **Chipset (IFD)** | IFD region permissions | Chipset บังคับ read-only ต่อ BIOS region |

---

## สรุปเปรียบเทียบ

| วิธี | ความปลอดภัย | ความยาก | ต้อง build ใหม่ | ต้องบัดกรี | bypass จาก OS |
|------|------------|---------|----------------|-----------|---------------|
| **1. SPI HW WP** | สูงมาก | ปานกลาง | ไม่ | ใช่ | ไม่ได้ |
| **2. SMM_BWP** | ปานกลาง | ง่าย | ใช่ | ไม่ | ยาก (ต้องมี SMM exploit) |
| **3. Full Stack** | สูงสุด | ยาก | ใช่ | ใช่ | ไม่ได้ |

---

## คำสั่ง flashrom/flashprog สำหรับตรวจสอบสถานะ WP

### ตรวจสอบพื้นฐาน

```bash
# ตรวจสอบว่า flashprog เห็นชิปหรือไม่ และชิปรุ่นอะไร
sudo flashprog -p internal --flash-name

# อ่านข้อมูลชิปทั้งหมด (probe)
sudo flashprog -p internal

# ดูสถานะ write protection ปัจจุบัน
sudo flashprog -p internal --wp-status

# ดู write protection range ที่ตั้งไว้
sudo flashprog -p internal --wp-list
```

### ตรวจสอบว่าเขียนได้หรือไม่ (ทดสอบ WP)

```bash
# backup ROM ปัจจุบันก่อนเสมอ
sudo flashprog -p internal -r backup.rom

# verify ว่า backup ถูกต้อง (อ่านซ้ำแล้วเทียบ)
sudo flashprog -p internal -r backup2.rom
sha512sum backup.rom backup2.rom  # hash ต้องตรงกัน

# ลองเขียน (verify only — ไม่เขียนจริง) เพื่อเช็คว่า WP ทำงาน
sudo flashprog -p internal --wp-status
# ถ้า WP เปิดอยู่ จะแสดง: WP: write protection is enabled
# ถ้า WP ปิดอยู่ จะแสดง: WP: write protection is disabled
```

### ตรวจสอบ IFD region permissions

```bash
# อ่าน flash layout (ดูว่า region ไหนเข้าถึงได้บ้าง)
sudo flashprog -p internal --fmap

# อ่านเฉพาะ BIOS region
sudo flashprog -p internal -r bios_region.bin --ifd -i bios

# ลองอ่าน ME region (ถ้า IFD lock ทำงาน จะอ่านไม่ได้)
sudo flashprog -p internal -r me_region.bin --ifd -i me
# ถ้า ME region ถูกล็อค จะได้ error: "Transaction error!"

# ลองอ่าน Flash Descriptor region
sudo flashprog -p internal -r ifd_region.bin --ifd -i fd
```

### ตรวจสอบ BIOS_CNTL register (ระดับ chipset)

```bash
# อ่าน BIOS_CNTL register จาก PCI config space
# LPC bridge = PCI 0:1f.0, offset 0xdc
sudo setpci -s 0:1f.0 dc.b

# ตีความผลลัพธ์ (เช่น ได้ "0a"):
#   bit 0 (0x01) = BIOSWE  — 0=write disabled, 1=write enabled
#   bit 1 (0x02) = BLE     — 0=no lock, 1=BIOS lock enabled
#   bit 5 (0x20) = SMM_BWP — 0=no SMM protection, 1=SMM protects BIOS
#
# ตัวอย่าง:
#   0x00 = ไม่มี protection ใดๆ (BIOSWE=0, BLE=0, SMM_BWP=0)
#   0x02 = BLE enabled แต่ BIOSWE=0 (ป้องกันอยู่)
#   0x22 = BLE + SMM_BWP enabled (ป้องกันเต็มที่)
#   0x0a = BLE enabled + BIOSWE somehow set (ผิดปกติ)
```

### ตรวจสอบ SMI status

```bash
# หา PMBASE address ก่อน
sudo setpci -s 0:1f.0 40.l
# ผลลัพธ์เช่น "00001801" → PMBASE = 0x1800 (mask bit 0)

# อ่าน SMI_EN register (PMBASE + 0x30)
sudo iotools io_read32 0x1830
# bit 0 = GBL_SMI_EN — 1=SMI enabled, 0=SMI disabled
# ถ้า GBL_SMI_EN=0 แสดงว่า SMM protection ไม่ทำงาน แม้ BLE จะตั้งไว้

# อ่าน SMI_LOCK (ใน GEN_PMCON register)
# ถ้า SMI_LOCK=1 → GBL_SMI_EN แก้ไม่ได้ (ดี)
# ถ้า SMI_LOCK=0 → attacker สามารถปิด GBL_SMI_EN ได้ (ไม่ดี)
```

### สรุปคำสั่งตรวจ WP แบบเร็ว (Quick Check)

```bash
#!/bin/bash
echo "=== Flash Chip Info ==="
sudo flashprog -p internal --flash-name

echo ""
echo "=== WP Status ==="
sudo flashprog -p internal --wp-status

echo ""
echo "=== BIOS_CNTL Register ==="
BIOS_CNTL=$(sudo setpci -s 0:1f.0 dc.b)
echo "BIOS_CNTL = 0x${BIOS_CNTL}"
VAL=$((16#${BIOS_CNTL}))
echo "  BIOSWE  (bit 0) = $(( (VAL >> 0) & 1 ))  (0=protected, 1=writable)"
echo "  BLE     (bit 1) = $(( (VAL >> 1) & 1 ))  (0=no lock, 1=locked)"
echo "  SMM_BWP (bit 5) = $(( (VAL >> 5) & 1 ))  (0=no SMM WP, 1=SMM protects)"

echo ""
echo "=== IFD Region Access Test ==="
sudo flashprog -p internal -r /tmp/ifd_test.bin --ifd -i fd 2>&1 | tail -3
sudo flashprog -p internal -r /tmp/me_test.bin --ifd -i me 2>&1 | tail -3
rm -f /tmp/ifd_test.bin /tmp/me_test.bin
```

---

## ข้อมูลอ้างอิงเฉพาะ T480

- **Board config:** `config/coreboot/t480_vfsp_16mb/`
- **IFD:** `config/ifd/t480/ifd_16`
- **Chipset:** Intel Skylake/Kaby Lake (PCH-LP)
- **Flash size:** 16MB SPI NOR
- **SPI chip pin-out (SOIC-8):**
  - Pin 1: /CS (Chip Select)
  - Pin 2: DO (Data Out)
  - **Pin 3: /WP (Write Protect) — ต่อลง GND เพื่อเปิด HW WP**
  - Pin 4: GND
  - Pin 5: DI (Data In)
  - Pin 6: CLK (Clock)
  - Pin 7: /HOLD
  - Pin 8: VCC
- **ME:** Intel ME 11.6 (deguard ใช้ปิด Boot Guard)
- **ThunderBolt:** มีชิป flash แยก 1MB (ไม่เกี่ยวกับ main flash)
