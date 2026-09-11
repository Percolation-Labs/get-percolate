<img src="docs/assets/logo.png" alt="" width="56" align="left" hspace="12">

# Percolate — an AI workflow engine in Postgres

Percolate runs workflows, agents, and graph/semantic queries as tables,
functions and views inside PostgreSQL. A step runs the moment its
dependencies finish, in the same transaction — no external orchestrator, no
process running anywhere except for outbound HTTP.

<br clear="left">

```yaml
steps:
  - id: retrieve
    p8ql: 'SEARCH "outage causes" FROM chunks'
  - id: triage
    needs: [retrieve]
    agent: classifier
    input: '{{steps.retrieve.result}}'
    output_schema:
      type: object
      required: [verdict]
      properties: {verdict: {type: string, enum: [SAFETY, FINANCE, OTHER]}}
```

`define_yaml` compiles this to rows, `start_workflow` runs it, and `retrieve`
completes inside the database — `SEARCH` embeds the query and ranks it against
pgvector, no model call from outside.

**Docs: <https://percolation-labs.github.io/get-percolate>**

---

## Run it

### Docker Compose

```bash
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/compose/docker-compose.yml -o docker-compose.yml
echo 'OPENAI_API_KEY=sk-...' > .env      # optional: needed for embeddings and agent turns
docker compose up -d
```

Brings up Postgres 19 with the extensions, PostgREST, the outbound and
ingestion workers, the Content Server, the Agent Runtime and MinIO.

### Helm

```bash
cat > percolate-values.yaml <<EOF
secrets:
  postgresPassword: $(openssl rand -hex 24)
  authenticatorPassword: $(openssl rand -hex 24)
  workerPassword: $(openssl rand -hex 24)
  jwtSecret: $(openssl rand -hex 32)
  s3Key: $(openssl rand -hex 16)
  s3Secret: $(openssl rand -hex 24)
  openaiApiKey: "${OPENAI_API_KEY:-}"
  llmApiKey: "${OPENAI_API_KEY:-}"
EOF
helm install percolate oci://ghcr.io/percolation-labs/charts/percolate \
  --namespace percolate --create-namespace -f percolate-values.yaml
```

Plain chart, no CRDs — works directly with Flux (`HelmRelease`) or Argo CD.
Details in [`charts/percolate/README.md`](charts/percolate/README.md).

### Your own Postgres 19

```bash
curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/install.sh | sh
```

Installs the `percolate` extension (pure SQL) and `percolate_parser`
(compiled, prebuilt for linux/amd64, linux/arm64, macos/arm64) into an
existing database. See the docs for `bootstrap.sql` and role setup.

Setup, configuration, the sample dataset, and everything else:
**<https://percolation-labs.github.io/get-percolate>**

---

## License

MIT.
