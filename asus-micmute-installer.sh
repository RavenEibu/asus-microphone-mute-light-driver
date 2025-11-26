#!/usr/bin/env bash
# asus-micmute-installer.sh
# Installs a robust setup to sync the ASUS mic-mute LED with ALSA Capture:
#  - A systemd *user* service (starts after your session audio is up)
#  - A udev rule that keeps the LED node writable across boot/resume
#
# Usage:
#   sudo ./asus-micmute-installer.sh --install   # or -i
#   sudo ./asus-micmute-installer.sh --remove    # or -r
#
# The target user is auto-detected: $SUDO_USER (if set) otherwise $USER.

set -euo pipefail

# ----- Config -----
LED_CLASS_BRIGHTNESS="/sys/class/leds/platform::micmute/brightness"
UDEV_RULE="/etc/udev/rules.d/99-micmute-led.rules"
TARGET_SCRIPT="/usr/local/bin/micmute-led.sh"

INSTALL=0
REMOVE=0

# target user (prefer the user who ran sudo)
TARGET_USER="${SUDO_USER:-${USER}}"

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "[*] $*"; }

usage() {
  cat <<EOF
asus-micmute-installer.sh

Installs:
  • User systemd service: ~/.config/systemd/user/micmute-led.service
  • Embedded watcher:     $TARGET_SCRIPT
  • Udev rule:            $UDEV_RULE  (sets group 'audio' and g+rw on LED)

Usage:
  sudo $0 --install | -i
  sudo $0 --remove  | -r
EOF
}

# ----- Arg parsing -----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install|-i) INSTALL=1;;
    --remove|-r)  REMOVE=1;;
    -h|--help)    usage; exit 0;;
    *)            die "Unknown argument: $1 (see --help)";;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Run as root (use sudo)."

if (( INSTALL == 0 && REMOVE == 0 )); then
  usage; exit 1
fi
if (( INSTALL == 1 && REMOVE == 1 )); then
  die "Choose either --install or --remove, not both."
fi

id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' not found."

# ----- Helpers -----
ensure_audio_group() {
  if ! getent group audio >/dev/null; then
    info "Creating 'audio' system group…"
    groupadd -r audio
  fi
  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx audio; then
    :
  else
    info "Adding '$TARGET_USER' to 'audio' group (re-login may be needed)…"
    usermod -aG audio "$TARGET_USER"
  fi
}

write_embedded_script() {
  info "Installing embedded watcher to $TARGET_SCRIPT…"
  install -m 0755 /dev/stdin "$TARGET_SCRIPT" <<'EMBEDDED'
#!/bin/bash
# Watches ALSA Capture and drives ASUS mic-mute LED

check_service_status() {
  spawnAmixerLogger() { stdbuf -oL amixer -n events | grep --line-buffered Capture; }
  getCurrentState()   { stdbuf -oL amixer get Capture | grep --line-buffered -Em 1 '\[o.+\]'; }

  spawnAmixerLogger | while read -r _; do
    state=$(getCurrentState)
    if echo "$state" | grep -q '\[on\]'; then
      if echo "$state" | grep -q '\[0%\]'; then
        echo 1 > /sys/devices/platform/asus-nb-wmi/leds/platform::micmute/brightness
      else
        echo 0 > /sys/devices/platform/asus-nb-wmi/leds/platform::micmute/brightness
      fi
    else
      echo 1 > /sys/devices/platform/asus-nb-wmi/leds/platform::micmute/brightness
    fi
  done
}

while true; do
  # Wait until amixer is available
  if ! command -v amixer >/dev/null 2>&1; then
    sleep 2
    continue
  fi

  check_service_status
  sleep 2
done
EMBEDDED
}

write_udev_rule() {
  info "Writing udev rule to $UDEV_RULE…"
  cat >"$UDEV_RULE" <<'UDEV'
SUBSYSTEM=="leds", KERNEL=="platform::micmute", ACTION=="add", \
  RUN+="/bin/sh -c 'chgrp audio /sys/class/leds/%k/brightness && chmod g+rw /sys/class/leds/%k/brightness'"
SUBSYSTEM=="leds", KERNEL=="platform::micmute", ACTION=="change", \
  RUN+="/bin/sh -c 'chgrp audio /sys/class/leds/%k/brightness && chmod g+rw /sys/class/leds/%k/brightness'"
UDEV
  udevadm control --reload
  udevadm trigger -s leds || true
}

user_home_dir() { getent passwd "$TARGET_USER" | cut -d: -f6; }
user_uid()      { id -u "$TARGET_USER"; }

ensure_user_manager_running() {
  # Start the per-user systemd manager (works even without GUI login, if lingering is enabled)
  systemctl start "user@$(user_uid).service" 2>/dev/null || true
}

user_systemctl() {
  # Talk to the user's --user instance; wire XDG/DBUS for root->user calls.
  local cmd="$*"
  local uid; uid=$(user_uid)
  su - "$TARGET_USER" -c \
    "XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus systemctl --user $cmd" \
    || systemctl --machine="${TARGET_USER}@" --user $cmd
}

create_user_unit() {
  local home; home="$(user_home_dir)"
  local unit_dir="$home/.config/systemd/user"
  local unit_path="$unit_dir/micmute-led.service"
  mkdir -p "$unit_dir"

  cat >"$unit_path" <<'UNIT'
[Unit]
Description=Sync ASUS Mic-Mute LED with ALSA Capture (user)
After=default.target

[Service]
Type=simple
# Wait until amixer works to avoid "Host is down"
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do amixer sget Capture >/dev/null 2>&1 && exit 0; sleep 1; done; echo "ALSA control not ready" >&2; exit 1'
ExecStart=/usr/local/bin/micmute-led.sh
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
UNIT

  chown -R "$TARGET_USER":"$TARGET_USER" "$home/.config"

  # Enable even if the user manager isn't reachable: pre-create wants symlink.
  mkdir -p "$unit_dir/default.target.wants"
  ln -sf "$unit_path" "$unit_dir/default.target.wants/micmute-led.service"
}

install_all() {
  command -v udevadm >/dev/null || die "udev is required"
  command -v systemctl >/dev/null || die "systemd is required"
  if ! command -v amixer >/dev/null; then
    info "Warning: 'amixer' not found. Install alsa-utils for this to work."
  fi

  ensure_audio_group
  write_embedded_script
  write_udev_rule

  # Allow user services to run headless and start the user manager
  loginctl enable-linger "$TARGET_USER" >/dev/null 2>&1 || true
  ensure_user_manager_running

  create_user_unit

  # Reload + start via user manager (best effort)
  if user_systemctl daemon-reload 2>/dev/null; then
    user_systemctl enable --now micmute-led.service || true
  fi

  info "Done. Check:"
  info "  systemctl --user status micmute-led.service   # as $TARGET_USER"
  info "  journalctl --user -u micmute-led.service -f   # as $TARGET_USER"
  info "LED node perms should be g+rw and group 'audio':"
  info "  ls -l $LED_CLASS_BRIGHTNESS"
}

remove_all() {
  local home; home="$(user_home_dir)"
  local unit_path="$home/.config/systemd/user/micmute-led.service"

  # Stop/disable user service (best effort)
  if user_systemctl stop micmute-led.service 2>/dev/null; then :; fi
  if user_systemctl disable micmute-led.service 2>/dev/null; then :; fi
  if user_systemctl daemon-reload 2>/dev/null; then :; fi

  # Remove unit + symlink
  rm -f "$unit_path"
  rm -f "$home/.config/systemd/user/default.target.wants/micmute-led.service" 2>/dev/null || true

  # Remove udev rule
  rm -f "$UDEV_RULE"
  udevadm control --reload
  udevadm trigger -s leds || true

  # Remove embedded watcher
  rm -f "$TARGET_SCRIPT"

  info "Removed user service, udev rule, and watcher."
}

# ----- Do the thing -----
if (( INSTALL == 1 )); then
  install_all
elif (( REMOVE == 1 )); then
  remove_all
fi
