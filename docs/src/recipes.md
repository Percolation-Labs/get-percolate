# Workflow recipes

Seven pipelines you would actually deploy, each one written the same way: what
we are trying to do, the document that does it, and the mechanism folded away
underneath for when you want it.
{: .lede }

Everything here assumes you have read [the workflow grammar](grammar-workflow.html),
which is where the vocabulary lives. These pages divide the work deliberately:
the grammar page answers *what does `matrix` accept*, and this one answers *what
do I write to poll a source into a corpus an agent can be asked about*.

Two of the seven lean on something incomplete — the channel poller, and an Agent
Runtime that ships but has no compose service — and each is named in the recipe
that needs it rather than in a list at the bottom. Every function, column and key
below is checked against the installed schema; what has not been run end to end
is the seven pipelines as wholes.

## Before any of this runs

There are six things to set up before a recipe will work, and all of them are
one-time. Most produce a clear error in your hand if you skip them; the fourth
produces no error at all, which is why it gets more space than the others.

### Keys are names, never values

Nothing in this database holds a secret. A row that needs credentials holds the
**name of an environment variable**, and the process making the call resolves it.

What we are trying to do here is point a step at a credential without putting
the credential anywhere near the database.
{: .goal }

```yaml
  - id: notify
    rest:
      url: '{{env.OPS_WEBHOOK}}/incidents'
      method: POST
      credential_ref: OPS_TOKEN
```

| Where | Column or key | Resolved by |
|---|---|---|
| `aiq.embedding_models` | `credential_ref` | the worker, when it embeds |
| `agentic.tool_servers` | `credential_ref` | the Agent Runtime, calling a tool |
| a `rest:` step | `credential_ref:` inside the mapping | the worker |
| an `agent:` step | `P8_API_KEY`, written in by the compiler | the worker |

<details class="why" markdown="1">
<summary>Why it works — a secret in a row is a secret in every backup, and one
place refuses it outright</summary>

Keeping the reference rather than the value means `pg_dump` never contains a
key, a task stays replayable, and rotating a credential is a deployment change
rather than an `UPDATE` across your task history.

`{{env.X}}` is resolved **only by the worker**, and a `sql:` or `p8ql:` step
cannot read it. That is deliberate rather than an omission — the database has no
business knowing the deployment's environment, and the template resolver refuses
the namespace by name rather than resolving it to null.

One place enforces this instead of documenting it.
`agentic.tool_servers.default_headers` is checked by the table, because a key in
a header is the same key in a row that `credential_ref` exists to keep out, and
it would arrive by an entirely reasonable-looking registration:

<div class="evidence" markdown="1">
<div class="label">insert into agentic.tool_servers</div>

```
ERROR:  new row for relation "tool_servers" violates check constraint
        "tool_servers_headers_not_secrets"
```
</div>

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#rest-steps-and-where-the-credential-lives">the
`rest:` keys in full</a> ·
<a href="operating.html">what a worker needs in its environment</a></p>
</details>

### An embedding model, or `SEARCH` will not compile

What we are trying to do here is register a model so that vector queries have a
URL to be compiled against.
{: .goal }

<!-- run: sql -->
```sql
insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, is_default)
values ('text-embedding-3-small', 1536, 'openai',
        'https://api.openai.com/v1/embeddings', 'LLM_API_KEY', true)
on conflict (name) do nothing;   -- the harbour sample registers this same model

select aiq.register_embedding_space('text-embedding-3-small');
```

<details class="why" markdown="1">
<summary>Why it works — the storage table is generated from the registry, so the
dimension cannot drift</summary>

`register_embedding_space` creates the vector table and its HNSW index **from
the registry row**, which is what stops the stored dimension and the distance
operator from drifting away from what the model actually returns.

`provider` is not a label. It joins to `aiq.embedding_providers`, which holds the
request body's shape and the path to the vector in the response; `ollama` and
`openai` ship as rows, and a gateway that differs from either overrides the row
rather than forking anything.

`is_default` is enforced by a partial unique index rather than by a trigger, so
a deploy that would leave two defaults fails loudly instead of leaving a coin
flip about which space `SEMANTIC` searched.

With nothing registered there is no URL for the compiler to fill in, so a
document containing `SEARCH` or `SEMANTIC` is refused at `define_yaml` time
rather than failing on every run.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#a-vector-query-is-two-tasks">how the embed step
gets written for you</a> ·
<a href="query.html">the three search modes</a></p>
</details>

### Registering a function, and when it is worth it

What we are trying to do here is bless one operation the deployment wants
reviewed — while ordinary queries stay ordinary queries.
{: .goal }

```sql
select workflow.register_step_function(
    'land_notices', 'harbour.land_notices', array['jsonb'],
    p_description => 'register fetched notices and chunk their text');
```

<details class="why" markdown="1">
<summary>Why it works — registration refuses the grant problem instead of
deferring it</summary>

A step can carry its own SQL, so this is no longer the only door — it is the
one worth using for the operations you want reviewed, because a registered
function carries its own timeout and a description a model reads before calling
it. That is why the recipes below that *land* data have a small function behind
them, while the ones that only ask questions do not.

`execute_sql_step` is `SECURITY DEFINER`, so your function runs as *its* owner
and not as you. If that role cannot reach your schema, registration refuses with
the grant that fixes it — rather than succeeding and failing at every single
run, which is the version of this that costs an afternoon to diagnose.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#registering-a-function-and-what-it-still-buys">the exact
error, and the `sql:` key</a></p>
</details>

### A throttle has to exist before a step names it

This is the one to read twice, because skipping it produces no error anywhere.
`rate_key:` on a step is a **reference** to a row in `workflow.rate_limits`, not
a declaration of one, and `claim_task` consumes from that bucket with
`update … where key = $1` — which matches nothing when the bucket does not
exist, and therefore returns false every time, forever.

What we are trying to do here is create the bucket a throttled step will name,
before anything names it.
{: .goal }

<!-- run: sql -->
```sql
insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
values ('openai-completions', 20, 20, 1)
on conflict (key) do nothing;
```

<details class="why" markdown="1">
<summary>Why it works — and what the failure looks like, which is nothing at
all</summary>

Twenty tokens refilling at one a second. The task whose `rate_key` names a
missing bucket sits in `ready`, no worker ever claims it, no attempt is
recorded, nothing retries, and the worker beside it reports an empty queue. It
was measured on this collection's own embed fan-out: six children in `ready`, no
error, no dead task, no signal of any kind.

Give completions and embeddings **separate keys**. They hit different provider
limits, and sharing one bucket throttles the cheap call behind the expensive
one. `content.install_ingest_workflow` creates `structure_extraction` for you
when you ask it for a graph index, for exactly this reason.

<p class="related"><strong>Related</strong>
<a href="operating.html">watching for tasks that are not moving</a> ·
<a href="grammar-workflow.html">where `rate_key` sits on a step</a></p>
</details>

### Agents and tool servers are rows

What we are trying to do here is register an agent and the tool server it calls,
neither of which is code and neither of which is deployed.
{: .goal }

<!-- run: sql -->
```sql
select agentic.upsert_tool_server($j${
  "name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090",
  "emits_citations": true,
  "cached_tools": [{"name": "query"}, {"name": "schema"}]
}$j$::jsonb);

select agentic.upsert_agent($j${
  "name": "harbourmaster",
  "model": "anthropic:claude-sonnet-5",
  "audience": "user",
  "category": "tool_user",
  "system_prompt": "You answer questions about the fleet. Start with SCHEMA.",
  "tools": [{"server": "harbour-query", "tools": ["query"]}]
}$j$::jsonb);
```

<details class="why" markdown="1">
<summary>Why it works — an omitted key means leave it alone, which is not the
obvious implementation</summary>

Both upserts follow that rule for every column, and it is worth stating because
the obvious version gets it wrong in a way that returns success.
`{"name": "harbourmaster", "model": "…"}` is how anybody changes a model, and a
naive `set x = excluded.x` takes the column *default* for every key you did not
send — leaving the agent existing, resolving by name, and able to do nothing.

Two constraints shape how you register the machine ones. `category: extractor`
requires `structured_output_schema`, because a declared shape is what makes N
extractions combinable and what makes a bad answer retryable rather than
silently wrong. And `audience` is an access decision rather than a tag:
`agentic.agents` is sized for thousands of rows, one specialist per (source,
doctype), and a picker showing a person a thousand extractors is broken.

<p class="related"><strong>Related</strong>
<a href="agents.html">what else an agent row holds</a> ·
<a href="grammar-workflow.html#agent-steps-sessions-and-declared-shapes">the
`agent:` step</a></p>
</details>

### Ask this deployment what it accepts

What we are trying to do here is find out what this installation supports,
before debugging a document that will not compile.
{: .goal }

<!-- run: sql -->
```sql
select workflow.compiler_capabilities();
select aiq.query('SCHEMA "workflow"');
```

Both are covered in [the workflow grammar](grammar-workflow.html#getting-this-page-from-your-own-database),
which is where the reasoning lives.

---

## 1. Bring a source in

Every deployment starts here, and this is the recipe furthest from finished. A
**channel** is where content comes from: `file_upload` covers a person dragging
a PDF in, and `http_pull` covers a source you go and get.

What we are trying to do here is poll an external feed on the hour and turn what
comes back into resources the rest of the system can answer questions about.
{: .goal }

<!-- run: sql -->
```sql
insert into content.channels (name, kind, config, poll_interval)
values ('harbour-notices', 'http_pull',
        '{"url": "https://example.org/notices.json"}'::jsonb,
        interval '1 hour');
```

```yaml
name: harbour_notices_poll
steps:
  - id: cursor
    sql: {function: notices_cursor}

  - id: fetch
    needs: [cursor]
    rest:
      url: 'https://example.org/notices.json?since={{steps.cursor.result.since}}'
      method: GET
      jsonpath: items

  - id: land
    needs: [fetch]
    sql: {function: land_notices, args: ['{{steps.fetch.result}}']}
```

```sql
select workflow.schedule_workflow(
    p_name     => 'harbour-notices-hourly',
    p_workflow => 'harbour_notices_poll',
    p_cron     => '17 * * * *',
    p_overlap  => 'skip');

select cron.schedule('workflow-tick', '* * * * *', $$select workflow.tick()$$);
```

<details class="why" markdown="1">
<summary>Why it works — `external_id` is the idempotency key, and it is the whole
design of a poller</summary>

The landing function is the small piece of SQL this recipe costs you, and the
important line in it is that `content.register_fetched` returns **null** rather
than raising when the id has already been seen:

<!-- run: sql -->
```sql
create function harbour.land_notices(p_items jsonb) returns jsonb as $$
declare it jsonb; v_res uuid; v_new int := 0;
begin
    for it in select * from jsonb_array_elements(p_items) loop
        v_res := content.register_fetched(
            p_channel     => 'harbour-notices',
            p_external_id => it->>'id',
            p_title       => it->>'title',
            p_uri         => it->>'url',
            p_metadata    => it);
        continue when v_res is null;      -- seen on an earlier poll, not an error

        perform content.record_chunks(v_res, jsonb_build_array(jsonb_build_object(
            'ordinal', 0, 'content', it->>'body',
            'start_offset', 0, 'end_offset', length(it->>'body'))));
        v_new := v_new + 1;
    end loop;
    update content.channels set last_polled_at = now() where name = 'harbour-notices';
    return jsonb_build_object('registered', v_new);
end $$ language plpgsql;
```

A source that hands you the same fifty items every hour therefore costs fifty
no-ops, which makes overlapping windows free — and that in turn means you can
poll a source with no reliable cursor at all. A puller that treated the repeat
as an error would re-process its whole backlog every cycle.

**A resource does not need bytes.** `record_chunks` makes the text answerable
with nothing in object storage, because a scraped JSON record has no file and
`resources.file_id` is nullable to say so. Uploaded documents take the other
path, which is recipe 2.

Two things about the schedule are easier to know than to discover. The fire is
idempotent through the engine's own machinery rather than a second mechanism —
the external id is the schedule name and the minute, so a retried transaction
returns the existing run. And a schedule's `input` is a **constant**, with no
templating in it, which is exactly why the cursor above is a step reading the
database rather than a value on the schedule.

`overlap => 'skip'` is what stops a poll that runs long from stacking up behind
itself, and one `pg_cron` job covers every schedule you have, because a schedule
is a row.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#templates-and-the-one-rule-that-bites">why the
URL interpolates and the argument does not</a> ·
<a href="ingest.html">what happens to a resource after this</a> ·
<a href="install.html#pg_cron-if-you-want-schedules">setting up `pg_cron`</a></p>
</details>

> **What is missing.** `channels.poll_interval` is read by nothing, so the
> channel row above is documentation until the poller exists. Everything else in
> this recipe is built, and `workflow.schedules` with `overlap_policy` is the
> half of the pull-source design that shipped.

## 2. Make what lands answerable

What we are trying to do here is install the pipeline that turns any arriving
resource into chunks, vectors and graph nodes, in one call.
{: .goal }

<!-- run: sql -->
```sql
select aiq.install_structure_null('gpt-4o-mini');
select content.install_ingest_workflow(
           p_model       => 'text-embedding-3-small',
           p_graph_index => true,
           p_graph_model => 'gpt-4o-mini');

update content.channels
   set config = config || '{"ingest_workflow": "ingest_file"}'::jsonb
 where name = 'harbour-notices';
```

<div class="evidence" markdown="1">
<div class="label">install_ingest_workflow returns</div>

```
ingest_file: parse, embed with text-embedding-3-small in batches,
             graph-index each window with structure_null (gpt-4o-mini)
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the two indexes are siblings, so their failures are
independent</summary>

The return value is the point: it says what it installed rather than leaving you
to infer it from a bill. Ask for a model that is registered but unreachable and
it raises; let it pick the default and find the default uncallable, and it
degrades to parse-only and tells you so, carrying the compiler's own message
rather than a summary of it.

The shape it writes is the best worked example of composition in the collection:

```yaml
  - id: parse
    work: true                     # your ingest worker: bytes -> chunks
  - id: embed
    needs: [parse]                 # one batched call, not one per chunk
    work: true
  - id: graph
    needs: [parse]                 # a SIBLING of embed, not a successor
    matrix:
      rows: {function: windows_to_index, args: ['{{run.resource_id}}']}
      max_fanout: 200
      template: {queue: http, rate_key: structure_extraction, rest: …}
  - id: land_graph
    needs: [graph]
    sql: {function: land_graph_windows, args: ['{{steps.graph.result.task_id}}']}
```

Because `embed` and `graph` both depend on `parse` rather than on each other, a
deployment with no embedding model can still index a graph and a failed
extraction does not cost you the vectors. A chunkless resource — a CSV, which
becomes a Parquet dataset rather than prose — skips the graph branch for free,
because an empty row set releases the successor where a document-level step
would have had to raise.

The embed step is `work` rather than a matrix of `embed:` children because of the
payload cap: one 1536-dimension vector is about 31KB of JSON and a step's output
caps at 64KB, so two vectors do not fit in one task output. Any design carrying
corpus vectors through the engine is limited to batches of one.

<p class="related"><strong>Related</strong>
<a href="ingest.html">every format, and the captured run</a> ·
<a href="outputs.html">why an oversized output becomes an artifact</a> ·
<a href="grammar-workflow.html#matrix-the-work-to-do-is-a-query-result">the
matrix keys</a></p>
</details>

## 3. Answer a question from your own corpus

What we are trying to do here is retrieve from the corpus, have an agent answer
from what was retrieved, and land the answer in a table as a shape rather than
as prose.
{: .goal }

```yaml
name: notice_brief
steps:
  - id: retrieve
    p8ql: 'SEARCH "{{run.question}}" FROM chunks LIMIT 8'

  - id: answer
    needs: [retrieve]
    agent: harbourmaster
    input: |
      Question: {{run.question}}
      Evidence: {{steps.retrieve.result}}
    output_schema:
      type: object
      required: [answer, confidence, sufficient]
      properties:
        answer:     {type: string}
        confidence: {type: number}
        sufficient: {type: boolean}

  - id: record
    needs: [answer]
    sql: {function: record_brief, args: ['{{run.$id}}', '{{steps.answer.result}}']}
```

<details class="why" markdown="1">
<summary>Why it works — three authored steps become four tasks, and the fourth
is one you did not write</summary>

`SEARCH` desugars into a hidden **predecessor**: an `http_call` keyed
`retrieve__embed` that turns the question into a vector, plus the in-database
search step that consumes it. Your id stays on the search, so `needs: [retrieve]`
and `{{steps.retrieve.result}}` mean what they look like and nothing downstream
is rewired.

`output_schema` is what makes this composable. Without it, `answer` is prose and
`record_brief` has to parse it defensively; with it, the engine validates before
storing and the function receives an object. It is also the reason this pipeline
survives a bad model day: a shape violation is the one retryable failure in the
engine, so `max_attempts` becomes a real budget for asking again.

`{{run.$id}}` rather than `{{run.id}}` because the `$` prefix is reserved for
engine fields, so an input key of your own cannot shadow one.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#a-vector-query-is-two-tasks">the desugaring</a> ·
<a href="grammar-workflow.html#agent-steps-sessions-and-declared-shapes">what
`output_schema` checks and what it does not</a> ·
<a href="failure.html">why a shape violation retries</a></p>
</details>

## 4. One specialist per document type, over a backlog

This is the population the agentic subsystem is sized for. The agents a person
talks to are a rounding error; turning prose into structured data is
`sources × doctypes` specialists, each with a declared output shape.

What we are trying to do here is push a backlog of reports through a specialist
extractor and land the results, tolerating the ones that fail.
{: .goal }

<!-- run: sql -->
```sql
select agentic.upsert_agent($j${
  "name": "psc_report_extractor",
  "category": "extractor",
  "audience": "system",
  "model": "openai:gpt-4o-mini",
  "extracts_source": "harbour-notices",
  "extracts_doctype": "psc_report",
  "system_prompt": "Extract the deficiency record. Answer only with the schema.",
  "structured_output_schema": {
    "type": "object",
    "required": ["vessel", "code", "detained"],
    "properties": {
      "vessel":   {"type": "string"},
      "code":     {"type": "string"},
      "detained": {"type": "boolean"}}}
}$j$::jsonb);
```

```yaml
name: extract_psc_backlog
steps:
  - id: extract
    matrix:
      rows: {function: unextracted_psc_reports, args: ['{{run.batch}}']}
      max_fanout: 500
      continue_on: failed
      min_success: 0.9
      template:
        rate_key: openai-completions
        agent: psc_report_extractor
        input: '{{item.content}}'

  - id: land
    needs: [extract]
    sql: {function: land_psc_extractions, args: ['{{steps.extract.result.task_id}}']}
```

<details class="why" markdown="1">
<summary>Why it works — and the one edge that lands squarely in this recipe</summary>

A unique index enforces one specialist per (source, doctype), so a second
registration is a conflict to resolve rather than a coin flip at runtime. The
`structured_output_schema` on the row is not optional for `category: extractor`,
because an extractor without a declared shape is a model call with extra steps.

The part to plan for is that **a matrix template cannot declare `output_schema`**.
The compiler accepts `queue`, `rate_key`, `rest`, `embed`, `agent`, `work`,
`input`, `session` and `jsonpath` inside a template and not that — and
`output_schema` is the field that parses a model's JSON-in-a-string answer into
an object before it is stored. So a fan-out child lands a jsonb *string* where
recipe 3's single step would have landed an object, and `land_psc_extractions`
has to parse it.

That is not hypothetical: it is why `content.land_graph_windows` exists beside
`aiq.land_graph_fanout` rather than instead of it. Budget one `jsonb` parse in
every matrix fan-in over an agent until the parser closes it.

`min_success: 0.9` is a **transport** floor — a 200 carrying an empty body counts
as a success against it. The engine cannot know what a good extraction looks
like, so the threshold answers *did enough calls come back* and the agent's
declared shape answers the rest.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#matrix-the-work-to-do-is-a-query-result">every
matrix key</a> ·
<a href="agents.html#extractors-the-population-this-is-sized-for">why there are
thousands of these</a> ·
<a href="failure.html#fan-out-and-partial-failure">choosing a floor</a></p>
</details>

## 5. Two agents, one conversation

A classification and a follow-up should usually be two independent calls. When
the second agent needs what the first was *told* rather than only what it
answered, declare a session group.

What we are trying to do here is have three agents share one thread, and capture
the runtime's envelope from the last of them rather than only its text.
{: .goal }

```yaml
  - id: triage
    agent: classifier
    input: 'Classify: {{steps.retrieve.result}}'
    session_group: analysis

  - id: deep_dive
    needs: [triage]
    agent: researcher
    input: '{{steps.triage.result}}'
    session_group: analysis

  - id: audit
    needs: [deep_dive]
    agent: auditor
    input: 'Check {{steps.deep_dive.result}} against the notices it cites.'
    jsonpath: ''
```

<details class="why" markdown="1">
<summary>Why it works — the engine mints the session, so the run can originate a
conversation</summary>

`session_group` asks the engine for a session id that is stable for the life of
the run and bound to `{{run.$session}}`. Before this existed a workflow could
not *originate* a session at all: `session:` only resolved if the caller had put
an id in the run input, and the natural key derives from the run, which the run
could not see.

`jsonpath: ''` captures the whole response rather than the assistant text. The
default of `choices.0.message.content` is what almost every step wants, and
overriding it is how you keep the envelope — a session id the runtime issued,
token counts, tool traces — which is otherwise discarded before reaching
`runs.context`.

Citations come out of this for free and without asking the model for them.
`messages.citations` is built mechanically from the `tool_response` rows between
the previous assistant message and this one, for every server flagged
`emits_citations`. Models drop citations, invent ones that do not match what was
retrieved, and cite generically, so the list is built from what the context
actually held rather than from what the model says it used.

<p class="related"><strong>Related</strong>
<a href="agents.html">sessions, delegation and citations</a> ·
<a href="grammar-workflow.html#agent-steps-sessions-and-declared-shapes">the
`agent:` keys</a></p>
</details>

> **What is missing.** The Agent Runtime ships in the image and its schema is
> installed, but it has no compose service and no seeded agents, and it is the
> least-exercised corner of the collection. Treat the streaming and delegation
> behaviour as specified and reviewed rather than measured.

## 6. A pipeline that waits for a person

What we are trying to do here is have a model draft a notice, hold it for an
hour, and issue it only once a harbourmaster has signed off.
{: .goal }

```yaml
  - id: propose
    agent: harbourmaster
    input: 'Draft a detention notice for {{run.vessel}}'
    output_schema:
      type: object
      required: [notice, severity]
      properties:
        notice:   {type: string}
        severity: {type: string, enum: [advisory, detention]}

  - id: cooling_off
    needs: [propose]
    timer: 3600

  - id: approve
    needs: [cooling_off]
    signal: true

  - id: issue
    needs: [approve]
    sql: {function: issue_notice, args: ['{{steps.approve.result}}']}
```

```sql
select workflow.signal_task(:run_id, 'approve',
    '{"decision":"released","by":"harbourmaster"}'::jsonb);
```

<details class="why" markdown="1">
<summary>Why it works — a run with no owner is not owned by everyone</summary>

`signal_task` takes an explicit permission against the run's owner, which is set
from the verified JWT of whoever started it. That is also why a scheduled run
carries its schedule's owner rather than being unowned: without it, a scheduled
workflow that waits for approval could never be approved, by anybody.

Neither the wait nor the clock needs a process. A timer moves when
`promote_due_timers()` runs on the `pg_cron` minute that already ticks the
engine, and a signal step then sits in `waiting_external`, which is the status
meaning a person is the dependency.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#control-steps-waiting-for-a-clock-a-person-or-a-child">the
control steps</a> ·
<a href="operating.html">watching a run that is waiting on somebody</a></p>
</details>

## 7. Undo what already happened

An agent that only answers needs no compensation. A `rest:` step that booked
something does.

What we are trying to do here is give back a berth and a pilot, in the reverse
of the order they were taken, when the tide window is missed.
{: .goal }

```yaml
  - id: reserve_berth
    rest: {url: '{{env.PORT_API}}/berths', method: POST}
    compensate_with: release_berth
    saga_group: booking

  - id: book_pilot
    needs: [reserve_berth]
    rest: {url: '{{env.PORT_API}}/pilots', method: POST}
    compensate_with: cancel_pilot
    saga_group: booking

  - id: confirm_tide
    needs: [book_pilot]
    rest: {url: '{{env.TIDE_API}}/window', method: GET}
```

```sql
select workflow.begin_compensation(:run_id, 'booking');
```

<div class="evidence" markdown="1">
<div class="label">workflow.runs after compensation</div>

```
 status | compensation_state
--------+--------------------
 failed | compensated
```
</div>

<details class="why" markdown="1">
<summary>Why it works — two columns, because there are two questions</summary>

Compensations are not tasks until they are needed: before anything fails there
are three rows and the two undo steps are not among them. `begin_compensation`
creates them and runs them in the reverse of the order the originals succeeded
in, and because they are ordinary tasks they inherit retries, backoff and the
audit trail.

A saga that rolled back cleanly still did not do what it was asked, which is why
`status` and `compensation_state` are separate. A run reporting `succeeded`
because its cleanup worked is a run nobody investigates.

Which failures retry at all is the worker's decision rather than the engine's,
because the worker is the only thing that knows what a failure means. A missing
`credential_ref` is configuration rather than weather and is terminal on the
first attempt; a 404 stays a 404; an oversized response stays oversized.

<p class="related"><strong>Related</strong>
<a href="failure.html">the full retry classification</a> ·
<a href="cookbook.html">a saga with its task table captured</a></p>
</details>

## What each of these actually needs

| | worker | Agent Runtime | Content Server | `pg_cron` |
|---|---|---|---|---|
| 1. Bring a source in | yes | | | yes |
| 2. Make what lands answerable | yes | | yes | |
| 3. Answer from your corpus | yes | yes | | |
| 4. Extractor over a backlog | yes | yes | | |
| 5. Two agents, one conversation | yes | yes | | |
| 6. Waits for a person | yes | yes | | yes |
| 7. Undo what already happened | yes | | | |

Recipe 2 also needs the ingest worker, which is the same image with
`percolate ingest serve`. Everything in the `worker` column is there because the
recipe leaves the machine at least once. Nothing in the table is a control
plane, a scheduler process, a fan-out controller, a state store, a queue broker
or a workflow server.

The row with no ticks at all would be a pipeline of nothing but `p8ql:` and
`sql:` steps, and it is worth seeing once because it finishes before
`start_workflow` returns to you —
[the cookbook](cookbook.html) has that run with `in-database` in the worker
column.

## Where to go next

[The workflow grammar](grammar-workflow.html) is the reference for every key
used above. [Ten things, worked through](cookbook.html) is the same material one
primitive at a time, against a fixture you can install in a minute, with the
output each query actually produced. [Operating it](operating.html) covers what
to watch once one of these is running on a schedule and nobody is looking.
