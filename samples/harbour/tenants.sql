-- The two tenants this sample belongs to, as rows Percolate can point at.
--
-- SEPARATE FROM schema.sql ON PURPOSE, and the split is that file's whole
-- argument: `schema.sql` is a port-operations company's own schema and
-- deliberately mentions nothing about Percolate. An organisation IS a Percolate
-- concern -- `rbac.orgs` is the identity registry every policy scopes against --
-- so it does not belong in a file whose point is that it could have existed
-- before Percolate did.
--
-- WHY THIS FILE EXISTS AT ALL, which is worth recording because the sample ran
-- for several releases without it. Every row in `schema.sql` carries
-- `d0000000-...-000a` or `...-000b` as its org, and nothing created those orgs.
-- On 0.1.3 that was invisible: `aiq.nodes.org_id` was a bare uuid referencing
-- nothing, so the sample loaded, and its nodes belonged to an organisation that
-- did not exist. 0.1.4's scope work made org_id a real foreign key, and
-- `add_scope_columns` says exactly why -- "an org_id naming no org was a row
-- nobody could ever see and nothing could report."
--
-- So the load began failing with
--
--     insert or update on table "nodes" violates foreign key constraint
--     "nodes_org_id_fkey" -- Key (org_id)=(d0000000-...-000a) is not present
--
-- and the foreign key was right: it found a defect the sample had shipped with.
-- Caught by dev/release-rehearsal.sh running the published install guide
-- against a locally built 0.1.4, which is the stage that exists for exactly
-- this -- the four before it were green.
--
-- IDEMPOTENT, like every other step here: `sample load` is documented as safe
-- to re-run, and a second run is how you pick up an edit.

insert into rbac.orgs (id, slug, name) values
    ('d0000000-0000-0000-0000-00000000000a', 'meridian', 'Meridian Line'),
    ('d0000000-0000-0000-0000-00000000000b', 'kestrel',  'Kestrel Shipping')
on conflict (id) do update
    set slug = excluded.slug,
        name = excluded.name;
