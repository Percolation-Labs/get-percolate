# Querying

One dialect over a property graph, a vector index and a lexical index. This page
is about what gets into the graph in the first place, and what a caller sees
when they ask.
{: .lede }

[The P8QL grammar](grammar-p8ql.html) is the reference for the seven modes and
every modifier. The three things a reference cannot tell you are which rows
become nodes, why the property graph costs no migration, and why a query can
look empty when it is working correctly.

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
    p_summary_expr => "n.name || ' (IMO ' || n.imo || ')'",
    p_include_where => "n.status <> 'scrapped'");
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

**Forgetting `request.jwt.claims`** leaves the caller anonymous, which is a
legitimate identity with legitimately narrow visibility. The fix is the claim,
not a policy change.

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
