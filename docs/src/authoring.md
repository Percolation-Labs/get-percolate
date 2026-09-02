# Authoring in YAML

Writing a workflow is mostly a matter of choosing which of the step kinds a
piece of work actually is, and the choice matters more than the syntax: pick
right and most of your pipeline needs no process anywhere.
{: .lede }

[The workflow grammar](grammar-workflow.html) is the reference — every key, what
it compiles to, and who executes it. This page is the part a reference cannot
tell you, which is how to decide.

## Choosing a step kind

The single most useful habit is to reach for `work` last rather than first.

| If the work is | Write | Needs a process |
|---|---|---|
| a query, a projection, a rollup, a graph update | `sql` or `p8ql` | **no** |
| an outbound HTTP call | `rest` | the generic worker |
| turning text into a vector | `embed` | the generic worker |
| asking a model that has tools | `agent` | the Agent Runtime |
| genuinely your own code | `work` | your worker |

<details class="why" markdown="1">
<summary>Why it works — reaching for `work` is usually a sign the step should
have been `sql`</summary>

Indexing, projection, rollups and graph updates all feel like code because they
are code everywhere else. Here they are SQL — a statement on the step, or a
registered function where you want one — and they execute inside the transaction
that makes them ready, so a pipeline built out of them completes before
`start_workflow` returns to you.

The test is whether the work needs to leave the machine. If it does not, the
only thing `work` buys you is a process to deploy, a queue to watch, and a
worker that can be down.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#queries-that-need-no-process">what an
in-database step compiles to</a> ·
<a href="cookbook.html#6-a-workflow-with-nothing-running">a run that finishes
before the function returns</a></p>
</details>

## Write the query, not the plumbing

The two places the compiler does work on your behalf are worth knowing, because
both look like magic until you know why they exist.

What we are trying to do here is search a corpus by meaning without writing the
model call, and call a model without writing where its key lives.
{: .goal }

```yaml
  - id: retrieve
    p8ql: 'SEARCH "{{run.question}}" FROM chunks LIMIT 5'

  - id: judge
    needs: [retrieve]
    rest:
      url: '{{env.LLM_URL}}/v1/chat/completions'
      credential_ref: LLM_API_KEY
      body: {model: qwen2.5, prompt: 'Evidence: {{steps.retrieve.result}}'}
```

<details class="why" markdown="1">
<summary>Why it works — a url in a document outlives the deployment it was
written on</summary>

`SEARCH` compiles to two tasks, and the endpoint for the hidden embed step comes
from `aiq.embedding_models` rather than from your document. The model is written
into both halves so they cannot mean different spaces, and naming a different
one on each is refused while you are authoring rather than returning a
meaningless number at runtime.

`credential_ref` is a name the worker resolves from its own environment, so the
database stores the reference and never the secret. The endpoint may itself be
`{{env.LLM_URL}}/…`, which is what lets one registration serve dev, staging and
production without a per-deployment `UPDATE`.

Both are the same instinct: anything that differs between deployments belongs in
a row or an environment variable, and a document that outlives one deployment
should not carry either.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#a-vector-query-is-two-tasks">the desugaring in
full</a> ·
<a href="recipes.html#an-embedding-model-or-search-will-not-compile">registering
a model first</a></p>
</details>

## Three things get refused rather than ignored

All three exist to stop a document meaning something other than what it says,
which is the failure mode that costs the most to find.

<ol class="steps" markdown="1">
<li markdown="1">**An unknown key on a step** is a compile error listing the valid ones, so a typo like `ouput_schema` cannot pass for a feature.</li>
<li markdown="1">**`session`, `session_group` or `jsonpath` outside an `agent:` step**, which would otherwise be accepted and emit nothing.</li>
<li markdown="1">**A feature the installed compiler cannot emit**, even when the document compiles cleanly.</li>
</ol>

<details class="why" markdown="1">
<summary>Why it works — the third one is subtler than the other two and it is
the reason they exist</summary>

`output_schema` is not a step kind, so an older compiler drops the unknown key,
the document compiles, and the contract you declared is simply not there at
runtime. The run goes green either way, which makes a vanished contract harder
to debug than a missing feature — you are looking for a bug in your prompt
rather than in your build.

`define_yaml` refuses and tells you which of the two it hit. The compiled parser
and the SQL schema ship as separate artifacts on separate clocks, so this is not
a hypothetical: `select workflow.compiler_capabilities()` reports what the
installed build actually accepts and lists what is `missing`.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#getting-this-page-from-your-own-database">probing
the installed compiler</a> ·
<a href="install.html#checking-an-install-properly">checking an install
properly</a></p>
</details>

## Three validators, and why the third one had to exist

| Checked by | Rejects |
|---|---|
| `p8_compile_workflow` (Rust) | malformed YAML; a step with zero or two action keys; a `needs` naming a step that does not exist |
| `validate_spec` (on insert) | duplicate keys, unreachable steps, cycles with no entry point |
| `lint_spec` (authoring time) | a `p8ql` that is not a query, an unregistered `sql` function, an agent that does not exist, `{{steps.NOSUCHSTEP}}` |

<details class="why" markdown="1">
<summary>Why it works — the first two check the shape of the graph and nothing
about its contents</summary>

Every example in the third row was accepted by `define_yaml` at some point and
then failed at run time — or, in the case of an agent that does not exist, sat
queued forever, which is worse than failing because nothing reports it.

That is the general shape of the split. A compiler can tell you the document is
well formed and the graph is sound; only the database can tell you the function
you named is registered and the agent you named is a row. `lint_spec` runs
against the deployment you are about to define on.

<p class="related"><strong>Related</strong>
<a href="failure.html">what happens when a step fails anyway</a> ·
<a href="operating.html">finding a task that is not moving</a></p>
</details>

Next: [what a step leaves behind](outputs.html).
