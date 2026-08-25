# Brief: `~/.claude/judge/validate.py` — the judging-corpus validator

> **Status: CHRONICLE.** This is the wave assignment in the exact form it was
> given to the executor; paths and file names are spelled as they were called
> back then (`~/.claude/judge/`, `config.json`). The current layout is a single
> `~/.claude/probes/probes.toml` with the probe directory next to it; see
> `judge-architecture.md` and `probe-registry-spec.md`. The brief is not
> rewritten: it documents what was ordered, not what came to be.

Goal. There is a corpus of recorded judgements (`~/.claude/judge/records/
*.json[.gz]`) and a single-record replay tool (`replay.py`). There is no
separate tool that (1) checks verdicts against a LABELLED truth, (2) runs
SEVERAL models over the same corpus and shows which minimal one is good
enough, (3) accounts for the project settings layers the judging happened
under. We write exactly that tool. The design below is accepted; no decisions
are yours to make.

## Files

- YOU WRITE only: `~/.claude/judge/validate.py` (a new file, executable).
- YOU READ: `~/.claude/judge/replay.py`, `~/.claude/judge/config.json`,
  `~/.claude/judge/prompt.md`, records in `~/.claude/judge/records/`.
- YOU DO NOT TOUCH `replay.py`, `compact.py`, configs, the image, git (no
  commits — changes stay in the working tree).
- Code comments are constraints only («почему не иначе», boundaries), not a
  retelling of the code and not an edit history.

## What already exists and is reused (do NOT duplicate)

`replay.py` is imported as a module (its `main()` is guarded by
`if __name__`, the import is safe):

    import sys, os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import replay   # load, verdict_of, post, klass, UA

Verdict-parsing rules must have ONE home: the verdict class and the answer
parsing come from `replay.verdict_of` / `replay.klass`; no own copies.

## Record format (measured on live records)

Top-level keys: `t, tool, agent, model, ms, sw, http, outcome, en,
tries, jm, cfg, err1, verdict, url, pid, cwd, attempts, request, response`.
`request` is the FULL request body (`model, max_tokens, temperature, messages,
reasoning_effort`), `messages` = `[{role:"system"},{role:"user"}]`.
`cfg` is the path of the applied PROJECT `.claude/judge` directory, or `null`.
`cwd` is the session's working directory at the moment of the call.

## CLI

    validate.py run     [--records DIR] [--models "m:effort,m:effort"] [--repeat N]
                        [--limit N] [--jobs K] [--timeout S] [--prompt FILE]
                        [--project-layer record|recompose|off] [--url U] [--out FILE]
    validate.py label   <record file|name> --truth OK|WARN|BLOCK [--note "…"]
    validate.py list    [--records DIR] [--unlabelled]
    validate.py report  <run file>...

Defaults: `--records ~/.claude/judge/records`, `--models` from
`~/.claude/judge/config.json` (field `models`: elements `{"model","effort"}`
or a string), `--repeat 1`, `--jobs 4`, `--timeout 180`,
`--project-layer record`.

## Truth labelling

The file `~/.claude/judge/labels.jsonl`, one line per label:

    {"rec":"<record file name>","truth":"BLOCK","note":"…","t":"<ISO>"}

It is append-only; when several lines exist for one record, the LAST one
applies. `label` appends a line, `list` prints records with their recorded
verdict and label (or «нет метки»), `--unlabelled` — only unlabelled ones.
Do NOT invent labels: a human sets them. The tool must also work on a fully
unlabelled corpus.

## Project layers (`--project-layer`)

- `record` (default): the system message and parameters are taken from the
  record as they are — that is how the judging happened.
- `recompose`: the system message is assembled anew, by the SAME rules as in
  the judge itself:
  1. base = `--prompt FILE`, otherwise `~/.claude/judge/prompt.md`;
  2. if the record's `cfg` is not null and contains `prompt.md` — it REPLACES
     the base;
  3. if `cfg` contains `prompt.extra.md` and it is non-empty — it is appended
     to the result with the line `"\n\n=== ПРАВИЛА ЭТОГО ПРОЕКТА ===\n"` +
     the text.
  Also, on `recompose`, `max_tokens` and `context_chars` are taken from
  `<cfg>/config.json` if named there (they override the global ones); the
  model and the effort always come from the `--models` run string, not from
  the config.
  If `cfg` points to a nonexistent directory — the result line is marked
  `layer_missing: true` and the run over it still happens (on the base
  prompt).
- `off`: the system message = `--prompt FILE` (mandatory with `off`), the
  project layers are ignored entirely.

## The run

For each pair (model × record) × `--repeat`:
the body = a copy of the record's `request`, with `model`, `reasoning_effort`
(from the `--models` string), the system message (per `--project-layer`) and
`max_tokens` (if it came from the project config) replaced. Address: `--url`,
otherwise the record's `url`. Sending is `replay.post` (its User-Agent is
mandatory: the channel answers a request without a recognised agent with a
403 stub).

The result line (into `--out`, JSONL, default
`~/.claude/judge/bench/<ISO>-run.jsonl`):

    {"rec","model","effort","rep","klass","verdict","ms","http","error",
     "truth","layer","cfg","tokens_in","tokens_out","layer_missing"}

`tokens_*` are from the response's `usage` if present, otherwise null. A
request error is a line with `error` and `klass:"ERROR"`; such lines are
NEVER dropped silently.

## Summary (printed after `run` and by the `report` command)

A table, one row per model:

    модель  прогонов  ошибок  EMPTY  медиана_мс  p90_мс  ток_вх/вых
            пропусков  ложных_отмен  совпало_с_меткой  нестабильных

- «пропусков» = label `BLOCK`, received `OK|WARN|EMPTY|ERROR`. This is the
  WORST class: a judge that let through what it should have cancelled is
  indistinguishable from one that is off.
- «ложных отмен» = label `OK`, received `BLOCK`.
- «совпало_с_меткой» — labelled records only; the number of labelled records
  is printed separately, so that accuracy over three labels does not look
  like accuracy over a hundred.
- «нестабильных» (only with `--repeat>1`) = records where repeats of one
  model gave a DIFFERENT class.
- If there are no labels at all — agreement with the recorded verdict is
  printed instead of accuracy, with an explicit note that the recorded
  verdict is not the truth.

After the table — a recommendation line with the NAMED criterion, for
example: `минимальная годная: <model> (пропусков 0, нестабильных 0,
медиана 4.6 с); отвергнуты: <model> — 2 пропуска, <model> — нестабильна`. If none pass —
say exactly that; do not invent a candidate.

## Cost (if the data exists)

If `~/.claude.json` has `customModelCosts` with a key for the model — compute
and print the price of 100 consultations at the average tokens. No key — the
`—` column. Do not bend the arithmetic and do not write "approximately":
no data — a dash.

## Guardrails

- Zero network access anywhere except the address from the record/`--url`.
- No commits, no edits outside `validate.py`.
- Stop rule: an unexpected mismatch with the brief → one honest attempt →
  report BLOCKED with raw output, no deep diagnosis.
- Right to refuse: if part of the brief is already done or the premise is
  false — show proof (grep/diff/a run) and stop; inventing a diff is
  forbidden.

## Acceptance (run it yourself and attach raw output)

1. `validate.py list` — prints all 9 records with the recorded verdict's
   class and «нет метки».
2. `validate.py run --limit 3 --models "deepseek-v4-flash:high" --jobs 2` —
   three records are run, the table prints, the run file is created.
3. `validate.py run --limit 3 --models "deepseek-v4-flash:high,glm-5.3:max"`
   — two models in one table.
4. `validate.py run --limit 2 --project-layer recompose --models "deepseek-v4-flash:high"`
   — works on records with `cfg: null` (the base is taken) without
   exceptions.
5. `validate.py report <file from item 3>` — the same table without network
   access.
6. `validate.py label <any record> --truth OK --note "check"`, then
   `validate.py list --unlabelled` — the labelled record is gone from the
   list. After the check DELETE THE LINE FROM `labels.jsonl` (labels are set
   by a human); name this in the report.
7. Negative probe: `--url http://127.0.0.1:9/v1/chat/completions` on one
   record — a line with `error`, `klass:"ERROR"`, the table shows «ошибок 1»,
   the process does not crash.

In the report: what was done, the raw output of items 1–7, what was NOT done
and why.

<!-- BRIEF COMPLETE -->
