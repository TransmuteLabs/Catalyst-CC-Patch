#!/usr/bin/env bash
# Прополка тяжёлых артефактов патч-конвейера.
#
# По умолчанию только перечисляет. Сносит кандидатов только при явном --apply.
# Боевые корни в --self-check не участвуют: зубы гоняют свою фикстуру.
#
# Коды:
#   0  перепись прошла (таблица на stdout; с --apply кандидаты сняты)
#   2  прибор не смог измерить: корень недоступен, нет python3/lsof, lsof
#      не прошёл положительный контроль
#   3  НЕ ИЗМЕРЕНО: имя попало под правило, а размер/возраст снять не удалось
#      — частичная таблица не выдаётся и --apply не исполняется
#
# КОНСТРЕЙНТ (жёсткий список, не трогать НИКОГДА):
#   * бэкап образа в ~/.tweakcc (и любой путь внутри этого корня);
#   * пристинные копии корпуса поддерживаемых версий (>= пола);
#   * активная версия и цель активного указателя (launcher symlink), плюс .orig;
#   * файлы, которые сейчас открыты живым процессом;
#   * всё вне перечисленных корней.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$HERE/.." && pwd)

# --- ОДИН дом порогов. Второго присваивания этих имён в файле нет. ---
DEFAULT_OLDER_THAN_HOURS=6
DEFAULT_MIN_SIZE_MB=100

die2() { printf '%s\n' "$*" >&2; exit 2; }
die3() { printf '%s\n' "$*" >&2; exit 3; }

usage() {
  cat <<EOF
usage: bash tools/reap-heavy.sh [--apply] [--older-than-hours N] [--min-size-mb N]
                               [--fixture DIR] [--self-check]

  без --apply     таблица кандидатов (path, mb, age_h, reason), ничего не сносит
  --apply         снести ровно кандидатов таблицы
  --self-check    шесть зубов на своей фикстуре; боевые корни не участвуют

Корни (боевой прогон):
  \${TMPDIR:-/tmp}     cc-build-path-probe.* и checks-teeth.<pid>.*.bin
  /tmp/cc-matrix/bin   копии образов волн
  ~/.local/share/claude-patch/corpus
  ~/.local/share/claude/versions
  ~/ccpatch
  /tmp/claude-<uid>    скратчпады сессий (файлы >= --min-size-mb)

Пол поддержки читается из tools/corpus-versions.txt (минимум активной строки).
EOF
}

require_python() {
  command -v python3 >/dev/null || die2 "ОТКАЗ: нет python3 — прибор недоступен"
}

# Суффикс имени файла корпуса живёт в одном доме -- tools/corpus-file-name.sh;
# литерал здесь был бы второй копией знания (ценз единственности суффикса в
# корпусном стенде). Дом опрашивается пробным вызовом с пустой версией:
# имя пустой версии -- это и есть суффикс. ПУСТО НЕ НОЛЬ: дом не нашёлся или
# не ответил -- код 2, ценз корпуса не слепнет молча.
load_corpus_suffix() {
  [[ -f "$HERE/corpus-file-name.sh" ]] \
    || die2 "ОТКАЗ: нет дома имени корпуса $HERE/corpus-file-name.sh"
  . "$HERE/corpus-file-name.sh"
  local probe
  probe=$(corpus_file_name '')
  [[ -n "$probe" ]] \
    || die2 "ОТКАЗ: дом имени корпуса не дал суффикса -- ценз корпуса слеп"
  REAP_CORPUS_SUFFIX=$probe
  export REAP_CORPUS_SUFFIX
}

# MUT_REQUIRE_LSOF: пустой результат lsof без положительного контроля недействителен.
# Нет бинаря или бинарь не видит собственный процесс — код 2, не «открытых нет».
require_lsof() {
  LSOF=$(command -v lsof || true)
  if [[ -z "$LSOF" ]]; then
    printf '%s\n' "ОТКАЗ: нет lsof — прибор недоступен (открытые файлы нечем мерить)" >&2
    exit 2
  fi
  local pc
  pc=$("$LSOF" -p $$ -Fn) || true
  if [[ -z "$pc" ]]; then
    printf '%s\n' "ОТКАЗ: lsof не видит файлов своего процесса — прибор недоступен" >&2
    exit 2
  fi
}

parse_args() {
  APPLY=0
  SELF_CHECK=0
  FIXTURE=
  OLDER_THAN_HOURS=$DEFAULT_OLDER_THAN_HOURS
  MIN_SIZE_MB=$DEFAULT_MIN_SIZE_MB
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) APPLY=1; shift ;;
      --self-check) SELF_CHECK=1; shift ;;
      --fixture)
        [[ $# -ge 2 ]] || die2 "ОТКАЗ: --fixture нужен каталог"
        FIXTURE=$2
        shift 2
        ;;
      --older-than-hours)
        [[ $# -ge 2 ]] || die2 "ОТКАЗ: --older-than-hours нужно число"
        OLDER_THAN_HOURS=$2
        shift 2
        ;;
      --min-size-mb)
        [[ $# -ge 2 ]] || die2 "ОТКАЗ: --min-size-mb нужно число"
        MIN_SIZE_MB=$2
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      *) die2 "ОТКАЗ: неизвестный аргумент $1" ;;
    esac
  done
  case "$OLDER_THAN_HOURS" in
    ''|*[!0-9]*) die2 "ОТКАЗ: --older-than-hours должно быть целым неотрицательным, дано '$OLDER_THAN_HOURS'" ;;
  esac
  case "$MIN_SIZE_MB" in
    ''|*[!0-9]*) die2 "ОТКАЗ: --min-size-mb должно быть целым неотрицательным, дано '$MIN_SIZE_MB'" ;;
  esac
}

resolve_roots() {
  if [[ -n "$FIXTURE" ]]; then
    [[ -d "$FIXTURE" ]] || die2 "ОТКАЗ: фикстура недоступна: $FIXTURE"
    REAP_TMP=$FIXTURE/tmp
    REAP_MATRIX=$FIXTURE/cc-matrix/bin
    REAP_CORPUS=$FIXTURE/corpus
    REAP_VERSIONS=$FIXTURE/versions
    REAP_CCPATCH=$FIXTURE/ccpatch
    REAP_SCRATCH=$FIXTURE/scratchpad
    REAP_TWEAKCC=$FIXTURE/tweakcc
    REAP_LAUNCHER=$FIXTURE/bin/claude
    REAP_LIST=$FIXTURE/corpus-versions.txt
  else
    REAP_TMP=${TMPDIR:-/tmp}
    REAP_MATRIX=/tmp/cc-matrix/bin
    REAP_CORPUS=$HOME/.local/share/claude-patch/corpus
    REAP_VERSIONS=$HOME/.local/share/claude/versions
    REAP_CCPATCH=$HOME/ccpatch
    REAP_SCRATCH=/tmp/claude-$(id -u)
    REAP_TWEAKCC=$HOME/.tweakcc
    REAP_LAUNCHER=$HOME/.local/bin/claude
    REAP_LIST=$HERE/corpus-versions.txt
  fi
  [[ -f "$REAP_LIST" ]] || die2 "ОТКАЗ: нет списка версий $REAP_LIST — пол поддержки неизвестен"
}

# MUT_APPLY_FLAG: перечисление не сносит; только явное --apply.
run_census() {
  local __reap_apply=$APPLY
  export REAP_TMP REAP_MATRIX REAP_CORPUS REAP_VERSIONS REAP_CCPATCH
  export REAP_SCRATCH REAP_TWEAKCC REAP_LAUNCHER REAP_LIST
  export REAP_HOURS=$OLDER_THAN_HOURS
  export REAP_MINSIZE=$MIN_SIZE_MB
  export REAP_APPLY=$__reap_apply
  export REAP_LSOF="${LSOF:-}"
  python3 - <<'PY'
from __future__ import print_function
import glob
import os
import shutil
import stat
import subprocess
import sys
import time

def die2(msg):
    sys.stderr.write(msg + '\n')
    sys.exit(2)

def die3(msg):
    sys.stderr.write(msg + '\n')
    sys.exit(3)

def parse_ver(s):
    parts = []
    for p in s.split('.'):
        if not p.isdigit():
            die2("ОТКАЗ: неразобранная версия %r" % s)
        parts.append(int(p))
    if not parts:
        die2("ОТКАЗ: пустая версия")
    return tuple(parts)

def ver_lt(a, b):
    return parse_ver(a) < parse_ver(b)

def read_floor(path):
    vers = []
    try:
        fh = open(path, 'r')
    except OSError as exc:
        die2("ОТКАЗ: не прочитать список версий %s: %s" % (path, exc))
    with fh:
        for raw in fh:
            line = raw.replace('\r', '').split('#', 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) >= 2:
                vers.append(parts[1])
            else:
                die2("ОТКАЗ: строка списка без версии: %r" % raw.rstrip('\n'))
    if not vers:
        die2("ОТКАЗ: в списке нет активных версий — пол неизвестен")
    return min(vers, key=parse_ver)

def realpath(path):
    return os.path.realpath(path)

def exists(path):
    try:
        os.lstat(path)
        return True
    except OSError:
        return False

def under(root, path):
    if not root or not exists(root):
        return False
    r = realpath(root)
    p = realpath(path)
    sep = os.sep
    return p == r or p.startswith(r + sep)

def lstat_or_unmeasured(path):
    try:
        return os.lstat(path)
    except OSError as exc:
        die3("НЕ ИЗМЕРЕНО: не stat %s: %s" % (path, exc))

def tree_bytes(path):
    st = lstat_or_unmeasured(path)
    if stat.S_ISLNK(st.st_mode) or stat.S_ISREG(st.st_mode):
        return st.st_size, st.st_mtime
    if not stat.S_ISDIR(st.st_mode):
        return st.st_size, st.st_mtime
    total = 0
    try:
        for root, dirs, files in os.walk(path, followlinks=False):
            for name in files:
                fp = os.path.join(root, name)
                try:
                    total += os.lstat(fp).st_size
                except OSError as exc:
                    die3("НЕ ИЗМЕРЕНО: не размер %s: %s" % (fp, exc))
    except OSError as exc:
        die3("НЕ ИЗМЕРЕНО: не обойти %s: %s" % (path, exc))
    return total, st.st_mtime

def pid_is_alive(pid):  # MUT_PID_ALIVE
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OverflowError:
        return False
    except OSError:
        return False
    return True

def collect_paths(path):
    out = [path]
    if os.path.isdir(path) and not os.path.islink(path):
        try:
            for root, dirs, files in os.walk(path, followlinks=False):
                for name in files:
                    out.append(os.path.join(root, name))
        except OSError as exc:
            die2("ОТКАЗ: не обойти %s для проверки открытых файлов: %s" % (path, exc))
    return out

def path_is_open(path):  # MUT_PATH_OPEN
    lsof = os.environ.get('REAP_LSOF') or ''
    if not lsof:
        return False
    files = collect_paths(path)
    for i in range(0, len(files), 40):
        chunk = files[i:i + 40]
        try:
            r = subprocess.run([lsof, '-t'] + chunk,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except OSError as exc:
            die2("ОТКАЗ: lsof не запустился на %s: %s" % (path, exc))
        if r.returncode >= 2:
            err = r.stderr.decode('utf-8', 'replace').strip()
            die2("ОТКАЗ: lsof не смог проверить %s (rc=%d) %s" % (path, r.returncode, err))
        if r.stdout.strip():
            return True
    return False

def name_pid_probe(basename):
    # cc-build-path-probe.<suffix> — pid только если суффикс целиком из цифр.
    prefix = 'cc-build-path-probe.'
    if not basename.startswith(prefix):
        return None
    suffix = basename[len(prefix):]
    if suffix.isdigit():
        return int(suffix)
    return None

def name_pid_teeth(basename):
    # checks-teeth.<pid>.<rand>.bin — как пишет tools/checks-teeth.py
    if not (basename.startswith('checks-teeth.') and basename.endswith('.bin')):
        return None
    parts = basename.split('.')
    if len(parts) < 4:
        return None
    if parts[1].isdigit():
        return int(parts[1])
    return None

def remnant_pid(basename):
    # <name>.part.<pid> — как пишет tools/fetch-corpus.sh
    if '.part.' not in basename:
        return None, False
    suffix = basename.rsplit('.', 1)[-1]
    if suffix.isdigit():
        return int(suffix), True
    return None, True

def corpus_version(basename):
    if basename.endswith(corpus_suffix):
        return basename[:-len(corpus_suffix)]
    return None

def versions_version(basename):
    if basename.endswith('.orig'):
        core = basename[:-len('.orig')]
    else:
        core = basename
    if not core:
        return None
    for p in core.split('.'):
        if not p.isdigit():
            return None
    return core

def is_protected(path):  # MUT_PROTECTED
    tweak = os.environ.get('REAP_TWEAKCC') or ''
    if tweak and exists(tweak) and under(tweak, path):
        return True
    return False

def require_root_readable(root, label):
    if not exists(root):
        return False
    if not os.path.isdir(root):
        die2("ОТКАЗ: корень %s не каталог: %s" % (label, root))
    if not os.access(root, os.R_OK | os.X_OK):
        die2("ОТКАЗ: корень недоступен (%s): %s" % (label, root))
    return True

hours = int(os.environ['REAP_HOURS'])  # ONE_HOME_HOURS
minsize = int(os.environ['REAP_MINSIZE']) * 1024 * 1024
do_apply = os.environ.get('REAP_APPLY') == '1'
floor = read_floor(os.environ['REAP_LIST'])
# Суффикс читает родитель из дома имени корпуса; пустой -- отказ прибора:
# без него ценз корпуса не опознаёт ни одного образца (ПУСТО НЕ НОЛЬ).
corpus_suffix = os.environ.get('REAP_CORPUS_SUFFIX') or ''
if not corpus_suffix:
    die2('ОТКАЗ: суффикс имени корпуса не прочитан из дома -- ценз корпуса слеп')
now = time.time()
age_limit = hours * 3600.0

tmp = os.environ['REAP_TMP']
matrix = os.environ['REAP_MATRIX']
corpus = os.environ['REAP_CORPUS']
versions = os.environ['REAP_VERSIONS']
ccpatch = os.environ['REAP_CCPATCH']
scratch = os.environ['REAP_SCRATCH']
launcher = os.environ['REAP_LAUNCHER']

active_target = None
active_ver = None
if exists(launcher):
    try:
        active_target = realpath(launcher)
    except OSError as exc:
        die2("ОТКАЗ: не разрешить активный указатель %s: %s" % (launcher, exc))
    base = os.path.basename(active_target)
    active_ver = versions_version(base)

cands = []  # (path, nbytes, mtime, reason, root)

def add(path, reason, root):
    if not exists(path):
        return
    if not under(root, path):
        return
    if is_protected(path):
        return
    if path_is_open(path):
        return
    nbytes, mtime = tree_bytes(path)
    cands.append((path, nbytes, mtime, reason, root))

# 1. временный каталог: cc-build-path-probe.* и копии зубов
if require_root_readable(tmp, 'tmp'):
    for path in glob.glob(os.path.join(tmp, 'cc-build-path-probe.*')):
        if not os.path.isdir(path):
            continue
        pid = name_pid_probe(os.path.basename(path))
        if pid is not None:
            if pid_is_alive(pid):
                continue
            add(path, 'tmp: pid %d dead' % pid, tmp)
        else:
            st = lstat_or_unmeasured(path)
            if now - st.st_mtime >= age_limit:
                add(path, 'tmp: no pid in name, older than %sh' % hours, tmp)
    for path in glob.glob(os.path.join(tmp, 'checks-teeth.*.bin')):
        if os.path.isdir(path) and not os.path.islink(path):
            continue
        pid = name_pid_teeth(os.path.basename(path))
        if pid is not None:
            if pid_is_alive(pid):
                continue
            add(path, 'tmp: teeth copy, pid %d dead' % pid, tmp)
        else:
            st = lstat_or_unmeasured(path)
            if now - st.st_mtime >= age_limit:
                add(path, 'tmp: teeth copy, no pid, older than %sh' % hours, tmp)

# 2. /tmp/cc-matrix/bin — копии образов волн по возрасту
if require_root_readable(matrix, 'cc-matrix/bin'):
    try:
        names = os.listdir(matrix)
    except OSError as exc:
        die2("ОТКАЗ: не прочитать %s: %s" % (matrix, exc))
    for name in names:
        path = os.path.join(matrix, name)
        if os.path.isdir(path) and not os.path.islink(path):
            continue
        st = lstat_or_unmeasured(path)
        if now - st.st_mtime >= age_limit:
            add(path, 'matrix: older than %sh' % hours, matrix)

# 3. корпус: ТОЛЬКО обрывки загрузки и версии ниже пола.
#    Пристинные копии поддерживаемых версий сюда не попадают.
if require_root_readable(corpus, 'corpus'):
    try:
        names = os.listdir(corpus)
    except OSError as exc:
        die2("ОТКАЗ: не прочитать %s: %s" % (corpus, exc))
    for name in names:
        path = os.path.join(corpus, name)
        pid, is_part = remnant_pid(name)
        if is_part:
            if pid is not None and pid_is_alive(pid):
                continue
            if pid is None:
                add(path, 'corpus: download remnant, non-numeric suffix', corpus)
            else:
                add(path, 'corpus: download remnant, pid %d dead' % pid, corpus)
            continue
        ver = corpus_version(name)
        if ver is None:
            continue
        if ver_lt(ver, floor):
            add(path, 'corpus: version %s below floor %s' % (ver, floor), corpus)

# 4. каталог версий: ниже пола, КРОМЕ цели указателя и открытых живым процессом
if require_root_readable(versions, 'versions'):
    try:
        names = os.listdir(versions)
    except OSError as exc:
        die2("ОТКАЗ: не прочитать %s: %s" % (versions, exc))
    below = []
    for name in names:
        path = os.path.join(versions, name)
        ver = versions_version(name)
        if ver is None:
            continue
        if ver_lt(ver, floor):
            below.append((path, ver, name))
    if below:
        if not exists(launcher):
            die2("ОТКАЗ: есть версии ниже пола, а активный указатель %s отсутствует — не отличить защищённое" % launcher)
        if active_target is None:
            die2("ОТКАЗ: не разрешить активный указатель %s" % launcher)
        for path, ver, name in below:
            if active_ver is not None and ver == active_ver:
                continue
            if active_target is not None and realpath(path) == active_target:
                continue
            add(path, 'versions: version %s below floor %s' % (ver, floor), versions)

# 5. ~/ccpatch — каталоги прогонов по возрасту
if require_root_readable(ccpatch, 'ccpatch'):
    try:
        names = os.listdir(ccpatch)
    except OSError as exc:
        die2("ОТКАЗ: не прочитать %s: %s" % (ccpatch, exc))
    for name in names:
        path = os.path.join(ccpatch, name)
        if not os.path.isdir(path) or os.path.islink(path):
            continue
        st = lstat_or_unmeasured(path)
        if now - st.st_mtime >= age_limit:
            add(path, 'ccpatch: run dir older than %sh' % hours, ccpatch)

# 6. скратчпады: файлы крупнее порога, по возрасту
if require_root_readable(scratch, 'scratch'):
    try:
        for root, dirs, files in os.walk(scratch, followlinks=False):
            for name in files:
                path = os.path.join(root, name)
                try:
                    st = os.lstat(path)
                except OSError as exc:
                    die3("НЕ ИЗМЕРЕНО: не stat %s: %s" % (path, exc))
                if not stat.S_ISREG(st.st_mode):
                    continue
                if st.st_size < minsize:
                    continue
                if now - st.st_mtime >= age_limit:
                    add(path, 'scratch: size >= %sMb, older than %sh' % (os.environ['REAP_MINSIZE'], hours), scratch)
    except OSError as exc:
        die2("ОТКАЗ: не обойти скратчпад %s: %s" % (scratch, exc))

cands.sort(key=lambda r: r[0])
print('path\tmb\tage_h\treason')
for path, nbytes, mtime, reason, root in cands:
    mb = nbytes / 1048576.0
    age_h = (now - mtime) / 3600.0
    print('%s\t%.1f\t%.1f\t%s' % (path, mb, age_h, reason))

if do_apply:
    for path, nbytes, mtime, reason, root in cands:
        if not exists(path):
            continue
        if not under(root, path):
            sys.stderr.write('пропуск (вышел из корня): %s\n' % path)
            continue
        if is_protected(path) or path_is_open(path):
            sys.stderr.write('пропуск (защищено): %s\n' % path)
            continue
        try:
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path)
            else:
                os.remove(path)
        except OSError as exc:
            die2("ОТКАЗ: не снести %s: %s" % (path, exc))
PY
}

# ---------------------------------------------------------------------------
# --self-check: шесть зубов, у каждого свой названный красный.
# Мутации правят КОПИЮ; оригинал не трогается. Снимок + sha256, не git.
# ---------------------------------------------------------------------------

sha256_of() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

say() { printf '%s\n' "$*"; }

build_fixture() {
  # $1 dest  $2 deadpid  $3 livepid  $4 hold_path_var_name
  local fx="$1" deadpid="$2" livepid="$3"
  python3 - "$fx" "$deadpid" "$livepid" <<'PY'
import os, sys, time
fx, dead, live = sys.argv[1], sys.argv[2], sys.argv[3]
# Суффикс имени файла корпуса -- из единого дома, не литералом здесь.
sfx = os.environ['REAP_CORPUS_SUFFIX']
now = time.time()
old = now - 7 * 3600
young = now - 60
os.makedirs(os.path.join(fx, 'tmp'), exist_ok=True)
os.makedirs(os.path.join(fx, 'cc-matrix', 'bin'), exist_ok=True)
os.makedirs(os.path.join(fx, 'corpus'), exist_ok=True)
os.makedirs(os.path.join(fx, 'versions'), exist_ok=True)
os.makedirs(os.path.join(fx, 'ccpatch', 'w100'), exist_ok=True)
os.makedirs(os.path.join(fx, 'ccpatch', 'w101'), exist_ok=True)
os.makedirs(os.path.join(fx, 'scratchpad'), exist_ok=True)
os.makedirs(os.path.join(fx, 'tweakcc'), exist_ok=True)
os.makedirs(os.path.join(fx, 'bin'), exist_ok=True)

def write(path, data, mtime):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(data)
    os.utime(path, (mtime, mtime))

def touchdir(path, mtime):
    os.makedirs(path, exist_ok=True)
    os.utime(path, (mtime, mtime))

two = b'\0' * (2 * 1024 * 1024)
tiny = b'protected-tiny\n'

# garbage / protected in tmp
p_old = os.path.join(fx, 'tmp', 'cc-build-path-probe.oldnopid')
touchdir(p_old, old)
write(os.path.join(p_old, 'blob'), b'old-probe\n', old)
p_young = os.path.join(fx, 'tmp', 'cc-build-path-probe.youngnopid')
touchdir(p_young, young)
write(os.path.join(p_young, 'blob'), b'young-probe\n', young)
write(os.path.join(fx, 'tmp', 'checks-teeth.%s.x.bin' % dead), b'dead-teeth\n', young)
write(os.path.join(fx, 'tmp', 'checks-teeth.%s.x.bin' % live), b'live-teeth\n', old)

# matrix
write(os.path.join(fx, 'cc-matrix', 'bin', '242.wave.bin'), b'old-wave\n', old)
write(os.path.join(fx, 'cc-matrix', 'bin', '273.wave.bin'), b'young-wave\n', young)

# corpus: below floor + supported + remnants
write(os.path.join(fx, 'corpus', '2.1.270' + sfx), b'below\n', old)
write(os.path.join(fx, 'corpus', '2.1.272' + sfx), b'supported-272\n', old)
write(os.path.join(fx, 'corpus', '2.1.273' + sfx), b'supported-273\n', old)
write(os.path.join(fx, 'corpus', '2.1.269' + sfx + '.part.%s' % dead), b'remnant-dead\n', young)
write(os.path.join(fx, 'corpus', '2.1.272' + sfx + '.part.%s' % live), b'remnant-live\n', old)

# versions
write(os.path.join(fx, 'versions', '2.1.270'), b'ver-270\n', old)
write(os.path.join(fx, 'versions', '2.1.270.orig'), b'ver-270-orig\n', old)
write(os.path.join(fx, 'versions', '2.1.272'), b'ver-272\n', old)
write(os.path.join(fx, 'versions', '2.1.273'), b'ver-273\n', old)
write(os.path.join(fx, 'versions', '2.1.273.orig'), b'ver-273-orig\n', old)
os.symlink(os.path.join(fx, 'versions', '2.1.273'), os.path.join(fx, 'bin', 'claude'))

# ccpatch
write(os.path.join(fx, 'ccpatch', 'w100', 'target'), b'old-run\n', old)
touchdir(os.path.join(fx, 'ccpatch', 'w100'), old)
write(os.path.join(fx, 'ccpatch', 'w101', 'target'), b'young-run\n', young)
touchdir(os.path.join(fx, 'ccpatch', 'w101'), young)

# scratch
write(os.path.join(fx, 'scratchpad', 'big-old.bin'), two, old)
write(os.path.join(fx, 'scratchpad', 'big-young.bin'), two, young)
write(os.path.join(fx, 'scratchpad', 'small-old.bin'), tiny, old)
write(os.path.join(fx, 'scratchpad', 'held-open.bin'), two, old)

# NEVER-touch backup
write(os.path.join(fx, 'tweakcc', 'native-binary.backup'), two, old)

with open(os.path.join(fx, 'corpus-versions.txt'), 'w') as fh:
    fh.write('# platform: fixture\n')
    fh.write('272 2.1.272 00\n')
    fh.write('273 2.1.273 00\n')

# Directory mtime moves when children are created; set age AFTER contents.
for p, mt in (
    (os.path.join(fx, 'tmp', 'cc-build-path-probe.oldnopid'), old),
    (os.path.join(fx, 'tmp', 'cc-build-path-probe.youngnopid'), young),
    (os.path.join(fx, 'ccpatch', 'w100'), old),
    (os.path.join(fx, 'ccpatch', 'w101'), young),
):
    os.utime(p, (mt, mt))
PY
}

manifest_of() {
  python3 - "$1" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
rows = []
for dirpath, dirs, files in os.walk(root, followlinks=False):
    dirs.sort(); files.sort()
    for name in dirs:
        p = os.path.join(dirpath, name)
        rows.append('d %s' % p)
    for name in files:
        p = os.path.join(dirpath, name)
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode):
            rows.append('l %s -> %s' % (p, os.readlink(p)))
        else:
            h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
            rows.append('f %s %d %s' % (p, st.st_size, h))
print('\n'.join(sorted(rows)))
PY
}

mutate_copy() {
  local file="$1" n="$2"
  python3 - "$file" "$n" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
text = open(path, encoding='utf-8').read()
if n == 1:
    old = '  local __reap_apply=$APPLY\n'
    new = '  local __reap_apply=1\n'
elif n == 2:
    old = "        if ver_lt(ver, floor):\n            add(path, 'corpus: version %s below floor %s' % (ver, floor), corpus)\n"
    new = "        if True:\n            add(path, 'corpus: version %s below floor %s' % (ver, floor), corpus)\n"
elif n == 3:
    old = 'def pid_is_alive(pid):  # MUT_PID_ALIVE\n    try:\n        os.kill(pid, 0)\n'
    new = 'def pid_is_alive(pid):  # MUT_PID_ALIVE\n    return False\n    try:\n        os.kill(pid, 0)\n'
elif n == 4:
    old = 'def path_is_open(path):  # MUT_PATH_OPEN\n    lsof = os.environ.get(\'REAP_LSOF\') or \'\'\n'
    new = 'def path_is_open(path):  # MUT_PATH_OPEN\n    return False\n    lsof = os.environ.get(\'REAP_LSOF\') or \'\'\n'
elif n == 5:
    old = '''require_lsof() {
  LSOF=$(command -v lsof || true)
  if [[ -z "$LSOF" ]]; then
    printf '%s\\n' "ОТКАЗ: нет lsof — прибор недоступен (открытые файлы нечем мерить)" >&2
    exit 2
  fi'''
    new = '''require_lsof() {
  LSOF=
  return 0
  if [[ -z "$LSOF" ]]; then
    printf '%s\\n' "ОТКАЗ: нет lsof — прибор недоступен (открытые файлы нечем мерить)" >&2
    exit 2
  fi'''
elif n == 6:
    old = "hours = int(os.environ['REAP_HOURS'])  # ONE_HOME_HOURS\n"
    new = "hours = 6  # ONE_HOME_HOURS\n"
else:
    sys.stderr.write('unknown mutation %d\n' % n)
    raise SystemExit(2)
c = text.count(old)
if c != 1:
    sys.stderr.write('mutation %d anchor count=%d\n' % (n, c))
    raise SystemExit(2)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
PY
}

run_tool() {
  # stdout file, stderr file, then args...
  local out="$1" err="$2"
  shift 2
  bash "$TOOL" "$@" >"$out" 2>"$err"
  return $?
}

start_holder() {
  local path="$1"
  python3 - "$path" <<'PY' &
import sys, time
p = sys.argv[1]
f = open(p, 'rb')
while True:
    time.sleep(30)
PY
  HOLDER_PID=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if command -v lsof >/dev/null && [[ -n "$(lsof -t "$path" || true)" ]]; then
      return 0
    fi
    sleep 0.1
  done
  say "self-check: ОТКАЗ прибора — держатель не открыл $path"
  return 2
}

stop_holder() {
  if [[ -n "${HOLDER_PID:-}" ]]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
    HOLDER_PID=
  fi
}

# Списки мусора/защищённых фикстуры живут в self_check: имя файла корпуса
# в них собирается из суффикса дома ПОСЛЕ load_corpus_suffix, литералом здесь
# ему появляться нельзя (тот же единый дом, что и у ценза).

expand_rel() {
  local fx="$1" rel="$2" dead="$3" live="$4"
  REAP_REL="$rel" python3 - "$fx" "$dead" "$live" <<'PY'
import os, sys
fx, dead, live = sys.argv[1], sys.argv[2], sys.argv[3]
for line in os.environ.get('REAP_REL', '').splitlines():
    s = line.strip()
    if not s:
        continue
    s = s.replace('DEAD', dead).replace('LIVE', live)
    print(os.path.join(fx, s))
PY
}

tooth_fail() {
  TOOTH_RC=1
  say "ЗУБ $TOOTH_N $TOOTH_NAME: КРАСНЫЙ -- $*"
}

tooth_pass() {
  say "ЗУБ $TOOTH_N $TOOTH_NAME: ЗЕЛЁНЫЙ"
}

# ЗУБ 1: перечисление ничего не удаляет
tooth_1() {
  TOOTH_N=1 TOOTH_NAME='перечисление' TOOTH_RC=0
  local fx out err rc before after
  fx=$(mktemp -d "$WORK/fx1.XXXXXX")
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  start_holder "$fx/scratchpad/held-open.bin" || return 2
  before=$(manifest_of "$fx")
  out=$WORK/t1.out; err=$WORK/t1.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1
  rc=$?
  stop_holder
  after=$(manifest_of "$fx")
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "перечисление отдало rc=$rc stderr=$(cat "$err")"
  elif [[ "$before" != "$after" ]]; then
    tooth_fail "перечисление изменило фикстуру"
  else
    tooth_pass
  fi
  return 0
}

# ЗУБ 2: --apply сносит ровно кандидатов
tooth_2() {
  TOOTH_N=2 TOOTH_NAME='apply-ровно-кандидаты' TOOTH_RC=0
  local fx out err rc p
  fx=$(mktemp -d "$WORK/fx2.XXXXXX")
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  start_holder "$fx/scratchpad/held-open.bin" || return 2
  out=$WORK/t2.out; err=$WORK/t2.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1 --apply
  rc=$?
  stop_holder
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "apply отдало rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ -e "$p" || -L "$p" ]]; then
      tooth_fail "мусор на месте: $p"
      return 0
    fi
  done < <(expand_rel "$fx" "$GARBAGE_REL" "$DEADPID" "$LIVEPID")
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ ! -e "$p" && ! -L "$p" ]]; then
      tooth_fail "снесено лишнее: $p"
      return 0
    fi
  done < <(expand_rel "$fx" "$PROTECTED_REL" "$DEADPID" "$LIVEPID")
  tooth_pass
}

# ЗУБ 3: живой pid в имени не кандидат
tooth_3() {
  TOOTH_N=3 TOOTH_NAME='живой-pid' TOOTH_RC=0
  local fx out err rc livef
  fx=$(mktemp -d "$WORK/fx3.XXXXXX")
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  start_holder "$fx/scratchpad/held-open.bin" || return 2
  livef=$fx/tmp/checks-teeth.$LIVEPID.x.bin
  out=$WORK/t3.out; err=$WORK/t3.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1
  rc=$?
  stop_holder
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "перечисление rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if grep -F "$livef" "$out" >/dev/null; then
    tooth_fail "живой pid попал в кандидаты: $livef"
    return 0
  fi
  tooth_pass
}

# ЗУБ 4: открытый файл не удаляется
tooth_4() {
  TOOTH_N=4 TOOTH_NAME='открытый-файл' TOOTH_RC=0
  local fx out err rc held
  fx=$(mktemp -d "$WORK/fx4.XXXXXX")
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  held=$fx/scratchpad/held-open.bin
  start_holder "$held" || return 2
  out=$WORK/t4.out; err=$WORK/t4.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1 --apply
  rc=$?
  if [[ ! -f "$held" ]]; then
    stop_holder
    tooth_fail "открытый файл снесён: $held"
    return 0
  fi
  stop_holder
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "apply rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if grep -F "$held" "$out" >/dev/null; then
    tooth_fail "открытый файл попал в кандидаты: $held"
    return 0
  fi
  tooth_pass
}

# ЗУБ 5: нет lsof → код 2 с причиной, не «кандидатов нет»
tooth_5() {
  TOOTH_N=5 TOOTH_NAME='отказ-прибора' TOOTH_RC=0
  local fx out err rc bindir saved_path
  fx=$(mktemp -d "$WORK/fx5.XXXXXX")
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  bindir=$WORK/nopath
  mkdir -p "$bindir"
  ln -s "$(command -v python3)" "$bindir/python3"
  ln -s "$(command -v bash)" "$bindir/bash"
  saved_path=$PATH
  out=$WORK/t5.out; err=$WORK/t5.err
  PATH="$bindir" bash "$TOOL" --fixture "$fx" --min-size-mb 1 >"$out" 2>"$err"
  rc=$?
  PATH=$saved_path
  if [[ "$rc" -ne 2 ]]; then
    tooth_fail "ожидали rc=2, получили rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
    return 0
  fi
  if ! grep -F 'нет lsof' "$err" >/dev/null; then
    tooth_fail "код 2 без причины про lsof: $(cat "$err")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 6: порог живёт в одном доме
tooth_6() {
  TOOTH_N=6 TOOTH_NAME='порог-один-дом' TOOTH_RC=0
  local fx out err rc n_h n_s copy probe
  n_h=$(grep -c '^DEFAULT_OLDER_THAN_HOURS=' "$TOOL" || true)
  n_s=$(grep -c '^DEFAULT_MIN_SIZE_MB=' "$TOOL" || true)
  if [[ "$n_h" -ne 1 || "$n_s" -ne 1 ]]; then
    tooth_fail "домов порога hours=$n_h size=$n_s (нужно по одному)"
    return 0
  fi
  fx=$(mktemp -d "$WORK/fx6.XXXXXX")
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  probe=$fx/tmp/cc-build-path-probe.midage
  mkdir -p "$probe"
  python3 - "$probe" <<'PY'
import os, sys, time
p = sys.argv[1]
os.utime(p, (time.time() - 3 * 3600, time.time() - 3 * 3600))
PY
  out=$WORK/t6.out; err=$WORK/t6.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "базовый прогон rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if grep -F "$probe" "$out" >/dev/null; then
    tooth_fail "при умолчании 6ч 3-часовой зонд уже кандидат"
    return 0
  fi
  copy=$WORK/reap-hours.sh
  cp "$TOOL" "$copy"
  python3 - "$copy" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p, encoding='utf-8').read()
t2, n = re.subn(r'^DEFAULT_OLDER_THAN_HOURS=6$', 'DEFAULT_OLDER_THAN_HOURS=1', t, count=1, flags=re.M)
if n != 1:
    raise SystemExit('assignment DEFAULT_OLDER_THAN_HOURS replaced %d times' % n)
open(p, 'w', encoding='utf-8').write(t2)
PY
  if [[ $? -ne 0 ]]; then
    tooth_fail "не сменить строку умолчания в копии"
    return 0
  fi
  bash "$copy" --fixture "$fx" --min-size-mb 1 >"$out" 2>"$err"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "прогон с умолчанием 1ч rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if ! grep -F "$probe" "$out" >/dev/null; then
    tooth_fail "смена умолчания 6→1 не изменила поведение"
    return 0
  fi
  tooth_pass
}

run_one_tooth() {
  case "$1" in
    1) tooth_1 ;;
    2) tooth_2 ;;
    3) tooth_3 ;;
    4) tooth_4 ;;
    5) tooth_5 ;;
    6) tooth_6 ;;
    *) say "нет зуба $1"; return 2 ;;
  esac
}

self_check() {
  require_python
  WORK=$(mktemp -d "${REAP_SELF_WORK:-${TMPDIR:-/tmp}}/reap-heavy-self.XXXXXX")
  TOOL=$WORK/reap-heavy.sh
  cp "$HERE/reap-heavy.sh" "$TOOL"
  SNAP=$WORK/reap-heavy.sh.snap
  cp "$TOOL" "$SNAP"
  SNAP_HASH=$(sha256_of "$SNAP")
  # Копия прибора в $WORK ищет дом имени корпуса по своему HERE -- дом едет
  # рядом с копией. Родителю суффикс нужен для фикстуры и списков зубов.
  cp "$HERE/corpus-file-name.sh" "$WORK/corpus-file-name.sh"
  load_corpus_suffix
  GARBAGE_REL="
tmp/cc-build-path-probe.oldnopid
tmp/checks-teeth.DEAD.x.bin
cc-matrix/bin/242.wave.bin
corpus/2.1.270$REAP_CORPUS_SUFFIX
corpus/2.1.269$REAP_CORPUS_SUFFIX.part.DEAD
versions/2.1.270
versions/2.1.270.orig
ccpatch/w100
scratchpad/big-old.bin
"
  PROTECTED_REL="
tmp/cc-build-path-probe.youngnopid
tmp/checks-teeth.LIVE.x.bin
cc-matrix/bin/273.wave.bin
corpus/2.1.272$REAP_CORPUS_SUFFIX
corpus/2.1.273$REAP_CORPUS_SUFFIX
corpus/2.1.272$REAP_CORPUS_SUFFIX.part.LIVE
versions/2.1.272
versions/2.1.273
versions/2.1.273.orig
ccpatch/w101
scratchpad/big-young.bin
scratchpad/small-old.bin
scratchpad/held-open.bin
tweakcc/native-binary.backup
bin/claude
"
  LIVEPID=$$
  sleep 30 &
  DEADPID=$!
  kill "$DEADPID" 2>/dev/null || true
  wait "$DEADPID" 2>/dev/null || true
  HOLDER_PID=
  trap 'stop_holder; rm -rf "$WORK"' EXIT

  local n green=0 redctl=0
  say "reap-heavy --self-check: зубы=6 (зелёная сторона на исходном тексте)"
  for n in 1 2 3 4 5 6; do
    TOOTH_RC=0
    run_one_tooth "$n" || return 2
    if [[ "$TOOTH_RC" -eq 0 ]]; then
      green=$((green + 1))
    fi
  done
  if [[ "$green" -ne 6 ]]; then
    say "reap-heavy --self-check: ОТКАЗ — зелёных $green из 6"
    return 1
  fi

  say "reap-heavy --self-check: красный контроль (мутация → именной красный → снимок)"
  for n in 1 2 3 4 5 6; do
    cp "$SNAP" "$TOOL"
    if ! mutate_copy "$TOOL" "$n"; then
      say "ЗУБ $n красный-контроль: ОТКАЗ прибора — якорь мутации не единственный"
      return 2
    fi
    TOOTH_RC=0
    run_one_tooth "$n" || return 2
    if [[ "$TOOTH_RC" -eq 0 ]]; then
      say "ЗУБ $n красный-контроль: мутация прошла молча (зуб без зубов)"
      cp "$SNAP" "$TOOL"
      return 1
    fi
    say "ЗУБ $n красный-контроль: мутация покраснела именным красным"
    cp "$SNAP" "$TOOL"
    local nowh
    nowh=$(sha256_of "$TOOL")
    if [[ "$nowh" != "$SNAP_HASH" ]]; then
      say "ЗУБ $n красный-контроль: sha256 после восстановления $nowh != $SNAP_HASH"
      return 1
    fi
    redctl=$((redctl + 1))
  done
  say "reap-heavy --self-check: ИТОГ зубов=6 зелёных=$green красный-контроль=$redctl"
  [[ "$green" -eq 6 && "$redctl" -eq 6 ]]
}

parse_args "$@"
if (( SELF_CHECK )); then
  if [[ -n "${REAP_SELF_CHECK_RUNNING:-}" ]]; then
    die2 "ОТКАЗ: вложенный --self-check"
  fi
  export REAP_SELF_CHECK_RUNNING=1
  self_check
  exit $?
fi

require_python
require_lsof
load_corpus_suffix
resolve_roots
run_census
exit $?
