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
import re
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
blocks_at, substitute = _er.blocks_at, _er.substitute

SRC = HERE.parent / "docs" / "src"
# The harbour fixture's Meridian org, a fixed literal in samples/harbour/schema.sql.
ORG_A = "d0000000-0000-0000-0000-00000000000a"
# The Meridian member that samples/harbour/tenants.sql creates.
HARBOUR_READER = "e0000000-0000-0000-0000-00000000000a"

# ONE DEFINITION OF THE SEAT, and it is a function rather than two format
# strings because the two format strings is what went wrong. `wrap` and the
# old standalone emptiness re-run both opened a tenant-a session; when the seat moved from the
# bootstrapped administrator to the sample's own reader, only `wrap` was
# changed. So every page RAN correctly and was then re-checked for emptiness
# from a seat that could see nothing, and three pages were reported as
# "returned no rows" while returning rows -- a false FAIL, which is the same
# defect as a false pass and costs the same hour.
TENANT_A_CLAIMS = ('{"sub":"%s","role":"authenticated","orgs":["%s"]}'
                   % (HARBOUR_READER, ORG_A))

# EVERY SETTING A TENANT BLOCK CHANGES, IN ONE PLACE, because switching in and
# switching out are two lists that drift. `reset role` restores the role and
# leaves every other `set local` standing, and the page is one transaction, so a
# setting that is set here and not reset runs every owner block after it as the
# tenant. That happened: the claims were set and only the role was reset, and
# cookbook.md's upload at line 384 failed `not authorized to upload content`
# three tenant blocks later, reported as the page's failure. `enter`, `leave`
# and the guard are all generated from this tuple, so a third setting added here
# is reset and checked without anybody remembering to.
TENANT_A = (("role", "authenticated"), ("request.jwt.claims", TENANT_A_CLAIMS))


def enter(settings) -> str:
    """`set local` for each setting. SET LOCAL, not select set_config(): a
    select emits a row, which would count as output when a block's own answer
    is being weighed for emptiness."""
    return "".join(f"set local role {v};\n" if k == "role" else f"set local {k} = '{v}';\n"
                   for k, v in settings)


def leave(settings) -> str:
    """Reset each setting, then refuse to go on if any of them survived.

    NOT A SAVEPOINT rolled back after the block, which would reset everything at
    once: it would also undo what a tenant block wrote, and a later owner block
    on the same page may read it.

    The guard is a DO block, so it emits no row either. Its message names the
    settings it checked, so a failure says which one leaked.
    """
    names = [k for k, _ in settings]
    checks = " or ".join(
        "current_user <> session_user" if k == "role"
        else f"coalesce(current_setting('{k}', true), '') <> ''"
        for k in names)
    return ("".join(f"reset {k};\n" for k in names)
            + "do $$ begin\n"
            + f"  if {checks} then\n"
            + "    raise exception 'the examples runner left a tenant block''s settings "
              f"in force for the blocks after it (checked: {', '.join(names)})';\n"
            + "  end if;\n"
            + "end $$;\n")


def wrap(kind: str, context: str | None, body: str, after: str = "") -> str:
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
        return body + "\n" + after
    if context == "tenant-a":
        # THE SAMPLE'S READER, not the administrator this run bootstrapped.
        # From 0.1.4 an `orgs` claim is intersected with real membership, so a
        # subject who is in no org resolves to none -- and the admin is in none.
        # samples/harbour/tenants.sql ships a member of both tenants for exactly
        # this, and the documented preamble on graph.md and cookbook.md names
        # the same subject, so the harness and the reader are in one seat.
        # Everything it switches, and why switching back is generated rather
        # than written, is at TENANT_A.
        return enter(TENANT_A) + body + "\n" + after + leave(TENANT_A)
    raise SystemExit(f"unknown run context 'as:{context}' -- "
                     f"this runner knows: tenant-a")


# `psql:<stdin>:57: ERROR:  new row for relation ...` -- the line psql reports is
# a line of the SCRIPT this runner built, which is how an error is traced back
# to the block that raised it.
PSQL_ERROR = re.compile(r"^psql:<stdin>:(\d+): (?:ERROR|FATAL|PANIC):\s+(.*)$")


def stopped_by(stderr: str, spans: list[tuple[int, int, str]]) -> tuple[str, str]:
    """(label of the block that stopped the page, the error that stopped it).

    THE LAST ERROR, NOT THE FIRST LINE. This reported stderr's first line, and
    under ON_ERROR_STOP the error that stops psql is the last thing it writes:
    anything a block printed earlier comes first. On CI, recipes.md failed as
    `NOTICE: relation "emb_text_embedding_3_small" already exists, skipping`, a
    notice from an earlier statement, and the error behind it went unreported.

    The block is found from the script line psql names rather than from the last
    `### block` echo seen on stdout, so the label and the error come from the
    same line of output and cannot describe two different blocks.
    """
    lines = [l for l in stderr.splitlines() if l.strip()]
    for line in reversed(lines):
        m = PSQL_ERROR.match(line)
        if not m:
            continue
        n = int(m.group(1))
        where = next((label for first, last, label in spans if first <= n <= last),
                     f"script line {n}, outside every block")
        return where, m.group(2)
    return "an unknown block", (lines[-1] if lines else "(no stderr)")


def run_page(dsn: str, page: pathlib.Path) -> tuple[bool, str]:
    text = substitute(page.read_text())
    marked = [(ln, k, c, e, b) for ln, k, c, e, b in blocks_at(text) if k == "sql"]
    if not marked:
        return True, "no marked sql blocks"
    # The whole page in one transaction, rolled back at the end: a page's writes
    # do not leak into the next page's clean slate, and no block may carry its
    # own `begin`/`rollback` (that would close this one early) -- such a block is
    # left unmarked instead.
    #
    # Blocks are numbered from 1 and named by the line of their fence, so a
    # report reads `block 5, recipes.md:245` and a reader opens the page there.
    script = ["\\set ON_ERROR_STOP on", "begin;"]
    spans: list[tuple[int, int, str]] = []
    labels = []
    # AFTER EACH BODY, ITS ROW COUNT, before a tenant block's `leave` resets
    # anything: psql's ROW_COUNT is the last statement's, which is the answer the
    # page shows. Counted in place, in the page's own session, because a block
    # re-run alone loses the state the blocks before it made.
    for n, (ln, k, c, e, b) in enumerate(marked, 1):
        label = f"block {n}, {page.name}:{ln} (as:{c or 'owner'})"
        labels.append(label)
        script.append(f"\\echo '### {label}'")
        first = len(script) + 1
        script.extend(wrap(k, c, b, f"\\echo '{END} {n}' :ROW_COUNT\n").splitlines())
        spans.append((first, len(script), label))
    script.append("rollback;")
    # `-f -`, not a bare pipe: psql puts `psql:<stdin>:N:` in front of a message
    # only when it is reading a file, and `-` names stdin as one. Without it the
    # error carries no line, and nothing ties it to a block.
    r = subprocess.run(["psql", dsn, "-q", "-f", "-"], input="\n".join(script) + "\n",
                       capture_output=True, text=True)
    if r.returncode != 0:
        where, err = stopped_by(r.stderr, spans)
        return False, f"stopped at {where}: {err}"
    # AN EXAMPLE THAT SHOWS AN ANSWER MUST NOT COME BACK EMPTY, whoever runs it.
    # That is the `acme` failure -- a query against a fixture nobody loaded,
    # which errors nowhere -- and, in the owner's seat, a run read back inside
    # the statement that started it, under that statement's snapshot. Both
    # showed the reader a table and returned none. `aiq.query` always returns its
    # one envelope even when it matched nothing, so an empty `rows` array inside
    # counts as empty too. A tenant read is held to it even with no output shown,
    # because there the empty answer is the RLS failure.
    out = split_output(r.stdout)
    for n, (label, (ln, k, c, e, b)) in enumerate(zip(labels, marked), 1):
        if e or not (c == "tenant-a" or shows_output(text, ln)):
            continue
        empty, detail = is_empty(*out.get(n, (0, [])))
        if empty:
            seat = "as:tenant-a " if c == "tenant-a" else ""
            return False, (f"{label} returned no rows ({detail}) -- if that is "
                           f"correct, mark it `<!-- run: sql {seat}rows:0 -->`")
    return True, f"{len(marked)} blocks ran"


END = "@@@ end of block"
FOOTER = re.compile(r"^\((\d+) rows?\)$")


def split_output(stdout: str) -> dict[int, tuple[int, list[str]]]:
    """Block number -> (its last statement's row count, the lines it printed)."""
    out, lines = {}, []
    for line in stdout.splitlines():
        if line.startswith("### "):
            lines = []
        elif line.startswith(END + " "):
            n, count = line[len(END) + 1:].split()
            out[int(n)] = (int(count), lines)
        else:
            lines.append(line)
    return out


def is_empty(count: int, lines: list[str]) -> tuple[bool, str]:
    """No rows, or one row that is a lone envelope whose `rows` array is []."""
    # ROW_COUNT is 0 after EXPLAIN, which prints a plan, so a zero with a
    # positive `(N rows)` footer as the last one printed is still an answer.
    footers = [int(m.group(1)) for l in lines if (m := FOOTER.match(l.strip()))]
    if count == 0 and not (footers and footers[-1] > 0):
        return True, "no rows"
    # The LAST envelope printed, because that is the last statement's: a block
    # may show a deliberate miss first (`LOOKUP "meridien dawn"; -- 0 rows`).
    envelopes = [l.strip() for l in lines if l.strip().startswith("{")]
    if count == 1 and envelopes:
        try:
            doc = json.loads(envelopes[-1])
        except ValueError:
            doc = None
        if isinstance(doc, dict) and isinstance(doc.get("rows"), list) and not doc["rows"]:
            return True, "envelope with empty rows[]"
    return False, f"{count} row(s)"


def shows_output(text: str, fence_line: int) -> bool:
    """Whether the page prints an answer under the block whose fence opens at
    1-based `fence_line`: the next non-blank line after its closing fence opens
    another fence or an evidence box."""
    lines = text.splitlines()
    j = fence_line  # 0-based index of the first body line
    while j < len(lines) and not lines[j].startswith("```"):
        j += 1
    j += 1
    while j < len(lines) and not lines[j].strip():
        j += 1
    return j < len(lines) and (lines[j].startswith("```")
                               or lines[j].lstrip().startswith('<div class="evidence"'))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--page", help="one page (basename), else every page")
    a = ap.parse_args()
    # The seat has to EXIST, or every tenant read comes back empty and the
    # failure reads as "the documentation is wrong" rather than "the sample
    # did not load".
    r = subprocess.run(["psql", a.dsn, "-tAqc",
                        "select 1 from rbac.org_members m join rbac.users u "
                        "on u.id = m.user_id where u.id = '%s' and m.org_id = '%s'"
                        % (HARBOUR_READER, ORG_A)], capture_output=True, text=True)
    if r.stdout.strip() != "1":
        print(f"no member {HARBOUR_READER} of org {ORG_A} -- "
              f"load samples/harbour (tenants.sql creates them)", file=sys.stderr)
        return 2
    pages = [SRC / a.page] if a.page else sorted(SRC.glob("*.md"))
    bad = 0
    for p in pages:
        ok, msg = run_page(a.dsn, p)
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
