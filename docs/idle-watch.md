# The fleet idle watcher — architecture

The second consumer of the shared probe core (`probe-core.md`). The judge
answers the question "is this subagent call any good?"; the watcher answers a
different one: "and why are there no calls at all?". Everything between them
matches except four things, and those four are the parameters: when it is
called, what it is shown, with which prompt it judges, how it reacts.

## 1. The task and its boundary

The main loop is capable of working alone where the work could be split. This
is not a judgement error but a property of attention: an agent busy with
analysis does not ask itself whether it is time to branch out. The watcher is
an external occasion to remember this.

The reaction defines the boundary. The watcher is NOT a gate: it cancels
nothing and demands nothing. Its text arrives as a tab within the turn, and
the main loop is free to ignore it — it knows more about its own work.

The separate and more important half of the task is to STAY SILENT.
Sequential work is perfectly legitimate as a rule: the human may have
explicitly forbidden dispatches, ordered to first finish what was started, the
work may be indivisible, and the agent itself may be writing a brief — that
is, preparing a fan-out. A reminder at such a moment is worse than useless: it
pushes to break what the human built themselves. That is why the watcher's
prompt does not begin with searching for a subject but with searching for a
reason to stay silent, and the reason is sought in the transcript with a
provenance check: only an entry with `src":"user"` counts as a prohibition,
while a line from tool output does not, however it looks.

## 2. Where it lives

Two injection sites, one core (step 22 in `tweakcc-patch.js`, each between the
markers `/*__ccProbe0*/` and `/*__ccProbe1*/`). The WATCHER rides the main
dispatcher, on EVERY tool call; the JUDGE rides the dispatch tool's own `call`.
So the watcher runs FIRST — earlier than the judge, not after it, and it does
reach a call the judge will go on to cancel. This paragraph claimed the
opposite for as long as both probes shared one site, and the claim outlived the
split.

The fleet counter is maintained on every call, not only where the watcher is
invoked: counting only at the consultation point would mean never seeing
already-launched subagents. The list is capped at 256 marks — otherwise it
grows for the whole session.

The current dispatch is marked BEFORE the cheap count, which is why a turn that
launches a subagent needs no separate condition to stay silent. But a mark is a
record of a PAST dispatch, and it is not evidence about the present: the judge
may cancel the very call that left it, and any dispatch may have finished long
ago. So when the task registry is READABLE, a mark silences the watcher only
for `live_recheck_ms` — the time a fresh dispatch needs to reach the registry —
and the registry answers for everything after that. The window and the
threshold still decide when the registry cannot be read; the journal names
which of the two paths a refusal came from (`dispatch-settling` against
`fleet-busy`).

## 3. Two filters: by memory and by settings

The watcher is invoked on every tool call, so it is not only the consultation
that must be filtered out but also disk work. Hence two filters.

**The first is `pre`, in memory, before any I/O.** It looks at a single
number: `nextAt`, the moment before which the cheap count cannot converge. A
skipped pass is NOT written to the journal: it is not a consultation outcome
but its absence. A predicate throw leads to a full pass, not to a skip — a
filter failure must not blind the probe.

Without it the probe would pay on EVERY tool call: walking the tree upward up
to 24 levels with four filesystem accesses per level, reading and parsing the
settings, and a journal line — the very journal a human reads. Measured on
the carved-out code, 200 calls, a temporary directory (in a deep tree the gap is
larger): **0.137 ms for a full pass versus 0.004 ms for the filter**, and 200
journal lines instead of 400.

`nextAt` is not a polling interval but a computed moment: the window expires
at its own mark, cooldown at its own, and the fleet count drops below the
threshold when the `(n - threshold + 1)`-th oldest mark leaves the window. A
new dispatch only pushes that moment further out, so an early estimate is
safe: it costs one extra full pass, not a miss.

**The second is `gate`, by settings.** It works with settings already read
(the thresholds live in `[probe.idle-watch]` of the `probes.toml` file) and
BEFORE transcript assembly and any call to the model. Three refusals, each
with its own journal line and each setting its own `nextAt`:

| Line | What it means |
|---|---|
| `live-work:<N>` | `>= live_threshold` works of a suitable kind are alive right now — the session is occupied as a FACT |
| `fleet-busy:<N>` | there were already `>= threshold` dispatches within the window — the fleet is not idle |
| `window-not-filled` | the session is younger than the window: it has not yet had time to miss anything |
| `cooldown` | a reminder was recent; repeating it is noise |

The order of refusals is not accidental: live work is checked FIRST, because
it is the fact, while dispatch marks are its consequence. A mark lives exactly
one window and lies in the dangerous direction: a subagent working longer than
the window drops out of it, and the watcher would take a fan-out for idleness.
The task registry does not allow this.

Unavailability of the registry is NOT masked as "no work": it is declared by
the `task_registry_readable` field in the payload. Otherwise blindness would
be indistinguishable from silence — the very class for which the rule
"silence must be distinguishable from blindness" was established.

A refusal is written to the journal as `outcome:"filtered"` with a `by` field.
Without this record, "was not called" and "was called and stayed silent"
would be indistinguishable from the outside, and these are two different
outcomes with different causes.

The transcript is assembled AFTER the filter and the cheap count — otherwise
a filtered-out call would pay for transcript assembly and trimming for a
consultation that will not happen. Taking the snapshot of the turn remained
ABOVE: otherwise a filtered-out call would leave a record in the turns table
forever.

## 4. What is shown

The transcript is shared with the judge — records `{src,text}` with
provenance, pinning of the human's words during trimming, a declared omission,
and a budget in JSON characters. On top of it, the `=== FLEET ===` block with
five fields:

- `live_works` — how many works of a suitable kind are alive RIGHT NOW;
- `task_registry_readable` — whether the task registry was read at all (false
  means blindness, not absence of work);
- `spawns_in_window` — how many subagents were launched within the window;
- `window_min` — the window length in minutes;
- `current_tool` — the tool the agent is occupied with at that second.

The last field is about the current moment, not the intent, and the prompt
says so explicitly: reading a file does not mean scouting, launching a build
does not mean waiting.

## 5. Vocabulary and reaction

`SILENT` and `NUDGE`; only `NUDGE` has an action. On the first line, before
any justification — the answer may be cut off by the limit, and it is the
explanation that must be lost, not the decision.

The reaction is enqueueing into the pending notifications queue, the same one
through which background task results arrive mid-turn:
`tv({value:"[fleet-idle] …", mode:"task-notification", agentId:Di(), priority:"next"})`.

The channel was chosen by its design, not by taste: from inside an executing
tool the message array is entirely unreachable — attachments are assembled
only AFTER the whole batch — so the judge's throw is inapplicable here.

Both addressing fields were MEASURED against the installed image, and this
cost a separate round: the `typescript-src` reconstruction says the main loop
merges records with `agentId===undefined`, while in the 2.1.239 image the
merge predicate is `dA(e)` = `e.agentId===Di()`, meaning the address is the
SESSION identifier. A fix "per the reconstruction" would have broken delivery
without touching a single patch site. The priority is `next`, not `later`:
the merge threshold equals `later` only in a turn where Sleep fired, so a
`later` record would wait for Sleep indefinitely.

An enqueueing failure is NOT swallowed: it goes to the journal as
`nudge_undelivered` with a reason. A silent `catch` here would mean "the
journal says nudge, there is no delivery" — exactly the form where a mechanism
is formally alive and substantively off. Dropping a working call because of a
reminder is still impermissible, which is why the outcome is recorded rather
than thrown.

## 6. Failure policy — the reverse of the judge's

The judge is fail-closed: unable to judge, it cancels the call. The watcher is
fail-open, and this is not a setting but the design: it passes `arm:!1` to the
core, and the obligation to cancel is armed only at `arm && enforce &&
fail_closed`. The empty `onNoVerdict`/`onBroken`/`onFail` are not stubs "for
later" — they are the policy itself.

Broken settings or a missing prompt yield `outcome:"skip_degraded"`, and the
consultation is NOT performed at all. A probe not knowing its own rules has
nothing to judge by, so asking would be paying for an answer already known to be
worthless. (Until the fallback prompt moved out of the shared core into each
caller it also spoke only the judge’s vocabulary, so for the watcher this skip
was the only thing between a missing prompt and an endless run of unparsable
consultations.)

The outcome word in the journal is the verdict class in lower case (`silent`,
`nudge`, `nudge_not_enforced`). The core does not know the judge's vocabulary:
the `block` baked into it would write the watcher's silence with the same
signs as a real judge's cancellation.

## 7. Settings

Settings live in `~/.claude/probes/probes.toml`, the `[probe.idle-watch]`
table on top of `[defaults]`. The probe's own directory
`~/.claude/probes/idle-watch/` carries `prompt.md`, `journal.jsonl` and
`records/`; the project layer `.claude/probes` above the cwd is merged by the
same rule as the judge's, and `prompt.extra.md` is a file of THAT layer only —
there is no home-directory appendix, because a home prompt has nothing to
append to but itself. The switch is `CLAUDE_IDLE`; the
overrides are `CLAUDE_PROBES_DIR` (the probes home), `CLAUDE_IDLE_PROMPT`,
`CLAUDE_IDLE_MODEL`, `CLAUDE_IDLE_URL`, `CLAUDE_IDLE_TIMEOUT_MS`,
`CLAUDE_IDLE_DEBUG`.

Beyond the core schema, the `[probe.idle-watch]` table carries six cheap-count
fields: `live_kinds`, `live_threshold`, `live_recheck_ms` (occupancy by the
fact of live work) and `window_min`, `threshold`, `cooldown_min` (counting by
dispatch marks). All six are written into the file EXPLICITLY rather than left
to code defaults: a setting absent from the file is not configured by a human
— they will never learn of it.

## 8. How it is verified

`claude-patch-all.sh` — 116 checks. `tools/probe-bench.js` — scenarios on the
live carved-out code, of which the watcher's are: both verdicts,
the memory filter, all cheap-count refusals (each verified by its REASON —
they share the same outcome, and a swapped branch would pass green), live
work, stripped backgroundness, a non-agent kind of work, an empty registry, a
MISSING registry, broken settings, `enforce` turned off.

The bench runs **under `bun`** and refuses to work under node. The image is a
single-file bun executable, the carved-out block runs on its engine: under
node the parse error texts differ and the `Bun.*` API is absent. Before the
gate existed, the broken-settings scenario observed the node message
(`Expected property name or '}' in JSON at position 1…`, further truncated by
our trimming), while in production the short bun message arrives
(`JSON Parse error: Expected '}'`) — the bench was verifying a text that does
not exist in the product. A bun version mismatch (bench versus image) is
declared as a warning, not hushed up. The mismatch was closed 2026-08-24: the
bench's bun was brought up to 1.4.0.

It paid off immediately: on 1.3.14 `Bun.TOML` refused to read `x = [[1]]`,
and this nearly made it into the settings design as a constraint. The image's
version reads such a record — there is no constraint. A property of someone
else's runtime, measured on the wrong runtime, looks like a property of the
product.

The layered scenario reproduces the project layer ONLY by changing `HOME` and
the working directory: the layering branch in the core stands under
`if(!dirEnv)`, meaning an explicit `CLAUDE_PROBES_DIR` disables layering. A
bench that set the directory via a variable would be testing not the path by
which the layer is found in production.

WHAT IS CONFIRMED BY LIVE RUNS. The consultation happens at the right moments,
stays silent for the named reason, delivers a substantive NUDGE, the ladder
moves to the second rung, the filter works, enqueueing passes WITHOUT error
(not a single `nudge_undelivered` line in the journal). The run of 2026-08-24
on a separate session closed the rest with facts: `task_registry_readable:
true` (the task registry is read right at the injection point — previously
only the bench stub proved this), nine `live-work:<N>` filters, `sid` and
`title` in the records, `msrc: "agent"` on a dispatch without an explicit
model, and the project layer (`window_min: 1` against the production 30, `cfg`
with the layer's path).

WHAT IS NOT YET PROVEN. The appearance of the reminder text IN THE TURN ITSELF
has NOT been observed — the runs were in print mode (`-p`), where the queue
never reaches the model. This must be verified in an interactive session:
print mode is not suitable for it.

A MEASUREMENT PROTOCOL TRAP, paid for with 41 wasted calls: one cannot hold a
live background work and wait for a consultation at the same time — while
live work exists there is no consultation BY DESIGN. Verify measurement steps
for whether one suppresses the other's observability.

A pattern in the image proves presence, not functioning: once all of the
judge's checks were green exactly when it cancelled nothing (a regex assembled
from a string with a single slash degenerated the vocabulary). That is why
the bench is mandatory, not merely desirable.
