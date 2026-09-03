# The P8QL grammar

P8QL is the query dialect this collection speaks: nine modes over one endpoint,
compiled by a Rust parser that ships with the extension. This page is the whole
grammar at version 0.1.0, and the last section shows you how to ask your own
database for its version rather than trusting this one.
{: .lede }

There is one thing worth knowing before the table, because it explains most of
what the parser refuses. A modifier that means nothing for a mode is rejected
rather than ignored, so `TEXT "x" DEPTH 2` is an error instead of a query that
quietly does something other than what it says. That rule costs a little
convenience and buys the property that a query you can read is a query you can
trust.

## The nine modes

Every mode goes through `aiq.query(text, vector)`, which is `POST /rpc/query`
over the REST surface. The second argument is the embedding, and only the two
vector modes use it.

| Mode | Syntax | What it is for |
|---|---|---|
| `LOOKUP` | `[FUZZY] LOOKUP "<key>" [, "<key>" …] [LIMIT n]` | Resolve names to nodes. Takes a list, because an agent almost never holds exactly one entity |
| `GRAPH` | `GRAPH "<key>" [DEPTH n] [TYPE <relation>] [LIMIT n]` | Walk relationships out from a named node, to a bounded depth |
| `RELEVANCE` | `RELEVANCE "<key>" [, "<key>" …] [TYPE <relation>] [LIMIT n]` | Rank what is most related to one or more nodes. Not a walk — it returns an order |
| `PATH` | `PATH "<a>", "<b>" [, "<c>" …] [DEPTH n] [TYPE <relation>] [LIMIT n]` | How are these connected? Two names give the best routes; three or more give the smallest subgraph joining them |
| `TEXT` | `TEXT "<text>" FROM <source> [LIMIT n]` | Lexical search, needing no embedding anywhere |
| `SEMANTIC` | `SEMANTIC "<text>" FROM <source> [USING <model>] [LIMIT n]` | Meaning-based search. You supply the vector |
| `SEARCH` | `SEARCH "<text>" FROM <source> [USING <model>] [LIMIT n]` | Both rankings, fused |
| `SCHEMA` | `SCHEMA ["<facet>"] [FROM <name>]` | What this database *is*. The only mode answerable before you know anything |
| SQL | `<any read-only statement>` | The floor everything else sits on |

Each modifier has a domain, and a modifier written outside it is **refused**,
never ignored:

| Modifier | Where it applies | What it means there |
|---|---|---|
| `DEPTH` | `GRAPH`, `PATH` | bounds a traversal — hops out, or the longest route worth considering |
| `TYPE` | `GRAPH`, `RELEVANCE`, `PATH` | filters a relation on an edge |
| `LIMIT` | everywhere but `SCHEMA` | how many answers |
| `FROM`, `USING` | `TEXT`, `SEMANTIC`, `SEARCH` | which corpus, which embedding space |
| `FUZZY` | `LOOKUP` | trigram over `node_keys`, and only there |

`RELEVANCE "acme" DEPTH 2` is an error, and the error says why: it ranks by how
much score reaches a node, not by how many hops away it is — reach for `GRAPH`.
`PATH "acme"` is an error too, because one name is neither a route nor a
connecting subgraph.

`RELEVANCE` and `PATH` are the two modes that run in the compiled extension
rather than in SQL, and the two that ship switched off.
[Graph algorithms](graph.html) is their page.

## Resolving a name you are not sure of

Looking something up by a name a person typed is the first query an agent makes,
and it is almost never spelled the way the database has it.

What we are trying to do here is find a vessel from a half-remembered name, and
fall back to fuzzy matching when the exact spelling misses.
{: .goal }

```sql
select aiq.query('LOOKUP "meridien dawn"');            -- 0 rows
select aiq.query('FUZZY LOOKUP "meridien dawn" LIMIT 3');
select aiq.query('FUZZY LOOKUP "acme", "globex" LIMIT 5');
```

<details class="why" markdown="1">
<summary>Why it works — `FUZZY` is a prefix because it changes what the query means</summary>

The dialect used to accept `LOOKUP "acme" FUZZY`, with the modifier trailing,
and that spelling is now retired with a message telling you what to write
instead. A modifier that changes the meaning of a query belongs in front of the
thing it modifies, where you read it before you read the argument rather than
after you have already formed an expectation.

Commas between keys are optional, and both quote characters work
interchangeably. Single quotes matter more than they look: SQL and YAML both
take the double quote, so `'GRAPH ''R7'' DEPTH 2'` inside a workflow document
would be unwritable without them. Before single quotes were a quoting character,
that query parsed *successfully* with the argument as the literal `'R7'`, which
matched no key and raised no error.

<p class="related"><strong>Related</strong>
<a href="query.html">querying, with worked output</a> ·
<a href="cookbook.html">resolving a half-remembered name against a fixture</a></p>
</details>

## Walking out from a node

What we are trying to do here is find who ultimately operates a ship, and what
else was in the same port, from one walk.
{: .goal }

```sql
select aiq.query('GRAPH "Bulk Harmony" DEPTH 2');
select aiq.query('GRAPH "MERB" DEPTH 2 TYPE subsidiary_of');
```

<details class="why" markdown="1">
<summary>Why it works — `TYPE` narrows the walk rather than filtering its result</summary>

Restricting the relation is applied during the traversal, so a depth-2 walk with
a `TYPE` filter follows only edges of that relation at both hops rather than
walking everything and discarding most of it. On a well-connected node that is
the difference between a walk and a scan.

`DEPTH` defaults to 1. The rows come back with the path that reached them, which
is what lets a caller tell a sibling relationship — reached by going out to a
port and back in again — from a stored one.

<p class="related"><strong>Related</strong>
<a href="query.html">the graph modes with captured output</a> ·
<a href="grammar-workflow.html">using a walk as a workflow step</a></p>
</details>

## Ranking, which a walk cannot do

`GRAPH` answers *what is within n hops*. That is the right question one and two
hops out, and it is the wrong shape for "what matters most about this", because
a depth cap returns everything at that distance in no particular order and
leaves the ranking to a caller who cannot do it.

What we are trying to do here is ask what is most related to two entities at
once, without picking a depth.
{: .goal }

```sql
select aiq.query('RELEVANCE "bulk harmony", "rotterdam" LIMIT 3');
```

<div class="evidence" markdown="1">
<div class="label">against the harbour fixture, as tenant A</div>

```json
{"mode": "RELEVANCE",
 "rows": [{"key": "bulk harmony", "entity_type": "vessel",  "score": 0.2429, …},
          {"key": "rotterdam",    "entity_type": "port",    "score": 0.2424, …},
          {"key": "meri",         "entity_type": "operator", "score": 0.1667, …}],
 "exhausted": false,
 "unresolved": []}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — a list of seeds, a refused DEPTH, and two envelope keys
that only this mode carries</summary>

It takes a **list** for the same reason `LOOKUP` does: an agent almost never
holds exactly one entity, and relatedness to a *set* of seeds is a different and
usually better question than relatedness to one of them. The two seeds above
score almost identically because each is strongly related to the other.

`DEPTH` is refused rather than ignored, and the error message is the mode's
argument in one sentence: it ranks by how much score reaches a node, not by how
many hops away it is.

Two keys appear on this envelope and on no other. `unresolved` is here for the
reason it is on `LOOKUP` — the underlying call drops a seed it cannot resolve,
and through a JSON envelope that makes "no such entity" indistinguishable from
"that entity has nothing near it". `exhausted` is here because this is the only
budgeted mode; putting it on the seven that cannot be truncated is how a reader
learns to stop reading it.

The mode ships switched off, so on a fresh database it answers with a sentence
containing `aiq.enable_graph_algorithms('<your role>')` rather than a permission
error naming a compiled function you have never heard of.

<p class="related"><strong>Related</strong>
<a href="graph.html">the six graph algorithms, five of which are SQL-only</a> ·
<a href="graph.html#what-it-costs-on-a-graph-that-is-not-a-fixture">what it
costs at four million edges</a></p>
</details>

## How are these connected

Two names is a route. Three or more is the smallest structure joining all of
them — and that is the same mode rather than a second one, because a shortest
path *is* the Steiner tree of two terminals.

What we are trying to do here is find how a ship reaches its ultimate parent,
and then what joins three things at once.
{: .goal }

```sql
select aiq.query('PATH "bulk harmony", "meri" LIMIT 2');
select aiq.query('PATH "bulk harmony", "rotterdam", "meri"');
```

<div class="evidence" markdown="1">
<div class="label">two names: the routes, cheapest first</div>

```json
{"mode": "PATH",
 "rows": [{"hops": 2, "cost": 2.05, "nodes": ["bulk harmony", "merb", "meri"]},
          {"hops": 3, "cost": 3.00, "nodes": ["bulk harmony", "rotterdam",
                                              "meridian dawn", "meri"]}],
 "exhausted": false, "unresolved": []}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — one mode with a minimum arity, and a `DEPTH` default of
its own</summary>

`PATH` is the only mode with a *minimum* number of arguments. One name is
neither of the things it does, and whoever wrote it wanted `GRAPH` or
`RELEVANCE`; the error says so rather than guessing.

`DEPTH` bounds the longest route worth considering, and its default here is
**6**, not the 1 that `GRAPH` uses — a one-hop route is a direct edge, so
inheriting that default would have meant "only tell me about things already
adjacent". The substituted default appears in the returned `plan`, because a
default the caller cannot see is one they will discover from a short answer.

Cost with two names is the volume between them, square-rooted by searching from
both ends at once; the best route comes back in about 8 ms on a
four-million-edge graph and the alternates are what spend the budget. With
three or more it is one multi-source walk, and the answer reports how many
terminals it actually joined so a partial result cannot read as a whole one.

<p class="related"><strong>Related</strong>
<a href="graph.html#how-are-these-two-connected">the same question with captured
output and the cost at scale</a></p>
</details>

## The three search modes, and why there are three

A corpus where lexical and semantic search agree cannot show you why both exist.
The interesting case is a document that uses a rare exact token, beside another
that says the same thing in entirely different words.

What we are trying to do here is find the same page three ways, and see the
ranking each mode produces.
{: .goal }

```sql
select aiq.query('TEXT "PSC-441" FROM chunks LIMIT 3');
select aiq.query('SEMANTIC "a boiler fault" FROM chunks LIMIT 3', '[0,0,0.707,0.707]');
select aiq.query('SEARCH "PSC-441 boiler" FROM chunks LIMIT 3', '[0,0,0.707,0.707]');
```

<details class="why" markdown="1">
<summary>Why it works — the database makes no model calls, so the vector is an argument</summary>

`SEMANTIC` and `SEARCH` rank against a vector, and producing one is an HTTP call
to a model. No HTTP client extension is installed here deliberately, so the
vector arrives as the second argument to `aiq.query` and the database never
blocks on somebody else's latency.

In a workflow you do not write that call yourself. A `p8ql:` step in either mode
compiles to two tasks — a hidden embed step and the search that consumes it —
with the endpoint taken from `aiq.embedding_models` and the model name written
into the query so the vector and the space it is ranked against cannot be two
different models.

`USING <model>` names a registered embedding space explicitly. Leaving it out
takes the deployment's default, and the compiler refuses a document whose
`USING` disagrees with the model its embed step would call.

<p class="related"><strong>Related</strong>
<a href="query.html">all three modes against one corpus</a> ·
<a href="grammar-workflow.html#a-vector-query-is-two-tasks">the two-task
desugaring</a> ·
<a href="recipes.html">answering a question from your own corpus</a></p>
</details>

## Asking the database what it is

What we are trying to do here is find out what this deployment accepts, before
writing a query against it.
{: .goal }

```sql
select aiq.query('SCHEMA');                -- the index of facets
select aiq.query('SCHEMA "workflow"');     -- one facet, in detail
select aiq.query('SCHEMA "graph"');        -- entity types, relations, models
```

<details class="why" markdown="1">
<summary>Why it works — the answer is derived from the catalog, and verified by
running it</summary>

Anything the catalog can prove is read from it rather than written down: the
step kinds come off a check constraint, the callable functions off the
allow-list, the edge catalogue off the table whose trigger enforces it. What a
catalog cannot express is written by hand — and then every hand-written example
is fed back through the compiler on each read, so a spelling this deployment no
longer accepts reports itself instead of being served to an agent as
authoritative.

That is the difference between a capability document and documentation. This
page can go stale; `SCHEMA` cannot.

<p class="related"><strong>Related</strong>
<a href="query.html">SCHEMA output in full</a> ·
<a href="grammar-workflow.html">the workflow vocabulary, same mechanism</a></p>
</details>

## Plain SQL is a mode

What we are trying to do here is run an ordinary read-only query through the
same endpoint as everything else.
{: .goal }

```sql
select aiq.query('select count(*) from aiq.nodes');
```

<details class="why" markdown="1">
<summary>Why it works — SQL is recognised by how it starts, and executed
somewhere else</summary>

There is no `SQL` keyword. The parser sniffs the first word against exactly five
read-only openers — `SELECT`, `WITH`, `TABLE`, `VALUES`, `EXPLAIN` — and
anything else is an honest dialect error. That matters more than it sounds:
treating every unrecognised first word as SQL would turn `LOKUP "acme"` into a
Postgres syntax error at position 1, about a language the caller was not
writing.

`aiq.query` returns a **plan** for this mode rather than rows, because executing
it is the job of `aiq.sql_passthrough` — a `SECURITY INVOKER` function, so the
statement runs as you and not as the definer that would otherwise be reading on
your behalf.

The consequence catches people in workflows. A `p8ql:` step holding plain SQL has
no caller to be, so it stores the plan and completes:

<div class="evidence" markdown="1">
<div class="label">workflow.tasks.output</div>

```
 status | mode |                               note
--------+------+------------------------------------------------------------------
 done   | SQL  | execute via the SECURITY INVOKER read-only passthrough, not here
```
</div>

Treat a step whose output carries that note as a step that did not do what its
author meant. If you want SQL in a workflow, register a function and use
`sql: {function: …}`.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#registering-a-function-and-what-it-still-buys">registering
a step function</a> ·
<a href="authoring.html">what the compiler refuses</a></p>
</details>

## Three spellings that were retired

The parser recognises each of these and answers with the sentence telling you
what to write instead, rather than with "unknown mode".

| Was | Now | Why |
|---|---|---|
| `HYBRID "…"` | `SEARCH "…"` | `HYBRID` named the implementation; `SEARCH` names the intent |
| `LOOKUP "…" FUZZY` | `FUZZY LOOKUP "…"` | A modifier that changes meaning belongs before what it modifies |
| `SQL select …` | `select …` | Ceremony on the one mode that needed no help identifying itself |

## Getting this page from your own database

The grammar above is version 0.1.0 of the parser. Your deployment is the
authority on its own version, and it will tell you:

What we are trying to do here is read the grammar out of the installed parser
rather than out of a document.
{: .goal }

```sql
select p8_query_grammar();          -- every mode, syntax and example
select workflow.compiler_capabilities();   -- and whether the parser is current
```

<details class="why" markdown="1">
<summary>Why it works — the parser describes itself, so the description cannot
drift from it</summary>

`p8_query_grammar()` is a function in the same Rust crate as the parser it
describes, which is why it is worth preferring to this page: the two ship
together and are versioned together. An agent that reads it gets the vocabulary
and the proof that the vocabulary is current, in one call.

`compiler_capabilities()` is the companion check. The compiled parser and the
SQL schema ship on separate clocks and will eventually disagree, so rather than
comparing version strings it probes the installed build with one canary per
feature and lists what is `missing`. Version skew otherwise presents as a syntax
error in a document that is not wrong.

<p class="related"><strong>Related</strong>
<a href="install.html">checking an install properly</a> ·
<a href="grammar-workflow.html">the workflow grammar, same mechanism</a></p>
</details>

Next: [the workflow grammar](grammar-workflow.html), which is the same idea for
the YAML side.
