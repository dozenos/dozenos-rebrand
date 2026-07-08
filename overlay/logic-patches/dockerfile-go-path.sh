#!/usr/bin/env bash
#
# dockerfile-go-path.sh -- put /opt/go/bin on the build container's ENV PATH.
#
# WHY: docker/Dockerfile installs Go to /opt/go (`RUN ... tar -C /opt -xzf
# go*.tar.gz`) but only adds /opt/go/bin to PATH via `/etc/bash.bashrc` and
# `/etc/skel/.bashrc` -- both of which are sourced ONLY by INTERACTIVE bash
# shells. DozenOS's CI builds packages non-interactively:
# `docker run ... bash -c "... python3 build.py"`, and build.py runs each
# recipe's build_cmd via `run(..., shell=True)` = `/bin/sh -c`. Neither is
# interactive, so neither sources bashrc -> `go` is NOT on PATH -> every
# recipe that shells out to `go` directly (blackbox_exporter's build.sh,
# amazon-cloudwatch-agent's Makefile, podman's make) dies with
# "go: not found". (Prometheus-Makefile recipes like node_exporter/telegraf
# survive only because that Makefile downloads its own Go.) Confirmed by
# probing the live image: `go` lives at /opt/go/bin/go but `bash -c 'echo
# $PATH'` shows /opt/go/bin absent.
#
# FIX: a Dockerfile `ENV PATH="/opt/go/bin:${PATH}"` line, which Docker
# applies to EVERY process in the container (interactive or not, /bin/sh
# included) -- the standard way to expose a build tool, vs the interactive-
# only bashrc export the upstream image relies on. Inserted right before the
# existing bashrc-export RUN so it sits with the other Go PATH setup.
#
# Idempotent: no-op if the ENV line is already present. Fails loudly if the
# anchor (the bashrc Go-PATH export line) is gone -- an upstream Docker change
# to how Go is set up must re-run this by hand, not be silently papered over.
#
# Usage:
#   dockerfile-go-path.sh <target-tree>
#
# LOCAL ONLY -- no network, no git.
set -euo pipefail

die() { printf 'dockerfile-go-path: %s\n' "$*" >&2; exit 2; }

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "Usage: $0 <target-tree>" >&2; exit 2; }
[ -d "$TARGET" ] || die "not a directory: $TARGET"

DOCKERFILE="$TARGET/docker/Dockerfile"
[ -f "$DOCKERFILE" ] || die "expected file not found (upstream sync drift?): $DOCKERFILE"

# These are LITERAL Dockerfile strings to grep for / insert -- the ${PATH} and
# $PATH must stay unexpanded (Docker expands them at image-build time), so
# single quotes are deliberate.
# shellcheck disable=SC2016
ENV_LINE='ENV PATH="/opt/go/bin:${PATH}"'
# Anchor: the interactive-only Go PATH export the upstream image ships.
# shellcheck disable=SC2016
ANCHOR='export PATH=/opt/go/bin:$PATH" >> /etc/bash.bashrc'

if grep -qF "$ENV_LINE" "$DOCKERFILE"; then
  echo "dockerfile-go-path: already present (idempotent no-op)"
  exit 0
fi
# Only act when this Dockerfile actually installs Go. A Dockerfile with no Go
# install at all (e.g. a minimal test fixture) has nothing to patch -- skip
# quietly. But if Go IS installed and the PATH-export anchor is gone, that is
# real upstream drift in how Go is set up -- fail loudly (do NOT silently ship
# a container where `go` is off PATH again).
if ! grep -qE 'GO_VERSION_INSTALL|/opt/go' "$DOCKERFILE"; then
  echo "dockerfile-go-path: no Go install in $DOCKERFILE -- nothing to patch (skip)"
  exit 0
fi
grep -qF "$ANCHOR" "$DOCKERFILE" || die "Go IS installed in $DOCKERFILE but the PATH-export anchor line is gone -- upstream changed how Go is set up; re-review by hand"

# Insert the ENV line immediately before the anchor RUN line.
tmp=$(mktemp)
awk -v ins="$ENV_LINE" -v anchor='RUN echo "export PATH=/opt/go/bin:$PATH" >> /etc/bash.bashrc' '
  $0 == anchor && !done { print ins; done=1 }
  { print }
' "$DOCKERFILE" > "$tmp"

if ! grep -qF "$ENV_LINE" "$tmp"; then
  rm -f "$tmp"
  die "failed to insert ENV PATH line (anchor line did not match exactly) -- re-review by hand"
fi
mv "$tmp" "$DOCKERFILE"
echo "dockerfile-go-path: inserted '$ENV_LINE' before the bashrc Go-PATH export"
