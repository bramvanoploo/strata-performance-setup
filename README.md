<p align="center">
  <img src="assets/logo.png" alt="Strata Performance Setup" width="760">
</p>

An interactive TUI wizard (`strata-performance-setup.sh`) to inspect, apply, and revert host-level Linux performance optimizations for running **Strata** LLM inference—and to install, update, launch, and manage `strata.service` (or run in host-tuning mode when Strata is deployed in Docker on hosts like Unraid, TrueNAS SCALE, or Synology DSM).

The script automatically detects your distribution, CPU, RAM, GPU(s), laptop/chassis vendor, and bootloader, then presents only the optimizations applicable to your machine. Every optimization can be applied or reverted cleanly from the wizard.

> **Note:** Host-level tuning complements—but does not replace—Strata's own serving configuration. On VRAM-constrained GPUs, check your serving/prefill chunk settings (e.g. `auto` vs. pinned) before chasing marginal OS-level gains.

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

### Read-only detection check (`--check`)

Inspect detected OS/init, hardware, Strata installation or Docker container, and which optimization steps would apply without prompting for `sudo` or making any changes:

```bash
./strata-performance-setup.sh --check
```

---

## Documentation

- [Supported Distributions](documentation/supported-distributions.md) — Supported Linux families, package managers, and bootloaders
- [Supported Hardware](documentation/supported-hardware.md) — GPU, laptop/OEM, and system-wide optimizations
- [Live Dashboard & Strata Monitoring](documentation/live-dashboard-and-strata-monitoring.md) — Real-time system metrics, Strata status, and update polling
- [Using the Wizard](documentation/using-the-wizard.md) — Navigation, shortcuts, and benchmark configuration restore
- [Credits & Third-Party Projects](documentation/credits-and-third-party-projects.md) — Open-source projects integrated with the wizard
- [License](documentation/license.md) — Project license details
