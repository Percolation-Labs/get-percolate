# The harbour sample

A port-operations company: two tenants, four operators, five vessels, three
ports, a handful of inspections, a corpus of reports and a graph tying them
together. It is the domain every worked example in the
[documentation](https://percolating-sirsh.github.io/get-percolate) queries, so
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

Every step is idempotent, so a second run is how you pick up an edit rather
than something to avoid. The documents step re-uploads, and the Content Server
addresses files by content hash, so identical bytes do not become a second
resource.

## Taking it out

`plugin.yaml` is applied as a named plugin, so its skills and agents come out
together. The rest is an ordinary schema:

```sql
select agentic.remove_plugin('harbour');
drop schema harbour cascade;
```

The registry rows and the corpus are left for you to remove deliberately —
`aiq.nodes` for the three entity types, and the `harbour-reports` resources —
because dropping indexed content is not something a sample should do on your
behalf.
