# Credits & Third-Party Projects

This wizard relies on and integrates with the following open-source projects for hardware control, system tuning, and LLM serving (beyond standard OS/kernel utilities):

| Project | Role in Wizard | Repository |
| --- | --- | --- |
| **Strata** | LLM inference engine, CLI, updates, and `strata.service` | [Niko1221/Strata](https://github.com/Niko1221/Strata) |
| **LACT (`lactd`)** | GPU core & VRAM clock offset tuning (NVIDIA / AMD / Intel) | [ilya-zlobintsev/LACT](https://github.com/ilya-zlobintsev/LACT) |
| **gpu-unlock** | NVIDIA consumer GPU SM/tensor unlock kernel module (`gpu-unlock-dkms`) | [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) |
| **msi-ec** | MSI laptop Embedded Controller driver for shift/fan/Cooler Boost | [MControlSuite/msi-ec](https://github.com/MControlSuite/msi-ec) |
| **MControlCenter** | MSI laptop cooling and performance profile companion app | [dmitry-s93/MControlCenter](https://github.com/dmitry-s93/MControlCenter) |
| **asusctl** | ASUS laptop performance and fan profile control (`asusd`) | [asus-linux/asusctl](https://gitlab.com/asus-linux/asusctl) |
| **LenovoLegionLinux** | Lenovo Legion fan & power mode control (`legion_cli`) | [johnfanv2/LenovoLegionLinux](https://github.com/johnfanv2/LenovoLegionLinux) |
| **system76-power** | System76 laptop power & performance profile daemon | [pop-os/system76-power](https://github.com/pop-os/system76-power) |
| **TUXEDO Control Center** | TUXEDO laptop power/cooling daemon (`tccd`) | [tuxedocomputers/tuxedo-control-center](https://github.com/tuxedocomputers/tuxedo-control-center) |
| **libsmbios** | Dell thermal management CLI (`smbios-thermal-ctl`) | [dell/libsmbios](https://github.com/dell/libsmbios) |
| **ananicy-cpp** | Automatic process nice/scheduler tuning daemon | [ananicy-cpp/ananicy-cpp](https://gitlab.com/ananicy-cpp/ananicy-cpp) |
| **sched_ext (`scx`)** | BPF CPU scheduler (`scx_loader` / `scxctl` with `bpfland`) | [sched-ext/scx](https://github.com/sched-ext/scx) |
| **bpftune** | eBPF-driven automatic Linux kernel & sysctl tuning | [oracle/bpftune](https://github.com/oracle/bpftune) |
| **irqbalance** | Multi-core hardware IRQ load-balancing daemon | [Irqbalance/irqbalance](https://github.com/Irqbalance/irqbalance) |
| **zram-generator** | Systemd generator for `zstd`-compressed zram swap (Arch / Fedora) | [systemd/zram-generator](https://github.com/systemd/zram-generator) |
| **zram-tools** | `zramswap` service for `zstd`-compressed zram swap (Debian / Ubuntu) | [highvoltage/zram-tools](https://github.com/highvoltage/zram-tools) |
