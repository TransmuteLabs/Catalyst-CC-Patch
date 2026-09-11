# Porting the judge to a Claude Mod — specification

Written by the controller personally (adjudication is not delegated).
Companion to `judge-architecture.md` (what the judge IS) and
`judge-patch-spec.md` (how the splice was built). This document says what
the judge BECOMES when its carrier changes from a binary splice to a
function-hooks module, and what must NOT change with it.

Status: design, ratified on the budget fork by the user 2026-09-11
("перестройка + поднять предел патчем"). No splice is removed from the
patch layer until its mod carrier has been measured live — the standing
honesty boundary of task #116.

---

## 0. The user's decision and its two halves

> «логику работы прокси оставляем патчем а остальное пишем модом»
> (2026-09-11) — and, on the budget fork the same day: rebuild the judge
> AND raise the host's hook budget with a one-line patch.

Both halves are load-bearing, and the second is not a convenience:

* **Rebuild** — the judge must hold a refusal BY ITS OWN CONSTRUCTION,
  because fail-open is a property of the HOST and survives any limit.
* **Raise the limit** — because the measurement below shows the model
  rung cannot be squeezed under the stock limit by any amount of
  rebuilding.

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

and the model answered `##` — the first line of `/etc/hosts`. **The tool
executed; the refusal was lost.** Neighbouring constants of the same
measurement: grace after an abort `h0e = 5000`; core handlers declared
`budgetMs:0` (no limit); classic config-file hooks get `timeout
600000ms`, sixty times more.

This directly contradicts the judge's shipped mode: `[defaults] enforce =
true` plus `[probe.judge] fail_closed = true`.

### 1.2 The live judge does not fit in that budget — and not marginally

Counted by the controller over the live journal
`~/.claude/probes/judge/journal.jsonl`, 5997 records,
2026-08-24T11:20 → 2026-09-11T09:41 (docnum:other — these are judgings,
not kit counters):

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
| > 5 000 ms | 99.87 % |
| > 10 000 ms | **97.85 %** |
| > 30 000 ms | 63.03 % |
| > 60 000 ms | 22.78 % |

Outcomes: `ok` 5201, `warn` 556, `block` 221, `block_no_verdict` 19.
Rungs: one rung 5765, two 205, three 8, four 19.

**97.85 % of live adjudications exceed the stock hook budget.** A port
that only "re-fits the judge under 10 s" would lose the verdict on
ninety-eight of every hundred dispatches — silently, by fail-open, in the
direction of approval. The budget patch is therefore structural, not an
optimisation.

### 1.3 The 840-second tail is the ladder's own worst case, not a hang

Twenty records exceed 600 s; nineteen of them carry `tries: 4`. The
shipped per-rung `timeout_ms` is 240 000 ms and the automatic retry runs
on half its rung's clock, so a ladder walked to exhaustion costs
`240 + 240 + 240 + 120 = 840` seconds — exactly the 840 019 ms observed.
The tail is a derivation, not an anomaly: any host budget must be chosen
against the judge's OWN configured ceiling, not against its median.

### 1.4 A fast rung does exist

From inside `tool.call`, `$.model.complete` with `deepseek-flash`
returned `ALLOW` in **2008 ms** (same probe session). The carrier is not
slow; the judge's own prompt and transcript are what cost the time.

### 1.5 Why the median moved (INFERRED, with the confound named)

`judge-architecture.md` §5 records a median of 5.9 s on a 4.7 KB body in
August. Today's live median is 36.7 s. Two candidates, and this
measurement does not separate them: the judge's prompt home grew (42.6 KB
today), and the carrier model id changed editions. The journal shows the
editions differ sharply — `deepseek-v4-flash` median 37 457 ms (n=5354)
against `deepseek-flash` median 19 676 ms (n=411) — so the newer edition
is roughly twice as fast on the same work. Recorded as INFERRED; the
discriminating probe is one transcript run against both bodies on one
model id.

---

## 2. The invariant that replaces fail-open

> **Our deadline must always fire before the host's.**

The host cannot be made fail-closed — its abort path skips the hook and
runs what is below it. Therefore the mod must never be the party that
runs out of time. The judge computes its own deadline from a constant it
owns, arms it before any I/O, and on expiry RETURNS `{deny: …}` itself.
The host budget is then a backstop that, in correct operation, never
fires — and if it ever does, that is a defect of ours, observable as a
`hook failed: exceeded` line with no matching journal record.

This is the precise form of "the judge must hold the refusal itself". It
is testable, and its test is in §8.

---

## 3. Architecture — three stages, one obligation flag

The splice's obligation flag (`__jarm` in §7 of the architecture) ports
unchanged in MEANING: armed as soon as it is known the call is not
filtered out and `enforce` + `fail_closed` are on; cleared only by the
last action of a successful path. Everything that leaves the hook without
clearing it leaves with a refusal.

### Stage 0 — the deterministic gate (synchronous, no I/O)

Everything the routing table decides without a model: is the model named;
is `[dispatch-class:<id>]` present; is the model admitted for that class;
is the effort pin present for a proxy model; does an Anthropic model in a
non-executor class carry `[anthropic-exception:<basis>]`; agent-name →
class coercion.

This stage is **fail-closed by construction**: it performs no I/O, so it
cannot time out, and a missing or unparseable rule set means the rules
are UNKNOWN, which denies (the three-outcome layer reader of §7 of the
architecture — "absent", "read", "present but not understood" — ports as
is). Cost: microseconds against the ~12 ms the hook itself costs.

On today's traffic this stage is where the overwhelming majority of
refusals are already decided; it is the reason the port is viable at all.

### Stage 1 — model adjudication under OUR deadline

Reached only when stage 0 has no verdict. The ladder ports with its
rung fields (`model`, `timeout_ms`, `max_tokens`, `context_chars`,
`effort`) and its escalation causes (network error, threshold, non-2xx,
and **2xx without a verdict** — the rung that answers with emptiness must
not stall the ladder). `$.model.complete` is the channel; it keeps the
contract that `claude-*` stays on the subscription lane, PROVIDED the
routing splices remain in the patch (§ below).

Two rules the carrier forces on the ladder:

* **The ladder's total is capped by our deadline, not by the sum of its
  rungs.** Today the sum is 840 s; under the port the cap is the
  constant of §2, and rung budgets are derived from it, not the reverse.
* **There is no cancellation handle on a pending request**: measured —
  `$.model.complete` returns a STRING, not an object. A rung that
  overruns cannot be aborted from inside; the deadline is therefore
  enforced AROUND the call (`$.clock` + the obligation flag), and an
  overrun rung is abandoned, not cancelled. Its tokens are spent. This is
  a cost, and it is why the deadline is set once and not retried
  optimistically.

### Stage 2 — deny-now, verdict-later (the tail, and the fallback)

For the fraction that exceeds even the raised deadline, and as the
behaviour if the budget patch is ever absent (a stock binary, a machine
without our patch layer):

1. deny immediately with a message that names the reason as a channel
   defect, not a judgment defect;
2. continue the consultation and write the verdict into `$.store` keyed
   by a digest of the dispatch;
3. on the model's retry of the same dispatch, answer from the cache.

This keeps `block_no_verdict` distinguishable from `block` — the
separation §7 of the architecture was built to preserve — and it makes
the mod correct on an unpatched host, merely slower to converge.

---

## 4. Carrier map

Every row below is measured; nothing here is assumed.

| What the splice does | Mod carrier | Evidence |
|---|---|---|
| intercept before the tool runs | `on('tool.call')` | fires once per call; hook cost ~12 ms |
| cancel the dispatch | return `{deny:"text"}` | arrives verbatim as `<tool_use_error>…</tool_use_error>`, `is_error: true`, `toolDenialKind: "permission-rule"`; the model acts on it |
| "main loop only" (`agentType == "main"`) | `!("agentId" in e)` | `agentId` present ONLY on a subagent's call; positive control ran both cases in one session |
| which agent, if not main | `$.agent.list()`, match `id` to `e.agentId` | element `{id, description, type, status}` — strictly more than the old `agentType` |
| the dispatch's model and effort | `e` on `tool.call`, and `agent.spawn` | `agent.spawn` carries `subagentType, model, parentModel, provider{plugin,tier}, permissionMode, background, fork` |
| the current turn (injection 21) | `e` on `tool.call` IS that turn | injection 21 becomes unnecessary — one splice retired outright |
| the consultation | `$.model.complete({model, prompt})` | our proxy ids pass: `deepseek-flash`, `glm-5.3`, `claude-opus-5` → ok; invented id → HTTP 400 |
| the transcript | `await $.session.messages()` | returns a PROMISE; awaited it is the WHOLE conversation, growing 3 → 5 → 7 across three sequential calls — see §4a |
| the journal | `$.fs.write` | lives on 2.1.267, absent on 2.1.265 — see §6 |
| the rule in the system prompt (splice 26) | `on('prompt.section')` | rewrite proven live, both return forms |
| the switch, settings layers | `$.settings.read`, module scope, `$.store` | module runs in a separate worker: `globalThis.process` is undefined, so env reading goes through the host's own verb |

### 4a. Transcript fidelity — measured, and it carries provenance

Measured 2026-09-11, probe `/tmp/t113-tx/probe`: one run, the main loop
reading three fixture files in three separate steps, the transcript dumped
at every `tool.call`.

**The verb returns a Promise.** `$.session.messages()` is thenable
(`constructor.name === "Promise"`, own keys `[]`); unawaited, `.length` is
undefined and `.map` throws. The first pass of this probe measured its own
defect. Awaited, it yields an array.

**It is the whole conversation, not a window.** Lengths across the three
calls: 3 → 5 → 7 — two elements added per completed tool round. The earlier
note "3 elements" was the length at the FIRST call of a short run, read as
if it were a ceiling.

**Provenance is present, and it is structural — by key presence, not by
role.** Claude Code puts several different things under `user`, and §6 of
the architecture records what a judge shown bare roles does with that. The
carrier discriminates them anyway:

| element | `role` | own keys |
|---|---|---|
| what the human typed | `user` | `role, text, toolUses` |
| a tool RESULT | `user` | `role, text, toolUses, `**`toolResults`** |
| the model's prose | `assistant` | `role, text, toolUses` |
| the model's tool call | `assistant` | `role, text, toolUses` (text empty, `toolUses.length > 0`) |

The predicate is `"toolResults" in m` — the same shape of finding as
`agentId` on `tool.call`: an optional key that expresses a kind by its
PRESENCE. The judge therefore reconstructs provenance without heuristics on
text.

**The substance of a result is not in `text`.** A tool-result element has
`text` of length 0; the material rides the ASSISTANT element's `toolUses`
entry, which gains `result` and `text` once the result arrives:

```
{id:"toolu_…", name:"Read", input:{file_path:"…/f1.txt"},
 result:{type:"text", file:{filePath:"…", content:"ZQ-FIXTURE-ONE-ALPHA\n",
         numLines:2, startLine:1, totalLines:2}},
 text:"1\tZQ-FIXTURE-ONE-ALPHA\n2\t"}
```

**The call under judgment identifies itself.** The in-flight tool use — the
one the hook was entered for — carries only `{id, name, input}`, with no
`result`/`text` yet. Every completed call in the same transcript carries
both. This is a free discriminator, and it is stronger than matching by
`tool_use_id`.

Residue, named rather than assumed closed: §6 lists FOUR things the `user`
role conflates — human text, tool results, service insertions, letters from
other sessions. This run discriminated TWO of them. Service insertions
(`system-reminder`) and cross-session letters did not occur in it and remain
UNMEASURED; the probe that closes them must provoke both deliberately.

Retired by measurement: injection 21 (the turn accumulator) — the event
already carries what the accumulator was built to stash.

---

## 5. What the carrier's form costs the port

Four hard rules of the loader, each rejected by the validator otherwise:

1. the event name must be a string LITERAL inside `on("...")`;
2. `$` may not be indexed dynamically, nor reached through `?.`;
3. `$.noun` may not be READ as a value — only call sites `$.noun.verb(...)`;
4. a green `plugin validate` is compatible with a module that never
   loaded: one stray event name breaks the construction of `$`
   ("could not build $"), and — fail-closed — "its withholdings kept
   while it is declared". Acceptance MUST read `hooks module … loaded`
   from `--debug-file`, never the validator's exit alone.

Consequence for the judge: **no dynamic dispatch anywhere**. The routing
table cannot be walked as data into `$.noun[verb]` calls; it must be
compiled into literal call sites, or kept as pure data consumed by code
that itself performs no `$` lookups. Stage 0 is written so that the rule
set stays DATA and only the fixed handful of `$` verbs appear literally.

Two more shapes, measured, that the port must respect:

* **`$.clock.sleep` counts MILLISECONDS** (`sleep(45)` returned in 46 ms).
  The first ceiling measurement was vacuous because of this.
* **Concurrent hooks are real**: two tools in one assistant message
  produced simultaneous `tool.call` hooks. The judge may not assume
  ordering, and shared state must tolerate interleaving.

Free instrument, for every future measurement of this class: `-p ""`
loads the module and the CLI errors before any model call — module-load
and `$`-construction defects are found at zero token cost.

---

## 6. The journal

`$.fs.write` OVERWRITES; there is no append verb. A journal therefore
becomes read-modify-write, and §5's concurrency makes that a race: two
simultaneous `tool.call` hooks can each read the same file and the second
write can drop the first record. Since the journal is the mechanism that
makes a switched-off judge distinguishable from an approving one (§8 of
the architecture), losing records silently would reintroduce exactly the
defect the journal exists to close.

Design: one file PER RECORD, named by timestamp plus a random suffix —
the `records/` layout the judge already uses — and the index line
rebuilt by the existing compaction tool rather than appended live. This
removes the shared-file race entirely instead of guarding it.

`$.ui.log` is the fallback carrier (it works on 2.1.265 too and lands in
`--debug-file`), but it is a diagnostic, not a journal: it does not
survive the session.

---

## 7. The budget patch (the one line that stays in the patch layer)

Locator, structural, from the measurement:

* `budgetMs:n=<NAME>` — the SINGLE default site;
* `var <NAME>=1e4;` — the SINGLE declaration;
* the name is platform-dependent (`b0e` on darwin, `dPe` on linux), so it
  is READ FROM THE SITE and never pinned as a letter. This is the lesson
  of #75 and #114 applied before the fact rather than after.

Value, chosen by the controller against §1.2 and §1.3:

* judge's own deadline (stage 1 cap): **240 000 ms** — covers p99
  (193 713 ms); the ~1 % beyond it falls to stage 2, i.e. an explicit
  refusal, never a silent pass;
* host budget constant: **300 000 ms** — the deadline plus a 25 % margin,
  so the host's abort is unreachable in correct operation.

Declared cost, accepted with the decision: the limit is shared by every
hook of the plugin tier, so a third-party mod could hold a call for that
long. Mitigated by the fact that the plugin directory is ours and its
contents are ours; not mitigated by the patch itself. Recorded here so
that nobody rediscovers it as a surprise.

---

## 8. Acceptance

A port is accepted only with all of these, each carrying its own control:

1. `hooks module … loaded` present in `--debug-file` (not the validator's
   exit) — the green-validator-dead-mod class of §5.4.
2. **Positive control on the budget patch**: the 20 000 ms hook that today
   loses its `{deny}` must, on the patched image, DELIVER it — same probe,
   same prompt, the model reporting the refusal instead of the file's
   first line.
3. **Negative control on the same patch**: on an unpatched image the same
   probe still loses the refusal. Without this the first control proves
   only that the probe ran.
4. **Our-deadline-fires-first**: a rung pinned to a dead address, deadline
   set below the host budget; the outcome must be OUR `{deny}` with a
   journal record, and the host must print no `exceeded … budget` line.
5. Stage 0 denies with the rule set removed (rules UNKNOWN ⇒ deny), and
   the refusal names the file — the three-outcome layer reader.
6. `block` and `block_no_verdict` remain distinguishable in the journal.
7. The refusal path is exercised deliberately, as §7 of the architecture
   requires: names read by `catch` declared above the `try`, and a live
   call against a dead address after any edit.

---

## 9. Open items — measure before relying

* **Transcript fidelity: CLOSED positively** — see §4a. The whole
  conversation is reachable, and provenance is carried structurally
  (`"toolResults" in m`). Residue: service insertions and cross-session
  letters were not present in the run and are still UNMEASURED — the two
  remaining members of §6's list of four.
* `$.store` persistence scope (per session? across sessions? size cap?)
  — stage 2 depends on it.
* `next.signal` as a cancellation carrier: present, unexercised.
* Whether `agent.spawn` alone can carry the whole gate, letting
  `tool.call` handle only non-dispatch tools.

---

## 10. What does NOT move

The proxy contour stays a patch, by three controlled measurements
(#116): core inference does not pass through `model.complete` (positive
control: our own call did fire it); rewriting the input on `turn.start`
does not change the answer; `turn.step` arrives with a finished answer.
Splices 1, 2, 8, 9, 10, 11 and 19 therefore remain, and 19
(broken-stream recovery) remains permanently — there is no own-stream
form to move it to.

And the reason this boundary is not merely tidy: `$.model.complete` is
"one completion on the session's client". The judge in a mod inherits the
client's lane — subscription for `claude-*`, proxy for everything else —
ONLY while the routing splices keep shaping that client. Move them, and
the judge's own consultations start billing at API prices.
