#!/usr/bin/env python3
"""Pull the executable blocks out of the documentation.

The install guide is a sequence of commands a stranger types, and it was wrong
in four places at once: a grant list whose verbs no policy asked for, a CLI the
pages never said to install, a repository path a compose user had not cloned,
and an error code in an evidence block that no longer matched what the server
returned. Every one of those is mechanical, and every one would have been
caught by running the page.

The blocks are therefore RUN, not transcribed into a test that would drift from
them exactly the way the grant list drifted from the policies. A block opts in
with an HTML comment on the line before its fence:

    <!-- run: sql -->
    ```sql
    select rbac.bootstrap_admin('me@example.com', 'a long passphrase');
    ```

Opt-in rather than everything, because plenty of blocks are deliberately not
runnable as written -- they carry placeholders (`<the uid ...>`), offer two
alternatives in one fence, or show output rather than input. Marking is the
author saying "this one is a literal instruction", which is the only claim
worth testing.

    python3 ci/extract-runnable.py docs/src/install.md --kind sql
"""
import argparse
import pathlib
import re
import sys

# A marker may carry an execution context after the kind: `<!-- run: sql as:tenant-a -->`.
# The context names the identity the block runs under; ci/run_examples.py reads it,
# and the bare `<!-- run: sql -->` form (context None, meaning the owner seat a
# reader is in at a psql prompt) is unchanged, so ci/coldstart.sh is unaffected.
# A marker may carry an execution context after the kind: `<!-- run: sql as:tenant-a -->`.
# A tenant read is expected to return at least one row -- an empty answer is the
# `FUZZY LOOKUP "acme"` failure, a query against a fixture that was never loaded,
# which runs cleanly and returns nothing. A block that is legitimately empty
# (a route to a node another tenant owns) opts out with a trailing `rows:0`.
MARKER = re.compile(
    r'^<!--\s*run:\s*([a-z]+)(?:\s+as:([a-z0-9-]+))?(?:\s+(rows:0))?\s*-->\s*$')
FENCE = re.compile(r'^```')
PLACEHOLDER = re.compile(r'@@([a-z_]+)@@')


def substitute(text: str) -> str:
    """Resolve @@name@@ against versions.toml, as docs/build.py does.

    The loader is IMPORTED from versions.py rather than repeated here. It was
    repeated, and the copies drifted within the hour: versions.py grew a fallback
    for interpreters without tomllib and this one did not, so `ci/coldstart.sh`
    died on `ModuleNotFoundError: tomllib` in the middle of a release rehearsal.
    Two readers of one file is the shape this whole mechanism exists to remove.
    """
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    from versions import load
    table = load()

    def one(m):
        if m.group(1) not in table:
            raise SystemExit(f"unknown placeholder @@{m.group(1)}@@")
        return table[m.group(1)]
    return PLACEHOLDER.sub(one, text)


def blocks(text):
    """Yield (kind, body) for each marked fence, in document order."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = MARKER.match(lines[i])
        if not m:
            i += 1
            continue
        kind = m.group(1)
        context = m.group(2)   # e.g. 'tenant-a', or None for the owner seat
        allow_empty = m.group(3) is not None   # 'rows:0' -- an empty answer is correct here
        # The fence must be the very next line. A marker that has drifted away
        # from its block is a silent no-op otherwise, and this file exists
        # because silent no-ops are expensive.
        if i + 1 >= len(lines) or not FENCE.match(lines[i + 1]):
            raise SystemExit(
                f"line {i+1}: '<!-- run: {kind} -->' is not immediately "
                f"followed by a fenced block")
        j = i + 2
        body = []
        while j < len(lines) and not FENCE.match(lines[j]):
            body.append(lines[j])
            j += 1
        if j >= len(lines):
            raise SystemExit(f"line {i+1}: unterminated fenced block")
        yield kind, context, allow_empty, "\n".join(body)
        i = j + 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--kind", help="only blocks of this kind")
    ap.add_argument("--list", action="store_true",
                    help="report what is marked, rather than emitting it")
    a = ap.parse_args()

    # Substituted the same way docs/build.py substitutes, because this reads the
    # same files. A marked block is a literal instruction, and a literal
    # instruction containing @@core_min@@ is not one -- two readers of one file
    # where only one resolves placeholders is exactly the drift this repository
    # keeps finding.
    text = substitute(pathlib.Path(a.path).read_text())
    found = [(k, c, e, b) for k, c, e, b in blocks(text) if not a.kind or k == a.kind]
    if a.list:
        for k, c, e, b in found:
            ctx = f" as:{c}" if c else ""
            print(f"{k}{ctx}: {b.splitlines()[0][:70] if b.splitlines() else '(empty)'}")
        return 0
    if not found:
        print(f"{a.path}: no runnable blocks"
              + (f" of kind '{a.kind}'" if a.kind else ""), file=sys.stderr)
        return 1
    for _, _, _, b in found:
        print(b)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
