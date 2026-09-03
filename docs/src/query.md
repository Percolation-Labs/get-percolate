# Querying

One dialect over a property graph, a vector index and a lexical index. This page
is about what gets into the graph in the first place, and what a caller sees
when they ask.
{: .lede }

[The P8QL grammar](grammar-p8ql.html) is the reference for the eight modes and
every modifier, and [Graph algorithms](graph.html) is the page for the
questions a walk cannot answer at all — ranked relatedness, the best routes
between two things, what connects a result set, and what all of that costs. The four things a reference cannot tell you are who the dialect
is written for, which rows become nodes, why the property graph costs no
migration, and why a query can look empty when it is working correctly.

## Written for a model to write

P8QL exists because the caller doing most of the asking here is a language
model, and the modes are named after the moves an investigation is made of
rather than after the Postgres features that implement them. Resolve a name,
walk out from a thing, find things that mean the same, find things that say the
same, ask what exists at all.

What we are trying to do here is find a company from a name somebody typed
badly, and compare that against writing the same intent in SQL.
{: .goal }

```sql
select aiq.query('FUZZY LOOKUP "acme robotic" LIMIT 5');
```

```sql
-- the obvious hand-written equivalent
select n.entity_type, k.key, similarity(k.key, 'acme robotic') as score
from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
where k.key % 'acme robotic'
order by similarity(k.key, 'acme robotic') desc limit 5;
```

<div class="evidence" markdown="1">
<div class="label">the hand-written one, against the sample fixture</div>

```
 entity_type |      key      | score
-------------+---------------+-------
 company     | acme robotics | 0.800
 company     | acme          | 0.385
 company     | acme          | 0.385
```
</div>

<div class="evidence" markdown="1">
<div class="label">`FUZZY LOOKUP`, same string, same database</div>

```json
{"mode": "LOOKUP",
 "plan": {"ok": true, "args": ["acme robotic"], "fuzzy": true, "limit": 5, …},
 "rows": [{"node_id": "d767d1c8…", "entity_type": "company",
           "key": "acme robotics", "match_kind": "fuzzy", "score": 0.8,
           "input_key": "acme robotic"}],
 "unresolved": []}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the abstraction is over an investigation procedure, not
over one query</summary>

Those are the same company three times and the same company once. One node
carries three keys — `acme` canonical, `acme` short, `acme robotics` alias — so
the trigram query returns a row per matching *key*, and a caller that hydrates
each one fetches the same entity three times. `LOOKUP` answers "which nodes
match this string", which is the question that was actually asked, and it
reports which key matched so nothing is hidden by the deduplication.

The mode is also a cascade rather than a query: exact canonical first, then
short and alias, and only then trigram, each stage short-circuiting if it found
anything. Fuzzy matching a name that is spelled correctly is a way to get a
worse answer slowly, and that ordering is the sort of thing you write once
rather than in every prompt.

Each mode stands over a different Postgres feature — `pg_trgm` here, `pgvector`
under `SEMANTIC`, `tsvector` under `TEXT`, SQL/PGQ `GRAPH_TABLE` under `GRAPH` —
and a model writing raw SQL has to pick the right one, with the operator that
matches the index, and an embedding from the same model the column was written
with. The failures there are quiet ones: a distance operator that does not match
the opclass returns rows in the wrong order rather than an error, and a vector
from the wrong model returns a number rather than an error. The dialect turns
those into refusals — `SEMANTIC` will not run against a space written by a
different model, and a modifier that means nothing for a mode is rejected rather
than ignored.

Two things in the response are there for the same reason. `plan` is what the
parser understood, so a model can see that its query meant what it thought
before reading a single row, and `unresolved` names which of the keys it asked
for came back with nothing — the difference between "no such company" and "that
company has no edges", which is the distinction an agent most often gets wrong.

None of this is an attempt to stop anyone writing SQL. Plain SQL is a mode of
the dialect precisely because these seven will not cover a real question, and
the escape hatch is the floor everything else sits on.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html">every mode and modifier</a> ·
<a href="#start-by-asking-what-can-be-asked">the mode that describes the
others</a> ·
<a href="agents.html#tools-are-external-and-they-are-rows">how an agent reaches
this over MCP</a></p>
</details>

## Start by asking what can be asked

What we are trying to do here is find out what this database holds, before
writing a query against it.
{: .goal }

```sql
select aiq.query('SCHEMA');
select aiq.query('SCHEMA "graph"');
```

<details class="why" markdown="1">
<summary>Why it works — the capability document is derived where it can be and
verified where it cannot</summary>

`SCHEMA` is the mode an agent reads before writing its first query, and it is a
versioned capability document rather than a dump. Anything the catalog can prove
is read from it — entity types off the registry, relations off the edge
catalogue, models off `aiq.embedding_models`. Anything a catalog cannot express
is written by hand, and then every hand-written example is run back through the
compiler on each read.

That last part is what makes it trustworthy. A spelling this deployment no
longer accepts reports itself instead of being served to an agent as
authoritative, which a static document cannot do.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#asking-the-database-what-it-is">the `SCHEMA`
syntax</a> ·
<a href="grammar-workflow.html#getting-this-page-from-your-own-database">the
same mechanism for workflows</a></p>
</details>

## Identity: what becomes a node

A row becomes a node if you can find it with `LOOKUP`, or if it is the endpoint
of an edge. A document is both, since you name it and events reference it. A
chunk is neither.

What we are trying to do here is get a table into the graph without copying it.
{: .goal }

```sql
select aiq.register_entity_table(
    p_entity_type  => 'vessel',
    p_source_table => 'harbour.vessels',
    p_key_expr     => 'lower(n.name)',
    p_summary_expr => $$n.name || ' (IMO ' || n.imo || ')'$$,
    p_include_where => $$n.status <> 'scrapped'$$);
```

<details class="why" markdown="1">
<summary>Why it works — the registry is a curated index, not a second copy of
your data</summary>

Registration records how to *read* your table as nodes rather than copying rows
into a parallel store. The projection is kept in step by a statement-level
trigger, so writing ten thousand included rows costs one set `INSERT` into
`nodes` and `node_keys` rather than ten thousand trigger firings, and a bulk
`COPY` disables it and pays one rebuild pass instead.

Letting chunks in would put the registry on the wrong side of the scale
argument: a chunk is machine-generated volume that joins in *after* identity is
already known. The same rule is why a workflow artefact gets the `stored`
resource status rather than `ready` — step output is machine-generated too.

`include_where` is why a scrapped vessel stays in your table and stops being an
identity anybody can look up. Nothing is deleted; it simply stops being findable
by name.

There is a second way in. An uploaded file can be read by a structured-output
extractor whose nodes and edges land through `aiq.upsert_graph`, so the things
your documents *mention* sit in the graph beside the things your tables *hold*.
That is a flag on the ingestion pipeline and it is off by default, because an
embedding per chunk is cheap and a completion per window is a different order of
money.

<p class="related"><strong>Related</strong>
<a href="ingest.html">the extraction path</a> ·
<a href="cookbook.html#the-domain">a fixture where the inclusion policy is
visible</a></p>
</details>

## The property graph costs no migration

What we are trying to do here is query a graph without having adopted a graph
database.
{: .goal }

```sql
select * from aiq.nodes where entity_type = 'vessel';   -- ordinary SQL
select aiq.query('GRAPH "Bulk Harmony" DEPTH 2');       -- the same rows, walked
```

<details class="why" markdown="1">
<summary>Why it works — SQL/PGQ defines a property graph as a view over ordinary
tables</summary>

`CREATE PROPERTY GRAPH` in PG19 is read-only catalog metadata over
`nodes`, `edges` and hard-link junctions, compiled to ordinary joins at query
time. There is no separate graph store, no migration to adopt it, and no second
copy of anything to keep in step — which is the whole reason this collection
targets PG19 rather than bolting a graph layer on.

One PG19 limitation is worth knowing before you run into it: element pattern
quantifiers are not supported, so variable-length paths use `DEPTH` rather than
`{1,3}` syntax.

<p class="related"><strong>Related</strong>
<a href="index.html#what-it-costs">why this pins you to PG19</a> ·
<a href="grammar-p8ql.html#walking-out-from-a-node">the `GRAPH` mode</a></p>
</details>

## Over REST, and the two things that look like bugs

What we are trying to do here is query as a real caller, with their own identity
attached.
{: .goal }

```
POST /rpc/query   {"p_query": "LOOKUP \"acme\""}
```

<details class="why" markdown="1">
<summary>Why it works — and why an empty result is usually correct</summary>

RLS applies, so results come back filtered to what the caller can see. Two
things make results look like they are missing, and neither is a bug.

**Querying as a superuser** bypasses RLS unconditionally, so you see *more*
rather than less, and the filtered views start behaving oddly around you. This
is the failure this collection refuses to install into: every schema checks at
load time that its owner is not a superuser, because an owner-privileged view
owned by one silently disables RLS for every caller of that view.

**No token at all** is not narrow visibility, it is a wall: PostgREST falls back
to `web_anon`, which holds no table grants and no `usage` on `aiq`, so
`/rpc/query` answers `permission denied for schema aiq` with a 401. That is a
different failure from the one below and it says so.

**A token with no `orgs` claim** is the quiet one. It authenticates, RLS applies,
and tenanted rows are simply not there — so the query succeeds, returns zero
rows, and `LOOKUP` reports the name unresolved. Nothing distinguishes that from
data you never loaded, which is why it is worth minting the claim deliberately:

```bash
percolate auth token --email you@example.com --orgs <org-uuid>
```

The fix in both cases is the identity, not a policy change.

**Reading a base table over REST** is also a 403 by design — `authenticated`
holds grants on the `_api` views, not on `agentic.agents` or `aiq.nodes`
themselves. `GET /agents_api` is the readable surface; the base tables are
reached through the `SECURITY DEFINER` functions and nothing else.

Row-level security here is inside the ranking rather than a filter applied after
it, which is worth seeing once — the cookbook runs one `SEARCH` under two claims
and the *order* of the results changes, not only their number.

<p class="related"><strong>Related</strong>
<a href="cookbook.html#4-two-tenants-one-table">the same query under two
claims</a> ·
<a href="operating.html">what to watch in production</a></p>
</details>

Next: [the P8QL grammar](grammar-p8ql.html) for the modes themselves, or
[operating it](operating.html).
