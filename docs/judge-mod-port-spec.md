# Porting the judge to a Claude Mod — specification

Written by the controller personally (adjudication is not delegated).
Companion to `judge-architecture.md` (what the judge IS) and
`judge-patch-spec.md` (how the splice was built). This document says what
the judge BECOMES when its carrier changes from a binary splice to a
function-hooks module, and what must NOT change with it.

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
| journal | `$.fs.write` one file per record | overwrite, no append; concurrent hooks race a shared file |
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

`$.fs.write` overwrites. Design: one file per consultation,
`~/.claude/probes/judge/records/mod-<tool_use_id>.json` (id is unique per attempt; the *verdict cache* is the dispatch digest). The splice's
index line is not written by this carrier. Compaction of the splice
journal does not yet see these files — that is a follow-up, not a reason
to share a file.

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
* Project-layer `probes.toml` via `$.fs.ancestors` (v1 reads
  `~/.claude/probes/probes.toml` and `.claude/probes/probes.toml`).
* Compaction of `records/mod-*.json` into the existing journal index.
* Pass-path `next(e)` is NOT the 10 s budget. Measured `/tmp/t113-full/p-pass10`: Bash `sleep 15` — hook logged `after next dt=16033`, settled 16034 ms, **zero** `exceeded 10000ms` / `hook failed`, stdout `ZQ-PASS10-DONE`. The timer charges awaited work *around* `next()`, not the tool. Overrun remains only if we `await $.clock.sleep(11000)` (or complete) *before* returning.
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
