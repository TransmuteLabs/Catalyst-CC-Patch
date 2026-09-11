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
