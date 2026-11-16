# Supported Hardware

The script probes your system at startup and enables hardware-specific steps only when matching hardware is detected:

## GPUs
- **NVIDIA** *(any NVIDIA GPU supported by `nvidia-smi` — GeForce GTX/RTX including 50-series, Quadro/RTX Workstation, and Tesla/Datacenter GPUs)*:
  - **All supported NVIDIA GPUs** *(applied per-GPU for mixed or multi-GPU rigs)*:
    - `nvidia-persistenced` persistence mode (eliminates cold-start driver init delays on headless systemd hosts; no-op when the driver already stays resident, e.g. on container hosts)
    - Per-GPU persistent maximum GPU power limit (`nvidia-smi -i <id> -pl`, when the card allows raising above default; prevents artificial throttling if a GPU hits its default cap, with no effect if your workload draws below the default limit)
    - Per-GPU clock lock (`-lgc`/`-lmc`, with `-ac` application clocks fallback for older Kepler/Maxwell Tesla GPUs)
    - Per-GPU compute mode reset to `Default` (`nvidia-smi -i <id> -c 0`, when in `Exclusive_Process` or `Prohibited` mode)
  - **Card- / platform-specific** *(auto-detected when applicable)*:
    - Per-GPU ECC memory toggle (`nvidia-smi -i <id> -e 0` on ECC-capable workstation/Tesla/datacenter GPUs)
    - `nvidia-powerd` Dynamic Boost (supported mobile RTX laptops)
    - LACT (`lactd`) core & VRAM clock offsets (consumer/workstation GPUs; hidden on Tesla-only rigs)
    - `gpu-unlock` (`gpu-unlock-dkms` + `gpu_unlock.targets=all`, when Secure Boot is disabled; Arch-based distros via `pacman`/AUR, and experimental DKMS source-build support on Debian/Ubuntu, Fedora, and openSUSE; supported Turing/Ampere/Ada GPUs such as GTX 16, RTX 20/30/40, A10/A40/A100/L40, and RTX A-series)
- **AMD Radeon**:
  - `amdgpu` high-performance DPM level (`power_dpm_force_performance_level=high`) for ROCm/HIP
  - LACT (`lactd`) core & VRAM clock offsets
- **Intel Arc / Integrated GPUs**:
  - Minimum GPU frequency locked to RP0/max (supports both `xe` and `i915` kernel drivers) for SYCL
- **NVIDIA Jetson (Jetson Linux R32 / L4T R32.x)**:
  - **Jetson TX2 Series** (`TX2`, `TX2 4GB`, `TX2i`, `TX2 NX` / `tegra186`) auto-detection via device tree & `/etc/nv_tegra_release`
  - `nvpmodel -m 0` (`MAXN` mode enabling all Denver 2 + Cortex-A57 cores) and `jetson_clocks` persisted via systemd
  - PWM Fan maximum cooling (`target_pwm=255` via `strata-jetson-fan.service`)
  - CUDA device access (`video` group for `/dev/nvhost-gpu`)
  - Kernel 4.9 / Ubuntu 18.04 compatibility (THP `madvise` fallback and `zram-tools` / `zram-config` / `strata-zram.service` with `zstd` → `lz4` → `lzo`)

## Laptops & OEM Thermal / EC Controls
- **Generic ACPI Platform Profile** (`performance` mode via `/sys/firmware/acpi/platform_profile` — ThinkPad, IdeaPad, Legion, ASUS, HP, Dell, Acer, AMD PMF)
- **MSI** laptops (`msi-ec` + `ec_sys` turbo shift mode, advanced fan curve, optional Cooler Boost)
- **ASUS** ROG / TUF laptops (`asusctl` / `asusd` Performance profile)
- **Dell** systems (`smbios-thermal-ctl` BIOS ultra-performance mode)
- **Lenovo Legion** laptops (`LenovoLegionLinux` / `legiond`)
- **System76** (`system76-power` Performance profile)
- **TUXEDO** laptops (`tccd` / TUXEDO Control Center)

## System-Wide Optimizations (All Hardware)
- **Server Uptime:** Masks `sleep`, `suspend`, `hibernate`, and `hybrid-sleep` targets, and ignores laptop lid-close suspend
- **Memory & Realtime:** Grants unlimited `memlock`, `nice -11`, and `rtprio 98` so model weights and KV caches stay pinned in RAM (Dockerized Strata is detected by container image name and checked via `docker inspect` `HostConfig.Ulimits` for `memlock=-1:-1`, since containers do not inherit host `/etc/security/limits.d/`)
- **CPU & PCIe:** Optional CPU `performance` governor / `power-profiles-daemon` and PCIe ASPM `performance` policy
- **Kernel & Swap:** `sysctl` VM tuning (`vfs_cache_pressure=50`, `dirty_ratio=10`, `zone_reclaim_mode=0`), `ananicy-cpp` / `bpftune` on Arch/CachyOS, `sched_ext` BPF CPU scheduler (`scx_loader` / `scx` with `bpfland`), `zstd`-compressed `zram` swap, and `irqbalance`
- **Strata Management & Benchmarking:** Installs or updates [Strata](https://github.com/Niko1221/Strata), runs `strata launch`, manages `strata.service` from a saved preset, runs Strata benchmarks with coupled host-option/power tracking, and lets you inspect and restore past benchmark configurations. *(Tip: on VRAM-constrained GPUs, check Strata's serving/prefill chunk configuration—e.g. `auto` vs. a lower pinned value—before chasing marginal OS tweaks.)*

> **Recommended Specs:** The wizard will warn if your system has under **32 GiB RAM** or under **6 GiB NVIDIA VRAM** (or no dedicated NVIDIA/AMD/Intel Arc GPU), as larger models may not fit in memory, though you can still apply any applicable host optimizations.
