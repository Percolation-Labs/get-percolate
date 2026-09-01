# Querying

One dialect over a property graph, a vector index and a lexical index. Seven
modes, and the mode is the first word.
{: .lede }

```sql
select aiq.query('LOOKUP "acme"');
select aiq.query('GRAPH "acme" DEPTH 2 TYPE supplier_of');
select aiq.query('TEXT "power outage" FROM chunks LIMIT 10');
select aiq.query('SEMANTIC "why did it fail" FROM chunks', :embedding);
```

| Mode | Answers |
|---|---|
| `LOOKUP` | exact identity — does this name resolve to a node |
| `FUZZY` | approximate identity, trigram |
| `GRAPH` | traversal from a node, bounded by `DEPTH` and `TYPE` |
| `TEXT` | lexical search over a registered corpus |
| `SEMANTIC` | vector similarity |
| `SEARCH` | lexical and semantic, fused |
| `SCHEMA` | what can be asked, before you know anything |

`SCHEMA` is the one to look at first. It is a versioned capability document
assembled from registered facets, derived from the catalog where that is
possible and verified by running it where it is not, and it is what an agent
reads before writing its first query.

## `SEMANTIC` and `SEARCH` take two steps, and you write one

A `sql` step cannot embed text — that is a model call, and the database makes no
outbound calls. So those modes are two tasks, and that does not change:

```yaml
  - id: retrieve
    p8ql: 'SEARCH "…" FROM chunks'
```

compiles to an `http_call` keyed `retrieve__embed` and the query step keyed
`retrieve` that depends on it. Your id stays on the query — the step that
produces the result — so anything downstream still says `needs: [retrieve]` and
still reads `{{steps.retrieve.result}}`. The embed is a hidden predecessor
rather than a child, and nothing else in the document moves.

You never write the endpoint. It comes from `aiq.embedding_models`, along with
the request body's shape and the path to the vector in the response, so a url
does not end up in a document that outlives the deployment it was written on.
The hand-written pair is still legal and compiles to exactly the same rows:

```yaml
  - id: q
    embed: '{{run.question}}'
  - id: retrieve
    needs: [q]
    sql: {function: p8ql_vec, args: ['SEARCH "…" FROM chunks', '{{steps.q.result}}']}
```

### The model is pinned into both halves

This is the part that is not about typing. An embedding is only comparable
inside the space of the model that produced it, and nothing downstream can
notice when it is not: the dimension check passes whenever two models are the
same width, so searching one space with another's vector returns a number
rather than an error. Writing the pair by hand meant naming the model twice —
once on the embed call, once as `USING` on the query, or not at all — with
nothing checking that the two agreed.

So the model is resolved once, when the workflow is defined, and written into
both halves. Naming a different one on each is refused while you are authoring:

```
step 'retrieve' searches the 'nomic-embed-text' space but is handed a vector
produced by 'other-768'.
```

The in-database resolver substitutes a whole-string reference as a value, so an
embedding arrives as an array rather than a string, and interpolates one that
sits inside a longer string as text — which is what makes
`SEARCH "{{run.question}}"` search for the question rather than for the
braces.

## Identity: what becomes a node

A row becomes a node if you can find it with `LOOKUP` or if it is the endpoint
of an edge. A document is both, since you name it and events reference it. A
chunk is neither: it is machine-generated volume that joins in after identity is
already known, and letting chunks in would put the node registry on the wrong
side of the scale argument.

The same rule is why a workflow artefact gets the `stored` resource status
rather than `ready`, since step output is machine-generated too.

Rows arrive in the registry two ways. A table you register with
`aiq.register_entity_table` is projected as its rows change, which is how
documents, companies and filings get there. The other way is extraction: an
uploaded file can be read by a structured-output extractor whose nodes and
edges land through `aiq.upsert_graph`, so the things your documents mention are
in the graph next to the things your tables hold. That is a flag on the
ingestion pipeline and it is off by default — see
[uploading files](ingest.html).

## Property graphs are a read-only view

SQL/PGQ in PG19 defines a property graph as a view over ordinary relational
tables. There is no separate graph store, no migration to adopt it and no second
copy of anything to keep in step, so `nodes`, `node_keys` and `edges` are tables
you can read with plain SQL and `GRAPH_TABLE` is just another way to ask.

One PG19 limitation to know about before you run into it: element pattern
quantifiers are not supported, so variable-length paths use `DEPTH` rather than
`{1,3}` syntax.

## Over REST

```
POST /rpc/query   {"p_query": "LOOKUP \"acme\""}
```

RLS applies, so results come back filtered to what the caller can see. Two
things make results look like they are missing and neither is a bug: querying as
a superuser, which bypasses RLS so you see more rather than less and the
filtered views start behaving oddly, and forgetting `request.jwt.claims`, which
leaves the caller anonymous.

Next: [operating it](operating.html).
