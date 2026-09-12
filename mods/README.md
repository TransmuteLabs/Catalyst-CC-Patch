# mods/ — not the live plugin

The live consultation engine is the Claude plugin
`catalyst-probes@catalyst` in `TransmuteLabs/Catalyst`
(`plugins/catalyst-probes/`). The module is the core; consultants are
`[probe.<id>]` tables in `~/.claude/probes/probes.toml`.

This directory previously shipped three frozen plugins (judge / form /
idle) as a directory marketplace (`catalyst-mods`) whose
`installLocation` was this worktree. That bound the live hooks to a
dirty patch checkout. Do not register this path.

Install:

```
claude plugin marketplace add TransmuteLabs/Catalyst
claude plugin install catalyst-probes@catalyst
```

`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` and `CLAUDE_*_CARRIER=mod` stay in
`~/.claude/settings.json`. The binary splices (proxy) stay in this kit.

Session-only fallback: `scripts/claude-mods.sh`.
