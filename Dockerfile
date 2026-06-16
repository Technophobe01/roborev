# syntax=docker/dockerfile:1
#
# Production image for the roborev code-review daemon.
#
# Intended for CENTRAL use: a PostgreSQL sync hub and/or CI-poller that reviews
# GitHub PRs server-side. Commit-time reviews are driven by git post-commit hooks
# and belong on each workstation, not here.
#
# NOTE: actually running reviews requires the agent CLIs (codex, claude-code,
# gemini, ...) on PATH plus their API keys. This base image ships only the
# roborev binary + git; add agents via a derived image or a sidecar. The daemon,
# its HTTP API, and the CI poller run without them (reviews will fail until an
# agent is available).
#
# Build:  docker build -t ghcr.io/kenn-io/roborev:latest .
# Run:    docker run -p 7373:7373 -v roborev-data:/data ghcr.io/kenn-io/roborev:latest

# ---- Stage 1: Go build ------------------------------------------------------
FROM golang:1.26.3-bookworm AS build
WORKDIR /src

ARG VERSION=docker

COPY go.mod go.sum ./
RUN go mod download
COPY . .

# Pure Go (modernc.org/sqlite) — no CGO. -buildvcs=false so a missing .git is fine.
RUN CGO_ENABLED=0 go build -trimpath -buildvcs=false \
      -ldflags "-s -w -X go.kenn.io/roborev/internal/version.Version=${VERSION}" \
      -o /out/roborev ./cmd/roborev

# ---- Stage 2: runtime -------------------------------------------------------
FROM debian:bookworm-slim
# git: roborev shells out to git for diffs/worktrees.
# socat: bridges 0.0.0.0:<port> -> the daemon's loopback listener (it requires
#        a loopback bind). curl: healthcheck.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git socat \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/roborev /usr/local/bin/roborev
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Run as a non-root user; the named /data volume inherits this ownership.
RUN useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin roborev \
 && mkdir -p /data && chown roborev:roborev /data
USER roborev

# SECURITY: roborev's daemon API is UNAUTHENTICATED (it assumes a loopback,
# single-user trust model). Exposing it over the network — including
# /api/shutdown, /api/enqueue, and review-content reads — must be gated by a
# trusted/private network, Tailscale ACLs, or an authenticating proxy. Prefer
# publishing to host loopback, e.g. `-p 127.0.0.1:7373:7373`.
#
# DB, config, and runtime metadata live under ROBOREV_DATA_DIR on the volume.
# ROBOREV_PORT is the external (socat) port; the daemon binds
# ROBOREV_INTERNAL_PORT on loopback inside the container.
ENV ROBOREV_DATA_DIR=/data
ENV ROBOREV_PORT=7373
ENV ROBOREV_INTERNAL_PORT=7374
EXPOSE 7373
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=5 \
  CMD curl -fsS "http://127.0.0.1:${ROBOREV_PORT:-7373}/api/ping" || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
