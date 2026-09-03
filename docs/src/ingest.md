# Uploading files

You post a file and, with nothing else to run, it becomes an answer to a
question. That path is two workflow steps and one function call to install them,
and a flag on the same call adds a second index that makes the upload connected
as well as findable.
{: .lede }

## Installing the pipeline

`POST /files` hashes the bytes, stores them content-addressed in object storage,
registers a resource, and starts the ingestion workflow named by the channel you
uploaded to. That workflow has to exist first.

What we are trying to do here is install the pipeline that turns any arriving
file into searchable chunks.
{: .goal }

The model has to be registered before the pipeline can name it, so this is two
statements and the first one is not optional:

```sql
insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, is_default)
values ('text-embedding-3-small', 1536, 'openai',
        'https://api.openai.com/v1/embeddings', 'LLM_API_KEY', true);
select aiq.register_embedding_space('text-embedding-3-small');

select content.install_ingest_workflow('text-embedding-3-small');
-- ingest_file: parse, embed with text-embedding-3-small in batches
```

Skip the first two and the third refuses rather than installing something that
would fail later, which is the behaviour you want but does read as an error on
a fresh install:

```
ERROR:  embedding model 'text-embedding-3-small' is not registered, so an
        ingestion pipeline naming it would fail at every run. Register it
        first, or call this with no argument to install the parse-only pipeline.
```

**Both of the steps it writes run on the `ingest` queue, so something has to be
polling that queue.** The compose file ships an `ingest-worker` service for
exactly this; a deployment that runs only the `http` worker accepts uploads and
never reads them — `POST /files` returns 201, the run starts, and `parse` sits
at `ready` with nothing erroring.

<details class="why" markdown="1">
<summary>Why it works — it writes an ordinary workflow document, and no step
carries a url</summary>

```yaml
name: ingest_file
steps:
  - id: parse
    work: true
    queue: ingest
    input: {op: ingest, resource_id: '{{run.resource_id}}'}
  - id: embed
    needs: [parse]
    work: true
    queue: ingest
    input: {op: embed, resource_id: '{{run.resource_id}}',
            model: text-embedding-3-small}
```

You can read it, edit it or replace it — it is a definition like any other,
which is the point of generating one rather than hard-coding a pipeline.

Neither step carries an endpoint. The worker asks `aiq.embed_batch_call()` for
the url, the request shape, the path to the vector in the response and the
*name* of the credential, so the model lives in exactly one place and naming it
here is naming a model that is registered.

<p class="related"><strong>Related</strong>
<a href="recipes.html#an-embedding-model-or-search-will-not-compile">registering
the model first</a> ·
<a href="grammar-workflow.html">what `work:` steps compile to</a></p>
</details>

## Uploading one

What we are trying to do here is put a file in and get chunks out, with nothing
to run afterwards.
{: .goal }

`POST /files` takes the bytes as the body — the Content-Type is what picks the
family — and the Content Server is on port 8081 in the compose stack.

```bash
curl -s http://localhost:8081/files \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: text/markdown' \
  -H 'x-p8-title: Aurora Kestrel note' \
  --data-binary @note.md
```

<div class="evidence" markdown="1">
<div class="label">201, then the run the upload started</div>

```
{"resource_id":"44057672-…","checksum":"b440dc19…","bytes":144}

 step_key | queue  | status | attempts
----------+--------+--------+----------
 parse    | ingest | done   |        1
 embed    | ingest | ready  |        4

 resources | chunks
-----------+--------
         1 |      1
```
</div>

`embed` retrying is what a keyless install looks like: parsing and chunking need
no model, so the file is chunked and text-searchable, and the vector arrives
once `LLM_API_KEY` is set on the ingest worker. `x-p8-channel` picks the channel
whose workflow runs — omitted, it is the default one — and `$TOKEN` is the one
from [install](install.html#the-first-user-and-a-token).

## What we do with each format

The family comes from the content type and falls back to the extension. We never
take `application/octet-stream` as a family, since that is what an uploader sends
when it does not know.

| Format | What reads it |
|---|---|
| markdown, text | itself, already in the intermediate form |
| html | the standard library's `HTMLParser` |
| pdf | `pymupdf4llm`, which reads the PDF's own structure, no model, milliseconds a page |
| docx | `python-docx`, a zip and some XML in document order |
| wav, mp3, m4a | a transcription endpoint, since a model call belongs to the worker |
| csv, tsv, xlsx, parquet | `pyarrow`, and the file becomes a Parquet dataset rather than chunks |
| images, anything unrecognised | stored and retrievable, not pretended to be text |

<details class="why" markdown="1">
<summary>Why it works — everything text-shaped normalises to markdown before it
is chunked</summary>

Chunking each format from its own structure would be three chunkers with three
sets of edge cases. Normalising first means one chunker, and a passage that
still carries the heading and the table that told a reader what the sentence was
about.

We chunk with `semchunk`, which splits on the most significant boundary that
fits the budget — sections, then paragraphs, then sentences, then clauses —
rather than on a separator list. On Isaacus's legal retrieval measurement that
is worth about 8% over recursive splitting and about 12% over fixed-size chunks,
it is pure Python with no model behind it, and it returns offsets, so a citation
can point at a span rather than at a whole chunk.

**The default is 700 tokens, and most RAG code uses 200 to 400.** That is the
wrong size for what we do with a chunk, which is retrieve it, show it to a model
and cite it: a 250-token chunk retrieves the sentence that matched and loses the
sentence that explains it, so the model answers from a fragment and the citation
points at one. 700 tokens is two or three paragraphs of prose. Transcripts
default to 450 with more overlap, because there are no headings and no blank
lines to cut on.

The token counter is characters ÷ 4 and works offline. `tiktoken` is a better
count and downloads its encoding the first time it runs, which is an unhappy
thing to discover inside a container with no egress, so it is opt-in:
`tokenizer: "tiktoken:cl100k_base"`.

<p class="related"><strong>Related</strong>
<a href="agents.html#citations-are-derived-not-asked-for">how a chunk becomes a
citation</a></p>
</details>

## A table is not prose

What we are trying to do here is make a spreadsheet answerable by query rather
than by retrieval.
{: .goal }

```sql
select content.dataset_uri('incidents');
-- s3://p8-content/datasets/incidents/*.parquet
```

```python
tabular.read_dataset(uri, "select site, sum(downtime_hours) from dataset group by 1")
```

<details class="why" markdown="1">
<summary>Why it works — chunking a CSV is the default elsewhere and it answers
nothing</summary>

Two hundred rows of a price table become two hundred near-identical embeddings
that rank against each other, so *what was August revenue* retrieves five rows
that all look equally like the question. A table already has a query language.

So a tabular upload converts once to Parquet, lands beside the original bytes in
object storage, and is registered as a dataset with a chunk count of zero. The
column list comes from the Arrow schema the conversion produced rather than from
a CSV header, since a header is names and a query needs types.

Files for one dataset land under one prefix and `mode: append` means the reader
globs it, so this month's export joins last month's under one name. That is the
whole of the resemblance to Iceberg: there is no manifest, no snapshot
isolation, no schema evolution and no time travel. What breaks first is a schema
change between two files under one prefix, and a deployment that needs those
things needs Iceberg — which it can reach with a `read_parquet` rather than a
rewrite.

<p class="related"><strong>Related</strong>
<a href="outputs.html#4-everything-else-is-bytes">what else lives in object
storage</a></p>
</details>

## Changing the policy without changing the code

What we are trying to do here is make every file on one channel chunk small,
without touching the worker.
{: .goal }

```sql
update content.channels
   set config = content.merge_policy(config, '{"ingest_policy":
        {"chunking": {"target_tokens": 300}, "keep_markdown": false}}'::jsonb)
 where name = 'contracts';
```

<details class="why" markdown="1">
<summary>Why it works — three layers, and a later one wins key by key at every
depth</summary>

```
family default   a fact about a format and its library, in code
      ↓
channel          content.channels.config.ingest_policy
      ↓
upload           content.resources.metadata.ingest_policy
```

Defaults are statements about libraries and change when the library does, in the
same commit. Overrides are statements about a deployment's *content*, made by
the person uploading — who is usually not the person who deployed the worker.

The merge is **deep**, because a shallow one lets an upload that sets a single
chunking field erase the channel's other chunking fields, and the uploader would
then be running a strategy nobody chose.

The policy is validated strictly, so a misspelled key is refused by name rather
than ignored, and it fails the step **terminally** — it will not validate on the
fifth attempt either.

<p class="related"><strong>Related</strong>
<a href="failure.html#terminal-or-retryable">why a config error is terminal</a></p>
</details>

## Embedding a corpus is one call, not one per chunk

What we are trying to do here is embed four hundred chunks without four hundred
task rows.
{: .goal }

```json
{"embedded": 412, "requests": 5}
```

<details class="why" markdown="1">
<summary>Why it works — the payload cap makes the per-chunk shape impossible,
not merely slow</summary>

Embedding a *query* is a step that produces a vector and hands it to the next
step, and that is what the `embed:` step kind is for. Embedding a *corpus* runs
the other way: N vectors that have to be kept, keyed by chunk, in the space of
the model that produced them.

It cannot go through the engine one vector at a time. A step's output is capped
at 64KB and one 1536-dimension vector is about 31KB of JSON, so two vectors do
not fit in one task output whatever else you do. The process holding the vectors
is therefore the one that writes them, and what comes back to the engine is a
receipt.

For an eight-chunk document that is one request and one task row, where the
per-chunk shape was eight of each. Re-embedding a chunk replaces its vector, so
re-ingesting a document whose text changed does not leave the old vector ranking
against the new text.

<p class="related"><strong>Related</strong>
<a href="outputs.html#1-the-inline-payload">the payload cap</a> ·
<a href="grammar-workflow.html#a-vector-query-is-two-tasks">the query-shaped
`embed:` step</a></p>
</details>

## A second index off the same parse

Chunks and vectors make an upload findable. The other thing we can do with the
same parse is make it *connected*: read what each passage names and how those
things relate, and land that as nodes and edges in the graph.

What we are trying to do here is turn the graph index on, which is a flag on the
same install call.
{: .goal }

```sql
select aiq.install_structure_null('gpt-4o-mini');
select content.install_ingest_workflow(
           p_model       => 'text-embedding-3-small',
           p_graph_index => true,
           p_graph_model => 'gpt-4o-mini');
-- ingest_file: parse, embed with text-embedding-3-small in batches,
--             graph-index each window with structure_null (gpt-4o-mini)
```

<div class="evidence" markdown="1">
<div class="label">every extracted edge carries where it came from</div>

```
    relation     |       title        |     agent
-----------------+--------------------+----------------
 contains        | r7-field-notice.md | structure_null
 affiliated_with | r7-field-notice.md | structure_null
 supplies        | r7-field-notice.md | structure_null
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the two indexes are siblings, and the extractor is a row</summary>

The flag adds two steps:

```yaml
  - id: graph
    needs: [parse]                 # a sibling of embed, not a successor
    matrix:
      rows: {function: windows_to_index, args: ['{{run.resource_id}}']}
      max_fanout: 200
      template: {queue: http, rate_key: structure_extraction, rest: …}

  - id: land_graph
    needs: [graph]
    sql: {function: land_graph_windows, args: ['{{steps.graph.result.task_id}}']}
```

`embed` and `graph` both wait on `parse` and on nothing else, so the two indexes
run at the same time over the same text, a deployment with no embedding model
can still build a graph, and an extraction that fails costs you no vectors. A
window here is a chunk, so the extractor reads the same passages the embedder
embedded and a node can be traced back to the passage that named it.

The extractor is a row in `agentic.agents` rather than a prompt in the workflow,
which means changing what it looks for is an update rather than an edit to every
pipeline that uses it. `aiq.install_structure_null()` writes the default one: a
system prompt asking for what the document names and how those things connect,
and a JSON Schema whose relation field is an enum built from
`aiq.graph_vocabulary`. The vocabulary is closed, so an extractor cannot invent a
relation the graph then has to carry forever.

The five uploaded files produced about 90 soft nodes and 70 extracted edges over
13 relations. Those counts move between runs, since a model is doing the reading.
What does not move is the provenance above.

<p class="related"><strong>Related</strong>
<a href="query.html#identity-what-becomes-a-node">the other way rows reach the
graph</a> ·
<a href="grammar-workflow.html#matrix-the-work-to-do-is-a-query-result">why the
fan-in parses a string</a></p>
</details>

<details class="why" markdown="1">
<summary>Why it works — two things to know before you turn it on</summary>

**It costs a completion per window**, where the embedding branch costs a fraction
of a cent per document, and that is why the flag defaults to off. On five
documents it was a few cents; on a corpus it is the line item to watch.

**A cheap model gets some of it wrong, and we drop those rather than fail the
upload.** Two kinds: an edge pointing at node 8 when the model listed eight
nodes, and a relation outside the vocabulary — gpt-4o-mini emitted `trips` on a
document about a robotic arm.

The schema carries the vocabulary as an enum, and OpenAI honours an enum only in
strict structured-output mode, which this schema cannot use because strict wants
every property in `required` and the attribute bag is optional. So the enum is a
strong hint rather than a constraint. Both kinds are dropped before landing and
**counted in the receipt** (`edges_dropped_ordinal`, `edges_dropped_offvocab`),
which also tells you when the vocabulary is too small for your corpus.

Nothing resolves a soft node yet. Extraction lands names, so `Ravensworth` and
`Ravensworth Precision` are two nodes until something decides they are one, and
`aiq.promote_soft_node` is the function that would do it and is called by
nothing. The graph answers *what did the documents name, and how did they connect
it* rather than *what is out there*.

<p class="related"><strong>Related</strong>
<a href="recipes.html#a-throttle-has-to-exist-before-a-step-names-it">the
throttle this branch creates for you</a> ·
<a href="failure.html#fan-out-and-partial-failure">what a failed window does</a></p>
</details>

## Where it fails loudly

Three of these exist because the alternative is a pipeline that reports success.

- **A parse that yields nothing raises**, and names the likely cause for the
  parser that ran. A scanned PDF returning `""` would otherwise produce zero
  chunks, a resource that looks stored, and a file absent from every search
  anyone runs.
- **`ready` means "in the corpus".** A resource is marked `ready` only once
  chunks were written and `stored` otherwise, which is what
  `content.check_drift()` reconciles against.
- **A missing vector raises** rather than landing the rest of the batch, since a
  chunk with no vector is a hole in a corpus that still answers questions.

## What is not built, and one thing that bites

**Uploading a file whose title matches one already there fails to ingest.** A
resource projects into the node registry under `coalesce(title, uri, id)` and
those keys are unique, so v2 of `report.pdf` raises inside the projection and the
parse step fails for a reason that has nothing to do with parsing. This is the
most ordinary thing a user does. The fix is a decision about identity rather than
about ingestion — either the projection tolerates a taken name, or document keys
stop being titles — and until it is made, give the second upload a different
title.

The rest of the gaps:

- **No OCR.** A scanned PDF fails loudly and stays pending. Docling or a vision
  model per page is the opt-in, and it is not written.
- **No image understanding.** Images are stored. Describing one with a vision
  model is a real feature, and defaulting to it would put a model call behind
  every avatar upload.
- **Re-chunking is not incremental.** Fixing a typo in a 100-page document
  re-chunks and re-embeds all of it.
- **A failed batch re-embeds the whole batch.** The step is idempotent and not
  resumable, so four of five requests already paid for are paid for again.
- **A provider that cannot batch is called N times.** Ollama's embeddings
  endpoint takes one prompt, so the worker loops — same receipt, same retry, and
  no faster than the per-chunk shape it replaced.

Five formats — markdown, PDF, DOCX, WAV and CSV — were uploaded through a live
stack with both indexes on, and four questions were answered afterwards from four
different formats, with the CSV answered by SQL over Parquet rather than by
retrieval. Everything above is that run: the chunk counts, the one request for
eight chunks, the edges above and the relation the model invented.

Next: [querying](query.html).
