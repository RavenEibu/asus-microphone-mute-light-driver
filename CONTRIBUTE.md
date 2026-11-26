# Contributing to ASUS Mic‑Mute LED

Thanks for helping improve the ASUS Mic‑Mute LED installer! This project aims to keep the setup **simple, safe, and distro‑agnostic** (systemd user service + minimal udev permissions).

## Ground rules

- Keep the installer **POSIX/Bash** (no external deps beyond `systemd`, `udev`, and `pactl` or `amixer`).
- Prefer **user** services over root daemons; use udev only for **narrow** permissions (single LED node).
- Be explicit and defensive: clear error messages, `set -euo pipefail`, check preconditions.
- Document any user‑visible change in **README.md**.

## How to contribute

1. **Open an issue** describing the bug/feature with steps, logs, and your hardware model.
2. **Fork** the repo and create a branch:
   ```bash
   git checkout -b feat/short-topic   # or fix/short-topic, docs/short-topic
   ```
3. **Make focused changes**. Avoid mixing refactors with feature work.
4. **Run quick checks** (see below) and update docs as needed.
5. **Open a PR**. Explain *what changed* and *why*, list testing you performed, and any caveats.

## Quick checks (manual test plan)

> Do these on a host that actually exposes the LED (usually `/sys/class/leds/platform::micmute/brightness`).

```bash
# 0) Lint + automated tests (no hardware needed; CI runs the same)
shellcheck -S warning asus-micmute-installer.sh tests/run.sh
bash tests/run.sh
```

```bash
# 1) Fresh install
sudo ./asus-micmute-installer.sh --remove || true
sudo ./asus-micmute-installer.sh --install

# 2) Validate systemd (run as the target user)
systemctl --user daemon-reload
systemctl --user restart micmute-led.service
systemctl --user status micmute-led.service
journalctl --user -u micmute-led.service -b | tail -n +1
```

```bash
# 3) Validate udev permissions
ls -l /sys/class/leds/platform::micmute/brightness  # group=audio, g+rw
```

```bash
# 4) Functional check (LED toggles with mic state)
pactl set-source-mute   @DEFAULT_SOURCE@ toggle   # mute/unmute -> LED should change
pactl set-source-volume @DEFAULT_SOURCE@ 0%       # LED should turn ON (0%)
pactl set-source-volume @DEFAULT_SOURCE@ 50%      # LED should turn OFF (live, if unmuted)
# ALSA-only hosts: amixer set Capture toggle / 0% / 50%
```

```bash
# 4b) Recovery check: restart the audio server, the LED must keep following the mic
systemctl --user restart pipewire pipewire-pulse wireplumber
sleep 3; pactl set-source-mute @DEFAULT_SOURCE@ toggle   # LED should change; no CPU spin
pactl set-source-mute @DEFAULT_SOURCE@ toggle            # restore
ps -o pid,pcpu,args -C pactl,amixer                      # ~0% CPU
```

```bash
# 5) Removal
sudo ./asus-micmute-installer.sh --remove
```

## Coding style (shell)

- Top of scripts:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  IFS=$'
	'
  ```
- Use functions, `readonly` constants, `trap` for cleanup.
- Prefer `printf` over `echo` for predictable formatting.
- Avoid parsing `ls`; use globbing or direct file reads.
- Log helpers:
  ```bash
  info(){ printf '[INFO] %s
' "$*"; }
  warn(){ printf '[WARN] %s
' "$*" >&2; }
  die(){  printf '[ERR ] %s
' "$*" >&2; exit 1; }
  ```

## PR checklist

- [ ] `bash tests/run.sh` and `shellcheck` pass; new behavior has a test (the watcher is extracted from the installer, so tests cover it).
- [ ] Installer works on a clean machine (install → verify → remove).
- [ ] No privilege escalation beyond what’s needed for the LED node.
- [ ] README updated (usage, flags, behavior) if you changed UX.
- [ ] Logs are clear and actionable.
- [ ] New paths, unit names, or rules are explicit (no hidden env assumptions).

## Ideas & good first issues

- Optional `--led-path` flag (auto‑detect, fallback to current default); the watcher already honors `MICMUTE_LED`.
- Invert‑logic toggle for models with reversed LED semantics.
- Resync the LED after suspend/resume.
- Optional kernel `audio-micmute` LED trigger as a zero-process alternative (needs root to set the trigger).

## License

By contributing, you agree your changes are licensed under the repository’s **GPL‑3.0** license.
