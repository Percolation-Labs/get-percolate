# What a step leaves behind

A step finishing is not the same as a step producing something. This page is
about the second half: where the thing a step *made* actually lives, who owns it
afterwards, and what the next step is allowed to read.
{: .lede }

There are four answers, and only four. They are not interchangeable, and picking
the wrong one is how a workflow ends up with its real state in a JSONB column
nobody can query.

| Class | The output is | It lives in | The next step reads |
|---|---|---|---|
| **Payload** | a small JSON value | `tasks.output`, copied into `runs.context` | `{{steps.<id>.result}}` |
| **State** | rows | your tables | ids and counts — a receipt |
| **Shape** | a validated structured answer from a model | `agentic.messages` | the value, plus the message it came from |
| **Bytes** | a file | object storage, registered in `content` | `{{steps.<id>.$artifact}}` |

## 1. The inline payload

`{{steps.<id>.result}}` is a *value*, interpolated into the next task's input at
dispatch. That has a cost that is easy to miss: every byte a step returns is
copied into another task row, and again into `runs.context`, and stays there for
the life of the run.

So the payload class is bounded — `workflow.max_payload_bytes`, 64KB by default,
a hard limit rather than a warning. It is sized for what it is *for*: a status
code, a count, a document id, a 768-dimension embedding on its way from an embed
step to a search step (~10KB as JSON, and the reason the limit was raised from
8KB). Anything bigger is one of the other three classes wearing the wrong hat.

## 2. The database is the state

A `sql` step names a registered function; the function writes rows; the rows
*are* the result. **A step of this class returns a receipt, not the result** —
ids and counts, bounded by construction:

```json
{"result": {"resource_id": "…", "chunks": 412}}
```

The next step re-reads by key. A step that returns its rows has quietly made the
task table the storage layer for data that already has a home — with no index,
no type, and no RLS policy of its own.

## 3. A model produced a shape

An `agent:` step with `output_schema` is the only step whose output is both
authored outside the system and contractually shaped. The engine validates it
before storing, and a violation **retries** — the one place retry is the right
remedy.

<div class="evidence" markdown="1">
<div class="label">Not yet built</div>

The answer is validated by the workflow engine and stored in
`workflow.tasks.output`. It does **not** yet land as an assistant message row in
`agentic.messages` — which has no JSON column, so a structured answer would be
stored as a string with no link to the schema it satisfied. Four small pieces
close it; they are named in the specs rather than implied.
</div>

## 4. Everything else is bytes

A rendered report, a scraped page kept verbatim, a model response too large to
inline. It goes to object storage and comes back as a ref:

```json
{"status": 200, "result": {"pages": 12}, "$artifact": "9f3c…-uuid"}
```

### The ref is a sibling of `result`, not a value inside it

Three things fall out of that placement:

- `{{steps.<id>.result}}` is untouched, and `{{steps.<id>.$artifact}}` resolves
  the ref with no change to the template resolver.
- `output_schema` validates `result` and never sees the engine's key, so a
  contract with `additionalProperties: false` stays writable.
- A step that produced *only* bytes writes no `result` at all, and
  `{{steps.<id>.result}}` then fails loudly — correct, because there is no value.

### It is a resource id, not an `s3://` URI

`workflow.register_artifact(…)` returns a row in `content.resources`. That is
what makes an artifact RLS-scoped, checksum-deduped, servable, and visible to
`content.check_drift`. A bucket path in a JSONB column is none of those, and
drags a bucket name into a row meant to stay inspectable and replayable — the
same argument that makes `credential_ref` a *name*.

Reading it back needs no worker:

```yaml
  - id: index_it
    needs: [render]
    sql: {function: artifact, args: ['{{steps.render.$artifact}}']}
```

### Why the earlier spelling did not work

The specs used to say return `{"$ref": "s3://…"}`. The size check uses the jsonb
`?` operator, which is **top-level only**, while every step nests its payload
under `result`. Probed at a 64KB cap:

<div class="evidence" markdown="1">
<div class="label">probe</div>

```
A: oversized, {"$ref": …} at the top level        -> accepted, breaks every
                                                     {{steps.x.result}} reading it
B: oversized, {"status":200,"result":{"$ref": …}} -> REFUSED as oversized
```
</div>

No shape satisfied both. The size *bypass* that came with it is gone too: a real
ref is about thirty bytes and was never going to trip a 64KB cap, so
`not (output ? '$ref')` only ever fired on a payload that offloaded its bytes
and then inlined them anyway.
