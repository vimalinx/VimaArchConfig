#!/usr/bin/env bash
set -euo pipefail

QS_LOG_RULES='*.info=false;*.debug=false'
IPC_ATTEMPTS=40
IPC_INTERVAL=0.1

start_qs() {
  if qs list 2>/dev/null | grep -q '^Instance '; then
    return 0
  fi
  # A just-stopped instance can briefly leave launch state behind. The bounded
  # IPC loop below retries startup and still fails if the endpoint never loads.
  qs --daemonize --log-rules "$QS_LOG_RULES" || true
}

call_ipc() {
  local target="$1"
  local method="$2"
  local startup_method="${3:-$method}"
  local attempt=0

  if qs ipc call "$target" "$method" >/dev/null 2>&1; then
    return 0
  fi
  start_qs
  while (( attempt < IPC_ATTEMPTS )); do
    if qs ipc call "$target" "$startup_method" >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt % 5 == 4 )); then
      start_qs
    fi
    attempt=$((attempt + 1))
    sleep "$IPC_INTERVAL"
  done
  echo "quickshell IPC endpoint did not become ready: ${target}.${startup_method}" >&2
  return 1
}

close_ipc() {
  qs ipc call "$1" close >/dev/null 2>&1 || true
}

case "${1:-}" in
  action-open) call_ipc actionDesk open ;;
  action-toggle) call_ipc actionDesk toggle open ;;
  action-close) close_ipc actionDesk ;;
  status-open) call_ipc statusPanel open ;;
  status-toggle) call_ipc statusPanel toggle open ;;
  status-close) close_ipc statusPanel ;;
  # Compatibility aliases: open the terminal tab inside the unified Action Desk.
  terminals-open) call_ipc actionDesk openTerminals ;;
  terminals-toggle) call_ipc actionDesk toggleTerminals openTerminals ;;
  terminals-close) close_ipc actionDesk ;;
  overview-toggle) call_ipc overview toggle open ;;
  overview-open) call_ipc overview open ;;
  quit)
    delay_ms="${2:-2200}"
    sleep "$(awk "BEGIN { printf \"%.3f\", $delay_ms / 1000 }")"
    # A different surface may have reopened while this delayed quit was
    # sleeping. Recheck shared UI state so an old close cannot kill new work.
    idle_state="$(qs ipc call actionDesk shellIdle 2>/dev/null || true)"
    if [[ "$idle_state" == "true" ]]; then
      qs kill 2>/dev/null || true
    fi
    ;;
  *)
    echo "usage: $0 {action-open|action-toggle|action-close|status-open|status-toggle|status-close|terminals-open|terminals-toggle|terminals-close|overview-toggle|overview-open|quit [delay_ms]}" >&2
    exit 2
    ;;
esac
