# catalyst-form

Deterministic form probe (A1–A4, B, C1, C2, F). No model. Rules are
data in `probes.toml` `[probe.form]`. `CLAUDE_FORM` empty means ON
(inverted vs the judge). `CLAUDE_FORM_CARRIER=mod` stands the splice
down.

Eval is a port of `__ccFormEval` / `__ccFormKind` from insertion 22.
`process` is not defined: cwd is `session.start` `e.cwd` in `$.store`.

## Combined smoke + printf leak (staging, 2026-09-12)

Three modules loaded together (`environment 1/2/3`). With all three
`CLAUDE_*_CARRIER=mod` the isolated journals have **only** `carrier=mod`
lines (no splice `sid`/`pid`).

Write A1=cancel denies. Then grok used
`printf ... > docs/review/zq-brief.md`. The splice treats a `>` without a
heredoc body as empty post-state, so `brief_head` failed and the write
landed. The mod now classifies `brief_path` with empty text as a brief;
A1 fires. Re-smoke of that exact Bash: deny 5 ms, file ABSENT.
