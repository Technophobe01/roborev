#!/usr/bin/env sh
# Entrypoint for the roborev container.
#
# The roborev daemon requires a LOOPBACK bind (it rejects non-loopback
# addresses). To make it reachable from outside the container we run it on a
# loopback port and bridge 0.0.0.0:${ROBOREV_PORT} to it with socat.
#
# The daemon may pick a different port than requested (it runs FindAvailablePort
# even with an explicit --addr), so we read the actual bound address from its
# runtime metadata before pointing socat at it. We key on the daemon's PID so a
# stale daemon.<oldpid>.json left on the persisted volume is never picked up.
set -eu

: "${ROBOREV_DATA_DIR:=/data}"
: "${ROBOREV_PORT:=7373}"            # external port (socat listener; published)
: "${ROBOREV_INTERNAL_PORT:=7374}"  # preferred loopback port for the daemon
export ROBOREV_DATA_DIR

mkdir -p "${ROBOREV_DATA_DIR}/runtime"

roborev daemon run --addr "127.0.0.1:${ROBOREV_INTERNAL_PORT}" "$@" &
rr_pid=$!

# Wait for THIS daemon (by pid) to publish its actual bound address.
target="${ROBOREV_DATA_DIR}/runtime/daemon.${rr_pid}.json"
backend_addr=""
i=0
while [ "$i" -lt 100 ]; do
  if ! kill -0 "${rr_pid}" 2>/dev/null; then
    echo "roborev: daemon exited before publishing its address" >&2
    set +e; wait "${rr_pid}"; exit $?
  fi
  if [ -f "${target}" ]; then
    backend_addr="$(sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${target}" | head -n1)"
    [ -n "${backend_addr}" ] && break
  fi
  i=$((i + 1))
  sleep 0.1
done
[ -n "${backend_addr}" ] || backend_addr="127.0.0.1:${ROBOREV_INTERNAL_PORT}"
echo "roborev: bridging 0.0.0.0:${ROBOREV_PORT} -> ${backend_addr}" >&2

socat "TCP-LISTEN:${ROBOREV_PORT},fork,bind=0.0.0.0,reuseaddr" "TCP:${backend_addr}" &
socat_pid=$!

terminate() { kill -TERM "${rr_pid}" "${socat_pid}" 2>/dev/null || true; }
trap terminate INT TERM

# Supervise BOTH processes: if either the daemon or the proxy dies, tear the
# other down and exit non-zero so the container's restart policy recovers it.
while kill -0 "${rr_pid}" 2>/dev/null && kill -0 "${socat_pid}" 2>/dev/null; do
  sleep 2
done

if kill -0 "${rr_pid}" 2>/dev/null; then
  echo "roborev: socat proxy exited; stopping daemon" >&2
  kill -TERM "${rr_pid}" 2>/dev/null || true
  set +e; wait "${rr_pid}" 2>/dev/null; set -e
  exit 1
fi

# Daemon exited: capture its status, stop the proxy, propagate the status.
set +e
wait "${rr_pid}"
status=$?
set -e
kill -TERM "${socat_pid}" 2>/dev/null || true
wait "${socat_pid}" 2>/dev/null || true
exit "${status}"
