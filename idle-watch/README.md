# The fleet idle watcher

It notices the reverse of what the dispatch judge watches. The judge asks
"is this subagent call any good?", the watcher — "and why are there no calls
at all?". The mechanism is ONE (`docs/probe-core.md`), with exactly four
differences: when it is called, what it is shown, with which prompt it judges,
how it reacts.

It is NOT a gate. It cancels nothing and demands nothing: its text arrives as
a tab within the turn, and the main loop is free to ignore it — it knows more
about its own work.

## Files (read on EVERY call — editing requires no binary rebuild)

The settings of ALL probes live in one file, `~/.claude/probes/probes.toml`;
the probe keeps a directory for text and data:

| File | What it defines |
|---|---|
| `~/.claude/probes/probes.toml`, table `[probe.idle-watch]` | the model ladder, budgets, count thresholds |
| `~/.claude/probes/idle-watch/prompt.md` | the rules themselves: when to stay silent, when to name a subject |
| `~/.claude/probes/idle-watch/prompt.extra.md` | appended to `prompt.md` (a project addition) |
| `~/.claude/probes/idle-watch/body.json` | the full request template, if a custom provider or roles are needed |
| `~/.claude/probes/idle-watch/journal.jsonl` | a line for every consultation and every count refusal |
| `~/.claude/probes/idle-watch/records/` | the full request → response pair per consultation |

The effective settings = `[defaults]` with `[probe.idle-watch]` layered on
top; the probe's table is stronger. A probe not named in the file gets the
bare `[defaults]` — that is the absence of its own edits, not an error.
`enabled = false` disables the probe, and the disabling is visible in the
journal as the outcome `skip_disabled`.

The project layer is the nearest `.claude/probes` above the working directory:
`probes.toml` merges by keys, `prompt.md` and `body.json` replace,
`prompt.extra.md` is appended. The applied layer is visible in the journal via
the `cfg` field.

## Enabling

In `~/.claude/settings.json`, the `env` section:

```json
"CLAUDE_IDLE": "1"
```

Without the variable the injection does nothing. The watcher does not go to
subagents: the injection condition is `agentType === "main"`.

The probes home is set by a single variable for all probes —
`CLAUDE_PROBES_DIR`; when set explicitly, it DISABLES the project layer (the
probe must receive exactly what was given to it).

Per-run overrides: `CLAUDE_IDLE_PROMPT`,
`CLAUDE_IDLE_MODEL`, `CLAUDE_IDLE_URL`, `CLAUDE_IDLE_TIMEOUT_MS`,
`CLAUDE_IDLE_DEBUG`.

## Thresholds

```json
"live_kinds": ["local_agent","remote_agent","in_process_teammate"],
"live_threshold": 1,      // how many live works make the session occupied
"live_recheck_ms": 60000, // how soon to re-check while a work is running
"window_min": 30,         // the dispatch count window, minutes
"threshold": 1,           // how many dispatches over the window counts as sufficient
"cooldown_min": 30        // how often a reminder is possible at all
```

Session occupancy is taken from the TASK REGISTRY, not derived from dispatch
timestamps: a subagent working longer than the window dropped out of the
marks, and the session looked idle exactly while a fan-out was running. A
work counts as live if its status is `running`/`pending` and its background
flag is not stripped — the sign is taken from the image itself, not assigned
by us. `live_kinds` lists the kinds of work that count; by default only
agent ones, so a background build does not count as occupancy.

While live work exists, re-checking runs every minute, not at the end of the
window: the moment the fan-out ends is unknown, and waiting for the end of
the window would mean sleeping through an idle period that began right after
the fan-out.

Dispatch marks over the window are KEPT as a separate reading — "launched
recently" and "working right now" are different facts, and the watcher is
shown both.

While the session is younger than the window, the watcher is silent by
construction: it has not yet had time to miss anything. The current dispatch
is counted BEFORE the count, so the turn in which a subagent is launched is
silent without a separate condition.

Lowering `window_min` below a few minutes is not worth it: a consultation
takes tens of seconds, and with a short window it would arrive at work
already done.

## Verdicts

On the first line, before any justification:

```
SILENT:<reason for silence>
NUDGE:<what to dispatch right now>
```

An unrecognized answer does NOT count as a verdict — silence. With
`enforce: false` the verdict is still delivered and written to the journal,
but the reminder is not enqueued: the outcome is called `nudge_not_enforced`.

## Journal: how to read it

| `outcome` | What happened |
|---|---|
| `filtered` | a cheap-count refusal; the reason is in the `by` field: `live-work:<N>`, `fleet-busy:<N>`, `window-not-filled`, `cooldown` |
| `silent` | there was a consultation, no subject or a reason to stay silent |
| `nudge` | the reminder was delivered and enqueued |
| `nudge_not_enforced` | there was a verdict, but `enforce` is off |
| `nudge_undelivered` | there was a verdict, enqueueing failed; the reason is in the `reason` field |
| `empty` | no rung produced a verdict (the watcher is fail-open — it stays silent) |
| `skip_degraded` | settings or the prompt are broken; the consultation was NOT performed |

Every line is addressed by session: `sid` is the session identifier (it also
names the transcript file), `title` is its title, `cfg` is the applied
settings layer. `pid` is not suitable for this: the system reuses it, and
after the process dies the record points at nothing.

There must be NO line per tool call in the journal: the memory filter runs
before any I/O and writes nothing. If the journal grows on every call, it is
the filter that is broken, not the thresholds.

## Fault tolerance

The reverse of the judge's. The judge is fail-closed: unable to judge, it
cancels the call. The watcher is fail-open, and this is the design, not a
setting: it passes `arm:!1` to the core, and the obligation to do anything is
armed only at `arm && enforce && fail_closed`. The empty reactions to no
verdict, breakage, and channel failure are the policy itself.

A broken `probes.toml` or a missing `prompt.md` yield `skip_degraded` without
calling the model: a probe not knowing its own rules would get a fallback
prompt without its vocabulary and pay for a guaranteed silence.

## How to make sure it is alive

1. The journal has `filtered` lines — the injection works and the counting
   runs.
2. At least one `silent` or `nudge` line — the channel to the model is alive.
3. No `nudge_undelivered` lines — enqueueing passes.

Print mode (`claude -p`) is not suitable for verifying DELIVERY: the pending
notifications queue never reaches the model there. The journal is still kept
in full, so items 1-3 are verifiable in `-p`, while the appearance of the text
itself in the turn — only in an interactive session.

The whole design is in `docs/idle-watch.md`; the shared core contract is in
`docs/probe-core.md`.
