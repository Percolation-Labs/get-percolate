# What a step leaves behind

A step finishing is not the same as a step producing something. This page is
about the second half — where the thing a step made actually lives, who owns it
afterwards, and what the next step can read.
{: .lede }

There are four answers and they are not interchangeable. Picking the wrong one
is how you end up with the real state of a workflow sitting in a JSONB column
that nobody can query.

| Class | The output is | It lives in | The next step reads |
|---|---|---|---|
| **Payload** | a small JSON value | `tasks.output`, copied into `runs.context` | `{{steps.<id>.result}}` |
| **State** | rows | your tables | ids and counts, a receipt |
| **Shape** | a validated structured answer from a model | `agentic.messages` | the value, plus the message it came from |
| **Bytes** | a file | object storage, registered in `content` | `{{steps.<id>.$artifact}}` |

## 1. The inline payload

What we are trying to do here is pass a small value from one step to the next.
{: .goal }

```yaml
  - id: judge
    rest: {url: '{{env.LLM_URL}}/v1/chat/completions', jsonpath: choices.0.message.content}
  - id: route
    needs: [judge]
    sql: {function: route_by_verdict, args: ['{{steps.judge.result}}']}
```

<details class="why" markdown="1">
<summary>Why it works — every byte is copied twice, which is what bounds the
class</summary>

`{{steps.<id>.result}}` is interpolated into the next task's input when it is
dispatched. The cost is easy to miss: every byte a step returns is copied into
another task row, and again into `runs.context`, and stays there for the life of
the run.

So this class is bounded by `workflow.max_payload_bytes` — 64KB by default, and
a hard limit rather than a warning. That is sized for what it is for: a status
code, a count, a document id, or a 768-dimension embedding on its way from an
embed step to a search step, which is around 10KB as JSON and is why the limit
moved up from 8KB. Anything bigger is one of the other three classes wearing the
wrong hat.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#templates-and-the-one-rule-that-bites">whole-string
versus embedded references</a> ·
<a href="first-workflow.html">a payload flowing between four steps</a></p>
</details>

## 2. The database is the state

What we are trying to do here is have a step write rows and hand the next step a
receipt rather than the data.
{: .goal }

```json
{"result": {"resource_id": "…", "chunks": 412}}
```

<details class="why" markdown="1">
<summary>Why it works — returning the rows makes the task table the storage
layer</summary>

A `sql` step writes rows — with `write: true` on its own statement, or through
a registered function — and the rows *are* the result. The next step re-reads by
key.

If a step returns its rows instead, you have made `workflow.tasks` the storage
layer for data that already has a home — with no index, no types and no RLS
policy of its own. It also caps at 64KB, so the design fails at exactly the
scale where it mattered.

This is the same instinct behind a fan-in reading `matrix_outputs(task_id)`
rather than a payload: five hundred results are for aggregating inside a
function, not for passing through a step argument.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#registering-a-function-and-what-it-still-buys">registering
the function that writes them</a> ·
<a href="cookbook.html#7-fan-out-over-a-query-result">a fan-in reading a
handle</a></p>
</details>

## 3. A model produced a shape

What we are trying to do here is get an answer from a model that the next step
can treat as an object rather than as prose.
{: .goal }

```yaml
  - id: classify
    agent: triage
    output_schema:
      type: object
      required: [verdict]
      properties: {verdict: {type: string, enum: [SAFETY, FINANCE, OTHER]}}
```

<details class="why" markdown="1">
<summary>Why it works — it is the only output both written outside the system and
shaped by a contract</summary>

The engine validates before storing, and a violation retries — the one failure
in this engine deliberately classified that way, because the same prompt
genuinely can conform on the next attempt.

<div class="evidence" markdown="1">
<div class="label">Not built yet</div>

The answer is validated by the workflow engine and stored in
`workflow.tasks.output`. It does not yet land as an assistant message row in
`agentic.messages`, which has no JSON column — so a structured answer would go
in as a string with no link to the schema it satisfied. There are four small
pieces to close this and they are listed in the specs.
</div>

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#agent-steps-sessions-and-declared-shapes">what
the shape check supports and what it does not</a> ·
<a href="failure.html">why a shape violation retries</a></p>
</details>

## 4. Everything else is bytes

A rendered report, a scraped page kept verbatim, a model response too large to
inline. It goes to object storage and comes back as a ref.

What we are trying to do here is hand the next step something too big to carry,
and resolve it without a worker.
{: .goal }

```json
{"status": 200, "result": {"pages": 12}, "$artifact": "9f3c…-uuid"}
```

```yaml
  - id: index_it
    needs: [render]
    sql: {function: artifact, args: ['{{steps.render.$artifact}}']}
```

<details class="why" markdown="1">
<summary>Why it works — the ref sits beside `result`, not inside it, and the
earlier spelling could not</summary>

Three things follow from putting it there:

- `{{steps.<id>.result}}` is unchanged, and `{{steps.<id>.$artifact}}` resolves
  the ref with no change to the template resolver.
- `output_schema` validates `result` and never sees the engine's key, so a
  contract with `additionalProperties: false` still works.
- A step that produced only bytes writes no `result` at all, so
  `{{steps.<id>.result}}` fails loudly — which is what you want, since there is
  no value.

**It is a resource id, not an `s3://` URI.** `workflow.register_artifact(…)`
gives back a row in `content.resources`, which is what makes an artefact
RLS-scoped, deduplicated by checksum, servable, and visible to
`content.check_drift`. A bucket path in a JSONB column is none of those, and it
puts a bucket name into a row you wanted to keep inspectable and replayable — the
same argument that makes `credential_ref` a name rather than a secret.

Returning `{"$ref": "s3://…"}` in its place does not work, and nothing tells
you so. The size check uses the jsonb `?` operator, which only looks at
top-level keys, while every step nests its payload under `result`. Both ways
against a 64KB cap:

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

<p class="related"><strong>Related</strong>
<a href="ingest.html">what else lands in `content.resources`</a> ·
<a href="recipes.html#keys-are-names-never-values">the same argument about
credentials</a></p>
</details>

Next: [failure and retry](failure.html).
