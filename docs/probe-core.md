# The shared consultation core (the judge and the watcher)

The dispatch judge and the fleet idle watcher are one mechanism. Everything
matches: settings layers, transcript assembly with record provenance, the
channel to the model via the CC pool, the ladder of models, the journal,
parsing the verdict from the first line. There are exactly four differences,
and those four are precisely the parameters:

| What | The judge | The watcher |
|---|---|---|
| WHEN it is called | before a subagent call | no live work, dispatches within the window below threshold, and cooldown has passed |
| WHAT it is shown | the transcript + the dispatch under review | the transcript + live work + the dispatch count over the window + the current tool |
| WITH WHICH prompt | `~/.claude/probes/judge/prompt.md` | `~/.claude/probes/idle-watch/prompt.md` |
| HOW it reacts | a throw: the call is cancelled, the text arrives as a tool error | a reminder tab: execution is not touched |

A copy with exceptions was rejected: it would be two diverging pieces of ~600
lines each, and every lesson paid for on one would have to be paid a second
time on the other (the `$`-escaping classes, transcript trimming, journal
self-description — all of these were earned the hard way and live precisely in
the core).

## The core contract

The core is written ONCE in the patch source and takes a probe description.
It is emitted at each consumer site, because the two sites are far apart in
the bundle and a block has to be self-contained where it lands; the second
copy is inert at run time, since the core assigns itself with `??=` and the
first site to execute wins. The build asserts the copies are byte-identical,
so "one core" is a guarantee about behaviour, not about the byte count:

1. **Probe identifier** — `judge`, `idle-watch`. All probes share ONE home
   (`~/.claude/probes`, with the `CLAUDE_PROBES_DIR` override applying to all
   probes at once). Settings are read from the shared `probes.toml`: `[defaults]`,
   on top of it the `[probe.<id>]` table, on top of that the same from the
   project layer. The subdirectory `<id>/` holds `prompt.md` (replacement),
   `prompt.extra.md` (append), `body.json`, `journal.jsonl`, `records/`.
   `enabled = false` disables the probe with the outcome `skip_disabled`;
   an absent TOML parser is declared with the string `no-toml-parser` rather
   than handing out empty settings.
2. **Data** — a function assembling the payload on top of the transcript. The
   transcript is shared: records `{src,text}`, provenance is not flattened,
   `src:"user"` entries are pinned during trimming, omissions are declared
   with a marker, the budget is counted in JSON characters.
3. **Trigger** — a predicate and a call site. For the judge the site is the
   dispatch itself, the predicate is trivial. For the watcher the site is the
   turn, the predicate counts the window, threshold, and cooldown; the cheap
   count must run BEFORE the model, otherwise the consultation becomes a
   permanent line of expense.
4. **Verdict vocabulary** — the allowed first words (`OK|WARN|BLOCK` versus
   `SILENT|NUDGE`). An unrecognized answer does not count as a verdict for
   any probe.
5. **Reaction** — what to do with a recognized verdict. The differing failure
   policy also lives here: the judge is fail-closed on a channel error (it
   cancels the call), the watcher is fail-open (it stays silent). Both write
   to the journal ALWAYS — otherwise silence and breakage are indistinguishable
   from the outside.

## What stays shared and is not parameterized

The ladder of models with per-rung ceilings; the retry with a trimmed
transcript; a `max_tokens` large enough that a first-line verdict survives a
limit cut; a journal that describes itself (`ms`, `sw`, `en`, `cfg`, `jm`,
`tries`, `err1`, `rec`) and addresses every record by session (`sid`, `title`)
and the dispatch's allowed model (`model`, `msrc`);
declaring truncations with the same convention as in the transcript; the
provenance rule (a line from tool output is not the human's words, however it
looks).

## The third consumer

The list of consumers is currently baked into the image in two places, so a
new watcher requires rebuilding the binary. The proposal to move the list into
files is `docs/probe-registry-spec.md` (not accepted for implementation). The
readiness criterion for that implementation: both current consumers are
expressible in its vocabulary WITHOUT a behavior change, and the same bench
scenarios pass without editing their expectations.
