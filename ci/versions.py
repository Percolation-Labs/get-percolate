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


def not_ours() -> dict:
    """Three-part numbers in docs/src that look like ours and are not.

    `{filename: {literal: reason}}`. The reason is required by the shape rather
    than by a check: a bare list would let somebody silence this by adding a
    number, and the reason is what the next reader needs to judge whether the
    exemption is still true.
    """
    with (ROOT / "versions.toml").open("rb") as fh:
        return tomllib.load(fh).get("not_ours", {})


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
        # The database image was the one line in this file that floated: a bare
        # `:19` tag moves under an existing install, so `docker compose up`
        # reuses whatever is cached and two machines run different builds while
        # both read `:19`. It is now pinned to `:19-<extension>`, enforced here
        # the way the core image already was -- four services pinned and one
        # floating was the file being inconsistent about the single thing this
        # script exists to make consistent.
        ("compose/docker-compose.yml",
         re.compile(r"image: percolationlabs/percolate-postgres:19-([0-9]+\.[0-9]+\.[0-9]+)"),
         v["extension"], "the compose file pulls this database image"),
        # The chart's database image, for the compose file's reason above. It
        # floated at "19" after compose was pinned, which is the inconsistency
        # that comment names, one file over.
        ("charts/percolate/values.yaml",
         re.compile(r"tag: \"19-([0-9]+\.[0-9]+\.[0-9]+)\""),
         v["extension"], "the chart deploys this database image"),
        ("charts/percolate/Chart.yaml",
         re.compile(r"^appVersion: \"([0-9]+\.[0-9]+\.[0-9]+)\"", re.M),
         v["core"], "appVersion is what the chart deploys"),
        ("charts/percolate/Chart.yaml",
         re.compile(r"^version: ([0-9]+\.[0-9]+\.[0-9]+)", re.M),
         v["chart"], "the chart's own version"),
        # THE PIP FLOOR IS NOT IN THIS LIST ANY MORE. README.md carried
        # `percolate-core[sample,agent]>=<version>` as a literal, because a
        # README cannot hold a placeholder the docs build substitutes, and this
        # rule checked it. 1f6ae2a shortened the README and that line went with
        # the section it lived in. The FACT did not go anywhere: it is
        # docs/src/install.md's `>=@@core_min@@`, substituted from versions.toml
        # at build time, which cannot drift and so needs no rule here. What was
        # left was a rule matching nothing, and this script is right to call
        # that a stop rather than a pass -- `no match for ... the file changed
        # shape` was red on main and on every branch off it. If a literal
        # version ever returns to the README, this rule returns with it.
    ]


def check(v: dict, pins: bool = True) -> list[str]:
    """Every file that repeats a number still agrees with versions.toml.

    `pins=False` skips the per-file rules and checks only the docs literals.
    That is what `--as` wants: it asks about numbers nobody has published yet,
    and the files those rules cover are the ones `--set` rewrites, so reporting
    them as errors would make the answer always "no" and teach people to skip
    it. A check that cannot pass is one that gets bypassed the day it matters.
    """
    bad = []
    for path, pat, want, why in (rules(v) if pins else []):
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
    #
    # NOT EVERY THREE-PART NUMBER IS OURS, and this check cannot tell by looking.
    # docs/src/skills.md documents a sample PLUGIN whose own version happens to
    # be 0.2.0 -- a different namespace that collides by accident. The numbers
    # are the sample's, one of them inside an evidence block holding captured
    # output, so replacing them with a placeholder would be wrong twice: it
    # would claim the plugin's version is ours, and it would edit a recorded
    # measurement.
    #
    # So a literal can be declared foreign in versions.toml, by file, WITH a
    # reason. Declaring is exact -- a person writes down which number is not
    # ours and why -- rather than the checker guessing from context, which is
    # how a check like this starts passing over things that are ours.
    #
    # Found the expensive way: `--set published.extension=0.2.0` made 0.2.0 ours
    # and this check began refusing skills.md. The release itself stays green
    # (nothing calls --check before publishing) and the DOCS deploy fails, after
    # the image and the tag are out, leaving the published site describing the
    # previous version.
    owned = set(v.values())
    foreign = not_ours()
    for md in sorted((ROOT / "docs" / "src").glob("*.md")):
        text = md.read_text()
        lits = set(re.findall(r"\b([0-9]+\.[0-9]+\.[0-9]+)\b", text))
        exempt = foreign.get(md.name, {})
        for lit in lits:
            if lit in owned and lit not in exempt:
                bad.append(f"docs/src/{md.name}: literal {lit} -- use a placeholder "
                           f"so it cannot go stale (@@extension@@, @@core@@, "
                           f"@@chart@@, @@core_min@@), or declare it in "
                           f"versions.toml [not_ours] if it is not our number")
        # AND THE OTHER DIRECTION, because a one-way check over a list only
        # keeps the list from naming ghosts. An exemption whose literal has left
        # the file is an exemption nobody notices is stale, and the next number
        # to land on it inherits a pass it never earned.
        for lit in sorted(set(exempt) - lits):
            bad.append(f"versions.toml [not_ours]: {md.name} exempts {lit}, which "
                       f"the file no longer contains -- drop the exemption")
    return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--set", metavar="KEY=VALUE",
                    help="published.extension, published.core, published.chart "
                         "or requires.core -- bare key means published")
    ap.add_argument("--as", dest="as_", metavar="KEY=VALUE", action="append",
                    help="with --check: answer as if this number were already "
                         "published, writing nothing. The preflight question -- "
                         "'would --check still pass once we own 0.2.0?' -- asked "
                         "before the release rather than by the docs deploy "
                         "after it. Repeatable.")
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

        # ANYTHING THE CHART PACKAGES CHANGING MEANS THE CHART CHANGED, so its
        # own number moves with it. Two keys do that, and this fired for one:
        #
        #   core      -> Chart.yaml appVersion
        #   extension -> charts/percolate/values.yaml, the database image tag
        #
        # The extension arm was missing and the consequence is worse than a
        # collision. `helm push` to GHCR is an OCI push and OCI tags are
        # MUTABLE, so it does not refuse -- it overwrites chart 0.1.5 in place
        # with one that deploys a different database. Anyone tracking
        # `semver: 0.1.x` or Argo `targetRevision: 0.1.*` moves with it, with no
        # version change to review, pin against or roll back to. A chart version
        # is supposed to identify its contents; republishing one silently breaks
        # the only promise the number makes.
        #
        # This was the coupling stated in the comment that used to be here and
        # implemented for whichever key prompted it -- one rule, half enforced.
        if (table, name) in (("published", "core"), ("published", "extension")):
            text = path.read_text()
            cur = re.search(r'^chart\s*=\s*"([0-9]+)\.([0-9]+)\.([0-9]+)"',
                            text, re.M)
            maj, minor, patch = (int(x) for x in cur.groups())
            nxt = f"{maj}.{minor}.{patch + 1}"
            path.write_text(re.sub(r'(^chart\s*=\s*")[0-9.]+(")',
                                   rf"\g<1>{nxt}\g<2>", text, flags=re.M))
            moved = "appVersion" if name == "core" else "the database image tag"
            print(f"versions.toml: published.chart -> {nxt} "
                  f"({moved} moved, so the chart itself changed)")

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

    # --as: the same check, against the numbers a release is ABOUT to own.
    # Everything the literal check refuses depends on what is in `owned`, so a
    # literal that is fine today becomes an error the moment a release claims
    # that number -- and the only thing that ran --check afterwards was the docs
    # deploy, which fires after the image is published and the tag moved. This
    # asks the question while the answer is still cheap.
    KEYS = {"published.extension": "extension", "extension": "extension",
            "published.core": "core", "core": "core",
            "published.chart": "chart", "chart": "chart",
            "requires.core": "core_min", "requires.extension": "extension_min"}
    for item in a.as_ or []:
        key, _, value = item.partition("=")
        if key not in KEYS:
            print(f"error: --as {key} is not a version this file owns "
                  f"({', '.join(sorted(KEYS))})", file=sys.stderr)
            return 2
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
            print(f"error: {value!r} is not a version", file=sys.stderr)
            return 2
        v[KEYS[key]] = value
    if a.as_:
        # stderr, with the errors, because stdout through a pipe is block
        # buffered and stderr is not -- a header that arrives after the lines it
        # introduces is worse than none.
        print(f"checking as if published: {', '.join(a.as_)}", file=sys.stderr)

    bad = check(v, pins=not a.as_)
    for b in bad:
        print(f"error: {b}", file=sys.stderr)
    if bad:
        if a.as_:
            print("\nThis is what the docs deploy would say AFTER the release "
                  "published. Fix it now, while nothing has shipped.",
                  file=sys.stderr)
        else:
            print("\nrun ci/versions.py --set <key>=<version> to move a number "
                  "and rewrite what repeats it", file=sys.stderr)
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
