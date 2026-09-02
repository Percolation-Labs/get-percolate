# The P8QL grammar

P8QL is the query dialect this collection speaks: seven modes over one endpoint,
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

## The seven modes

Every mode goes through `aiq.query(text, vector)`, which is `POST /rpc/query`
over the REST surface. The second argument is the embedding, and only the two
vector modes use it.

| Mode | Syntax | What it is for |
|---|---|---|
| `LOOKUP` | `[FUZZY] LOOKUP "<key>" [, "<key>" …] [LIMIT n]` | Resolve names to nodes. Takes a list, because an agent almost never holds exactly one entity |
| `GRAPH` | `GRAPH "<key>" [DEPTH n] [TYPE <relation>] [LIMIT n]` | Walk relationships out from a named node |
| `TEXT` | `TEXT "<text>" FROM <source> [LIMIT n]` | Lexical search, needing no embedding anywhere |
| `SEMANTIC` | `SEMANTIC "<text>" FROM <source> [USING <model>] [LIMIT n]` | Meaning-based search. You supply the vector |
| `SEARCH` | `SEARCH "<text>" FROM <source> [USING <model>] [LIMIT n]` | Both rankings, fused |
| `SCHEMA` | `SCHEMA ["<facet>"] [FROM <name>]` | What this database *is*. The only mode answerable before you know anything |
| SQL | `<any read-only statement>` | The floor everything else sits on |

`DEPTH` and `TYPE` belong to `GRAPH` alone. `FROM` and `USING` belong to the
three search modes. `LIMIT` works everywhere except `SCHEMA`.

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
<a href="grammar-workflow.html#sql-steps-call-a-registered-function">registering
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
