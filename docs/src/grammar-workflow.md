# The workflow grammar

A workflow is a YAML document with a name and a list of steps, and each step
carries exactly one action. This page is the whole vocabulary at version @@extension@@ —
every key the compiler accepts, what each one compiles to, and who executes the
result.
{: .lede }

The thing to hold onto while reading it is that none of this is a second
execution engine. Every document here compiles to ordinary `workflow.tasks`
rows, so retry, backoff, the reaper, saga compensation, cancellation and tracing
all apply to a YAML workflow exactly as they apply to a hand-built one.

## The document

```yaml
name: <required, the workflow's name>
version: <optional int, default 1>
steps:
  - id: <required, unique within the document>
    needs: [<step ids this one waits for -- an AND-join>]
    queue: <which worker pool claims it; in-database kinds ignore it>
    rate_key: <a shared throttle consumed before the task can be claimed>
    compensate_with: <step id to run in reverse if a saga member fails>
    saga_group: <groups tasks compensated together>
    <exactly one action, from the table below>
```

Unknown keys are refused by name rather than ignored, which is `deny_unknown_fields`
doing its job and is why a typo in a step key is a compile error rather than a
silently missing feature.

## The nine actions

Each step carries exactly one. The compiler rejects zero or two, and says which
step.

| YAML | compiles to | who executes it |
|---|---|---|
| `p8ql: '<query>'` | `kind: sql` | **nobody** — runs inside Postgres |
| `sql: '<statement>'` | `kind: sql` | **nobody** — the SQL you wrote, read-only |
| `sql: {statement, write: true}` | `kind: sql` | **nobody** — SQL that changes the database |
| `sql: {function, args}` | `kind: sql` | **nobody** — a registered function |
| `rest: {url, …}` | `kind: http_call` | the worker's built-in handler |
| `embed: <text>` | `kind: http_call` | the worker, at a URL from the registry |
| `agent: <name>` | `kind: http_call` | the Agent Runtime |
| `work: true` | `kind: work` | **you** — the only case needing your code |
| `matrix: {…}` | `kind: matrix` | **nobody** — expansion is a transaction |
| `signal: true` | `kind: signal` | **a person**, via `signal_task` |
| `timer: <seconds>` | `kind: timer` | **nobody** — a clock |
| `workflow: <name>` | `kind: sub_workflow` | **nobody** — the child expands in-transaction |

The last three are *control* steps. They wait rather than act, which is why
declaring one alongside an action is refused.

## Queries that need no process

What we are trying to do here is run a graph walk and a lexical search as
workflow steps, with nothing deployed anywhere.
{: .goal }

```yaml
name: fleet_brief
steps:
  - id: operator
    p8ql: 'LOOKUP "MERI"'
  - id: fleet
    needs: [operator]
    p8ql: 'GRAPH "MERI" DEPTH 1'
  - id: reports
    needs: [operator]
    p8ql: 'TEXT "PSC-441" FROM chunks LIMIT 3'
```

<div class="evidence" markdown="1">
<div class="label">workflow.tasks after start_workflow returns</div>

```
 step_key | kind | status |   worker    | rows_out
----------+------+--------+-------------+----------
 fleet    | sql  | done   | in-database |        4
 operator | sql  | done   | in-database |        1
 reports  | sql  | done   | in-database |        2
```
</div>

<details class="why" markdown="1">
<summary>Why it works — an in-database step executes in the transaction that
makes it ready</summary>

A `sql` or `p8ql` step becomes ready the moment its dependencies resolve, and
`autorun_sql_steps` executes it inside that same transaction. There is no queue
to poll and no process to deploy, which is why the run above has already
finished by the time `start_workflow` returns to you.

The rows land on the task, so the graph walk the middle step did is readable
straight out of `workflow.tasks.output` rather than having to be recomputed.

One thing to know lives here, and it is the seventh P8QL mode. A `p8ql:` step
holding *plain SQL* executes, and inside a step the invoker is the **engine
owner** — which owns every table and is not subject to their row-level
security. So such a step reads across tenants. It is a deliberate beta trade and
`percolate.sql_policy = 'registered'` refuses it from @@extension_min@@ onward;
[the cookbook](cookbook.html#6-a-workflow-with-nothing-running) has the whole of
it.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#plain-sql-is-a-mode">why plain SQL behaves that
way</a> ·
<a href="first-workflow.html">a four-step pipeline end to end</a></p>
</details>

## `sql` steps run SQL

What we are trying to do here is ask the database a question, in a workflow,
without ceremony.
{: .goal }

```yaml
  - id: quarters
    needs: [land]
    sql: "select fy, fp, val from sec.facts where cik = {{run.cik}} order by fy desc"
```

<div class="evidence" markdown="1">
<div class="label">the step's result</div>

```json
[{"fy": 2026, "fp": "Q3", "val": 109420000000},
 {"fy": 2026, "fp": "Q2", "val": 111180000000}]
```
</div>

A statement is read-only. One that changes the database says so, and is refused
if it does not:

```yaml
  - id: purge
    sql:
      statement: "delete from staging where run_id = {{run.$id}}"
      write: true
```

And a registered function stays available, which is what the engine's own steps
use:

```yaml
  - id: reindex
    sql: {function: rebuild_graph_index, args: [company]}
```

<details class="why" markdown="1">
<summary>Why it works — two guards, and only one of them is the boundary</summary>

A read is wrapped as `select … from (<your statement>) t` and runs with
`transaction_read_only` on. The wrap is structural: Postgres refuses a
data-modifying `WITH` anywhere but the top level, so `with gone as (delete …)`
fails on its shape rather than on a keyword list. The read-only transaction
catches everything else, including a volatile function that writes, which no
wrapping sees. The keyword check beside them is a courtesy that turns an abort
into a sentence naming `write: true`.

Every `{{template}}` becomes a **bound parameter**. The statement is rewritten
so each reference reads `$1->>'<ref>'` and the values are bound alongside it, so
a run input of `'; drop table x; --` is a string — not because it was escaped,
but because it never reaches the parser. Quotes you write yourself are consumed
rather than doubled, so `cik = '{{run.cik}}'` and `cik = {{run.cik}}` mean the
same thing.

This covers `{{item.*}}` inside a `matrix:` template as well, which matters
because those values are rows rather than something the author typed. A JSON
number binds as `::numeric` and a boolean as `::boolean`, so `where n =
{{run.n}}` still works against an integer column; a text value compared against
a non-text column needs your own cast, because `->>` is text where a quoted
literal used to be coerced by context.

The one thing you cannot template is an identifier — `from {{run.table}}`
becomes `from ($1->>'run.table')` and fails with `syntax error at or near "$1"`.
That is the parameterisation working, not a gap: values can be bound and names
cannot, which is where every database driver draws the same line.

**What it costs.** A statement runs as the engine owner, which owns every table
and bypasses row-level security, so anyone who may define a workflow may read
anything in the database. That is a deliberate trade: the alternative made every
question a privileged human had to bless. A deployment that wants the old
boundary sets one thing —

```sql
alter database <db> set percolate.sql_policy = 'registered';
```

— and statements are refused at authoring time and, from @@extension_min@@, at dispatch too, with registered
functions still running.

<p class="related"><strong>Related</strong>
<a href="recipes.html#registering-a-function-and-when-it-is-worth-it">registering a
function, and when it is worth it</a> ·
<a href="outputs.html">what a `sql` step should return</a></p>
</details>

## Registering a function, and what it still buys

What we are trying to do here is bless an operation the deployment wants
reviewed, and give it a description a model can read.
{: .goal }

<!-- run: sql -->
```sql
select workflow.register_step_function(
    'rebuild_graph_index', 'aiq.rebuild_entity_type', array['text'],
    p_description => 'reproject one entity type into the node registry');
```

<details class="why" markdown="1">
<summary>Why it works — a timeout, a description, and an inventory</summary>

The registry stopped being a gate and kept the jobs it was always better at. A
registered function carries its own `timeout_ms`, and its description is the
same text a bound tool takes into a model's context — so `workflow.step_functions`
is the answer to *what can a workflow cause to run* for the operations you chose
to bless. Under `sql_policy = 'registered'` it is also the whole surface.

Registration checks one thing that is easy to get wrong and expensive to
discover late. `execute_sql_step` is `SECURITY DEFINER`, so your function runs
as *its* owner rather than as you — and if that role cannot reach your schema,
registration refuses with the grant that fixes it rather than succeeding and
failing at every run:

<div class="evidence" markdown="1">
<div class="label">register_step_function</div>

```
ERROR:  function harbour.land_notices(jsonb) is not reachable by app_owner,
        which is the role that will execute it (execute_sql_step is SECURITY
        DEFINER). Registration would succeed and every invocation would fail
        with "permission denied for schema harbour". Run:
        grant usage on schema harbour to app_owner;
```
</div>

<p class="related"><strong>Related</strong>
<a href="#sql-steps-run-sql">the spelling that needs no registration</a> ·
<a href="outputs.html">what a `sql` step should return</a></p>
</details>

## `rest` steps, and where the credential lives

What we are trying to do here is call an external API and keep the key out of
the database.
{: .goal }

```yaml
  - id: notify
    queue: http
    rest:
      url: '{{env.OPS_WEBHOOK}}/incidents'
      method: POST
      credential_ref: OPS_TOKEN
      timeout_ms: 30000
      mode: async
      jsonpath: data.id
      body: {summary: '{{steps.brief.result}}'}
```

<details class="why" markdown="1">
<summary>Why it works — the whole `rest:` mapping becomes the task input, so
these are keys and not a schema</summary>

The compiler copies the mapping under `rest:` into `workflow.tasks.input`
verbatim, which is why `url`, `method`, `body`, `headers`, `timeout_ms`,
`jsonpath`, `mode` and `credential_ref` are all available without the grammar
enumerating them: the worker's handler is what reads them, and the compiler does
not need an opinion.

`credential_ref` is a **name**, resolved by the worker from its own environment.
A dump of `workflow.tasks` therefore never contains a secret and a task stays
inspectable and replayable. `{{env.X}}` works the same way and is resolved
**only by the worker** — a `sql:` or `p8ql:` step cannot read it, deliberately,
because the database has no business knowing the deployment's environment.

`mode: async` returns immediately and lets the callee call `complete_task` when
it finishes. That is the seam a long-running call uses, and it is what an
`agent:` step compiles to.

<p class="related"><strong>Related</strong>
<a href="failure.html">which HTTP failures retry</a> ·
<a href="recipes.html#keys-are-names-never-values">every place a credential is
named rather than stored</a></p>
</details>

## A vector query is two tasks

What we are trying to do here is search a corpus by meaning from one authored
step, without writing the model call.
{: .goal }

```yaml
  - id: retrieve
    p8ql: 'SEARCH "{{run.question}}" FROM chunks LIMIT 5'
```

<details class="why" markdown="1">
<summary>Why it works — the compiler writes the embed step, and pins the model
into both halves</summary>

`SEARCH` and `SEMANTIC` rank against a vector, and the database makes no model
calls. So the compiler expands that one step into an `http_call` keyed
`retrieve__embed` plus the `sql` step keyed `retrieve` that consumes it. Your id
stays on the search, so `needs: [retrieve]` and `{{steps.retrieve.result}}` mean
what they look like and nothing downstream is rewired — the embed is a hidden
*predecessor*, not a replacement.

You never write the URL. It comes from `aiq.embedding_models`, and `USING <model>`
is written into the query if it was not there and refused if it disagrees with
the embed step's model. A vector from one space ranked against another is not an
error at runtime, only a meaningless number, so it is made a compile error
instead.

`queue:` on the step routes the **embed** half; the search half runs in-database
and is claimed by nobody. The hand-written pair — `embed:` then
`sql: {function: p8ql_vec, …}` — is still legal and compiles to exactly the same
rows.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#the-three-search-modes-and-why-there-are-three">the
three search modes</a> ·
<a href="recipes.html">a retrieval pipeline with an agent on the end</a></p>
</details>

## `agent` steps, sessions and declared shapes

What we are trying to do here is have a model answer with a shape we can put in
a column, and have two agents share one conversation.
{: .goal }

```yaml
  - id: triage
    agent: classifier
    input: 'Classify: {{steps.retrieve.result}}'
    session_group: analysis
    output_schema:
      type: object
      required: [verdict, confidence]
      properties:
        verdict:    {type: string, enum: [SAFETY, FINANCE, OTHER]}
        confidence: {type: number}

  - id: deep_dive
    needs: [triage]
    agent: researcher
    input: '{{steps.triage.result}}'
    session_group: analysis        # …so these two share one conversation
    jsonpath: ''                   # capture the envelope, not just the text
```

<details class="why" markdown="1">
<summary>Why it works — an agent step is a REST step whose URL and auth the
compiler fills in</summary>

It compiles to `POST {{env.P8_AGENT_URL}}/internal/run` with `mode: async` and
`credential_ref: P8_API_KEY`. The runtime answers `202` immediately and calls
`complete_task` when the agent finishes, so a twenty-minute agent holds no
connection. Nested delegation happens inside the runtime rather than being
unrolled into the workflow graph, which is why a researcher calling an analyst
is one task here and a delegation tree there.

`session_group` asks the **engine** for a session id, stable for the life of the
run and bound to `{{run.$session}}`. Steps naming the same group share a
conversation, two groups are two threads, and declaring neither stays stateless
— the right default for a classifier.

`output_schema` is what makes the answer composable: the engine parses the
model's JSON-in-a-string reply and checks it *before* storing, so the next step
receives an object rather than prose. A shape violation is **the one retryable
failure in this engine** — every other terminal classification exists because
retrying cannot help, and here the same prompt genuinely can conform next time.

It is a shape check and not JSON Schema. Types including `integer`, `required`,
`properties`, `enum`, `items` and `additionalProperties: false` are supported;
`$ref`, `allOf`/`anyOf`/`oneOf`, `pattern`, `format` and numeric bounds are not,
and are named here rather than silently ignored. Declaring `output_schema` on a
`sql` or `matrix` step is refused, because the check is for output this engine
did not produce.

<p class="related"><strong>Related</strong>
<a href="agents.html">what an agent row holds</a> ·
<a href="failure.html">why a shape violation retries</a> ·
<a href="recipes.html">an extractor fanned out over a backlog</a></p>
</details>

## `matrix` — the work to do is a query result

What we are trying to do here is turn one authored step into N tasks, with
nothing outside the database deciding how many.
{: .goal }

```yaml
  - id: extract
    matrix:
      rows: "select id, content from reports where extracted_at is null"
      max_fanout: 500
      continue_on: failed
      min_success: 0.9
      template:
        rate_key: openai-completions
        agent: psc_report_extractor
        input: '{{item.content}}'

  - id: land
    needs: [extract]
    sql: {function: land_extractions, args: ['{{steps.extract.result.task_id}}']}
```

<details class="why" markdown="1">
<summary>Why it works — the children are inserted by the statement that completes
the parent</summary>

There is no window in which `extract` is `done` and the children do not exist
yet. A controller-based fan-out has that window, and a controller that dies
inside it strands the fan-out with nothing to resume from.

`max_fanout` is mandatory and the compiler says why rather than defaulting: a
cross join with a forgotten `WHERE` expands to the cartesian product, and that
should fail one step rather than the database. `rows:` takes the query itself
or a registered function, exactly as `sql:` does — with one difference: a row
source is always read-only, because it is re-run by every retry of the
expansion.

`continue_on: failed` lets a failed child satisfy its dependents, and
`min_success` is the floor below which the aggregate is cancelled rather than
run on partial data — a fraction if it is ≤ 1, an absolute count if it is > 1.
Declaring `min_success` without `continue_on` is refused by name, because the
first failed child would cancel the successors and the threshold could never be
reached. It is a **transport** floor: a 200 carrying an empty body counts as a
success against it.

The fan-in reads a **handle**, not a payload. `{{steps.extract.result.task_id}}`
is the matrix task and `workflow.matrix_outputs(task_id)` pairs every child with
its row, status and output. Five hundred extractions are for aggregating inside
your own function, not for passing through a step argument that caps at 64KB.

One sharp edge worth knowing before you rely on it: a matrix *template* cannot
declare `output_schema`. The compiler accepts `queue`, `rate_key`, `rest`,
`embed`, `agent`, `work`, `input`, `session` and `jsonpath` inside a template and
not that, so a fan-out child lands the model's answer as a JSON string and your
fan-in parses it.

<p class="related"><strong>Related</strong>
<a href="failure.html#fan-out-and-partial-failure">partial failure in
depth</a> ·
<a href="outputs.html">why the fan-in reads handles</a> ·
<a href="recipes.html">the backlog recipe this comes from</a></p>
</details>

## Control steps — waiting for a clock, a person, or a child

What we are trying to do here is hold a run open until a harbourmaster signs
off, with a cooling-off period first and no process doing the waiting.
{: .goal }

```yaml
  - id: cooling_off
    needs: [notice]
    timer: 3600
  - id: approve
    needs: [cooling_off]
    signal: true
  - id: issue
    needs: [approve]
    workflow: issue_notice        # a child workflow, expanded in-transaction
```

```sql
select workflow.signal_task(:run_id, 'approve',
    '{"decision":"released","by":"harbourmaster"}'::jsonb);
```

<details class="why" markdown="1">
<summary>Why it works — waiting is a row state, so nothing holds a process open
to do it</summary>

A `timer` moves when `workflow.promote_due_timers()` runs on the `pg_cron`
minute that already ticks the engine. A `signal` step then sits in
`waiting_external`, which is the status meaning a person is the dependency, and
only `signal_task` moves it.

`signal_task` checks who you are, and a run with no owner is not owned by
everyone: it takes an explicit permission against the run's owner, set from the
verified JWT of whoever started it. That is also why a scheduled run carries its
schedule's owner — otherwise a scheduled workflow that waits for approval could
never be approved, by anybody.

All three of these were legal *engine* kinds that no document could reach until
somebody tried to write exactly this workflow and the compiler refused it. And
`sub_workflow` had never executed at all: `start_child_workflow` inserted a run
row without expanding the child's task graph, so composition was advertised,
unreachable, and broken underneath.

<p class="related"><strong>Related</strong>
<a href="install.html#pg_cron-if-you-want-schedules">why `pg_cron` is not
optional for timers</a> ·
<a href="recipes.html">a pipeline that waits for a person</a></p>
</details>

## Templates, and the one rule that bites

Four namespaces, all resolved at **dispatch** rather than at definition time.

| Template | Reads |
|---|---|
| `{{run.<key>}}` | what `start_workflow` was called with |
| `{{run.$id}}`, `{{run.$trace_id}}`, `{{run.$session}}` | the run's own identity — `$` is reserved so an input key cannot shadow it |
| `{{steps.<id>.result}}` | a completed step's output, dotted paths supported |
| `{{item.<key>}}` | one matrix row, bound only on fan-out children |
| `{{env.<VAR>}}` | the worker's environment. Never available to a `sql` step |

<details class="why" markdown="1">
<summary>Why it works — a whole-string reference keeps its type, an embedded one
becomes text</summary>

This is the rule to internalise, because getting it backwards does not raise.

`args: ['{{steps.embed.result}}']` is a **whole-string** reference, so it
resolves to the vector as an array rather than to a string that looks like one.
`url: 'https://x/?since={{steps.cursor.result.since}}'` is **embedded**, so it
interpolates as text and the URL works.

The failure was in this collection's own headline example. A step passing
`'SEARCH "{{run.question}}" FROM chunks LIMIT 3'` is not a whole-string
reference, so the substitution happened nowhere, the lexical half searched for
the literal text `{{run.question}}`, every lexical rank came back null, and the
fusion quietly degraded to semantic-only. It returned rows. It looked like it
worked.

Typing `{{run.id}}` when you meant `{{run.$id}}` raises with the spelling you
wanted, rather than resolving to nothing and failing three tasks later.

<p class="related"><strong>Related</strong>
<a href="first-workflow.html">the run seeing itself</a> ·
<a href="outputs.html">why every step nests under `result`</a></p>
</details>

## Getting this page from your own database

What we are trying to do here is read the vocabulary out of the installed
compiler rather than out of a document.
{: .goal }

<!-- run: sql -->
```sql
select p8_workflow_grammar();               -- the document, step keys, actions
select workflow.compiler_capabilities();    -- and whether this build is current
select aiq.query('SCHEMA "workflow"');      -- plus what THIS deployment allows
```

<details class="why" markdown="1">
<summary>Why it works — the vocabulary is fixed, but what a deployment accepts
is rows</summary>

The step kinds are the engine's and they are in the parser. The functions a
`sql:` step may call, the queues a step may route to and the agents an `agent:`
step may name are all rows on the database in front of you, so no document can
be authoritative about them.

`SCHEMA "workflow"` returns both halves and runs its own examples through the
compiler on every read, so a spelling this deployment no longer accepts reports
itself rather than being served as correct. `compiler_capabilities()` probes the
installed build with one canary per feature and lists what is `missing`, which
is how version skew between the Rust parser and the SQL schema shows up as a
capability report rather than as a syntax error in a document that is not wrong.

<div class="evidence" markdown="1">
<div class="label">workflow.compiler_capabilities()</div>

```
 {"accepts": {"matrix": true, "output_schema": true, "continue_on": true,
              "signal": true, "timer": true, "sub_workflow": true},
  "missing": []}
```
</div>

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#getting-this-page-from-your-own-database">the same
mechanism for the query dialect</a></p>
</details>

Next: [authoring in YAML](authoring.html) walks the same vocabulary as prose,
and [workflow recipes](recipes.html) puts it to work.
