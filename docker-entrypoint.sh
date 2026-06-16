#!/usr/bin/env sh
# Entrypoint for the roborev container.
#
# The roborev daemon requires a LOOPBACK bind (it rejects non-loopback
# addresses). To make it reachable from outside the container we run it on a
# loopback port and bridge 0.0.0.0:${ROBOREV_PORT} to it with socat.
#
# The daemon may pick a different port than requested (it runs FindAvailablePort
# even with an explicit --addr), so we read the ACTUAL bound address from its
# runtime metadata (keyed by PID), probe it, and only then start socat. We never
# guess the address; if the daemon never readies we fail so the restart policy
# can retry.
set -eu

: "${ROBOREV_DATA_DIR:=/data}"
: "${ROBOREV_PORT:=7373}"            # external port (socat listener; published)
: "${ROBOREV_INTERNAL_PORT:=7374}"  # preferred loopback port for the daemon
export ROBOREV_DATA_DIR

mkdir -p "${ROBOREV_DATA_DIR}/runtime"

# Clear stale runtime metadata from a previous ungraceful run: /data persists and
# PIDs can be reused, so a leftover daemon.<pid>.json could be misread as current.
rm -f "${ROBOREV_DATA_DIR}"/runtime/daemon.*.json 2>/dev/null || true

roborev daemon run --addr "127.0.0.1:${ROBOREV_INTERNAL_PORT}" "$@" &
rr_pid=$!

die_with_daemon() { echo "roborev: $1" >&2; set +e; wait "${rr_pid}" 2>/dev/null; exit "${2:-1}"; }

# Wait for THIS daemon (by pid) to publish its actual bound address. Keep waiting
# while it is alive; abort if it dies or never readies within the cap (~60s).
target="${ROBOREV_DATA_DIR}/runtime/daemon.${rr_pid}.json"
backend_addr=""
i=0
while [ "$i" -lt 600 ]; do
  kill -0 "${rr_pid}" 2>/dev/null || die_with_daemon "daemon exited before publishing its address" "$?"
  if [ -f "${target}" ]; then
    backend_addr="$(sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${target}" | head -n1)"
    [ -n "${backend_addr}" ] && break
  fi
  i=$((i + 1)); sleep 0.1
done
[ -n "${backend_addr}" ] || { kill -TERM "${rr_pid}" 2>/dev/null || true; die_with_daemon "daemon did not publish an address in time; aborting" 1; }

# Probe the backend before committing socat to it.
j=0
until curl -fsS -o /dev/null "http://${backend_addr}/api/ping" 2>/dev/null; do
  kill -0 "${rr_pid}" 2>/dev/null || die_with_daemon "daemon exited during readiness probe" "$?"
  j=$((j + 1)); [ "$j" -ge 100 ] && { kill -TERM "${rr_pid}" 2>/dev/null || true; die_with_daemon "backend ${backend_addr} not ready; aborting" 1; }
  sleep 0.1
done

echo "roborev: bridging 0.0.0.0:${ROBOREV_PORT} -> ${backend_addr}" >&2
socat "TCP-LISTEN:${ROBOREV_PORT},fork,bind=0.0.0.0,reuseaddr" "TCP:${backend_addr}" &
socat_pid=$!

terminate() { kill -TERM "${rr_pid}" "${socat_pid}" 2>/dev/null || true; }
trap terminate INT TERM

# Supervise BOTH: if either the daemon or the proxy dies, stop the other and exit
# non-zero so the container's restart policy recovers it.
while kill -0 "${rr_pid}" 2>/dev/null && kill -0 "${socat_pid}" 2>/dev/null; do
  sleep 2
done

if kill -0 "${rr_pid}" 2>/dev/null; then
  echo "roborev: socat proxy exited; stopping daemon" >&2
  kill -TERM "${rr_pid}" 2>/dev/null || true
  set +e; wait "${rr_pid}" 2>/dev/null; set -e
  exit 1
fi

set +e
wait "${rr_pid}"
status=$?
set -e
kill -TERM "${socat_pid}" 2>/dev/null || true
wait "${socat_pid}" 2>/dev/null || true
exit "${status}"
