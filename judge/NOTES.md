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

So the ordering is not a cost question. glm-5.3 answers the same consultation
in 6.4 s at 93%, flash in 22.5 s at 21%. flash stays as the second rung with
the global 60 s cap, where it is reached only after glm has already failed.

## The defect that let this hide for three days

Our own abort and an upstream abort arrived in the journal as the same
sentence. Diagnosing it needed comparing each attempt's `ms` against its own
`timeout_ms` by hand. The core now marks its own cap explicitly: the attempt
carries `timed_out: true` and the error text is prefixed
`our cap <N>ms fired -> `. A self-inflicted timeout must never again read like
a flaky provider — the two have different remedies.
