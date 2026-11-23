# Supported Hardware

The script probes your system at startup and enables hardware-specific steps only when matching hardware is detected:

## GPUs
- **NVIDIA** *(any NVIDIA GPU supported by `nvidia-smi` — GeForce GTX/RTX including 50-series, Quadro/RTX Workstation, Tesla/Datacenter K80–B200/RTX PRO 6000 Server/CMP HX, and DGX Spark `GB10`)*:
  - **All supported NVIDIA GPUs** *(applied per-GPU for mixed or multi-GPU rigs)*:
    - `nvidia-persistenced` persistence mode (uses `nvidia-persistenced.service` when packaged, or falls back to a systemd/SysVinit service via `nvidia-persistenced` / `nvidia-smi -pm 1` on headless/container hosts)
    - Per-GPU persistent maximum GPU power limit (`nvidia-smi -i <id> -pl`, when the card allows raising above default or current BMC-capped power)
    - Per-GPU clock lock (`-lgc`/`-lmc`, with valid `mem,gr` pair lookup and `-ac` + `--auto-boost-default=0` fallback for older Kepler/Maxwell/Pascal Tesla GPUs)
    - Per-GPU compute mode reset to `Default` (`nvidia-smi -i <id> -c 0`, when in `Exclusive_Process` or `Prohibited` mode)
  - **Tesla / Datacenter, Multi-GPU & Platform-Specific** *(auto-detected when applicable)*:
    - **NVSwitch Fabric Manager (`nvidia_fabricmanager`):** Detects NVSwitch hardware (`/dev/nvidia-nvswitch*` / PCI IDs) on HGX/DGX SXM nodes and installs/enables `nvidia-fabricmanager.service`
    - **MIG Disable (`nvidia_mig_disable`):** Detects active or pending Multi-Instance GPU (MIG) partitions on A100/A30/H100/H200/B200 GPUs and disables MIG (`nvidia-smi -mig 0`) for full VRAM & tensor parallelism
    - **Volta (`sm_70` / Tesla V100) Strata Decode Table (`nvidia_sm70_table`):** Automatically exports `STRATA_SM70_TABLE=1` for Strata CLI runs, `/etc/profile.d/strata-sm70.sh`, and `strata.service`, and notes CUDA 12 / R580 driver branch requirements for Pascal/Volta (`sm_60`/`sm_61`/`sm_70`)
    - **Tesla Idle P-State Daemon (`nvidia_pstate`, `[EXP]`):** Installs `sasha0552/nvidia-pstated` (or isolated Python `nvidia-pstate` polling daemon if NVML headers are absent) to drop legacy Tesla/CMP GPUs (P40, P100, P4, M40, M60, V100) from stuck P0 (~30–50 W) into P8 (~9–10 W) idle, scopes automatically to legacy P-state GPUs even in mixed rigs, and restores normal P-state governance on stop or revert
    - **Passive/Datacenter Thermal Power Cap (`nvidia_power_cap`, `[OPT]`):** Sets a custom TDP cap (e.g., ~70% TDP / 175 W on a 250 W passive card) to prevent passive thermal throttling while preserving memory-bandwidth-bound decode speed; preserved when running `[a]` unless you choose to revert out-of-scope options
    - **Multi-GPU PCIe ACS Disable (`pcie_acs_disable`, `[EXP]`):** Detects enabled PCIe Access Control Services (`ACSCtl`) on multi-GPU rigs lacking NVLink/XGMI and installs a `setpci` boot service targeting PCIe bridges (`0604`, `ECAP_ACS+0x6.w=0000`) for direct GPU-to-GPU P2P on bare-metal single-tenant hosts
    - **Open-Source GPU P2P (`nvidia_p2p_open`, `[EXP]`):** Configures NVIDIA open-source GPU kernel modules / DMA-BUF P2P support for multi-GPU rigs
    - **DGX Spark (`GB10`):** Recognizes unified 128 GiB LPDDR5X memory when `nvidia-smi` reports `memory.total` as `[N/A]`, prevents false `<= 5 GiB VRAM` warnings, and hides LACT
    - Per-GPU ECC memory toggle (`nvidia-smi -i <id> -e 0` on ECC-capable workstation/Tesla/datacenter GPUs)
    - `nvidia-powerd` Dynamic Boost (supported mobile RTX laptops)
    - LACT (`lactd`) core & VRAM clock offsets (consumer/workstation NVIDIA, non-Instinct AMD, and Intel Arc GPUs; hidden on datacenter/Instinct/DGX-Spark-only rigs)
    - `gpu-unlock` (`gpu-unlock-dkms` + `gpu_unlock.targets=all`, when Secure Boot is disabled; Arch-based distros via `pacman`/AUR, and experimental DKMS source-build support on Debian/Ubuntu, Fedora, and openSUSE; strictly scoped to consumer Turing/Ampere/Ada GeForce GTX 16 and RTX 20/30/40 GPUs, since datacenter/workstation cards are factory-unlocked)
- **AMD Radeon & Instinct**:
  - Automatic AMD `gfx` architecture detection across both `0x03*` display and `0x12*` processing-accelerator PCI classes (via KFD topology `/sys/class/kfd/kfd/topology/nodes`, `rocminfo`, DRM/PCI IDs, and device names), distinguishing compute APUs from desktop 2-CU display iGPUs (`gfx1036`) alongside discrete GPUs and Instinct CDNA accelerators (`MI50`/`MI60` `gfx906`, `MI100` `gfx908`, `MI210`/`MI250X` `gfx90a`, `MI300X`/`MI300A`/`MI325X` `gfx942`, `MI350X`/`MI355X` `gfx950`), with XGMI/Infinity Fabric topology checks and deduplicated shared GTT pool reporting
  - `amdgpu` high-performance DPM level (`power_dpm_force_performance_level=high`, with `amd-smi` / `rocm-smi` fallback on Instinct GPUs) for ROCm/HIP
  - **AMD GPU COMPUTE Power Profile (`amd_compute_profile`, `[OPT]`):** Switches `pp_power_profile_mode` to `COMPUTE` for sustained inference workloads
  - **AMD RADV Vulkan & Runtime PM (`amd_vulkan_radv`, `amd_runpm_disable` `[!]`):** Configures Vulkan RADV / `radv` ICD and optional `amdgpu.runpm=0` runtime power management disable
  - **AMD Instinct Compute/Memory Partition Mode (`amd_instinct_partition`, `[OPT]`):** Switches CDNA 2/3/4 Instinct GPUs (`MI250X`/`MI300X`/`MI325X`) between `SPX`+`NPS1` (unified GPU for massive single models) and `CPX`+`NPS4` (split XCDs for concurrent smaller models)
  - LACT (`lactd`) core & VRAM clock offsets (non-Instinct AMD GPUs)
  - **Unified-Memory APUs (`amd_apu_memory`):** Raises GTT memory limit (`ttm.pages_limit` and `ttm.page_pool_size`) for Strix Point (`gfx1150`), Strix Halo (`gfx1151`), Krackan (`gfx1152`), Phoenix / Hawk Point (`gfx1103`), and other AMD APUs
  - **Radeon 780M / 760M MES Reset Workaround (`amd_cwsr_disable`):** Adds `amdgpu.cwsr_enable=0` on `gfx1103` Linux systems to stop MES `REMOVE_QUEUE` GPU resets (Strata #6132) without increasing idle power draw
  - **Local Strata HIP Engine Build (`[STRATA]` → `Build Local Strata HIP Engine`):** Automatically compiles, packages, verifies, and registers a self-contained Strata HIP engine from `Niko1221/Strata` source across non-prebuilt AMD `gfx` architecture-family ranges — RDNA 1 (`gfx101x`), RDNA 2 (`gfx103x`, excluding the 2-CU desktop display iGPU `gfx1036`), RDNA 3 (`gfx110x`), RDNA 3.5 (`gfx115x`), RDNA 4 (`gfx120x`), Vega 20 (`gfx906` via `-DSTRATA_HIP_GFX906=ON`), and Instinct CDNA (`gfx908`, `gfx90a`, `gfx942`, `gfx950` via `-DSTRATA_ENABLE_HIP=ON`), acquiring AMD's TheRock ROCm SDK (including `gfx94X-dcgpu` / `gfx950-dcgpu` or using compatible `/opt/rocm`), patching `engine/cmake/hip_backend.cmake` if needed (as in Strata #1217), bundling runtime libraries and matching `hipBLASLt` tuning tables, and automatically exporting `STRATA_EXPERIMENTAL_GFX1150=1` / `STRATA_EXPERIMENTAL_GFX1103=1` for wizard CLI calls, `strata.service`, and non-systemd RC scripts
- **Intel Arc Alchemist / Battlemage / Data Center Flex & Max / Integrated GPUs**:
  - Detects Alchemist (`A`-series / Flex), Battlemage (`B580`, `B570`, `Arc Pro B50`, `Arc Pro B60`), Data Center GPU Max, and integrated Intel GPUs (while ignoring non-GPU `0x1200` Intel NPU/QAT accelerators), tallies discrete Arc VRAM, and includes multi-Arc setups in `iommu_pt` and NUMA topology checks
  - Intel GPU Compute Runtime (`intel_compute_stack` — OpenCL / Level Zero packages across Arch, Fedora, Debian/Ubuntu, and openSUSE)
  - Minimum GPU frequency locked to RP0/max (supports both `xe` and `i915` kernel drivers) for SYCL
  - Intel hybrid P-core pinning (`intel_pcore_pinning`) for inference processes
  - LACT (`lactd`) core & VRAM clock offsets on discrete Intel Arc GPUs
- **NVIDIA Jetson (L4T R32 / R35 / R36+)**:
  - **Jetson TX2 (`tegra186`), Xavier (`tegra194`), Orin (`tegra234`), and AGX Thor (`tegra264`)** auto-detection via device tree & `/etc/nv_tegra_release`
  - `nvpmodel -m <MAXN>` and `jetson_clocks` persisted via systemd
  - PWM Fan maximum cooling (`target_pwm=255`, supporting `pwm-fan` and `tegra_pwmfan` hwmon) via `strata-jetson-fan.service`
  - CUDA device access (`video` / `render` groups)
  - Kernel 4.9 / Ubuntu 18.04 compatibility (THP `madvise` fallback and `zram-tools` / `zram-config` / `strata-zram.service` with `zstd` → `lz4` → `lzo`)
- **Apple Silicon (macOS 15+, Metal — M1 / M2 / M3 / M4 / M5+ Pro/Max/Ultra)**:
  - Auto-detects SoC (`machdep.cpu.brand_string`), P/E thread layout, unified memory (`hw.memsize`), GPU core count and Metal version (`system_profiler SPDisplaysDataType`), laptop vs. desktop chassis (`MacBook*` / `InternalBattery`), and `iogpu.wired_limit_mb`
  - **Metal GPU Wired Memory Limit (`macos_wired_limit`, `[OPT]`):** Raises `sysctl iogpu.wired_limit_mb` above macOS's ~75% residency cap (with safe OS headroom guardrails) and persists it across reboots via a `launchd` LaunchDaemon (`com.strata.macos-wired-limit`) so larger packs fit resident without SSD streaming
  - **Power Mode (`macos_power_mode`):** Enables High Power Mode (`pmset powermode 2`, where supported on Max/Ultra chassis) and disables Low Power Mode (scoped to `-c` AC power on MacBooks, excluded from `[L]`)
  - **Spotlight SSD I/O Exclusion (`macos_spotlight_exclude`):** Places reversible `.metadata_never_index` markers in Strata data, cache, and model directories (`~/.local/share/strata`, `~/.cache/strata`, `~/.strata`, `~/Documents/Strata`, and optional custom folders) to stop `mds_stores` indexing latency during SSD expert streaming
  - **Time Machine Exclusion (`macos_timemachine_exclude`):** Excludes model and cache directories from Time Machine snapshots (`tmutil addexclusion`) to prevent background backup I/O contention
  - **Strata Metal Engine Switches (`macos_metal_tuning`, `[OPT]`):** Configures documented Strata Metal switches (`STRATA_METAL_F16=1`, `STRATA_MACOS_SENSORS=1`, `STRATA_METAL_PROMPT_CHUNK`, `STRATA_METAL_ARENA_GB`, `STRATA_METAL_WIRE_ARENA=0`) in `~/.config/strata/macos-metal-env.conf`, automatically exported to wizard runs, benchmarks, `com.strata.server` (`launchd`), and optional `~/.zprofile` integration
  - **Thunderbolt 5 RDMA (`macos_rdma_tb5`, `[OPT]`):** Configures macOS Thunderbolt 5 RDMA / cluster networking for multi-Mac distributed inference
  - **Server Uptime (`prevent_sleep`):** Configures `pmset` (`sleep 0`, `standby 0`, `autopoweroff 0`, `powernap 0`, plus optional `disablesleep 1` for clamshell MacBook servers) with clean snapshot/restore on revert

## Non-GPU AI Accelerators & Edge NPUs
- **Tenstorrent NPU (`tenstorrent_setup`):** Configures hugepages, KMD, and `/dev/tenstorrent` device permissions for `tt-metal` and vLLM
- **AMD Ryzen AI XDNA NPU (`amd_xdna_npu`):** Loads `amdxdna` driver and configures `/dev/accel` permissions for Lemonade
- **Intel Core Ultra NPU (`intel_npu_stack`):** Loads `intel_vpu` driver and configures `/dev/accel` permissions for OpenVINO
- **Rockchip RK3588 NPU (`rockchip_rk3588_npu`):** Sets NPU/DMC/CPU performance governors and `/dev/rknpu` device access
- **Hailo-10H / Hailo-8 NPU (`hailo_npu_setup`):** Configures Hailo runtime and `/dev/hailo` device permissions
- **Huawei Ascend NPU (`huawei_ascend_cann`):** Configures CANN environment profile and `/dev/davinci` device access
- **Moore Threads MUSA (`moore_threads_musa`):** Configures MUSA toolkit environment profile and `/dev/musa` device access

## Laptops & OEM Thermal / EC Controls
- **Generic ACPI Platform Profile** (`performance` mode via `/sys/firmware/acpi/platform_profile` — ThinkPad, IdeaPad, Legion, ASUS, HP, Dell, Acer, AMD PMF)
- **Apple Mac (Linux / Intel Macs)** (`apple_smc_cooling` — detects Apple hardware via DMI / `applesmc` and configures either an aggressive `mbpfan` thermal curve or a persistent `applesmc` sysfs manual fan speed floor, restoring automatic SMC control on revert; excluded from `[L]`)
- **MSI** laptops (`msi-ec` + `ec_sys` turbo shift mode, advanced fan curve, optional Cooler Boost)
- **ASUS** ROG / TUF laptops (`asusctl` / `asusd` Performance profile)
- **Dell** systems (`smbios-thermal-ctl` BIOS ultra-performance mode)
- **Lenovo Legion** laptops (`LenovoLegionLinux` / `legiond`)
- **System76** (`system76-power` Performance profile)
- **TUXEDO** laptops (`tccd` / TUXEDO Control Center)

## System-Wide Optimizations (All Hardware)
- **Server Uptime & Headless Boot:** Masks `sleep`, `suspend`, `hibernate`, and `hybrid-sleep` targets, ignores laptop lid-close suspend, and optionally switches `systemd` to `multi-user.target` (`headless_target`)
- **Memory & Realtime:** Grants unlimited `memlock`, `nice -11`, and `rtprio 98` so model weights and KV caches stay pinned in RAM (Dockerized Strata is detected by container image name and checked via `docker inspect` `HostConfig.Ulimits` for `memlock=-1:-1`, since containers do not inherit host `/etc/security/limits.d/`)
- **CPU, NUMA & PCIe:** Multi-socket / multi-NUMA automatic NUMA balancing disable (`kernel.numa_balancing=0`, page-migration jitter hygiene) and `numactl --interleave=all` wrapper for native `strata.service` installs, plus optional CPU `performance` governor / `power-profiles-daemon` and PCIe ASPM `performance` policy
- **Kernel & Swap:** `sysctl` VM tuning (`vfs_cache_pressure=50`, `dirty_ratio=10`, `zone_reclaim_mode=0`), opt-in kernel/VM trade-offs (`mitigations=off`, `init_on_alloc=0`, `split_lock_detect=off`, `vm.overcommit_memory=1`), `ananicy-cpp` / `bpftune` on Arch/CachyOS, `sched_ext` BPF CPU scheduler (`scx_loader` / `scx` with `bpfland`), `zstd`-compressed `zram` swap, and `irqbalance`
- **Strata Management & Benchmarking:** Installs or updates [Strata](https://github.com/Niko1221/Strata), builds and registers local AMD HIP engine components when an AMD GPU/APU lacks a prebuilt Linux engine, runs `strata launch`, manages `strata.service` (`systemd` / SysVinit) or `com.strata.server` (`launchd` user LaunchAgent with `AbandonProcessGroup=true`) from a saved preset, runs Strata benchmarks with coupled host-option/power tracking, and lets you inspect and restore past benchmark configurations. *(Tip: on VRAM-constrained GPUs, check Strata's serving/prefill chunk configuration—e.g. `auto` vs. a lower pinned value—before chasing marginal OS tweaks, and run a warmup pass after cold model load before A/B comparing host steps, as decode throughput can ramp over the first several requests.)*

> **Recommended Specs:** On Linux, the wizard warns if your system does not have more than **31 GiB RAM** or more than **5 GiB NVIDIA VRAM** (or has no dedicated NVIDIA/AMD/Intel Arc GPU); on macOS Apple Silicon, it requires **16 GiB+ unified memory** (and notes SSD expert streaming on **16–48 GiB** Macs). You can still inspect and apply any applicable host optimizations regardless of warnings.
