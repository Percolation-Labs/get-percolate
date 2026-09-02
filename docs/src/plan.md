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
<summary>Why it works — the next thing this wants is a run, not another check</summary>

Nothing static can tell you that a step returned a well-formed result meaning
nothing. One execution can. The plan carries `step_key` on every step and
`workflow.tasks` is keyed on `(run_id, step_key)`, so joining the last run's
status and output shape onto the document is a join:

```sql
select n->>'id', t.status
  from jsonb_array_elements(workflow.plan_graph('sec_revenue')->'nodes') n
  left join workflow.tasks t
    on t.run_id = :run and t.step_key = n->>'step_key';
```

That overlay is not built into `plan_graph` on purpose: a `p_run_id` argument
would put a runtime concern inside the one function whose whole value is that it
is pure and reads only configuration.

<p class="related"><strong>Related</strong>
<a href="operating.html">what to watch while it runs</a></p>
</details>
