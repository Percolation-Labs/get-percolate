# The workflow grammar

A workflow is a YAML document with a name and a list of steps, and each step
carries exactly one action. This page is the whole vocabulary at version
@@extension@@ —
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
    when: <a SQL predicate; false or null skips the step>
    <exactly one action, from the table below>
  - id: <a group of steps tried again until a check passes>
    needs: [...]
    repeat: {max: <1 to 20>, until: <a SQL predicate>, steps: [<steps, as above>]}
```

Unknown keys are refused by name rather than ignored, which is
`deny_unknown_fields`
doing its job and is why a typo in a step key is a compile error rather than a
missing feature that reports nothing.

`when:` and `repeat:` are [below](#when-a-step-that-runs-only-if). They are
newer than the rest of this page: an installed compiler that lists both under
`accepts` in [`compiler_capabilities()`](#getting-this-page-from-your-own-database)
has them.

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

Here we run a graph walk and a lexical search as workflow steps, with nothing
deployed anywhere.
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
 step_key | kind |  status   |   worker    | rows_out
----------+------+-----------+-------------+----------
 fleet    | sql  | succeeded | in-database |        4
 operator | sql  | succeeded | in-database |        1
 reports  | sql  | succeeded | in-database |        2
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

One thing to know lives here, and it is the ninth P8QL mode. A `p8ql:` step
holding *plain SQL* executes, and inside a step the invoker is the **engine
owner** — which owns every table and is not subject to their row-level
security. So such a step reads across tenants. It is a beta trade and
`percolate.sql_policy = 'registered'` refuses it from @@extension_min@@ onward;
[the cookbook](cookbook.html#6-a-workflow-with-nothing-running) has the whole of
it.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#plain-sql-is-a-mode">why plain SQL behaves that
way</a> ·
<a href="first-workflow.html">a four-step pipeline end to end</a></p>
</details>

## `sql` steps run SQL

Here we ask the database a question, in a workflow, without ceremony.
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
a non-text column needs your own cast, because `->>` yields text and text is not
coerced to the column's type for you.

The one thing you cannot template is an identifier — `from {{run.table}}`
becomes `from ($1->>'run.table')` and fails with `syntax error at or near "$1"`.
That is the parameterisation working, not a gap: values can be bound and names
cannot, which is where every database driver draws the same line.

**What it costs.** A statement runs as the engine owner, which owns every table
and bypasses row-level security, and so does every `p8ql:` step, dialect modes
included. Anyone who may define a workflow may read anything in the database.
That is the trade: the alternative made every question a privileged human had to
bless.

In @@extension@@ it also reaches whoever *starts* the run, and anyone signed in
may start any workflow: a member who runs a retrieval workflow an admin wrote
reads every org's documents through it. The next extension release refuses such
a step when the person who started the run may not define workflows. The
[cookbook](cookbook.html#6-a-workflow-with-nothing-running) says what to do
until then.

A deployment can also refuse the SQL an author writes —

```sql
alter database <db> set percolate.sql_policy = 'registered';
```

— and statements are refused at authoring time and, from @@extension_min@@, at
dispatch too, with registered functions still running. That narrows what an
author may write. It does not stop a `p8ql:` SEARCH reading as the owner,
because `p8ql` is itself a registered function.

<p class="related"><strong>Related</strong>
<a href="recipes.html#registering-a-function-and-when-it-is-worth-it">registering a
function, and when it is worth it</a> ·
<a href="outputs.html">what a `sql` step should return</a></p>
</details>

## Registering a function, and what it still buys

Here we bless an operation the deployment wants reviewed, and give it a
description a model can read.
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
same text a bound tool takes into a model's context — so
`workflow.step_functions`
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

The check is on the **table**, not on this function, and the difference is the
one that makes the inventory worth trusting. A plain `insert into
workflow.step_functions` is refused by the same rule with the same message, so
there is no door into the registry that skips it — including one you reach by
reading the table before this page. Registering is owner-only either way; what
the trigger adds is that an owner cannot do it by accident.

<p class="related"><strong>Related</strong>
<a href="#sql-steps-run-sql">the spelling that needs no registration</a> ·
<a href="outputs.html">what a `sql` step should return</a></p>
</details>

## `rest` steps, and where the credential lives

Here we call an external API and keep the key out of the database.
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
      wait_ms: 600000
      jsonpath: data.id
      body: {summary: '{{steps.brief.result}}'}
```

<details class="why" markdown="1">
<summary>Why it works — the whole `rest:` mapping becomes the task input, so
these are keys and not a schema</summary>

The compiler copies the mapping under `rest:` into `workflow.tasks.input`
verbatim, which is why `url`, `method`, `body`, `headers`, `timeout_ms`,
`jsonpath`, `mode`, `wait_ms` and `credential_ref` are all available without the grammar
enumerating them: the worker's handler is what reads them, and the compiler does
not need an opinion.

`credential_ref` is a **name**, resolved by the worker from its own environment.
A dump of `workflow.tasks` therefore never contains a secret and a task stays
inspectable and replayable. `{{env.X}}` works the same way and is resolved
**only by the worker** — a `sql:` or `p8ql:` step cannot read it,
because the database has no business knowing the deployment's environment.

`mode: async` sends the request and then **holds the task** until the callee
calls `complete_task` or `fail_task`. While it holds, the worker heartbeats the
lease and writes nothing; when the callee finishes, the worker lets go. `wait_ms`
bounds the hold, and is 15 minutes when omitted. Past it the worker fails the
task **terminally**, because a retry would send a second request to a callee
that may still be working. A `wait_ms` that is not a positive whole number of
milliseconds is refused before anything is sent.

**The hold occupies the worker.** `percolate worker` runs one task at a time,
so a worker holding an async step claims nothing else until the callee answers
or `wait_ms` passes. Run as many `http` workers as you expect async steps in
flight at once, plus the ones your synchronous steps need.

That is the seam a scheduled agent run uses: its step posts to `/internal/run`,
and the runtime completes the task when the turn ends, or fails it with a
verdict when the turn does. An `agent:` step does not use it; it is the
synchronous call [below](#agent-steps-sessions-and-declared-shapes).

<p class="related"><strong>Related</strong>
<a href="failure.html">which HTTP failures retry</a> ·
<a href="failure.html#crash-recovery">the heartbeat and lease fence the hold
relies on</a> ·
<a href="recipes.html#keys-are-names-never-values">every place a credential is
named rather than stored</a></p>
</details>

## A vector query is two tasks

Here we search a corpus by meaning from one authored step, without writing the
model call.
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

You never write the URL. It comes from `aiq.embedding_models`, and `USING
<model>`
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

Here we have a model answer with a shape we can put in a column, and have two
agents share one conversation.
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

It compiles to `POST {{env.P8_AGENT_URL}}/v1/chat/completions` on the `http`
queue with `credential_ref: P8_API_KEY`, and reads the answer from
`choices.0.message.content` — the call is synchronous, so the worker holds the
connection for the length of the turn. The worker needs `P8_AGENT_URL`, which
the compose file and chart set, and no token: it signs one for the run's owner
([why](agents.html#naming-one-from-a-workflow)). Nested delegation
happens inside the runtime rather than being
unrolled into the workflow graph, which is why a researcher calling an analyst
is one task here and a delegation tree there.

`session_group` asks the **engine** for a session id, stable for the life of the
run and bound to `{{run.$session}}`. Steps naming the same group share a
conversation, two groups are two threads, and declaring neither stays stateless
— the right default for a classifier. The step sends the id as `session_id`,
which is the key the Agent Runtime reads, and the engine creates the
`agentic.sessions` row for it, owned by whoever started the run, the first time
a step needs it, so the runtime has a conversation to continue rather than an
id it answers 404 to.

`output_schema` is what makes the answer composable: the engine parses the
model's JSON-in-a-string reply and checks it *before* storing, so the next step
receives an object rather than prose. A shape violation is **the one retryable
failure in this engine** — every other terminal classification exists because
retrying cannot help, and here the same prompt genuinely can conform next time.

It is a shape check and not JSON Schema. Types including `integer`, `required`,
`properties`, `enum`, `items` and `additionalProperties: false` are supported;
`$ref`, `allOf`/`anyOf`/`oneOf`, `pattern`, `format` and numeric bounds are not,
and are named here rather than ignored without a word. Declaring `output_schema`
on a
`sql` or `matrix` step is refused, because the check is for output this engine
did not produce.

<p class="related"><strong>Related</strong>
<a href="agents.html">what an agent row holds</a> ·
<a href="failure.html">why a shape violation retries</a> ·
<a href="recipes.html">an extractor fanned out over a backlog</a></p>
</details>

## `matrix` — the work to do is a query result

Here we turn one authored step into N tasks, with nothing outside the database
deciding how many.
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

There is no window in which `extract` is `succeeded` and the children do not
exist
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

One sharp edge to check before you rely on it: a matrix *template* cannot
declare `output_schema`. The compiler accepts `queue`, `rate_key`, `rest`,
`embed`, `agent`, `work`, `input`, `session` and `jsonpath` inside a template
and
not that, so a fan-out child lands the model's answer as a JSON string and your
fan-in parses it.

<p class="related"><strong>Related</strong>
<a href="failure.html#fan-out-and-partial-failure">partial failure in
depth</a> ·
<a href="outputs.html">why the fan-in reads handles</a> ·
<a href="recipes.html">the backlog recipe this comes from</a></p>
</details>

## Control steps — waiting for a clock, a person, or a child

Here we hold a run open until a harbourmaster signs off, with a cooling-off
period first and no process doing the waiting.
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
select workflow.signal_task(
    (select run_id from workflow.tasks
      where step_key = 'approve' and status = 'waiting_external'
      order by created_at desc limit 1),
    'approve', '{"decision":"released","by":"harbourmaster"}'::jsonb);
```

The subquery finds the newest run waiting on `approve`. From `psql` it needs the
identity claim that [your first workflow](first-workflow.html#watching-a-run)
sets, because `signal_task` checks who is signing and refuses a session that
carries nobody. It returns how many waiting steps it resolved: `1` here, and `0`
for a signal sent before the step is `waiting_external`, a second answer, or a
misspelled name, none of which changes anything. Send a signal once `waiting`
says the step needs you, and read the count.

<details class="why" markdown="1">
<summary>Why it works — waiting is a row state, so nothing holds a process open
to do it</summary>

A `timer` moves when `workflow.promote_due_timers()` runs on the `pg_cron`
minute that already ticks the engine. A `signal` step then sits in
`waiting_external`, which is the status meaning a person is the dependency, and
only `signal_task` moves it. Both ask whether the run is finished once they
have moved a step, as `complete_task` does, so a run whose last step is a
signal or a timer ends `succeeded` when that step does.

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

## `when:` — a step that runs only if

A step can carry a condition over the run's input and earlier results. When it
does not hold, the step is skipped and the run carries on.

Here we send a claim to review only when its score is over 0.5, and pay it
either way.
{: .goal }

<!-- run: sql -->
```sql
select workflow.define_yaml($y$
name: claim_gate
steps:
  - id: score
    sql: "select {{run.score}} as v"
  - id: review
    needs: [score]
    when: "{{steps.score.result.0.v}} > 0.5"
    sql: "select 'reviewed' as r"
  - id: pay
    needs: [review]
    sql: "select 'paid' as p"
$y$);

select workflow.start_workflow('claim_gate', '{"score": 0.2}'),
       workflow.start_workflow('claim_gate', '{"score": 0.9}');

select r.input->>'score' as score, t.step_key, t.status, r.status as run
  from workflow.runs r
  join workflow.definitions d on d.id = r.workflow_def_id
  join workflow.tasks t on t.run_id = r.id
 where d.name = 'claim_gate'
 order by score, t.id;
```

<div class="evidence" markdown="1">
<div class="label">the two runs</div>

```
 score | step_key |  status   |    run
-------+----------+-----------+-----------
 0.2   | score    | succeeded | succeeded
 0.2   | review   | skipped   | succeeded
 0.2   | pay      | succeeded | succeeded
 0.9   | score    | succeeded | succeeded
 0.9   | review   | succeeded | succeeded
 0.9   | pay      | succeeded | succeeded
```
</div>

<details class="why" markdown="1">
<summary>Why it works — skipped is a terminal success, so nothing after it
waits or is cancelled</summary>

The engine asks the predicate once, when the step's needs are done and it would
otherwise become ready. True runs the step. False or null marks it `skipped`,
which `workflow.lifecycle_states` records as terminal and a success, so the
steps after it are released as they would be after a success, and a run of
successes and skips has succeeded. A skipped step is never claimed, a skipped
`signal` never waits for anybody, and a skipped step is never compensated,
because it did nothing.

Each `{{template}}` in a predicate is a bound value, as in a `sql:` statement,
and a step it names must be in `needs`; the definition is refused otherwise. A
skipped step's result is null, so a template naming it binds `NULL` and a
comparison with it is null, which skips too. `when: "{{steps.review.result.0.r}}
is null"` is therefore how a step asks whether `review` was skipped. A gate is
a `when:` on every step it guards: `pay` above runs after a skipped `review`
because it has no condition of its own.

The predicate runs through `workflow.run_sql`, as a `sql:` step does: read-only,
under `percolate.sql_policy`, and as the run's owner, so row policies apply to
whatever it reads. One that cannot be evaluated fails its step and the run,
with `when: <the error>` as the step's error
([failure](failure.html#a-step-that-did-not-need-to-run)).

<p class="related"><strong>Related</strong>
<a href="failure.html#a-step-that-did-not-need-to-run">skipped, failed and
cancelled</a> ·
<a href="#sql-steps-run-sql">how a template binds in SQL</a></p>
</details>

## `repeat:` — try again until a check passes

A group of steps can run again until a check over its own results holds, up to
a number of attempts stated in the document.

Here we count up one attempt at a time until the count reaches the run's
target, at most four times. Each attempt reads the one before it, and the check
holds at the second.
{: .goal }

<!-- run: sql -->
```sql
select workflow.define_yaml($y$
name: count_to
steps:
  - id: loop
    repeat:
      max: 4
      until: "{{steps.count.result.0.n}} >= {{run.target}}"
      steps:
        - id: count
          sql: "select coalesce({{previous.count.result.0.n}}, 0) + 1 as n"
$y$);

select workflow.start_workflow('count_to', '{"target": 2}');

select t.step_key, t.status, t.output->'result'->0 as result
  from workflow.runs r
  join workflow.definitions d on d.id = r.workflow_def_id
  join workflow.tasks t on t.run_id = r.id
 where d.name = 'count_to'
 order by t.id;
```

<div class="evidence" markdown="1">
<div class="label">one run of count_to</div>

```
 step_key |  status   |                                        result
----------+-----------+--------------------------------------------------------------------------------------
 count_1  | succeeded | {"n": 1}
 count_2  | succeeded | {"n": 2}
 count_3  | skipped   |
 count_4  | skipped   |
 loop     | succeeded | {"last": {"count": [{"n": 2}]}, "attempts": 2, "satisfied": true, "max_attempts": 4}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the compiler writes the attempts out, so a repeat is
still a DAG</summary>

Attempt n of `count` is the ordinary step `count_<n>`. The first steps of an
attempt wait for the last steps of the attempt before, and every step of an
attempt after the first carries `when: not (<until over the attempt before>)`.
Once the check holds, the next attempt is skipped, and because a skipped step's
result is null, so is every attempt after it. Each attempt is a task row a
trace can read, and the bound is the number of rows written: `max` is required,
from 1 to 20, and a repeat without it is refused.

Inside the group, `{{steps.<inner>}}` is this attempt's step and
`{{previous.<inner>}}` the attempt before. On the first attempt there is none:
in SQL (`sql:`, `p8ql:`, `when:`) the template is `NULL`, quotes around it
included, which is why `coalesce` starts the count at 0; anywhere else, such as
an agent's input, it is removed. `until` must name at least one of the
attempt's steps, and an inner step's own `when:` still applies alongside it.

The repeat's id is a final step that waits for every attempt. The steps after
the repeat read it rather than the attempts:

| Template | Value |
|---|---|
| `{{steps.loop.result.0.attempts}}` | how many attempts ran |
| `{{steps.loop.result.0.satisfied}}` | whether `until` held after the last of them |
| `{{steps.loop.result.0.last.<inner>}}` | the last attempt's result for that step |

An attempt can be any steps, agents included: a writer and a critic, with
`until` over the critic's grade and the writer's input reading
`{{previous.<critic>.result}}`, is the same document with two inner steps.

`satisfied` false with `attempts` equal to `max` is a repeat that ran out, and a
step after it can say what to do then with a `when:` of its own. Repeats do not
nest, the group takes only `id`, `needs` and `repeat`, and an attempt's name
must not collide with another step's id.

<p class="related"><strong>Related</strong>
<a href="#when-a-step-that-runs-only-if">the condition each attempt
carries</a> ·
<a href="#templates-and-the-one-rule-that-bites">every template
namespace</a></p>
</details>

## Templates, and the one rule that bites

Four namespaces, all resolved at **dispatch** rather than at definition time.

| Template | Reads |
|---|---|
| `{{run.<key>}}` | what `start_workflow` was called with |
| `{{run.$id}}`, `{{run.$trace_id}}`, `{{run.$session}}` | the run's own identity — `$` is reserved so an input key cannot shadow it |
| `{{steps.<id>.result}}` | a completed step's output, dotted paths supported |
| `{{item.<key>}}` | one matrix row, bound only on fan-out children |
| `{{previous.<id>.result}}` | inside a `repeat:`, the attempt before's step; `NULL` in SQL on the first attempt |
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
fusion degraded to semantic-only, reporting nothing. It returned rows. It looked
like it
worked.

Typing `{{run.id}}` when you meant `{{run.$id}}` raises with the spelling you
wanted, rather than resolving to nothing and failing three tasks later.

<p class="related"><strong>Related</strong>
<a href="first-workflow.html">the run seeing itself</a> ·
<a href="outputs.html">why every step nests under `result`</a></p>
</details>

## Getting this page from your own database

Here we read the vocabulary out of the installed compiler rather than out of a
document.
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
              "signal": true, "timer": true, "sub_workflow": true,
              "when": true, "repeat": true},
  "missing": []}
```
</div>

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#getting-this-page-from-your-own-database">the same
mechanism for the query dialect</a></p>
</details>

Next: [ten things, worked through](cookbook.html), which puts this vocabulary
to work one capability at a time; [workflow recipes](recipes.html) after it
assembles it into whole pipelines.
