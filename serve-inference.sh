#!/usr/bin/env bash
# Serve llama.cpp on the LAN with an API key and origin-locked CORS.
# Upstream: https://github.com/ggml-org/llama.cpp
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/config.env"
fi

IFACE="${IFACE:-enp12s0}"
PORT="${PORT:-8080}"
MODEL_PRESET="${MODEL_PRESET:---vision-gemma-12b-default}"
CORS_ORIGINS="${CORS_ORIGINS:-localhost}"
LLAMA_BIN="${LLAMA_BIN:-/usr/bin/llama}"
CONFIG_DIR="${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/llama-lan}"
API_KEY_FILE="${API_KEY_FILE:-$CONFIG_DIR/api-keys}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/llama-lan}"
LOG_FILE="$STATE_DIR/server.log"
PID_FILE="$STATE_DIR/server.pid"
TLS_CERT="${TLS_CERT:-}"
TLS_KEY="${TLS_KEY:-}"
ENABLE_WEBUI="${ENABLE_WEBUI:-0}"
ENABLE_METRICS="${ENABLE_METRICS:-0}"
CURL_INSECURE="${CURL_INSECURE:-0}"

mkdir -p "$STATE_DIR"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

lan_ip() {
  local ip=""
  if [[ -n "$IFACE" ]]; then
    ip="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
  fi
  printf '%s' "$ip"
}

scheme() {
  if [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]]; then printf 'https'; else printf 'http'; fi
}

base_url() {
  printf '%s://%s:%s' "$(scheme)" "$(lan_ip)" "$PORT"
}

curl_opts() {
  CURL_OPTS=(-sS -m 5)
  if [[ "$CURL_INSECURE" == "1" ]]; then CURL_OPTS+=(-k); fi
}

first_key() { head -n1 "$API_KEY_FILE"; }

ensure_key() {
  local dir
  dir="$(dirname "$API_KEY_FILE")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  if [[ ! -s "$API_KEY_FILE" ]]; then
    openssl rand -hex 32 > "$API_KEY_FILE"
    note "generated API key -> $API_KEY_FILE"
  fi
  chmod 600 "$API_KEY_FILE"
}

port_in_use() {
  ss -ltn 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"
}

find_server_pid() {
  local p cmd
  for p in $(pgrep -x llama 2>/dev/null || true); do
    cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
    case "$cmd" in
      *" serve "*"--port $PORT "*) printf '%s\n' "$p"; return 0 ;;
    esac
  done
  return 1
}

pid_alive() { [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

rotate_log() {
  if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE") > 10485760 )); then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi
}

wait_healthy() {
  local ip="$1" timeout="${2:-120}" i
  curl_opts
  for ((i = 0; i < timeout; i++)); do
    if curl "${CURL_OPTS[@]}" -H "Authorization: Bearer $(first_key)" \
      "$(scheme)://$ip:$PORT/health" 2>/dev/null | grep -q '"ok"'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

cmd_start() {
  need ip
  need ss
  need curl
  need openssl
  if pid_alive; then
    note "already running (pid $(cat "$PID_FILE"))"
    return 0
  fi
  local ip
  ip="$(lan_ip)"
  [[ -n "$ip" ]] || die "no IPv4 address found on IFACE='$IFACE'; set IFACE in config.env"
  port_in_use && die "port $PORT is already in use"
  if pgrep -f 'llama cli' >/dev/null 2>&1; then
    die "interactive 'llama cli' is running and holds VRAM; exit it before starting the server"
  fi
  [[ -x "$LLAMA_BIN" ]] || die "not executable: $LLAMA_BIN"
  ensure_key
  rotate_log

  local args=(serve "$MODEL_PRESET"
    --host "$ip" --port "$PORT"
    --api-key-file "$API_KEY_FILE"
    --cors-origins "$CORS_ORIGINS"
    --no-cors-credentials)
  [[ "$ENABLE_WEBUI" == "1" ]] || args+=(--no-webui)
  [[ "$ENABLE_METRICS" == "1" ]] && args+=(--metrics)
  if [[ -n "$TLS_CERT" || -n "$TLS_KEY" ]]; then
    [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]] || die "set both TLS_CERT and TLS_KEY, or neither"
    [[ -r "$TLS_CERT" ]] || die "cannot read TLS_CERT: $TLS_CERT"
    [[ -r "$TLS_KEY" ]] || die "cannot read TLS_KEY: $TLS_KEY"
    args+=(--ssl-cert-file "$TLS_CERT" --ssl-key-file "$TLS_KEY")
  fi

  note "starting llama.cpp on $(scheme)://$ip:$PORT"
  note "  cors: $CORS_ORIGINS   model: $MODEL_PRESET"
  setsid --fork "$LLAMA_BIN" "${args[@]}" >>"$LOG_FILE" 2>&1 < /dev/null

  local pid="" i
  for ((i = 0; i < 50; i++)); do
    if pid="$(find_server_pid)"; then break; fi
    pid=""
    sleep 0.2
  done
  if [[ -z "$pid" ]]; then
    tail -n 30 "$LOG_FILE" >&2 || true
    die "server process did not appear; see $LOG_FILE"
  fi
  printf '%s\n' "$pid" > "$PID_FILE"

  if ! wait_healthy "$ip" 180; then
    tail -n 30 "$LOG_FILE" >&2 || true
    die "server did not become healthy; see $LOG_FILE"
  fi
  note "healthy (pid $pid)"
  note "base url: $(scheme)://$ip:$PORT/v1"
  note "api key:  $(first_key)"
}

cmd_stop() {
  local pid=""
  if [[ -f "$PID_FILE" ]]; then pid="$(cat "$PID_FILE")"; fi
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    pid="$(find_server_pid || true)"
  fi
  if [[ -z "$pid" ]]; then
    note "not running"
    rm -f "$PID_FILE"
    return 0
  fi
  note "stopping pid $pid..."
  if [[ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" == "$pid" ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
  local i
  for ((i = 0; i < 80; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$pid" 2>/dev/null; then
    note "force killing..."
    if [[ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" == "$pid" ]]; then
      kill -KILL -- "-$pid" 2>/dev/null || true
    else
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$PID_FILE"
  note "stopped"
}

cmd_status() {
  need curl
  local ip
  ip="$(lan_ip)"
  if pid_alive; then
    note "running (pid $(cat "$PID_FILE"))"
  else
    note "not running"
  fi
  note "bind: $(scheme)://${ip:-?}:$PORT"
  note "cors: $CORS_ORIGINS"
  note "key file: $API_KEY_FILE"
  [[ -s "$API_KEY_FILE" ]] || return 0
  if [[ -z "$ip" ]]; then return 0; fi
  curl_opts
  if curl "${CURL_OPTS[@]}" -H "Authorization: Bearer $(first_key)" \
    "$(scheme)://$ip:$PORT/health" 2>/dev/null | grep -q '"ok"'; then
    note "health: ok"
    curl "${CURL_OPTS[@]}" -H "Authorization: Bearer $(first_key)" \
      "$(scheme)://$ip:$PORT/v1/models" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    for m in d.get("data",[]): print("model:", m.get("id"))
except Exception: pass' || true
  else
    note "health: unavailable"
  fi
}

cmd_logs() {
  [[ -f "$LOG_FILE" ]] || die "no log file at $LOG_FILE"
  tail -n "${1:-100}" -f "$LOG_FILE"
}

cmd_rotate_key() {
  local was_running=0
  if pid_alive; then
    was_running=1
    cmd_stop
  fi
  ensure_key
  openssl rand -hex 32 > "$API_KEY_FILE"
  chmod 600 "$API_KEY_FILE"
  note "new api key: $(first_key)"
  if [[ "$was_running" == "1" ]]; then
    cmd_start
  else
    note "restart the server to apply the new key"
  fi
}

usage() {
  cat <<'EOF'
Usage: ./serve-inference.sh [command]

  start        start llama.cpp on the LAN (writes pid + log)
  stop         stop the server and its model router children
  restart      stop then start
  status       show bind address, health, and served models
  logs [N]     tail the server log (default 100 lines)
  key          print the API key clients must send
  rotate-key   generate a new key (restarts if running)

Config: copy config.example.env to config.env and edit.
EOF
}

case "${1:-status}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status) cmd_status ;;
  logs) cmd_logs "${2:-100}" ;;
  key) first_key; echo ;;
  rotate-key) cmd_rotate_key ;;
  -h | --help | help) usage ;;
  *) usage; exit 1 ;;
esac
