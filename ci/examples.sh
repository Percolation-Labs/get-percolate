#!/usr/bin/env bash
# Run the documentation's marked example blocks against a sample-loaded database.
#
# ci/coldstart.sh proves the INSTALL path against the full stack. This proves
# the REFERENCE pages: every `<!-- run: sql -->` block (see ci/run_examples.py),
# in document order, so a column that no longer exists, a fixture that was never
# loaded, a function whose name drifted, or an example whose output block a
# reader cannot reproduce, fails the build instead of the reader.
#
# EACH PAGE RUNS IN ITS OWN TRANSACTION, rolled back at the end, so nothing a
# page writes survives into the next -- a page that relies on creating a skill
# meets a database where that skill does not exist, rather than one an earlier
# page happened to leave. That is the property that keeps a create-then-use page
# honest; without it the harness passes on exactly the state it exists to catch.
#
# Only the `db` container is started: these blocks are SQL, and a rolled-back
# page never commits a workflow for a worker to see, so no service is needed.
#
#     ci/examples.sh                 # against the published image
#     IMAGE=percolate-postgres:local ci/examples.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
WORK=$(mktemp -d)
PROJECT=p8examples
trap 'docker compose -f "$ROOT/compose/docker-compose.yml" -p "$PROJECT" down -v >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

say() { printf '\n=== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
dc() { docker compose -f "$ROOT/compose/docker-compose.yml" -p "$PROJECT" "$@"; }

PY_BIN=""
for c in python3.13 python3.12 python3.11 python3; do
    command -v "$c" >/dev/null || continue
    "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null \
        && { PY_BIN=$c; break; }
done
[ -n "$PY_BIN" ] || fail "no python >= 3.11 on PATH"

say "bring up only the database"
dc down -v >/dev/null 2>&1 || true
dc up -d db >/dev/null

say "wait for the extension"
# TCP first: the image's first-start server listens on the socket only, and the
# extension row can exist there before it stops and the real server starts --
# which the TCP DSN below would then meet.
for _ in $(seq 1 60); do
    dc exec -T db pg_isready -h 127.0.0.1 -U p8 -d percolate >/dev/null 2>&1 \
    && dc exec -T db psql -U p8 -d percolate -tAc \
        "select 1 from pg_extension where extname='percolate'" 2>/dev/null | grep -q 1 && break
    sleep 3
done
PORT=$(dc port db 5432 | cut -d: -f2)
DSN="postgres://p8:p8@localhost:$PORT/percolate"
psql "$DSN" -tAqc "select 1 from pg_extension where extname='percolate'" | grep -q 1 \
    || fail "extension never came up"

say "the first administrator, from install.md"
"$PY_BIN" ci/extract-runnable.py docs/src/install.md --kind sql \
    | psql "$DSN" -v ON_ERROR_STOP=1 -q -f -

say "load the sample (the state every reference page assumes)"
# THE FLOOR COMES FROM versions.toml, not from a literal here. This line said
# `>=0.1.7` against a `[requires] core` of 0.1.8 -- so the job whose entire
# purpose is proving the reference pages work against the core the docs tell a
# reader to install was proving it against an older one, and a page using
# anything added since 0.1.7 would have been green here and broken for them.
#
# Nothing substitutes into a shell script the way docs/build.py substitutes into
# a page, so the number had no way to follow versions.toml and no way to be
# noticed when it stopped. Reading it is the fix; `ci/versions.py --check` now
# also scans ci/*.sh for anyone who types one back in. `coldstart.sh` reads this
# file the same way, and $PY_BIN is already required to be >= 3.11 for tomllib.
CORE_MIN=$("$PY_BIN" - "$ROOT/versions.toml" <<'EOF'
import sys, tomllib
print(tomllib.load(open(sys.argv[1], "rb"))["requires"]["core"])
EOF
)
[ -n "$CORE_MIN" ] || fail "could not read [requires] core from versions.toml"
"$PY_BIN" -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet "${PERCOLATE_CORE_SPEC:-percolate-core[sample,agent]>=$CORE_MIN}"
P8_ADMIN_DSN="$DSN" "$WORK/venv/bin/percolate" sample load "$ROOT/samples/harbour" \
    --as-email me@example.com --skip-documents > "$WORK/load.log" 2>&1 \
    || { sed 's/^/    /' "$WORK/load.log" >&2; fail "sample load failed"; }

# A documented one-time operator grant (graph.html), committed here so the
# RELEVANCE/PATH/graph examples resolve on every page rather than only after the
# page that grants -- each page rolls back, so a grant inside one would not last.
say "enable graph algorithms (a documented operator grant)"
psql "$DSN" -tAqc "select aiq.enable_graph_algorithms('authenticated')" >/dev/null

say "run every page's examples, each in its own rolled-back transaction"
"$PY_BIN" ci/run_examples.py --dsn "$DSN" || fail "a documented example no longer runs"

printf '\nEXAMPLES OK\n'
