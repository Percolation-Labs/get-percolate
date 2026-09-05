# Graph algorithms

`GRAPH` walks. These rank, bound and search — the questions a walk cannot
answer, compiled into the extension because they are not expressible as a
query. They ship switched off, and this page starts there.
{: .lede }

[Querying](query.html) is the page for the dialect, and `GRAPH` is the right
tool for one and two hops — it is a hundred times faster than
anything here at that distance. What follows is for the questions that need a
*ranking* rather than a neighbourhood, a *bound* rather than a depth cap, or a
search over a space too large to enumerate: what is most related to this, how
are these two connected, what connects these eight, and how much of the answer
rests on a model's guess.

Every example on this page ran against the [harbour
fixture](cookbook.html#the-domain) — four operators, five vessels, three ports,
nine edges — and the output is what it produced. Nine edges is small on
purpose: every answer below can be checked by eye. What the same calls cost on
a graph of four million edges is measured rather than guessed, and it is at the
bottom of the page.

## Nothing is callable until you say so

They install with the extension and are granted to nobody. A fresh database has
the functions present, inert, and unreachable through PostgREST.

What we are trying to do here is turn them on for the role your API calls
arrive as.
{: .goal }

<!-- run: sql -->
```sql
select aiq.enable_graph_algorithms('authenticated');
```

To hand them back — before a benchmark, or to a role that should no longer
reach them — pass `false`: `select aiq.enable_graph_algorithms('authenticated',
false)`. It is a grant either way, not a session toggle, so it survives
reconnects and says how many functions it moved.

<div class="evidence" markdown="1">
<div class="label">what the grant reports</div>

```json
{"role": "authenticated", "enabled": true, "functions": 27,
 "note": "the first call in each backend builds an adjacency snapshot; …"}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — twenty-seven functions, because a grant on half of them
is half a grant</summary>

The wrappers in `aiq` are `SECURITY INVOKER`, so they run as the caller and the
compiled functions underneath them have to be callable by that caller too.
Granting the wrapper alone produces a permission error at the first call, from
a function name the caller has never heard of, so one call grants both halves.

They are off by default because the first call in a backend builds an adjacency
snapshot of the graph, and that is the largest allocation this extension makes
— 225 MB on a four-million-edge graph. Nothing builds it until somebody asks,
and on a fresh install nobody can.

`aiq.enable_graph_algorithms` does not grant itself, for the obvious reason.

<p class="related"><strong>Related</strong>
<a href="operating.html">what else to size before enabling</a> ·
<a href="install.html">installing the extension in a Postgres you already
run</a></p>
</details>

## Every output on this page is a tenant's view

These run as the caller and the adjacency snapshot is built as the caller, so
every number below depends on who is asking. The outputs on this page were
taken as tenant A — Meridian — and they are *not* what the
`postgres://p8:p8@localhost:5432/percolate` connection on the install page
returns, because that role is a superuser and a superuser bypasses RLS
unconditionally. You get more rows, different scores, and no error to tell you
which you are looking at.

What we are trying to do here is become the caller these outputs belong to.
{: .goal }

```sql
begin;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e0000000-0000-0000-0000-00000000000a",
    "orgs":["d0000000-0000-0000-0000-00000000000a"]}';   -- Meridian
-- any example from this page goes here
rollback;
```

Wrap each example below in those four lines. The `begin` is load-bearing and
its absence is silent: `SET LOCAL` outside a transaction warns and then does
nothing, so the claims are never set and you get the superuser's answer, which
looks like the example working.

It is worth seeing the difference once, because it does not announce itself.
Run [the components query](#what-is-linked-to-what-at-all) as the owner rather
than as Meridian and the cluster comes back with nine members instead of six —
Kestrel's operator, ship and port are visible to a superuser and belong to the
other tenant — and the second statement, which selects `where size = 6`, then
matches no component at all and returns zero rows rather than an error.

The subject matters as much as the org, and this is the part that catches
people. An `orgs` claim is **intersected with real membership** — it is an
assertion about who you are, not a grant — so a claim naming an organisation
with no member behind it resolves to no organisations and every query on this
page returns zero rows, with no error anywhere. The `sub` above is a reader the
sample creates and enrols in Meridian for this purpose. To use your own account
instead, put its id in `sub` and give it the membership the claim asserts:

```sql
insert into rbac.org_members (org_id, user_id)
values ('d0000000-0000-0000-0000-00000000000a', '<your user id>')
on conflict do nothing;
```

The org id above is the one `samples/harbour` loads, and the sample's own
[README](https://github.com/Percolation-Labs/get-percolate/blob/main/samples/harbour/README.md)
lists both. [Two tenants, one
table](cookbook.html#4-two-tenants-one-table) is the same mechanism shown from
the other side.

## Two of them are dialect modes

Four of the six stay SQL functions. Two are P8QL modes, because they are the
ones an agent asks constantly and the ones generated SQL gets wrong quietly — a
depth-capped walk returns the right rows in the wrong order and nothing says
so.

What we are trying to do here is ask the ranked question through the same REST
endpoint as every other query.
{: .goal }

<!-- run: sql as:tenant-a -->
```sql
select aiq.query('RELEVANCE "bulk harmony", "rotterdam" LIMIT 3');
select aiq.query('PATH "bulk harmony", "meri" LIMIT 2');
select aiq.query('PATH "bulk harmony", "rotterdam", "meri"');
-- POST /rpc/query  {"p_query": "RELEVANCE \"bulk harmony\" LIMIT 3"}
```

<div class="evidence" markdown="1">
<div class="label">the envelope, with the two keys only this mode carries</div>

```json
{"mode": "RELEVANCE",
 "rows": [{"key": "bulk harmony", "entity_type": "vessel",   "score": 0.2429, …},
          {"key": "rotterdam",    "entity_type": "port",     "score": 0.2424, …},
          {"key": "meri",         "entity_type": "operator", "score": 0.1667, …}],
 "exhausted": false,
 "unresolved": []}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — eight modes, still six modifiers, and two refusals that
teach</summary>

The dialect budgeted seven modes and six modifiers so that it fits in a prompt,
and six new modes would have spent that budget on questions asked far less often
than `LOOKUP`. This costs two modes and **no new modifiers**: `DEPTH`, `TYPE`
and `LIMIT` already mean here exactly what they mean on `GRAPH`.

`PATH` is one mode with two arities rather than two modes, because a shortest
path *is* the Steiner tree of two terminals — two names give the best routes,
three or more give the smallest structure joining all of them.

`DEPTH` on `RELEVANCE` is refused, and the refusal is the whole argument in one
error message — *it ranks by how much score reaches a node, not by how many hops
away it is*. A caller who writes it is reaching for `GRAPH`, and the error says
so. `PATH` with one name is refused for the mirror reason.

`unresolved` and `exhausted` appear on this envelope and on no other, each for a
stated reason: the first because a dropped seed would make "no such entity" look
like "nothing is related", the second because this is the only budgeted mode and
a flag on the seven that cannot be truncated is a flag nobody reads.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#ranking-which-a-walk-cannot-do">the mode in the
grammar reference</a> ·
<a href="query.html">the seven modes it joined</a></p>
</details>

## What is related to this — ranked, not enumerated

A depth cap answers "everything within two hops", which for a hub is thousands
of rows in no order and leaves the ranking to a caller who has no way to do it.
This returns the ranking, and the ranking is the answer.

What we are trying to do here is ask what a ship is connected to, and get the
six things that matter most rather than the whole neighbourhood.
{: .goal }

<!-- run: sql as:tenant-a -->
```sql
select key, entity_type, round(score::numeric, 4) as score, budget_exhausted
from aiq.related(array['bulk harmony'], 6)
order by score desc;
```

<div class="evidence" markdown="1">
<div class="label">as tenant A, against the harbour fixture</div>

```
      key      | entity_type | score  | budget_exhausted
---------------+-------------+--------+------------------
 bulk harmony  | vessel      | 0.3036 | f
 rotterdam     | port        | 0.1823 | f
 merb          | operator    | 0.1745 | f
 meri          | operator    | 0.1663 | f
 meridian dawn | vessel      | 0.1254 | f
 meridian star | vessel      | 0.0479 | f
```
</div>

Meridian Line ranks below Meridian Bulk even though both are owners, because
one is a hop further away; the sister ship that shares a port outranks the one
that does not.

<details class="why" markdown="1">
<summary>Why it works — a local push walk costs what the neighbourhood costs,
not what the graph costs</summary>

This is personalised PageRank by local push. The important property is not the
ranking but the *locality*: the walk only touches the part of the graph the
mass actually reaches, so a query on a million-node graph costs what the seed's
surroundings cost. Measured at four million edges it is 93 ms at the median.

It is also anytime. The unpushed mass is tracked as a residual, so running out
of budget under-estimates every score and leaves the ordering intact — which is
why `budget_exhausted` rides on every row rather than living in a second call.
"Nothing else is related" and "I ran out of budget" are different answers and
the shape of the result has to keep them apart.

**Do not reach for this at one or two hops.** The recursive walk behind `GRAPH`
answers a depth-2 question in about a millisecond on the same graph. This earns
its place when you need the order, not the neighbours.

<p class="related"><strong>Related</strong>
<a href="query.html#the-property-graph-costs-no-migration">`GRAPH`, for one and
two hops</a> ·
<a href="grammar-p8ql.html#walking-out-from-a-node">the `GRAPH` mode</a></p>
</details>

## How are these two connected

Not one route — the best few, cheapest first, so a reader can see that the
obvious answer had an alternative.

What we are trying to do here is find how a ship reaches its ultimate parent,
and see the second-best route as well as the first.
{: .goal }

`graph_paths` answers in node ids, because ids are what a caller joins on. The
projection back to names is the join you would write anyway, and it is spelled
out here rather than elided so the table below is something you can produce:

<!-- run: sql as:tenant-a -->
```sql
with paths as (
    select row_number() over (order by (v->>'cost')::numeric) as route,
           (v->>'hops')::int as hops,
           round((v->>'cost')::numeric, 2) as cost,
           v->'path' as path
    from jsonb_array_elements(aiq.graph_paths('bulk harmony', 'meri', 2)->'paths') v
), hop as (
    select p.route, p.hops, p.cost, e.ord,
           (select key from aiq.node_keys where node_id = (e.el->>'from')::uuid and kind = 'canonical') as src,
           (select key from aiq.node_keys where node_id = (e.el->>'to')::uuid   and kind = 'canonical') as dst,
           e.el->>'relation' as relation
    from paths p, lateral jsonb_array_elements(p.path) with ordinality e(el, ord)
)
select route, hops, cost,
       min(src) filter (where ord = 1) || ' -> ' || string_agg(dst, ' -> ' order by ord) as route_taken,
       string_agg(relation, ', ' order by ord) as relations
from hop group by route, hops, cost order by route;
```

<div class="evidence" markdown="1">
<div class="label">projected into node keys, as Meridian</div>

```
 route | hops | cost |                    route_taken                     |               relations
-------+------+------+----------------------------------------------------+---------------------------------------
     1 |    2 | 2.05 | bulk harmony -> merb -> meri                       | operated_by, subsidiary_of
     2 |    3 | 3.00 | bulk harmony -> rotterdam -> meridian dawn -> meri | last_called, last_called, operated_by
```
</div>

The ownership chain wins, but the second route is the interesting one: two
ships that called at the same port, one of which is operated by the parent
directly.

<details class="why" markdown="1">
<summary>Why it works — bidirectional search, and a cost model where hops are
the unit and confidence breaks the tie</summary>

Each edge costs `1 − ln(weight)`, so "shortest" means fewest hops, tie-broken
by how well corroborated they are. The 0.95 subsidiary claim makes route 1 cost
2.05 rather than 2.00, which is enough to order two routes of the same length
without letting a long chain of certain edges lose to a short unreliable one.

The search runs from both ends and meets in the middle. That matters most when
there is *no* path: a one-sided search has to settle the whole component before
it can say so, which on a four-million-edge graph exhausted the budget on 96
calls in 100. Two frontiers settle roughly the square root of that volume, and
the single best path comes back in 8 ms.

The alternates are what cost. Asking for `k=1` never runs out of budget on the
graphs we have measured; asking for three hits the ceiling on about a third of
calls at four million edges, and returns the best path plus however many
alternates the budget bought.

`as_of` is accepted here and applied while the search is running rather than to
the result — the only correct placement, since filtering afterwards returns the
k best paths *including* expired edges, minus the ones that happened to be
expired. This is the one read path in Percolate that honours `valid_to`.

<p class="related"><strong>Related</strong>
<a href="query.html#over-rest-and-the-two-things-that-look-like-bugs">why an
empty result is usually correct</a></p>
</details>

## A name that does not resolve is said out loud

Row-level security applies, because these run as the caller. A node the caller
cannot see is not a node they can walk to — and the answer says which of the
two names failed rather than coming back empty.

What we are trying to do here is ask for a route to a competitor that belongs
to another tenant.
{: .goal }

<!-- run: sql as:tenant-a -->
```sql
select aiq.graph_paths('bulk harmony', 'kest', 2) - 'meta' as answer;
```

<div class="evidence" markdown="1">
<div class="label">as tenant A, who cannot see Kestrel Shipping</div>

```json
{"ok": true, "paths": [], "unresolved": ["kest"]}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — and why the cached snapshot cannot leak across a
tenant</summary>

The adjacency snapshot is built through SPI as the caller, so RLS filters it at
build time, and an edge whose endpoint the caller cannot see is dropped rather
than walked — an edge can otherwise disclose that an invisible node exists just
by being visible itself.

That snapshot is then *cached in the backend*, which is exactly the shape that
leaks: a pooled connection handed from one tenant to the next would serve the
first tenant's graph to the second. Every entry point re-checks a fingerprint —
role, claims, and the tables' modification counters — and rebuilds rather than
reusing somebody else's. It is asserted by behaviour rather than by reading the
code: one backend, two identities, and the second must get a different
snapshot.

<p class="related"><strong>Related</strong>
<a href="cookbook.html">the same query asked twice with different claims</a> ·
<a href="query.html#over-rest-and-the-two-things-that-look-like-bugs">querying
as a superuser, and why it looks wrong</a></p>
</details>

## How much of this rests on a guess

Edge weights are not decoration: a rivalry asserted by one trade paper sits at
0.4 next to a registry-backed 1.0. After two hops nothing else in the system
can tell you which kind of claim you are standing on.

What we are trying to do here is see the confidence of a route, first along one
relation and then with the whole graph available.
{: .goal }

<!-- run: sql as:tenant-a -->
```sql
select key, confidence, support
from aiq.graph_trust(array['merb'], 0.01, 4, 250, 'subsidiary_of')
order by confidence desc, key;

select key, confidence, support
from aiq.graph_trust(array['merb'], 0.01, 4)
order by confidence desc, key;
```

<div class="evidence" markdown="1">
<div class="label">along the ownership relation alone</div>

```
 key  | confidence | support
------+------------+---------
 merb |          1 |       0
 meri |       0.95 |       1
```
</div>

<div class="evidence" markdown="1">
<div class="label">and with every relation available</div>

```
     key      | confidence | support
--------------+------------+---------
 bulk harmony |          1 |       0
 merb         |          1 |       0
 meri         |          1 |       0
 rotterdam    |          1 |       0
```
</div>

The registry's 0.95 subsidiary claim is not the best-supported route to
Meridian Line. Three edges of AIS and registry fact at 1.0 — the ship called at
Rotterdam, so did a sister ship, and that ship is operated by the parent — get
there without giving anything up.

<details class="why" markdown="1">
<summary>Why it works — max-product does not penalise length, and `support`
is the column to read second</summary>

`confidence` is the best single path, computed as the product of the weights
along it. There is no per-hop penalty, deliberately: a long chain of certain
edges should not lose to a short uncertain one, which is precisely what the two
answers above show.

`support` is the corroboration count — how many independent neighbours carry
belief into that node — combined by noisy-OR. A confident number with `support`
0 is one path's opinion. Read together they answer *how much of this rests on a
model's guess*, which is the question an extracted graph makes unavoidable.

The walk stops at a rank bound rather than at a confidence floor, and that is
not an implementation detail: a floor bounds *belief*, not *work*. On a
small-world graph a floor of 0.2 and a floor of 0.05 both reached two thirds of
a million nodes, because five hops of 0.65-weight edges clear either. The walk
settles in decreasing confidence, so the first k nodes it settles *are* the
answer — which took this from 277 ms with every call over budget to 5 ms with
none.

<p class="related"><strong>Related</strong>
<a href="ingest.html">where extracted edges and their weights come from</a></p>
</details>

## What connects these several things

The honest follow-up to a retrieval that returned eight entities is not "which
is most relevant" but "what connects them", and no amount of ranking answers
it.

What we are trying to do here is find the smallest structure joining a ship, a
port and an operator.
{: .goal }

```sql
select jsonb_array_length(v->'nodes') as nodes, (v->>'connected')::int as terminals_joined, …
from (select aiq.graph_connect(array['bulk harmony','rotterdam','meri']) v) q;
```

<div class="evidence" markdown="1">
<div class="label">three terminals, four nodes, three edges</div>

```
 nodes | terminals_joined | edges
-------+------------------+-----------------------------------------------------
     4 |                3 | meridian dawn -[operated_by]- meri
                          | bulk harmony  -[last_called]- rotterdam
                          | meridian dawn -[last_called]- rotterdam
```
</div>

Meridian Dawn is not one of the three things asked for. It is in the answer
because it is what joins them, which is the entire point of asking.

<details class="why" markdown="1">
<summary>Why it works — an approximation, budgeted by construction, that says
how many terminals it actually joined</summary>

This is the Steiner tree, which is NP-hard, so it is a 2-approximation rather
than an answer: one multi-source walk labels every node with its nearest
terminal, the connections are read off the edges that cross a boundary between
two territories, a minimum spanning tree picks which to keep, and non-terminal
leaves are pruned.

`terminals_joined` is there because a partial answer must not read as a
complete one. A terminal whose neighbourhood the walk never reached is left out
and counted, rather than quietly dropped.

The single-walk form replaced one walk per terminal after measuring it: at four
million edges the per-terminal version spent 502 ms of a 500 ms budget and
still returned a partial answer. The same call is now 130 ms and joins every
terminal.

<p class="related"><strong>Related</strong>
<a href="query.html">retrieval, which is what produces the terminals</a></p>
</details>

## What is linked to what at all

Before anything decides what a cluster *means*, there is a cheaper question:
which nodes are transitively connected at all.

What we are trying to do here is find the clusters in the graph, and then the
edges inside one of them without a query per cluster.
{: .goal }

<!-- run: sql as:tenant-a -->
```sql
select c.size, string_agg(k.key, ', ' order by k.key) as members
from aiq.graph_components(2) c
join aiq.node_keys k on k.node_id = c.node_id and k.kind = 'canonical'
group by c.component, c.size order by c.size;

select ks.key as src, i.relation, kd.key as dst,
       round(i.weight::numeric, 2) as weight
from aiq.graph_induced(array(
        select node_id from aiq.graph_components(2) where size = 6)) i
join aiq.node_keys ks on ks.node_id = i.src_id and ks.kind = 'canonical'
join aiq.node_keys kd on kd.node_id = i.dst_id and kd.kind = 'canonical'
order by ks.key, i.relation, kd.key;
```

<div class="evidence" markdown="1">
<div class="label">the harbour cluster, and the edges inside it</div>

```
 size | members
------+-------------------------------------------------------------------
    6 | bulk harmony, merb, meri, meridian dawn, meridian star, rotterdam

      src      |   relation    |    dst    | weight
---------------+---------------+-----------+--------
 bulk harmony  | last_called   | rotterdam |   1.00
 bulk harmony  | operated_by   | merb      |   1.00
 merb          | subsidiary_of | meri      |   0.95
 meridian dawn | last_called   | rotterdam |   1.00
 meridian dawn | operated_by   | meri      |   1.00
 meridian star | operated_by   | meri      |   1.00
```
</div>

<details class="why" markdown="1">
<summary>Why it works — filter the snapshot first, or the answer is one
blob</summary>

Components is union-find, which is linear and about as cheap as a compiled
graph function gets: 184 ms over 749,000 edges. The component is named by the
smallest node id in it, so the name is stable across runs — a component id that
moves between two runs over the same graph is not an id.

It is also the function that most needs the snapshot filter in front of it. An
evidence graph records a weak opinion on every pair it ever considered, because
"we looked and found nothing" is a different fact from "we never looked" — and
components over all of that is one component containing everything. Build the
snapshot over the relations and the weight floor you mean first:

<!-- run: sql as:tenant-a -->
```sql
select aiq.graph_snapshot(true, array['operated_by','subsidiary_of'], 0.6);
```

That filter is pushed into the build query, so the rows never arrive and are
never resident — 3.8 s and 225 MB becomes 677 ms and 98 MB on a fifth of a
four-million-edge table. It is also **sticky**: the filtered graph is what every
other function walks until the next build, and every result reports the filter
it ran under, so a caller can always tell which graph it just walked.

`graph_induced` exists for a round trip rather than for compute. A repair pass
over thousands of small clusters, fetching each cluster's internal edges with
its own query, is thousands of round trips for a few hundred bytes each — and
one call answers all of them, because an edge internal to the union of disjoint
components is internal to exactly one of them.

<p class="related"><strong>Related</strong>
<a href="scaling.html">what the rest of the system costs, measured the same
way</a></p>
</details>

## How big is it, before you walk it

The reason a three-hop question falls over is not that three hops is hard. It
is that nobody knows the frontier is four hundred thousand nodes until they are
holding it.

What we are trying to do here is find out how big a neighbourhood is without
enumerating it.
{: .goal }

<!-- run: sql as:tenant-a -->
```sql
select aiq.graph_reach_build(3) -> 'depth' as sketch_depth;
select aiq.graph_frontier('meri', 2, true) as frontier;
```

<div class="evidence" markdown="1">
<div class="label">estimate against the exact count, on a six-node neighbourhood</div>

```json
{"ok": true, "depth": 2, "estimate": 6.30, "exact": 6, "exact_complete": true,
 "meta": {"budget_ms": 250, "elapsed_ms": 0.001, "edge_visits": 8, "exhausted": false}}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — a magnitude, not a count, and built by the caller who
will read it</summary>

`graph_reach_build` runs a few passes of HyperLogLog union over the adjacency
and keeps only the cardinality: four bytes per node per depth, and the query is
then an array read. Read the number as an order of magnitude rather than a
count — the median error is about 6% and the 95th percentile is around 22%,
which is plenty for deciding whether a walk will touch thousands or millions
and useless for anything that needs the figure itself.

Pass `exact => true` and it also runs the real traversal, which is how the two
columns above ended up side by side. That is a check, not a habit: the exact
count is the query the sketch exists to avoid.

The build is granted to the same role as the queries, and that was a
correction. It looked like a maintenance operation to withhold — but the sketch
lives in the backend that built it, over the graph *that caller* could see, so
a sketch built by an administrator and read by a tenant comes back
`"estimate": null`. An index only its author can use is not an index.

<p class="related"><strong>Related</strong>
<a href="operating.html">what to schedule, and what to watch</a></p>
</details>

## Where this reaches across the extension boundary

Percolate is two extensions, and it has to be. `percolate_parser` carries
compiled functions, so a superuser installs it. `percolate` owns tables and
row-level security policies, so a superuser must *not* — extension objects
belong to whoever runs the script, and a superuser-owned table has policies that
never fire.

Everything on this page crosses that line, and so does a good deal that is not
on this page.

What we are trying to do here is find out whether the two halves of this
database are in step.
{: .goal }

<!-- run: sql -->
```sql
select aiq.extension_boundary();
```

<div class="evidence" markdown="1">
<div class="label">twenty-three crossings, across two schemas</div>

```json
{"ok": true,
 "provider": {"extension": "percolate_parser", "version": "@@extension@@", "functions": 21},
 "crossings": [{"caller": "aiq.query",     "callee": "aiq_parse",         "present": true},
               {"caller": "aiq.related",   "callee": "p8_graph_ppr",      "present": true},
               {"caller": "workflow.define_yaml", "callee": "p8_compile_workflow", "present": true},
               …],
 "missing": []}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — late binding is what makes the split possible and the
failure quiet</summary>

plpgsql resolves a function name when it runs, not when it is created. That is
what lets the two halves install separately, and it is exactly why the failure
mode is silent: a database can install cleanly, pass its surface audit, and then
fail on the first call because the compiled half is older than the SQL half.

That is not an exotic state. **A SQL reload does not carry a `.so`**, so it is
the normal condition of any stack that pulled a new schema without pulling a new
image — the case this page's own functions are most likely to be missing in.

Three rules follow, and they are why this is a section rather than a footnote.
A caller across the boundary checks first, and the check names the *extension*
rather than raising `function p8_graph_ppr does not exist`, which reads as a
corrupt schema. The compiled half stays pure or close to it — the parser is
computation over a string, the graph functions read through SPI as the caller so
row-level security still applies, and nothing across the boundary writes.
And version skew is treated as a first-class state rather than an error to
explain away, because two halves shipping on different rails will diverge.

The report is derived from the catalog rather than from a list somebody
maintains, since a hand-written list drifts both ways at once — claiming a
crossing that has gone and missing the one added last week. Deriving it caught a
false positive worth keeping in mind: the first version matched `aiq_parse()`
inside the *error message* several functions raise to apologise for its absence,
and reported four crossings that were apologies rather than calls.

<p class="related"><strong>Related</strong>
<a href="install.html">installing the two extensions in the right order</a> ·
<a href="operating.html">what to check after an upgrade</a></p>
</details>

## What it costs, on a graph that is not a fixture

Nine edges proves the shape and nothing about the cost. These are the same
calls against a heavy-tailed fixture of **3.94 million edges over a million
nodes**, one backend, p50 and p95 in milliseconds:

| | p50 | p95 | over a 250 ms budget |
|---|---|---|---|
| `aiq.graph_trust` | 5.5 | 6.7 | 0 of 100 |
| `aiq.graph_dense` | 16.6 | 22.0 | 0 of 50 |
| `aiq.related` | 93.3 | 115.0 | 0 of 100 |
| `aiq.graph_connect` (5 terminals) | 129.8 | 148.4 | 0 of 33 |
| `aiq.graph_paths` (k=3) | 161.1 | 250.7 | 34 of 100 |
| **any first call in a backend** | **2 700** | — | it builds the snapshot |
| `aiq.graph_components` | 184.3 | — | one shot |
| *the recursive walk, depth 2* | 0.9 | 2.9 | — |
| *the recursive walk, depth 3* | 19.7 | 4527.0 | — |

The last two rows are the point of the table. At two hops the ordinary walk
wins by two orders of magnitude and you should use it. At three it has a 4.5
second 95th percentile and a worst case of nineteen seconds, because nothing
bounds it — and that is the failure every function on this page exists to
convert into a budget and an honest `budget_exhausted`.

And under concurrency, which is the measurement that changed the design:

| clients | tps | p50 | p95 | peak container memory |
|---|---|---|---|---|
| 1 | 10 | 90.3 ms | 102.2 ms | 1.04 GiB |
| 4 | 29 | 114.8 ms | 132.7 ms | 3.33 GiB |
| 8 | — | — | — | 5.55 GiB, **OOM kill and cluster restart** |
| 8, with admission control | 14 | — | — | six served, two refused, cluster alive |

Latency barely moves from one client to four. **Memory is the constraint, not
CPU**, and it arrives at single digits.

<details class="why" markdown="1">
<summary>Why it works — the failure at eight clients was not a slow query, and
what now happens instead</summary>

The adjacency snapshot is **per backend**: 225 MB at four million edges, and
roughly twice that at the peak of a build. Eight concurrent callers on a
7.65 GiB machine did not produce a slow query — the OOM killer took a backend
with `signal 9`, and Postgres did what it must when a backend dies holding
shared memory: *terminating any other active server processes*, then recovery.
One graph query took the cluster down.

Nothing in Postgres prevented it, and that is structural rather than an
oversight: this memory is allocated by the extension, outside `work_mem`, so no
existing setting sees it and the planner does not know it exists.

So there is admission control now, built from a primitive Postgres already has.
A backend takes one of `percolate.graph_snapshot_slots` (default six)
session-level advisory locks before it builds and holds it as long as it holds
the snapshot — locks and memory released together when the connection ends. A
backend that cannot get one is **refused with a sentence** telling it what is
held and how to release one. Re-run at eight clients: six served, two refused,
cluster alive.

It is a setting rather than a constant because the right value is a function of
how much memory the machine has, and it is a *superuser* setting because a
limit the callers it bounds can raise is not a limit. There is a second one,
`percolate.graph_snapshot_max_mb`, that bounds a single snapshot — the two are
not substitutes: the ceiling stops one graph too large for any backend, the
slots stop N ordinary callers, and it was the second that took the box.

That is the same discipline as everywhere else here — turn a quiet
catastrophic failure into a loud refusal — applied to the one failure on this
page that was not a wrong answer but an outage.

Three ways to live with it, and the choice is operational: a small number of
long-lived workers that build once, preloading at connection start, or moving
the snapshot into shared memory. The measurement above promoted the third from
"the natural next build" to a **requirement above single-digit concurrency**.
Six slots is a guard rail, not a scaling story.

Every one of those figures is the **call**, not the algorithm, and the
distinction is worth the four fields it costs. A budget measured from after the
snapshot is fetched reports 96 ms of a 2,689 ms wait on a cold first call: both
numbers are true of the walk, and the one an operator would build an SLO on is
off by 28×. So the answer carries `elapsed_ms` for the call, `walk_ms` for the
algorithm, `build_ms` for the snapshot, and keeps `exhausted` (the *answer* is
partial) separate from `over_budget` (the *call* took longer than it was given)
— opposite problems with opposite fixes.

Figures are from one run of `dev/scale/graph/run.sh` and
`03-concurrency.sh`. Re-running moves the latency probes by 10–30% and the
build probes by up to 2×, so read the ordering and the slope rather than the
third digit.

<p class="related"><strong>Related</strong>
<a href="scaling.html">the engine's own hot paths, measured the same way</a> ·
<a href="operating.html">worker pools and what to watch</a></p>
</details>
