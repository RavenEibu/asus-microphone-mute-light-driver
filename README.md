# ASUS Mic-Mute LED — Installer/Uninstaller

Sync the **ASUS mic-mute LED** with your **ALSA Capture** state.
This repository contains a single self-contained script: **`asus-micmute-installer.sh`**.
It embeds the watcher daemon and lets you install or uninstall in two ways:

* **Option A (systemd service)** — runs the watcher at boot; fixes LED permissions before start.
* **Option B (udev rule)** — ensures the LED node is writable by your user’s group when the device appears (boot/resume).

> Works on most systemd-based distros that use ALSA. The watcher listens to `amixer` events and updates the LED accordingly.

---

## What it does

* Installs an embedded watcher to: `/usr/local/bin/micmute-led.sh`
  (only when you install **Option A**)
* For **Option A**:

  * Creates a systemd unit: `/etc/systemd/system/micmute-led.service`
  * At service start, runs:
    `chgrp audio /sys/class/leds/platform::micmute/brightness && chmod g+rw ...`
  * Runs the watcher **as your user**, group `audio`. Restarts if it exits.
* For **Option B**:

  * Creates a udev rule: `/etc/udev/rules.d/99-micmute-led.rules`
  * When the LED device appears/changes, grants group-write on the brightness file.

**Watcher logic (embedded):**

* Subscribes to `amixer` events and polls `amixer get Capture`.
* If Capture is **[off]** → LED **ON** (muted).
* If Capture is **[on]** and **0%** → LED **ON** (effectively muted).
* If Capture is **[on]** and **>0%** → LED **OFF** (live mic).
* Writes to: `/sys/devices/platform/asus-nb-wmi/leds/platform::micmute/brightness`
  (permission changes are applied to the stable symlink:
  `/sys/class/leds/platform::micmute/brightness`, which points to the same node).

---

## Requirements

* **systemd** (for Option A)
* **udev** (for Option B — present on virtually all Linux distros)
* **ALSA utilities** (`amixer` must exist; package is usually `alsa-utils`)
* ASUS LED exposed at: `/sys/class/leds/platform::micmute/brightness`
* Kernel driver: `asus-nb-wmi` (usually auto-loaded on ASUS laptops)

Check LED path:

```bash
ls -l /sys/class/leds/platform::micmute/brightness
```

---

## Quick start

1. Make the installer executable:

```bash
chmod +x asus-micmute-installer.sh
```

2. Install one or both options:

### Option A — systemd (recommended)

Installs the embedded watcher and starts it at boot:

```bash
sudo ./asus-micmute-installer.sh --install a --user <your_login>
```

### Option B — udev rule (permission helper)

Keeps the LED node writable for the `audio` group at boot/resume:

```bash
sudo ./asus-micmute-installer.sh --install b
```

### Both (robust)

```bash
sudo ./asus-micmute-installer.sh --install both --user <your_login>
```

> The installer ensures group **audio** exists and adds `<your_login>` to it if needed. You may need to **log out/in once** so your shell session picks up the new group.

---

## Uninstall

* Remove **Option A** (systemd):

```bash
sudo ./asus-micmute-installer.sh --uninstall a
```

* Remove **Option B** (udev):

```bash
sudo ./asus-micmute-installer.sh --uninstall b
```

* Remove **everything** (also deletes `/usr/local/bin/micmute-led.sh`):

```bash
sudo ./asus-micmute-installer.sh --uninstall all
```

---

## How it works (under the hood)

### Option A (systemd)

* Unit file: `/etc/systemd/system/micmute-led.service`
* Key bits:

  * `ExecStartPre=…chgrp/chmod…` grants **audio** group write access to the LED file.
  * `User=<your_login>` & `Group=audio` run the watcher unprivileged.
  * `After=sound.target` ensures it starts post sound stack init.
  * `Restart=always` with `RestartSec=2`.
* Logs:

```bash
journalctl -u micmute-led.service -b
```

### Option B (udev)

* Rule file: `/etc/udev/rules.d/99-micmute-led.rules`
* On device `add`/`change`, runs:

  ```
  chgrp audio /sys/class/leds/platform::micmute/brightness
  chmod g+rw /sys/class/leds/platform::micmute/brightness
  ```
* Reload and trigger is automatic during install:

  ```
  udevadm control --reload
  udevadm trigger -s leds
  ```

---

## Verifying it works

1. Confirm LED file is writable by the `audio` group:

```bash
ls -l /sys/class/leds/platform::micmute/brightness
# Expect group = audio and g+rw
```

2. Toggle mic capture and watch the LED:

```bash
amixer get Capture | tail -n +1
amixer set Capture toggle     # toggle mute on/off
amixer set Capture 0%         # volume to 0% (LED should be ON)
amixer set Capture 50%        # >0% (LED should be OFF)
```

3. Check service logs (Option A):

```bash
journalctl -u micmute-led.service -b
```

---

## Customization

* **Polling interval**: edit `/usr/local/bin/micmute-led.sh` and change `sleep 2` at the bottom.
* **Different LED path**: update the installer’s LED path (both the systemd `ExecStartPre` and the udev rule) *and* the watcher’s write path if your hardware uses a different LED name.
* **Run as root instead**: you can remove `User=`/`Group=` in the service and skip permission steps, but running as your user with a narrow `g+rw` on one sysfs file is safer.

---

## Troubleshooting

* **LED path missing**
  Not all ASUS models expose `platform::micmute`. Verify the path under `/sys/class/leds`. If your machine uses a different LED name, adapt the installer and watcher.

* **No LED reaction**
  Ensure `alsa-utils` is installed and `amixer` works. Try:

  ```bash
  amixer -n events
  ```

  and

  ```bash
  amixer get Capture
  ```

  If PipeWire/PulseAudio is in use, ALSA controls should still map through; ensure your Capture control actually toggles mute/volume.

* **Permissions revert after suspend**
  Use **Option B** (udev), or install **both**. Option B reapplies perms on device `add/change`.

* **Group change not taking effect**
  After being added to `audio`, log out and back in (or reboot) so your session picks up the new group.

---

## Files created by the installer

* **Option A**:

  * `/etc/systemd/system/micmute-led.service`
  * `/usr/local/bin/micmute-led.sh` (embedded watcher)
* **Option B**:

  * `/etc/udev/rules.d/99-micmute-led.rules`

Uninstalling with `--uninstall all` removes all of the above.

---

## Security notes

* The service runs as your **non-root user**, with write access granted **only** to the specific LED brightness node.
* No broad `chmod 666` is used; instead, group ownership `audio` + `g+rw`.
* Systemd unit is simple and scoped; no network or special capabilities required.

---

## Commands reference

```bash
# Install A (systemd), run as your user:
sudo ./asus-micmute-installer.sh --install a --user mylogin

# Install B (udev only):
sudo ./asus-micmute-installer.sh --install b

# Install both:
sudo ./asus-micmute-installer.sh --install both --user mylogin

# Status & logs (Option A):
systemctl status micmute-led.service
journalctl -u micmute-led.service -b

# Uninstall:
sudo ./asus-micmute-installer.sh --uninstall a
sudo ./asus-micmute-installer.sh --uninstall b
sudo ./asus-micmute-installer.sh --uninstall all
```

---

## License

MIT.
