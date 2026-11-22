# HTPC `mpv` Configuration — Windows 11 · `gpu-next` (D3D11) · Epson 5050UB · Jellyfin MPV Shim

A deterministic, empirically validated `mpv` playback pipeline engineered for a dedicated Windows 11 Home Theater PC running **Jellyfin MPV Shim**, an **AMD Radeon RX 9060 XT**, an **Epson Home Cinema 5050UB** 4K pixel-shifting projector, and an **HDMI AVR** bitstream audio chain.

This repository pairs an always-on 10-bit BT.2020 PQ `libplacebo` configuration (`mpv.conf`) with automated HDMI 2.0 bandwidth-safe refresh-rate/HDR switching (`refresh.lua` + `set_display.ps1`), live pipeline verification and benchmark logging (`profile_hud.lua`), and real-time A/B calibration hotkeys (`input.conf`).

---

## System & Hardware Baseline

| Layer | Hardware / Software | Active Configuration & Constraints |
| :--- | :--- | :--- |
| **OS & Frontend** | Windows 11 · Jellyfin MPV Shim | External `mpv` execution (`mpv v0.42.0-dev` / `libplacebo v7.387.0`) |
| **GPU & Decoder** | AMD Radeon RX 9060 XT | `vo=gpu-next`, `gpu-api=d3d11`, `gpu-context=d3d11`, `hwdec=d3d11va` (zero-copy `d3d11[nv12]` / `p010` decode) |
| **Display Output** | Epson Home Cinema 5050UB | `d3d11-output-format=rgb10_a2` (DXGI `RGB_FULL_G2084_NONE_P2020`); HDMI 2.0 (18 Gbps) ceiling; ~80-nit calibrated peak in BT.2020 with DCI-P3 coverage |
| **Audio Chain** | HDMI AVR (Atmos / Lossless) | `ao=wasapi`, `audio-exclusive=yes`, `audio-spdif=ac3,eac3,dts,dts-hd,truehd`, `video-sync=audio` |
| **Color Pipeline** | Native `libplacebo` | `gamut-mapping-mode=perceptual`, `target-trc=pq`, `target-prim=bt.2020`, `target-gamut=display-p3`, `target-peak=150` |

---

## Prerequisites

The configurations, companion scripts, and custom shaders in this repository require the following software to be installed:

* **[mpv.exe](https://mpv.io/) (Required):** Download the latest 64-bit Windows build from [mpv.io](https://mpv.io/) (or [mpv Windows builds](https://sourceforge.net/projects/mpv-player-windows/files/)). A modern build supporting `vo=gpu-next` and `libplacebo` (e.g., `mpv v0.38+` / `v0.42.0-dev`) is required for the Direct3D 11 / PQ tone-mapping pipeline.
* **[Jellyfin MPV Shim](https://github.com/jellyfin/jellyfin-mpv-shim) (Optional):** If using this setup on a dedicated Home Theater PC casting frontend, install [Jellyfin MPV Shim](https://github.com/jellyfin/jellyfin-mpv-shim). It acts as a lightweight remote casting target that delegates playback directly to `mpv.exe` without transcoding.

---

## Repository Structure

Deploy these files into your Windows `mpv` configuration directory (`%APPDATA%\mpv\`, referenced by `mpv` as `~~/`):

```text
%APPDATA%\mpv\
├── .gitattributes               # Line-ending and binary tracking configuration
├── .gitignore                   # Excludes GPU shader caches, telemetry logs, and OS artifacts
├── LICENSE                      # GNU General Public License v3.0
├── README.md                    # System architecture, calibration, and telemetry documentation
├── input.conf                   # Live A/B tone-mapping, peak-nit, and gamut-mapping hotkeys
├── mpv.conf                     # Core D3D11/libplacebo pipeline, scalers, and conditional profiles
├── set_display.ps1              # Native Win32 P/Invoke script for Windows HDR & refresh-rate switching
├── docs/                        # Architecture reference and projector setting guides
│   └── mpv.conf_Technical_Summary___Architecture_Reference.pdf
├── script-opts/                 # Per-script configuration directory (.gitkeep tracked)
├── scripts/
│   ├── refresh.lua              # FPS detection, 2:1 HDMI 2.0 cadence capping, 10s settle pause, audio scoring
│   └── profile_hud.lua          # Live profile-cond evaluator, swapchain-safe OSD banner, session telemetry logger
└── shaders/
    ├── CAS.glsl                 # FidelityFX Contrast Adaptive Sharpening (native 4K SDR)
    ├── CAS_PQ.glsl              # PQ-relinearized CAS (native 4K HDR / DoVi / HDR10+)
    ├── CAS-scaled.glsl          # Post-upscale CAS (sub-4K SDR)
    ├── CAS-scaled_PQ.glsl       # PQ-relinearized post-upscale CAS (sub-4K HDR / DoVi / HDR10+)
    ├── CfL_Prediction.glsl      # Chroma-from-Luma upscaling
    ├── filmgrain.glsl           # Optional synthetic film grain for SDR
    ├── FSRCNNX_x2_8-0-4-1.glsl  # 14-pass neural luma upscaler (sub-4K ≤ 31 fps)
    ├── ravu-lite-ar-r3.hook     # Lightweight anti-ringing upscaler (sub-4K > 31 fps)
    └── cache/                   # Persistent DXBC GPU shader cache (.gitkeep tracked; binaries ignored)
```

---

## Architectural Design & Empirical Rationale

Every architectural choice in this setup was validated via `mpv-debug.log` analysis, `vo-passes` GPU timing telemetry, and A/B visual testing:

* **Direct3D 11 over Vulkan:** `gpu-api=vulkan` was abandoned in favor of `gpu-api=d3d11` (`d3d11-exclusive-fs=no`, `d3d11-output-format=rgb10_a2`) to guarantee zero-copy `d3d11va` decoding on the RX 9060 XT and stable DXGI HDR swapchain handshaking without exclusive-fullscreen instability.
* **Always-On 10-Bit PQ Container:** Locking the swapchain to BT.2020 PQ (`target-colorspace-hint=yes`, `target-colorspace-hint-mode=target`) keeps SDR and HDR content on a single calibrated projector baseline without display-side mode drift.
* **Native `libplacebo` over Stacked 3D LUTs:** External DisplayCAL `.cube` 3D LUTs (`lut-type=native`) were removed because stacking a baked 3D LUT on top of dynamic tone mapping (`spline` / `st2094-40`) caused double-compression and shadow crush. Native `libplacebo` perceptual gamut mapping (`display-p3` inside `bt.2020`) preserves shadow detail and highlight rolloff.
* **Linear SDR-to-PQ Gain Scaling:** Rather than compressing SDR highlights with `reinhard` or `clip`, the `[SDR]` profile applies linear pre-PQ gain scaling (`target-peak=203`, `contrast=-25`, `brightness=0`) to align SDR white with the 150-nit HDR projector ceiling without knee artifacts.
* **Bottom-to-Top Profile Precedence:** Because `mpv` evaluates matching auto-profiles from the bottom of `mpv.conf` upward when properties initialize simultaneously, resolution/upscaling profiles sit at the **bottom** (Layer 1) and dynamic-range/container profiles sit **above** them (Layer 2). Every `profile-cond` is gated on `p["video-params/w"] ~= nil and p["video-params/colormatrix"] ~= nil` so both layers evaluate on the exact same tick.
* **Jellyfin MPV Shim Protection:** `reset-on-next-file=audio-delay,sub-delay,speed,video-aspect-override` restricts per-file resets so Shim's IPC and `user-data` properties persist across playlist transitions.

---

## `mpv.conf` Pipeline Breakdown

### Global Baseline
* **Window & Presentation:** `fullscreen=yes`, `ontop=yes`, `window-maximized=yes`.
* **Scaling, Debanding & Dithering:** Tuned for the RX 9060 XT and Epson 5050UB pixel shifting—uses 1D separable `scale=spline36` (`scale-antiring=0.7`), separable orthogonal `cscale=mitchell` (`cscale-antiring=0`), `dscale=mitchell` (`correct-downscaling=yes`, `linear-downscaling=no`), 1-pass debanding (`deband=yes`, `deband-iterations=1`, `deband-threshold=16`, `deband-range=16`, `deband-grain=0`), and 10-bit blue-noise dithering (`dither-depth=10`, `dither=fruit`).
* **Subtitles & Auto-Crop:** Prioritizes English tracks (`alang=eng,en`, `slang=eng,en`), caps text and bitmap (PGS) subtitle luminance at 100 nits (`sub-hdr-peak=100`, `image-subs-hdr-peak=100`) to prevent glare in the PQ container, and enables automated black-bar cropping (`autocrop-auto=yes`, `autocrop-speed=4`, `autocrop-blacklimit=5`) with `sub-pos=95` and `sub-use-margins=no`.

### Conditional Auto-Profiles
All conditional profiles use `profile-restore=copy` to prevent state bleed between consecutive files.

#### Layer 1: Resolution & Upscaling (Bottom of `mpv.conf` — Evaluated First)

| Profile | Trigger Condition | Shader Stack |
| :--- | :--- | :--- |
| **`[sub-4k]`** | Non-DoVi P5; `< 3840x2160`; `container-fps <= 31` | `glsl-shaders-clr` → `CfL_Prediction.glsl` → `FSRCNNX_x2_8-0-4-1.glsl` → `CAS-scaled.glsl` |
| **`[4k-native]`** | Non-DoVi P5; `>= 3840` or `>= 2160` | `glsl-shaders-clr` → `CfL_Prediction.glsl` → `CAS.glsl` |
| **`[High-FPS-Override]`** | Non-DoVi P5; `< 3840x2160`; `container-fps > 31` | `glsl-shaders-clr` → `ravu-lite-ar-r3.hook` → `CAS-scaled.glsl` |

#### Layer 2: Dynamic Range & Container Overrides (Above Layer 1 — Evaluated Second)

| Profile | Trigger Condition | Overrides & Shader Modifications |
| :--- | :--- | :--- |
| **`[HDRplus]`** | HDR10+ (`hdr-format == "hdr10-plus"` or `scene-max-r/g/b > 0`, non-DoVi) | `deband=no`, `tone-mapping=st2094-40`, `hdr-contrast-recovery=0.35`, `hdr-compute-peak=no`; swaps CAS for `CAS_PQ.glsl` / `CAS-scaled_PQ.glsl` |
| **`[DoVi-P7]`** | `dolby-vision-profile == 7` (UHD Blu-ray MEL & FEL) | `deband=no`, `tone-mapping=spline`, `hdr-compute-peak=yes` (`hdr-peak-percentile=99.995`, `hdr-peak-decay-rate=15`), `hdr-contrast-recovery=0.30`; swaps CAS for `CAS_PQ.glsl` / `CAS-scaled_PQ.glsl` |
| **`[DoVi]`** | Dolby Vision Profile 8 and other RPU streams (excludes P5 & P7) | `deband=no`, `tone-mapping=spline`, `hdr-compute-peak=no`, `hdr-contrast-recovery=0.30`; swaps CAS for `CAS_PQ.glsl` / `CAS-scaled_PQ.glsl` |
| **`[HDR]`** | `gamma == "pq"` or `"hlg"`; non-DoVi; non-HDR10+ (`scene-max <= 0`) | `deband=no`, `tone-mapping=spline`, `hdr-compute-peak=yes` (`hdr-peak-percentile=99.995`, `hdr-peak-decay-rate=15`), `hdr-contrast-recovery=0.30`; swaps CAS for `CAS_PQ.glsl` / `CAS-scaled_PQ.glsl` |
| **`[SDR-Filmgrain]`** | Non-PQ, non-HLG, non-DoVi SDR streams | Idempotently removes and appends `filmgrain.glsl` after upscaling |
| **`[SDR]`** | Non-PQ, non-HLG, non-DoVi SDR streams | `target-peak=203`, `contrast=-25`, `brightness=0`; preserves global `deband=yes` |
| **`[DoVi-P5]`** | `dolby-vision-profile == 5` (IPT-PQ) | Executes `glsl-shaders-clr` to strip YCbCr-dependent shaders while preserving `audio-spdif` |

*(Note: `CAS_PQ.glsl` and `CAS-scaled_PQ.glsl` use `//!WHEN` guards—`OUTPUT.w NATIVE_CROPPED.w / 1.3 <` vs. `>`—so only the appropriate native or post-upscale pass executes on the GPU.)*

---

## Companion Automation & Telemetry Scripts

### 1. `scripts/refresh.lua` & `set_display.ps1`
Bridges `mpv` playback lifecycle events to native Windows display controls while respecting the Epson 5050UB's HDMI 2.0 (18 Gbps) ceiling and handshake latency:

* **Duplicate-Instance Guard:** Every callback and keybinding verifies `mp.get_script_name() == "refresh"` to prevent duplicate execution if Jellyfin MPV Shim loads the scripts directory more than once.
* **Multi-Fallback FPS Detection & 2:1 Cadence Capping:** Reads `container-fps` → selected video track `demux-fps` → `estimated-vf-fps`, then maps via nearest-neighbor matching (`23.976→23`, `24→24`, `25/50→25`, `29.97/59.94→29`, `30/60→30 Hz`). Capping 50/59.94/60 fps to 25/29/30 Hz maintains exact 2:1 cadence within 10-bit 4:4:4 HDMI 2.0 bandwidth limits.
* **Native Win32 Display Switching (`set_display.ps1`):** Uses `user32.dll` P/Invoke (`QueryDisplayConfig` / `DisplayConfigSetDeviceInfo` with `DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE`, plus `EnumDisplaySettings` / `ChangeDisplaySettings`) to toggle Windows Advanced Color (HDR) and display refresh rate without third-party utilities.
* **10-Second HDMI Settle Pause & Shim Unpause Interception:** On `file-loaded`, pauses playback and launches `set_display.ps1` asynchronously (deduplicated via `<hdr_flag>_<target_hz>`). A `pause` property observer intercepts Jellyfin MPV Shim's automatic unpause (~0.15s–0.35s post-load) while `settling == true`, holding playback for `settle_secs = 10` seconds after the switch completes so no opening frames are lost during projector HDMI lock.
* **Priority Audio Track Selection:** Scores available audio tracks at 0.15s post-load, prioritizing English (`eng`/`en`) TrueHD, E-AC3, DTS, and AC3 streams, Atmos titles, and higher channel counts while penalizing commentary/SDH tracks.
* **Clean Teardown & Forced Exit Keys:** On `end-file` and `shutdown`, kills pending timers and runs a detached PowerShell call to restore Windows to SDR @ 23 Hz. Forces `ESC` and `alt+bs` (MCE Back) to dispatch `script-message custom-bind bind1` for reliable Shim exit.

### 2. `scripts/profile_hud.lua`
Provides real-time visual confirmation and persistent session telemetry (`~~/mpv_test_runs.log`) without hardcoded rule drift:

* **Live `profile-cond` Evaluator:** Reads `profile-list` at runtime and evaluates the exact `profile-cond` Lua expressions from `mpv.conf` inside an isolated environment (`p` property proxy + `get()` helper) matching `mpv`'s internal `@auto_profiles.lua`.
* **Swapchain-Safe OSD Banner:** Polls every 250 ms (up to 12 retries) on `file-loaded`, `playback-restart`, and unpause until `vo-configured == true` and `video-params/w > 0`, rendering a left-justified top-left (`{\an7}`) `ass-events` banner (`[active profiles] | HDR / SDR->PQ @ XX.XX Hz`) for 10 seconds.
* **Pipeline & Health Telemetry:** Snapshots media path, active profiles, resolution, FPS, colormatrix, gamma, DoVi profile, HDR format, tone-mapping state, loaded `glsl-shaders`, and actual executed GPU passes (`vo-passes.fresh` with per-pass average ms) at 1.5s into playback. Samples health metrics every 2.0s and writes a final `Health` summary (`Drops`, `Delayed`, `Mistimed`, `Display-FPS vs Container-FPS`, `HWDec`) on `end-file`.

---

## Interactive Calibration Hotkeys (`input.conf`)

Designed for live A/B testing without colliding with Jellyfin MPV Shim's keybindings:

| Keybinding | Action | Cycled Values / Target State |
| :--- | :--- | :--- |
| **`Shift + H`** (`H`) | Cycle tone-mapping curve | `spline` → `bt.2390` → `bt.2446a` → `clip` |
| **`Shift + N`** (`N`) | Cycle target peak brightness | `80`, `100`, `120`, `150`, `200`, `250`, `300`, `400`, `500` nits |
| **`Shift + G`** (`G`) | Cycle gamut mapping mode | `perceptual` → `relative` → `saturation` → `clip` → `reinhard` |
| **`Shift + R`** (`R`) | Reset live overrides to baseline | `tone-mapping=spline`, `target-peak=150`, `gamut-mapping-mode=perceptual` |

---

## Verified Performance Telemetry

Empirical validation on a 1080p SDR test clip (`[sub-4k + SDR-Filmgrain + SDR]` @ 23.976 fps, 52.4s run via `mpv_test_runs.log` and `mpv-debug.log`) confirmed exact cadence lock and zero playback faults (`Drops=0 | Delayed=0 | Mistimed=0`):

* **Steady-State GPU Render Time:** **4.03 ms** total across 25 passes (leaving >34 ms of headroom within the 41.708 ms frame budget):
  * Debanding: `0.09 ms`
  * `FSRCNNX_x2_8-0-4-1.glsl` (14 passes): `2.51 ms`
  * `CAS-scaled.glsl` (2 passes): `0.46 ms`
  * `filmgrain.glsl`: `0.00 ms`
  * `CfL_Prediction.glsl` (4 passes): `0.46 ms`
  * Separable orthogonal `mitchell` chroma scaling (2 passes): `0.51 ms`

---

## Deployment & Operational Notes

1. **Configure Jellyfin MPV Shim (Optional):** If using [Jellyfin MPV Shim](https://github.com/jellyfin/jellyfin-mpv-shim), configure it to use your standalone [mpv.io](https://mpv.io/) installation (`mpv_ext: true`, `mpv_ext_no_ovr: true`) pointing to your `mpv` binary (e.g., `C:\Tools\mpv\mpv.exe`) so Shim delegates directly to your local `mpv.conf` without overriding renderer options.
2. **Production Logging Hygiene:** Keep `log-file="~~/mpv-debug.log"` and `msg-level=...` commented out in `mpv.conf` during normal viewing to avoid disk I/O from verbose `libplacebo` shader dumps; uncomment only during diagnostic capture passes.
3. **Exclusive WASAPI Recovery:** If exclusive WASAPI bitstream audio ever drops out after an HDMI resync on your AVR/projector, uncomment `mp.command("ao-reload")` inside `end_settle()` in `scripts/refresh.lua`.
4. **Telemetry Inspection:** Check `%APPDATA%\mpv\mpv_test_runs.log` after playback to verify active profile stacks, executed GPU passes (`//!WHEN` guard behavior), and zero dropped/mistimed frames.

---

## Shader Authors & Acknowledgments

This configuration integrates high-performance custom GLSL shaders developed by open-source community authors:

| Shader | Upstream Author / Project | License | Purpose |
| :--- | :--- | :--- | :--- |
| **FSRCNNX** (`FSRCNNX_x2_8-0-4-1.glsl`) | **igv** (based on Chao Dong et al.) | GNU LGPLv3 | Fast super-resolution neural network upscaler for sub-4K sources |
| **RAVU** (`ravu-lite-ar-r3.hook`) | **bjin** | GNU LGPLv3 | Rapid Anime Visual Upscaler with anti-ringing for high-framerate playback |
| **CfL Prediction** (`CfL_Prediction.glsl`) | **João Chrisóstomo** | MIT License | Chroma-from-Luma prediction upscaler |
| **FidelityFX CAS** (`CAS.glsl`, `CAS-scaled.glsl`) | **Advanced Micro Devices, Inc. (AMD)** | MIT License | Contrast Adaptive Sharpening ported and scaled for `mpv` |
| **CAS (PQ / HDR Variant)** (`CAS_PQ.glsl`, `CAS-scaled_PQ.glsl`) | Community adaptation of AMD FidelityFX CAS | MIT License | Contrast Adaptive Sharpening relinearized for PQ / HDR10 pipelines |
| **Film Grain** (`filmgrain.glsl`) | **deus0ww** / `mpv` community | Unlicense / Public Domain | Gaussian synthetic film grain synthesis for SDR content |

Special thanks to the **mpv** and **libplacebo** developers (wm4, haasn, and contributors) for pioneering the Direct3D 11 / `gpu-next` rendering architecture.

---

## License

This configuration and companion scripts are licensed under the **GNU General Public License v3.0** (GPLv3). Third-party shaders remain under their respective upstream licenses (MIT / LGPLv3). See [LICENSE](LICENSE) for full legal text.
