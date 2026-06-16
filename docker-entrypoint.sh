#!/usr/bin/env sh
# Entrypoint for the roborev container.
#
# The roborev daemon requires a LOOPBACK bind (it rejects non-loopback
# addresses). To make it reachable from outside the container we run it on
# 127.0.0.1:${ROBOREV_INTERNAL_PORT} and bridge 0.0.0.0:${ROBOREV_PORT} -> that
# loopback port with socat. The daemon has no Host-header allowlist, so no extra
# config is needed for the bridge.
set -eu

: "${ROBOREV_DATA_DIR:=/data}"
: "${ROBOREV_PORT:=7373}"            # external port (socat listener; published)
: "${ROBOREV_INTERNAL_PORT:=7374}"  # loopback port the daemon binds
export ROBOREV_DATA_DIR

mkdir -p "${ROBOREV_DATA_DIR}"

socat "TCP-LISTEN:${ROBOREV_PORT},fork,bind=0.0.0.0,reuseaddr" "TCP:127.0.0.1:${ROBOREV_INTERNAL_PORT}" &
socat_pid=$!

roborev daemon run --addr "127.0.0.1:${ROBOREV_INTERNAL_PORT}" "$@" &
rr_pid=$!

terminate() { kill -TERM "${rr_pid}" "${socat_pid}" 2>/dev/null || true; }
trap terminate INT TERM

wait "${rr_pid}"
status=$?
kill -TERM "${socat_pid}" 2>/dev/null || true
wait "${socat_pid}" 2>/dev/null || true
exit "${status}"
