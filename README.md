<p align="center">
  <img src="assets/logo.png" alt="Strata Performance Setup" width="760">
</p>

# Strata Performance Setup

An interactive TUI wizard (`strata-performance-setup.sh`) to inspect, apply, and revert host-level Linux performance optimizations for running **Strata** LLM inference—and to install, update, launch, and manage `strata.service`.

The script automatically detects your distribution, CPU, RAM, GPU(s), laptop/chassis vendor, and bootloader, then presents only the optimizations applicable to your machine. Every optimization can be applied or reverted cleanly from the wizard.

<p align="center">
  <img src="assets/tui-screenshot.png" alt="Strata Performance Setup TUI" width="880">
</p>

---

## Quick Start (Recommended)

### Run directly on your machine

```bash
curl -fsSL https://raw.githubusercontent.com/bramvanoploo/strata-performance-setup/main/strata-performance-setup.sh -o ~/strata-performance-setup.sh && chmod +x ~/strata-performance-setup.sh && ~/strata-performance-setup.sh
```

> **Why download instead of `curl ... | bash`?**  
> `strata-performance-setup.sh` is an interactive TUI that reads your menu selections from standard input. Saving it first keeps your terminal attached for interactive prompts and `sudo` authentication.

### Run on a remote machine via SSH

Replace `192.168.1.100` with your target machine's IP address (or `user@<ip>` if the remote username differs):

```bash
ssh -t 192.168.1.100 'curl -fsSL https://raw.githubusercontent.com/bramvanoploo/strata-performance-setup/main/strata-performance-setup.sh -o ~/strata-performance-setup.sh && chmod +x ~/strata-performance-setup.sh && ~/strata-performance-setup.sh'
```

### Clone the repository and run

```bash
git clone https://github.com/bramvanoploo/strata-performance-setup.git
cd strata-performance-setup
chmod +x strata-performance-setup.sh
./strata-performance-setup.sh
```

---

## Supported Distributions

The wizard supports systemd-based Linux distributions across three package families:

| Family | Supported Distributions | Package Manager |
| :--- | :--- | :--- |
| **Arch-based** | Arch Linux, CachyOS, EndeavourOS, Manjaro, Garuda (and `ID_LIKE=arch`) | `pacman` (plus `yay` or `paru` for AUR packages) |
| **Fedora-based** | Fedora, Nobara, RHEL, CentOS, Rocky Linux, AlmaLinux (and `ID_LIKE=fedora` / `rhel`) | `dnf` |
| **Debian-based** | Debian, Ubuntu, Pop!\_OS, Linux Mint, KDE neon (and `ID_LIKE=debian` / `ubuntu`) | `apt-get` |

> **Bootloaders:** Kernel command-line parameters (used when BIOS locks runtime PCIe ASPM writes or for `gpu-unlock`) are automatically configured for **Limine** (`/etc/default/limine`), **GRUB** (`/etc/default/grub`), or **systemd-boot** (`/etc/kernel/cmdline`).

---

## Supported Hardware

The script probes your system at startup and enables hardware-specific steps only when matching hardware is detected:

### GPUs
- **NVIDIA** (GTX 16 / RTX 20 / RTX 30 / RTX 40 / A-series & L-series):
  - `nvidia-persistenced` persistence mode (eliminates cold-start delays on headless hosts)
  - `nvidia-powerd` Dynamic Boost (mobile RTX GPUs)
  - Persistent maximum GPU power limit (`nvidia-smi -pl` via systemd)
  - LACT (`lactd`) core & VRAM clock offsets
  - `gpu-unlock-dkms` + `gpu_unlock.targets=all` *(Arch-based distros, supported Turing/Ampere/Ada GPUs)*
- **AMD Radeon**:
  - `amdgpu` high-performance DPM level (`power_dpm_force_performance_level=high`) for ROCm/HIP
  - LACT (`lactd`) core & VRAM clock offsets
- **Intel Arc / Integrated GPUs**:
  - Minimum GPU frequency locked to RP0/max (supports both `xe` and `i915` kernel drivers) for SYCL

### Laptops & OEM Thermal / EC Controls
- **Generic ACPI Platform Profile** (`performance` mode via `/sys/firmware/acpi/platform_profile` — ThinkPad, IdeaPad, Legion, ASUS, HP, Dell, Acer, AMD PMF)
- **MSI** laptops (`msi-ec` + `ec_sys` turbo shift mode, advanced fan curve, optional Cooler Boost)
- **ASUS** ROG / TUF laptops (`asusctl` / `asusd` Performance profile)
- **Dell** systems (`smbios-thermal-ctl` BIOS ultra-performance mode)
- **Lenovo Legion** laptops (`LenovoLegionLinux` / `legiond`)
- **System76** (`system76-power` Performance profile)
- **TUXEDO** laptops (`tccd` / TUXEDO Control Center)

### System-Wide Optimizations (All Hardware)
- **Server Uptime:** Masks `sleep`, `suspend`, `hibernate`, and `hybrid-sleep` targets, and ignores laptop lid-close suspend
- **Memory & Realtime:** Grants unlimited `memlock`, `nice -11`, and `rtprio 98` so model weights and KV caches stay pinned in RAM
- **CPU & PCIe:** Optional CPU `performance` governor / `power-profiles-daemon` and PCIe ASPM `performance` policy
- **Kernel & Swap:** `sysctl` VM tuning (`vfs_cache_pressure=50`, `dirty_ratio=10`, `zone_reclaim_mode=0`), `ananicy-cpp` / `bpftune` on Arch/CachyOS, `zstd`-compressed `zram` swap, and `irqbalance`
- **Strata Management:** Installs or updates [Strata](https://github.com/Niko1221/Strata), runs `strata launch`, and sets up `strata.service` from a saved preset

> **Recommended Specs:** The wizard will warn if your system has under **32 GiB RAM** or under **6 GiB NVIDIA VRAM** (or no dedicated NVIDIA/AMD/Intel Arc GPU), as larger models may not fit in memory, though you can still apply any applicable host optimizations.

---

## Using the Wizard

Once launched, the main index lists every optimization applicable to your machine along with its live `[APPLIED]` / `[NOT APPLIED]` status:

- Press `w` (or `Enter`) to walk through the **guided wizard** step by step
- Press `a` to **apply all recommended optimizations** for your hardware in one action (with confirmation; excludes Strata setup and minimal-gain/higher-idle-power options like CPU Performance and PCIe ASPM)
- Press `x` to **revert all recommended optimizations** in one action (with confirmation)
- Enter a **step number** to jump directly to a specific optimization
- Inside any step, press `a` to **apply/update**, `r` to **revert**, `n` / `b` to move next/back, or `i` to return to the index

---

## License

See [LICENSE](LICENSE).
