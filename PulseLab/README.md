# PulseLab Foreground Engine 1.0

Experimental iOS foreground CPU micro-bursts, real Metal compute dispatches, and app-sandbox file I/O, with individually enabled engines, 5–100 ms cadence, four presets, thermal throttling, and live operation counters.

**Not a system-wide power-state unlock.** GPU completions include scheduling and CPU overhead; file reads may be cached; activity ends when the app backgrounds. Sustained load could increase thermal throttling and worsen latency.

This folder builds with XcodeGen in the repository's PulseLab GitHub workflow. GitHub Actions produces an **unsigned** IPA. Sign for the destination iPhone using an Apple certificate and provision, or have a trusted sideloading tool sign the unsigned IPA. Never publicly upload a private .p12 certificate or its password.

No background mode, CPU idle, system-wide GPU clock, or NVMe power overrides.
