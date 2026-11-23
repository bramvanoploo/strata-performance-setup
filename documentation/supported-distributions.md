# Supported Platforms & Distributions

The wizard supports Linux distributions across systemd, Slackware SysVinit, and NAS/appliance families, as well as **macOS** on Apple Silicon (`launchd`):

| Family | Supported Distributions / OS | Package Manager |
| :--- | :--- | :--- |
| **Arch-based** | Arch Linux, CachyOS, EndeavourOS, Manjaro, Garuda (and `ID_LIKE=arch`) | `pacman` (plus `yay` or `paru` for AUR packages) |
| **Fedora-based** | Fedora, Nobara, RHEL, CentOS, Rocky Linux, AlmaLinux (and `ID_LIKE=fedora` / `rhel`) | `dnf` |
| **Debian-based** | Debian, Ubuntu (including **NVIDIA Jetson Linux L4T R32 / R35 / R36+**), Pop!\_OS, Linux Mint, KDE neon (and `ID_LIKE=debian` / `ubuntu`) | `apt-get` |
| **openSUSE / SLES** | openSUSE Leap/Tumbleweed, SLES, SLED (and `ID_LIKE=suse`) | `zypper` |
| **Slackware** | Slackware 15.0 / -current (SysVinit `/etc/rc.d/rc.strata.*` + `/etc/rc.d/rc.local`) | `slackpkg` |
| **Unraid** | Unraid (Slackware-based SysVinit; persists boot hooks via `/boot/config/strata/` + `/boot/config/go` invoked with `sh` so `vfat` mounts without execute bits survive reboots, host-tuning mode when Strata runs in Docker) | `slackpkg` / host-only |
| **TrueNAS SCALE** | TrueNAS SCALE (Debian-based appliance with `systemd`; host-tuning mode for containerized Strata, skips restricted `apt-get` installs) | host-only (appliance) |
| **Synology DSM** | Synology DSM 7 (`systemd`) & DSM 6 (`/usr/local/etc/rc.d/strata-*.sh`); host-tuning mode for containerized Strata | host-only (appliance) |
| **WSL2 (Windows)** | Ubuntu, Debian, Fedora, Arch, openSUSE under Windows Subsystem for Linux 2 (`wsl2_windows_config` for `.wslconfig` RAM cap & idle timeout, `wsl2_linux_tuning` for `/etc/wsl.conf` `systemd`/metadata & native `ext4` model storage; bare-metal-only steps are automatically hidden) | Distro native (`apt-get` / `dnf` / `pacman` / `zypper`) |
| **macOS** | macOS 15+ on **Apple Silicon** (`arm64` / M1–M5+, `launchd` user LaunchAgents & system LaunchDaemons; requires Bash 4.3+ via `brew install bash`, automatically re-execed when invoked with `/bin/bash`) | `brew` (Homebrew) |

> **Apple Hardware Notes:**
> - **Intel Macs on macOS (`x86_64`)** are flagged as unsupported by upstream Strata (`strata` for macOS requires Apple Silicon M1 or newer and macOS 15+ Metal residency sets).
> - **Apple Silicon on Linux (Asahi Linux)** is detected with a note explaining that upstream Strata's Metal engine currently requires macOS 15+ (Linux ARM64 prebuilt engines target DGX Spark CUDA).
> - **Intel Macs running Linux** (`x86_64`) are supported via `apple_smc_cooling` (`mbpfan` / `applesmc`) alongside standard Linux GPU and system steps.

> **Bootloaders (Linux):** Kernel command-line parameters (used for `amd_apu_memory` `ttm.pages_limit`, `amd_cwsr_disable` `amdgpu.cwsr_enable=0`, IOMMU passthrough, 1 GiB hugepages, `gpu-unlock`, or when BIOS locks runtime PCIe ASPM writes) are automatically configured for **Limine** (`/etc/default/limine`), **GRUB** (`/etc/default/grub` via `grub-mkconfig` or `grub2-mkconfig`), **systemd-boot** (`/etc/kernel/cmdline`), **ELILO** (`/boot/efi/EFI/Slackware/elilo.conf` or `/etc/elilo.conf`), or **LILO** (`/etc/lilo.conf`).
