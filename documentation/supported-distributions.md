# Supported Distributions

The wizard supports Linux distributions across systemd, Slackware SysVinit, and NAS/appliance families:

| Family | Supported Distributions | Package Manager |
| :--- | :--- | :--- |
| **Arch-based** | Arch Linux, CachyOS, EndeavourOS, Manjaro, Garuda (and `ID_LIKE=arch`) | `pacman` (plus `yay` or `paru` for AUR packages) |
| **Fedora-based** | Fedora, Nobara, RHEL, CentOS, Rocky Linux, AlmaLinux (and `ID_LIKE=fedora` / `rhel`) | `dnf` |
| **Debian-based** | Debian, Ubuntu (including **Jetson Linux R32 / L4T R32.x**), Pop!\_OS, Linux Mint, KDE neon (and `ID_LIKE=debian` / `ubuntu`) | `apt-get` |
| **openSUSE / SLES** | openSUSE Leap/Tumbleweed, SLES, SLED (and `ID_LIKE=suse`) | `zypper` |
| **Slackware** | Slackware 15.0 / -current (SysVinit `/etc/rc.d/rc.strata.*` + `/etc/rc.d/rc.local`) | `slackpkg` |
| **Unraid** | Unraid (Slackware-based SysVinit; persists boot hooks via `/boot/config/strata/` + `/boot/config/go` invoked with `sh` so `vfat` mounts without execute bits survive reboots, host-tuning mode when Strata runs in Docker) | `slackpkg` / host-only |
| **TrueNAS SCALE** | TrueNAS SCALE (Debian-based appliance with `systemd`; host-tuning mode for containerized Strata, skips restricted `apt-get` installs) | host-only (appliance) |
| **Synology DSM** | Synology DSM 7 (`systemd`) & DSM 6 (`/usr/local/etc/rc.d/strata-*.sh`); host-tuning mode for containerized Strata | host-only (appliance) |

> **Bootloaders:** Kernel command-line parameters (used for `amd_apu_memory` `ttm.pages_limit`, `amd_cwsr_disable` `amdgpu.cwsr_enable=0`, IOMMU passthrough, 1 GiB hugepages, `gpu-unlock`, or when BIOS locks runtime PCIe ASPM writes) are automatically configured for **Limine** (`/etc/default/limine`), **GRUB** (`/etc/default/grub` via `grub-mkconfig` or `grub2-mkconfig`), **systemd-boot** (`/etc/kernel/cmdline`), **ELILO** (`/boot/efi/EFI/Slackware/elilo.conf` or `/etc/elilo.conf`), or **LILO** (`/etc/lilo.conf`).
