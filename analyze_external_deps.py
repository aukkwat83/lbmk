#!/usr/bin/env python3
"""
Analyze external dependencies downloaded outside Guix
Focus on GNAT and other binary downloads from init.sh and init-pico.sh
"""

import re
import json

# GNAT FSF information from init.sh
GNAT_INFO = {
    "name": "GNAT FSF (Ada Compiler)",
    "version": "15.2.0-1",
    "source": "External Download",
    "upstream_url": "https://github.com/alire-project/GNAT-FSF-builds",
    "download_url": "https://github.com/alire-project/GNAT-FSF-builds/releases/download/gnat-15.2.0-1/gnat-x86_64-linux-15.2.0-1.tar.gz",
    "sha256": "4640d4b369833947ab1a156753f4db0ecd44b0f14410b5b2bc2a14df496604bb",
    "blob_free": "true",
    "license": "GPL-3.0-or-later with GCC Runtime Library Exception",
    "note": "✓ GNAT FSF builds from GCC releases - blob-free Ada compiler",
    "description": "FSF GCC-based GNAT Ada compiler. Required for coreboot Ada support. Built from FSF GCC 15.2.0 sources.",
    "used_in": ["init.sh", "Main Build (coreboot crossgcc)"],
    "purpose": "Ada compiler frontend for GCC, required to build coreboot's crossgcc with Ada support",
    "components": [
        "gcc-15.2.0 (base compiler)",
        "gnat-15.2.0 (Ada frontend)",
        "binutils",
        "gdb",
        "Ada runtime libraries"
    ],
    "maintainer": "Alire Project",
    "build_source": "Built from FSF GCC sources",
    "verification": "SHA256 checksum verified in init.sh",
    "installed_to": "$HOME/.local/lib/gnat-15.2.0-1",
    "reference_url": "https://github.com/alire-project/GNAT-FSF-builds/releases/tag/gnat-15.2.0-1"
}

# ARM toolchain from manifest-pico.scm
ARM_TOOLCHAIN_INFO = {
    "name": "arm-none-eabi-nano-toolchain",
    "version": "12.3.rel1",
    "source": "Guix Package (make-arm-none-eabi-nano-toolchain-12.3.rel1)",
    "blob_free": "true",
    "license": "GPL-3.0-or-later",
    "note": "✓ Blob-free ARM bare-metal toolchain from Guix",
    "description": "GCC-based toolchain for ARM Cortex-M microcontrollers with newlib-nano",
    "used_in": ["manifest-pico.scm", "Pico Serprog Build"],
    "purpose": "Cross-compiler for Raspberry Pi Pico (ARM Cortex-M0+)",
    "components": [
        "arm-none-eabi-gcc",
        "arm-none-eabi-binutils",
        "newlib (C library)",
        "newlib-nano (size-optimized C library)"
    ],
    "upstream_url": "https://developer.arm.com/Tools%20and%20Software/GNU%20Toolchain",
    "guix_definition": "gnu/packages/embedded.scm"
}

def analyze_init_scripts():
    """Analyze init.sh and init-pico.sh for external dependencies"""
    external_deps = []
    
    # Add GNAT
    external_deps.append(GNAT_INFO)
    
    # Add ARM toolchain
    external_deps.append(ARM_TOOLCHAIN_INFO)
    
    # Check for other downloads in init.sh
    try:
        with open('init.sh', 'r') as f:
            content = f.read()
            
            # Check for unifont
            if 'unifont' in content:
                external_deps.append({
                    "name": "GNU Unifont",
                    "version": "15.x (from Guix)",
                    "source": "Guix Package (font-gnu-unifont)",
                    "blob_free": "true",
                    "license": "GPL-2.0-or-later",
                    "note": "✓ Blob-free Unicode font",
                    "description": "GNU Unifont bitmap font, used by GRUB bootloader",
                    "used_in": ["manifest.scm", "GRUB build"],
                    "purpose": "Provides Unicode font for GRUB graphical menu",
                    "upstream_url": "https://unifoundry.com/unifont/",
                    "format": "PCF (Portable Compiled Format)",
                    "cached_in": "cache/fonts-misc/unifont.pcf.gz"
                })
    except FileNotFoundError:
        pass
    
    return external_deps

def generate_external_deps_section(external_deps):
    """Generate Markdown section for external dependencies"""
    
    section = """
## 🔧 External Dependencies (Downloaded Outside Guix)

The following components are downloaded directly from upstream sources during the build setup process (`init.sh`):

"""
    
    for dep in external_deps:
        icon = "🔵" if dep['blob_free'] == "true" else "🔴"
        
        section += f"""### {icon} {dep['name']}

- **Version:** `{dep['version']}`
- **Source:** {dep['source']}
- **Used in:** {', '.join(dep['used_in']) if isinstance(dep['used_in'], list) else dep['used_in']}
- **Purpose:** {dep['purpose']}
- **Status:** {dep['note']}
- **License:** {dep['license']}
- **Description:** {dep['description']}
"""
        
        if 'upstream_url' in dep:
            section += f"- **🌐 Upstream:** <{dep['upstream_url']}>\n"
        
        if 'download_url' in dep:
            section += f"- **📥 Download URL:** <{dep['download_url']}>\n"
        
        if 'reference_url' in dep:
            section += f"- **📜 Release Info:** <{dep['reference_url']}>\n"
        
        if 'sha256' in dep:
            section += f"- **🔐 SHA256:** `{dep['sha256']}`\n"
        
        if 'components' in dep and dep['components']:
            section += f"- **📦 Components:**\n"
            for comp in dep['components']:
                section += f"  - {comp}\n"
        
        if 'installed_to' in dep:
            section += f"- **📂 Installed to:** `{dep['installed_to']}`\n"
        
        if 'verification' in dep:
            section += f"- **✅ Verification:** {dep['verification']}\n"
        
        section += "\n"
    
    return section

def main():
    print("🔍 Analyzing external dependencies...")
    
    external_deps = analyze_init_scripts()
    
    print(f"   Found {len(external_deps)} external dependencies")
    
    # Generate markdown section
    markdown = generate_external_deps_section(external_deps)
    
    # Save to file
    with open('external_deps_section.md', 'w') as f:
        f.write(markdown)
    
    print("✅ External dependencies section generated: external_deps_section.md")
    
    # Also save as JSON
    with open('external_deps.json', 'w') as f:
        json.dump(external_deps, f, indent=2)
    
    print("✅ External dependencies JSON: external_deps.json")

if __name__ == "__main__":
    main()
