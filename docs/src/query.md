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

`SCHEMA` is the one worth knowing about: a versioned capability document
assembled from registered facets, derived from the catalog where it can be and
**verified by execution** where it cannot. It is what an agent reads before
writing its first query.

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

This is the architecture showing up in the syntax rather than being hidden by
it. The two-step shape puts the decision — *this step leaves the machine* — at
the point where an author would otherwise not think about it.

The in-database resolver substitutes whole-string references keeping their
native type, so the embedding arrives as an array rather than a string.

## Identity: what becomes a node

A row becomes a node if it is `LOOKUP`-searchable or is an edge endpoint. A
document is both — you name it, and events reference it. A **chunk is neither**:
it is machine-generated data-plane volume that joins in after identity is known,
and admitting chunks would put the node registry on the wrong side of the scale
argument.

The same rule is why a workflow artifact gets the `stored` resource status
rather than `ready`: step output is machine-generated too.

## Property graphs are a read-only view

SQL/PGQ in PG19 defines a property graph as a view over ordinary relational
tables. There is no separate graph store, no migration to adopt it, and no
second copy of anything to keep in step — `nodes`, `node_keys` and `edges` are
tables you can read with plain SQL, and `GRAPH_TABLE` is another way to ask.

One current PG19 limitation is worth knowing rather than discovering: **element
pattern quantifiers are not supported**, so variable-length paths are expressed
with `DEPTH` rather than with `{1,3}` syntax.

## Over REST

```
POST /rpc/query   {"p_query": "LOOKUP \"acme\""}
```

RLS applies, so results are filtered to what the caller may see. Two things make
results look "missing" and neither is a bug: querying as a superuser (RLS is
bypassed, so you see *more*, not less, and the filtered views behave
unexpectedly), and forgetting `request.jwt.claims`, which leaves the caller
anonymous.
