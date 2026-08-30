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
installed if any one of the pipeline's 119 checks fails, and the switch to a new build
happens only after those checks AND the smoke run AND the interface gate AND the
probe bench have all passed.

Before any of that the run refuses outright — nothing is written — if the
pasted code does not parse, if the check block does not parse, or if a count
stated in this file or under `docs/` disagrees with the declaration that owns
it (`EXPECTED_CHECKS`, `EXPECTED_SCENARIOS`). A number written in prose has no
reader and goes stale by default; that last gate is its reader. Counts that
record a PAST build are exempt when the line says so — see the message the
gate prints.

> **Boundary.** This repository contains ONLY our own files. The Claude Code
> image is Anthropic's proprietary software and is not distributed here:
> the pipeline reads the one already installed on your machine. Whether
> modifying it is permitted is determined by your agreement with Anthropic,
> not by this license. Use at your own risk: a broken image is fixed by
> reinstalling, but the time is lost.

Verified on **2.1.233 through 2.1.247** (macOS arm64). This is a mac tool: that is where it
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
bash claude-patch-all.sh --target X --expect-sha <hex>   # ... and prove X is X
```

**A default run never touches the live file until every gate has passed.** It
copies the live binary to `<binary>.staging`, builds there, and swaps the result
in with a rename at the end — so a gate that fires late (the interface gate, the
probe bench, any of the pipeline's 119 checks) leaves the live installation
untouched instead of half-patched. Sessions already running keep the old build
until they restart: they hold the previous inode.

`--target` is the exception: it patches the named file IN PLACE, and the caller
owns the staging discipline.

```bash
V=~/.local/share/claude/versions/2.1.238
cp -p "$V.orig" "$V.staging"
bash claude-patch-all.sh --target "$V.staging" --expect-sha "$(shasum -a 256 "$V.orig" | awk '{print $1}')"
mv "$V.staging" "$V"      # atomic; takes effect on the next launch
```

`--expect-sha` is asked BEFORE anything else and refuses with its own exit code
(4) when the bytes at that path are not the ones named: between a caller's copy
and the moment the pipeline reads the file there is a lock wait, an unpacker
install and tweakcc's whole stage, and a failed copy or a leftover from an
earlier run would otherwise be measured greenly under the pinned version's name.
Whether or not anything was pinned, the run prints `Source digest: <hex> <path>`
for the bytes the build actually begins from, so a verdict can be bound to them
afterwards.

Re-running the script is how you recover — but it is not always enough. When the
live image already carries our patches and the pristine copy beside it is
missing, is itself patched, or belongs to a DIFFERENT build, a default run
refuses rather than rebuild: the first would poison tweakcc's backup, the last
would swap another version over the live one. The refusal prints the line that
does work, `bash claude-patch-all.sh --update <version>`.

The order must not be violated: `tweakcc --apply` restores the binary from
its own backup copy, so our patches always run AFTER it, and any tweakcc
invocation (including its TUI) requires re-running this script.

## Contents

| file | role |
|---|---|
| `claude-patch-all.sh` | the pipeline: tweakcc → our patches → signing → checks → launcher switch → model costs |
| `tweakcc-patch.js` | the patches themselves, as a script for `tweakcc adhoc-patch`; the 119 checks that verify them live in `claude-patch-all.sh` |
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
| `tools/probe-bench.js` | the bench: scenarios run on code cut out of the built image (run under `bun` — the image is built with it). Plus `--self-check`: probe-bench's 5 recorded mutations break probe-bench ITSELF — the comparator, the undefined-key skip, the missing-specification rule, the scenario count and the unknown-key door — and each must SWALLOW a redness the poisoned copy shows, which is the only direction that proves a harness has teeth. The build runs both, as it does for the judge tools |
| `tools/probes-migrate.py` | a one-time consolidation of the two old `config.json` files into a single `probes.toml`, with a self-check |
| `docs/probe-registry-spec.md` | the probe registry spec: one settings file, a dictionary of conditions, reactions |
| `docs/review/` | the campaign home: the audit ledger (`findings-ledger.md`) and the round reports. It lived in `/tmp` until a reboot on 2026-08-28 wiped the ledger of every round — the transcript was the only way back. Its numbers belong to their own dates, so the doc-number gate skips this directory by name and says so in the build output; the kit build does not ship it (`docs/*.md` is not recursive) |
| `tools/emit-check.js` | parses the pasted code BEFORE the image is built |
| `tools/build-path-probe.sh` | drives the default-run BUILD branch for real (staging, rename, tweakcc’s backup) — the one thing the pipeline's 119 checks cannot see, with a negative control. Run by `tools/sweep.sh` as a pre-flight, once per sweep — until wave 20 nothing called it at all, which is exactly how the `--update` staging regression reached the tree. Cases: a patched live file rebuilt from `.orig`, a `.orig` of another version refused, a pristine live file staged (and its stock bytes kept), `--update`, whose install ALSO builds beside the live name, and the CLI doors — the one case that builds nothing: with the lock held by somebody else, an unknown option and two modes at once must still answer «broken contract» and `--help` must still print usage, because a broken call is broken forever while a held lock is transient; its control moves the parsing back under the lock and must turn those answers into «retry later». One more case builds nothing either: the restore of a borrowed file, both ways — a diverged live file is put back with no partial `.probe-restore` left, an impossible restore answers non-zero and leaves no debris, and the FORM of the aggregation is read out of the probe itself, because a failed restore must keep the snapshots (they are then the only way back) and redden the run. Before wave 22 that branch printed a warning and exited zero, and the same cleanup then deleted the snapshots. One more case builds nothing: a `--target` run handed bytes that are not stock must refuse with code 4 BEFORE the unpacker and tweakcc's stage and leave the named file byte-for-byte as it was — on 2026-08-28 it did neither, twice, and the live installation came back mutated from a run that reported a refusal; its control disables that guard alone and stubs the first gate past it, so walking past the site costs seconds instead of a build. Each case carries a mutation that must redden it BY ITS OWN NAMED CAUSE — the `--update` control once went red because a helper file was missing from the mutant kit, which proves nothing about the branch |
| `tools/judge-tools-bench.py` | стенд для `judge/compact.py` и обеих прополок временных имён: сценарии гоняют настоящие каталоги, режим `--self-check` требует, чтобы каждая записанная мутация краснила стенд. Оба режима — гейт каждой сборки |
| `tools/costs-bench.py` | стенд для синхронизации моделей и цен: герметичные сценарии по `set-model-costs.py`, стражам установщика в `claude_patch.py`, формату списка корпуса и функциям конвейера, извлекаемым из живого файла, а не копируемым; режим `--self-check` требует, чтобы каждая записанная мутация краснила свой сценарий своей причиной. Оба режима — гейт каждой сборки (с волны 26; до неё стенд не звал никто) |
| `scripts/probes-sync.sh` | раскатка домов проб и судьи (настройки, промты, launchd-агенты) в `~/.claude` и сверка раскатанных байтов с этим деревом (`--diff`); замок писателей сериализует одновременные синхронизации, а сборка гоняет сверку как гейт, отказывая, когда launchd и ядро исполняют байты, которых в дереве нет |
| `tools/probes-sync-bench.sh` | стенд для этой синхронизации: замок писателей и видимость стадий на игрушечном доме, плюс `--self-check` с мутациями. Оба режима — гейт каждой сборки (с волны 26; до неё стенд не звал никто) |
| `tools/lock-probe.sh` | the lock instrument: proves the run lock survives a killed parent while its writers live, that inheritance is proven by the DESCRIPTOR rather than by a variable, and that the directory fallback is reachable — run first by `build-path-probe.sh`. Also proves the other direction, the one that cost a whole sweep: a child spawned with the lock descriptor CLOSED does not hold the lock after its parent exits, and one spawned normally does. bash sets no close-on-exec on a redirection, so the long-lived CLI session the interface gate starts inherited fd 9 and kept the pipeline lock alive after the run ended; the gate now spawns it with `9>&-` |
| `tools/checks-on-image.sh` | runs the SHIPPED check block (extracted from the pipeline, refusing if its anchor is gone) against any image — the correct way to prove a check has teeth: mutating the INPUT image and rebuilding does not work, tweakcc restores its backup over the target and the mutation silently vanishes. `--floor <image>` turns it into a gate of its own: against a PRISTINE image it pins the exact set of checks allowed to be green, declared in the script by name. A check whose predicate a stock image already satisfies cannot fail on a patched one either — it only looks like coverage — so a new one joining that set is a build failure until it is either fixed or declared |
| `tools/backup-divergence-probe.sh` | the truth table of the guard that refuses when the named target and tweakcc's backup are different images of the SAME version — tweakcc restores its backup over the target, so the build would be made from bytes nobody named; extracts the real guard and refuses if its anchor is gone — run by `build-path-probe.sh` |
| `docs/judge-architecture.md` | the judge's full design: injections, flow, layers, invariants |
| `docs/judge-patch-spec.md` | the campaign journal: anchors, rejected options, measurements |
| `tools/sweep.sh` | version sweep: every pristine image of the corpus through the whole pipeline, one summary line per version. Refuses BEFORE building when an image is missing, unreadable, or its sha256 does not match the pin — and verifies again the COPY it is about to feed the pipeline, since the pin proved the source and whole builds pass between the two. Ends on ONE of two lines — `SWEEP DONE` (every version measured, none red) or `SWEEP НЕПОЛНЫЙ` with a non-zero exit; a busy pipeline lock is waited out (`SWEEP_LOCK_BUDGET`, default 600s) and, if it never clears, the version is recorded as НЕ ИЗМЕРЕНО with the holder captured by `lsof` next to the log. Holds its own lock so two sweeps cannot clobber the shared summary, and runs from a copy of itself, so the kit stays editable while it works. Without arguments it measures the five newest versions of the corpus rather than all of it (user's decision, 2026-08-28: old versions no longer spend the machine), announces that set in the stream AND in the summary — a narrowed scope read as a verdict about the whole corpus is exactly the confusion the announcements exist to prevent — and `SWEEP_LAST_N` moves the number, with `0` meaning the whole corpus. A version named twice on the command line is a refusal: «all N versions measured» promises N DIFFERENT ones. Once the lock is taken the summary is overwritten with a «прогон начат» line, so a refusal at any later door cannot leave the previous run's verdict readable as this run's — and the green verdict is written into the summary too, not only to stdout. The kit snapshot is removed on any exit, not only the successful one — but only once nothing is still executing out of it: `kill -TERM -<pgid>` reaches the sweep and the pipeline raised from the snapshot at the same time, and bash reads a script body BY OFFSET, so removing it mid-shutdown tears the run apart. The sweep waits `SWEEP_KIT_DRAIN` seconds, and if residents remain it keeps the directory and says so; the same primitive serves the normal tail and the trap, because the first edition guarded only the trap while the successful run removed the snapshot unconditionally. Each version is handed to the pipeline with `--expect-sha` and the run's own floor image, and the verdict counts the pipeline's `Source digest:` line for THOSE bytes as a field of its own: a run that measured something else is red, not green. Debris from an interrupted earlier run (a kit snapshot, a copy of the sweep, the pgid record) is reaped when it is more than a day old — the trap handlers cannot fire for a process that was killed outright — and a file whose mtime lies in the future counts as spoiled, not fresh, since a healthy writer never stamps ahead. Stopping a run goes through `tools/sweep.sh --stop`: it signals the group only when it is alive AND the recorded start time of its leader still matches, because pgids are reused and a stale record would aim the TERM at somebody else's run. Before the first build it runs `tools/build-path-probe.sh` once, from the snapshot: the default-run build branch is invisible to every check in the pipeline, and the sweep is the only automated runner of real builds. A red probe stops the sweep; «nothing to measure on this machine» (its own exit code) does not; `SWEEP_SKIP_BUILD_PROBE` switches it off and says so in both the output and the summary |
| `tools/fetch-corpus.sh` | fills that corpus from the npm REGISTRY (a local image may already be patched), straight into its own directory — never through the installs directory, whose cleanup phase is what destroyed the old corpus. A pin is only ever established from registry bytes: an image already sitting in the corpus without a pin is re-fetched and compared, never trusted. Verifies the pin of every image it finds, so it doubles as the corpus integrity check. An image that cannot be READ is named as unreadable rather than as tampered — an empty hash against a pin used to send the reader hunting for substituted bytes. The corpus file name comes from `tools/corpus-file-name.sh`, the single home both tools read. Holds its own lock (`CORPUS_FETCH_LOCK`, descriptor 6 — the sweep sits on 8 and the pipeline on 9), so two fetchers cannot download into the same names at once, and records a pin by writing a temporary file, fsync-ing it and renaming: a pin file truncated by a kill would otherwise read as «no pin» and send the next run downloading over a good image |
| `tools/corpus-tools-bench.sh` | corpus-tools-bench, for the corpus tools: 102 scenarios on a toy corpus. What they cover is a LIST, not a quantifier — an audit refuted the old «every refusal door» claim by recounting the doors: the sweep's refusals for a missing, unreadable or pin-mismatched image, for a missing, empty, duplicate-version, duplicate-label, malformed-pin, malformed-version or foreign-platform list, for a busy sweep lock and for a version named twice; the fetcher's unreadable-image and pin doors and its «pin only from registry bytes» rule; the provenance label; all three copy failures; every field the verdict consumes; the summary an early refusal must invalidate; the snapshot removed on refusal; the build-path pre-flight in every reading of the probe’s answer — called by default, a refusal stops the sweep before the first build, «nothing to measure here» does not, «the instrument cannot measure» is its own class and not a red run, and switching the probe off is announced; the registry-teeth pre-flight in every reading of its answer — called by default with its verdict announced, a red instrument stops the sweep before the first build, «the instrument cannot measure» keeps its own class rather than reddening the run, and switching it off is announced; the corpus-tools pre-flight the same way — the bench is called twice (its scenarios AND its teeth), a red bench stops the sweep, «cannot measure» and «the lock machinery is broken» each keep their own class, and switching it off is announced; the bench’s own immunity to the environment a REAL sweep leaves around it — the sweep exports its leader bookkeeping, and a toy sweep that inherits it skips its leader block and reaches for the real kit, which is how a pre-flight once spent forty minutes running real builds against the live tweakcc state; that scenario has two halves, a live run under a leaked environment and the scrub’s FORM read out of the kit copy, because the launcher whose behaviour it measures lives in the executing file and the teeth may only edit copies; the presence of the two wave-20 gate CALLS, through the verdict fields that require their lines in the build log — delete either call from the pipeline and the sweep goes red; the single home of the corpus file name and the one knob every home of the run-lock name reads; the CLASS of every answer and not merely its non-zero code — a named version list that does not exist is «nothing to measure» and not «the list does not parse», a busy pre-flight bench is «retry later» and not a red bench, a sweep whose only incompleteness came from a busy pipeline lock says «retry later» instead of refusing on merits, and a pipeline answering «broken call contract» is named as that in the verdict rather than as a bare number, a pin with no row left in the list is «nowhere to record what was measured» rather than a red corpus, and a list parser that cannot load the module it reads the platform from blames the KIT rather than the list; the bench’s immunity to the operator’s own skip knobs — `SWEEP_SKIP_BUILD_PROBE` in the ambient environment used to ride into the toy sweeps and redden an unrelated scenario, so the scenarios pass their own names and the form of that mapping is read out of the kit copy; the default MEASURED SET — a run with no arguments takes the five newest versions of the corpus by NUMBER (not the tail of the file, whose order is hand-written) and says so in the stream and in the summary, and `SWEEP_LAST_N=0` still measures all of it; both halves have their own toy corpus of seven versions, because on the shared two-version one «the last five» and «all» are the same run; the length agreement of the five mutation tables (`--table-check`); the live-run guard in both directions — a real pipeline run is caught, the kit path sitting in another program's argv is not — and the guard's FORM, which must be one and the same in the sweep and in the bench: the bench's own stricter copy used to refuse on the doc-number gate's argv; the snapshot of the kit surviving the cleanup while a process started from it is still alive — on the NORMAL tail as well as on refusal, since the first edition guarded only the trap while the successful run removed it unconditionally; the bench's own precondition in both directions — a foreign pipeline outside its temp root is seen, its OWN decoration inside that root is not, because scenario 45 raises a fake pipeline on purpose and the precondition used to refuse the bench on its own prop; the mark a mid-run real pipeline leaves on disk, because the sweep is only ever called from a command substitution and an `exit` there ends the substitution alone; and the queue two bench runs form (their stub is named `claude-patch-all.sh`, so without it each would call the other a live build). The pipeline it drives is a STUB that prints the verdict markers, so the bench never takes the real lock and never builds an image; the only network it can touch is a registry lookup for a deliberately nonexistent version, which refuses — the fetcher scenarios pass with the network down too. Plus `--self-check`, where corpus-tools-bench's 107 recorded mutations must each redden their scenario AND leave the trace recorded for it — a scenario that goes red for a neighbouring door's reason proves that door, not its own. Coverage is checked by the bench itself: a scenario without a mutation of its own proves nothing, and the ONE deliberate exception is named in the code — the positive control of the verdict, which any always-red mutation reddens anyway. Deliberately NOT wired into the build: it drives the same scripts, whose global tweakcc-state guard refuses while a pipeline run is alive — so it refuses upfront with its own exit code instead. Run it beside `build-path-probe.sh` and `lock-probe.sh` |
| `tools/checks-teeth.py` | the teeth of the check registry itself: `checks-on-image.sh` proves a check RUNS, never that it can fail, and a check that cannot fail is not coverage. The control run over a built image must be green; then every row of `checks-mutations.tsv` is applied to a COPY of those built bytes — an edit of equal length, because the input image cannot be mutated at all (tweakcc restores its backup over the target and the mutation silently vanishes) — the shipped check block is run, and the red set must be exactly the row's own check plus the neighbours the row declares. checks-teeth's 19 recorded mutations cover the check bodies round 20 rewrote, the core guarantees of wave 23 — the notice on an answer cut at the output cap, the disabled-probe memo, the ambiguous dispatch class, the evicted turn — and the two wave-24 guarantees: the marking that lets the judge tell its own pending call from the calls that already went out, and the single probes home that keeps an isolated session's records out of the live one; and the three promises of the record horizon, each of which must be able to go red alone — the exact prune boundary, the exemption of the record just written, and the archive kept out of the window (measured on 2026-08-30: while `.gz` was counted alongside live records, the horizon carried off 24 of 45 labelled ones). Padding goes INSIDE the expression where trailing spaces would break a neighbouring check's pattern; a row whose anchor is gone is «the instrument cannot measure», not a silent pass. Run as a sweep pre-flight, switched off by `SWEEP_SKIP_CHECKS_TEETH` and announced when it is |
| `tools/docnum-bench.py` | the teeth of the doc-number gate: it copies the kit, carves the gate out of the pipeline by its anchor (refusing if the anchor is gone), proves the pristine copy is GREEN, then applies every mutation recorded in `docnum-mutations.tsv` and requires each to redden the gate for its own reason. docnum-bench's 40 recorded mutations, one per rule of the grammar (the newest one guards the elided-noun form «все N» — a count whose noun was dropped used to be invisible to the gate BY CONSTRUCTION, and a live stale number hid behind exactly that form, round 28 F-12; the next-newest two guard the campaign-journal home wave 24 gave the audit ledger: dropping the exclusion must redden the gate on the ledger itself, and pointing it at a directory that does not exist must refuse) — including the five the round-17 lenses added: a marker frees exactly ONE count, the ±400 window refuses two names as strictly as the sentence does, a fenced block is PARSED rather than blanked, a table cell inherits the noun of its column header, and the closed list of number-words is complete in both languages; run by the build |
| `tools/docnum-mutations.tsv` | those mutations as data: id, file, the exact text to replace, its replacement, and what the gate must answer. They live outside the code because each one is a deliberately WRONG count, and the gate scans prose in `.md`, `.sh`, `.js` and `.py` — written in the bench itself they would be live claims |
| `tools/corpus-list.py` | the single home of the corpus-list FORMAT, read by both the sweep and the fetcher. Each of them used to parse the file with its own `while read`, and the two readings disagreed: a line without a pin was a refusal for one and a reason to download and record a pin for the other; a stray fourth field was swallowed by both; one version under two labels counted as two measured versions over a single file on disk. Also refuses a list that does not name its platform, or names another machine's: the pin is platform-specific, and a corpus carried over would otherwise be rejected image by image as tampered |
| `tools/corpus-versions.txt` | the one list both of them read, in the format `tools/corpus-list.py` defines: a `# platform:` line naming the registry package the pins belong to, then label, version, sha256 per line. One version per bundle SHAPE our anchors must understand, plus the boundary versions where the shape changed |
| `tools/listener.py` | an HTTP receiver for routing probes |
| `tools/corpus-file-name.sh` | the single home of the corpus file name: the sweep, the fetcher and the bench derive it from one function, because a suffix changed in one of them alone would leave the sweep measuring the old bytes with their pins still matching |
| `tools/image-check.py` | decides whether a file is a WHOLE Claude Code image: magic, product marker, and COMPLETENESS from the image's own headers — an interrupted download passes the first two and fails later inside the unpacker, naming a consequence instead of the cause |
| `tools/site.d.ts` | the contract of the splice site: every host name the injected block does not declare itself, so «the name exists» is a compiler question rather than a memory one |

## What the patches do (119 pipeline checks)

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

## Turning the probes on

The judge and the fleet watcher are inert until their switches are set, and they
read the rest of their posture from `~/.claude/probes/probes.toml`.

The switch is obeyed with or without that file. `CLAUDE_JUDGE=enforce` enforces
immediately -- and on a machine where `probes.toml` is missing the judge's
`prompt.md` is missing too, which is a broken posture rather than a lax one: the
judge does not know the rules it is meant to judge by, so it CANCELS every
dispatch and names the file to create. That is deliberate, and it is the
opposite of a silent pass, but it will stop the fleet until the files are there.
Install them first.

`fail_closed` is the one setting with no environment carrier, because a setting
with two homes is the defect this kit checks for elsewhere. Without the file a
channel failure therefore passes rather than cancels.

```sh
bash scripts/probes-sync.sh --to-home   # FIRST: settings and prompts into ~/.claude/probes
export CLAUDE_JUDGE=enforce             # nothing happens until this is set
export CLAUDE_IDLE=1                    # the fleet watcher, separately
```

Each probe also reads `~/.claude/probes/<probe>/prompt.md`. If that file is
missing, the journal records it with the exact path to create, and what happens
next depends on the posture: in advise the probe consults on a built-in
instruction written in its own verdict vocabulary; under `enforce` it does not
consult at all -- not knowing the rules is a broken posture, so the judge
cancels and the watcher stays silent.


## Going back to stock

`--update` and a default run both leave a pristine copy of the same build beside
the patched one, as `<binary>.orig`; a default run over an unpatched binary keeps
the live bytes there BEFORE building over them, and replaces an existing `.orig`
only when it is missing, is not pristine, or is a twin of a different build.
`--target` is the exception: it patches the named file in place and writes no
copy, so there the only original is tweakcc's own backup under `~/.tweakcc`.
Restoring is a staging copy and a rename, never a `cp` over
the live file: a bun executable reads its embedded assets back out of its own
file, the patched and pristine images differ in size, and overwriting in place
moves every offset under a session that is still running.

```sh
V=~/.local/share/claude/versions/<version>
cp -p "$V.orig" "$V.restore" && mv "$V.restore" "$V"
```

Sessions already running keep the old build until they are restarted -- they
hold the previous inode.

Two things worth knowing before trusting a restore:

* `tweakcc` keeps its own backup at `~/.tweakcc/native-binary.backup` and
  restores it blind, without checking what is in it. If something once pointed
  it at an already-patched binary, its `--restore` writes patched bytes and
  reports success. Check with
  `grep -c -a -F 'baseURL:/^claude/i.test(' ~/.tweakcc/native-binary.backup` --
  a non-zero count means the backup carries the patches. This kit checks the
  same thing on every run and repairs it when it holds a pristine copy.
* Rolling back to a PREVIOUS version is not possible from local files: cleanup
  keeps the current version and its `.orig`, plus any older version a running
  session is still executing (with that version's `.orig`, so it can be
  restored too); once those sessions exit the next `--update` collects them.
  Re-install the older version
  with `--update <version>`.


## Exit codes

Every tool of the kit answers in the same vocabulary, and every caller
branches on the CLASS rather than on «non-zero». One code for two different
answers is how «the lock is busy, retry later» once looked exactly like «the
kit is broken, retrying is pointless» for ten minutes of waiting.

| code | meaning | what the caller should do |
|---|---|---|
| 0 | green | carry on |
| 1 | a refusal on the merits: a gate failed, an assertion does not hold | fix the kit or the image |
| 2 | the instrument cannot measure: the call contract is broken (unknown argument, wrong arity) or an anchor it carves by is gone | fix the call, or the anchor |
| 3 | a lock is held by another LIVE run | retry later |
| 4 | what was named does not match what is there: `--expect-sha`, a corpus pin, a declared table length | look at the source of the mismatch |
| 5 | there is nothing to measure on this machine | move on, having announced the skip |
| 6 | the environment or the lock machinery is broken (a false ownership claim, `perl` cannot flock) | retrying will not help — fix the machine |

Death by a signal is answered as 128+N (130 INT, 143 TERM, via the split
traps) and is NOT a kit verdict: POSIX reports the signal, this table reports
the kit's answers. Declared here for the two-sided rule — a reachable code
must be declared, and the split traps of wave 26/28 made 130/143 reachable.

130 arrives when INT is delivered to the process GROUP — what a terminal
does on Ctrl-C. `kill -INT <script pid>` while a foreground child is alive
is dropped by bash: the child runs to completion, the INT trap does NOT
fire, and the run finishes with its ordinary code. Nothing is truncated —
the whole run executed — so that code is honest; but probing 130 with a
single-pid kill yields the false conclusion that the trap is broken
(measured on bash 3.2, round 25, request F-6).

Each tool declares the SUBSET it can return in its own header; the table above
is the shared vocabulary, not a promise that every tool uses all of it. One
narrowing is deliberate and declared: `set-model-costs.py` can exit non-zero —
the CONVEYOR swallows its non-zero code as a WARNING, because the image is
already built and correct by then; the claim «never exits fatally» belongs to
the caller, not to the script (round 28, F-11).

## Environment knobs

The kit reads these; everything else it uses is derived. A knob that removes
coverage announces itself in the run's output — a silent skip is
indistinguishable from a gate that ran.

| knob | default | what it does |
|---|---|---|
| `CLAUDE_PATCH_SIGN_ID` | ad-hoc signature | the codesign identity for the rebuilt image; without a valid one the keychain re-prompts |
| `CLAUDE_PATCH_SKIP_BENCH` | unset | skips the probe bench — the only gate that EXECUTES the judge and the watcher; announced, and the announcement says their behaviour is unverified |
| `CLAUDE_PATCH_SKIP_MODELS` | unset | skips the cost/context-window sync into `~/.claude.json`; the sweep sets it for every build it makes and says so |
| `CLAUDE_PATCH_GATE_BUDGET` | 150 | seconds the interface gate waits for a first paint before calling it a timeout; announced when it is not the default |
| `CLAUDE_PATCH_FLOOR_IMAGE` | unset | the pristine twin for the floor gate when there is no `.orig` beside the target (the sweep points it at its corpus image) |
| `CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES` | unset | escape hatch: a crash of the tweakcc stage stops being fatal |
| `CLAUDE_PATCH_LOCK` | `$TMPDIR/claude-patch-all.<uid>.lock` | the pipeline lock file; the probes and the bench point it away from the live one so a real run is never blocked by a test |
| `CATALYST_TWEAKCC_REPO` | `TransmuteLabs/Catalyst-tweakcc` | the tweakcc fork the pipeline builds from |
| `CATALYST_TWEAKCC_SHA` | pinned in the pipeline | the fork commit; a moving fork would silently change what the stage does |
| `CATALYST_TWEAKCC_CACHE` | `~/.cache/catalyst-tweakcc` | where that checkout is cached |
| `TWEAKCC_LOCAL` | unset | use a local tweakcc checkout instead of the pinned fork; announced, because the pinned commit no longer describes the build |
| `CLAUDE_PROBES_DIR` | `$CLAUDE_CONFIG_DIR/probes`, иначе `~/.claude/probes` | the probes home: settings, prompts and records of the judge and the watcher. Лестница -- та же, что у самого продукта: сессия с изолированным `CLAUDE_CONFIG_DIR` (в том числе поднятая гейтом интерфейса) читает и пишет пробы в СВОЁМ доме, а не в живом |
| `SWEEP_LOCK_BUDGET` | 600 | seconds the sweep waits out a busy pipeline lock before recording the version as НЕ ИЗМЕРЕНО |
| `SWEEP_SKIP_BUILD_PROBE` | unset | skips the build-path pre-flight; announced in the output AND in the summary |
| `SWEEP_SKIP_TOOLS_BENCH` | unset | skips the corpus-tools pre-flight; announced in the output AND in the summary |
| `SWEEP_STATE_DIR` | `/tmp/cc-matrix` | the sweep's working root: logs, the summary, the kit snapshot |
| `SWEEP_KIT_DRAIN` | 60 | seconds the sweep waits for processes started FROM the kit snapshot before removing it; if any are still there the snapshot is kept and named in the output |
| `CORPUS_DIR` | `~/.local/share/claude-patch/corpus` | the home of the pristine images the sweep measures |
| `CORPUS_LIST` | `tools/corpus-versions.txt` | the versions list both the sweep and the fetcher read |
| `CORPUS_FETCH_LOCK` | `<corpus>/.fetch.lock` | the fetcher's own lock: two fetchers would race on the same files |
| `CORPUS_BENCH_LOCK`, `CORPUS_BENCH_LOCK_BUDGET` | `$TMPDIR/corpus-tools-bench.<uid>.lock`, 300 | the bench's own lock and how long a second run queues on it |
| `KEEP_ROOT` | unset | the build-path probe keeps its working root for analysis instead of removing it; announced |

Not for operators, and not a public interface: `CLAUDE_PATCH_LOCK_HELD_BY`
(passed to children to prove inherited lock ownership), `SWEEP_SELF`,
`SWEEP_KIT`, `SWEEP_LEADER` (the sweep's own re-exec bookkeeping) and the
`STUB_*` family (how the bench drives its stub pipeline).

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

## Перепись замков кита

Каждое открытие замка в ките названо здесь. Пропущенная строка -- не косметика:
номер дескриптора наследуется ребёнком, и держатель, поднявший долгоживущего
ребёнка без `N>&-`, оставляет замок занятым после собственной смерти (именно
так однажды был потерян целый свип). `tools/lock-probe.sh` сверяет эту таблицу
с деревом и краснеет, если в ките есть открытие, которого здесь нет.

| открывает | дескриптор | файл замка | зачем |
|---|---|---|---|
| `claude-patch-all.sh` | 9 | `CLAUDE_PATCH_LOCK` (умолчание `$TMPDIR/claude-patch-all.$(id -u).lock`) | состояние tweakcc общее: два прогона теряют записи друг друга |
| `tools/build-path-probe.sh` | 9 | ТОТ ЖЕ файл | зонд гоняет настоящие сборки и обязан стоять в той же очереди |
| `tools/checks-teeth.py` | — (`flock` из python) | ТОТ ЖЕ файл, но РАЗДЕЛЯЕМЫЙ | меряет живой образ: сборка меняет его под руками, два замера друг другу не мешают |
| `tools/sweep.sh` | 8 | `$STATE/sweep.lock` | свипы-ровесники делят сводку, `bin/<версия>.wave.bin` и логи |
| `tools/fetch-corpus.sh` | 6 | `CORPUS_FETCH_LOCK` (умолчание `$CORPUS/.fetch.lock`) | два наполнителя качали бы в одни имена |
| `scripts/probes-sync.sh` | 7 | `PROBES_SYNC_LOCK` (умолчание `$CLAUDE_HOME_DIR/probes-sync.lock`) | раскатка пишет в дом проб через стадии: два писателя-ровесника оставили бы дом полусобранным |
| `tools/corpus-tools-bench.sh` | 9 | `CORPUS_BENCH_LOCK` -- ДРУГОЙ файл под тем же номером | стенды выстраиваются в очередь; номер общий с конвейером НАМЕРЕННО: стенд закрывает его каждому игрушечному свипу (`9>&-`), поэтому один процесс никогда не держит оба |

