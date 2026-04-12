# RF Leak Analysis Report — ThinkPad T480 Libreboot

**Date:** 2026-04-12  
**Target:** Lenovo ThinkPad T480 running Libreboot (coreboot)  
**Firmware:** coreboot `25.12-565-gca0d1a11955a-dirty` (build 2026-04-05)  
**OS:** GNU Guix System (Linux 6.18.20-gnu)  
**Objective:** ระบุแหล่งที่มาของ RF emission ผิดปกติจาก CPU/mainboard

---

## 1. System Hardware Summary

| Component | Detail |
|-----------|--------|
| CPU | Intel Core i7-8550U @ 1.80GHz (Kaby Lake-R, 8th Gen) |
| Microcode | `0xf6` (revision 246) |
| Logical CPUs | 4 (HyperThreading disabled — ปกติควรเป็น 8) |
| PCH | Sunrise Point-LP (rev 21) |
| Flash | 16MB SPI NOR |
| IFD Platform | `sklkbl` (Skylake/Kaby Lake unified) |
| Ethernet | Intel I219-LM (`enp0s31f6`) — wired only |
| ThunderBolt | Intel JHL6240 Alpine Ridge LP (rev 01) |
| WiFi | **ไม่มี** — ไม่พบ hardware |
| Bluetooth | **ไม่มี** — ไม่พบ hardware |

---

## 2. Intel ME (Management Engine) Status

| Check | Result |
|-------|--------|
| PCI device `00:16.0` | **ไม่มี** |
| PCI device `00:16.*` | **ไม่มี** ทุก sub-function |
| MEI kernel module | **ไม่ได้โหลด** |
| `lsmod \| grep mei` | ไม่พบ |

### Assessment

ME ถูก neuter สำเร็จโดย `me_cleaner` ของ Libreboot:
- ME firmware ถูกตัดเหลือ 2MB SKU (`config/vendor/t480/pkg.cfg`: `ME11sku="2M"`)
- Boot Guard ถูกปิดผ่าน `deguard` (`ME11bootguard="y"`)
- ME version: `11.6.0.1126`, PCH: LP
- `me_state=Disabled` ถูก set ใน CMOS (patch `0004`)

**Verdict: ME ไม่ใช่แหล่ง RF leak — ถูกปิดแล้ว**

---

## 3. Wireless & Bluetooth Status

```
WiFi (ieee80211):  ไม่พบ hardware
Bluetooth:         ไม่พบ hardware
rfkill:            ไม่มี device
iwlwifi module:    ไม่ได้โหลด
btusb module:      ไม่ได้โหลด
```

Network interfaces ที่ active:
- `lo` — loopback
- `enp0s31f6` — Intel I219-LM (wired Ethernet, state UP)

**Verdict: ไม่มี wireless transceiver ใด ๆ — ตัดออกจากแหล่ง RF leak**

---

## 4. ThunderBolt Controller — ตัวต้องสงสัยหลัก

### Hardware Detail

| Property | Value |
|----------|-------|
| Controller | Intel JHL6240 Alpine Ridge LP 2016 |
| PCI IDs | `8086:15c0` (bridge), `8086:15bf` (NHI), `8086:15c1` (USB) |
| Subsystem ID | **`2222:1111`** |
| Kernel driver | `thunderbolt` (loaded) |
| Firmware source | Lenovo `n24th13w.exe` (extracted, 1MB) |

### PCI Topology (6 devices active)

```
01:00.0 PCI bridge         — JHL6240 TB3 Bridge (root)
02:00.0 PCI bridge         — JHL6240 TB3 Bridge
02:01.0 PCI bridge         — JHL6240 TB3 Bridge
02:02.0 PCI bridge         — JHL6240 TB3 Bridge
03:00.0 System peripheral  — JHL6240 TB3 NHI (Native Host Interface)
05:00.0 USB controller     — JHL6240 TB3 USB 3.1
```

### Findings

1. **Subsystem ID `2222:1111` ผิดปกติ** — ค่า Lenovo มาตรฐานควรเป็น `17aa:xxxx` ค่า `2222:1111` อาจหมายถึง:
   - ThunderBolt firmware ถูก flash ด้วย generic/custom image
   - Subsystem ID ถูกเปลี่ยนระหว่าง Libreboot build process
   - ค่าจาก `config/vendor/t480/pkg.cfg` อาจไม่ตรงกับ OEM

2. **Controller active ตลอดเวลา** — แม้ไม่ได้เสียบอุปกรณ์ ThunderBolt ใด ๆ controller ยังทำงานอยู่ (kernel module loaded, 6 PCI devices enumerated)

3. **High-speed differential signaling** — ThunderBolt 3 ใช้ signaling ที่ความถี่สูง (up to 40 Gbps) ซึ่งเป็นแหล่ง EMI/RF emission สำคัญ แม้ไม่มีอุปกรณ์ต่ออยู่ controller ยังอาจส่ง idle pattern หรือ link training signals

4. **Firmware แยกต่างหาก** — ThunderBolt IC มี flash 1MB แยกจาก main SPI:
   - Download URL: `https://download.lenovo.com/pccbbs/mobiles/n24th13w.exe`
   - Binary hash: `15aea269e79d92fe...`
   - กำหนดใน `config/vendor/t480/pkg.cfg`

### Risk Level: HIGH

**Verdict: ThunderBolt เป็นตัวต้องสงสัยหลักสำหรับ RF leak**

### Recommended Actions

```bash
# ทดสอบโดยปิด ThunderBolt module แล้ววัด RF ใหม่
sudo modprobe -r thunderbolt

# ถ้า RF ลดลง ให้ blacklist ถาวร
echo "blacklist thunderbolt" | sudo tee /etc/modprobe.d/no-thunderbolt.conf

# ตรวจ firmware version
sudo cat /sys/bus/thunderbolt/devices/*/nvm_version 2>/dev/null
```

---

## 5. CPU & Microcode Analysis

### Microcode

| Property | Value |
|----------|-------|
| Version | `0xf6` (246 decimal) |
| Source | `config/submodule/coreboot/default/intel-microcode/module.cfg` |
| Repo | `https://review.coreboot.org/intel-microcode.git` |
| Hash | `f910b0a225d66a23a407710c61b0b63ee612b50f` |

Version `0xf6` เป็น revision มาตรฐานสำหรับ Kaby Lake-R (i7-8550U, CPUID `0x806EA`) ไม่มีสิ่งผิดปกติจากตัว version เอง อย่างไรก็ตาม microcode เป็น closed binary blob ที่ไม่สามารถ audit ได้

### CPU Flags ที่เกี่ยวข้อง

| Flag | ความหมาย | ผลต่อ RF |
|------|----------|----------|
| `intel_pt` | Intel Processor Trace | อาจเพิ่ม bus activity |
| `hwp` / `hwp_epp` | Hardware P-states | ควบคุม frequency scaling — อาจสร้าง clock harmonics |
| `vmx` | VT-x enabled | ไม่เกี่ยวกับ RF โดยตรง |
| `monitor` | MONITOR/MWAIT | เกี่ยวกับ C-states / power gating |
| `dtherm` | Digital Thermal Sensor | ตรวจวัด thermal — ไม่เกี่ยวกับ RF |
| `art` | Always Running Timer | timer ที่ทำงานตลอด — minimal RF impact |

### HyperThreading Disabled

- i7-8550U มี 4 cores / 8 threads แต่ระบบเห็นแค่ 4 logical CPUs
- SMT ถูกปิด (น่าจะเพื่อ Spectre/MDS mitigation)
- การปิด SMT เปลี่ยน power delivery pattern ของ CPU ซึ่งอาจเปลี่ยนลักษณะ RF emission ได้เล็กน้อย

**Verdict: Microcode และ CPU config ไม่น่าจะเป็นแหล่ง RF leak หลัก แต่ไม่สามารถ audit blob ได้**

---

## 6. Thermal & Signal Processing Controllers

```
00:04.0 Signal processing controller — Xeon E3-1200 v5 Thermal Subsystem [8086:1903]
00:14.2 Signal processing controller — Sunrise Point-LP Thermal subsystem [8086:9d31]
```

ทั้งสองตัวเป็น thermal/power management controller ที่:
- ควบคุม CPU PLL, clock dividers, power rails
- กำหนดพฤติกรรมโดย FSP-S (closed binary)
- FSP-S path: `vendorfiles/kabylake/Fsp_S.fd`
- Config: `CONFIG_FSP_FD_PATH="3rdparty/fsp/KabylakeFspBinPkg/Fsp.fd"`

PLL และ clock circuitry สามารถสร้าง RF harmonics ได้ โดยเฉพาะถ้า:
- Spread spectrum clocking (SSC) ถูกปิดหรือ misconfigure
- Clock frequencies ตรงกับ resonant frequency ของ PCB trace

**Verdict: เป็นไปได้แต่ยากที่จะเปลี่ยนโดยไม่แก้ FSP binary**

---

## 7. PCI Device Map (ทุก device ที่ active)

| BDF | Class | Device | Risk |
|-----|-------|--------|------|
| `00:00.0` | Host Bridge | Kaby Lake DRAM Registers | Low |
| `00:02.0` | VGA | UHD Graphics 620 | Low |
| `00:04.0` | Signal Proc | Thermal Subsystem (CPU) | Medium |
| `00:14.0` | USB | Sunrise Point USB 3.0 xHCI | Low |
| `00:14.2` | Signal Proc | Thermal Subsystem (PCH) | Medium |
| `00:17.0` | SATA | Sunrise Point AHCI | Low |
| `00:1d.0` | PCI Bridge | PCIe Root Port #9 | Low |
| `00:1f.0` | ISA Bridge | LPC/eSPI Controller | Low |
| `00:1f.2` | Memory | Sunrise Point PMC | Low |
| `00:1f.3` | Audio | HD Audio | Low |
| `00:1f.6` | Ethernet | I219-LM | Low |
| `01:00.0` | PCI Bridge | **JHL6240 TB3** | **HIGH** |
| `02:00.0` | PCI Bridge | **JHL6240 TB3** | **HIGH** |
| `02:01.0` | PCI Bridge | **JHL6240 TB3** | **HIGH** |
| `02:02.0` | PCI Bridge | **JHL6240 TB3** | **HIGH** |
| `03:00.0` | System Periph | **JHL6240 TB3 NHI** | **HIGH** |
| `05:00.0` | USB | **JHL6240 TB3 USB 3.1** | **HIGH** |

ไม่พบ device `00:16.x` (Intel ME) — ยืนยันว่า ME ถูก neuter สำเร็จ

---

## 8. CPU Vulnerability Mitigations

| Vulnerability | Mitigation |
|---------------|-----------|
| Meltdown | PTI (Page Table Isolation) |
| Spectre v1 | usercopy/swapgs barriers |
| Spectre v2 | IBRS + IBPB + RSB filling |
| MDS | Clear CPU buffers, **SMT disabled** |
| L1TF | PTE Inversion, VMX conditional flush, **SMT disabled** |
| MMIO Stale Data | Clear CPU buffers, **SMT disabled** |
| Gather Data Sampling | Microcode mitigation |
| SRBDS | Microcode mitigation |
| Spec Store Bypass | Disabled via prctl |
| TSX Async Abort | Not affected |
| Retbleed | IBRS |

SMT ถูกปิดเพื่อ mitigation — ยืนยันว่า HyperThreading disabled ไม่ใช่ anomaly

---

## 9. Libreboot/lbmk Configuration Files ที่เกี่ยวข้อง

### Files ที่เกี่ยวกับ CPU โดยตรง

| File | Role |
|------|------|
| `config/coreboot/t480_vfsp_16mb/target.cfg` | Board target, IFD platform |
| `config/coreboot/t480_vfsp_16mb/config/libgfxinit_corebootfb` | Full coreboot config (CPU, SMM, FSP, ME, power) |
| `config/coreboot/t480_vfsp_16mb/config/libgfxinit_txtmode` | Text-mode variant |
| `config/vendor/t480/pkg.cfg` | ME, FSP, ThunderBolt firmware config |
| `config/ifd/t480/ifd_16` | Intel Flash Descriptor (region map) |
| `config/ifd/t480/gbe` | Gigabit Ethernet NIC config |

### Files ที่เกี่ยวกับ firmware blobs

| File | Role |
|------|------|
| `config/submodule/coreboot/default/intel-microcode/module.cfg` | Microcode repository |
| `config/submodule/coreboot/default/fsp/module.cfg` | FSP repository |
| `include/vendor.sh` | ME extraction, FSP handling, deguard, me_cleaner |

### Patches ที่เกี่ยวข้อง

| Patch | Effect |
|-------|--------|
| `0004-set-me_state-Disabled-on-all-cmos.default-files.patch` | Force ME soft-disable |
| `0029-src-intel-skylake-Disable-stack-overflow-debug-optio.patch` | Disable CPU debug on SKL |
| `0030-soc-intel-skylake-Don-t-compress-FSP-S.patch` | FSP-S uncompressed for reproducibility |
| `0031-lenovo-Add-Kconfig-option-CONFIG_LENOVO_TBFW_BIN.patch` | ThunderBolt firmware Kconfig |
| `0032-Conditional-TBFW-setting-for-kabylake-thinkpads.patch` | TB firmware for T480/T480s/T580 |

---

## 10. Conclusion & Recommendations

### Summary

| แหล่ง | Status | RF Risk |
|--------|--------|---------|
| Intel ME | Neutered + soft-disabled | **None** |
| WiFi/Bluetooth | ไม่มี hardware | **None** |
| Ethernet (I219-LM) | Active, wired only | **Low** |
| CPU Microcode (`0xf6`) | Standard version, closed blob | **Low-Medium** (ไม่สามารถ audit) |
| FSP-M / FSP-S | Closed binary, controls PLL/clock | **Medium** (ไม่สามารถ audit) |
| Thermal controllers | Active, controlled by FSP | **Medium** |
| **ThunderBolt (JHL6240)** | **Active, anomalous subsystem ID** | **HIGH** |

### Recommended Investigation Steps

1. **ปิด ThunderBolt module แล้ววัด RF**
   ```bash
   sudo modprobe -r thunderbolt
   # วัด RF — ถ้าลดลง = ThunderBolt เป็นตัวการ
   ```

2. **ตรวจ dmesg สำหรับ firmware anomalies**
   ```bash
   sudo dmesg | grep -iE "thunder|microcode|firmware|error|fail"
   ```

3. **ตรวจ ThunderBolt NVM firmware version**
   ```bash
   sudo cat /sys/bus/thunderbolt/devices/*/nvm_version
   ```

4. **เปรียบเทียบ RF emission ก่อน/หลังปิดแต่ละ component**
   - ปิด ThunderBolt -> วัด RF
   - ปิด Audio (`sudo modprobe -r snd_hda_intel`) -> วัด RF
   - เปลี่ยน CPU governor (`echo powersave | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`) -> วัด RF

5. **ถ้า ThunderBolt เป็นตัวการ — blacklist ถาวร**
   ```bash
   echo "blacklist thunderbolt" | sudo tee /etc/modprobe.d/no-thunderbolt.conf
   ```

6. **พิจารณา hardware-level investigation**
   - ใช้ SDR (Software Defined Radio) วัดความถี่ที่ emit ออกมา
   - เทียบกับ clock frequencies ที่ใช้: 100 MHz BCLK, 24 MHz crystal, TB3 signaling frequencies
   - ถ้า RF ตรงกับ harmonic ของ clock frequency ใด = ระบุ source ได้แม่นยำ

### Security Considerations

- **Intel Microcode** (`0xf6`) และ **FSP** เป็น closed binary blobs ที่ไม่สามารถ audit ได้ — เป็นข้อจำกัดพื้นฐานของ Intel platform แม้จะใช้ Libreboot
- **ThunderBolt firmware** เป็น closed binary จาก Lenovo — มี DMA access ที่สามารถเข้าถึง memory โดยตรง
- RF emission ที่ผิดปกติอาจเป็นผลจาก firmware ทำงานไม่ถูกต้อง หรืออาจเป็น side-channel ที่ leak ข้อมูลผ่าน electromagnetic emanation (TEMPEST-class concern)

---

*Report generated by Claude Code — based on live system diagnostics on 2026-04-12*
