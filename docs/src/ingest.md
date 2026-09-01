# Uploading files

You post a file and, with nothing else to run, it becomes an answer to a
question. That path is two workflow steps and one function call to install
them.
{: .lede }

`POST /files` hashes the bytes, stores them content-addressed in object
storage, registers a resource, and starts the ingestion workflow named by the
channel you uploaded to. The workflow parses the file to markdown, chunks it,
and embeds every chunk into the space of a registered model, so a few seconds
later `SEARCH` over `chunks` finds it.

We install the pipeline with one call:

```sql
select content.install_ingest_workflow();
-- ingest_file: parse + embed (text-embedding-3-small)
```

That writes an ordinary workflow document, which you can read, edit or replace:

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

Neither step carries a url. The worker asks `aiq.embed_batch_call()` for the
endpoint, the request shape, the path to the vector in the response and the
name of the credential, so the model still lives in one place — the registry —
and naming it here is naming a model that is registered.

## What we do with each format

The family comes from the content type and falls back to the extension. We
never take `application/octet-stream` as a family, since that is what an
uploader sends when it does not know.

| Format | What reads it |
|---|---|
| markdown, text | itself, already in the intermediate form |
| html | the standard library's `HTMLParser` |
| pdf | `pymupdf4llm`, which reads the PDF's own structure, no model, milliseconds a page |
| docx | `python-docx`, a zip and some XML in document order |
| wav, mp3, m4a | a transcription endpoint, since a model call belongs to the worker |
| csv, tsv, xlsx, parquet | `pyarrow`, and the file becomes a Parquet dataset rather than chunks |
| images, anything unrecognised | stored and retrievable, not pretended to be text |

Everything text-shaped is normalised to markdown before it is chunked, and the
rest follows from that. Chunking each format from its own structure would be
three chunkers with three sets of edge cases, and normalising first means one
chunker and a passage that still carries the heading and the table that told a
reader what the sentence was about.

We chunk with `semchunk`, which splits on the most significant boundary that
fits the budget — sections, then paragraphs, then sentences, then clauses —
rather than on a separator list. On Isaacus's legal retrieval measurement that
is worth about 8% over recursive splitting and about 12% over fixed-size
chunks, it is pure Python with no model behind it, and it returns offsets, so
a citation can point at a span rather than at a whole chunk.

### Why 700 tokens

Most RAG code chunks at 200 to 400 tokens and that is the wrong size for what
we do with a chunk, which is retrieve it, show it to a model and cite it. A
250-token chunk retrieves the sentence that matched and loses the sentence that
explains it, so the model answers from a fragment and the citation points at
one. 700 tokens is two or three paragraphs of prose. Transcripts default to 450
with more overlap, because there are no headings and no blank lines to cut on.

The token counter is characters ÷ 4 and works offline. `tiktoken` is a better
count and downloads its encoding the first time it runs, which is an unhappy
thing to discover inside a container with no egress, so it is opt-in:
`tokenizer: "tiktoken:cl100k_base"`.

## A table is not prose

Chunking a CSV is the default in most pipelines and it answers nothing: two
hundred rows of a price table become two hundred near-identical embeddings that
rank against each other, so "what was August revenue" retrieves five rows that
all look equally like the question. A table already has a query language.

So a tabular upload converts once to Parquet, lands beside the original bytes
in object storage, and is registered as a dataset with a chunk count of zero.
The column list comes from the Arrow schema the conversion produced rather than
from a CSV header, since a header is names and a query needs types.

```sql
select content.dataset_uri('incidents');
-- s3://p8-content/datasets/incidents/*.parquet
```

```python
tabular.read_dataset(uri, "select site, sum(downtime_hours) from dataset group by 1")
```

Files for one dataset land under one prefix and `mode: append` means the reader
globs it, so this month's export joins last month's under one name. That is the
whole of the resemblance to Iceberg: there is no manifest, no snapshot
isolation, no schema evolution and no time travel. What breaks first is a
schema change between two files under one prefix, and a deployment that needs
those things needs Iceberg, which it can reach with a `read_parquet` rather
than a rewrite.

## Changing the policy without changing the code

Three layers, and a later one wins key by key at every depth:

```
family default   a fact about a format and its library, in code
      ↓
channel          content.channels.config.ingest_policy
      ↓
upload           content.resources.metadata.ingest_policy
```

Defaults are statements about libraries and change when the library does, in
the same commit. Overrides are statements about a deployment's content, made by
the person uploading, who is usually not the person who deployed the worker.

```sql
-- every file on this channel chunks small and keeps no markdown
update content.channels
   set config = content.merge_policy(config, '{"ingest_policy":
        {"chunking": {"target_tokens": 300}, "keep_markdown": false}}'::jsonb)
 where name = 'contracts';
```

The merge is deep, because a shallow one lets an upload that sets a single
chunking field erase the channel's other chunking fields, and the uploader
would then be running a strategy nobody chose. The policy is validated
strictly, so a misspelled key is refused by name rather than ignored, and it
fails the step terminally, since it will not validate on the fifth attempt
either.

## Embedding a corpus is one call, not one call per chunk

Embedding a *query* is a step that produces a vector and hands it to the next
step, and that is what the `embed:` step kind is for. Embedding a *corpus* runs
the other way: N vectors that have to be kept, keyed by chunk, in the space of
the model that produced them.

It cannot go through the engine one vector at a time. A step's output is capped
at 64KB and one 1536-dimension vector is about 31KB of JSON, so two vectors do
not fit in one task output whatever else you do. The process holding the
vectors is therefore the one that writes them, and what comes back to the
engine is a receipt:

```json
{"embedded": 412, "requests": 5}
```

For an eight-chunk document that is one request and one task row, where the
per-chunk shape was eight of each. Re-embedding a chunk replaces its vector, so
re-ingesting a document whose text changed does not leave the old vector
ranking against the new text.

## Where it fails loudly

Three of these exist because the alternative is a pipeline that reports
success:

- A parse that yields nothing raises, and names the likely cause for the parser
  that ran. A scanned PDF returning "" would otherwise produce zero chunks, a
  resource that looks stored, and a file absent from every search anyone runs.
- `ready` means "in the corpus". A resource is marked `ready` only once chunks
  were written and `stored` otherwise, which is what `content.check_drift()`
  reconciles against.
- A missing vector raises rather than landing the rest of the batch, since a
  chunk with no vector is a hole in a corpus that still answers questions.

## What is not built, and one thing that bites

**Uploading a file whose title matches one already there fails to ingest.** A
resource projects into the node registry under `coalesce(title, uri, id)` and
those keys are unique, so v2 of `report.pdf` raises inside the projection and
the parse step fails for a reason that has nothing to do with parsing. This is
the most ordinary thing a user does. The fix is a decision about identity
rather than about ingestion — either the projection tolerates a taken name, or
document keys stop being titles — and until it is made, give the second upload
a different title.

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
  endpoint takes one prompt, so the worker loops — same receipt, same retry,
  and no faster than the per-chunk shape it replaced.
- **The graph index is off by default.** The same parse can feed a second
  index, where a structured-output agent reads the document and its nodes and
  edges land in the graph, so an upload is connected as well as findable. Its
  database half ships and is asserted; no model has been pointed at it yet. A
  completion per document is a different order of cost from an embedding per
  chunk, which is why that branch is a flag on
  `content.install_ingest_workflow()` rather than a default.

Five formats — markdown, PDF, DOCX, WAV and CSV — were uploaded through a live
stack, and four questions were answered afterwards from four different formats,
with the CSV answered by SQL over Parquet rather than by retrieval. Everything
above is that run.

Next: [querying](query.html).
