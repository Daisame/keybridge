#!/usr/bin/with-contenv bash
# Keybridge: stream `getevent` from an Android TV over network ADB and fire
# Home Assistant events for the configured keys.
set -u

# Paths/URL can be overridden for local testing; in the add-on they are the defaults.
DATA="${KEYBRIDGE_DATA:-/data}"
OPTS="${DATA}/options.json"
API="${KEYBRIDGE_API:-http://supervisor/core/api/events}"
ERR=/tmp/adb.err

# ADB stores its RSA key under $HOME/.android. /data persists across restarts,
# so the TV only asks to authorise this add-on once. Keep the key private.
umask 077
export HOME="$DATA"
mkdir -p -m 700 "${DATA}/.android"

log() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
nap() { sleep "$1" & wait $!; }   # interruptible sleep, so SIGTERM is handled promptly

HOST=$(jq -r '.adb_host // ""' "$OPTS")
PORT=$(jq -r '.adb_port // 5555' "$OPTS")
EVENT=$(jq -r '.event_type // "adb_key"' "$OPTS")
FWD_REPEAT=$(jq -r '.forward_repeat // false' "$OPTS")

# Validate options again here (the add-on schema is the first line of defence).
if [[ ! "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  log "adb_host is not set or invalid. Set it in the add-on options and restart."
  exit 1
fi
if [[ ! "$PORT" =~ ^[0-9]{1,5}$ ]]; then
  log "adb_port is invalid."
  exit 1
fi
if [[ ! "$EVENT" =~ ^[a-z][a-z0-9_]{0,63}$ ]]; then
  log "event_type must be lowercase letters, digits and underscores (max 64)."
  exit 1
fi

# Allow-list of key names, looked up by exact match (no regex built from options).
declare -A ALLOW=()
while IFS= read -r k; do
  if [[ "$k" =~ ^[A-Za-z][A-Za-z0-9_]{0,63}$ ]]; then
    ALLOW["$k"]=1
  else
    log "ignoring invalid key name '${k}'"
  fi
done < <(jq -r '.keys[]?' "$OPTS")
if [ "${#ALLOW[@]}" -eq 0 ]; then
  log "no valid keys configured. Add at least one key (e.g. KEY_VOLUMEUP)."
  exit 1
fi

TARGET="${HOST}:${PORT}"

# Post an event to Home Assistant. The token goes in on stdin (curl -K -), so it
# never appears on a command line. Key down/up posts are retried briefly.
fire() { # fire <event_type> <json> [retry]
  local -a retry=()
  [ "${3:-}" = "retry" ] && retry=(--retry 2 --retry-delay 1 --retry-connrefused)
  local http
  http=$(printf 'header = "Authorization: Bearer %s"\n' "${SUPERVISOR_TOKEN:-}" | \
    curl -s --connect-timeout 1 -m 3 "${retry[@]}" -K - -o /dev/null -w '%{http_code}' \
      -X POST -H "Content-Type: application/json" --data-binary "$2" "${API}/$1") || http="curl-failed"
  case "$http" in
    2*) ;;
    *) log "warning: event $1 -> HTTP ${http}" ;;
  esac
}

# Status events are transitions, not a heartbeat: only fire when the status changes.
LAST_STATUS=""
status() {
  [ "$1" = "$LAST_STATUS" ] && return 0
  LAST_STATUS="$1"
  fire "${EVENT}_status" "{\"status\":\"$1\"}"
}

ADB_PID=""
WD=""
cleanup() {
  [ -n "$WD" ] && kill "$WD" 2>/dev/null
  [ -n "$ADB_PID" ] && kill "$ADB_PID" 2>/dev/null
  status disconnected
  exit 0
}
trap cleanup TERM INT

# Retry delay grows 10 -> 20 -> 40 -> 80 -> 120 s while the TV is unreachable,
# has not authorised our key, or the stream keeps dying. It resets after a
# healthy stream. Every connect attempt can raise an "Allow USB debugging?"
# prompt on the TV, so don't hammer it.
DELAY=10
backoff() {
  nap "$DELAY"
  DELAY=$(( DELAY * 2 ))
  [ "$DELAY" -gt 120 ] && DELAY=120
}

log "Target ${TARGET}, event type '${EVENT}', keys: ${!ALLOW[*]}, forward_repeat=${FWD_REPEAT}"

while true; do
  adb disconnect "$TARGET" >/dev/null 2>&1
  out=$(timeout 15 adb connect "$TARGET" 2>&1)
  state=$(timeout 10 adb -s "$TARGET" get-state 2>&1)
  if [ "$state" != "device" ]; then
    log "Not ready (${out} / ${state}). On first run, accept the 'Allow USB debugging?' prompt on the TV (tick 'Always allow'). Retrying in ${DELAY}s."
    status unavailable
    backoff
    continue
  fi

  # Prove we can read input events before declaring the link up.
  if ! timeout 10 adb -s "$TARGET" shell getevent -p </dev/null >/dev/null 2>"$ERR"; then
    log "Connected but cannot read input events: $(head -c 200 "$ERR" | tr '\n' ' ')Retrying in ${DELAY}s."
    status unavailable
    backoff
    continue
  fi

  log "Connected to ${TARGET}; streaming key events"
  status connected
  START=$SECONDS

  # `exec` inside the process substitution makes $! the PID of adb itself.
  exec 3< <(exec adb -s "$TARGET" shell getevent -l </dev/null 2>"$ERR")
  ADB_PID=$!

  # Heartbeat: if the link dies silently, kill the stream so we reconnect.
  # Two consecutive failures are required, to ride out a briefly busy TV.
  (
    fails=0
    while sleep 20; do
      if timeout 8 adb -s "$TARGET" shell true </dev/null >/dev/null 2>&1; then
        fails=0
      else
        fails=$(( fails + 1 ))
        log "Heartbeat failed (${fails}/2)"
        if [ "$fails" -ge 2 ]; then
          kill "$ADB_PID" 2>/dev/null
          exit 0
        fi
      fi
    done
  ) &
  WD=$!

  # getevent -l lines look like:
  #   /dev/input/event7: EV_KEY       KEY_VOLUMEUP         DOWN
  while read -r dev type code value _ <&3; do
    [ "$type" = "EV_KEY" ] || continue
    [[ "$dev" =~ ^/dev/input/event[0-9]+:$ ]] || continue
    [[ "$code" =~ ^[A-Za-z][A-Za-z0-9_]{0,63}$ ]] || continue
    [ -n "${ALLOW["$code"]+x}" ] || continue
    value="${value%$'\r'}"
    case "$value" in
      DOWN)   st="down" ;;
      UP)     st="up" ;;
      REPEAT) [ "$FWD_REPEAT" = "true" ] || continue
              st="repeat" ;;
      *) continue ;;
    esac
    log "key ${code} ${st}"
    body=$(jq -cn --arg k "$code" --arg s "$st" --arg d "${dev%:}" '{key:$k,state:$s,device:$d}')
    fire "$EVENT" "$body" retry
  done
  exec 3<&-

  kill "$WD" 2>/dev/null
  kill "$ADB_PID" 2>/dev/null
  wait "$WD" 2>/dev/null
  WD=""
  ADB_PID=""
  UP=$(( SECONDS - START ))
  status disconnected
  if [ "$UP" -ge 60 ]; then
    DELAY=10
    log "Stream ended after ${UP}s; reconnecting"
    nap 5
  else
    log "Stream ended after ${UP}s: $(head -c 200 "$ERR" | tr '\n' ' ')Retrying in ${DELAY}s."
    backoff
  fi
done
