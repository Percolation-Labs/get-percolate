#!/usr/bin/env bash
# ci/fetch-tag-file.py waits out a fresh tag's 404 and fails an old tag's at once (REM-1155).
#
#     ci/fetch-tag-file-test.sh
#
# A local server plays raw.githubusercontent.com and the GitHub API: the raw file answers 404 for its first N
# requests, then 200, and the tag's tagger date is set per case. Nothing leaves this machine.
set -euo pipefail
T=$(mktemp -d)
cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$T/server.py" <<'PY'
import json, os, sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
state = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body=b""):
        self.send_response(code); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        cfg = json.load(open(f"{state}/cfg.json"))
        with open(f"{state}/log", "a") as f: f.write(self.path + "\n")
        if self.path.startswith("/raw/"):
            n = sum(1 for l in open(f"{state}/log") if l.startswith("/raw/"))
            return self.send(200, b"-- the harness\n") if n > cfg["raw_404s"] else self.send(404)
        if self.path.endswith("/git/ref/tags/v9.9.9"):
            return self.send(200, json.dumps({"object": {"type": "tag", "sha": "abc"}}).encode())
        if self.path.endswith("/git/tags/abc"):
            when = (datetime.now(timezone.utc) - timedelta(seconds=cfg["age"])).strftime("%Y-%m-%dT%H:%M:%SZ")
            return self.send(200, json.dumps({"tagger": {"date": when}}).encode())
        self.send(404)
HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
echo '{"raw_404s": 0, "age": 0}' > "$T/cfg.json"
python3 "$T/server.py" "$T" "$PORT" & PID=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done
export RAW=http://127.0.0.1:$PORT/raw GH_API=http://127.0.0.1:$PORT FETCH_FIRST_WAIT=0.2
F="$(dirname "$0")/fetch-tag-file.py"
case_() {   # raw 404s, tag age seconds, patience
    printf '{"raw_404s": %s, "age": %s}\n' "$1" "$2" > "$T/cfg.json"; : > "$T/log"; rm -f "$T/out"
    export FETCH_PATIENCE=$3
    set +e; python3 "$F" Percolation-Labs/percolate v9.9.9 dev/tests/x.sql "$T/out" 2> "$T/err"; rc=$?; set -e
    raws=$(grep -c '^/raw/' "$T/log" || true)
}

# 1. A tag 30s old answers 404 three times, then serves: fetched, after three retries.
case_ 3 30 120
[ "$rc" = 0 ] || { cat "$T/err"; fail "a fresh tag's file was not fetched (exit $rc)"; }
[ "$raws" = 4 ] || fail "expected 4 raw requests (one, then three retries), made $raws"
grep -q 'the harness' "$T/out" || fail "the file was not written"
echo "ok   a 404 on a tag 30s old is retried until it serves (4 requests)"

# 2. A tag an hour old answers 404: missing, on the first answer, with no retry.
case_ 1000 3600 120
[ "$rc" = 1 ] || { cat "$T/err"; fail "an old tag's 404 exited $rc, not 1"; }
[ "$raws" = 1 ] || fail "an old tag's 404 was retried ($raws raw requests)"
grep -q 'missing rather than not served yet' "$T/err" || { cat "$T/err"; fail "the old-tag message"; }
echo "ok   a 404 on a tag an hour old fails on its first answer"

# 3. A fresh tag that never serves gives up after its patience, not forever.
start=$(date +%s); case_ 1000 30 3; took=$(( $(date +%s) - start ))
[ "$rc" = 1 ] || fail "a fresh tag that never serves exited $rc, not 1"
[ "$took" -le 6 ] || fail "patience 3s took ${took}s"
grep -q 'still 404 after 3s' "$T/err" || { cat "$T/err"; fail "the gave-up message"; }
[ "$raws" -ge 3 ] || fail "only $raws raw requests in 3s of backoff"
echo "ok   a fresh tag that never serves gives up after its patience (${took}s, $raws requests)"

# 4. A file served at once never asks the API.
case_ 0 30 120
[ "$rc" = 0 ] && [ "$raws" = 1 ] && ! grep -q '/git/' "$T/log" || { cat "$T/log"; fail "a served file asked the API"; }
echo "ok   a 200 at once needs no API call"
