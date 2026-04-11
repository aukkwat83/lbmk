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
