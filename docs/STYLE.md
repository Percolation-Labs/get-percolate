# How these docs are written

This file is the convention every page in `src/` follows. It is here rather
than in a reviewer's head because the format is the thing that makes the site
navigable, and a page that quietly opts out of it costs more than it saves.

## The unit: lesson, example, why it works

Everything on this site is built out of one repeating unit, and a page is a
sequence of them rather than an essay with code in it.

1. **The lesson.** What you are about to learn, in a heading and a sentence or
   two of prose. Written for somebody who does not yet know they need it.
2. **The example.** One sentence in the same voice on every page — *what we are
   trying to do here is …* — marked `{: .goal }`, and then the SQL or the YAML.
   Captured output follows in an `.evidence` block where we have it.
3. **Why it works.** The mechanism, the trade-off, and the failure the design
   prevents, inside a collapsed `<details class="why">`.

The reason for the third beat being collapsed is the reader we have most of:
somebody scanning for the shape of a solution, who wants to copy an example and
move on. They should be able to go example to example without scrolling past
paragraphs of reasoning. The reader who wants the reasoning always knows exactly
where it is, and it is one click away rather than on another page.

```markdown
### Fan out over a query result

One authored step becomes N tasks, and nothing outside the database decides how
many.

What we are trying to do here is run the same extraction over every document in
a backlog, without writing the fan-out by hand.
{: .goal }

```yaml
  - id: extract
    matrix:
      rows: {function: unextracted, args: ['{{run.batch}}']}
      max_fanout: 500
```

<details class="why" markdown="1">
<summary>Why it works — the expansion happens inside the transaction that
completes the parent</summary>

The children are inserted by the statement that marks `extract` done, so there
is no window in which the parent has completed and the work does not exist yet.
A controller-based fan-out has that window, and a controller that dies inside it
strands the fan-out with nothing to resume from.

`max_fanout` is mandatory because a cross join with a forgotten `WHERE` expands
to the cartesian product, and that should fail one step rather than the
database.

<p class="related"><strong>Related</strong>
<a href="authoring.html">the matrix reference</a> ·
<a href="failure.html">what happens when a child fails</a></p>
</details>
```

## The rules that follow from it

**One sentence of preamble, not four.** If an example needs three paragraphs of
setup, the setup belongs in a general page or in the `why` block, and the
example should link to it. Preamble is the single most common way a page becomes
unskimmable, and it is what this format exists to prevent.

**Every example opens the same way.** *What we are trying to do here is …* every
time, in `{: .goal }`. It reads as a formula, and that is deliberate: a formula
is recognisable at a glance, so a reader can find the examples on a page without
reading it.

**Backlinks are part of the format, not a courtesy.** Every `why` block ends with
a `<p class="related">` line. Link sideways to the page that owns the concept,
and down to the spec where the detail lives. A reader who opened the mechanism is
the reader most likely to want the next level down, and the alternative is that
each page re-explains its neighbours.

**Write DRY, with the repetition allowed in one place.** A concept has exactly
one home page, and every other page links to it. The exception is the `why`
blocks, where a moderate restatement is correct rather than sloppy: somebody
reading one collapsed block should not have to open three others to follow it.

**Do not write terse.** Sentence fragments and clipped openings read as notes to
self rather than as documentation, and they are worst at the start of a
paragraph, where they cost the reader the sentence they need in order to place
what follows. Open a paragraph with a full sentence that says what the paragraph
is about. "Six preliminaries, all one-time." is a note; "There are six things to
set up before any of this runs, and all of them are one-time." is a sentence.

**Keep the status chips honest.** `proven` means it was executed and there is an
assertion behind it, `designed` means specified and reviewed but not run,
`absent` means named because leaving it out would read as done. Moving a page
back to `designed` is a normal edit.

## The markup, exactly

| Thing | Markup |
|---|---|
| Page lede | a paragraph followed by `{: .lede }` |
| Example goal | a paragraph followed by `{: .goal }` |
| Why-it-works | `<details class="why" markdown="1">` + `<summary>` |
| Backlinks | `<p class="related"><strong>Related</strong> … · … </p>` |
| Captured output | `<div class="evidence" markdown="1">` + `<div class="label">` |
| Numbered walkthrough | `<ol class="steps" markdown="1">` |

`markdown="1"` is required on every HTML block that contains Markdown —
`md_in_html` ships inside the `extra` extension the build already loads, and
without the attribute the contents render as literal text.

The `summary` line carries the hook rather than the word "Details": *Why it
works — the expansion happens inside the transaction that completes the parent*.
A reader decides whether to open it from that line alone, so it has to say
something.
