#!/usr/bin/env python3
"""Build the docs site from docs/src/*.md.

    uv run --with markdown --with pygments python docs/build.py
    ./docs/build.sh                                  # the same, with the deps pinned

Everything comes from nav.toml: the sidebar, the prev/next pager, llms.txt and
llms-full.txt. One source, so a page cannot be in the site and missing from the
agent index -- which is the failure this would otherwise have, since nobody
looks at llms.txt to notice it is stale.

Output lands in docs/_site/ and is gitignored. CI publishes it; a local build is
for looking at it.
"""
from __future__ import annotations

import html
import re
import shutil
import sys
import tomllib
from pathlib import Path

import markdown

HERE = Path(__file__).resolve().parent
SRC = HERE / "src"
OUT = HERE / "_site"
CHIPS = {"proven": "proven", "designed": "designed", "absent": "absent"}


def load_nav() -> dict:
    with (HERE / "nav.toml").open("rb") as fh:
        return tomllib.load(fh)


def pages(nav: dict) -> list[dict]:
    """Flat page list, in nav order -- what the pager and llms.txt walk."""
    out = []
    for section in nav.get("section", []):
        for page in section.get("page", []):
            out.append({**page, "section": section["name"],
                        "url": page["file"].replace(".md", ".html")})
    return out


def render_markdown(text: str) -> tuple[str, str]:
    """Returns (html, first paragraph as plain text).

    `codehilite` with guess_lang off: a fenced block with no language is
    output, not code, and guessing turns a psql table into badly-coloured
    Python. That is exactly the distinction the theme draws.
    """
    md = markdown.Markdown(extensions=[
        "extra", "toc", "sane_lists", "attr_list",
        "codehilite", "admonition",
    ], extension_configs={
        "codehilite": {"css_class": "hl", "guess_lang": False},
    })
    body = md.convert(text)
    first = ""
    m = re.search(r"<p>(.*?)</p>", body, re.S)
    if m:
        first = re.sub(r"<[^>]+>", "", m.group(1)).strip()
    return body, first


def chip(status: str | None) -> str:
    if status not in CHIPS:
        return ""
    return f'<span class="chip chip-{status}">{CHIPS[status]}</span>'


def sidebar(nav: dict, current: str) -> str:
    parts = []
    for section in nav.get("section", []):
        parts.append(f'<div class="group">{html.escape(section["name"])}</div>')
        for page in section.get("page", []):
            url = page["file"].replace(".md", ".html")
            cls = ' class="here"' if url == current else ""
            parts.append(f'<a href="{url}"{cls}>{html.escape(page["title"])}</a>')
    return "\n".join(parts)


def pager(all_pages: list[dict], i: int) -> str:
    prev = all_pages[i - 1] if i > 0 else None
    nxt = all_pages[i + 1] if i + 1 < len(all_pages) else None
    left = (f'<a href="{prev["url"]}"><span class="dir">Previous</span>'
            f'{html.escape(prev["title"])}</a>') if prev else "<span></span>"
    right = (f'<a href="{nxt["url"]}" style="text-align:right"><span class="dir">Next</span>'
             f'{html.escape(nxt["title"])}</a>') if nxt else "<span></span>"
    return f'<div class="pager">{left}{right}</div>'


SHELL = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} — {site}</title>
<meta name="description" content="{summary}">
<link rel="canonical" href="{site_url}/{url}">
<link rel="icon" type="image/png" href="assets/logo.png">
<meta property="og:title" content="{title} — {site}">
<meta property="og:description" content="{summary}">
<meta property="og:type" content="article">
<meta property="og:url" content="{site_url}/{url}">
<!-- Two families and a mono, with real fallbacks: the page is readable before
     anything loads, and stays readable if fonts.gstatic.com is blocked. -->
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700&family=Newsreader:ital,opsz,wght@0,6..72,400;0,6..72,500;1,6..72,400&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<link rel="stylesheet" href="theme/style.css">
</head>
<body>
<header class="masthead">
  <div class="masthead-inner">
    <img src="assets/logo.png" alt="">
    <a class="wordmark" href="index.html">{site}</a>
    <span class="tagline">{tagline}</span>
    <span class="spacer"></span>
    <a class="ext" href="https://github.com/percolating-sirsh/get-percolate">GitHub</a>
    <a class="ext" href="llms.txt">llms.txt</a>
  </div>
</header>
<div class="shell">
  <nav class="toc">
{sidebar}
  </nav>
  <main>
{body}
{pager}
  </main>
</div>
<footer class="site"><div class="inner">
  <span>Percolate</span>
  <span class="dot">&bull;</span>
  <a href="https://percolationlabs.ai">Percolation Labs</a>
  <a href="https://github.com/percolating-sirsh/p8-subsystems">Specs</a>
  <a href="https://github.com/percolating-sirsh/percolate-core">Services</a>
  <a href="https://pypi.org/project/percolate-core/">PyPI</a>
  <span class="spacer"></span>
  <span>MIT</span>
</div></footer>
</body>
</html>
"""


def build() -> int:
    nav = load_nav()
    all_pages = pages(nav)
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    shutil.copytree(HERE / "theme", OUT / "theme")
    shutil.copytree(HERE / "assets", OUT / "assets")

    missing = [p["file"] for p in all_pages if not (SRC / p["file"]).exists()]
    if missing:
        # Loudly, and before writing a site with holes in it. A nav entry with
        # no page renders as a link to a 404, which is the kind of thing that
        # ships because nobody clicks every link.
        print(f"error: nav.toml names pages that do not exist: {', '.join(missing)}",
              file=sys.stderr)
        return 1

    full_md = [f"# {nav['site_name']} — {nav['site_tagline']}\n",
               nav["description"].strip(), ""]
    index_lines = [f"# {nav['site_name']}", "",
                   f"> {nav['description'].strip()}", ""]
    by_section: dict[str, list[str]] = {}

    for i, page in enumerate(all_pages):
        text = (SRC / page["file"]).read_text()
        body, first_para = render_markdown(text)
        summary = page.get("summary") or first_para

        # The status chip rides on the h1, so it is the first thing read and is
        # attached to the claim rather than floating in a legend.
        body = re.sub(r"(<h1[^>]*>.*?)(</h1>)",
                      lambda m: m.group(1) + chip(page.get("status")) + m.group(2),
                      body, count=1, flags=re.S)

        (OUT / page["url"]).write_text(SHELL.format(
            title=html.escape(page["title"]),
            site=html.escape(nav["site_name"]),
            tagline=html.escape(nav["site_tagline"]),
            site_url=nav["site_url"].rstrip("/"),
            url=page["url"],
            summary=html.escape(summary),
            sidebar=sidebar(nav, page["url"]),
            body=body,
            pager=pager(all_pages, i),
        ))

        by_section.setdefault(page["section"], []).append(
            f"- [{page['title']}]({nav['site_url'].rstrip('/')}/{page['url']}): {summary}")
        full_md += [f"\n\n---\n\n## {page['title']}",
                    f"_status: {page.get('status', 'unstated')}_\n", text]

    # llms.txt -- llmstxt.org: an H1, a blockquote summary, then link sections.
    # Generated from the same nav as the site so it cannot fall behind, which is
    # the whole failure mode of a hand-written one: nobody reads it often enough
    # to notice it is wrong.
    for name, links in by_section.items():
        index_lines += [f"## {name}", "", *links, ""]
    index_lines += [
        "## Source", "",
        "- [Specs and schema](https://github.com/percolating-sirsh/p8-subsystems): the SQL, and the specs each capability is asserted against.",
        "- [Services](https://github.com/percolating-sirsh/percolate-core): the worker, Content Server and Agent Runtime.",
        "- [Getting started](https://github.com/percolating-sirsh/get-percolate): compose file, Helm chart, install script.",
        "",
        "## Optional", "",
        f"- [Full documentation as one file]({nav['site_url'].rstrip('/')}/llms-full.txt): every page above, concatenated.",
        "",
    ]
    (OUT / "llms.txt").write_text("\n".join(index_lines))
    (OUT / "llms-full.txt").write_text("\n".join(full_md))

    # Pages needs this to serve the custom domain, and it must be in the
    # published artifact rather than in the repo root -- the workflow uploads
    # _site, not the repo.
    (OUT / "CNAME").write_text("docs.percolationlabs.ai\n")
    # And this, or Pages runs the whole thing through Jekyll and drops
    # every directory beginning with an underscore.
    (OUT / ".nojekyll").write_text("")

    (OUT / "robots.txt").write_text(
        f"User-agent: *\nAllow: /\nSitemap: {nav['site_url'].rstrip('/')}/sitemap.xml\n")
    urls = "".join(
        f"<url><loc>{nav['site_url'].rstrip('/')}/{p['url']}</loc></url>" for p in all_pages)
    (OUT / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>'
        f'<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{urls}</urlset>')

    print(f"built {len(all_pages)} pages + llms.txt + llms-full.txt -> {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(build())
