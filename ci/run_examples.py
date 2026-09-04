#!/usr/bin/env python3
"""Run the documentation's marked example blocks against a live database.

`ci/coldstart.sh` proved the install guide by running it. This does the same for
the rest of the pages: every `<!-- run: sql -->` block is executed against a
freshly sample-loaded stack, in document order, and a page that stops on an
error -- a column that does not exist, a fixture that was never loaded, a
function whose name drifted -- fails the build instead of a reader.

    ci/run_examples.py --dsn postgres://p8:p8@localhost:5432/percolate
    ci/run_examples.py --dsn ... --page graph.md      # one page

WHY A CONTEXT. Half these views are RLS-filtered, so a tenant read run as the
bare owner returns the wrong rows (more, not fewer) with no error to say so --
the exact failure this repository keeps finding. A block that shows a tenant's
answer is marked `<!-- run: sql as:tenant-a -->` and this runner wraps it in the
Meridian seat a reader is in after minting a token. Bare `<!-- run: sql -->`
runs as the owner, which is where a reader sits at a psql prompt.

WHY IN ORDER, CUMULATIVELY. A page is a script: one block creates a skill, the
next pins it. Run alone, the second fails against state the first would have
made. So a page's blocks share one psql session, in document order.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent

# extract-runnable.py has a hyphen, so it cannot be imported by name -- load it
# by path. Reusing its parser and placeholder substitution keeps ONE reader of
# the block format and the @@version@@ table, which is the property this whole
# mechanism exists to hold.
import importlib.util  # noqa: E402
_spec = importlib.util.spec_from_file_location(
    "extract_runnable", HERE / "extract-runnable.py")
_er = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_er)
blocks_with_context, substitute = _er.blocks, _er.substitute

SRC = HERE.parent / "docs" / "src"
# The harbour fixture's Meridian org, a fixed literal in samples/harbour/schema.sql.
ORG_A = "d0000000-0000-0000-0000-00000000000a"


def admin_sub(dsn: str) -> str:
    r = subprocess.run(
        ["psql", dsn, "-tAqc",
         "select id from rbac.users order by created_at limit 1"],
        capture_output=True, text=True)
    return r.stdout.strip()


def wrap(kind: str, context: str | None, body: str, sub: str) -> str:
    """One block, ready to run inside the page's transaction.

    The whole page runs in one `begin; ... rollback;` (see run_page), so nothing
    a page writes survives it -- the next page meets the sample and nothing else,
    which is the property that keeps a create-then-use page honest. A tenant read
    therefore switches role INLINE and switches back, rather than opening its own
    transaction, because a nested `begin/rollback` would end the page's.
    """
    if kind != "sql":
        return ""  # only sql blocks are executed here; shell/pip are coldstart's
    if context is None:
        return body + "\n"
    if context == "tenant-a":
        claims = ('{"sub":"%s","role":"authenticated","orgs":["%s"]}' % (sub, ORG_A))
        # SET LOCAL, not select set_config(): a select emits a row, which would
        # count as output when a block's own answer is being weighed for emptiness.
        return (
            "set local role authenticated;\n"
            f"set local request.jwt.claims = '{claims}';\n"
            + body + "\n"
            "reset role;\n"
        )
    raise SystemExit(f"unknown run context 'as:{context}' -- "
                     f"this runner knows: tenant-a")


def run_page(dsn: str, page: pathlib.Path, sub: str) -> tuple[bool, str]:
    text = substitute(page.read_text())
    marked = [(k, c, e, b) for k, c, e, b in blocks_with_context(text) if k == "sql"]
    if not marked:
        return True, "no marked sql blocks"
    # The whole page in one transaction, rolled back at the end: a page's writes
    # do not leak into the next page's clean slate, and no block may carry its
    # own `begin`/`rollback` (that would close this one early) -- such a block is
    # left unmarked instead.
    script = "\\set ON_ERROR_STOP on\nbegin;\n"
    for i, (k, c, e, b) in enumerate(marked):
        script += f"\\echo '### block {i} (as:{c or 'owner'})'\n"
        script += wrap(k, c, b, sub)
    script += "rollback;\n"
    r = subprocess.run(["psql", dsn, "-q"], input=script,
                       capture_output=True, text=True)
    if r.returncode != 0:
        stops = [l for l in r.stdout.splitlines() if l.startswith("### block")]
        where = stops[-1] if stops else "before first block"
        err = (r.stderr.strip().splitlines() or ["(no stderr)"])[0]
        return False, f"stopped at {where}: {err}"
    # A tenant read that shows rows must not come back empty -- that is the
    # `acme` failure, a query against a fixture nobody loaded, which errors
    # nowhere. `aiq.query` always returns its one envelope even when it matched
    # nothing, so an empty `rows` array inside counts as empty too.
    for i, (k, c, e, b) in enumerate(marked):
        if c != "tenant-a" or e:
            continue
        empty, detail = returns_empty(dsn, b, sub)
        if empty:
            return False, (f"block {i} returned no rows ({detail}) -- if that is "
                           f"correct, mark it `as:tenant-a rows:0`")
    return True, f"{len(marked)} blocks ran"


def returns_empty(dsn: str, body: str, sub: str) -> tuple[bool, str]:
    """Run one tenant read standalone (rolled back) and say whether it is empty.

    Empty means: no output rows at all, or a lone `aiq.query`/graph envelope whose
    `rows` array is []. Anything else -- a scalar, a JSON object with no `rows`
    key, one or more table rows -- is a non-empty answer.
    """
    claims = ('{"sub":"%s","role":"authenticated","orgs":["%s"]}' % (sub, ORG_A))
    script = ("begin;\nset local role authenticated;\n"
              f"set local request.jwt.claims = '{claims}';\n"
              + body + "\nrollback;\n")
    r = subprocess.run(["psql", dsn, "-tAq", "-v", "ON_ERROR_STOP=1"],
                       input=script, capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    if not lines:
        return True, "no rows"
    if len(lines) == 1 and lines[0].lstrip().startswith("{"):
        try:
            doc = json.loads(lines[0])
            if isinstance(doc.get("rows"), list) and not doc["rows"]:
                return True, "envelope with empty rows[]"
        except (ValueError, AttributeError):
            pass
    return False, f"{len(lines)} row(s)"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--page", help="one page (basename), else every page")
    a = ap.parse_args()
    sub = admin_sub(a.dsn)
    if not sub:
        print("no user in rbac.users -- load the sample first", file=sys.stderr)
        return 2
    pages = [SRC / a.page] if a.page else sorted(SRC.glob("*.md"))
    bad = 0
    for p in pages:
        ok, msg = run_page(a.dsn, p, sub)
        mark = "ok  " if ok else "FAIL"
        # Pages with no marked blocks are silent unless asked for by name.
        if ok and msg == "no marked sql blocks" and not a.page:
            continue
        print(f"{mark} {p.name:24} {msg}")
        bad += 0 if ok else 1
    if bad:
        print(f"\n{bad} page(s) with an example that no longer runs", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
