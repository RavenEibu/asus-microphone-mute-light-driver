#!/usr/bin/env bash
# Stub-based tests for the watcher embedded in asus-micmute-installer.sh.
# No audio server, ALSA device or LED hardware needed: pactl/amixer are replaced by
# stubs and the LED is a plain file. Usage: bash tests/run.sh
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
PASS=0; FAIL=0

cleanup() { pkill -f "$T/" 2>/dev/null; exec 8>&- 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# --- fixtures ---------------------------------------------------------------
awk "/<<'EMBEDDED'/{f=1;next} /^EMBEDDED\$/{f=0} f" "$ROOT/asus-micmute-installer.sh" > "$T/watcher.sh"
mkdir -p "$T/bin"

# pactl stub: state lives in $STUB/{mute,vol}; `subscribe` streams the $STUB/events fifo.
cat > "$T/bin/pactl" <<'STUB'
#!/usr/bin/env bash
case $1 in
  subscribe)        echo launch >> "$STUB/launches"; exec cat "$STUB/events" ;;
  info)             exit 0 ;;
  get-source-mute)  echo "Mute: $(cat "$STUB/mute")" ;;
  get-source-volume) v=$(cat "$STUB/vol")
                     echo "Volume: front-left: 1 / ${v}% / 0.00 dB,   front-right: 1 / ${v}% / 0.00 dB" ;;
  *) exit 1 ;;
esac
STUB
# amixer stub: same state; `-n events` streams the fifo, or spins when $STUB/spin exists.
cat > "$T/bin/amixer" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == get ]]; then
  [[ $(cat "$STUB/mute") == yes ]] && sw=off || sw=on
  echo "  Front Left: Capture 1 [$(cat "$STUB/vol")%] [$sw]"; exit 0
fi
echo launch >> "$STUB/launches"
if [[ -e $STUB/spin ]]; then while :; do :; done; fi
exec cat "$STUB/events"
STUB
chmod +x "$T/bin/pactl" "$T/bin/amixer"
mkfifo "$T/events"

# --- helpers ----------------------------------------------------------------
led()      { cat "$T/led" 2>/dev/null; }
set_state(){ echo "$1" > "$T/mute"; echo "$2" > "$T/vol"; }          # mute(yes|no) vol(%)
event()    { echo "$1" >&8; }
launches() { wc -l < "$T/launches" 2>/dev/null || echo 0; }
launches_ge(){ (( $(launches) >= $1 )); }
launches_is(){ (( $(launches) == $1 )); }
file_is()    { [[ $(cat "$1" 2>/dev/null) == "$2" ]]; }

wait_for() {  # wait_for <timeout_s> <command...> : poll until the command succeeds
  local deadline=$(( SECONDS + $1 )); shift
  while (( SECONDS < deadline )); do "$@" && return 0; sleep 0.1; done
  "$@"
}
led_is()   { [[ $(led) == "$1" ]]; }

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

start() {  # start [ENV=VAL ...] : fresh watcher with a fresh fifo writer
  : > "$T/launches"; : > "$T/err"; : > "$T/led"   # sysfs node always exists
  exec 8<>"$T/events"
  env PATH="$T/bin:$PATH" STUB="$T" MICMUTE_LED="$T/led" MICMUTE_LED_RETRY=1 \
      WATCHDOG_INTERVAL=1 WATCHDOG_MAX_PCT=50 WATCHDOG_STRIKES=2 "$@" \
      bash "$T/watcher.sh" 2>"$T/err" 8>&- &
  WPID=$!
}
stop() { kill "$WPID" 2>/dev/null; pkill -f "$T/" 2>/dev/null; wait "$WPID" 2>/dev/null; exec 8>&-; }

# --- tests ------------------------------------------------------------------
echo "static"
check "bash -n watcher" bash -n "$T/watcher.sh"

echo "pactl backend: LED = muted OR volume 0%"
set_state yes 100; start MICMUTE_BACKEND=pactl
check "initial sync (muted -> 1)"            wait_for 5 led_is 1
set_state no 100;  event "Event 'change' on source #1"
check "unmuted, 100% -> 0"                   wait_for 5 led_is 0
set_state yes 100; event "Event 'change' on source #1"
check "muted, 100% -> 1"                     wait_for 5 led_is 1
set_state no 100;  event "Event 'change' on source #1"
wait_for 5 led_is 0                          # start from LED off so the 0% rule is really exercised
set_state no 0;    event "Event 'change' on source #1"
check "unmuted, 0% -> 1"                     wait_for 5 led_is 1
set_state yes 0;   event "Event 'change' on source #1"
check "muted + 0% -> 1"                      wait_for 5 led_is 1
set_state no 40;   event "Event 'change' on server"
check "default source change, 40% -> 0"      wait_for 5 led_is 0
set_state yes 40;  event "Event 'new' on client #7"; event "Event 'remove' on source-output #3"; sleep 1
check "unrelated events are ignored"         led_is 0
stop

echo "pactl backend: recovery when the sound server goes away"
set_state no 100; start MICMUTE_BACKEND=pactl
wait_for 5 led_is 0
exec 8>&-                       # writer closes -> `pactl subscribe` hits EOF and exits
set_state yes 100               # state changes while the listener is down
exec 8<>"$T/events"
check "listener relaunched and LED resynced" wait_for 8 led_is 1
set_state no 100; event "Event 'change' on source #1"
check "events work after recovery"           wait_for 5 led_is 0
check "listener was relaunched (>=2 launches)" launches_ge 2
check "watchdog stayed quiet"                bash -c "! grep -q spinning '$T/err'"
stop

echo "amixer backend (fallback)"
set_state yes 100; start MICMUTE_BACKEND=amixer
check "initial sync (muted -> 1)"            wait_for 5 led_is 1
set_state no 100;  event "numid=1,iface=MIXER,name='Capture Switch'"
check "unmuted -> 0"                         wait_for 5 led_is 0
set_state no 0;    event "numid=2,iface=MIXER,name='Capture Volume'"
check "0% -> 1"                              wait_for 5 led_is 1
stop

echo "watchdog"
rm -f "$T/spin"; set_state no 100; start MICMUTE_BACKEND=amixer
wait_for 5 led_is 0; sleep 4
check "healthy listener is not killed"       launches_is 1
stop
: > "$T/spin"; set_state no 100; start MICMUTE_BACKEND=amixer
check "spinning listener is killed and relaunched" wait_for 15 launches_ge 2
check "watchdog logged it"                   grep -q spinning "$T/err"
stop

echo "LED not writable"
set_state yes 100; start MICMUTE_BACKEND=pactl MICMUTE_LED="$T/nodir/led"
check "warning logged"                       wait_for 5 grep -q "cannot write LED node" "$T/err"
sleep 3
check "warning logged only once"             test "$(grep -c 'cannot write LED node' "$T/err")" -eq 1
mkdir -p "$T/nodir"; : > "$T/nodir/led"
check "recovers once the LED is writable"    wait_for 8 file_is "$T/nodir/led" 1
stop

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
