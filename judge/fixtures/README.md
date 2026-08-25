# Fixtures for live checks of the judge

Two ready-made project settings. Both checks require a LIVE run: the judge
works inside the client's process, and its invocation cannot be faked from
the outside.

Run from the fixture DIRECTORY (the project layer is searched upward from
the working directory), with the judge enabled:

    cd judge/fixtures/ladder
    CLAUDE_JUDGE=1 claude -p "Запусти ровно одного субагента: тип glm-scout, \
      модель glm-5.3, промпт: «[dispatch-class:scout] Выполни echo 11 и верни \
      вывод.» Ничего больше не делай." --model glm-5.3

## ladder — the ladder and the project layer

The first rung is a deliberately nonexistent model. Expected in the journal:
`tries: 2`, the second rung answered, `err1` holds the first rung's refusal,
`cfg` points at the fixture directory.

Measured 2026-08-20 (the `pool` channel): the first rung dropped out in
34 ms (`api error from the pool`), the second answered in 7.7 s.

## enforce — a cancellation that reached the model

`enforce: true` plus a project rule that forbids scout subagents. Expected:
in the journal `outcome: block`, `en: config`; in the session itself — the
tool call refused with the reason, no retry of the same call, and the work
done without a subagent.

Measured 2026-08-20: the verdict in 4.4 s, the session did the work with the
Bash tool and named the reason for the cancellation outright.

Neither fixture enables the judge on its own: `CLAUDE_JUDGE` is set in the
command.
