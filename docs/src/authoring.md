# Authoring in YAML

One document, five step kinds, three template namespaces. The compiler is a
Rust extension rather than a service, so authoring is SQL-native: nothing needs
to be running to define a workflow.
{: .lede }

## Step kinds

Each step has exactly **one** action key. Zero or two is a compile error naming
the step.

| Kind | Runs | Needs a process |
|---|---|---|
| `sql` | a registered function, in-database | no |
| `p8ql` | a query in the P8QL dialect | no |
| `rest` | an outbound HTTP call | the generic worker |
| `agent` | a row in `agentic.agents` | the Agent Runtime |
| `work` | code you wrote | your worker |

Plus control forms: `matrix` (fan-out), `timer`, `signal` (wait for the outside
world), `sub_workflow`.

**Reaching for `work` is usually a sign the step should have been `sql`.**
Indexing, projection, a rollup, a graph update — all of those are `sql`, and
they run with nothing running anywhere.

## Templates

`{{run.x}}`, `{{steps.<id>.<path>}}`, `{{item.*}}` and `{{env.X}}` resolve **at
dispatch**, never when the workflow is defined. Substituting at author time
would make the stored definition a snapshot of one run, and make the recorded
task input a lie about what was sent.

### Every step nests its payload under `result`

`{{steps.<id>.result}}` is the one idiom to learn. A `sql` step returns
`{"result": …}`, a `rest` step `{"status": 200, "result": …}`, a `matrix` step
`{"result": {"task_id": …, "fanout": N}}`. Reach into it with
`{{steps.<id>.result.<path>}}`.

### Two resolvers, deliberately different

- **`rest` steps** are resolved by the worker, which has `{{env.*}}` because
  credentials and endpoints live in its environment.
- **`sql` steps** are resolved in-database, and have **no `{{env.*}}`** — the
  database has no business reading the deployment's environment. Only
  whole-string references are substituted, and they keep their native type, so
  a vector arrives as an array rather than a string.

## Credentials are names

```yaml
  - id: call
    rest:
      url: '{{env.LLM_URL}}/v1/chat/completions'
      credential_ref: LLM_API_KEY
```

`credential_ref` is a **name**, resolved by the worker from its own environment.
The database stores only the reference, so a dump of `workflow.tasks` never
contains a secret and a task stays inspectable and replayable.

## Declaring an output shape

```yaml
  - id: classify
    agent: triage
    input: 'Classify: {{item.text}}'
    output_schema:
      type: object
      required: [verdict, confidence]
      properties:
        verdict:    {type: string, enum: [SAFETY, FINANCE, OTHER]}
        confidence: {type: number}
```

The engine parses the answer — a model returns structured output as message
*content*, i.e. a string — and checks it before anything is stored.

**A shape violation is retryable, and it is the only failure deliberately
classified that way.** Every other terminal classification exists because
retrying cannot help: a 404 stays a 404, an oversized response stays oversized.
Here the same prompt genuinely can produce conforming output next attempt, so
`max_attempts` becomes a real budget for "ask again".

It is a **shape check, not JSON Schema**. Types (including `integer`),
`required`, `properties`, `enum`, `items` and `additionalProperties: false` —
which is what "combine N agent results safely" actually needs. `$ref`,
`allOf`/`anyOf`/`oneOf`, `pattern`, `format` and numeric bounds are *not*
supported, and are named here rather than silently ignored.

## What is refused rather than ignored

This is the part worth reading twice, because all three exist to prevent a
document that quietly means something other than what it says.

<ol class="steps" markdown="1">
<li markdown="1">**An unknown key on a step** is a compile error listing the valid ones — so a typo (`ouput_schema`) cannot be mistaken for a feature.</li>
<li markdown="1">**`session`, `session_group` or `jsonpath` outside an `agent:` step**, which would otherwise be accepted and emit nothing.</li>
<li markdown="1">**A feature the installed compiler cannot emit**, *including when the document compiles clean*. `output_schema` is not a step kind: serde drops the unknown key, the document compiles, and the declared contract simply is not there at runtime. A silently dropped contract is worse than an unsupported feature, so `define_yaml` probes `compiler_capabilities()` and refuses.</li>
</ol>

## Two validators, two questions

| Checked by | Rejects |
|---|---|
| `p8_compile_workflow` (Rust) | malformed YAML; a step with zero or two action keys; a `needs` naming a step that does not exist |
| `validate_spec` (on insert) | duplicate keys, unreachable steps, cycles with no entry point |
| `lint_spec` (authoring time) | a `p8ql` that is not a query, an unregistered `sql` function, an agent that does not exist, a `{{steps.NOSUCHSTEP}}` |

The third exists because the first two check the *graph* and nothing about its
*content* — and every one of those examples was accepted by `define_yaml` and
failed at run time, or worse, queued forever.
