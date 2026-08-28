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
#      -> must ALSO stage, from the live bytes themselves, and must first keep
#         those bytes as `.orig`. Patching in place there was a hole of its own:
#         the live installation was the build for the whole run, so a gate that
#         fired late left the human with an image that had been patched and then
#         declared unfit, while the run reported a refusal.
#   c  the negative control: case (a) again, but against a copy of the pipeline
#      with 0b disabled entirely. At least one of case (a)'s assertions MUST go
#      red -- otherwise those assertions are decoration and this probe proves
#      nothing. The probe names which ones reddened.
#   d  the same control for case (b): 0b disabled, live binary pristine.
#   u  the installer's own `--update` path, offline and in seconds: it must
#      build BESIDE the target and swap by rename, never download over the live
#      file. Its control is a copy of claude_patch.py with the staging removed.
#
# Case (c) runs a mutant copy of the pipeline out of a directory of symlinks to
# this kit, so nothing is written into the source tree; and it snapshots
# ~/.tweakcc/native-binary.backup first, because a mutant whose whole point is to
# hand tweakcc a patched image may well poison it -- that is the failure being
# demonstrated. The snapshot is restored, and the restore verified, on every exit
# path including a kill.
#
# Exit codes: 0 green; 3 cannot measure (pipeline lock busy, the lock instrument
# or the backup guard red); 5 nothing to measure ON THIS MACHINE (no patched
# install with a pristine twin beside it); 1 a case went red.
#
# Called by tools/sweep.sh as a pre-flight, once per sweep: this branch is
# invisible to every check in the pipeline, and a tool nobody calls has been
# dead three times in this kit.
#
# Usage:  bash tools/build-path-probe.sh [--case abcdu] [--version 2.1.247]
# Cost:   one full run per case (tweakcc + our patches + the pipeline's 114
#         checks + the interface gate + the bench), so a few minutes each.

set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE="$HERE/claude-patch-all.sh"
OUR_MARKER='baseURL:/^claude/i.test('
TWEAKCC_BACKUP="$HOME/.tweakcc/native-binary.backup"

VERSIONS="$HOME/.local/share/claude/versions"
CASES=abcdu
WANT_VER=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --case)    CASES="$2"; shift 2 ;;
    --version) WANT_VER="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Замок берётся ПОСЛЕ разбора аргументов. Раньше он стоял выше, и `--help` во
# время свипа отвечал «конвейер уже работает» вместо текста использования --
# отказ там, где ничего разделять не нужно: аргументы читаются без единого
# касания общего состояния.
#
# А перед самим замком гоняется прибор замка. Зонд пути сборки опирается на то,
# что владение передаётся детям и держится всё его время; если этот механизм
# сломан, зонд молча измерял бы не то. Прибор дешёв (секунды), у него свой
# TMPDIR, настоящего замка он не касается. Заодно это единственный вызывающий
# прибора: инструмент, которого никто не зовёт, в этом ките уже трижды
# оказывался мёртвым, и за его тишиной каждый раз лежал дефект.
if ! bash "$(dirname "$0")/lock-probe.sh"; then
  echo "ОТКАЗ: прибор замка не сошёлся -- не измеряю путь сборки на сломанном замке." >&2
  exit 3
fi

# По той же причине -- страж «цель против бэкапа tweakcc». Зонд трижды
# запускает конвейер по своим целям; если страж сломан в сторону ложного
# срабатывания, кейсы зонда упрутся в отказ и он измерит не то, а если в
# сторону молчания -- обе стороны будут зелены при подменённом входе. Проба
# ничего не собирает и настоящего бэкапа не касается: секунды.
if ! bash "$(dirname "$0")/backup-divergence-probe.sh"; then
  echo "ОТКАЗ: страж «цель против бэкапа» не сошёлся -- не измеряю путь сборки." >&2
  exit 3
fi

# ЗАМОК НА ВСЁ ВРЕМЯ ЗОНДА, а не внутри каждого дочернего прогона.
#
# Зонд одалживает ЖИВОЕ состояние `~/.tweakcc` -- снимает `config.json` и
# `native-binary.backup`, гоняет три полных прогона конвейера, восстанавливает.
# Замок конвейера закрывает только время самого прогона; между кейсами и на
# восстановлении его нет. В это окно настоящий прогон (или прямой tweakcc)
# законно обновляет backup шагом 1b и `ccVersion` в startupCheck -- а
# восстановление зонда, которое отличает «своя порча» от «чужая работа» только
# по `cmp`, откатывает и то и другое на снимок сорокаминутной давности.
# Последствие ровно то, ради обнаружения которого зонд написан: откаченный
# `ccVersion` заставляет следующий startupCheck освежить backup из
# УСТАНОВЛЕННОГО (пропатченного) бинаря -- отравление, диагностируемое много
# позже как «site not found».
#
# То же окно у seed_version_mismatch: он пишет живой конфиг ДО того, как
# ребёнок возьмёт замок, и способен лечь между `--list-patches` и `--apply`
# чужого прогона (каждый вызов tweakcc читает конфиг заново).
#
# Поэтому замок берётся ЗДЕСЬ и держится до выхода, а дочерние прогоны получают
# его по наследству через CLAUDE_PATCH_LOCK_HELD_BY: взяв замок заново, ребёнок
# встал бы против собственного родителя. Конвейер эту заявку проверяет, а не
# принимает на слово (см. его преамбулу).
# Ручка та же, что у конвейера и свипа. Зонд её НЕ читал и брал боевой файл:
# прогон, уведённый на отдельный замок, получал зонд, севший на замок соседа --
# то есть ровно ту встречную блокировку, против которой ручка и заведена.
# Форма выражения одна во всех четырёх домах и запинена стендом: преамбула
# конвейера обязана оставаться самодостаточной (lock-probe исполняет её
# ОТДЕЛЬНО, вырезав из файла), поэтому общий файл сюда не подключить.
LOCK_FILE="${CLAUDE_PATCH_LOCK:-${TMPDIR:-/tmp}/claude-patch-all.$(id -u).lock}"
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1 && flock -n 9; then
  :
elif perl -e '
      use Fcntl ":flock";
      open(my $fh, ">&=9") or exit 2;
      exit(flock($fh, LOCK_EX|LOCK_NB) ? 0 : 1);
    '; then
  :
else
  __rc=$?
  # «Занято» и «прибор не сработал» -- разные ответы, и второй нельзя читать как
  # первый: молчаливое продолжение без замка и есть тот вход, на котором зонд
  # откатывает чужую работу.
  if [[ $__rc -eq 1 ]]; then
    echo "ОТКАЗ: конвейер уже работает (замок $LOCK_FILE занят)." >&2
    echo "       Зонд одалживает живой ~/.tweakcc и рядом с ним идти не может." >&2
    echo "       Кто держит:  lsof $LOCK_FILE" >&2
  else
    echo "ОТКАЗ: не удалось взять замок (perl rc=$__rc)." >&2
    echo "       Без замка зонд откатит чужую работу на свой снимок -- не иду." >&2
  fi
  exit 3
fi
export CLAUDE_PATCH_LOCK_HELD_BY=$$

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
inode() {
  [[ -f "$1" ]] || { echo "absent"; return 0; }
  stat -f%i "$1" 2>/dev/null || stat -c%i "$1" 2>/dev/null || echo "none"
}
# Отсутствие и «оба диалекта промолчали» -- РАЗНЫЕ ответы, и ни один из них не
# является инодом. Потребитель сравнивает ДО с ПОСЛЕ, поэтому обязан отвергать
# оба, а не радоваться неравенству.
is_inode() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
self_test_inode() {
  local t; t="$(mktemp)"
  is_inode "$(inode "$t")" || { echo "ПРОВАЛ самопроверки inode(): живой файл не дал инода" >&2; rm -f "$t"; exit 1; }
  rm -f "$t"
  is_inode "$(inode "$t")" && { echo "ПРОВАЛ самопроверки inode(): исчезнувший файл дал инод" >&2; exit 1; }
  return 0
}
self_test_inode

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
# «Нет материала» и «не могу мерить» -- РАЗНЫЕ ответы, и второй нельзя читать
# как первый. Оба уезжали кодом 3, а его же отдаёт занятый замок и красный
# прибор: вызывающий (предполёт свипа) не мог отличить «на этой машине нечего
# мерить» от «механизм сломан», и любая политика по коду 3 была бы неверна для
# одной из сторон. Материал -- 5, отказы остаются на 3.
if [[ -z "$WANT_VER" || ! -f "$PATCHED" || ! -f "$PRISTINE" ]]; then
  echo "SKIP: need both $PATCHED and $PRISTINE" >&2
  echo "  (install a version with: bash claude-patch-all.sh --update <version>)" >&2
  exit 5
fi
if [[ "$(marks "$PATCHED")" == 0 ]]; then
  echo "SKIP: $PATCHED does not carry our patches, so case (a) has nothing to preserve" >&2
  exit 5
fi
if [[ "$(marks "$PRISTINE")" != 0 ]]; then
  echo "SKIP: $PRISTINE is not pristine -- it carries our marker" >&2
  exit 5
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cc-build-path-probe.XXXXXX")"
BACKUP_SNAP="$ROOT/native-binary.backup.snapshot"
[[ -f "$TWEAKCC_BACKUP" ]] && cp -p "$TWEAKCC_BACKUP" "$BACKUP_SNAP"
TWEAKCC_CFG="$HOME/.tweakcc/config.json"
CFG_SNAP="$ROOT/config.json.snapshot"
# Три состояния, а не два: конфиг был и снят в снимок; конфига не было и его
# создаст сам зонд (тогда после прогона файл надо УБРАТЬ, а не «восстановить»);
# конфиг был, но снять не удалось. Без третьего флага зонд, создавший конфиг на
# чистой машине, оставлял бы его человеку навсегда.
CFG_WAS_ABSENT=0
if [[ -f "$TWEAKCC_CFG" ]]; then
  cp -p "$TWEAKCC_CFG" "$CFG_SNAP"
else
  CFG_WAS_ABSENT=1
fi

cleanup() {
  # Restore the borrowed config first: it carries the seeded version, and leaving
  # a bogus one behind makes the next real tweakcc run refresh its backup from
  # whatever binary happens to be installed -- the exact poisoning this probe is
  # about, caused by the probe.
  if [[ "${CFG_WAS_ABSENT:-0}" == "1" ]]; then
    # Конфига до зонда не было. Восстанавливать нечего -- надо убрать свой,
    # иначе зонд оставляет человеку файл с ccVersion=0.0.0-probe, то есть ровно
    # ту рассинхронизацию, ради обнаружения которой он его и завёл.
    if [[ -f "$TWEAKCC_CFG" ]]; then
      rm -f "$TWEAKCC_CFG" && echo "removed $TWEAKCC_CFG (the probe created it; there was none before)"
    fi
  elif [[ -f "$CFG_SNAP" ]]; then
    if ! cmp -s "$CFG_SNAP" "$TWEAKCC_CFG" 2>/dev/null; then
      cp -p "$CFG_SNAP" "$TWEAKCC_CFG.probe-restore" \
        && mv "$TWEAKCC_CFG.probe-restore" "$TWEAKCC_CFG" \
        && echo "restored $TWEAKCC_CFG from the probe's snapshot" \
        || echo "WARNING: could not restore $TWEAKCC_CFG from $CFG_SNAP" >&2
    fi
  fi
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

# Драйвер случая (u) пишется на диск здесь, а не встраивается в тело функции:
# его надо запустить ДВАЖДЫ -- по киту дерева и по мутированной копии, -- и обе
# половины обязаны исполнять ОДИН И ТОТ ЖЕ текст, иначе контроль сравнивает
# разные приборы.
cat > "$ROOT/update-probe.py" <<'UPDATE_PROBE'
"""Куда пишет `claude_patch.py --update`: в живой файл или рядом с ним.

Сеть и настоящий патч заменены заглушками -- измеряется не содержимое сборки, а
ИМЯ ФАЙЛА, в который пишет каждый шаг. Аргумент -- каталог с claude_patch.py
(дерево кита или мутированная копия).
"""
import os
import shutil
import sys
import tempfile
from pathlib import Path

kit = sys.argv[1]
sys.path.insert(0, kit)
import claude_patch as m

LIVE = b'PRISTINE-STOCK-IMAGE-no-patches'
FRESH = b'FRESH-STOCK-BYTES-FROM-REGISTRY'
BUILT = b'PATCHED-BYTES-with-marker-' + m.ROUTING_MARKER

failed = []


def probe(patch_works):
    root = Path(tempfile.mkdtemp(prefix='update-probe.'))
    try:
        vdir = root / 'versions'
        vdir.mkdir()
        target = vdir / '0.0.900'
        target.write_bytes(LIVE)
        repointed = []

        m.versions_dir = lambda: vdir
        m.download_binary = lambda version, dest: Path(dest).write_bytes(FRESH)
        m.repoint_launcher = lambda t: repointed.append(Path(t))

        def fake_patch(t, backup=None):
            if not patch_works:
                raise RuntimeError('патч упал (так и задумано)')
            Path(t).write_bytes(BUILT)
        m.patch_binary = fake_patch

        try:
            m.main(['--update', '0.0.900'])
            crashed = None
        except BaseException as e:          # SystemExit тоже
            crashed = repr(e)

        now = target.read_bytes()
        orig = vdir / '0.0.900.orig'
        staging_orig = vdir / '0.0.900.staging.orig'
        staging = vdir / '0.0.900.staging'
        if patch_works:
            if crashed:
                failed.append('успешный патч, а прогон упал: %s' % crashed)
            if now != BUILT:
                failed.append('цель не получила собранные байты (%r)' % now[:40])
            if staging.exists():
                failed.append('стадия осталась на диске: %s' % staging.name)
            if repointed != [target]:
                failed.append('лаунчер переведён не на цель: %r' % repointed)
        else:
            if not crashed:
                failed.append('патч упал, а прогон объявил успех')
            if now != LIVE:
                failed.append('ЖИВОЙ ФАЙЛ ПЕРЕПИСАН при упавшем патче: %r' % now[:40])
            if repointed:
                failed.append('лаунчер переведён при упавшем патче: %r' % repointed)
        if not orig.exists():
            failed.append('пристинная копия .orig не создана')
        elif orig.read_bytes() != FRESH:
            failed.append('.orig не из байт реестра: %r' % orig.read_bytes()[:40])
        if staging_orig.exists():
            failed.append('создана вторая копия под именем стадии: %s' % staging_orig.name)
    finally:
        shutil.rmtree(root, ignore_errors=True)


probe(patch_works=False)
probe(patch_works=True)
if failed:
    for f in failed:
        print('ПРОВАЛ ' + f)
    sys.exit(1)
print('ok --update строит рядом с целью и подменяет переименованием')
UPDATE_PROBE

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
# tweakcc's startupCheck refreshes its backup from `ccInstallationPath` only
# when the recorded version differs from the installed one. Without a mismatch
# the backup is never rewritten, so "the backup is still stock" holds in every
# case for a reason that has nothing to do with what is being tested -- and the
# control could not redden it no matter what it disabled. Seeded before EVERY
# run, because tweakcc records the real version once it refreshes and would not
# fire a second time.
seed_version_mismatch() {
  # Прежняя форма молча возвращалась, если конфига нет: `[[ -f ... ]] || return 0`.
  # На машине без конфига seed не срабатывал НИКОГДА, а значит утверждение
  # «бэкап всё ещё штатный» держалось по причине, не связанной с предметом
  # проверки, и отрицательный контроль не мог его покраснить -- при этом зонд
  # всё равно печатал, что контроль показал зубы.
  #
  # Отсутствие конфига -- не причина не мерить: tweakcc читает его как
  # `{...defaultConfig, ...JSON.parse(content)}` (src/config.ts:253), поэтому
  # файл из одного ключа законен, а после прогона он убирается (CFG_WAS_ABSENT).
  mkdir -p "$(dirname "$TWEAKCC_CFG")"
  [[ -f "$TWEAKCC_CFG" ]] || printf '{}\n' > "$TWEAKCC_CFG"
  python3 - "$TWEAKCC_CFG" <<'PY'
import json, os, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg['ccVersion'] = '0.0.0-probe'
# The LIVE config of the person running this probe. Staged and renamed: the
# probe's restore runs from a trap, and a trap does not run on SIGKILL, so a
# torn write here would outlive the probe.
tmp = p + '.probe-new'
with open(tmp, 'w', encoding='utf-8') as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
os.replace(tmp, p)
PY
}

run_pipeline() {  # <script> <bindir> <logfile>
  seed_version_mismatch
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
  # Неравенство инодов -- утверждение о ДВУХ существующих файлах. Ответ
  # "absent"/"none" не инод, и пропускать его как «изменился» значит
  # засчитывать исчезновение бинарника за успешную подмену.
  if ! is_inode "$ino_before" || ! is_inode "$ino_after"; then
    bad "инод не измерен (до=$ino_before после=$ino_after): файла нет или stat промолчал"
  elif [[ "$ino_before" != "$ino_after" ]]; then
    ok "swapped in by rename (inode $ino_before -> $ino_after)"
  else
    bad "same inode $ino_after: patched in place, under any running session"
  fi
  [[ -e "$d/claude.staging" ]] \
    && bad 'left a staging file behind' || ok 'no staging file left behind'
  [[ "$(marks "$d/claude")" != 0 ]] \
    && ok 'the build that landed carries our patches' \
    || bad 'the build that landed carries NO patches'
  # `marks` answers 0 for a stock file AND for one that is not there (its own
  # self-test asserts exactly that), so testing only the count lets ABSENCE pass
  # as cleanliness. After a full pipeline run the backup exists -- tweakcc makes
  # it -- and its disappearance is its own finding, with its own words.
  if [[ ! -f "$TWEAKCC_BACKUP" ]]; then
    bad "tweakcc's backup is GONE -- there is nothing to restore from"
  elif [[ "$(marks "$TWEAKCC_BACKUP")" == 0 ]]; then
    ok "tweakcc's backup is still stock"
  else
    bad "tweakcc's backup now holds OUR build -- --restore would hand out patched bytes"
  fi
}

# --- case b: nothing to preserve ---------------------------------------------
case_b() {
  local d log rc ino_before ino_after
  d="$(stage_dir b)"; log="$ROOT/b.log"
  cp -p "$PRISTINE" "$d/claude"
  ino_before="$(inode "$d/claude")"
  echo "case b: live binary pristine, no copy beside it"
  run_pipeline "$PIPELINE" "$d" "$log"; rc=$?
  ino_after="$(inode "$d/claude")"

  [[ $rc -eq 0 ]] && ok "pipeline finished (rc=0)" || bad "pipeline exited rc=$rc (see $log)"
  grep -q 'building beside it into' "$log" \
    && ok 'took the staging branch from the live bytes' \
    || bad 'patched the live file in place -- a late gate would leave it half-built'
  if ! is_inode "$ino_before" || ! is_inode "$ino_after"; then
    bad "инод не измерен (до=$ino_before после=$ino_after): файла нет или stat промолчал"
  elif [[ "$ino_before" != "$ino_after" ]]; then
    ok "swapped in by rename (inode $ino_before -> $ino_after)"
  else
    bad "same inode $ino_after: patched in place, under any running session"
  fi
  [[ -e "$d/claude.staging" ]] \
    && bad 'left a staging file behind' || ok 'no staging file left behind'
  # Пристинные байты не должны исчезнуть вместе с подменой: `.orig` -- это то,
  # из чего пересобирает следующий прогон по умолчанию и что чинит бэкап
  # tweakcc. На чистой машине его раньше не появлялось вовсе, и ВТОРОЙ прогон
  # отказывал с «нет пристинной копии рядом».
  if [[ ! -f "$d/claude.orig" ]]; then
    bad 'pristine bytes are gone: no .orig beside the build'
  elif [[ "$(marks "$d/claude.orig")" != 0 ]]; then
    bad '.orig carries our patches -- it is not a pristine copy'
  else
    ok 'the live pristine bytes were kept as .orig'
  fi
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
  # Anchored to 0b's OUTER condition -- the line that decides whether a default
  # run stages at all. Both branches inside it (live patched -> from `.orig`,
  # live pristine -> from the live bytes) are disabled by this one edit, which
  # is exactly the state the pipeline was in before this wave.
  #
  # The anchor is the whole line, so a rewrite that touches a second guard shows
  # up as a changed-line count and refuses. Faithfulness of a mutation is not a
  # matter of intent: it is counted.
  sed -E 's/^if \[\[ -z "\$TARGET" && \$DO_UPDATE -eq 0 && \$ONLY_OURS -eq 0 \]\]; then$/if false; then/' \
    "$PIPELINE" > "$kit/claude-patch-all.sh"
  local changed
  changed=$(diff "$PIPELINE" "$kit/claude-patch-all.sh" | grep -c '^< ' || true)
  case "$changed" in ''|*[!0-9]*) changed=0 ;; esac
  if [[ "$changed" -eq 0 ]]; then
    bad 'the mutation did not apply -- 0b no longer has the expected trigger, so this control proves nothing'
    return
  fi
  if [[ "$changed" -ne 1 ]]; then
    bad "the mutation rewrote $changed lines, not 1 -- it is disabling more than 0b, so nothing it shows is about 0b"
    return
  fi

  d="$(stage_dir c)"; log="$ROOT/c.log"
  cp -p "$PATCHED"  "$d/claude"
  cp -p "$PRISTINE" "$d/claude.orig"
  ino_before="$(inode "$d/claude")"
  echo "case c (negative control): same as (a), with 0b's trigger forced false"
  run_pipeline "$kit/claude-patch-all.sh" "$d" "$log"; rc=$?
  ino_after="$(inode "$d/claude")"

  # The REQUIRED red is named, and it is the one 0b is: without 0b the pipeline
  # cannot announce a staging rebuild. Counting "at least one" let any mutant
  # that merely crashes the pipeline -- a syntax error, a missing bun, an
  # unrelated guard tripping -- pass as proof about the staging branch.
  local required=0
  grep -q 'rebuilding from the pristine copy' "$log" || { required=1; note 'red' 'staging branch not taken'; }
  if ! is_inode "$ino_before" || ! is_inode "$ino_after"; then
    note 'info' "инод не измерен (до=$ino_before после=$ino_after) -- не засчитано"
  elif [[ "$ino_before" == "$ino_after" ]]; then
    reddened=$((reddened+1)); note 'red' "patched in place (inode $ino_after)"
  fi
  [[ "$(marks "$TWEAKCC_BACKUP")" != 0 ]] && { reddened=$((reddened+1)); note 'red' "tweakcc's backup poisoned"; }
  # Reported, never counted: a pipeline that refused says nothing about which
  # assertion has teeth, and it is the most likely way a future mutation goes
  # wrong without anyone noticing.
  [[ $rc -ne 0 ]] && note 'info' "pipeline refused (rc=$rc) -- not counted as evidence"

  if [[ $required -eq 1 ]]; then
    ok "the mutation reddens the staging assertion, and $reddened more of case (a)'s"
  else
    bad 'the mutation changed NOTHING about the staging branch: case (a) is not testing 0b'
  fi
}

# --- case d: the negative control for case (b) -------------------------------
# Case (c) proves case (a)'s assertions have teeth on the PATCHED-live branch.
# The pristine-live branch is separate code with its own assertions, so it needs
# its own control -- otherwise "the default run always stages" is proven for one
# half and asserted for the other.
case_d() {
  local d log rc ino_before ino_after kit reddened=0 required=0
  kit="$ROOT/kit"
  if [[ ! -f "$kit/claude-patch-all.sh" ]]; then
    bad 'case (d) needs the mutant kit built by case (c) -- run them together (--case cd)'
    return
  fi
  d="$(stage_dir d)"; log="$ROOT/d.log"
  cp -p "$PRISTINE" "$d/claude"
  ino_before="$(inode "$d/claude")"
  echo "case d (negative control): same as (b), with 0b disabled"
  run_pipeline "$kit/claude-patch-all.sh" "$d" "$log"; rc=$?
  ino_after="$(inode "$d/claude")"

  grep -q 'building beside it into' "$log" || { required=1; note 'red' 'staging branch not taken'; }
  if ! is_inode "$ino_before" || ! is_inode "$ino_after"; then
    note 'info' "инод не измерен (до=$ino_before после=$ino_after) -- не засчитано"
  elif [[ "$ino_before" == "$ino_after" ]]; then
    reddened=$((reddened+1)); note 'red' "patched in place (inode $ino_after)"
  fi
  [[ -f "$d/claude.orig" ]] || { reddened=$((reddened+1)); note 'red' 'pristine bytes not kept'; }
  [[ $rc -ne 0 ]] && note 'info' "pipeline refused (rc=$rc) -- not counted as evidence"

  if [[ $required -eq 1 ]]; then
    ok "the mutation reddens case (b)'s staging assertion, and $reddened more"
  else
    bad 'the mutation changed NOTHING about the pristine-live branch: case (b) is not testing 0b'
  fi
}

# --- case u: the installer's own --update path -------------------------------
# Offline and in seconds: the network fetch and the byte patch are both replaced
# by stubs, because what is being measured is WHICH FILE each step writes to.
#
# The defect this exists for: `--update` downloaded straight into the target. If
# the requested version was the installed one and merely unpatched (a restore,
# an interrupted run, a fresh image), the launcher's own file was truncated and
# refilled over the network -- and a run that died in that window left the
# installation broken for good. patch_binary has staged its write since the
# beginning; the download was the one step that still wrote through the live
# name.
case_u() {
  local out rc mut
  echo "case u: claude_patch.py --update builds beside the target"
  out="$(python3 "$ROOT/update-probe.py" "$HERE" 2>&1)"; rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  [[ $rc -eq 0 ]] && ok 'the --update path never writes through the live name' \
                  || bad "the --update path wrote through the live name (see above)"

  # Отрицательный контроль: копия установщика без стадии. Утверждение обязано
  # покраснеть -- иначе оно ничего не проверяет.
  # Кит копии -- ПОЛНЫЙ: `main()` первым делом требует patch_claude_routing.py
  # рядом с собой, и копия из одного файла краснела с чужой причиной («нет
  # patch_claude_routing.py»), то есть доказывала сломанный прибор, а не
  # отсутствие стадии.
  mut="$ROOT/mutkit"; mkdir -p "$mut"
  cp "$HERE/claude_patch.py" "$HERE/patch_claude_routing.py" "$mut/"
  python3 - "$mut/claude_patch.py" <<'MUT'
import sys

p = sys.argv[1]
t = open(p, encoding='utf-8').read()
# Якорь НАЧИНАЕТСЯ С ПЕРЕВОДА СТРОКИ, и это не украшение: тот же оператор есть
# в ветке --download-only с отступом в 12 пробелов, а поиск по восьми пробелам
# -- ЕГО ПОДСТРОКА. Первая редакция контроля так и села на чужую ветку: мутация
# «применилась», прогон вёл себя как исправный, и контроль объявил утверждение
# беззубым, ничего о нём не измерив.
NEEDLE = ('\n        staging = target.with_name(target.name + ".staging")\n'
          '        download_binary(version, staging)\n')
if t.count(NEEDLE) != 1:
    sys.exit('МУТАЦИЯ НЕ ПРИМЕНИЛАСЬ: якорь ветки --update найден %d раз' % t.count(NEEDLE))
t2 = t.replace(NEEDLE, '\n        staging = target\n        download_binary(version, staging)\n', 1)
if t2.count('.with_name(target.name + ".staging")') != 1:
    sys.exit('МУТАЦИЯ ЗАДЕЛА ЧУЖУЮ ВЕТКУ: стадий осталось %d'
             % t2.count('.with_name(target.name + ".staging")'))
open(p, 'w', encoding='utf-8').write(t2)
MUT
  if [[ $? -ne 0 ]]; then
    bad 'case (u) control: the mutation did not apply -- it proves nothing'
    return
  fi
  out="$(python3 "$ROOT/update-probe.py" "$mut" 2>&1)"; rc=$?
  # Требуется НАЗВАННАЯ причина: упавший прибор (нет соседнего файла, опечатка
  # в мутации) тоже даёт ненулевой код, и без имени причины беззубость
  # неотличима от исправности.
  if [[ $rc -ne 0 && "$out" == *"ЖИВОЙ ФАЙЛ ПЕРЕПИСАН"* ]]; then
    ok "the control reddens it by its own cause: $(printf '%s' "$out" | grep -m1 'ЖИВОЙ ФАЙЛ')"
  elif [[ $rc -ne 0 ]]; then
    bad "the control reddened by a FOREIGN cause: $(printf '%s' "$out" | grep -m1 'ПРОВАЛ\|ERROR')"
  else
    bad 'the control did NOT redden: case (u) is not testing the staging'
  fi
}

for c in $(echo "$CASES" | grep -o .); do
  case "$c" in
    a) case_a ;;
    b) case_b ;;
    c) case_c ;;
    d) case_d ;;
    u) case_u ;;
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
