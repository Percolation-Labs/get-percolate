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

## Why `SEMANTIC` and `SEARCH` take two steps

A `sql` step cannot embed text — that is a model call, and the database makes no
outbound calls. So those modes compose as two steps:

```yaml
  - id: embed
    rest: {url: '{{env.LLM_URL}}/api/embeddings', jsonpath: embedding}
  - id: retrieve
    needs: [embed]
    sql: {function: p8ql_vec, args: ['SEARCH "…" FROM chunks', '{{steps.embed.result}}']}
```

The architecture shows up in the syntax here rather than being hidden by it, and
the two-step shape puts the fact that this step leaves the machine right where
you are writing it.

The in-database resolver substitutes whole-string references and keeps their
native type, so the embedding arrives as an array rather than a string.

## Identity: what becomes a node

A row becomes a node if you can find it with `LOOKUP` or if it is the endpoint
of an edge. A document is both, since you name it and events reference it. A
chunk is neither: it is machine-generated volume that joins in after identity is
already known, and letting chunks in would put the node registry on the wrong
side of the scale argument.

The same rule is why a workflow artefact gets the `stored` resource status
rather than `ready`, since step output is machine-generated too.

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
