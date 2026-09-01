# What a step leaves behind

A step finishing is not the same as a step producing something. This page is
about the second half — where the thing a step made actually lives, who owns it
afterwards, and what the next step can read.
{: .lede }

There are four answers. They are not interchangeable, and picking the wrong one
is how you end up with the real state of a workflow sitting in a JSONB column
that nobody can query.

| Class | The output is | It lives in | The next step reads |
|---|---|---|---|
| **Payload** | a small JSON value | `tasks.output`, copied into `runs.context` | `{{steps.<id>.result}}` |
| **State** | rows | your tables | ids and counts, a receipt |
| **Shape** | a validated structured answer from a model | `agentic.messages` | the value, plus the message it came from |
| **Bytes** | a file | object storage, registered in `content` | `{{steps.<id>.$artifact}}` |

## 1. The inline payload

`{{steps.<id>.result}}` is a value that gets interpolated into the next task's
input when it is dispatched. That has a cost which is easy to miss: every byte
a step returns is copied into another task row, and again into `runs.context`,
and stays there for the life of the run.

So this class is bounded, by `workflow.max_payload_bytes`, 64KB by default, and
it is a hard limit rather than a warning. That is sized for what it is for — a
status code, a count, a document id, or a 768-dimension embedding on its way
from an embed step to a search step, which is around 10KB as JSON and is why
the limit moved up from 8KB. Anything bigger is one of the other three classes
wearing the wrong hat.

## 2. The database is the state

A `sql` step names a registered function, the function writes rows, and the
rows are the result. A step like this should return a receipt rather than the
result — ids and counts, bounded by construction:

```json
{"result": {"resource_id": "…", "chunks": 412}}
```

The next step re-reads by key. If a step returns its rows instead, you have
made the task table the storage layer for data that already has a home, with no
index, no types and no RLS policy of its own.

## 3. A model produced a shape

An `agent:` step with `output_schema` is the only step whose output is both
written by something outside the system and shaped by a contract. The engine
validates it before storing it, and a violation retries.

<div class="evidence" markdown="1">
<div class="label">Not built yet</div>

The answer is validated by the workflow engine and stored in
`workflow.tasks.output`. It does not yet land as an assistant message row in
`agentic.messages`, which has no JSON column, so a structured answer would go
in as a string with no link to the schema it satisfied. There are four small
pieces to close this and they are listed in the specs.
</div>

## 4. Everything else is bytes

A rendered report, a scraped page kept verbatim, a model response too large to
inline. It goes to object storage and comes back as a ref:

```json
{"status": 200, "result": {"pages": 12}, "$artifact": "9f3c…-uuid"}
```

### The ref sits beside `result`, not inside it

Three things follow from putting it there:

- `{{steps.<id>.result}}` is unchanged, and `{{steps.<id>.$artifact}}` resolves
  the ref with no change to the template resolver.
- `output_schema` validates `result` and never sees the engine's key, so a
  contract with `additionalProperties: false` still works.
- A step that produced only bytes writes no `result` at all, so
  `{{steps.<id>.result}}` fails loudly. That is what you want, since there is
  no value.

### It is a resource id, not an `s3://` URI

`workflow.register_artifact(…)` gives you back a row in `content.resources`.
That is what makes an artefact RLS-scoped, deduplicated by checksum, servable,
and visible to `content.check_drift`. A bucket path in a JSONB column is none
of those, and it puts a bucket name into a row you wanted to keep inspectable
and replayable, in the same way that `credential_ref` is a name rather than a
secret.

Reading it back needs no worker:

```yaml
  - id: index_it
    needs: [render]
    sql: {function: artifact, args: ['{{steps.render.$artifact}}']}
```

### Why the earlier spelling did not work

The specs used to say return `{"$ref": "s3://…"}`. The size check uses the
jsonb `?` operator, which only looks at top-level keys, while every step nests
its payload under `result`. Tried both ways against a 64KB cap:

<div class="evidence" markdown="1">
<div class="label">probe</div>

```
A: oversized, {"$ref": …} at the top level        -> accepted, and breaks every
                                                     {{steps.x.result}} reading it
B: oversized, {"status":200,"result":{"$ref": …}} -> refused as oversized
```
</div>

No shape satisfied both. The size bypass that came with it is gone as well: a
real ref is about thirty bytes and was never going to trip a 64KB cap, so
`not (output ? '$ref')` only ever fired on a payload that had offloaded its
bytes and then inlined them anyway.

Next: [failure and retry](failure.html).
