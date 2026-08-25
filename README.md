# Claude Code Patch Kit

A pipeline that patches the locally installed Claude Code image and
installs three mechanisms in it: multi-provider model routing, the
**dispatch judge** (it inspects every subagent call before it runs — is the
brief ready, is the model proportionate, is a fan-out warranted), and the
**fleet idle watcher** (it catches the case of "the main loop is working
while the subagents sit idle" — a case that no dispatch statistics can see
by design). Both mechanisms share one core and are configured by a single
`probes.toml` file.

The patch lives in the image itself, not in a hook: a hook does not see
everything and can be worked around, an injection cannot. Nothing is
installed if any one of the 78 checks fails, and the switch to a new build
happens only after the smoke gate.

> **Boundary.** This repository contains ONLY our own files. The Claude Code
> image is Anthropic's proprietary software and is not distributed here:
> the pipeline reads the one already installed on your machine. Whether
> modifying it is permitted is determined by your agreement with Anthropic,
> not by this license. Use at your own risk: a broken image is fixed by
> reinstalling, but the time is lost.

Verified on **2.1.239** (macOS arm64). This is a mac tool: that is where it
lives and where it is tested. By construction `claude_patch.py` also
handles linux and windows (the patched JS bundle is IDENTICAL on all
platforms; only the container differs — unpacking, repacking, signing), but
those paths have not been run and are not considered verified.

The patches locate their anchors with structural regular expressions, so
they usually survive version upgrades; on a miss the pipeline fails loudly
and installs NOTHING. On 2.1.239 there were two misses (an adapter around
the tool invocation and a `$jS` name pasted into a template without
escaping) — both are fixed, see `docs/judge-architecture.md` §14.

## Requirements

- `node` (tweakcc runs on it), `python3`, network access for `npx tweakcc`
- macOS: a signing identity. The script takes the first available identity
  (`security find-identity -v -p codesigning`); override it with the
  `CLAUDE_PATCH_SIGN_ID` variable. Without a valid signature the keychain
  returns "Not logged in".

## How to use

```bash
bash claude-patch-all.sh                  # patch the current installation
bash claude-patch-all.sh --update         # install a fresh Claude Code and patch it
bash claude-patch-all.sh --update 2.1.238 # a specific version
bash claude-patch-all.sh --only-ours      # without tweakcc's own patches
```

**If you are patching the binary that is running your session RIGHT NOW**,
build to the side and swap by rename, or you can kill the live process:

```bash
V=~/.local/share/claude/versions/2.1.238
cp -p "$V.orig" "$V.staging"
bash claude-patch-all.sh --target "$V.staging"
mv "$V.staging" "$V"      # atomic; takes effect on the next launch
```

The order must not be violated: `tweakcc --apply` restores the binary from
its own backup copy, so our patches always run AFTER it, and any tweakcc
invocation (including its TUI) requires re-running this script.

## Contents

| file | role |
|---|---|
| `claude-patch-all.sh` | the pipeline: tweakcc → our patches → signing → checks → launcher switch → model costs |
| `tweakcc-patch.js` | the patches themselves (78 checks), a script for `tweakcc adhoc-patch` |
| `claude_patch.py` | cross-platform install/download/launcher switch |
| `set-model-costs.py` | syncs `customModelCosts` and `customModelContextWindows` into `~/.claude.json` |
| `patch-claude-routing.sh/.ps1` | thin wrappers around `claude_patch.py` (must sit next to it) |
| `patch_claude_routing.py` | a standalone byte-neutral patcher (an alternative without tweakcc) |
| `judge/` | the judge's tools (annotation, replay, compaction); its prompt and records live in `~/.claude/probes/judge/` |
| `judge/channel.py` | the single dispatch home: the `pool` channel (through the client itself) and `http` |
| `judge/replay.py` | replays a recorded adjudication (model, instructions, effort overrides) |
| `judge/validate.py` | runs the corpus through several models, with metrics and a recommendation |
| `judge/adjudicate.py` | annotation: a strong model evaluates a delivered verdict |
| `judge/fixtures/` | fixtures for the live checks: the ladder and cancellation |
| `judge/compact.py` | daily compaction of records; installed as a launchd agent |
| `judge/com.transmutelabs.judge-compact.plist` | a sample launchd agent for daily compaction (adjust the paths) |
| `idle-watch/` | the fleet idle watcher's files → put into `~/.claude/probes/idle-watch/` |
| `idle-watch/README.md` | the watcher's operator manual: enabling, thresholds, the journal |
| `docs/idle-watch.md` | the watcher's full design: two filters, the channel, the refusal policy |
| `docs/probe-core.md` | the contract of the probes' shared core: what is a parameter and what is shared |
| `tools/probe-bench.js` | the bench: scenarios run on code cut out of the built image (run under `bun` — the image is built with it) |
| `tools/probes-migrate.py` | a one-time consolidation of the two old `config.json` files into a single `probes.toml`, with a self-check |
| `docs/probe-registry-spec.md` | the probe registry spec: one settings file, a dictionary of conditions, reactions |
| `tools/emit-check.js` | parses the pasted code BEFORE the image is built |
| `docs/judge-architecture.md` | the judge's full design: injections, flow, layers, invariants |
| `docs/judge-patch-spec.md` | the campaign journal: anchors, rejected options, measurements |
| `tools/listener.py` | an HTTP receiver for routing probes |

## What the patches do (78 checks)

Routing and models: `claude-*` go to the subscription, everything else to
the proxy; arbitrary models on agents; gateway model discovery without a
token; per-model costs and context windows; the proxy lane survives an
expired login; a dispatch preserves the model and effort; session resume
does not lose the proxy model.

Interface and resilience: the model badge on a subagent, type and model in
the agent list, the chevron color, session search reads to the tail, a
broken stream is retried instead of yielding a half-answer, an interactive
coordinator mode.

Ported from tweakcc (its own set does not apply on 2.1.238 — the bundle it
builds fails to parse): status-line throttling 300→500 ms; lifting BOTH
refusals at euid 0 (tweakcc lifts only the first); reading `AGENTS.md` and
other names instead of `CLAUDE.md`.

The dispatch judge: a map of the current turn; a consultation before the
dispatch by the CLIENT'S OWN MODEL POOL (claude-* — the subscription lane,
the rest — the proxy; a separate HTTP path only by an explicit address); a
journal record of every consultation; the ladder of attempts with its own
threshold, budget, effort, and transcript size at each rung; the transcript
goes as an array of records with provenance, not as annotated strings;
trimming the transcript evicts anything BEFORE the human turns, but pinned
entries are capped by a share of the transcript; a local command's output
does not carry the human label, while slash-command arguments do; the
compaction summary is pinned by a separate share as the sole carrier of the
standing directives after the transcript is compacted; an answer without a
verdict on a 2xx counts as a failed rung; a failed rung keeps ITS OWN
reason and its own answer (otherwise the next one overwrote the diagnosis);
`fail_closed` mode — the call is cancelled when no rung produced a verdict,
and such a cancellation is named in the journal by its own outcome; a full
record of every consultation next to the journal; a project settings layer.

The fleet idle watcher: a second consumer of the SAME core as the judge —
the settings layers, transcript assembly, the channel to the model, the
ladder, the journal, and verdict parsing all coincide; there are exactly
four differences, and they are precisely the parameters (when it is called,
what it is shown, with which prompt, how it reacts). It is invoked on a
tool call rather than on a dispatch, and it responds not with cancellation
but with a reminder note inserted into the turn — it is NOT a gate. Half of
its job is to stay silent: the prompt starts by searching for a reason why
there should be no fan-out right now (the human forbade it, told it to
finish first, the work is indivisible, the loop is writing a brief), and
only an entry with `src":"user"` counts as a prohibition. Two filters: one
by memory before any I/O at all (every refusal names the moment before
which it cannot change) and one by settings — window, threshold, cooldown.

System prompt: a RULE is injected into the main loop — a cancelled dispatch
carries a reason, the reason is an instruction to fix, an unchanged retry
is forbidden. Without `CLAUDE_JUDGE` there is no injection; subagents do
not get it.

## Settings the patch does NOT make (and should not)

In `~/.claude/settings.json`, the `env` section:

```json
"CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS": "1000000"
```

This is a stock Claude Code variable — it overrides the 25,000-token
default for file reads, and no bytes need patching for that. The separate
SIZE limit (262,144 bytes) is not controlled by the variable and remains.

The judge is off by default. To enable it, add to the same place:

```json
"CLAUDE_JUDGE": "1"        // observation and journaling only
"CLAUDE_JUDGE": "enforce"  // cancel failing calls
```

A project states its own rules by itself, in the nearest `.claude/probes/`
above the working directory: keys go in `probes.toml` under the
`[probe.judge]` table, text in `judge/prompt.extra.md`. The judge still
knows nothing about the project — it judges the event, the logic, and the
rules.

Adjudication records accumulate uncompressed and are archived by a daily
pass. A launchd agent (sample: `com.transmutelabs.judge-compact`, 04:07) is
more reliable than crontab: a run missed due to sleep is worked off by
launchd after wake-up.

The fleet idle watcher is also off by default and is enabled by its own
variable:

```json
"CLAUDE_IDLE": "1"
```

The thresholds live in `~/.claude/probes/probes.toml` under the
`[probe.idle-watch]` table: `window_min` (the counting window),
`threshold` (how many dispatches within the window count as sufficient),
and `cooldown_min` (how often a reminder is possible at all). The project
layer is `.claude/probes/`, with the same merge rules as the judge's.

For details see `judge/README.md` and `idle-watch/README.md`.

## Rakes we stepped on

- **A pattern match ≠ a working image.** One unescaped newline inside an
  inserted literal kept every check green while the binary died on a
  `SyntaxError`. That is why the pipeline has a hard smoke run: the image
  is launched and must print the version line, or the launcher does not
  switch. That run is what catches such cases.
- **`$(cmd | head -1)` in a check throws away the exit code** — a broken
  image reports success. Capture the status separately.
- **tweakcc packs the bundle as BYTES**: non-ASCII in an inserted literal
  arrives double-encoded. Emit `\uXXXX`.
- **A check of the form `var X=500` is GREEN on a clean image** — there
  are six such constants in there. Run any new check against a CLEAN
  image: it must fail.
- **Switch the launcher only AFTER the checks.** Between "clean install"
  and "patched" there is a window: a session started inside it will go to
  the proxy with a subscription token and die.

## License

MIT — see `LICENSE`. The license covers this repository's files: the
pipeline, its checks, the probe tools, the bench, and the documentation.
It does not extend to the Claude Code image.
