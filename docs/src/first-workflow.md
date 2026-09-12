# Your first workflow

A workflow is a document. `define_yaml` compiles it into rows and
`start_workflow` runs it, and because both are ordinary SQL functions you do not
need anything running in order to define one.
{: .lede }

## The smallest one that does something

What we are trying to do here is define and run a workflow with nothing deployed
anywhere.
{: .goal }

<!-- run: sql -->
```sql
select workflow.define_yaml($$
name: hello
steps:
  - id: now
    sql: {function: p8ql, args: ['SELECT now()']}
$$);

select workflow.start_workflow('hello', '{}'::jsonb) as run \gset
```

`\gset` puts the run id in a `psql` variable, because the next thing you will
want is to look at it and the id is the only handle you get.

<details class="why" markdown="1">
<summary>Why it works — the run has already finished by the time
`start_workflow` returns</summary>

A `sql` step becomes ready as soon as the things it depends on are satisfied,
and then executes inside Postgres in that same transaction. There is no worker
involved anywhere, no queue to poll, and no moment where the run exists but
nothing is acting on it.

That is not a special case for trivial workflows. Any pipeline made only of
`sql` and `p8ql` steps behaves this way, however long it is.

<p class="related"><strong>Related</strong>
<a href="authoring.html#choosing-a-step-kind">why to reach for `sql` first</a> ·
<a href="cookbook.html#6-a-workflow-with-nothing-running">a three-step version
with its task table</a></p>
</details>

## A four-step one

What we are trying to do here is fetch a rate table, project it into typed rows,
fan out over the currencies it produced, and aggregate the children.
{: .goal }

The three functions the document calls are yours rather than the engine's, so
they come first. They live in a schema owned by `app_owner`, which is the role a
`sql` step runs as, and each is registered under the name the document uses:

<!-- run: sql -->
```sql
set role app_owner;
create schema if not exists fx;
create table if not exists fx.rates (
    run_id uuid, code text, rate numeric, primary key (run_id, code));

-- project: today's rates, one row per currency
create or replace function fx.project(p_run uuid, p_rates jsonb) returns jsonb
language sql as $f$
    with landed as (
        insert into fx.rates (run_id, code, rate)
        select p_run, key, value::numeric from jsonb_each_text(p_rates)
        returning 1)
    select jsonb_build_object('rows', count(*)) from landed
$f$;

-- fan: one row per watched currency, which becomes one child each
create or replace function fx.currencies(p_run uuid, p_watch jsonb) returns jsonb
language sql stable as $f$
    select coalesce(jsonb_agg(jsonb_build_object(
               'code', code, 'since', current_date - 90) order by code), '[]')
    from fx.rates where run_id = p_run and p_watch ? code
$f$;

-- volatility: 90-day coefficient of variation, read from the children
create or replace function fx.volatility(p_fan uuid) returns jsonb
language sql stable as $f$
    select jsonb_object_agg(code, cv) from (
        select c->'item'->>'code' as code,
               round(stddev((day.v->>(c->'item'->>'code'))::numeric)
                     / avg((day.v->>(c->'item'->>'code'))::numeric), 4) as cv
        from jsonb_array_elements(workflow.matrix_outputs(p_fan)) c,
             jsonb_each(c->'output'->'result') as day(d, v)
        where c->>'status' = 'succeeded'
        group by 1) s
$f$;
reset role;

select workflow.register_step_function('fx_project', 'fx.project', array['uuid', 'jsonb']);
select workflow.register_step_function('fx_currencies', 'fx.currencies', array['uuid', 'jsonb']);
select workflow.register_step_function('fx_volatility', 'fx.volatility', array['uuid']);
```

Then the workflow, which asks [Frankfurter](https://frankfurter.dev) — a free
exchange-rate API that needs no key — for today's rates and then for ninety days
of each watched currency:

<!-- run: sql -->
```sql
select workflow.define_yaml($$
name: fx_daily
steps:
  - id: fetch
    queue: http
    rest:
      url: https://api.frankfurter.dev/v1/latest?from=USD
      jsonpath: rates

  - id: project
    needs: [fetch]
    sql: {function: fx_project, args: ['{{run.$id}}', '{{steps.fetch.result}}']}

  - id: fan
    needs: [project]
    matrix:
      rows: {function: fx_currencies, args: ['{{run.$id}}', '{{run.watch}}']}
      max_fanout: 20
      template:
        queue: http
        rest:
          url: 'https://api.frankfurter.dev/v1/{{item.since}}..?from=USD&to={{item.code}}'
          jsonpath: rates

  - id: volatility
    needs: [fan]
    sql: {function: fx_volatility, args: ['{{steps.fan.result.task_id}}']}
$$);

select workflow.start_workflow('fx_daily', '{"watch": ["EUR", "GBP", "JPY"]}') as run \gset
```

<div class="evidence" markdown="1">
<div class="label">select step_key, kind, status from workflow.tasks where run_id = :'run' order by created_at, step_key — 0.4 seconds after the start</div>

```
  step_key  |   kind    |  status
------------+-----------+-----------
 fan        | matrix    | succeeded
 fetch      | http_call | succeeded
 project    | sql       | succeeded
 volatility | sql       | pending
 fan[0]     | http_call | succeeded
 fan[1]     | http_call | succeeded
 fan[2]     | http_call | running
```
</div>

<div class="evidence" markdown="1">
<div class="label">the volatility task's output, a few seconds later with all seven succeeded</div>

```
{"result": {"EUR": 0.0088, "GBP": 0.0095, "JPY": 0.0155}}
```
</div>

Only two of those four steps need a process. `project` and `volatility` run
inside the database, and `fetch` and the fan-out children are outbound calls,
which is the one thing the database will not do. The children are keyed by
position rather than by value: `fan[0]` is the first row `fx_currencies`
returned, which is EUR because it orders by code, and the row itself travels
with the child as `{{item}}`.

<details class="why" markdown="1">
<summary>Why it works — three things this example teaches</summary>

**The run can see itself, behind a `$`.** `{{run.*}}` reads the input you passed
to `start_workflow` — `{{run.watch}}` above is the list you started it with —
and the run's own identity lives behind the prefix:
`{{run.$id}}` is this run's uuid, `{{run.$trace_id}}` the trace shared by every
task in it, `{{run.$session}}` a conversation id the engine mints for agent
steps. The prefix exists because plenty of payloads have a key called `id`, and
without it the same template would mean different things depending on what you
passed in. You cannot work around it by passing the run id yourself either,
since you do not have it until `start_workflow` returns.

**The row set is a query.** `matrix.rows` takes the statement itself — or a
registered function, if the deployment wants that operation blessed. `max_fanout`
is required for the same reason you would not run a query with no `LIMIT`
against a result set you have not seen.

**The fan-in reads handles, not values.** `fx_volatility` is handed the matrix
task's id, `{{steps.fan.result.task_id}}`, and reads the children through
`workflow.matrix_outputs` rather than through a template. Children do
not write into `runs.context`, because one JSONB column rewritten in full on
every completion gives you quadratic write amplification once a fan-out gets
wide.

The children also exist as rows the moment `fan` completes, with `volatility`
already depending on all of them, so there is never a moment where the fan-out
has happened and the work is not written down.

<p class="related"><strong>Related</strong>
<a href="grammar-workflow.html#templates-and-the-one-rule-that-bites">every
template namespace</a> ·
<a href="outputs.html">why a fan-in reads a handle</a> ·
<a href="cookbook.html#7-fan-out-over-a-query-result">a fan-out with its rows
captured</a></p>
</details>

## Watching a run

What we are trying to do here is find out where a run has got to, from SQL or
over HTTP.
{: .goal }

<!-- run: sql -->
```sql
-- once per psql session: read as the administrator install.md created
select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'me@example.com'))::text, false);

select status, count(*) from workflow.tasks_api where run_id = :'run'::uuid group by 1;
select * from workflow.runs_api where id = :'run'::uuid;
```

`:'run'` with the quotes, not `:run` — psql interpolates a bare `:run` as a raw
token and a uuid is not one, so the unquoted form is a syntax error rather than
an empty result. It comes from the `\gset` above; if you have started a new
shell since then, start another run rather than hunting for the id, because
`workflow.definitions` is not readable by an application role and there is no
by-name lookup for a run.

**These need an identity, and say nothing when there isn't one.** Both are
RLS-filtered, so without the `set_config` line — or on an install where
`rbac.bootstrap_admin` has not run yet — they return zero rows rather than an
error, which looks identical to a run that never happened. The line puts in
the `psql` session the same claim a bearer token carries over HTTP; making the
administrator ([install](install.html#the-first-user-and-a-token)) does not do
it for you, because a `psql` session carries no claims of its own. Being a
superuser does not help either, because RLS on a view is evaluated as the
view's owner — `api_viewer`, which is deliberately neither the table owner nor
a superuser. `workflow.runs` itself is not filtered, if you want to confirm the
run exists before chasing identity.

<details class="why" markdown="1">
<summary>Why it works — every function in the client API is already a REST
endpoint</summary>

Both of those are RLS-filtered views, so a caller sees their own runs and not
anybody else's. Over REST they are `GET /runs_api?id=eq.<uuid>` and
`GET /tasks_api?run_id=eq.<uuid>`.

There is no generated SDK, and there is not meant to be. Every function in the
client API is a PostgREST endpoint already, which makes any HTTP-capable
language a complete client — and it means the management surface is the same one
a worker uses rather than a second, privileged path.

<p class="related"><strong>Related</strong>
<a href="operating.html">what to watch when nobody is looking</a> ·
<a href="query.html#over-rest-and-the-two-things-that-look-like-bugs">why a
result can look empty</a></p>
</details>

Next: [authoring in YAML](authoring.html), which covers how to choose between
the step kinds; [the workflow grammar](grammar-workflow.html) is the full
vocabulary.
