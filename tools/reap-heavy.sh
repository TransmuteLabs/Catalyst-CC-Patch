#!/usr/bin/env bash
# Прополка тяжёлых артефактов патч-конвейера.
#
# По умолчанию только перечисляет. Сносит кандидатов только при явном --apply.
# Боевые корни в --self-check не участвуют: зубы гоняют свою фикстуру.
#
# Коды:
#   0  перепись прошла (таблица на stdout; с --apply кандидаты сняты)
#   2  прибор не смог измерить: корень недоступен, нет python3/lsof, lsof
#      не прошёл положительный контроль, или битый/нечитаемый маркер аренды
#   3  НЕ ИЗМЕРЕНО: имя попало под правило, а размер/возраст снять не удалось
#      по правам/вводу-выводу — частичная таблица не выдаётся и --apply не
#      исполняется. Исчезновение кандидата между обходом и stat СЮДА НЕ ВХОДИТ:
#      это штатная гонка многовладельческого корня (живые дорожки удаляют
#      параллельно) — свой счётчик, громкая строка «гонка: …», код 0.
#
# ОБЪЯВЛЕННАЯ АРЕНДА корня (после incident 16.09: возраст+размер — НЕ основание
# сносить то, что читает живой замер; прополка 09:21 снесла корпуса 267-270
# под идущим цензом). Маркер кладёт ВЛАДЕЛЕЦ занятого каталога:
#   <занятый каталог>/.reap-lease  -- одна строка:
#   reap-lease-v1 <unix-секунды-истечения> [причина...]
# Срок — epoch (UTC без засады часовых поясов), целое, 10+ цифр.
#   занять: printf 'reap-lease-v1 %s мой замер\n' "$(( $(date +%s) + 7200 ))" \
#             > <каталог>/.reap-lease
#   снять:  rm <каталог>/.reap-lease
# Аренда защищает каталог-владелец и ВСЁ внутри: на уровне корня — весь
# корень целиком; на уровне кандидата — обход каталогов-предков от корня
# до кандидата (для файла — до его каталога), живой маркер в любом звене
# исключает весь поддерево этого звена.
# Истёкшая аренда не защищает НИЧЕГО (бессрочной аренды нет). Битый или
# нечитаемый маркер -- ОТКАЗ с кодом 2 и причиной: принять испорченное
# объявление за «аренды нет» значит снести данные под живым замером.
# Прополка НЕ угадывает занятость (ни по mtime, ни по чему иному):
# защищает только ЯВНОЕ объявление. Каждый прогон печатает громкую строку
# «аренда: пропущено корней по аренде: N» -- в перечислении и в --apply,
# ноль тоже.
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
# Потолок накопления корней зонда с ЗАВЕРШЁННЫМ возвратом (#57): суммарный
# размер таких корней выше этого = снести старшие (снимки протухли). Держимые
# корни (возврат не завершён) потолок НЕ трогает.
DEFAULT_PROBE_CAP_MB=4096

die2() { printf '%s\n' "$*" >&2; exit 2; }
die3() { printf '%s\n' "$*" >&2; exit 3; }

# Часовой завершения обязателен для КАЖДОГО EXIT-трапа: bash 3.2 отдаёт код 0,
# когда скрипт с трапом умирает на фатальной ошибке подстановки (unbound
# variable под `set -u`, bad substitution) -- трап исполняется, `$?` внутри
# него ноль, и вызывающий видит успех вместо оборванного прогона. Штатный
# конец объявляет себя сам (__DONE=1), трап без объявления краснит.
# Уборка временного каталога и держателя живёт ЗДЕСЬ, а не отдельным трапом
# внутри self_check: `trap` в bash глобален, и трап функции затёр бы часового.
# Сигнальные трапы переводят сигнал в КОД (130/143) и стоят отдельными
# строками -- войдя в общий гвард, точечный TERM пришёлся бы на последнюю
# УДАВШУЮСЯ команду и был бы объявлен «ошибкой оболочки».
__DONE=0
WORK=''
HOLDER_PID=
stop_holder() {
  if [[ -n "${HOLDER_PID:-}" ]]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
    HOLDER_PID=
  fi
}
__reap_heavy_guard() {
  __rc=$?
  # Часовой контекста исполнителя ловушки: bash 5.2 исполняет EXIT-трап
  # В ПОДОБОЛОЧКЕ, когда фоновый потомок умирает от перехватываемого сигнала
  # (#237) -- без предиката тело сносило бы рабочий каталог среди прогона.
  # В bash 4.0+ BASHPID в подоболочке отличен от $$ (PID главного процесса).
  # В bash без BASHPID (3.2) PID исполняющей трап оболочки добывается форком:
  # PPID ребёнка подстановки -- PID нашей оболочки. Контекст -- ТРИ исхода:
  # главный / подоболочка / НЕ ОПРЕДЕЛЁН. Упавший или пустой форк обязан
  # считаться главным процессом (молчаливый невыход главного дороже редкой
  # уборки в подоболочке: вред требует совпадения двух независимых редкостей)
  # и объявляться именной строкой в stderr -- отказ инструмента не имеет
  # права одеваться в вердикт. Выход из ветки подоболочки -- return, не
  # exit: код выхода подоболочки менять мы права не имеем. Форк исполняется
  # один раз за выход и только на bash без BASHPID.
  if [[ -n "${BASHPID:-}" ]]; then
    [[ "$BASHPID" != "$$" ]] && return
  else
    __guard_ctx=$(exec sh -c 'echo $PPID') || __guard_ctx=
    if [[ -n "$__guard_ctx" && "$__guard_ctx" != "$$" ]]; then
      return
    fi
    [[ -z "$__guard_ctx" ]] && echo "ЧАСОВОЙ КОНТЕКСТА НЕ ОПРЕДЕЛЁН (форк PPID не дал ответа) -- продолжаю уборку как главный процесс" >&2
  fi
  # Однократность: повторный вход ловушки уборки не делает.
  trap - EXIT
  stop_holder
  [[ -n "${WORK:-}" ]] && rm -rf "$WORK"
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "ОТКАЗ: reap-heavy оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 2
  fi
  exit "$__rc"
}
trap '__reap_heavy_guard' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  cat <<EOF
usage: bash tools/reap-heavy.sh [--apply] [--older-than-hours N] [--min-size-mb N]
                               [--probe-cap-mb N] [--fixture DIR] [--self-check]

  без --apply     таблица кандидатов (path, mb, age_h, reason), ничего не сносит
  --apply         снести ровно кандидатов таблицы
  --probe-cap-mb  потолок накопления ЗАВЕРШЁННЫХ корней зонда (умолч. 4096); 0 = без потолка
  --self-check    зубы на своей фикстуре; боевые корни не участвуют

Корень зонда cc-build-path-probe.* несёт след return.done, только когда возврат
живого состояния завершён. БЕЗ следа корень ДЕРЖИТСЯ и называется (громкая
строка «держим:»), никогда не сносится по возрасту -- config.json.snapshot в нём
может быть единственным путём возврата. СО следом корень -- предмет обычной
прополки (возраст/мёртвый pid) и потолка накопления (--probe-cap-mb).

Занятые каталоги защищаются ОБЪЯВЛЕННОЙ АРЕНДОЙ: одна строка
  <каталог>/.reap-lease -> "reap-lease-v1 <unix-секунды-истечения> [причина]"
Арендованное не сносится; истёкшая аренда не защищает; битый маркер =
отказ с кодом 2. Каждый прогон печатает громкую строку с числом пропущенных
корней (ноль тоже). Форма -- в шапке файла.

Корни (боевой прогон):
  \${TMPDIR:-/tmp}     cc-build-path-probe.* и checks-teeth.<pid>.*.bin
  /tmp/cc-matrix/bin   копии образов волн
  ~/.local/share/claude-patch/corpus
  ~/.local/share/claude/versions
  ~/ccpatch
  /tmp/claude-<uid>    скратчпады сессий (файлы >= --min-size-mb)

Пол поддержки читается из tools/support-floor.txt, не из минимума списка корпуса.
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
  probe=$(corpus_file_name '') || { printf 'ПРИБОР НЕДОСТУПЕН: не получено имя файла корпуса\n' >&2; exit 2; }
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
    __DONE=1
    exit 2
  fi
  local pc
  pc=$("$LSOF" -p $$ -Fn) || true
  if [[ -z "$pc" ]]; then
    printf '%s\n' "ОТКАЗ: lsof не видит файлов своего процесса — прибор недоступен" >&2
    __DONE=1
    exit 2
  fi
}

parse_args() {
  APPLY=0
  SELF_CHECK=0
  FIXTURE=
  OLDER_THAN_HOURS=$DEFAULT_OLDER_THAN_HOURS
  MIN_SIZE_MB=$DEFAULT_MIN_SIZE_MB
  PROBE_CAP_MB=$DEFAULT_PROBE_CAP_MB
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
      --probe-cap-mb)
        [[ $# -ge 2 ]] || die2 "ОТКАЗ: --probe-cap-mb нужно число"
        PROBE_CAP_MB=$2
        shift 2
        ;;
      -h|--help) usage; __DONE=1; exit 0 ;;
      *) die2 "ОТКАЗ: неизвестный аргумент $1" ;;
    esac
  done
  case "$OLDER_THAN_HOURS" in
    ''|*[!0-9]*) die2 "ОТКАЗ: --older-than-hours должно быть целым неотрицательным, дано '$OLDER_THAN_HOURS'" ;;
  esac
  case "$MIN_SIZE_MB" in
    ''|*[!0-9]*) die2 "ОТКАЗ: --min-size-mb должно быть целым неотрицательным, дано '$MIN_SIZE_MB'" ;;
  esac
  case "$PROBE_CAP_MB" in
    ''|*[!0-9]*) die2 "ОТКАЗ: --probe-cap-mb должно быть целым неотрицательным, дано '$PROBE_CAP_MB'" ;;
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
    REAP_FLOOR=$FIXTURE/support-floor.txt
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
    REAP_FLOOR=$HERE/support-floor.txt
  fi
  REAP_FLOOR_PARSER=$HERE/corpus-list.py
  [[ -f "$REAP_FLOOR" ]] || die2 "ОТКАЗ: нет дома пола $REAP_FLOOR — пол поддержки неизвестен"
  [[ -f "$REAP_FLOOR_PARSER" ]] || die2 "ОТКАЗ: нет разборщика пола $REAP_FLOOR_PARSER"
}

# MUT_APPLY_FLAG: перечисление не сносит; только явное --apply.
run_census() {
  local __reap_apply=$APPLY
  export REAP_TMP REAP_MATRIX REAP_CORPUS REAP_VERSIONS REAP_CCPATCH
  export REAP_SCRATCH REAP_TWEAKCC REAP_LAUNCHER REAP_LIST
  export REAP_FLOOR REAP_FLOOR_PARSER
  export REAP_HOURS=$OLDER_THAN_HOURS
  export REAP_MINSIZE=$MIN_SIZE_MB
  export REAP_PROBE_CAP=$PROBE_CAP_MB
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

# Исчезновение кандидата МЕЖДУ обходом и stat -- ШТАТНАЯ ГОНКА, не отказ.
# Контраст с judge/compact.py (ОДНОВЛАДЕЛЬЧЕСКИЙ каталог: там исчезновение под
# обходом считается сбоем -- владелец один, и никто не вправе удалять под замером).
# Здесь корни МНОГОВЛАДЕЛЬЧЕСКИЕ (живые дорожки пишут и удаляют параллельно),
# поэтому FileNotFoundError на stat -- нормальная гонка: считается своим
# счётчиком, печатается громкой строкой и НЕ роняет прогон. Прочие отказы stat
# (права, ввод-вывод) остаются die3 с причиной словами.
race_vanished = []  # (путь, текст ошибки); только реально исчезнувшее под обходом

def note_vanished(path, exc):
    race_vanished.append((path, str(exc)))

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

def read_floor_from_list(path):
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

def read_floor(path):
    parser = os.environ.get('REAP_FLOOR_PARSER') or ''
    if not parser:
        die2('ОТКАЗ: разборщик пола не назван — пол поддержки неизвестен')
    proc = subprocess.Popen(
        [sys.executable, parser, '--floor', path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = proc.communicate()
    if not isinstance(out, str):
        out = out.decode('utf-8', 'replace')
        err = err.decode('utf-8', 'replace')
    if proc.returncode != 0:
        sys.stderr.write(err)
        sys.exit(proc.returncode if proc.returncode else 2)
    ver = out.strip().split('\n')[0].strip()
    if not ver:
        die2('ОТКАЗ: разборщик пола вернул пусто — пол поддержки неизвестен')
    return ver

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
    # None -- кандидат исчез между обходом и stat (штатная гонка): вызывающий
    # пропускает его. Прочие OSError (права, ввод-вывод) -- die3.
    try:
        return os.lstat(path)
    except FileNotFoundError as exc:
        note_vanished(path, exc)
        return None
    except OSError as exc:
        die3("НЕ ИЗМЕРЕНО: не stat %s: %s" % (path, exc))

def tree_bytes(path):
    st = lstat_or_unmeasured(path)
    if st is None:
        return None  # исчез между обходом и stat -- штатная гонка
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
                except FileNotFoundError as exc:
                    note_vanished(fp, exc)
                    continue
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

# --- ОБЪЯВЛЕННАЯ АРЕНДА корня -------------------------------------------------
# КОНСТРЕЙНТ: защищает только ЯВНОЕ объявление <каталог>/.reap-lease (одна
# строка: "reap-lease-v1 <unix-секунды> [причина]"); прополка не угадывает
# занятость по mtime/lsof/чему-либо ещё. Битый или нечитаемый маркер --
# ОТКАЗ 2 с причиной: принять испорченное объявление за «аренды нет» значит
# снести данные под живым замером (инцидент 16.09, 09:21). Живость аренды
# (срок > now) живёт в ОДНОМ доме -- lease_on_dir; истёкшая не защищает.

LEASE_NAME = '.reap-lease'
LEASE_MAGIC = 'reap-lease-v1'
lease_hits = {}  # занятой каталог -> (expiry, причина); только реально пропущенное


def read_lease(lease_path):
    # None -- маркера нет. Пустой/многострочный/непонятный/нечитаемый -- die2.
    try:
        st = os.lstat(lease_path)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode):
        die2("ОТКАЗ: битый маркер аренды %s: не обычный файл" % lease_path)
    try:
        fh = open(lease_path, 'r')
    except OSError as exc:
        die2("ОТКАЗ: не прочитать маркер аренды %s: %s" % (lease_path, exc))
    try:
        data = fh.read()
    finally:
        fh.close()
    lines = [l for l in data.splitlines() if l.strip()]
    if len(lines) != 1:
        die2("ОТКАЗ: битый маркер аренды %s: значимых строк %d, нужна одна"
             % (lease_path, len(lines)))
    parts = lines[0].split(None, 2)
    if len(parts) < 2 or parts[0] != LEASE_MAGIC:
        die2("ОТКАЗ: битый маркер аренды %s: ждали %r, дано %r"
             % (lease_path, LEASE_MAGIC, lines[0]))
    tok = parts[1]
    if not tok.isdigit() or len(tok) < 10:
        die2("ОТКАЗ: битый маркер аренды %s: срок %r -- не unix-секунды"
             % (lease_path, tok))
    reason = parts[2] if len(parts) > 2 else ''
    return int(tok), reason


def lease_on_dir(d):
    got = read_lease(os.path.join(d, LEASE_NAME))
    if got is None:
        return None
    expiry, reason = got
    if expiry > now:  # MUT_LEASE_LIVE
        return expiry, reason
    return None  # истёкшая аренда не защищает ничего (бессрочной аренды нет)


def reaped_root(root):
    # Аренда на уровне корня: корень целиком выпадает из скана и считается
    # пропущенным даже если кандидатов в нём не нашли (иначе «пропущено»
    # неотличимо от «нечего сносить»).
    hit = lease_on_dir(root)
    if hit is None:
        return False
    lease_hits.setdefault(root, hit)
    return True


def chain_lease(path, root):
    # Цепь каталогов root..candidate: живой маркер в любом звене защищает
    # поддерево этого звена; звено = (путь, срок, причина). Кандидат всегда
    # собран os.path.join от того же root (см. add()/under()), поэтому цепля
    # идёт по совпадению путей, а не по realpath: realpath рвал бы цепь на
    # симлинках внутри корня и молча переставал видеть аренду.
    root_n = root.rstrip('/') or '/'
    if os.path.isdir(path) and not os.path.islink(path):
        cur = path
    else:
        cur = os.path.dirname(path)
    chain = []
    while True:
        chain.append(cur)
        if cur == root_n or cur == os.sep:
            break
        nxt = os.path.dirname(cur)
        if nxt == cur:
            break
        cur = nxt
    chain.reverse()
    for d in chain:
        hit = lease_on_dir(d)
        if hit is not None:
            return d, hit[0], hit[1]
    return None


def covered_by_lease(path, root):
    hit = chain_lease(path, root)
    if hit is None:
        return False
    lease_hits.setdefault(hit[0], (hit[1], hit[2]))
    return True


def fmt_utc(ts):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(ts))

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
probe_cap = int(os.environ['REAP_PROBE_CAP']) * 1024 * 1024  # потолок завершённых корней зонда (#57)
do_apply = os.environ.get('REAP_APPLY') == '1'
floor = read_floor(os.environ['REAP_FLOOR'])
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
held_probe_roots = []      # корни зонда БЕЗ return.done -- держим и называем (#57)
probe_roots_complete = []  # корни зонда С return.done, не в кандидатах по возрасту -- предмет потолка

def add(path, reason, root):
    if not exists(path):
        return
    if not under(root, path):
        return
    if covered_by_lease(path, root):
        return
    if is_protected(path):
        return
    if path_is_open(path):
        return
    measured = tree_bytes(path)
    if measured is None:
        return  # кандидат исчез между обходом и stat -- штатная гонка
    nbytes, mtime = measured
    cands.append((path, nbytes, mtime, reason, root))

# 1. временный каталог: cc-build-path-probe.* и копии зубов
# Корень зонда с ЗАВЕРШЁННЫМ возвратом несёт след return.done (пишет
# build-path-probe.sh на чистом возврате): снимки протухли -- сносить свободно
# по обычным признакам (мёртвый pid / возраст) и по потолку накопления.
# Корень БЕЗ следа -- возврат НЕ завершён (провал / SIGKILL / обрыв):
# config.json.snapshot может быть ЕДИНСТВЕННЫМ путём возврата (адресат первой
# двери стража) ⇒ ДЕРЖИМ и НАЗЫВАЕМ, никогда не сносим по возрасту (инцидент
# 2026-08-31: глоб снёс путь возврата). Различие -- ПО СЛЕДУ В КОРНЕ, не по
# времени и не по размеру.
if require_root_readable(tmp, 'tmp') and not reaped_root(tmp):
    for path in glob.glob(os.path.join(tmp, 'cc-build-path-probe.*')):
        if not os.path.isdir(path):
            continue
        if not os.path.exists(os.path.join(path, 'return.done')):
            held_probe_roots.append(path)
            continue
        pid = name_pid_probe(os.path.basename(path))
        if pid is not None and pid_is_alive(pid):
            continue  # живой прогон -- не трогаем даже с завершённым следом
        probe_roots_complete.append(path)
        if pid is not None:
            add(path, 'tmp: pid %d dead' % pid, tmp)
        else:
            st = lstat_or_unmeasured(path)
            if st is None:
                continue  # исчез между обходом и stat -- штатная гонка
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
            if st is None:
                continue  # исчез между обходом и stat -- штатная гонка
            if now - st.st_mtime >= age_limit:
                add(path, 'tmp: teeth copy, no pid, older than %sh' % hours, tmp)

# 2. /tmp/cc-matrix/bin — копии образов волн по возрасту
if require_root_readable(matrix, 'cc-matrix/bin') and not reaped_root(matrix):
    try:
        names = os.listdir(matrix)
    except OSError as exc:
        die2("ОТКАЗ: не прочитать %s: %s" % (matrix, exc))
    for name in names:
        path = os.path.join(matrix, name)
        if os.path.isdir(path) and not os.path.islink(path):
            continue
        st = lstat_or_unmeasured(path)
        if st is None:
            continue  # исчез между обходом и stat -- штатная гонка
        if now - st.st_mtime >= age_limit:
            add(path, 'matrix: older than %sh' % hours, matrix)

# 3. корпус: ТОЛЬКО обрывки загрузки и версии ниже пола.
#    Пристинные копии поддерживаемых версий сюда не попадают.
if require_root_readable(corpus, 'corpus') and not reaped_root(corpus):
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
if require_root_readable(versions, 'versions') and not reaped_root(versions):
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
if require_root_readable(ccpatch, 'ccpatch') and not reaped_root(ccpatch):
    try:
        names = os.listdir(ccpatch)
    except OSError as exc:
        die2("ОТКАЗ: не прочитать %s: %s" % (ccpatch, exc))
    for name in names:
        path = os.path.join(ccpatch, name)
        if not os.path.isdir(path) or os.path.islink(path):
            continue
        st = lstat_or_unmeasured(path)
        if st is None:
            continue  # исчез между обходом и stat -- штатная гонка
        if now - st.st_mtime >= age_limit:
            add(path, 'ccpatch: run dir older than %sh' % hours, ccpatch)

# 6. скратчпады: файлы крупнее порога, по возрасту
if require_root_readable(scratch, 'scratch') and not reaped_root(scratch):
    try:
        for root, dirs, files in os.walk(scratch, followlinks=False):
            for name in files:
                path = os.path.join(root, name)
                try:
                    st = os.lstat(path)
                except FileNotFoundError as exc:
                    note_vanished(path, exc)
                    continue
                except OSError as exc:
                    die3("НЕ ИЗМЕРЕНО (скратч): не stat %s: %s" % (path, exc))
                if not stat.S_ISREG(st.st_mode):
                    continue
                if st.st_size < minsize:
                    continue
                if now - st.st_mtime >= age_limit:
                    add(path, 'scratch: size >= %sMb, older than %sh' % (os.environ['REAP_MINSIZE'], hours), scratch)
    except OSError as exc:
        die2("ОТКАЗ: не обойти скратчпад %s: %s" % (scratch, exc))

# ПОТОЛОК НАКОПЛЕНИЯ ЗАВЕРШЁННЫХ КОРНЕЙ ЗОНДА (#57): корни со следом
# return.done возврат уже завершили -- снимки протухли, держать их незачем;
# без потолка они копятся вечно (дефекта-потолка до #57 не было вовсе).
# Держим до probe_cap; при переполнении сносим СТАРШИЕ первыми, пока удержанное
# не уйдёт под потолок. Корни БЕЗ следа (held_probe_roots) потолок НЕ трогает --
# они несут незавершённый путь возврата.
if probe_cap > 0 and probe_roots_complete:
    already = set(c[0] for c in cands)
    ceil_c = []  # (path, nbytes, mtime) завершённых, ещё не в кандидатах
    for path in probe_roots_complete:
        if path in already:
            continue
        measured = tree_bytes(path)
        if measured is None:
            continue  # исчез под обходом -- штатная гонка
        ceil_c.append((path, measured[0], measured[1]))
    retained = sum(r[1] for r in ceil_c)
    if retained > probe_cap:
        ceil_c.sort(key=lambda r: r[2])  # старший mtime (меньшее число) первым
        for path, nbytes, mtime in ceil_c:
            if retained <= probe_cap:
                break
            before = len(cands)
            add(path, 'tmp: probe root over cap (удержано %d MB > %d MB)'
                % (retained // 1048576, probe_cap // 1048576), tmp)
            if len(cands) > before:
                retained -= nbytes

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
        if covered_by_lease(path, root):
            sys.stderr.write('пропуск (аренда): %s\n' % path)
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

# ГРОМКАЯ СТРОКА: молчаливый пропуск по аренде неотличим от «нечего
# сносить» -- печатается число и ноль тоже, в обоих режимах.
print('аренда: пропущено корней по аренде: %d' % len(lease_hits))
for _d in sorted(lease_hits):
    _exp, _rsn = lease_hits[_d]
    print('аренда: пропущен %s до %s%s'
          % (_d, fmt_utc(_exp), (' причина: %s' % _rsn) if _rsn else ''))

# ГРОМКАЯ СТРОКА ГОНКИ: кандидат, исчезнувший между обходом и stat -- штатная
# гонка многовладельческого корня, не отказ. Печатается число (ноль тоже) и
# путь каждого исчезнувшего, в обоих режимах.
print('гонка: кандидатов исчезло под обходом: %d' % len(race_vanished))
for _p, _e in race_vanished:
    print('гонка: исчез %s (%s)' % (_p, _e))

# ГРОМКАЯ СТРОКА ДЕРЖАНИЯ (#57): корень зонда БЕЗ следа return.done -- возврат
# НЕ завершён; config.json.snapshot может быть единственным путём возврата
# (адресат первой двери стража). Держим и НАЗЫВАЕМ, никогда не сносим по
# возрасту (инцидент 2026-08-31: глоб снёс путь возврата). Число (ноль тоже) и
# путь каждого держимого, в обоих режимах.
print('держим: корней зонда без следа возврата: %d' % len(held_probe_roots))
for _h in sorted(held_probe_roots):
    print('держим: %s (нет return.done -- возврат не завершён)' % _h)
PY
}

# ---------------------------------------------------------------------------
# --self-check: зубы прибора, у каждого свой названный красный.
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

# garbage / protected in tmp. След return.done (#57): оба корня ЗАВЕРШИЛИ
# возврат -- они предмет обычной прополки (по возрасту), а не держания.
p_old = os.path.join(fx, 'tmp', 'cc-build-path-probe.oldnopid')
touchdir(p_old, old)
write(os.path.join(p_old, 'blob'), b'old-probe\n', old)
write(os.path.join(p_old, 'return.done'), b'return complete rc=0\n', old)
p_young = os.path.join(fx, 'tmp', 'cc-build-path-probe.youngnopid')
touchdir(p_young, young)
write(os.path.join(p_young, 'blob'), b'young-probe\n', young)
write(os.path.join(p_young, 'return.done'), b'return complete rc=0\n', young)
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
with open(os.path.join(fx, 'support-floor.txt'), 'w') as fh:
    fh.write('2.1.272\t2026-09-15\tfixture floor\n')

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
  local file="$1" n="$2" branch=FORK
  # Якорь мутаций часового обязан лежать в ЖИВОЙ ветке интерпретатора
  # (#237): мутация в мёртвой ветке не меняет поведения. Признак --
  # свойство интерпретатора (BASHPID), не версии bash и не машины.
  [[ -n "${BASHPID:-}" ]] && branch=BASHPID
  MUT_GUARD_BRANCH="$branch" python3 - "$file" "$n" <<'PY'
import os
import sys
path, n = sys.argv[1], int(sys.argv[2])
guard_branch = os.environ.get('MUT_GUARD_BRANCH', '')
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
    __DONE=1
    exit 2
  fi'''
    new = '''require_lsof() {
  LSOF=
  return 0
  if [[ -z "$LSOF" ]]; then
    printf '%s\\n' "ОТКАЗ: нет lsof — прибор недоступен (открытые файлы нечем мерить)" >&2
    __DONE=1
    exit 2
  fi'''
elif n == 6:
    old = "hours = int(os.environ['REAP_HOURS'])  # ONE_HOME_HOURS\n"
    new = "hours = 6  # ONE_HOME_HOURS\n"
elif n == 7:
    old = '    if covered_by_lease(path, root):\n        return\n'
    new = ''
elif n == 8:
    old = '    if expiry > now:  # MUT_LEASE_LIVE\n'
    new = '    if True:  # MUT_LEASE_LIVE\n'
elif n == 9:
    old = "print('аренда: пропущено корней по аренде: %d' % len(lease_hits))\n"
    new = "pass  # MUT_LOUD\n"
elif n == 10:
    old = 'def lease_on_dir(d):\n    got = read_lease(os.path.join(d, LEASE_NAME))\n'
    new = 'def lease_on_dir(d):  # MUT_SILENT_BAD\n    return None\n    got = read_lease(os.path.join(d, LEASE_NAME))\n'
elif n == 11:
    # MUT_SENTINEL_OFF: снять часовой контекста -- подоболочка снова убирает.
    old = ('  if [[ -n "${BASHPID' + ':-}" ]]; then\n'
   + '    [[ "$BASHPID"' + ' != "$$" ]] && return\n'
   + '  else\n'
   + "    __guard_ctx=$(exec sh -c " + "'echo $PPID'" + ") || __guard_ctx=\n"
   + '    if [[ -n "$__guard_ctx" && "$__guard_ctx" != "$$" ]]; then\n'
   + '      return\n'
   + '    fi\n'
   + '    [[ -z "$__guard_ctx" ]] && echo "ЧАСОВОЙ КОНТЕКСТА НЕ ОПРЕДЕЛЁН (форк PPID не дал ответа) -- продолжаю уборку как главный процесс" >&2\n'
   + '  fi\n')
    new = ''
elif n == 12:
    # MUT_SENTINEL_INV: инвертировать предикат ЖИВОЙ ветки -- главный
    # перестаёт убирать, подоболочка снова убирает. Якорь-близнец
    # выбирается по интерпретатору; проверка единственности действует
    # на каждом из двух якорей.
    if guard_branch == 'BASHPID':
        old = '    [[ "$BASHPID"' + ' != "$$" ]] && return\n'
        new = '    [[ "$BASHPID"' + ' == "$$" ]] && return\n'
    else:
        old = '    if [[ -n "$__guard_ctx" && "$__guard_ctx" != "$$" ]]; then\n'
        new = '    if [[ -n "$__guard_ctx" && "$__guard_ctx" == "$$" ]]; then\n'
elif n == 13:
    # MUT_SENTINEL_EXIT: return -> exit: код выхода подоболочки меняется.
    # В форк-ветке якорь несёт строку if: одиночный return неуникален.
    if guard_branch == 'BASHPID':
        old = '    [[ "$BASHPID"' + ' != "$$" ]] && return\n'
        new = '    [[ "$BASHPID"' + ' != "$$" ]] && exit\n'
    else:
        old = '    if [[ -n "$__guard_ctx" && "$__guard_ctx" != "$$" ]]; then\n      return\n'
        new = '    if [[ -n "$__guard_ctx" && "$__guard_ctx" != "$$" ]]; then\n      exit\n'
elif n == 14:
    # MUT_TRAP_RESET_OFF: снять самосъём ловушки -- повторный вход не исключён.
    old = '  trap ' + '- EXIT\n'
    new = ''
elif n == 15:
    # MUT_CTX_FALLBACK_OFF: снять фолбэк-добывалку на литеральный $$ --
    # неопределённый контекст перестаёт объявляться и не отличим от главного.
    old = "    __guard_ctx=$(exec sh -c " + "'echo $PPID'" + ") || __guard_ctx=\n"
    new = '    __guard_ctx=$$\n'
elif n == 16:
    # MUT_VANISH_DIE3: снять ветку штатной гонки в lstat_or_unmeasured --
    # исчезнувший кандидат снова роняет прогон кодом 3 (до-#214 поведение).
    old = ('    except FileNotFoundError as exc:\n'
           '        note_vanished(path, exc)\n'
           '        return None\n')
    new = ''
elif n == 17:
    # MUT_PERM_SWALLOW: отказ stat по правам в обходе скратча перестаёт ронять
    # прогон -- права-ошибка глотается как гонка (нечитаемое молча пропадает).
    old = ('                except OSError as exc:\n'
           '                    die3("НЕ ИЗМЕРЕНО (скратч): не stat %s: %s" % (path, exc))\n')
    new = ('                except OSError as exc:\n'
           '                    continue\n')
elif n == 18:
    # MUT_HELD_OFF: снять держание корня без следа возврата -- корень без
    # return.done снова сносится по возрасту (инцидент 2026-08-31: путь
    # возврата уходит под глоб).
    old = "        if not os.path.exists(os.path.join(path, 'return.done')):\n"
    new = "        if False:\n"
elif n == 19:
    # MUT_HELD_ALWAYS: держать КАЖДЫЙ корень -- завершённый возврат (return.done)
    # больше не прибирается, снимки копятся вечно.
    old = "        if not os.path.exists(os.path.join(path, 'return.done')):\n"
    new = "        if True:\n"
elif n == 20:
    # MUT_CAP_OFF: снять потолок накопления -- завершённые корни зонда сверх
    # probe_cap перестают сноситься, tmp растёт без предела.
    old = 'if probe_cap > 0 and probe_roots_complete:\n'
    new = 'if False and probe_cap > 0 and probe_roots_complete:\n'
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
    # Пустой lsof -t — штатно: держатель ещё не виден; цикл повторяет, затем отказ прибора.
    local __lsof_t
    if command -v lsof >/dev/null; then
      __lsof_t="$(lsof -t "$path" || true)"
    else
      __lsof_t=
    fi
    if [[ -n "$__lsof_t" ]]; then
      return 0
    fi
    sleep 0.1
  done
  say "self-check: ОТКАЗ прибора — держатель не открыл $path"
  return 2
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
  fx=$(mktemp -d "$WORK/fx1.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  start_holder "$fx/scratchpad/held-open.bin" || return 2
  before=$(manifest_of "$fx") || { printf 'ПРИБОР НЕДОСТУПЕН: не снят снимок фикстуры до прогона\n' >&2; exit 2; }
  out=$WORK/t1.out; err=$WORK/t1.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1
  rc=$?
  stop_holder
  after=$(manifest_of "$fx") || { printf 'ПРИБОР НЕДОСТУПЕН: не снят снимок фикстуры после прогона\n' >&2; exit 2; }
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
  fx=$(mktemp -d "$WORK/fx2.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
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
  fx=$(mktemp -d "$WORK/fx3.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
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
  fx=$(mktemp -d "$WORK/fx4.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
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
  fx=$(mktemp -d "$WORK/fx5.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
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
  fx=$(mktemp -d "$WORK/fx6.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  probe=$fx/tmp/cc-build-path-probe.midage
  mkdir -p "$probe"
  # След завершённого возврата (#57): без него корень держится, и порог возраста
  # не проверить -- зуб 6 мерит именно порог, поэтому возврат должен быть завершён.
  printf 'return complete rc=0\n' > "$probe/return.done"
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

# Аренда в зубах пишется ВЯЗКОГО срока: владеющий замер длился бы минуты,
# а фикстура живёт секунды -- epoch из date +%s + запас.
write_lease() {
  # $1 каталог  $2 срок (unix-секунды)  $3 причина
  mkdir -p "$1"
  printf 'reap-lease-v1 %s %s\n' "$2" "$3" > "$1/.reap-lease"
}

# КОНСТРЕЙНТ зуба: файл аренды ВНУТРИ каталога-кандидата двигает его mtime,
# и возрастной кандидат перестает им быть -- зуб покраснел бы не по своему
# основанию (или прошёл бы молча под мутацией). После write_lease на
# возрастном кандидате mtime обязана быть возвращена назад.
backdate() {
  # $1 path  $2 unix-секунды
  python3 - "$1" "$2" <<'PY'
import os, sys
ts = float(sys.argv[2])
os.utime(sys.argv[1], (ts, ts))
PY
}

# ЗУБ 7: арендованный корень/каталог НЕ сносится, неарендованный -- сносится.
# Аренда стоит ДВУМЯ способами: на уровне корня (ccpatch -- весь корень
# выпадает) и на уровне каталога-кандидата (проб в tmp). Неарендованный
# мусор обязан уйти, иначе «не сносит» неотличим от «сломан весь прибор».
tooth_7() {
  TOOTH_N=7 TOOTH_NAME='аренда-защищает' TOOTH_RC=0
  local fx out err rc now_s
  fx=$(mktemp -d "$WORK/fx7.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  now_s=$(date +%s) || { printf 'ПРИБОР НЕДОСТУПЕН: не получено текущее время для аренды\n' >&2; exit 2; }
  write_lease "$fx/ccpatch" "$((now_s + 7200))" 'зуб7: боевой корень занят'
  write_lease "$fx/tmp/cc-build-path-probe.oldnopid" "$((now_s + 7200))" 'зуб7: занят кандидат'
  backdate "$fx/tmp/cc-build-path-probe.oldnopid" "$((now_s - 7 * 3600))"
  out=$WORK/t7.out; err=$WORK/t7.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1 --apply
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "apply с арендой rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if [[ ! -d "$fx/ccpatch/w100" || ! -e "$fx/ccpatch/w100/target" ]]; then
    tooth_fail "снесено арендованное: $fx/ccpatch"
    return 0
  fi
  if [[ ! -d "$fx/tmp/cc-build-path-probe.oldnopid" ]]; then
    tooth_fail "снесён арендованный кандидат: $fx/tmp/cc-build-path-probe.oldnopid"
    return 0
  fi
  # Аренда видна и в таблице: без учета аренды в add() арендованный
  # кандидат возвращается в кандидаты (перечисление врёт, даже если
  # повторная проверка apply ещё что-то прикрывает). Табличная строка
  # отличается от громкой строки аренды тем, что путь в ней отделён
  # табуляцией ('path\tmb\t...'), поэтому поиск с хвостовым табулятором.
  if grep -F "${fx}/tmp/cc-build-path-probe.oldnopid	" "$out" >/dev/null; then
    tooth_fail "арендованный кандидат в таблице сноса: $fx/tmp/cc-build-path-probe.oldnopid"
    return 0
  fi
  if grep -F "${fx}/ccpatch/w100	" "$out" >/dev/null; then
    tooth_fail "кандидаты из арендованного корня в таблице: $fx/ccpatch/w100"
    return 0
  fi
  if [[ -e "$fx/cc-matrix/bin/242.wave.bin" ]]; then
    tooth_fail "неарендованный мусор цел: $fx/cc-matrix/bin/242.wave.bin"
    return 0
  fi
  if [[ -e "$fx/scratchpad/big-old.bin" ]]; then
    tooth_fail "неарендованный мусор цел: $fx/scratchpad/big-old.bin"
    return 0
  fi
  tooth_pass
}

# ЗУБ 8: ИСТЁКШАЯ аренда не защищает.
tooth_8() {
  TOOTH_N=8 TOOTH_NAME='аренда-истекла' TOOTH_RC=0
  local fx out err rc now_s
  fx=$(mktemp -d "$WORK/fx8.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  now_s=$(date +%s) || { printf 'ПРИБОР НЕДОСТУПЕН: не получено текущее время для аренды\n' >&2; exit 2; }
  write_lease "$fx/ccpatch" "$((now_s - 60))" 'зуб8: срок прошёл до прогона'
  out=$WORK/t8.out; err=$WORK/t8.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1 --apply
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "apply с истёкшей арендой rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if [[ -d "$fx/ccpatch/w100" ]]; then
    tooth_fail "истёкшая аренда защитила: $fx/ccpatch/w100"
    return 0
  fi
  if grep -F 'пропущено корней по аренде: 1' "$out" >/dev/null; then
    tooth_fail "истёкшая аренда учтена в громкой строке: $(cat "$out")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 9: пропуск назван ГРОМКОЙ строкой с числом; ноль тоже печатается.
tooth_9() {
  TOOTH_N=9 TOOTH_NAME='громкая-строка-аренды' TOOTH_RC=0
  local fx out err rc now_s n
  # 9а: аренд нет -- строка с нулём обязана быть (иначе «пропущено»
  # неотличимо от «не печатаем»).
  fx=$(mktemp -d "$WORK/fx9a.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  out=$WORK/t9a.out; err=$WORK/t9a.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "перечисление без аренд rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  n=$(grep -c '^аренда: пропущено корней по аренде: 0$' "$out" || true)
  if [[ "$n" -ne 1 ]]; then
    tooth_fail "нет громкой строки с нулём (строка '^...: 0' найдена $n раз): $(cat "$out")"
    return 0
  fi
  # 9б: есть живая аренда на уровень корня -- число 1 и названный путь.
  fx=$(mktemp -d "$WORK/fx9b.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  now_s=$(date +%s) || { printf 'ПРИБОР НЕДОСТУПЕН: не получено текущее время для аренды\n' >&2; exit 2; }
  write_lease "$fx/corpus" "$((now_s + 3600))" 'ценз мёртвых ветвей читает корпуса'
  out=$WORK/t9b.out; err=$WORK/t9b.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "перечисление с арендой rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if ! grep -F 'аренда: пропущено корней по аренде: 1' "$out" >/dev/null; then
    tooth_fail "нет строки с числом 1: $(cat "$out")"
    return 0
  fi
  if ! grep -F "$fx/corpus" "$out" >/dev/null; then
    tooth_fail "арендованный корень не назван: $(cat "$out")"
    return 0
  fi
  if ! grep -F 'до ' "$out" >/dev/null; then
    tooth_fail "не назван момент истечения: $(cat "$out")"
    return 0
  fi
  if ! grep -F 'ценз мёртвых ветвей' "$out" >/dev/null; then
    tooth_fail "не названа причина аренды: $(cat "$out")"
    return 0
  fi
  if grep -F 'corpus/2.1.270' "$out" >/dev/null; then
    tooth_fail "арендованный корпус всё равно в кандидатах: $(cat "$out")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 10: битый маркер = ненулевой код с причиной, а не «аренды нет».
tooth_10() {
  TOOTH_N=10 TOOTH_NAME='битый-маркер-отказ' TOOTH_RC=0
  local fx out err rc now_s bad
  for bad in 'мусор вместо аренды' 'reap-lease-v1 не-число' 'reap-lease-v1 123' ''; do
    fx=$(mktemp -d "$WORK/fx10.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
    build_fixture "$fx" "$DEADPID" "$LIVEPID"
    mkdir -p "$fx/corpus"
    printf '%s\n' "$bad" > "$fx/corpus/.reap-lease"
    out=$WORK/t10.out; err=$WORK/t10.err
    run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
      tooth_fail "битый маркер проглочен молча (rc=0) на входе '$bad': $(cat "$out")"
      return 0
    fi
    if [[ "$rc" -ne 2 ]]; then
      tooth_fail "битый маркер '$bad' дал rc=$rc, ждали 2: $(cat "$err")"
      return 0
    fi
    if ! grep -F 'битый маркер аренды' "$err" >/dev/null; then
      tooth_fail "код 2 без причины на входе '$bad': $(cat "$err")"
      return 0
    fi
    rm -rf "$fx"
  done
  # положительный контроль той же формой: ВЯЗКИЙ текст, годный маркер рядом --
  # rc=0 (иначе «падает на всём» выглядело бы падением на битом).
  fx=$(mktemp -d "$WORK/fx10ok.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  now_s=$(date +%s) || { printf 'ПРИБОР НЕДОСТУПЕН: не получено текущее время для аренды\n' >&2; exit 2; }
  write_lease "$fx/corpus" "$((now_s + 3600))" 'годный'
  out=$WORK/t10ok.out; err=$WORK/t10ok.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "годный маркер дал rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 11: EXIT-ловушка, исполнившаяся в ПОДОБОЛОЧКЕ, НЕ убирает рабочий
# каталог. bash 5.2 исполняет EXIT-трап преждевременно -- в подоболочке, когда
# фоновый потомок умирает от перехватываемого сигнала (#237). Вызов двойной:
# повторный вызов часового не убирает и не ломает прогон. Положительный
# контроль -- зуб 12 (главный процесс убирает тот же каталог).
tooth_11() {
  TOOTH_N=11 TOOTH_NAME='подоболочка-не-убирает' TOOTH_RC=0
  local probe stand rc
  probe=$(mktemp -d "$WORK/g11.XXXXXX") || { say "ЗУБ 11: ОТКАЗ прибора -- mktemp не создал зонд подоболочки"; return 2; }
  stand=$WORK/t11-stand.sh
  {
    sed -n '/^stop_holder()/,/^}/p; /^__reap_heavy_guard()/,/^}/p' "$TOOL"
    printf 'WORK=%q\n' "$probe"
    printf 'HOLDER_PID=\n__DONE=1\n'
    printf '( __reap_heavy_guard; __reap_heavy_guard )\n'
  } > "$stand"
  bash "$stand"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "стенд подоболочки rc=$rc"
    return 0
  fi
  if [[ ! -d "$probe" ]]; then
    tooth_fail "подоболочка снесла рабочий каталог $probe"
    return 0
  fi
  tooth_pass
}

# ЗУБ 12: ГЛАВНЫЙ процесс убирает тот же каталог -- положительный контроль
# зуба 11: без него «подоболочка не убирает» зелено и на предикате,
# отвергающем вообще всё.
tooth_12() {
  TOOTH_N=12 TOOTH_NAME='главный-убирает' TOOTH_RC=0
  local probe stand rc
  probe=$(mktemp -d "$WORK/g12.XXXXXX") || { say "ЗУБ 12: ОТКАЗ прибора -- mktemp не создал зонд главного выхода"; return 2; }
  stand=$WORK/t12-stand.sh
  {
    sed -n '/^stop_holder()/,/^}/p; /^__reap_heavy_guard()/,/^}/p' "$TOOL"
    printf 'WORK=%q\n' "$probe"
    printf 'HOLDER_PID=\n__DONE=1\n'
    printf "trap '__reap_heavy_guard' EXIT\nexit 0\n"
  } > "$stand"
  bash "$stand"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "стенд главного выхода rc=$rc"
    return 0
  fi
  if [[ -d "$probe" ]]; then
    tooth_fail "главный процесс не убрал $probe"
    return 0
  fi
  tooth_pass
}

# ЗУБ 13: смерть фонового потомка от ПЕРЕХВАТЫВАЕМОГО сигнала (kill без -9)
# безопасна: wait отдаёт статус потомка (143), рабочий каталог жив СРЕДИ
# прогона, прогон доходит до конца, финальная уборка срабатывает. На bash 3.2
# ловушка mid-run не исполняется вовсе (измерено #237) -- зуб зелёный там по
# платформенной причине. Форма выхода часового -- return, не exit -- контракт
# (код выхода подоболочки менять права не имеем); на bash 5.2 return и exit в
# этом месте поведенчески неразличимы (измерено #237), поэтому форма
# проверяется текстом тела.
tooth_13() {
  TOOTH_N=13 TOOTH_NAME='потомок-TERM-безопасен' TOOTH_RC=0
  local probe stand log rc gbody
  probe=$(mktemp -d "$WORK/g13.XXXXXX") || { say "ЗУБ 13: ОТКАЗ прибора -- mktemp не создал зонд смерти потомка"; return 2; }
  log=$WORK/t13.log
  : > "$log"
  stand=$WORK/t13-stand.sh
  {
    sed -n '/^stop_holder()/,/^}/p; /^__reap_heavy_guard()/,/^}/p' "$TOOL"
    printf 'WORK=%q\n' "$probe"
    printf 'LOG=%q\n' "$log"
    printf 'HOLDER_PID=\n__DONE=0\n'
    printf "trap '__reap_heavy_guard' EXIT\n"
    printf "trap 'exit 130' INT\ntrap 'exit 143' TERM\n"
    printf 'sleep 30 & p=$!\nkill "$p"\nwait "$p"; echo "WAIT_RC=$?" >> "$LOG"\n'
    printf 'if [[ -d "$WORK" ]]; then echo WORK_AFTER_WAIT=yes >> "$LOG"; else echo WORK_AFTER_WAIT=no >> "$LOG"; fi\n'
    printf '__DONE=1\nexit 0\n'
  } > "$stand"
  bash "$stand"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "стенд смерти потомка rc=$rc лог=$(cat "$log" 2>/dev/null)"
    return 0
  fi
  # Статус wait по убитому TERM потомку платформозависим: bash 5.2 отдаёт 143,
  # bash 3.2 при живой TERM-ловушке -- 0 (измерено, стенды t32/t32b, 3.2.57).
  # Защитное свойство (каталог жив среди прогона) проверяется ниже и строго.
  if ! grep -q '^WAIT_RC=143$' "$log" && ! grep -q '^WAIT_RC=0$' "$log"; then
    tooth_fail "wait не отдал статус потомка: $(cat "$log")"
    return 0
  fi
  if ! grep -q '^WORK_AFTER_WAIT=yes$' "$log"; then
    tooth_fail "рабочий каталог снесён среди прогона: $(cat "$log")"
    return 0
  fi
  if [[ -d "$probe" ]]; then
    tooth_fail "финальная уборка не сработала: $probe"
    return 0
  fi
  gbody=$(sed -n '/^__reap_heavy_guard()/,/^}/p' "$TOOL") || { say "ЗУБ 13: ОТКАЗ прибора -- тело гварда не извлекается"; return 2; }
  if [[ -z "${BASHPID:-}" ]]; then
    say "ЗУБ 13: поведенческая половина недостижима без BASHPID -- mid-run ловушка на этом интерпретаторе не исполняется вовсе; стенд выше доказал свойство платформы, не часового; контракт выхода обеих веток -- текстом тела ниже"
  fi
  if [[ "$gbody" != *']] && return'* ]]; then
    tooth_fail "часовой, ветка BASHPID: выход подоболочки не return (контракт: код выхода подоболочки не меняем)"
    return 0
  fi
  # Голый return в теле неуникален: ветка форка опознаётся только трёхстрочной
  # формой блока. Паттерн собран \n-эскейпами: реальные переводы строк живут
  # только в рантайме, иначе файл получил бы вторую копию якорей мутаций
  # INV/EXIT-форка и проверка единственности в mutate_copy легла бы (count=2).
  # В [[ ]] переменная паттерна обязана быть закавычена: незакавыченный $'...'
  # ломается о glob-семантику квадратной скобки (измерено, bash 3.2 и 5.2).
  local fork_block
  fork_block=$'    if [[ -n "$__guard_ctx" && "$__guard_ctx" != "$$" ]]; then\n      return\n    fi'
  if [[ "$gbody" != *"$fork_block"* ]]; then
    tooth_fail "часовой, ветка форка: выход подоболочки не return (контракт: код выхода подоболочки не меняем)"
    return 0
  fi
  tooth_pass
}

# ЗУБ 14: ОДНОКРАТНОСТЬ: ловушка снимает себя (trap с минусом по EXIT) между
# сохранением кода выхода и уборкой. Поведенческая однократность повторных
# mid-run вызовов измерена зубом 11 (двойной вызов); повторного входа в
# главном процессе на bash 5.2 не построить (bash сам не ре-триггерит
# EXIT-handler, измерено #237), поэтому инвариант самосъёма проверяется
# текстом тела.
tooth_14() {
  TOOTH_N=14 TOOTH_NAME='однократность-ловушка-снимает-себя' TOOTH_RC=0
  local body pyrc
  body=$(sed -n '/^__reap_heavy_guard()/,/^}/p' "$TOOL") || { say "ЗУБ 14: ОТКАЗ прибора -- тело гварда не извлекается"; return 2; }
  pyrc=0
  python3 - "$body" <<'PY' || pyrc=$?
import sys
body = sys.argv[1]
i_rc = body.find('__rc=$?')
i_trap = body.find('trap ' + '- EXIT')
i_rm = body.find('rm ')
if i_rc < 0:
    sys.stderr.write('нет сохранения кода выхода\n')
    sys.exit(1)
if i_trap < 0 or i_trap < i_rc:
    sys.stderr.write('нет снятия ловушки после __rc=$?\n')
    sys.exit(2)
if i_rm >= 0 and i_trap > i_rm:
    sys.stderr.write('снятие ловушки стоит после уборки\n')
    sys.exit(3)
PY
  if [[ "$pyrc" -ne 0 ]]; then
    tooth_fail "структура тела гварда: pyrc=$pyrc"
    return 0
  fi
  tooth_pass
}

# ЗУБ 15: контекст НЕ ОПРЕДЕЛЁН -- третий исход часового: упавшая или
# пустая добывалка PID (ветка bash без BASHPID) обязана продолжить уборку
# как главный процесс И объявить отказ именной строкой в stderr; молчаливого
# исхода не бывает. На bash с BASHPID ветка недостижима (переменная readonly
# и всегда установлена оболочкой), там зуб держит структурную половину и
# красный контроль мутации добывалки; поведенческая половина гоняется на
# bash без BASHPID (PATH без sh валит форк-добывалку).
tooth_15() {
  TOOTH_N=15 TOOTH_NAME='контекст-не-определён' TOOTH_RC=0
  local probe stand rc gbody nopath rm_path bash_abs
  gbody=$(sed -n '/^__reap_heavy_guard()/,/^}/p' "$TOOL") || { say "ЗУБ 15: ОТКАЗ прибора -- тело гварда не извлекается"; return 2; }
  if [[ "$gbody" != *'__guard_ctx=$(exec'* || "$gbody" != *'|| __guard_ctx='* || "$gbody" != *'ЧАСОВОЙ КОНТЕКСТА НЕ ОПРЕДЕЛЁН'* ]]; then
    tooth_fail "в теле гварда нет добывалки с захватом кода или именной строки отказа"
    return 0
  fi
  if [[ -n "${BASHPID:-}" ]]; then
    say "ЗУБ 15: структурная половина; поведенческая -- только bash без BASHPID (на этой машине ветка недостижима)"
    tooth_pass
    return 0
  fi
  probe=$(mktemp -d "$WORK/g15.XXXXXX") || { say "ЗУБ 15: ОТКАЗ прибора -- mktemp не создал зонд"; return 2; }
  stand=$WORK/t15-stand.sh
  {
    sed -n '/^stop_holder()/,/^}/p; /^__reap_heavy_guard()/,/^}/p' "$TOOL"
    printf 'WORK=%q\n' "$probe"
    printf 'HOLDER_PID=\n__DONE=1\n'
    printf "trap '__reap_heavy_guard' EXIT\nexit 0\n"
  } > "$stand"
  nopath=$WORK/t15-nopath
  mkdir -p "$nopath" || { say "ЗУБ 15: ОТКАЗ прибора -- не создать пустой PATH"; return 2; }
  rm_path=$(command -v rm) || { say "ЗУБ 15: ОТКАЗ прибора -- нет rm"; return 2; }
  ln -s "$rm_path" "$nopath/rm" || { say "ЗУБ 15: ОТКАЗ прибора -- не положить rm в пустой PATH"; return 2; }
  # Интерпретатор зовётся АБСОЛЮТНЫМ путём: PATH стенда намеренно пуст
  # (в нём только rm), и поиск bash по нему даёт отказ прибора вместо
  # вердикта. Ветка достижима только на bash без BASHPID (3.2).
  bash_abs=${BASH:-}
  [[ -n "$bash_abs" && -x "$bash_abs" ]] || bash_abs=$(command -v bash) || { say "ЗУБ 15: ОТКАЗ прибора -- не найден абсолютный путь bash"; return 2; }
  PATH="$nopath" "$bash_abs" "$stand" >"$WORK/t15.out" 2>"$WORK/t15.err"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "стенд неопределённого контекста rc=$rc stderr=$(cat "$WORK/t15.err")"
    return 0
  fi
  if [[ -d "$probe" ]]; then
    tooth_fail "контекст не определён, но каталог не убран: $probe"
    return 0
  fi
  if ! grep -q 'ЧАСОВОЙ КОНТЕКСТА НЕ ОПРЕДЕЛЁН' "$WORK/t15.err"; then
    tooth_fail "неопределённый контекст прошёл молча: $(cat "$WORK/t15.err")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 16: кандидат, исчезнувший МЕЖДУ обходом и stat -- штатная гонка
# многовладельческого корня: rc 0, попадает в счётчик гонки, назван громкой
# строкой. Триггер детерминирован швом REAP_LSOF: обёртка lsof на проверке
# открытых файлов (-t) сносит кандидата и объявляет «не открыт» (rc 1) --
# следующий stat в tree_bytes встречает исчезнувший путь. Обёртка кладётся
# первой в PATH: require_lsof берёт её же (command -v lsof), а положительный
# контроль (-p ... -Fn) обёртка проходит непустым ответом.
tooth_16() {
  TOOTH_N=16 TOOTH_NAME='исчез-под-обходом-гонка' TOOTH_RC=0
  local fx out err rc bindir cand
  fx=$(mktemp -d "$WORK/fx16.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  bindir=$WORK/lsofwrap16
  mkdir -p "$bindir"
  cat > "$bindir/lsof" <<'WRAP'
#!/usr/bin/env bash
# ЗУБ 16: -p <pid> -Fn -- положительный контроль require_lsof, дать непустой
# ответ. -t <пути> -- проверка открытых: снести переданных кандидатов и
# объявить «не открыт» (rc 1), чтобы следующий stat встретил исчезнувший путь.
for a in "$@"; do
  if [[ "$a" == "-p" ]]; then printf 'n/dev/null\n'; exit 0; fi
done
shift   # снять -t
rm -rf "$@"
exit 1
WRAP
  chmod +x "$bindir/lsof"
  cand=$fx/cc-matrix/bin/242.wave.bin
  out=$WORK/t16.out; err=$WORK/t16.err
  PATH="$bindir:$PATH" bash "$TOOL" --fixture "$fx" --min-size-mb 1 >"$out" 2>"$err"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "исчезновение кандидата уронило прогон rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if ! grep -Eq 'гонка: кандидатов исчезло под обходом: [1-9][0-9]*' "$out"; then
    tooth_fail "нет громкой строки гонки с ненулевым счётчиком: $(cat "$out")"
    return 0
  fi
  if ! grep -Fq "гонка: исчез $cand" "$out"; then
    tooth_fail "исчезнувший кандидат $cand не назван в счётчике гонки: $(cat "$out")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 17: файл, нечитаемый по правам (родитель без x), в обходе скратча по-
# прежнему роняет прогон кодом 3 с причиной словами -- это НЕ штатная гонка.
# Триггер детерминирован: каталог с r без x -- обход видит имя (readdir), а
# lstat ребёнка даёт EACCES независимо от d_type файловой системы.
tooth_17() {
  TOOTH_N=17 TOOTH_NAME='нечитаем-по-правам-отказ' TOOTH_RC=0
  local fx out err rc locked
  fx=$(mktemp -d "$WORK/fx17.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  locked=$fx/scratchpad/locked
  mkdir -p "$locked"
  python3 - "$locked/big" <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'\0' * (2 * 1024 * 1024))
PY
  chmod 0400 "$locked"
  out=$WORK/t17.out; err=$WORK/t17.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1
  rc=$?
  chmod 0700 "$locked"   # вернуть x, иначе rm -rf "$WORK" не уберёт содержимое
  if [[ "$rc" -ne 3 ]]; then
    tooth_fail "нечитаемый по правам файл не дал rc=3 (дано rc=$rc) stderr=$(cat "$err")"
    return 0
  fi
  if ! grep -Fq 'НЕ ИЗМЕРЕНО' "$err"; then
    tooth_fail "код 3 без причины словами: $(cat "$err")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 18: корень зонда БЕЗ следа return.done -- возврат не завершён; НЕ сносить
# даже если старше порога (config.json.snapshot внутри может быть единственным
# путём возврата -- инцидент 2026-08-31). Корень держится и называется громкой
# строкой. Красный контроль n=18 (if False) снимает держание -- старый корень
# без следа снова уезжает в кандидаты и под --apply исчезает.
tooth_18() {
  TOOTH_N=18 TOOTH_NAME='держим-без-следа-возврата' TOOTH_RC=0
  local fx out err rc held
  fx=$(mktemp -d "$WORK/fx18.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  held=$fx/tmp/cc-build-path-probe.heldnofile
  mkdir -p "$held"
  printf 'live-state\n' > "$held/config.json.snapshot"
  python3 - "$held" <<'PY'
import os, sys, time
p = sys.argv[1]
old = time.time() - 7 * 3600
os.utime(p, (old, old))
PY
  out=$WORK/t18.out; err=$WORK/t18.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1 --apply
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "прогон rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if [[ ! -d "$held" ]]; then
    tooth_fail "корень без следа возврата снесён под --apply: $held"
    return 0
  fi
  if grep -F "$held"$'\t' "$out" >/dev/null; then
    tooth_fail "корень без следа возврата в таблице сноса: $held"
    return 0
  fi
  if ! grep -Fq "держим: $held" "$out"; then
    tooth_fail "корень без следа возврата не назван в держим: $(cat "$out")"
    return 0
  fi
  tooth_pass
}

# ЗУБ 19: корень зонда СО следом return.done возврат завершил -- прибирается по
# обычным признакам (возраст), НЕ держится. Красный контроль n=19 (if True)
# держит КАЖДЫЙ корень -- завершённый больше не прибирается, снимки копятся.
tooth_19() {
  TOOTH_N=19 TOOTH_NAME='завершённый-прибирается' TOOTH_RC=0
  local fx out err rc comp
  fx=$(mktemp -d "$WORK/fx19.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  comp=$fx/tmp/cc-build-path-probe.compold
  mkdir -p "$comp"
  printf 'blob\n' > "$comp/blob"
  printf 'return complete rc=0\n' > "$comp/return.done"
  python3 - "$comp" <<'PY'
import os, sys, time
p = sys.argv[1]
old = time.time() - 7 * 3600
os.utime(p, (old, old))
PY
  out=$WORK/t19.out; err=$WORK/t19.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "прогон rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if ! grep -F "$comp"$'\t' "$out" >/dev/null; then
    tooth_fail "завершённый старый корень не попал в кандидаты: $(cat "$out")"
    return 0
  fi
  if grep -Fq "держим: $comp" "$out"; then
    tooth_fail "завершённый корень ошибочно в держим: $comp"
    return 0
  fi
  tooth_pass
}

# ЗУБ 20: потолок накопления завершённых корней. Два молодых корня со следом
# возврата (~2 МБ каждый) сверх --probe-cap-mb 3: возраст их не берёт, берёт
# потолок -- сносится СТАРШИЙ, младший остаётся под потолком. Красный контроль
# n=20 (if False and ...) снимает потолок -- старший корень остаётся.
tooth_20() {
  TOOTH_N=20 TOOTH_NAME='потолок-накопления' TOOTH_RC=0
  local fx out err rc r_old r_new
  fx=$(mktemp -d "$WORK/fx20.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог фикстуры\n' >&2; exit 2; }
  [ -n "$fx" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога фикстуры пуст\n' >&2; exit 2; }
  build_fixture "$fx" "$DEADPID" "$LIVEPID"
  r_old=$fx/tmp/cc-build-path-probe.capold
  r_new=$fx/tmp/cc-build-path-probe.capnew
  python3 - "$r_old" "$r_new" <<'PY'
import os, sys, time
r_old, r_new = sys.argv[1], sys.argv[2]
two = b'\0' * (2 * 1024 * 1024)
now = time.time()
for p, mt in ((r_old, now - 3000), (r_new, now - 60)):
    os.makedirs(p, exist_ok=True)
    open(os.path.join(p, 'blob'), 'wb').write(two)
    open(os.path.join(p, 'return.done'), 'w').write('return complete rc=0\n')
    os.utime(p, (mt, mt))
PY
  out=$WORK/t20.out; err=$WORK/t20.err
  run_tool "$out" "$err" --fixture "$fx" --min-size-mb 1 --probe-cap-mb 3
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    tooth_fail "прогон rc=$rc stderr=$(cat "$err")"
    return 0
  fi
  if ! grep -F "$r_old" "$out" | grep -Fq 'over cap'; then
    tooth_fail "старший сверхлимитный корень не снесён потолком: $(cat "$out")"
    return 0
  fi
  if grep -F "$r_new"$'\t' "$out" >/dev/null; then
    tooth_fail "младший корень снесён при достаточном потолке: $r_new"
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
    7) tooth_7 ;;
    8) tooth_8 ;;
    9) tooth_9 ;;
    10) tooth_10 ;;
    11) tooth_11 ;;
    12) tooth_12 ;;
    13) tooth_13 ;;
    14) tooth_14 ;;
    15) tooth_15 ;;
    16) tooth_16 ;;
    17) tooth_17 ;;
    18) tooth_18 ;;
    19) tooth_19 ;;
    20) tooth_20 ;;
    *) say "нет зуба $1"; return 2 ;;
  esac
}

self_check() {
  require_python
  WORK=$(mktemp -d "${REAP_SELF_WORK:-${TMPDIR:-/tmp}}/reap-heavy-self.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог self-check\n' >&2; exit 2; }
  [ -n "$WORK" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога self-check пуст\n' >&2; exit 2; }
  TOOL=$WORK/reap-heavy.sh
  cp "$HERE/reap-heavy.sh" "$TOOL"
  SNAP=$WORK/reap-heavy.sh.snap
  cp "$TOOL" "$SNAP"
  SNAP_HASH=$(sha256_of "$SNAP") || { printf 'ПРИБОР НЕДОСТУПЕН: не снят отпечаток снимка прибора\n' >&2; exit 2; }
  # Копия прибора в $WORK ищет дом имени корпуса по своему HERE -- дом едет
  # рядом с копией. Родителю суффикс нужен для фикстуры и списков зубов.
  cp "$HERE/corpus-file-name.sh" "$WORK/corpus-file-name.sh"
  cp "$HERE/corpus-list.py" "$WORK/corpus-list.py"
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

  local n green=0 redctl=0
  say "reap-heavy --self-check: зубы=20 (зелёная сторона на исходном тексте)"
  for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    TOOTH_RC=0
    run_one_tooth "$n" || return 2
    if [[ "$TOOTH_RC" -eq 0 ]]; then
      green=$((green + 1))
    fi
  done
  if [[ "$green" -ne 20 ]]; then
    say "reap-heavy --self-check: ОТКАЗ — зелёных $green из 20"
    return 1
  fi

  say "reap-heavy --self-check: красный контроль (мутация → именной красный → снимок)"
  for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    cp "$SNAP" "$TOOL"
    if ! mutate_copy "$TOOL" "$n"; then
      say "ЗУБ $n красный-контроль: ОТКАЗ прибора — якорь мутации не единственный"
      return 2
    fi
    TOOTH_RC=0
    run_one_tooth "$n" || return 2
    if [[ "$TOOTH_RC" -eq 0 ]]; then
      # Молчащий зуб помечается именной строкой и необновлением redctl:
      # очередь до конца, полный ИТОГ, ненулевой код (красный остаётся красным).
      say "ЗУБ $n красный-контроль: мутация прошла молча (зуб без зубов)"
      cp "$SNAP" "$TOOL"
      continue
    fi
    say "ЗУБ $n красный-контроль: мутация покраснела именным красным"
    cp "$SNAP" "$TOOL"
    local nowh
    nowh=$(sha256_of "$TOOL") || { printf 'ПРИБОР НЕДОСТУПЕН: не снят отпечаток копии после восстановления\n' >&2; exit 2; }
    if [[ "$nowh" != "$SNAP_HASH" ]]; then
      say "ЗУБ $n красный-контроль: sha256 после восстановления $nowh != $SNAP_HASH"
      return 1
    fi
    redctl=$((redctl + 1))
  done
  say "reap-heavy --self-check: ИТОГ зубов=20 зелёных=$green красный-контроль=$redctl"
  [[ "$green" -eq 20 && "$redctl" -eq 20 ]]
}

parse_args "$@"
if (( SELF_CHECK )); then
  if [[ -n "${REAP_SELF_CHECK_RUNNING:-}" ]]; then
    die2 "ОТКАЗ: вложенный --self-check"
  fi
  export REAP_SELF_CHECK_RUNNING=1
  self_check
  __rc=$?
  __DONE=1
  exit "$__rc"
fi

require_python
require_lsof
load_corpus_suffix
resolve_roots
run_census
__rc=$?
__DONE=1
exit "$__rc"
