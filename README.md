# ASUS Mic-Mute LED — Linux driver/installer

Sync the **ASUS mic-mute keyboard LED** with your microphone **Capture** state on Linux.
This repo ships one self-contained installer: `asus-micmute-installer.sh`.

- Installs a **systemd *user*** service that mirrors ALSA *Capture* (mute/volume) to the mic-mute LED.
- Adds a **udev rule** so the LED node stays writable across boot/resume.
- Runs unprivileged as your user (grants narrow write access to the LED node via the `audio` group).

> Requires a machine where the kernel (via `asus-nb-wmi`) exposes the LED as `platform::micmute`.

---

## Quick start

```bash
git clone git@github.com:RavenEibu/asus-microphone-mute-light-driver.git
cd git@github.com:RavenEibu/asus-microphone-mute-light-driver.git
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
  Starts a watcher process (`/usr/local/bin/micmute-led.sh`), restarts on exit, and waits for ALSA to be ready.
- **Watcher** (embedded, created by the installer): `/usr/local/bin/micmute-led.sh`
  Polls/subscribes to `amixer` events and writes LED brightness accordingly:
  - **LED ON** if mic is **muted** (`[off]`) or volume is **0%`**
  - **LED OFF** if mic is **live** (`[on]` and volume > 0%)
- **udev rule**: `/etc/udev/rules.d/99-micmute-led.rules`
  Ensures the LED brightness node is group-`audio` and `g+rw` on device add/change.

---

## Requirements

- ASUS laptop with kernel module **`asus-nb-wmi`** (usually auto-loaded)
- LED node exists at: `/sys/class/leds/platform::micmute/brightness`
- **systemd**, **udev**, and **ALSA utilities** (`amixer`) available

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
amixer get Capture | tail -n +1
amixer set Capture toggle   # mute/unmute
amixer set Capture 0%       # LED should turn ON (muted/0%)
amixer set Capture 50%      # LED should turn OFF (live)
```

3) **Logs (run as the target user)**

```bash
systemctl --user status micmute-led.service
journalctl --user -u micmute-led.service -b
```

> The installer enables user lingering and starts your user manager so the service can run even without an active GUI session.

---

## How it works (under the hood)

- **Watcher**: a tiny shell script that reads `amixer` and writes to:
  `/sys/class/leds/platform::micmute/brightness`
- **systemd (*user*)**: unit in `~/.config/systemd/user/micmute-led.service` with:
  - `ExecStartPre` loop to wait for ALSA readiness
  - `Restart=always` with `RestartSec=2`
  - `WantedBy=default.target`
- **udev**: rule applies `chgrp audio` and `chmod g+rw` to the LED’s `brightness` node on `add|change`.

---

## Customization

- **Polling interval**: edit the embedded watcher (created at `/usr/local/bin/micmute-led.sh`) — change the `sleep` value.
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
  Ensure `alsa-utils` is installed and that `amixer get Capture` shows valid controls. PipeWire/PulseAudio on top of ALSA is fine.

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
