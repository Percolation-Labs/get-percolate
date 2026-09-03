# Agents

An agent is a specification, and the specification is a row. Its prompt, its
model, the external tools it may call and the agents it may delegate to are all
data, so adding one is an insert and changing one is an `UPDATE` — nothing is
redeployed, and no workflow that uses it is touched.
{: .lede }

The three moves below are the whole loop: write the spec, save it, call it over
REST. Everything after them is what the row can carry once you want more from
it — including the prose it shares with other agents, which is
[skills](skills.html) rather than more of this page.

## Write the spec

An agent definition is a **JSON Schema document**. There is no `prompt` key: the
system prompt is the schema's `description`, and the structured output is its
`properties`.

What we are trying to do here is write an agent as a file we can commit, review
in a diff, and hand to anything that reads JSON Schema.
{: .goal }

```yaml
type: object
name: harbourmaster
description: |-
  You answer questions about the fleet.

  Start with SCHEMA to see what exists, then query. Never guess a vessel name.
model: anthropic:claude-sonnet-5
tools:
  - server: harbour-query
    tools: [query]
properties:
  verdict: {type: string}
  vessel:  {type: string}
required: [verdict, vessel]
```

A `description` this short is deliberate. Anything in it that would be equally
true of a sibling agent belongs in a [skill](skills.html) — a fragment stored
once and referenced by every agent that needs it — rather than copied into each
prompt and left to drift.

The same document is what a Python class produces, because the convention was
chosen so that the two forms are one artifact rather than two:

```python
class Harbourmaster(BaseModel):
    """You answer questions about the fleet.

    Start with SCHEMA to see what exists, then query. Never guess a vessel name.
    """
    model_config = ConfigDict(json_schema_extra={
        "name": "harbourmaster",
        "model": "anthropic:claude-sonnet-5",
        "tools": [{"server": "harbour-query", "tools": ["query"]}],
    })
    verdict: str
    vessel: str
```

<div class="evidence" markdown="1">
<div class="label">Harbourmaster.model_json_schema(), rendered back out as YAML</div>

```yaml
type: object
name: harbourmaster
description: |-
  You answer questions about the fleet.

  Start with SCHEMA to see what exists, then query. Never guess a vessel name.
model: anthropic:claude-sonnet-5
tools:
- server: harbour-query
  tools:
  - query
properties:
  verdict:
    title: Verdict
    type: string
  vessel:
    title: Vessel
    type: string
required:
- verdict
- vessel
```
</div>

<details class="why" markdown="1">
<summary>Why it works — there is no export step, because the authored form and
the deployed form are the same document</summary>

The build step is `model_json_schema()`, which pydantic already wrote. That is
what turns "authored in code, deployed as data" from a pipeline into an
identity: the class has full IDE support and is unit-testable in isolation, and
the moment it is finished it is already serializable, because the only
constraint on an agent definition is that it holds no inline tool code — only
references to external tools, which the next two sections cover.

The convention comes from `p8k8`, the system this one replaces, and it is kept
deliberately for what it rules out. A `prompt:` key makes the prompt a string in
a config file. `description` makes it the docstring of a class, which means the
description a human writes is the description the model receives, and every tool
that already reads JSON Schema reads an agent for free.

One thing was dropped from that lineage rather than inherited quietly. `p8k8`
distinguished `structured_output: true` — properties are the output contract —
from `false`, where properties are "thinking aides" that shape the model's
reasoning without ever being returned. Here `properties` has exactly one
meaning, the output contract, because that is what makes `chained_action`
reachable: an automatic follow-on action needs a validated shape to fire on.
Thinking aides are a real idea and simply are not in this system.

<p class="related"><strong>Related</strong>
<a href="#the-rest-of-what-the-row-carries">what else the row holds</a> ·
<a href="#extractors-the-population-this-is-sized-for">why the output shape is
mandatory for some agents</a></p>
</details>

## Save it

Applying an agent is a migration, not a deploy.

What we are trying to do here is get that file into the database, from `psql`
or from anything that can make an HTTP request.
{: .goal }

There is one function underneath this, so a migration, a script or PostgREST
all reach it the same way:

```sql
select agentic.upsert_agent($j${
  "name": "harbourmaster",
  "model": "anthropic:claude-sonnet-5",
  "category": "tool_user",
  "system_prompt": "You answer questions about the fleet.",
  "tools": [{"server": "harbour-query", "tools": ["query"]}]
}$j$::jsonb);
```

```bash
curl -s http://localhost:3000/rpc/upsert_agent \
  -H 'Accept-Profile: agentic' -H 'Content-Profile: agentic' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"p_spec": {"name": "harbourmaster", "model": "anthropic:claude-sonnet-5"}}'
```

<details class="why" markdown="1">
<summary>Why it works — an omitted key means "leave it alone", and getting that
wrong is a silent total loss</summary>

`upsert_agent` takes the row shape — `system_prompt` and
`structured_output_schema` spelled out — while the file you commit is the schema
document above, where those two are `description` and `properties`. Making that
translation is yours to do for now: there is no packaged CLI that reads the
schema document and calls the function for you, so a script that does both, or
a thin wrapper around `pydantic`'s own `model_json_schema()`, is what "deploying
an agent" means until one exists.

The upsert updates only the columns whose **keys are present**, never every
column. Written the obvious way — `set x = excluded.x` for each one — the most
ordinary edit there is, `{"name": "harbourmaster", "model": "…"}` to change a
model, returns 200 and leaves the agent with an empty system prompt and no
tools: it still exists, still resolves by name, and can do nothing. `excluded`
carries the column *default* for every key the caller did not send. This was
found by doing it, and the same mistake had already shipped once one function
away in `upsert_tool_server`, which is why the rule is now stated once and
applied to every column.

Authorization is inside the function rather than in the client. The upsert is
gated on `rbac.has_permission(uid, 'agents', 'update')`, so pushing as a user
without it fails in Postgres — a check the client performs is a suggestion, one
the database performs is a rule.

Nothing restarts. Agents are loaded at invocation, never at startup, which is
the property that makes "adding an agent is an insert" actually true rather than
true-after-a-rollout.

<p class="related"><strong>Related</strong>
<a href="recipes.html#agents-and-tool-servers-are-rows">the same omitted-key
rule for tool servers</a> ·
<a href="install.html">where PostgREST and the agent runtime come from</a></p>
</details>

## Call it over REST

The runtime has two HTTP endpoints. One runs a turn and streams it; the other
relays a stream to somebody who did not start it.

What we are trying to do here is talk to the agent we just saved, with an
ordinary HTTP client and no bespoke fields.
{: .goal }

Two things have to be true before this returns anything but an error, and
neither is about the agent:

- **`$TOKEN` is a JWT you sign**, and a fresh install has nobody to sign one
  for. [Install § the first user, and a token](install.html#the-first-user-and-a-token)
  is the whole of it; without it this endpoint answers `401 a verified bearer
  token is required` before the stream opens.
- **The model has to be one the runtime can load.** The published
  `percolate-core` image ships `pydantic-ai-slim` with the **OpenAI provider
  only**, so the `anthropic:` model in the spec above — which is what the row
  should say once you are running against Anthropic — comes back as
  `ImportError: Please install the anthropic package` inside the stream, as a
  `RUN_ERROR` event on an otherwise-200 response. On the compose stack, point
  the row at an `openai:` model and give the runtime the provider's own key
  (`OPENAI_API_KEY`, not `LLM_API_KEY`, which is the worker's credential
  mechanism and not read here); `OPENAI_BASE_URL` aims the same client at any
  OpenAI-shaped gateway.

```sql
update agentic.agents set model = 'openai:gpt-4o-mini' where name = 'harbourmaster';
```

```bash
curl -N http://localhost:8080/chat \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{
        "model": "harbourmaster",
        "messages": [{"role": "user", "content": "What has Aurora Kestrel been cited for?"}],
        "stream": true
      }'
```

<div class="evidence" markdown="1">
<div class="label">the response, as server-sent events</div>

```
X-P8-Session-Id: 8f2c…  (also in every event below)

event: RUN_STARTED
data: {"type":"RUN_STARTED","run_id":"…","agent_name":"harbourmaster"}

event: TOOL_CALL_START
data: {"type":"TOOL_CALL_START","tool_name":"query","tool_call_id":"…"}

event: TOOL_CALL_END
data: {"type":"TOOL_CALL_END","tool_call_id":"…","is_error":false}

event: TEXT_MESSAGE_CONTENT
data: {"type":"TEXT_MESSAGE_CONTENT","message_id":"…","delta":"Two port state "}

event: RUN_FINISHED
data: {"type":"RUN_FINISHED","status":"succeeded"}
```
</div>

Continuing the conversation is echoing back the session id you were handed, and
watching one you did not start is a second endpoint:

```bash
curl -N http://localhost:8080/chat -H "X-P8-Session-Id: 8f2c…" …
curl -N http://localhost:8080/sessions/8f2c…/events
```

<details class="why" markdown="1">
<summary>Why it works — the common shape on the way in, this system's richer one
on the way out</summary>

`model` names an **agent**, not an LLM. That single reuse is what lets an
off-the-shelf OpenAI-shaped client drive this runtime with nothing bespoke in
it; the LLM actually called comes from the `agents` row. A client's own `tools`
field is accepted by the shape and deliberately ignored, because an agent's tool
surface is whatever `tool_servers` its row points at, and honouring
caller-supplied tools would put per-request tool binding straight back in.

The thread id travels as a header rather than only a body field, and that is the
load-bearing part: the inbound contract is the OpenAI chat shape, which has
nowhere to put one, so a client using a stock SDK can only reach for a header.
An unknown or unowned id fails with a status code *before* the stream opens,
never as an event inside it — once the response has begun the status is already
sent, and "your session id was wrong" is not something a client should have to
parse out of a stream. Resume needs nothing else, because history is reloaded
from rows.

`stream: false` is refused rather than quietly buffered. This endpoint exists
precisely because streaming is the one thing PostgREST structurally cannot do;
a caller who wants the finished turn reads `messages_api`, which is a better
answer than a fake non-streaming mode.

The second endpoint is not a convenience — it is the proof that the stream is a
*relay* rather than a side effect of the request. Both endpoints read the same
per-session Postgres `NOTIFY` channel, so a client that drops mid-turn
reconnects and keeps receiving, a second client can watch a conversation it did
not start, and neither of them needs to know that delegation exists.

<p class="related"><strong>Related</strong>
<a href="#delegation-is-an-ordinary-tool-call">why sub-agents arrive on the same
stream</a> ·
<a href="query.html#over-rest-and-the-two-things-that-look-like-bugs">reading
rows over PostgREST</a></p>
</details>

## Tools are external, and they are rows

The runtime has no tool code of its own — not one, not even a trivial one. Every
tool an agent can call is a reference to an independently deployed,
independently versioned service.

What we are trying to do here is give an agent a tool without deploying any
code.
{: .goal }

```sql
select agentic.upsert_tool_server($j${
  "name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090",
  "emits_citations": true,
  "cached_tools": [{"name": "query"}, {"name": "schema"}]
}$j$::jsonb);
```

An agent then names that server, and optionally narrows which of its tools it
may use:

<div class="evidence" markdown="1">
<div class="label">the binding, as stored</div>

```
     agent     |    server     | allowlist
---------------+---------------+-----------
 harbourmaster | harbour-query | ["query"]
```
</div>

<details class="why" markdown="1">
<summary>Why it works — tools are discovered rather than declared, and the
allowlist is a list</summary>

A tool server is registered once — url, `kind` (`mcp` or `openapi`),
`credential_ref`, and a cached list of what it currently exposes, fetched at
registration by reading the server's own schema document rather than keeping a
hand-written copy that drifts. `agents.tools` is a list of references into that
table, so the same service bound by ten agents is one row and not ten copies of
a URL and its credentials.

The key is `tools`, plural, and it takes a **list**. Writing `"tool": "query"`
is accepted by the database, which stores the array as opaque JSON, and then
silently dropped by the runtime — leaving the agent with no allowlist at all,
which means every tool that server exposes. It widens access and reports
success, which is the worst shape a mistake can have.

An OpenAPI server is an adapter onto the same canonical shape MCP already
defines, never a second parallel mechanism, and the adapter carries no
per-service knowledge: `operationId` becomes the tool name, parameters merge
into one input schema, method and path become the invocation target. Two things
the first real binding taught: the document is frequently Swagger 2.0 rather
than OpenAPI 3, and the base URL for calls is where the document was *fetched*
from, not what the document claims — `host`/`basePath` and `servers` routinely
lie behind a proxy, and preferring them trades a fact for a claim.

There is no in-process tool registry, which is the deliberate break from the
system this replaces. A tool mapped by name in a Python dict is code you have to
deploy in order to change; the whole point of a row is that changing it is an
`UPDATE`. `emits_citations` is a flag on the server rather than a naming
convention, because whether responses are citable retrieval results is a
property of the server: this collection's query server sets it, a ticketing API
does not.

<p class="related"><strong>Related</strong>
<a href="cookbook.html#10-an-agent-is-a-row">registering one, with the binding
captured</a> ·
<a href="recipes.html#agents-and-tool-servers-are-rows">the omitted-key rule
that makes a re-sync safe</a></p>
</details>

## Delegation is an ordinary tool call

An agent that may call other agents does so through the same mechanism it uses
for everything else, because there is no second mechanism.

What we are trying to do here is let a researcher agent hand work to an analyst,
without either of them knowing anything the other does not.
{: .goal }

```sql
select agentic.upsert_tool_server($j${
  "name": "p8-agents", "kind": "mcp", "url": "http://agent:8080/mcp",
  "serves_agents": true
}$j$::jsonb);

select agentic.upsert_agent($j${
  "name": "researcher",
  "tools": [{"server": "p8-agents", "tools": ["agent__analyst"]}]
}$j$::jsonb);
```

<details class="why" markdown="1">
<summary>Why it works — the runtime serves its own agents as an MCP server, so
delegation needs no built-in tool</summary>

The rule that the runtime has zero built-in tools left a hole: there was no
legal way to say "agent A may delegate to agent B". A hardcoded
`delegate(agent)` tool would have been the first built-in tool and would have
broken the rule everything else rests on. The resolution keeps it intact — the
runtime exposes its own agents as an MCP server, one tool per agent, so
delegation becomes an ordinary `tool_servers` reference. The gateway is the same
deployed process, not a second service.

That makes the per-server allowlist do double duty: `tools: ["agent__analyst"]`
is how you narrow *which* agents a researcher may delegate to, using the same
field that narrows which query operations it may call.

`serves_agents` is a flag rather than a name prefix, and for a sharper reason
than `emits_citations`. Delegation decides how the turn is persisted and hands
the callee a delegated-by header, so detecting it from an `agent__` prefix meant
any registered MCP server could claim that namespace — and a server merely
*named* `agent` produced it by accident through collision-prefixing.

A delegation is persisted differently from an ordinary tool call. Ordinary calls
ride along as JSONB on the assistant row; a delegation gets its own `tool_call`
and `tool_response` rows, written *during* the turn rather than at the end,
because the sub-run's row has to point back at the call that spawned it. A
runtime that persists a whole turn atomically at the end cannot populate that
column at all, and the delegation tree ends up walkable in only one direction.

Nothing new appears on the wire. A delegation is already a tool call, so the
sub-agent's entire streamed turn is the payload of a `TOOL_CALL_START` /
`TOOL_CALL_END` pair in the parent's stream, correlated by the sub-run's own
`run_id`. Every run in a session publishes to one channel, so a client renders
"delegating to the analyst" as an in-progress tool call without the protocol
needing to know delegation is happening. The delegation tree is also the span
tree: `parent_span_id` is the parent run's own `span_id`, not something
maintained separately.

<p class="related"><strong>Related</strong>
<a href="#call-it-over-rest">the stream those events arrive on</a> ·
<a href="recipes.html#5-two-agents-one-conversation">three agents in one
thread</a></p>
</details>

## The rest of what the row carries

Everything above is the loop. These are the columns you reach for once one agent
is running and you want it to behave differently.

What we are trying to do here is bound a long conversation, fire an action on
the structured output, and keep the table usable at a thousand rows.
{: .goal }

```sql
select agentic.upsert_agent($j${
  "name": "harbourmaster",
  "audience": "user",
  "category": "tool_user",
  "tags": ["fleet", "compliance"],
  "context_policy": {"window_messages": 40, "summarize_after_messages": 60},
  "chained_action": {"kind": "pg_function", "target": "agentic.apply_summary"}
}$j$::jsonb);
```

<details class="why" markdown="1">
<summary>Why it works — the numbers are per-agent data, because the right number
is still an open question</summary>

`context_policy` is the persistence adapter's reload policy. The default is
windowing plus a reserved slot for a rolling summary, never "everything ever
said in this session", and the parameters live on the row rather than as
constants in the adapter because message-count-versus-token-estimate is
genuinely unsettled. `summarizer_agent_id` names which agent summarizes the
windowed-out history — a nullable self-reference, so "who summarizes" is data
too.

The window is scoped to the **branch**, not the session. A session-scoped window
hands a delegated sub-agent the parent's rows, including the `tool_call` row
representing its own invocation, which is both wrong and confusing to the model.
A run reloads the messages of the runs sharing its parent: `null` for a
top-level run, so successive turns are one continuous history; the parent's run
id for a delegated one, so a sub-agent sees its own turns and nothing of the
conversation that called it.

`chained_action` is p8k8's "chained tool call" reframed as data rather than a
Python callable lookup. A `pg_function` target has the signature
`(jsonb) -> jsonb` and receives the structured output *plus* the run context
that produced it — `{"run_id", "session_id", "agent", "output"}` — because an
action given only the model's output cannot write anything scoped to the
conversation it came from, which is exactly what a summarizer needs. It fires
whenever the agent has both a schema and an action: under pydantic-ai the output
either validates or the run fails, so there is no third state to test for.

`audience` is an access decision and is deliberately not derived from `tags`.
Whether a human may pick an agent should not be something a typo can change, and
once this table holds thousands of rows a picker showing a person a thousand
machine extractors is broken. `category` is a closed list for the same reason:
an open one becomes a synonym pile within a month, and filtering was the point.

<p class="related"><strong>Related</strong>
<a href="#extractors-the-population-this-is-sized-for">what makes the table that
big</a> ·
<a href="skills.html#what-the-prompt-becomes-and-who-decides">the skills key inside
context_policy</a> ·
<a href="outputs.html">the same schema idea for a workflow step</a></p>
</details>

## Citations are derived, not asked for

What we are trying to do here is know what an agent actually had in front of it
when it answered.
{: .goal }

```sql
select seq, role, citations from agentic.messages_api
where session_id = :session order by seq;
```

<details class="why" markdown="1">
<summary>Why it works — asking the model for its own citations does not work
well</summary>

`messages.citations` is populated by the runtime, mechanically, from the
`tool_response` rows between the previous assistant message and this one — for
every tool server flagged `emits_citations`, the `resource_id` and `chunk_id` of
every row the query actually returned.

Models drop citations, invent ones that do not match what was retrieved, or cite
generically. So the list is built from what the agent's context actually
contained when it answered rather than from what it says it used, and that needs
no cooperation from the model at all.

Retrieval payloads themselves are not stored. A RAG result is volatile scratch:
it is re-fetched next turn against a moving index, it would dominate the table
by volume, and replaying it as history would feed the model stale context it did
not ask for. The assistant row keeps the fact of the call and its provenance,
and nothing of its payload — citations without payloads is the whole design.

<p class="related"><strong>Related</strong>
<a href="ingest.html">where a citable chunk comes from</a> ·
<a href="query.html">what the query server returns</a></p>
</details>

## Extractors: the population this is sized for

The agents you talk to will be a rounding error. Turning prose into structured
data is a cost-ordered cascade whose last tier is a specialist extractor per
(source, document type), and that population is `sources × doctypes`.

What we are trying to do here is register one specialist and have the database
refuse it if the shape is missing.
{: .goal }

```sql
select agentic.upsert_agent($j${
  "name": "psc_report_extractor",
  "category": "extractor",
  "audience": "system",
  "extracts_source": "harbour-notices",
  "extracts_doctype": "psc_report",
  "structured_output_schema": {"type": "object", "required": ["vessel"]}
}$j$::jsonb);
```

<details class="why" markdown="1">
<summary>Why it works — two constraints stop this table becoming unusable at a
thousand rows</summary>

`category = 'extractor'` requires `structured_output_schema`, enforced by the
schema. An extractor with no declared shape is a model call with extra steps,
since the shape is what lets you combine N extractions and what makes a bad
answer retryable rather than silently wrong.

A unique index enforces one specialist per (source, doctype), so a second
registration is a conflict to resolve rather than a coin flip at runtime.

<p class="related"><strong>Related</strong>
<a href="recipes.html#4-one-specialist-per-document-type-over-a-backlog">a
backlog through one of these</a> ·
<a href="grammar-workflow.html#matrix-the-work-to-do-is-a-query-result">why the
fan-in has to parse a string</a></p>
</details>

## Naming one from a workflow

An agent is also a step kind, which is how a pipeline gets one without knowing
any of the above.

What we are trying to do here is have two agents work in sequence and share one
conversation between them.
{: .goal }

```yaml
  - id: triage
    agent: classifier
    input: 'Classify: {{steps.retrieve.result}}'
    session_group: analysis

  - id: deep_dive
    needs: [triage]
    agent: researcher            # may itself delegate to other agents
    input: '{{steps.triage.result}}'
    session_group: analysis      # …so these two share one conversation
```

<details class="why" markdown="1">
<summary>Why it works — an agent step is a REST step whose URL and auth the
compiler fills in</summary>

It compiles to `POST {{env.P8_AGENT_URL}}/internal/run` with `mode: async`: the
runtime accepts the task id, returns `202` immediately, and calls
`complete_task` when the agent finishes — the same seam every long-running step
uses, so a twenty-minute agent holds no connection open anywhere. That is a
third endpoint, and it is the one part of this page the runtime does not serve
yet.

`session_group` asks the engine for a session id that is stable for the life of
the run and bound to `{{run.$session}}`. Steps naming the same group share a
conversation, two groups are two independent threads, and declaring neither
stays stateless, which is the right default for a classification step.

Before this existed a workflow could not *start* a session of its own:
`session:` only resolved if the caller had put an id in the run input, and the
natural key comes from the run, which the run could not see until `{{run.$id}}`
existed.

Nested delegation happens inside the runtime rather than being unrolled into the
workflow graph, so a researcher agent calling an analyst is one task here and a
delegation tree there.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#agent-steps-sessions-and-declared-shapes">every
`agent:` key</a> ·
<a href="first-workflow.html">a four-step pipeline end to end</a></p>
</details>

## Where this page stands

The schema is installed, and the bindings on this page were executed against it:
one agent over one MCP tool server and one OpenAPI tool server, both discovered
rather than declared, and the schema-document round trip is the real output of
`model_json_schema()`. The runtime that serves `/chat` is built and its own
suite has taken a three-level delegation tree, a resumed session and a
second-client relay end to end against a live database and a live model.

What this repository does not assert is the turn itself, because an agent run is
an LLM call and a tool call and neither of those is a catalog lookup. So treat
the streaming and delegation behaviour described here as specified, reviewed and
exercised elsewhere rather than measured here.

Next: [your first workflow](first-workflow.html), which is the same database
seen from the other side — a four-step pipeline walked from `define_yaml` to a
completed run.
