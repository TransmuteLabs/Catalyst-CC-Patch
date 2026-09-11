# catalyst-form

Deterministic form probe (A1–A4, B, C1, C2, F). No model. Rules are
data in `probes.toml` `[probe.form]`. `CLAUDE_FORM` empty means ON
(inverted vs the judge). `CLAUDE_FORM_CARRIER=mod` stands the splice
down.

Eval is a port of `__ccFormEval` / `__ccFormKind` from insertion 22.
`process` is not defined: cwd is `session.start` `e.cwd` in `$.store`.
