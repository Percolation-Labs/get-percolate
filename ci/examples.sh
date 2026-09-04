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
for _ in $(seq 1 60); do
    dc exec -T db psql -U p8 -d percolate -tAc \
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
"$PY_BIN" -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install --quiet "${PERCOLATE_CORE_SPEC:-percolate-core[sample,agent]>=0.1.7}"
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
