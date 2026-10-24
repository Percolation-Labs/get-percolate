# Your first memory

This page goes from a running stack to a note you wrote and then found again by
asking a question in different words. It takes about four minutes, needs no
model key, and every block on it is run by CI against a fresh install, so it
is what you should expect to see.

Bring the stack up first, as [install](install.html#docker-compose) shows:
fetch `docker-compose.yml`, then `docker compose up -d`. Every command below
runs in the directory that holds that file. If you already run a Postgres on
port 5432, or have installed Percolate before, the install page's notes on
`P8_PG_PORT` and `COMPOSE_PROJECT_NAME` come first.

## Sign in

Nothing over HTTP works until there is a first user, and every call after that
carries a token for them.

Here we create the administrator and get a token for them.
{: .goal }

```bash
docker compose exec -T db psql -U p8 -d percolate \
  -c "select rbac.bootstrap_admin('me@example.com', 'a long passphrase')"
```

<!-- run: shell -->
```bash
uid=$(docker compose exec -T db psql -U p8 -d percolate -Atc \
        "select id from rbac.users where email = 'me@example.com'")
export TOKEN=$(docker compose exec -T content percolate auth token --sub "$uid")
```

The token lasts an hour; run the second block again for a new one.

<details class="why" markdown="1">
<summary>Why it works — the first user is a bootstrap, and the stack signs the
token</summary>

A fresh install has no users and no roles, because the alternative is a
default administrator with a known password. `bootstrap_admin` creates the
user and an `admin` role holding every permission the system checks, and
refuses to run a second time. The `content` container carries the `percolate`
CLI and the stack's signing secret, so it signs the token for you.

This token has no `orgs` claim, so it sees every org you belong to — none yet,
which is fine: what you write below is yours alone.

<p class="related"><strong>Related</strong>
<a href="install.html#the-first-user-and-a-token">the first user, in full</a> ·
<a href="query.html#over-rest-and-the-two-things-that-look-like-bugs">what a token's claims change</a></p>
</details>

## Teach it to read

An upload becomes searchable through an ingestion workflow, and a fresh install
has none until you install one.

Here we register the embedding model the workers carry and install the pipeline
that uses it.
{: .goal }

Run it in `psql` on the database, `docker compose exec db psql -U p8 -d
percolate`:

<!-- run: sql -->
```sql
insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, is_default)
values ('bge-small-en-v1.5', 384, 'fastembed', 'BAAI/bge-small-en-v1.5', null, true)
on conflict (name) do nothing;
select aiq.register_embedding_space('bge-small-en-v1.5');
select content.install_ingest_workflow('bge-small-en-v1.5');
```

<div class="evidence" markdown="1">
```
                   install_ingest_workflow
-------------------------------------------------------------
 ingest_file: parse, embed with bge-small-en-v1.5 in batches
```
</div>

<details class="why" markdown="1">
<summary>Why it works — the model runs on the CPU inside the ingest
worker</summary>

`bge-small-en-v1.5` runs in-process in the ingest worker through fastembed, so
there is no key and no bill. The pipeline is an ordinary two-step workflow,
parse then embed, and the database refuses to install one naming a model that
is not registered, which is why the insert comes first.

<p class="related"><strong>Related</strong>
<a href="ingest.html#installing-the-pipeline">the pipeline, and hosted models</a></p>
</details>

## Write a memory

Anything you upload is stored, chunked and embedded, and the first time you
write something it is easiest to make it a short note.

Here we write a note and upload it.
{: .goal }

<!-- run: shell -->
```bash
cat > note.md <<'EOF'
# Aurora Kestrel

The Aurora Kestrel prefers berth 7 at Rotterdam, because the crane there
handles refrigerated containers fastest.
EOF
curl -s -w '\n' http://localhost:8081/files \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: text/markdown' \
  -H 'x-p8-title: Aurora Kestrel' \
  --data-binary @note.md
```

<div class="evidence" markdown="1">
```
{"resource_id":"01a16cb9-…","checksum":"…","bytes":130}
```
</div>

The upload answers at once, and reading and embedding the note take the ingest
worker a few seconds more.

## Recall it

A memory is useful when you can find it without remembering how you wrote it.

Here we ask a question that shares only the ship's name with the note, and get
the note back.
{: .goal }

<!-- run: shell -->
```bash
Q='where does the Kestrel like to dock'
VEC=$(curl -s http://localhost:8081/embed \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg q "$Q" '{texts: [$q]}')" | jq -c '.vectors[0]')
curl -s -X POST http://localhost:3000/rpc/query \
  -H 'Content-Type: application/json' \
  -H 'Content-Profile: aiq' \
  -H "Authorization: Bearer $TOKEN" \
  -d "$(jq -n --arg q "SEARCH \"$Q\" FROM chunks LIMIT 3" --arg v "$VEC" \
        '{p_query: $q, p_embedding: $v}')" | jq '.rows[0].content'
```

<div class="evidence" markdown="1">
```
"# Aurora Kestrel\n\nThe Aurora Kestrel prefers berth 7 at Rotterdam, because the crane there\nhandles refrigerated containers fastest."
```
</div>

If it prints `null`, the worker has not finished with the note yet: wait a few
seconds and run it again. The blocks use `jq`, which most systems have; if
yours does not, install it first.

<details class="why" markdown="1">
<summary>Why it works — the database ranks, and something outside it
embeds</summary>

The database makes no model calls, so the question is embedded first, by the
Content Server's `/embed`, with the same model the note was embedded with.
`SEARCH` then fuses a lexical rank and a semantic rank inside Postgres, and row
security means you see only what your token may read. `Content-Profile: aiq`
is required: without it PostgREST looks for the function in another schema and
answers 404.

<p class="related"><strong>Related</strong>
<a href="query.html#over-rest-and-the-two-things-that-look-like-bugs">querying over REST</a> ·
<a href="grammar-p8ql.html">the P8QL grammar</a></p>
</details>

## Where to go next

The note above is a memory you wrote yourself. An agent's memory is the same
tables: [agents](agents.html) shows an agent that searches them during a
conversation, and `reflect_session` reads a finished conversation back into the
graph, each fact citing the message that said it. Both need a model key in
`.env`. The [sample](install.html#the-sample-which-nothing-loads-for-you) loads
a corpus, agents and two tenants to try them against, and
[your first workflow](first-workflow.html) puts steps around a query.
