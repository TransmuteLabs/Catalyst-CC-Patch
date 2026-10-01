# shellcheck shell=bash
# Изоляция побочных записей --target (#559). Подключается (`source`) конвейером
# (claude-patch-all.sh, ДО открытия замка -- предзамковой проверке изоляции
# нужны функции этого файла раньше exec 9>>, FIX5) и зубами
# (tools/target-isolation-teeth.sh). Файл ОБЪЯВЛЯЕТ функции и константы
# cold-build (новых имён два: TARGET_ISOLATION_COLD_DIRS, __TI_COLD_ON);
# никаких записей и процессов на верхнем уровне нет.
#
# CONSTRAINT: источник -- живой дом tweakcc и общий кэш распаковщика --
# НИКОГДА не редактируется и его содержимое не печатается; копия user-конфига и
# бэкапов живёт только в приватном temp прогона (каталог 0700 из проверенного
# непустого mktemp -d, не путь из пользовательской настройки).
# CONSTRAINT: до решения mktemp -- ни одной записи; отказ прибора оставляет
# сохранённый путь ПУСТЫМ, и уборка тогда не трогает ничего (опасный cleanup по
# пустоте запрещён).
# CONSTRAINT: лестница источника -- ДОСЛОВНО лестница getConfigDir запиненного
# форка (Catalyst-tweakcc @ a700ade, src/config.ts:57): непустой после trim()
# TWEAKCC_CONFIG_DIR (с раскрытием ~ по expandTildeAtLoad, src/config.ts:43),
# иначе существующий ~/.tweakcc, затем ~/.claude/tweakcc, затем
# $XDG_CONFIG_HOME/tweakcc, иначе ~/.tweakcc. Расхождение лестниц ловит
# существующая сверка «Configuration saved at» после --apply.
# CONSTRAINT: ссылки разыменовываются ПРИ КОПИРОВАНИИ (cp -L), чтобы форк не
# писал через ссылку назад в живой дом; отказ на петле/недоступном источнике --
# ДО первого запуска форка.
# CONSTRAINT: готовая запись кэша копируется с сохранением структуры (cp -a);
# КОРЕНЬ собственной копии обязан быть реальным каталогом (ссылка-источник
# переносилась бы как корень и вела в живой путь), после чего КОПИЯ
# сканируется: ссылка, разрешающаяся ВНЕ копии, с НЕСУЩЕСТВУЮЩЕЙ целью
# (битая, петля) или неразрешимая, -- отказ ДО первого CLI; ферма
# ОТНОСИТЕЛЬНЫХ ссылок pnpm внутри копии разрешена.
# CONSTRAINT: владение temp подтверждается ТОЛЬКО активацией: она кладёт в
# корень отметку с одноразовым токеном и запоминает его; уборка удаляет путь
# лишь при совпадении префикса mktemp, отметки и токена. Унаследованный из
# среды TARGET_ISOLATION_ROOT (и любой путь без отметки) не удаляется --
# конвейер обнуляет переменные ДО установки EXIT-трапа, это второй рубеж.
# CONSTRAINT: модель -- остатки дерева и конкурентные прогоны прибора, не произвольная подмена корня/маркера процессом того же UID.
# CONSTRAINT: источник монтирования проверяется только на Linux; на Darwin действует строковый слой и идентичность каталогов.
# CONSTRAINT: native-claudejs-*.js -- ВЫХОДЫ форка, не входы; не копируются.
# Коды отказа (таблица кита): 1 -- источник недоброкачественен (не-regular вход,
# петля/недоступность копирования, ссылка кэша наружу, нечитаемое поддерево
# скана); 2 -- прибор (mktemp, разрешение пути, ФС cold-build); 6 -- окружение
# (собственный temp оказался бы ВНУТРИ источника или защищённого живого дома;
# [559-fix5] то же -- для пути замка и ПРЕДКОВ защищённого дерева, и отказ
# возможен ДО открытия замка -- предзамковой проверкой;
# [559-fix6] то же -- для пути замка ВНУТРИ источника конфигурации, включая
# custom TWEAKCC_CONFIG_DIR вне защитного перечня: открытие замка (exec 9>>)
# создаёт файл замка в живом источнике. Отказ разрешения пути (python3/realpath) -- ЯВНЫЙ rc 2
# через всю цепочку __ti_real -> стражи -> preflight, не полагающийся на
# set -e вызывающего: пустой canonical path не читается разрешённым);
# [559-fix7] то же -- для ИМЕНИ замка-entry в источнике (исходящий symlink
# source/config.json наружу: realpath цели проходит, а имя живёт в источнике;
# родитель разрешается realpath(dirname), конечное имя НЕ разыменовывается),
# владелец / охраняется целиком (шаблон "$2"/* при / обращается в //), отказ
# разрешения в activate -- ЯВНЫЙ exit 2 ДО mktemp (второй рубеж).

# Скан копии записи кэша: перечисляет ссылки, разрешающиеся вне корня копии
# (абсолютные наружу, неразрешимые, петли); stdout -- по строке на ссылку,
# rc 3 -- есть хоть одна (включая отказ обхода поддерева), rc 0 -- нет.
__ti_cache_outside_links() {  # $1 корень копии
  python3 - "$1" <<'PYSCAN'
import os, sys
root = os.path.realpath(sys.argv[1])
bad = []

def _deny(err):
    # CONSTRAINT: тихий пропуск нечитаемого поддерева легализовал бы ссылку
    # наружу внутри него -- отказ обхода равен нарушению, не чистому кэшу
    bad.append('%s (обход невозможен: %s)' % (getattr(err, 'filename', None) or root, err))

# корень обязан быть доступен ЯВНО: несуществующий/закрытый корень без этой
# пробы дал бы пустой обход и rc 0 -- «чистый кэш» без единого замера
try:
    with os.scandir(root):
        pass
except OSError as err:
    _deny(err)
# [559-fix4] CONSTRAINT: отказ обхода поддерева НЕ принимается за чистый кэш --
# без onerror os.walk молча пропускает нечитаемое поддерево вместе со ссылками
for dirpath, dirnames, filenames in os.walk(root, onerror=_deny):
    for name in list(dirnames) + filenames:
        p = os.path.join(dirpath, name)
        if not os.path.islink(p):
            continue
        target = os.readlink(p)
        try:
            resolved = os.path.realpath(p)
        except OSError:
            bad.append('%s -> %s (не разрешается)' % (p, target))
            continue
        # [559c] ворота: написанная цель ОБЯЗАНА существовать -- битая ссылка
        # и петля (на новых python realpath ошибки не поднимает) неразличимы
        # от рабочей без exists()
        if not os.path.exists(resolved):
            bad.append('%s -> %s (цели нет: %s)' % (p, target, resolved))
            continue
        if resolved != root and not resolved.startswith(root + os.sep):
            bad.append('%s -> %s (вне копии: %s)' % (p, target, resolved))
if bad:
    print('\n'.join(bad))
    sys.exit(3)
PYSCAN
}

# --- [559-fix5] общие детали выбора домов: ОДНА лестница и ОДИН realpath ------
# CONSTRAINT: предзамковая проверка и активация выбирают источник, temp и
# защищённые дома ЭТИМ кодом -- вторая лестница расходилась бы молча.
__ti_path_clean() {  # $1 путь, $2 имя ручки; управляющие байты -- rc 6.
  local LC_ALL=C
  if [[ "$1" =~ [[:cntrl:]] ]]; then
    printf 'FATAL: изоляция target: %s содержит управляющий байт: %q\n' "$2" "$1" >&2
    return 6
  fi
}

__ti_inputs_clean() {
  __ti_path_clean "$HOME" HOME || return $?
  __ti_path_clean "${TMPDIR:-/tmp}" TMPDIR || return $?
  __ti_path_clean "${TWEAKCC_CONFIG_DIR:-}" TWEAKCC_CONFIG_DIR || return $?
  __ti_path_clean "${CATALYST_TWEAKCC_CACHE:-}" CATALYST_TWEAKCC_CACHE || return $?
  __ti_path_clean "${XDG_CONFIG_HOME:-}" XDG_CONFIG_HOME || return $?
  __ti_path_clean "${TWEAKCC_LOCAL:-}" TWEAKCC_LOCAL || return $?
}

__ti_real() {  # $1 путь, $2 имя ручки; прибор -- rc 2, управляющие байты -- rc 6.
  [[ -n "$1" ]] || { echo "target-isolation: пустой путь для разрешения" >&2; return 2; }
  __ti_path_clean "$1" "${2:-путь}" || return $?
  local r
  # CONSTRAINT: сентинел сохраняет хвостовой newline до проверки результата;
  # после проверки stdout уже не содержит управляющих байтов.
  r="$(python3 -c 'import os,sys;sys.stdout.write(os.path.realpath(sys.argv[1])+"\x01")' "$1")" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: не разрешён полный путь %s\n' "$1" >&2; return 2; }
  [[ "$r" == *$'\x01' ]] || { printf 'ПРИБОР НЕДОСТУПЕН: разрешение %s дало пустой путь/нет терминатора\n' "$1" >&2; return 2; }
  r="${r%$'\x01'}"
  [[ -n "$r" ]] || { printf 'ПРИБОР НЕДОСТУПЕН: разрешение %s дало пустой путь\n' "$1" >&2; return 2; }
  __ti_path_clean "$r" "${2:-разрешённый путь}" || return $?
  printf '%s\n' "$r"
}

# Лестница источника -- ДОСЛОВНО лестница getConfigDir запиненного форка
# (Catalyst-tweakcc @ a700ade, src/config.ts:57): непустой после trim()
# TWEAKCC_CONFIG_DIR (с раскрытием ~ по expandTildeAtLoad, src/config.ts:43),
# иначе существующий ~/.tweakcc, затем ~/.claude/tweakcc, затем
# $XDG_CONFIG_HOME/tweakcc, иначе ~/.tweakcc. Расхождение лестниц ловит
# существующая сверка «Configuration saved at» после --apply.
__ti_source_path() {
  __ti_inputs_clean || return $?
  local src="${TWEAKCC_CONFIG_DIR:-}"
  # CONSTRAINT: JS trim удаляет только края всей строки своим набором Unicode;
  # Python str.strip() без явного набора удалял бы также не-JS whitespace.
  src="$(python3 -c 'import sys; JS_TRIM="\u0009\u000a\u000b\u000c\u000d                  　﻿";sys.stdout.write(sys.argv[2].strip(JS_TRIM)+"\x01")' --ti-js-trim "$src")" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: trim TWEAKCC_CONFIG_DIR не выполнен\n' >&2; return 2; }
  [[ "$src" == *$'\x01' ]] || { printf 'ПРИБОР НЕДОСТУПЕН: trim TWEAKCC_CONFIG_DIR не выполнен (нет терминатора)\n' >&2; return 2; }
  src="${src%$'\x01'}"
  __ti_path_clean "$src" TWEAKCC_CONFIG_DIR || return $?
  if [[ -n "$src" ]]; then
    # [559-fix4] CONSTRAINT: раскрытие -- дословно path.join(os.homedir(),
    # filepath.slice(1)) форка (src/config.ts:43): ~other/dir -> $HOME/other/dir,
    # ~/dir -> $HOME/dir; конкатенация без слэса съедала бы границу дома
    if [[ "$src" == "~"* ]]; then
      src="${src:1}"
      # [559-fix4] CONSTRAINT: слэс границы дома ставится ЗДЕСЬ: path.join форка
      # дописывает его к «~other/dir»; снятие строки возвращает склейку без границы
      [[ "$src" == /* ]] || src="/$src"
      src="$HOME$src"
    fi
  # [559-fix4] CONSTRAINT: existsSync форка -- это -e, НЕ -d: существующий ФАЙЛ
  # ~/.tweakcc выбирается лестницей и отвергается ниже как не-каталог, без
  # отката к следующему дому (расхождение ловится сверкой «Configuration saved at»)
  elif [[ -e "$HOME/.tweakcc" ]]; then
    src="$HOME/.tweakcc"
  elif [[ -e "$HOME/.claude/tweakcc" ]]; then
    src="$HOME/.claude/tweakcc"
  elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    src="$XDG_CONFIG_HOME/tweakcc"
  else
    src="$HOME/.tweakcc"
  fi
  printf '%s\n' "$src"
}

# [559-fix6] общий сегментный страж «кандидат НЕ внутри живого владельца»:
# ЕДИНСТВЕННОЕ сравнение реальных путей по границе сегмента (совпадение либо
# вложенность) -- его зовут и для TMPDIR, и для пути замка, оба против
# источника конфигурации; вторая копия сравнения расходилась бы молча.
# CONSTRAINT: сравнение РЕАЛЬНЫХ путей; отказ -- rc 6 (окружение) ДО mktemp и
# ДО открытия замка -- ни одного байта в живое состояние (exec 9>> создаёт
# файл замка на пути, которого ещё нет).
__ti_guard_inside() {  # $1 кандидат (реальный путь), $2 владелец (реальный путь), $3 имя кандидата, $4 имя владельца
  local inside=0
  # [559-fix7] ворота: владелец / -- ЛЮБОЙ абсолютный кандидат вложен в корень:
  # шаблон "$2"/* при / обращается в // и не покрывает даже /tmp, источник /
  # оставался без охраны; не-абсолютный кандидат у realpath-владельца невозможен
  if [[ "$2" == "/" ]]; then
    if [[ "$1" == /* ]]; then
      inside=1
    fi
  elif [[ "$1" == "$2" || "$1" == "$2"/* ]]; then
    inside=1
  fi
  # CONSTRAINT: required требует строгой вложенности, не равенства корню.
  if [[ "${5:-}" == required ]]; then
    if [[ "$inside" != 1 || "$1" == "$2" ]]; then
      echo "FATAL: изоляция target: $3 ($1) не лежит строго внутри $4 ($2)" >&2
      exit 6
    fi
  elif [[ "$inside" == 1 ]]; then
    echo "FATAL: изоляция target: $3 ($1) лежит внутри $4 ($2) -- живое состояние, staging не вправе менять его байты и inode. Исправьте TMPDIR/CLAUDE_PATCH_LOCK." >&2
    exit 6
  fi
}

__ti_guard_identity() {  # $1 кандидат, $2 имя, остальные -- защищённые каталоги.
  local ti_python_rc=0
  python3 - "$@" <<'PYIDENTITY' || ti_python_rc=$?
import os, sys
try:
    identities = set()
    for p in sys.argv[3:]:
        try:
            s = os.stat(p)
        except FileNotFoundError:
            continue
        identities.add((s.st_dev, s.st_ino))
    p = os.path.realpath(sys.argv[1])
    while True:
        try:
            s = os.stat(p)
            break
        except FileNotFoundError:
            parent = os.path.dirname(p)
            if parent == p:
                raise
            p = parent
    while True:
        if (s.st_dev, s.st_ino) in identities:
            print('FATAL: изоляция target: %s -- идентичность предка совпадает с защищённым каталогом (%s)' % (sys.argv[2], p), file=sys.stderr)
            sys.exit(6)
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
        s = os.stat(p)
except OSError as e:
    print('ПРИБОР НЕДОСТУПЕН: идентичность каталогов не измерена: %s' % e, file=sys.stderr)
    sys.exit(2)
PYIDENTITY
  case "$ti_python_rc" in
    0|2|6) return "$ti_python_rc" ;;
    *) printf 'ПРИБОР НЕДОСТУПЕН: идентичность каталогов: python3 rc %s\n' "$ti_python_rc" >&2; return 2 ;;
  esac
}

__ti_guard_mount_source() {  # $1 кандидат, $2 имя, остальные -- защищённые каталоги.
  local ti_python_rc=0
  python3 - "$@" <<'PYMOUNT' || ti_python_rc=$?
import os, posixpath, re, sys
if sys.platform != 'linux':
    sys.exit(0)

def inside(p, root):
    return p == root or p.startswith(root.rstrip('/') + '/')

def decode(p):
    p = re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), p)
    if not p.startswith('/'):
        raise ValueError('mountinfo: не абсолютный путь')
    return p

try:
    mounts = []
    # CONSTRAINT: ручка меняет только путь чтения mountinfo, не отключает слой.
    with open(os.environ.get('TARGET_ISOLATION_MOUNTINFO', '/proc/self/mountinfo'), encoding='utf-8', errors='surrogateescape') as f:
        for line in f:
            fields = line.split()
            sep = fields.index('-')
            if sep < 6 or len(fields) != sep + 4 or not re.fullmatch(r'[0-9]+:[0-9]+', fields[2]):
                raise ValueError('mountinfo: неверная запись')
            int(fields[0]); int(fields[1])
            mounts.append((fields[2], decode(fields[3]), decode(fields[4])))
    if not mounts:
        raise ValueError('mountinfo: пустая таблица')

    def source(p):
        p = os.path.realpath(p)
        matches = [m for m in mounts if inside(p, m[2])]
        if not matches:
            raise ValueError('mountinfo: нет точки монтирования для ' + p)
        dev, root, point = max(matches, key=lambda m: len(m[2]))
        rest = p[len(point):].lstrip('/')
        return dev, posixpath.normpath(posixpath.join(root, rest))

    candidate = os.path.realpath(sys.argv[1])
    while True:
        try:
            os.stat(candidate)
            break
        except FileNotFoundError:
            parent = os.path.dirname(candidate)
            if parent == candidate:
                raise
            candidate = parent
    dev, path = source(candidate)
    for p in sys.argv[3:]:
        try:
            os.stat(p)
        except FileNotFoundError:
            continue
        pdev, ppath = source(p)
        if dev == pdev and inside(path, ppath):
            print('FATAL: изоляция target: %s -- источник монтирования внутри защищённого каталога (%s)' % (sys.argv[2], p), file=sys.stderr)
            sys.exit(6)
except (OSError, ValueError, IndexError) as e:
    print('ПРИБОР НЕДОСТУПЕН: mountinfo не прочитан/не разобран: %s' % e, file=sys.stderr)
    sys.exit(2)
PYMOUNT
  case "$ti_python_rc" in
    0|2|6) return "$ti_python_rc" ;;
    *) printf 'ПРИБОР НЕДОСТУПЕН: mountinfo: python3 rc %s\n' "$ti_python_rc" >&2; return 2 ;;
  esac
}

# [559-fix5] общий страж защищённых домов: ЕДИНСТВЕННЫЙ перечень и правила --
# его зовут и предзамковая проверка (путь замка, TMPDIR), и активация (TMPDIR).
# Кандидат не может:
#   лежать внутри защищённого живого дома -- сам общий $HOME/.cache входит в
#     защищённую область, а не только его pnpm/catalyst-подкаталоги;
#   быть ПРЕДКОМ защищённого дерева ВНУТРИ живого HOME (сам $HOME, $HOME/.cache,
#     $HOME/.local и т.д.) -- temp/замок разбрасывали бы состояние по живому
#     дереву; системный tmp, содержащий тестовый HOME, предком НЕ считается
#     (он вне живого HOME);
#   быть живым XDG-родителем защищённого дома, когда тот вне HOME.
# CONSTRAINT: сравнение РЕАЛЬНЫХ путей по границе сегмента; отказ -- rc 6
# (окружение), ДО mktemp и ДО открытия замка -- ни одного байта в живые дома
# и никаких удалений в общем кэше; target-warden и чужие каталоги не трогаются.
__ti_guard_protected() {  # $1 кандидат (реальный путь), $2 имя кандидата (текст)
  # [559-fix12] CONSTRAINT: пустой HOME -- отказ окружения, не «дом = cwd»
  [[ -n "${HOME:-}" ]] || { echo "FATAL: изоляция target: HOME пуст -- защищённые живые дома не определены; задайте HOME." >&2; return 6; }
  local home_real
  # [559-fix6] CONSTRAINT: отказ разрешения -- ЯВНЫЙ return 2 наверх: пустой
  # home_real молча пропускал бы предка-сравнения (сравнение с пустотой)
  home_real="$(__ti_real "$HOME" HOME)" || return $?
  local ti_prot='' ti_prot_real=''
  local -a ti_protected=()
  for ti_prot in "$HOME/.claude" "$HOME/.tweakcc" "$HOME/.npm" "$HOME/.cache" "$HOME/.cache/pnpm" "$HOME/.local/share/pnpm" "$HOME/.local/share/claude" "$HOME/.local/state/pnpm" "${CATALYST_TWEAKCC_CACHE:-$HOME/.cache/catalyst-tweakcc}" "${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/tweakcc}"; do
    [[ -n "$ti_prot" ]] || continue
    # [559-fix6] тот же явный отказ прибора: пустой защищённый путь -- не «нет защиты»
    ti_prot_real="$(__ti_real "$ti_prot" "защищённый путь HOME/CATALYST_TWEAKCC_CACHE/XDG_CONFIG_HOME")" || return $?
    ti_protected+=("$ti_prot_real")
    if [[ "$1" == "$ti_prot_real" || "$1" == "$ti_prot_real"/* ]]; then
      echo "FATAL: изоляция target: $2 ($1) лежит внутри защищённого живого дома/общего кэша ($ti_prot_real) -- staging не вправе менять его состояние. Исправьте TMPDIR/CLAUDE_PATCH_LOCK." >&2
      exit 6
    fi
    # [559-fix8] ворота: кандидат / -- предок КАЖДОГО защищённого дома, вне
    # зависимости от положения HOME: шаблон "$1"/* при / обращается в //
    if [[ "$1" == "/" ]]; then
      echo "FATAL: изоляция target: $2 ($1) -- корень ФС, предок защищённого живого дома ($ti_prot_real): собственный temp/замок создавали бы состояние в живом дереве. Исправьте TMPDIR/CLAUDE_PATCH_LOCK." >&2
      exit 6
    fi
    if [[ "$ti_prot_real" == "$1"/* ]]; then
      if [[ "$1" == "$home_real" || "$1" == "$home_real"/* ]]; then
        echo "FATAL: изоляция target: $2 ($1) -- предок защищённого живого дома ($ti_prot_real): собственный temp/замок создавали бы состояние в живом дереве. Исправьте TMPDIR/CLAUDE_PATCH_LOCK." >&2
        exit 6
      fi
      # [559-fix8] ворота: HOME / -- любой абсолютный кандидат лежит в HOME:
      # шаблон "$home_real"/* при / обращается в //
      if [[ "$home_real" == "/" && "$1" == /* ]]; then
        echo "FATAL: изоляция target: $2 ($1) -- предок защищённого живого дома ($ti_prot_real) внутри живого HOME (/): собственный temp/замок создавали бы состояние в живом дереве. Исправьте TMPDIR/CLAUDE_PATCH_LOCK." >&2
        exit 6
      fi
      # CONSTRAINT: dirname вне [[ -- отказ подстановки внутри [[ не становится rc стража, пустой вывод не отличим от «не родитель».
      if [[ -n "${XDG_CONFIG_HOME:-}" && "$ti_prot" == "$XDG_CONFIG_HOME/tweakcc" ]]; then
        local ti_xdg_parent
        ti_xdg_parent="$(dirname "$ti_prot_real")" \
          || { printf 'ПРИБОР НЕДОСТУПЕН: dirname защищённого дома не выполнен: %s\n' "$ti_prot_real" >&2; return 2; }
        [[ -n "$ti_xdg_parent" ]] \
          || { printf 'ПРИБОР НЕДОСТУПЕН: dirname защищённого дома пуст: %s\n' "$ti_prot_real" >&2; return 2; }
        if [[ "$1" == "$ti_xdg_parent" ]]; then
          echo "FATAL: изоляция target: $2 ($1) -- живой XDG-родитель защищённого дома ($ti_prot_real). Исправьте TMPDIR/CLAUDE_PATCH_LOCK." >&2
          exit 6
        fi
      fi
    fi
  done
  __ti_guard_identity "$1" "$2" "${ti_protected[@]}" || return $?
  __ti_guard_mount_source "$1" "$2" "${ti_protected[@]}" || return $?
}

__ti_cache_destination() {
  local dest root
  dest="$(__ti_real "$1" "назначение кэша")" || return $?
  root="$(__ti_real "$TARGET_ISOLATION_ROOT" TARGET_ISOLATION_ROOT)" || return $?
  __ti_guard_inside "$dest" "$root" "назначение кэша" TARGET_ISOLATION_ROOT required
  __ti_guard_protected "$dest" "назначение кэша" || return $?
}

# [559-fix5] страж TMPDIR: источник + защищённые дома. Проверка ДО mktemp и
# ДО открытия замка: собственный temp не может лежать внутри копируемого
# источника (он скопировал бы сам себя) ни внутри защищённого живого дома.
# [559-fix6] CONSTRAINT: сравнение с источником -- ОБЩИЙ сегментный страж
# (__ti_guard_inside); им же предзамковая проверка держит путь замка вне
# источника (custom TWEAKCC_CONFIG_DIR вне HOME/XDG/кеша -- тоже живое
# состояние). Отказ разрешения пути -- rc 2 наверх, не пустой путь
__ti_guard_tmp() {  # $1 tmp_real, $2 src_real
  __ti_guard_inside "$1" "$2" "TMPDIR" "источника"
  __ti_guard_protected "$1" "TMPDIR" || return $?
}

# [559-fix5] предзамковая проверка --target: ТОЛЬКО ЧТЕНИЕ (realpath), вызывается
# конвейером ДО exec 9>>"$__lock". CONSTRAINT: проверяет путь ФАКТИЧЕСКИ
# выбранного замка -- как заданный CLAUDE_PATCH_LOCK, так и выведенный из
# TMPDIR -- и сам TMPDIR; отказ (rc 6) не создаёт ни замка, ни temp, ни одного
# CLI и не меняет байты/mtime защищённого дерева. Проверка только внутри
# activate для замка ПОЗДНЯЯ -- к тому моменту exec 9>> уже писал бы в живой
# дом; активация сохраняет собственные проверки как второй рубеж. Нормальный
# общий замок в системном tmp остаётся разрешён (включая унаследованный замок
# под /tmp при тестовом HOME внутри /tmp: системный tmp не становится «общим
# кэшем» от положения фикстуры).
# [559-fix6] CONSTRAINT: отказ разрешения пути (python3/realpath) -- ЯВНЫЙ
# rc 2 на КАЖДОМ шаге цепочки __ti_real -> стражи -> сюда: под set +e пустой
# canonical path не имеет права читаться разрешённым (стражи с пустым
# кандидатом молча проходят). Отказ защиты -- rc 6.
target_isolation_preflight() {  # $1 путь замка, уже выбранный вызывающим
  __ti_inputs_clean || return $?
  __ti_path_clean "$1" "путь замка" || return $?
  local src_path src_real tmp_real lock_real
  # [559-fix8] ворота: путь источника -- отдельная проверяемая ступень: статус
  # подстановки, вложенной в аргумент __ti_real, гаснет, и пустой путь
  # разрешился бы realpath в cwd
  src_path="$(__ti_source_path)" || return $?
  # [559-fix8] ворота: пустой путь источника -- отказ ДО разрешения
  [[ -n "$src_path" ]] \
    || { printf 'ПРИБОР НЕДОСТУПЕН: путь источника конфигурации пуст\n' >&2; return 2; }
  # [559-fix8] ворота: разрешение источника -- проверяемая ступень после пути
  src_real="$(__ti_real "$src_path" "источника")" || return $?
  tmp_real="$(__ti_real "${TMPDIR:-/tmp}" TMPDIR)" || return $?
  __ti_guard_tmp "$tmp_real" "$src_real" || return $?
  # [559-fix6] ворота: отказ разрешения пути замка -- rc 2, не пустой путь:
  # пустой lock_real молча проходил бы оба стража и разрешал замок
  lock_real="$(__ti_real "$1" "путь замка")" || return $?
  # [559-fix6] ворота: путь замка -- НЕ внутри источника конфигурации; custom
  # TWEAKCC_CONFIG_DIR вне HOME/XDG/кеша -- всё равно живое состояние, а
  # открытие замка (exec 9>>) создаёт файл замка в источнике;
  # тот же сегментный страж, что и для TMPDIR (ссылки уже разыменованы realpath)
  __ti_guard_inside "$lock_real" "$src_real" "путь замка" "источника"
  __ti_guard_protected "$lock_real" "путь замка" || return $?
  # [559-fix7] ворота: ИМЯ замка -- entry в РАЗРЕШЁННОМ родителе: realpath цели
  # пропускал исходящую ссылку ИЗ источника (source/config.json -> внешний
  # файл: цель снаружи, а имя живёт в источнике). Родитель разрешается realpath
  # (symlink родителей и самого источника схлопываются), конечное имя НЕ
  # разыменовывается; родитель относительного имени без / -- ., для /leaf -- /;
  # сосед-не-владелец (source-other) границей сегмента не задевается; отказ
  # разрешения родителя -- явный rc 2
  local lock_dir lock_base lock_parent lock_entry
  # [559-fix8] ворота: dirname пути замка -- отдельная проверяемая ступень:
  # вложенный в аргумент __ti_real отказ гас, пустой родитель разрешался в cwd
  lock_dir="$(dirname -- "$1")" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: dirname пути замка не выполнен: %s\n' "$1" >&2; return 2; }
  # [559-fix8] ворота: пустой родитель пути замка
  [[ -n "$lock_dir" ]] \
    || { printf 'ПРИБОР НЕДОСТУПЕН: dirname пути замка пуст: %s\n' "$1" >&2; return 2; }
  # [559-fix8] ворота: basename пути замка -- отдельная проверяемая ступень
  lock_base="$(basename -- "$1")" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: basename пути замка не выполнен: %s\n' "$1" >&2; return 2; }
  # [559-fix8] ворота: пустое имя пути замка
  [[ -n "$lock_base" ]] \
    || { printf 'ПРИБОР НЕДОСТУПЕН: basename пути замка пуст: %s\n' "$1" >&2; return 2; }
  lock_parent="$(__ti_real "$lock_dir" "родитель пути замка")" || return $?
  lock_entry="$lock_parent/$lock_base"
  # [559-fix7] ворота: имя-entry НЕ внутри источника (снятие = допуск замка)
  __ti_guard_inside "$lock_entry" "$src_real" "имя замка" "источника"
}

target_isolation_activate() {
  # Вызывается ТОЛЬКО веткой --target ДО ensure_tweakcc и до первого CLI
  # (включая --list-patches): после неё TWEAKCC_CONFIG_DIR указывает на
  # собственный temp-дом, и ни одна стадия не видит живого дома.

  # --- лестница источника: ОБЩИЙ код с предзамковой проверкой (см. CONSTRAINT
  # у __ti_source_path); активация сохраняет собственные проверки как второй
  # рубеж -- предзамковая проверка для замка поздней быть не может
  local src_path src_real
  # [559-fix8] ворота: путь источника -- отдельная проверяемая ступень, ЯВНЫЙ
  # exit 2 ДО mktemp и первого CLI (статус вложенной подстановки гаснет)
  src_path="$(__ti_source_path)" || exit $?
  # [559-fix8] ворота: пустой путь источника в activate -- отказ ДО разрешения
  [[ -n "$src_path" ]] \
    || { printf 'ПРИБОР НЕДОСТУПЕН: путь источника конфигурации пуст\n' >&2; exit 2; }
  # [559-fix7] ворота: отказ разрешения источника -- ЯВНЫЙ exit 2 ДО mktemp и
  # первого CLI: под set +e пустой src_real молча шёл в стражи (пустой владелец
  # в сегментном сравнении); тело продукта в shell вправе завершаться здесь
  # явно -- верхний уровень helper остаётся декларативным
  src_real="$(__ti_real "$src_path" "источника")" || exit $?
  if [[ -e "$src_real" && ! -d "$src_real" ]]; then
    echo "FATAL: изоляция target: источник конфигурации не каталог: $src_real" >&2
    exit 1
  fi

  # --- собственный temp: источник и защищённые дома -- ОБЩИЙ страж
  # (__ti_guard_tmp); проверка ДО mktemp -- ни одного байта в живые дома
  local tmp_real
  # [559-fix8] ворота: разрешение TMPDIR в activate -- ЯВНЫЙ exit 2 ДО mktemp
  tmp_real="$(__ti_real "${TMPDIR:-/tmp}" TMPDIR)" || exit $?
  # [559-fix8] ворота: страж TMPDIR в activate -- ЯВНЫЙ exit 2 ДО mktemp
  __ti_guard_tmp "$tmp_real" "$src_real" || exit $?

  local owner_token="ti-$$-${BASHPID:-$$}-${RANDOM}${RANDOM}"
  TARGET_ISOLATION_OWNER_TOKEN=''
  TARGET_ISOLATION_ROOT="$(mktemp -d "$tmp_real/cc-target-isolation.XXXXXXXX")" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: не создан собственный каталог target-прогона\n' >&2; exit 2; }
  [[ -n "$TARGET_ISOLATION_ROOT" ]] \
    || { printf 'ПРИБОР НЕДОСТУПЕН: путь собственного каталога target-прогона пуст\n' >&2; exit 2; }
  # CONSTRAINT: маркер -- первая запись после mktemp; до успешной записи
  # рекурсивная уборка не вправе признавать каталог своим.
  if ! printf '%s\n' "$owner_token" > "$TARGET_ISOLATION_ROOT/.catalyst-ti-owner"; then
    printf 'ПРИБОР НЕДОСТУПЕН: не записана отметка владения %s\n' "$TARGET_ISOLATION_ROOT/.catalyst-ti-owner" >&2
    rm -f -- "$TARGET_ISOLATION_ROOT/.catalyst-ti-owner" \
      || { printf 'ПРИБОР НЕДОСТУПЕН: не удалён собственный маркер: %s\n' "$TARGET_ISOLATION_ROOT" >&2; exit 2; }
    rmdir -- "$TARGET_ISOLATION_ROOT" \
      || { printf 'ПРИБОР НЕДОСТУПЕН: не убран каталог после отказа маркера: %s\n' "$TARGET_ISOLATION_ROOT" >&2; exit 2; }
    TARGET_ISOLATION_ROOT=''
    exit 2
  fi
  TARGET_ISOLATION_OWNER_TOKEN="$owner_token"
  # CONSTRAINT: после маркера отказ chmod/-d узнаётся штатной EXIT-уборкой.
  chmod 700 "$TARGET_ISOLATION_ROOT" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: не выставлен 0700 на %s\n' "$TARGET_ISOLATION_ROOT" >&2; exit 2; }
  [[ -d "$TARGET_ISOLATION_ROOT" ]] \
    || { printf 'ПРИБОР НЕДОСТУПЕН: собственный путь не каталог: %s\n' "$TARGET_ISOLATION_ROOT" >&2; exit 2; }

  # --- копия входов текущего пина форка ---------------------------------------
  local own="$TARGET_ISOLATION_ROOT/home"
  mkdir -m 700 -p "$own" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: не создан собственный дом %s\n' "$own" >&2; exit 2; }
  if [[ -d "$src_real" ]]; then
    local f
    for f in config.json native-binary.backup cli.js.backup \
             catalyst-expected-off.txt catalyst-home-origin.txt \
             catalyst-prompt-floor.txt catalyst-prompt-conflicts.txt \
             systemPromptOriginalHashes.json systemPromptAppliedHashes.json; do
      if [[ -e "$src_real/$f" || -L "$src_real/$f" ]]; then
        # Существующий не-regular (битая ссылка, каталог, FIFO) -- отказ;
        # отсутствие входа допустимо там, где его допустим форк.
        [[ -f "$src_real/$f" ]] || {
          echo "FATAL: изоляция target: вход дома tweakcc не обычный файл: $src_real/$f" >&2
          exit 1
        }
        cp -pL "$src_real/$f" "$own/$f" || {
          echo "FATAL: изоляция target: вход не скопирован (петля/недоступен): $src_real/$f" >&2
          exit 1
        }
      fi
    done
    for f in system-prompts prompt-data-cache; do
      if [[ -e "$src_real/$f" || -L "$src_real/$f" ]]; then
        [[ -d "$src_real/$f" ]] || {
          echo "FATAL: изоляция target: вход дома tweakcc не каталог: $src_real/$f" >&2
          exit 1
        }
        cp -RpL "$src_real/$f" "$own/$f" || {
          echo "FATAL: изоляция target: каталог не скопирован (петля/недоступен): $src_real/$f" >&2
          exit 1
        }
      fi
    done
  else
    # Исходного дома нет: собственный ПУСТОЙ дом с отметкой происхождения --
    # только ВНУТРИ него. Без отметки дверь выключенных правок приняла бы
    # дефолты форка за дрейф и красила бы свежую машину.
    printf 'target-прогон #559: дом создан изоляцией --target; оператора у него нет, исходного дома (%s) не было\n' "$src_real" \
      > "$own/catalyst-home-origin.txt" \
      || { printf 'ПРИБОР НЕДОСТУПЕН: не записана отметка происхождения собственного дома\n' >&2; exit 2; }
  fi

  # --- кэш распаковщика --------------------------------------------------------
  # TWEAKCC_LOCAL -- явное решение оператора: кэш не изолируется, конфигурация
  # всё равно собственная.
  local cache_copied=0
  if [[ -z "${TWEAKCC_LOCAL:-}" ]]; then
    local cache_src="${CATALYST_TWEAKCC_CACHE:-$HOME/.cache/catalyst-tweakcc}"
    local cache_own="$TARGET_ISOLATION_ROOT/cache"
    __ti_path_clean "$cache_src/$CATALYST_TWEAKCC_SHA" "источник кэша" || exit $?
    __ti_path_clean "$cache_own/$CATALYST_TWEAKCC_SHA" "назначение кэша" || exit $?
    mkdir -m 700 -p "$cache_own" \
      || { printf 'ПРИБОР НЕДОСТУПЕН: не создан собственный кэш %s\n' "$cache_own" >&2; exit 2; }
    __ti_cache_destination "$cache_own/$CATALYST_TWEAKCC_SHA" || exit $?
    if [[ -f "$cache_src/$CATALYST_TWEAKCC_SHA/dist/index.mjs" ]]; then
      # Запись пина переносится ЦЕЛИКОМ с сохранением структуры (cp -a: ферма
      # ОТНОСИТЕЛЬНЫХ ссылок pnpm внутри записи остаётся рабочей в копии).
      # Абсолютная ссылка наружу собственной копии вела бы запись форка в
      # живой путь -- копия сканируется, нарушение -- отказ ДО первого CLI.
      # Общий кэш ниже НЕ читается на запись и НЕ чистится; без готовой записи
      # штатная загрузка ensure_tweakcc собирает форк только в собственном кэше.
      cp -a "$cache_src/$CATALYST_TWEAKCC_SHA" "$cache_own/$CATALYST_TWEAKCC_SHA" || {
        echo "FATAL: изоляция target: готовая запись пина не скопирована в собственный кэш" >&2
        exit 1
      }
      # [559c] ворота: корень собственной записи -- РЕАЛЬНЫЙ каталог, не
      # ссылка: cp -a переносит ссылку-источник как корень копии, и тогда
      # весь прогон (и realpath скана) читал бы через неё живой каталог.
      if [[ -L "$cache_own/$CATALYST_TWEAKCC_SHA" || ! -d "$cache_own/$CATALYST_TWEAKCC_SHA" ]]; then
        echo "FATAL: изоляция target: корень собственной записи кэша -- ссылка или не каталог ($cache_own/$CATALYST_TWEAKCC_SHA); копия вела бы в живой путь. Отказ ДО первого CLI" >&2
        exit 1
      fi
      [[ -f "$cache_own/$CATALYST_TWEAKCC_SHA/dist/index.mjs" ]] || {
        echo "FATAL: изоляция target: копия записи пина неполна (нет dist/index.mjs)" >&2
        exit 1
      }
      local scan_out='' scan_rc=0
      scan_out="$(__ti_cache_outside_links "$cache_own/$CATALYST_TWEAKCC_SHA")" || scan_rc=$?
      # [559b] ворота: ссылки кэша не выходят за собственную копию -- запись
      # форка через абсолютную/неразрешимую ссылку ушла бы в живой путь.
      # [559-fix4] нечитаемое поддерево скана -- тот же отказ: принять его за
      # чистый кэш значило бы пропустить ссылки, которые скан не увидел.
      if [[ $scan_rc -ne 0 ]]; then
        echo "FATAL: изоляция target: запись пина кэша несёт ссылки наружу собственной копии или недоступные для скана поддеревья -- запись форка ушла бы в живой путь либо не проверена. Отказ ДО первого CLI:" >&2
        if [[ -n "$scan_out" ]]; then
          printf '%s\n' "$scan_out" | sed 's/^/  /' >&2
        fi
        exit 1
      fi
      cache_copied=1
    fi
    CATALYST_TWEAKCC_CACHE="$cache_own"
  fi

  # ДО первого CLI: форк (getConfigDir) и kit-лестница обязаны увидеть копию.
  export TWEAKCC_CONFIG_DIR="$own"
  echo "Изоляция target (#559): дом конфигурации -- собственный temp $own (источник $src_real остаётся нетронутым)"
  if [[ -z "${TWEAKCC_LOCAL:-}" ]]; then
    if [[ $cache_copied -eq 1 ]]; then
      echo "Изоляция target (#559): кэш распаковщика -- собственный temp $CATALYST_TWEAKCC_CACHE (готовая запись пина скопирована)"
    else
      echo "Изоляция target (#559): кэш распаковщика -- собственный temp $CATALYST_TWEAKCC_CACHE (готовой записи нет; штатная загрузка соберёт форк в нём)"
    fi
  else
    echo "Изоляция target (#559): кэш НЕ изолируется -- TWEAKCC_LOCAL задан оператором явно; конфигурация всё равно собственная"
  fi
}

target_isolation_cleanup() {
  # Убирает ТОЛЬКО собственный temp: непустой УНИКАЛЬНЫЙ путь, сохранённый
  # активацией, проверенный как каталог и как абсолютный путь. Пустой путь --
  # прибора не было, убирать нечего; чужие каталоги и живые пути не трогаются.
  # Вызывается из __release_lock конвейера (EXIT/INT/TERM идут через него).
  local root="${TARGET_ISOLATION_ROOT:-}"
  [[ -n "$root" ]] || return 0
  if [[ "$root" != /* || "$root" == "/" ]]; then
    echo "ВНИМАНИЕ: путь изоляции target не абсолютный -- уборка пропущена: $root" >&2
    return 0
  fi
  [[ -d "$root" ]] || return 0
  local base base_rc=0
  base="$(basename "$root" 2>&1)" || base_rc=$?
  if [[ $base_rc -ne 0 ]]; then
    printf 'ВНИМАНИЕ: basename при уборке отказал (rc=%s), каталог не удалён: %s; %s\n' "$base_rc" "$root" "$base" >&2
    return 2
  fi
  if [[ "$base" != cc-target-isolation.* ]]; then
    echo "ВНИМАНИЕ: путь изоляции target не несёт префикса собственного mktemp -- уборка пропущена: $root" >&2
    return 0
  fi
  local marker="$root/.catalyst-ti-owner" want="${TARGET_ISOLATION_OWNER_TOKEN:-}"
  local have='' have_rc=0
  if [[ -f "$marker" ]]; then
    have="$(LC_ALL=C sed -n '1p' "$marker" 2>&1)" || have_rc=$?
    if [[ $have_rc -ne 0 ]]; then
      printf 'ВНИМАНИЕ: чтение маркера при уборке отказало (rc=%s), каталог не удалён: %s; %s\n' "$have_rc" "$root" "$have" >&2
      return 2
    fi
  fi
  # [559b] ворота: уборка только подтверждённого владельца -- совпадение
  # абсолютного пути владения не доказывает: отметка и токен ставятся ТОЛЬКО
  # активацией (mktemp), унаследованный из среды путь их не несёт.
  if [[ -z "$want" || "$have" != "$want" ]]; then
    echo "ВНИМАНИЕ: путь изоляции target не подтверждён владельцем -- уборка пропущена: $root" >&2
    return 0
  fi
  rm -rf "$root" || { echo "ВНИМАНИЕ: не убран temp изоляции target: $root" >&2; return 2; }
  return 0
}

# --- [559-fix4] перенаправление писателей холодной сборки форка ----------------
# Холодная загрузка ensure_tweakcc без перенаправления писала npm/pnpm-кэши в
# живые HOME-дома (замер Linux: 11 726 файлов ~514 МБ; с перенаправлением --
# ноль). CONSTRAINT: перенаправление действует ТОЛЬКО на дочерний процесс
# install/build через __ti_cold_wrap -- глобальные и пользовательские значения
# не меняются; подкаталоги создаются ДО запуска и обязаны лежать на той же ФС,
# что каталог сборки (иначе pnpm выбирает volume-root store); ветка включается
# только под --target (активация уже гарантировала: root вне защищённых домов).
TARGET_ISOLATION_COLD_DIRS=(npm-cache xdg-data xdg-cache xdg-state)
__TI_COLD_ON=0

target_isolation_cold_env() {  # $1 каталог сборки ($dir.tmp); включает перенаправление
  [[ -n "${TARGET_ISOLATION_ROOT:-}" ]] || { printf 'ПРИБОР НЕДОСТУПЕН: cold-build без собственного temp изоляции\n' >&2; exit 2; }
  local d='' dev_root='' dev=''
  dev_root="$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_dev)' "$1")" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: не измерено устройство каталога сборки\n' >&2; exit 2; }
  [[ -n "$dev_root" ]] || { printf 'ПРИБОР НЕДОСТУПЕН: пустое устройство каталога сборки\n' >&2; exit 2; }
  for d in "${TARGET_ISOLATION_COLD_DIRS[@]}"; do
    mkdir -p "$TARGET_ISOLATION_ROOT/$d" \
      || { printf 'ПРИБОР НЕДОСТУПЕН: не создан приватный каталог cold-build %s\n' "$d" >&2; exit 2; }
  done
  for d in "${TARGET_ISOLATION_COLD_DIRS[@]}"; do
    dev="$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_dev)' "$TARGET_ISOLATION_ROOT/$d")" \
      || { printf 'ПРИБОР НЕДОСТУПЕН: не измерено устройство приватного каталога %s\n' "$d" >&2; exit 2; }
    [[ "$dev" == "$dev_root" ]] || {
      echo "FATAL: изоляция target: приватный каталог cold-build ($TARGET_ISOLATION_ROOT/$d) на другой ФС, чем каталог сборки ($1) -- pnpm выбрал бы volume-root store. Отказ ДО запуска install/build" >&2
      exit 2
    }
  done
  __TI_COLD_ON=1
}

__ti_cold_wrap() {  # запуск холодной сборки с перенаправлением писателей
  # [559-fix4] CONSTRAINT: единственная точка перенаправления четырёх писателей
  # -- эта строка: её снятие убирает все четыре редиректа сразу и краснит
  # адресный зуб по живым домам; включается только target_isolation_cold_env
  if [[ "${__TI_COLD_ON:-0}" == 1 ]]; then
    env "npm_config_cache=$TARGET_ISOLATION_ROOT/npm-cache" "XDG_DATA_HOME=$TARGET_ISOLATION_ROOT/xdg-data" "XDG_CACHE_HOME=$TARGET_ISOLATION_ROOT/xdg-cache" "XDG_STATE_HOME=$TARGET_ISOLATION_ROOT/xdg-state" "$@"
  else
    "$@"
  fi
}
