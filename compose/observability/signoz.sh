#!/usr/bin/env bash
# A telemetry backend to look at, in one command.
#
#   ./signoz.sh up        # fetch, start, create the org, print the URL
#   ./signoz.sh down      # stop, keep the data
#   ./signoz.sh destroy   # stop and delete the data
#
# SigNoz is one choice and percolate does not depend on it. `observability.yml`
# exports OTLP to whatever `P8_OTLP_BACKEND` names, and nothing in
# `percolate-collector.yaml` mentions this project. It is here because a local
# backend that takes traces, logs and metrics on one endpoint is the fastest
# way to see whether your telemetry works, and because the setup has one step
# that is easy to miss and hard to diagnose -- see BOOTSTRAP below.
#
# WHY A SCRIPT RATHER THAN SERVICES IN THE OVERLAY. SigNoz is seven services,
# five mounted ClickHouse XML files and a startup step that downloads a binary
# from GitHub releases. Copying that into this repository would mean owning
# their upgrade path: their next release moves a config key and percolate's
# compose file is broken by a project percolate does not ship. This fetches
# THEIR compose at a pinned tag and runs it unmodified, so upgrading is a
# one-line change here and a diff you can read.
set -euo pipefail

# Pinned. A floating tag over a persistent volume is not "always current", it
# is "whatever the volume was created with, forever, with no way to tell".
SIGNOZ_REF="${SIGNOZ_REF:-a8f6b8187}"     # v0.129.0
PROJECT="${SIGNOZ_PROJECT:-signoz}"
UI_PORT="${SIGNOZ_UI_PORT:-3301}"
EMAIL="${SIGNOZ_EMAIL:-admin@percolate.local}"
# SIGNOZ ENFORCES A PASSWORD POLICY: 12+ characters with an uppercase, a
# lowercase, a digit and a symbol. The obvious default here was
# `percolate-observability`, which fails it -- and the failure arrives as a
# plain 400, so a script that shrugs at non-200 reports "already set up" while
# the org does not exist and every OTLP connection is refused. This default
# satisfies the policy; change it, and keep it satisfying the policy.
PASSWORD="${SIGNOZ_PASSWORD:-Percolate!2026}"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECKOUT="${SIGNOZ_CHECKOUT:-$HERE/.signoz}"

# BOTH FILES, EXPLICITLY. Passing `-f` at all turns OFF compose's automatic
# discovery of `docker-compose.override.yaml` next to the base file -- so the
# override written by `override()` below was silently ignored, SigNoz kept
# its own 8080, and the stack came up with the UI unreachable behind
# percolate's agent. Naming both is the fix and the reason to name both.
COMPOSE_FILES=(
  -f "$CHECKOUT/deploy/docker/docker-compose.yaml"
  -f "$CHECKOUT/deploy/docker/docker-compose.override.yaml"
)

need() { command -v "$1" >/dev/null || { echo "need $1 on PATH" >&2; exit 1; }; }

fetch() {
  need git
  if [ ! -d "$CHECKOUT/.git" ]; then
    # A NON-GIT DIRECTORY HERE IS NORMAL, not a sign somebody meddled: docker
    # creates a missing bind-mount source as an empty directory, so a stack
    # started after this checkout was removed leaves exactly this behind --
    # `.signoz/deploy/docker/...` as empty dirs and no `.git`. `git clone` then
    # refuses ("destination path already exists and is not an empty
    # directory") and the script stops with a message about git rather than
    # about what happened. Clear it and clone: everything here is fetched, so
    # there is nothing in it to lose.
    [ -e "$CHECKOUT" ] && rm -rf "$CHECKOUT"
    echo "==> fetching SigNoz at $SIGNOZ_REF"
    git clone --filter=blob:none --no-checkout --quiet \
      https://github.com/SigNoz/signoz.git "$CHECKOUT"
  fi
  git -C "$CHECKOUT" fetch --quiet origin "$SIGNOZ_REF" 2>/dev/null || true
  # Only deploy/: the rest of that repository is a Go service and a React app
  # neither of which we build.
  git -C "$CHECKOUT" checkout --quiet "$SIGNOZ_REF" -- deploy/
}

override() {
  # THE UI MOVES OFF 8080. The main percolate stack publishes the agent there
  # by default, so SigNoz's own default collides with percolate's most-used
  # port -- and compose starts anyway, leaving one of them unreachable in a way
  # that reads as a broken service rather than as a port clash.
  cat > "$CHECKOUT/deploy/docker/docker-compose.override.yaml" <<EOF
services:
  signoz:
    ports: !override
      - "${UI_PORT}:8080"
EOF
}

bootstrap() {
  # THE STEP EVERYBODY MISSES, and the reason this is a script.
  #
  # SigNoz's collector cannot register until an ORGANISATION exists, and until
  # it registers it RESETS EVERY OTLP CONNECTION. The backend logs `cannot
  # create agent without orgId`; the sender sees `Connection reset by peer`,
  # and a plain `curl` to the ingest port fails identically -- so it reads as a
  # network fault in your stack rather than as a setup step in theirs. It cost
  # an afternoon once; it costs a POST here.
  echo "==> waiting for SigNoz"
  for _ in $(seq 1 90); do
    if curl -fsS "http://localhost:${UI_PORT}/api/v1/health" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  echo "==> creating the organisation"
  code=$(curl -s -o /tmp/signoz-register.out -w '%{http_code}' \
    -X POST "http://localhost:${UI_PORT}/api/v1/register" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"percolate\",\"orgName\":\"percolate\",\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}" || true)
  # DO NOT SHRUG AT A NON-200. The first version of this said "already set up,
  # most likely" for every failure, and the failure it was actually hiding was
  # a rejected password -- so the script printed a success banner, the org did
  # not exist, and the collector went on refusing every connection. A setup
  # step that cannot fail loudly is worse than one nobody automated.
  if [ "$code" = "200" ]; then
    echo "    created; sign in as ${EMAIL}"
  elif grep -qi "already exists\|already registered\|invite\|self-registration is disabled" /tmp/signoz-register.out 2>/dev/null; then
    # "self-registration is disabled" IS the already-set-up answer. SigNoz
    # turns self-registration off the moment a first org exists, so a second
    # `up` against a surviving sqlite volume gets that rather than a duplicate
    # error -- and the first version of this list did not include it, so
    # re-running the script on an intact stack failed with a banner telling you
    # to go and fix a registration that had already succeeded.
    echo "    already set up; sign in as ${EMAIL}"
  else
    echo "    FAILED (HTTP ${code}):" >&2
    sed 's/^/    /' /tmp/signoz-register.out >&2 2>/dev/null || true
    echo >&2
    echo "    Until an organisation exists, SigNoz's collector cannot register" >&2
    echo "    and REFUSES EVERY OTLP CONNECTION -- which looks like a network" >&2
    echo "    fault on the sending side. Fix the above and re-run." >&2
    exit 1
  fi

  # The collector registers on its own retry loop, but it backs off to 30s and
  # a restart is instant. Without this, the first minute of a fresh stack drops
  # everything sent to it, which is exactly the minute somebody is watching.
  echo "==> restarting the collector so it registers now"
  docker restart signoz-otel-collector >/dev/null 2>&1 || true

  # AND THEN WAIT FOR IT, because "the containers are up" is not "it accepts
  # telemetry". On a fresh volume the collector runs `migrate sync check`
  # first and does not open its receivers until ClickHouse has every schema
  # migration -- around ninety seconds here. Until then the port refuses
  # connections, so a script that printed its success banner at this point sent
  # somebody off to configure an exporter against a backend that would reject
  # everything for the next minute and a half. Measured, not guessed.
  echo "==> waiting for the collector to accept OTLP"
  for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' -d '{"resourceSpans":[]}' \
      "http://localhost:4318/v1/traces" 2>/dev/null || true)
    if [ "$code" = "200" ]; then
      echo "    accepting"
      return 0
    fi
    sleep 5
  done
  echo "    still not accepting after five minutes." >&2
  echo "    docker logs signoz-otel-collector  -- most likely still migrating" >&2
  exit 1
}

case "${1:-up}" in
  up)
    need docker; need curl
    fetch
    override
    echo "==> starting SigNoz ($SIGNOZ_REF)"
    docker compose -p "$PROJECT" "${COMPOSE_FILES[@]}" up -d
    bootstrap
    cat <<EOF

SigNoz is up.

  UI        http://localhost:${UI_PORT}
  sign in   ${EMAIL} / ${PASSWORD}
  OTLP      localhost:4317 (gRPC), localhost:4318 (HTTP)

Now start percolate with the overlay:

  docker compose -f compose/docker-compose.yml -f compose/observability.yml up -d

Ask the agent something, then look for the service 'percolate-agent-runtime'.
A turn is one 'percolate.turn <agent>' span with the model call under it;
'percolate.run.id' on that span is the agentic.runs row.
EOF
    ;;
  down)
    docker compose -p "$PROJECT" "${COMPOSE_FILES[@]}" down
    ;;
  destroy)
    docker compose -p "$PROJECT" "${COMPOSE_FILES[@]}" down -v
    echo "volumes deleted"
    ;;
  *)
    echo "usage: $0 [up|down|destroy]" >&2
    exit 2
    ;;
esac
