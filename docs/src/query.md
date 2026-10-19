# Querying

One dialect over a property graph, a vector index and a lexical index. This page
is about what gets into the graph in the first place, and what a caller sees
when they ask.
{: .lede }

[The P8QL grammar](grammar-p8ql.html) is the reference for the nine modes and
every modifier, and [Graph algorithms](graph.html) is the page for the
questions a walk cannot answer at all — ranked relatedness, the best routes
between two things, what connects a result set, and what all of that costs. The
four things a reference cannot tell you are who the dialect
is written for, which rows become nodes, why the property graph costs no
migration, and why a query can look empty when it is working correctly.

## Written for a model to write

P8QL exists because the caller doing most of the asking here is a language
model, and the modes are named after the moves an investigation is made of
rather than after the Postgres features that implement them. Resolve a name,
walk out from a thing, find things that mean the same, find things that say the
same, ask what exists at all.

Here we find an operator from a name somebody typed badly, and compare that
against writing the same intent in SQL.
{: .goal }

<!-- run: sql as:tenant-a -->
```sql
select aiq.query('FUZZY LOOKUP "meridien" LIMIT 5');
```

<!-- run: sql as:tenant-a -->
```sql
-- the obvious hand-written equivalent
select n.entity_type, k.key,
       round(similarity(k.key, 'meridien')::numeric, 3) as score
from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
where k.key % 'meridien'
order by score desc, k.key limit 5;
```

<div class="evidence" markdown="1">
<div class="label">the hand-written one, against the harbour fixture</div>

```
 entity_type |      key      | score
-------------+---------------+-------
 operator    | meridian      | 0.500
 operator    | meri          | 0.400
 operator    | meridian bulk | 0.353
 vessel      | meridian dawn | 0.353
 vessel      | meridian star | 0.353
```
</div>

<div class="evidence" markdown="1">
<div class="label">`FUZZY LOOKUP`, same string, same database</div>

```json
{"mode": "LOOKUP",
 "plan": {"ok": true, "args": ["meridien"], "fuzzy": true, "limit": 5, …},
 "rows": [{"node_id": "1cf8519b…", "entity_type": "operator",
           "key": "meridian", "match_kind": "fuzzy", "score": 0.5,
           "input_key": "meridien"},
          {"node_id": "d18825eb…", "entity_type": "operator",
           "key": "meridian bulk", "match_kind": "fuzzy", "score": 0.3529412,
           "input_key": "meridien"},
          {"node_id": "eac3f853…", "entity_type": "vessel",
           "key": "meridian dawn", "match_kind": "fuzzy", "score": 0.3529412,
           "input_key": "meridien"},
          {"node_id": "fbaa9eb3…", "entity_type": "vessel",
           "key": "meridian star", "match_kind": "fuzzy", "score": 0.3529412,
           "input_key": "meridien"}],
 "unresolved": []}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the abstraction is over an investigation procedure, not
over one query</summary>

Those are five keys and four things. Meridian Line carries two of them — `meri`
canonical and `meridian` short — so the trigram query returns a row per matching
*key*, and a caller that hydrates each one fetches the same operator twice.
`LOOKUP` answers "which nodes match this string", which is the question that was
actually asked, so it returns the operator once and reports which key matched,
and nothing is hidden by the deduplication.

The mode is also a cascade rather than a query: exact canonical first, then
short and alias, and only then trigram, each stage short-circuiting if it found
anything. You can watch it short-circuit — `FUZZY LOOKUP "meridian"` comes back
with `"match_kind": "short"` and `"score": 1`, having never reached the trigram
stage, because the string it was given is a key that exists. Fuzzy matching a
name that is spelled correctly is a way to get a worse answer slowly, and that
ordering is the sort of thing you write once rather than in every prompt.

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

Here we find out what this database holds, before writing a query against it.
{: .goal }

<!-- run: sql -->
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

Here we get a table into the graph without copying it.
{: .goal }

<!-- run: sql -->
```sql
select aiq.register_entity_table(
    p_entity_type   => 'vessel',
    p_source_table  => 'harbour.vessels',
    p_key_expr      => 'n.name',
    p_summary_expr  => $$n.name || ' (IMO ' || n.imo || ')'$$,
    p_org_expr      => 'n.org_id',
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

`org_expr` is what keeps a tenant's vessel its tenant's. This is the sample's
own registration, repeated, and registering again replaces the whole row — so
an argument you leave out goes back to its default rather than keeping what was
there. Without `p_org_expr` the default is `null`, and the next rebuild projects
every vessel with no org and `visibility = public`, readable by every tenant.

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

Here we query a graph without having adopted a graph database.
{: .goal }

<!-- run: sql as:tenant-a -->
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

One PG19 limitation to know before you run into it: element pattern
quantifiers are not supported, so variable-length paths use `DEPTH` rather than
`{1,3}` syntax.

<p class="related"><strong>Related</strong>
<a href="index.html#what-it-costs">why this pins you to PG19</a> ·
<a href="grammar-p8ql.html#walking-out-from-a-node">the `GRAPH` mode</a></p>
</details>

## Over REST, and the two things that look like bugs

Here we query as a real caller, with their own identity attached.
{: .goal }

```bash
curl -X POST http://localhost:3000/rpc/query \
  -H 'Content-Type: application/json' \
  -H 'Content-Profile: aiq' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"p_query": "LOOKUP \"meridian\""}'
```

**`Content-Profile: aiq` is not optional.** PostgREST exposes several schemas
and the *first* one in `PGRST_DB_SCHEMAS` is the default, which in the shipped
compose file is `content` — so a `POST /rpc/query` without the header looks for
`content.query`, does not find it, and answers `404` with `PGRST202: Could not
find the function content.query`. That reads like the function was never
installed. It is there; you asked the wrong schema for it. Reads use
`Accept-Profile` and writes and RPC use `Content-Profile`.

**`SEARCH` and `SEMANTIC` need the vector as well.** `/rpc/query` is
`aiq.query(p_query, p_embedding)`, and the database makes no model calls, so a
vector mode sent with `p_query` alone answers `400` with `SEARCH fuses lexical
and semantic ranks, so it needs p_embedding`. Embed the text with the model the
corpus was embedded with, and send the array as `p_embedding`, a JSON string, as
the workbench does:

```bash
VEC=$(curl -s https://api.openai.com/v1/embeddings \
  -H "Authorization: Bearer $LLM_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model": "text-embedding-3-small", "input": "PSC-441 boiler"}' \
  | jq -c '.data[0].embedding')

curl -X POST http://localhost:3000/rpc/query \
  -H 'Content-Type: application/json' \
  -H 'Content-Profile: aiq' \
  -H "Authorization: Bearer $TOKEN" \
  -d "$(jq -n --arg q 'SEARCH "PSC-441 boiler" FROM chunks LIMIT 3' --arg v "$VEC" \
        '{p_query: $q, p_embedding: $v}')"
```

`TEXT "PSC-441" FROM chunks` is the lexical half on its own, and needs no
vector over REST or anywhere else.

<details class="why" markdown="1">
<summary>Why it works — and why an empty result is usually correct</summary>

RLS applies, so results come back filtered to what the caller can see. Two
things make results look like they are missing, and neither is a bug.

**Querying as a superuser** bypasses RLS unconditionally, so you see *more*
rather than less, and the filtered views start behaving oddly around you. This
is the failure this collection refuses to install into: every schema checks at
load time that its owner is not a superuser, because an owner-privileged view
owned by one disables RLS for every caller of that view, without a word.

**No token at all** is not narrow visibility, it is a wall: PostgREST falls back
to `web_anon`, which holds no table grants and no `usage` on `aiq`, so
`/rpc/query` answers `permission denied for schema aiq` with a 401. That is a
different failure from the one below and it says so.

**A token with no `orgs` claim** is the quiet one. It authenticates, RLS
applies,
and tenanted rows are simply not there — so the query succeeds, returns zero
rows, and `LOOKUP` reports the name unresolved. Nothing distinguishes that from
data you never loaded, which is why the claim is worth minting with care:

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

## Following a relation you cannot name

`GRAPH` walks a relation you name. Sometimes the question is only "how does
this reach a port?", and the relation is whatever the data turns out to hold.

Here we start from Meridian's bulk operator and ask for the ports it reaches,
without saying how.
{: .goal }

<!-- run: sql as:tenant-a -->
```sql
select aiq.sql_passthrough($q$
  select round, key, entity_type, resolved, path
    from aiq.iterated_join('merb', 'port', 3)$q$);
```

<div class="evidence" markdown="1">
<div class="label">the walk, as the Meridian reader</div>

```
[{"key": "rotterdam", "round": 2, "resolved": true, "entity_type": "port",
  "path": [{"from": "merb (operator)", "to": "bulk harmony (vessel)",
            "via": "operated_by (inverse)", "link": "edge", "score": 1.000},
           {"from": "bulk harmony (vessel)", "to": "rotterdam (port)",
            "via": "last_called", "link": "edge", "score": 1.000}]}]
```
</div>

<details class="why" markdown="1">
<summary>Why it works — every hop says which kind of link it was, and the walk
has a stated bound</summary>

`aiq.iterated_join(seed, target_type, max_rounds, …)` walks out from one node a
round at a time until it reaches nodes of the target type. Each hop is one of
four kinds of link, and `path` names which: a stored edge of any relation,
walked either way; a key two nodes share; a name similar above a threshold
(`p_similarity`, never "the nearest k", so a weak match is not promoted for
being the best of a bad lot); or a judge's verdict. The judged kind needs a
function named in `percolate.link_judge`, and asking for it without one is
refused by name, because a model call cannot run inside the statement.

The bound is part of the call. `max_rounds` must be between 1 and 5, a round
that has more candidates than `p_budget` defers the rest to the next round
rather than dropping them, and a walk that reaches nothing returns one row
with `resolved` false saying so, instead of an empty result that looks like a
missing fixture. The seed must name exactly one node: a key two nodes hold is
refused, rather than walked from whichever came first.

It is a function, so P8QL reaches it through its SQL mode, which `aiq.query`
plans and `aiq.sql_passthrough` runs as the caller.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#plain-sql-is-a-mode">SQL as a mode</a> ·
<a href="graph.html">graph algorithms</a></p>
</details>

## Finding a question by what it means

A person rarely asks a question in the words somebody else filed it under, so
questions are searched by meaning, and each answer comes with the stances of
the claims that answer it.

Here we file two questions, answer one, and find it from a differently worded
question. The block signs you in as yourself, a member of Meridian, so the
questions are yours and the next section can read Meridian's facts.
{: .goal }

<!-- run: sql -->
```sql
insert into rbac.org_members (org_id, user_id)
select 'd0000000-0000-0000-0000-00000000000a', id from rbac.users where email = 'me@example.com'
on conflict do nothing;

select set_config('request.jwt.claims', json_build_object(
         'sub', (select id from rbac.users where email = 'me@example.com'),
         'orgs', json_build_array('d0000000-0000-0000-0000-00000000000a'))::text, false) is not null as signed_in;

insert into aiq.embedding_models (name, dim, provider, endpoint, is_default, notes)
values ('tour-3d', 3, 'openai', 'https://example.invalid/v1/embeddings', false,
        'three dimensions, written by hand, so this page runs without a model');
select aiq.register_embedding_space('tour-3d') is not null as space_ready;

select (research.submit_package('{"schema_version": "0.1", "title": "Port state control",
  "visibility": "listed", "edges": [],
  "claims": [{"id": "C1", "kind": "Inference",
              "text": "Detentions follow inspections that find structural faults.",
              "source_ids": ["S1"]}],
  "sources": [{"id": "S1", "title": "Detention list", "url": "https://example.com/psc",
               "origin": "Tour"}]}')->>'revision_id') as rev \gset

select claims.pose_question('Does a detention usually follow a structural fault?') as q_detention \gset
select claims.pose_question('Should pilots board at the outer buoy?') as q_pilots \gset
select claims.propose_answer(:'rev', 'C1', :'q_detention', 'yes') is not null as answered;

insert into aiq.emb_tour_3d (chunk_id, embedding) values
  (:'q_detention', '[1, 0, 0]'), (:'q_pilots', '[0, 1, 0]');

select phrasing, round(distance::numeric, 3) as distance, within, yes, no, depends
  from claims.find_question('[0.9, 0.1, 0]'::vector, 0.5, 2, 'tour-3d');
```

<div class="evidence" markdown="1">
<div class="label">the nearest questions to the vector [0.9, 0.1, 0]</div>

```
                      phrasing                       | distance | within | yes | no | depends
-----------------------------------------------------+----------+--------+-----+----+---------
 Does a detention usually follow a structural fault? |    0.006 | t      |   1 |  0 |       0
 Should pilots board at the outer buoy?              |    0.890 | f      |   0 |  0 |       0
(2 rows)
```
</div>

A question's answer can be read as of any date, and `claims.stance_changes`
says which claims moved it between two:

<!-- run: sql -->
```sql
select claim_key, stance_then, stance_now, change
  from claims.stance_changes(:'q_detention', now() - interval '1 day');
```

<div class="evidence" markdown="1">
<div class="label">what changed in the last day</div>

```
 claim_key | stance_then | stance_now | change
-----------+-------------+------------+--------
 C1        |             | yes        | added
(1 row)
```
</div>

<details class="why" markdown="1">
<summary>Why it works — a question is a corpus like any other, and distance ranks
without deciding</summary>

A question's text, its phrasing or else its frame's subject and outcome, is
registered as the semantic source `questions`, so its vectors live in a model's
embedding space keyed by the question's id, beside the chunks and claims.
`claims.find_question(vector, max_distance, limit, model, at)` returns the
nearest questions the caller may read, each with `within`, whether it falls
inside the distance the caller set. The floor has no default, because what
counts as close depends on the model, and "nothing close enough" is an answer:
the nearest question is still shown, so the caller sees what it missed.

The vectors above are written by hand so the page runs without a model. On a
deployment, `claims.install_question_embed_workflow(model)` defines a workflow
that embeds every question a space lacks, through the model's HTTP endpoint,
and the query vector is embedded the same way, as for `SEMANTIC`. A question is
readable only when a work the caller may read answers it, so a question nobody
has answered is not found at all, by meaning or by words.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#the-three-search-modes-and-why-there-are-three">the
search modes</a> ·
<a href="#over-rest-and-the-two-things-that-look-like-bugs">sending a vector
over REST</a></p>
</details>

## A remembered fact bears on a question

The memory graph holds facts and the questions graph holds arguments, and a link
between them says that a fact matters to a question, without saying what the
fact concludes.

Here we propose that a vessel's last port of call bears on the detention
question, and read the link from both ends.
{: .goal }

<!-- run: sql -->
```sql
select e.id as fact from aiq.edges e
  join aiq.nodes s on s.id = e.src_id
 where e.relation = 'last_called' and s.summary like 'Bulk Harmony%' \gset

select claims.propose_bears_on(:'fact', :'q_detention', 0.7) is not null as proposed;

select phrasing, status, p from claims.questions_of_fact(:'fact');
select content, status, p from claims.facts_on_question(:'q_detention');

select set_config('request.jwt.claims', '', false);
```

<div class="evidence" markdown="1">
<div class="label">the link, read from the fact and from the question</div>

```
                      phrasing                       |  status  |  p
-----------------------------------------------------+----------+-----
 Does a detention usually follow a structural fault? | proposed | 0.7
(1 row)

                            content                            |  status  |  p
---------------------------------------------------------------+----------+-----
 Bulk Harmony (IMO 9407711) last called Rotterdam, Netherlands | proposed | 0.7
(1 row)
```
</div>

<details class="why" markdown="1">
<summary>Why it works — a link, never a verdict, and readable only with both of
its ends</summary>

`claims.bears_on` records who proposed a link and with what probability, and
later whether a person confirmed or disputed it, as new rows rather than edits.
It carries no stance: what the fact says about the question is read from the
fact by whoever reads it, and a stored stance would be a conclusion the graph
drew for them. An agent's proposal and a person's both land `proposed`, and only
a person can confirm one, with `claims.review_bears_on`.

A link is visible only to a caller who may read the fact and the question, so a
link can never disclose either. On a deployment the proposals come from a
workflow, `claims.install_fact_question_workflow`, which offers each unlinked
fact its nearest questions by distance and lets a decider choose among them or
"none of these": distance says where to look, and never makes the link.

<p class="related"><strong>Related</strong>
<a href="graph.html#a-fact-is-no-more-visible-than-the-memory-it-came-from">a
fact's visibility</a> ·
<a href="#finding-a-question-by-what-it-means">finding a question</a></p>
</details>

Next: [graph algorithms](graph.html), which asks harder questions of the same
graph; [the P8QL grammar](grammar-p8ql.html) has the modes themselves.
