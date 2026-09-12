# Using the UI

The Percolate workbench lets you turn a task into a saved workflow, try it with
real data, inspect the results and schedule it to run again. Workflows combine
data sources, queries, agents and plugin capabilities. Packages carry those
definitions so you can reuse a complete job in another workspace.
{: .lede }

**The workbench ships in `percolate-core` @@core@@, and you start it
yourself.** Install the extra and run the server:

```bash
pip install 'percolate-core[ui]'
percolate ui
```

The static files are package data, so the wheel carries them; the extra is
`fastapi` and `uvicorn`, which is what serves them. The
[Compose installation](install.html#docker-compose) starts the backend
services and **does not** start a UI server — that is the one step this page
asks of you. Everything the workbench shows is also reachable over PostgREST
and SQL, which [Operating it](operating.html) uses, so nothing here is the only
route to anything.

Two things on this page are still ahead of the release: the API source editor
and AI authoring helpers, and session recovery, which need database and runtime
changes that have not landed. Each is marked where it appears.

## Open a workspace

If your operator has supplied a workbench URL, open it and choose **Sign in**.
Use **Sign in with token** with an access token issued for that deployment.
The workbench does not provide a password login or create an account for you.
An enabled local development workspace also offers **Continue to workspace**.

What we are trying to do here is connect a locally served UI to an existing
Percolate deployment.
{: .goal }

From an updated `percolate-core` checkout, install the UI extra in a Python
3.11 or later environment and start the server. These example addresses use
the Compose host ports; change them to the addresses your browser can reach.

```bash
python -m pip install -e '.[ui]'
export P8_UI_REST_URL=http://localhost:3000
export P8_UI_CORE_URL=http://localhost:8080
export P8_UI_CONTENT_URL=http://localhost:8081
export P8_UI_WORKFLOW_QUEUE=http
export P8_UI_INGEST_QUEUE=ingest
percolate ui serve --host 127.0.0.1 --port 8082
```

Open `http://localhost:8082`. In **Settings**, check the PostgREST, Agent Runtime
and Content Server endpoints, then open **Surface** to check the UI's database
reads and service connections. Endpoint changes in Settings are saved in this
browser and override the server defaults. The queue names above must match
queues that your workers consume.

<details class="why" markdown="1">
<summary>Why it works — the browser uses the system's existing interfaces</summary>

`percolate ui serve` serves static files and deployment configuration. The
browser sends authenticated requests to PostgREST for database operations, the
Agent Runtime for agent turns and the Content Server for file bytes. Those
services must share the deployment's database and JWT identity configuration.
Database grants and row policies still govern access.

For separate browser origins, configure CORS on the backends. The updated
standalone Agent Runtime and Content Server accept
`P8_CORS_ORIGINS=http://localhost:8082` in their own environments; PostgREST or
your reverse proxy also needs to allow the UI origin. A same-origin proxy is
another deployment option. Container service names such as `agent` are not
browser addresses.

Provider credentials belong on the runtime or workers. Keep
`P8_UI_DEV_TOKEN` disabled outside a throwaway local development environment:
enabling it exposes the development JWT signing secret to the browser so it
can mint sessions.

<p class="related"><strong>Related</strong>
<a href="install.html">installing the services</a> ·
<a href="operating.html#version-skew">checking version skew</a></p>
</details>

## Move between a list, an editor and a result

Listings give you a compact view of the available work. Open a source, file or
agent to focus on it; **Back to list** returns to the collection. **Expand**
gives a selected source or document more room on a wide screen. Narrow screens
show the selected item on its own.

Data Sources opens saved feeds in **Records & progress**. Use **Configuration**
to edit, **Ask AI** to review a proposal and **Package** to inspect the export.
File sources use **Data & processing** for their ingestion results.

Query has **Both**, **Editor** and **Results** controls. You can compare a query
with its results or AI review on a wide screen, then give either pane the full
width. Running a query on a narrow screen opens its results; returning to
**Editor** keeps the query. **Query help & options** contains the query guide
and semantic-search input. **Download result** is with the results.

Workflow creation offers **Design with AI**, **Definition**, **Run with inputs**
and **Package**. Saving opens the input form; **Start workflow** executes it. The example starter folds
away once a definition exists. Run details group **Results**, **Tasks**,
**Dependencies** and **History & details** so you can inspect one aspect at a
time. Failed runs open their task view.

An AI proposal has an explicit apply action. Applying it changes the draft;
saving or running remains a separate step. If you edit a query, source or
schedule after asking AI, request a fresh proposal before applying it.

## Compose a recurring brief from an API feed

Start with the job and the result it should deliver. **Workflows → Create a
workflow → Design with AI** considers the visible sources, agents, plugins,
skills, tool servers and saved workflows. **Browse workspace components** lets
you search that catalogue and select components to steer the design.

What we are trying to do here is keep a news feed current, select useful
evidence and produce a sourced brief that can run again.
{: .goal }

1. Describe the job. For example:

   > Refresh our existing news API source using its watermark, query the latest
   > eight articles, and ask an available agent for a brief with source URLs and
   > next steps. Reuse existing components and package the complete job.

2. Choose **Suggest a workflow**. Review the outcome, step dependencies and
   **Component choices**. AI can reuse existing components, propose a new API
   source or a focused agent, or ask for a missing API contract. The browser
   supplies live schema and compiles the proposed workflow. Drafting uses a
   runtime turn with tool calls and chained actions disabled.
3. Choose **Apply to draft**. This changes local work only. If the design needs
   a new source or agent, inspect its definition and choose **Create source**
   or **Create agent**. Each creation has its own receipt. Existing components
   are reused unchanged. Edits made after asking AI require a fresh proposal.
4. Choose **Review definition & save**, then **Validate & save**. Saving uses
   the database's authoritative validation and opens **Run with inputs**.
   Choose **Start workflow** and inspect each task and its result in **Runs**.
5. Open **Package** to export the source, agent and workflow definitions.
   Queries are inside their workflow steps. Review **Destination requirements**:
   named tool servers, skills, plugin capabilities, provider credentials and
   worker queues may need separate configuration. The installer also needs
   permission to author the included components. Referenced existing workflows
   whose definitions cannot be exported must be installed separately. The
   requirements are also included as comments in the downloaded manifest.
6. Once the result is useful, open **Schedules → New schedule** and choose this
   workflow, inputs, timezone and overlap policy. A workflow with its own refresh
   step can ingest, query and interpret in the same recorded run.

To propose missing components, try **Propose a new agent** or **New API
workflow**. Known public examples include GitHub issues and Spaceflight News.
For a private or unfamiliar API, supply its endpoint documentation or response
shape, including stable IDs, pagination and watermark behaviour. Credentials
remain worker configuration; the composer uses references to them.

A delayed request offers **Stop waiting** and a link to its AI conversation.
Stopping the browser wait does not claim to cancel the runtime turn. After
leaving the page, use **Previous AI designs → Recover last completed design**
to review a saved proposal again. Recovery checks current components and
compiles the definition before offering Apply.

Use **Data Sources** to test or refine an ingestion contract in detail, and
**Query** to develop an individual query. **Use in workflow** opens that query
as a step in **Definition**, where you can continue composing it with other
work. It is also valid to save a query-only workflow when that completes the job.

<details class="why" markdown="1">
<summary>Why it works — ingestion progress and report execution are recorded runs</summary>

An API pull is a workflow run. Each page commits its records and continuation
together, and the committed watermark advances after all pages finish. A page
budget or HTTP failure leaves a checkpoint from which work can resume.
Timestamp overlap re-reads the boundary window, and stable IDs let repeated
records update existing rows without creating duplicates. Older versions
cannot replace newer records.

Original JSON and transformed records are retained in `content.source_records`
under their source. The ingestion transform can project and rename fields and
apply simple casts; further analysis belongs in the follow-on workflow. API
ingestion does not automatically create graph entities or embeddings.

The composed job has its own saved definition, inputs, tasks and results.
Saving a definition does not start it. When ingestion is a step of the job,
dependent queries wait for that step and agents receive their query results.
Inspect a complete run before deciding its cadence.

<p class="related"><strong>Related</strong>
<a href="query.html">query syntax and retrieval modes</a> ·
<a href="authoring.html">composing workflow steps</a> ·
<a href="outputs.html">reading task outputs</a></p>
</details>

## Reuse a data source

In **Data Sources**, open the source’s **Package** tab to review and export a
`manifest.yaml` containing the current draft's source configuration and
ingestion workflow. Review the manifest before using it in another workspace.
The package identifies the source by name under its installation owner, so
the destination can keep its own ingestion progress.

Exports include the configured initial watermark but exclude collected
records, runtime watermarks, page checkpoints, credential values and
schedules. The destination needs matching API ingestion support, a worker for
the named queue and any referenced credentials.

The current API worker supports GET JSON endpoints with watermark filters and
Link-header, next-URL, token or page-number pagination. Reference a credential
configured on the worker, with its allowed API origin, when the endpoint needs
authentication. OAuth refresh, streaming firehoses, webhooks, custom signing
and POST search require additional connector work. For an unfamiliar API,
give the AI assistant its response example and pagination contract; it does
not browse for arbitrary API documentation.

## Use agents and files within the workflow

Use **Help** for product guidance, such as “How would I build a weekly issue
triage workflow?” The help assistant explains Percolate using its workbench
guide, while **Chat** lets you try tasks with a selected agent and inspect its
tool evidence. Configure the agent's model, instructions and tools in
**Agents**, then add an agent step where your workflow needs that reasoning.

AI suggestions require a reachable Agent Runtime, a configured provider and
the `percolate_help` agent with its guide and read-only query tool. In a source
checkout, the operator can provision that helper using `dev/ui_assistant.py`
with a caller token and a model configured in the deployment. A suggestion
produces a draft for review; applying it to an editor does not execute a query,
pull an API or start a workflow.

Use **Files → Add document** when the task needs uploaded documents or pasted
text. Choose **Upload file** or **Paste text**, select a configured ingestion
source under **Processing options**, then add the content and inspect its ingestion run,
extracted text and chunks before querying it. **File & document sources** in
Data Sources configures this path, including optional embeddings and document
transformations. See [Uploading files](ingest.html) for the underlying pipeline.

## Inspect work and recover from errors

| What you need to do | Where to go |
|---|---|
| Recover from **Session expired** or **JWT expired** | Open **Account / Sign in** and use a fresh deployment access token. An enabled local development session offers **Renew session** or **Continue to workspace**. |
| Diagnose a connection failure | Check **Settings** for stale endpoint overrides, then **Surface** for failed service or database reads. Check the backend's allowed browser origin if direct API calls work but browser calls fail. |
| Understand a failed workflow | Open **Runs**, select the run and inspect the failed task, its inputs, error and retry history. Correct the cause before starting another run. |
| Find work waiting for a worker | Open **Queues & pools**, then check that a worker is consuming the task's queue. Use **Load & limits** and **Events** for capacity and execution history. |
| Investigate irrelevant agent answers | Check the selected agent's instructions and tool results. Use **Help** for product questions and ask a task agent for evidence from the relevant records. |
| Investigate missing document search results | Open **Files** and check ingestion, extracted chunks and the configured embedding model before changing the query. |

A passing Surface check confirms that the checked interfaces responded; run
the actual task to verify its provider, credentials and data. The
[operating guide](operating.html#what-to-watch) covers the database views and
audits behind these operational checks.
