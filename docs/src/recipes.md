# Workflow recipes

Whole pipelines rather than single moves: a source polled on a clock, a
backlog pushed through a specialist extractor, a question answered by an agent
over your own corpus. Each recipe says what has to exist before it will run.
{: .lede }

[Ten things, worked through](cookbook.html) is the other cookbook, and it is
the one to read first if you have not used any of this yet: it takes one
capability at a time — resolve a name, walk the graph, fan out, undo — against
a fixture you can install in a minute. This page assumes those work and asks
the next question, which is what you actually assemble out of them.

## How much of this has been run

Say it up front, because the rest of this site is written to a stricter rule.
Every other page was executed against a live database before it was written and
pastes the output it got. **This page is composed rather than captured.** Every
function name, argument, column and YAML key below was checked against the
installed schema and against the compiler's own grammar
(`p8_workflow_grammar()`), and where a component has been run end to end
somewhere else the recipe says so and points at it. What is not asserted is the
pipelines as wholes.

Two of the seven also depend on things this release does not have — the channel
poller and an exercised Agent Runtime — and those are named in place rather
than at the bottom. The page carries the `designed` chip for that reason and
moves when the runs exist.

## The shape all seven share

```
  something arrives          a channel: an upload, a poll, a person
        |
  it becomes a resource      content.resources -- a row, bytes optional
        |
  it is indexed              chunks + vectors, and optionally graph nodes
        |
  a workflow asks it a       p8ql: SEARCH / GRAPH / LOOKUP, in-database
  question
        |
  an agent answers with      agent: + output_schema -- a shape, not prose
  a declared shape
        |
  the answer lands           sql: {function: ...} into your own tables
```

Every recipe below is a cut through that diagram. Nothing in it is a service
you run except the worker, the Content Server and the Agent Runtime, and the
first two are one image with different commands.

---

## Before anything runs

Six preliminaries, all one-time. Skipping most of them produces a clear error
in your hand at registration time. Skipping the fourth produces no error at
all, forever, which is why it has its own section.

### Keys are names, never values

Nothing in this database holds a secret. A row that needs credentials holds the
**name of an environment variable**, and the process making the call resolves
it. So `pg_dump` never contains a key, a task stays replayable, and rotating a
credential is a deployment change rather than an `UPDATE`.

| Where | Column or key | Resolved by |
|---|---|---|
| `aiq.embedding_models` | `credential_ref` | the worker, when it embeds |
| `agentic.tool_servers` | `credential_ref` | the Agent Runtime, when it calls a tool |
| a `rest:` step | `credential_ref:` inside the mapping | the worker |
| an `agent:` step | `P8_API_KEY`, written in by the compiler | the worker |

```yaml
  - id: notify
    rest:
      url: '{{env.OPS_WEBHOOK}}/incidents'
      method: POST
      credential_ref: OPS_TOKEN
      body: {summary: '{{steps.brief.result}}'}
```

`{{env.X}}` is resolved **only by the worker**. A `sql:` or `p8ql:` step cannot
read it, deliberately: the database has no business knowing the deployment's
environment, and `resolve_template_ref` refuses the namespace by name rather
than resolving it to null.

The one place this is enforced rather than documented is
`agentic.tool_servers.default_headers`, which is checked by the table:

```
ERROR:  new row for relation "tool_servers" violates check constraint
        "tool_servers_headers_not_secrets"
```

`authorization`, `proxy-authorization` and `cookie` are refused there, because a
key in a header is the same key in a row that `credential_ref` exists to keep
out, and it would arrive by an entirely reasonable-looking registration.

### An embedding model, or `SEARCH` will not compile

`SEMANTIC` and `SEARCH` rank against a vector, and producing one is a model
call the database does not make. A `p8ql:` step in either mode compiles to two
tasks — an embed and the search — and the compiler fills in the embed's URL
from the registry. With nothing registered there is no URL to fill in, so the
document is refused at `define_yaml` time rather than failing per run.

```sql
insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, is_default)
values ('text-embedding-3-small', 1536, 'openai',
        'https://api.openai.com/v1/embeddings', 'LLM_API_KEY', true);

select aiq.register_embedding_space('text-embedding-3-small');
```

The second call generates the storage table and its HNSW index **from the
registry row**, so the dimension and the distance operator cannot drift from
what the model actually returns. `provider` is not a label: it joins to
`aiq.embedding_providers`, which holds the request body's shape and the path to
the vector in the response. `ollama` and `openai` ship as rows; a gateway that
differs from either overrides the row instead of forking anything.

`is_default` is enforced by a partial unique index, not a trigger — two
defaults would be a coin flip about which space `SEMANTIC` searched, so a bad
deploy fails loudly instead.

### The functions a step is allowed to call

A `sql:` step names a function in an allow-list. It cannot carry SQL, which is
what stops a workflow document from being an injection surface, and it is why
every recipe below that lands data has a small function behind it.

```sql
select workflow.register_step_function(
    'land_notices',              -- what the step says
    'harbour.land_notices',      -- what actually runs
    array['jsonb'],
    p_description => 'register fetched notices and chunk their text');
```

Registration checks something worth knowing about, because getting it wrong
produces a workflow that registers cleanly and fails at every single run:
`execute_sql_step` is `SECURITY DEFINER`, so the function runs as **its** owner,
not as you. If that role cannot reach your schema, registration refuses with
the grant to run:

```
ERROR:  function harbour.land_notices(jsonb) is not reachable by app_owner,
        which is the role that will execute it (execute_sql_step is SECURITY
        DEFINER). Registration would succeed and every invocation would fail
        with "permission denied for schema harbour". Run:
        grant usage on schema harbour to app_owner;
```

### A throttle has to exist before a step names it

`rate_key:` on a step is a **reference** to a row in `workflow.rate_limits`, not
a declaration of one. `claim_task` consumes from that bucket with
`update ... where key = $1`, which matches no rows when the bucket does not
exist and therefore returns false — every time, forever.

The failure has no error in it. The task sits in `ready`, no worker ever claims
it, no attempt is recorded, nothing retries, and the worker beside it reports an
empty queue. It was measured on this collection's own embed fan-out: six
children in `ready`, no error, no dead task.

```sql
insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
values ('openai-completions', 20, 20, 1)
on conflict (key) do nothing;
```

Twenty tokens refilling at one a second. Give completions and embeddings
**separate keys** — they hit different provider limits, and one bucket throttles
the cheap call behind the expensive one. `content.install_ingest_workflow`
creates `structure_extraction` for exactly this reason when you ask it for a
graph index.

### Agents and tool servers are rows

A tool server is an endpoint; an agent names tools on it by name. Neither is
code and neither is deployed.

```sql
select agentic.upsert_tool_server($j${
  "name": "harbour-query",
  "kind": "mcp",
  "url": "http://query-mcp:8090",
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

**An omitted key means leave it alone.** Both upserts follow that rule for every
column, and it is stated here because the obvious implementation gets it wrong
in a way that returns success: `{"name": "harbourmaster", "model": "..."}` is
how anybody changes a model, and a naive `set x = excluded.x` would take the
column default for every key you did not send — leaving the agent existing,
resolving by name, and able to do nothing.

Two constraints shape how you register the machine ones. `category: extractor`
requires `structured_output_schema`, because a shape is what makes N extractions
combinable and what makes a bad answer retryable rather than silently wrong. And
`audience` (`user` / `internal` / `system`) is an access decision rather than a
tag — `agentic.agents` is sized for thousands of rows, one specialist per
(source, doctype), and a picker that shows a person a thousand extractors is
broken.

### Ask this deployment what it accepts

Two probes, and both are worth running into a fresh environment before you
debug a workflow that will not compile.

```sql
select workflow.compiler_capabilities();
select aiq.schema('workflow');
```

The first probes the installed parser with one canary per feature and lists
what is `missing`; the compiled parser and the SQL schema ship on separate
clocks and version skew otherwise presents as a syntax error in your document.
The second returns this installation's vocabulary — the functions a `sql:` step
may call, the queues, the registered agents — and runs its own examples through
the compiler on every read, so a spelling this build no longer accepts reports
itself instead of being served as authoritative.

---

## 1. Bring a source in

The one every deployment starts with, and the one that is furthest from done.

A **channel** is where content comes from. `file_upload` covers a person
dragging a PDF in; `http_pull` and `feed` cover a source you go and get. The row
exists, `poll_interval` exists — and **nothing reads it yet**. So a pull source
today is a workflow you author and a schedule you create, which is more typing
than an `INSERT` and does run.

```sql
insert into content.channels (name, kind, config, poll_interval)
values ('harbour-notices', 'http_pull',
        '{"url": "https://example.org/notices.json"}'::jsonb,
        interval '1 hour');
```

The workflow is three steps: read the cursor, fetch, land what came back.

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

Both `notices_cursor` and `land_notices` are functions you register — a `sql:`
step can only name what is in the allow-list, which is the preliminary above.

Two template rules are load-bearing in that document. A reference **embedded in
a string** interpolates as text, which is what makes the URL work; a reference
that is the **whole string** keeps its native type, which is what makes
`args: ['{{steps.fetch.result}}']` arrive as a JSON array rather than as a
string that looks like one.

Getting that split wrong does not raise. It was this collection's own headline
example that proved it: a step passing
`'SEARCH "{{run.question}}" FROM chunks LIMIT 3'` was not a whole-string
reference, so the substitution happened nowhere, the lexical half searched for
the literal text `{{run.question}}`, every lexical rank came back null, and the
fusion quietly degraded to semantic-only. It returned rows. It looked like it
worked.

The landing function is the small piece of SQL this recipe costs you:

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

        -- Null means this id was registered on an earlier poll. Not an error:
        -- a puller that treats it as one re-processes its backlog every cycle.
        continue when v_res is null;

        perform content.record_chunks(v_res, jsonb_build_array(jsonb_build_object(
            'ordinal', 0, 'content', it->>'body',
            'start_char', 0, 'end_char', length(it->>'body'))));
        v_new := v_new + 1;
    end loop;

    update content.channels set last_polled_at = now() where name = 'harbour-notices';
    return jsonb_build_object('registered', v_new);
end $$ language plpgsql;
```

**`external_id` is the idempotency key and the whole design of a poller.**
`register_fetched` returns null rather than raising when the id is already
there, so a source that hands you the same fifty items every hour costs fifty
no-ops. Overlapping windows are then free, which means you can poll a source
that has no reliable cursor at all.

**A resource does not need bytes.** `record_chunks` makes the text answerable
with nothing in object storage — a scraped JSON record has no file, and the
schema says so by making `resources.file_id` nullable. Uploaded documents take
the other path, which is recipe 2.

Then the clock:

```sql
select workflow.schedule_workflow(
    p_name     => 'harbour-notices-hourly',
    p_workflow => 'harbour_notices_poll',
    p_cron     => '17 * * * *',
    p_overlap  => 'skip');
```

`overlap => 'skip'` is what stops a poll that runs long from stacking up behind
itself. Schedules fire from `workflow.tick()`, which needs one `pg_cron` job for
the whole system — one job however many schedules you have, because a schedule
is a row:

```sql
select cron.schedule('workflow-tick', '* * * * *', $$select workflow.tick()$$);
```

Two things about schedules that are easier to know than to discover. The fire is
idempotent through the engine's own machinery rather than a second mechanism —
the external id is the schedule name and the minute, so a retried transaction
returns the existing run. And **a schedule's `input` is a constant**: there is no
templating in it, which is exactly why the cursor above is a step reading the
database rather than a value on the schedule.

> **What is missing.** `channels.poll_interval` is read by nothing, so the
> channel row above is documentation until the poller exists. Everything else in
> this recipe is built, and `workflow.schedules` with `overlap_policy` is the
> half of the pull-source design that shipped.

## 2. Make what lands answerable

One call installs the pipeline that turns a resource into chunks, vectors and,
if you ask for it, graph nodes:

```sql
select aiq.install_structure_null('gpt-4o-mini');
select content.install_ingest_workflow(
           p_model       => 'text-embedding-3-small',
           p_graph_index => true,
           p_graph_model => 'gpt-4o-mini');
-- ingest_file: parse, embed with text-embedding-3-small in batches,
--             graph-index each window with structure_null (gpt-4o-mini)
```

The return value is the point: it says what it installed rather than leaving you
to infer it. Ask for a model that is registered but unreachable and it raises;
let it pick the default and find the default uncallable, and it degrades to
parse-only and tells you so, carrying the compiler's own message rather than a
summary of it.

The shape it writes is worth reading once, because it is the best worked example
of composition in the collection:

```yaml
  - id: parse
    work: true                        # your ingest worker: bytes -> chunks
  - id: embed
    needs: [parse]                    # one batched call, not one per chunk
    work: true
  - id: graph
    needs: [parse]                    # a SIBLING of embed, not a successor
    matrix:
      rows: {function: windows_to_index, args: ['{{run.resource_id}}']}
      max_fanout: 200
      template: {queue: http, rate_key: structure_extraction, rest: …}
  - id: land_graph
    needs: [graph]
    sql: {function: land_graph_windows, args: ['{{steps.graph.result.task_id}}']}
```

**The two indexes are siblings, so their failures are independent.** A
deployment with no embedding model still indexes a graph; a failed extraction
does not cost you the vectors. And a chunkless resource — a CSV, which becomes a
Parquet dataset rather than prose — skips the graph branch for free, because an
empty row set releases the successor where a document-level step would have had
to raise.

The details of what happens to each format, why a chunk is 700 tokens, and why
embedding a corpus is one call rather than one per chunk are all on
[Uploading files](ingest.html), which is a captured run rather than a
composition. Point a channel at the pipeline by name and every upload through it
starts one:

```sql
update content.channels
   set config = config || '{"ingest_workflow": "ingest_file"}'::jsonb
 where name = 'harbour-notices';
```

## 3. Answer a question from your own corpus

Retrieval and a model, as one document, with the answer arriving as a shape you
can put in a column.

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

Three authored steps, four tasks. `SEARCH` desugars into a hidden
**predecessor** — an `http_call` keyed `retrieve__embed` that turns the question
into a vector, and the in-database search step that consumes it. Your id stays
on the search, so `needs: [retrieve]` and `{{steps.retrieve.result}}` mean what
they look like and nothing is rewired. You never write the embedding URL, and
the model is pinned into the query at definition time so the vector and the
space it is ranked against cannot be two different models.

`{{run.$id}}` rather than `{{run.id}}`: the `$` prefix is reserved for engine
fields, so an input key of your own cannot shadow one. Type the wrong one and
the engine tells you which to write instead of resolving to nothing and failing
three tasks later.

**`output_schema` is what makes this composable.** Without it `answer` is prose
and `record` has to parse it defensively. With it the engine parses the model's
JSON-in-a-string answer and checks it *before* anything is stored, so
`record_brief` receives an object. And a shape violation is **the one retryable
failure in this engine** — every other terminal classification exists because
retrying cannot help, and here the same prompt genuinely can conform on the
next attempt, which makes `max_attempts` a real budget for asking again.

It is a shape check and not JSON Schema: types, `required`, `properties`,
`enum`, `items` and `additionalProperties: false`. `$ref`, `allOf`/`anyOf`,
`pattern`, `format` and numeric bounds are not supported and are named here
rather than silently ignored.

## 4. One specialist per document type, over a backlog

This is the population the agentic subsystem is actually sized for. The agents a
person talks to are a rounding error; turning prose into structured data is
`sources × doctypes` specialists, each with a declared output shape.

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

A unique index enforces one specialist per (source, doctype): a second
registration is a conflict to resolve rather than a coin flip at runtime.

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

**`max_fanout` is mandatory**, and the compiler says why rather than defaulting:

```
ERROR: workflow YAML did not compile: matrix step 'extract' declares no
`max_fanout`. A matrix needs a ceiling: a cross join with a forgotten WHERE
expands to the cartesian product, and that should fail this step rather than
the database.
```

The expansion happens in the transaction that completes the parent, so there is
no window where the parent is `done` and the children do not exist — which is
the failure mode a controller-based fan-out has and cannot resume from.

`continue_on: failed` lets a failed child satisfy its dependents, and
`min_success: 0.9` is the threshold that still fails the run when a tenth of the
batch did not come back. Declaring `min_success` without `continue_on` is
refused by name, because without it the first failed child cancels the
successors and the threshold could never be reached.

It is a **transport** floor and not a content one: a 200 carrying an empty body
counts as a success against it. The engine cannot know what a good extraction
looks like, so the threshold answers "did enough calls come back?" and nothing
more. What a good extraction looks like is the agent's
`structured_output_schema`, which is why the extractor row carries one and why
the table refuses an extractor without it.

**The fan-in is a handle, not a payload.** `{{steps.extract.result.task_id}}` is
the matrix task, and `workflow.matrix_outputs(task_id)` pairs every child with
its row, its status and its output. Reduce inside your own function: five
hundred extractions are for aggregating, not for passing through a step argument
that caps at 64KB.

**One sharp edge, and it lands squarely in this recipe.** A matrix *template*
cannot declare `output_schema`. The compiler accepts `queue`, `rate_key`,
`rest`, `embed`, `agent`, `work`, `input`, `session` and `jsonpath` inside a
template and not that — and `output_schema` is the field that parses a model's
JSON-in-a-string answer into an object before it is stored. So a fan-out child
lands a jsonb *string* where recipe 3's single step would have landed an object,
and `land_psc_extractions` has to parse it.

That is not a hypothetical: it is why `content.land_graph_windows` exists beside
`aiq.land_graph_fanout` rather than instead of it. The fix belongs in the
parser, and until it is there, budget one `jsonb` parse in every matrix fan-in
over an agent.

## 5. Two agents, one conversation

A classification and a follow-up should usually be two independent calls. When
they should not — when the second agent needs what the first was told, not just
what it answered — declare a session group.

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

`session_group` asks the **engine** for a session id, stable for the life of the
run and bound to `{{run.$session}}`. Steps naming the same group share one
conversation; two groups in one run are two independent threads; declaring
neither stays stateless, which is the right default for a classifier. An
explicit `session:` still wins, for a caller threading an id it already holds.

`jsonpath: ''` on the last step captures the **whole** response rather than the
assistant text. The default is `choices.0.message.content`, which is what almost
every step wants; overriding it is how you keep the envelope — a session id the
runtime issued, token counts, tool traces — which is otherwise discarded before
reaching `runs.context`.

An `agent:` step is an ordinary REST step whose URL and auth the compiler fills
in: `POST {{env.P8_AGENT_URL}}/internal/run`, `mode: async`,
`credential_ref: P8_API_KEY`. It returns `202` immediately and the runtime calls
`complete_task` when the agent finishes, so a twenty-minute agent holds no
connection. Nested delegation happens inside the runtime rather than being
unrolled into the workflow graph — a researcher calling an analyst is one task
here and a delegation tree there, and the delegation tree is also the span tree.

Citations come out of this for free and without asking the model for them:
`messages.citations` is built mechanically from the `tool_response` rows between
the previous assistant message and this one, for every server flagged
`emits_citations`. Models drop citations, invent ones that do not match what was
retrieved, and cite generically — so the list is built from what the context
actually held rather than from what the model says it used.

> **What is missing.** The Agent Runtime ships in the image and its schema is
> installed, but it has no compose service and no seeded agents, and it is the
> least-exercised corner of the collection. Treat the streaming and delegation
> behaviour as specified and reviewed rather than measured.

## 6. A pipeline that waits for a person

A model proposes; a person decides; the decision is the thing that moves the
run. Neither the wait nor the clock needs a process.

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

`timer` and `signal` are control steps: they hold the run open and act on
nothing. A timer moves when `workflow.promote_due_timers()` is called by the
same `pg_cron` schedule that ticks the engine; a signal step then sits in
`waiting_external`, which is the status that means a person is the dependency,
and the only thing that moves it is:

```sql
select workflow.signal_task(:run_id, 'approve',
    '{"decision":"released","by":"harbourmaster"}'::jsonb);
```

**`signal_task` checks who you are, and a run with no owner is not owned by
everyone.** It takes an explicit permission against the run's owner, which is
set from the verified JWT of whoever started it. This is why a scheduled run
carries the schedule's owner rather than being unowned: a scheduled workflow
that waits for approval could otherwise never be approved, by anybody.

`timer`, `signal` and `sub_workflow` had all been legal *engine* kinds for a
long time and none of them was reachable from a document. It took somebody
trying to write this exact workflow and having the compiler refuse it to find
that out — and `sub_workflow` turned out never to have executed at all, because
`start_child_workflow` inserted a run row without expanding the child's task
graph. Composition was advertised, unreachable, and broken underneath.

## 7. Undo what already happened

An agent that only answers needs no compensation. An agent whose `chained_action`
wrote somewhere, or a `rest:` step that booked something, does.

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

Compensations are not tasks until they are needed: before anything fails there
are three rows and the two undo steps are not among them. Fail the tide check
terminally, call `workflow.begin_compensation(:run_id, 'booking')`, and they are
created and run in the reverse of the order the originals succeeded in.

```
 status | compensation_state
--------+--------------------
 failed | compensated
```

Two columns because there are two questions. A saga that rolled back cleanly
still did not do what it was asked, and a run that reports `succeeded` because
its cleanup worked is a run nobody investigates.

Which failures retry at all is the worker's decision, not the engine's, because
the worker is the only thing that knows what a failure means. A missing
`credential_ref` is configuration rather than weather and is terminal on the
first attempt; a 404 stays a 404; an oversized response stays oversized. The one
deliberate exception is the `output_schema` violation from recipe 3.
[Failure and retry](failure.html) has the full classification.

---

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
`percolate ingest serve`. Everything in the `worker` column is there because
the recipe leaves the machine at least once — a fetch, an embed, an agent
dispatch. Nothing in the table is a control plane, a scheduler process, a
fan-out controller, a state store, a queue broker or a workflow server.

The row that would have no ticks at all is a pipeline of nothing but `p8ql:`
and `sql:` steps — a retrieval, a graph walk, a rollup — and it is worth
seeing once, because it finishes before `start_workflow` returns to you.
[Ten things, worked through §6](cookbook.html) is that run, with the task
table it produced and `in-database` in the worker column.

## Where to go next

[Authoring in YAML](authoring.html) is the reference for every key used above
and for what the compiler refuses. [Ten things, worked through](cookbook.html)
is the same material one primitive at a time, against a fixture you can install
in a minute, with the output each query actually produced.
[Operating it](operating.html) covers what to watch once one of these is running
on a schedule and nobody is looking at it.
