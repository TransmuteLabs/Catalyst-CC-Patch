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

# One cache entry per pinned SHA, ~490 MB each, and nothing ever removed them:
# nine pins from a single afternoon of bisecting a locator came to 4.3 GB. Keep
# the pin in use plus the two most recent others -- enough to step a bump back
# without a two-minute rebuild -- and drop the rest. Nothing removed here is
# lost: an entry is a content-addressed fetch of a commit GitHub still serves,
# rebuilt on demand by ensure_tweakcc.
prune_tweakcc_cache() {
  local keep="$1" entry
  [[ -d "$CATALYST_TWEAKCC_CACHE" ]] || return 0
  # Iterated by GLOB, not by parsing `ls`. A cache entry whose name contains a
  # newline splits into two lines of `ls` output, and those two lines then name
  # two OTHER real entries -- so the malformed directory survives and two good
  # ones are deleted. Restricting the domain to what ensure_tweakcc actually
  # creates (a 40-character hex commit id) closes that and the `..` class at
  # once: anything else in this directory is left alone rather than guessed at.
  #
  # The in-use pin is touched first so that mtime order reflects USE. Excluding
  # it by name protects this run; touching it also protects a CONCURRENT run,
  # which excludes its own pin but would otherwise be free to select ours.
  if [[ -d "$CATALYST_TWEAKCC_CACHE/$CATALYST_TWEAKCC_SHA" ]]; then
    touch "$CATALYST_TWEAKCC_CACHE/$CATALYST_TWEAKCC_SHA"
  fi
  local -a entries=()
  while IFS= read -r entry; do
    entries+=("$entry")
  done < <(
    cd "$CATALYST_TWEAKCC_CACHE" 2>/dev/null || exit 0
    for entry in [0-9a-f][0-9a-f]*; do
      [[ -d "$entry" && ${#entry} -eq 40 && "$entry" =~ ^[0-9a-f]{40}$ ]] || continue
      [[ "$entry" == "$CATALYST_TWEAKCC_SHA" ]] && continue
      printf '%s\t%s\n' "$(stat -f '%m' "$entry" 2>/dev/null || echo 0)" "$entry"
    done | sort -rn | cut -f2-
  )
  (( ${#entries[@]} > keep )) || return 0
  echo "==> Cleaning old unpacker builds (keeping the pin in use + $keep most recent)"
  for entry in "${entries[@]:keep}"; do
    rm -rf "${CATALYST_TWEAKCC_CACHE:?}/$entry" && echo "    removed ${entry:0:12}"
  done
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

# --- which tweakcc unpacks the image -----------------------------------------
# Claude Code 2.1.242 split the bundle from one 28 MB module into an ESM entry
# plus ~1400 chunks. Published tweakcc (4.3.3 and every release after it as of
# this writing) extracts the entry ALONE, so all 25 locators search a 20 KB stub
# and the whole set fails at once — a failure that reads like 25 broken patches
# rather than one broken unpacker, which is exactly how it was first misread.
# Our fork joins the entry with its chunks; on 2.1.241 and earlier its selection
# is a single module and it behaves identically to the published one.
#
# This is the second time the unpacker, not the patches, was the thing that
# broke: 4.3.2 could not read the container Claude Code ships from 2.1.231 on
# (bun bumped, the binary grew ~5 MB) and aborted with "Failed to extract
# JavaScript from native installation" before any patch was evaluated. That one
# was fixable by raising a version floor; this one was not, which is why there
# is a fork.
#
# The fork is pinned BY COMMIT, never by branch. The unpacker decides what every
# locator sees, so "whatever main happens to be today" would silently make two
# runs of this script incomparable. A commit SHA is content-addressed, so the
# pin is its own integrity check: GitHub cannot serve a different tree under it.
# Bump it deliberately, the way any dependency is bumped.
CATALYST_TWEAKCC_REPO="${CATALYST_TWEAKCC_REPO:-TransmuteLabs/Catalyst-tweakcc}"
CATALYST_TWEAKCC_SHA="${CATALYST_TWEAKCC_SHA:-d5ced06304cf537ebee7204e72fcc62acada9d0e}"
CATALYST_TWEAKCC_CACHE="${CATALYST_TWEAKCC_CACHE:-$HOME/.cache/catalyst-tweakcc}"

# TWEAKCC_LOCAL is the development escape hatch: point it at a built
# dist/index.mjs to try an unpacker change before it is pushed and pinned. It is
# an EXPLICIT opt-in and it announces itself — an implicit "use the sibling
# checkout if one happens to be there" would make the run depend on the shape of
# somebody's disk.
ensure_tweakcc() {
  if [[ -n "${TWEAKCC_LOCAL:-}" ]]; then
    [[ -f "$TWEAKCC_LOCAL" ]] || { echo "ERROR: TWEAKCC_LOCAL=$TWEAKCC_LOCAL does not exist"; exit 1; }
    TWEAKCC=(node "$TWEAKCC_LOCAL")
    echo "Unpacker: local build via TWEAKCC_LOCAL ($TWEAKCC_LOCAL)"
    return
  fi

  local dir="$CATALYST_TWEAKCC_CACHE/$CATALYST_TWEAKCC_SHA"
  if [[ ! -f "$dir/dist/index.mjs" ]]; then
    echo "==> Fetching the unpacker: $CATALYST_TWEAKCC_REPO @ ${CATALYST_TWEAKCC_SHA:0:12}"
    # Built in .tmp and renamed into place only once dist/index.mjs exists, so an
    # interrupted fetch can never leave a cache entry that looks complete.
    rm -rf "$dir.tmp"
    mkdir -p "$dir.tmp"
    # No `curl | tar`: a pipe reports the LAST stage's exit code, and a failed
    # download would read as a successful extraction of nothing.
    curl -fsSL -o "$dir.tmp/src.tar.gz" \
      "https://codeload.github.com/$CATALYST_TWEAKCC_REPO/tar.gz/$CATALYST_TWEAKCC_SHA" \
      || { echo "ERROR: could not fetch $CATALYST_TWEAKCC_REPO @ $CATALYST_TWEAKCC_SHA"; exit 1; }
    tar -xzf "$dir.tmp/src.tar.gz" -C "$dir.tmp" --strip-components=1 \
      || { echo "ERROR: could not unpack the unpacker tarball"; exit 1; }
    rm -f "$dir.tmp/src.tar.gz"
    ( cd "$dir.tmp" \
      && npx -y pnpm@latest install --frozen-lockfile \
      && npx -y pnpm@latest run build ) \
      || { echo "ERROR: unpacker build failed in $dir.tmp"; exit 1; }
    [[ -f "$dir.tmp/dist/index.mjs" ]] \
      || { echo "ERROR: unpacker build produced no dist/index.mjs"; exit 1; }
    rm -rf "$dir"
    mv "$dir.tmp" "$dir"
    echo "Unpacker cached in $dir"
  fi

  TWEAKCC=(node "$dir/dist/index.mjs")
  echo "Unpacker: $CATALYST_TWEAKCC_REPO @ ${CATALYST_TWEAKCC_SHA:0:12}"
  prune_tweakcc_cache 2
}
ensure_tweakcc

# --- 1. let the user pick tweakcc's patches ----------------------------------
if [[ $CONFIGURE -eq 1 ]]; then
  echo "==> Opening tweakcc's UI — pick the patches you want, save, and quit."
  "${TWEAKCC[@]}" || true
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
  if "${TWEAKCC[@]}" --list-patches >/dev/null 2>&1; then
    echo "==> Applying tweakcc's configured patches"
    # A patch of tweakcc's that cannot find its site prints a ✗ row and marks
    # itself failed -- and then the CLI exits 0 anyway. Nothing downstream looks
    # at it either: none of our checks below cover tweakcc's own output. So a
    # patch could stop applying entirely and the build would still be declared
    # good, with the feature simply gone. That is the same silence the interface
    # gate exists to end, except the gate only sees a CRASH: a clean skip renders
    # the stock interface and passes it.
    #
    # Every patch in the config is there because it is wanted, so a ✗ is a
    # failure of the build. The escape hatch is for deliberately running against
    # a version where something is known not to apply yet.
    TWEAKCC_OUT="$(mktemp)"
    set +e
    "${TWEAKCC[@]}" --apply -y 2>&1 | tee "$TWEAKCC_OUT"
    TWEAKCC_RC=${PIPESTATUS[0]}
    set -e
    if [[ $TWEAKCC_RC -ne 0 ]]; then
      echo "NOTE: tweakcc --apply reported a problem (no config yet?); continuing with ours only."
    elif [[ "${CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES:-0}" != "1" ]] \
         && grep -qE '^    ✗ |applied with some failures' "$TWEAKCC_OUT"; then
      echo "FATAL: a configured tweakcc patch did not apply:" >&2
      grep -E '^    ✗ ' "$TWEAKCC_OUT" | sed 's/^ */  /' >&2
      grep -E '^patch: ' "$TWEAKCC_OUT" | sed 's/^/  /' >&2
      echo "  Set CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES=1 to build anyway." >&2
      rm -f "$TWEAKCC_OUT"
      exit 1
    fi
    rm -f "$TWEAKCC_OUT"
  fi
fi

# --- 3. our patches, ALWAYS after tweakcc -------------------------------------
# The injected code is parsed BEFORE the build: the patcher is syntactically
# intact on its own, while a program glued from hundreds of string pieces may
# not parse at all. The check must be CALLED: while it was merely shipped in
# the kit, it was broken by two commits and stayed silent.
echo "==> Разбор вклеиваемого кода"
node "$(dirname "$0")/tools/emit-check.js"

echo "==> Applying our multi-provider patches"
"${TWEAKCC[@]}" adhoc-patch \
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
python3 - "$BIN" "$OUR_PATCH" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
src = open(sys.argv[2], encoding='utf-8').read()
ID = rb'[A-Za-z_$][\w$]*'

def _same_env_helper(d):
    # The two edited sites live megabytes apart, so sameness cannot be asserted
    # with one backreference: name the helper at the gate, then look for that
    # exact name at the override.
    m = re.search(rb'if\(!(' + ID + rb')\(process\.env\.CLAUDE_CODE_COORDINATOR_MODE\)\)return!1;', d)
    if not m:
        return False
    return bool(re.search(re.escape(m.group(1)) + rb'\(process\.env\.CLAUDE_CODE_COORDINATOR_FORCE\)', d))

def _judge_catch_scope(d):
    # The judge's failure path runs only when something is broken, so a typo in
    # it lives unnoticed: the name __pdir was read from a neighboring block and
    # crashed with ReferenceError BEFORE the journal write — the dispatch got
    # "__pdir is not defined", the journal got nothing. The check is
    # structural: every name the catch reads must be declared ABOVE the try.
    m = re.search(rb'let __t0=Date\.now\(\),(.{0,900}?)__jdir=', d, re.S)
    if not m:
        return False
    # __o is a parameter of the core function itself, not a declaration inside
    # the body: it is always in scope, and requiring its declaration would mean
    # requiring the impossible. It is taken from the signature, not written in
    # as a constant.
    sig = re.search(rb'globalThis\.__ccProbe\?\?=async function\((__\w+)\)', d)
    declared = set(re.findall(rb'(__\w+)\s*=', m.group(1))) | {b'__jdir', b'__cut'}
    if sig:
        declared |= {sig.group(1)}
    c = re.search(rb'\}\}catch\(__e\)\{if\(__e&&__e\.__ccJudgeBlock\)throw __e;(.{0,1400}?)\}\}', d, re.S)
    if not c:
        return False
    body = c.group(1)
    local = set(re.findall(rb'let (__\w+)', body)) | {b'__e', b'__jlog', b'__ccJudgeBlock'}
    used = set(re.findall(rb'(__\w+)', body))
    return not (used - declared - local)

def _captured_names(src):
    # Names captured by a regex, and everything built from them.
    n = set(re.findall(r'const (\w+) = [^;\n]*\[\d+\]', src))
    for _ in range(3):
        for m in re.finditer(r'const (\w+) =\s*(`[^`]*`)', src):
            if any(g in n for g in re.findall(r'\$\{(\w+)\}', m.group(2))):
                n.add(m.group(1))
    return n

def _escaped_interpolations(src):
    # A minified name can contain `$`: in 2.1.239 the session matcher is called
    # `$jS`. In a regex SOURCE `$` is the end-of-line anchor, so a name injected
    # bare never matches, and the locator fails not because the build changed
    # but because the minifier picked a different letter. In the REPLACEMENT
    # string the same `$` reads as a group reference and substitutes someone
    # else's capture — silently. The CLASS is checked: no captured name may
    # stand in a template or replacement without rxEsc/repEsc. On the pre-fix
    # source this catches 12 places.
    names, lines, bad = _captured_names(src), src.split('\n'), []
    for i, ln in enumerate(lines):
        hits = [x for x in names if '${%s}' % x in ln]
        if not hits:
            continue
        for j in range(i, max(-1, i - 6), -1):
            t = lines[j]
            if 'applied.push(' in t or 'fail(' in t:
                break
            if 'new RegExp(' in t or 'js.replace(' in t:
                bad += hits
                break
    return not bad

def _judge_both_shapes(src):
    # 2.1.239 moved the tool call behind an adapter: `e.call(w,ctx,…)` became
    # `hii(e).execute(w,ctx,…)`, where `hii(e) = e.executor ?? {execute:…}`.
    # The judge locator must hold BOTH shapes and latch onto the tool itself,
    # not the wrapper: the tool has `.name`, the adapter does not.
    i = src.find("step('22 judge consulted")
    j = src.find("step('23", i)
    blk = src[i:j] if i >= 0 and j > i else ''
    return (r'\\.call|' in blk) and (r'\\)\\.execute' in blk) and ('m[2] ?? m[3]' in blk)

def _session_memory_ungated(d):
    """Both session-memory gates are gone, checked WITHOUT naming the flags.

    Patch step 7 matches these gates by shape rather than by flag name, so a
    check pinned to "tengu_passport_quail" would go green on a bundle whose
    renamed flag still gates extraction -- weaker than the step it verifies,
    which is the wrong way round for a check.

    The extraction gate is scoped to the entry point the anchor names: bundle
    wide this exact form has three instances on 2.1.246 (hawthorn_steeple and
    vscode_feedback_survey are unrelated), and inside the window it is unique.
    The extract-mode predicate shape is unique bundle wide, so it needs no
    scope.

    The predicate half is checked POSITIVELY. Absence of the gated shape alone
    cannot tell "forced" from "reshaped upstream", and the second reads as
    success while session memory stays off -- the same one-sided weakness this
    docstring warns about for flag names. The end state is exactly one function
    of the forced shape `function X(){return!Y()||Z("tengu_...",!1)}`: the flag
    guard gone, the product's own interactivity condition kept. Measured on
    pristine 2.1.233 / 240 / 242 / 246: gated shape 1, forced shape 0.
    """
    anchor = b'querySource:"extract_memories",forkLabel:"extract_memories"'
    at = d.find(anchor)
    if at == -1:
        return False
    window = d[at:at + 8000]
    if re.search(rb'if\(!' + ID + rb'\("tengu_[a-z0-9_]+",!1\)\)\s*return[^;]*;', window):
        return False
    predicate = (rb'function ' + ID + rb'\(\)\{if\(!' + ID + rb'\("tengu_[a-z0-9_]+",!1\)\)return!1;'
                 rb'return!' + ID + rb'\(\)\|\|' + ID + rb'\("tengu_[a-z0-9_]+",!1\)\}')
    if re.search(predicate, d):
        return False
    forced = (rb'function ' + ID + rb'\(\)\{return!' + ID + rb'\(\)\|\|'
              + ID + rb'\("tengu_[a-z0-9_]+",!1\)\}')
    return len(re.findall(forced, d)) == 1


def _stream_finalize_ok(d):
    """The exhaustion path must never finalize a half answer as a success.

    Which shape proves that depends on the build, because 2.1.246 added a
    recovery the earlier releases have no equivalent of:

      - no truncation marker in the image (233..242 in range): there is nothing
        downstream that could recover from the marker, so the yield is gone and
        the original error is thrown unconditionally.
      - marker present (246): the yield survives ONLY for the lane whose reader
        can act on it -- a non-interactive main-loop session, where the product
        suppresses the marker from the output and nudges the model to resume
        from the truncation. Every other lane still throws.

    Asserting only the first shape would fail the second, and asserting only
    "no marker is emitted" would pass a build where the yield came back
    unguarded, which is the stock half answer.
    """
    cond = (rb'\((' + ID + rb')\.isNonInteractiveSession&&\1\.querySource\?\.startsWith\('
            rb'"repl_main_thread"\)&&\([^()]{0,80}\)\)')
    if b'truncatedAfterOutput' not in d:
        if re.search(rb',error:"server_error"\}\),' + ID + rb'!=="credited"', d):
            return False
        return bool(re.search(
            rb'tengu_streaming_partial_finalized.{0,240}?!=="credited"\)'
            + ID + rb'="credited",.{0,300}?;throw ' + ID + rb'\}'
            rb'throw ' + ID + rb'\("tengu_streaming_fallback_to_non_streaming"', d, re.S))
    # An UNGUARDED marker yield is the stock half answer -- check first, so a
    # build that merely kept the stock site cannot pass on the clauses below.
    if re.search(rb',yield ' + ID + rb'\(\{content:[^;]{0,1400}?,error:"server_error"', d):
        return False
    if not re.search(rb'tengu_streaming_partial_finalized.{0,240}?,' + cond + rb'\?yield ', d, re.S):
        return False
    if not re.search(rb';if\(!' + cond + rb'\)throw ' + ID + rb';break ' + ID + rb'\}throw '
                     + ID + rb'\("tengu_streaming_fallback_to_non_streaming"', d):
        return False
    return True


def _bypass_no_immunity(d):
    # The registry marks two circuit breakers immune to full-bypass mode:
    #   dangerousRemoval:    {bypassImmune:!0, classifierRouted:!0}
    #   isolatePeerMachines: {bypassImmune:!0, classifierRouted:!1}
    # Step 27 lifts ONLY the first. isolatePeerMachines keeps one machine's
    # session from acting on another through a peer channel; a session holding a
    # full-bypass key is exactly the session that should still stop there.
    #
    # Three facts, none of them leaning on a minified name. From 2.1.242 the
    # bundle is code-split ESM: the predicate exports under a chunk-local name
    # and every consumer imports it under a name of its own, so no single name
    # spans both sides and counting uses across the image proves nothing.
    #
    # 1. The STOCK two-argument call must be gone in its exact shape.
    if re.search(rb'\?' + ID + rb'\(' + ID + rb'\.decisionReason,' + ID + rb'\):void 0;', d):
        return False
    # 2. The narrowed predicate must stand in its place -- absence of the stock
    #    shape alone cannot tell "narrowed" from "branch deleted outright", and
    #    the second is what this check previously accepted.
    if not re.search(
        rb'\?' + ID + rb'\(' + ID + rb'\.decisionReason,\(__ccbr\)=>'
        rb'__ccbr\.circuitBreaker!=="dangerousRemoval"&&' + ID + rb'\(__ccbr\)\):void 0;', d):
        return False
    # 3. The breaker the narrowing names must still exist, and the one whose
    #    immunity is deliberately kept must still be marked immune. A rename
    #    upstream would otherwise turn this step into a silent no-op (case 1) or
    #    silently drop the guard we chose to keep (case 2).
    if b'dangerousRemoval:{bypassImmune:!0' not in d:
        return False
    if b'isolatePeerMachines:{bypassImmune:!0' not in d:
        return False
    return len(re.findall(rb'\.decisionReason,', d)) >= 1


def _probe_hooks_both_sites(d):
    """The probe block must sit in front of EVERY tool-dispatch site.

    There are two on 2.1.233 / 240 / 242 / 246, both in the same bundle module:
    the main dispatcher, and the inner executor the REPL sandbox hands to
    model-written JavaScript. The REPL's tool map excludes exactly one tool --
    REPL itself -- so the dispatch tool is reachable from inside a REPL program,
    and for as long as only the main site was hooked, a subagent started that
    way reached neither the judge nor the fleet counter. In a mechanism that
    fails CLOSED, an unhooked path is not a gap in coverage, it is a silent
    pass, so the site count is asserted rather than assumed.

    Counting blocks alone would accept two blocks in front of the SAME site, so
    each block is identified by the call that follows it: the REPL one carries
    the sandbox's `fileReadingLimits`, the main one closes its context literal
    straight after `userModified`.

    The cores must also be byte-identical. They are emitted from one string and
    reference no call-site name, so any difference means an edit reached one
    copy and not the other -- the drift the single-core decomposition exists to
    prevent.
    """
    ends = [mm.end() for mm in re.finditer(rb'/\*__ccProbe1\*/', d)]
    starts = [mm.start() for mm in re.finditer(rb'/\*__ccProbe0\*/', d)]
    if len(ends) != 2 or len(starts) != 2:
        return False
    cores = [d[st:d.index(b'if(process.env.CLAUDE_JUDGE', st)] for st in starts]
    if len(set(cores)) != 1 or len(cores[0]) < 15000:
        return False
    repl = main = 0
    for e in ends:
        tail = d[e:e + 400]
        if re.match(rb'(?:let )?' + ID + rb'=await [\s\S]{0,160}?'
                    rb'fileReadingLimits:\{maxTokens:1/0,maxSizeBytes:268435456\}', tail):
            repl += 1
        elif re.match(rb'' + ID + rb'=await [\s\S]{0,160}?userModified:' + ID
                      + rb'\.userModified\?\?!1\},', tail):
            main += 1
    return repl == 1 and main == 1


# Every check below that COUNTS occurrences counts them per emitted block: the
# numbers were measured when the block existed once, and they say something
# about the shape of one probe, not about how many dispatch sites it guards.
# Emitting it at a second site would double each of them, and a doubled `== 6`
# no longer tells 3+3 from 2+4. So the site count is proved above, once, and
# the duplicate blocks are dropped here -- the checks keep both their numbers
# and their meaning. Removal only takes text away, so every "is absent" check
# is unaffected by it.
_probe_full = d
_probe_dup = re.findall(rb'/\*__ccProbe0\*/[\s\S]*?/\*__ccProbe1\*/', d)
for _b in _probe_dup[1:]:
    d = d.replace(_b, b'', 1)

checks = {
    'routing (claude-* -> subscription)': b'baseURL:/^claude/i.test(' in d,
    'captured names are escaped into patterns': _escaped_interpolations(src),
    'judge anchors both tool-call shapes':      _judge_both_shapes(src),
    'full bypass keeps peer-machine immunity': _bypass_no_immunity(d),
    'agent model schema relaxed':         b'.enum(["sonnet","opus","haiku","fable"])' not in d,
    'gateway discovery without token':    bool(re.search(rb'ANTHROPIC_AUTH_TOKEN,' + ID + rb'=' + ID + rb'\(\);if\(!1&&!', d)),
    # Two-sided: the stock branch must be gone AND the widened one must still
    # test the "inherit" sentinel. The negative alone passed a build where the
    # sentinel test had been dropped from the ternary -- `"inherit"` is truthy,
    # so it reached the model-name parser and produced a badge from a parse of
    # the sentinel.
    'subagent model badge':               not re.search(rb'else if\((' + ID + rb')\.model&&\1\.model!=="inherit"\)', d)
                                          and bool(re.search(
                                              rb',' + ID + rb'=(' + ID + rb')\.model&&\1\.model!=="inherit"\?'
                                              + ID + rb'\(\1\.model\):' + ID + rb';', d)),
    # The postcondition is that the chevron's colour is CONDITIONAL on the
    # loading state -- which colour is the user's config. Pinning "success"
    # made this check stricter than the step it verifies: step 6 became
    # colour-agnostic when tweakcc started writing this edit first, so setting
    # chevronIdleThemeColor to anything else would pass the step and fail here.
    'input chevron colour':               bool(re.search(rb'color:' + ID + rb'\?' + ID + rb':"[^"]*",dimColor:!1', d)),
    'session memory forced on':           _session_memory_ungated(d),
    # every override read must now be a merge: `{...X().additionalModelCostsCache,...X().customModelCosts}`
    'custom model costs':                 len(re.findall(rb'\{\.\.\.' + ID + rb'\(\)\.additionalModelCostsCache,\.\.\.' + ID + rb'\(\)\.customModelCosts\}', d))
                                          == len(re.findall(ID + rb'\(\)\.additionalModelCostsCache', d)) > 0,
    # every gateway-model filter must be followed by the de-disguise map
    'gateway model de-disguise':          len(re.findall(rb'\.map\(\(' + ID + rb'\)=>' + ID + rb'\.id\.startsWith\("claude-fable-5-dd-"\)', d))
                                          == len(re.findall(rb'/\(claude\|anthropic\)/i\.test\(', d)) > 0,
    # One site, two lookups (raw id, then canonical name), read through a
    # guarded local at the HEAD of the function. Counting `().customModelContext
    # Windows?.[` was satisfied by the old tail placement, where four earlier
    # returns shadowed the override, and by an unguarded config read that throws
    # before the config settles -- so it proved neither of the things that matter.
    'per-model context window':           bool(re.search(
                                              rb'\{let __ccw;try\{__ccw=' + ID + rb'\(\)\.customModelContextWindows\}catch\{\}'
                                              rb'let __ccv=__ccw\?\.\[(' + ID + rb')\]\?\?__ccw\?\.\['
                                              + ID + rb'\(' + ID + rb'\(\1\)\)\];'
                                              rb'if\(typeof __ccv==="number"&&__ccv>0\)return __ccv;', d))
                                          and not re.search(rb'\?\?' + ID + rb'\(\)\.customModelContextWindows', d),
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
    # The model-supplied effort must be DECLARED (schema), CARRIED (destructured
    # once in the call handler) and VALIDATED before it reaches the definition.
    # Counting two `effort:__ccEffort` passed the version that attached the raw
    # string straight through, which is the defect: an unvalidated model-supplied
    # value reaching an internal effort layer. Now the only bare use is the
    # destructure, and the attach site must normalise the product's own aliases
    # and drop anything outside its vocabulary.
    'dispatch carries effort':            len(re.findall(rb'effort:__ccEffort', d)) == 1
                                          and bool(re.search(
                                              rb'=\{agentDefinition:\(\(\(\)=>\{let __ccLvl=__ccEffort==="med"\?"medium":'
                                              rb'__ccEffort==="ultracode"\?"xhigh":__ccEffort;return __ccLvl&&'
                                              rb'\["low","medium","high","xhigh","max"\]\.includes\(__ccLvl\)\?'
                                              rb'\{\.\.\.(' + ID + rb'),effort:__ccLvl\}:\1\}\)\(\)\),promptMessages:', d))
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
    # two shapes, because 2.1.242 rewrote the effect: upstream added the loaded
    # length to the dependencies (closing the deadlock the same way) and then
    # capped the scan with a give-up counter, which the patch now steps over
    # while the search UI is open
    'resume search pages in the tail': bool(re.search(
                                              rb'if\((' + ID + rb')==="search"\|\|(' + ID + rb')\+(' + ID + rb')>='
                                              rb'(' + ID + rb')\.length\)(' + ID + rb')\((' + ID + rb')\*3\)\},'
                                              rb'\[\2,\6,\4\.length,\5,\1,(' + ID + rb')\.length\]\),\7\.length===0', d))
                                          or bool(re.search(
                                              rb'if\((' + ID + rb')==="search"\|\|\((' + ID + rb')\+(' + ID + rb')>='
                                              rb'(' + ID + rb')\.length&&(' + ID + rb')\.current\.empty<' + ID + rb'\)\)'
                                              rb'\5\.current\.empty\+\+,(' + ID + rb')\((' + ID + rb')\*3\)\},'
                                              rb'\[\2,\7,\4\.length,(' + ID + rb'),\6,\1\]\),' + ID + rb'\.length===0', d)),
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
                                              # 2.1.245 inserts two more declarations right after
                                              # `{value:0}`; the tail run still identifies the two
                                              # counters this patch raises
                                              rb'=3,' + ID + rb'=\{value:0\},(?:' + ID + rb'=[^,;]{1,24},){0,8}'
                                              rb'' + ID + rb'=300,' + ID + rb'=0,'
                                              rb'' + ID + rb'=0,' + ID + rb'=!1,' + ID + rb'=300,' + ID + rb'=0,', d))
                                          and bool(re.search(
                                              rb'if\((' + ID + rb')=null,!(' + ID + rb')\)await (' + ID + rb')\('
                                              rb'(' + ID + rb')\((' + ID + rb')\),(' + ID + rb')\);continue ', d))
                                          and bool(re.search(
                                              rb'&&' + ID + rb'===null&&' + ID + rb'<Math\.max\(' + ID + rb',300\)\)\{', d))
                                          # the content-gate that blocked retry after a real block is gone
                                          and bool(re.search(
                                              rb'if\(' + ID + rb'===null&&\(' + ID + rb'\?' + ID + rb'<' + ID + rb':'
                                              rb'' + ID + rb'<' + ID + rb'\)\)\{', d))
                                          and not re.search(
                                              rb'if\(!' + ID + rb'&&' + ID + rb'===null&&\(' + ID + rb'\?'
                                              rb'' + ID + rb'<' + ID + rb':' + ID + rb'<' + ID + rb'\)\)\{', d)
                                          # the exhaustion path, whichever shape this build calls for
                                          and _stream_finalize_ok(d),
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
                                              rb'\?\.agentContext\?\.agentType==="main"\)'
                                              rb'await globalThis\.__ccProbe\(\{', d)),
    'probe hooks both dispatch sites': _probe_hooks_both_sites(_probe_full),
    # One core per site, and the count is CHECKED. The previous form of this
    # entry was `bool(re.search(...))` under the name "defined once" -- a
    # presence test wearing a count's name, which would have gone green on any
    # number of copies including the drifted ones it was written to forbid.
    # (Copies across sites are compared byte for byte by the entry above; this
    # one is what keeps a single site from accumulating two.)
    'probe core defined once per site': len(re.findall(
                                              rb'globalThis\.__ccProbe\?\?=async function\(__o\)\{', d)) == 1,
    # The verdict vocabulary is set by the CALLER: the judge and the watcher
    # have different ones, and a vocabulary hardcoded into the core would
    # silently judge the watcher in the judge's words.
    'probe verdict vocabulary comes from the caller': bool(re.search(
                                              rb'let __rx=new RegExp\("\^\\\\s\*\(\?:"\+__o\.rx\+"\):\.\*\$","gm"\)', d))
                                          and bool(re.search(
                                              rb'rx:"OK\|BLOCK\|STOP\|DENY\|WARN",act:"BLOCK\|STOP\|DENY"', d)),
    # A regex built from a STRING needs a double backslash: a single one
    # quietly degenerates the class (`"\s"` in a JS string is the letter s,
    # `"[\s\S]"` is [sS]), and the verdict vocabulary stops matching while
    # staying syntactically valid. Measured on the bench: BLOCK was recorded as
    # ok, and the judge cancelled nothing.
    'probe verdict classes survive string escaping': bool(re.search(
                                              rb'new RegExp\("\^\(\?:"\+__o\.act\+"\):\\\\s\*'
                                              rb'\(\[\\\\s\\\\S\]\+\)\$","m"\)', d))
                                          and not re.search(
                                              rb'new RegExp\("\^\(\?:"\+__o\.act\+"\):\\s\*\(\[\\s\\S\]\+\)', d),
    # The watcher is the second consumer of the SAME core. A separate
    # definition here would mean the decomposition into a core never happened.
    'watcher rides the same core': bool(re.search(
                                              rb'if\(process\.env\.CLAUDE_IDLE&&' + ID +
                                              rb'\?\.agentContext\?\.agentType==="main"\)'
                                              rb'await globalThis\.__ccProbe\(\{'
                                              rb'tag:"\[Watch\]",dirName:"idle-watch",arm:!1,'
                                              rb'label:"FLEET",rx:"SILENT\|NUDGE",act:"NUDGE",', d)),
    # The watcher's reaction is a tab in the thread, not a dispatch
    # cancellation. A throw here would crash a working tool for the sake of a
    # reminder; `arm:!1` additionally locks the failure path through which the
    # judge cancels a dispatch.
    # The main-loop filter in the IMAGE is `dA(e)=e.agentId===Di()`; the
    # typescript-src reconstruction says `undefined` at this spot and has
    # diverged since 2.1.239.
    # The drain threshold equals "later" only in a thread with Sleep, so
    # "later" would wait for Sleep indefinitely: a journal with "nudge" and
    # zero delivery.
    'watcher nudges through the notification queue': bool(re.search(
                                              rb'onAct:async\(__r\)=>\{try\{' + ID +
                                              rb'\(\{value:"\[fleet-idle\] "\+__r\+"[^"]*",'
                                              rb'mode:"task-notification",agentId:' + ID +
                                              rb'\(\),priority:"next"\}\)\}', d))
                                          # a silent catch here = a journal with nudge and zero delivery
                                          and bool(re.search(
                                              rb'outcome:"nudge_undelivered"', d))
                                          # the recipient must match what the filter itself requires
                                          and bool(re.search(
                                              rb'function (\w+)\(\w+\)\{return \w+\.agentId===(\w+)\(\)\}', d))
                                          and bool(re.search(
                                              rb'onNoVerdict:\(\)=>\{\},onBroken:\(\)=>\{\},'
                                              rb'onFail:\(\)=>\{\}\}\)', d)),
    # The fleet count happens on EVERY tool call: counting only where the
    # watcher is invoked means never seeing already-started subagents. The
    # list is capped from above — otherwise it grows the whole session.
    'watcher counts every dispatch': bool(re.search(
                                              rb'globalThis\.__ccFleet\?\?=\[\];if\(' + ID +
                                              rb'\.name==="Agent"\|\|' + ID + rb'\.name==="Task"\)\{'
                                              rb'globalThis\.__ccFleet\.push\(Date\.now\(\)\);', d))
                                          and bool(re.search(
                                              rb'if\(globalThis\.__ccFleet\.length>256\)', d)),
    # The cheap count stands BEFORE the model: a busy fleet, an unfilled window
    # and a cooldown cut off the consultation for free. Without it the watcher
    # would become a permanent expense line on every tool call.
    'watcher spends nothing before the cheap count': bool(re.search(
                                              rb'if\(__ask&&__o\.gate\)\{let __g=null;', d))
                                          # three count refusals; the exact moment of each is
                                          # checked separately below
                                          and bool(re.search(rb'return "fleet-busy:"\+__n\}', d))
                                          and bool(re.search(rb'return "window-not-filled"\}', d))
                                          and bool(re.search(rb'return "cooldown"\}', d)),
    # The probe is called on every tool call, so the filter must run BEFORE
    # reading settings: walking up the tree costs tens of filesystem accesses,
    # and a journaled refusal would drown the human's journal.
    'probe skips before touching the disk': bool(re.search(
                                              rb'globalThis\.__ccProbe\?\?=async function\(__o\)\{'
                                              rb'if\(__o\.pre\)\{let __pr=null;try\{__pr=__o\.pre\(\)\}'
                                              rb'catch\{__pr=null\}if\(__pr\)return\}', d)),
    # The filter must know the MOMENT, not the polling interval: every cheap-count
    # refusal names a time before which it cannot change.
    'watcher names the next possible moment': bool(re.search(
                                              rb'pre:\(\)=>\{let __s=globalThis\.__ccWatch;'
                                              rb'return __s&&__s\.nextAt>Date\.now\(\)\?"not-yet":null\}', d))
                                          and bool(re.search(
                                              rb'if\(__n>=__th\)\{__s\.nextAt=__f\[__n-__th\]\+__w;', d))
                                          and bool(re.search(
                                              rb'__s\.nextAt=__s\.start\+__w;', d))
                                          and bool(re.search(
                                              rb'__s\.nextAt=__s\.last\+__cd;', d))
                                          and bool(re.search(
                                              rb'__s\.last=__now;__s\.nextAt=__now\+__cd;return null', d)),
    # A cheap-count refusal lands in the journal with a REASON: otherwise "never
    # called" and "called and stayed silent" are indistinguishable, and those
    # are two different outcomes.
    'watcher journals why it stayed cheap': bool(re.search(
                                              rb'await __jlog\(\{outcome:"filtered",by:String\(__g\),'
                                              rb'cls:null\}\)', d)),
    # The outcome word in the journal is the class named by the model, not the
    # judge's "block": the vocabulary comes from the caller, and a hardcoded
    # word would write the watcher's silence with the same characters as a real
    # judge cancellation.
    'outcome word comes from the verdict class': bool(re.search(
                                              # a regex LITERAL: one backslash, unlike the
                                              # string-built vocabulary one above
                                              rb'let __ocw=String\(\(/\^\\s\*\(\[A-Za-z\]\+\):/'
                                              rb'\.exec\(__v\|\|""\)\|\|\[\]\)\[1\]\|\|"ok"\)'
                                              rb'\.toLowerCase\(\);', d))
                                          and bool(re.search(
                                              rb'outcome:__bl\?\(__en\?__ocw:__ocw\+"_not_enforced"\):'
                                              rb'\(__v\?__ocw:', d))
                                          and not re.search(
                                              rb'outcome:__bl\?\(__en\?"block"', d),
    # The corpus of records is the material for model selection and for
    # training our own, and it will have to be parsed from the outside. The
    # verdict vocabulary therefore lives IN THE RECORD ITSELF: a copy in
    # config.json would be a second source of truth and would drift silently,
    # while without the vocabulary the parsing tools hardcode the judge's
    # OK/WARN/BLOCK and cannot express the watcher's SILENT/NUDGE at all. The
    # journal line carries no vocabulary deliberately — a human reads it.
    'records carry their own verdict vocabulary': bool(re.search(
                                              rb'JSON\.stringify\(\{\.\.\.__base,rx:__o\.rx,act:__o\.act,'
                                              rb'http:__jst,url:__jurl,pid:process\.pid,', d))
                                          and not re.search(
                                              rb'let __base=\{t:__ts,rx:', d),
    # a WARN never reaches the model and a fail-open skip leaves no trace,
    # so both are only observable through the append-only journal
    'judge journals every consultation': bool(re.search(
                                              rb'appendFile\(__jdir\+"/journal\.jsonl"', d)),
    # a journal line has to say which switch armed enforcement and what the
    # consultation cost — without both, `block` and `block_not_enforced` are
    # separable only by guessing at the environment of a past run
    'judge journal records cost and switch': bool(re.search(
                                              rb'ms:Date\.now\(\)-__t0,sw:__o\.sw\|\|null', d))
                                          and bool(re.search(
                                              rb'en:__en\?\(__o\.sw==="enforce"\?'
                                              rb'"env":"config"\):null', d))
                                          # the judge's switch remains env: the core does not know it
                                          and bool(re.search(
                                              rb'sw:process\.env\.CLAUDE_JUDGE,', d)),
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
                                              rb'if\(__has\.some\(\(__x\)=>__x\.c===1\)\)\{if\(__c!==__dir\)'
                                              rb'\{__pdir=__c;__phomeP=__ch\}break\}', d))
                                  and bool(re.search(
                                              rb'if\(__phomeP\)\{let __c1=await __ldt\(__phomeP\+"/probes\.toml"\);'
                                              rb'if\(__c1===!1\)__cfgbad=!0;else if\(__c1\)'
                                              rb'__cfg=\{\.\.\.__cfg,\.\.\.__eff\(__c1,__o\.dirName\)\}\}', d)),
    'judge context is structured, not prefixed': bool(re.search(
                                              rb'return\{src:__role,text:__bt\}\}\)\.filter\(Boolean\)', d))
                                          and bool(re.search(
                                              rb'let __cut=\(__n\)=>\{let __b=Math\.max\(60,__n\),'
                                              rb'__pb=Math\.floor\(__b\*0\.35\),__sb=Math\.floor\(__b\*0\.3\);', d)),
    # the main loop is told the RULE, not the judge: a cancelled dispatch was
    # once read as the routing gate firing and blindly retried
    'dispatch-cancellation rule reaches the main loop': bool(re.search(
                                              rb'\.\.\.\(process\.env\.CLAUDE_JUDGE&&[A-Za-z_$][\w$]*'
                                              rb'\?\.agentContext\?\.agentType==="main"\?\['
                                              rb'"A subagent dispatch may be reviewed', d)),
    # a record has to be REPLAYABLE, so it carries the endpoint, the sending
    # process, and what every rung was fed — not just the body that answered
    'judge keeps the full consultation': bool(re.search(
                                              rb'\{\.\.\.__base,rx:__o\.rx,act:__o\.act,'
                                              rb'http:__jst,url:__jurl,pid:process\.pid,'
                                              rb'cwd:process\.cwd\(\),attempts:__jatt,request:__rq,'
                                              rb'response:__jres\}', d))
                                          and bool(re.search(
                                              rb'__jatt\.push\(__a\)', d)),
    # the judge must ride the client model pool, not its own HTTP call: a
    # dedicated path would route claude-models to api.anthropic.com at API
    # prices
    'judge rides the client model pool': bool(re.search(
                                              rb'via:__http\?"http":"pool"', d))
                                          and bool(re.search(
                                              rb'querySource:"hook_prompt",toolChoice:void 0', d))
                                          and bool(re.search(
                                              rb'effortValue:__e\.effort\|\|void 0', d)),
    # a whole-ladder failure under fail_closed = cancellation, not a silent pass
    'judge can fail closed': bool(re.search(
                                              rb'__fc=!__v&&__en&&__fcl', d))
                                          and bool(re.search(
                                              rb'let __fcl=__cfgbad\|\|__cfg\.fail_closed===!0', d))
                                          and bool(re.search(rb'if\(__fc\)await __o\.onNoVerdict\(', d))
                                          # ...and the judge's reaction to it must be a throw,
                                          # otherwise fail_closed turns into fail-open with a one-line edit at the call site
                                          and bool(re.search(
                                              rb'onNoVerdict:\(__r\)=>\{let __e=new Error\([\s\S]{0,4000}?'
                                              rb'__e\.__ccJudgeBlock=!0;throw __e\}', d)),
    # a channel cancellation and a verdict cancellation are different defects,
    # different names
    'judge names a fail-closed cancellation': bool(re.search(
                                              rb'__fc\?"block_no_verdict":"empty"', d)),
    # trimming the transcript must not drop what the human typed before
    # anything else
    'judge keeps the human turns when trimming': bool(re.search(
                                              rb'__pr=\(__x\)=>__x&&\(__x\.src==="user"\|\|'
                                              rb'__x\.src==="compaction-summary"\)', d))
                                          and bool(re.search(
                                              rb'if\(!__al\(__k\)\|\|__pr\(__a\[__k\]\)\)continue;'
                                              rb'if\(__tot-__w\[__k\]>=__b\)', d))
                                          # the share is counted per CLASS (a per-item summary cap
                                          # gave 64% of the transcript), the carrier is cut by text, not dropped
                                          and bool(re.search(
                                              rb'__cap\(__iss,__sb\);__cap\(__isu,__pb\)', d))
                                          and bool(re.search(
                                              rb'__dp\?"; \\u0412\\u042b\\u0422\\u0415\\u0421', d)),
    # the last unpinned entry is shortened to fit the gap rather than dropped:
    # otherwise the transcript empties out and the judges blind
    'judge fills the budget instead of emptying the tape': bool(re.search(
                                              rb'if\(__tot-__w\[__k\]>=__b\)\{__del\(__k,!1\);continue\}', d))
                                          and bool(re.search(
                                              rb'if\(__w\[__k\]>120\)__fit\(__k,__w\[__k\]-\(__tot-__b\)\);'
                                              rb'else __del\(__k,!1\)', d)),
    # trimming thresholds and the marker cost are counted in JSON LENGTH:
    # text thresholds missed on escaping in both directions (overflow and
    # undershoot)
    'judge measures trimming in JSON length': bool(re.search(
                                              rb'let __fit=\(__i,__tc\)=>\{if\(__w\[__i\]<=__tc\)return 0;', d))
                                          and bool(re.search(
                                              rb'__lim=Math\.max\(8,Math\.floor\(__lim\*__tc/__c\*0\.9\)\)', d))
                                          and bool(re.search(
                                              rb'__tot\+__mc>__n', d)),
    # trimming must be LINEAR: re-serialising the whole array on every removal
    # gave 8.3 s of local compute against the rung's 25 s threshold
    'judge trims without re-serialising': bool(re.search(
                                              rb'__cs=\(__x\)=>JSON\.stringify\(__x\)\.length\+1', d))
                                          and bool(re.search(
                                              rb'__del=\(__i,__p\)=>\{if\(__dd\[__i\]\)return 0;__dd\[__i\]=!0', d))
                                          # removal marks instead of cutting out: a splice per
                                          # removal gave 5-10 s on a marathon transcript
                                          and len(re.findall(rb'__a\.splice\(', d)) == 0
                                          # the marks are reset after EVERY compaction: otherwise
                                          # the marker count runs on stale marks and undercounts
                                          # the pinned human turns, down to zero with three live
                                          # occurrences: introducing the mark array and the reset
                                          # after each of the two compactions
                                          and len(re.findall(rb'__dd=new Array\(__a\.length\)\.fill\(!1\)', d)) == 3
                                          and len(re.findall(rb'__fit\(0,', d)) == 0
                                          and len(re.findall(rb'__s=JSON\.stringify\(__a\)', d)) == 0
                                          and bool(re.search(rb'__mt=\(\)=>"\[\\u043b', d))
                                          and bool(re.search(rb'__pb=Math\.floor\(__b\*0\.35\)', d)),
    # the numbers in the marker and in the record itself must state the FACT,
    # not the call count: counting __fit calls gave 39 trims against 4 live
    # ones, and counting from the previous cut gave "123 cut out" where
    # 200000 were cut
    'judge counts trimmed records honestly': bool(re.search(
                                              rb'let __ot=new Array\(__a\.length\)\.fill\(null\)', d))
                                          # a trim always works from the ORIGINAL text
                                          and bool(re.search(
                                              rb"let __t=__ot\[__i\]!==null\?__ot\[__i\]:String\(__a\[__i\]\.text\)", d))
                                          and bool(re.search(
                                              rb'__ot\[__i\]=__t;__a\[__i\]=__nx', d))
                                          # the originals array is carried across BOTH compactions
                                          and len(re.findall(rb'__ot=__ot\.filter\(', d)) == 2
                                          # the call counter is removed from the code entirely
                                          and len(re.findall(rb'__c2', d)) == 0
                                          and bool(re.search(
                                              rb'__ctd=\(\)=>\{let __r=0;.{0,80}__ot\[__k\]!==null', d))
                                          and bool(re.search(rb'\(__cd=__ctd\(\)\)\?', d)),
    # the failure path reads only names declared above the try (see the helper)
    'judge fail-open path stays in scope': _judge_catch_scope(d),
    # a channel failure under fail_closed = CANCELLATION, not a pass: the retry
    # on a short transcript was not wrapped, its crash was written up as a
    # regular skip and the dispatch went through
    'judge cancels when it cannot decide': bool(re.search(
                                              rb'if\(__ask\)\{__jarm=!!__o\.arm&&__en&&__fcl;', d))
                                          # the retry is wrapped the same way as a rung
                                          and bool(re.search(
                                              rb'try\{__raw=await __call\(__cut\(Number\('
                                              rb'__cfg\.retry_context_chars\?\?8000\)\)', d))
                                          # the obligation is released LAST
                                          and bool(re.search(
                                              rb'await __o\.onAct\(__bl\[1\]\.trim\(\)\);__jarm=!1;\}\}catch', d))
                                          and bool(re.search(
                                              rb'outcome:__jarm\?"block_no_verdict":"skip"', d))
                                          and bool(re.search(
                                              rb'if\(__jarm\)await __o\.onFail\(__rs\);', d))
                                          # the journal write does not steer control past decisions
                                          and bool(re.search(
                                              rb'try\{await __jlog\(\{http:__jst,outcome:__bl\?', d))
                                          and bool(re.search(
                                              rb'verdict:__clip\(__v,400\)\|\|null\}\)\}catch\{\}', d)),
    # every truncation in the journal and the record is declared, like
    # trimming the transcript. A name-by-name list of forbidden places forbids
    # only what has already been thought of: trimming THE DISPATCH ITSELF was
    # not in it, and a bare slice on the main object of the judgment held
    # 69/69 while the judge returned corrected dispatches for a truncation we
    # had made ourselves (measured 2026-08-23). The dispatch is pinned
    # separately.
    # A journal record is addressed by SESSION, not by pid alone: the OS
    # reuses pids, and after the process dies the record points at nothing.
    # The pin is class-level: the field must sit in the shared base (the record
    # file inherits it too), the getter must swallow the throw — a journal line
    # has no right to disappear over a field — and there must be no bare call
    # in the base.
    # Session busyness is taken from the task REGISTRY, not inferred from
    # dispatch timestamps: a subagent working longer than the window fell out
    # of the marks, and the session looked idle exactly while the fan-out was
    # running. The pin is class-level: reading the registry, a liveness check
    # exactly as in the image (_L), a readability declaration in the payload,
    # and a recheck NOT through the window.
    # The dispatch model is RESOLVED (call -> agent definition -> inheritance),
    # the source is named by the msrc field. A third of the records went out
    # without a model, and the "who worked with what" census undercounted that
    # third. The pin is class-level: the old form is forbidden too — the model
    # straight from the call into the record base.
    'journal resolves the dispatch model': bool(re.search(
                                              rb'__mdl=\(\)=>\{try\{let __m=__o\.input\?\.model;', d))
                                          and bool(re.search(
                                              rb'ctx\?\.options\?\.agentDefinitions\?\.activeAgents', d))
                                          and bool(re.search(rb'__dm!=="inherit"\)return\{m:__dm,s:"agent"\}', d))
                                          and bool(re.search(rb's:__dm==="inherit"\?"inherit":"main"', d))
                                          and bool(re.search(rb'model:__mv\.m,msrc:__mv\.s', d))
                                          and len(re.findall(rb'model:__o\.input\?\.model,', d)) == 0,
    # The session title is taken through an accessor whose binding in the image
    # is NOT proven: a wrong name would return a stack parse instead of a
    # string, SILENTLY. The shape check is mandatory — without it the journal
    # would collect garbage that looks like data.
    # The applied settings layer is named in EVERY journal line, not only in
    # consultation lines: before, the layer filter named nothing, and which
    # config.json took effect had to be inferred indirectly from behavior. The
    # field has exactly one source — the shared record base.
    'every journal line names the applied config layer': bool(re.search(
                                              rb'msrc:__mv\.s,cfg:__pdir\|\|null,', d))
                                          and len(re.findall(rb'cfg:__pdir\|\|null', d)) == 1,
    'session title is shape-guarded': bool(re.search(
                                              rb'__ttl=\(\)=>\{try\{let __i=__sid\(\);', d))
                                          and bool(re.search(
                                              rb'typeof __v==="string"&&__v\?__v:void 0', d))
                                          and bool(re.search(rb'title:__ttl\(\)', d)),
    'watcher counts live work, not dispatch marks': bool(re.search(
                                              rb'__tr=[\w$]+\?\.taskRegistry\?\.all\?\.\(\)', d))
                                          and bool(re.search(
                                              rb'status==="running"\|\|[\w$.?]+status==="pending"', d))
                                          and bool(re.search(
                                              rb'isBackgrounded!==!1', d))
                                          and bool(re.search(
                                              rb'return "live-work:"\+', d))
                                          and bool(re.search(
                                              rb'task_registry_readable:', d))
                                          # an unreachable registry is NOT reported as "no work"
                                          and bool(re.search(rb'__s\.reg=!!__tr', d))
                                          and bool(re.search(rb'if\(__tr&&__lv\.length>=__lth\)', d)),
    'journal line carries the session id': bool(re.search(
                                              rb'__base=\{t:__ts,sid:__sid\(\)', d))
                                          and bool(re.search(
                                              rb'__sid=\(\)=>\{try\{return [\w$]+\(\)\}catch\{return null\}\}', d))
                                          # a bare image call outside the swallower:
                                          # the swallower itself is not under the ban
                                          and len(re.findall(
                                              rb'sid:(?!__sid\(\))[\w$]+\(\),tool:', d)) == 0,
    'judge declares every truncation': len(re.findall(
                                              rb'__clip\(', d)) >= 6
                                          and len(re.findall(rb'__v\.slice\(0,400\)', d)) == 0
                                          and len(re.findall(rb'\.resp=__t2?\.slice\(0,800\)', d)) == 0
                                          # the dispatch is cut ONLY with a declaration
                                          and bool(re.search(
                                              rb'__dtr=__dsrc\.length>__dmax;', d))
                                          and bool(re.search(
                                              rb'__disp=__dtr\?__dsrc\.slice\(0,__dmax\):__dsrc', d))
                                          and bool(re.search(
                                              rb'__lbl=String\(__o\.label\|\|"DISPATCH"\)\+\(__dtr\?', d))
                                          and len(re.findall(
                                              rb'\.slice\(0,Number\(__cfg\.dispatch_chars', d)) == 0
                                          # the failed attempt's message: a bare slice
                                          # chopped off the phrase naming the tool
                                          and len(re.findall(rb'__xe\?\.message\?\?__xe\)\.slice\(', d)) == 0
                                          and bool(re.search(rb'__clip\(__em,200\)', d))
                                          # our own OUTPUT ceiling is called by its own name
                                          and bool(re.search(rb'our output budget "\+__ob\[1\]\+" exhausted', d))
                                          # before the first attempt there are ZERO attempts
                                          and bool(re.search(rb'__jtry=0,__jerr1=null', d)),
    # a broken config silently removed enforce and fail_closed: the judge
    # looked alive and let everything through, including its own BLOCK verdict
    # one home for all probes: the id is a subdirectory, not a separate
    # settings root
    'settings live in one probes home': bool(re.search(
                                              rb'let __phome=__o\.dirEnv\|\|\(\(process\.env\.HOME\|\|"\."\)'
                                              rb'\+"/\.claude/probes"\);let __dir=__phome\+"/"\+__o\.dirName', d))
                                          # a probe's journal lives in its subdirectory of the same home
                                          and bool(re.search(
                                              rb'__jdir=\(__o\.dirEnv\|\|\(\(process\.env\.HOME\|\|"\."\)'
                                              rb'\+"/\.claude/probes"\)\)\+"/"\+__o\.dirName', d))
                                          # ONE environment variable for all probes
                                          and len(re.findall(rb'dirEnv:process\.env\.CLAUDE_PROBES_DIR', d)) == 2
                                          and len(re.findall(rb'CLAUDE_JUDGE_DIR', d)) == 0
                                          and len(re.findall(rb'CLAUDE_IDLE_DIR', d)) == 0,
    # [defaults] under the probe table; a probe not named in the file gets
    # bare defaults — that is the absence of its own edits, not an error
    'probe settings merge defaults under the probe table': bool(re.search(
                                              rb'let __eff=\(__t,__id\)=>__t&&typeof __t==="object"'
                                              rb'\?\{\.\.\.\(__t\.defaults\|\|\{\}\),'
                                              rb'\.\.\.\(\(__t\.probe\|\|\{\}\)\[__id\]\|\|\{\}\)\}:\{\}', d)),
    # disabling a probe is a setting; the registry must silence one consumer
    # without touching the others, and the silencing must be VISIBLE in the
    # journal
    'a disabled probe says so in the journal': bool(re.search(
                                              rb'if\(__cfg\.enabled===!1\)\{await __jlog\('
                                              rb'\{outcome:"skip_disabled"\}\);return\}', d)),
    # a missing TOML parser is an event, not empty settings: empty ones
    # silently remove enforce, the ladder and the budgets
    'a missing TOML parser is declared, not silently empty': bool(re.search(
                                              rb'let __tp=globalThis\.Bun\?\.TOML\?\.parse;'
                                              rb'if\(typeof __tp!=="function"\)\{'
                                              rb'__deg\.push\("no-toml-parser:"\+__f\);'
                                              rb'__degb\.push\("no-toml-parser:"\+__f\);return !1\}', d)),
    'judge tells a broken config from a missing one': bool(re.search(
                                              rb'let __ldt=async\(__f\)=>\{let __x=await __rdj\(__f\)', d))
                                          and bool(re.search(
                                              rb'let __c0=await __ldt\(__phome\+"/probes\.toml"\);'
                                              rb'if\(__c0===!1\)__cfgbad=!0;else if\(__c0\)'
                                              rb'__cfg=__eff\(__c0,__o\.dirName\)', d))
                                          # unknown enforce/fail_closed count as ON
                                          and bool(re.search(
                                              rb'__cfg\.enforce===!0\|\|__cfgbad', d))
                                          and bool(re.search(
                                              rb'let __fcl=__cfgbad\|\|__cfg\.fail_closed===!0', d))
                                          # an unreadable layer is distinct from a missing one:
                                          # "no such path" (ENOENT/ENOTDIR/ELOOP) versus
                                          # "the path exists, no access" (EACCES/EPERM)
                                          and bool(re.search(
                                              rb'__c==="EACCES"\|\|__c==="EPERM"\?2:', d))
                                          and bool(re.search(
                                              rb'__c==="ENOENT"\|\|__c==="ENOTDIR"\|\|'
                                              rb'__c==="ELOOP"\|\|__c==="ENAMETOOLONG"\?0:3', d))
                                          and bool(re.search(
                                              rb'__deg\.push\("layer-unreadable:"', d))
                                          # a BOM is invisible and the parser rejects it
                                          and bool(re.search(
                                              rb'if\(__x\.charCodeAt\(0\)===65279\)__x=__x\.slice\(1\)', d))
                                          and bool(re.search(
                                              rb'__deg\.push\("empty:"\+__f\)', d)),
    # broken rules are not "fall back to defaults" but a cancellation naming
    # the file
    'judge cancels when its rules are broken': bool(re.search(
                                              rb'if\(__degb\.length&&__en\)\{', d))
                                          and bool(re.search(
                                              rb'await __o\.onBroken\(__dcut\(__degb,3\)\.join\("; "\)\)', d))
                                          and bool(re.search(
                                              rb'outcome:__o\.arm\?"block_degraded":"skip_degraded"', d))
                                          # a probe that does not cancel the dispatch does not pay
                                          # for a consultation by rules it does not have
                                          and bool(re.search(
                                              rb'await __o\.onBroken\(__dcut\(__degb,3\)\.join\("; "\)\);return\}', d))
                                          and bool(re.search(
                                              rb'\.\.\.\(__deg\.length\?\{deg:__dcut\(__deg,5\)\}:\{\}\)', d))
                                          and bool(re.search(
                                              rb'onBroken:\(__r\)=>\{let __e=new Error[\s\S]{0,4000}?__e\.__ccJudgeBlock=!0;throw __e\}', d)),
    # the fallback prompt must be able to cancel, otherwise the gate is
    # formally alive and substantively off: the old one had no word BLOCK at
    # all
    'fallback prompt can cancel': b'BLOCK cancels the dispatch' in d
                                          and b'SWAP:<model>:<why>' not in d
                                          and bool(re.search(
                                              rb'let __pmm="prompt-missing:"\+__dir', d)),
    # an answer outside the vocabulary is not a verdict: it used to be
    # recorded as ok
    'an unrecognised answer is not a verdict': bool(re.search(
                                              rb'return \(\(String\(__rr\)\.match\(__rx\)\|\|\[\]\)\.pop\(\)\|\|""\)\.trim\(\)', d))
                                          and len(re.findall(rb'\.pop\(\)\)\|\|__ct\)\.trim\(\)', d)) == 0,
    # a cancellation must have a way out: which file to fix, and whether
    # several more like it were silently dropped
    'a cancelled dispatch names the file to fix': bool(re.search(
                                              rb'"prompt-missing:"\+__dir\+"/prompt\.md"', d))
                                          # degradation lists are cut with a declaration
                                          and bool(re.search(
                                              rb'__dcut=\(__l,__k\)=>__l\.length<=__k\?__l:'
                                              rb'__l\.slice\(0,__k\)\.concat\(', d))
                                          and len(re.findall(rb'__deg\.slice\(0,5\)', d)) == 0
                                          and len(re.findall(rb'__degb\.slice\(0,3\)', d)) == 0
                                          and bool(re.search(rb'deg:__dcut\(__deg,5\)', d))
                                          # on a fresh install the journal creates its own directory
                                          and bool(re.search(
                                              rb'catch\(__ae\)\{if\(__ae\?\.code!=="ENOENT"\)throw __ae;'
                                              rb'await __jfs\.mkdir\(__jdir,\{recursive:!0\}\)', d)),
    # local command output is a PROGRAM's answer; it must not carry the human
    # label: otherwise pinning keeps it forever as an authorization
    'judge does not read command output as the human': bool(re.search(
                                              rb'__bt\.includes\("<local-command-stdout"\)', d))
                                          and bool(re.search(
                                              rb'\?"user-command":', d))
                                          and bool(re.search(
                                              rb'<command-args>\\s\*\[\^\\s<\]/\.test\(__bt\)\)\?"user"', d)),
    # an unknown wrapper under the user role must be VISIBLE in the journal:
    # three defects in a row were one class, found through an incident
    'judge reports unknown user-role wrappers': bool(re.search(
                                              rb'\{uw:__uw\.slice\(0,5\)\}', d))
                                          and bool(re.search(
                                              rb'"command-name","command-message","command-args"', d)),
    # after compaction the summary is the ONLY carrier of standing directives;
    # it is pinned with its own share and trimmed by text, not dropped
    'judge pins the compaction summary': bool(re.search(
                                              rb'__M\?\.isCompactSummary\?"compaction-summary"', d))
                                          and bool(re.search(
                                              rb'__x\.src==="compaction-summary"\)', d))
                                          and bool(re.search(
                                              rb'__sb=Math\.floor\(__b\*0\.3\)', d)),
    # a rung failure must carry the reason and its own reply, otherwise there
    # is nothing to analyze
    'judge keeps the reason of a failed rung': bool(re.search(
                                              rb'api error from the pool: ', d))
                                          and len(re.findall(rb'__a\.resp=', d)) == 2,
    # ported from tweakcc, whose own patch set cannot apply on this build
    # a bare 'var X=500' matches six unrelated constants in the PRISTINE binary,
    # so the check has to reach the debounce site first and then assert on the
    # constant that site actually names
    'statusline throttle raised': (lambda mm: bool(mm) and bool(re.search(
                                              # the captured name may contain `$`, which is an
                                              # ANCHOR in a pattern: the same class the patch
                                              # script closes with rxEsc, missed here. On 2.1.245
                                              # the constant is named `$Ke` and this check
                                              # reported a false FAIL for a correctly patched
                                              # binary. It is the only unescaped interpolation in
                                              # this file — the other .group() uses are haystacks.
                                              rb'var ' + re.escape(mm.group(1)) + rb'=500\b', d)))(
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

# --- 5a2. the interface must actually come up ---------------------------------
# `--version` never executes a single React render. A patch that emits a name
# which is not in scope where it lands passes every byte check AND the version
# smoke, then kills the product the moment the interface is drawn: 2.1.246
# shipped that way twice in one morning ("l0 is not defined", then "sR is not
# defined"), each time with 78/78 green above this line.
#
# So drive the real interface on a pty with a pre-submitted prompt and require
# the prompt to come BACK on screen -- the echo is the user-message renderer
# having run, which is the exact path both crashes died on.
#
# The session runs in a THROWAWAY config home, and every part of that is
# load-bearing. An earlier version of this gate reused the user's own config and
# a trusted project of theirs, which meant each build: started their 9 MCP
# servers, fired their hooks, wrote a transcript, a history entry and a cost
# record into a real project of theirs, and -- because settings.json `env`
# overrides the process environment -- sent the prompt to their live proxy and
# got a real billed answer back. "Points at a dead port" was written in this
# file while none of it was true.
#
#   * CLAUDE_CONFIG_DIR   -> a temp home: no hooks, no MCP, no history, no cost
#   * seeded trust entry  -> no "is this a project you trust?" prompt, which is
#                            what a session stops at otherwise, rendering
#                            nothing while grepping exactly like a clean run
#   * a NON-claude model  -> patch #1 routes claude-* to api.anthropic.com no
#                            matter what the environment says; anything else
#                            falls through to ANTHROPIC_BASE_URL, so only a
#                            non-claude id actually reaches the dead port
#   * CHILD_SESSION marker-> transcript saving off
#   * --strict-mcp-config -> no servers even if one were configured
GATE_HOME="$(mktemp -d)"
mkdir -p "$GATE_HOME/cfg" "$GATE_HOME/proj"
GATE_PROMPT="tweakcc interface gate"
python3 - "$GATE_HOME" <<'PYSEED'
import json, os, sys
home = sys.argv[1]
cfg = os.path.join(home, "cfg")
proj = os.path.realpath(os.path.join(home, "proj"))
# The project key must be the RESOLVED path: on macOS /tmp is a symlink to
# /private/tmp, and a key written under the unresolved name does not match, so
# the session stops at the trust prompt and the gate proves nothing.
json.dump(
    {
        "hasCompletedOnboarding": True,
        "theme": "dark",
        "autoUpdates": False,
        "projects": {proj: {"hasTrustDialogAccepted": True, "allowedTools": [], "history": []}},
    },
    open(os.path.join(cfg, ".claude.json"), "w"),
)
json.dump(
    {
        "model": "gate-offline-model",
        "env": {
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:9",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        },
    },
    open(os.path.join(cfg, "settings.json"), "w"),
)
PYSEED

GATE_LOG="$GATE_HOME/capture.log"
: > "$GATE_LOG"

# Reads the capture and answers in one word: RENDERED, PENDING, or ERROR <what>.
gate_state() {
  python3 - "$GATE_LOG" "$GATE_PROMPT" <<'PYSTATE'
import re, sys

raw = open(sys.argv[1], "rb").read().decode("utf8", "replace")
# OSC sequences carry the prompt text in a notification payload and can be
# terminated by BEL *or* by ESC-backslash; stripping only the BEL form left the
# prompt visible to the marker check without a single character having been
# rendered.
txt = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", raw)
txt = re.sub(r"\x1b[\[\(][0-9;?<>=]*[a-zA-Z]", "", txt)
txt = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", txt)
# The interface writes cursor moves where a person sees spaces, so a literal
# "auto mode on" is not present as bytes even while it is on the screen.
flat = re.sub(r"\s+", "", txt)

# A connection failure is the EXPECTED outcome here -- the model id is routed to
# a dead port on purpose -- so those two are not interface faults.
BENIGN = ("Connectionrefused", "Connectionerror", "APIError", "fetchfailed")
# Order matters. The parenthesised exit line is the only place the name is
# delimited; anywhere else the flattening glues it to whatever the screen drew
# just before it ("...for shortcuts ERROR" + "l0"), so the on-screen ERROR
# label is consumed explicitly and the capture is non-greedy. Without both, the
# gate reported the identifier as "forshortcutsERRORl0".
m = re.search(r"unrecoverableinterfaceerror\(([^)]*)\)", flat)
if m:
    print(f"ERROR unrecoverable interface error ({m.group(1)})")
    sys.exit()
m = re.search(r"ERROR([A-Za-z_$][A-Za-z0-9_$]*?)isnotdefined", flat)
if m:
    print(f"ERROR {m.group(1)} is not defined")
    sys.exit()
if "isnotdefined" in flat:
    tail = flat[: flat.index("isnotdefined")][-16:]
    print(f"ERROR ...{tail} is not defined")
    sys.exit()
# Any exception class, not the three that happened to be seen once: a build
# that dies with RangeError or "Cannot read properties of undefined" is just as
# broken, and the earlier list called both of those a pass.
for m in re.finditer(r"([A-Z][A-Za-z]*Error)", flat):
    if m.group(1) not in BENIGN:
        print(f"ERROR {m.group(1)}")
        sys.exit()
if re.search(r"Cannotread(?:property|properties)of(?:undefined|null)", flat):
    print("ERROR cannot read properties of undefined")
    sys.exit()
print("RENDERED" if re.sub(r"\s+", "", sys.argv[2]) in flat else "PENDING")
PYSTATE
}

# `exec` replaces the subshell so $! is the pid that setsid then makes a session
# and process-group leader. Killing the single pid leaves `script` and the CLI
# running: during one version sweep that left 23 sessions and 1.4 GB resident.
# The group kill is what actually ends the run.
(
  cd "$GATE_HOME/proj" || exit 1
  exec env CLAUDE_CONFIG_DIR="$GATE_HOME/cfg" CLAUDE_CODE_CHILD_SESSION=1 \
    perl -e 'use POSIX (); POSIX::setsid(); exec @ARGV or die $!' \
    script -q /dev/null "$BIN" --strict-mcp-config "$GATE_PROMPT" >"$GATE_LOG" 2>&1
) &
GATE_PID=$!

# A full session start on a machine already running builds is not a two-second
# affair, and a healthy build that misses the budget is reported as a failure.
# 40s was a guess that a loaded box can lose; this is generous and adjustable.
GATE_BUDGET="${CLAUDE_PATCH_GATE_BUDGET:-150}"
GATE_STATE=PENDING
GATE_EXITED=0
for _ in $(seq 1 "$GATE_BUDGET"); do
  sleep 1
  GATE_STATE="$(gate_state)"
  case "$GATE_STATE" in
    ERROR*) break ;;
  esac
  if ! kill -0 $GATE_PID 2>/dev/null; then
    # It ended on its own. That is not success by itself: read the exit status.
    GATE_EXITED=1
    wait $GATE_PID 2>/dev/null
    GATE_RC=$?
    GATE_STATE="$(gate_state)"
    break
  fi
  if [[ "$GATE_STATE" == RENDERED ]]; then
    # An error can still land after the first paint, so keep watching for a
    # while instead of declaring victory three seconds in.
    for _ in $(seq 1 8); do
      sleep 1
      GATE_STATE="$(gate_state)"
      [[ "$GATE_STATE" == ERROR* ]] && break
      kill -0 $GATE_PID 2>/dev/null || break
    done
    break
  fi
done

if [[ $GATE_EXITED -eq 0 ]]; then
  kill -TERM -"$GATE_PID" 2>/dev/null || kill -TERM "$GATE_PID" 2>/dev/null || true
  wait $GATE_PID 2>/dev/null || true
  GATE_RC=0
fi

case "$GATE_STATE" in
  RENDERED)
    if [[ ${GATE_RC:-0} -ne 0 ]]; then
      echo "FATAL: the interface drew its message and then exited ${GATE_RC}" >&2
      echo "  capture kept at $GATE_LOG" >&2
      exit 1
    fi
    echo "Interface: came up in a throwaway home and drew its message, no name or type errors"
    rm -rf "$GATE_HOME"
    ;;
  ERROR*)
    echo "FATAL: the interface does not come up — leaving the launcher alone" >&2
    echo "  ${GATE_STATE#ERROR }" >&2
    echo "  capture kept at $GATE_LOG" >&2
    exit 1
    ;;
  *)
    echo "FATAL: the interface gate never reached a render within ${GATE_BUDGET}s," >&2
    echo "       so it proves nothing — refusing to call this build good." >&2
    echo "       Raise CLAUDE_PATCH_GATE_BUDGET if the machine is simply slow." >&2
    echo "  capture kept at $GATE_LOG" >&2
    exit 1
    ;;
esac

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
  # The keep-list is built from the REAL version name, not the target name:
  # when building into staging (--target X.staging) basename would give
  # "2.1.237.staging", and the cleanup would wipe the live 2.1.237 along with
  # its pristine .orig — everything except the intermediate file. Only the
  # binary a live session was executing at that moment would survive.
  CURRENT_VER="$(basename "$BIN")"
  CURRENT_VER="${CURRENT_VER%.staging}"
  CURRENT_VER="${CURRENT_VER%.orig}"
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
