#!/usr/bin/env bash
# The third install path, run: a plain PostgreSQL 19 that is NOT our image,
# then install.sh, then bootstrap.sql -- twice, with pg_cron on.
#
# coldstart.sh runs the compose path and nothing ran this one, which is how it
# shipped three defects at once: install.md told readers to run a bare
# `CREATE EXTENSION percolate` that the extension refuses; bootstrap.sql set
# its role passwords through transaction-local settings outside a transaction,
# so `authenticator` and `worker` were created with NO password while the
# script exited 0; and a third run with pg_cron on died on
# `jobname_username_uniq`. Every one of those is an exit code or a login, so
# every one is asserted here.
#
# The working tree's install.sh and bootstrap.sql are the ones under test; the
# release assets install.sh downloads are the published ones.
#
#     ci/ownpg.sh
#     PG_IMAGE=postgres:19beta3-bookworm ci/ownpg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
NAME=p8ownpg-$$
PG_IMAGE=${PG_IMAGE:-postgres:19beta3-bookworm}
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

say()  { printf '\n=== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
in_pg() { docker exec -i "$NAME" "$@"; }
psql_() { in_pg psql -U postgres -d appdb -v ON_ERROR_STOP=1 "$@"; }

say "a plain $PG_IMAGE, with pgvector and pg_cron from PGDG"
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=pw "$PG_IMAGE" >/dev/null
for _ in $(seq 1 30); do in_pg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
in_pg bash -c 'apt-get update -qq && apt-get install -y -qq postgresql-19-pgvector postgresql-19-cron curl openssl' >/dev/null

say "install.sh (the working tree's)"
docker cp "$ROOT/install.sh" "$NAME:/tmp/install.sh"
in_pg bash -c 'cd /tmp && sh install.sh' | tail -3
docker cp "$ROOT/bootstrap.sql" "$NAME:/tmp/bootstrap.sql"

say "pg_cron on, the way install.md says"
in_pg psql -U postgres -qc "create database appdb" \
    -c "alter system set shared_preload_libraries = 'pg_cron'" \
    -c "alter system set cron.database_name = 'appdb'" \
    -c "alter system set cron.use_background_workers = on"
docker restart "$NAME" >/dev/null
for _ in $(seq 1 30); do in_pg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done

say "bootstrap.sql, three times"
AUTH_PW=$(openssl rand -hex 24); WORKER_PW=$(openssl rand -hex 24)
for i in 1 2 3; do
    out=$(in_pg psql -U postgres -d appdb -v ON_ERROR_STOP=1 \
            -v auth_pw="$AUTH_PW" -v worker_pw="$WORKER_PW" -f /tmp/bootstrap.sql 2>&1) \
        || { echo "$out" >&2; fail "bootstrap.sql run $i exited non-zero"; }
    # The passwords are not echoed: a generated password printed to a terminal
    # or a CI log is a leaked one.
    ! grep -q "$WORKER_PW" <<<"$out" || fail "bootstrap.sql printed the worker password"
    ! grep -q "clearing password" <<<"$out" || fail "bootstrap.sql cleared a role password (run $i)"
done
echo "    three runs, exit 0"

say "the service roles log in over TCP with the passwords they were given"
in_pg env PGPASSWORD="$AUTH_PW"   psql -h 127.0.0.1 -U authenticator -d appdb -tAc 'select 1' >/dev/null \
    || fail "authenticator cannot log in with auth_pw"
in_pg env PGPASSWORD="$WORKER_PW" psql -h 127.0.0.1 -U worker -d appdb -tAc 'select 1' >/dev/null \
    || fail "worker cannot log in with worker_pw"

say "the extension is whole, and owned by a non-superuser"
missing=$(psql_ -tAc "select workflow.compiler_capabilities()->>'missing'")
[ "$missing" = "[]" ] || fail "compiler_capabilities reports missing: $missing"
owner=$(psql_ -tAc "select r.rolname from pg_extension e join pg_roles r on r.oid = e.extowner where e.extname = 'percolate'")
[ "$owner" = "app_owner" ] || fail "percolate is owned by $owner, not app_owner"

# EVERY workflow job, AS scheduler -- not a count. This asserted `= 3`, and
# adding a fourth job (`workflow-purge`, REM-109) failed a check that was
# asking the wrong question: the guarantee is that no maintenance job runs as a
# privileged role, and three is an implementation detail of how many there are
# today. A count has to be edited by whoever adds a job, which is how it ends
# up out of step with `bootstrap.sql` -- and the version that catches the real
# defect is the one `p8-subsystems/dev/tests/workflow/03-cron-tick.sql:49`
# already uses, so this now asks it the same way.
say "the clock: every workflow job, as scheduler"
bad=$(psql_ -tAc "select string_agg(jobname || ' as ' || username, ', ')
                    from cron.job
                   where database = 'appdb' and jobname like 'workflow-%'
                     and username <> 'scheduler'")
[ -z "$bad" ] || fail "maintenance jobs must run as scheduler, not: $bad"
jobs=$(psql_ -tAc "select count(*) from cron.job where username = 'scheduler' and database = 'appdb' and jobname like 'workflow-%'")
[ "$jobs" -ge 1 ] || fail "no scheduler-owned workflow cron jobs at all -- the clock is not registered"
say "  $jobs workflow job(s), all scheduler-owned"

say "the first administrator and the README's first workflow"
psql_ -qc "select rbac.bootstrap_admin('you@example.com', 'a long passphrase')" >/dev/null
psql_ -qc "select workflow.define_yaml(\$\$
name: hello
steps:
  - id: now
    sql: {function: p8ql, args: ['SELECT now()']}
\$\$)" >/dev/null
# Two statements: a run started inside the query that reads it is invisible to
# that query's snapshot.
run=$(psql_ -tAc "select workflow.start_workflow('hello', '{}'::jsonb)")
status=$(psql_ -tAc "select status from workflow.runs where id = '$run'")
[ "$status" = "succeeded" ] || fail "the hello workflow ended '$status'"

printf '\nOWN-POSTGRES PATH OK\n'
