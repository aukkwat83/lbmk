# Build Libreboot บน Guix System

คู่มือสำหรับ build Libreboot (lbmk) firmware บน Guix System
ตั้งแต่เครื่องใหม่จนถึง build สำเร็จ

## ข้อกำหนดเบื้องต้น

- Guix System (x86_64)
- อินเทอร์เน็ต (สำหรับดาวน์โหลด source และ GNAT binary)
- พื้นที่ว่าง ~5 GB

## ขั้นตอนบนเครื่องใหม่

### 1. ตั้งค่า Git

```bash
git config --global user.name "ชื่อ"
git config --global user.email "อีเมล"
```

### 2. ตั้งค่า PATH

เพิ่มบรรทัดนี้ใน `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
eval "$(guix-ssl-env)"
```

จากนั้นโหลดค่าใหม่:

```bash
source ~/.bashrc
```

### 3. Clone repo

```bash
git clone https://codeberg.org/libreboot/lbmk.git
cd lbmk
```

### 4. รัน init

```bash
guix shell -m manifest.scm -- ./init.sh
```

ครั้งแรกจะใช้เวลาสักครู่ เพราะต้อง:

- ดาวน์โหลด dependencies ผ่าน Guix (~70 packages)
- ดาวน์โหลด GNAT Ada compiler (~382 MB) ไปยัง `~/.local/lib/gnat-*/`
- สร้าง wrapper `cc`, `c99`, `python`, `gnat*` ใน `~/.local/bin/`
- Patch ELF interpreter ของ binary ที่ pre-compiled (GNAT, cbfstool, ifdtool)
- Rebuild `util/sbase/` จาก source
- Copy `unifont.pcf.gz` สำหรับ GRUB
- สร้าง `guix-ssl-env` helper สำหรับ SSL certificates

### 5. Build

```bash
guix shell -m manifest.scm
./mk -b coreboot t480_vfsp_16mb
```

Build ครั้งแรกจะนานเพราะต้อง compile coreboot crossgcc toolchain

### 6. ผลลัพธ์

ROM images จะอยู่ใน `bin/t480_vfsp_16mb/`:

```
seagrub_t480_vfsp_16mb_libgfxinit_corebootfb_usqwerty.rom
seagrub_t480_vfsp_16mb_libgfxinit_txtmode_usqwerty.rom
seabios_t480_vfsp_16mb_libgfxinit_corebootfb.rom
...
```

## เมื่อย้ายเครื่องหรือเปลี่ยน user

รัน `init.sh` อีกครั้ง:

```bash
guix shell -m manifest.scm -- ./init.sh
```

สคริปต์จะจัดการให้อัตโนมัติ:

- Patch ELF binary ใหม่ให้ตรงกับ glibc ของเครื่องปัจจุบัน
- ตรวจจับว่า project path เปลี่ยนแล้วลบ build tree เก่าของ GRUB
- สร้าง wrapper ใหม่ที่ชี้ path ถูกต้อง

## Build target อื่น

ดู target ที่มี:

```bash
ls config/coreboot/
```

Build target ที่ต้องการ:

```bash
./mk -b coreboot <ชื่อ_target>
```

## ไฟล์สำคัญ

| ไฟล์ | หน้าที่ |
|------|---------|
| `manifest.scm` | รายการ dependencies สำหรับ `guix shell` |
| `init.sh` | สคริปต์ setup เครื่องใหม่ (รันใน guix shell) |
| `config/data/grub/mkhelper.cfg` | config ของ GRUB ใช้ `${PWD}` เป็น path แบบ dynamic |

## ทำไมต้องมี GNAT

T480 ใช้ `libgfxinit` สำหรับ graphics initialization ซึ่งเขียนด้วย Ada
coreboot ต้อง build crossgcc toolchain พร้อม Ada support
จึงต้องมี GNAT compiler บนเครื่อง host

GNU Guix ไม่มี package GNAT จึงใช้ pre-built binary จาก
[ALIRE project](https://github.com/alire-project/GNAT-FSF-builds)
version 15.2.0 ให้ตรงกับ `gcc-toolchain@15` ใน manifest

## แก้ปัญหา

| ปัญหา | วิธีแก้ |
|-------|---------|
| `gcc: command not found` | ยังไม่ได้อยู่ใน `guix shell -m manifest.scm` |
| `unifont.pcf.gz not found` | ตรวจว่า manifest มี `(list font-gnu-unifont "pcf")` |
| `sbase/sha512sum: cannot execute` | รัน `init.sh` ใน guix shell |
| `cbfstool: cannot execute` | รัน `init.sh` ใน guix shell |
| SSL/TLS error ตอนดาวน์โหลด | เพิ่ม `eval "$(guix-ssl-env)"` ใน `~/.bashrc` |

## ล้าง build artifacts

```bash
rm -rf bin/ src/ xbmkwd/          # ผลลัพธ์และ source tree
rm -rf elf/coreboot/*/            # coreboot tools ที่ compile แล้ว
rm -rf cache/                     # cache ทั้งหมด (unifont, fonts, state)
```

GNAT อยู่ที่ `~/.local/lib/gnat-*/` แยกจาก project
ลบได้ด้วย `rm -rf ~/.local/lib/gnat-*`

## อัปเดต GNAT version

เมื่อ Guix อัปเดต `gcc-toolchain` เป็น version ใหม่:

1. แก้ `GNAT_VERSION`, `GNAT_SHA256` ใน `init.sh`
2. แก้ `gcc-toolchain@XX` ใน `manifest.scm`
3. ลบ `~/.local/lib/gnat-*` แล้วรัน `init.sh` ใหม่
