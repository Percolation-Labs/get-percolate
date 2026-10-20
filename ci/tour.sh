#!/usr/bin/env bash
# Install Percolate as a stranger does and run the LangGraph tour on it (REM-1014).
#
# coldstart.sh and examples.sh bring the stack up from THIS checkout's compose
# file, on a machine whose images and database are whatever CI last left. Two
# defects passed every one of those runs and were found by fresh readers: the
# `member` role a fresh install did not have (REM-993) and a MinIO image that
# answered 401 to anybody without it cached (REM-981). This run has neither
# crutch. It starts in an empty directory on a runner with no image cache,
# downloads the compose file from the URL the install page gives a reader, and
# follows the tour from its first block.
#
# The tour is not copied here. Its canonical copy is the extension repository's
# dev/tests/workflow/25-the-langgraph-article-runs.sql, fetched at the release
# tag under test, and it is two halves:
#
#   live blocks   the reader's shell, between `-- live: <name>` and `-- /live`.
#                 This runs the first three as written -- stack (mkdir, curl,
#                 .env, compose up), venv (pip install percolate-core) and shell
#                 (bootstrap_admin, a token) -- in one shell, as the reader does.
#                 The later ones start runs that need a real model, so they are
#                 not run here.
#   SQL           everything else, run in one psql session against the stack's
#                 database. Its pg_temp.work plays the worker and answers each
#                 agent step by name, so no model and no key is needed: the
#                 tour's stub mode. One transaction, rolled back by the file.
#
# Red on the first failure, with the failing block's text and its error printed.
#
#     ci/tour.sh              # the release versions.toml on main names
#     ci/tour.sh 0.2.27       # must be the release main's compose file pins
#     ALLOW_CACHED=1 ci/tour.sh   # on a machine that has images (ports from 5432 must be free)
set -uo pipefail

EXT_REPO=${EXT_REPO:-Percolation-Labs/percolate}
RAW=https://raw.githubusercontent.com
HARNESS_PATH=dev/tests/workflow/25-the-langgraph-article-runs.sql
FIRST_BLOCKS=(stack venv shell)

say()  { printf '\n=== %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

V=${1:-${VERSION:-}}
if [ -z "$V" ]; then
    V=$(curl -fsSL "$RAW/Percolation-Labs/get-percolate/main/versions.toml" \
        | sed -n 's/^extension *= *"\([0-9.]*\)".*/\1/p' | head -1)
    [ -n "$V" ] || fail "could not read published.extension from get-percolate's versions.toml on main"
fi

# The empty directory. Everything below happens inside it; the tour's own first
# block makes the directory the stack lives in.
WORK=$(mktemp -d)
cd "$WORK" || fail "no work directory"
trap '[ -d "$WORK/langgraph-tour" ] && (cd "$WORK/langgraph-tour" && docker compose down -v >/dev/null 2>&1); rm -rf "$WORK"' EXIT

say "under test: extension $V, the tour at $EXT_REPO v$V"
# A hosted runner starts with no image of ours. Said, so a cache somebody adds
# later is a red run rather than a quiet return to the crutch this replaces.
if [ -z "${ALLOW_CACHED:-}" ] && docker image ls --format '{{.Repository}}' | grep -qiE 'percolat|minio|rustfs|postgrest'; then
    docker image ls >&2
    fail "this machine already has a stack image cached; the run must start with none (ALLOW_CACHED=1 for a local run)"
fi

curl -fsSL "$RAW/$EXT_REPO/v$V/$HARNESS_PATH" -o harness.sql \
    || fail "the tour harness is not at $EXT_REPO v$V/$HARNESS_PATH"

# One live block, its `-- ` prefix dropped, exactly as the harness's header says.
live_block() {
    awk -v name="$1" '
        $0 == "-- live: " name { on = 1; next }
        on && $0 == "-- /live" { exit }
        on { sub(/^-- ?/, ""); print }' harness.sql
}

# The reader's shell: one script, so variables and functions carry from block to
# block. After each block, a check that it did what the next one relies on.
{
    echo 'set -o pipefail'
    echo 'trap '"'"'[ $? -eq 0 ] || echo "FAIL: the block printed last stopped the reader" >&2'"'"' EXIT'
    for b in "${FIRST_BLOCKS[@]}"; do
        body=$(live_block "$b")
        [ -n "$body" ] || { echo "echo 'the harness at v$V has no live block named $b' >&2; exit 1"; continue; }
        printf '\necho; echo "=== live: %s"\n' "$b"
        printf 'cat <<'"'"'__BLOCK__'"'"'\n%s\n__BLOCK__\n' "$body"
        # -e for the block: a command that fails in it is one the reader sees fail.
        printf 'set -e\n%s\nset +e\n' "$body"
        case $b in
            stack)
                # The image a stranger got is the release under test, or this
                # run is testing a release nobody downloads today.
                printf '%s\n' \
                  "pin=\$(sed -n 's/.*percolate-postgres:\(19-[0-9.]*\)}.*/\1/p' docker-compose.yml | head -1)" \
                  "echo \"the downloaded compose pins \$pin\"" \
                  "if [ \"\$pin\" != 19-$V ]; then" \
                  "  echo \"FAIL: the compose file on main pins \$pin, not 19-$V\" >&2; exit 1" \
                  "fi" \
                  "docker compose ps --format '{{.Service}} {{.State}} {{.Health}}'" ;;
            shell)
                printf '%s\n' \
                  '[ -n "$P8_USER_ID" ] || { echo "FAIL: bootstrap_admin left no me@example.com" >&2; exit 1; }' \
                  '[ -n "$TOKEN" ] || { echo "FAIL: percolate auth token printed nothing" >&2; exit 1; }' \
                  'echo "signed in as $P8_USER_ID"' ;;
        esac
    done
    # The SQL half, in the reader's psql, against the stack the blocks above made.
    printf '\necho; echo "=== the tour'"'"'s SQL, the worker stubbed"\n'
    printf 'psql "$P8_DSN" -X -v ON_ERROR_STOP=1 -f "%s/harness.sql" > "%s/sql.log" 2>&1\n' "$WORK" "$WORK"
} > reader.sh

bash reader.sh
rc=$?
[ -d langgraph-tour ] || fail "the stack block made no langgraph-tour directory"

if [ -f sql.log ] && [ $rc -ne 0 ]; then
    tail -n 40 sql.log
    # psql reports the line of the statement that stopped it. Print the block it
    # sits in, from its `-- block:` (or section) header to that line.
    line=$(sed -n 's/^psql:[^:]*:\([0-9]*\): ERROR:.*/\1/p' sql.log | tail -1)
    if [ -n "$line" ]; then
        start=$(awk -v n="$line" 'NR <= n && /^-- (block: |§)/ { s = NR } END { print s + 0 }' harness.sql)
        [ "$start" -gt 0 ] || start=1
        say "the failing block, harness.sql lines $start-$line at v$V"
        sed -n "${start},${line}p" harness.sql
    fi
fi

if [ $rc -ne 0 ]; then
    say "what the stack said"
    (cd langgraph-tour && docker compose ps -a && docker compose logs --tail=40) 2>&1 || true
    fail "the LangGraph tour does not run on a fresh install of $V"
fi

say "the tour ran on a fresh install of $V"
tail -n 3 sql.log
