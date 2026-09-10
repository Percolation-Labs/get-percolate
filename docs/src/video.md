# The AI-generated video, for which we apologise

Eight minutes on why any of this is in Postgres.
{: .lede }

<figure class="film">
<video controls preload="metadata"
       poster="assets/percolate-the-control-plane-poster.jpg"
       width="1280" height="720">
  <source src="assets/percolate-the-control-plane.mp4" type="video/mp4">
  <track kind="captions" srclang="en" label="English" default
         src="assets/percolate-the-control-plane.vtt">
  Your browser will not play this one.
  <a href="assets/percolate-the-control-plane.mp4">Download the mp4</a> instead.
</video>
<figcaption>Percolate — the control plane. 7:47, captioned.
<a href="assets/percolate-the-control-plane.mp4">mp4, 8 MB</a></figcaption>
</figure>

## What it covers

Ten sections, in the order the pages here are written in. The argument is the
one on [what Percolate is](index.html), at the speed of somebody explaining it
rather than the speed of a reference.

| | | |
|---|---|---|
| 00:00 | The experiment | Push all of it down and look |
| 00:52 | What is left | Everything here is a row |
| 01:28 | Built first | Permissions and workflow, underneath the agent runtime rather than in front of it |
| 02:23 | Install a domain | A domain, installed as a document |
| 03:11 | Sourcing | Ingestion is a subsystem |
| 03:59 | Ask across modes | One language over entity lookup, graph, semantic and lexical search — with plain SQL as the floor |
| 05:33 | Workflow semantics | An agent turn is just a step kind |
| 06:20 | The slow participant | When the next step is a person |
| 07:08 | Nobody holds the plan | Postgres is the queue |
| 07:29 | Where the work is | A database problem wearing an AI hat |

<details class="why" markdown="1">
<summary>Why it works — the video is the pitch, and the pages are the
contract</summary>

Nothing here is evidence. The hosts assert things that the rest of this site
either shows working or names as a cost, and where the two disagree the pages
are right: they are checked against a running database on every build and the
narration is not.

Read it as the argument for the design and then go and see whether the design
holds — [what it costs](index.html#what-it-costs) is the other side of it, and
[scaling](scaling.html) is the side with numbers in it.

<p class="related"><strong>Related</strong>
<a href="index.html">what Percolate is</a> ·
<a href="install.html">install it and find out</a></p>
</details>
