# Agents

An agent is a row. Its prompt, model, tools and delegation are all data, so
changing any of them never touches a workflow that uses it.
{: .lede }

## Naming one from a workflow

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

It calls `POST /internal/run` at the Agent Runtime, which returns `202`
immediately and calls `complete_task` when the agent finishes — the same
`mode: async` seam every long-running step uses, so a twenty-minute agent holds
no connection open anywhere.

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
delegation tree there. The delegation tree is also the span tree, since
`parent_span_id` is the parent run's own `span_id` rather than something
maintained separately.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#agent-steps-sessions-and-declared-shapes">every
`agent:` key</a> ·
<a href="recipes.html#5-two-agents-one-conversation">three agents in one
thread</a></p>
</details>

## Tools are rows too

What we are trying to do here is give an agent a tool without deploying any
code.
{: .goal }

```sql
select agentic.upsert_tool_server($j${
  "name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090",
  "emits_citations": true
}$j$::jsonb);
```

<details class="why" markdown="1">
<summary>Why it works — tools are discovered rather than declared</summary>

A tool is an MCP or OpenAPI endpoint registered in `agentic.tool_servers`, and
the runtime reads the server's own schema document instead of keeping a
hand-written copy that drifts away from it.

There is no in-process Python tool registry, which is a change from the system
this replaces. A tool mapped by name in a dict is code you have to deploy in
order to change, and the whole point of a row is that changing it is an
`UPDATE`.

`emits_citations` is a flag on the server rather than a naming convention,
because whether a server returns citable retrieval results is a property of the
server: this collection's query server sets it, a ticketing API does not.

<p class="related"><strong>Related</strong>
<a href="cookbook.html#10-an-agent-is-a-row">registering one, with the binding
captured</a> ·
<a href="recipes.html#agents-and-tool-servers-are-rows">the omitted-key rule
that makes an upsert safe</a></p>
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

`audience` (`user` / `internal` / `system`) is an access decision rather than
something derived from tags, because whether a human can pick an agent should not
be something a typo can change. Once this table holds thousands of rows, "list
the agents" is useless without a filter and a picker showing a person a thousand
machine extractors is broken.

A unique index enforces one specialist per (source, doctype), so a second
registration is a conflict to resolve rather than a coin flip at runtime.

<p class="related"><strong>Related</strong>
<a href="recipes.html#4-one-specialist-per-document-type-over-a-backlog">a
backlog through one of these</a> ·
<a href="grammar-workflow.html#matrix-the-work-to-do-is-a-query-result">why the
fan-in has to parse a string</a></p>
</details>

## Where this page stands

The schema is installed and there is a worked binding: one agent over one MCP
tool server and one OpenAPI tool server, both discovered rather than declared.
What we have not asserted anywhere is the turn itself, since an agent run is an
LLM call and a tool call and neither of those is a catalog lookup. So treat the
streaming and delegation behaviour described here as specified and reviewed
rather than measured.

Next: [uploading files](ingest.html).
