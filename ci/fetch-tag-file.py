#!/usr/bin/env python3
"""Fetch one file at a tag from raw.githubusercontent.com, waiting out a tag GitHub has not served yet (REM-1155).

    ci/fetch-tag-file.py <owner/repo> <tag> <path> <out>

On the 2026-10-23 train the tour asked for v0.2.30's harness 6 seconds after the tag was created and got a 404;
a rerun passed. raw.githubusercontent.com serves a new ref a little after the API has it. So a 404 is retried, with
backoff for about two minutes -- but only when the GitHub API says the tag was created in the last ten minutes. A
file missing from an older tag is really missing, and fails on its first answer, as it always did.

Exits 0 with the file written, or 1 saying which of the two it was. Knobs, for the test (ci/fetch-tag-file-test.sh):
RAW and GH_API (base URLs), FETCH_FRESH (seconds a tag counts as new, 600), FETCH_PATIENCE (seconds to keep
retrying, 120), FETCH_FIRST_WAIT (the first backoff, 2; it doubles).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

RAW = os.environ.get("RAW", "https://raw.githubusercontent.com").rstrip("/")
GH_API = os.environ.get("GH_API", "https://api.github.com").rstrip("/")
FRESH = float(os.environ.get("FETCH_FRESH", "600"))
PATIENCE = float(os.environ.get("FETCH_PATIENCE", "120"))
FIRST_WAIT = float(os.environ.get("FETCH_FIRST_WAIT", "2"))


def get(url: str, api: bool = False) -> tuple[int, bytes]:
    req = urllib.request.Request(url)
    if api:
        req.add_header("Accept", "application/vnd.github+json")
        if os.environ.get("GITHUB_TOKEN"):
            req.add_header("Authorization", f"Bearer {os.environ['GITHUB_TOKEN']}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""


def tag_age(repo: str, tag: str) -> float | None:
    """Seconds since the tag was created: the tagger's date for an annotated tag, the commit's for a light one.
    None when the API cannot say, which is treated as old: no reason to wait is no wait."""
    status, body = get(f"{GH_API}/repos/{repo}/git/ref/tags/{tag}", api=True)
    if status != 200:
        return None
    obj = json.loads(body)["object"]
    if obj["type"] == "tag":
        status, body = get(f"{GH_API}/repos/{repo}/git/tags/{obj['sha']}", api=True)
        when = json.loads(body)["tagger"]["date"] if status == 200 else None
    else:
        status, body = get(f"{GH_API}/repos/{repo}/git/commits/{obj['sha']}", api=True)
        when = json.loads(body)["committer"]["date"] if status == 200 else None
    if not when:
        return None
    return time.time() - datetime.fromisoformat(when.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.splitlines()[2].strip(), file=sys.stderr)
        return 2
    repo, tag, path, out = sys.argv[1:]
    url = f"{RAW}/{repo}/{tag}/{path}"
    status, body = get(url)
    if status == 404:
        age = tag_age(repo, tag)
        if age is not None and age < FRESH:
            print(f"{url}: 404, and {tag} is {age:.0f}s old, so GitHub may not serve it yet; "
                  f"retrying for up to {PATIENCE:.0f}s", file=sys.stderr)
            deadline, wait = time.monotonic() + PATIENCE, FIRST_WAIT
            while status == 404 and time.monotonic() < deadline:
                time.sleep(min(wait, max(0.0, deadline - time.monotonic())))
                wait *= 2
                status, body = get(url)
                print(f"  retried: {status}", file=sys.stderr)
            if status == 404:
                print(f"{url}: still 404 after {PATIENCE:.0f}s, on a tag {age:.0f}s old when asked", file=sys.stderr)
                return 1
        else:
            said = "the API does not know the tag" if age is None else f"{tag} is {age:.0f}s old"
            print(f"{url}: 404, and {said}, so the file is missing rather than not served yet", file=sys.stderr)
            return 1
    if status != 200:
        print(f"{url}: HTTP {status}", file=sys.stderr)
        return 1
    with open(out, "wb") as f:
        f.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
