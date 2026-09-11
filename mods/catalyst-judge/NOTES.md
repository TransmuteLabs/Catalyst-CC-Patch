# catalyst-judge — function-hooks carrier

The dispatch judge and the system-prompt cancellation rule, as a Claude
Mod. Companion spec: `docs/judge-mod-port-spec.md`.

## Arming

Both of these, together:

```
export CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1
export CLAUDE_JUDGE=enforce          # same switch as the splice
export CLAUDE_JUDGE_CARRIER=mod      # splice stands down; this module arms
```

and load the plugin:

```
claude --plugin-dir /path/to/Catalyst-CC-Patch/mods/catalyst-judge ...
```

Without `CLAUDE_JUDGE_CARRIER=mod` the plugin is inert (pass-through) and
the splice keeps judging. Without `CLAUDE_JUDGE` both carriers are off.

Acceptance of a load is the debug line
`hooks module catalyst-judge loaded (worker, environment 1, tier user)`
plus `$ built for catalyst-judge`. A green `plugin validate` is not
acceptance.

## What it does

- `prompt.section` on `communication:L`: injects the retry/correction rule
  (replaces injection 26 when the carrier is `mod`).
- `tool.call` on `Agent`/`Task` from the main loop (`!("agentId" in e)`):
  stage-0 filter from `probes.toml`, then inverted fail-closed — PENDING
  deny in 1–2 ms, `$.model.complete` in the background, retry sees the
  verdict. Hook body never awaits the consultation (host budget 10 s,
  fail-open).

## What it does not do

- It does not raise the 10 s host budget (unpatchable; bytecode).
- It does not move the proxy splices.
- It does not cut injection 22 from the image; `CLAUDE_JUDGE_CARRIER=mod`
  makes that splice a no-op. Cut the splice after this carrier has a live
  journal indistinguishable from today's.

## Journal

One file per consultation:
`~/.claude/probes/judge/records/mod-<tool_use_id>.json`.
The splice's index line is not written; compaction of the splice journal
does not see these files yet.

## Pass-path vs the 10 s budget

`return next(e)` can take longer than 10 s (Bash sleep 15 settled in 16034 ms).
That time is **not** charged: no `exceeded 10000ms`, the tool finished, the
hook ran its after-`next` write. The 10 s wall is awaited work of ours
before we return (the fail-open probe slept 11 s *instead of* calling
`next`). Passing a long Agent is therefore not a budget defect.

## The 897 overlays

They are tweakcc's prompt-snapshot layer in `~/.tweakcc/system-prompts/`,
not this module. Our only binary prompt feature was injection 26; it lives
here as `prompt.section` on `communication:L`. This module does not write
the user's overlay directory.

## Stand-down measured (staging image, 2026-09-12)

Patched a *copy* of 2.1.267.orig (`/tmp/t113-full/267.staging`). Live inode
untouched. On that image:

| `CLAUDE_JUDGE_CARRIER` | mod PENDING | splice journal |
|---|---|---|
| `mod` | yes (then OK, agent PONG) | **delta 0** |
| unset | 0 (inert) | **+1** grok-scout ok |

The live install still lacks the variable until it is rebuilt.

## Project layer measured (staging image, 2026-09-12)

`$.fs.ancestors` rejects anything that is not a relative `.md` name
(host check). `process` is not defined in the module. `PWD` is not a
cwd: `env -i` strips it and the walk from HOME-only missed a project
file two levels up.

Relative `$.fs.read(".claude/probes/probes.toml")` / `"../".repeat(i)` is
resolved against the host cwd. ENOENT errors contain the absolute path
(`/private/tmp/...`), which is how the walk skips the global home.

On `/tmp/t113-full/267.staging` with isolated `CLAUDE_CONFIG_DIR`,
`CLAUDE_JUDGE_CARRIER=mod`, cwd=`.../tree/sub/deep`, project toml at
`.../tree/.claude/probes/probes.toml` with `classes_skip = ["scout-enum"]`,
no `PWD`:

* filter log: `filtered classes_skip cls=scout-enum project=/private/tmp/.../tree/.claude/probes`
* records `kind=SKIP`, journal `outcome=skip` `carrier=mod`
* 0 `Adjudication is in progress`; agent returned `ZQ-LAYER-PONG`
* the same tree on the previous walk (empty PWD, absolute from PWD)
  judged: 15 PENDING, `projectHome=""`, outcome ok

`CLAUDE_PROBES_DIR` still disables the walk (splice `__o.dirEnv`).

## Journal index

Detached read-modify-write of `journal.jsonl` (overwrite, no append verb).
`judge/compact.py fold_mod_records` inserts any `mod-*.json` whose `rec`
is missing. Isolated wipe → fold restored 2 skip lines; second pass added 0.
Launchd `com.maratkarimov.judge-compact` runs `~/.claude/judge/compact.py`.
