# Ten things, worked through

Ten scenarios against one small domain, each with the output it actually
produced. If you have read the other pages and want to see the pieces used
together rather than one at a time, this is that page.
{: .lede }

Everything below was run against a live PostgreSQL 19 with the extension
installed, and the tables are pasted from the transcript rather than typed out
from what the query ought to return. You can reproduce all of it in about a
minute, and the last section says how.

## The domain

One fixture, reused by all ten. A port-operations company with two shipping
lines in it: **Meridian Line**, which has a bulk subsidiary and three ships,
and **Kestrel Shipping**, which has one. There are three ports that belong to
neither, a chartering house both of them use, four inspection records, and five
short inspection reports.

Two tenants matter more than the ships do. Almost every example below is the
same query asked twice with a different claim, and the answers differ because
row-level security is doing the work rather than a `where org_id =` somebody
remembered to write.

```
harbour fixture: 4 operators, 5 vessels, 3 ports, 4 inspections,
                 11 nodes, 9 edges, 5 chunks
```

Five vessels and eleven nodes, because one of the ships is scrapped and the
registration that projects vessels into the graph carries
`include_where => n.status <> 'scrapped'`. The row is still there in
`harbour.vessels`; it is not an identity anybody can look up.

## 1. Resolve a name somebody half-remembered

This is the question an agent asks first, and almost never with the right
spelling. `LOOKUP` searches keys, so it answers from the node registry rather
than from any of the tables the keys came from.

```sql
select aiq.query('LOOKUP "meridien dawn"');       -- 0 rows
select aiq.query('FUZZY LOOKUP "meridien dawn" LIMIT 3');
```

```
      key      | entity_type | score | match_kind
---------------+-------------+-------+------------
 meridian dawn | vessel      | 0.647 | fuzzy
 meridian      | operator    | 0.353 | fuzzy
```

The exact spelling returns nothing and `FUZZY` returns the ship, plus the
operator behind it at a lower score. If you know the shape of the names in your
store you can skip the fuzz entirely by registering a short key, which is an
editorial act rather than a derived one and is why nothing projects them for
you:

```sql
select aiq.add_node_key('Meridian Dawn', 'dawn', 'short');
select aiq.query('LOOKUP "dawn"');
```

```
 key  | entity_type | match_kind
------+-------------+------------
 dawn | vessel      | short
```

## 2. Walk the ownership chain, and find a neighbour on the way

`GRAPH` walks relations out from a node. One walk answers two questions here:
who ultimately operates this ship, and what else was in the same port.

```sql
select aiq.query('GRAPH "Bulk Harmony" DEPTH 2');
```

```
 depth |   type   |           summary           |               path               | weight
-------+----------+-----------------------------+----------------------------------+--------
 1     | port     | Rotterdam, Netherlands      | ["last_called"]                  |   1.00
 1     | operator | Meridian Bulk               | ["operated_by"]                  |   1.00
 2     | vessel   | Meridian Dawn (IMO 9331802) | ["last_called", "last_called"]   |   1.00
 2     | operator | Meridian Line               | ["operated_by", "subsidiary_of"] |   0.95
```

Two things in that table are worth slowing down for. The row at depth 2 with
`["last_called", "last_called"]` is a different ship found by going out to
Rotterdam and back in again, which is a sibling relationship nobody stored. And
the ownership row has a weight of 0.95 rather than 1.00, because the
subsidiary claim came from a registry and `edges.weight` is where that kind of
confidence lands.

Narrow it with `TYPE` when you want the chain on its own:

```sql
select aiq.query('GRAPH "MERB" DEPTH 2 TYPE subsidiary_of');
```

```
 depth |    summary
-------+---------------
 1     | Meridian Line
```

## 3. Three ways to find the same page

The corpus is written so the three retrieval modes disagree, since a corpus
where they agree cannot show you why there are three. One report carries a rare
inspection code verbatim; another says the same thing in different words and
carries none of them.

`TEXT` is lexical and needs no embedding anywhere:

```sql
select aiq.query('TEXT "PSC-441" FROM chunks LIMIT 3');
```

```
 score  |                         content
--------+----------------------------------------------------------
 0.0991 | Port state control at Rotterdam raised deficiency PSC-44
 0.0991 | Meridian internal: PSC-441 exposure now covers two vesse
```

`SEMANTIC` takes the vector from you, since the database makes no model calls.
It returns refs rather than content, so join back to read them:

```sql
select round((r->>'distance')::numeric,3) as distance, left(c.content,56) as content
from jsonb_array_elements(
       aiq.query('SEMANTIC "a boiler fault" FROM chunks LIMIT 3',
                 '[0,0,0.707,0.707]')->'rows') r
join content.resource_chunks c on c.id = (r->>'chunk_id')::uuid
order by 1;
```

```
 distance |                         content
----------+----------------------------------------------------------
    0.000 | The secondary steam generator was found unserviceable an
    0.010 | Meridian internal: PSC-441 exposure now covers two vesse
    0.055 | Port state control at Rotterdam raised deficiency PSC-44
```

The nearest hit shares not one word with "a boiler fault", which is the case
`TEXT` cannot reach. `SEARCH` fuses both rankings, so a page found by only one
of the two still places:

```sql
select aiq.query('SEARCH "PSC-441 boiler" FROM chunks LIMIT 3', '[0,0,0.707,0.707]');
```

```
 lex | sem |   rrf   |                       content
-----+-----+---------+------------------------------------------------------
 1   | 3   | 0.03227 | Port state control at Rotterdam raised deficiency PS
     | 1   | 0.01639 | The secondary steam generator was found unserviceabl
     | 2   | 0.01613 | Meridian internal: PSC-441 exposure now covers two v
```

The winner is first on lexical rank and third on semantic, and neither ranking
alone would have put it there. Rows with an empty `lex` were never matched
lexically at all and placed on their semantic rank.

## 4. Two tenants, one table

Nothing in these queries filters by organisation. The query is the same query;
only the claim changes.

```sql
set local role authenticated;
set local request.jwt.claims = '{"orgs":["…000a"]}';   -- Meridian
select entity_type, summary from aiq.nodes
where entity_type in ('vessel','operator') order by entity_type, summary;
```

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

The same statement with Kestrel's claim:

```
 entity_type |           summary
-------------+------------------------------
 operator    | Kestrel Shipping
 operator    | Nordvik Chartering
 vessel      | Aurora Kestrel (IMO 9214578)
```

Nordvik appears in both because its `org_id` is null, and the three ports are
visible to everyone for the same reason. A shared tier is a real category here
rather than a gap in the policy; without it every tenant would need a private
copy of Rotterdam.

The part I would check by behaviour rather than by reading the policy is that a
name does not resolve at all:

```sql
select count(*) from aiq.lookup('Meridian Dawn');   -- as Kestrel: 0
```

A key that matches and then returns nothing looks identical to a key that does
not exist, and only one of those is safe.

Go back to the `SEARCH` in scenario 3 and run it as Kestrel, and the ranking
itself moves:

```
 lex | sem |                       content
-----+-----+------------------------------------------------------
 1   | 2   | Port state control at Rotterdam raised deficiency PS
     | 1   | The secondary steam generator was found unserviceabl
```

The winner's semantic rank went from 3 to 2, because the Meridian note that
outranked it is not there for this caller. Row-level security reorders results,
it does not only remove rows.

## 5. A file becomes answerable

`register_upload` records that bytes exist somewhere and `record_chunks`
records what they say. Neither needs the bytes in Postgres, since the file
lives in object storage and the row carries the bucket and key.

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

It is searchable straight away, with no reindex step to run:

```
 score  |                       content
--------+------------------------------------------------------
 0.0608 | Gothenburg PSC inspection found the auxiliary boiler
```

**There are two dedup keys and they do different jobs.** The checksum dedups
the *bytes* in `content.files`; `external_id` dedups the *registration* in
`content.resources`. Register the same upload twice with the same
`external_id` and you get the same resource back. Register it twice with no
`external_id` and you get two resources over one file, which means the
ingestion runs twice:

```
 same_resource | same_file
---------------+-----------
 f             | t
```

So pass an `external_id` whenever the upload might be retried, and treat it as
the caller's idempotency key.

## 6. A workflow with nothing running

Both steps below are in-database kinds, so the run has finished by the time
`start_workflow` returns to you. There is no queue to poll and no process to
deploy.

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

```
 step_key | kind | status |   worker    | rows_out
----------+------+--------+-------------+----------
 fleet    | sql  | done   | in-database |        4
 operator | sql  | done   | in-database |        1
 reports  | sql  | done   | in-database |        2
```

The rows are on the task, so the graph walk the middle step did is readable
straight out of `workflow.tasks.output`.

**One thing to know before you write these.** A `p8ql:` step holding a dialect
query executes and returns rows, as above. A `p8ql:` step holding *plain SQL*
does not execute, and the task still goes `done`:

```
 status | mode |                               note
--------+------+------------------------------------------------------------------
 done   | SQL  | execute via the SECURITY INVOKER read-only passthrough, not here
```

Plain SQL goes through `aiq.sql_passthrough`, which runs as the caller rather
than as the definer, and a step cannot reach it. If you want SQL in a
workflow, register a function and use `sql: {function: …}`, which is scenario 7.
I would treat a step whose output carries that `note` as a step that did not
do what its author meant.

## 7. Fan out over a query result

One authored step becomes N tasks, and the expansion happens in the transaction
that completes it. Nothing outside the database decides the width.

```yaml
  - id: fan
    matrix:
      max_fanout: 50
      rows: {function: deficient_vessels}
      template:
        p8ql: 'LOOKUP "{{item.vessel}}"'
```

`rows:` names a function in the `workflow.step_functions` allow-list rather
than taking an inline `SELECT`, so a workflow document cannot smuggle arbitrary
SQL past the compiler. Registering one is the price of that, and it is also
where the query deciding the fan-out width lives.

Leave out `max_fanout` and the compiler refuses the document with the reason:

```
ERROR: workflow YAML did not compile: matrix step 'fan' declares no
`max_fanout`. A matrix needs a ceiling: a cross join with a forgotten WHERE
expands to the cartesian product, and that should fail this step rather than
the database.
```

With it, two vessels had open deficiencies, so two children:

```
 step_key |  kind  | status |   worker
----------+--------+--------+-------------
 fan      | matrix | done   | in-database
 fan[0]   | sql    | done   | in-database
 fan[1]   | sql    | done   | in-database
 report   | sql    | done   | in-database
```

Each child carries its own row under `{{item}}`, and the rows live on the
children rather than on the parent, so five thousand of them do not have to fit
in one payload:

```
    vessel     |  code   | resolved
---------------+---------+-----------
 Bulk Harmony  | PSC-441 | canonical
 Meridian Dawn | PSC-441 | canonical
```

## 8. Wait for a person, or for a clock

A detention decision belongs to the harbourmaster, and the run should sit there
until they make it. `timer:` and `signal:` are control steps: they hold the run
open and neither needs a process to do the waiting.

```yaml
  - id: cooling_off
    needs: [notice]
    timer: 3600
  - id: approve
    needs: [cooling_off]
    signal: true
```

Immediately after `start_workflow`, the timer is what is holding the run:

```
  step_key   |  kind  | status  | still_waiting
-------------+--------+---------+---------------
 approve     | signal | pending | f
 cooling_off | timer  | ready   | t
 notice      | sql    | done    | f
 release     | sql    | pending | f
```

`workflow.promote_due_timers()` is what a clock calls, and after it runs the
signal step moves to `waiting_external`, which is the state that means a person
is the dependency. The only thing that moves it is `signal_task`:

```sql
select workflow.signal_task(:run_id, 'approve',
    '{"decision":"released","by":"harbourmaster"}'::jsonb);
```

```
  step_key   |  kind  | status
-------------+--------+--------
 approve     | signal | done
 cooling_off | timer  | done
 notice      | sql    | done
 release     | sql    | done
```

`signal_task` checks who you are, and a run with no owner is not owned by
everyone. It takes an explicit permission, so the run has to have been started
by somebody for the harbourmaster to be able to sign it off.

## 9. Undo the steps that already worked

A berth is booked, a pilot is booked, and then the tide window is missed. Two
things have to be given back in the reverse of the order they were taken.

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

Before anything fails there are three tasks, and the two compensations are not
among them:

```
   step_key    |   kind    | status
---------------+-----------+--------
 book_pilot    | sql       | done
 confirm_tide  | http_call | ready
 reserve_berth | sql       | done
```

Fail the tide check terminally, call `begin_compensation`, and the two undo
steps are created and run:

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

The run ends `failed` with `compensation_state = compensated`, and those are
two separate columns because they answer two separate questions. A saga that
rolled back cleanly still did not do what it was asked.

## 10. An agent is a row

No class, no decorator, nothing to deploy. A tool server is a row naming an
endpoint, and an agent is a row naming tools on it by name.

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
  "tools": [{"server": "harbour-query", "tool": "query"}]
}$j$::jsonb);
```

```
     agent     |    server     | tool
---------------+---------------+-------
 harbourmaster | harbour-query | query
```

Registration and re-sync are the same call, so correcting the url later must
not throw away what discovery found:

```
           tools_after_resync
-----------------------------------------
 [{"name": "query"}, {"name": "schema"}]
```

Sessions and runs are rows too, which is what makes a conversation something
you can query rather than something in a log:

```
 status  | trigger_kind |           title
---------+--------------+----------------------------
 running | interactive  | Aurora Kestrel PSC history
```

Registering the agent and opening the session are two different actors, and the
examples run them that way. Registering needs `agents:update`, which a
migration has and a person usually does not; opening a session needs a user,
because `agentic.sessions.user_id` is not nullable.

## Running all of it

The fixture and the ten scripts live in `dev/examples/` in the specs
repository. Against the compose stack:

```bash
cd dev/examples
./run.sh          # the fixture, then all ten
./run.sh 07       # just the fan-out
DSN="postgres://…" ./run.sh
```

Each example runs in its own transaction and rolls back, so they are
order-independent and you can run them as many times as you like. The fixture
is idempotent and re-running it is how you get back to a known state.

If you want to go deeper on any one of these, [Querying](query.md) covers the
dialect properly, [Authoring in YAML](authoring.md) covers the step kinds and
what the compiler refuses, and [Uploading files](ingest.md) covers what happens
between `POST /files` and a chunk that answers a question.
