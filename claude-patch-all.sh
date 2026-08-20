#!/usr/bin/env bash
# One command for the whole stack: tweakcc's own patches + our multi-provider
# patches + a correct signature + the model data those patches read.
#
#   bash claude-patch-all.sh                 # apply everything to the current install
#   bash claude-patch-all.sh --configure     # open tweakcc's TUI to pick ITS patches, then apply everything
#   bash claude-patch-all.sh --update        # install the latest Claude Code first, then apply everything
#   bash claude-patch-all.sh --update 2.1.222
#   bash claude-patch-all.sh --only-ours     # skip tweakcc's patches, apply only ours
#   bash claude-patch-all.sh --target /path/to/binary   # build somewhere else
#   CLAUDE_PATCH_SKIP_MODELS=1 bash claude-patch-all.sh # skip the model price/window sync
#
# --target exists for the case where the binary you want to patch is the one
# currently RUNNING your session: patching in place rewrites a live executable
# and can kill it. Instead, build into a staging file and swap it in with a
# rename, which the running process (holding the old inode) never notices:
#
#   V=~/.local/share/claude/versions/2.1.222
#   cp -p "$V.orig" "$V.staging"
#   bash claude-patch-all.sh --target "$V.staging"
#   mv "$V.staging" "$V"        # atomic; takes effect on the next launch
#
# ORDER MATTERS AND IS NOT NEGOTIABLE:
#   `tweakcc --apply` RESTORES Claude Code from tweakcc's backup before applying
#   its own patches, which wipes anything else in the binary. So our patches must
#   always come AFTER it, and re-running tweakcc (its TUI included) always
#   requires re-running this script to put ours back. This script is safe to
#   re-run at any time — that is how you recover.
#
#   Both tweakcc steps re-sign ad-hoc with an identifier derived from the file
#   name. On macOS that breaks the login keychain's ACL for the OAuth item
#   ("Not logged in"), so we re-sign LAST with a stable identity and the original
#   bundle id.
set -euo pipefail

# 4.3.3 minimum: 4.3.2's unpacker cannot read the container Claude Code ships
# from 2.1.231 on (bun bumped; the binary grew ~5 MB) and aborts with "Failed to
# extract JavaScript from native installation" before any patch is evaluated.
TWEAKCC_VER="${TWEAKCC_VER:-4.3.3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUR_PATCH="$HERE/tweakcc-patch.js"
INSTALLER="$HERE/claude_patch.py"
COSTS_SYNC="$HERE/set-model-costs.py"
BUNDLE_ID="com.anthropic.claude-code"

# ~/.claude.json is rewritten by the model sync (and by Claude Code itself), so
# every run leaves a timestamped backup. Keep the three most recent.
prune_config_backups() {
  local count
  count=$(ls ~/.claude.json.backup.* 2>/dev/null | wc -l)
  if [[ $count -gt 3 ]]; then
    echo "==> Cleaning old config backups (keeping 3 most recent)"
    ls -t ~/.claude.json.backup.* | tail -n +4 | while read -r f; do rm -v "$f"; done
  fi
}

CONFIGURE=0
ONLY_OURS=0
DO_UPDATE=0
UPDATE_VER=""
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configure) CONFIGURE=1; shift ;;
    --only-ours) ONLY_OURS=1; shift ;;
    --target)    shift; [[ $# -gt 0 ]] || { echo "--target needs a path" >&2; exit 1; }
                 TARGET="$1"; shift ;;
    --update)    DO_UPDATE=1; shift
                 [[ $# -gt 0 && "$1" != --* ]] && { UPDATE_VER="$1"; shift; } || true ;;
    -h|--help)   sed -n '2,33p' "$0"; exit 0 ;;
    *)           echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$TARGET" && $DO_UPDATE -eq 1 ]] && { echo "ERROR: --target and --update are mutually exclusive" >&2; exit 1; }

[[ -f "$OUR_PATCH" ]] || { echo "ERROR: tweakcc-patch.js not found next to this script"; exit 1; }
command -v node >/dev/null || { echo "ERROR: node is required (tweakcc runs on Node)"; exit 1; }

# --- 0. optionally install a pristine Claude Code -----------------------------
if [[ -n "$TARGET" ]]; then
  [[ -f "$TARGET" ]] || { echo "ERROR: --target $TARGET does not exist"; exit 1; }
  BIN="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$TARGET")"
elif [[ $DO_UPDATE -eq 1 ]]; then
  echo "==> Installing a pristine Claude Code${UPDATE_VER:+ $UPDATE_VER}"
  BIN="$(python3 "$INSTALLER" --download-only ${UPDATE_VER:+$UPDATE_VER} | tail -1)"
else
  CLAUDE_BIN="$(command -v claude || true)"
  [[ -z "$CLAUDE_BIN" ]] && { echo "ERROR: 'claude' not on PATH"; exit 1; }
  BIN="$(readlink -f "$CLAUDE_BIN" 2>/dev/null || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$CLAUDE_BIN")"
fi
echo "Target binary: $BIN"

# Keep our own pristine copy independent of tweakcc's backup.
if [[ ! -f "$BIN.orig" ]]; then
  cp -p "$BIN" "$BIN.orig"
  echo "Backed up -> $BIN.orig"
fi

# --- always start from pristine ----------------------------------------------
# Both patch sets consume anchors: applied twice, the second run cannot find
# them ("routing site not found"). tweakcc restores from ITS OWN backup before
# applying, so if that backup was ever taken from an already-patched binary it
# silently re-introduces the old edits and breaks the run. Reset both to the
# pristine build, which makes this script deterministic and re-runnable.
if ! cmp -s "$BIN" "$BIN.orig"; then
  cp -p "$BIN.orig" "$BIN"
  echo "Reset to pristine from $BIN.orig"
fi
TWEAKCC_BACKUP="$HOME/.tweakcc/native-binary.backup"
if [[ -f "$TWEAKCC_BACKUP" ]] && ! cmp -s "$TWEAKCC_BACKUP" "$BIN.orig"; then
  cp -p "$BIN.orig" "$TWEAKCC_BACKUP"
  echo "Re-pointed tweakcc's backup at the pristine build"
fi

# --- 1. let the user pick tweakcc's patches ----------------------------------
if [[ $CONFIGURE -eq 1 ]]; then
  echo "==> Opening tweakcc's UI — pick the patches you want, save, and quit."
  npx -y "tweakcc@$TWEAKCC_VER" || true
fi

# --- 2. tweakcc's own patches (restores from its backup first!) ---------------
# tweakcc takes no target argument — it resolves the installation itself, from
# `ccInstallationPath` in its config (auto-detect when null). After --update that
# resolution can still land on the PREVIOUS version, silently patching a binary
# nobody runs while ours stays untouched. Pin it to the binary we are working on.
if [[ $ONLY_OURS -eq 0 ]]; then
  TWEAKCC_CFG="$HOME/.tweakcc/config.json"
  if [[ -f "$TWEAKCC_CFG" ]]; then
    python3 - "$TWEAKCC_CFG" "$BIN" <<'PY'
import json, sys
path, target = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
if cfg.get('ccInstallationPath') != target:
    cfg['ccInstallationPath'] = target
    json.dump(cfg, open(path, 'w'), indent=2, ensure_ascii=False)
    print(f"Pinned tweakcc to {target}")
PY
  fi
  if npx -y "tweakcc@$TWEAKCC_VER" --list-patches >/dev/null 2>&1; then
    echo "==> Applying tweakcc's configured patches"
    npx -y "tweakcc@$TWEAKCC_VER" --apply -y || {
      echo "NOTE: tweakcc --apply reported a problem (no config yet?); continuing with ours only."
    }
  fi
fi

# --- 3. our patches, ALWAYS after tweakcc -------------------------------------
echo "==> Applying our multi-provider patches"
npx -y "tweakcc@$TWEAKCC_VER" adhoc-patch \
  --script "@$OUR_PATCH" \
  -p "$BIN" \
  --confirm-possible-dangerous-patch

# --- 4. signature (must be last: both steps above sign ad-hoc) ---------------
if [[ "$(uname -s)" == "Darwin" ]]; then
  SIGN_ID="${CLAUDE_PATCH_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1{print $2}')}"
  if [[ -n "$SIGN_ID" && "$SIGN_ID" != "valid" ]]; then
    codesign -f -i "$BUNDLE_ID" -s "$SIGN_ID" "$BIN"
    echo "Re-signed with $SIGN_ID (bundle id $BUNDLE_ID)"
  else
    echo "WARNING: no code-signing identity found — keychain OAuth will NOT work."
  fi
fi

# --- 5. verify ---------------------------------------------------------------
echo "==> Verifying"
python3 - "$BIN" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
ID = rb'[A-Za-z_$][\w$]*'

def _same_env_helper(d):
    # The two edited sites live megabytes apart, so sameness cannot be asserted
    # with one backreference: name the helper at the gate, then look for that
    # exact name at the override.
    m = re.search(rb'if\(!(' + ID + rb')\(process\.env\.CLAUDE_CODE_COORDINATOR_MODE\)\)return!1;', d)
    if not m:
        return False
    return bool(re.search(re.escape(m.group(1)) + rb'\(process\.env\.CLAUDE_CODE_COORDINATOR_FORCE\)', d))

checks = {
    'routing (claude-* -> subscription)': b'baseURL:/^claude/i.test(' in d,
    'agent model schema relaxed':         b'.enum(["sonnet","opus","haiku","fable"])' not in d,
    'gateway discovery without token':    bool(re.search(rb'ANTHROPIC_AUTH_TOKEN,' + ID + rb'=' + ID + rb'\(\);if\(!1&&!', d)),
    'subagent model badge':               not re.search(rb'else if\((' + ID + rb')\.model&&\1\.model!=="inherit"\)', d),
    'input chevron colour':               bool(re.search(rb'color:' + ID + rb'\?' + ID + rb':"success",dimColor:!1', d)),
    'session memory forced on':           not re.search(rb'if\(!' + ID + rb'\("tengu_passport_quail",!1\)\)return;', d),
    # every override read must now be a merge: `{...X().additionalModelCostsCache,...X().customModelCosts}`
    'custom model costs':                 len(re.findall(rb'\{\.\.\.' + ID + rb'\(\)\.additionalModelCostsCache,\.\.\.' + ID + rb'\(\)\.customModelCosts\}', d))
                                          == len(re.findall(ID + rb'\(\)\.additionalModelCostsCache', d)) > 0,
    # every gateway-model filter must be followed by the de-disguise map
    'gateway model de-disguise':          len(re.findall(rb'\.map\(\(' + ID + rb'\)=>' + ID + rb'\.id\.startsWith\("claude-fable-5-dd-"\)', d))
                                          == len(re.findall(rb'/\(claude\|anthropic\)/i\.test\(', d)) > 0,
    # one site, two lookups (raw id, then canonical name)
    'per-model context window':           len(re.findall(rb'\(\)\.customModelContextWindows\?\.\[', d)) == 2,
    # the expired-login bail must be reachable only for the subscription lane,
    # and the proxy lane that now survives it must null both auth headers or
    # the SDK rejects the request itself
    'proxy lane survives expired login':  bool(re.search(
                                              rb'\{if\(!\(!/\^claude/i\.test\(' + ID + rb'\)&&process\.env\.ANTHROPIC_BASE_URL\)\)'
                                              rb'throw new ' + ID + rb';\}if\(', d))
                                          and bool(re.search(
                                              rb'&&!/\^claude/i\.test\(' + ID + rb'\)&&process\.env\.ANTHROPIC_BASE_URL\)'
                                              + ID + rb'\.Authorization=null,' + ID + rb'\["X-Api-Key"\]=null;', d)),
    # no path may still discard the caller's model: not coordinator mode, and
    # not the fork path (whose flag is whatever is_fork reports)
    'dispatch keeps its model':           not re.search(rb'Date\.now\(\),' + ID + rb'=' + ID + rb'\(\)\?void 0:', d)
                                          and not re.search(rb'is_fork:(' + ID + rb'),.{0,4000}?\1\?void 0:', d, re.S)
                                          and not re.search(rb'model:(' + ID + rb')\?void 0:.{0,40}?,override:\1\?', d, re.S),
    # effort must be DECLARED (schema), CARRIED (call handler) and USED (spliced
    # into the definition the runtime reads) — declaring it alone would satisfy
    # a routing gate while the request still went at the vendor default
    'dispatch carries effort':            len(re.findall(rb'effort:__ccEffort', d)) == 2
                                          and bool(re.search(rb'=\{agentDefinition:__ccEffort\?\{\.\.\.(' + ID
                                                             + rb'),effort:__ccEffort\}:\1,promptMessages:', d))
                                          and bool(re.search(rb'dispatch_class:' + ID + rb'\(\)\.optional\(\)', d)),
    # coordinator mode must be reachable interactively via its own opt-in (never
    # by borrowing CLAUDE_CODE_REMOTE, which also moves the auth token), and it
    # must no longer be the thing that disables fork — that would undo #12 for
    # anyone who turns the mode on
    # the switch must be parsed by the SAME helper that parses the variable
    # already gating this function — same identifier in both calls
    'interactive coordinator mode':       bool(re.search(
                                              rb'if\(!(' + ID + rb')\(process\.env\.CLAUDE_CODE_COORDINATOR_MODE\)\)return!1;'
                                              rb'if\(' + ID + rb'\(\)&&!' + ID + rb'\(\)&&!' + ID + rb'\.CLAUDE_CODE_REMOTE'
                                              rb'&&!\1\(process\.env\.CLAUDE_CODE_COORDINATOR_INTERACTIVE\)\)return!1;', d))
                                          # neither resolver shape may still gate fork on the mode
                                          and not re.search(
                                              rb'let ' + ID + rb'=' + ID + rb'\(\);if\(' + ID + rb'\(\)\)return"disabled";'
                                              rb'if\(' + ID + rb'\.CLAUDE_CODE_FORK_SUBAGENT===!1\)', d)
                                          and not re.search(
                                              rb'\{if\(' + ID + rb'\(\)\)return"disabled";'
                                              rb'if\(' + ID + rb'\.CLAUDE_CODE_FORK_SUBAGENT===!0\)return"env";', d),
    # a resumed session must not be able to drag the process out of the mode the
    # environment asked for; the bail sits before the first read of the live
    # predicate, so nothing is flipped and no warning is produced
    'env overrides resumed mode':         bool(re.search(
                                              rb'\{if\(!(' + ID + rb')\)return;'
                                              rb'if\((' + ID + rb')\(process\.env\.CLAUDE_CODE_COORDINATOR_FORCE\)\)return;'
                                              rb'let ' + ID + rb'=' + ID + rb'\(\),' + ID + rb'=\1==="coordinator";', d))
                                          # parsed by the same helper that gates the mode itself
                                          and _same_env_helper(d),
    # a row must carry what was actually spawned: the agent type and the model,
    # the latter falling back to the agent definition when the dispatch did not
    # override it (the normal case for the pinned vendor agents)
    'agent row shows type and model':     bool(re.search(
                                              rb'=\[(' + ID + rb')\.agentType,\1\.model\?\?\1\.selectedAgent\?\.model,'
                                              rb'.{0,80}?\]\.filter\(Boolean\)\.join\(" \\xB7 "\)', d, re.S)),
    # a search must be able to reach sessions the picker has not paged in yet:
    # while the search UI is open the page request fires unconditionally, and
    # the growth signal comes from the LOADED list (the filtered one stops
    # growing as soon as a page contains no match, which is the deadlock)
    'resume search pages in the tail': bool(re.search(
                                              rb'if\((' + ID + rb')==="search"\|\|(' + ID + rb')\+(' + ID + rb')>='
                                              rb'(' + ID + rb')\.length\)(' + ID + rb')\((' + ID + rb')\*3\)\},'
                                              rb'\[\2,\6,\4\.length,\5,\1,(' + ID + rb')\.length\]\),\7\.length===0', d)),
    # a NAMED dispatch becomes an in-process teammate, whose record is built
    # from a different literal than a plain local agent; the agent type has to
    # reach it through the spawn directive or the row shows only the model
    'named agent carries its type': bool(re.search(
                                              rb'planModeRequired:(' + ID + rb')\?\?!1,model:(' + ID + rb'),'
                                              rb'agentType:(' + ID + rb')\};', d))
                                          and bool(re.search(
                                              rb'type:"in_process_teammate",status:"running",identity:' + ID + rb','
                                              rb'prompt:(' + ID + rb')\.description\?\?' + ID + rb',model:' + ID + rb','
                                              rb'agentType:\1\.agentType,', d)),
    # a stream that dies after content arrived must be retried like any other
    # request and must never leave a truncated answer behind reported as a
    # success: budgets raised to 300, the shared backoff on the wait, and the
    # exhaustion path throws instead of emitting "…may be incomplete"
    'broken stream retried, not halved': bool(re.search(
                                              rb'=3,' + ID + rb'=\{value:0\},' + ID + rb'=300,' + ID + rb'=0,'
                                              rb'' + ID + rb'=0,' + ID + rb'=!1,' + ID + rb'=300,' + ID + rb'=0,', d))
                                          and bool(re.search(
                                              rb'if\((' + ID + rb')=null,!(' + ID + rb')\)await (' + ID + rb')\('
                                              rb'(' + ID + rb')\((' + ID + rb')\),(' + ID + rb')\);continue ', d))
                                          and bool(re.search(
                                              rb'&&' + ID + rb'===null&&' + ID + rb'<Math\.max\(' + ID + rb',300\)\)\{', d))
                                          # the synthetic "may be incomplete" message is no longer
                                          # emitted at the finalize site; the original error is thrown
                                          # the content-gate that blocked retry after a real block is gone
                                          and bool(re.search(
                                              rb'if\(' + ID + rb'===null&&\(' + ID + rb'\?' + ID + rb'<' + ID + rb':'
                                              rb'' + ID + rb'<' + ID + rb'\)\)\{', d))
                                          and not re.search(
                                              rb'if\(!' + ID + rb'&&' + ID + rb'===null&&\(' + ID + rb'\?'
                                              rb'' + ID + rb'<' + ID + rb':' + ID + rb'<' + ID + rb'\)\)\{', d)
                                          and not re.search(rb',error:"server_error"\}\),' + ID + rb'!=="credited"', d)
                                          and bool(re.search(
                                              rb'tengu_streaming_partial_finalized.{0,200}?!=="credited"\)'
                                              rb'' + ID + rb'="credited",.{0,300}?;throw (' + ID + rb')\}'
                                              rb'throw ' + ID + rb'\("tengu_streaming_fallback_to_non_streaming"', d, re.S)),
    # a session that ran on a proxy model must come back on it: the stock
    # verdict chain classifies every non-first-party id as unknown_family
    'session model restore keeps a proxy model': bool(re.search(
                                              rb'let ' + ID + rb'=process\.env\.ANTHROPIC_BASE_URL&&'
                                              rb'!/\^claude/i\.test\(' + ID + rb'\)\?void 0:'
                                              rb'!\(' + ID + rb'\.has\(', d)),
    # judge part 1: the current turn (thinking included) is stashed by
    # tool_use id, because the message reaching the executor carries the
    # tool_use block alone
    'judge stashes the current turn': bool(re.search(
                                              rb'\.streamingToolExecutor\.addTool\(' + ID + rb',' + ID + rb','
                                              rb'\(process\.env\.CLAUDE_JUDGE\?'
                                              rb'\(\(globalThis\.__ccJudgeTurn\?\?=new Map\(\)\)', d)),
    # judge part 2: consulted before a subagent dispatch, off unless
    # CLAUDE_JUDGE is set, fail-open on every path
    'judge consulted before dispatch': bool(re.search(
                                              rb'if\(process\.env\.CLAUDE_JUDGE&&\(' + ID + rb'\.name==="Agent"'
                                              rb'\|\|' + ID + rb'\.name==="Task"\)&&' + ID +
                                              rb'\?\.agentContext\?\.agentType==="main"\)\{', d)),
    # a WARN never reaches the model and a fail-open skip leaves no trace,
    # so both are only observable through the append-only journal
    'judge journals every consultation': bool(re.search(
                                              rb'appendFile\(__jdir\+"/journal\.jsonl"', d)),
    # a journal line has to say which switch armed enforcement and what the
    # consultation cost — without both, `block` and `block_not_enforced` are
    # separable only by guessing at the environment of a past run
    'judge journal records cost and switch': bool(re.search(
                                              rb'ms:Date\.now\(\)-__t0,sw:process\.env\.CLAUDE_JUDGE\|\|null', d))
                                          and bool(re.search(
                                              rb'en:__en\?\(process\.env\.CLAUDE_JUDGE==="enforce"\?'
                                              rb'"env":"config"\):null', d)),
    # the journal line clips the verdict and holds none of the material the
    # judge saw, so the request/response pair is kept beside it per consultation
    # a text prefix cannot carry provenance — content shares its namespace and
    # any line starting with 'user: ' forges a label, so the transcript goes
    # over as a JSON array whose `src` cannot be reached from inside `text`
    # a silent fail-open under load is indistinguishable from blanket approval,
    # so a failed consultation is retried once on a short tail before giving up
    # a 2xx whose budget went entirely into reasoning returns no verdict, and
    # silence reads as consent — that must advance the chain like any failure
    # the body template carries its own ceiling, so config.json's max_tokens is
    # a silent no-op without this override — that silence once ate a cancellation
    'judge budget has one home': bool(re.search(
                                              rb'let __mt=__e\.max_tokens\|\|__cfg\.max_tokens;'
                                              rb'if\(__mt\)__obj\.max_tokens=Number\(__mt\)', d)),
    'judge treats a verdictless reply as a failure': bool(re.search(
                                              rb'__v=__pv\(__raw\);if\(__v\)break;', d))
                                          and bool(re.search(
                                              rb'__errs\.push\(__jm\+": empty verdict"\)', d)),
    # each rung of the ladder carries its own deadline and transcript size,
    # because the reasons a rung fails differ
    'judge ladder rungs carry their own limits': bool(re.search(
                                              rb'__raw=await __call\(__e\.context_chars\?'
                                              rb'__cut\(Number\(__e\.context_chars\)\):__ctx,'
                                              rb'Number\(__e\.timeout_ms\|\|__tmo\),__e\)', d)),
    'judge retries a failed consultation': bool(re.search(
                                              rb'for\(let __i=0;__i<__mdls\.length;__i\+\+\)\{', d))
                                          and bool(re.search(
                                              rb'__jtry=__mdls\.length\+1;__jm=__e\.model;', d)),
    # a project restates the RULES for itself; the judge still knows nothing
    # about what the project is — the nearest .claude/judge above cwd layers over
    # the global one
    'judge takes a project layer': bool(re.search(
                                              rb'if\(__has\.some\(Boolean\)\)\{if\(__c!==__dir\)'
                                              rb'__pdir=__c;break\}', d))
                                  and bool(re.search(
                                              rb'if\(__pdir\)try\{__cfg=\{\.\.\.__cfg,\.\.\.JSON\.parse\(', d)),
    'judge context is structured, not prefixed': bool(re.search(
                                              rb'return\{src:__role,text:__bt\}\}\)\.filter\(Boolean\)', d))
                                          and bool(re.search(
                                              rb'let __cut=\(__n\)=>\{let __a=__arr\.slice\(\),'
                                              rb'__s=JSON\.stringify\(__a\);', d)),
    # the main loop is told the RULE, not the judge: a cancelled dispatch was
    # once read as the routing gate firing and blindly retried
    'dispatch-cancellation rule reaches the main loop': bool(re.search(
                                              rb'\.\.\.\(process\.env\.CLAUDE_JUDGE&&[A-Za-z_$][\w$]*'
                                              rb'\?\.agentContext\?\.agentType==="main"\?\['
                                              rb'"A subagent dispatch may be reviewed', d)),
    # a record has to be REPLAYABLE, so it carries the endpoint, the sending
    # process, and what every rung was fed — not just the body that answered
    'judge keeps the full consultation': bool(re.search(
                                              rb'\{\.\.\.__base,http:__jst,url:__jurl,pid:process\.pid,'
                                              rb'cwd:process\.cwd\(\),attempts:__jatt,request:__rq,'
                                              rb'response:__jres\}', d))
                                          and bool(re.search(
                                              rb'__jatt\.push\(__a\)', d)),
    # ported from tweakcc, whose own patch set cannot apply on this build
    # a bare 'var X=500' matches six unrelated constants in the PRISTINE binary,
    # so the check has to reach the debounce site first and then assert on the
    # constant that site actually names
    'statusline throttle raised': (lambda mm: bool(mm) and bool(re.search(
                                              rb'var ' + mm.group(1) + rb'=500\b', d)))(
                                          re.search(rb'\.setTimeout\(\(\)=>\{this\.#' + ID
                                                    + rb'=null,this\.#' + ID + rb'\(\)\},('
                                                    + ID + rb')\)\}', d)),
    'root/sudo refusal neutralised': not re.search(
                                              rb'cannot be used with root/sudo privileges'
                                              rb' for security reasons"\),process\.exit\(1\)', d),
    'CLAUDE.md alternates tried': bool(re.search(
                                              rb'"AGENTS\.md","GEMINI\.md"', d)),
}
for name, ok in checks.items():
    print(f"  [{'OK' if ok else 'FAIL'}] {name}")
sys.exit(0 if all(checks.values()) else 1)
PY

# A pattern check proves the injected BYTES are present; it does not prove the
# bundle still PARSES. One mis-escaped newline inside an injected string literal
# left every check green while the image died on "SyntaxError: Unexpected EOF"
# (measured 2026-08-20). So run the image and require a real version line — and
# capture the status separately: `echo "$(... | head -1)"` throws the exit code
# away and reports a dead binary as a success.
set +e
SMOKE_OUT="$("$BIN" --version 2>&1)"
SMOKE_RC=$?
set -e
echo "Version: $(printf '%s\n' "$SMOKE_OUT" | head -1)"
if [[ $SMOKE_RC -ne 0 || "$SMOKE_OUT" != *"Claude Code"* ]]; then
  echo "FATAL: the patched image does not run — leaving the launcher alone" >&2
  exit 1
fi

# --- 5b. only now may the launcher point at the new build ----------------------
# The installer deliberately leaves ~/.local/bin/claude on the PREVIOUS version:
# between "pristine installed" and "patched + verified" there is about a minute,
# and a session started inside it runs unpatched — claude-* traffic then goes to
# the local proxy with the subscription OAuth bearer and the session dies on
# "unknown provider for model claude-opus-5" (observed 2026-08-18). The checks
# above are the gate: `set -e` aborts before this line if any of them failed.
if [[ $DO_UPDATE -eq 1 ]]; then
  python3 "$HERE/claude_patch.py" --repoint "$BIN"
fi

# --- 6. cleanup previous versions ---------------------------------------------
# After a successful --update, remove all older version binaries and their .orig
# backups. Keep only the current version and its .orig (for emergency restore).
# Config backups: keep only the 3 most recent.
if [[ $DO_UPDATE -eq 1 ]]; then
  VERSIONS_DIR="$(dirname "$BIN")"
  CURRENT_VER="$(basename "$BIN")"
  echo
  echo "==> Cleaning up previous versions"
  # A version a live session is still executing is kept: unlinking a running
  # binary leaves the process on its now-nameless inode, and a bun executable
  # reads embedded assets back out of its own file. Those sessions release it
  # on exit, so the next --update collects it.
  # Enumerate pids and ask about each: `lsof -c claude` returns nothing on
  # macOS for these processes (verified 2026-08-12, which is how a running
  # 2.1.226 got unlinked), while `lsof -p <pid>` reports the text image fine.
  IN_USE="$(for p in $(pgrep -x claude 2>/dev/null); do
      lsof -p "$p" 2>/dev/null | awk '$4=="txt"{print $NF}'
    done | sort -u)"
  for old in "$VERSIONS_DIR"/2.1.*; do
    base="$(basename "$old")"
    [[ "$base" == "$CURRENT_VER" || "$base" == "$CURRENT_VER.orig" ]] && continue
    if grep -qxF "$old" <<<"$IN_USE"; then
      echo "  kept (a running session is executing it): $base"
      continue
    fi
    rm -v "$old"
  done
  prune_config_backups
fi

# --- 7. the model data the patches read --------------------------------------
# Patches #8 and #10 only teach the binary WHERE to look: customModelCosts and
# customModelContextWindows in ~/.claude.json. What is IN those keys is a
# snapshot taken by set-model-costs.py, and the proxy gains models between runs
# — each one then bills at the $5/$25 Opus fallback and is pinned to a 200K
# window until somebody remembers to re-sync. That is exactly how glm-5.3 sat
# unpriced with the wrong window for a day (2026-08-15). Patching is the one
# moment this install is already being touched, so the data is refreshed here
# and the two halves stop drifting apart.
#
# Never fatal. The sync needs the proxy up (for its model listing) and
# models.dev reachable; neither has anything to do with whether the binary was
# patched correctly, so a failure is a warning and the old numbers stay.
if [[ "${CLAUDE_PATCH_SKIP_MODELS:-0}" != "1" && -f "$COSTS_SYNC" ]]; then
  echo
  echo "==> Refreshing model prices and context windows"
  MODELS_LOG="$(mktemp)"
  # No pipe on the command itself: `python3 ... | grep` would report grep's exit
  # code and a failed sync would read as success. -u so that the two streams
  # land in the log in the order they were written.
  if python3 -u "$COSTS_SYNC" >"$MODELS_LOG" 2>&1; then
    grep -E '^(Backed up|Wrote) ' "$MODELS_LOG" || true
    echo "  (a running claude keeps the old numbers — the config is read once per process)"
    prune_config_backups
  else
    echo "WARNING: model sync failed; prices and context windows are unchanged."
    tail -3 "$MODELS_LOG" | sed 's/^/  /'
  fi
  rm -f "$MODELS_LOG"
fi

echo
echo "Done. Re-run this script after ANY of:"
echo "  * a Claude Code update      (bash $(basename "$0") --update)"
echo "  * running tweakcc's TUI or --apply (it restores from backup and drops our patches)"
echo "  * the proxy gaining a model (or just: bash $(basename "$0") --only-ours)"
echo "Restore the pristine binary with:  cp \"$BIN.orig\" \"$BIN\""
