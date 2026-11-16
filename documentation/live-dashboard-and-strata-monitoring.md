# Live Dashboard & Strata Monitoring

The header and dedicated **`[STATS]`** / **`[STRATA]`** pages keep system and inference telemetry up to date without interrupting your input:

- **Live Dashboard (`[STATS]`):** Continuously refreshes every **1 second** across three stacked sections:
  - **System Information:** OS, kernel, Jetson board/L4T/SoC (when on Jetson), CPU model/threads, RAM capacity/speed/timings/health warnings, GPU model(s), total VRAM, and NVIDIA power limits.
  - **Live System Usage:** Color-coded bars for CPU usage + temperature, RAM usage, per-GPU utilization + temperature and VRAM (supports single/multi-GPU NVIDIA/AMD setups and Jetson Tegra X2 load/`GPU-therm`), and horizontal `Power:` (`GPU`, `CPU`, and `Sys` watts, including Jetson INA3221 `VDD_IN`/`VDD_GPU`/`VDD_CPU` rails).
    - *Tip:* On x86 systems without a PSU or battery hwmon sensor, run with `sudo` (`sudo ~/strata-performance-setup.sh`) so the script can read root-only `intel-rapl` energy counters for `CPU` and `Sys` power.
  - **Strata Live Telemetry:** Installed Strata version (or Docker container host-tuning mode), live running state & `strata.service` status, active serving preset and model, and live/session average `tok/s`.
- **Strata Options & Benchmark Summaries (`[STRATA]`):** Displays the **Latest**, **Previous**, and **Best** benchmark summaries (model, median & average decode/prefill `tok/s`, `%` diff vs. previous and vs. best, average power, and sanity/check counts) above the Strata lifecycle menu (`Install`, `Update`, `Remove`, `Service`, `Benchmark`, and `History`), with background polling for live `strata.service` and benchmark readiness.
- **Active Update Polling:** Checks for Strata updates in the background every **60 seconds**, displays an `[UPDATE AVAILABLE]` banner on every screen when a new version is found, and lets you press `u` to open the Update Strata page, stop Strata (`strata.service` or `strata launch --stop`), run `strata update --yes`, restart `strata.service` if it was active, and notify you once the model is `[LIVE]` again.
