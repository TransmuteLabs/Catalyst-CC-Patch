# Porting the judge to a Claude Mod — specification

Written by the controller personally (adjudication is not delegated).
Companion to `judge-architecture.md` (what the judge IS) and
`judge-patch-spec.md` (how the splice was built). This document says what
the judge BECOMES when its carrier changes from a binary splice to a
function-hooks module, and what must NOT change with it.

Live carrier (2026-09-12): one plugin `catalyst-probes@catalyst` in
`TransmuteLabs/Catalyst` (`plugins/catalyst-probes/`). The module is the
core; consultants are `[probe.<id>]` in `probes.toml`. The kit `mods/`
directory is not the live install.

Status: design, rewritten 2026-09-11 evening against the live measurements
in `project_function_hooks_recon.md` (ПОЛНАЯ КАРТИНА ПОРТА) and the probes
under `/tmp/t113-*` and `/tmp/t113-full/`. The  morning ratification
"rebuild AND raise the host budget with a one-line patch" is **half-void**:
rebuild stands; the budget patch is closed negatively (bytecode, operand
`1e4` not addressable). No splice is removed from the image until this
carrier has been measured live — the standing honesty boundary of task
#116. `CLAUDE_JUDGE_CARRIER=mod` stands the splice down without deleting it.

---

## 0. The user's decision

> «логику работы прокси оставляем патчем а остальное пишем модом»
> (2026-09-11), then: the patch stays but shrinks; it becomes a patch for
> *capability*, features go in the mod («да, двигайся в этом направлении»).

What that means after the measurements:

* **Proxy stays a patch.** Three controls: core inference does not pass
  through `$.model.complete`; rewriting `turn.start` does not change the
  answer; `turn.step` arrives with a finished answer.
* **Judge and prompts go in the mod.** The 10 s host budget is not raised
  (cannot be). The judge holds a refusal by construction: inverted
  fail-closed, not by waiting inside the hook.
* **tweakcc does not go away** — the proxy splices keep it. The insertion
  shrinks.

The capability the remaining patch grows is one environment variable:
`CLAUDE_JUDGE_CARRIER=mod` makes injection 22 and injection 26 no-ops so
the two carriers cannot double-judge. Default (unset) is the splice.

---

## 1. The measurement that governs this design

### 1.1 The host's hook budget is 10 000 ms and it is FAIL-OPEN

Measured 2026-09-11, mac, patched 2.1.267, probe `/tmp/t113-failopen/probe`.
A hook on `tool.call` slept 20 000 ms and returned `{deny:"ZQ-DENY: …"}`.
The host printed:

```
[ERROR] hook failed: probe: exceeded 10000ms budget
        (tool.call; skipped; what is below it ran in its place)
```

**The tool executed; the refusal was lost.** Neighbouring constants of
the same measurement: grace after an abort `h0e = 5000`; core handlers
declared `budgetMs:0` (no limit); classic config-file hooks get `timeout
600000ms`.

This directly contradicts the judge's shipped mode: `[defaults] enforce =
true` plus `[probe.judge] fail_closed = true`.

### 1.2 The live judge does not fit in that budget — and not marginally

Counted by the controller over the live journal
`~/.claude/probes/judge/journal.jsonl`, 5997 records,
2026-08-24T11:20 → 2026-09-11T09:41:

| quantile | latency |
|---|---|
| p50 | 36 747 ms |
| p75 | 57 290 ms |
| p90 | 87 330 ms |
| p95 | 111 040 ms |
| p99 | 193 713 ms |
| max | 890 272 ms |

| threshold | records above it |
|---|---|
| > 10 000 ms | **97.85 %** |
| > 30 000 ms | 63.03 % |
| > 60 000 ms | 22.78 % |

A port that only "re-fits the judge under 10 s" would lose the verdict on
ninety-eight of every hundred dispatches — silently, by fail-open, in the
direction of approval.

### 1.3 The 840-second tail is the ladder's own worst case, not a hang

Twenty records exceed 600 s; nineteen of them carry `tries: 4`. The
shipped per-rung `timeout_ms` is 240 000 ms; a ladder walked to exhaustion
costs `240 + 240 + 240 + 120 = 840` seconds — exactly the 840 019 ms
observed.

### 1.4 A fast rung exists, and size is not the 36 s

From inside `tool.call`, `$.model.complete` with `deepseek-flash` returned
`ALLOW` in **2008 ms** (toy prompt). Detached, the same verb with a 44 000
byte pad (combat prompt home is 42 588 bytes) returned `ALLOW` in **2877
ms** (`/tmp/t113-full/p7-long`). The 36.7 s median is the judge's ladder
and reasoning, not the prompt's length, and not the carrier.

### 1.5 The budget operand is not patchable

Measured 2026-09-11 with a positive control of form (8233 boxed-ints in
the image; 10000 not among them). The hook engine runs from bytecode; its
JS text is inert. `var b0e=1e4` / `budgetMs:n=b0e` (linux `dPe`) is that
inert text. Three `double 10000.0` hits are the native dtoa table, not a
JS constant. `engine.create` adds nouns; it does not lift `budgetMs`
(same worker). There is no host setting. Path (b) of the morning
decision — raise the limit with a locator — is closed.

### 1.6 Detached work is not charged against the 10 s

The 10 s clock is the *awaited* duration of the hook. A promise started
without `await` and finishing after `return` is not charged:

* `/tmp/t113-defer`: sleep 2003 ms after `next()`, no `exceeded` line.
* `/tmp/t113-full/p1-det-complete-next`: `$.model.complete` ALLOW in 3924
  ms after `next()`, log line after the model's `stop`.
* `/tmp/t113-full/p8-synth`: complete ALLOW in 1706 ms after `{deny}`,
  retry saw `OK:ALLOW`.

The 50 s of judge thinking the operator asked about is this path: it is
not in the 10 s.

A `-p` process that exits before the background finishes kills it
(`/tmp/t113-full/p3-death-sleep`, 15 s sleep, 14.5 s wall, no `bg.json`).
An interactive session keeps the process; the background lives with it.

---

## 2. The invariant that replaces fail-open

> **The awaited body of `tool.call` returns in milliseconds. The
> consultation is detached. A missing verdict is a refusal, never a pass.**

The host cannot be made fail-closed — its abort path skips the hook and
runs what is below it. Therefore the mod must never be the party that
runs out of time. It does not await the ladder. It writes PENDING, returns
`{deny}`, and lets the background write the verdict into `$.store`. A
retry that still sees PENDING is the same deny (no second ladder). A
retry that sees BLOCK/NONE is a final refusal. A retry that sees OK/WARN
calls `next(e)`.

The 10 s host budget is a wall around the awaited body, not a deadline
for the judge. 50 s of thinking is normal (p75 57 s) and happens in the
background.

---

## 3. Architecture — two stages, inverted fail-closed

The splice's obligation flag (`__jarm`) ports in MEANING: armed as soon as
the call is not filtered out and `enforce` + `fail_closed` are on;
cleared only by the last action of a successful path. On this carrier the
flag *is* the PENDING record in `$.store`. Leaving the hook without a
record already in store leaves with `{deny}`.

### Stage 0 — the selector (synchronous, small I/O)

Combat stage 0 (`tweakcc-patch.js` ~3040–3105) is a filter «judge or not»,
not a set of routing refusals. It reads `probes.toml` (measured 1–2 ms
for a 7888-byte fixture plus regexp plus branch, `/tmp/t113-stage0`),
honours `enabled`, `classes_skip` / `agents_skip` / `classes_judge` /
`agents_judge`, and the `__ask` flag. Refusals of the *dispatch* are
issued by the model later, not here.

This stage fits the 10 s budget with a ~5000× margin. `{deny}` from a
synchronous return is delivered verbatim (positive control). An
artificial overrun still loses the deny (negative control).

A missing or unparseable rule set does not skip the call: the module
still arms PENDING and consults (fail-closed on the judgment itself). A
filter match (`classes_skip` etc.) calls `next(e)` and writes
`filtered` to the record.

### Stage 1 — inverted fail-closed (the whole ladder)

Reached only when stage 0 says judge. The awaited hook:

1. reads `$.store` at a digest of the dispatch (`tool|agent|prompt`), not `tool_use_id` — a retry mints a new id (measured: 64 denies / 63 ladders on one Agent ping when keyed by id);
2. if PENDING / BLOCK / NONE / OK / WARN — returns as in §2, no I/O;
3. if empty — `$.store.set(PENDING)` **before** the deny (without this,
   a retry storm starts a new ladder each time; measured `/tmp/t113-full/p2`
   four completes, `/tmp/t113-full/p4` one);
4. starts a detached ladder (`$.model.complete` on `deepseek-flash`,
   then `glm-5.3`, then `gpt-5.6-terra`);
5. returns `{deny: PENDING_MSG}` in milliseconds.

The detached ladder writes OK/WARN/BLOCK/NONE into the same key and a
per-record file under `records/mod-<id>.json`. Parsing of the verdict is
unchanged: first line `^(OK|BLOCK|STOP|DENY|WARN):`, else last such line
in the body (architecture §7).

`$.model.complete` returns a STRING; there is no cancellation handle. A
rung that hangs is abandoned by walking to the next after the call
throws, not by aborting it.

### Prompt rule (replaces injection 26)

`on("prompt.section")` for `communication:L` appends, in English:

* if the tool error says adjudication is in progress: wait and repeat
  the SAME dispatch unchanged;
* if the tool error names a correction: apply it, never repeat the
  identical call.

The two must not be collapsed. Measured (`/tmp/t113-full/p2c`): deny
text «wait and repeat the SAME» with no verdict yet is a retry storm
(68 denies, killed). Measured (`/tmp/t113-full/p2b`): «all tools
blocked» is a stop. Measured (`/tmp/t113-full/p2`): a Read-only deny is
walked around with Bash `head`. This module therefore intercepts
`Agent` and `Task` only (the splice's own gate) and the PENDING text
names «do not switch to Bash».

Grok-4.6 without coaching will not wait 50 s. The section is load-bearing.

---

## 4. Carrier map

Every row is measured.

| What the splice does | Mod carrier | Evidence |
|---|---|---|
| intercept before the tool runs | `on("tool.call")` | fires once per call |
| cancel the dispatch | return `{deny:"text"}` | `<tool_use_error>`, `toolDenialKind=permission-rule` |
| main loop only | `!("agentId" in e)` | `agentId` only on a subagent's call |
| Agent / Task only | `e.tool === "Agent" \|\| e.tool === "Task"` | same gate as the splice (`$2.name`) |
| which agent | `e.subagent_type`; `$.agent.list()` if needed | spawn also carries `model, parentModel` |
| consultation | detached `$.model.complete({model, prompt})` | proxy ids pass; invented id → HTTP 400; after deny: p8 1706 ms ALLOW |
| transcript | `await $.session.messages()` | Promise; whole conversation; `"toolResults" in m` |
| journal | unique `records/mod-*.json` + `journal.jsonl.shard.<rec>`; `compact.py` `fold_journal_shards` | `$.fs.write` overwrites; RMW of the combined jsonl replaced 6302 lines with one (2026-09-12). Never RMW the index. |
| switch, home | `$.env.get("CLAUDE_JUDGE")` etc. as a **string literal** | scan lists the names; object form is rejected |
| rule in the system prompt | `on("prompt.section")` | both return forms proven (`ZQA`/`ZQB`) |
| extra methods | `on("engine.create")` then `{...await next(e), noun:{ method(){} }}` | `$.zqprobe.ping()` = PONG in 0.7 ms; does not lift the budget |

`e` on `tool.call` is FLAT (`e.input` is undefined). Read has `file_path`;
Agent/Task have `prompt`, `subagent_type`, `model` on `e` itself.

### 4a. Transcript fidelity

Measured `/tmp/t113-tx`. Awaited `$.session.messages()` is the whole
conversation (3→5→7). Provenance is structural: a tool RESULT is `role
user` plus the extra key `toolResults`; the substance of a result rides
the assistant element's `toolUses[i].result`. Residue: service insertions
and cross-session letters were not in that run.

---

## 5. What the carrier's form costs the port

1. Event name — string LITERAL in `on("...")`.
2. `$` is not indexed dynamically, not reached through `?.`.
3. `$.noun` is not READ as a value — only `$.noun.verb(...)`.
4. A green `plugin validate` can coexist with a module that never loaded.
   Acceptance reads `hooks module … loaded` and `$ built for …` from
   `--debug-file`.
5. `engine.create`: the value of `next(e)` must not be used in a
   `BinaryExpression` and must not be passed as an argument.
   Spread `{...await next(e), noun:{ ping(){} }}` is legal. An interface
   is an object of **functions**, not `{owner, methods}`.
6. `$.clock.sleep` is milliseconds.
7. Two tools in one assistant message = concurrent hooks. `$.store` keys
   are per `tool_use_id`; a shared key races (`/tmp/t113-full/p5-race`,
   both empty in the same millisecond).
8. `$.env.get("NAME")` — the name is a string literal so the scan can
   list it.

---

## 6. The journal

`$.fs.write` overwrites; there is no append verb. Design:

* one file per consultation, `records/mod-<tool_use_id>.json` (id is unique
  per attempt; the *verdict cache* is the dispatch digest);
* an index line as a unique sibling `journal.jsonl.shard.<rec>` (one
  line). `$.fs.write` overwrites the whole path; RMW of `journal.jsonl`
  is fail-open on a short/failed read (measured 2026-09-12: 6302 lines /
  5.7 MB replaced with one). Unique record files remain the source of
  truth.
* `judge/compact.py` `fold_journal_shards` appends those siblings with
  Python `open(..., 'a')` and deletes the shard after read-back;
  `fold_mod_records` still inserts any `mod-*.json` whose `rec` is not
  yet in the index (idempotent; nightly launchd).

The home of the files is the probe home: `CLAUDE_PROBES_DIR`, else
`CLAUDE_CONFIG_DIR/probes`, else `~/.claude/probes` (same ladder as the
splice, круг 21 F-8). Isolated `CLAUDE_CONFIG_DIR` no longer leaks into
the live journal.

---

## 7. The budget patch — CLOSED NEGATIVELY

There is no line in the patch layer that raises `budgetMs`. §1.5. The
morning locator (`budgetMs:n=<NAME>`, `var <NAME>=1e4` → `3e5`) would
edit inert text. Do not ship it. Do not keep a reserved slot for it.

`CLAUDE_JUDGE_CARRIER` is the only new patch surface, and it is a
stand-down, not a budget change.

---

## 8. Acceptance

A port is accepted only with all of these, each with its own control:

1. `hooks module catalyst-judge loaded` and `$ built for catalyst-judge`
   in `--debug-file`.
2. Stage 0 filter: a `classes_skip` match calls `next(e)` (tool runs);
   a class the judge list names is denied PENDING on the first call.
3. PENDING is one ladder: a coached retry does not start a second
   `$.model.complete` (`bgStarted === 1`).
4. A BLOCK verdict on the retry is `{deny}` naming the reason; the
   Agent/Task does not run.
5. An OK verdict on the retry calls `next(e)`; the Agent/Task runs.
6. The awaited hook never prints `exceeded 10000ms budget`.
7. With `CLAUDE_JUDGE_CARRIER` unset, this module is inert and the splice
   still judges (negative control on the stand-down).
8. `block` and `block_no_verdict` (NONE) remain distinguishable in the
   record file.
9. No splice is deleted from `tweakcc-patch.js` until a live journal of
   this carrier matches today's outcomes on the same traffic.

---

## 9. Open items — measure before relying

* Service insertions and cross-session letters in `$.session.messages()`
  (two of the four `user`-role kinds in architecture §6).
* `$.model.complete` with the *text* of the combat judge prompt (size is
  measured; reasoning latency of that text in the detached verb is not).
* Uncoached retry on opus/fable (measured on grok-4.6).
* Background lifetime in an interactive session (measured killed under
  `-p` when the process exits).
* Project-layer `probes.toml`: `$.fs.ancestors` is **CLOSED NEGATIVELY**
  for this (host check: names must each be a `.md` file). The splice
  walks `process.cwd()` 24 levels; `process` is not defined in a module.
  `PWD` is absent under `env -i`. Measured: relative `$.fs.read` is
  resolved against the host cwd, and ENOENT errors name the absolute
  path. v2 walks `"../".repeat(i)+".claude/probes"` and skips the
  candidate whose resolved path is the global home. Overlay of
  `classes_skip` / `agents_skip` / `classes_judge` / `agents_judge` is
  last-layer-wins (project key present replaces, even if `[]`).
  `prompt.md` in the project layer replaces, `prompt.extra.md` appends.
  `CLAUDE_PROBES_DIR` disables the walk. Measured `/tmp/t113-full/p-layer/skip2`:
  cwd two levels below the project file, no `PWD`, `classes_skip=["scout-enum"]`
  → `filtered classes_skip`, journal `outcome=skip`, 0 PENDING; the same
  tree under v1 (cwd-only / empty PWD) judged (15 PENDING).
* Compaction of `records/mod-*.json` into the journal index: the hook
  writes the line; `compact.py fold_mod_records` repairs races.
* Pass-path `next(e)` is NOT the 10 s budget. Measured `/tmp/t113-full/p-pass10`: Bash `sleep 15` — hook logged `after next dt=16033`, settled 16034 ms, **zero** `exceeded 10000ms` / `hook failed`, stdout `ZQ-PASS10-DONE`. The timer charges awaited work *around* `next()`, not the tool. Overrun remains only if we `await $.clock.sleep(11000)` (or complete) *before* returning.
* `$.store` key length: max 256 (measured). Dispatch head+tail overflowed
  (302); FNV-1a of the prompt plus tool/agent/len fits.
* Operator knobs from `probes.toml` (no Bun.TOML in the module): ladder
  `[[probe.judge.models]]`, `enforce` / `fail_closed` / `enabled`,
  `attach_*`, `dispatch_chars` / `context_chars`, env
  `CLAUDE_JUDGE_MODEL` / `_PROMPT` / `_TIMEOUT_MS`. `session.start` `e.cwd`
  is the walk root.
* `next.signal` as a cancellation carrier: present, unexercised.

* Flag `tengu_plugin_hooks_modules` is off by default; the env
  `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` overrides. Vendor API may change.

---

## 10. What does NOT move

The proxy contour stays a patch, by the three controls in §0. Splices 1,
2, 8, 9, 10, 11 and 19 remain; 19 (broken-stream recovery) remains
permanently — there is no own-stream form to move it to.

`$.model.complete` is "one completion on the session's client". The judge
in a mod inherits the client's lane — subscription for `claude-*`, proxy
for everything else — ONLY while those routing splices keep shaping that
client.

Form-probe and idle-watch still share `__ccProbe` in injection 22. They
are not this port. The user's order was providers (stay a patch) and
judges (this document) first.

---

## 11. The `agent.spawn` site — measured 2026-09-13

Everything above places the judge on `tool.call`. That was written without
this site. `agent.spawn` is a purpose-built adjudication point on the
Agent tool's own path, and it carries what `tool.call` does not: the
**model**, and the right to change it.

Measured live, mac, patched 2.1.267, isolated `CLAUDE_CONFIG_DIR`, probe
plugin loaded with `--plugin-dir` (no marketplace, no live install
touched). Eleven cases, each its own `claude -p` run; acceptance of every
case is the host's own debug line plus the artefact the module wrote.

### 11.1 It fires on an ordinary Agent dispatch

Not on a mod-initiated spawn — on the dispatch the main loop itself makes.
One firing per dispatch:

```
hooks module spawnprobe loaded (worker, environment 1, tier user); events: agent.spawn
engine.create: no plugin-provided interfaces; $ built for spawnprobe
hooks module spawnprobe agent.spawn settled in 5.1ms (worker hop, next() included)
```

The module also loads inside the subagent's own worker (a second debug
file), but `agent.spawn` fires only in the dispatching session.

### 11.2 The argument

Twelve keys reach the handler. Writability is the image's own split
(`wPt` is the pinned set: "the identity of the spawn and its parent is
pinned"):

| key | value in the probe run | |
|---|---|---|
| `prompt` | the dispatch prompt | writable |
| `description` | `Reply OK` | writable |
| `subagentType` | `worker` | writable |
| `model` | `undefined` (inherit) | writable |
| `background` | `true` | writable |
| `cwd` | `undefined` | writable (absolute path) |
| `tool_use_id` | `toolu_01PEfiXubGkEYNJRR9JGsqJJ` | pinned |
| `parentModel` | `claude-opus-5[1m]` | pinned |
| `permissionMode` | `default` | pinned |
| `fork` | `false` | pinned |
| `name` | `undefined` | pinned |
| `provider` | `{plugin, tier}` | pinned |

`parentAgentId` is pinned too but did not reach the handler in a main-loop
dispatch. `resolveModel` exists at the call site and is NOT exposed to the
module — a handler cannot ask the host what a model id will resolve to.

### 11.3 The four outcomes

| handler returns | host line | dispatch |
|---|---|---|
| `next(e)` | `agent.spawn settled in 4.8ms` | runs unchanged |
| `{deny: "…"}` | `agent.spawn worker: denied by a hook (…)` | **refused**; the model reads `Subagent spawn denied by a plugin: …` |
| `{model: "opus"}` | `agent.spawn worker: model (inherit) -> opus by a hook (resolves to claude-opus-5[1m])` | runs on the named model |
| `{}` (neither) | `agent.spawn hook skipped: returned the wrong shape (neither { model } nor { deny })` | **runs anyway** |

`next(modified)` rewrites the argument: `agent.spawn worker: prompt,
description rewritten by a hook`. Rewriting a pinned key throws and the
handler is discarded whole — its other rewrites with it:

```
agent.spawn hook skipped: threw spawnprobe: next() passed an argument with
a changed tool_use_id (the identity of the spawn and its parent is pinned; …)
```

### 11.4 Retype works, and the caller is not told

`next({...e, subagentType: "probe-beta"})` on a dispatch the main loop
addressed to `probe-alpha`:

```
agent.spawn probe-alpha: subagentType rewritten by a hook
```

`probe-beta` ran. The caller saw only the content — in the probe run the
main loop noticed by itself that the answer did not match the agent it had
asked for. A retype is therefore a silent substitution unless the mod says
so in the `prompt` it also rewrites.

### 11.5 The admission asymmetry — a defect of the site, not of us

An unknown **agent** is refused by the host:

```
Subagent spawn denied by a plugin: a hook's subagentType 'ЗАМЕР-НЕТ-ТАКОГО-113'
names no agent this call can dispatch (available: probe-alpha, probe-beta, worker)
```

An unknown **model** is not checked at all. `{model: "ЗАМЕР-МОДЕЛЬ-113"}`
produced `model (inherit) -> ЗАМЕР-МОДЕЛЬ-113 by a hook (resolves to
ЗАМЕР-МОДЕЛЬ-113)` and the run died downstream at the API with `400
unknown provider for model ЗАМЕР-МОДЕЛЬ-113`. The hook is the last word on
the model with nothing behind it: **a routing mod that writes `model` owns
the id's validity outright.** Our own table is the only check there will
be, and a typo in it surfaces as a 400 in the middle of a dispatch, not as
a refusal at the gate.

Further refusal branches read from the image, not exercised here: a retype
on a web-fetch dispatch admitted without classifier review; a rewrite that
a permission rule would have denied or asked about (re-checked after the
rewrite); `cwd` together with `isolation: "worktree"`; an in-process
teammate backgrounded by the hook; MCP servers required by the named
agent.

### 11.6 The budget is the same 10 s, and the same fail-open

`await sleep(12000)` before `next(e)`:

```
agent.spawn hook skipped: ran past its 10s budget
hooks module spawnprobe agent.spawn settled in 10010.6ms (worker hop, next() included)
```

The dispatch ran. This is §1.1's rule on a second site, and it is charged
the same way as §9's pass-path note: work awaited *before* returning is
charged, `next()` itself is not.

What does fit: `$.model.complete` runs on this site —
`{model:"glm-5.3-flash", max_tokens:16, timeoutMs:8000}` answered in
**3520 ms**, the site settled in 3527.9 ms. `$.agent.spawn` also runs from
inside it (1377–1544 ms for a trivial subagent), and the host guards
re-entry by itself:

```
agent.spawn skipped: re-entry (its own frame is being dispatched; origin spawnprobe#0)
```

so a module's own nested spawn does not re-enter its own handler. The
`$.agent.spawn` API budget is **50 spawns per session, 4 at once**.

Measured API detail: `$.agent.spawn` wants **camelCase `subagentType`**.
The tool-shaped `subagent_type` alone is dropped and the call fails with
`subagent_type is required: the general-purpose agent is not available in
this session`.

### 11.7 What this changes for the port

The judge is two things, and this site splits them cleanly:

* **The deterministic table gate** (class membership, markers, effort
  pins — no completion involved) belongs on `agent.spawn`. It is
  microseconds, so the 10 s budget is not a constraint, and it gains what
  the classic `PreToolUse` gate never had: it can **reroute** a dispatch
  to the right model instead of only refusing it. The gate's refusal text
  already names the right point; on this site it could simply go there.
* **The consulting judge** (a completion, then a verdict) does not belong
  here as a blocking call. A fast rung fits (3.5 s), the combat ladder
  does not, and an overrun is silent pass-through — §2's inverted
  fail-closed is still the only construction that holds a refusal.

Neither half is written yet. What is settled is that the site exists, that
it fires on real dispatches, and that model and agent are both writable
from it.

### 11.8 What the carrier can reach — measured 2026-09-13

The gate half cannot move until a module can read the gate's own table.
The table ships inside the `catalyst` plugin; the consultation engine is a
different plugin (`catalyst-probes`). Measured on the same stand (probe
`coexist`, one `claude -p`, isolated config):

**One plugin carries BOTH a classic hooks block and a module.** A single
`hooks/hooks.json` with `"hooks"` *and* `"modules"` loaded both: the
classic `PreToolUse` hook wrote its artefact and the module wrote its own
in the same run, with `hooks module coexist loaded … events: agent.spawn`
and `$ built for coexist` in the debug. So the `agent.spawn` module can
live in the `catalyst` plugin, next to the table — it does not have to
join `catalyst-probes`.

**But the module is not told where its plugin is.** `CLAUDE_PLUGIN_ROOT`
reached the classic hook (absolute path) and reached the module as EMPTY.
Relative `$.fs.read` does not help: `target.txt`, `./target.txt` and
`hooks/target.txt` were all refused, and the error names the path resolved
against the HOST CWD (this is §9's earlier note, re-confirmed on a second
site). `$.fs.ancestors` is not an escape either — host check: "takes
names, a list of relative .md file names".

**Absolute paths read fine, and the active install is DERIVABLE** with no
new environment handle:

```
<config home>/plugins/installed_plugins.json
  → the record for "catalyst@catalyst"
  → its installPath (absolute, already version-keyed)
  → + "/hooks/routing-table.toml"
```

Measured live from inside the module: `installed_plugins.json` read,
record `{scope:"user", installPath:".../cache/catalyst/catalyst/0.8.25",
version:"0.8.25", gitCommitSha:"e90739b9…"}`, table read, `[selection]`
present, `qwen3.8-flash` absent. Use `installPath` verbatim — do not
rebuild it from `version`, and do not reach for the version at all.

**TRAP — the marketplace clone is not the active install.**
`<config home>/plugins/marketplaces/<mp>/hooks/routing-table.toml` is also
readable and is the one stable, version-free path, which makes it the
tempting choice. It is the install SOURCE, not what is installed: on this
machine the clone and the cache agreed only by accident of timing, and a
module reading it would enforce a different table than the classic gate
beside it enforces. The two carriers of one rule must read one file.

**INSTRUMENT TRAP.** `$.fs.read` returns a STRING — its `.length` is
characters, not bytes. The table read as 23 500 while the file is 34 210
bytes; with Cyrillic prose the two differ by ~45 %. Do not compare a
module's length against `stat`/`wc -c` without converting.
