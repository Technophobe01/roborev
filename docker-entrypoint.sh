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

# resolve_backend_addr <pid>: print the daemon's published bound address read from
# its PID-keyed runtime metadata (so a stale daemon.<oldpid>.json is never used).
# Polls up to ROBOREV_RESOLVE_MAX_TRIES (x0.1s).
#   return 0: address printed
#   return 1: timed out without an address
#   return 2: the daemon pid is no longer alive
resolve_backend_addr() {
  _pid="$1"
  _tries="${ROBOREV_RESOLVE_MAX_TRIES:-600}"
  _target="${ROBOREV_DATA_DIR}/runtime/daemon.${_pid}.json"
  _n=0
  while [ "${_n}" -lt "${_tries}" ]; do
    kill -0 "${_pid}" 2>/dev/null || return 2
    if [ -f "${_target}" ]; then
      _addr="$(sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${_target}" | head -n1)"
      [ -n "${_addr}" ] && { printf '%s\n' "${_addr}"; return 0; }
    fi
    _n=$((_n + 1))
    sleep 0.1
  done
  return 1
}

# Test seam: resolve an address from existing runtime metadata and exit, without
# starting the daemon or socat. Used by docker_entrypoint_test.go.
if [ -n "${ROBOREV_RESOLVE_ONLY:-}" ]; then
  resolve_backend_addr "${ROBOREV_RESOLVE_PID:-0}"
  exit $?
fi

mkdir -p "${ROBOREV_DATA_DIR}/runtime"

# Clear stale runtime metadata from a previous ungraceful run: /data persists and
# PIDs can be reused, so a leftover daemon.<pid>.json could be misread as current.
rm -f "${ROBOREV_DATA_DIR}"/runtime/daemon.*.json 2>/dev/null || true

# `roborev daemon run` runs in the FOREGROUND, so rr_pid IS the daemon's own pid
# and it publishes runtime/daemon.<rr_pid>.json keyed by that same pid — which is
# what resolve_backend_addr looks up below. If daemon run is ever changed to
# fork/daemonize, that lookup would target the wrong pid and time out; keep it
# foreground (or teach the resolver the child's pid).
roborev daemon run --addr "127.0.0.1:${ROBOREV_INTERNAL_PORT}" "$@" &
rr_pid=$!

# Install the cleanup trap BEFORE the (up to ~70s) address-resolve + readiness
# probe. This entrypoint is PID 1, where an untrapped SIGTERM is ignored — so
# without an early trap a `docker stop` during startup stalls until the grace
# period SIGKILLs everything (no clean daemon shutdown). socat_pid is empty until
# the bridge starts; ${socat_pid:+...} keeps kill from erroring on the empty value.
socat_pid=""
terminate() { kill -TERM "${rr_pid}" ${socat_pid:+"${socat_pid}"} 2>/dev/null || true; }
trap terminate INT TERM

die_with_daemon() { echo "roborev: $1" >&2; set +e; wait "${rr_pid}" 2>/dev/null; exit "${2:-1}"; }

# Discover the actual bound address (never guess).
rc=0
backend_addr="$(resolve_backend_addr "${rr_pid}")" || rc=$?
if [ "${rc}" -ne 0 ]; then
  if [ "${rc}" -eq 2 ]; then
    die_with_daemon "daemon exited before publishing its address" 1
  fi
  kill -TERM "${rr_pid}" 2>/dev/null || true
  die_with_daemon "daemon did not publish an address in time; aborting" 1
fi

# Probe the backend before committing socat to it.
j=0
until curl -fsS -o /dev/null "http://${backend_addr}/api/ping" 2>/dev/null; do
  kill -0 "${rr_pid}" 2>/dev/null || die_with_daemon "daemon exited during readiness probe" "$?"
  j=$((j + 1))
  [ "${j}" -ge 100 ] && { kill -TERM "${rr_pid}" 2>/dev/null || true; die_with_daemon "backend ${backend_addr} not ready; aborting" 1; }
  sleep 0.1
done

echo "roborev: bridging 0.0.0.0:${ROBOREV_PORT} -> ${backend_addr}" >&2
socat "TCP-LISTEN:${ROBOREV_PORT},fork,bind=0.0.0.0,reuseaddr" "TCP:${backend_addr}" &
socat_pid=$!   # terminate() (trapped above) now tears down socat too.

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
