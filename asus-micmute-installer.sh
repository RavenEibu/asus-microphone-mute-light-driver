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
# Watches the default capture source and drives the ASUS mic-mute LED.
#   LED ON  : microphone muted, or volume at 0%
#   LED OFF : microphone live (unmuted and volume > 0%)
#
# Backends (auto-detected, override with MICMUTE_BACKEND=pactl|amixer):
#   pactl  : event-driven via `pactl subscribe` (PipeWire/PulseAudio). Idle cost ~0
#            and it exits cleanly when the sound server goes away.
#   amixer : fallback via `amixer -n events` (ALSA only, no pactl needed).

export LC_ALL=C
# Tunables (environment): MICMUTE_BACKEND, MICMUTE_LED, MICMUTE_LED_RETRY, WATCHDOG_*
LED=${MICMUTE_LED:-/sys/devices/platform/asus-nb-wmi/leds/platform::micmute/brightness}
LED_RETRY=${MICMUTE_LED_RETRY:-10}   # seconds between checks while the LED node is missing/unwritable
LED_WARNED=0

if [[ -z ${MICMUTE_BACKEND:-} ]]; then
  if command -v pactl >/dev/null 2>&1; then MICMUTE_BACKEND=pactl; else MICMUTE_BACKEND=amixer; fi
fi

# Safety net: a long-lived event listener can lose its server connection (e.g. after a
# PipeWire restart) and spin at 100% CPU instead of exiting. Kill it when it stays busy so
# the main loop respawns a healthy one.
WATCHDOG_INTERVAL=${WATCHDOG_INTERVAL:-3}    # seconds between CPU samples
WATCHDOG_MAX_PCT=${WATCHDOG_MAX_PCT:-50}     # % of one core considered "spinning"
WATCHDOG_STRIKES=${WATCHDOG_STRIKES:-2}      # consecutive hot samples before kill

# utime+stime (clock ticks) of a pid, from /proc/<pid>/stat
cpu_ticks() {
  local stat rest f
  stat=$(<"/proc/$1/stat") || return 1
  rest=${stat##*) }          # strip "pid (comm) " -> fields start at 3 (state)
  read -ra f <<<"$rest"
  printf '%s\n' $(( f[11] + f[12] ))
}

watchdog() {
  local pid=$1 hz limit prev cur strikes=0
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  limit=$(( WATCHDOG_MAX_PCT * hz * WATCHDOG_INTERVAL / 100 ))
  prev=$(cpu_ticks "$pid") || return 0
  while sleep "$WATCHDOG_INTERVAL"; do
    cur=$(cpu_ticks "$pid") || return 0          # process already gone
    if (( cur - prev > limit )); then strikes=$(( strikes + 1 )); else strikes=0; fi
    prev=$cur
    if (( strikes >= WATCHDOG_STRIKES )); then
      echo "event listener (pid $pid) is spinning; restarting it" >&2
      kill "$pid" 2>/dev/null
      return 0
    fi
  done
}

# ---- backends ---------------------------------------------------------------

# Event stream; run via `exec` in a subshell so $! is the listener's pid.
event_stream() {
  if [[ $MICMUTE_BACKEND == pactl ]]; then
    exec pactl subscribe
  else
    exec stdbuf -oL amixer -n events
  fi
}

# Is this event line worth a LED refresh?
is_relevant() {
  if [[ $MICMUTE_BACKEND == pactl ]]; then
    [[ $1 == *" on source #"* || $1 == *" on server"* ]]   # source change / default source change
  else
    [[ $1 == *Capture* ]]
  fi
}

# Sets the LED: 1 when muted or 0%, 0 when live.
updateLed() {
  if [[ $MICMUTE_BACKEND == pactl ]]; then
    local mute vol pct
    mute=$(pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null) || return 0
    vol=$(pactl get-source-volume @DEFAULT_SOURCE@ 2>/dev/null) || return 0
    [[ $vol =~ ([0-9]+)% ]] || return 0
    pct=${BASH_REMATCH[1]}
    if [[ $mute == *yes* || $pct -eq 0 ]]; then echo 1 > "$LED"; else echo 0 > "$LED"; fi
  else
    local state
    state=$(amixer get Capture 2>/dev/null | grep -Em 1 '\[o.+\]' || true)
    if grep -q '\[on\]' <<<"$state" && ! grep -q '\[0%\]' <<<"$state"; then
      echo 0 > "$LED"
    else
      echo 1 > "$LED"
    fi
  fi
}

# True when the LED node can be written. Logs once per outage, so a missing or
# unwritable LED shows up in `systemctl status` / journalctl instead of failing silently.
led_ready() {
  if [[ -w $LED ]]; then LED_WARNED=0; return 0; fi
  if (( LED_WARNED == 0 )); then
    echo "cannot write LED node $LED (missing or no permission): is asus-nb-wmi loaded and the udev rule applied? retrying every ${LED_RETRY}s" >&2
    LED_WARNED=1
  fi
  return 1
}

check_service_status() {
  local line pid wd efd
  # `exec` inside <(...) keeps $! == the listener pid, so the watchdog can kill it.
  exec {efd}< <(event_stream 2>/dev/null)
  pid=$!

  updateLed            # sync once on (re)start; events only fire on changes
  watchdog "$pid" &
  wd=$!

  while read -r -u "$efd" line; do
    is_relevant "$line" || continue
    while read -r -t 0.2 -u "$efd" _; do :; done   # coalesce bursts of events
    updateLed
  done

  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  exec {efd}<&-
}

while true; do
  # Wait until the backend tool is available
  if ! command -v "$MICMUTE_BACKEND" >/dev/null 2>&1; then
    sleep 2
    continue
  fi

  # Don't listen (and don't look healthy) while the LED can't be driven
  if ! led_ready; then
    sleep "$LED_RETRY"
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
# Wait until the audio server answers (pactl, or amixer as fallback) to avoid "Host is down"
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do { pactl info >/dev/null 2>&1 || amixer sget Capture >/dev/null 2>&1; } && exit 0; sleep 1; done; echo "Audio server not ready" >&2; exit 1'
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
  if ! command -v pactl >/dev/null && ! command -v amixer >/dev/null; then
    info "Warning: neither 'pactl' nor 'amixer' found. Install libpulse (pactl) or alsa-utils."
  fi

  if [[ ! -e "$LED_CLASS_BRIGHTNESS" ]]; then
    info "Warning: $LED_CLASS_BRIGHTNESS not found. This model may not expose the mic-mute LED"
    info "         via asus-nb-wmi (see: ls /sys/class/leds). The service will keep retrying and log a warning."
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
