# The "judge on agent dispatch" patch — campaign journal

> **Status as of 2026-08-20.** This is a CHRONICLE: the original intent, the
> measured anchors, the discarded options, the defects found, and the live
> measurements — in the order they appeared. The current design of the
> mechanism is described in full in `judge-architecture.md`; the operator
> instructions are in `judge/README.md`. Wherever the text below diverges
> from them, they are right.
>
> What no longer applies here: injection 2 (the bridge to the single-request
> engine) was discarded in favor of a direct HTTP request; input rewriting
> was discarded in favor of cancellation; "no disk reads" was revoked — the
> setting is read from files on every call; the anchors were measured on
> 2.1.235, the installed image is 2.1.237. What appeared AFTER this text and
> is described only in the architecture: the ladder of attempts with per-rung
> limits, the verdict on the first line, the transcript as an array of
> records with provenance, full consultation records and their replay, the
> project layer of the setting, the rule in the system prompt (step 26).


Goal: when the MAIN loop invokes the subagent-spawning tool, give the local
judge model the same context the server-side advisor receives (request
history + the system part), PLUS the current turn with its reasoning, which
the advisor does not have, and apply the verdict through existing
mechanisms (input rewriting / error result).

All anchors were measured on the INSTALLED 2.1.235
(`~/.local/share/claude/versions/2.1.235`, 313 349 904 bytes). Line numbers
are not used — only structural literals.

## Injection 1 — an accumulator of the current turn, addressable by call id

The location (2.1.235, verbatim):

    if(po.type==="assistant"){if(ne&&Ruf(Z.agentId,Z.agentContext)&&!po.isApiErrorMessage)xuf(po.message.content);
    let Dl=Jc??po;if(!Ju)Ye.push(Dl);let Xu=Dl.message.content.filter((wd)=>wd.type==="tool_use");
    if(Xu.length>0)gr.push(...Xu),bt.needsFollowUp=!0;for(let wd of Xu)bt.streamingToolExecutor.addTool(wd,Dl)}

Facts the injection stands on:
- in streaming, EVERY content block arrives as a SEPARATE assistant message
  (`content: UKn([ni], ...)` — an array of one element), so the message
  that reaches the executor carries ONLY the tool-use block, no reasoning;
- the accumulator (`Ye`) collects ALL assistant messages of the current
  turn, including reasoning blocks (they accumulate in plain text).

The edit: before `addTool`, put a SNAPSHOT of the accumulator into a global
map, keyed by the call block's id:

    globalThis.__ccJudgeTurn ??= new Map();
    globalThis.__ccJudgeTurn.set(wd.id, Ye.slice());

Why a map and not a context field: the context object in this loop is
REASSIGNED (`Z={...Z,messages:...}`), so mutating "the same" object does
not guarantee visibility to the executor. Keying by the call id removes the
object-identity question entirely.

Release: the entry is deleted by the reader (injection 3) immediately
after reading; additionally, the map is trimmed past 64 entries.

## Injection 2 — a bridge to the single-request engine (DISCARDED)

> Discarded: the engine is called with constructors from another module's
> scope; reaching it would have required a lazy bridge that might never
> initialize. Instead — a direct HTTP request that depends on no minified
> binding.

The engine (unique in the bundle):

    async function UHe({messages:e,systemPrompt:t,thinkingConfig:r,tools:n,signal:o,options:i})

It goes through the same client factory as the main loop, so our routing
patch steers any non-`claude` model to the proxy automatically.

The bridge is defined not next to `UHe` but next to a READY-MADE call
example (the artifact-comment autoreaction module), because all the
constructors are already in scope there. The example, verbatim:

    await UHe({messages:[hn({content:i})],systemPrompt:am([rcv]),
      thinkingConfig:{type:"disabled"},tools:[],
      signal:e.context.abortController.signal,
      options:{model:RO(),querySource:"artifact_comment_triage",
        isNonInteractiveSession:!0,agents:[],hasAppendSystemPrompt:!1,
        mcpTools:[],enablePromptCaching:!1,maxOutputTokensOverride:128,
        stickyBetas:DF(ID()),proactivityLevel:Mre(e.context),
        agentContext:NS(),async getToolPermissionContext(){return ZH()}}})

The edit: right after this expression (or before the function containing
it), define:

    globalThis.__ccJudgeAsk = async (msgs, sys, model, signal, ctx) => UHe({
      messages: msgs, systemPrompt: am([sys]),
      thinkingConfig: {type:"disabled"}, tools: [], signal,
      options:{ model, querySource:"artifact_comment_triage",
        isNonInteractiveSession:!0, agents:[], hasAppendSystemPrompt:!1,
        mcpTools:[], enablePromptCaching:!1, maxOutputTokensOverride:512,
        stickyBetas:DF(ID()), proactivityLevel:Mre(ctx),
        agentContext:NS(), async getToolPermissionContext(){return ZH()} }});

OPEN: whether an arbitrary `querySource` value is allowed. For now the
example's value is reused — verify on a live run that it affects nothing
but telemetry.

## Injection 3 — the judge itself, before tool execution

The location (2.1.235, verbatim):

    se=await e.call(E,{...n,toolUseId:t,userModified:X.userModified??!1},o,i,p)

Name correspondence in this scope: `e` the tool, `t` the call id,
`n` the tool context, `i` the (single-block) assistant message, `E` the
tool input, `X` the permissions-pipeline result. Stable anchors stand
nearby: the `[Stall] tool_dispatch_start` log line (unique across the
whole tree) and the `phase:"pre_call"` branch.

The edit: insert a block before this expression that
1. returns immediately if the enable environment variable is not set;
2. returns if the tool name is neither `Agent` nor `Task`;
3. returns if the call was made NOT by the main loop
   (`n.agentContext?.agentType !== "main"`);
4. assembles the context: `(n.messages ?? []).concat(the turn snapshot
   keyed by t)`;
5. calls `globalThis.__ccJudgeAsk` with the judge system part and its own
   timeout;
6. applies the verdict:
   - rewrite: `E = {...E, model: <model>}` (verified live that the call
     parameter beats the model from the agent definition);
   - refuse: return an error result the same way the `phase:"pre_call"`
     branch does;
7. on ANY error, timeout, or unparsable answer — lets the call through
   unchanged (fail-open) and writes the reason to the debug log.

## Invariants the patch must hold

- Off by default: without the environment variable, behavior is
  byte-for-byte as today.
- The judge does not judge itself: its own tool request invokes no tools
  (`tools: []`), recursion is impossible.
- Subagents are not judged (condition 3) — the user's requirement.
- Fail-open on every failure path.
- ~~No disk reads: context comes from memory.~~ REVOKED: the setting
  (config/prompt/body, global and project layers) is read from files on
  EVERY call — a judge whose wording can only be changed by rebuilding the
  binary is not iterable. The transcript is still taken from memory.

## What has been verified live (probes in scratchpad/probe-updatedinput/)

- Model rewriting through a rewritten input IS APPLIED to the agent
  dispatch and overrides the model pinned in the agent definition's
  frontmatter.
- The refusal text reaches the model in the tool result body with the
  error flag; the model reads it and corrects the call.
- On conflicting verdicts of several interceptors, refusal wins.
- The main loop's payload lacks an agent identifier (the discriminator).

## Decision change 2026-08-20: cancellation instead of rewriting

The judge does NOT rewrite the dispatch. On a negative verdict it CANCELS
the call and explains to the main loop what is wrong; the main loop reissues
the call itself.

Why this and not model rewriting: the deterministic gate sits EARLIER in
the same function, so a model/effort pair rewritten here would pass no
one's check. Refusal is strictly narrower than what the gate already
allowed — order stops mattering.

The mechanics of refusal — a `throw` inside a block that is anyway wrapped
by the tool executor's outer `catch(Z)`. Read in 2.1.235: this catch builds
`{type:"tool_result", content:<error text>, is_error:!0, tool_use_id:t}`
and puts it into the message stream. The refusal text reaches the model
the normal way, and the patch is not coupled to any minified constructor
name.

The judge's own `catch` is fail-open by design (a crashed judge must not
stop the session), so the refusal is marked `__er.__ccJudgeBlock=!0` and
rethrown — otherwise it would be swallowed where channel failures are
swallowed.

The verdict vocabulary: `OK:` pass, `WARN:` pass with a note,
`BLOCK:`/`STOP:`/`DENY:` cancel. Cancellation applies only under
`CLAUDE_JUDGE=enforce` or `enforce:true` in config.json.

## The channel address

The judge has no separate address: `CLAUDE_JUDGE_URL` -> `config.json.url`
-> `process.env.ANTHROPIC_BASE_URL` -> `http://127.0.0.1:8317`. The `url`
field from config.json was removed: the proxy is already set in the
session settings.

## Measurements 2026-08-20 (4.7 KB body, real context)

| model | n | median | max | parsed verdicts |
|---|---|---|---|---|
| glm-5.3 | 8 | 4.6 s | 8.8 s | 8/8 |
| deepseek-v4-flash | 8 | 7.0 s | 12.0 s (plus 2 calls >30 s) | 0/3 in the comparative run |
| grok-4.6 | 3 | 15.2 s | 18.5 s | 3/3 |

Context volume does not determine latency: cutting it to 8 KB did not
lower it. The judge was moved to glm-5.3, threshold 15 s — with headroom
over the observed tail. End-to-end run: 3 of 3 verdicts, channel 200.
Under the previous 8 s threshold the judge would have been skipped in
about half the calls, i.e. it would have been nearly inert.

## Defects found and fixed along the way

1. `join("\n")` in the patch source was emitted as a REAL newline inside a
   string literal — the bundle stopped parsing, while every
   pattern-matching check stayed green.
2. The pipeline's smoke run was written as
   `echo "Version: $("$BIN" --version | head -1)"` — the exit code was
   discarded, and a broken image reported success. It is now a hard gate:
   the status is captured separately; a missing version line halts the
   pipeline before the launcher swap.
3. The refusal was swallowed by the judge's own `catch` (see above).
4. A non-ASCII literal arrived double-encoded: tweakcc unpacks and packs
   the bundle as BYTES. The refusal text is emitted with `\uXXXX`
   escaping.
5. A missing `+` in a patch string concatenation: automatic semicolon
   insertion makes such code valid for `node --check`, yet truncates the
   patch string. Caught only by the smoke gate — it is the real test.
6. An empty verdict was indistinguishable from a channel failure. For
   debugging, the raw answer and HTTP status are written to
   `last-response.json`.

## The consultation journal (added 2026-08-20)

WARN does not reach the model and cannot: the call proceeds, and the tool
result the model will see later comes from the agent itself. There is no
channel for a note there. Practically, WARN is OK with a journal record.

Hence the journal is always kept, not only under debugging: a call skipped
due to a failure and a call the judge never touched are indistinguishable
from outside ("disabled on both ends"). File `journal.jsonl`, one line per
consultation, fields: `t`, `tool`, `agent`, `model`, `http`, `outcome`,
`verdict`/`reason`.

`outcome`: ok | warn | block | block_not_enforced | empty | skip.
`block_not_enforced` is separated out, otherwise a refusal issued outside
enforce mode would merge with ok.

The record is written OUTSIDE the inner try, so it survives an import
failure and a channel break; it is itself wrapped so that it cannot break
the call. Verified on live runs with debugging DISABLED: an ordinary call
gave `ok` with a verdict, a call to a dead address — `skip` with a reason
code, the agent completing its work regardless.

The first-priority metric in live operation is the share of `skip` and
`empty` by reason code. A separate check for the journal's presence was
added to the pipeline.

## The dispatch selector (added 2026-08-20, absent by default)

What the injection point sees (measured by a live run, not inferred):
`{description, prompt, subagent_type, run_in_background}`. The `model`
field is present ONLY if the model is named in the call itself; when
inherited from the agent definition it is absent altogether. So the
"expensive model" rule is expressed through the agent NAME, not the model.

`config.json.filter`: `classes_judge`, `classes_skip`, `agents_judge`,
`agents_skip` — lists of regular expressions. `_skip` wins; if at least
one `_judge` is set, only matches are judged. The class is taken from
`[dispatch-class:…]` in the prompt. Absence of the `filter` key means
judge everything (the previous behavior).

A filtered call writes `outcome:"filtered"` to the journal and does NOT go
to the network — its latency tax is zero, and the saving is measurable
from the journal.

Anti-loop is held structurally: only calls with `agentType==="main"` are
judged, so the subagents' own dispatches are not judged and there is no
recursion.

Verified by three runs: without a filter — `ok`; a filter on
analysis/critique/audit and the scout class — `filtered` (no network
call); the same filter and the critique class — the consultation took
place, and the judge refused on the merits (a critic on a mechanical
task), recorded as `block_not_enforced`.

## In passing: code 429 from the proxy

An empty verdict, previously looking like "the model kept silent", turned
out to be an HTTP 429 response. Visible in the journal as
`outcome:"empty"` with `http:429`. An example of why the raw answer is
needed: from the verdict alone, a channel refusal and the model's silence
are indistinguishable.

## Narrowing causes to their conditions (2026-08-20)

The lens: not "does the skip print its reason" but "does the skip
CONDITION coincide exactly with the stated reason, or is it broader". Two
places turned out broader.

1. `outcome:"filtered"` covered two different decisions: the class is
   named in the skip list — and the class is simply absent from the
   "judge" list. The latter is how an unnoticed typo in the config
   silently disables the judge for a whole class. The field `by` was
   added: `classes_skip` | `agents_skip` | `not_in_judge_list` |
   `no_class_marker`.
2. A journal write failure was muffled by its own interceptor, i.e. a
   consultation that never happened looked like one that never occurred —
   the journal reproduced the very blindness it exists for. Now the whole
   line goes to the error stream.

Verified: `by:"classes_skip"` and `by:"not_in_judge_list"` on live runs;
with a nonexistent journal directory, the full record with ENOENT went to
the error stream.

Two probes before this were worthless and were redone — recorded here so
as not to repeat: (1) a call with the class `adjudication` never reaches
the judge; the main loop's own routing table rejects it; (2) `chmod 500`
on a DIRECTORY does not prevent appending to an already existing file —
you need a nonexistent directory.

## The verification matrix as of 2026-08-20 (all — live bench runs unless stated otherwise)

VERIFIED END-TO-END:
- build: 22 pipeline checks green, the image launches (the smoke gate);
- judge off without the variable: no channel calls;
- cancellation: the call did not happen, the text reached the main loop
  verbatim;
- pass on OK: the agent completed its work;
- WARN: the call went through, outcome `warn`;
- enforce from the variable AND from the config file — both cancel;
- fail-open on a dead address: `skip` + reason, the agent completed its
  work;
- the wait threshold (1 ms): `skip` with interruption, the agent completed
  its work;
- 429 from the channel: `empty` + `http:429`;
- filter: `classes_skip`, `classes_judge`, `agents_skip`, `agents_judge`,
  `not_in_judge_list` — each with its own `by`;
- journal write failure: the full line went to the error stream (ENOENT);
- absence of `body.json`: the judge assembled the body itself, a verdict
  was obtained;
- model override: with `CLAUDE_JUDGE_MODEL=grok-4.6` grok answered,
  without the variable — the model from `config.json`;
- a BACKGROUND call (`run_in_background`): the consultation took place;
- INTERACTIVE mode (via a pseudo-terminal, not `-p`): there is a journal
  record;
- ANTI-LOOP: an agent invoked a subagent within itself (proven by the
  `SUBAGENT_USED=yes` answer), the journal holds exactly ONE record — of
  the main loop's call;
- TWO parallel calls in one turn: both consultations took place, the
  second verdict references the first call — the per-identifier turn
  layout works.

THE DISABLED STATE (patch in the image, guard lifted) — verified
separately:
- no `CLAUDE_JUDGE` variable: no channel calls (verified with a receiver
  on 127.0.0.1:8899 WITH A POSITIVE CONTROL — with the guard on, the same
  receiver answers and its verdict lands in the journal, so the zero in
  the first case is not an empty one), no journal is created, the agent
  works normally;
- `enforce:true` in the config file WITHOUT the variable does not enable
  the judge — the single master switch is the environment variable;
- a DEFECT found by this check and fixed: the current-turn layout
  (injection 1) ran UNCONDITIONALLY, regardless of the guard. Entries
  from that map are deleted only when the judge READS them, so with the
  judge off they were never deleted and the map sat at its 64-entry
  ceiling, holding arrays of messages for a function that never ran. Now
  both injections hang on one switch; the expression is
  short-circuited, nothing executes with the guard lifted.

OPERATIONAL RISKS — verified separately 2026-08-20:
- REPEATED CANCELLATION does not loop: the main loop reissued the call
  once, then stopped and presented the fork to the user. Before the
  refusal-text fix there were two repeats, and the model ATTRIBUTED the
  cancellation to the routing gate, proposing to edit
  `hooks/routing-table.toml`. The wording was fixed to name the source
  and explicitly separate it from the gate; after the fix — correct
  attribution and one repeat instead of two. Lesson: refusal text is part
  of the mechanism, not decoration; an ambiguous wording costs an extra
  round and misleads diagnosis.
- CONCURRENT WRITES: three sessions at once — 3 lines, all parse, none
  broken.
- a BROKEN `config.json`: the judge runs on defaults (model glm-5.3).
- a BROKEN `body.json`: the fallback body assembly fires, a verdict was
  obtained.
- CONTEXT TRIMMING (`context_chars=300`): the body shrank to 912
  characters, a verdict was obtained.

VERIFIED NOT END-TO-END (and why an end-to-end run is impossible):
- `no_class_marker`: a dispatch without a marker is rejected by the
  routing hook EARLIER than the judge (verified: the journal is empty,
  the refusal came from the gate). An isolated config without hooks does
  not come up — the credentials are tied to the real one. The branch was
  verified by executing code EXTRACTED VERBATIM FROM THE BUILT IMAGE on
  three inputs: a marker outside the list -> `not_in_judge_list`; no
  marker -> `no_class_marker`; marker in the list -> judge.

NOT VERIFIED:
- the tool name `Task`: such a call cannot be produced from the terminal.
  The branch is not a guess — the bundle contains
  `var fi="Agent",t5="Task"` and its own check
  `if(e!=="Agent"&&e!=="Task")return`, i.e. the patch repeats the
  binary's own contract;
- installation into the working image was not performed.

PROBE TRAPS (all three gave GREEN on a worthless check):
1. the "one record" anti-loop with the nested call never executed — a
   vacuous check; you need evidence that the nested call happened;
2. `chmod 500` on a DIRECTORY does not prevent appending to an existing
   file;
3. a probe through a class forbidden by the routing table never reaches
   the judge.

## Porting to 2.1.237 (2026-08-20)

Update from 2.1.235 via `claude-patch-all.sh --update`. All locators of
both judge injections were found without edits — the structural regular
expressions survived the two-version hop (235 -> 236 -> 237). 22 checks
green, the smoke gate passed, the launcher switched to 2.1.237.

Live verification on the new image, not only against patterns: guard
lifted — no journal; observation — verdict `ok`; cancellation — the call
did not happen, the refusal text delivered verbatim and with correct
source attribution.

Our own tweakcc patches still do not apply on 2.1.237 (the same parse
error as on 2.1.235) — the pipeline survives this and installs only ours.

## Moving the tweakcc settings into our patch (2026-08-20)

The tweakcc patches do not apply wholesale on 2.1.237 (its compiled bundle
does not parse), so the four needed settings were done differently.

1. `increaseFileReadLimit` — WITHOUT touching bytes. 2.1.237 has a native
   variable `CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS` that overrides the
   default `eaS=25000` (function `Amt`, branch `taS()??…`). Written into
   `~/.claude/settings.json` with the value 1000000. The separate BYTE
   limit `WAt=262144` is controlled by no variable and stays: a file
   larger than 256 KB is cut regardless of the token limit.
   Verified: a 198 KB file without the variable truncates at line 759;
   with the variable it reads through to the end marker.
2. `statuslineThrottleMs` (step 23) — the status-line scheduler delay
   constant 300 -> 500. The locator is the `setTimeout(…, CONST)` call
   site inside the scheduler, which also names the constant.
3. `allowBypassPermissionsInSudo` (step 24) — BOTH refusals at euid 0 are
   lifted: the built-in one on the launch path and the exported
   `refuseBypassUnderRoot`. tweakcc edits only the first (its
   `String.match` stops there), i.e. its variant left the setting
   half-applied.
4. `claudeMdAltNames` (step 25) — a wrapper around the SINGLE memory-file
   reading function: if nothing exists at `…/CLAUDE.md`, AGENTS.md,
   GEMINI.md, CRUSH.md, QWEN.md, IFLOW.md, WARP.md,
   copilot-instructions.md are tried. tweakcc's approach (editing the
   error-interception block) misses here: with a store descriptor, a
   missing file is returned by the normal `absent`, not an exception. For
   the alternative the descriptor is NOT reused — it names one key and
   would return CLAUDE.md's bytes under someone else's name.
   Verified with a negative control: a directory containing only
   AGENTS.md — the old image answers "NO", the new one reads and follows
   the instruction from the file.

A TRAP caught right here: the first version of the pipeline check looked
for `var X=500` and gave GREEN on a CLEAN image — there are six such
constants there. The check is bound to the call site. All three new
checks were run against a clean image and fail correctly.

In `~/.tweakcc/config.json` these four items are disabled (backup copy
next to it), so that when tweakcc is fixed they are not applied twice.
