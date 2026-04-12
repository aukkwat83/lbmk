;; -*- mode: scheme; -*-
;; =============================================================================
;; libreboot-system.scm — Guix System for Libreboot (SeaGRUB / T480)
;; =============================================================================
;;
;; Partition layout สำหรับ Libreboot:
;;   /boot  — ext2 (ไม่มี journal, GRUB อ่านได้แน่นอน) ~1 GiB
;;   /      — ext4 (ส่วนที่เหลือทั้งหมด)
;;
;; SeaGRUB boot chain:
;;   Libreboot ROM -> SeaBIOS -> GRUB (MBR) -> linux-libre kernel (/boot)
;;
;; ติดตั้ง:
;;   sudo ./install.sh          # partition + format + generate UUIDs
;;   sudo guix system init /mnt/etc/config.scm /mnt
;;
;; =============================================================================

(use-modules (gnu)
             (guix gexp))
(use-service-modules cups desktop networking ssh xorg base sysctl)

(operating-system
  (locale "en_US.utf8")
  (timezone "Asia/Bangkok")
  (keyboard-layout (keyboard-layout "us"))
  (host-name "guixlaptop")

  ;; ══════════════════════════════════════════════════════════════════════════
  ;; [HARDENING] Kernel Boot Parameters
  ;; ══════════════════════════════════════════════════════════════════════════
  (kernel-arguments
    (append (list
              ;; ── Memory Hardening ──
              "slab_nomerge"
              "init_on_alloc=1"
              "init_on_free=1"
              "page_alloc.shuffle=1"
              "randomize_kstack_offset=on"

              ;; ── Attack Surface Reduction ──
              "vsyscall=none"

              ;; ── Boot ──
              "loglevel=4")
            %default-kernel-arguments))

  ;; ══════════════════════════════════════════════════════════════════════════
  ;; System Packages
  ;; ══════════════════════════════════════════════════════════════════════════
  (packages (append (specifications->packages
                      '("nss-certs"
                        "nftables"))
                    %base-packages))

  ;; ══════════════════════════════════════════════════════════════════════════
  ;; User Accounts
  ;; ══════════════════════════════════════════════════════════════════════════
  (users (cons* (user-account
                  (name "guix")
                  (comment "Guix")
                  (group "users")
                  (home-directory "/home/guix")
                  (supplementary-groups '("wheel" "netdev" "audio" "video")))
                %base-user-accounts))

  ;; ══════════════════════════════════════════════════════════════════════════
  ;; Services
  ;; ══════════════════════════════════════════════════════════════════════════
  (services
    (append
      (list
        ;; ── Desktop Environment ──
        (service gnome-desktop-service-type)

        ;; ── Tor ──
        (service tor-service-type)

        ;; ── X.org ──
        (set-xorg-configuration
          (xorg-configuration (keyboard-layout keyboard-layout)))

        ;; ════════════════════════════════════════════════════════════════════
        ;; [HARDENING] nftables Firewall
        ;; ════════════════════════════════════════════════════════════════════
        (service nftables-service-type
          (nftables-configuration
            (ruleset (plain-file "nftables.conf"
"flush ruleset

table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;
    iif lo accept
    ct state established,related accept
    ct state invalid drop
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept
    ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
    ip protocol icmp icmp type echo-request limit rate 5/second accept
    ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
    udp dport 5353 accept
    counter drop
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
"))))

      ;; ════════════════════════════════════════════════════════════════════
      ;; [HARDENING] Modified Desktop Services
      ;; ════════════════════════════════════════════════════════════════════
      (modify-services %desktop-services

        (guix-service-type config =>
          (guix-configuration
            (inherit config)
            (substitute-urls
              '("https://ci.guix.gnu.org"
                "https://bordeaux.guix.gnu.org"))
            (extra-options '("--gc-keep-derivations=yes"
                            "--gc-keep-outputs=yes"))))

        (sysctl-service-type config =>
          (sysctl-configuration
            (settings
              '(;; Network: Anti-MITM & Anti-Spoofing
                ("net.ipv4.tcp_syncookies" . "1")
                ("net.ipv4.conf.all.rp_filter" . "1")
                ("net.ipv4.conf.default.rp_filter" . "1")
                ("net.ipv4.conf.all.accept_redirects" . "0")
                ("net.ipv4.conf.default.accept_redirects" . "0")
                ("net.ipv6.conf.all.accept_redirects" . "0")
                ("net.ipv6.conf.default.accept_redirects" . "0")
                ("net.ipv4.conf.all.send_redirects" . "0")
                ("net.ipv4.conf.default.send_redirects" . "0")
                ("net.ipv4.conf.all.secure_redirects" . "0")
                ("net.ipv4.conf.default.secure_redirects" . "0")
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

                ;; Kernel: Anti-Exploitation
                ("kernel.kptr_restrict" . "2")
                ("kernel.dmesg_restrict" . "1")
                ("kernel.perf_event_paranoid" . "3")
                ("kernel.yama.ptrace_scope" . "1")
                ("kernel.unprivileged_bpf_disabled" . "1")
                ("net.core.bpf_jit_harden" . "2")
                ("kernel.kexec_load_disabled" . "1")
                ("kernel.sysrq" . "0")
                ("kernel.randomize_va_space" . "2")

                ;; Filesystem Protection
                ("fs.protected_hardlinks" . "1")
                ("fs.protected_symlinks" . "1")
                ("fs.protected_fifos" . "2")
                ("fs.protected_regular" . "2")
                ("fs.suid_dumpable" . "0"))))))))

  ;; ══════════════════════════════════════════════════════════════════════════
  ;; Bootloader — Libreboot SeaGRUB
  ;; ══════════════════════════════════════════════════════════════════════════
  ;; SeaGRUB: SeaBIOS (in ROM) -> GRUB (MBR on disk) -> kernel
  ;; grub-bootloader ติดตั้ง GRUB ลง MBR ให้ SeaBIOS หาเจอ
  ;; __BOOT_DISK__ จะถูกแทนที่โดย install.sh
  (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets (list "__BOOT_DISK__"))
                (keyboard-layout keyboard-layout)))

  ;; ══════════════════════════════════════════════════════════════════════════
  ;; File Systems — Libreboot partition layout
  ;; ══════════════════════════════════════════════════════════════════════════
  ;; /boot = ext2 (ไม่มี journal — GRUB payload อ่านได้ 100%)
  ;; /     = ext4 (performance + journal สำหรับ root)
  ;;
  ;; __ROOT_UUID__ และ __BOOT_UUID__ จะถูกแทนที่โดย install.sh
  (file-systems (cons* (file-system
                         (mount-point "/")
                         (device (uuid "__ROOT_UUID__" 'ext4))
                         (type "ext4"))
                       (file-system
                         (mount-point "/boot")
                         (device (uuid "__BOOT_UUID__" 'ext2))
                         (type "ext2"))
                       %base-file-systems)))
