# The probes registry — spec

Status: **implementation not started**. Written 2026-08-24, after the basis
underneath it had been verified by a live run (see "What has already been
measured").

The settings layout is **ratified by the human on 2026-08-24** ("agreed"):
one `probes.toml` for all probes in the shared home, prompts as separate
files. Everything else in this document remains a proposal.

## Why

Today the image has two consumers of the shared core `globalThis.__ccProbe`:
the dispatch judge and the fleet idle watcher. They differ in **exactly four
parameters** — when to call, what to show, which prompt to judge by, how to
react — but those four are baked into the binary in two places. Adding a
third watcher today means patching and reinstalling the image.

The registry moves the LIST of consumers out of the image and into files.
A watcher for a new situation is then introduced by editing a directory,
not by rebuilding the binary, and is overridden per project on the same
footing as the other settings.

Motivating examples (from the human, 2026-08-24):

- **model coverage** — remind that a model admitted to measurement has not
  received a single dispatch, or received them all in one lens only (a
  measurement in someone else's strong lens gives no honest picture of
  capabilities);
- **build hygiene** — watch that agents do not build locally all the time,
  only when it is genuinely needed;
- **rule-compliance checking** — with skipping the work by default, so that
  there are no false blocks by construction.

## What has already been measured (the basis)

Everything below is confirmed by fact, not inferred.

| fact | confirmed by |
|---|---|
| 31 kinds of hook event are constructed in the image | enumeration of the literals `hook_event_name:"…"` |
| events converge into the funnel `t4({session,getAppState,hookInput,…})`, with the `yB` generator on top | 17 emission points via `yB`, 11 direct calls of the `t4` form |
| EVERY event carries the common part `session_id, transcript_path, cwd, prompt_id, permission_mode, agent_id, agent_type, effort` | schema parse in `YP()` |
| `Stop`/`SubagentStop` carry `background_tasks` and `session_crons` | event schema; the builder `Yuh(taskRegistry.all())` |
| the task registry is read DIRECTLY at the injection point | in the field: `task_registry_readable: true` in the consultation payload |
| the sign of live work — `status running|pending` and background-ness not lifted | `_L` in the image; in the field, 9 `live-work:N` filter hits |
| the project layer of settings is applied and named in the record | in the field: `window_min: 1` instead of the field value 30, `cfg=/tmp/watch-probe/.claude/idle-watch` |
| the record is addressed by session and its title | in the field: `sid=0ed12ae4`, `title=CC-Pathc-Test2` |
| the dispatch model is resolved from the agent definition | in the field: `model=glm-5.3`, `msrc=agent` when called without a model |
| TOML parsing in the image runtime is free | the image is a single-file bun 1.4.0 executable (`bun/1.4.0 npm/…` in the native part, self-update address `bun-v1.4.0`); the bundle contains a `Bun.TOML` call; parsing verified on bun 1.3.14 — comments are stripped, nested tables yield nested objects |
| the bench can run on the same runtime as the image | `bun tools/probe-bench.js` — 32/32 docnum:historical without touching the scenarios at measurement time (36 scenarios after the move to `probes.toml`) — docnum:historical, обе цифры про прошлые сборки; the runtime gate added 2026-08-24 |
| the image's TOML version reads nested arrays | on bun **1.4.0** (the image version) `x = [[1]]` parses. On 1.3.14 it fails: the lexer greedily read `[[` as an array-of-tables header. The defect is someone else's and closed before us; it does NOT affect the design |

Still open: the full trace `yB → sdh → adh → … → t4` has not been followed.
This does not affect the choice of injection point (both forms lead into
`t4`), but it should be written down.

## Model

All settings of all probes live in ONE file; each probe keeps a directory
for its text and data:

```
<home>/probes/
    probes.toml          # ALL settings of ALL probes; merged across layers
    <id>/
        prompt.md        # what to judge by; replaced wholesale
        prompt.extra.md  # appended to the inherited one
        body.json        # full request template (optional)
        journal.jsonl    # the probe's records
        records/         # the corpus of consultations
```

`<id>` is the table key in `probes.toml`, the directory name, and the field
in the journal. The current probes' identifiers are **`judge`** and
**`idle-watch`**, i.e. their present directory names: the id is visible in
journals, `validate.py`, the kit, and memory records, and renaming would
multiply the migration surface while giving the mechanism nothing.
The judge and the fleet watcher become entries of this same registry (see
"Migration").

**Why settings in one file, but not prompts.** A human-facing setting is a
number and a list; those are convenient to see side by side and compare
across probes, and TOML additionally carries comments (today the meaning of
`window_min` lives only in the README next to it). A prompt is a
multi-kilobyte markdown that is edited an order of magnitude more often
than settings (`judge/prompt.md` was rewritten even on the ratification
day). Folding prompts into the shared file widens the blast radius: today
a broken settings file takes out ONE probe — and even that had to be fixed
separately, it silently unset `enforce`, — while an accidental delimiter
inside a nested prompt would break parsing for ALL probes at once.

Journals and records stay in the per-probe directories: that is data,
written line by line and in parallel; merging them into a shared file makes
no sense.

**Why TOML and not JSON.** Comments. The home already keeps this pattern —
`routing-override.toml`. Parsing is free: the image is built with bun,
`Bun.TOML.parse` exists in the runtime and is already used by the bundle.
The price is named and paid — the bench must run under bun, otherwise it
measures a different engine (gate added 2026-08-24).

### probes.toml

```toml
# Default values for all probes; a probe's own table overrides them.
[defaults]
max_tokens      = 24000
timeout_ms      = 240000
context_chars   = 24000
cooldown_min    = 30
dispatch_chars  = 16000

[probe.judge]
enabled = true                   # disables the probe entirely
on      = ["PreToolUse"]         # trigger events; see the vocabulary
show    = ["dispatch"]           # what goes into the payload
act     = "cancel"               # log_only | nudge | cancel
rx      = "OK|WARN|BLOCK"        # the verdict vocabulary

  [probe.judge.when]    # predicate; see the vocabulary
  field = "tool_name"
  in    = ["Agent", "Task"]
```

Precedence of values: `[defaults]` → the probe's table → the same path in
the project layer. The keys of the ladder, budgets, and transcripts are
inherited from the current judge and watcher settings unchanged — the
registry does not reinvent them.

The form above is parsed by `Bun.TOML.parse` and yields exactly the expected
structure.

### The predicate vocabulary

A condition is **data, not code**. Executable expressions from the config
are forbidden: a broken `config.json` once silently unset `enforce`, and
turning settings into code would widen that very class. Hence a fixed
vocabulary of predicates over already-collected state.

Sources available to a predicate:

1. **Event fields.** The common part (8 fields, always present) plus each
   of the 31 kinds' own: tool and its input/output/error,
   `background_tasks`, `session_crons`, `agent_type`, `session_title`,
   `permission_mode`, the compaction `trigger`, `task_*`/`teammate_*`,
   `file_path`, `reason`, and the rest.
2. **In-process sources.** The core runs inside the process and takes the
   same things the event fields are built from: the task registry, the cron
   registry, agent definitions. No need to wait for a specific event for
   this.
3. **Our own states.** Process age, time since the previous consultation of
   THIS watcher, the outcomes of its past consultations, window counters.
4. **Our journals and roster files.** The census of "who worked on what" is
   already kept by the judge's journal; the roster of models and classes
   lives in `routing-override.toml`.

Predicate forms (a closed list):

| form | meaning |
|---|---|
| `equals` / `in` | field equals a value / belongs to a list |
| `matches` | field matches a regular expression |
| `count_at_least` / `count_below` | list size (live works, window dispatches) |
| `older_than_min` / `newer_than_min` | how old a mark is |
| `absent` / `present` | field exists or not |
| `all` / `any` / `not` | combinations of the above |

A condition is written with **named keys**, not positional pairs: it has a
`field` and exactly one form key.

```toml
  [probe.judge.when]
  field = "tool_name"
  in    = ["Agent", "Task"]
```

A combination is an array of tables, one condition per table:

```toml
  [[probe.idle-watch.when.all]]
  field       = "live_works"
  count_below = 1

  [[probe.idle-watch.when.all]]
  field          = "last_consultation"
  older_than_min = 30
```

The positional form (`in = ["tool_name", ["Agent","Task"]]`) was rejected
for readability: the meaning of an element is fixed by its place in the
array, and adding a condition form would silently change it for everyone.
Named keys are self-describing and produce no nested arrays at all.

A caveat about how this argument took shape. At first the positional form
was rejected as UNPARSEABLE — the bench ran under bun 1.3.14, where
`x = [[1]]` fails. The image version (1.4.0) reads it, so the "unparseable"
argument turned out to be a property of the wrong runtime. The form stays
named for the reason above, but recording it here should have been done as
a measurement on the image's runtime. The same case the bench's runtime
gate was added for.

The vocabulary can be extended only by a new form in the image, with a
check and a scenario on the bench. That is the price that keeps the config
data.

### Actions

| `act` | what it does | channel |
|---|---|---|
| `log_only` | writes the verdict to its own journal, stays silent | — |
| `nudge` | puts a reminder into the pending-notification queue | the same the watcher uses today |
| `cancel` | cancels the call by throwing | the same the judge uses today |

The third action will require work in the image — there are exactly two
channels today.

## Layers

Order: **built-in base → global home → nearest `.claude` above cwd**
(≤24 levels), the later one wins. The mechanism is already implemented and
field-verified: the settings file is merged by keys, `prompt.md`/`body.json`
are replaced wholesale, `prompt.extra.md` is appended, and the applied
directory is named by the `cfg` field in every journal line.

The project layer is `<project>/.claude/probes/probes.toml`; it is merged
by inner paths, not replacing the file wholesale. A project may: override
any key of any probe, **disable** a probe (`enabled = false`), **add** its
own (a new `[probe.<id>]` table plus a directory with a prompt).

An explicit `CLAUDE_PROBES_DIR` disables the layering — by design: a probe
must receive exactly what was set for it. The registry preserves this
behavior; the current `CLAUDE_JUDGE_DIR` and `CLAUDE_IDLE_DIR` collapse
into one variable.

## Against vacuous operation

The main danger of the registry is not cost but that watchers will multiply
and some of them will run vacuously while looking alive. Requirements
without which the registry must not be accepted:

1. **`log_only` is the default for a new watcher.** The right to speak, let
   alone cancel, is granted separately and explicitly. False blocks are
   then absent by construction.
2. **Incubation.** A day in `log_only`; a voice — only after the corpus of
   records has been read by a human.
3. **Silence is distinguishable from blindness.** Every record must carry:
   whether the transcript was trimmed, whether the verdict was parsed,
   whether the predicate's sources were read. An unreachable source is
   declared by a field, not passed off as "nothing there" — the
   `task_registry_readable` precedent.
4. **Emptiness is counted.** By `id` from the journal it must be countable:
   called → reached the model → produced a parsed verdict → produced a
   finding. A watcher with zero findings over N consultations is either
   impeccable or blind, and TELLING THEM APART must be possible FROM THE
   RECORD.
5. **A shared cap per session, not per watcher.** Otherwise ten watchers
   with freewheeling conditions will multiply traffic without anyone's
   decision.
6. **We count, the model judges.** The watcher is fed a computed table,
   not raw material to recompute. Recomputation is where claims break.
7. **A mechanically decidable condition is not handed to the model.** If a
   regex or a ready utility answers it, the condition belongs in a cheap
   predicate, not in a consultation.

## Migration

Both current consumers are expressible through the vocabulary in one file
(the form below is parsed by `Bun.TOML.parse` wholesale, together with the
`[defaults]` from the "Model" section):

```toml
[probe.judge]
enabled = true
on      = ["PreToolUse"]
show    = ["dispatch"]
act     = "cancel"
rx      = "OK|WARN|BLOCK"

  [probe.judge.when]
  field = "tool_name"
  in    = ["Agent", "Task"]

[probe.idle-watch]
enabled      = true
on           = ["PostToolUse"]
show         = ["fleet", "tool"]
act          = "nudge"
rx           = "SILENT|NUDGE"
cooldown_min = 30

  [[probe.idle-watch.when.all]]
  field       = "live_works"
  count_below = 1

  [[probe.idle-watch.when.all]]
  field       = "spawns_in_window"
  count_below = 1

  [[probe.idle-watch.when.all]]
  field          = "last_consultation"
  older_than_min = 30

  [probe.idle-watch.gate]
  live_kinds      = ["local_agent", "remote_agent", "in_process_teammate"]
  live_threshold  = 1
  live_recheck_ms = 60000
```

**Moving the live directories.** `~/.claude/judge/` and
`~/.claude/idle-watch/` are working right now and hold journals and the
corpus of records. The settings from both `config.json` files are folded
into one `probes.toml` once; the prompts move to
`probes/<id>/prompt.md`. The old directories **stay in place** as
historical journals — reading settings from two sources is forbidden;
that is exactly the class where silent divergence lives. The switch-over
moment must be exactly one.

**A caveat about the cancellation channel.** Today the judge throws from
inside the executing tool, and the cancellation arrives as a `tool_result`
with `is_error` — with an explanation the loop reads. The hook side offers
a different channel (`permissionBehavior: deny`), and that is DIFFERENT
observable behavior. So `act: cancel` either keeps the current injection,
or moves to the deny form only after equivalence is proven on the bench.
Swapping the channel silently is not allowed.

**The implementation readiness criterion:** every bench scenario (36 today)
must pass on the registry implementation without editing expectations. If
the judge's or the watcher's behavior changed — the registry is not ready,
not "the bench is outdated".

## Open questions

- The full trace `yB → … → t4` has not been followed (does not affect the
  choice of injection point).
- The form of the shared per-session cap on consultations has not been
  chosen.
- The bench runs under bun of a **different version** than the image
  (1.3.14 vs 1.4.0): the gate warns about it, but the divergence is not
  closed. Closing it means installing the image's bun version — a change
  to the human's environment, a separate decision.
- The list of probes is no longer a question: the list IS the
  `probes.toml` itself; walking the directory on every probe is unneeded.
  What remains is choosing the moment the file is re-read (today settings
  are read on every consultation).
