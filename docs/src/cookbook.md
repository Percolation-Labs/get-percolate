# Ten things, worked through

Ten scenarios against one small domain, one capability at a time, each with the
output it actually produced. This is the page for finding out what a single move
does and what it gives you back.
{: .lede }

Everything below was run against a live PostgreSQL 19 with the extension
installed, and the tables are pasted from the transcript rather than typed out
from what the query ought to return. You can reproduce all of it in about a
minute, and the last section says how.

If you came looking for whole pipelines rather than single moves, this is the
wrong page and [workflow recipes](recipes.html) is the right one. The two divide
the work deliberately: this page answers *what does `GRAPH` return*, and that one
answers *how do I poll a source into a corpus an agent can be asked about*.

## The domain

One fixture, reused by all ten. It is a port-operations company with two
shipping lines in it: **Meridian Line**, which has a bulk subsidiary and three
ships, and **Kestrel Shipping**, which has one. There are three ports belonging
to neither, a chartering house both of them use, four inspection records, and
five short inspection reports.

```
harbour fixture: 4 operators, 5 vessels, 3 ports, 4 inspections,
                 11 nodes, 9 edges, 5 chunks
```

Two tenants matter more than the ships do. Almost every example below is the
same query asked twice with a different claim, and the answers differ because
row-level security is doing the work rather than a `where org_id =` somebody
remembered to write.

<details class="why" markdown="1">
<summary>Why it works — five vessels but eleven nodes, and the missing one is
deliberate</summary>

One of the ships is scrapped, and the registration that projects vessels into
the graph carries `include_where => n.status <> 'scrapped'`. The row is still
there in `harbour.vessels`; it is simply not an identity anybody can look up.

That is the inclusion policy doing its job. The node registry is a curated
index over a subset of your data — things worth resolving by name, plus edge
endpoints — rather than a copy of the data plane, which is what keeps it small
enough to be a lookup rather than a second database.

<p class="related"><strong>Related</strong>
<a href="query.html">what becomes a node, and how</a> ·
<a href="grammar-p8ql.html">the query grammar these all use</a></p>
</details>

## 1. Resolve a name somebody half-remembered

This is the question an agent asks first, and it almost never arrives with the
right spelling.

What we are trying to do here is find a vessel from a misspelled name, and then
make the right spelling cheap for next time.
{: .goal }

```sql
select aiq.query('LOOKUP "meridien dawn"');       -- 0 rows
select aiq.query('FUZZY LOOKUP "meridien dawn" LIMIT 3');
```

<div class="evidence" markdown="1">
<div class="label">aiq.query</div>

```
      key      | entity_type | score | match_kind
---------------+-------------+-------+------------
 meridian dawn | vessel      | 0.647 | fuzzy
 meridian      | operator    | 0.353 | fuzzy
```
</div>

```sql
select aiq.add_node_key('Meridian Dawn', 'dawn', 'short');
select aiq.query('LOOKUP "dawn"');
```

<div class="evidence" markdown="1">
<div class="label">aiq.query</div>

```
 key  | entity_type | match_kind
------+-------------+------------
 dawn | vessel      | short
```
</div>

<details class="why" markdown="1">
<summary>Why it works — `LOOKUP` searches keys, and a short key is an editorial
act</summary>

The lookup answers from the node registry rather than from any of the tables the
keys came from, which is why one query resolves a vessel and an operator in the
same breath — they are different tables and the same kind of identity.

Exact spelling returns nothing and `FUZZY` returns the ship plus the operator
behind it at a lower score. If you know the shape of the names in your store you
can skip the fuzz entirely by registering a short key, and nothing projects those
for you deliberately: deciding that "dawn" means that ship is a judgement, not a
derivation, and a system that guessed would eventually guess wrong in a way
nobody could see.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#resolving-a-name-you-are-not-sure-of">why `FUZZY` is
a prefix</a> ·
<a href="query.html">the node registry</a></p>
</details>

## 2. Walk the ownership chain, and find a neighbour on the way

What we are trying to do here is answer two questions from one walk: who
ultimately operates this ship, and what else was in the same port.
{: .goal }

```sql
select aiq.query('GRAPH "Bulk Harmony" DEPTH 2');
```

<div class="evidence" markdown="1">
<div class="label">aiq.query</div>

```
 depth |   type   |           summary           |               path               | weight
-------+----------+-----------------------------+----------------------------------+--------
 1     | port     | Rotterdam, Netherlands      | ["last_called"]                  |   1.00
 1     | operator | Meridian Bulk               | ["operated_by"]                  |   1.00
 2     | vessel   | Meridian Dawn (IMO 9331802) | ["last_called", "last_called"]   |   1.00
 2     | operator | Meridian Line               | ["operated_by", "subsidiary_of"] |   0.95
```
</div>

```sql
select aiq.query('GRAPH "MERB" DEPTH 2 TYPE subsidiary_of');
```

<div class="evidence" markdown="1">
<div class="label">aiq.query</div>

```
 depth |    summary
-------+---------------
 1     | Meridian Line
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the path column finds relationships nobody stored, and
the weight says how much to believe them</summary>

Two rows in that table are worth slowing down for.

The depth-2 row with `["last_called", "last_called"]` is a different ship,
reached by going out to Rotterdam and back in again. Nobody stored a
"sibling" relationship; the walk found it, and the path is what tells you it is
derived rather than asserted.

The ownership row carries a weight of 0.95 rather than 1.00 because the
subsidiary claim came from a registry rather than from a filing, and
`edges.weight` is where that kind of confidence lands. It is a static number,
which is a known limitation — a claim asserted two years ago weighs the same as
one asserted this morning.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#walking-out-from-a-node">why `TYPE` narrows the walk
rather than its result</a> ·
<a href="query.html">the edge catalogue</a></p>
</details>

## 3. Three ways to find the same page

The corpus is written so the three retrieval modes disagree, because a corpus
where they agree cannot show you why there are three. One report carries a rare
inspection code verbatim; another says the same thing in different words and
carries none of them.

What we are trying to do here is find the same page lexically, semantically, and
by fusing both, and watch the ranking change.
{: .goal }

```sql
select aiq.query('TEXT "PSC-441" FROM chunks LIMIT 3');
```

<div class="evidence" markdown="1">
<div class="label">TEXT — lexical, no embedding anywhere</div>

```
 score  |                         content
--------+----------------------------------------------------------
 0.0991 | Port state control at Rotterdam raised deficiency PSC-44
 0.0991 | Meridian internal: PSC-441 exposure now covers two vesse
```
</div>

```sql
select round((r->>'distance')::numeric,3) as distance, left(c.content,56) as content
from jsonb_array_elements(
       aiq.query('SEMANTIC "a boiler fault" FROM chunks LIMIT 3',
                 '[0,0,0.707,0.707]')->'rows') r
join content.resource_chunks c on c.id = (r->>'chunk_id')::uuid
order by 1;
```

<div class="evidence" markdown="1">
<div class="label">SEMANTIC — the vector is an argument</div>

```
 distance |                         content
----------+----------------------------------------------------------
    0.000 | The secondary steam generator was found unserviceable an
    0.010 | Meridian internal: PSC-441 exposure now covers two vesse
    0.055 | Port state control at Rotterdam raised deficiency PSC-44
```
</div>

```sql
select aiq.query('SEARCH "PSC-441 boiler" FROM chunks LIMIT 3', '[0,0,0.707,0.707]');
```

<div class="evidence" markdown="1">
<div class="label">SEARCH — both rankings, fused</div>

```
 lex | sem |   rrf   |                       content
-----+-----+---------+------------------------------------------------------
 1   | 3   | 0.03227 | Port state control at Rotterdam raised deficiency PS
     | 1   | 0.01639 | The secondary steam generator was found unserviceabl
     | 2   | 0.01613 | Meridian internal: PSC-441 exposure now covers two v
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the winner is first on one ranking and third on the
other, and neither alone would have found it</summary>

The nearest semantic hit shares not one word with "a boiler fault", which is
exactly the case `TEXT` cannot reach. Meanwhile `TEXT` finds the rare token
`PSC-441` that a vector will happily rank alongside a dozen near-synonyms.

Fusion is what lets a page found by only one of the two still place. Rows with an
empty `lex` were never matched lexically at all and placed on their semantic
rank alone.

`SEMANTIC` returns refs rather than content, which is why the middle query joins
back to read them — the vector table holds `chunk_id` and an embedding, and
carrying the text through the ranking would mean copying the corpus into every
result.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#the-three-search-modes-and-why-there-are-three">why
the database takes the vector as an argument</a> ·
<a href="grammar-workflow.html#a-vector-query-is-two-tasks">how a workflow writes
the embed step for you</a></p>
</details>

## 4. Two tenants, one table

What we are trying to do here is run the same query under two different claims
and see the answers differ, with nothing in the query filtering by organisation.
{: .goal }

```sql
set local role authenticated;
set local request.jwt.claims = '{"orgs":["…000a"]}';   -- Meridian
select entity_type, summary from aiq.nodes
where entity_type in ('vessel','operator') order by entity_type, summary;
```

<div class="evidence" markdown="1">
<div class="label">as Meridian</div>

```
 entity_type |           summary
-------------+-----------------------------
 operator    | Meridian Bulk
 operator    | Meridian Line
 operator    | Nordvik Chartering
 vessel      | Bulk Harmony (IMO 9407711)
 vessel      | Meridian Dawn (IMO 9331802)
 vessel      | Meridian Star (IMO 9331803)
```
</div>

<div class="evidence" markdown="1">
<div class="label">the same statement, as Kestrel</div>

```
 entity_type |           summary
-------------+------------------------------
 operator    | Kestrel Shipping
 operator    | Nordvik Chartering
 vessel      | Aurora Kestrel (IMO 9214578)
```
</div>

<details class="why" markdown="1">
<summary>Why it works — RLS reorders results, it does not only remove rows</summary>

Nordvik appears in both because its `org_id` is null, and the three ports are
visible to everyone for the same reason. A shared tier is a real category rather
than a gap in the policy: without it, every tenant would need a private copy of
Rotterdam.

The part worth checking by behaviour rather than by reading the policy is that a
name does not resolve at all. `select count(*) from aiq.lookup('Meridian Dawn')`
returns 0 as Kestrel — because a key that matches and then returns nothing looks
identical to a key that does not exist, and only one of those is safe.

Now go back to the `SEARCH` in scenario 3 and run it as Kestrel:

<div class="evidence" markdown="1">
<div class="label">SEARCH, as Kestrel</div>

```
 lex | sem |                       content
-----+-----+------------------------------------------------------
 1   | 2   | Port state control at Rotterdam raised deficiency PS
     | 1   | The secondary steam generator was found unserviceabl
```
</div>

The winner's semantic rank moved from 3 to 2, because the Meridian note that
outranked it is not there for this caller. Row-level security is inside the
ranking, not a filter applied after it.

<p class="related"><strong>Related</strong>
<a href="operating.html">the two things that make results look "missing"</a> ·
<a href="recipes.html#keys-are-names-never-values">how a service presents a
caller's identity</a></p>
</details>

## 5. A file becomes answerable

What we are trying to do here is register bytes that live in object storage,
record what they say, and have them searchable with no reindex step.
{: .goal }

```sql
select content.register_upload(
    p_channel      => 'harbour-reports',
    p_checksum     => 'sha256:6f1a9c',
    p_bucket       => 'harbour',
    p_object_key   => 'psc/2026/gothenburg-9214578.pdf',
    p_size_bytes   => 48213,
    p_content_type => 'application/pdf',
    p_title        => 'Gothenburg PSC report',
    p_org_id       => '…000a',
    p_external_id  => 'psc-2026-018');

select content.record_chunks(:resource_id, $j$[
  {"ordinal":0,"content":"Gothenburg PSC inspection found the auxiliary boiler within tolerance.","start_char":0,"end_char":69},
  {"ordinal":1,"content":"No deficiencies were recorded against Aurora Kestrel on this call.","start_char":70,"end_char":135}
]$j$::jsonb);
```

<div class="evidence" markdown="1">
<div class="label">TEXT "auxiliary boiler" FROM chunks — immediately afterwards</div>

```
 score  |                       content
--------+------------------------------------------------------
 0.0608 | Gothenburg PSC inspection found the auxiliary boiler
```
</div>

<details class="why" markdown="1">
<summary>Why it works — there are two dedup keys and they do different jobs</summary>

Neither call needs the bytes in Postgres. The file lives in object storage and
the row carries the bucket and key.

The checksum dedups the **bytes** in `content.files`; `external_id` dedups the
**registration** in `content.resources`. Register the same upload twice with the
same `external_id` and you get the same resource back. Register it twice with no
`external_id` and you get two resources over one file, which means the ingestion
runs twice:

<div class="evidence" markdown="1">
<div class="label">registering twice with no external_id</div>

```
 same_resource | same_file
---------------+-----------
 f             | t
```
</div>

So pass an `external_id` whenever the upload might be retried, and treat it as
the caller's idempotency key. That is the same property recipe 1 leans on for a
poller.

Two tenants uploading the same public PDF get one object and two resources,
which is correct: they each uploaded a thing, with their own title, org and
lifecycle, that happens to share bytes.

<p class="related"><strong>Related</strong>
<a href="ingest.html">what the ingestion pipeline does with it next</a> ·
<a href="recipes.html#1-bring-a-source-in">the same idempotency key in a
poller</a></p>
</details>

## 6. A workflow with nothing running

What we are trying to do here is run a three-step pipeline that has already
finished by the time `start_workflow` returns.
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
<div class="label">workflow.tasks</div>

```
 step_key | kind | status |   worker    | rows_out
----------+------+--------+-------------+----------
 fleet    | sql  | done   | in-database |        4
 operator | sql  | done   | in-database |        1
 reports  | sql  | done   | in-database |        2
```
</div>

<details class="why" markdown="1">
<summary>Why it works — and the one trap that reports success</summary>

Both step kinds here are in-database, so each executes inside the transaction
that makes it ready. There is no queue to poll and no process to deploy, and the
rows land on the task, so the graph walk the middle step did is readable
straight out of `workflow.tasks.output`.

The trap is worth knowing before you write these. A `p8ql:` step holding a
*dialect* query executes and returns rows, as above. A `p8ql:` step holding
**plain SQL** does not execute, and the task still goes `done`:

<div class="evidence" markdown="1">
<div class="label">workflow.tasks.output</div>

```
 status | mode |                               note
--------+------+------------------------------------------------------------------
 done   | SQL  | execute via the SECURITY INVOKER read-only passthrough, not here
```
</div>

Plain SQL goes through `aiq.sql_passthrough`, which runs as the caller rather
than as the definer, and a step has no caller to be. Treat a step whose output
carries that note as a step that did not do what its author meant. If you want
SQL in a workflow, register a function and use `sql: {function: …}`, which is
scenario 7.

<p class="related"><strong>Related</strong>
<a href="grammar-p8ql.html#plain-sql-is-a-mode">the passthrough, and why SQL is
sniffed rather than announced</a> ·
<a href="grammar-workflow.html#queries-that-need-no-process">the in-database
step kinds</a></p>
</details>

## 7. Fan out over a query result

What we are trying to do here is turn one authored step into one task per
vessel with an open deficiency, without deciding the width outside the database.
{: .goal }

```yaml
  - id: fan
    matrix:
      max_fanout: 50
      rows: {function: deficient_vessels}
      template:
        p8ql: 'LOOKUP "{{item.vessel}}"'
```

<div class="evidence" markdown="1">
<div class="label">workflow.tasks — two vessels had open deficiencies</div>

```
 step_key |  kind  | status |   worker
----------+--------+--------+-------------
 fan      | matrix | done   | in-database
 fan[0]   | sql    | done   | in-database
 fan[1]   | sql    | done   | in-database
 report   | sql    | done   | in-database
```
</div>

<div class="evidence" markdown="1">
<div class="label">each child carries its own row under {{item}}</div>

```
    vessel     |  code   | resolved
---------------+---------+-----------
 Bulk Harmony  | PSC-441 | canonical
 Meridian Dawn | PSC-441 | canonical
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the expansion is a transaction, and the ceiling is
mandatory</summary>

The children are inserted by the statement that completes the parent, so nothing
outside the database decides the width and there is no window where the parent
is `done` and the children do not exist.

`rows:` names a function in the `workflow.step_functions` allow-list rather than
taking an inline `SELECT`, so a workflow document cannot smuggle arbitrary SQL
past the compiler. Registering one is the price of that, and it is also where
the query deciding the fan-out width lives.

Leave out `max_fanout` and the compiler refuses the document with the reason:

<div class="evidence" markdown="1">
<div class="label">define_yaml</div>

```
ERROR: workflow YAML did not compile: matrix step 'fan' declares no
`max_fanout`. A matrix needs a ceiling: a cross join with a forgotten WHERE
expands to the cartesian product, and that should fail this step rather than
the database.
```
</div>

The rows live on the children rather than on the parent, so five thousand of
them do not have to fit in one payload — which is also why a fan-in reads a
handle rather than a value.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#matrix-the-work-to-do-is-a-query-result">every
matrix key</a> ·
<a href="outputs.html">why the fan-in reads handles</a> ·
<a href="failure.html#fan-out-and-partial-failure">surviving a failed child</a></p>
</details>

## 8. Wait for a person, or for a clock

A detention decision belongs to the harbourmaster, and the run should sit there
until they make it.

What we are trying to do here is hold a run open through a cooling-off period
and then a human decision, with no process doing the waiting.
{: .goal }

```yaml
  - id: cooling_off
    needs: [notice]
    timer: 3600
  - id: approve
    needs: [cooling_off]
    signal: true
```

<div class="evidence" markdown="1">
<div class="label">immediately after start_workflow — the timer is holding it</div>

```
  step_key   |  kind  | status  | still_waiting
-------------+--------+---------+---------------
 approve     | signal | pending | f
 cooling_off | timer  | ready   | t
 notice      | sql    | done    | f
 release     | sql    | pending | f
```
</div>

```sql
select workflow.signal_task(:run_id, 'approve',
    '{"decision":"released","by":"harbourmaster"}'::jsonb);
```

<div class="evidence" markdown="1">
<div class="label">after the signal</div>

```
  step_key   |  kind  | status
-------------+--------+--------
 approve     | signal | done
 cooling_off | timer  | done
 notice      | sql    | done
 release     | sql    | done
```
</div>

<details class="why" markdown="1">
<summary>Why it works — `waiting_external` is the status that means a person is
the dependency</summary>

`workflow.promote_due_timers()` is what a clock calls, and after it runs the
signal step moves to `waiting_external`. The only thing that moves it from there
is `signal_task`.

That function checks who you are, and a run with no owner is not owned by
everyone. It takes an explicit permission, so the run has to have been started
by somebody for the harbourmaster to be able to sign it off — which is also why
a scheduled run carries the schedule's owner rather than being unowned.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#control-steps-waiting-for-a-clock-a-person-or-a-child">the
control steps</a> ·
<a href="recipes.html#6-a-pipeline-that-waits-for-a-person">the same shape with
an agent drafting the notice</a></p>
</details>

## 9. Undo the steps that already worked

A berth is booked, a pilot is booked, and then the tide window is missed. Two
things have to be given back in the reverse of the order they were taken.

What we are trying to do here is roll back the parts of a booking that
succeeded, after a later step fails terminally.
{: .goal }

```yaml
  - id: reserve_berth
    p8ql: 'LOOKUP "Rotterdam"'
    compensate_with: release_berth
    saga_group: booking
  - id: book_pilot
    needs: [reserve_berth]
    p8ql: 'LOOKUP "MERI"'
    compensate_with: cancel_pilot
    saga_group: booking
```

<div class="evidence" markdown="1">
<div class="label">before anything fails — the compensations are not tasks yet</div>

```
   step_key    |   kind    | status
---------------+-----------+--------
 book_pilot    | sql       | done
 confirm_tide  | http_call | ready
 reserve_berth | sql       | done
```
</div>

<div class="evidence" markdown="1">
<div class="label">after begin_compensation</div>

```
                      step_key                      |   kind    | status
----------------------------------------------------+-----------+--------
 book_pilot                                         | sql       | done
 cancel_pilot:1d05408d-98c4-4b96-9d08-cb63dd0b166d  | sql       | done
 confirm_tide                                       | http_call | failed
 release_berth:e765c77e-87e1-4be6-ade7-096c551af57b | sql       | done
 reserve_berth                                      | sql       | done
```

```
 status | compensation_state
--------+--------------------
 failed | compensated
```
</div>

<details class="why" markdown="1">
<summary>Why it works — two columns, because there are two questions</summary>

The run ends `failed` with `compensation_state = compensated`, and those are
separate columns deliberately. A saga that rolled back cleanly still did not do
what it was asked, and a run reporting `succeeded` because its cleanup worked is
a run nobody investigates.

Compensations are ordinary tasks, so they inherit retries, backoff and the audit
trail — and they stay out of the forward graph, so a compensation cannot
accidentally satisfy a forward dependency.

<p class="related"><strong>Related</strong>
<a href="failure.html#saga-compensation">the compensation ordering</a> ·
<a href="recipes.html#7-undo-what-already-happened">the same shape over real
external calls</a></p>
</details>

## 10. An agent is a row

What we are trying to do here is register an agent and the tool server it calls,
with no class, no decorator and nothing to deploy.
{: .goal }

```sql
select agentic.upsert_tool_server($j${
  "name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090",
  "emits_citations": true,
  "cached_tools": [{"name": "query"}, {"name": "schema"}]
}$j$::jsonb);

select agentic.upsert_agent($j${
  "name": "harbourmaster",
  "model": "anthropic:claude-sonnet-5",
  "system_prompt": "You answer questions about the fleet. Start with SCHEMA…",
  "tools": [{"server": "harbour-query", "tools": ["query"]}]
}$j$::jsonb);
```

<div class="evidence" markdown="1">
<div class="label">the binding</div>

```
     agent     |    server     | allowlist
---------------+---------------+-----------
 harbourmaster | harbour-query | ["query"]
```
</div>

<details class="why" markdown="1">
<summary>Why it works — registration and re-sync are the same call, so
correcting a URL cannot throw away discovery</summary>

A tool server is a row naming an endpoint, and an agent is a row naming that
server plus an allowlist of tools on it. The allowlist is a list: `"tool":
"query"` is stored here without complaint and then dropped by the runtime,
leaving the agent with no allowlist at all — which means every tool the server
exposes. Re-running the upsert with a corrected URL keeps what discovery
found:

<div class="evidence" markdown="1">
<div class="label">tools after re-sync</div>

```
           tools_after_resync
-----------------------------------------
 [{"name": "query"}, {"name": "schema"}]
```
</div>

Sessions and runs are rows too, which is what makes a conversation something you
can query rather than something in a log:

<div class="evidence" markdown="1">
<div class="label">agentic.sessions</div>

```
 status  | trigger_kind |           title
---------+--------------+----------------------------
 running | interactive  | Aurora Kestrel PSC history
```
</div>

Registering the agent and opening the session are two different actors, and the
examples run them that way. Registering needs `agents:update`, which a migration
has and a person usually does not; opening a session needs a user, because
`agentic.sessions.user_id` is not nullable.

<p class="related"><strong>Related</strong>
<a href="agents.html">the rest of what an agent row holds</a> ·
<a href="recipes.html#agents-and-tool-servers-are-rows">the omitted-key rule
that makes an upsert safe</a></p>
</details>

## Running all of it

The fixture and the ten scripts live in `dev/examples/` in the specs repository.

What we are trying to do here is get back to a known state and run any subset of
the ten against it.
{: .goal }

```bash
cd dev/examples
./run.sh          # the fixture, then all ten
./run.sh 07       # just the fan-out
DSN="postgres://…" ./run.sh
```

<details class="why" markdown="1">
<summary>Why it works — each example rolls back, so they are order-independent</summary>

Every example runs in its own transaction and rolls back, which is what makes
them safe to run in any order and as many times as you like. The fixture is
idempotent, and re-running it is how you get back to a known state.

<p class="related"><strong>Related</strong>
<a href="install.html">getting a database to run them against</a> ·
<a href="recipes.html">the same primitives assembled into pipelines</a></p>
</details>

If you want to go deeper on any one of these, [the P8QL grammar](grammar-p8ql.html)
and [the workflow grammar](grammar-workflow.html) are the references,
[querying](query.html) covers the dialect as prose, and
[uploading files](ingest.html) covers what happens between `POST /files` and a
chunk that answers a question.

And if you now want these ten assembled into things worth deploying — a source
polled on a clock, a backlog through a specialist extractor, a question answered
by an agent over your own corpus — that is [workflow recipes](recipes.html).
