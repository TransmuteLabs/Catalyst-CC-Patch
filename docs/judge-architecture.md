# The Subagent Dispatch Judge — Architecture

This document describes the MECHANISM in full: where it lives in the
binary, how a single act of judging flows, which layers of settings
define it, what it guarantees and what it does not. The chronology of
findings, measurements, and rejected options is in `judge-patch-spec.md`
(the campaign journal); the operator's manual is in `judge/README.md`.
What is here is what you need to KNOW the mechanism, to carry it to the
next version, and to extend it.

State as of 2026-08-27, images 2.1.233 through 2.1.247, checks in
`claude-patch-all.sh` — 116 (all green on the built image). As of 2026-08-22 the judging mechanism
has been split into a shared CORE and its callers: the core contract is
in `probe-core.md`, and its second consumer (the fleet idle watcher) is
in `idle-watch.md`. Everything below describes the judge; what it shares
with the watcher is marked as core.

---

## 1. The task and the boundary

Between "the model decided to call a subagent" and "the subagent went to
work" there is a moment in which the call is fully defined but not yet
executed. The judge lives exactly in that moment. It receives the session
layout and the call itself, and answers with one of three: pass, pass
with a note, cancel with an explanation.

What it does NOT do, and why:

- **It does not rewrite the call.** Substituting the model or the effort
  would produce a pair that nobody validates: the deterministic routing
  gate (`hooks/routing-table.toml`) runs EARLIER in the same function,
  and an edit made here would slip past it. A refusal is strictly
  narrower than what the gate has already allowed, so the ordering stops
  mattering.
- **It does not judge subagents.** Only the main loop is judged
  (`agentType==="main"`): a subagent executes a decision already made;
  judging it means judging twice and inside someone else's
  responsibility.
- **It does not know the project.** It judges the event, the logic, and
  the rules. A project is entitled to STATE its rules (the layer below),
  but a description of the subject domain is not needed by the judge and
  is not passed to it.

---

## 2. Three injections into the binary

The patcher (`tweakcc-patch.js`) finds locations with structural regexes
over `[A-Za-z_$][\w$]*` with backreferences — not by minified names,
which change from build to build.

### Injection 21 — the current-turn accumulator

In streaming mode EVERY content block leaves as its own assistant message
(`content` — an array of one element). What reaches the tool executor is
a message with only a `tool_use` block in it: the reasoning that led to
the call has already left, in an earlier and different message. The full
turn exists only in the loop's accumulator, which the executor does not
see.

The injection puts a snapshot of the accumulator into
`globalThis.__ccJudgeTurn`, keyed by the tool call id. The key is the id,
not the context object itself: the loop REASSIGNS the context
(`Z={...Z,messages:...}`), so object identity cannot be the bridge. The
map is capped at 64 entries and cleaned up by whoever reads it. The
injection itself is gated by the same `CLAUDE_JUDGE` switch — otherwise,
with the judge off, nobody would delete the entries and the map would
hang from the ceiling for the sake of a non-working function.

The extra argument at `addTool` is ignored by the receiving side — it
exists only to introduce the side effect without rewriting the operator.

### Injection 22 — the judge itself

Location: inside the dispatch tool's own `call`, at the top of the body,
right after the parameter pattern the original signature destructured —
which the patch moves into the body so the judge can run after it:

```
async call(__ccIn, l, c, u, d) { let {prompt:e, subagent_type:t, …} = __ccIn;
  /* the judge */ …
```

It used to sit immediately before the executor's `e.call(…)`. That was an
anchor on a COUNT of dispatchers, and the count is upstream's to change:
a dispatcher that appears in a later version is then a silent pass, which
a fail-closed mechanism cannot afford. The tool's own `call` is the one
funnel every executor must go through — the main dispatcher, the REPL
sandbox, and `claude mcp serve` — including the 2.1.239 adapter, which
falls through to `e.call(…)` because the tool declares no `executor`.

A cancellation is thrown with `throw`; the executor's outer `catch`
routinely turns what was thrown into a `tool_result` with `is_error`.
This is precisely the "stop, and here is what is wrong" — and it is not
coupled to any minified name. The product refuses a launch from exactly
here too (the nesting-depth cap throws out of this method), so a throw at
this point is the product's own idiom, not one we invented.

**Accepted trade-off.** The judge is consulted BEFORE the tool's own
guards — depth cap, teammate rules, budget. A dispatch those guards would
refuse is therefore still judged, and still costs one consultation and
one journal line. The alternative is worse: running after them would put
the judge behind checks whose order and existence upstream may change,
and the dispatch was authored either way — judging it is not a lie about
what happened.

**What has no id here.** `claude mcp serve` calls this same method with a
context built as `agentContext:{agentType:"main", agentId:…}` and no
`toolUseId` at all. The key is therefore undefined on that whole route:
there is no current turn to fetch (correctly — none was stashed), and the
record name must not lean on the key for uniqueness. See §9.

The consultation goes through the client's OWN single request
(`queryModelWithoutStreaming`, the same path the prompt hooks use). This
is a matter of principle, not convenience: the function goes through the
same client factory as any other request, so the model pool and both of
its lanes are the client's. `claude-*` stays on the subscription lane
(patch 1); everything else goes to the proxy. A dedicated HTTP path would
send claude-models to api.anthropic.com at API prices — a different
contract and a different bill; an early revision of the judge was wrong
in exactly this way.

The function's name is located by the patcher structurally, by its
signature (`{messages, systemPrompt, thinkingConfig, tools, signal,
options}`), not by its minified spelling.

Raw HTTP remains for exactly two cases: an explicitly named address
(`CLAUDE_JUDGE_URL` or `url` in the config — this is how the bench's
probes hit their own receiver) and the absence of pool binding in a
particular build. The second case is insurance: a judge that has lost its
channel must degrade observably, not silently. Each attempt's channel is
visible in the record as the `via` field (`pool` | `http`).

### Injection 26 — the rule in the system prompt

A cancelled call is visible to the model as a tool error, and a tool
error by default reads as "try again". Therefore a rule is glued into the
main loop (in English, like the rest of the system prompt):

> A subagent dispatch may be reviewed before it runs. If one is cancelled, the
> tool result states the reason: treat that reason as a correction to apply.
> Reissue the dispatch only with the change it names, and never repeat the
> identical call — an unchanged retry cannot succeed. This review is separate
> from the permission system and from any routing gate, so do not attribute a
> cancellation to either.

The gluing point is the same system prompt assembly where the advisor
puts its instructions (`services/api/claude.ts:2041` in the
reconstruction). The gluing is gated by `CLAUDE_JUDGE` and
`agentType==="main"`: subagents do not get the rule, and with the judge
off it is not there at all.

---

## 3. The flow of a single judging

```
the model decides to call Agent/Task
   │
   ├─ injection 21: turn snapshot → __ccJudgeTurn[tool_use.id]
   │
   ▼
deterministic routing gate (PreToolUse, routing-table.toml)
   │  allowed
   ▼
injection 22
   1. switch:        CLAUDE_JUDGE set?  name == Agent|Task?  agentType == main?
   2. layer search:  global ~/.claude/probes  +  nearest .claude/probes above cwd
   3. selector:      filter (classes_skip / agents_skip / classes_judge / agents_judge)
   4. transcript:    context messages + turn snapshot  →  array of {src,text}
   5. trimming:      context_chars, whole entries from the head
   6. body:          body.json + substitutions {{MODEL}} {{PROMPT}} {{CONTEXT}} {{DISPATCH}}
   7. ladder:        rung after rung until a verdict is obtained
   8. parsing:       the FIRST line of the form OK:/WARN:/BLOCK:/STOP:/DENY:
   9. journal:       index line + full record beside it
  10. execution:     BLOCK and enforce  →  throw  →  is_error to the model
   │
   ▼
e.call(...) — the subagent starts
```

Any error in steps 2–9 is caught by the outer `catch`: the call goes
through as usual, and the journal gets an `outcome:"skip"` with the
reason. The refusal is the only thing that propagates outward (the
`__ccJudgeBlock` label).

---

## 4. Settings layers

Everything the operator turns is read FROM FILES ON EVERY CALL. A judge
whose wording can only be changed by rebuilding the binary is not
iterable.

| Layer | Source | Overrides |
|------|--------|-------------|
| environment | `CLAUDE_JUDGE`, `CLAUDE_PROBES_DIR`, `CLAUDE_JUDGE_MODEL`, `_URL`, `_TIMEOUT_MS`, `_PROMPT`, `_DEBUG` | everything |
| project | nearest `.claude/probes` above cwd (up to 24 levels) | global |
| global | `~/.claude/probes` | defaults in code |

Merge rules: a probe's effective settings are `[defaults]`, overlaid with
`[probe.judge]`, and then the same from the project's `probes.toml` on
top (a shallow merge, by keys); a project's `prompt.md` and `body.json`
REPLACE the global ones wholesale; `prompt.extra.md` is APPENDED to the
prompt under the heading «ПРАВИЛА ЭТОГО ПРОЕКТА». An explicitly set
`CLAUDE_PROBES_DIR` disables the project layer: a probe must receive
exactly what was handed to it. The applied project directory is visible
in the journal as the `cfg` field.

Files:

| File | Role |
|------|------|
| `~/.claude/probes/probes.toml`, table `[probe.judge]` | ladder, thresholds, budgets, trims, `enforce`, selector, recording |
| `prompt.md` | the judge's instruction (lenses, trust rules, verdict format) |
| `prompt.extra.md` | project only: appended project rules |
| `body.json` | the FULL request template with placeholders — model, parameters, message layout |
| `journal.jsonl` | index of judgings, one line per call |
| `records/` | full requests and responses, one file per call |
| `replay.py` | replay a record with model/prompt/effort substitution; the sole home of the verdict dictionary reader |
| `validate.py` | run the corpus through several models, metrics, recommendation |
| `adjudicate.py` | corpus labeling by a strong model over the verdicts already issued |
| `compact.py` | daily compression of records (launchd agent) |

All four accept the common `--home <probes home>`, `--probe <id>`, and
`--image <path>`: the home says where to look for `probes.toml` and the
probe directory, the id selects the settings table, the image is the
source of the verdict dictionary. The dictionary is NOT baked into any
tool: it is read from the image, and if the read fails the tool refuses
rather than substituting a baked-in one — a divergence from the image
would mislabel the entire corpus.

Substitution into the template goes through `JSON.stringify` without
outer quotes, so a quote or a newline inside the transcript cannot break
the body's JSON.

---

## 5. The ladder of attempts

The judge shares a channel with the very fleet it judges: when the fleet
is loaded, the judge is the first to fall off — and a silent pass is
indistinguishable from approval. That is why `models` is not a list of
names but a ladder of rungs, each with its OWN limits:

```json
"models": [
  {"model":"deepseek-v4-flash","effort":"high"},
  {"model":"glm-5.3","effort":"max","context_chars":8000}
]
```

Rung fields: `model`, `timeout_ms`, `max_tokens`, `context_chars`,
`effort`. A bare string is shorthand for `{model:"…"}`. Failure causes
differ, so the remedies differ: an overloaded provider needs a larger
threshold, a reasoning model needs a larger budget, a bloated transcript
needs a short tail.

The move to the next rung happens on: a network error, a threshold
firing, a non-2xx AND **a 2xx response without a verdict** (the budget
went into reasoning, `finish_reason: "length"`). The last one is a class
of its own: without it the ladder stalls on the first model that answers
with emptiness.

Output-budget overrun arrives over the two channels DIFFERENTLY, and this
determined the ceiling's size. Over raw HTTP the break is soft:
`finish_reason:"length"`, and a verdict printed on the first line has
already arrived and is usable. Through the pool the same break is a
synthetic client error ("response exceeded the N output token maximum")
with `output_tokens: 0`: no text remains AT ALL, and the "verdict on the
first line" rule does not save you here. A measurement on one transcript
(2026-08-20): flash spends 434–2120 tokens at `high` and 302–3000 at
`low` — the spread within one effort exceeds the difference between
efforts, so there is nothing to treat overrun with by lowering the
effort. The ceiling was raised 3000 → 8000 (the shipped settings ask for
24000; 8000 is what the code falls back to when nothing is configured, and
the single home of that number is `__mtd`): it does not lengthen a normal
answer, but it removes the unrecoverable break on the path where a break
costs the whole consultation (27.9 s observed wasted, after which rung 2
answered in 2.5 s). A rung for which even 8000 is not enough, the ladder
yields to the next one — this is a leash, not a budget.

After the ladder, if there is still no verdict, an automatic last rung
follows: the same last model on a short tail (`retry_context_chars`,
default 8000; `0` disables it — for a ladder that already ends with a
short rung).

The shipped `timeout_ms` is 240 s per rung (`probes/probes.toml`); with no
config at all the code falls back to 8 s. The budget is per RUNG, not for the
ladder: three rungs plus the retry is the worst case, and the retry runs on
half its rung's clock. The choice logic:
better to over-wait than to under-wait — a long answer is cheaper than a
missed call.

Effort (`effort`) is mandatory for proxy models and must match the pins
accepted in the routing table (flash `high|xhigh`, glm-5.3 `max`,
gpt-5.6-sol `high|xhigh`, grok-4.6 `max`). Without it the request goes
out with the default effort — at one point that was `low`, and the judge
worked at half strength unnoticed. On the pool path effort rides as the
`options.effortValue` field, and the output limit as
`options.maxOutputTokensOverride`: here the client assembles the request
body, and `body.json` takes no part on this path (it remains the
raw-channel template).

What exactly goes out on the pool path was captured by a proxy dump
2026-08-20 (the client body and the upstream body match in what matters):

    model: deepseek-v4-flash | max_tokens: 3000 | stream: true | tools: 0
    (the ceiling has since been raised: 8000 as the code default, 24000 in
    the shipped settings — see above)
    output_config: {"effort":"high"} system: 3 blocks — the client's
    billing header, "You are a Claude agent, built on Anthropic's Claude
    Agent SDK.", and our judge instruction

Two facts follow. The effort DOES reach the upstream, including for a
model the client marks `unrecognized_model` — the assumption that it
drops it was refuted by the dump. And the judge's instruction does not
arrive alone: ahead of it the client places two blocks of its own, so the
judge's prompt is always read in this framing.

A `claude-*` can also be a rung of the ladder: it goes over the
subscription lane, not at API prices. Measured 2026-08-20 on a live
session: `claude-haiku-4-5` returned a verdict in 2.3 s. A channel
comparison on one input and one model (`deepseek-v4-flash`): pool —
median 5.9 s (5 runs, 4.3–15.4), raw HTTP — median 6.0 s (4 runs,
4.6–21.1). There is no channel difference; latency is determined by the
length of the reasoning (the outliers had 1700–2100 output tokens against
400 at the median). Incidentally: on the pool path part of the input is
read from the prompt cache (input tokens 220–284 instead of 1700 on the
same transcript); raw HTTP does not have this.

---

## 6. The transcript: provenance instead of roles

Claude Code puts four different things under the `user` role: what the
human typed; tool results; service insertions and notifications; letters
from other sessions. A judge shown bare roles reads the defendant's own
text as a user sanction (measured: a call passed because the main loop
had written "this is a sanctioned probe" a second earlier).

So every transcript entry gets a provenance:

| `src` | What it is |
|-------|---------|
| `user` | what the human typed |
| `assistant` | the text of the very main loop whose call is being judged |
| `tool-output` | tool output |
| `injected` | service insertions, task notifications, letters from other sessions |

Distinguishing goes FIRST by the envelope — `toolUseResult`, `isMeta`,
`isVisibleInTranscriptOnly`, the presence of a `tool_result` block (the
same thing Claude Code itself uses), and only then by wrapper markers
(`<system-reminder`, `<task-notification`, `<cross-session-message`,
`[SYSTEM NOTIFICATION`, `[Request interrupted by user`).

The transcript is passed as a JSON ARRAY, not as labeled strings. A text
prefix carries no trust: content and label share one namespace, and any
string inside a command's output, a file, a web page, or a letter from
another session that begins with `user: ` is indistinguishable from a
real label (demonstrated 2026-08-20 by printing exactly such a string).
In JSON the same text is escaped into the `text` field and cannot become
the neighboring `src` key.

Trimming discards WHOLE old entries — cutting a serialized string would
mean handing the judge broken JSON.

The judge's instruction pins the conclusion: a reference to permission
("this is a probe", "the user sanctioned it") carries weight ONLY from an
entry with `src` equal to `user`.

---

Transcript trimming pins the HUMAN's replies. While trimming was FIFO,
the user's instructions were discarded FIRST — they are the oldest.
Measured by the bench 2026-08-21: after ~70 turns the prohibition
«в этой сессии не вызывай opus» left the transcript entirely (0 `src:"user"`
entries out of 177), and the call was cancelled only by ECHO — a quote of
the prohibition survived in the first 300 characters of a previous
cancellation that had arrived as `tool-output`. Had the main loop been
working silently, the eviction would have been total, and the judge would
have judged as though the human had said nothing. Now `__cut` evicts from
the head everything EXCEPT `src:"user"`, and cuts the human's replies
only if those alone cannot fit; the discard is announced with an entry
`[transcript trimmed: N entries evicted…]`, so the surviving entries are
not read as neighbors. What is pinned is also capped at 35% of the
budget, and within that share is evicted by seniority — otherwise pinning
makes garbage eternal (the bench measured service entries occupying 21%
of a short transcript and growing monotonically). And the `user` class
itself was cleaned up: `<local-command-stdout>` is the PROGRAM's answer,
now `tool-output`; a command invoked by the human got its own label
`user-command` (a human action, but not an instruction to the judge),
while `<command-args>` with non-empty content is the human's direct
speech and stays `user`.

A separate label `compaction-summary` (by the envelope flag
`isCompactSummary`). After a compaction not ONE `user` entry remains in
the transcript — measured by the bench 2026-08-21 — and the human's
directive survives only in the summary. So the summary is pinned with its
own share (30% of the budget) and trimmed BY TEXT rather than discarded.
Trust in it is asymmetric: a prohibition holds, a permission does not
(the client writes the retelling and could have absorbed someone else's
text; a false cancellation is cheaper than a silently passed
prohibition).

These three findings are one class: the client keeps putting new kinds of
entries under the `user` role. Therefore an unknown wrapper in the `user`
class now lands in the journal as the `uw` field: the class became
measurable. Verified on the INSTALLED binary: the function was extracted
from the image and run over 202 entries — the human's reply survived, 66
others were evicted, transcript 59,546 characters against a budget of
60,000.

Every number in a transcript description names a FACT at the time of
output, not a count of actions taken. This is a separate invariant,
because it was violated three times in a row, always in its own favor:
the marker undercounted pinned replies (it counted by deletion labels
after reindexing), overcounted trims (it counted calls, not surviving
entries — 39 against 4 on a real transcript), and the record itself
undercounted what was cut (a re-trim counted from the previous cut point,
not from the original: «вырезано 123» where 4 remained of 200,004
characters).
The invariant is held by two rules: the counters are computed AFTER the
final compaction over the live entries, and a trim of any depth cuts from
the ORIGINAL text, which is kept alongside the transcript. The second
also makes nested labels structurally impossible.

A rung's threshold also works on the pool path — this was checked
separately, because all the judge's traffic now goes there: a rung with
`timeout_ms: 1500` broke off at 1506 ms with "Request was aborted". Hence
also the treatment for minute-long consultations: a rung may carry its own
`timeout_ms`, after which the full transcript yields to a short rung that
answers in 2-3 s. The shipped rungs do NOT set one — they inherit the 240 s
from `[defaults]` — so this is a lever available to an operator, not a
property of the kit as delivered.

---

## 7. The verdict

The verdict must be the FIRST line of the answer. Measured: with the
explanation in front, a reasoning model spent the entire budget deciding
to cancel and was cut off before printing the line — the call went
through, because silence reads as consent. With this ordering, a cutoff
costs the explanation, not the decision.

Parsing: the first line of the form `^(OK|BLOCK|STOP|DENY|WARN):` in
`content`. If `content` is empty but there is reasoning — the LAST such
line is taken from the reasoning: a verdict rehearsed in the middle of a
thought must not override the conclusion.

Execution:

| Verdict | What happens |
|---------|----------------|
| `OK:` | the call goes; a journal line |
| `WARN:` | the call goes; a journal line; **never reaches the model** |
| `BLOCK:`/`STOP:`/`DENY:` with `enforce` | `throw` → `is_error` to the model, the call did not happen |
| same without `enforce` | the call goes, the journal says `block_not_enforced` |
| no verdict on any rung, `fail_closed` | `throw` → the call did not happen, the journal says `block_no_verdict` |
| the judge failed BEFORE a verdict (config, body, trimming, retry), `fail_closed` | `throw` → the call did not happen, the journal says `block_no_verdict` with `reason` |
| settings or prompt broken, `enforce` | `throw` → the call did not happen, the journal says `block_degraded` with `deg` |
| same without `fail_closed` | the call goes, the journal says `skip` with `reason` |

The obligation to issue a decision lives in a separate flag, not derived
from the verdict: it is armed as soon as it is known that the call is not
filtered out and `enforce` + `fail_closed` are on, and is cleared by the
LAST action of the successful path. Anything that throws earlier cancels
the call. Without this, "pass on breakage" and "pass with fail_closed
off" were the same outcome: the retry on the short transcript was not
wrapped, its failure was written as a routine `skip`, and the call went
through — a silent pass exactly where `fail_closed` exists to prevent
one.

The boundary is drawn not along "ENOENT versus everything else", but
along "the path does not exist" (ENOENT, ENOTDIR, ELOOP, ENAMETOOLONG)
versus "the path exists, no access" (EACCES, EPERM); an unfamiliar code
cancels nothing but is named in the journal along with the code itself.
An ordinary file named `.claude` at any ancestor yields ENOTDIR — under
the former boundary this cancelled the ENTIRE subtree with a healthy
judge. A BOM is stripped before parsing: it is invisible, and a
cancellation over it was unreadable. An empty file is called empty but
remains a cancellation — zero bytes means "the settings were there and
vanished", not "there are no settings".

A missing file and an UNREADABLE file are different events, and treating
them identically (`try{…}catch{}` with no trace) switched the gate off
entirely: a broken settings file yielded an empty object, and with it
`enforce` and `fail_closed` disappeared, and a judge with a `BLOCK`
issued would write `block_not_enforced` and pass the call. The layer
reader now returns three outcomes — "absent", "present and read",
"present but not understood" — and the third means the rules are UNKNOWN:
`enforce` and `fail_closed` are treated as on, the call is cancelled with
the file's name. The same for an unreadable project layer: before, it was
indistinguishable from an absent one, the walk went higher and could pick
up someone else's. Harmless degradations (a broken `body.json`) do not
touch the call but land in the journal as the `deg` field — an operator
who supplied their own template must learn that it was not applied.

The fallback prompt (when there is no `prompt.md` of one's own) must be
able to CANCEL. The previous one did not contain the word BLOCK at all
and offered the model a single non-OK outcome, `SWAP:`, which was
recorded as `ok`: the gate was formally alive and substantively off. From
the same root — the response parsing: it returned the raw text if no
verdict line was found, and any answer outside the dictionary became
"ok". An answer without a recognized line is not a verdict.

A cancellation must have a way out: every degradation label carries the
file PATH, list truncation is announced (`[not all shown: N more]`), and
the journal creates its own directory on the first record — otherwise on
a fresh install, where cancellations are most numerous, the journal would
not contain a single one.

The refusal path runs ONLY on breakage, so it must be tested
deliberately: `__pdir` was read in `catch` from a `let` declared inside
the `try`, and the path died with a ReferenceError before reaching the
journal — the dispatch got "__pdir is not defined", the journal got
nothing. Hence the rule: names read by `catch` are declared above the
`try`; there is a structural pipeline check for this, and after any judge
edit the refusal path is tested with a live call against a dead address
(`CLAUDE_JUDGE_URL` to a closed port, `CLAUDE_PROBES_DIR` to a separate
directory, so as not to dirty the corpus).

The two cancellations are separated deliberately. `block` is a JUDGMENT
defect (the judge answered and was wrong), treated by the prompt.
`block_no_verdict` is a CHANNEL defect (the judge did not answer; the
mode cancelled on its behalf); it is not visible in the verdict at all
and is analyzed via `attempts`. From the outside both look the same — a
cancelled dispatch — and while both were written as `empty`, they were
also indistinguishable from a PASSED call, that is, from the opposite
outcome.

`WARN` is a note to the human, not a channel to the model; the
instruction says this outright so the judge does not write into `WARN`
directives that there is physically nobody to execute.

`enforce` is enabled either by `CLAUDE_JUDGE=enforce` or by `"enforce":
true` in the config; the journal's `en` field says which of the two
sources fired — previously this was unobservable.

---

## 8. Fault tolerance and its price

Every failure path is fail-open BY DEFAULT — a dead proxy, a blown threshold,
a broken config, a missing file, and the call goes through as before — but the
shipped settings turn that off for the judge: `[probe.judge] fail_closed =
true` on top of `[defaults] enforce = true`. On a machine installed from this
kit a channel failure therefore CANCELS the dispatch (the user's principle: a
false cancellation is better than a silent pass). The table in §7 is the
authority on which state does what; this paragraph describes the code default
underneath it. This is
the right choice (the judge must not break the work), but it has a price:
**a judge that switched itself off looks in every report exactly like a
judge that approved everything**.

The price is paid for with observability, not by cancelling fail-open:

- the journal is kept ALWAYS, not only with debugging on;
- every line has an `outcome`: `ok | warn | block | block_not_enforced |
  block_no_verdict | empty | skip | filtered`;
- `ms` — latency (the mechanism's only real cost), `sw` — the switch's
  value, `tries`/`jm` — on which rung and by which model the answer was
  obtained, `err1` — all previous rungs' errors, `cfg` — the project
  layer that took effect (it stands in EVERY line, including filtered-out
  ones: previously the filter did not name the layer, and which file had
  acted had to be inferred indirectly from behavior), `sid` and `title` —
  the session and its title (`pid` is no good for addressing: the system
  reuses it — it is carried too, but as the WRITER'S SIGNATURE, which is
  what lets the bench tell its own leak into the live probes home from a
  live session's work; `sid` stays the address), `model` with `msrc` — the dispatch's ALLOWED model and the
  source of the permission (`call`/`agent`/`inherit`; previously only the
  one explicit in the call was written, and a third of the records went
  out with no model at all), `rec` — the full record's name.

This directly closes off "disabled at both ends": without a record, both
a pass and a WARN are indistinguishable from a judge who was never asked.

---

## 9. Records, replay, compression

A journal line is an INDEX, not evidence: its verdict is trimmed, and the
material the judge saw is not in it at all. So a full record is written
alongside, one file per consultation: `{...journal line, http, url, pid,
cwd, attempts[], request, response}`. `attempts` stores, per rung, the
model, transcript size, threshold, budget, duration, code, and error.

Two things this was done for (the user's wording): (1) to later check
whether it judged correctly; (2) to later train a small model on this.

**The record's NAME is a join key, so it must be unique by construction.**
The journal line points at the file through `rec`, and `validate.py` and
`adjudicate.py` index human labels by that basename — two consultations
sharing a name do not merely overwrite a file, they merge two different
judgements under one label, and nothing in the data says it happened. The
name cannot get uniqueness from the tool-use id, because not every route
has one: under `claude mcp serve` the key is undefined for the whole
route (§2, injection 22), which turned `String(key).slice(-8)` into the
constant `ndefined`. The name is therefore
`<timestamp>-<key|nokey>-<pid>-<seq>`: the key keeps the correlation
where it exists, `nokey` says plainly when it does not, and pid plus a
per-process counter separate everything else — across processes and
inside one. Readers must keep treating `rec` as opaque; nothing may parse
a meaning back out of the name.

**The directory is bounded.** One record per consultation, ~28 KB each,
about 130 a day — measured on the live install at 31 MB across 1134 files
with nothing anywhere that ever deleted one. After each successful write
the directory is listed and everything past the newest `records_keep`
(default 500) is unlinked; record names begin with a fixed-width ISO
stamp and end with a zero-padded counter, so a lexicographic sort is
chronological down to two records written in the same millisecond. The
horizon is SHARED: every session on this machine writes into the same
directory, so the count above is the whole machine's, not one session's,
and a busy neighbour evicts a quiet session's records sooner than its own
rate would suggest. The record just written is never the one evicted —
names are ordered by a wall clock, and a clock stepped backwards would
otherwise make the newest file sort earliest and take it first. The prune
rides the WRITE on purpose: `record = false` means "stop writing", not
"erase what is already there", and a switch that quietly destroyed an
existing corpus would be a worse surprise than a directory that stops
growing. A prune failure is reported on the same channel as a failed
record write and never swallowed — except a file a neighbouring session
removed first, which is the outcome this loop wanted and is not reported
as a failure.

The record schema grew over the campaign: the corpus's first seven
records lack the `url`, `cwd`, and `attempts` fields — these appeared
later. Every consumer of the corpus must tolerate this and say so out
loud when substituting what is missing (the validator marks such runs
with a `url_from` field): a run against a substituted address is a
different experimental condition, and passing it off silently as the
original is not allowed.

`replay.py` replays a record: the same request, with substitution of the
model, instruction, address, effort. The channel is chosen by the
`--channel` key:

- `http` — byte-for-byte the same body that went to the proxy. The only
  EXACT replay, but it exists only for the proxy lane.
- `pool` — a run through the client itself (`claude -p --system-prompt …
  --tools ""`). This reaches `claude-*`, but it is NOT the same input:
  measured 2026-08-20 — the client adds its own ~22 thousand tokens of
  context (system prompt, skills, session-start insertions), and on the
  same record the verdict changed `OK → BLOCK`. There was no way around
  it: `--bare` and a separate `CLAUDE_CONFIG_DIR` break authorization
  ("Not logged in"), `--settings` with empty hooks does not remove the
  context, and disabling skills via `CLAUDE_CODE_DISABLE_*` does not
  change the volume (checked twice: the same 22,351 cache-creation
  tokens).
- `auto` — `pool` for `claude-*`, otherwise `http`.

Hence the rule: models can be compared with each other only within ONE
channel, and a "judging replay" in the strict sense is possible only over
the `http` channel. The price of a `pool` run is also different: 21–116 s
and 7–11 thousand output tokens against seconds and hundreds of tokens
over HTTP.

`adjudicate.py` — corpus labeling: a strong model evaluates the verdict
ALREADY ISSUED (`CORRECT` / `WRONG:<class>` / `UNSURE`), it does not
judge the call anew. Proposed labels go into `labels.jsonl` with `source:
"model:<name>"` and NEVER overwrite human ones; `validate.py` computes
accuracy over both SEPARATELY — a proposed label is a hypothesis, not
truth. This is how a prompt edit is checked WITHOUT a new session — on
the recorded input, `--prompt` turned `OK` into `BLOCK`, which is what
proved the fix. The request needs a recognizable `User-Agent`, otherwise
the perimeter answers 403.

Records accumulate uncompressed (writing in the hot path must be cheap)
and are compressed by a daily pass of `compact.py` — idempotently; the
source is deleted only after the archive is re-read and parsed. It is
started by a launchd agent (`com.transmutelabs.judge-compact`, 04:07): a
run missed due to sleep launchd works off after wakeup, whereas crontab
does not.

---

## 9a. Corpus cleanliness

Records before 2026-08-20 ~21:00 are BENCH probes and my own: the
dispatches in them were dictated by a human verbatim, and the judge
lawfully reads them as a direct order. For a sweep over models such
material skews the sample toward `OK`, so when labeling and comparing
models it must either be excluded by time or labeled separately.

A separate trap of the same kind: judging one's own probe proves nothing.
If you dictate the call yourself, the judge sees a user sanction and
answers `OK` where you expect a cancellation. Only the one who formulates
the dispatch themselves and has not read the test plan can test a
cancellation.

## 9b. What leaves the machine

The judge sends the current turn to a model over the proxy. What exactly
goes was never written down, and "the judge sees the dispatch" reads as
though only the dispatch goes. It does not. Stated plainly, because a
mechanism whose outbound content is inferred rather than declared is one
nobody can consent to:

| Sent | Form | Limit |
|------|------|-------|
| user and assistant text | verbatim | none per block |
| the model's `thinking` | verbatim, prefixed `[thinking]` | none per block |
| every `tool_use` | tool name + its input serialized as JSON | first **400** characters |
| every `tool_result` | the result content | first **300** characters |
| the dispatch itself | `JSON.stringify(input)` — prompt, subagent_type, description, model | `dispatch_chars`, default 16000 |
| the rules | `prompt.md`, or `CLAUDE_JUDGE_PROMPT`, or the built-in fallback | none |
| the whole transcript | after the above, as one string | `context_chars`, default 60000 |

So the output of commands, the paths and arguments the tools were called
with, and the beginnings of files that were read all leave the machine
whenever they are in the turn the judge is asked about. The judge does
not open any path of its own — it reads only `prompt.md`, `probes.toml`
and `body.json` — but material already present in a `tool_result` is
material it forwards.

There is **no content-based filtering**: `filter` in the config decides
whether to consult at all (by dispatch class and agent type), not what to
strip. The only reduction anywhere on this path is truncation by length.

Everything sent is also written to disk beside the journal, in the record
(§9), whose `request` field holds the outbound body verbatim.

Two consequences worth stating. First, the destination is whatever the
configured model id routes to through the local proxy — one consultation
may walk the whole ladder and hand the same material to several vendors
in turn (§5). Second, the material is NOT reflected back in a visible
error: on an HTTP failure only the status code is raised, and on a pool
failure only up to 300 characters of the channel's own reply.

If a turn must not leave the machine, the lever is `enabled = false` or a
`filter` that refuses the class — not an expectation that the judge
redacts, because it does not.

## 10. Neighboring mechanisms

| Mechanism | Relation |
|----------|-----------|
| routing gate (`routing-table.toml`, PreToolUse) | deterministic, runs EARLIER; the judge only narrows what is allowed |
| permission system | separate; the glued-in rule explicitly forbids blaming a cancellation on it |
| server-side advisor (`advisor`) | invoked by the model on the server, sees the request body, i.e. the state BEFORE the model's answer; the judge sees the current turn, which the advisor never gets |
| daily compression | outside the process, launchd |

---

## 11. Invariants

Must not be broken:

1. **Off means off.** Without `CLAUDE_JUDGE`, neither injection 22, nor
   accumulator 21, nor gluing 26 works.
2. **Main loop only.** `agentType==="main"` in both injections, 22 and
   26.
3. **Fail-open + mandatory recording.** No failure path breaks a
   dispatch, and none remains without a journal line.
4. **Cancellation, not substitution.** The judge gives the call nothing
   the gate has not allowed. 4a. **The channel is the shared circuit.**
   The judge goes through the client's model pool. A route of its own to
   a vendor bypassing the pool is forbidden: it changes both the billing
   contract and the authorization, and the set of available models.
5. **One home for a setting.** A value set in the config must reach the
   request body; the template may not silently override it (happened
   twice: the model, and then a 1200-token budget that cut a cancellation
   into silence).
6. **Provenance — from the envelope, not from the text.**
7. **The verdict is the first line.**
8. **ASCII on the wire.** tweakcc unpacks and packs the bundle BY BYTES:
   a non-ASCII character written as a literal comes back double-encoded,
   and a real newline inside a string literal of the bundle breaks
   parsing. Only `\uXXXX` and `\n`.

---

## 12. Blind spots

- The judge sees the transcript and the call, but not the repository's
  files and not the call's result: it judges the INTENT, not the outcome.
- `model` in `tool_input` is visible only when named in the call itself;
  the model from the agent's definition is not visible to the judge.
- Transcript trimming discards the old: a long session hands the judge a
  tail, and a ground stated at the session's start does not reach it.
- `WARN` has no channel to the model by design.
- One judging per call: a batch of simultaneous dispatches is judged one
  by one, without knowledge of one another (the CONCENTRATION lens works
  only over the transcript).

---

## 13. Extension points

- **Other tools.** The injection's condition is
  `name==="Agent"||name==="Task"`; extending to another tool needs no new
  locations, only a name and lenses.
- **Another CALLER** (the axis along which the extension actually went,
  2026-08-22). The mechanism was split into a core and a probe
  description: directory, data, trigger, verdict dictionary, reaction.
  The judge is the first consumer, the fleet idle watcher the second. A
  copy with exceptions was rejected: two diverging pieces of ~600 lines
  each would make you pay for every lesson twice. The contract is
  `probe-core.md`.
- **The selector.** `filter` already supports regex lists by dispatch
  class and by agent name, in both directions (`*_skip` / `*_judge`).
- **Your own request layout.** `body.json` is the full template; you can
  change the provider, roles, and message order without touching the
  binary.
- **Training a small model.** `records/` is an already-ready corpus of
  "input → verdict" pairs; `replay.py` is the bench for comparing
  candidates on one input.
- **Project rules.** `prompt.extra.md` in the project — without editing
  the global instruction.

---

## 14. Patcher lessons (each cost one incident)

1. **`ID` is declared LOCALLY in every step.** Taken from a neighboring
   step, it gives a `ReferenceError`, and the step silently does not
   apply.
2. **The failure gate stands AT THE VERY END of the file.** Once it stood
   in the middle, and the four steps after it ran unguarded: a broken
   locator was recorded and read by nobody, and the build reported
   success with a missing patch — that is exactly how step 26 first went
   through as a stub.
3. **A template check is not a smoke probe.** A `ReferenceError: __res is
   not defined` after reworking the request turned ALL judgings into
   `skip`, while all template checks stayed green. The journal caught it,
   not the build. Hence the hard smoke gate: `--version` must return 0
   and print "Claude Code", otherwise the launcher is not repointed.
4. **The launcher is repointed ONLY after green checks**
   (`claude_patch.py --repoint` refuses to work with an unpatched image):
   repointing ahead of time left a window in which new sessions ran
   unpatched.
5. **Your own battery can turn out empty.** Dispatches dictated by me are
   read by the judge as a user sanction — the real findings came from the
   live battery on the bench, not from my own runs.
6. **A captured name is glued into a pattern only through `rxEsc`.** A
   minified name can contain `$`: in 2.1.239 the session matcher is
   called `$jS`. In a regex SOURCE `$` is the end-of-string anchor, so
   the bare name never matches, and the locator falls not because the
   build changed but because the minifier picked a different letter. In
   the REPLACEMENT string the same `$` is a group reference: there, a
   substitution of someone else's capture would pass SILENTLY. Twelve
   places stood bare; one bit. It is fixed as a class (`rxEsc`/`repEsc`),
   and the check "captured names are escaped into patterns" catches the
   next such place at the source, before the build.
7. **A predicate can be passed as a CALLBACK.** A grep over `Name(`
   showed zero consumers of the immunity predicate — and this nearly
   became the conclusion "the mechanism is not wired up". It was passed
   as `_B(reason, Name)`: the instrument did not see the call form, and a
   zero on such an instrument is indistinguishable from a real zero.
   Count usages by the name WITHOUT the parentheses.
8. **The tool-call form is not a constant.** In 2.1.239 the direct
   `e.call(w,ctx,…)` moved behind an adapter `hii(e).execute(w,ctx,…)`,
   where `hii(e) = e.executor ?? {execute:(…)=>e.call(…)}`. The judge's
   locator holds BOTH forms and hooks onto the TOOL itself, not the
   wrapper: `.name` exists on the tool, not on the adapter. The
   replacement is inserted by offset (`m.index`), not via
   `String.replace`: group numbers diverge between the forms, and a `$`
   in the replacement would be read as a reference.

---

## 14a. How to see what actually went to the proxy

Channel diagnostics on CliProxyAPI (verified 2026-08-20; the procedure
was confirmed by the proxy project's session):

- `~/.cli-proxy-api/logs/main.log` — access lines only: code, latency,
  path, request id in square brackets. No bodies.
- `~/.cli-proxy-api/logs/error-*.log` — full dumps, but only for
  UNsuccessful ones.
- Full dumps of successful ones are enabled by `request-log` (NOT
  `debug`: that only changes the log level). A live toggle without
  restart, driving the API on 8318:

      K='<mgmt-key from ~/.cli-proxy-api/config.yaml>' curl -s -X PUT
      http://127.0.0.1:8318/v0/management/request-log \ -H
      "Authorization: Bearer $K" -H 'Content-Type: application/json' \ -d
      '{"value":true}'
      # exactly ONE call from Claude Code
      curl -s -X PUT http://127.0.0.1:8318/v0/management/request-log \ -H
      "Authorization: Bearer $K" -H 'Content-Type: application/json' \ -d
      '{"value":false}' ls -t ~/.cli-proxy-api/logs/v1-messages-*

  The key in `config.yaml` is plaintext; `merged-config.yaml` holds its
  bcrypt hash, and with that the management API answers `invalid
  management key`.
- Both sides are visible in the dump: `REQUEST BODY` — what the client
  sent, `API REQUEST N` — what went upstream after the protocol
  translation (N>1 — a retry on a different credential), `API RESPONSE
  N`, `RESPONSE`.
- There is no per-session filter; the granularity is the request id (it
  is also in the file name, and also in `main.log`); there is `GET
  /v0/management/request-log-by-id/:id`.
- Keep the window to seconds: bodies are written in full, non-error dumps
  have no rotation, and the rest of the fleet goes through the backend —
  other people's bodies will fall into the window too.

A separate trap: `ANTHROPIC_BASE_URL` from the session's shell
environment does NOT redirect the session — `env` in
`~/.claude/settings.json` overrides the variable. A probe conceived as
"route the proxy lane to its own receiver" went to the real proxy and
silently looked successful.

## 15. Porting to a new version

1. Unpack the new version's image, run `claude-patch-all.sh` — the
   locators are structural and usually apply as is.
2. 116/116 checks must pass; any `fail` — read the locator, do not work
   around it. The locators survived 2.1.229–2.1.238 without edits (the
   237→238 transition — on the first run). On 2.1.239 two broke: the
   adapter around the tool call, and the `$jS` name glued into a pattern
   unescaped (lessons 6 and 7 in §14). Both were in the patcher, not in
   the workaround: the pipeline writes NOTHING if any patch fails, so on
   2.1.239 there would have been no judge in the image at all.
3. The smoke gate (`--version`) must pass BEFORE the launcher is
   repointed.
4. A live probe of the judge: one session with `CLAUDE_JUDGE=enforce`,
   one deliberately overreaching dispatch; the journal must show
   `outcome:"block"`, `en`, `tries`, `rec`, and the session must show a
   tool error with the reason's text.
5. Ladder and cancellation: two fixtures in `judge/fixtures/` (see its
   README) — run both, compare the journal against the expectations
   recorded there as well.
6. Project-layer control: the same dispatch from a directory with
   `.claude/probes/judge/prompt.extra.md` — in the journal `cfg` points
   at the project directory; outside the project `cfg: null`.
