# Notes — the judge's model ladder

## Why glm-5.3 leads and deepseek-v4-flash does not (measured 2026-08-23)

The ladder used to open with `deepseek-v4-flash` under a 25 s cap, on the
theory that the cheap model takes the quick first look and the expensive one
only cleans up after it. Three days of journal refute the theory.

From 228 stored records, 430 attempts:

| rung | attempts | succeeded | median ms (successful) | ctx_chars | cap |
|---|---|---|---|---|---|
| deepseek-v4-flash | 228 | 50 (21%) | 22507 | 58263 | 25000 |
| glm-5.3 | 188 | 175 (93%) | 6408 | 23255 | 60000 |
| claude-haiku-4-5 | 14 | 14 (100%) | 5480 | 11870 | 60000 |

All 178 flash failures read `Error: Request was aborted.` at ms 25002 against
`timeout_ms 25000` — every one of them was OUR OWN cap, not the provider.
Successful flash attempts pile up against the same wall: median 22507, p90
25002, max 25003. The rung was not flaky; it was strangled.

The first rung also carried the LARGEST transcript (58 k against glm's 23 k),
because it declared no `context_chars` and silently inherited the global
60000 while every later rung declared a smaller one. An omitted key reads as
"modest default" and means "the maximum" — the ladder was inverted in the one
direction the config makes invisible.

## The input was not the driver — the output budget was

Probed directly against the proxy at `reasoning_effort: high`:

| probe | elapsed | output tokens |
|---|---|---|
| 24 k ctx, max_tokens 1200 | 12.0 s | 1200 (truncated) |
| 58 k ctx, max_tokens 1200 | 17.1 s | 1200 (truncated) |
| 24 k ctx, max_tokens 12000 | 49.2 s | 5204 |
| 24 k ctx, max_tokens 2500 | 30.1 s | 2501 (truncated) |

Effort is not a lever here and is not even monotonic: at max_tokens 12000 the
same payload took 84 s at `low` (7088 tokens) and 118 s at `medium` (10096).
The model writes at roughly 60-85 tokens/s and keeps writing until it hits the
budget. No cap below ~90 s can hold it at the judge's 12000-token budget, and
shrinking the budget only guarantees truncation.

So the ordering is not a cost question, and the first reading of it was
incomplete. flash is genuinely the FASTER model per token — ~106 tokens/s
against glm's ~41 (5204 tokens in 49 s against 181 in 4.4 s). It loses on
wall-clock only because it emits 29x more of them.

There is no small-budget escape. Probed at 300, 600 and 1200 output tokens,
flash returns a `thinking` block and no verdict at all — it is still working
through the criteria when the budget ends. It needs its ~5000 tokens, so ~50 s
is its floor on this task, and the "verdict on the first line" rule it does
not obey.

## Why flash leads anyway (user ruling 2026-08-23)

Latency was the wrong optimisation target. glm-5.3 is nominally unlimited but
carries a 5-hour ceiling and degrades under load — and it is the same model the
fleet executes with, so a judge that leads with glm competes for quota with the
work it judges. That is the failure this house already records: the judge
shares a channel with the fleet it judges, and under load the judge is what
drops out first.

Ruling, verbatim: «пусть растет консультация потому что это важно. лучше
потерять минуту чем пару дней». A consultation may cost a minute; a dispatch
sent wrong, or a fleet standing idle, costs days.

So both ladders lead with flash under a 240 s cap that lets it finish, glm
second as the fallback, haiku third in the judge. Every rung declares its own
`context_chars` explicitly: an omitted key inherits the global maximum, which
is how the leading rung silently ended up carrying the LARGEST transcript
under the TIGHTEST clock.

The cap is global and the ladder is sequential plus a short-tail retry, so a
consultation where every rung times out can stand for 16 minutes in the path
of what it judges. That is the accepted price of the ruling above.

That ruling governs the CLOCK and nothing else. It was briefly mis-carried into
`judge/prompt.md` as a cost model — a section telling the judge that a wrong
dispatch burns budget and can stop the work — and the user struck it out on
sight (2026-08-23): «судья должен судить о задаче, а не о том как экономить
бюджет… это решение мое и главного оркестратора». The judge reasons about the
task: what is being done, whether the brief suffices, whether the model fits
the work. Spend, quota and exhaustion are decided by the human and the main
loop, and reach the judge already decided — as the allowed-model list in the
gate's settings. A latency tolerance is not a licence to make the judge an
economiser.

## The same ladder lives in two places

`judge/config.json` and `idle-watch/config.json` are separate files over one
shared core. The first fix landed in the judge alone and left the watcher
running the old strangled ladder for a full slice — 6 of 7 consultations
burning 25 s on a rung that never answered. Any change to one is a change to
both until the day they are meant to differ, and today they differ only in
`max_tokens`, `dispatch_chars`, `fail_closed` and the watcher's own gate keys.

## The dispatch was the one truncation nobody announced (2026-08-23)

The house rule is old and written into the core itself: *every* truncation is
declared, with the same convention as the transcript's, because a cut mid-word
reads as a finished text. Journal fields declare it, records declare it, a
clipped verdict declares it. The dispatch did not:

    let __disp = String(...).slice(0, Number(__cfg.dispatch_chars || 4000));

A bare slice, on the single object the judge exists to judge. Measured over the
last 120 records: 29% of dispatches hit the 4000 ceiling (median 2815, max
8982). Two verdicts named the cut explicitly, one of them a BLOCK that
cancelled a valid dispatch and sent the main loop off to repair a brief that
was already complete — the failure mode is worse than it looks, because a brief
whose report-format section fell past the ceiling reads as a brief with no
report format, and that BLOCK looks perfectly reasonable in the journal.

Fixed in three places, because any one alone leaves the judge unable to do its
job: the core announces the cut (`[диспатч подрезан: показано N из M знаков]`),
the prompt states that the marker is OURS and is not a ground for return, and
the budget rose 4000 -> 16000 so a normal brief arrives whole.

The check `judge declares every truncation` was green for the entire life of
the defect. It enumerated the forbidden sites BY NAME — `__v.slice(0,400)`,
`.resp=__t.slice(0,800)` — so it forbade exactly what someone had already
thought of. A blocklist cannot catch the site nobody listed. It now pins the
dispatch positively (the announced conditional must be present) and negatively
(the bare form must be absent), and it was mutation-tested both ways: it fails
on the pre-fix image and passes on the fixed one.
