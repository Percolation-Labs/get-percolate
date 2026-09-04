# Reading a plan before you run it

A workflow definition is a DAG of steps and nothing else. What a step *reaches*
— the agent it calls and that agent's tools, the corpus a query ranks and the
space it ranks in, the function, queue and rate key that decide whether the task
is ever claimed — is spread across four schemas. `workflow.plan_document()`
resolves all of it and hands back the pipeline, in order, with each entity
expanded where it is used.
{: .lede }

What we are trying to do here is read a workflow somebody else wrote, without
opening four catalogs.
{: .goal }

```sql
select workflow.plan_document('sec_revenue');
```

`sec_revenue` is the pipeline the output below came from — an agent, an MCP tool
server and a corpus, which is what makes it worth reading — and it is not
installed by anything here, so that exact call answers `no workflow definition
named sec_revenue` on your stack. Every function on this page takes any
definition name, so substitute one you have.

**`harbour_deficiencies`, from the sample the install guide loads, is the one to
use** — it has an agent and a corpus behind it, so all four functions have
something to say about it. `ingest_file` from [uploading files](ingest.html)
also resolves, but `plan_probe` finds nothing to report on it.

And **`plan_status` reports on runs, so it is empty until you start one.**
Measured on `harbour_deficiencies`: no rows before, four after a single
`start_workflow`. An empty result there is the absence of runs, not a workflow
that failed to resolve — which is the one reading of these four that looks like
a broken install and is not.

<div class="evidence" markdown="1">
<div class="label">one step of five</div>

```yaml
- id: summarise
  kind: agent
  about: asks agent sec_analyst (on openai:gpt-4o-mini)
  needs: [land, quarters]
  requires_env: [P8_AGENT_URL]
  input: 'Landed: {{steps.land.result}}. What happened to quarterly revenue?'
  calls:
    agent: sec_analyst
    model: openai:gpt-4o-mini
    system_prompt: |
      You read US SEC XBRL facts and answer in one paragraph, quoting figures
      exactly as filed... Report the concept and the filing form alongside any
      number you quote, because a 10-Q restated in a 10-K is not the same fact.
    output_shape: {required: [headline, latest_value, confidence]}
    servers: [{server: p8-query, kind: mcp, url: 'http://query-mcp:8090', synced_at: null}]
    tools:   [{tool: p8-query/query}]
  defects:
    - {severity: warning, code: unsynced_server,
       message: "tool server 'p8-query' has never been synced"}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the agent's prompt is the agent's intent, so the plan
carries it</summary>

An agent is a row, and a plan that named the row and stopped would have expanded
nothing. So the whole system prompt is inline, along with the shape the agent
must return, the servers it binds and the tools it is narrowed to on each — and
one hop further, the agents it may delegate to, because that is also what it can
do.

The same applies to data. A query step carries the corpus's table, its columns
and types, and the models it is *actually* embedded in — not the ones that are
registered, which is a different question and the one that hides a broken
pipeline.

**Curation is the point.** Constraints, indexes, RLS policies and full JSON
Schemas are deliberately absent. An expansion that reproduces everything a
workflow touches is a document nobody reads twice, which fails the same way as
not expanding at all. The rule for what stays: *if two steps of the same kind
would differ in it, it describes the pipeline.*

<p class="related"><strong>Related</strong>
<a href="agents.html">an agent, its tools and who it may delegate to</a> ·
<a href="grammar-workflow.html">every key the compiler accepts</a></p>
</details>

## The same resolution, as a graph

What we are trying to do here is get the nodes and edges, for a viewer or a diff.
{: .goal }

```sql
select workflow.plan_graph('sec_revenue');
```

<div class="evidence" markdown="1">
<div class="label">stats, and two of fifteen nodes</div>

```yaml
stats: {nodes: 15, edges: 21, steps: 5, errors: 0, warnings: 3}
nodes:
- {id: 'source:chunks', kind: source, lane: data,
   detail: {table: content.resource_chunks, embedded_in: [{model: demo-quad-a, dim: 4}]}}
- {id: 'step:retrieve', kind: step, lane: step, rank: 1, step_key: retrieve}
edges:
- {from: 'step:retrieve', to: 'source:chunks', kind: reads}
- {from: 'source:chunks', to: 'model:demo-quad-a', kind: ranked_in}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the document is a projection of the graph, not a second
resolver</summary>

Both come out of one resolution. Two views that resolved separately would be two
answers to the only question that matters, and the second one would be wrong
first.

Node ids are stable (`kind:name`), so the same agent named by three steps is one
node with three edges into it, and a diff between two versions of a definition is
a set difference. Steps carry `rank` — longest path from a root — and every node
carries a `lane`, which is what a layout needs. Steps also carry `step_key`, and
`workflow.tasks` is keyed `(run_id, step_key)`, so colouring a plan with a live
run is a join rather than a second system.

The catalog it is built from is an *argument*, not a fetch: `plan_catalog()`
assembles what this deployment has, through ordinary views, and hands it in. So
the plan you get is built from exactly the rows you could see.

<p class="related"><strong>Related</strong>
<a href="operating.html">the audits that fail loudly</a></p>
</details>

## What it checks

What we are trying to do here is find every definition in the deployment that
names something which is not there.
{: .goal }

```sql
select workflow as wf, severity, code, node from workflow.plan_defects() order by 1, 2;
```

<div class="evidence" markdown="1">
<div class="label">against a freshly seeded stack</div>

```
     wf      | severity |        code        |     node
-------------+----------+--------------------+---------------
 ask_uploads | error    | space_model_split  | source:chunks
 ask_uploads | warning  | unconfigured_queue | queue:http
 ingest_file | warning  | unconfigured_queue | queue:ingest
```
</div>

The errors, in the order they will cost you something:

| code | what it means |
|---|---|
| `space_model_split` | a query ranks a corpus in a space that corpus has no vectors in — returns rows, not an error |
| `unknown_rate_key` | the throttle has no row, so `claim_task` skips the task **forever**, silently |
| `unknown_agent` | the runtime 404s every call; the step burns its retries on a name that was never going to resolve |
| `unknown_source` · `unknown_model` | the query returns zero rows, or has nowhere to rank |
| `unregistered_server` | the agent runs with a smaller toolset than its definition claims, and answers anyway |
| `unknown_relation` | a statement names a table nobody can see — a warning, because the extraction is a heuristic over SQL |
| `unsynced_server` · `unconfigured_queue` · `no_space` | warnings: something works, on a default nobody chose |

<details class="why" markdown="1">
<summary>Why it works — the check that earns its place is the one nothing else
makes</summary>

`space_model_split` is the reason this exists. A corpus is embedded per model,
one space table each, and a query that ranks a corpus in a space it was never
embedded into is not an error anywhere: cosine distance between two spaces is a
number, just a meaningless one. The compiler closes this for
`p8ql: 'SEARCH …'`, which pins one model into both halves; it cannot close the
hand-written pair, where the embed step and the query are two steps somebody
wired together. This is that path, seen before it runs.

`unknown_rate_key` is the quietest. `try_consume_rate_limit` updates no row and
returns false, every time, so the task sits `ready` and no worker ever claims
it — no attempt, no error, no dead task. An unthrottled step would have run; a
step naming a throttle that does not exist never runs at all.

<p class="related"><strong>Related</strong>
<a href="failure.html">what retries and what is terminal</a> ·
<a href="query.html">where a corpus and its spaces come from</a></p>
</details>

## Probing: run the cheap half

What we are trying to do here is find out whether a pipeline works, without
paying for it.
{: .goal }

```sql
select * from workflow.plan_probe('sec_revenue');
```

<div class="evidence" markdown="1">
<div class="label">nothing here executes a step</div>

```
   step   |   probe   | verdict |                     detail
----------+-----------+---------+-------------------------------------------------
 quarters | parses    | ok      | the planner accepted it
 quarters | relations | ok      | reads sec_facts
 quarters | returns   | ok      | {"fp": "text", "fy": "integer", "val": "numeric"}
 typo     | parses    | fail    | relation "sec_factz" does not exist
 land     | arity     | fail    | 'record_chunks' is registered with 2 argument(s)
                                  and this step passes 1
 ask      | env       | skipped | needs P8_AGENT_URL from the worker's environment
 ask      | agent     | ok      | agent 'percolate' exists
```
</div>

<details class="why" markdown="1">
<summary>Why it works — EXPLAIN plans and discards, and CREATE VIEW validates
without running</summary>

Probing a five-step pipeline costs no outbound request, no model call and no
row. `EXPLAIN` without `ANALYZE` gives you the parse and the relations the
*planner* names — not a guess from reading the string. A temp view gives the
result's column names and types, because a view is validated and planned at
creation and executes nothing.

`arity` is the one that saves an afternoon: at dispatch, a step passing one
argument to a two-argument function fails with `function f(text) does not
exist`, which reads as a missing function rather than a miscounted argument
list.

**`skipped` is never `ok`.** The worker's environment, an outbound URL, whether
a credential resolves — all of those belong to a process the database
deliberately cannot see. A probe that passed them would be worse than one that
says it cannot tell.

Templates become `null` before probing, since `{{run.cik}}` is not SQL. That is
enough for parsing, relations and column types, and honestly less than a run.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#sql-steps-run-sql">what a statement step may
carry</a> ·
<a href="failure.html">what happens when one fails for real</a></p>
</details>

## The last run, beside the plan

What we are trying to do here is find out what shape a step actually returns, so
the next step can be written against it.
{: .goal }

```sql
select * from workflow.plan_status('sec_revenue');
```

<div class="evidence" markdown="1">
<div class="label">shapes, not values</div>

```
   step   | status | attempts |                      returned
----------+--------+----------+----------------------------------------------------
 quarters | done   |        1 | {"of": {"fp": "string", "fy": "number"}, "rows": 2}
 tally    | done   |        1 | {"of": {"n": "number", "peak": "number"}, "rows": 1}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the join was already there</summary>

A step's declared output is `jsonb`. Somebody writing
`{{steps.quarters.result}}` into an agent's prompt has no way to know what keys
it has, and no plan can tell them — one execution can. `workflow.tasks` is keyed
`(run_id, step_key)` and every step node carries `step_key`, so this is a join
rather than a second system.

Keys and their types, or a row count. The values are one `select` away and would
make this unreadable for a fan-out that returned four thousand rows.

It is `SECURITY INVOKER`, unlike everything else on this page: `workflow.tasks`
is RLS-enabled and per-tenant, so you see the runs your policies admit.

<p class="related"><strong>Related</strong>
<a href="operating.html">what to watch while a run is in flight</a></p>
</details>

## What it cannot do

This is pre-flight, not verification, and the difference matters enough to state
plainly.

**It cannot tell you the plan is wrong.** It checks that names resolve. A
pipeline that fetches the right document, lands every row and answers the
question it was asked can still be answering the wrong question — one built
against the SEC's XBRL API reported a company's quarterly revenue as three times
its real figure, because the concept carries year-to-date facts under the same
name and the landing step ignored the period start. Zero errors, all the way
through.

**It cannot see the worker's environment.** `requires_env` lists what a step
needs, and cannot check it: the environment belongs to the worker, deliberately,
because that is where credentials live. The commonest failure of an otherwise
sound plan is an agent step on a deployment with no Agent Runtime configured,
and the plan can name the variable while knowing nothing about whether it is set.

**Its warnings are not all news.** Every queue warning fires on a fresh install,
because nothing ships `queue_config` rows. A report whose warnings are all
present on a clean deployment teaches people to skip it, so read the errors first
and treat the warnings as a list of defaults nobody chose.

<details class="why" markdown="1">
<summary>Why it works — the two gaps above are now two functions, and the third
is still open</summary>

Two of the three complaints on this page have answers: *what shape does this
return* is `plan_status`, and *does any of it actually work* is `plan_probe`.

The one that remains is the first, and it does not have a mechanical fix: a
plan cannot tell you the pipeline is asking the wrong question. Probing proves
a statement parses and names real tables; it cannot know that the concept you
selected carries year-to-date facts under the same name as quarterly ones.
Reading the numbers is still the job.

<p class="related"><strong>Related</strong>
<a href="operating.html">what to watch while it runs</a></p>
</details>
