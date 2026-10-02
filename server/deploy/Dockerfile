# syntax=docker/dockerfile:1.7
#
# The Karmashala server in a container. Build from the repository root:
#
#   docker build -f server/deploy/Dockerfile -t karmashala-server .
#
# Multi-stage. The build stage runs on the builder's own platform and builds
# for the target's, exactly as the release does (`dart build cli
# --target-os=linux --target-arch=…`, .github/workflows/release-build.yml):
# the server is a member of the repository's pub workspace, so resolving it needs the
# Flutter SDK even though the host itself uses no Flutter. The runtime stage is
# a slim Debian with the bundle — bin/ and lib/ side by side, never flattened
# (the binary loads its bundled SQLite from ../lib) — proven there with
# probe-store and probe-pty before the image is done.
#
# The agent CLIs (Claude Code, Codex) are NOT in this image: install them in an
# image built FROM this one and sign in inside the container — see
# server/README.md, "Docker".

FROM --platform=$BUILDPLATFORM ghcr.io/cirruslabs/flutter:stable AS build
ARG TARGETARCH
WORKDIR /src
COPY . .
RUN flutter pub get
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "no Karmashala server build for $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    dart build cli -t server/bin/karmashala_host.dart \
      --target-os=linux --target-arch="$arch" -o build/server

FROM debian:bookworm-slim
# git: checkpoints and worktrees; bash: agents' login-shell lookups and the
# checks projects run; tini: a PID 1 that forwards SIGTERM, so `docker stop`
# lets the server end its sessions and exit.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git bash curl procps tini \
 && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --shell /bin/bash karmashala \
 && mkdir -p /data \
 && chown karmashala:karmashala /data \
 && chmod 700 /data
COPY --from=build /src/build/server/bundle /opt/karmashala-server
RUN /opt/karmashala-server/bin/karmashala_host probe-store \
 && /opt/karmashala-server/bin/karmashala_host probe-pty

USER karmashala
ENV HOME=/home/karmashala \
    PATH=/opt/karmashala-server/bin:/home/karmashala/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    SHELL=/bin/bash
WORKDIR /home/karmashala
# The store, server.json and every pairing.
VOLUME ["/data"]
# The phone listener. Nothing else is published: the agents' MCP endpoint and
# hook listener are loopback-only inside the container, and the control
# socket is a file.
EXPOSE 47820
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/karmashala-server/bin/karmashala_host"]
# Inside a container the listener has to bind every interface to be reachable
# through a published port at all; which interfaces of the *machine* reach it
# is decided by how the port is published (see docker-compose.yml).
CMD ["serve", "--data-dir=/data", "--companion", "--bind=0.0.0.0"]
