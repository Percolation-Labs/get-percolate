-- Prepare a PostgreSQL 19 you already run to hold Percolate.
--
--   export P8_AUTH_PW=$(openssl rand -hex 24) P8_WORKER_PW=$(openssl rand -hex 24)
--   psql -d yourdb -v ON_ERROR_STOP=1 \
--        -v auth_pw="$P8_AUTH_PW" -v worker_pw="$P8_WORKER_PW" \
--        -f bootstrap.sql
--
-- Hex, not base64: the services connect with a URL, and base64 emits `/` and
-- `+`, so postgres://authenticator:Ab+c/Def@host/db stops parsing at the `/`
-- (`invalid integer value "Ab+c" for connection option "port"`). Exported
-- first, because a password generated inline is printed nowhere and the
-- services' connection strings need it next.
--
-- Run it as a SUPERUSER, and note that this is the only part that is. The
-- extension itself refuses to be installed by one:
--
--   REFUSING TO LOAD: current_user (postgres) is a cluster superuser.
--   Superusers bypass RLS unconditionally, so the owner-privileged views
--   below would return ALL rows to every caller.
--
-- That refusal is the whole reason this file exists. Creating a role is a
-- superuser action; owning the schema must not be. `CREATE EXTENSION percolate`
-- on its own therefore cannot work, whoever runs it: as a superuser it is
-- refused, and as anybody else the roles it needs do not exist yet. So the
-- roles come first, and then the extension is installed *by* app_owner.
--
-- The compose image does the same at initdb from its own script, which is why
-- `docker compose up` needs no bootstrap step. If you are using the image, you
-- do not need this file.
--
-- Idempotent: safe to run against a cluster that already has some of it.

\if :{?auth_pw} \else \set auth_pw 'authpass' \endif
\if :{?worker_pw} \else \set worker_pw 'workerpass' \endif

do $$
begin
    if current_setting('is_superuser') <> 'on' then
        raise exception
            'bootstrap.sql creates cluster roles, which needs a superuser. '
            'The extension itself is installed by app_owner further down, and '
            'refuses to load as a superuser -- that is the point of the split.';
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Roles. CLUSTER-level, so they are created once per cluster and a second
--    database reuses them -- which is why this cannot live inside the
--    extension, whose scope is one database.
--
--    Neither app_owner nor api_viewer may ever be a superuser. app_owner is
--    about to own every table in the collection, and a superuser owner makes
--    every policy inert while looking correct.
-- ---------------------------------------------------------------------------
-- A PASSWORD IS SET ONLY WHEN THE ROLE IS CREATED, never on a role that was
-- already there. Roles are cluster-level and so are their passwords, so
-- bootstrapping a SECOND database in a cluster that already runs Percolate
-- would otherwise reset the credentials the first one's services are using --
-- and the symptom is the other stack's PostgREST going into a restart loop on
-- "password authentication failed for user authenticator", some distance from
-- anything you just did. Found exactly that way.
--
-- The values come through set_config rather than as :variables because psql
-- does not substitute inside a dollar-quoted block; the loop would try to
-- create a role literally named :'auth_pw'. `true` makes them transaction-local
-- so they do not linger in the session -- which is why the BEGIN is here. psql
-- commits every statement on its own, so without it the settings were gone
-- before the loop below read them: both roles were created with an empty
-- password (`NOTICE: empty string is not a valid password, clearing password`)
-- and the script exited 0. `\gset` rather than a bare select, which printed
-- both passwords to the terminal.
begin;
select set_config('bootstrap.auth_pw',   :'auth_pw',   true) as _auth_pw,
       set_config('bootstrap.worker_pw', :'worker_pw', true) as _worker_pw \gset

do $$
declare
    r record;
    existed boolean;
begin
    for r in
        select * from (values
            ('app_owner',     'nologin',         null),
            ('api_viewer',    'nologin',         null),
            ('web_anon',      'nologin',         null),
            ('authenticated', 'nologin',         null),
            -- noinherit: authenticator holds web_anon and authenticated but
            -- must not USE their privileges except by SET ROLE, which is what
            -- makes per-request identity switching mean anything.
            ('authenticator', 'noinherit login', 'bootstrap.auth_pw'),
            -- The worker and Content Server connect as themselves and hold NO
            -- table grants; every interaction is a SECURITY DEFINER call. That
            -- is what makes "bring your own worker" safe to offer.
            ('worker',        'login',           'bootstrap.worker_pw'),
            -- LOGIN, because pg_cron connects over libpq as the job's user. A
            -- NOLOGIN scheduler means "connection failed" once a minute with
            -- the job still showing as active.
            ('scheduler',     'login',           null)
        ) as t(name, attrs, pw_setting)
    loop
        existed := exists (select 1 from pg_roles where rolname = r.name);
        if not existed then
            execute format('create role %I %s', r.name, r.attrs);
            if r.pw_setting is not null then
                execute format('alter role %I password %L',
                               r.name, current_setting(r.pw_setting));
            end if;
        elsif r.pw_setting is not null then
            raise notice 'role % already exists -- keeping its current password. '
                         'Change it with ALTER ROLE if you meant to.', r.name;
        end if;
    end loop;
end $$;
commit;

grant api_viewer    to app_owner;      -- so app_owner can hand it the views
grant web_anon      to authenticator;
grant authenticated to authenticator;
-- From 0.2.0 a workflow step runs as the person who started its run, through
-- api_viewer, which therefore needs what a signed-in person holds. The 0.2.0
-- extension refuses to install or upgrade without it, and names this line.
grant authenticated to api_viewer;

-- ---------------------------------------------------------------------------
-- 2. The extensions a non-superuser cannot install, and the room app_owner
--    needs to create things in this database.
-- ---------------------------------------------------------------------------
create extension if not exists vector;
create extension if not exists percolate_parser;

do $$ begin
    execute format('grant create on database %I to app_owner', current_database());
end $$;
grant create, usage on schema public to app_owner;

-- NOBODY A PERSON CAN BECOME MAY REWRITE WHO THEY ARE, from 0.2.0. Every row
-- rule reads the caller from `request.jwt.claims`, and set_config writes it:
-- through the SQL passthrough a signed-in user could put anyone's id there and
-- read as them. So set_config belongs to the roles that set identity on
-- someone's behalf. Per database, because a function's ACL lives in the
-- database. Conditional on the version this database will install, because
-- 0.1.x's passthrough still calls set_config as the caller and would stop
-- working; 0.2.0 refuses to install until this has run.
do $$
declare v text := (select default_version from pg_available_extensions where name = 'percolate');
begin
    if v is not null and string_to_array(v, '.')::int[] >= array[0, 2, 0] then
        revoke execute on function pg_catalog.set_config(text, text, boolean) from public;
        grant execute on function pg_catalog.set_config(text, text, boolean)
            to authenticator, app_owner, worker, scheduler;
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. The system itself, installed BY app_owner so that app_owner owns it.
--    `reset role` afterwards, so a psql session that continues does not keep
--    creating things as the schema owner by accident.
-- ---------------------------------------------------------------------------
set role app_owner;
create extension if not exists percolate cascade;
reset role;

-- ---------------------------------------------------------------------------
-- 4. The clock, if this server has one. Optional, and its absence is quiet in
--    exactly the wrong direction -- without it scheduled workflows never fire,
--    the reaper never recovers a crashed worker's tasks, and every timer step
--    waits forever, none of which produce an error.
--
--    pg_cron is a background worker, so no CREATE EXTENSION can add it after
--    startup: the server has to have been started with
--      -c shared_preload_libraries=pg_cron -c cron.database_name=<this db>
--
--    ONE set of jobs covers the whole deployment however many schedules you
--    have, because a schedule is a row rather than a cron entry.
-- ---------------------------------------------------------------------------
do $$
begin
    -- THREE conditions, and the third is the one that is easy to miss.
    -- cron.database_name names ONE database for the whole cluster, and
    -- `create extension pg_cron` in any other one fails outright:
    --   "can only create extension in database <name>". So a bootstrap that
    -- checked only for preloading would install cleanly in the database the
    -- setting happens to name and die at the last statement in every other.
    if exists (select 1 from pg_available_extensions where name = 'pg_cron')
       and coalesce(current_setting('shared_preload_libraries', true), '') like '%pg_cron%'
       and coalesce(current_setting('cron.database_name', true), 'postgres')
           = current_database()
    then
        create extension if not exists pg_cron;
        -- Scheduled AS scheduler in one call. cron.schedule() makes the job
        -- the caller's, and the rename that followed it collided with the row
        -- the previous run had already renamed (`jobname_username_uniq`), so
        -- the third run of an "idempotent" script failed. A job name that
        -- already exists for scheduler is updated in place.
        perform cron.schedule_in_database('workflow-tick',   '* * * * *',
                    'select workflow.tick()',               current_database(), 'scheduler');
        perform cron.schedule_in_database('workflow-reaper', '* * * * *',
                    'select workflow.reap_stale_tasks()',   current_database(), 'scheduler');
        perform cron.schedule_in_database('workflow-timers', '* * * * *',
                    'select workflow.promote_due_timers()', current_database(), 'scheduler');
        -- A FOURTH JOB, BECAUSE NOTHING DELETED A FINISHED RUN (REM-109).
        -- workflow.purge_completed shipped and was scheduled by no deployment,
        -- so an operator who left this running kept every run, task and
        -- task_event for ever. Disk is the least of it: workflow.queue_depth --
        -- what the autoscaler asks how much work there is -- degrades with the
        -- live-to-total row ratio, so at around 10k tasks/day the thing that
        -- decides how many workers to run gets slower for a quarter and then
        -- starts mattering.
        --
        -- Daily, not per-minute, because it is retention rather than clock
        -- work; 03:17 rather than 03:00 so it does not land with everything
        -- else on the hour. Its own defaults bound one pass (30 days, 50 runs
        -- a batch, 1000 batches), and the three jobs above are `scheduler` for
        -- the same reason this is: the function is SECURITY DEFINER and is
        -- granted to scheduler and to nobody else.
        perform cron.schedule_in_database('workflow-purge',  '17 3 * * *',
                    'select workflow.purge_completed()',    current_database(), 'scheduler');
        raise notice 'percolate: pg_cron scheduled -- tick, reaper, timers and purge are live';
        -- scheduler has no password, so a job that connects over libpq fails
        -- once a minute wherever pg_hba asks for one, and still shows active.
        if coalesce(current_setting('cron.use_background_workers', true), 'off') <> 'on' then
            raise notice 'percolate: cron.use_background_workers is off, so each job logs in '
                         'as scheduler over libpq -- set it to on, or give pg_hba a rule '
                         'that lets scheduler connect locally, or the jobs fail with '
                         '"connection failed" while cron.job shows them active.';
        end if;
    elsif coalesce(current_setting('shared_preload_libraries', true), '') like '%pg_cron%'
    then
        raise notice 'percolate: pg_cron is preloaded but cron.database_name is %, not '
                     '%. The clock runs in one database per cluster, so scheduled '
                     'workflows, the reaper and timer steps will not fire for this one.',
                     coalesce(current_setting('cron.database_name', true), 'postgres'),
                     current_database();
    else
        raise notice 'percolate: pg_cron is NOT preloaded, so scheduled workflows, the '
                     'stale-task reaper and timer steps will not fire. Start the server '
                     'with -c shared_preload_libraries=pg_cron -c cron.database_name=%',
                     current_database();
    end if;
end $$;

-- The last thing that has to happen, said here because the failure it prevents
-- is silent. rbac ships empty on purpose -- the alternative is a default
-- administrator with a known password -- and until somebody holds a role, every
-- `*_api` view correctly returns zero rows to everyone, which is indis-
-- tinguishable from an install that did not work. Being a superuser does not
-- reveal them either: RLS on those views is evaluated as their owner,
-- `api_viewer`, which is deliberately neither a superuser nor the table owner.
do $$
begin
    if not exists (select 1 from rbac.user_roles) then
        raise notice 'percolate: rbac is empty, so every *_api view will return no rows '
                     'to anyone yet. Make the first administrator with:  '
                     'select rbac.bootstrap_admin(''you@example.com'', ''a long passphrase'');';
    end if;
end $$;

select 'percolate ' || extversion || ' installed into ' || current_database()
  from pg_extension where extname = 'percolate';
