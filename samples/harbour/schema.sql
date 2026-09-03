-- The harbour domain: ordinary tables that existed before Percolate did.
--
-- This is the one part of the sample that is SQL rather than YAML, and
-- deliberately so. Everything Percolate adds -- which entities are addressable,
-- what the graph means, which agents exist, what the workflows are -- is a
-- document you can read in the files beside this one. What is HERE is just a
-- port-operations company's own schema, and inventing a YAML dialect to
-- describe `create table` would be describing SQL badly.
--
-- That split is the sample's argument in miniature: Percolate indexes tables
-- you already have. Nothing below mentions Percolate.
--
-- Two tenants and a shared tier. A port is legitimately global -- duplicating
-- Rotterdam per shipping line would defeat the point of one identity registry
-- -- so shared rows carry a null org and the policies treat that as visible to
-- everyone rather than as missing data.

-- Owned by app_owner, not by whoever is connected. `percolate` installs
-- everything it creates under a non-superuser on purpose -- a superuser
-- bypasses row-level security unconditionally, which would leave every policy
-- in the collection inert while looking correct -- and a sample that created
-- its tables as the superuser would be the exception that quietly undoes it.
--
-- It is also required rather than tidy. `execute_sql_step` is SECURITY
-- DEFINER and runs as app_owner, so a step function in a schema app_owner
-- cannot reach registers fine and then fails at every invocation with
-- "permission denied for schema harbour". register_step_function refuses the
-- registration rather than letting that happen, which is how this comment
-- came to be here.
set role app_owner;

create schema if not exists harbour;
grant usage on schema harbour to app_owner;

create table if not exists harbour.operators (
    id        uuid primary key,
    name      text not null,
    code      text,
    parent_id uuid references harbour.operators(id),
    org_id    uuid
);

create table if not exists harbour.vessels (
    id          uuid primary key,
    name        text not null,
    imo         text not null,
    operator_id uuid references harbour.operators(id),
    status      text not null default 'in_service',
    org_id      uuid
);

create table if not exists harbour.ports (
    id      uuid primary key,
    name    text not null,
    country text not null,
    org_id  uuid
);

-- Inspections are rows a query answers FROM. They are not identities anyone
-- looks up by name, so they are never registered as an entity type -- which is
-- the distinction the registry exists to make.
create table if not exists harbour.inspections (
    id              uuid primary key,
    vessel_id       uuid references harbour.vessels(id),
    port_id         uuid references harbour.ports(id),
    inspected_at    date not null,
    outcome         text not null,
    deficiency_code text,
    org_id          uuid
);

-- ---------------------------------------------------------------------------
-- The data. Fixed uuids so the sample is idempotent and so the documents
-- beside it can refer to these vessels by name and mean these rows.
-- ---------------------------------------------------------------------------
insert into harbour.operators (id, name, code, parent_id, org_id) values
    ('40000000-0000-0000-0000-000000000001','Meridian Line','MERI',null,'d0000000-0000-0000-0000-00000000000a'),
    ('40000000-0000-0000-0000-000000000002','Kestrel Shipping','KEST',null,'d0000000-0000-0000-0000-00000000000b'),
    ('40000000-0000-0000-0000-000000000003','Meridian Bulk','MERB','40000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-00000000000a'),
    -- Shared: a chartering house both lines use, owned by neither.
    ('40000000-0000-0000-0000-000000000004','Nordvik Chartering','NORD',null,null)
on conflict (id) do update set
    name = excluded.name, code = excluded.code,
    parent_id = excluded.parent_id, org_id = excluded.org_id;

insert into harbour.vessels (id, name, imo, operator_id, status, org_id) values
    ('50000000-0000-0000-0000-000000000001','Meridian Dawn','9331802','40000000-0000-0000-0000-000000000001','in_service','d0000000-0000-0000-0000-00000000000a'),
    ('50000000-0000-0000-0000-000000000002','Meridian Star','9331803','40000000-0000-0000-0000-000000000001','in_service','d0000000-0000-0000-0000-00000000000a'),
    ('50000000-0000-0000-0000-000000000003','Bulk Harmony','9407711','40000000-0000-0000-0000-000000000003','in_service','d0000000-0000-0000-0000-00000000000a'),
    ('50000000-0000-0000-0000-000000000004','Aurora Kestrel','9214578','40000000-0000-0000-0000-000000000002','in_service','d0000000-0000-0000-0000-00000000000b'),
    -- Scrapped, and therefore excluded by the vessel registration's
    -- include_where. An inclusion predicate that never excludes anything
    -- proves nothing, so the sample carries one row for it to exclude.
    ('50000000-0000-0000-0000-000000000005','Old Pelican','8811234','40000000-0000-0000-0000-000000000004','scrapped',null)
on conflict (id) do update set
    name = excluded.name, imo = excluded.imo,
    operator_id = excluded.operator_id, status = excluded.status,
    org_id = excluded.org_id;

insert into harbour.ports (id, name, country, org_id) values
    ('60000000-0000-0000-0000-000000000001','Rotterdam','Netherlands',null),
    ('60000000-0000-0000-0000-000000000002','Felixstowe','United Kingdom',null),
    ('60000000-0000-0000-0000-000000000003','Gothenburg','Sweden',null)
on conflict (id) do update set name = excluded.name, country = excluded.country;

insert into harbour.inspections (id, vessel_id, port_id, inspected_at, outcome, deficiency_code, org_id) values
    ('70000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001','2026-06-14','deficiency','PSC-441','d0000000-0000-0000-0000-00000000000a'),
    ('70000000-0000-0000-0000-000000000002','50000000-0000-0000-0000-000000000002','60000000-0000-0000-0000-000000000002','2026-07-02','clear',null,'d0000000-0000-0000-0000-00000000000a'),
    ('70000000-0000-0000-0000-000000000003','50000000-0000-0000-0000-000000000003','60000000-0000-0000-0000-000000000001','2026-03-19','deficiency','PSC-441','d0000000-0000-0000-0000-00000000000a'),
    ('70000000-0000-0000-0000-000000000004','50000000-0000-0000-0000-000000000004','60000000-0000-0000-0000-000000000003','2026-07-11','clear',null,'d0000000-0000-0000-0000-00000000000b')
on conflict (id) do update set
    outcome = excluded.outcome, deficiency_code = excluded.deficiency_code;

-- ---------------------------------------------------------------------------
-- One step function, for the fan-out example.
--
-- `matrix: rows:` names a function in the workflow.step_functions allow-list
-- rather than taking an inline SELECT, so a workflow document cannot smuggle
-- arbitrary SQL past the compiler. Registering one is the price of that, and
-- it is also where the query deciding the fan-out width actually lives.
-- ---------------------------------------------------------------------------
create or replace function harbour.deficient_vessels()
returns jsonb language sql stable as $f$
    select coalesce(jsonb_agg(jsonb_build_object(
               'vessel', v.name, 'imo', v.imo, 'code', i.deficiency_code)
               order by v.name), '[]'::jsonb)
    from harbour.inspections i
    join harbour.vessels v on v.id = i.vessel_id
    where i.outcome = 'deficiency';
$f$;

select workflow.register_step_function(
    'deficient_vessels', 'harbour.deficient_vessels', '{}',
    p_description => 'vessels with an open PSC deficiency, one row each');
