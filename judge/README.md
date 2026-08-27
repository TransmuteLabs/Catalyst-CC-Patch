# Subagent dispatch judge

The binary patch consults the judge BEFORE every Agent/Task call made by the
main loop (calls made by the subagents themselves are not judged). The judge
sees the current session history up to and including the current turn, plus
the dispatch text.

The judge does not rewrite a call. It either passes it through or CANCELS it
and tells the main loop what is wrong; the cancellation reaches the model as
a tool error.

## Files (read on EVERY call — editing requires no binary rebuild)

Settings for ALL probes live in a single `~/.claude/probes/probes.toml`; the
judge keeps a directory `~/.claude/probes/judge/` for text and data.

| file | what it defines |
|---|---|
| `probes.toml`, table `[probe.judge]` | model, timeout, mode, context limits |
| `judge/prompt.md` | the judge's instruction (substituted into `{{PROMPT}}`) |
| `judge/body.json` | full request template: `{{PROMPT}}`, `{{MODEL}}`, `{{CONTEXT}}`, `{{DISPATCH}}` |

Effective settings = `[defaults]` + `[probe.judge]`, the probe's table wins.
Below, "config.json" appears in post-mortems of past defects — it is named
there as it was named at the time; the mechanism has not changed since, only
the file has.

The model has ONE home: `CLAUDE_JUDGE_MODEL` -> `model` in the judge's
settings -> the default. In the template it is substituted via `{{MODEL}}`; a
literal written into `body.json` by hand will be overridden — otherwise the
documented override would silently stop working whenever a template exists
(which is exactly what happened before 2026-08-20).

Debug files (written only under `CLAUDE_JUDGE_DEBUG=1`):
`last-request.<pid>.json` and `last-verdict.<pid>.txt`. The pid is in the name
because two sessions used to write both files under one name and the one you
read was whichever finished last. There is no `last-response.json`: the reply
is in the record (`response`), together with the request that produced it, and
a second copy under a fixed name would only be another thing to keep in step.

## Enabling

| variable | meaning |
|---|---|
| `CLAUDE_JUDGE` | unset — the judge is fully off: no channel calls, no records, no context accumulation |
| `CLAUDE_JUDGE=1` | the judge is consulted, but cancellation is not applied |
| `CLAUDE_JUDGE=enforce` | cancellation is applied (the same effect comes from `enforce = true` in the judge's settings) |
| `CLAUDE_JUDGE_DEBUG=1` | verdict to stderr + dumps |
| `CLAUDE_JUDGE_MODEL`, `CLAUDE_JUDGE_URL`, `CLAUDE_JUDGE_TIMEOUT_MS`, `CLAUDE_JUDGE_PROMPT` | point overrides |
| `CLAUDE_PROBES_DIR` | home of ALL probes; when set explicitly, disables the project layer |

The single master switch is the variable `CLAUDE_JUDGE`. `enforce:true` in
the file does NOT enable the judge; it only sets the mode of an already
enabled one. Otherwise the environment beats the file, and the file beats the
default. The channel address is taken by default from the session's
`ANTHROPIC_BASE_URL` — no need to set it separately.

### State as of 2026-08-20: watching is enabled globally

In `~/.claude/settings.json`, under `env`, sits `"CLAUDE_JUDGE": "1"` — the
judge reviews every dispatch of the main loop and writes a journal with
records, but does NOT cancel: the global `enforce` is `false`. This is the
corpus-collection mode before choosing the smallest model.

The price of this mode: each subagent dispatch gains one consultation
(median around 5-8 s) and one channel request. If that gets in the way,
narrow it with the `filter` selector in the config (lists of classes and
agent names), or remove the variable from the settings; a backup of the
settings made before enabling sits nearby:
`~/.claude/settings.json.backup-judge-on`.

## Which calls to judge (by default — all)

A consultation costs several seconds on EVERY main-loop call, so the judge's
settings allow narrowing the scope. There is no `filter` key by default —
then all calls are judged.

```json
"filter": {
  "classes_judge": ["analysis", "critique", "audit"],
  "classes_skip":  ["adjudication"],
  "agents_judge":  ["^fable-", "^opus-"],
  "agents_skip":   []
}
```

Rules: the strings are regular expressions; `_skip` lists win; if at least
one `_judge` list is set, only matches are judged. The class comes from the
`[dispatch-class:…]` marker in the prompt, the agent name from
`subagent_type`.

What the injection point sees and what it does not (measured):
`subagent_type` and the class marker are always present; the `model` field
appears ONLY if the model is named in the call itself. A model inherited
from the agent definition is invisible here — the "expensive model" rule
has to be expressed through the agent name, not the model.

Filtered calls land in the journal with `outcome:"filtered"` and a `by`
field naming the rule that FIRED: `classes_skip`, `agents_skip`,
`not_in_judge_list`, `no_class_marker`. The distinction is not cosmetic: a
typo in a `_judge` list and an intentional skip produce the same outcome,
and without `by` the first looks like the second. The tax saving is
computable from the journal.

## Verdicts

```
OK:<reason>                                    pass through
WARN:<reason>                                  pass through, note goes to the journal only
BLOCK:<what is wrong and what to do instead>   cancel the call
```

Important about WARN: it does NOT reach the model and cannot. The call
proceeds, and the tool result the model later sees comes from the agent
itself — there is no regular channel for a note there. Practically, WARN is
an OK with a journal record. The instruction writer should not count on
anyone reading the text after WARN during the session: if the note must
change the main loop's behavior, it is a BLOCK; otherwise it lives only in
the journal. The LAST verdict-looking line from `content`, `reasoning` and
`reasoning_content` is accepted — a reasoning model often leaves `content`
empty.

## Fault tolerance and the journal

Any judge failure (channel unavailable, timeout, unparseable answer) passes
the call through. The only thing the internal error interception enforces
is the cancellation itself.

That is why the journal is kept ALWAYS, not only during debugging: a call
skipped due to failure and a call the judge never touched are
indistinguishable from the outside. The file is `journal.jsonl`, one line
per consultation:

```json
{"t":"…","tool":"Agent","agent":"glm-scout","model":"glm-5.3","ms":3952,"sw":"1",
 "http":200,"outcome":"ok","en":null,"verdict":"OK:…"}
{"t":"…","tool":"Agent","agent":"glm-scout","model":"glm-5.3","ms":12,"sw":"1",
 "outcome":"skip","reason":"TypeError: Unable to connect…"}
```

Values of `outcome`: `ok`, `warn`, `block` (cancelled by verdict),
`block_not_enforced` (a cancellation was issued but the mode is not
enforce), `block_no_verdict` (cancelled by an exhausted ladder under
`fail_closed`), `empty` (answer without a verdict, call passed through),
`skip` (the judge did not run; the reason is in `reason`).

The last two cancellations are distinguished ON PURPOSE: `block` is a
judgment defect, cured by the prompt; `block_no_verdict` is a channel
defect, invisible in the verdict at all, and must be investigated through
the record's `attempts`. While both were written as the same word, they
were also indistinguishable from a skip — that is, from the exact opposite
outcome.

Each line describes itself: `ms` is the full consultation round trip in
milliseconds (single digits for filtered calls, seconds for real ones),
`sw` is the value of `CLAUDE_JUDGE` in that run, `en` is what exactly
armed the enforcement mode: `"env"`, `"config"`, or `null` when it is not
armed. Without the last two fields, a `block` line and a
`block_not_enforced` line from different runs differed only by a guess
about which environment was in effect.

The first-priority metric in live operation is the share of `skip` and
`empty` by reason code: a judge that "sits there and never fires" shows no
green signs. Measured 2026-08-20: two consultations in a row hit the
timeout, and fail-open passed both dispatches in complete silence — in the
report that is indistinguishable from "the judge approved everything".

That is why the judge walks a LADDER of attempts from `models`: a rung
fails — the same question goes to the next one. A rung is either a model
name as a string, or an object with its own limits:

```json
"timeout_ms": 60000,
"models": [
  {"model": "deepseek-v4-flash"},
  {"model": "glm-5.3", "timeout_ms": 90000, "context_chars": 8000},
  {"model": "gpt-5.6-sol", "max_tokens": 1500, "effort": "low"}
]
```

The shared default timeout is 60 seconds, the user's decision (2026-08-20):
"better to over-wait than to under-wait". The grounds are measurable:
trivial judging takes 2-3 seconds, while a contested one — the very kind
the mechanism exists for — took 21.4 seconds and 2389 answer tokens. Under
the 20-second timeout in place an hour earlier, that verdict would have
been killed by timeout; under the old 1200-token ceiling it would have
been cut off mid-word.

A rung's effort is set separately and must match the routing table pin:
`deepseek-v4-flash` — `high`, `glm-5.3` — `max`. Before 2026-08-20 the
judge ran with `"reasoning_effort": "low"` hard-wired into the template —
below what is allowed — and this was noticed not by a human but by the
dispatch gate, when the same request was retried from the outside.
Measurement after raising to `high`: 2.5 / 2.5 s versus the old 2.5-3.6 s,
so the price is zero.

Per-rung limits exist because rungs fail for DIFFERENT reasons: an
overloaded provider needs a bigger timeout, a reasoning model a bigger
budget, an overly long transcript a short tail. `timeout_ms`,
`max_tokens`, `context_chars` and `effort` in a rung override the shared
values; whatever is absent is taken from the config root. The order of
rungs is the order of attempts, so for the "judging must be certain" case
the ladder can be extended as long as needed.

A rung that failed on its own timeout does not spend the shared one:
verified with a local receiver — a rung with `timeout_ms: 1000` broke off
at 1007 ms under a 30 s shared timeout, the next one yielded to the third
with an empty answer, and the third issued the refusal (`tries:3`,
`err1:"slow-a: AbortError… | empty-b: empty verdict"`). The transition
happens on network failure, on timeout, and on any non-2xx (HTTP 429 once
produced an empty verdict, and that read as "the judge has nothing to
say"). If none answered, one last attempt is made on the last model with
the transcript trimmed to `retry_context_chars` — the transcript itself is
the main cost of the request. If that fails too, the call goes out
unjudged, silently, as before.

An empty answer on HTTP 200 is as much a failure as a network error: a
reasoning model can spend the whole budget on thinking and be cut off with
`finish_reason:"length"`, and then the decision to cancel the call is never
printed at all, while the judge's silence passes the dispatch. Measured
2026-08-20: the judge identified both an oversized model and a fabricated
sanction — and never got to announce the refusal. Hence the verdict is
required on the FIRST line of the answer, before the justification (a
cut-off then carries away the explanation, not the decision), and an
answer without a verdict advances the chain to the next model. After the
format change flash fits into 150 tokens where 1200 had not been enough.

The output ceiling is a LEASH, and through the pool it snaps dry. Measured
2026-08-20 on the same transcript: `deepseek-v4-flash` spends 434 / 568 /
944 / 1826 / 2120 answer tokens at effort `high`, and 302 / 973 / 1065 /
1204 / 3000 at `low`. The spread within one effort exceeds the difference
between efforts, so lowering the effort for budget reasons is pointless —
the table pin stays `high`. What matters is different: HOW the overrun
ends. Over HTTP it arrives softly — `finish_reason:"length"`, the
first-line verdict is already printed and valid. Through the pool the same
overrun becomes a synthetic client error ("response exceeded the N output
token maximum") with `output_tokens: 0`: no text remains at all, and the
"verdict on the first line" rule does NOT save it. The price was observed
live — 27.9 seconds thrown away, after which the next rung gave a verdict
in 2.5 seconds. Hence the shared ceiling is raised from 3000 to 8000
tokens: it does not lengthen a normal answer (the model writes as much as
it intended) but removes the cutoff where a cutoff is unrecoverable. A
rung for which even 8000 is not enough for a yes/no decision lawfully
yields to the next one.

Frequency, for scale: over the first day's 49 consultations rung 1
yielded six times, and all six within one half-hour under bench load.

`fail_closed: true` — if NOT A SINGLE rung produced a verdict, including
the last attempt with the trimmed transcript, the call is CANCELED, not
passed through. The user's decision (2026-08-20):
«лучше ложная отмена, чем молчаливый пропуск». This is the only place where the judge
departs from fail-open; under `fail_closed: false` (the default) an
exhausted ladder still passes the dispatch silently.

The journal shows this in full: `jm` — which model gave the verdict,
`tries` — on which attempt, `err1` — how the failed ones ended. Worst-case
latency is the number of models plus one attempt, multiplied by the
timeout; with a chain of two and `timeout_ms: 60000` that is several
minutes. The user's decision (2026-08-20): such a delay is acceptable,
because a prevented wrong dispatch costs more.

Measured 2026-08-20 on trivial judging: `deepseek-v4-flash` — 3.6 / 3.4 /
3.3 s (median 3.4, tiny spread), `glm-5.3` — 5.9 / 1.9 / 2.1 s (median
2.1, but jumpy). Hence the chain order: the stable one first, the fast one
second.

If writing to the journal fails (no directory, no permissions), the line
goes to the error stream in full — otherwise an unperformed consultation
would look like one that never happened, that is, the journal would
reproduce exactly the blindness it exists to remove.

## Transcript trimming

The transcript is trimmed to `context_chars`, and until 2026-08-21 the
trimming was FIFO — meaning it threw away the HUMAN's instructions first,
they being the oldest. The bench measured the price: after ~70 turns
the prohibition «в этой сессии не вызывай opus» was gone from the
transcript entirely (0 records with `src:"user"` out of 177). The call was
still cancelled then, but only by ECHO — a quote of the prohibition
survived in the first 300 characters of a past cancellation that had
arrived as `tool-output`. Had the main loop worked silently, the eviction
would have gone through clean.

Now everything is evicted from the head EXCEPT `src:"user"`; human
replies are cut only if they alone do not fit the budget. The skip is
announced by a record `[лента подрезана: вытеснено N записей; реплики
человека сохранены]` — otherwise the surviving records read as adjacent,
and the CONCENTRATION lens judges by a splice that never happened in the
run. It costs almost nothing: human instructions in a transcript number
in single digits (10 out of 150 in the measurement).

Two limitations found right after pinning (bench, 2026-08-21). First:
`<local-command-stdout>` arrives under the `user` role, although it is
the PROGRAM's reply to a human action — that is, local command output was
landing in the single provenance to which the judge gives the weight of a
sanction, and after pinning it settled there forever. Now it is
`tool-output`, and the command invocation itself (`<command-name>`) got
the label `user-command`: a human action, but not an instruction to the
judge. Second: pinning without a ceiling makes garbage ETERNAL — in the
bench measurement service records occupied 21% of a short transcript and
grew monotonically. Therefore pinned content is capped at 35% of the
transcript budget, and within that share eviction is by seniority: fresh
words of the human matter more than old ones.

A third limitation was found in the same place and turned out heavier
than the first two: the COMPACTION SUMMARY. It arrives under the `user`
role with the `isCompactSummary` flag, weighs tens of thousands of
characters, and until 2026-08-21 received the `injected` label — meaning
it was the first to fly out of the transcript. The bench measured the
consequence: after compaction not ONE `src:"user"` record remains in the
judge's transcript, and a standing human prohibition exists only inside
the summary, that is, for the judge it does not exist as a sanction at
all. Meanwhile the trimming marker said «реплики человека сохранены» —
formally not a lie (there was nothing to preserve), but it sounded
reassuring exactly where things were at their worst.

Now the summary has its own label `compaction-summary`, its own pinning
share (30% of the budget) and trimming BY TEXT (from both ends: the head
carries the essence, the tail the "all user messages" and "open tasks"
sections) instead of ejection: the sole carrier of standing instructions
cannot be thrown out. The rule of trust in it is deliberately asymmetric
and is written in the prompt: a prohibition or a restriction from the
summary applies, a permission or "the user approved" does not. The
grounds: the summary is written by the client retelling the run, and the
retelling could have absorbed someone else's text, so it cannot issue a
sanction; a prohibition only restricts, and a false cancellation is
cheaper than a silent pass. The marker now names the numbers:
`[лента подрезана: вытеснено N записей; закреплено
реплик человека: K, резюме компакции: M]`.

The slash-command arguments label was fixed in the same place:
`<command-args>` carries the human's OWN words
(«веди полосу lane-16, без агентов и без скриптов» — 24 such
blocks in the project's transcripts), so a record with non-empty
arguments is `user` with full sanction rights,
while a bare invocation like `/model` stays `user-command`.

And one conclusion about the defect class itself. Three finds in a row —
local command output, slash-command arguments, the compaction summary —
were ONE AND THE SAME thing: Claude Code keeps putting new kinds of
records under the `user` role, and each was found through an incident.
Therefore an unknown wrapper surviving in the `user` class lands in the
journal as the field `uw` — the class is now measurable instead of
waiting for the next incident.

Symmetry matters more than any single half. The first draft of pinning
trimmed ONLY the summary by text and still threw human replies out whole —
and the bench showed a hole in the same spot: one large user paste pushed
out both the summary and the standing prohibition itself, while the
marker reported «закреплено реплик человека: 1»
(the surviving "reply" was the useless tail of a paste). Now ANY
carrier of instructions is trimmed by text, and the LONGEST one, not
the oldest: size is not a sign of importance, and the age policy
threw out a fifteen-character prohibition in favor of a
hundred-thousand-character paste. Eviction by seniority engages
only when there is nothing left to trim. The last line of defense
(the transcript still does not fit, nothing unpinned remains) no longer
demolishes the pinned unconditionally either — it shortens the longest
record. And the marker names what was lost among the pinned:
`ВЫТЕСНЕНО ЗАКРЕПЛЁННЫХ: N`.

Verified on the installed image by reproducing the bench cases: a 42 KB
summary plus a prohibition plus a 120 KB paste under a 60 000 budget — the
prohibition is visible, the summary survived (17 943 characters); the same
on a short rung under an 8 000 budget — the prohibition is visible, the
summary 2 343; forty instructions in a row — all 41 in the transcript, 31
trimmed by text, none lost.

Three more roots turned up when the bench hit the already fixed trimming —
and all three were properties of the CODE, not of the fed transcript.

First: the summary share was counted PER RECORD, not per class. As many
summaries as there are in the transcript, that many times 30% of the
budget: measured — 14 summaries took 64% of the transcript, and unpinned
content was evicted clean, meaning the judge stopped seeing the very
course of work it is asked about. Now the share is counted over the whole
class, as for human replies.

Second: the iteration ceilings (60 and 40) returned a transcript ABOVE the
budget. With many pinned records each shorter than 400 characters, text
trimming never engaged, leaving eviction — and after the counter ran out
the function returned what it had: 1000 short replies gave 301 237
characters against a 60 000 budget, and shrinking the budget did not
shrink the transcript at all. This is exactly the input that runs into
the model's output ceiling.

Third: the trimming was QUADRATIC — the whole array was re-serialized on
every deletion. 4 800 records cost 8.3 seconds of pure local computation
under a rung timeout of 25 seconds, meaning the trimming itself ate the
timeout, and separately on every rung.

Rewritten to counting by numbers: each record's cost is computed once,
then arithmetic follows, and serialization happens exactly once, at the
end. Measurement on the installed image: 14 summaries + 80 work records
-> transcript 45 214 within budget, summaries 39%, all 80 work records in
place, 1 ms; 1000 short replies -> 21 053 within budget, 6 ms; 4 800
records -> 59 895 within budget, 17 ms instead of 8 300.

And one more root, found after the rewrite: UNPINNED records were only
ever evicted whole and never trimmed by text. Three manifestations, all
measured by the bench. The transcript could zero out completely: with
nothing pinned and one fresh record longer than the budget, the loop
evicted everything including that record itself, and the judge received a
transcript of one marker — that is, it issued an ordinary verdict BLIND,
which is worse than cancellation because it goes unnoticed (the boundary
at a 60 000 budget: a record of 59 700 survived, 59 800 zeroed the
transcript). The budget went unused: a 200 KB summary plus a 200 KB reply
plus 40 KB of fresh work yielded a transcript of 38 815 under a 60 000
budget, with the work thrown out whole although its tail would have fit
the gap. And most often it hit the lower rungs: on a 12 000 transcript
the judge saw 446 characters — 96% of the budget vanished together with
the course of work.

Now a record whose deletion would push the transcript below the budget is
SHORTENED to the remaining gap instead of being thrown out. Measurement
after the fix: 30 old records plus a fresh 90 KB one -> transcript
59 856, the fresh one in place, trimmed; a single 59 800 record ->
survives; the unused-budget case -> 59 855 out of 60 000, work in the
transcript; a rung with a 12 000 transcript -> 11 855 instead of 446, the
human prohibition visible.

Worth remembering separately: the text of an `assistant` record in the
transcript is unlimited (in the layout only tool results are cut to 300
characters and invocations to 400), so "one unpinned record longer than
the budget" is not an exotic case but an ordinary long reply of the main
loop.

The last pair of roots is borderline but real: the trimming thresholds
were counted in TEXT characters while the budget was in JSON characters.
Escaping inflates a control character sixfold, and the miss went both
ways: the transcript exceeded the budget at small values (the bench
measured an excess up to +630 at `context_chars` below 1100) and
undershot the budget on escapable content (a transcript of nothing but
quotes took 8.5% of the allotted space). Separately, the marker reserve
did not add up: the `Math.max(200,…)` floor ate it, and the marker landed
on top of the budget.

Now all thresholds are given in JSON length: the trimming receives a
target PRICE of a record and picks the text limit from the actual one,
and the marker is added last and paid for by shrinking the transcript by
exactly its own price (on a tiny budget it switches to a short form,
otherwise it does not fit itself). Verified by a battery of 3 024
combinations (six kinds of content x 7 transcript sizes x 6 record
lengths x 12 budgets from 200 to 60 000): zero excesses; budget
utilization 90-99% versus the former 8.5% on escapable content.

Quadraticity had to be removed TWICE, and the second time it was of a
different nature. The first lived in serialization (the whole array was
rebuilt on every deletion). The second lived in the deletions themselves:
`splice` over two arrays and a repeated search for the longest record at
every step. Measured by the bench: a transcript of 40-60 thousand records
cost 5-10 seconds of PURE local computation, on every rung of the ladder,
that is, up to half a minute of added delay before the verdict. Its
differential check pointed at the culprit precisely: the same transcript
without pinned records — 886 ms, with 20% pinned — 5108 ms, meaning the
class ceiling was paying.

Now deletion MARKS instead of cutting, the array is compacted once at the
end, and the top-up inside the share goes with a single cursor from the
head instead of searching for the longest at every step. Measurement after
the fix: 2 500 records — 6 ms, 10 000 — 22, 20 000 — 44, 40 000 — 76,
60 000 — 128 ms (it was 9 998). The bench's differential check: 40 000
without pinned records 72 ms, with 20% pinned 77 ms — the class ceiling's
contribution is gone.

And the latest for today — the marker LIED in its own favor, and in the
working range. Deletion marks were reset after the first compaction of
the array but not after the second (inside the marker block), and the
numbers for the marker were counted through those marks over the already
re-indexed transcript. The marker loop deletes from the head, so after
the filter the marked indexes hold the first SURVIVORS — and the counter
skipped them. The marker undercounted pinned human replies: on a
transcript of 4000 short lines it claimed 433 against 439 actual under a
60 000 budget, 56 against 63 at 8 000; in extreme form it said
«закреплено реплик человека: 0» when two lay in the transcript. That
is, it told the
judge the exact opposite of the truth — the very guarantee pinning was
created for. The numbers are now counted over the filtered transcript,
marks are reset after EVERY compaction, and a pipeline check stands over
this. Verified: 108 combinations of record count, reply share and budget —
zero discrepancies.

From the same family, weaker: the marker loop had index 0 hard-wired,
while deletions go from the head — an already-marked record got trimmed,
and a live one never received its final trim. It had no consequences (the
bench measured 744 firings out of 10 710, all at budgets of 130-256, no
excesses), but the index was wrong all the same: now the first live
record is taken.

The same lens — "the transcript description must not lie" — applied to
ALL numbers, not just pinning, exposed two more lying numbers (bench,
2026-08-21). First: «подрезано по тексту: N» counted trim INVOCATIONS, not
records surviving to output. One record can be trimmed twice (first by
class share, then in the marker loop), and a trimmed one can later be
evicted — the counter still remembered it. On a real transcript at a
24 000 budget the marker claimed 39 trims against 22 live ones, at
12 000 — 39 against 20, at 1 000 — 39 against 4, that is, tenfold. Now
LIVE records with the label are counted, after the final filter.

The second is worse, because it lied inside the record itself. A repeat
trim took the already-trimmed text and counted the cut relative to IT,
while the past label fell out of the text together with the trace of the
first trim. The worst deliberate case: a record claimed
«[вырезано 123 знаков]» when 4 characters remained of the original 200
004. The judge reads
"one hundred twenty-three" and may rightly believe it sees the record
almost whole. Now the record stores the ORIGINAL text, and any trim —
first or third — cuts from it: the number in the label always names the
cut from the original, and nested labels become structurally impossible,
not a matter of lucky arithmetic (the bench noted separately that there
was no protection in the code — the label fell out on its own). The
corner where, under heavy escaping, head and tail overlapped and the
label printed a negative number was closed along the way.

Verified on the installed image: 704 synthetic combinations (record
count x length x budget x composition) — zero false numbers, zero marker
discrepancies; a real transcript of 6 506 records at budgets from 60 000
down to 400 — the claimed matches the actual at every one (57/57, 31/31,
16/16, 12/12, 2/2), zero false numbers in records; a targeted double trim
of one record — the number in the label equals the cut from the original
at all five budgets. Regression: 1 296 budget combinations — zero
excesses everywhere except the long-described corner `context_chars` =
60, where the marker physically does not fit; 60 000 records — 120 ms.

The next round the bench ran with the same lens over the journal and the
record — and the main thing it found was not a number but an OUTCOME. The
retry on the shortened transcript was not wrapped in try/catch, unlike
every rung of the ladder. Meaning: the ladder is exhausted without a
verdict, the retry throws (timeout, channel refusal) — control goes to
the outer catch, which writes "skip" and does NOT cancel the call. A
silent pass exactly at the point `fail_closed` was created for, and in
the journal it looks like a regular skip.

While verifying this on a live call, I found the second half of the
defect, my own: the refusal path itself was broken. `__pdir` (the
project layer directory) was declared INSIDE `try` but read in the
`catch` — a neighboring block where `let` is not visible. The path
executes only on failure, so the typo lived unnoticed: the journal had
NOT ONE "skip" record newer than the day the `cfg` field was added.
Measured: a dispatch with a dead judge address returned "__pdir is not
defined", and the journal got nothing — building the record object
crashed before the record itself. That is, the only path obliged to
explain why the judge stayed silent was itself the loudest silencer.

Fixed in full, not at the crash point. The retry is wrapped as a rung
(its error now lands in `err1` instead of being lost). The obligation to
deliver a decision was lifted into the variable `__jarm`: it is armed as
soon as it is known that the call is not filtered and `enforce` +
`fail_closed` are on, and it is cleared by the LAST action of the
success path. Any exit to `catch` with the flag armed is a cancellation,
not a skip; this also covers crashes BEFORE the ladder (reading the
config, building the body, trimming), where no verdict can exist. The
journal write is wrapped at the call site, so that its failure with a
ready BLOCK cannot turn into a pass. `__pdir` was lifted to the other
pass-through names, and the pipeline gained a structural check: every
name the `catch` reads must be declared above the `try`. The check is
not a rubber stamp — on the previous image it names `__pdir`, on the new
one it is clean.

Measured on the installed image, dead judge address: `fail_closed:true`
-> `block_no_verdict`, `tries:4`, all four errors in `err1` (including
the retry's error), the dispatch CANCELED with an explanation about the
channel; `fail_closed:false` -> `empty`, the dispatch went through. The
`catch` path was verified separately — the function was extracted from
the image and run: without the obligation it writes "skip" with the full
set of fields (`cfg` in place, no ReferenceError), with it armed it
throws a cancellation labeled `__ccJudgeBlock`.

From the same check — two more, weaker. The attempt's answer and status
(`__jres`, `__jst`) were not cleared at the start of the next one: the
request was written by every attempt, but the answer only by the
successful one, and a record could glue the last attempt's request to an
early answer. The bench honestly said that in 63 records this does not
occur — the successful attempt always turned out to be the last. I built
the reverse case deliberately (the first rung answers with a model error,
the second breaks off by timeout before any answer): before the fix the
top-level `http`/`response` would belong to the first with the request
from the second; after the fix they are empty, and the attempts' traces
each remain with their own. And `tries` was initialized to one — it
claimed an attempt where the throw happened before the ladder; now zero.

Finally, truncations in the journal and the record are announced by the
same convention as transcript trimming: `verdict` (400), an attempt's
`resp` (800), `err1` in chunks (80), `reason` (200) — all receive «[вырезано N знаков]».
A verdict cut off mid-word reads to a human as the
whole verdict, and a truncated answer of a failed attempt as its whole
trace.

The next round the bench ran over the OTHER failure paths — those that
execute only on breakage, and therefore are tested by nothing except
deliberate breakage. Two gate switches were found.

First: a broken `config.json` silently turned the judge into fail-open.
`try{__cfg=JSON.parse(…)}catch{}` gave an empty object, and with it
everything written in the config vanished — both `enforce` and
`fail_closed`. Bench measurements on the same broken file: with a dead
channel — `empty` and the dispatch WENT THROUGH (with a sound config
under the same conditions, `block_no_verdict` and cancellation); with a
live channel and a real `BLOCK:` verdict — `block_not_enforced` and the
dispatch WENT THROUGH. The judge issued a cancellation, and the
cancellation was silently thrown away. Along the way, and also silently:
`max_tokens` fell to the built-in 1200 (below the threshold it was being
raised to 8000 for), the ladder collapsed to a single rung, the timeout
became 8000 ms. The journal said not a word about any of this.

The key to the fix is an asymmetry the bench named outright: a missing
config and an UNREADABLE config are different events. The first means
"there are no settings, work by default", the second — "there are
settings, but I could not understand them". Now the reader distinguishes
them: `null` — no file, `!1` — the file exists but was not read or not
parsed. An unintelligible config means `enforce` and `fail_closed` are
UNKNOWN, and they are treated as enabled: the dispatch is canceled with
the file name and the parse error text. The same for an unreadable
project layer (`chmod 000`), which before was indistinguishable from a
missing one — the layer vanished silently, and the walk upward went on
and could pick up SOMEONE ELSE'S layer.

Second: a missing `prompt.md` gave a fallback prompt that DOES NOT KNOW
HOW TO CANCEL. The built-in text (131 characters) did not contain the
word BLOCK at all, and the only non-OK outcome it offered the model —
`SWAP:` — was recorded as `ok` and passed the call through. The
cancellation machinery itself was intact: the bench checked both sides —
if the model produces `BLOCK:` anyway, the call is canceled. That is,
the gate was formally alive and substantively off, and from the outside
this looked like normal operation: a journal full of "ok". The fallback
prompt was rewritten — it explains that a call can be canceled and names
BLOCK; SWAP was removed as a leftover of an old design (the judge does
not rewrite a call, it cancels it). And the absence of one's own
`prompt.md` under `enforce` is now by itself a cancellation: that is a
broken deployment, not a mode of operation.

From the same post-mortem — a third fix, wider than the find. The answer
parser returned the RAW text of the model if no verdict line was found
in it, and such an answer was recorded as `ok`. That is, any answer
outside the vocabulary — not only `SWAP:` — passed the call and claimed
a verdict that did not exist. Now an answer without a recognized line is
not a verdict; under `fail_closed` that is a cancellation, while the
full answer still lies in the record.

All degradations land in the journal as the `deg` field — both those
that cancel the call and the harmless ones (a broken `body.json`: the
judge works with the built-in body, but whoever placed their own
template learns it was not applied). Measured on the installed image:
broken config -> `block_degraded`, `tries:0`, `deg` names the file and
the parse error; missing `prompt.md` under `enforce` ->
`block_degraded`; the same without `enforce` -> the call goes,
`deg:["prompt-missing"]`, the verdict issued by the fallback prompt;
broken `body.json` -> the call goes, `deg` names it; unreadable layer ->
`block_degraded` listing all four unreadable files; sound layout ->
`ok`, 8.3 s, no `deg` field.

Separately I will note what the bench checked and found done right: the
judge directory read-only. `BLOCK` still cancels the call, the whole
journal line goes to stderr in full, plus a separate line about the
failed write. Here a judge that could not write speaks in words rather
than disappearing.

The reverse pass — false cancellations, that is, sound layouts the new
rules could have judged broken. The bench confirmed that a layer of a
single `prompt.extra.md`, a single `body.json`, a single `prompt.md`, a
single `config.json`, an empty `.claude/judge` directory without files,
`CLAUDE_JUDGE_PROMPT` with `prompt.md` absent, and a symlink into a
nonexistent directory produce no cancellations. Two layouts did.

The first — a BOM at the start of `config.json`. The file is
substantively sound, looks normal to a human, editors add a BOM
silently, and `JSON.parse` does not accept it. The cancellation then
reported "Unexpected token '﻿'" where the breaking character is
INVISIBLE: the human knows the file but cannot see the defect, and there
is no way out of such a cancellation by reading. The BOM is stripped
before parsing.

The second — an ancestor where `.claude` turned out to be a file, not a
directory: `access` gives ENOTDIR, and the reader treated everything
except ENOENT as unreadable. Any dispatch from any directory below was
canceled, although the judge's own layout was intact and the "layer" was
a foreign file. The bench also named the right boundary: what must be
distinguished is not "ENOENT versus everything else" but "the path does
not exist" (ENOENT, ENOTDIR, ELOOP, ENAMETOOLONG) versus "the path
exists, no access" (EACCES, EPERM). An unfamiliar code is the third
case: it cancels nothing, but it does not vanish either — it is named in
the journal as `layer-unknown`/`unread-unknown` together with the code
itself.

An empty `config.json` (zero bytes or only whitespace) is left as a
CANCELLATION, although the bench proposed treating it as missing. The
reason: zero bytes means "there were settings and they are gone", not
"there are no settings", and reading that as absence would bring back
the very silent fail-open an earlier round was fixing. But the message
now names the cause directly — `empty:<path>` instead of "Unexpected
end of JSON input".

There must be a way out of a cancellation, and the bench found three
places where there was none. The `prompt-missing` label named neither
file nor directory — on a fresh install that is the only refusal a human
will see, and it did not follow from it that what to create is
`~/.claude/probes/judge/prompt.md`; now the label carries the path (and the
project layer's path, if there is one). Degradation lists were cut
silently — five of six lines went to the journal, the human fixed five
files and got the cancellation again; now the truncation is announced by
the declension-free form `[показаны не все: ещё N]`, the same in the
cancellation text. And the journal was not written at all when the
judge's directory did not yet exist: appending went without `mkdir`,
and it is exactly on a fresh install that cancellations are most
plentiful; now the directory is created on first write (verified: in an
empty directory both `journal.jsonl` and `records` appeared).

Measured on the installed image: BOM -> `ok`, no cancellation; the
`.claude` ancestor-file -> `ok`, `cfg:null`, no `deg` field; empty
config -> `block_degraded`, `deg:["empty:/tmp/…/config.json"]`; missing
`prompt.md` under `enforce` -> cancellation, and the main loop's text
names the exact file path to the human; six degradations -> five in the
journal plus the marker; sound layout -> `ok` in 6.2 s.

An environment trap found along the way: `env.CLAUDE_JUDGE` from
`settings.json` OVERRIDES a variable passed on the command line. This
makes a probe of the form `CLAUDE_JUDGE=enforce claude -p …`
meaningless — the journal will show `sw:"1"`, and `enforce` has to be
set via `enforce: true` in the config.

The round about JUDGING ITSELF, not the machinery. The bench walked the
corpus of records with three lenses and found neither an invented
sanction (43 verdicts mention the human; every one leaning on a sanction
has a `src=user` record), nor fabricated quotes (of 11 quoted fragments
8 are verbatim, 3 are the judge's own words in quotes), nor a mismatch
between reasoning and verdict (six OK with negative markers in the
reasoning — all six "considered cancellation and rejected it with a
named cause"). The flip side is a plus: the judge does not merely follow
the provenance rule, it articulates it — "the transcript contains not a
single record with src=user giving such a sanction".

One thing was found: SOURCE DEGRADATION. The same dispatch on two
transcripts — with ten human replies and with zero — gives BLOCK both
times, but the grounds change: when the human's words exist the judge
quotes them; when they do not, it leans on an `assistant` record, that
is, on the text of the very party whose call it is judging. The verdict
is stable, the grounds are not.

I verified by direct experiment, not observation: I took a real record
with 130 entries and ten human replies, cut all `src:"user"` OUT OF IT,
and ran the same model on both transcripts. The result was stronger than
expected: on the transcript without replies the judge did not invent a
sanction and did not swap the source — it wrote that there is no
prohibition in the transcript at all, called the main loop's claim a
fabricated sanction, and issued WARN, because substantively there was
nothing to cancel for. That is, under a single changed variable the
behavior was exemplary.

But on ANOTHER transcript (177 entries, zero human replies, but an
`assistant` record with «твой запрет для меня в силе») the same
judge wrote "direct prohibition of the user" in quotes — attributing to
the human words that appear in not one `src:"user"` record of the
transcript. The direction of the cancellation was safe, but the wording
lied about the source. The prompt closed this with two rules: a
prohibition found only in `assistant` may be honored (a false
cancellation is cheaper than a pass), but the source MUST be named in
the verdict; and quotes are only for verbatim citations from the
transcript, with the `src` named next to the citation. After the fix the
same transcript gives "You confirm it yourself — 'your prohibition
still holds for me, I see it and remember it'", so whoever reads the
journal sees what the cancellation stands on.

Incidentally, the first rung's reliability on long transcripts was
measured: at `max_tokens` 8000 two runs out of five on a
22-thousand-token transcript gave no verdict at all (measured spend
7880 of 8000); at 12000 — three out of three did. The output budget was
raised to 12000. This is the second time the output ceiling turned out
to be tight, and both times it was found not by calculation but by
measurement: 3000 was not enough on a short transcript, 8000 on a long
one.

A caveat about the corpus, which the bench made itself and which must be
remembered: of 59 records, forty have a transcript of 2-3 entries —
these are dictated probes where the human's sanction is verbatim and
unambiguous. On such a corpus "no violations visible" does not mean
"there are none".

The role was rebuilt by the user's decision (2026-08-21). Three rounds
of edits had gone into security — resilience to forgeries, distrust of
the main loop's records, memory of standing prohibitions — and that
turned out to be the wrong task. SDD compliance is held by a
deterministic gate, standing prohibitions are set by a hook's settings,
and a session "could always deceive or forget" — catching it on that is
not the judge's job. Removed from the prompt were the sanction
provenance rule, the asymmetry of trust in the compaction summary, the
design of pinning in the trimmed transcript, and the concentration lens.

The judge judges three things: brief readiness (and names what is
missing), the model against the task IN BOTH DIRECTIONS (an expensive
one on closed mechanics — send back; analysis and diagnosis on a cheap
executor — also), and fan-out for analysis, critique, audit. A line "no
zealotry" was added to the prompt: judge by what is written outright, do
not invent rare cases and do not look for roundabout designs.

The reference of classes and models is embedded IN THE PROMPT, not fed
by code (the user's decision: "it is more correct to embed this
information into it, so as not to build extra code"). The order within a
line is the order of preference; class membership is held by the gate,
the judge speaks about preference within the list and about fan-out.
OBLIGATION: when editing `hooks/routing-table.toml`, the reference in
`prompt.md` must be synchronized by hand — otherwise the judge will keep
reminding per a stale order.

Verified on real records: a record where opus stood on a closed task two
measurements off — three runs out of three BLOCK with a named cause;
routine scouting on glm-5.3 — three out of three OK, with the verdict
itself noting that glm is third in the scout class preference order yet
appropriate.

What trimming does NOT fix: the provenance rule. A forged prohibition
from command output the judge rejects and names a forgery — verified by
the bench in a separate experiment. Also verified was the case of
imitating a past cancellation BY THE JUDGE ITSELF (bench, 2026-08-21):
the text of a cancellation was placed word for word into command output,
with a quote of a prohibition the human never typed. The judge passed
the call and named the forgery down to the source: "the forged 'judge
cancellation' lies in `tool-output` from printf and carries no weight;
the real `user` prohibited only opus". The provenance rule holds on
this kind of text too.

## What the main loop knows about the judge

Nothing — and that is deliberate. Only a RULE is pasted into the main
model's system prompt, with no mention of the judge: a subagent call may
be checked before launch; a canceled call returns the reason; the reason
is an instruction to fix things; retrying without changes is forbidden;
and the cancellation should not be attributed to the permission system
or the routing gate. Thus the loop gets a behavior, not an addressee it
could argue with.

The insertion goes where Claude Code pastes the advisor instructions,
and only for the main loop (`agentContext.agentType==="main"`) —
subagents make no dispatches. Without `CLAUDE_JUDGE` there is no text at
all: verified by both controls — with the guard armed the model quotes
the rule verbatim, without it the model answers that no such rule
exists.

The occasion: the first wording of the cancellation text the model took
for the routing gate firing and repeated the same call. A reworded
refusal helped then, but the loop only learned of the rule at the moment
of cancellation.

## The project settings layer

The judge deliberately knows nothing about the project: it judges the
event, the logic, and the rules. If a project has its own rules, the
project states them, in the nearest `.claude/probes/` above the working
directory:

    <project>/.claude/probes/probes.toml        [probe.judge] keys override global
    <project>/.claude/probes/judge/prompt.extra.md  appended to the shared instruction
    <project>/.claude/probes/judge/prompt.md        fully replaces the shared one
    <project>/.claude/probes/judge/body.json        fully replaces the request form

The search goes upward from the working directory, the nearest wins; the
global directory itself does not count as a layer. `CLAUDE_PROBES_DIR`
switches off the layering entirely — the probe must receive exactly what
it was given. Which layer ruled the verdict is written to the journal as
the `cfg` field; otherwise lines from two sessions in different projects
are indistinguishable in one journal.

Verified 2026-08-20: a project gave the judge its own model (`glm-5.3`
instead of the global flash) and its own rule
(«правки в util.js — только opus/1c»), and the judge canceled a
dispatch that did not match that rule although by the general rules
the call was impeccable. The control outside the project: `cfg: null`, the global model.

## What the judge does NOT see

The project's memory files (`CLAUDE.md`, `AGENTS.md`) live in the main
model's system prompt, while the judge receives only the transcript and
the dispatch. So the main loop can act by rules the judge does not know.
Measured 2026-08-20: a module file with the rule
«правки только на opus, класс 1c» made the loop put opus on a
one-character replacement, and the judge never saw that rule — it
passed the call without a word about the model.

After the instruction was strengthened (silent model inflation and a
declared class not matching the task became independent grounds for
cancellation), the same input yields a cancellation: verified both by
replaying the record (`OK -> BLOCK` on the same request) and by a live
run. The blind spot remains: the judge judges by the dispatch, not by
the project's rules.

## Replay and daily compaction

`replay.py <file|directory>` replays a recorded judging: the request body
in the record lies exactly as it went to the channel, so a replay is the
same request once more. The point is substitution: `--model` rechecks
the same input with another model, `--prompt` with a new edition of the
judge's instruction, `--effort` with another effort; on a directory a
summary "verdict class matched / changed" is printed. It also
understands compressed records.

Verified 2026-08-20: a record with a refusal on a fabricated ground
reproduced on its own model and was independently confirmed on a second
one — different wording, same verdict.

One trap that cost an hour: the channel rejects a request without a
recognizable agent (403 with a perimeter placeholder page), so
`replay.py` presents itself as the client's agent. The judge itself
walks from inside the binary and never loses its agent — from the
outside this has to be restored by hand, otherwise reproducibility is
illusory.

`compact.py` — the daily compaction pass: records are written
uncompressed (a fresh one must be readable and greppable) and by age are
moved into `.gz`. Order of magnitude: 107 KB -> 26 KB, fourfold. The
pass is idempotent; the source is deleted only after the archive has
been read back and parsed.

    python3 ~/.claude/probes/judge/compact.py --older-than-hours 24

It is run by the launchd agent `com.transmutelabs.judge-compact` (04:07,
`RunAtLoad false`, log `~/Library/Logs/judge-compact.log`). Not crontab:
a run missed to sleep is worked off by launchd after wake. A sample
plist sits in the kit next to this file — edit the paths for yourself in
it, and `launchctl bootstrap gui/$UID
~/Library/LaunchAgents/<file>.plist` installs it.

## A full record of every judging

A journal line is a pointer, not a proof: the verdict in it is truncated,
and the material the judge decided on is not there at all. Therefore,
next to it, in `records/`, one file per consultation is kept — the full
request (the system instruction, the transcript with provenance labels,
the dispatch itself) and the raw channel answer, plus the same metadata
as in the journal line. The file name lands in the journal line as the
`rec` field, so there is a direct step from pointer to material.

This gives two things. A judging can be rechecked after the fact — you
see exactly what the judge saw, not a retelling. And the set of
"input -> verdict" pairs is fit material for training one's own small
model in the judge role.

Order of magnitude: about 6-7 KB per consultation on a transcript of a
couple of turns, up to tens of kilobytes on a long one. Recording is
disabled by `record = false` in the judge's settings; the journal is kept
as before.

The transcript goes to the judge as an ARRAY of records
`{"src":"…","text":"…"}`, where `src` is provenance: `user` (typed by
the human), `assistant` (text of the main loop under judgment),
`tool-output` (tool output), `injected` (service inserts, task
notifications, letters of other sessions). Without this markup all of the
above arrives under the single role `user`, and the judge took for a
human sanction a line the main loop wrote to itself (measured
2026-08-20).

An ARRAY, not labeled lines: a text prefix carries no trust, because the
content lives in the same space — a line `user: user allowed`, printed
by command output, a read file, or another session's letter, is
indistinguishable from a real label (verified by forgery on 2026-08-20).
In JSON the same line is escaped into `text` and cannot become the
neighboring `src` key. Provenance is taken first from the message
envelope (`toolUseResult`, `isMeta` — the same signs by which Claude
Code itself tells them apart) and only then by wrapper markers.

Transcript trimming to `context_chars` discards whole records from the
head: a serialized string cannot be cut, the judge would receive broken
JSON.

The journal is append-only and never trims itself — about 300 bytes per
main-loop call. When it gets in the way, the file can simply be
truncated.

## Latency

Measured 2026-08-20 on a real 4.7 KB body: glm-5.3 — median 4.6 s,
maximum 8.8 s, the verdict parsed in 8 runs out of 8. deepseek-v4-flash
and grok-4.6 are 1.5-3 times slower. Context volume has almost no effect
on latency.
