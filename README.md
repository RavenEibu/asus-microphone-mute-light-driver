# ASUS Mic-Mute LED — Linux driver/installer

Sync the **ASUS mic-mute keyboard LED** with your microphone **Capture** state on Linux.
This repo ships one self-contained installer: `asus-micmute-installer.sh`.

- Installs a **systemd *user*** service that mirrors the default microphone state (mute/volume) to the mic-mute LED.
- Adds a **udev rule** so the LED node stays writable across boot/resume.
- Runs unprivileged as your user (grants narrow write access to the LED node via the `audio` group).

> Requires a machine where the kernel (via `asus-nb-wmi`) exposes the LED as `platform::micmute`.

---

## Quick start

```bash
git clone git@github.com:RavenEibu/asus-microphone-mute-light-driver.git
cd asus-microphone-mute-light-driver
chmod +x asus-micmute-installer.sh

# Install (service + udev rule)
sudo ./asus-micmute-installer.sh --install

# Uninstall everything
sudo ./asus-micmute-installer.sh --remove
```

**Target user**: auto-detected (`$SUDO_USER` if set, otherwise `$USER`).
If you’re added to the `audio` group during install, **log out/in** (or reboot) so the membership takes effect.

---

## What gets installed

- **User service**: `~/.config/systemd/user/micmute-led.service`
  Starts a watcher process (`/usr/local/bin/micmute-led.sh`), restarts on exit, and waits for the audio server (`pactl`, or `amixer` as fallback) to be ready.
- **Watcher** (embedded, created by the installer): `/usr/local/bin/micmute-led.sh`
  Subscribes to audio events and writes LED brightness accordingly. Backend is auto-detected: `pactl subscribe` (PipeWire/PulseAudio, preferred, event-driven) or `amixer -n events` (ALSA fallback); force one with `MICMUTE_BACKEND=pactl|amixer`:
  - **LED ON** if mic is **muted** or volume is **0%**
  - **LED OFF** if mic is **live** (unmuted and volume > 0%)
  - Syncs the LED once on every (re)start, and includes a **watchdog** that restarts the event listener if it spins on CPU (see Troubleshooting).
- **udev rule**: `/etc/udev/rules.d/99-micmute-led.rules`
  Ensures the LED brightness node is group-`audio` and `g+rw` on device add/change.

---

## Requirements

- ASUS laptop with kernel module **`asus-nb-wmi`** (usually auto-loaded)
- LED node exists at: `/sys/class/leds/platform::micmute/brightness`
- **systemd**, **udev**, and either `pactl` (libpulse / pipewire-pulse, preferred) or ALSA utilities (`amixer`)

Check LED node:

```bash
ls -l /sys/class/leds/platform::micmute/brightness
```

---

## Verify it’s working

1) **Permissions**

```bash
ls -l /sys/class/leds/platform::micmute/brightness
# expect: group = audio and mode includes g+rw
```

2) **Toggle mic & watch LED**

```bash
# PipeWire / PulseAudio (pactl backend)
pactl set-source-mute   @DEFAULT_SOURCE@ toggle   # mute/unmute -> LED follows
pactl set-source-volume @DEFAULT_SOURCE@ 0%       # LED should turn ON (0%)
pactl set-source-volume @DEFAULT_SOURCE@ 50%      # LED should turn OFF (live, if unmuted)

# ALSA only (amixer backend)
amixer set Capture toggle
amixer set Capture 0%
amixer set Capture 50%
```

3) **Logs (run as the target user)**

```bash
systemctl --user status micmute-led.service
journalctl --user -u micmute-led.service -b
```

> The installer enables user lingering and starts your user manager so the service can run even without an active GUI session.

---

## How it works (under the hood)

- **Watcher**: a tiny shell script that reads the mic state (`pactl`, or `amixer` as fallback) and writes to:
  `/sys/class/leds/platform::micmute/brightness`
- **systemd (*user*)**: unit in `~/.config/systemd/user/micmute-led.service` with:
  - `ExecStartPre` loop to wait for the audio server (`pactl info`, or `amixer sget Capture`)
  - `Restart=always` with `RestartSec=2`
  - `WantedBy=default.target`
- **udev**: rule applies `chgrp audio` and `chmod g+rw` to the LED’s `brightness` node on `add|change`.

---

## Customization

- **Backend**: auto-detected (`pactl` preferred, `amixer` fallback). Force one by adding `Environment=MICMUTE_BACKEND=pactl` (or `amixer`) to the user unit.
- **Watchdog**: tune `WATCHDOG_INTERVAL`, `WATCHDOG_MAX_PCT`, `WATCHDOG_STRIKES` the same way. The watcher is event-driven (no polling); the `sleep 2` in `/usr/local/bin/micmute-led.sh` is only the retry delay when the listener exits.
- **Different LED name/path**: edit the installer **and** the embedded watcher path before installing.
- **Run as root instead**: not recommended; current setup limits write access to a single sysfs node via the `audio` group.

---

## Troubleshooting

- **LED file missing**
  Not all ASUS models expose `platform::micmute`. List LEDs:
  ```bash
  ls -1 /sys/class/leds
  ```
  If your LED has a different name, adjust both the installer’s LED path and the watcher’s write path.

- **No LED reaction**
  Check that `pactl get-source-mute @DEFAULT_SOURCE@` works (PipeWire/PulseAudio) or, for the ALSA fallback, that `alsa-utils` is installed and `amixer get Capture` shows valid controls. Look at `journalctl --user -u micmute-led.service -b`.

- **Event listener stuck at ~100% CPU after PipeWire/PulseAudio restarts**
  `pactl subscribe` exits cleanly when the server restarts, but the `amixer -n events` fallback can lose its connection and spin instead of exiting. The watcher samples the listener's CPU every 3 s and restarts it after two consecutive samples above 50% of a core (tunable via `WATCHDOG_INTERVAL`, `WATCHDOG_MAX_PCT`, `WATCHDOG_STRIKES`, see Customization). To recover an already-running install, re-run `sudo ./asus-micmute-installer.sh --install` and `systemctl --user restart micmute-led.service`.

- **Permission denied on `brightness`**
  Reinstall to reapply the udev rule, or confirm your session picked up the `audio` group (log out/in).

- **LED logic inverted for your model**
  Edit the watcher at `/usr/local/bin/micmute-led.sh` and swap the values written to `brightness`.

---

## Security notes

- Watcher runs as a **non-root** user.
- Grants `g+rw` **only** on the single LED `brightness` node (no broad `chmod 666`).
- No network access or special capabilities required.

---

## Contributing

Issues and PRs are welcome — see **[CONTRIBUTE.md](./CONTRIBUTE.md)**.

---

## License
**GPL-3.0** — see **[LICENSE](./LICENSE)**.
