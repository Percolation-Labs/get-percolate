-- Prepare a PostgreSQL 19 you already run to hold Percolate.
--
--   psql -d yourdb -v ON_ERROR_STOP=1 \
--        -v auth_pw="$(openssl rand -base64 24)" \
--        -v worker_pw="$(openssl rand -base64 24)" \
--        -f bootstrap.sql
--
-- Run it as a SUPERUSER, and note that this is the only part that is. The
-- extension itself refuses to be installed by one:
--
--   REFUSING TO LOAD: current_user (postgres) is a cluster superuser.
--   Superusers bypass RLS unconditionally, so the owner-privileged views
--   below would silently return ALL rows to every caller.
--
-- That refusal is the whole reason this file exists. Creating a role is a
-- superuser action; owning the schema must not be. `CREATE EXTENSION percolate`
-- on its own therefore cannot work, whoever runs it: as a superuser it is
-- refused, and as anybody else the roles it needs do not exist yet. So the
-- roles come first, and then the extension is installed *by* app_owner.
--
-- The compose image runs exactly this at initdb, which is why `docker compose
-- up` needs no bootstrap step. If you are using the image, you do not need
-- this file.
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
-- so they do not linger in the session.
select set_config('bootstrap.auth_pw',   :'auth_pw',   true),
       set_config('bootstrap.worker_pw', :'worker_pw', true);

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

grant api_viewer    to app_owner;      -- so app_owner can hand it the views
grant web_anon      to authenticator;
grant authenticated to authenticator;

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
        perform cron.schedule('workflow-tick',   '* * * * *', 'select workflow.tick()');
        perform cron.schedule('workflow-reaper', '* * * * *', 'select workflow.reap_stale_tasks()');
        perform cron.schedule('workflow-timers', '* * * * *', 'select workflow.promote_due_timers()');
        update cron.job set username = 'scheduler'
         where jobname in ('workflow-tick','workflow-reaper','workflow-timers');
        raise notice 'percolate: pg_cron scheduled -- tick, reaper and timers are live';
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

select 'percolate ' || extversion || ' installed into ' || current_database()
  from pg_extension where extname = 'percolate';
