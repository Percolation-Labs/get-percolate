#!/usr/bin/env python3
"""A stand-in decision model: answers Jev's request with probabilities, from Claude or any OpenAI-compatible model.

Percolate asks a decision model wherever one can decide -- which lead a walk follows, which question a fact bears on,
whether two names are one thing -- and it asks in one format, Jev's: a STATE and a map of typed QUESTIONS, each
answered with probabilities. This is a small HTTP service that speaks that format, so a deployment can decide with a
model it already has while it has no Jev key. Python 3.11+, standard library only.

    python3 standin.py                              # Claude Code (`claude -p`) on your subscription, port 8790
    python3 standin.py --backend openai \\
        --openai-url https://api.openai.com/v1 --openai-model gpt-4o-mini   # key in OPENAI_API_KEY

Then, beside get-percolate's docker-compose.yml, `P8_DECIDER=standin` in .env and `docker compose up -d`.

THE REQUEST (POST, any path; Jev's own shape):

    {"model": "standin",
     "state": <any JSON: what the questions are about>,
     "questions": {
        "<id>": {"type": "noul",   "instructions": "...", "criteria": {"true": "...", "false": "..."}},
        "<id>": {"type": "choice", "instructions": "...", "criteria": {"<option>": "<what it means>", ...}},
        "<id>": {"type": "score",  "instructions": "...", "criteria": ["<lowest level>", ..., "<highest>"]}}}

THE ANSWER:

    {"model": "standin/claude-sonnet",
     "answers": {
        "<id>": {"type": "noul",   "noul": 0.93},
        "<id>": {"type": "choice", "choice": "<option>", "probabilities": {"<option>": 0.81, ...}},
        "<id>": {"type": "score",  "score": 1.7, "probabilities": {"0": 0.1, "1": 0.2, "2": 0.7}}},
     "usage": {"input_tokens": 0, "output_tokens": 0}}

`noul` is P(yes); a choice's probabilities sum to 1 over the options named, and `choice` is the likeliest; a score's
are over the levels' indexes, lowest first, and `score` is their probability-weighted index. A model that generates
text is asked for these numbers and they are normalised here; a decision model like Jev reads them off one forward
pass. That is the difference a stand-in cannot hide: its probabilities are the model's stated confidence, not a
distribution, so measure a threshold on it before trusting one.

Each answer is cached by the whole request (in memory, and in --cache when given), so a run that is repeated asks the
model once. STANDIN_API_KEY, when set, is the bearer token a caller must present: the service spends your Claude
subscription or your API key, and Docker's host address is reachable from every container on the machine.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLE = ("You are a small decision model. You are given a state, as JSON, and typed questions about it. Answer every "
        "question with probabilities, from what the state says. Do not explain. For a `noul` question give p, the "
        "probability that the answer is yes. For a `choice` question give a probability for every option named in its "
        "criteria; they sum to 1. For a `score` question give a probability for every level, by its index from 0 "
        "(the first, lowest level); they sum to 1. Where the state does not settle a question, say so with the "
        "probabilities: spread them, or put the mass on an option that says it cannot tell.")


def schema(questions: dict) -> dict:
    """The JSON schema the backend fills: one object per question, numbers only."""
    props = {}
    for qid, q in questions.items():
        kind = q.get("type")
        if kind == "noul":
            props[qid] = {"type": "object", "properties": {"p": {"type": "number", "minimum": 0, "maximum": 1}},
                          "required": ["p"], "additionalProperties": False}
        elif kind in ("choice", "score"):
            keys = list(q["criteria"]) if kind == "choice" else [str(i) for i in range(len(q["criteria"]))]
            props[qid] = {"type": "object", "additionalProperties": False, "required": keys,
                          "properties": {k: {"type": "number", "minimum": 0, "maximum": 1} for k in keys}}
        else:
            raise ValueError(f"question {qid!r} has type {kind!r}; a question is a noul, a choice or a score")
    return {"type": "object", "properties": props, "required": list(questions), "additionalProperties": False}


def prompt(state, questions: dict) -> str:
    return ("state:\n" + json.dumps(state, indent=1, ensure_ascii=False) +
            "\n\nquestions:\n" + json.dumps(questions, indent=1, ensure_ascii=False) +
            "\n\nAnswer as one JSON object with a key per question id, as the schema says.")


def answers(raw: dict, questions: dict) -> dict:
    """The backend's numbers, normalised and shaped as Jev answers."""
    out = {}
    for qid, q in questions.items():
        got = raw.get(qid) or {}
        if q["type"] == "noul":
            out[qid] = {"type": "noul", "noul": min(max(float(got.get("p", 0.5)), 0.0), 1.0)}
            continue
        keys = list(q["criteria"]) if q["type"] == "choice" else [str(i) for i in range(len(q["criteria"]))]
        ps = {k: max(float(got.get(k, 0.0)), 0.0) for k in keys}
        total = sum(ps.values()) or 1.0
        ps = {k: round(v / total, 4) for k, v in ps.items()}
        if q["type"] == "choice":
            out[qid] = {"type": "choice", "choice": max(ps, key=ps.get), "probabilities": ps}
        else:
            out[qid] = {"type": "score", "score": round(sum(int(k) * v for k, v in ps.items()), 4),
                        "probabilities": ps}
    return out


class Claude:
    """Headless Claude Code on the subscription: no tools, no settings files, no session kept."""

    def __init__(self, model: str, timeout: float):
        self.model, self.timeout, self.cwd = model, timeout, tempfile.mkdtemp(prefix="standin-")
        self.name = f"standin/claude-{model}"

    def __call__(self, state, questions: dict) -> dict:
        cmd = ["claude", "-p", "--model", self.model, "--tools", "", "--setting-sources", "",
               "--no-session-persistence", "--output-format", "json", "--system-prompt", ROLE,
               "--json-schema", json.dumps(schema(questions)), prompt(state, questions)]
        done = subprocess.run(cmd, cwd=self.cwd, capture_output=True, text=True, timeout=self.timeout,
                              stdin=subprocess.DEVNULL)
        if done.returncode != 0:
            raise RuntimeError(f"claude -p exited {done.returncode}: {(done.stderr or done.stdout)[:300]}")
        r = json.loads(done.stdout)
        return r.get("structured_output") or json.loads(r["result"])


class OpenAICompatible:
    """Any /chat/completions endpoint that honours a JSON schema: OpenAI, a local server, a gateway."""

    def __init__(self, url: str, model: str, key: str | None, timeout: float):
        self.url, self.model, self.key, self.timeout = url.rstrip("/") + "/chat/completions", model, key, timeout
        self.name = f"standin/{model}"

    def __call__(self, state, questions: dict) -> dict:
        body = {"model": self.model, "temperature": 0,
                "messages": [{"role": "system", "content": ROLE}, {"role": "user", "content": prompt(state, questions)}],
                "response_format": {"type": "json_schema",
                                    "json_schema": {"name": "answers", "strict": True, "schema": schema(questions)}}}
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json",
                                              **({"Authorization": f"Bearer {self.key}"} if self.key else {})})
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            data = json.load(resp)
        return json.loads(data["choices"][0]["message"]["content"])


class Cache:
    def __init__(self, path: str | None):
        self.path, self.d, self.lock = path, {}, threading.Lock()
        if path and os.path.exists(path):
            with open(path) as f:
                for line in f:
                    x = json.loads(line)
                    self.d[x["k"]] = x["a"]

    def get(self, k):
        return self.d.get(k)

    def put(self, k, a):
        with self.lock:
            self.d[k] = a
            if self.path:
                with open(self.path, "a") as f:
                    f.write(json.dumps({"k": k, "a": a}) + "\n")


def serve(backend, port: int, host: str, key: str | None, cache: Cache) -> None:
    class Handler(BaseHTTPRequestHandler):
        def reply(self, status: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):  # a health check
            self.reply(200, {"model": backend.name, "ok": True})

        def do_POST(self):
            if key and self.headers.get("Authorization") != f"Bearer {key}":
                return self.reply(401, {"error": "this stand-in wants Authorization: Bearer $STANDIN_API_KEY"})
            try:
                req = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
                questions = req["questions"]
                if not isinstance(questions, dict) or not questions:
                    raise ValueError("questions is a non-empty object of id -> question")
                schema(questions)
            except (ValueError, KeyError, TypeError) as e:
                return self.reply(422, {"error": f"not a decision request: {e}"})
            k = hashlib.sha256(json.dumps([backend.name, req.get("state"), questions], sort_keys=True).encode()).hexdigest()
            got = cache.get(k)
            if got is None:
                try:
                    got = answers(backend(req.get("state"), questions), questions)
                except Exception as e:  # noqa: BLE001 -- a backend failure is the caller's 502, and retryable
                    print(f"backend failed: {e}", file=sys.stderr, flush=True)
                    return self.reply(502, {"error": f"the stand-in's model failed: {e}"[:500]})
                cache.put(k, got)
            print(json.dumps({"state": req.get("state"), "answers": got}, ensure_ascii=False)[:600], flush=True)
            self.reply(200, {"model": backend.name, "answers": got, "usage": {"input_tokens": 0, "output_tokens": 0}})

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer((host, port), Handler)
    print(f"{backend.name} answering Jev requests on http://{host}:{port}", flush=True)
    server.serve_forever()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--port", type=int, default=int(os.environ.get("STANDIN_PORT", 8790)))
    ap.add_argument("--host", default=os.environ.get("STANDIN_HOST", "0.0.0.0"),
                    help="0.0.0.0 so the worker's container reaches it as host.docker.internal")
    ap.add_argument("--backend", choices=("claude", "openai"), default=os.environ.get("STANDIN_BACKEND", "claude"))
    ap.add_argument("--claude-model", default=os.environ.get("STANDIN_CLAUDE_MODEL", "sonnet"))
    ap.add_argument("--openai-url", default=os.environ.get("STANDIN_OPENAI_URL", "https://api.openai.com/v1"))
    ap.add_argument("--openai-model", default=os.environ.get("STANDIN_OPENAI_MODEL", "gpt-4o-mini"))
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("--cache", default=os.environ.get("STANDIN_CACHE"), help="a .jsonl file answers are kept in")
    a = ap.parse_args()
    backend = (Claude(a.claude_model, a.timeout) if a.backend == "claude"
               else OpenAICompatible(a.openai_url, a.openai_model, os.environ.get("OPENAI_API_KEY"), a.timeout))
    serve(backend, a.port, a.host, os.environ.get("STANDIN_API_KEY") or None, Cache(a.cache))


if __name__ == "__main__":
    main()
