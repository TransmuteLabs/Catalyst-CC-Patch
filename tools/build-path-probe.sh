#!/usr/bin/env bash
# The build-path probe: the one part of this kit the 114 checks cannot see.
#
# Every check in claude-patch-all.sh is a byte search over the FINISHED image, so
# all of them are blind to how that image came to be. The sweep across versions
# drives the pipeline through `--target`, which patches in place -- so the whole
# default-run branch (step 0b: notice the live binary already carries us, rebuild
# from the pristine copy into a staging file, swap it in by rename) has no
# coverage at all. Two regressions in that branch had already shipped by the time
# this probe was written: `PRISTINE_SRC="$BIN.orig"` naming a file that never
# exists on `--update`, and a version comparison that read tweakcc's second
# `--version` line and refused every default run. Neither was reachable from the
# sweep, and neither was visible to any check.
#
# So this drives the pipeline for real, three times, over throwaway copies:
#
#   a  live binary patched, a matching pristine `.orig` beside it
#      -> must stage, must swap in by RENAME (new inode: a running session keeps
#         executing the old one), must leave no staging file, and must not let
#         tweakcc's backup become a copy of our build.
#   b  live binary pristine, no `.orig` at all -- a first run on a clean machine
#      -> must NOT stage (there are no patches to preserve, and staging from a
#         copy that does not exist cannot be done), must patch in place.
#   c  the negative control: case (a) again, but against a copy of the pipeline
#      with 0b's trigger forced to false. At least one of case (a)'s assertions
#      MUST go red -- otherwise those assertions are decoration and this probe
#      proves nothing. The probe names which ones reddened.
#
# Case (c) runs a mutant copy of the pipeline out of a directory of symlinks to
# this kit, so nothing is written into the source tree; and it snapshots
# ~/.tweakcc/native-binary.backup first, because a mutant whose whole point is to
# hand tweakcc a patched image may well poison it -- that is the failure being
# demonstrated. The snapshot is restored, and the restore verified, on every exit
# path including a kill.
#
# Usage:  bash tools/build-path-probe.sh [--case a|b|c] [--version 2.1.247]
# Cost:   one full pipeline run per case (tweakcc + our patches + 114 checks +
#         the interface gate + the bench), so a few minutes each.

set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE="$HERE/claude-patch-all.sh"
OUR_MARKER='baseURL:/^claude/i.test('
TWEAKCC_BACKUP="$HOME/.tweakcc/native-binary.backup"
VERSIONS="$HOME/.local/share/claude/versions"
CASES=abc
WANT_VER=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --case)    CASES="$2"; shift 2 ;;
    --version) WANT_VER="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# `grep -c` prints 0 AND exits 1 when it finds nothing, so `|| echo 0`
# APPENDS a second line instead of substituting one: on a clean file the
# helper used to return "0\n0", which every comparison here read as "not
# zero". Take grep's own number when it is a number; a missing or unreadable
# file makes grep print nothing at all, and only that case defaults to 0.
marks() {
  local n
  n=$(grep -c -a -F "$OUR_MARKER" "$1" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# The instrument is tested before it is trusted. This probe exists because
# an assertion that cannot fail looks exactly like an assertion that passes,
# and the helper above was itself an example: written in wave 8, it made
# every case skip and every negative-control line count as reddened, and
# nobody could see it until the probe was run for the first time.
self_test_marks() {
  local d yes no
  d="$(mktemp -d)"; yes="$d/yes"; no="$d/no"
  printf '%s\n' "prefix ${OUR_MARKER} suffix" > "$yes"
  printf '%s\n' "nothing to see here" > "$no"
  local a b c
  a="$(marks "$yes")"; b="$(marks "$no")"; c="$(marks "$d/absent")"
  rm -rf "$d"
  if [[ "$a" != 1 || "$b" != 0 || "$c" != 0 ]]; then
    echo "FATAL: marks() не различает помеченный и чистый файл (есть=$a нет=$b отсутствует=$c)" >&2
    exit 1
  fi
}
self_test_marks
# BSD stat and GNU stat spell the same question differently, and a probe whose
# central assertion is "the inode changed" must not report `none` on Linux
# because it asked in the wrong dialect -- that reads as "the file is gone".
inode() { stat -f%i "$1" 2>/dev/null || stat -c%i "$1" 2>/dev/null || echo none; }

# --- material ----------------------------------------------------------------
# A patched build and a pristine copy of the SAME version. Both have to be real:
# a probe that fabricates its own inputs measures the fabrication. If they are
# not on this machine the probe SKIPS and says what is missing -- it does not
# quietly pass.
if [[ -z "$WANT_VER" ]]; then
  live="$(readlink "$HOME/.local/bin/claude" 2>/dev/null || true)"
  WANT_VER="$(basename "${live:-}")"
fi
PATCHED="$VERSIONS/$WANT_VER"
PRISTINE="$VERSIONS/$WANT_VER.orig"
if [[ -z "$WANT_VER" || ! -f "$PATCHED" || ! -f "$PRISTINE" ]]; then
  echo "SKIP: need both $PATCHED and $PRISTINE" >&2
  echo "  (install a version with: bash claude-patch-all.sh --update <version>)" >&2
  exit 3
fi
if [[ "$(marks "$PATCHED")" == 0 ]]; then
  echo "SKIP: $PATCHED does not carry our patches, so case (a) has nothing to preserve" >&2
  exit 3
fi
if [[ "$(marks "$PRISTINE")" != 0 ]]; then
  echo "SKIP: $PRISTINE is not pristine -- it carries our marker" >&2
  exit 3
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cc-build-path-probe.XXXXXX")"
BACKUP_SNAP="$ROOT/native-binary.backup.snapshot"
[[ -f "$TWEAKCC_BACKUP" ]] && cp -p "$TWEAKCC_BACKUP" "$BACKUP_SNAP"

cleanup() {
  # Restore the borrowed backup before anything else, and SAY whether it worked:
  # a silent failure here leaves the human with a poisoned tweakcc restore and no
  # idea this probe was the cause.
  if [[ -f "$BACKUP_SNAP" ]]; then
    if ! cmp -s "$BACKUP_SNAP" "$TWEAKCC_BACKUP" 2>/dev/null; then
      cp -p "$BACKUP_SNAP" "$TWEAKCC_BACKUP.probe-restore" \
        && mv "$TWEAKCC_BACKUP.probe-restore" "$TWEAKCC_BACKUP" \
        && echo "restored $TWEAKCC_BACKUP from the probe's snapshot" \
        || echo "WARNING: could not restore $TWEAKCC_BACKUP from $BACKUP_SNAP" >&2
    fi
  fi
  [[ -n "${KEEP_ROOT:-}" ]] || rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

FAILED=0
note()  { printf '  %-6s %s\n' "$1" "$2"; }
ok()    { note 'ok'   "$1"; }
bad()   { note 'FAIL' "$1"; FAILED=$((FAILED+1)); }

# Every case gets its own bin/ so PATH holds exactly one image and the
# recognizer's "exactly one" rule is satisfied by construction.
stage_dir() {
  local d="$ROOT/$1/bin"
  rm -rf "$ROOT/$1"; mkdir -p "$d"
  echo "$d"
}
run_pipeline() {  # <script> <bindir> <logfile>
  ( PATH="$2:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    CLAUDE_PATCH_SKIP_MODELS=1 bash "$1" ) >"$3" 2>&1
}

# --- case a: live patched, pristine copy beside it ---------------------------
case_a() {
  local d log rc ino_before ino_after
  d="$(stage_dir a)"; log="$ROOT/a.log"
  cp -p "$PATCHED"  "$d/claude"
  cp -p "$PRISTINE" "$d/claude.orig"
  ino_before="$(inode "$d/claude")"
  echo "case a: live binary patched, pristine copy beside it"
  run_pipeline "$PIPELINE" "$d" "$log"; rc=$?
  ino_after="$(inode "$d/claude")"

  [[ $rc -eq 0 ]] && ok "pipeline finished (rc=0)" || bad "pipeline exited rc=$rc (see $log)"
  grep -q 'rebuilding from the pristine copy' "$log" \
    && ok 'took the staging branch' || bad 'never announced the staging branch'
  [[ "$ino_before" != "$ino_after" ]] \
    && ok "swapped in by rename (inode $ino_before -> $ino_after)" \
    || bad "same inode $ino_after: patched in place, under any running session"
  [[ -e "$d/claude.staging" ]] \
    && bad 'left a staging file behind' || ok 'no staging file left behind'
  [[ "$(marks "$d/claude")" != 0 ]] \
    && ok 'the build that landed carries our patches' \
    || bad 'the build that landed carries NO patches'
  [[ "$(marks "$TWEAKCC_BACKUP")" == 0 ]] \
    && ok "tweakcc's backup is still stock" \
    || bad "tweakcc's backup now holds OUR build -- --restore would hand out patched bytes"
}

# --- case b: nothing to preserve ---------------------------------------------
case_b() {
  local d log rc
  d="$(stage_dir b)"; log="$ROOT/b.log"
  cp -p "$PRISTINE" "$d/claude"
  echo "case b: live binary pristine, no copy beside it"
  run_pipeline "$PIPELINE" "$d" "$log"; rc=$?

  [[ $rc -eq 0 ]] && ok "pipeline finished (rc=0)" || bad "pipeline exited rc=$rc (see $log)"
  grep -q 'rebuilding from the pristine copy' "$log" \
    && bad 'staged from a copy that does not exist' || ok 'patched in place, as it must'
  [[ -e "$d/claude.staging" ]] \
    && bad 'left a staging file behind' || ok 'no staging file left behind'
  [[ "$(marks "$d/claude")" != 0 ]] \
    && ok 'the build carries our patches' || bad 'the build carries NO patches'
}

# --- case c: the negative control --------------------------------------------
# The mutation is named, minimal and faithful: 0b's trigger is forced false, so
# the pipeline hands tweakcc the live patched image exactly as it did before 0b
# existed. Everything else -- including 1b's repair of the backup and the
# post-stage assertion -- is left alone, because the point is to prove case (a)'s
# assertions detect THIS, not to disable the whole file.
case_c() {
  local d log rc ino_before ino_after kit reddened=0
  kit="$ROOT/kit"; mkdir -p "$kit"
  # A directory of symlinks: `dirname "$0"` inside the pipeline must resolve to
  # something that has tweakcc-patch.js, tools/ and judge/ beside it, and the
  # source tree must stay untouched.
  local f
  for f in "$HERE"/* "$HERE"/.[!.]*; do
    [[ -e "$f" ]] || continue
    ln -sfn "$f" "$kit/$(basename "$f")"
  done
  rm -f "$kit/claude-patch-all.sh"
  sed 's/&& grep -q -a -F "\$OUR_MARKER" "\$BIN"; then/\&\& false; then/' \
    "$PIPELINE" > "$kit/claude-patch-all.sh"
  if cmp -s "$PIPELINE" "$kit/claude-patch-all.sh"; then
    bad 'the mutation did not apply -- 0b no longer has the expected trigger, so this control proves nothing'
    return
  fi

  d="$(stage_dir c)"; log="$ROOT/c.log"
  cp -p "$PATCHED"  "$d/claude"
  cp -p "$PRISTINE" "$d/claude.orig"
  ino_before="$(inode "$d/claude")"
  echo "case c (negative control): same as (a), with 0b's trigger forced false"
  run_pipeline "$kit/claude-patch-all.sh" "$d" "$log"; rc=$?
  ino_after="$(inode "$d/claude")"

  grep -q 'rebuilding from the pristine copy' "$log" || { reddened=$((reddened+1)); note 'red' 'staging branch not taken'; }
  [[ "$ino_before" == "$ino_after" ]] && { reddened=$((reddened+1)); note 'red' "patched in place (inode $ino_after)"; }
  [[ "$(marks "$TWEAKCC_BACKUP")" != 0 ]] && { reddened=$((reddened+1)); note 'red' "tweakcc's backup poisoned"; }
  [[ $rc -ne 0 ]] && { reddened=$((reddened+1)); note 'red' "pipeline refused (rc=$rc)"; }

  if [[ $reddened -gt 0 ]]; then
    ok "the mutation reddens $reddened of case (a)'s assertions"
  else
    bad 'the mutation changed NOTHING: case (a) passes with 0b disabled, so it is not testing 0b'
  fi
}

for c in $(echo "$CASES" | grep -o .); do
  case "$c" in
    a) case_a ;;
    b) case_b ;;
    c) case_c ;;
    *) echo "unknown case: $c" >&2; exit 2 ;;
  esac
done

if [[ $FAILED -eq 0 ]]; then
  echo "build path: every assertion held, and the control shows they have teeth"
else
  echo "build path: $FAILED assertion(s) failed; logs under $ROOT (kept)" >&2
  KEEP_ROOT=1
  exit 1
fi
