# Agents

An agent is a **row**. Its prompt, model, tools and delegation are data, so
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

This exists because a workflow previously could not *originate* a session:
`session:` resolved only if the caller had put an id in the run input, and the
natural key derives from the run — which the run could not see until
`{{run.$id}}` existed.

## What an agent step actually is

An ordinary REST step whose URL and auth the compiler fills in. It calls
`POST /internal/run` at the Agent Runtime, which returns `202` immediately and
calls `complete_task` when the agent finishes — the same `mode: async` seam
every long-running step uses.

**Nested delegation happens inside the runtime**, not unrolled into the workflow
graph. A researcher agent calling an analyst is one task here and a delegation
tree there. The delegation tree *is* the span tree: `parent_span_id` is the
parent run's own `span_id`, never independently maintained.

## Tools are rows too

A tool is an MCP or OpenAPI endpoint registered in `agentic.tool_servers`,
**discovered rather than declared** — the runtime reads the server's own schema
document instead of keeping a hand-written copy that drifts.

There is no in-process Python tool registry. That is a deliberate difference
from the prior system this replaces: a tool mapped by name in a dict is code you
have to deploy to change.

## Citations are derived, not asked for

`messages.citations` is populated by the runtime, mechanically, from the
`tool_response` rows between the previous assistant message and this one — for
every tool server flagged `emits_citations`, the `resource_id`/`chunk_id` of
every row the query actually returned.

Asking the model to emit its own citation list is unreliable: models drop them,
invent ones that do not match what was retrieved, or cite generically. This is
provenance by construction — *what did the agent's context actually contain when
it answered*, not *what does the agent claim it used* — and it needs no
cooperation from the model.

## Extractors: the population this is sized for

The agents you talk to will be a rounding error. Turning prose into structured
data is a cost-ordered cascade whose last tier is a **specialist extractor per
(source, document type)** with a declared output schema — and that population is
`sources × doctypes`, so `agentic.agents` is expected to hold thousands of rows.

`schema.sql` enforces it: `category = 'extractor'` requires
`structured_output_schema is not null`. An extractor without a declared shape is
a model call with extra steps — the shape is what makes N extractions combinable
and what makes a bad answer *retryable* rather than silently wrong.

`audience` (`user` / `internal` / `system`) is an **access decision**, not
derived from tags: whether a human may pick an agent should not be something a
typo can change.

## Status of this page

The schema is installed and a worked binding exists — one agent over one MCP
tool server and one OpenAPI tool server, discovered rather than declared. What
is not yet asserted anywhere is the **turn itself**: an agent run is an LLM call
and a tool call, and neither is a catalog lookup. Treat the streaming and
delegation behaviour here as specified and reviewed rather than as measured.
