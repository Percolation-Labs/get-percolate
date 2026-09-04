# The harbour sample

A port-operations company: two tenants, four operators, five vessels, three
ports, a handful of inspections, a corpus of reports and a graph tying them
together. It is the domain every worked example in the
[documentation](https://percolation-labs.github.io/get-percolate) queries, so
loading it is what turns those pages from reading into running.

```bash
percolate sample load samples/harbour --as-email you@example.com
```

Nothing loads itself. A fresh install stays empty until you run that, which is
deliberate — rows that appear because a container started are rows nobody
chose, and a demo you cannot tell apart from a deployment is a bad demo.

## What it needs

**An embedding key**, in `LLM_API_KEY`. The corpus is uploaded through
`POST /files` and embedded by the running ingestion pipeline, so loading it
costs one embedding call per document.

That is the honest shape rather than an inconvenience. An earlier version of
this fixture shipped literal four-dimension vectors so it would load with
nothing running; it reproduced beautifully and taught the wrong thing, because
a reader who copied the pattern had a corpus no model had ever seen and
rankings that meant nothing. What you search here is what a model produced.

If you do not have a key yet:

```bash
percolate sample load samples/harbour --skip-documents --as-email you@example.com
```

`LOOKUP`, `FUZZY`, `GRAPH` and `TEXT` all work without it. Only `SEMANTIC` and
`SEARCH` need the vectors.

## Two tenants, so your token has to pick one

Most of what the sample loads is **tenanted**, and a token minted without an
`orgs` claim sees only the shared tier — the three ports and Nordvik
Chartering. That is the policies working, but it does not look like it:
`LOOKUP "Meridian Dawn"` comes back with zero rows and the name reported
unresolved, which reads as *the sample did not load* rather than *you are not
in that tenant*.

| Tenant | org id |
|---|---|
| Meridian | `d0000000-0000-0000-0000-00000000000a` |
| Kestrel | `d0000000-0000-0000-0000-00000000000b` |

```bash
percolate auth token --email you@example.com \
  --orgs d0000000-0000-0000-0000-00000000000a
```

```
LOOKUP "Meridian Dawn"    rows: 1    # your tenant
LOOKUP "Aurora Kestrel"   rows: 0    # Kestrel's, and correctly invisible
LOOKUP "Rotterdam"        rows: 1    # shared, visible to both
```

Swap the org id for the other one and the first two answers swap over. That is
the whole of scenario 4 in the [cookbook](https://percolation-labs.github.io/get-percolate/cookbook.html),
and it is worth doing once by hand: nothing in the query mentions an
organisation.

## What is in it

| File | What it is | Applied by |
|---|---|---|
| `schema.sql` | the company's own tables and rows | executed as SQL |
| `sources.yaml` | which tables are addressable, and the embedding model | `aiq.register_entity_table`, `register_embedding_space` |
| `graph.yaml` | the relation vocabulary, and edges named by key | `aiq.relation_types`, `aiq.edges` |
| `plugin.yaml` | skills and agents, as one removable bundle | `agentic.apply_plugin` |
| `workflows/` | workflow documents | `workflow.define_yaml` |
| `documents/` | the corpus, as markdown | `POST /files` |

Only `schema.sql` is SQL, and only because it is a company's own schema —
inventing a YAML dialect to describe `create table` would be describing SQL
badly. Everything Percolate adds is a document in the same format you would
author by hand, which is the second reason to read this directory: an agent
really is the JSON Schema document `agents.md` describes, and here is one.

## Loading it twice

Every step is idempotent **except the documents step**, so a second full run
needs care.

The Content Server addresses the *bytes* by content hash — a re-upload stores
nothing new — but it registers a **second resource row** pointing at them. Both
rows carry the same title, and the `document` entity's canonical key is
`coalesce(n.title, n.uri, n.id::text)` under a unique index on
`(org_id, key, entity_type)`. So the second resource's `parse` task collides:

```
duplicate key value violates unique constraint "idx_node_keys_canonical"
DETAIL: Key (org_id, key, entity_type)=(null, rotterdam psc report, document)
        already exists.
```

and, being classified retryable, burns its attempts before failing for good.
Nothing warns you at upload time; the 201 comes back as usual.

So use `--skip-documents` when reloading, unless you have removed the corpus
first:

```sql
delete from content.resources where channel_id =
  (select id from content.channels where name = 'harbour-reports');
```

This is a real limitation rather than a quirk of the sample — two documents
that share a title cannot both be registered, and a title is a free-form
header.

## Taking it out

`plugin.yaml` is applied as a named plugin, so its skills and agents come out
together. The rest is an ordinary schema:

```sql
select agentic.apply_plugin('{"name":"harbour","version":"1.0.0"}'::jsonb);
drop schema harbour cascade;
```

That is the install call with an empty manifest, not a second function: it
prunes each row through the path that knows what else references it, and
returns a receipt of what went.

```
{"agents": [], "plugin": "harbour", "skills": [], "tool_servers": [],
 "removed": ["agent:harbourmaster", "skill:harbour-house-style"], "version": "1.0.0"}
```

The registry rows and the corpus are left for you to remove deliberately —
`aiq.nodes` for the three entity types, and the `harbour-reports` resources —
because dropping indexed content is not something a sample should do on your
behalf.
