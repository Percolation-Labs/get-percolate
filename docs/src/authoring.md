# Authoring in YAML

One document, five step kinds and three template namespaces. The compiler is a
Rust extension rather than a service, so nothing needs to be running for you to
define a workflow.
{: .lede }

## Step kinds

Each step has exactly one action key. Zero or two is a compile error that names
the step.

| Kind | Runs | Needs a process |
|---|---|---|
| `sql` | a registered function, in the database | no |
| `p8ql` | a query in the P8QL dialect | no |
| `rest` | an outbound HTTP call | the generic worker |
| `agent` | a row in `agentic.agents` | the Agent Runtime |
| `work` | code you wrote | your worker |

There are also control forms: `matrix` for fan-out, `timer`, `signal` for
waiting on the outside world, and `sub_workflow`.

If you find yourself reaching for `work`, it is usually a sign the step should
have been `sql`. Indexing, projection, rollups and graph updates are all `sql`,
and they run with nothing running anywhere.

## Templates

`{{run.x}}`, `{{steps.<id>.<path>}}`, `{{item.*}}` and `{{env.X}}` all resolve
when the step is dispatched, not when you define the workflow. If they resolved
at author time the stored definition would be a snapshot of one run, and the
task input we recorded would not be what was actually sent.

### Every step nests its payload under `result`

`{{steps.<id>.result}}` is the one idiom to learn. A `sql` step returns
`{"result": …}`, a `rest` step returns `{"status": 200, "result": …}`, and a
`matrix` step returns `{"result": {"task_id": …, "fanout": N}}`. Reach further
in with `{{steps.<id>.result.<path>}}`.

### Two resolvers that behave differently

`rest` steps are resolved by the worker, which has `{{env.*}}` available
because credentials and endpoints live in its environment.

`sql` steps are resolved inside the database and have no `{{env.*}}` at all,
since the database has no business reading the deployment's environment. Only
whole-string references are substituted and they keep their native type, so an
embedding arrives as an array rather than as a string.

## Credentials are names

```yaml
  - id: call
    rest:
      url: '{{env.LLM_URL}}/v1/chat/completions'
      credential_ref: LLM_API_KEY
```

`credential_ref` is a name that the worker resolves from its own environment.
The database only ever stores the reference, so a dump of `workflow.tasks`
never contains a secret and you can hand a task around and replay it.

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
content, which is to say a string — and checks it before anything is stored.

A shape violation retries, and it is the only failure in the engine classified
that way. Every other terminal classification is terminal because retrying
cannot help: a 404 stays a 404 and an oversized response stays oversized. Here
the same prompt really can produce conforming output next time, so
`max_attempts` becomes a budget for asking again.

This is a shape check rather than JSON Schema. You get types (including
`integer`), `required`, `properties`, `enum`, `items` and
`additionalProperties: false`, which covers what "combine N agent results
safely" actually needs. `$ref`, `allOf`/`anyOf`/`oneOf`, `pattern`, `format`
and numeric bounds are not supported, and we list them here rather than
ignoring them silently.

## What gets refused rather than ignored

Three things, all of which stop a document meaning something other than what it
says:

<ol class="steps" markdown="1">
<li markdown="1">An unknown key on a step is a compile error that lists the valid ones, so a typo like `ouput_schema` cannot pass for a feature.</li>
<li markdown="1">`session`, `session_group` or `jsonpath` outside an `agent:` step, which would otherwise be accepted and emit nothing.</li>
<li markdown="1">A feature the installed compiler cannot emit, even when the document compiles cleanly. `output_schema` is not a step kind, so serde drops the unknown key, the document compiles, and the contract you declared is not there at runtime. `define_yaml` refuses and tells you which of the two it hit, because a contract that vanishes is harder to debug than a feature that is missing — the run goes green either way.</li>
</ol>

## Three validators

| Checked by | Rejects |
|---|---|
| `p8_compile_workflow` (Rust) | malformed YAML, a step with zero or two action keys, a `needs` naming a step that does not exist |
| `validate_spec` (on insert) | duplicate keys, unreachable steps, cycles with no entry point |
| `lint_spec` (authoring time) | a `p8ql` that is not a query, an unregistered `sql` function, an agent that does not exist, `{{steps.NOSUCHSTEP}}` |

The third one exists because the first two check the shape of the graph and
nothing about its contents. Every example in that row was accepted by
`define_yaml` at some point and then failed at run time, or in the case of a
missing agent, sat queued forever.

Next: [what a step leaves behind](outputs.html).
