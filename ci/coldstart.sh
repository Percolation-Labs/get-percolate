#!/usr/bin/env bash
# Install this repository the way a stranger does, by running its own pages.
#
# Every cold-start break found so far was mechanical and would have shown up
# the first time anybody executed the install guide against a published
# artifact: a grant list whose verbs no policy asked for, a CLI no page said to
# install, a sample path that assumed a clone, an evidence block whose HTTP
# code the server had stopped returning. None of that survives being run.
#
# The commands come OUT OF THE DOCUMENTATION (ci/extract-runnable.py), never
# from a copy kept here. A copy is what drifts, and drift is the whole disease.
# What this file adds is the assertions -- the part a reader performs by
# looking, which CI has to do explicitly.
#
#     ci/coldstart.sh                       # against the published image
#     IMAGE=percolate-postgres:local ci/coldstart.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'cd "$WORK" && docker compose down -v >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

say() { printf '\n=== %s\n' "$*"; }
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    # The commonest cause, said once, at the point it matters. Without this the
    # run ends on `function rbac.bootstrap_admin does not exist` and reads as a
    # broken install guide rather than an unshipped release.
    [ "${AHEAD:-no}" = "yes" ] && {
        printf '\nversions.toml says the documentation is AHEAD of what is published.\n' >&2
        printf 'This guide describes a release that has not shipped, so it cannot pass\n' >&2
        printf 'against the published artifacts yet. Ship it, or rehearse against a\n' >&2
        printf 'local build:  IMAGE=<local-tag> PERCOLATE_CORE_SPEC=<path> ci/coldstart.sh\n' >&2; }
    exit 1
}

# Chosen once, at the top, and used for everything Python here. The version of
# this that picked an interpreter only for the venv left `ci/extract-runnable.py`
# running under whatever `python3` happened to be -- on a Mac, the system 3.9,
# which has no tomllib -- so the run died reading versions.toml rather than
# testing anything.
PY_BIN=""
for c in python3.13 python3.12 python3.11 python3; do
    command -v "$c" >/dev/null || continue
    "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null \
        && { PY_BIN=$c; break; }
done
[ -n "$PY_BIN" ] || fail "no python >= 3.11 on PATH -- the tooling reads TOML, and percolate-core requires it"

cd "$WORK"

# Any earlier run of this script shares the compose project name in the file
# under test ("percolate"), so its volumes are still here. An initialised
# pgdata is the one piece of state that makes a cold start not cold: the image
# runs its init scripts exactly once, on an empty volume, so a leftover from a
# previous image silently becomes the thing under test.
docker compose -f "$ROOT/compose/docker-compose.yml" -p percolate down -v >/dev/null 2>&1 || true

# The image override is written BEFORE anything starts, for the same reason:
# compose reads it at `up`, and changing an image afterwards recreates the
# container onto the volume the previous image already initialised. Gating an
# unpublished build means it has to be there for the first start, not the
# second.
if [ -n "${IMAGE:-}" ]; then
    printf 'services:\n  db:\n    image: %s\n' "$IMAGE" > docker-compose.override.yml
    echo "(db image overridden: $IMAGE)"
fi

say "install.md: bring the stack up"
# The page is run VERBATIM, which also tests the thing most likely to rot in
# it: that the raw.githubusercontent URL a reader curls still resolves.
"$PY_BIN" "$ROOT/ci/extract-runnable.py" "$ROOT/docs/src/install.md" --kind shell > steps.sh
bash steps.sh
[ -s docker-compose.yml ] || fail "the documented curl produced no compose file"

# Then the working tree's copy replaces what was fetched. Without this a PR
# that changes compose/docker-compose.yml would be graded against main's copy
# -- green for a change nobody ran. Editing the file after the fetch rather
# than rewriting the command keeps the command under test.
if ! cmp -s "$ROOT/compose/docker-compose.yml" docker-compose.yml; then
    echo "(compose file differs from main -- testing the working tree's copy)"
    cp "$ROOT/compose/docker-compose.yml" docker-compose.yml
    docker compose up -d >/dev/null
fi

say "wait for the database"
for _ in $(seq 1 60); do
    docker compose exec -T db psql -U p8 -d percolate -tAc \
        "select 1 from pg_extension where extname='percolate'" 2>/dev/null \
        | grep -q 1 && break
    sleep 3
done

psql_() { docker compose exec -T db psql -U p8 -d percolate -v ON_ERROR_STOP=1 "$@"; }

# Named BEFORE the assertions, so a failure that is really "this release has not
# shipped yet" says so instead of surfacing as `function does not exist` from
# whichever assertion happened to touch it first.
say "is the documentation ahead of what is published?"
"$PY_BIN" "$ROOT/ci/versions.py" --check | sed -n '/^note:/,$p' | sed 's/^/    /'
AHEAD=$("$PY_BIN" - "$ROOT/versions.toml" <<'EOF'
import sys, tomllib
v = tomllib.load(open(sys.argv[1], "rb"))
p, r = v["published"], v["requires"]
print("yes" if any(r.get(k, p[k]) != p[k] for k in ("core", "extension")) else "no")
EOF
)

say "what is under test"
psql_ -c "select * from percolate_build()" || {
    [ "$AHEAD" = "yes" ] && echo "    (no percolate_build() -- expected while the extension release is outstanding)"
    true; }

say "install.md: the capability probe reports nothing missing"
missing=$(psql_ -tAc "select workflow.compiler_capabilities()->>'missing'")
[ "$missing" = "[]" ] || fail "compiler_capabilities reports missing: $missing"

say "install.md: the first administrator"
"$PY_BIN" "$ROOT/ci/extract-runnable.py" "$ROOT/docs/src/install.md" --kind sql | psql_ -f -

# The bug this whole file exists for. The page used to grant verbs nothing
# checked, so the admin it produced held permissions that matched no policy --
# and nothing said so. Asserting the COUNT would just re-encode a number;
# asserting that every declared pair is held is the actual property.
ungranted=$(psql_ -tAc "
    select count(*) from rbac.permission_kinds k
     where not exists (select 1 from rbac.role_permissions p
                        where p.role='admin' and p.resource=k.resource
                          and p.action=k.action)")
[ "$ungranted" = "0" ] || fail "$ungranted declared permission(s) not granted to admin"

say "first-workflow.md: define, start, and see it"
"$PY_BIN" "$ROOT/ci/extract-runnable.py" "$ROOT/docs/src/first-workflow.md" --kind sql | psql_ -f -

# Read it back AS THE ADMIN, through the RLS-filtered view the page tells you
# to use. Reading workflow.runs instead would pass while the documented query
# returned nothing, which is exactly the failure that shipped.
#
# The successful-state word is joined from workflow.lifecycle_states rather than
# written here. efebac2 renamed it and left three hardcoded copies behind -- CI,
# the release rehearsal, and this file -- each of which failed separately, on a
# different day, and each of which failed by finding NOTHING rather than by
# erroring. That is the worst shape a stale literal can take in a check: it does
# not say the word is wrong, it says your feature is broken.
seen=$(psql_ -tAc "
    select set_config('request.jwt.claims',
        json_build_object('sub', (select id from rbac.users
                                   where email='me@example.com'))::text, false);
    select count(*) from workflow.runs_api r
      join workflow.lifecycle_states s on s.state = r.status
     where s.is_success")
[ "$(echo "$seen" | tail -1)" -ge 1 ] || fail "runs_api shows no finished run to the admin the docs just created"

say "install.md: the CLI it tells you to install exists and has the commands it names"
# In a venv: this installs from an index, and a check that quietly mutates the
# environment it runs in is not one anybody will run twice. PERCOLATE_CORE_SPEC
# points it at a local checkout or a pre-release when the release being gated
# is not on PyPI yet.
# An explicit 3.11+, and a clear refusal when there is not one. percolate-core
# requires >=3.11; on a Mac `python3` is often the system 3.9, and pip's answer
# to "no version of this package supports your interpreter" is to backtrack
# through every release looking for one that does -- minutes of silence ending
# in "no matching distribution", which reads as a broken package rather than a
# wrong interpreter. install.md now names the requirement for the same reason.
echo "(using $PY_BIN: $("$PY_BIN" --version))"
"$PY_BIN" -m venv "$WORK/cli-venv"
# THE SPEC COMES OUT OF THE PAGE, like every other command here. It did not,
# and that is exactly the drift this file's header warns about: the default
# here read `percolate-core[sample]` while install.md said plain
# `percolate-core`, so CI installed one thing and every reader installed
# another. CI was green and the documented path stopped at
#   "reading a sample needs PyYAML: pip install 'percolate-core[sample]'"
# on the very next command. Both were then wrong together, because the shipped
# sample also needs [agent] to translate plugin.yaml's JSON-Schema agents --
# which nothing caught, because the check below only asked whether the
# subcommand EXISTED.
#
# `run: pip` rather than `run: shell`: steps.sh is executed verbatim in this
# shell, and a `pip install` there would install into whatever interpreter is
# on PATH instead of the venv. The block is still the single home for the
# string.
PIP_SPEC=$("$PY_BIN" "$ROOT/ci/extract-runnable.py" "$ROOT/docs/src/install.md" --kind pip \
           | sed -n "s/^pip install '\(.*\)'$/\1/p")
[ -n "$PIP_SPEC" ] || fail "install.md has no '<!-- run: pip -->' block naming what to install"
echo "(installing what install.md says: $PIP_SPEC)"
"$WORK/cli-venv/bin/pip" install --quiet \
    "${PERCOLATE_CORE_SPEC:-$PIP_SPEC}" || \
    fail "pip install $PIP_SPEC failed -- install.md tells a reader to run this"
# `percolate sample load` is step three of the README. It was documented for
# weeks while no published wheel or image had the command at all, because the
# version in the tree still named the release that predated it.
# Asking the command itself, not grepping the help screen. The first version
# of this matched against `--help`, whose box-drawing characters are multibyte
# and made the pattern match nothing on a CLI that had the command -- a check
# that fails when it should pass is only marginally better than one that passes
# when it should fail. A missing subcommand exits non-zero here; a present one
# prints its own usage.
for cmd in sample auth; do
    "$WORK/cli-venv/bin/percolate" "$cmd" --help >/dev/null 2>&1 || \
        fail "'percolate $cmd' is documented but missing from the installed CLI"
done

say "install.md: the sample it tells you to load, actually loads"
# ASKING THE COMMAND TO DO ITS JOB, not whether it exists. `--help` passing is
# what let two separate extras gaps ship: the loader refuses on a missing
# extra long before it writes anything, and a `--help` check cannot tell the
# difference between a CLI that can load the sample and one that will stop on
# its first line.
#
# --skip-documents because the corpus step needs a real embedding key and this
# check must run without one; everything the extras are needed FOR -- the YAML
# reader and the JSON-Schema agent translation in plugin.yaml -- is on this
# path. Idempotent by design, so a re-run is not a special case.
P8_ADMIN_DSN="postgres://p8:p8@localhost:5432/percolate" \
    "$WORK/cli-venv/bin/percolate" sample load "$ROOT/samples/harbour" \
        --as-email me@example.com --skip-documents > "$WORK/sample.log" 2>&1 || {
    sed 's/^/    /' "$WORK/sample.log" >&2
    fail "'percolate sample load' failed -- install.md tells a reader to run this"; }
grep -q '^  plugin harbour' "$WORK/sample.log" || {
    sed 's/^/    /' "$WORK/sample.log" >&2
    fail "the sample loaded without applying plugin.yaml -- the agent half is what needs [agent]"; }
# And the rows are really there, read back through the database rather than
# from the loader's own account of itself.
[ "$(psql_ -tAc "select count(*) from agentic.agents where name = 'harbourmaster'")" = "1" ] || \
    fail "sample load reported success and agentic.agents has no harbourmaster"

say "every function the documentation names exists in this install"
# `agentic.remove_plugin('harbour')` was documented in two places -- install.md
# and samples/harbour/README.md -- as the way to take the sample back out, and
# it has never existed in any release or in the source tree. The capability is
# real and is spelled `apply_plugin` with an empty manifest, which agentic's
# schema states outright: uninstalling goes through the pruning path because
# that is the one that knows what else references a row.
#
# A name in a code fence is a promise, and this is the cheapest possible check
# of it: every `schema.function(` the pages write down, against pg_proc on the
# database the guide just built. It found one that had shipped.
#
# Names only, not signatures. Arity and argument types drift for good reasons
# and a doc example is allowed to omit a defaulted parameter; a function that
# does not exist at all is never right.
docs_fns=$("$PY_BIN" - "$ROOT" <<'EOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
pat = re.compile(r'\b(rbac|workflow|aiq|content|agentic|percolate)\.([a-z_]+)\(')
names = set()
for f in list((root / "docs/src").glob("*.md")) + list(root.glob("samples/*/README.md")):
    names |= {f"{m.group(1)}.{m.group(2)}" for m in pat.finditer(f.read_text())}
print("\n".join(sorted(names)))
EOF
)
live_fns=$(psql_ -tAc "select n.nspname||'.'||p.proname
                         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname in ('rbac','workflow','aiq','content','agentic','percolate')" | sort -u)
absent=$(comm -23 <(echo "$docs_fns") <(echo "$live_fns") | tr '\n' ' ')
[ -z "${absent// /}" ] || fail "the documentation names function(s) this install does not have: $absent"
echo "    $(echo "$docs_fns" | wc -l | tr -d ' ') documented function names, all present"

printf '\nCOLD START OK\n'
