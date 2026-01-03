#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:-freepbx-test:local}"
NAME="${SMOKE_CONTAINER_NAME:-freepbx-smoke}"
PORT="${SMOKE_PORT:-8080}"
TIMEOUT_SECS="${SMOKE_TIMEOUT_SECS:-10}"
LOG_TAIL_LINES="${SMOKE_LOG_TAIL_LINES:-250}"

say() { printf '[smoke] %s\n' "$*"; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}

fail_dump() {
  say "--- docker inspect (state/health) ---"
  docker inspect "$NAME" 2>/dev/null | sed -n '1,200p' || true

  say "--- docker logs (tail ${LOG_TAIL_LINES}) ---"
  docker logs --tail "${LOG_TAIL_LINES}" "$NAME" 2>/dev/null | cat || true

  say "--- apachectl -M (MPM check) ---"
  docker exec "$NAME" bash -lc 'apachectl -M 2>&1 | cat || true' || true

  say "--- apache mods-enabled listing ---"
  docker exec "$NAME" bash -lc 'ls -la /etc/apache2/mods-enabled 2>/dev/null | cat || true' || true

  say "--- apache configtest + includes dump ---"
  docker exec "$NAME" bash -lc 'apache2ctl configtest 2>&1 | cat || true; apache2ctl -V 2>&1 | cat || true; apachectl -t -D DUMP_RUN_CFG 2>&1 | cat || true; apachectl -t -D DUMP_INCLUDES 2>&1 | cat || true' || true

  say "--- apache: show loadmodule mpm_* occurrences ---"
  docker exec "$NAME" bash -lc 'grep -R "^[[:space:]]*LoadModule[[:space:]]\+mpm_" -n /etc/apache2 2>/dev/null | head -n 50 | cat || true' || true

  say "--- apache: check modules dir contains mpm so files ---"
  docker exec "$NAME" bash -lc 'ls -la /usr/lib/apache2/modules/mod_mpm_*.so 2>/dev/null | cat || true' || true

  say "--- apache: try configtest with hard fallback conf (if present) ---"
  docker exec "$NAME" bash -lc 'if [ -f /etc/apache2/apache2-ha-min.conf ]; then apache2ctl -t -f /etc/apache2/apache2-ha-min.conf 2>&1 | cat || true; apachectl -M -f /etc/apache2/apache2-ha-min.conf 2>&1 | cat || true; else echo "no /etc/apache2/apache2-ha-min.conf"; fi' || true

  say "--- http check (best-effort) ---"
  curl -v --max-time 5 "http://127.0.0.1:${PORT}/" 2>&1 | tail -n 60 | cat || true
}

wait_ready() {
  local start now elapsed status health
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    elapsed=$(( now - start ))
    if (( elapsed > TIMEOUT_SECS )); then
      say "TIMEOUT after ${TIMEOUT_SECS}s"
      return 1
    fi

    status="$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo 'unknown')"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME" 2>/dev/null || echo 'unknown')"
    say "status=${status} health=${health} elapsed=${elapsed}s"

    # If container exited, bail fast.
    if [[ "$status" != "running" ]]; then
      return 1
    fi

    # Prefer Docker health if present.
    if [[ "$health" == "healthy" ]]; then
      return 0
    fi

    # Fallback: if no healthcheck, probe HTTP.
    if [[ "$health" == "none" ]]; then
      if curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/" >/dev/null; then
        return 0
      fi
    fi

    sleep 1
  done
}

main() {
  say "cleanup old container: ${NAME}"
  cleanup

  say "run container: ${NAME} (port ${PORT}:80) image=${IMAGE}"
  docker run -d --name "$NAME" -p "${PORT}:80" "$IMAGE" >/dev/null

  if ! wait_ready; then
    say "FAILED: service not ready"
    fail_dump
    cleanup
    exit 1
  fi

  say "OK: ready"
  say "--- http check ---"
  curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/" >/dev/null || true

  say "done"
  cleanup
}

main "$@"
