# Agents

An agent is a row. Its prompt, model, tools and delegation are all data, so
changing any of them never touches a workflow that uses it.
{: .lede }

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

## Sessions

Declaring `session_group` asks the engine for a session id, stable for the life
of the run and bound to `{{run.$session}}`. Steps naming the same group share a
conversation; two groups are two independent threads; declaring neither stays
stateless, which is the right default for a classification step.

Before this a workflow could not start a session of its own. `session:` only
resolved if the caller had put an id in the run input, and the natural key comes
from the run, which the run could not see until `{{run.$id}}` existed.

## What an agent step actually is

An ordinary REST step whose URL and auth the compiler fills in. It calls
`POST /internal/run` at the Agent Runtime, which returns `202` immediately and
calls `complete_task` when the agent finishes — the same `mode: async` seam
every long-running step uses.

Nested delegation happens inside the runtime rather than being unrolled into the
workflow graph, so a researcher agent calling an analyst is one task here and a
delegation tree there. The delegation tree is also the span tree, since
`parent_span_id` is the parent run's own `span_id` rather than something
maintained separately.

## Tools are rows too

A tool is an MCP or OpenAPI endpoint registered in `agentic.tool_servers`, and
it is discovered rather than declared: the runtime reads the server's own schema
document instead of keeping a hand-written copy that drifts away from it.

There is no in-process Python tool registry, which is a change from the system
this replaces. A tool mapped by name in a dict is code you have to deploy in
order to change.

## Citations are derived, not asked for

`messages.citations` is populated by the runtime, mechanically, from the
`tool_response` rows between the previous assistant message and this one — for
every tool server flagged `emits_citations`, the `resource_id`/`chunk_id` of
every row the query actually returned.

Asking the model to emit its own citation list does not work well: models drop
them, invent ones that do not match what was retrieved, or cite generically. So
we build the list from what the agent's context actually contained when it
answered, rather than from what it says it used, and that needs no cooperation
from the model at all.

## Extractors: the population this is sized for

The agents you talk to will be a rounding error. Turning prose into structured
data is a cost-ordered cascade whose last tier is a **specialist extractor per
(source, document type)** with a declared output schema — and that population is
`sources × doctypes`, so `agentic.agents` is expected to hold thousands of rows.

`schema.sql` enforces this: `category = 'extractor'` requires
`structured_output_schema is not null`. An extractor with no declared shape is a
model call with extra steps, since the shape is what lets you combine N
extractions and what makes a bad answer retryable rather than silently wrong.

`audience` (`user` / `internal` / `system`) is an access decision rather than
something derived from tags, because whether a human can pick an agent should not
be something a typo can change.

## Where this page stands

The schema is installed and there is a worked binding: one agent over one MCP
tool server and one OpenAPI tool server, both discovered rather than declared.
What we have not asserted anywhere is the turn itself, since an agent run is an
LLM call and a tool call and neither of those is a catalog lookup. So treat the
streaming and delegation behaviour described here as specified and reviewed
rather than measured.

Next: [uploading files](ingest.html).
