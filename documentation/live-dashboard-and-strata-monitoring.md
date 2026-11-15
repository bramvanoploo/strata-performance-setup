# Live Dashboard & Strata Monitoring

The header continuously refreshes every **1 second** across **all pages** (index, step views, and benchmark history) without interrupting your input:

- **Live System Usage (left):** Color-coded bars for CPU usage + temperature, RAM usage, per-GPU utilization + temperature and VRAM (supports single/multi-GPU NVIDIA/AMD setups and Jetson Tegra X2 load/`GPU-therm`), and horizontal `Power:` (`GPU`, `CPU`, and `Sys` watts, including Jetson INA3221 `VDD_IN`/`VDD_GPU`/`VDD_CPU` rails).
  - *Tip:* On x86 systems without a PSU or battery hwmon sensor, run with `sudo` (`sudo ~/strata-performance-setup.sh`) so the script can read root-only `intel-rapl` energy counters for `CPU` and `Sys` power.
- **System Information (right):** OS, kernel, Jetson board/L4T/SoC (when on Jetson), CPU model/threads, RAM capacity/speed/timings, GPU model(s), total VRAM, and NVIDIA power limits.
- **Strata & Latest Benchmark Block:** Installed Strata version, live running state & `strata.service` status (polled every 1s), active serving preset and model, live/session average `tok/s`, and the **Latest Benchmark** summary (model, median & average decode/prefill `tok/s`, average power, and check/sanity counts).
- **Active Update Polling:** Checks for Strata updates in the background every **60 seconds**, displays an `[UPDATE AVAILABLE]` banner on every screen when a new version is found, and lets you press `u` to open the Update Strata page, stop Strata (`strata.service` or `strata launch --stop`), run `strata update --yes`, restart `strata.service` if it was active, and notify you once the model is `[LIVE]` again.
