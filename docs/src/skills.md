# Skills and plugins

A skill is a prompt fragment in a row. An agent **attaches** the ones it may
use the same way it binds tools — by name, carrying the listing and not the
text — and a body is loaded on demand when a turn calls for it. So a prompt is
assembled at invocation rather than authored whole, attaching a capability
costs a line rather than a page, and adding one is an insert.
{: .lede }

The idea is not ours. [Agent Skills](https://agentskills.io) is an open
standard, and [Anthropic's plugin
specification](https://code.claude.com/docs/en/plugins-reference) packages
skills, subagents and tool servers into an installable bundle. Both put those
things in a **directory**: `skills/<name>/SKILL.md` with YAML frontmatter, a
`plugin.json` beside it, discovered by walking the tree.

We keep the idea and change the substrate, because in this system everything is
already data. A skill is a row, a plugin is a row, and the agent that uses them
is a row. That is not a port of the standard — it is the same design given
things a file tree cannot have: row-level security on who may read a fragment,
one write path that refuses a bad one, retrieval over the whole population, a
version recorded on the run that used it, and install-and-uninstall as a
transaction.

## Write a skill

A skill has two parts and the split between them is the entire mechanism: a
**listing** a model reads to decide whether it needs this, and a **body** it
reads once it has decided.

What we are trying to do here is turn a paragraph that four different agents
have been carrying in their own prompts into one row that all four reference.
{: .goal }

```sql
select agentic.upsert_skill($j${
  "name": "p8ql-fuzzy-lookup",
  "description": "When a LOOKUP returns nothing, use FUZZY LOOKUP instead of guessing another spelling.",
  "when_to_use": "A LOOKUP came back empty, or you are about to try a second spelling of a name, ticker or code.",
  "content": "WHEN A LOOKUP FINDS NOTHING, USE `FUZZY LOOKUP` -- do not guess another spelling. The names in this store follow conventions you cannot deduce. Asked about sterling, a model tried `sterling`, `gbp`, `gbp/usd`, `GBPUSD` and `fx_pair` in five separate calls and gave up, while `FUZZY LOOKUP \"gbp\"` returns `usd/gbp` on the first try.",
  "requires_tools": ["harbour-query"],
  "category": "procedure",
  "tags": ["query", "p8ql"]
}$j$::jsonb);
```

<details class="why" markdown="1">
<summary>Why it works — the listing is what enters every prompt, so the database
treats it as a budget rather than a text field</summary>

`description` and `when_to_use` go into the prompt of every agent that is
offered this skill, whether or not the skill is ever used. `content` costs
nothing until the fragment is expanded. Two columns rather than one is what
makes offering a thousand skills affordable, and it is the same progressive
disclosure the standard describes — a skill's body *"loads only when it's
used, so long reference material costs almost nothing until you need it."*

Because the listing is a budget, the table enforces one: `description` plus
`when_to_use` is capped at 1,536 characters, which is the standard's own
listing cap transcribed rather than invented. A cap enforced by the table is
the only kind that holds — the alternative is truncation at render time, which
is invisible, and a skill whose trigger sentence was cut in half is a skill the
model quietly stops choosing.

`when_to_use` is separate from `description` because it answers a different
question and because it is the sentence a semantic match should hit: a user's
request rarely resembles a capability statement, and usually does resemble the
situation the fragment is for.

`requires_tools` is the useful half of the standard's `allowed-tools`. That
field is a permission grant against an interactive approval flow, and there is
no such flow here — what survives is the dependency it implies, which the
database checks the moment an agent tries to carry the fragment.

<p class="related"><strong>Related</strong>
<a href="https://agentskills.io">the Agent Skills standard</a> ·
<a href="https://code.claude.com/docs/en/skills">frontmatter and progressive
disclosure</a> ·
<a href="agents.html">the agent whose prompt this joins</a></p>
</details>

## Attaching a skill is like binding a tool

This is the part worth getting straight before anything else, because it is
where the efficiency comes from and it is easy to assume the opposite.

A tool is offered to a model as a **listing** — a name, a description, an
argument schema. The implementation lives in a service the model never sees,
and it is reached only when the turn calls for it. That is why an agent can be
offered dozens of tools without dozens of implementations sitting in its
context.

A skill attached to an agent works the same way, and the parallel is the design
rather than a metaphor:

| | `agents.tools` | `agents.skills` |
|---|---|---|
| the row names | servers and tool names | fragment names |
| the prompt carries | name, description, parameters | name, description, when to use |
| it does **not** carry | the implementation | the body |
| on demand you get | the tool's result | the fragment's text |
| the model then | calls it | follows it |

So **attaching is cheap and it is lazy**. Every attached fragment costs one
listing line in every prompt, whether or not it is used. The body arrives only
when the turn calls for it. Attaching one more capability costs a line, not a
page.

What we are trying to do here is give an agent eleven procedures it may use,
while its prompt carries the text of almost none of them.
{: .goal }

Eleven skills is the shape this is sized for. This block is about
`context_policy` — which skills reach the prompt, and when — so it pins none,
and the reason is the next section: `p8ql-fuzzy-lookup` declares
`requires_tools`, and pinning it before the agent binds that server is refused.
The pins come after the binding, further down.

Two things about `skills` and `context_policy.skills.always`, because they look
alike and are not. **A pin is validated**: `pins skill(s) p8ql-graph-walk, ...
which do not exist` rather than an agent quietly carrying a reference to
nothing. **`always` is not** — the two names below do not exist yet, this is
accepted, and each resolves to nothing the agent silently never receives, which
is exactly what the refusal one field to the left exists to prevent. Worth
knowing before you put something load-bearing in `always`.

```sql
select agentic.upsert_agent($j${
  "name": "harbourmaster",
  "context_policy": {"skills": {
    "always":    ["house-style", "safety-no-destructive-sql"],
    "match": true, "top_k": 2, "min_score": 0.28,
    "max_chars": 6000, "index": "bound", "sticky": true
  }}
}$j$::jsonb);
```

<div class="evidence" markdown="1">
<div class="label">the same eleven fragments, two ways — measured</div>

```
if attaching meant carrying the body     4,400 chars, every turn, regardless
what attaching actually costs            2,403 chars of listings

one turn's assembled prompt (asking about an empty LOOKUP):
  agent's own prompt          179
  2 always-on bodies        \
  2 bodies the turn matched  > 1,400
  7 remaining listings      1,614
  ------------------------------------
  total                     3,267 chars   vs 4,579 if bodies were carried
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the eager cost grows with the surface and the lazy cost
does not</summary>

Write out what a prompt costs under each model and the difference is structural
rather than a matter of degree.

**If attaching carried the body**, the prompt is `agent + Σ(all attached
bodies)`. Every term grows with the size of the surface. Attaching a twelfth
fragment costs its whole body on every turn forever, including the turns it has
nothing to do with — so there is a point, and it arrives quickly, where you
stop attaching things because you cannot afford them. That is the same pressure
that makes people write one enormous system prompt and then stop editing it.

**With lazy attachment**, the prompt is `agent + Σ(always bodies) + (at most
top_k bodies, capped by max_chars) + N listings`. Only the last term grows with
the surface, and it grows in units of a listing rather than a body. The bodies
that arrive are chosen per turn and bounded by a budget you set, not by how
many fragments exist.

In the fixture above a listing averages 218 characters against a body's 400,
so the surface term grows about 1.8× more slowly. **That ratio is the whole
game, and 1.8 is a floor rather than a typical figure** — these fragments are
deliberately terse. A real procedure runs to two or five thousand characters
against the same ~220-character listing, which is 10× to 25×. The saving is
proportional to how much you have to say.

The one thing you pay unconditionally is the index: `N` listing lines, every
turn. That is the honest cost of this shape, and it is why the index is a
decision rather than a freebie — [what the numbers say](#what-the-numbers-say)
is where that decision is argued, and where the listing turns out to be doing
most of the work.

<p class="related"><strong>Related</strong>
<a href="agents.html#tools-are-external-and-they-are-rows">the tool surface
this mirrors</a> ·
<a href="#what-the-prompt-becomes-and-who-decides">what arrives on demand, and who decides</a></p>
</details>

## Attach it to an agent

What we are trying to do here is add one fragment to an agent without knowing,
or overwriting, the rest of the list it already carries.
{: .goal }

The skill written above declares `requires_tools: ["harbour-query"]`, and attaching a
skill to an agent that does not bind the server it names is **refused**:

```
ERROR: agent harbourmaster: p8ql-fuzzy-lookup needs harbour-query -- a tool server
       this agent does not bind. Bind it, unpin the skill, or do not remove
       the binding.
```

That is the guard working rather than something to route around — a prompt
fragment telling a model to reach for a tool it cannot call is worse than no
fragment — but it does mean the server and the binding come first:

```sql
select agentic.upsert_tool_server($j${
  "name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090"
}$j$::jsonb);

select agentic.upsert_agent($j${
  "name": "harbourmaster",
  "tools": [{"server": "harbour-query", "tools": ["query"]}]
}$j$::jsonb);
```

```sql
select agentic.attach_skill('harbourmaster', 'p8ql-fuzzy-lookup');

-- author and attach in one statement, which is what the REST path needs
select agentic.attach_skill('harbourmaster', 'house-style', $j${
  "description": "How answers are written here.",
  "content": "Say which tool told you something. An answer assembled from retrieval is worth exactly what its sources are worth."
}$j$::jsonb);
```

<details class="why" markdown="1">
<summary>Why it works — appending in the database closes a lost update that
read-modify-write cannot</summary>

Without this, adding one fragment means reading `agents.skills`, appending, and
sending the whole array back. Two clients doing that at once both read the same
array and the second write silently discards the first — no error, no conflict,
and an agent missing an instruction somebody watched themselves add.

<div class="evidence" markdown="1">
<div class="label">two connections, one agent, two fragments, both reading before either writes</div>

```
read-modify-write (the array, through upsert_agent)  ->  1 of 2 landed
attach_skill                                         ->  2 of 2 landed
```
</div>

`attach_skill` appends inside a `select … for update`, so concurrent attaches
to one agent serialize instead of clobbering. It does not write the agent row
itself: it computes the new array and hands it to `upsert_agent`, so the checks
that refuse an unknown fragment, or one whose `requires_tools` name a server
this agent does not bind, run from one copy rather than two. Attaching a skill
written against the query server to an agent that binds no query server is
refused with the same message as authoring it that way.

Attaching what is already attached is a no-op rather than an error, and a new
fragment appends at the end because composed fragments are concatenated in
listed order. Two things are refused rather than resolved: an agent that does
not exist, because the underlying upsert would cheerfully create one with an
empty prompt that resolves by name and can do nothing; and a name given both as
an argument and inside the spec, disagreeing, because whichever one the
function picked, the other is what somebody believed they had written.

<p class="related"><strong>Related</strong>
<a href="agents.html#save-it">the agent write path these checks live in</a></p>
</details>

## What the prompt becomes, and who decides

Attachment says what an agent *may* use. This is when a body actually arrives,
and there are three answers, differing only in **who decides**: the author, the
runtime, or the model.

What we are trying to do here is have an agent always follow two house rules,
pick up whatever else the current question calls for, and know what else it
could ask for.
{: .goal }

```sql
select agentic.upsert_agent($j${
  "name": "harbourmaster",
  "context_policy": {
    "window_messages": 40,
    "skills": {
      "always":  ["house-style", "safety-no-destructive-sql"],
      "match": true, "matcher": "semantic",
      "top_k": 2, "min_score": 0.28, "max_chars": 6000,
      "index": "bound", "sticky": true
    }
  }
}$j$::jsonb);
```

<div class="evidence" markdown="1">
<div class="label">what one turn assembled, for the request "LOOKUP sterling came back empty"</div>

```json
{"composed": ["house-style", "safety-no-destructive-sql"],
 "matched":  [{"skill": "p8ql-fuzzy-lookup",     "score": 0.4193},
              {"skill": "p8ql-unresolved-names", "score": 0.3841}],
 "expanded": ["p8ql-fuzzy-lookup", "p8ql-unresolved-names"],
 "indexed":  19,
 "chars": {"prompt": 5852, "agent": 179, "bodies": 1400, "index": 4199}}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — expansion is the primitive, and the tool that fetches a
skill is an option rather than the mechanism</summary>

`always` is the **unconditional** subset of the attached surface: read from the
database at invocation and concatenated into the prompt. It is a policy key
rather than the meaning of attachment, and that is the distinction the section
above turns on — if attaching were eager there would be no cheap way to give an
agent a large surface at all. Expect two or three names here out of a surface
of dozens.

**Matched** is the runtime's answer: it embeds the turn's request, ranks it
against the listings of the attached surface, and expands what clears
`min_score` under the `max_chars` budget. `scope` widens that ranking beyond
what the agent attached, which is discovery rather than capability — a
different claim, so a different key. No round trip and no tool call — the model never
has to know skills exist. When the budget is reached the remaining matches fall
back to their index lines and the run records which ones, because a silent
truncation is the failure the listing cap exists to prevent one level up.

The third way in is **fetched**, where the model asks. It is two surfaces, split
by how large the population is:

`load_skill(name)` is **one tool** covering the attached surface. The index has
already named those fragments, so the model does not need to search for them —
it needs a way to ask, and one tool with one argument is that. Keeping it to one
is deliberate: every tool an agent is offered costs its name, description and
schema in every prompt, and a design that answers "how do we expose this?" with
"another tool" has usually not asked the question yet.

Beyond the attached surface, an agent can be permitted to reach fragments it
could never list — a thousand rows will not fit in a prompt as a thousand
listing lines. Those become **deferred tools**: one per fragment, hidden from
the model entirely, surfaced by a search when a request calls for one. This is
[pydantic-ai's `defer_loading()`](https://pydantic.dev/docs/ai/tools-toolsets/tools-advanced/),
used as-is, and it is the same trade this page has been making all along —
a listing is cheap, a body is not — in the framework's own vocabulary. An agent
that permits no discovery carries none of it.

**None of this uses a framework's lazy loading, and it does not need to.**
pydantic-ai has a `DeferredLoadingToolset` that hides tools from a model until
a search turns them up, which is the same instinct — but the laziness here is a
SQL projection. The query behind the index asks for the name, the description
and the trigger, and never for the body, so a body is not read until it is
named. That holds under any framework or none. It is also the half that is easy
to get wrong, because the prompt looks lazy either way: a query that selects
the whole row and uses three columns of it has already pulled every attached
body out of the database.

`sticky` is why instructions do not churn. Matching per turn against the latest
message, on its own, means a fragment expanded on turn three is gone on turn
four when the subject moves — so a model told to cite its sources quietly stops
being told, and nothing reports it. With stickiness the set is a union within a
branch: later matches are added, never swapped in, so instructions are
monotonic and the accumulation is bounded by `max_chars` rather than by the
size of the fleet.

<p class="related"><strong>Related</strong>
<a href="agents.html#the-rest-of-what-the-row-carries">the rest of
`context_policy`</a> ·
<a href="https://pydantic.dev/docs/ai/tools-toolsets/toolsets/">pydantic-ai's
toolsets, which this deliberately does not use</a></p>
</details>

<div class="evidence" markdown="1">
<div class="label">the fetched path, running against a real model</div>

```
tool surface  1 (load_skill) + 10 deferred (hidden until searched)

  -> load_skill({"name":"p8ql-fuzzy-lookup"})
  <- WHEN A LOOKUP FINDS NOTHING, USE `FUZZY LOOKUP` -- do not guess another...

  -> skill_extraction_cost_cascade({})          # never attached, never listed
  <- Extraction is ordered by cost, not by capability. Structured feeds first...
```
</div>

<details class="why" markdown="1">
<summary>Why it works — and the limit worth knowing before you rely on it</summary>

The second call in that trace is the one to look at. `extraction-cost-cascade`
was never attached to the agent, never appeared in its index, and was never in
its prompt. It was found by search and followed, which is what deferred loading
is for.

The limit is that **the model has to decide to look.** Asked how to get
structured data out of 200 documents without it costing a fortune, the same
agent with the same population answered from its own general knowledge and
never searched at all — and answered reasonably, which is worse, because
nothing signals that a house procedure went unread. The moment the request was
shaped like a request to look, the right fragment arrived.

That is the argument for the runtime deciding rather than the model, and it is
why matching is the primary path and fetching is the addition. A fragment the
runtime expands is in front of the model whether or not the model would have
thought to ask.

<p class="related"><strong>Related</strong>
<a href="#what-the-prompt-becomes-and-who-decides">the two paths that do not
require the model to ask</a></p>
</details>

## Matching is a query, not a second index

The database already knows how to rank text against a question. Skills register
as a corpus like any other, so nothing new was built to find them.

What we are trying to do here is ask which fragments bear on a request, using
the same modes that answer every other retrieval question in this system.
{: .goal }

```sql
select s.name, round((1 - m.distance)::numeric, 3) as score
  from aiq.semantic_in('skills', :query_vector, 'text-embedding-3-small', 5) m
  join agentic.skills_api s on s.id = m.chunk_id
 order by score desc;
```

<details class="why" markdown="1">
<summary>Why it works — a table with an <code>id</code> is a corpus, and only
the listing is embedded</summary>

`agentic.skills` needed no adaptation to become searchable: the semantic path
joins its embedding space back to the source table on `id`, which is the whole
contract. It is registered as **both** a semantic and a lexical source, so an
agent's matching policy degrades to full-text where no embedding provider is
configured rather than degrading to nothing.

Only the listing is embedded, never the body. A body is hundreds of imperative
lines that dilute the one sentence describing what the fragment is for, and
that claim was measured rather than assumed: embedding the listing beats
embedding the body by 22 points of hit@1 and 0.118 of MRR over 31 labelled
requests. The body arm finds the right fragment somewhere in the top three four
points *more* often — expansion takes the top *k* under a threshold, so rank is
what decides, but the recall result is real and is written down rather than
rounded away.

The text that gets embedded is a generated column, so the text a matcher
indexes and the text a reader sees cannot drift apart. That turned out to have
a consequence worth knowing: a generated column may not reference another
generated column, so the full-text vector is generated from the base columns
directly rather than from the generated listing.

<p class="related"><strong>Related</strong>
<a href="query.html">the query modes this reuses</a> ·
<a href="ingest.html">how a corpus gets its vectors</a></p>
</details>

## A plugin is the bundle, and the bundle is removable

Servers, skills and agents arrive together and leave together. That is what a
plugin is here: not a new kind of thing, but **provenance on the things that
already exist**.

What we are trying to do here is install a capability — the tools, the prose
and the agent that uses both — from one document, and be able to take it back
out later.
{: .goal }

```sql
select agentic.apply_plugin($j${
  "name": "harbour-extras", "version": "0.2.0",
  "tool_servers": [{"name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090"}],
  "skills":       [{"name": "p8ql-fuzzy-lookup", "description": "...", "content": "...",
                    "requires_tools": ["harbour-query"]}],
  "agents":       [{"name": "harbourmaster", "skills": ["p8ql-fuzzy-lookup"],
                    "system_prompt": "You answer questions about the fleet.",
                    "tools": [{"server": "harbour-query", "tools": ["query"]}]}]
}$j$::jsonb);
```

**A manifest PRUNES.** Anything stamped with that plugin name and absent from
the manifest is removed — that is what makes a plugin removable, and it is why
the name above is `harbour-extras` rather than `harbour`. Applying a manifest
under the sample's own name would delete the skill the sample ships and rewrite
its agent, silently, on a database the install guide has just told you to load.
Measured before this was changed: `harbour-house-style` gone, `harbourmaster`'s
skills replaced, the plugin row left reading version 0.2.0. Use a name of your
own unless you mean to replace the whole plugin.

**The agents in a manifest are ROWS, not schema documents**, and the difference
is silent. `apply_plugin` passes each one to `upsert_agent`, which reads
`system_prompt` and `structured_output_schema` — so an agent written the way
[agents](agents.html) authors them, with `description` and `properties`, is
accepted, stored, and left with an empty prompt and no output contract. It
resolves by name and can do nothing. Either spell the row keys here, as above,
or translate first: `percolate agent push` and `percolate sample load` both run
the schema document through `authoring.from_json_schema` on your behalf.

<div class="evidence" markdown="1">
<div class="label">re-applying the same plugin with one agent dropped from the document</div>

```json
{"plugin": "harbour", "version": "0.2.1",
 "tool_servers": ["harbour-query"], "skills": ["p8ql-fuzzy-lookup"],
 "agents": ["harbourmaster"],
 "removed": ["agent:scratch", "skill:p8ql-graph-walk"]}
```
</div>

<details class="why" markdown="1">
<summary>Why it works — an upsert-only apply is how a bundle rots, so this one
prunes and says what it removed</summary>

Applying is one transaction in one order — servers, then skills, then agents —
because an agent's composed fragments must exist before they can be validated,
and a fragment's `requires_tools` name servers the agent must already bind.

The half that matters is the prune. Without it, an agent dropped from the
document stays installed, still resolvable by name, still runnable, and nothing
on disk describes it any more. So a row carrying this plugin's name and absent
from this manifest is removed, and the removals come back in the result rather
than happening quietly. That makes an absent section loud on purpose:
`{"name": "harbour"}` declares no agents and therefore removes every agent
`harbour` installed, which is what makes uninstall expressible without a second
function.

Three things it refuses to remove, and none of them is caught by a foreign key,
because `agents.skills` is a list of names and `agents.tools` holds server
names in JSONB — which is exactly what lets one fragment serve many agents. An
agent with runs against it is not deleted, because that would delete
conversation history. A skill another agent still carries is not deleted; nor
is a server another agent still binds. Uncaught, that third case is the
quietest failure in the schema: the other agent keeps working and loses a third
of its instructions.

<p class="related"><strong>Related</strong>
<a href="https://code.claude.com/docs/en/plugins-reference">the plugin manifest
this mirrors</a> ·
<a href="agents.html#tools-are-external-and-they-are-rows">tool servers as
rows</a></p>
</details>

## What the numbers say

Two things here are only settleable by measurement, and both were measured
against a fleet of 23 fragments, 31 labelled requests and a real model.

<div class="evidence" markdown="1">
<div class="label">behaviour probe: 4 procedures, 3 arms, 5 samples per cell, one model at temperature 0</div>

```
arm                     cost        behaviour   body-only detail
bare agent              --            2/20            0/20
one listing line       ~223 chars    16/20            0/20
full body              260-503 chars 18/20           13/20
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the listing changes what the model does, and the body
makes it precise</summary>

Two of twenty to eighteen of twenty is the whole design justified in one
column: a fragment in the prompt changes what the model does, reliably, on
requests where the agent without it does the wrong thing every time.

The surprise is the middle row. A single 223-character listing line — the model
is told only that the fragment *exists* — produces sixteen of the eighteen
behaviour changes that the full body produces. What the body actually buys is
not behaviour but **specificity**: told only that a fragment about destructive
SQL existed, the model proposed the statement and declined to run it, which is
correct, and never asked for the primary-key predicate the body requires.

Per character, the index is the most efficient instruction-carrier in the
design, which is what sets the defaults: `index` is `bound` and `top_k` is 2
rather than 3. **Index everything, expand few.**

The index is also the one cost that grows with the surface — one line per
attached fragment, every turn — and it is worth knowing where that turns.
Listing the unexpanded fragments beats expanding all of them exactly when a
body is longer than its own listing. A fragment terser than its own description
should be always-on rather than lazy: cheaper to have than to advertise.

A rule about authoring follows, and it is measured rather than stylistic: write
the description as an instruction, because that is what the model acts on.
*"When a LOOKUP returns nothing, use FUZZY LOOKUP instead of guessing another
spelling"* is a complete instruction in 96 characters and scored 5 out of 5
with no body at all. A description written as a label — *"about name
resolution"* — would have scored none of that.

<p class="related"><strong>Related</strong>
<a href="https://github.com/percolating-sirsh/p8-subsystems/blob/main/specs/agentic/plugins.md">the
spec, with every number and what it does not settle</a></p>
</details>

## Why a row rather than a file

Everything on this page exists in the standard already. What changes when the
substrate is a database rather than a directory is worth stating plainly,
because it is the only reason to have done it differently.

<details class="why" markdown="1">
<summary>Why it works — five things a file tree cannot do, each of which we got
for free from machinery that was already here</summary>

**Access control is the same access control.** A skill is shared configuration
under a policy, on the same row-level security every other table in this system
uses. A directory's answer is filesystem permissions on the machine running the
agent, which is not an answer at all once the agent is a service.

**One write path can refuse a bad skill.** `upsert_skill` bumps a version when
the text changes and not when a tag does; `upsert_agent` refuses a fragment
that does not exist, or one whose declared tool dependency the agent does not
bind. A file tree has no moment at which to check either, so both become review
comments.

**Retrieval was already built.** Finding the right fragment among a thousand is
the same problem as finding the right chunk among a million, and it is the same
`SEMANTIC` and `TEXT` machinery, over a corpus registered the same way. Nothing
was added to search skills.

**Provenance is a column.** The version that was expanded is recorded on the
run that used it, so a run whose answer rests on a procedure since rewritten is
reconstructable. Without it nothing downstream can even detect it is looking at
the wrong text.

**Installing and uninstalling are transactions.** A plugin applies as one
statement and prunes what it no longer declares, with referential checks that a
directory has no place to put.

The general point is the one this whole system keeps making. Because agents,
tools, workflows and identity are all already rows, a new idea usually does not
need new machinery — it needs a table and the machinery that is already there.
Skills are a good test of that claim, because the standard they come from was
designed for a filesystem and lost nothing on the way in.

<p class="related"><strong>Related</strong>
<a href="index.html">what "Postgres is the system" buys and costs</a> ·
<a href="agents.html">agents as rows</a></p>
</details>

## Where this page stands

The schema is installed and every statement on this page runs against it:
`upsert_skill`, `attach_skill`, `detach_skill`, `apply_plugin` and the views
they read through, verified on a clean install with the collection's surface
audit passing. The lost-update comparison, the assembled-prompt accounting, the
retrieval scores and the behaviour probe are all captured output from a live
database and a live model, not illustrations.

One thing this page does *not* claim: that any of it runs on pydantic-ai's
deferred loading. It does not. The path that would use it is the gateway, where
a model asks for a fragment by name — and that path is specified and not yet
built.

Two things are honest gaps rather than omissions. The behaviour probe is four
procedures against one model, which is enough to separate 2/20 from 16/20 and
nowhere near enough to separate 16/20 from 18/20 — and that second comparison
is what the `top_k` recommendation leans on. And the fetched path, where a
model asks for a fragment by name through a gateway, is specified and not
measured: instructions arriving as a tool result are probably followed less
reliably than instructions in a prompt, and that "probably" is still judgement.

Next: [agents](agents.html), which is the row these fragments attach to, and
where the tool servers they depend on are registered.
