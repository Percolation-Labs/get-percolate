#!/usr/bin/env python3
"""One home for the published version numbers, and the files that must repeat them.

`versions.toml` is the home. `docs/build.py` substitutes @@placeholders@@ into
the built pages, so nothing in `docs/src/` needs a literal. Three kinds of file
cannot use a placeholder, because something other than the docs build reads
them: a compose file is executed by docker, a Chart.yaml is parsed by Helm, and
a README renders on GitHub. Those get real literals -- written here, and checked
here.

    ci/versions.py --check          # CI gate: does everything still agree?
    ci/versions.py --set core=0.1.7 # move a number and rewrite what repeats it

This exists because the previous mechanism was a GitHub issue asking a person to
go and find them. It did not work. Three pages claimed the dialect was 0.1.0 for
a whole release after it became 0.1.1, and nothing reported it, because stale
prose is indistinguishable from current prose at a glance.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

try:
    import tomllib                      # 3.11+
except ModuleNotFoundError:             # pragma: no cover - depends on install
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        raise SystemExit(
            "ci/versions.py reads TOML, which needs Python 3.11 or newer "
            f"(this is {sys.version_info.major}.{sys.version_info.minor}) -- "
            "run it with a newer interpreter, or `pip install tomli`. "
            "On a Mac the bare `python3` is often the system 3.9.")

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load() -> dict:
    with (ROOT / "versions.toml").open("rb") as fh:
        v = tomllib.load(fh)
    return {
        "extension": v["published"]["extension"],
        "core": v["published"]["core"],
        "chart": v["published"]["chart"],
        "core_min": v["requires"]["core"],
        "extension_min": v["requires"].get("extension", v["published"]["extension"]),
    }


# Each rule is (file, regex with one capture group, which version it must equal).
# The regex is the contract: it names the exact shape of the literal, so a rule
# that stops matching is a file that changed shape and needs a human, not a
# silent pass.
def rules(v: dict) -> list[tuple[str, re.Pattern, str, str]]:
    return [
        ("compose/docker-compose.yml",
         re.compile(r"image: percolationlabs/percolate-core:([0-9]+\.[0-9]+\.[0-9]+)"),
         v["core"], "the compose file pulls this image"),
        ("charts/percolate/Chart.yaml",
         re.compile(r"^appVersion: \"([0-9]+\.[0-9]+\.[0-9]+)\"", re.M),
         v["core"], "appVersion is what the chart deploys"),
        ("charts/percolate/Chart.yaml",
         re.compile(r"^version: ([0-9]+\.[0-9]+\.[0-9]+)", re.M),
         v["chart"], "the chart's own version"),
        ("README.md",
         re.compile(r"percolate-core>=([0-9]+\.[0-9]+\.[0-9]+)"),
         v["core_min"], "the documented pip floor"),
    ]


def check(v: dict) -> list[str]:
    bad = []
    for path, pat, want, why in rules(v):
        text = (ROOT / path).read_text()
        found = pat.findall(text)
        if not found:
            bad.append(f"{path}: no match for {pat.pattern!r} -- the file changed "
                       f"shape, so this rule no longer checks anything")
            continue
        for got in set(found):
            if got != want:
                bad.append(f"{path}: says {got}, versions.toml says {want} ({why})")

    # A literal anywhere in docs/src that equals a number we own should have been
    # a placeholder. Older versions are left alone on purpose -- "as of the 0.1.4
    # pin" is history, and history does not go stale.
    owned = set(v.values())
    for md in sorted((ROOT / "docs" / "src").glob("*.md")):
        for lit in set(re.findall(r"\b([0-9]+\.[0-9]+\.[0-9]+)\b", md.read_text())):
            if lit in owned:
                bad.append(f"docs/src/{md.name}: literal {lit} -- use a placeholder "
                           f"so it cannot go stale (@@extension@@, @@core@@, "
                           f"@@chart@@, @@core_min@@)")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--set", metavar="KEY=VALUE",
                    help="published.extension, published.core, published.chart "
                         "or requires.core -- bare key means published")
    a = ap.parse_args()

    if a.set:
        key, _, value = a.set.partition("=")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
            print(f"error: {value!r} is not a version", file=sys.stderr)
            return 2
        table, _, name = key.rpartition(".")
        table = table or "published"
        path = ROOT / "versions.toml"
        text = path.read_text()
        # Rewritten in place rather than re-serialised: this file is mostly
        # comments explaining why each number exists, and tomllib cannot write.
        pat = re.compile(rf"(^\[{table}\][^\[]*?^{name}\s*=\s*\")[0-9.]+(\")",
                         re.M | re.S)
        if not pat.search(text):
            print(f"error: no {table}.{name} in versions.toml", file=sys.stderr)
            return 2
        path.write_text(pat.sub(rf"\g<1>{value}\g<2>", text))
        print(f"versions.toml: {table}.{name} -> {value}")

        # Moving appVersion CHANGES THE CHART, and Helm refuses to republish a
        # chart version that already exists -- so the chart's own number has to
        # move with it or the publish step collides. That coupling is always
        # true and was previously carried in an issue asking a person to
        # remember it, which is the kind of thing a person remembers until the
        # once they do not.
        if (table, name) == ("published", "core"):
            text = path.read_text()
            cur = re.search(r'^chart\s*=\s*"([0-9]+)\.([0-9]+)\.([0-9]+)"',
                            text, re.M)
            maj, minor, patch = (int(x) for x in cur.groups())
            nxt = f"{maj}.{minor}.{patch + 1}"
            path.write_text(re.sub(r'(^chart\s*=\s*")[0-9.]+(")',
                                   rf"\g<1>{nxt}\g<2>", text, flags=re.M))
            print(f"versions.toml: published.chart -> {nxt} "
                  f"(appVersion moved, so the chart itself changed)")

        v = load()
        for rel, rpat, want, _ in rules(v):
            f = ROOT / rel
            before = f.read_text()
            after = rpat.sub(lambda m: m.group(0).replace(m.group(1), want), before)
            if after != before:
                f.write_text(after)
                print(f"  {rel}: -> {want}")
        return 0

    v = load()
    bad = check(v)
    for b in bad:
        print(f"error: {b}", file=sys.stderr)
    if bad:
        print("\nrun ci/versions.py --set <key>=<version> to move a number and "
              "rewrite what repeats it", file=sys.stderr)
        return 1

    print("versions.toml agrees with every file that repeats it:")
    for k in ("extension", "core", "chart", "core_min"):
        print(f"  {k:10} {v[k]}")
    # Two independent gaps, reported the same way. Each means the same thing:
    # the documentation describes something a reader cannot install yet, which
    # is a state worth naming out loud rather than leaving for coldstart.sh to
    # discover as a bare `function does not exist`.
    outstanding = [(n, v[f"{k}_min"], v[k])
                   for n, k in (("percolate-core", "core"), ("the extension", "extension"))
                   if v[f"{k}_min"] != v[k]]
    if outstanding:
        print()
        for name, req, pub in outstanding:
            print(f"note: the docs require {name} {req} and {pub} is published.")
        print("      A release is outstanding -- ci/coldstart.sh fails until it ships,")
        print("      and that failure is the docs being ahead, not the docs being wrong.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
