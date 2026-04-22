
## 🔧 External Dependencies (Downloaded Outside Guix)

The following components are downloaded directly from upstream sources during the build setup process (`init.sh`):

### 🔵 GNAT FSF (Ada Compiler)

- **Version:** `15.2.0-1`
- **Source:** External Download
- **Used in:** init.sh, Main Build (coreboot crossgcc)
- **Purpose:** Ada compiler frontend for GCC, required to build coreboot's crossgcc with Ada support
- **Status:** ✓ GNAT FSF builds from GCC releases - blob-free Ada compiler
- **License:** GPL-3.0-or-later with GCC Runtime Library Exception
- **Description:** FSF GCC-based GNAT Ada compiler. Required for coreboot Ada support. Built from FSF GCC 15.2.0 sources.
- **🌐 Upstream:** <https://github.com/alire-project/GNAT-FSF-builds>
- **📥 Download URL:** <https://github.com/alire-project/GNAT-FSF-builds/releases/download/gnat-15.2.0-1/gnat-x86_64-linux-15.2.0-1.tar.gz>
- **📜 Release Info:** <https://github.com/alire-project/GNAT-FSF-builds/releases/tag/gnat-15.2.0-1>
- **🔐 SHA256:** `4640d4b369833947ab1a156753f4db0ecd44b0f14410b5b2bc2a14df496604bb`
- **📦 Components:**
  - gcc-15.2.0 (base compiler)
  - gnat-15.2.0 (Ada frontend)
  - binutils
  - gdb
  - Ada runtime libraries
- **📂 Installed to:** `$HOME/.local/lib/gnat-15.2.0-1`
- **✅ Verification:** SHA256 checksum verified in init.sh

### 🔵 arm-none-eabi-nano-toolchain

- **Version:** `12.3.rel1`
- **Source:** Guix Package (make-arm-none-eabi-nano-toolchain-12.3.rel1)
- **Used in:** manifest-pico.scm, Pico Serprog Build
- **Purpose:** Cross-compiler for Raspberry Pi Pico (ARM Cortex-M0+)
- **Status:** ✓ Blob-free ARM bare-metal toolchain from Guix
- **License:** GPL-3.0-or-later
- **Description:** GCC-based toolchain for ARM Cortex-M microcontrollers with newlib-nano
- **🌐 Upstream:** <https://developer.arm.com/Tools%20and%20Software/GNU%20Toolchain>
- **📦 Components:**
  - arm-none-eabi-gcc
  - arm-none-eabi-binutils
  - newlib (C library)
  - newlib-nano (size-optimized C library)

### 🔵 GNU Unifont

- **Version:** `15.x (from Guix)`
- **Source:** Guix Package (font-gnu-unifont)
- **Used in:** manifest.scm, GRUB build
- **Purpose:** Provides Unicode font for GRUB graphical menu
- **Status:** ✓ Blob-free Unicode font
- **License:** GPL-2.0-or-later
- **Description:** GNU Unifont bitmap font, used by GRUB bootloader
- **🌐 Upstream:** <https://unifoundry.com/unifont/>

