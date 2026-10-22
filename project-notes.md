# Project Context: Dual-Screen Reception Kiosk (AnotterKiosk Fork)

## 1. Objective
We are building a single-PC, dual-screen kiosk appliance for a company reception desk driving two 1920x1080 displays:
1. **Interactive Display (Wacom One 14):** Displays safety information and captures customer signatures in a web app using pen and touch input.
2. **Passive Display (TV):** Displays an information dashboard with zero user interaction.

## 2. Validated & Rejected Approaches (Do Not Re-litigate)
- **Frontend (SOLVED):** Built with TanStack + React. We already replaced the outdated `react-signature-pad-wrapper` with a modern HTML5 `<canvas>` implementation (`PointerEvents` + `touch-action: none`). Wacom pen and touch input are verified working on Linux.
- **OS Choice (DECIDED):** We are forking and extending **AnotterKiosk** (`https://github.com/Manawyrm/AnotterKiosk`), which builds a minimal, read-only SquashFS Debian image running in RAM with Xorg, Chromium, and a FAT32 `/boot/kioskbrowser.ini` config partition.
- **Rejected Alternatives (DO NOT SUGGEST):**
  - *No Windows:* Rejected due to subtractive lockdown overhead (Explorer replacement, file-picker breakout vectors, Windows Update reboots, AD security risk).
  - *No Hyprland / Custom Arch / From-Scratch Distro:* Rejected for production stability and maintenance reasons.
  - *No Two-Device Split (e.g., separate Raspberry Pi):* Both screens must run off a single standalone x86 desktop PC.

## 3. Architecture & Planned Modifications to AnotterKiosk
To transform `AnotterKiosk` from a single-screen signage image into a dual-screen Wacom kiosk, we have designed four core changes:

### A. Package & Window Manager Adjustments
- Add `xserver-xorg-input-wacom`, `libwacom-common`, and `x11-xserver-utils` (`xrandr`, `xset`) to the Debian image build.
- Replace single-screen `matchbox-window-manager` with `openbox` so X11 respects multi-monitor coordinate geometry (`--window-position`).

### B. Configuration Extension (`/boot/kioskbrowser.ini`)
Extend the INI config and parsing scripts to replace the single URL with dual-display variables:
- `WACOM_OUTPUT="DP-1"`
- `WACOM_URL="https://..."`
- `TV_OUTPUT="HDMI-1"`
- `TV_URL="https://..."`

### C. X11 Startup, Display Layout & Input Mapping
In the Xorg startup script:
1. Disable DPMS and screen blanking (`xset s off -dpms s noblank`).
2. Position displays side-by-side via `xrandr`:
   `xrandr --output "$WACOM_OUTPUT" --mode 1920x1080 --pos 0x0 --primary --output "$TV_OUTPUT" --mode 1920x1080 --pos 1920x0`
3. Bind all Wacom input sub-devices (Pen, Eraser, Finger Touch) strictly to `$WACOM_OUTPUT` so touches/pen strokes never span across or jump to the TV:
   ```sh
   xsetwacom --list devices | awk -F'id: |\t' '{print $2}' | while read -r id; do
       xsetwacom --set "$id" MapToOutput "$WACOM_OUTPUT"
   done

```

4. Launch two isolated Chromium instances in RAM using separate `--user-data-dir` paths (required so Chromium honors `--window-position` for the second instance):
* **Wacom Instance (`0,0`):** `--user-data-dir=/tmp/kiosk-wacom --window-position=0,0 --window-size=1920,1080 --kiosk --no-first-run --noerrdialogs --disable-session-crashed-bubble --disable-pinch --overscroll-history-navigation=0 "$WACOM_URL"`
* **TV Instance (`1920,0`):** `--user-data-dir=/tmp/kiosk-tv --window-position=1920,0 --window-size=1920,1080 --kiosk --no-first-run --noerrdialogs --disable-session-crashed-bubble "$TV_URL"`



### D. TV Standby / EDID Persistence

* Append `video=HDMI-A-1:1920x1080@60e` (forced enable) to the kernel command line in the bootloader config so turning off the TV (dropping the HDMI 5V hot-plug signal) does not cause Xorg to collapse the second screen onto the Wacom display.

## 4. Open Tasks (What We Need Help Implementing Next)

1. **Exact Repo Patches:** Map these changes onto the actual files in the `AnotterKiosk` repository (build scripts, rootfs overlays, systemd services, and bootloader configs).
2. **Wacom USB Hot-Plug Recovery (`udev` Rule):** If the Wacom USB cable (Vendor ID `056a`) is unplugged/reconnected or power-cycled while Xorg is already running, Xorg resets the coordinate matrix across both screens. We need a `udev` rule or background hook that re-runs the `xsetwacom MapToOutput` binding automatically on USB reconnect.
3. **Dual-Instance Watchdog / Process Supervision:** Adapt `AnotterKiosk`'s single-browser watchdog/systemd unit so that both Chromium instances (`kiosk-wacom` and `kiosk-tv`) are monitored independently and restarted cleanly if either process crashes.
4. **Optional Hardening:** Support importing an internal corporate Root CA into `/etc/skel/.pki/nssdb` during image build if internal HTTPS endpoints are used.
