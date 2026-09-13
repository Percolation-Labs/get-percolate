#!/usr/bin/env python3
"""bootstrap.sql sets the same per-role timeouts as the image's superuser step.

Two files do the superuser's half of an install. p8-subsystems'
`dev/image-init/00-superuser.sql` runs at the image's initdb, and this
repository's `bootstrap.sql` is what an own-Postgres install downloads and runs
by hand. REM-113 put four timeouts per login role into the first and nothing
into the second, so an own-Postgres database ran every query unbounded, and no
check existed that could have noticed.

bootstrap.sql cannot include the other file: it is fetched on its own by
`install.sh`, with no p8-subsystems checkout beside it. So it carries a copy,
and this compares the copies. It does not interpret SQL. It reads the one
`values` table each file drives its `alter role ... set` loop from, maps each
row's columns onto the setting names that loop writes, and requires the two
results to be equal.

    python3 ci/superuser-step.py path/to/p8-subsystems/dev/image-init/00-superuser.sql
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# `execute format('alter role %I set statement_timeout = %L', r.role, r.stmt);`
SETTING = re.compile(
    r"alter role %I set (\w+) = %L',\s*r\.role,\s*r\.(\w+)\)", re.I)
# `) as t(role, stmt, txn, idle, lock)`
COLUMNS = re.compile(r"\)\s*as\s+t\(([^)]*)\)", re.I)
# `('worker', '300s', '600s', '60s', '15s')`
ROW = re.compile(r"\(\s*'([^']*)'((?:\s*,\s*'[^']*')+)\s*\)")


def role_settings(path: pathlib.Path) -> dict[str, dict[str, str]]:
    """{role: {setting: value}} from the do-block that sets role timeouts."""
    text = path.read_text()
    blocks = [b for b in re.split(r"\$\$", text) if SETTING.search(b)]
    if len(blocks) != 1:
        sys.exit(f"{path}: expected one block of `alter role %I set ...` "
                 f"statements, found {len(blocks)}")
    block = blocks[0]
    cols = COLUMNS.search(block)
    if not cols:
        sys.exit(f"{path}: the settings loop has no `as t(...)` column list")
    names = [c.strip() for c in cols.group(1).split(",")]
    column_to_setting = {col: guc for guc, col in SETTING.findall(block)}
    out: dict[str, dict[str, str]] = {}
    for m in ROW.finditer(block[:cols.start()]):
        values = [m.group(1)] + re.findall(r"'([^']*)'", m.group(2))
        if len(values) != len(names):
            sys.exit(f"{path}: row {values} has {len(values)} values "
                     f"for {len(names)} columns")
        row = dict(zip(names, values))
        out[row["role"]] = {column_to_setting[c]: v
                            for c, v in row.items() if c in column_to_setting}
    if not out:
        sys.exit(f"{path}: the settings loop has no rows")
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    image = role_settings(pathlib.Path(sys.argv[1]))
    ours = role_settings(ROOT / "bootstrap.sql")
    if image == ours:
        for role, s in sorted(ours.items()):
            print(f"  {role:14} " + "  ".join(f"{k}={v}" for k, v in sorted(s.items())))
        print("bootstrap.sql sets the same role timeouts as 00-superuser.sql")
        return 0
    print("FAIL: bootstrap.sql and 00-superuser.sql set different role timeouts",
          file=sys.stderr)
    for role in sorted(set(image) | set(ours)):
        a, b = image.get(role), ours.get(role)
        if a != b:
            print(f"  {role}:\n    00-superuser.sql  {a}\n    bootstrap.sql     {b}",
                  file=sys.stderr)
    print("Copy the values table from 00-superuser.sql §2 into bootstrap.sql.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
