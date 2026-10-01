#!/usr/bin/env bash
# Зубы изоляции побочных записей --target (#559). Три писателя, наблюдавшихся в
# живых прогонах (build-staging-7.log:764,1055-1060): автосверка/автораскатка
# проб в настоящий дом, модельный sync с чисткой бэкапов конфига, живой дом и
# общий кэш tweakcc. Предмет -- СИНТЕТИЧЕСКИЕ фикстуры в mktemp: ни одного
# байта настоящего конфига или креденшела в фикстуре нет, живой HOME не читается
# на запись НИКОГДА.
# Волна FIX4 (T36+): тихий отказ обхода os.walk скана кэша, лестница источника
# existsSync/-e и раскрытие ~other, TMPDIR в защищённых живых домах, export
# TWEAKCC_CONFIG_DIR в ENV детей, touch-only записи (st_mtime_ns в снимке),
# холодная сборка ensure_tweakcc с перенаправлением npm/pnpm/XDG-писателей,
# выключатель deep-link-регистрации в составленном gate settings и честность
# строки target-ветки раскатки о стендах кита.
# Волна FIX5 (T57+): предзамковая проверка НАСТОЯЩЕГО конвейера (замок из
# TMPDIR/CLAUDE_PATCH_LOCK не открывается в защищённом живом доме и общем
# кэше, включая предков), квитанция target-раскатки в каноне стадий,
# подлинный блок стендов кита вместе с раскаткой в T54, ветка st_dev
# холодной сборки контролируемой подменой пробы.
# Волна FIX6 (T63+): замок не открывается и ВНУТРИ ИСТОЧНИКА конфигурации
# (custom TWEAKCC_CONFIG_DIR вне защитного перечня -- живое состояние, exec 9>
# обнуляет его байты), отказ разрешения пути (python3/realpath) -- ЯВНЫЙ rc 2
# через всю цепочку даже под set +e; T57/T59/T61/T62 измеряют раннюю запись,
# стадию и запуск мока по предметным свидетелям, не по ENOENT/игле/TI_ROOT.
# Волна FIX7 (T65+): замок target-прогона открывается БЕЗ усечения (exec 9>>:
# hard link на существующий файл больше не обнуляется), ИМЯ замка-entry
# проверяется в разрешённом родителе (исходящий symlink source/config.json),
# владелец / охраняется в __ti_guard_inside, отказ resolver в activate --
# явный exit 2 до mktemp; T57 дополнительно снимает живой XDG-дом, T64 гоняет
# A/B независимо, T67 мерит отказ resolver реальным главным скриптом (рука
# activate -- по последовательности preflight -> замок -> activate, см. зуб).
#
# Форма измерения -- ИЗВЛЕЧЕНИЕ подлинного текста конвейера по якорям (образец:
# tools/backup-divergence-probe.sh): зуб исполняет НАСТОЯЩИЕ строки ворот, а не
# их пересказ. Пропажа якоря -- отказ прибора (код 2), а не тишина.
#
# Коды (подмножество таблицы кита):
#   0  все зубы зелёные
#   1  красный: хоть один зуб провалился
#   2  прибор не может мерить: нет --scope, предмета (скрипта кита) или якоря
#      извлечения; отсутствие helper-изоляции здесь -- ПРИБОРНЫЙ красный ярлыка
#      «helper отсутствует», НЕ поведенческий: поведенческий красный несут зубы
#      проводки ниже по реально стрелявшим писателям
#   4  прогнанных зубов не сходится с пином EXPECTED_TEETH
#   6  сломано окружение: нет python3/sha256sum/timeout; отказ mktemp -- rc 2
#
# CONSTRAINT: только Linux (sha256sum, GNU cp); на Mac не запускать.
# CONSTRAINT: rm -rf только при непустом WORKDIR.
# CONSTRAINT: пин числа зубов -- EXPECTED_TEETH; расхождение -- код 4.
set -u

SCOPE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope) shift
             [[ $# -gt 0 ]] || { echo "нет --scope target-isolation — тесты не стартуют" >&2; exit 2; }
             SCOPE="$1"; shift ;;
    *)       echo "неизвестный ключ: $1 (нужен --scope target-isolation)" >&2; exit 2 ;;
  esac
done
[[ "$SCOPE" == "target-isolation" ]] \
  || { echo "нет --scope target-isolation — тесты не стартуют" >&2; exit 2; }

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${SCRIPT:-$KIT/claude-patch-all.sh}"
HELPER="${HELPER:-$KIT/tools/target-isolation.sh}"
FSMETA="${FSMETA:-$KIT/tools/fs-meta.sh}"

command -v python3 >/dev/null || { echo "нет python3 — извлекать нечем" >&2; exit 6; }
command -v sha256sum >/dev/null || { echo "нет sha256sum — снимок фикстур не собрать" >&2; exit 6; }
command -v timeout >/dev/null || { echo "нет timeout — прогон реального скрипта не ограничить" >&2; exit 6; }
# CONSTRAINT: неполный кит -- отказ прибора, а не красный предмет
for __ti_kit_file in "$SCRIPT" "$HELPER" "$FSMETA" "$KIT/tweakcc-patch.js"; do
  [[ -f "$__ti_kit_file" ]] || { echo "ОТКАЗ ПРИБОРА: кит неполон: $__ti_kit_file" >&2; exit 2; }
done

EXPECTED_TEETH=106
PASSED=0; FAILED=0; RAN=0; WORKDIR=''
# CONSTRAINT: штатный конец объявляет себя сам (__DONE=1); голый EXIT-трап съедает
# обрыв с кодом 0 (правило часового, claude-patch-all.sh).
__DONE=0
cleanup() {
  if [[ -n "${WORKDIR:-}" ]]; then rm -rf "${WORKDIR}"; fi
}
__ti_teeth_guard() {
  local __rc=$?
  trap - EXIT
  cleanup
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "ОТКАЗ: target-isolation-teeth оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 2
  fi
  exit "$__rc"
}
trap '__ti_teeth_guard' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/ti-teeth.XXXXXXXX") || {
  printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; __DONE=1; exit 2; }
[ -n "$WORKDIR" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; __DONE=1; exit 2; }

ok()  { PASSED=$((PASSED + 1)); printf '  ok     %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf '  ПРОВАЛ %s\n' "$1"; }

# --- извлечение подлинного текста конвейера по якорям --------------------------
# Старт-якорь обязан встретиться РОВНО один раз; конец -- первый после старта.
extract() {  # $1 скрипт, $2 старт-regex, $3 конец-regex, $4 включать конец (0/1)
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import re, sys
script, start, end, inc = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    lines = open(script, encoding='utf-8').read().splitlines(True)
except OSError as exc:
    print('ОТКАЗ извлечения: не читается %s (%s)' % (script, exc), file=sys.stderr)
    sys.exit(2)
s = [i for i, l in enumerate(lines) if re.match(start, l)]
if len(s) != 1:
    print('ОТКАЗ извлечения: старт-якорь %r найден %d раз (ждан 1)' % (start, len(s)), file=sys.stderr)
    sys.exit(2)
e = [i for i, l in enumerate(lines) if re.match(end, l) and i > s[0]]
if not e:
    print('ОТКАЗ извлечения: конец-якорь %r после старта не найден' % end, file=sys.stderr)
    sys.exit(2)
j = e[0] if inc == 1 else e[0] - 1
sys.stdout.write(''.join(lines[s[0]:j + 1]))
PY
}

# Однопеременная мутация КОПИИ конвейера: ровно ОДНА строка после маркера ворот
# заменяется; форма старой строки проверяется до правки, иначе мутация не
# закладывается (приборный отказ, не зелёный прогон).
mutate_one() {  # $1 src, $2 dst, $3 маркер-regex, $4 старая-строка-regex, $5 новая строка
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import re, sys
src, dst, marker, old, new = sys.argv[1:6]
# CONSTRAINT: строка мутации = физическая строка по LF; байты вне целевой строки не меняются
text = open(src, encoding='utf-8', newline='').read()
lines = re.split(r'(?<=\n)', text)
if lines and lines[-1] == '':
    lines.pop()
m = [i for i, l in enumerate(lines) if re.match(marker, l)]
if len(m) != 1:
    print('ОТКАЗ мутации: маркер %r найден %d раз -- ворот на дереве нет' % (marker, len(m)), file=sys.stderr)
    sys.exit(2)
i = m[0] + 1
# за маркером могут идти строки его же комментария: воротная строка -- первая
# НЕ пустая и НЕ комментарий
while i < len(lines) and (lines[i].strip() == '' or lines[i].lstrip().startswith('#')):
    i += 1
if i >= len(lines) or not re.match(old, lines[i]):
    print('ОТКАЗ мутации: строка после маркера не совпала с %r (нашли %r)' % (old, lines[i:i+1] and lines[i]), file=sys.stderr)
    sys.exit(2)
if re.match(old, ''):
    print('ОТКАЗ ПРИБОРА: игла пустая: %s' % src, file=sys.stderr)
    sys.exit(2)
matched = {j for j, line in enumerate(lines) if re.match(old, line)}
identical = {j for j, line in enumerate(lines) if line == lines[i]}
if matched != identical:
    print('ОТКАЗ ПРИБОРА: игла неоднозначна: %s old_n=%d ident_n=%d' % (src, len(matched), len(identical)), file=sys.stderr)
    sys.exit(2)
lines[i] = new + '\n'
open(dst, 'w', encoding='utf-8', newline='').write(''.join(lines))
PY
}

# --- снимок каталога: путь + st_mtime_ns + sha256; ссылки пишутся как
# LINK -> цель, каталоги -- DIR + st_mtime_ns: touch-only записи (байты не
# меняются) и перестановки времени каталогов тоже ловятся; корень «.» входит в
# снимок -- сдвиг mtime самого каталога при неизменных детях виден
# CONSTRAINT: снимок полный или rc2 -- отказ cd, find, sort, readlink/stat/
# sha256sum на элементе и записи строки не гасится: пустой/частичный снимок
# сравнился бы с таким же пустым и дал зелень
snap() {
  ( set -o pipefail
    cd "$1" || exit 2
    LC_ALL=C find . \( -type f -o -type l -o -type d \) -print0 \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' p; do
          if [[ -L "$p" ]]; then
            t="$(readlink -- "$p")" || exit 2
            printf '%s LINK %s\n' "$p" "$t" || exit 2
          elif [[ -d "$p" ]]; then
            m="$(stat -c '%.9Y' -- "$p")" || exit 2
            [[ -n "$m" ]] || exit 2
            printf '%s DIR %s\n' "$p" "$m" || exit 2
          else
            m="$(stat -c '%.9Y' -- "$p")" || exit 2
            h="$(sha256sum < "$p")" || exit 2
            h="${h%% *}"
            [[ -n "$m" && -n "$h" ]] || exit 2
            printf '%s %s %s\n' "$p" "$m" "$h" || exit 2
          fi
        done ) || return 2
}

# CONSTRAINT: при отказе файла снимка НЕТ (прежний удаляется до записи) --
# частичный файл не доживает до сравнения; вызывающий зуб обязан проверить rc
snap_to() {  # $1 каталог, $2 файл снимка; 0 -- полный снимок записан, 2 -- отказ
  rm -f -- "$2" || return 2
  snap "$1" > "$2" || { rm -f -- "$2"; return 2; }
}

# --- inode-снимок: путь + inode, включая корень «.»; тот же rc-контракт
isnap() {
  ( set -o pipefail
    cd "$1" || exit 2
    LC_ALL=C find . -printf '%p %i\n' | LC_ALL=C sort ) || return 2
}
isnap_to() {  # $1 каталог, $2 файл снимка; 0 -- полный снимок записан, 2 -- отказ
  rm -f -- "$2" || return 2
  isnap "$1" > "$2" || { rm -f -- "$2"; return 2; }
}

# CONSTRAINT: метка отказа прибора несёт имя зуба-вызывающего (FUNCNAME[1]) --
# звать ТОЛЬКО из тела зуба tNN
instr_bad() { local t="${FUNCNAME[1]:-t00}"; bad "T${t#t} ПРИБОР НЕДОСТУПЕН: $1"; }
changed() {  # $1 $2 -- снимки; 0 = различаются, 1 = равны; отказ diff -- rc2
  # CONSTRAINT: rc2 обязан доходить до вызывающего зуба -- маскирование
  # сравнением давало бы зелень на нечитаемом снимке
  local rc=0
  diff "$1" "$2" >/dev/null || rc=$?
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

# --- синтетическая фикстура прогона --------------------------------------------
# НИ ОДНОГО настоящего байта конфига: все файлы -- синтетика. Один прогон --
# одна фикстура (зубы не делят состояние).
FAKE_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
# CONSTRAINT: каждая запись фикстуры проверена -- частичная фикстура даёт rc2
# ДО любого зуба (отказ прибора), а не предметный вердикт на неполном входе
mk_put() {  # $1 файл, далее -- аргументы printf; отказ записи -- rc2
  local dst="$1"; shift
  printf "$@" > "$dst" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: фикстура не записана: %s\n' "$dst" >&2; return 2; }
}
mk_run() {  # команда фикстуры (mkdir/ln/touch/chmod); отказ -- rc2
  "$@" || { printf 'ПРИБОР НЕДОСТУПЕН: шаг фикстуры отказал: %s\n' "$*" >&2; return 2; }
}
mk_env() {  # -> E (каталог фикстуры), переменные-пути; отказ создания/сборки -- rc2
  E=$(mktemp -d "$WORKDIR/env.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создана фикстура\n' >&2; return 2; }
  mk_run mkdir -p "$E/home/.tweakcc/system-prompts" "$E/home/.tweakcc/prompt-data-cache" \
           "$E/cache/catalyst-tweakcc/$FAKE_SHA/dist/lib" \
           "$E/judge-home" "$E/kit-mock/scripts" "$E/tmp" "$E/img" "$E/obs" "$E/lock" "$E/prompt-floor-target" \
    || return 2
  # дом ОПЕРАТОРА: синтетические patch options, бэкапы, объявления
  mk_put "$E/home/.tweakcc/config.json" \
    '{"ccVersion":"2.1.283","patchOptions":{"synthetic":true},"settings":{"theme":"synthetic"}}\n' || return 2
  mk_put "$E/home/.tweakcc/config.json.backup.OLD" \
    '{"ccVersion":"2.1.283","patchOptions":{"stale":true}}\n' || return 2
  mk_put "$E/home/.tweakcc/native-binary.backup" 'SYNTHETIC-NATIVE-BACKUP-v1\x00' || return 2
  mk_put "$E/home/.tweakcc/cli.js.backup" 'SYNTHETIC-CLIJS-BACKUP-v1' || return 2
  mk_put "$E/home/.tweakcc/catalyst-expected-off.txt" \
    '# синтетическое объявление выключенных\npatch-one-synthetic\n' || return 2
  # вход-ССЫЛКА: копия обязана разыменовать её в обычный файл
  mk_put "$E/prompt-floor-target/floor.txt" 'synthetic-prompt-floor-via-link\n' || return 2
  mk_run ln -s ../../prompt-floor-target/floor.txt "$E/home/.tweakcc/catalyst-prompt-floor.txt" || return 2
  mk_put "$E/home/.tweakcc/catalyst-prompt-conflicts.txt" '0\n' || return 2
  mk_put "$E/home/.tweakcc/systemPromptOriginalHashes.json" '{}\n' || return 2
  mk_put "$E/home/.tweakcc/systemPromptAppliedHashes.json" '{}\n' || return 2
  mk_put "$E/home/.tweakcc/system-prompts/a.diff" 'overlay-a\n' || return 2
  mk_put "$E/home/.tweakcc/system-prompts/b.diff" 'overlay-b\n' || return 2
  mk_put "$E/home/.tweakcc/prompt-data-cache/snap.json" '{"snap":"synthetic"}\n' || return 2
  # ВЫХОДЫ форка -- не входы: их копировать запрещено
  mk_put "$E/home/.tweakcc/native-claudejs-orig.js" 'native-claudejs OUTPUT\n' || return 2
  mk_put "$E/home/.tweakcc/native-claudejs-patched.js" 'native-claudejs OUTPUT\n' || return 2
  # ЧЕТЫРЕ синтетических бэкапа модельного конфига
  local i
  for i in 20260901-000001 20260902-000002 20260903-000003 20260904-000004; do
    mk_put "$E/home/.claude.json.backup.$i" '{"synthetic-backup":"%s"}\n' "$i" || return 2
  done
  # общий кэш: готовый пин + три устаревших записи с упорядоченными метками
  mk_put "$E/cache/catalyst-tweakcc/$FAKE_SHA/dist/index.mjs" '#!/usr/bin/env node\n// synthetic pinned unpacker\n' || return 2
  mk_put "$E/cache/catalyst-tweakcc/$FAKE_SHA/dist/lib/x.mjs" 'synthetic-lib\n' || return 2
  mk_put "$E/cache/catalyst-tweakcc/$FAKE_SHA/package.json" '{"name":"synthetic-unpacker"}\n' || return 2
  local n=1
  for n in 1 2 3; do
    local sha
    sha="$(printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb%d' "$n")" \
      || { printf 'ПРИБОР НЕДОСТУПЕН: не собран synthetic sha фикстуры\n' >&2; return 2; }
    mk_run mkdir -p "$E/cache/catalyst-tweakcc/$sha/dist" || return 2
    mk_put "$E/cache/catalyst-tweakcc/$sha/dist/index.mjs" 'stale-unpacker-%s\n' "$n" || return 2
    mk_run touch -t "20200${n}010100.00" "$E/cache/catalyst-tweakcc/$sha/dist/index.mjs" || return 2
    if [[ "$n" == 1 ]]; then TI_STALE1="$sha"; fi
  done
  # синтетический дом судьи и наблюдатели
  cat > "$E/kit-mock/scripts/probes-sync.sh" <<'MOCK' || { printf 'ПРИБОР НЕДОСТУПЕН: фикстура не записана: probes-sync.sh\n' >&2; return 2; }
#!/usr/bin/env bash
# СИНТЕТИЧЕСКИЙ наблюдатель раскатки: пишет вызовы, коды управляются diff_rc.
printf '%s\n' "$*" >> "$MOCK_STATE_DIR/probes-sync.calls" || exit 3
# строка вызова только что дописана: счёт >= 1, rc grep -- 0; иной rc -- отказ мока
n=$(grep -c . "$MOCK_STATE_DIR/probes-sync.calls") || exit 3
case " $* " in
  *" --diff "*)
    if [[ -f "$MOCK_STATE_DIR/diff_rc" && "$n" -le 2 ]]; then
      d=$(cat "$MOCK_STATE_DIR/diff_rc") || exit 3
      exit "$d"
    fi
    exit 0 ;;
  *" --to-home "*)
    mkdir -p "$JUDGE_HOME/tools" || exit 3
    printf 'canon-bytes-synthetic\n' > "$JUDGE_HOME/tools/rolled.py" || exit 3
    exit 0 ;;
  *) exit 0 ;;
esac
MOCK
  cat > "$E/kit-mock/set-model-costs.py" <<'MOCKPY' || { printf 'ПРИБОР НЕДОСТУПЕН: фикстура не записана: set-model-costs.py\n' >&2; return 2; }
import os, sys
open(os.path.join(os.environ["MOCK_STATE_DIR"], "sync.called"), "w").write("called\n")
print("Backed up -> %s" % os.path.join(os.environ["HOME"], ".claude.json.backup.synthetic"))
sys.exit(0)
MOCKPY
  # цель-заглушка для зуба ворот --target --configure: не исполнимый мусор
  mk_put "$E/img/fake-target" 'not-an-image\x00' || return 2
  mk_run chmod 644 "$E/img/fake-target" || return 2
}

# --- сборка обёртки: преамбула фикстуры + подлинный извлечённый текст ----------
# CONSTRAINT: строки группы-писателя связаны && -- статус группы несёт КАЖДУЮ
# запись; в форме { a; b; } > f отказ ранней записи гас под статусом последней
# (или под успешным if без ветки)
wrap_begin() {  # $1 обёртка, $2 TARGET ('' или путь), $3 доп. env-присваивания
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' &&
    printf 'E=%q\n' "$E" &&
    # HOME/TMPDIR ЭКСПОРТИРОВАНЫ: их читают дети подлинного текста (mktemp,
    # python-наблюдатель синка), а не только сама оболочка обёртки.
    printf 'export HOME=%q\n' "$E/home" &&
    printf 'TARGET=%q\n' "$2" &&
    printf 'export MOCK_STATE_DIR=%q\n' "$E/obs" &&
    printf 'export JUDGE_HOME=%q\n' "$E/judge-home" &&
    printf 'export TMPDIR=%q\n' "$E/tmp" &&
    { [[ -z "${3:-}" ]] || printf '%s\n' "$3"; }
  } > "$1" || { printf 'ПРИБОР НЕДОСТУПЕН: обёртка не записана: %s\n' "$1" >&2; return 2; }
}
# CONSTRAINT: запись фикстуры/обёртки ОБЯЗАНА проверять rc -- отказ записи
# даёт rc2 (отказ прибора), а не зуб на частичной фикстуре
mk_append() {  # $1 файл, $2 строка (без \n); отказ дозаписи -- rc2
  printf '%s\n' "$2" >> "$1" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: дозапись фикстуры не выполнена: %s\n' "$1" >&2; return 2; }
}
# CONSTRAINT: правка фикстуры проверяется по РЕЗУЛЬТАТУ: sed -i без совпадения
# даёт rc0 и оставляет фикстуру прежней -- зуб мерил бы не заказанный вход
mk_sed() {  # $1 файл, $2 выражение sed, $3 строка, которая ОБЯЗАНА появиться целиком
  sed -i "$2" "$1" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: правка фикстуры отказала: %s\n' "$1" >&2; return 2; }
  grep -qxF -- "$3" "$1" \
    || { printf 'ПРИБОР НЕДОСТУПЕН: правка фикстуры не легла (%s): %s\n' "$3" "$1" >&2; return 2; }
}
wrap_export() {  # $1 обёртка, $2 имя, $3 значение, $4 export-якорь вставки (необязательный).
  python3 - "$1" "$2" "$3" "${4:-}" <<'PYEXPORT'
import pathlib, shlex, sys
p = pathlib.Path(sys.argv[1]); name, value, anchor = sys.argv[2:]
lines = p.read_text().splitlines(True)
indices = [i for i, line in enumerate(lines) if line.startswith('export ' + name + '=')]
assignment = 'export ' + name + '=' + shlex.quote(value) + '\n'
if len(indices) == 0 and anchor:
    anchors = [i for i, line in enumerate(lines) if line.startswith('export ' + anchor + '=')]
    if len(anchors) != 1:
        print('ПРИБОР НЕДОСТУПЕН: export-якорь %s найден %d раз' % (anchor, len(anchors)), file=sys.stderr)
        sys.exit(2)
    lines.insert(anchors[0] + 1, assignment)
elif len(indices) == 1:
    lines[indices[0]] = assignment
else:
    print('ПРИБОР НЕДОСТУПЕН: export %s найден %d раз' % (name, len(indices)), file=sys.stderr)
    sys.exit(2)
p.write_text(''.join(lines))
PYEXPORT
}

wrap_run() {  # $1 обёртка -> WR_RC, WR_OUT
  WR_RC=0
  # CONSTRAINT: обёртка обязана нести СВОЮ среду, а не наследовать ручки
  # внешнего прогона: CLAUDE_PATCH_SKIP_KIT_BENCH=1 внешнего кита менял вердикт
  # T54 (normal), а наследованный CLAUDE_PATCH_LOCK открывал внешний замок
  WR_OUT=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_LOCAL -u TWEAKCC_CONFIG_DIR \
             -u CATALYST_TWEAKCC_CACHE -u XDG_CONFIG_HOME \
             -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
             -u CLAUDE_PATCH_SKIP_KIT_BENCH -u CLAUDE_PATCH_LOCK \
             bash "$1" 2>&1) || WR_RC=$?
}

# Сценарий активации+лестницы: подлинный кусок [умолчание кэша .. вызов
# __tw_no_prompts_wrap] + подлинная лестница дома + имитация писателя форка
# (startup.ts:122-143 запиненного форка: смена версии -- unlink бэкапа и новый
# бэкап; saveConfig перезаписывает config.json; слой промтов пишет в system-prompts).
# $5 sim: 1 -- имитация писателя (по умолчанию), 0 -- копия остаётся нетронутой
# (зуб точности копии меряет байты ДО любой записи).
build_activation_wrap() {  # $1 обёртка, $2 TARGET, $3 TWEAKCC_LOCAL ('' или путь), $4 скрипт-источник, $5 sim
  local sim="${5:-1}"
  wrap_begin "$1" "$2" "" || return 2
  {
    printf 'CATALYST_TWEAKCC_REPO=%q\n' 'synthetic/repo' &&
    printf 'CATALYST_TWEAKCC_SHA=%q\n' "$FAKE_SHA" &&
    printf 'CATALYST_TWEAKCC_CACHE=%q\n' "$E/cache/catalyst-tweakcc" &&
    { [[ -z "$3" ]] || printf 'export TWEAKCC_LOCAL=%q\n' "$3"; } &&
    printf 'source %q\n' "$FSMETA" &&
    { [[ ! -f "$HELPER" ]] || printf 'source %q\n' "$HELPER"; }
  } >> "$1" || { printf 'ПРИБОР НЕДОСТУПЕН: обёртка не дописана: %s\n' "$1" >&2; return 2; }
  # подлинный prune_tweakcc_cache: его вызывает извлечённый ниже ensure_tweakcc
  extract "$4" '^prune_tweakcc_cache\(\) \{' '^\}$' 1 >> "$1" || return 2
  extract "$4" '^CATALYST_TWEAKCC_CACHE=' '^__tw_no_prompts_wrap$' 1 >> "$1" || return 2
  extract "$4" '^TWEAKCC_HOME=' '^TWEAKCC_EXPECTED_OFF=' 1 >> "$1" || return 2
  if [[ "$sim" == "1" ]]; then
  cat >> "$1" <<'SIM' || { printf 'ПРИБОР НЕДОСТУПЕН: имитация писателя не дописана: %s\n' "$1" >&2; return 2; }
# --- имитация писателя форка в РАЗРЕШЕННЫЙ ему дом ($TWEAKCC_HOME) -----------
mkdir -p "$TWEAKCC_HOME/system-prompts"
rm -f "$TWEAKCC_BACKUP"
printf 'simulated-fork-new-backup' > "$TWEAKCC_BACKUP"
printf '{"ccVersion":"9.9.9-sim"}\n' > "$TWEAKCC_CFG"
printf 'sim-overlay\n' > "$TWEAKCC_HOME/system-prompts/sim.diff"
SIM
  fi
  cat >> "$1" <<'DUMP' || { printf 'ПРИБОР НЕДОСТУПЕН: хвост обёртки не дописан: %s\n' "$1" >&2; return 2; }
printf 'TI_ROOT=%s\nTI_CFG=%s\nTI_CACHE=%s\nTI_HOME=%s\n' \
  "${TARGET_ISOLATION_ROOT:-}" "${TWEAKCC_CONFIG_DIR:-}" "${CATALYST_TWEAKCC_CACHE:-}" "$TWEAKCC_HOME"
echo WIRE_DONE
DUMP
}

# Сценарий стадии раскатки: подлинный блок [раскатка .. до 0d].
build_probes_wrap() {  # $1 обёртка, $2 TARGET, $3 скрипт-источник
  wrap_begin "$1" "$2" "" || return 2
  extract "$3" '^# --- раскатка судейских инструментов' '^# --- 0d\.' 0 >> "$1" || return 2
  mk_append "$1" 'echo WIRE_DONE' || return 2
}

# [559-fix5] моки трёх стендов кита: пишут имя в $MOCK_STATE_DIR/bench.calls
# при каждом вызове (прогон и --self-check); самопроверок стендов здесь нет --
# предмет T54 в исполнении ПОДЛИННОГО блока, а не в их вердиктах.
# CONSTRAINT: отказ записи мока -- rc2 вызывающему зубу; отказ записи факта
# вызова внутри мока -- его ненулевой код: пустой bench.calls иначе читался бы
# как «стенд не звали»
mk_bench_mocks() {  # $1 каталог обёртки (моки лягут в $1/tools); отказ -- rc2
  mk_run mkdir -p "$1/tools" || return 2
  cat > "$1/tools/judge-tools-bench.py" <<'MOCKB1' || { printf 'ПРИБОР НЕДОСТУПЕН: мок не записан: judge-tools-bench.py\n' >&2; return 2; }
import os
open(os.path.join(os.environ["MOCK_STATE_DIR"], "bench.calls"), "a").write("judge-tools-bench\n")
raise SystemExit(0)
MOCKB1
  cat > "$1/tools/costs-bench.py" <<'MOCKB2' || { printf 'ПРИБОР НЕДОСТУПЕН: мок не записан: costs-bench.py\n' >&2; return 2; }
import os
open(os.path.join(os.environ["MOCK_STATE_DIR"], "bench.calls"), "a").write("costs-bench\n")
raise SystemExit(0)
MOCKB2
  cat > "$1/tools/probes-sync-bench.sh" <<'MOCKB3' || { printf 'ПРИБОР НЕДОСТУПЕН: мок не записан: probes-sync-bench.sh\n' >&2; return 2; }
#!/usr/bin/env bash
# СИНТЕТИЧЕСКИЙ стенд проб: только факт вызова, без своего вердикта
printf 'probes-sync-bench\n' >> "$MOCK_STATE_DIR/bench.calls" || exit 3
exit 0
MOCKB3
  mk_run chmod +x "$1/tools/probes-sync-bench.sh" || return 2
}

# [559-fix5] сценарий стендов+раскатки ЦЕЛИКОМ: подлинный блок
# [KIT_BENCH_NAMES .. до 0d) -- блок стендов (4599-4706) и блок раскатки
# (4708-4799) исполняются вместе, стенды -- через изолированные моки в
# $(dirname "$0")/tools обёртки.
build_bench_rollout_wrap() {  # $1 обёртка, $2 TARGET, $3 скрипт-источник
  wrap_begin "$1" "$2" "" || return 2
  extract "$3" '^KIT_BENCH_NAMES=' '^# --- 0d\.' 0 >> "$1" || return 2
  mk_append "$1" 'echo WIRE_DONE' || return 2
}

# Сценарий шага 7: подлинные __envon и prune_config_backups + подлинный блок.
build_model_wrap() {  # $1 обёртка, $2 TARGET, $3 скрипт-источник
  local assignment
  printf -v assignment 'COSTS_SYNC=%q' "$E/kit-mock/set-model-costs.py"
  wrap_begin "$1" "$2" "$assignment" || return 2
  extract "$3" '^__envon\(\) \{' '^\}$' 1 >> "$1" || return 2
  extract "$3" '^prune_config_backups\(\) \{' '^\}$' 1 >> "$1" || return 2
  extract "$3" '^# --- 7\. the model data the patches read' '^echo "Done\. Re-run' 0 >> "$1" || return 2
  mk_append "$1" 'echo WIRE_DONE' || return 2
}

# Сценарий холодной загрузки ensure_tweakcc (#559-fix4 п.5): подлинные
# prune_tweakcc_cache и ensure_tweakcc после (возможной) активации; curl/tar/npx
# -- СИНТЕТИЧЕСКИЕ моки в PATH обёртки, сеть не трогается. Мок-npx моделирует
# замеренных писателей холодной сборки: redirected-переменная есть -- маркер в
# неё, нет -- в живой HOME-фолбэк (накопленный замер: 11 726 файлов ~514 МБ --
# RED-улика волны; здесь только адресная фикстура, не полный install).
# CONSTRAINT: отказ записи мока -- rc2 вызывающему зубу: недописанный мок в PATH
# уступает место настоящей утилите (curl -- сеть, npx -- живые писатели)
mk_cold_mocks() {  # $1 каталог моков; отказ -- rc2
  mk_run mkdir -p "$1" || return 2
  cat > "$1/curl" <<'MOCKCURL' || { printf 'ПРИБОР НЕДОСТУПЕН: мок не записан: curl\n' >&2; return 2; }
#!/usr/bin/env bash
# СИНТЕТИЧЕСКАЯ загрузка: тело «tarball» пишется по -o, сеть не трогается
out=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || { echo "mock curl: нет -o" >&2; exit 1; }
printf 'synthetic-cold-tarball\n' > "$out" || exit 3
MOCKCURL
  cat > "$1/tar" <<'MOCKTAR' || { printf 'ПРИБОР НЕДОСТУПЕН: мок не записан: tar\n' >&2; return 2; }
#!/usr/bin/env bash
# СИНТЕТИЧЕСКАЯ распаковка: распаковывать нечего, dist пишет мок-npx
exit 0
MOCKTAR
  cat > "$1/npx" <<'MOCKNPX' || { printf 'ПРИБОР НЕДОСТУПЕН: мок не записан: npx\n' >&2; return 2; }
#!/usr/bin/env bash
# СИНТЕТИЧЕСКИЙ npm/pnpm-писатель: redirected-переменные -> маркер в них,
# отсутствующие -> живые HOME-фолбэки; «build» создаёт dist/index.mjs.
# [559-fix6] CONSTRAINT: маркер ЗАПУСКА пишется первым делом в независимый
# известный заранее путь ($MOCK_STATE_DIR, экспортирован обёрткой) --
# наблюдение запуска install/build не зависит от TI_ROOT, который печатается
# только после ensure_tweakcc (T62)
printf 'invoked\n' >> "$MOCK_STATE_DIR/mock-npx.invoked" || exit 3
mark() {
  local v="${!1:-}"
  if [[ -n "$v" ]]; then
    mkdir -p "$v" && printf 'side-write\n' > "$v/ti-marker" || exit 3
  else
    mkdir -p "$2" && printf 'side-write\n' > "$2/ti-marker" || exit 3
  fi
}
mark npm_config_cache "$HOME/.npm/_cacache"
mark XDG_DATA_HOME "$HOME/.local/share/pnpm"
mark XDG_CACHE_HOME "$HOME/.cache/pnpm"
mark XDG_STATE_HOME "$HOME/.local/state/pnpm"
for a in "$@"; do
  if [[ "$a" == "build" ]]; then
    mkdir -p dist && printf '#!/usr/bin/env node\n// synthetic cold build\n' > dist/index.mjs || exit 3
  fi
done
exit 0
MOCKNPX
  mk_run chmod +x "$1/curl" "$1/tar" "$1/npx" || return 2
}

build_cold_wrap() {  # $1 обёртка, $2 TARGET ('' или путь), $3 скрипт-источник
  wrap_begin "$1" "$2" "" || return 2
  {
    printf 'CATALYST_TWEAKCC_REPO=%q\n' 'synthetic/repo' &&
    printf 'CATALYST_TWEAKCC_SHA=%q\n' "$FAKE_SHA" &&
    printf 'CATALYST_TWEAKCC_CACHE=%q\n' "$E/cache/catalyst-tweakcc" &&
    printf 'source %q\n' "$FSMETA" &&
    printf 'source %q\n' "$HELPER"
  } >> "$1" || { printf 'ПРИБОР НЕДОСТУПЕН: обёртка не дописана: %s\n' "$1" >&2; return 2; }
  # подлинный prune_tweakcc_cache: ensure_tweakcc зовёт его в update-ветке
  extract "$3" '^prune_tweakcc_cache\(\) \{' '^\}$' 1 >> "$1" || return 2
  extract "$3" '^ensure_tweakcc\(\) \{' '^\}$' 1 >> "$1" || return 2
  cat >> "$1" <<'DUMP' || { printf 'ПРИБОР НЕДОСТУПЕН: хвост обёртки не дописан: %s\n' "$1" >&2; return 2; }
if [[ -n "$TARGET" ]]; then target_isolation_activate; fi
ensure_tweakcc
printf 'TI_ROOT=%s\nTI_CACHE=%s\nTI_CFG=%s\n' \
  "${TARGET_ISOLATION_ROOT:-}" "${CATALYST_TWEAKCC_CACHE:-}" "${TWEAKCC_CONFIG_DIR:-}"
echo WIRE_DONE
DUMP
}

cold_run() {  # $1 обёртка -> WR_RC, WR_OUT (PATH с моками; writers-env вычищен)
  WR_RC=0
  WR_OUT=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_LOCAL -u TWEAKCC_CONFIG_DIR \
             -u CATALYST_TWEAKCC_CACHE -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
             -u XDG_CACHE_HOME -u XDG_STATE_HOME -u npm_config_cache \
             -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
             PATH="$E/mockbin:$PATH" bash "$1" 2>&1) || WR_RC=$?
}

count_backups() {  # -> stdout: число бэкапов; grep rc1 (нет совпадений) -- 0; отказ I/O -- rc2
  local listing n rc=0
  listing=$(ls -A "$1/home") || return 2
  n=$(printf '%s\n' "$listing" | grep -c '^\.claude\.json\.backup\.') || rc=$?
  case "$rc" in
    0) printf '%s\n' "$n" ;;
    1) printf '0\n' ;;
    *) return 2 ;;
  esac
}

# CONSTRAINT: одного статуса пайпа под pipefail мало: `sort` rc2 + `grep -c .` rc1
# сворачиваются в rc1 с stdout "0" и отказ прибора не отличим от валидного нуля
# (старая форма `sort -u | grep -c . || true` маскировала обе ступени); стадии
# проверяются раздельно, значением считаются только rc0+цифры или rc1+ровно "0"
count_uniq_lines() {  # $1 -- файл; число различных непустых строк в stdout; отказ любой ступени -- rc2
  local sorted out rc=0
  sorted=$(LC_ALL=C sort -u "$1") || return 2
  out="$(set -o pipefail; printf '%s\n' "$sorted" | grep -c .)" || rc=$?
  case "$rc" in
    0) [[ "$out" =~ ^[0-9]+$ ]] || return 2
       printf '%s\n' "$out" ;;
    1) [[ "$out" == "0" ]] || return 2
       printf '0\n' ;;
    *) return 2 ;;
  esac
}

# CONSTRAINT: значение счёта -- только rc0+цифры или rc1+ровно "0" (контракт
# count_uniq_lines); rc>1, rc1 с иным stdout и нечисловой stdout -- отказ прибора
count_matches() {  # $1 -- шаблон, $2 -- файл; число строк-совпадений в stdout; отказ -- rc2
  local out rc=0
  out=$(grep -c -- "$1" "$2") || rc=$?
  case "$rc" in
    0) [[ "$out" =~ ^[0-9]+$ ]] || return 2
       printf '%s\n' "$out" ;;
    1) [[ "$out" == "0" ]] || return 2
       printf '0\n' ;;
    *) return 2 ;;
  esac
}

# CONSTRAINT: пустое stdout при rc0 -- допустимое «значения нет» (не отказ);
# отказ любой ступени printf|sed|tail обязан доходить вызывающему зубу как rc2
ti_var() {  # -> stdout: последнее значение переменной из WR_OUT; отказ reader -- rc2
  local rc=0
  ( set -o pipefail; printf '%s\n' "$WR_OUT" | sed -n "s/^$1=//p" | tail -1 ) || rc=$?
  [[ $rc -eq 0 ]] || return 2
}

# ==============================================================================
# T01: bash -n предмета с честным rc (Linux-обязательство брифа)
t01() {
  RAN=$((RAN + 1))
  local rc=0
  bash -n "$SCRIPT" 2>"$WORKDIR/t01.err" || rc=$?
  if [[ $rc -ne 0 ]]; then bad "T01 bash -n конвейера rc=$rc"; return; fi
  if [[ -f "$HELPER" ]]; then
    bash -n "$HELPER" 2>>"$WORKDIR/t01.err" || { bad "T01 bash -n helper rc=$?"; return; }
  fi
  ok 'T01 bash -n предмета (конвейер, helper) -- rc=0'
}

# T02: helper присутствует и подключается (ПРИБОРНЫЙ зуб: его красный -- ярлык
# «helper отсутствует», НЕ поведенческий; поведенческий красный несут T10+)
t02() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then
    bad 'T02 helper отсутствует (приборная, не поведенческая: предметные зубы ниже краснеют сами)'
    return
  fi
  local out rc=0
  out=$(bash -c 'source "$1"; type target_isolation_activate >/dev/null && type target_isolation_cleanup >/dev/null' _ "$HELPER" 2>&1) || rc=$?
  if [[ $rc -ne 0 ]]; then bad "T02 helper не подключается: $out"; return; fi
  ok 'T02 helper присутствует и подключается'
}

# T03: активация на синтетическом HOME -- копия входов, разыменование ссылок,
# исключение выходов, точность patch options
t03() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T03 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T03 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  # sim=0: зуб мерит ТОЧНОСТЬ КОПИИ до любой записи в неё
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { bad "T03 извлечение отказало"; return; }
  snap_to "$E/home/.tweakcc" "$E/src.before" || { instr_bad 'снимок src.before источника не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T03 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local root cfg
  root=$(ti_var TI_ROOT) || { bad 'T03 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT'; return; }
  cfg=$(ti_var TI_CFG) || { bad 'T03 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CFG'; return; }
  if [[ -z "$root" || ! -d "$root" ]]; then bad 'T03 собственный temp не создан'; return; fi
  if [[ -z "$cfg" || "$cfg" != "$root"/* ]]; then bad 'T03 TWEAKCC_CONFIG_DIR не внутри собственного temp'; return; fi
  local perm
  perm=$(stat -c '%a' "$root") || { bad 'T03 ПРИБОР НЕДОСТУПЕН: отказ stat режима temp'; return; }
  if [[ "$perm" != "700" ]]; then bad "T03 режим temp = $perm, ждали 700"; return; fi
  # входы скопированы, байты patch options совпали
  local f bad3=""
  for f in config.json native-binary.backup cli.js.backup catalyst-expected-off.txt \
           catalyst-prompt-conflicts.txt systemPromptOriginalHashes.json \
           systemPromptAppliedHashes.json; do
    [[ -f "$cfg/$f" ]] || bad3="$bad3 нет:$f"
    cmp -s "$E/home/.tweakcc/$f" "$cfg/$f" || bad3="$bad3 байты:$f"
  done
  # ссылка разыменована: обычный файл с байтами цели ссылки, не LINK
  if [[ -L "$cfg/catalyst-prompt-floor.txt" ]] || ! cmp -s "$E/prompt-floor-target/floor.txt" "$cfg/catalyst-prompt-floor.txt"; then
    bad3="$bad3 floor-не-разыменована"
  fi
  [[ -f "$cfg/system-prompts/a.diff" && -f "$cfg/prompt-data-cache/snap.json" ]] || bad3="$bad3 каталоги-входов"
  # выходы и мусор источника не скопированы
  local x
  for x in native-claudejs-orig.js native-claudejs-patched.js config.json.backup.OLD; do
    [[ -e "$cfg/$x" ]] && bad3="$bad3 лишний:$x"
  done
  if [[ -n "$bad3" ]]; then bad "T03 копия дома расходится:$bad3"; return; fi
  # CONSTRAINT: снимок ПОСЛЕ -- проверенный файл, не process substitution:
  # отказ снимка в <(...) гас, и сравнение шло с пустотой
  snap_to "$E/home/.tweakcc" "$E/src.after" || { instr_bad 'снимок src.after источника не снят'; return; }
  local ch03=0
  changed "$E/src.before" "$E/src.after" || ch03=$?
  if [[ $ch03 -eq 2 ]]; then bad 'T03 ПРИБОР НЕДОСТУПЕН: отказ diff снимков источника'; return; fi
  if [[ $ch03 -eq 0 ]]; then bad 'T03 источник изменён активацией'; return; fi
  ok 'T03 активация: копия входов точна, ссылки разыменованы, выходы исключены, источник нетронут'
}

# T04: имитация записи/удаления ТОЛЬКО внутри собственного дома -- источник прежний
t04() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T04 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T04 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T04 извлечение отказало"; return; }
  snap_to "$E/home/.tweakcc" "$E/snap.A" || { instr_bad 'снимок snap.A живого дома не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T04 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  snap_to "$E/home/.tweakcc" "$E/snap.B" || { instr_bad 'снимок snap.B живого дома не снят'; return; }
  local ch04=0
  changed "$E/snap.A" "$E/snap.B" || ch04=$?
  if [[ $ch04 -eq 2 ]]; then bad 'T04 ПРИБОР НЕДОСТУПЕН: отказ diff снимков живого дома'; return; fi
  if [[ $ch04 -eq 0 ]]; then bad 'T04 живой дом изменён при записи только в собственный'; return; fi
  local cfg
  cfg=$(ti_var TI_CFG) || { bad 'T04 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CFG'; return; }
  if ! cmp -s "$E/home/.tweakcc/native-binary.backup" "$cfg/native-binary.backup"; then
    : # копия ПЕРЕзаписана имитацией -- так и задумано; бэкап источника сверен снимком выше
  fi
  if [[ ! -s "$cfg/native-binary.backup" ]] || ! grep -q 'simulated-fork-new-backup' "$cfg/native-binary.backup"; then
    bad 'T04 имитация не дошла до собственного дома (вакуумная зелень)'; return
  fi
  ok 'T04 запись/удаление внутри собственного дома; источник байт-в-байт прежний'
}

# T05: кэш изолирован: пин скопирован в собственный, общий не тронут
t05() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T05 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T05 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T05 извлечение отказало"; return; }
  snap_to "$E/cache" "$E/snap.cache.A" || { instr_bad 'снимок snap.cache.A общего кэша не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T05 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  snap_to "$E/cache" "$E/snap.cache.B" || { instr_bad 'снимок snap.cache.B общего кэша не снят'; return; }
  local ch05=0
  changed "$E/snap.cache.A" "$E/snap.cache.B" || ch05=$?
  if [[ $ch05 -eq 2 ]]; then bad 'T05 ПРИБОР НЕДОСТУПЕН: отказ diff снимков кэша'; return; fi
  if [[ $ch05 -eq 0 ]]; then bad 'T05 общий кэш изменён в target-прогоне'; return; fi
  local own
  own=$(ti_var TI_CACHE) || { bad 'T05 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CACHE'; return; }
  local root5
  root5=$(ti_var TI_ROOT) || { bad 'T05 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT'; return; }
  if [[ -z "$own" || "$own" != "$root5"/* ]]; then bad 'T05 CATALYST_TWEAKCC_CACHE не в собственном temp'; return; fi
  [[ -f "$own/$FAKE_SHA/dist/index.mjs" ]] || { bad 'T05 готовый пин не скопирован в собственный кэш'; return; }
  ok 'T05 кэш: пин скопирован в собственный temp, общий кэш не читан на запись'
}

# T06: исходного дома нет -- собственный пустой дом с отметкой происхождения
t06() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T06 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T06 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run rm -rf "$E/home/.tweakcc" || { instr_bad 'фикстура: живой дом не убран'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T06 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T06 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local cfg root6
  cfg=$(ti_var TI_CFG) || { bad 'T06 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CFG'; return; }
  root6=$(ti_var TI_ROOT) || { bad 'T06 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT'; return; }
  if [[ -z "$cfg" || "$cfg" != "$root6"/* ]]; then bad 'T06 собственный дом не назначен'; return; fi
  if [[ ! -s "$cfg/catalyst-home-origin.txt" ]]; then bad 'T06 отметка происхождения пуста/отсутствует -- дверь примет дефолты за дрейф'; return; fi
  if [[ -e "$E/home/.tweakcc" ]]; then bad 'T06 живой путь ~/.tweakcc создан прогоном'; return; fi
  ok 'T06 свежая машина: пустой собственный дом с отметкой catalyst-home-origin.txt'
}

# T07: повреждённый mktemp -- ранний отказ ДО CLI и без опасной уборки
t07() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T07 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T07 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/badbin" || { instr_bad 'фикстура: каталог badbin не создан'; return; }
  cat > "$E/badbin/mktemp" <<'BADMK' || { instr_bad 'фикстура: мок mktemp не записан'; return; }
#!/usr/bin/env bash
exit 1
BADMK
  mk_run chmod +x "$E/badbin/mktemp" || { instr_bad 'фикстура: мок mktemp не исполним'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T07 извлечение отказало"; return; }
  snap_to "$E/home/.tweakcc" "$E/snap.A" || { instr_bad 'снимок snap.A живого дома не снят'; return; }
  WR_RC=0
  WR_OUT=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_LOCAL -u TWEAKCC_CONFIG_DIR \
             PATH="$E/badbin:$PATH" bash "$w" 2>&1) || WR_RC=$?
  if [[ $WR_RC -eq 0 ]]; then bad 'T07 сломанный mktemp прошёл зелёно'; return; fi
  snap_to "$E/home/.tweakcc" "$E/snap.B" || { instr_bad 'снимок snap.B живого дома не снят'; return; }
  local ch07=0
  changed "$E/snap.A" "$E/snap.B" || ch07=$?
  if [[ $ch07 -eq 2 ]]; then bad 'T07 ПРИБОР НЕДОСТУПЕН: отказ diff снимков живого дома'; return; fi
  if [[ $ch07 -eq 0 ]]; then bad 'T07 отказ сломанного mktemp написал в живой дом'; return; fi
  ok 'T07 сломанный mktemp: ранний отказ, живой дом нетронут'
}

# T08: цикл symlink во входном каталоге -- отказ ДО первого запуска форка
t08() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T08 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T08 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run ln -s self-loop "$E/home/.tweakcc/system-prompts/self-loop" || { instr_bad 'фикстура: цикл symlink не заложен'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T08 извлечение отказало"; return; }
  snap_to "$E/home/.tweakcc" "$E/snap.A" || { instr_bad 'снимок snap.A живого дома не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -eq 0 ]]; then bad 'T08 цикл symlink прошёл зелёно'; return; fi
  snap_to "$E/home/.tweakcc" "$E/snap.B" || { instr_bad 'снимок snap.B живого дома не снят'; return; }
  local ch08=0
  changed "$E/snap.A" "$E/snap.B" || ch08=$?
  if [[ $ch08 -eq 2 ]]; then bad 'T08 ПРИБОР НЕДОСТУПЕН: отказ diff снимков живого дома'; return; fi
  if [[ $ch08 -eq 0 ]]; then bad 'T08 отказ по циклу написал в живой дом'; return; fi
  ok 'T08 цикл symlink: ранний отказ, живой дом нетронут'
}

# T09: собственный temp оказался бы ВНУТРИ источника -- отказ ДО любых записей
t09() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T09 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T09 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/home/.tweakcc/tmpdir-inside" || { instr_bad 'фикстура: tmpdir-inside не создан'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T09 извлечение отказало"; return; }
  # TMPDIR подменяется ВНУТРИ обёртки: её преамбула переписала бы внешний env
  wrap_export "$w" TMPDIR "$E/home/.tweakcc/tmpdir-inside" || { instr_bad 'фикстура: TMPDIR обёртки не подменён'; return; }
  snap_to "$E/home/.tweakcc" "$E/snap.A" || { instr_bad 'снимок snap.A живого дома не снят'; return; }
  WR_RC=0
  WR_OUT=$(bash "$w" 2>&1) || WR_RC=$?
  if [[ $WR_RC -eq 0 ]]; then bad 'T09 temp-внутри-источника прошёл зелёно'; return; fi
  snap_to "$E/home/.tweakcc" "$E/snap.B" || { instr_bad 'снимок snap.B живого дома не снят'; return; }
  local ch09=0
  changed "$E/snap.A" "$E/snap.B" || ch09=$?
  if [[ $ch09 -eq 2 ]]; then bad 'T09 ПРИБОР НЕДОСТУПЕН: отказ diff снимков источника'; return; fi
  if [[ $ch09 -eq 0 ]]; then bad 'T09 отказ по вложенности написал в источник'; return; fi
  ok 'T09 temp внутри источника: отказ до первой записи в источник'
}

# T10: проводка target -- kit-лестница видит КОПИЮ, живой дом переживает
# имитацию писателя форка (поведенческий зуб: на дереве без изоляции красный)
t10() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T10 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T10 извлечение отказало"; return; }
  snap_to "$E/home/.tweakcc" "$E/snap.A" || { instr_bad 'снимок snap.A живого дома не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T10 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local home10 root10
  home10=$(ti_var TI_HOME) || { bad 'T10 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_HOME'; return; }
  root10=$(ti_var TI_ROOT) || { bad 'T10 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT'; return; }
  if [[ "$home10" != "$root10"/* ]]; then
    bad "T10 лестница кита отдала форку не копию: TWEAKCC_HOME=$home10"
    return
  fi
  snap_to "$E/home/.tweakcc" "$E/snap.B" || { instr_bad 'снимок snap.B живого дома не снят'; return; }
  local ch10=0
  changed "$E/snap.A" "$E/snap.B" || ch10=$?
  if [[ $ch10 -eq 2 ]]; then bad 'T10 ПРИБОР НЕДОСТУПЕН: отказ diff снимков живого дома'; return; fi
  if [[ $ch10 -eq 0 ]]; then bad 'T10 ПИСАТЕЛЬ: живой дом tweakcc изменён target-прогоном'; return; fi
  ok 'T10 target: TWEAKCC_HOME -- собственный temp, живой дом не изменён'
}

# T11: проводка target -- общий кэш не чищен (prune не вызван), записи только
# в собственный кэш (поведенческий: старое дерево чистит общий кэш)
t11() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T11 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T11 извлечение отказало"; return; }
  snap_to "$E/cache" "$E/snap.cache.A" || { instr_bad 'снимок snap.cache.A общего кэша не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T11 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  snap_to "$E/cache" "$E/snap.cache.B" || { instr_bad 'снимок snap.cache.B общего кэша не снят'; return; }
  local ch11=0
  changed "$E/snap.cache.A" "$E/snap.cache.B" || ch11=$?
  if [[ $ch11 -eq 2 ]]; then bad 'T11 ПРИБОР НЕДОСТУПЕН: отказ diff снимков кэша'; return; fi
  if [[ $ch11 -eq 0 ]]; then bad 'T11 ПИСАТЕЛЬ: общий кэш распаковщика изменён target-прогоном (prune/Touch)'; return; fi
  ok 'T11 target: общий кэш не тронут (prune не вызван)'
}

# T12: проводка update (TARGET пуст) -- прежнее поведение: живой дом выбран
# лестницей, prune кэша исполняется (parent-контроль: update не регрессировал)
t12() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T12 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "" "" "$SCRIPT" || { bad "T12 извлечение отказало"; return; }
  snap_to "$E/cache" "$E/snap.cache.A" || { instr_bad 'снимок snap.cache.A общего кэша не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T12 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local home12 root12
  home12=$(ti_var TI_HOME) || { bad 'T12 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_HOME'; return; }
  root12=$(ti_var TI_ROOT) || { bad 'T12 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT'; return; }
  if [[ "$home12" != "$E/home/.tweakcc" ]]; then
    bad "T12 РЕГРЕССИЯ update: лестница выбрала $home12 вместо живого дома"
    return
  fi
  if [[ -n "$root12" ]]; then bad 'T12 РЕГРЕССИЯ update: изоляция включилась без --target'; return; fi
  snap_to "$E/cache" "$E/snap.cache.B" || { instr_bad 'снимок snap.cache.B общего кэша не снят'; return; }
  local ch12=0
  changed "$E/snap.cache.A" "$E/snap.cache.B" || ch12=$?
  if [[ $ch12 -eq 2 ]]; then bad 'T12 ПРИБОР НЕДОСТУПЕН: отказ diff снимков кэша'; return; fi
  if [[ $ch12 -eq 1 ]]; then bad 'T12 РЕГРЕССИЯ update: prune кэша не исполнился'; return; fi
  if [[ -e "$E/cache/catalyst-tweakcc/$TI_STALE1" ]]; then
    bad 'T12 РЕГРЕССИЯ update: самая старая запись кэша пережила prune'
    return
  fi
  ok 'T12 update: живой дом по лестнице, prune кэша исполняется как раньше'
}

# T13: раскатка в target не исполняется и не объявляет «раскатка полная»
# (поведенческий: старое дерево гоняет раскатку в target-прогоне)
t13() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T13 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/kit-mock/stage.sh"
  build_probes_wrap "$w" "$E/img/fake-target" "$SCRIPT" || { bad "T13 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T13 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ -e "$E/obs/probes-sync.calls" ]]; then
    bad 'T13 ПИСАТЕЛЬ: probes-sync вызван в target-прогоне'
    return
  fi
  if [[ "$WR_OUT" != *"РАСКАТКА ЖИВОГО ДОМА НЕ ИЗМЕРЯЛАСЬ В STAGING"* ]]; then
    bad 'T13 честное сообщение об неизмеренной раскатке не напечатано'
    return
  fi
  if [[ "$WR_OUT" == *"раскатка полная"* ]]; then
    bad 'T13 target объявил «раскатка полная», ничего не измеряя'
    return
  fi
  if [[ -e "$E/judge-home/tools/rolled.py" ]]; then bad 'T13 дом судьи изменён target-прогоном'; return; fi
  ok 'T13 target: раскатка не исполнялась, «полная» не объявлена, дом судьи цел'
}

# T14: раскатка в update-прогоне: автораскатка rc=7 катит канон в дом судьи
# и пересверяется (parent-контроль: update не регрессировал)
t14() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T14 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/obs/diff_rc" '7\n' || { instr_bad 'фикстура: diff_rc не записан'; return; }
  local w="$E/kit-mock/stage.sh"
  build_probes_wrap "$w" "" "$SCRIPT" || { bad "T14 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T14 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"дом выровнен по канону — раскатка полная"* ]]; then
    bad 'T14 автораскатка не дошла до пересверки'
    return
  fi
  local calls
  # CONSTRAINT: перечень создаёт только дописью вызванный наблюдатель (MOCK выше),
  # поэтому отсутствие файла -- предметный ноль вызовов, не отказ прибора; отказ
  # счёта существующего файла -- собственная ПРИБОР-метка
  if [[ ! -e "$E/obs/probes-sync.calls" ]]; then
    bad 'T14 вызовов probes-sync = 0 (наблюдатель не вызван), ждали 3 (diff, to-home, diff)'; return
  fi
  calls=$(count_matches . "$E/obs/probes-sync.calls") \
    || { bad 'T14 ПРИБОР НЕДОСТУПЕН: отказ grep перечня вызовов probes-sync'; return; }
  if [[ "$calls" != "3" ]]; then bad "T14 вызовов probes-sync = $calls, ждали 3 (diff, to-home, diff)"; return; fi
  if [[ ! -f "$E/judge-home/tools/rolled.py" ]]; then bad 'T14 дом судьи не получил раскатку в update-прогоне'; return; fi
  ok 'T14 update: автораскатка 7 -> to-home -> пересверка, дом судьи обновлён'
}

# T15: модельный sync в target не исполняется, бэкапы конфига не чистятся
# (поведенческий: старое дерево гоняет sync и prune в target-прогоне --
# build-staging-7.log:1055-1060)
t15() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T15 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  build_model_wrap "$w" "$E/img/fake-target" "$SCRIPT" || { bad "T15 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T15 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ -e "$E/obs/sync.called" ]]; then bad 'T15 ПИСАТЕЛЬ: set-model-costs вызван в target-прогоне'; return; fi
  if [[ "$WR_OUT" != *"Model data: SKIPPED — target isolation"* ]]; then
    bad 'T15 честная ветка «SKIPPED — target isolation» не напечатана'
    return
  fi
  local n15
  n15=$(count_backups "$E") || { bad 'T15 ПРИБОР НЕДОСТУПЕН: отказ подсчёта бэкапов'; return; }
  if [[ "$n15" != "4" ]]; then bad "T15 ПИСАТЕЛЬ: бэкапы конфига почищены в target (осталось $n15 из 4)"; return; fi
  ok 'T15 target: sync не вызван, «SKIPPED — target isolation», 4 бэкапа целы'
}

# T16: модельный sync в update-прогоне: исполняется, prune держит 3 (parent)
t16() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T16 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  build_model_wrap "$w" "" "$SCRIPT" || { bad "T16 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T16 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ ! -e "$E/obs/sync.called" ]]; then bad 'T16 РЕГРЕССИЯ update: sync не вызван'; return; fi
  if [[ "$WR_OUT" != *"Refreshing model prices"* ]]; then bad 'T16 заголовок синка не напечатан'; return; fi
  local n16
  n16=$(count_backups "$E") || { bad 'T16 ПРИБОР НЕДОСТУПЕН: отказ подсчёта бэкапов'; return; }
  if [[ "$n16" != "3" ]]; then bad "T16 РЕГРЕССИЯ update: prune оставил $n16 бэкапов, ждали 3"; return; fi
  if [[ -e "$E/home/.claude.json.backup.20260901-000001" ]]; then
    bad 'T16 РЕГРЕССИЯ update: самый старый бэкап не удалён'
    return
  fi
  ok 'T16 update: sync вызван, prune 4 -> 3 (старейший удалён)'
}

# T17: ручка CLAUDE_PATCH_SKIP_MODELS=1 вне target -- прежняя семантика
t17() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T17 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  build_model_wrap "$w" "" "$SCRIPT" || { bad "T17 извлечение отказало"; return; }
  WR_RC=0
  WR_OUT=$(env CLAUDE_PATCH_SKIP_MODELS=1 HOME="$E/home" TMPDIR="$E/tmp" \
             MOCK_STATE_DIR="$E/obs" JUDGE_HOME="$E/judge-home" bash "$w" 2>&1) || WR_RC=$?
  if [[ $WR_RC -ne 0 ]]; then bad "T17 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"SKIPPED — CLAUDE_PATCH_SKIP_MODELS=1"* ]]; then
    bad 'T17 объявленная ручка не сохранила прежнюю ветку'
    return
  fi
  if [[ -e "$E/obs/sync.called" ]]; then bad 'T17 ручка не выключила sync'; return; fi
  local n17
  n17=$(count_backups "$E") || { bad 'T17 ПРИБОР НЕДОСТУПЕН: отказ подсчёта бэкапов'; return; }
  if [[ "$n17" != "4" ]]; then bad "T17 ручка чистнула бэкапы ($n17 из 4)"; return; fi
  ok 'T17 ручка CLAUDE_PATCH_SKIP_MODELS=1: прежняя семантика вне target'
}

# T18: ворота --target --configure: ранний отказ кодом 2 без единой записи
# (поведенческий: старое дерево принимает комбинацию)
t18() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T18 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  # снимки -- ВНЕ $E: файл снимка не имеет права попасть в собственный предмет
  snap_to "$E" "$WORKDIR/t18.A" || { instr_bad 'снимок t18.A фикстуры не снят'; return; }
  local rc=0 out
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS HOME="$E/home" TMPDIR="$E/tmp" \
          CLAUDE_PATCH_LOCK="$E/lock/run.lock" \
          timeout 90 bash "$SCRIPT" --target "$E/img/fake-target" --configure 2>&1) || rc=$?
  snap_to "$E" "$WORKDIR/t18.B" || { instr_bad 'снимок t18.B фикстуры не снят'; return; }
  if [[ $rc -ne 2 ]]; then bad "T18 --target --configure ответил rc=$rc (ждали 2) :: ${out%%$'\n'*}"; return; fi
  if [[ "$out" != *"--target and --configure are mutually exclusive"* ]]; then
    bad 'T18 отказ не назвал причину взаимной исключительности'
    return
  fi
  local ch18=0
  changed "$WORKDIR/t18.A" "$WORKDIR/t18.B" || ch18=$?
  if [[ $ch18 -eq 2 ]]; then bad 'T18 ПРИБОР НЕДОСТУПЕН: отказ diff снимков фикстуры'; return; fi
  if [[ $ch18 -eq 0 ]]; then
    bad 'T18 отказ --target --configure оставил записи в фикстуре'
    return
  fi
  ok 'T18 --target --configure: ранний отказ rc=2, записей нет'
}

# T19: положительные контроли наблюдателя -- создать/заменить/удалить внутри
# фикстуры ОБЯЗАНЫ регистрироваться снимками (иначе зелёное -- вакуумное)
t19() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T19 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local d="$E/observer-scratch"
  mk_run mkdir -p "$d" || { instr_bad 'фикстура: каталог наблюдателя не создан'; return; }
  snap_to "$d" "$E/s.0" || { instr_bad 'снимок s.0 наблюдателя не снят'; return; }
  mk_put "$d/f" 'one\n' || { instr_bad 'фикстура: create наблюдателя не записан'; return; }
  snap_to "$d" "$E/s.1" || { instr_bad 'снимок s.1 наблюдателя не снят'; return; }
  local ch19a=0
  changed "$E/s.0" "$E/s.1" || ch19a=$?
  if [[ $ch19a -eq 2 ]]; then bad 'T19 ПРИБОР НЕДОСТУПЕН: отказ diff снимков наблюдателя (create)'; return; fi
  if [[ $ch19a -eq 1 ]]; then bad 'T19 контроль наблюдателя: create не зарегистрирован'; return; fi
  mk_put "$d/f" 'two-two\n' || { instr_bad 'фикстура: replace наблюдателя не записан'; return; }
  snap_to "$d" "$E/s.2" || { instr_bad 'снимок s.2 наблюдателя не снят'; return; }
  local ch19b=0
  changed "$E/s.1" "$E/s.2" || ch19b=$?
  if [[ $ch19b -eq 2 ]]; then bad 'T19 ПРИБОР НЕДОСТУПЕН: отказ diff снимков наблюдателя (replace)'; return; fi
  if [[ $ch19b -eq 1 ]]; then bad 'T19 контроль наблюдателя: replace не зарегистрирован'; return; fi
  mk_run rm -f "$d/f" || { instr_bad 'фикстура: unlink наблюдателя не выполнен'; return; }
  snap_to "$d" "$E/s.3" || { instr_bad 'снимок s.3 наблюдателя не снят'; return; }
  local ch19c=0
  changed "$E/s.2" "$E/s.3" || ch19c=$?
  if [[ $ch19c -eq 2 ]]; then bad 'T19 ПРИБОР НЕДОСТУПЕН: отказ diff снимков наблюдателя (unlink)'; return; fi
  if [[ $ch19c -eq 1 ]]; then bad 'T19 контроль наблюдателя: unlink не зарегистрирован'; return; fi
  ok 'T19 наблюдатель видит create/replace/unlink'
}

# T20: мутант «возврат probes-sync auto-roll» -- раскатка возвращена в target
t20() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T20 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local mut="$E/mut-probes.sh"
  mutate_one "$SCRIPT" "$mut" '^# \[559\] ворота: раскатка' \
    '^if \[\[ -z "\$TARGET" \]\]; then$' 'if true; then' \
    || { bad 'T20 мутация не заложена: ворот раскатки на дереве нет'; return; }
  bash -n "$mut" || { bad 'T20 мутант не парсится'; return; }
  local w="$E/kit-mock/stage.sh"
  build_probes_wrap "$w" "$E/img/fake-target" "$mut" || { bad "T20 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T20 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ ! -e "$E/obs/probes-sync.calls" ]]; then
    bad 'T20 ВАКУУМНАЯ ЗЕЛЕНЬ: возврат auto-roll не пойман (mock не вызван)'
    return
  fi
  ok 'T20 мутант возврата auto-roll краснеет предметно (раскатка пошла в target)'
}

# T21: мутант «возврат model sync» -- шаг 7 вернул sync в target
t21() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T21 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local mut="$E/mut-model.sh"
  mutate_one "$SCRIPT" "$mut" '^# \[559\] ворота: модельные данные' \
    '^if \[\[ -n "\$TARGET" \]\]; then$' 'if false; then' \
    || { bad 'T21 мутация не заложена: ворот шага 7 на дереве нет'; return; }
  bash -n "$mut" || { bad 'T21 мутант не парсится'; return; }
  local w="$E/wrap.sh"
  build_model_wrap "$w" "$E/img/fake-target" "$mut" || { bad "T21 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T21 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ ! -e "$E/obs/sync.called" ]]; then
    bad 'T21 ВАКУУМНАЯ ЗЕЛЕНЬ: возврат model sync не пойман'
    return
  fi
  local n21
  n21=$(count_backups "$E") || { bad 'T21 ПРИБОР НЕДОСТУПЕН: отказ подсчёта бэкапов'; return; }
  if [[ "$n21" == "4" ]]; then
    bad 'T21 мутант вызвал sync, но prune не почистил бэкапы -- причина не предметная'
    return
  fi
  ok 'T21 мутант возврата model sync краснеет предметно (sync + prune 4->3)'
}

# T22: мутант «возврат live tweakcc home/cache» -- изоляция снята, писатель
# форка снова бьёт по живому дому
t22() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T22 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local mut="$E/mut-activation.sh"
  mutate_one "$SCRIPT" "$mut" '^# \[559\] ворота: изоляция' \
    '^if \[\[ -n "\$TARGET" \]\]; then$' 'if false; then' \
    || { bad 'T22 мутация не заложена: ворот изоляции на дереве нет'; return; }
  bash -n "$mut" || { bad 'T22 мутант не парсится'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$mut" || { bad "T22 извлечение отказало"; return; }
  snap_to "$E/home/.tweakcc" "$E/snap.A" || { instr_bad 'снимок snap.A живого дома не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T22 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  snap_to "$E/home/.tweakcc" "$E/snap.B" || { instr_bad 'снимок snap.B живого дома не снят'; return; }
  local ch22=0
  changed "$E/snap.A" "$E/snap.B" || ch22=$?
  if [[ $ch22 -eq 2 ]]; then bad 'T22 ПРИБОР НЕДОСТУПЕН: отказ diff снимков живого дома'; return; fi
  if [[ $ch22 -eq 1 ]]; then
    bad 'T22 ВАКУУМНАЯ ЗЕЛЕНЬ: возврат живого дома не пойман (дом не изменён)'
    return
  fi
  ok 'T22 мутант возврата live home/cache краснеет предметно (живой дом изменён)'
}

# T23: TWEAKCC_LOCAL -- конфигурация всё равно собственная, кэш не изолируется
t23() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T23 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T23 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/local-unpacker.mjs" '#!/usr/bin/env node\n// synthetic local build\n' \
    || { instr_bad 'фикстура: local-unpacker.mjs не записан'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "$E/local-unpacker.mjs" "$SCRIPT" \
    || { bad "T23 извлечение отказало"; return; }
  snap_to "$E/home/.tweakcc" "$E/snap.A" || { instr_bad 'снимок snap.A живого дома не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T23 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local cfg cache23 root23
  cfg=$(ti_var TI_CFG) || { bad 'T23 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CFG'; return; }
  cache23=$(ti_var TI_CACHE) || { bad 'T23 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CACHE'; return; }
  root23=$(ti_var TI_ROOT) || { bad 'T23 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT'; return; }
  if [[ -z "$cfg" || "$cfg" != "$root23"/* ]]; then bad 'T23 TWEAKCC_LOCAL: конфигурация не собственная'; return; fi
  if [[ "$cache23" != "$E/cache/catalyst-tweakcc" ]]; then
    bad 'T23 TWEAKCC_LOCAL: кэш перенаправлен -- явное решение оператора сломано'
    return
  fi
  snap_to "$E/home/.tweakcc" "$E/snap.B" || { instr_bad 'снимок snap.B живого дома не снят'; return; }
  local ch23=0
  changed "$E/snap.A" "$E/snap.B" || ch23=$?
  if [[ $ch23 -eq 2 ]]; then bad 'T23 ПРИБОР НЕДОСТУПЕН: отказ diff снимков живого дома'; return; fi
  if [[ $ch23 -eq 0 ]]; then bad 'T23 TWEAKCC_LOCAL: живой дом изменён'; return; fi
  ok 'T23 TWEAKCC_LOCAL: конфиг свой, кэш не тронут, живой дом цел'
}

# T24: абсолютная ссылка в готовой записи пина -> отказ ДО первого CLI;
# живой sentinel и общий кэш не тронуты (fix-wave #559b, дефект cp -a)
t24() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T24 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T24 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/live-sentinel.txt" 'live-sentinel\n' || { instr_bad 'фикстура: live-sentinel не записан'; return; }
  mk_run ln -s "$E/live-sentinel.txt" "$E/cache/catalyst-tweakcc/$FAKE_SHA/abs-link.js" \
    || { instr_bad 'фикстура: абсолютная ссылка кэша не заложена'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T24 извлечение отказало"; return; }
  snap_to "$E/home/.tweakcc" "$E/snap.home.A" || { instr_bad 'снимок snap.home.A живого дома не снят'; return; }
  snap_to "$E/cache" "$E/snap.cache.A" || { instr_bad 'снимок snap.cache.A общего кэша не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -eq 0 ]]; then bad 'T24 абсолютная ссылка кэша наружу принята копией (форк писал бы в живой путь)'; return; fi
  if [[ "$WR_OUT" != *"наружу собственной копии"* ]]; then
    bad 'T24 отказ не назвал причину (ссылки наружу собственной копии)'
    return
  fi
  if ! cmp -s "$E/live-sentinel.txt" <(printf 'live-sentinel\n'); then bad 'T24 живой sentinel повреждён'; return; fi
  snap_to "$E/home/.tweakcc" "$E/snap.home.B" || { instr_bad 'снимок snap.home.B живого дома не снят'; return; }
  snap_to "$E/cache" "$E/snap.cache.B" || { instr_bad 'снимок snap.cache.B общего кэша не снят'; return; }
  local ch24a=0 ch24b=0
  changed "$E/snap.home.A" "$E/snap.home.B" || ch24a=$?
  changed "$E/snap.cache.A" "$E/snap.cache.B" || ch24b=$?
  if [[ $ch24a -eq 2 || $ch24b -eq 2 ]]; then bad 'T24 ПРИБОР НЕДОСТУПЕН: отказ diff снимков живого дома/кэша'; return; fi
  if [[ $ch24a -eq 0 || $ch24b -eq 0 ]]; then
    bad 'T24 отказ по ссылке кэша написал в живой дом/кэш'
    return
  fi
  ok 'T24 абсолютная ссылка кэша: ранний отказ, живые пути нетронуты'
}

# T25: относительная ферма ссылок pnpm РАЗРЕШЕНА и остаётся ссылкой в копии
t25() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T25 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T25 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local nm="$E/cache/catalyst-tweakcc/$FAKE_SHA/node_modules"
  mk_run mkdir -p "$nm/.pnpm/chalk@5.5.0/node_modules/chalk" || { instr_bad 'фикстура: ферма pnpm не создана'; return; }
  mk_put "$nm/.pnpm/chalk@5.5.0/node_modules/chalk/index.js" 'synthetic-chalk\n' \
    || { instr_bad 'фикстура: index.js фермы pnpm не записан'; return; }
  mk_run ln -s .pnpm/chalk@5.5.0/node_modules/chalk "$nm/chalk" || { instr_bad 'фикстура: ссылка pnpm не заложена'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { bad "T25 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T25 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local own25
  own25="$(ti_var TI_CACHE)" || { bad 'T25 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CACHE'; return; }
  local copy="$own25/$FAKE_SHA/node_modules"
  if [[ ! -L "$copy/chalk" ]]; then bad 'T25 относительная ссылка pnpm не сохранена ссылкой'; return; fi
  local target25
  target25=$(readlink "$copy/chalk") || { bad 'T25 ПРИБОР НЕДОСТУПЕН: отказ readlink ссылки pnpm'; return; }
  if [[ "$target25" != ".pnpm/chalk@5.5.0/node_modules/chalk" ]]; then
    bad 'T25 ссылка pnpm изменила цель при копировании'
    return
  fi
  if [[ ! -f "$copy/chalk/index.js" ]]; then bad 'T25 ссылка pnpm не разрешается ВНУТРИ копии'; return; fi
  ok 'T25 относительные ссылки pnpm: сохранены и разрешаются внутри копии'
}

# T26: env TARGET_ISOLATION_ROOT=чужой каталог, прогон БЕЗ --target --
# реальный скрипт доходит до EXIT-трапа (отказ целостности кита), чужой
# каталог обязан уцелеть (fix-wave #559b, дефект унаследованной переменной)
t26() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T26 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/foreign-dir" || { instr_bad 'фикстура: чужой каталог не создан'; return; }
  mk_put "$E/foreign-dir/keep.txt" 'foreign-keep\n' || { instr_bad 'фикстура: keep.txt не записан'; return; }
  local rc=0 out
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS HOME="$E/home" TMPDIR="$E/tmp" \
          CLAUDE_PATCH_LOCK="$E/lock/t26.lock" TARGET_ISOLATION_ROOT="$E/foreign-dir" \
          timeout 90 bash "$SCRIPT" 2>&1) || rc=$?
  if [[ ! -f "$E/foreign-dir/keep.txt" ]]; then
    bad "T26 ПИСАТЕЛЬ: чужой каталог из env TARGET_ISOLATION_ROOT удалён EXIT-трапом (rc=$rc)"
    return
  fi
  if [[ $rc -eq 0 ]]; then bad "T26 прогон без --target прошёл зелёно (rc=0) -- не тот путь"; return; fi
  ok 'T26 env TARGET_ISOLATION_ROOT без --target: чужой каталог уцелел'
}

# T27: env TARGET_ISOLATION_ROOT=чужой каталог + ранний отказ
# (--target --configure, rc 2 до трапа) -- чужой каталог уцелел
t27() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T27 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/foreign-dir" || { instr_bad 'фикстура: чужой каталог не создан'; return; }
  mk_put "$E/foreign-dir/keep.txt" 'foreign-keep\n' || { instr_bad 'фикстура: keep.txt не записан'; return; }
  local rc=0 out
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS HOME="$E/home" TMPDIR="$E/tmp" \
          CLAUDE_PATCH_LOCK="$E/lock/t27.lock" TARGET_ISOLATION_ROOT="$E/foreign-dir" \
          timeout 90 bash "$SCRIPT" --target "$E/img/fake-target" --configure 2>&1) || rc=$?
  if [[ $rc -ne 2 ]]; then bad "T27 ранний отказ не сработал (rc=$rc)"; return; fi
  if [[ ! -f "$E/foreign-dir/keep.txt" ]]; then
    bad 'T27 чужой каталог из env удалён при раннем отказе'
    return
  fi
  ok 'T27 env TARGET_ISOLATION_ROOT при раннем отказе: чужой каталог уцелел'
}

# T28: положительный контроль уборки СОБСТВЕННОГО temp + ворота владельца
# (поддельный токен / env-путь без активации не удаляются)
t28() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T28 helper отсутствует (приборная, не поведенческая)'; return; fi
  # A: собственный temp убирается
  mk_env || { bad 'T28 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { bad "T28 извлечение отказало (A)"; return; }
  cat >> "$w" <<'AUX' || { instr_bad 'фикстура: хвост обёртки A не дописан'; return; }
printf 'TI_ROOT2=%s\n' "${TARGET_ISOLATION_ROOT:-}"
target_isolation_cleanup
if [[ -e "${TARGET_ISOLATION_ROOT:-/nonexistent-ti}" ]]; then echo CLEANUP_STILL_THERE; else echo CLEANUP_GONE; fi
AUX
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T28 A обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local root2_28
  root2_28=$(ti_var TI_ROOT2) || { bad 'T28 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT2'; return; }
  if [[ -z "$root2_28" ]]; then bad 'T28 A собственный temp не создан'; return; fi
  if [[ "$WR_OUT" != *"CLEANUP_GONE"* ]]; then bad 'T28 A собственный temp не убран (уборка сломана)'; return; fi
  # B: поддельный токен -- уборка запрещена
  mk_env || { bad 'T28 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { bad "T28 извлечение отказало (B)"; return; }
  cat >> "$w" <<'AUX' || { instr_bad 'фикстура: хвост обёртки B не дописан'; return; }
TARGET_ISOLATION_OWNER_TOKEN="forged-wrong-token"
target_isolation_cleanup
if [[ -e "${TARGET_ISOLATION_ROOT:-/nonexistent-ti}" ]]; then echo CLEANUP_STILL_THERE; else echo CLEANUP_GONE; fi
AUX
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T28 B обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"CLEANUP_STILL_THERE"* ]]; then bad 'T28 B поддельный токен удалил собственный путь (ворот владельца нет)'; return; fi
  if [[ "$WR_OUT" != *"не подтверждён владельцем"* ]]; then bad 'T28 B ворота владельца не назвали причину'; return; fi
  # C: env-путь без активации -- helper-уровень, без участия конвейера
  mk_env || { bad 'T28 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/foreign-dir" || { instr_bad 'фикстура: чужой каталог не создан'; return; }
  mk_put "$E/foreign-dir/keep.txt" 'foreign-keep\n' || { instr_bad 'фикстура: keep.txt не записан'; return; }
  w="$E/wrap-helper.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' &&
    printf 'TARGET_ISOLATION_ROOT=%q\n' "$E/foreign-dir" &&
    printf 'source %q\n' "$HELPER" &&
    cat <<'AUX'
target_isolation_cleanup
if [[ -e "$TARGET_ISOLATION_ROOT" ]]; then echo FOREIGN_THERE; else echo FOREIGN_GONE; fi
AUX
  } > "$w" || { instr_bad 'фикстура: обёртка C не записана'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T28 C обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"FOREIGN_THERE"* ]]; then bad 'T28 C env-путь без активации удалён уборкой'; return; fi
  ok 'T28 уборка: свой temp убран; поддельный токен и env-путь не тронуты'
}

# T29: мутант «ворота владельца уборки сняты» -- поддельный токен удаляет путь
t29() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T29 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T29 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local mut="$E/mut-helper-cleanup.sh"
  mutate_one "$HELPER" "$mut" '^[ ]*# \[559b\] ворота: уборка только подтверждённого владельца' \
    '^[ ]*if \[\[ -z "\$want" [|][|] "\$have" != "\$want" \]\]; then$' 'if false; then' \
    || { bad 'T29 мутация не заложена: ворот владельца на дереве нет'; return; }
  bash -n "$mut" || { bad 'T29 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save"; bad "T29 извлечение отказало"; return; }
  HELPER="$helper_save"
  cat >> "$w" <<'AUX' || { instr_bad 'фикстура: хвост обёртки не дописан'; return; }
TARGET_ISOLATION_OWNER_TOKEN="forged-wrong-token"
target_isolation_cleanup
if [[ -e "${TARGET_ISOLATION_ROOT:-/nonexistent-ti}" ]]; then echo CLEANUP_STILL_THERE; else echo CLEANUP_GONE; fi
AUX
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T29 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"CLEANUP_GONE"* ]]; then
    bad 'T29 ВАКУУМНАЯ ЗЕЛЕНЬ: снятие ворот владельца не поймано (путь уцелел)'
    return
  fi
  ok 'T29 мутант снятия ворот владельца краснеет предметно (поддельный путь удалён)'
}

# T30: мутант «скан ссылок кэша снят» -- абсолютная ссылка принята копией
t30() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T30 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T30 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/live-sentinel.txt" 'live-sentinel\n' || { instr_bad 'фикстура: live-sentinel не записан'; return; }
  mk_run ln -s "$E/live-sentinel.txt" "$E/cache/catalyst-tweakcc/$FAKE_SHA/abs-link.js" \
    || { instr_bad 'фикстура: абсолютная ссылка кэша не заложена'; return; }
  local mut="$E/mut-helper-scan.sh"
  mutate_one "$HELPER" "$mut" '^[ ]*# \[559b\] ворота: ссылки кэша не выходят' \
    '^[ ]*if \[\[ \$scan_rc -ne 0 \]\]; then$' 'if false; then' \
    || { bad 'T30 мутация не заложена: скана ссылок на дереве нет'; return; }
  bash -n "$mut" || { bad 'T30 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save"; bad "T30 извлечение отказало"; return; }
  HELPER="$helper_save"
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T30 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local own30
  own30="$(ti_var TI_CACHE)" || { bad 'T30 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CACHE'; return; }
  if [[ ! -L "$own30/$FAKE_SHA/abs-link.js" ]]; then
    bad 'T30 ВАКУУМНАЯ ЗЕЛЕНЬ: абсолютная ссылка в копии не обнаружена (мутант не пойман)'
    return
  fi
  ok 'T30 мутант снятия скана ссылок краснеет предметно (абсолютная ссылка в копии)'
}

# T31: сама запись пина-источника -- ССЫЛКА на внешний каталог: корень копии
# обязан остаться реальным каталогом, копия-ссылка ведёт в живой путь (#559c)
t31() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T31 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T31 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/external-entry/dist" || { instr_bad 'фикстура: внешний вход не создан'; return; }
  mk_put "$E/external-entry/dist/index.mjs" '#!/usr/bin/env node\n' || { instr_bad 'фикстура: index.mjs внешнего входа не записан'; return; }
  mk_put "$E/external-entry/EXTERNAL-SENTINEL.txt" 'external-sentinel\n' \
    || { instr_bad 'фикстура: EXTERNAL-SENTINEL.txt не записан'; return; }
  mk_run rm -rf "$E/cache/catalyst-tweakcc/$FAKE_SHA" || { instr_bad 'фикстура: запись пина не убрана'; return; }
  mk_run ln -s "$E/external-entry" "$E/cache/catalyst-tweakcc/$FAKE_SHA" || { instr_bad 'фикстура: запись-ссылка не заложена'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T31 извлечение отказало"; return; }
  snap_to "$E/external-entry" "$E/snap.ext.A" || { instr_bad 'снимок snap.ext.A внешнего входа не снят'; return; }
  snap_to "$E/home/.tweakcc" "$E/snap.home.A" || { instr_bad 'снимок snap.home.A живого дома не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -eq 0 ]]; then bad 'T31 запись-ссылка принята: корень копии ведёт в живой внешний каталог'; return; fi
  if [[ "$WR_OUT" != *"корень собственной записи кэша"* ]]; then
    bad 'T31 отказ не назвал причину (корень собственной записи)'
    return
  fi
  snap_to "$E/external-entry" "$E/snap.ext.B" || { instr_bad 'снимок snap.ext.B внешнего входа не снят'; return; }
  snap_to "$E/home/.tweakcc" "$E/snap.home.B" || { instr_bad 'снимок snap.home.B живого дома не снят'; return; }
  # CONSTRAINT: отказ diff (rc2) под `if changed || changed` читается как «нет
  # изменений» и дал бы ложную зелень; статус каждого вызова отдельно, ok --
  # только две единицы (оба снимка равны); запись, доказанная любым вызовом (0),
  # -- предметный bad и побеждает отказ другого вызова; иначе rc2 -- ПРИБОР-метка
  local ch31a=0 ch31b=0
  changed "$E/snap.ext.A" "$E/snap.ext.B" || ch31a=$?
  changed "$E/snap.home.A" "$E/snap.home.B" || ch31b=$?
  if [[ $ch31a -eq 0 || $ch31b -eq 0 ]]; then
    bad 'T31 отказ по ссылке-корню написал во внешние/живые пути'
    return
  fi
  if [[ $ch31a -eq 2 ]]; then bad 'T31 ПРИБОР НЕДОСТУПЕН: отказ diff снимков внешнего входа'; return; fi
  if [[ $ch31b -eq 2 ]]; then bad 'T31 ПРИБОР НЕДОСТУПЕН: отказ diff снимков дома оператора'; return; fi
  ok 'T31 запись-источник-ссылка: корень копии реален, отказ до первого CLI, внешние пути целы'
}

# T32: битая ссылка с написанной целью ВНУТРИ копии -- цель обязана существовать
t32() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T32 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T32 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run ln -s ./not-there "$E/cache/catalyst-tweakcc/$FAKE_SHA/dangling" || { instr_bad 'фикстура: битая ссылка не заложена'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T32 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -eq 0 ]]; then bad 'T32 битая ссылка с целью внутри копии принята (realpath легализовал написание)'; return; fi
  if [[ "$WR_OUT" != *"цели нет"* ]]; then
    bad 'T32 отказ не назвал причину (цели нет)'
    return
  fi
  ok 'T32 битая ссылка внутри записи: отказ до первого CLI'
}

# T33: петля из двух ссылок внутри записи -- отказ до первого CLI
t33() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T33 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T33 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run ln -s cycle-b "$E/cache/catalyst-tweakcc/$FAKE_SHA/cycle-a" || { instr_bad 'фикстура: cycle-a не заложена'; return; }
  mk_run ln -s cycle-a "$E/cache/catalyst-tweakcc/$FAKE_SHA/cycle-b" || { instr_bad 'фикстура: cycle-b не заложена'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" || { bad "T33 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -eq 0 ]]; then bad 'T33 петля ссылок внутри записи принята'; return; fi
  if [[ "$WR_OUT" != *"не разрешается"* && "$WR_OUT" != *"цели нет"* ]]; then
    bad 'T33 отказ не назвал причину петли'
    return
  fi
  ok 'T33 петля ссылок внутри записи: отказ до первого CLI'
}

# T34: мутант «проверка корня копии снята» -- запись-ссылка становится корнем
t34() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T34 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T34 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/external-entry/dist" || { instr_bad 'фикстура: внешний вход не создан'; return; }
  mk_put "$E/external-entry/dist/index.mjs" '#!/usr/bin/env node\n' || { instr_bad 'фикстура: index.mjs внешнего входа не записан'; return; }
  mk_run rm -rf "$E/cache/catalyst-tweakcc/$FAKE_SHA" || { instr_bad 'фикстура: запись пина не убрана'; return; }
  mk_run ln -s "$E/external-entry" "$E/cache/catalyst-tweakcc/$FAKE_SHA" || { instr_bad 'фикстура: запись-ссылка не заложена'; return; }
  local mut="$E/mut-helper-root.sh"
  mutate_one "$HELPER" "$mut" '^[ ]*# \[559c\] ворота: корень собственной записи' \
    '^[ ]*if \[\[ -L "\$cache_own/\$CATALYST_TWEAKCC_SHA" \|\| ! -d "\$cache_own/\$CATALYST_TWEAKCC_SHA" \]\]; then$' 'if false; then' \
    || { bad 'T34 мутация не заложена: проверки корня копии на дереве нет'; return; }
  bash -n "$mut" || { bad 'T34 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save"; bad "T34 извлечение отказало"; return; }
  HELPER="$helper_save"
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T34 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local own34
  own34="$(ti_var TI_CACHE)" || { bad 'T34 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CACHE'; return; }
  if [[ ! -L "$own34/$FAKE_SHA" ]]; then
    bad 'T34 ВАКУУМНАЯ ЗЕЛЕНЬ: корень-ссылка в копии не обнаружена (мутант не пойман)'
    return
  fi
  ok 'T34 мутант снятия проверки корня краснеет предметно (корень копии -- ссылка)'
}

# T35: мутант «проверка существования цели снята» -- битая ссылка принята
t35() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T35 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T35 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run ln -s ./not-there "$E/cache/catalyst-tweakcc/$FAKE_SHA/dangling" || { instr_bad 'фикстура: битая ссылка не заложена'; return; }
  local mut="$E/mut-helper-exists.sh"
  # отступ строки python сохраняется в замене: без него мутант ломает разбор
  mutate_one "$HELPER" "$mut" '^[ ]*# \[559c\] ворота: написанная цель' \
    '^[ ]*if not os\.path\.exists\(resolved\):$' '        if False:' \
    || { bad 'T35 мутация не заложена: проверки существования цели на дереве нет'; return; }
  bash -n "$mut" || { bad 'T35 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save"; bad "T35 извлечение отказало"; return; }
  HELPER="$helper_save"
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T35 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local own35
  own35="$(ti_var TI_CACHE)" || { bad 'T35 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CACHE'; return; }
  if [[ ! -L "$own35/$FAKE_SHA/dangling" ]]; then
    bad 'T35 ВАКУУМНАЯ ЗЕЛЕНЬ: битая ссылка в копии не обнаружена (мутант не пойман)'
    return
  fi
  ok 'T35 мутант снятия exists-проверки краснеет предметно (битая ссылка в копии)'
}

# T36: скан копии кэша не принимает нечитаемое поддерево: отказ обхода os.walk
# равен нарушению; корень доступен ЯВНО. Факт traversal-отказа устанавливается
# ПРОБОЙ до прогона (подконтрольная непривилегированная фикстура); под root
# chmod 000 не блокирует листинг -- приборная краснота, не зелёный прогон
t36() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T36 helper отсутствует (приборная, не поведенческая)'; return; fi
  mk_env || { bad 'T36 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local tree="$E/scan-tree"
  mk_run mkdir -p "$tree/dark/dist" || { instr_bad 'фикстура: дерево скана не создано'; return; }
  mk_put "$E/live-sentinel.txt" 'live-sentinel\n' || { instr_bad 'фикстура: live-sentinel не записан'; return; }
  mk_run ln -s "$E/live-sentinel.txt" "$tree/dark/abs-link.js" || { instr_bad 'фикстура: ссылка наружу не заложена'; return; }
  # [559-fix5] CONSTRAINT: собственный chmod снимается на КАЖДОЙ ветке выхода
  # (ранний отказ без восстановления краснил cleanup побочным отказом своей же
  # фикстуры); ветка B дополнительно держит 000 на самом $tree до возврата
  # CONSTRAINT: отказ восстановления -- отказ прибора (stderr chmod -- в лог
  # зуба): невосстановленные права ломают уборку WORKDIR
  t36_restore() {
    chmod 755 "$tree" "$tree/dark" \
      || { printf 'ПРИБОР НЕДОСТУПЕН: права фикстуры не восстановлены: %s\n' "$tree" >&2; return 2; }
  }
  if ! mk_run chmod 000 "$tree/dark"; then
    t36_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
    instr_bad 'фикстура: chmod 000 поддерева не выполнен'; return
  fi
  local probe_rc=0
  # CONSTRAINT: stderr пробы -- лог зуба в $WORKDIR (не глушить и не в общий
  # поток): печать -- в сообщение отказа проверки пробы
  python3 - "$tree" <<'PYPROBE' >/dev/null 2>"$WORKDIR/t36.probe.err" || probe_rc=$?
import os, sys
errs = []
for _dp, _dn, _fn in os.walk(sys.argv[1], onerror=lambda e: errs.append(e)):
    pass
sys.exit(1 if errs else 0)
PYPROBE
  if [[ $probe_rc -ne 1 ]]; then
    t36_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
    bad "T36 ПРИБОР: факт traversal-отказа не установлен (chmod 000 не блокирует листинг -- прогон под root?); зелёным это быть не может :: stderr пробы: $(cat "$WORKDIR/t36.probe.err")"
    return
  fi
  local out36 rcA=0
  out36="$(bash -c 'source "$1"; __ti_cache_outside_links "$2"' _ "$HELPER" "$tree" 2>&1)" || rcA=$?
  if [[ $rcA -eq 0 ]]; then
    t36_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
    bad 'T36 нечитаемое поддерево со ссылкой принято за чистый кэш (тихий пропуск os.walk)'; return
  fi
  if [[ "$out36" != *'обход невозможен'* ]]; then
    t36_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
    bad 'T36 отказ скана не назвал причину обхода'; return
  fi
  # недоступный КОРЕНЬ -- явный отказ, не пустой «чистый» обход
  if ! mk_run chmod 755 "$tree/dark" || ! mk_run chmod 000 "$tree"; then
    t36_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
    instr_bad 'фикстура: права ветки B не выставлены'; return
  fi
  local rcB=0
  out36="$(bash -c 'source "$1"; __ti_cache_outside_links "$2"' _ "$HELPER" "$tree" 2>&1)" || rcB=$?
  t36_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
  if [[ $rcB -eq 0 ]]; then bad 'T36 недоступный корень скана дал чистый обход (rc=0)'; return; fi
  if ! cmp -s "$E/live-sentinel.txt" <(printf 'live-sentinel\n'); then bad 'T36 скан повредил живой sentinel'; return; fi
  ok 'T36 скан: нечитаемое поддерево и недоступный корень -- отказ, не чистый кэш'
}

# T37: мутант «скрытый os.walk отказ» -- onerror снят: нечитаемое поддерево
# снова пропускается молча (предметно -- тихий пропуск возвращается)
t37() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T37 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T37 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local tree="$E/scan-tree"
  mk_run mkdir -p "$tree/dark" || { instr_bad 'фикстура: дерево скана не создано'; return; }
  mk_put "$E/live-sentinel.txt" 'live-sentinel\n' || { instr_bad 'фикстура: live-sentinel не записан'; return; }
  mk_run ln -s "$E/live-sentinel.txt" "$tree/dark/abs-link.js" || { instr_bad 'фикстура: ссылка наружу не заложена'; return; }
  # [559-fix5] CONSTRAINT: как в T36 -- собственный chmod снимается на каждой
  # ветке выхода, чтобы cleanup фикстуры не краснил лог побочным отказом
  # CONSTRAINT: отказ восстановления -- отказ прибора (stderr chmod -- в лог зуба)
  t37_restore() {
    chmod 755 "$tree/dark" \
      || { printf 'ПРИБОР НЕДОСТУПЕН: права фикстуры не восстановлены: %s\n' "$tree/dark" >&2; return 2; }
  }
  if ! mk_run chmod 000 "$tree/dark"; then
    t37_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
    instr_bad 'фикстура: chmod 000 поддерева не выполнен'; return
  fi
  local probe_rc=0
  # CONSTRAINT: stderr пробы -- лог зуба в $WORKDIR (не глушить и не в общий
  # поток): печать -- в сообщение отказа проверки пробы
  python3 - "$tree" <<'PYPROBE' >/dev/null 2>"$WORKDIR/t37.probe.err" || probe_rc=$?
import os, sys
errs = []
for _dp, _dn, _fn in os.walk(sys.argv[1], onerror=lambda e: errs.append(e)):
    pass
sys.exit(1 if errs else 0)
PYPROBE
  if [[ $probe_rc -ne 1 ]]; then
    t37_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
    bad "T37 ПРИБОР: факт traversal-отказа не установлен -- мутант нечем мерить :: stderr пробы: $(cat "$WORKDIR/t37.probe.err")"; return
  fi
  local mut="$E/mut-scan-onerror.sh"
  if ! mutate_one "$HELPER" "$mut" '^# \[559-fix4\] CONSTRAINT: отказ обхода поддерева' \
    '^for dirpath, dirnames, filenames in os\.walk\(root, onerror=_deny\):$' \
    'for dirpath, dirnames, filenames in os.walk(root):'; then
    t37_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
    bad 'T37 мутация не заложена: onerror-обработки на дереве нет'; return
  fi
  if ! bash -n "$mut"; then
    t37_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
    bad 'T37 мутант не парсится'; return
  fi
  local rc=0
  # CONSTRAINT: stderr мутанта -- лог зуба в $WORKDIR (не глушить и не в общий
  # поток): печать -- в сообщение отказа проверки вакуумной зелени
  bash -c 'source "$1"; __ti_cache_outside_links "$2"' _ "$mut" "$tree" >/dev/null 2>"$WORKDIR/t37.mutant.err" || rc=$?
  t37_restore || { instr_bad 'права фикстуры не восстановлены'; return; }
  if [[ $rc -ne 0 ]]; then bad "T37 ВАКУУМНАЯ ЗЕЛЕНЬ: снятие onerror не убрало отказ -- мутант не пойман :: stderr мутанта: $(cat "$WORKDIR/t37.mutant.err")"; return; fi
  ok 'T37 мутант скрытого os.walk-отказа краснеет предметно (тихий пропуск вернулся)'
}

# T38: лестница источника -- existsSync форка (-e, НЕ -d): существующий ФАЙЛ
# ~/.tweakcc ВЫБИРАЕТСЯ и отвергается как не-каталог, без отката к
# ~/.claude/tweakcc
t38() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T38 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T38 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run rm -rf "$E/home/.tweakcc" || { instr_bad 'фикстура: живой дом не убран'; return; }
  mk_put "$E/home/.tweakcc" 'not-a-dir-sentinel\n' || { instr_bad 'фикстура: файл ~/.tweakcc не записан'; return; }
  mk_run mkdir -p "$E/home/.claude/tweakcc" || { instr_bad 'фикстура: запасной дом не создан'; return; }
  mk_put "$E/home/.claude/tweakcc/config.json" 'fallback-marker\n' || { instr_bad 'фикстура: config.json запасного дома не записан'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { bad "T38 извлечение отказало"; return; }
  local expected38
  expected38="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$E/home/.tweakcc")" \
    || { bad 'T38 ПРИБОР НЕДОСТУПЕН: отказ python3 realpath фикстуры'; return; }
  snap_to "$E/home" "$E/snap.A" || { instr_bad 'снимок snap.A HOME не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -eq 0 ]]; then bad 'T38 файл на месте ~/.tweakcc принят лестницей (откат к следующему дому)'; return; fi
  if [[ "$WR_OUT" != *"источник конфигурации не каталог: $expected38"* ]]; then
    bad 'T38 отказ не выбрал ФАЙЛ ~/.tweakcc как источник (лестница не existsSync)'
    return
  fi
  snap_to "$E/home" "$E/snap.B" || { instr_bad 'снимок snap.B HOME не снят'; return; }
  local ch38=0
  changed "$E/snap.A" "$E/snap.B" || ch38=$?
  if [[ $ch38 -eq 2 ]]; then bad 'T38 ПРИБОР НЕДОСТУПЕН: отказ diff снимков HOME'; return; fi
  if [[ $ch38 -eq 0 ]]; then bad 'T38 отказ по не-каталогу написал в HOME'; return; fi
  ok 'T38 лестница existsSync: файл ~/.tweakcc выбран и отвергнут, отката нет'
}

# T39: мутант «file-vs-dir ladder» -- -e заменён обратно на -d: файл
# пропускается, лестница откатывается к ~/.claude/tweakcc
t39() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T39 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T39 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run rm -rf "$E/home/.tweakcc" || { instr_bad 'фикстура: живой дом не убран'; return; }
  mk_put "$E/home/.tweakcc" 'not-a-dir-sentinel\n' || { instr_bad 'фикстура: файл ~/.tweakcc не записан'; return; }
  mk_run mkdir -p "$E/home/.claude/tweakcc" || { instr_bad 'фикстура: запасной дом не создан'; return; }
  mk_put "$E/home/.claude/tweakcc/config.json" 'fallback-marker\n' || { instr_bad 'фикстура: config.json запасного дома не записан'; return; }
  local mut="$E/mut-ladder.sh"
  mutate_one "$HELPER" "$mut" '^  # \[559-fix4\] CONSTRAINT: existsSync форка' \
    '^  elif \[\[ -e "\$HOME/\.tweakcc" \]\]; then$' '  elif [[ -d "$HOME/.tweakcc" ]]; then' \
    || { bad 'T39 мутация не заложена: -e-лестницы на дереве нет'; return; }
  bash -n "$mut" || { bad 'T39 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save"; bad "T39 извлечение отказало"; return; }
  HELPER="$helper_save"
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T39 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local cfg39
  cfg39=$(ti_var TI_CFG) || { bad 'T39 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CFG'; return; }
  if ! cmp -s "$cfg39/config.json" <(printf 'fallback-marker\n'); then
    bad 'T39 ВАКУУМНАЯ ЗЕЛЕНЬ: откат к ~/.claude/tweakcc не пойман (копия не оттуда)'
    return
  fi
  ok 'T39 мутант file-vs-dir краснеет предметно (источник -- запасной дом)'
}

# T40: ~other/dir раскрывается в $HOME/other/dir -- источник и копия оттуда
t40() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T40 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T40 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/home/other/dir" || { instr_bad 'фикстура: ~other/dir не создан'; return; }
  mk_put "$E/home/other/dir/config.json" '{"ccVersion":"2.1.283","patchOptions":{"otherhome":true}}\n' \
    || { instr_bad 'фикстура: config.json ~other/dir не записан'; return; }
  mk_put "$E/home/other/dir/catalyst-expected-off.txt" 'other-expected-off\n' \
    || { instr_bad 'фикстура: expected-off ~other/dir не записан'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { bad "T40 извлечение отказало"; return; }
  mk_sed "$w" "s|^export TMPDIR=.*|&\nexport TWEAKCC_CONFIG_DIR='~other/dir'|" \
    "export TWEAKCC_CONFIG_DIR='~other/dir'" || { instr_bad 'фикстура: TWEAKCC_CONFIG_DIR обёртки не подставлен'; return; }
  local expected40
  expected40="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$E/home/other/dir")" \
    || { bad 'T40 ПРИБОР НЕДОСТУПЕН: отказ python3 realpath фикстуры'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T40 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"источник $expected40 остаётся нетронутым"* ]]; then
    bad 'T40 ~other/dir не раскрыт в $HOME/other/dir (граница дома склеена)'
    return
  fi
  local cfg40
  cfg40=$(ti_var TI_CFG) || { bad 'T40 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CFG'; return; }
  cmp -s "$cfg40/config.json" "$E/home/other/dir/config.json" \
    || { bad 'T40 копия взята не из $HOME/other/dir'; return; }
  cmp -s "$cfg40/catalyst-expected-off.txt" "$E/home/other/dir/catalyst-expected-off.txt" \
    || { bad 'T40 expected-off взят не из $HOME/other/dir'; return; }
  ok 'T40 ~other/dir -> $HOME/other/dir: источник и копия верны'
}

# T41: контроль ~/dir -> $HOME/dir (косая черта после ~ сохраняется)
t41() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T41 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T41 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/home/ti-alt-home" || { instr_bad 'фикстура: ~/ti-alt-home не создан'; return; }
  mk_put "$E/home/ti-alt-home/config.json" '{"ccVersion":"2.1.283","patchOptions":{"althome":true}}\n' \
    || { instr_bad 'фикстура: config.json ~/ti-alt-home не записан'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { bad "T41 извлечение отказало"; return; }
  mk_sed "$w" "s|^export TMPDIR=.*|&\nexport TWEAKCC_CONFIG_DIR='~/ti-alt-home'|" \
    "export TWEAKCC_CONFIG_DIR='~/ti-alt-home'" || { instr_bad 'фикстура: TWEAKCC_CONFIG_DIR обёртки не подставлен'; return; }
  local expected41
  expected41="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$E/home/ti-alt-home")" \
    || { bad 'T41 ПРИБОР НЕДОСТУПЕН: отказ python3 realpath фикстуры'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T41 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"источник $expected41 остаётся нетронутым"* ]]; then
    bad 'T41 ~/dir не раскрыт в $HOME/dir'
    return
  fi
  local cfg41
  cfg41=$(ti_var TI_CFG) || { bad 'T41 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CFG'; return; }
  cmp -s "$cfg41/config.json" "$E/home/ti-alt-home/config.json" \
    || { bad 'T41 копия взята не из $HOME/ti-alt-home'; return; }
  ok 'T41 контроль ~/dir -> $HOME/dir'
}

# T42: контроль XDG -- нет ни одного дома tweakcc, XDG_CONFIG_HOME задан:
# источник $XDG_CONFIG_HOME/tweakcc (лестница форка, шаг 4)
t42() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T42 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T42 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run rm -rf "$E/home/.tweakcc" || { instr_bad 'фикстура: живой дом не убран'; return; }
  mk_run mkdir -p "$E/xdgconf/tweakcc" || { instr_bad 'фикстура: XDG-дом не создан'; return; }
  mk_put "$E/xdgconf/tweakcc/config.json" '{"ccVersion":"2.1.283","patchOptions":{"xdghome":true}}\n' \
    || { instr_bad 'фикстура: config.json XDG-дома не записан'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { bad "T42 извлечение отказало"; return; }
  wrap_export "$w" XDG_CONFIG_HOME "$E/xdgconf" TMPDIR || { instr_bad 'фикстура: XDG_CONFIG_HOME обёртки не подставлен'; return; }
  local expected42
  expected42="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$E/xdgconf/tweakcc")" \
    || { bad 'T42 ПРИБОР НЕДОСТУПЕН: отказ python3 realpath фикстуры'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T42 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"источник $expected42 остаётся нетронутым"* ]]; then
    bad 'T42 лестница не выбрала $XDG_CONFIG_HOME/tweakcc'
    return
  fi
  ok 'T42 контроль XDG: источник $XDG_CONFIG_HOME/tweakcc'
}

# T43: TMPDIR внутри ЗАЩИЩЁННОГО живого дома (общий кэш, .claude, .tweakcc,
# npm/pnpm-дома, XDG-дом tweakcc) -- отказ кодом 6 ДО mktemp, ни одного
# созданного temp и ни одной записи
t43() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T43 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T43 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/home/.claude/x" "$E/home/.npm/x" "$E/home/.cache/pnpm/x" \
           "$E/home/.local/share/pnpm/x" "$E/home/.local/state/pnpm/x" \
           "$E/cache/catalyst-tweakcc/x" "$E/xdgconf/tweakcc/x" \
    || { instr_bad 'фикстура: защищённые дома не созданы'; return; }
  local case_dir w leftover msg_pat
  for case_dir in "$E/home/.claude" "$E/home/.tweakcc" "$E/home/.npm" \
                  "$E/home/.cache/pnpm" "$E/home/.local/share/pnpm" \
                  "$E/home/.local/state/pnpm" "$E/cache/catalyst-tweakcc" \
                  "$E/xdgconf/tweakcc"; do
    # ~/.tweakcc совпадает с источником -- его ловит ПРЕЖНЯЯ ветка «внутри
    # источника» (T09); остальные дома -- только новый защищённый перечень
    if [[ "$case_dir" == "$E/home/.tweakcc" ]]; then
      msg_pat='внутри источника'
    else
      msg_pat='защищённого живого дома'
    fi
    w="$E/wrap.sh"
    build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { bad "T43 извлечение отказало ($case_dir)"; return; }
    if [[ "$case_dir" == "$E/xdgconf/tweakcc" ]]; then
      wrap_export "$w" XDG_CONFIG_HOME "$E/xdgconf" TMPDIR || { instr_bad "фикстура: XDG_CONFIG_HOME обёртки не подставлен ($case_dir)"; return; }
    fi
    wrap_export "$w" TMPDIR "$case_dir/x" || { instr_bad "фикстура: TMPDIR обёртки не подменён ($case_dir)"; return; }
    wrap_run "$w"
    if [[ $WR_RC -ne 6 ]]; then bad "T43 TMPDIR в защищённом доме ($case_dir) прошёл rc=$WR_RC (ждали 6)"; return; fi
    if [[ "$WR_OUT" != *"$msg_pat"* ]]; then bad "T43 отказ не назвал причину ($case_dir; ждали: $msg_pat)"; return; fi
    leftover="$(find "$E" -name 'cc-target-isolation.*' -print -quit)" \
      || { bad "T43 ПРИБОР НЕДОСТУПЕН: отказ find остатков temp ($case_dir)"; return; }
    if [[ -n "$leftover" ]]; then bad "T43 отказ создал temp ($case_dir): $leftover"; return; fi
  done
  ok 'T43 TMPDIR в любом защищённом живом доме: rc=6 до mktemp, temp нет'
}

# T44: мутант «TMPDIR в cache» -- общий кэш (и pnpm/XDG-дома) сняты из
# защищённого перечня: TMPDIR в общем кэше проходит, temp создаётся в нём
t44() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T44 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T44 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/cache/catalyst-tweakcc/x" || { instr_bad 'фикстура: каталог в общем кэше не создан'; return; }
  local mut="$E/mut-tmphomes.sh"
  mutate_one "$HELPER" "$mut" '^  for ti_prot in .*$' \
    '^    \[\[ -n "\$ti_prot" \]\] [|][|] continue$' '    [[ "$ti_prot" == "$HOME/.claude" || "$ti_prot" == "$HOME/.tweakcc" ]] || continue' \
    || { bad 'T44 мутация не заложена: перечня защищённых домов на дереве нет'; return; }
  bash -n "$mut" || { bad 'T44 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save"; bad "T44 извлечение отказало"; return; }
  HELPER="$helper_save"
  wrap_export "$w" TMPDIR "$E/cache/catalyst-tweakcc/x" || { instr_bad 'фикстура: TMPDIR обёртки не подменён'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T44 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local found44
  found44="$(find "$E/cache/catalyst-tweakcc/x" -maxdepth 1 -name 'cc-target-isolation.*' -print -quit)" \
    || { bad 'T44 ПРИБОР НЕДОСТУПЕН: отказ find temp в общем кэше'; return; }
  if [[ -z "$found44" ]]; then
    bad 'T44 ВАКУУМНАЯ ЗЕЛЕНЬ: temp в общем кэше не создан -- мутант не пойман'
    return
  fi
  ok 'T44 мутант TMPDIR-в-кэше краснеет предметно (temp создан в общем кэше)'
}

# T45: TWEAKCC_CONFIG_DIR виден ДОЧЕРНЕЙ оболочке (ENV, абсолютный собственный
# дом) -- снятие export из production обязано краснить
t45() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T45 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T45 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/wrap.sh"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { bad "T45 извлечение отказало"; return; }
  cat >> "$w" <<'AUX' || { instr_bad 'фикстура: reader CHILD_CFG не дописан'; return; }
CHILD_CFG=$(bash -c 'printf "%s" "${TWEAKCC_CONFIG_DIR:-}"') || { echo 'T45 ПРИБОР НЕДОСТУПЕН: отказ reader CHILD_CFG' >&2; exit 2; }
printf 'CHILD_CFG=%s\n' "$CHILD_CFG"
AUX
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T45 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local own45 child45
  own45=$(ti_var TI_CFG) || { bad 'T45 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CFG'; return; }
  child45=$(ti_var CHILD_CFG) || { bad 'T45 ПРИБОР НЕДОСТУПЕН: отказ ti_var CHILD_CFG'; return; }
  if [[ -z "$own45" || "$own45" != /* ]]; then bad 'T45 собственный дом не создан/не абсолютный'; return; fi
  if [[ "$child45" != "$own45" ]]; then
    bad "T45 дочерний bash не видит собственный дом в ENV: CHILD='$child45' vs OWN='$own45'"
    return
  fi
  ok 'T45 TWEAKCC_CONFIG_DIR экспортирован: дочерняя оболочка видит собственный дом'
}

# T46: мутант «снятие export» -- переменная больше не в ENV детей
t46() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T46 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T46 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local mut="$E/mut-export.sh"
  mutate_one "$HELPER" "$mut" '^  # ДО первого CLI: форк \(getConfigDir\)' \
    '^  export TWEAKCC_CONFIG_DIR="\$own"$' '  TWEAKCC_CONFIG_DIR="$own"' \
    || { bad 'T46 мутация не заложена: export-строки на дереве нет'; return; }
  bash -n "$mut" || { bad 'T46 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save"; bad "T46 извлечение отказало"; return; }
  HELPER="$helper_save"
  cat >> "$w" <<'AUX' || { instr_bad 'фикстура: reader CHILD_CFG не дописан'; return; }
CHILD_CFG=$(bash -c 'printf "%s" "${TWEAKCC_CONFIG_DIR:-}"') || { echo 'T46 ПРИБОР НЕДОСТУПЕН: отказ reader CHILD_CFG' >&2; exit 2; }
printf 'CHILD_CFG=%s\n' "$CHILD_CFG"
AUX
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T46 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local own46 child46
  own46=$(ti_var TI_CFG) || { bad 'T46 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CFG'; return; }
  child46=$(ti_var CHILD_CFG) || { bad 'T46 ПРИБОР НЕДОСТУПЕН: отказ ti_var CHILD_CFG'; return; }
  if [[ -z "$own46" ]]; then bad 'T46 мутант сломал саму активацию'; return; fi
  if [[ -n "$child46" ]]; then
    bad 'T46 ВАКУУМНАЯ ЗЕЛЕНЬ: дочерняя оболочка по-прежнему видит переменную'
    return
  fi
  ok 'T46 мутант снятия export краснеет предметно (ребёнок без собственного дома)'
}

# T47: положительный контроль снимка -- touch-only (байты не меняются) и
# touch-only каталога обязаны регистрироваться (st_mtime_ns в снимке)
t47() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T47 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local d="$E/mtime-scratch"
  mk_run mkdir -p "$d/inner" || { instr_bad 'фикстура: каталог mtime-контроля не создан'; return; }
  mk_put "$d/f" 'same-bytes\n' || { instr_bad 'фикстура: файл mtime-контроля не записан'; return; }
  snap_to "$d" "$E/m.0" || { instr_bad 'снимок m.0 не снят'; return; }
  mk_run touch -t 202001010000.00 "$d/f" || { instr_bad 'фикстура: touch файла не выполнен'; return; }
  snap_to "$d" "$E/m.1" || { instr_bad 'снимок m.1 не снят'; return; }
  local ch47a=0
  changed "$E/m.0" "$E/m.1" || ch47a=$?
  if [[ $ch47a -eq 2 ]]; then bad 'T47 ПРИБОР НЕДОСТУПЕН: отказ diff снимков mtime (файл)'; return; fi
  if [[ $ch47a -eq 1 ]]; then bad 'T47 контроль: touch-only файла не зарегистрирован (снимок без mtime_ns?)'; return; fi
  if ! cmp -s "$d/f" <(printf 'same-bytes\n'); then bad 'T47 контроль: байты изменились -- это не touch-only'; return; fi
  snap_to "$d" "$E/m.2" || { instr_bad 'снимок m.2 не снят'; return; }
  mk_run touch -t 202001020000.00 "$d/inner" || { instr_bad 'фикстура: touch каталога не выполнен'; return; }
  snap_to "$d" "$E/m.3" || { instr_bad 'снимок m.3 не снят'; return; }
  local ch47b=0
  changed "$E/m.2" "$E/m.3" || ch47b=$?
  if [[ $ch47b -eq 2 ]]; then bad 'T47 ПРИБОР НЕДОСТУПЕН: отказ diff снимков mtime (каталог)'; return; fi
  if [[ $ch47b -eq 1 ]]; then bad 'T47 контроль: touch-only каталога не зарегистрирован'; return; fi
  ok 'T47 снимок видит touch-only файла и каталога (st_mtime_ns)'
}

# T48: мутант «touch-only общего cache» -- прогон трогает mtime записи общего
# кэша без смены байтов; снимок с mtime_ns обязан это ловить
t48() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T48 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T48 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local mut="$E/mut-touch.sh"
  mutate_one "$HELPER" "$mut" '^    if \[\[ \$cache_copied -eq 1 \]\]; then$' \
    '^      echo "Изоляция target \(#559\): кэш распаковщика -- собственный temp \$CATALYST_TWEAKCC_CACHE \(готовая запись пина скопирована\)"$' \
    '      touch "$E/cache/catalyst-tweakcc/$CATALYST_TWEAKCC_SHA/dist/index.mjs"; echo "Изоляция target (#559): кэш распаковщика -- собственный temp $CATALYST_TWEAKCC_CACHE (готовая запись пина скопирована)"' \
    || { bad 'T48 мутация не заложена: строки объявления кэша на дереве нет'; return; }
  bash -n "$mut" || { bad 'T48 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save"; bad "T48 извлечение отказало"; return; }
  HELPER="$helper_save"
  snap_to "$E/cache" "$E/snap.cache.A" || { instr_bad 'снимок snap.cache.A общего кэша не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T48 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  snap_to "$E/cache" "$E/snap.cache.B" || { instr_bad 'снимок snap.cache.B общего кэша не снят'; return; }
  local ch48=0
  changed "$E/snap.cache.A" "$E/snap.cache.B" || ch48=$?
  if [[ $ch48 -eq 2 ]]; then bad 'T48 ПРИБОР НЕДОСТУПЕН: отказ diff снимков кэша'; return; fi
  if [[ $ch48 -eq 1 ]]; then bad 'T48 ВАКУУМНАЯ ЗЕЛЕНЬ: touch-only общего кэша не пойман (снимок без mtime?)'; return; fi
  if ! cmp -s "$E/cache/catalyst-tweakcc/$FAKE_SHA/dist/index.mjs" <(printf '#!/usr/bin/env node\n// synthetic pinned unpacker\n'); then
    bad 'T48 содержимое записи изменилось -- поймана перезапись, не touch-only'
    return
  fi
  ok 'T48 мутант touch-only общего кэша краснеет предметно (mtime_ns в снимке)'
}

# T49: холодная загрузка под --target -- install/build успешны, все четыре
# писателя ушли в приватные подкаталоги собственного temp, синтетический HOME
# не получил ни нового файла, ни изменённого mtime, запись собрана в СОБСТВЕННОМ
# кэше (модель замера 514 МБ)
t49() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T49 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T49 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_cold_mocks "$E/mockbin" || { instr_bad 'фикстура: моки холодной сборки не записаны'; return; }
  mk_run rm -rf "$E/cache/catalyst-tweakcc/$FAKE_SHA" || { instr_bad 'фикстура: запись пина не убрана'; return; }
  local w="$E/wrap.sh"
  build_cold_wrap "$w" "$E/img/fake-target" "$SCRIPT" || { bad "T49 извлечение отказало"; return; }
  snap_to "$E/home" "$E/snap.home.A" || { instr_bad 'снимок snap.home.A HOME не снят'; return; }
  cold_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T49 холодная сборка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local root49 own49 d
  root49=$(ti_var TI_ROOT) || { bad 'T49 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT'; return; }
  own49=$(ti_var TI_CACHE) || { bad 'T49 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CACHE'; return; }
  if [[ -z "$root49" || -z "$own49" || "$own49" != "$root49"/* ]]; then bad 'T49 собственный temp/кэш не назначены'; return; fi
  for d in npm-cache xdg-data xdg-cache xdg-state; do
    [[ -f "$root49/$d/ti-marker" ]] || { bad "T49 положительный контроль: писатель $d не дошёл до собственного temp"; return; }
  done
  [[ -f "$own49/$FAKE_SHA/dist/index.mjs" ]] || { bad 'T49 запись пина не собрана в собственном кэше'; return; }
  if [[ -e "$E/cache/catalyst-tweakcc/$FAKE_SHA" ]]; then bad 'T49 общий кэш получил новую запись'; return; fi
  snap_to "$E/home" "$E/snap.home.B" || { instr_bad 'снимок snap.home.B HOME не снят'; return; }
  local ch49=0
  changed "$E/snap.home.A" "$E/snap.home.B" || ch49=$?
  if [[ $ch49 -eq 2 ]]; then bad 'T49 ПРИБОР НЕДОСТУПЕН: отказ diff снимков HOME'; return; fi
  if [[ $ch49 -eq 0 ]]; then
    bad 'T49 ПИСАТЕЛЬ: холодная сборка оставила след в синтетическом HOME (файл/mtime)'
    return
  fi
  ok 'T49 холодный --target: сборка в собственном кэше, писатели в private-temp, HOME нетронут'
}

# T50: мутант «снятие четырёх cold-build redirects» (одной группой) --
# писатели возвращаются в живые HOME-фолбэки
t50() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T50 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T50 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_cold_mocks "$E/mockbin" || { instr_bad 'фикстура: моки холодной сборки не записаны'; return; }
  mk_run rm -rf "$E/cache/catalyst-tweakcc/$FAKE_SHA" || { instr_bad 'фикстура: запись пина не убрана'; return; }
  local mut="$E/mut-cold.sh"
  mutate_one "$HELPER" "$mut" '^  # \[559-fix4\] CONSTRAINT: единственная точка перенаправления' \
    '^  if \[\[ "\$\{__TI_COLD_ON:-0\}" == 1 \]\]; then$' '  if false; then' \
    || { bad 'T50 мутация не заложена: перенаправления на дереве нет'; return; }
  bash -n "$mut" || { bad 'T50 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_cold_wrap "$w" "$E/img/fake-target" "$SCRIPT" || { HELPER="$helper_save"; bad "T50 извлечение отказало"; return; }
  HELPER="$helper_save"
  snap_to "$E/home" "$E/snap.home.A" || { instr_bad 'снимок snap.home.A HOME не снят'; return; }
  cold_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T50 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local root50
  root50=$(ti_var TI_ROOT) || { bad 'T50 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT'; return; }
  if [[ -e "$root50/npm-cache/ti-marker" ]]; then
    bad 'T50 ВАКУУМНАЯ ЗЕЛЕНЬ: перенаправление живо при снятом вороте'
    return
  fi
  snap_to "$E/home" "$E/snap.home.B" || { instr_bad 'снимок snap.home.B HOME не снят'; return; }
  local ch50=0
  changed "$E/snap.home.A" "$E/snap.home.B" || ch50=$?
  if [[ $ch50 -eq 2 ]]; then bad 'T50 ПРИБОР НЕДОСТУПЕН: отказ diff снимков HOME'; return; fi
  if [[ $ch50 -eq 1 ]]; then
    bad 'T50 ВАКУУМНАЯ ЗЕЛЕНЬ: возврат писателей в живые дома не пойман'
    return
  fi
  [[ -f "$E/home/.npm/_cacache/ti-marker" ]] || { bad 'T50 след живого фолбэка npm не найден (причина не предметная)'; return; }
  ok 'T50 мутант снятия редиректов краснеет предметно (писатели в живых домах)'
}

# T51: parent-контроль -- холодная загрузка БЕЗ --target не меняется:
# перенаправлений нет (моки пишут живые фолбэки), сборка в общем кэше
t51() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T51 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T51 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_cold_mocks "$E/mockbin" || { instr_bad 'фикстура: моки холодной сборки не записаны'; return; }
  mk_run rm -rf "$E/cache/catalyst-tweakcc/$FAKE_SHA" || { instr_bad 'фикстура: запись пина не убрана'; return; }
  local w="$E/wrap.sh"
  build_cold_wrap "$w" "" "$SCRIPT" || { bad "T51 извлечение отказало"; return; }
  cold_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T51 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local root51
  root51=$(ti_var TI_ROOT) || { bad 'T51 ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT'; return; }
  if [[ -n "$root51" ]]; then bad 'T51 изоляция включилась без --target'; return; fi
  [[ -f "$E/cache/catalyst-tweakcc/$FAKE_SHA/dist/index.mjs" ]] \
    || { bad 'T51 РЕГРЕССИЯ update: запись не собрана в общем кэше'; return; }
  [[ -f "$E/home/.npm/_cacache/ti-marker" ]] \
    || { bad 'T51 РЕГРЕССИЯ update: перенаправление протекло в update-ветку'; return; }
  ok 'T51 update без --target: сборка в общем кэше, перенаправлений нет'
}

# T52: составленный gate settings JSON -- выключатель регистрации глубинных
# ссылок на ВЕРХНЕМ уровне, render (env прибора) и trust не ослаблены, HOME
# фикстуры не тронут
t52() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T52 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local w="$E/gate-wrap.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' &&
    printf 'E=%q\n' "$E" &&
    printf 'export HOME=%q\n' "$E/home" &&
    printf 'export TMPDIR=%q\n' "$E/tmp" &&
    printf 'GATE_HOME=%q\n' "$E/gate-home" &&
    printf 'mkdir -p "$GATE_HOME/cfg" "$GATE_HOME/proj"\n'
  } > "$w" || { instr_bad 'фикстура: обёртка gate не записана'; return; }
  extract "$SCRIPT" "^python3 - \"\\\$GATE_HOME\" <<'PYSEED'\$" '^PYSEED$' 1 >> "$w" \
    || { bad "T52 извлечение отказало"; return; }
  mk_append "$w" 'echo WIRE_DONE' || { instr_bad 'фикстура: хвост обёртки gate не дописан'; return; }
  snap_to "$E/home" "$E/snap.home.A" || { instr_bad 'снимок snap.home.A HOME не снят'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T52 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local py_rc=0
  python3 - "$E/gate-home" <<'PYGATE' || py_rc=$?
import json, os, sys
home = sys.argv[1]
cfg = os.path.join(home, "cfg")
settings = json.load(open(os.path.join(cfg, "settings.json")))
assert settings.get("disableDeepLinkRegistration") == "disable", \
    "нет верхнеуровневого disableDeepLinkRegistration=disable: %r" % settings.get("disableDeepLinkRegistration")
assert settings.get("model") == "gate-offline-model", "model изменён"
env = settings.get("env", {})
for k, v in {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:9",
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
}.items():
    assert env.get(k) == v, "ослаблен gate render: env[%s]=%r" % (k, env.get(k))
cc = json.load(open(os.path.join(cfg, ".claude.json")))
assert cc.get("hasCompletedOnboarding") is True, "onboarding слетел"
proj = os.path.realpath(os.path.join(home, "proj"))
assert cc["projects"][proj]["hasTrustDialogAccepted"] is True, "trust слетел"
PYGATE
  if [[ $py_rc -ne 0 ]]; then bad 'T52 состав gate settings расходится (assert выше)'; return; fi
  snap_to "$E/home" "$E/snap.home.B" || { instr_bad 'снимок snap.home.B HOME не снят'; return; }
  local ch52=0
  changed "$E/snap.home.A" "$E/snap.home.B" || ch52=$?
  if [[ $ch52 -eq 2 ]]; then bad 'T52 ПРИБОР НЕДОСТУПЕН: отказ diff снимков HOME'; return; fi
  if [[ $ch52 -eq 0 ]]; then bad 'T52 PYSEED написал в HOME фикстуры'; return; fi
  ok 'T52 gate settings: выключатель deep-link сверху, render/trust не ослаблены, HOME чист'
}

# T53: мутант «снятие gate-settings выключателя» -- ключа нет, регистрация
# вернулась бы в настоящий HOME запускаемого образа
t53() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T53 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local mut="$E/mut-gate.sh"
  mutate_one "$SCRIPT" "$mut" '^        # \[559-fix4\] CONSTRAINT: выключатель регистрации' \
    '^        "disableDeepLinkRegistration": "disable",$' '        "disableDeepLinkRegistration_MUTANT": "disable",' \
    || { bad 'T53 мутация не заложена: выключателя в PYSEED нет'; return; }
  bash -n "$mut" || { bad 'T53 мутант не парсится'; return; }
  local script_save="$SCRIPT" script_mut="$mut"
  SCRIPT="$mut"
  local w="$E/gate-wrap.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' &&
    printf 'E=%q\n' "$E" &&
    printf 'export HOME=%q\n' "$E/home" &&
    printf 'export TMPDIR=%q\n' "$E/tmp" &&
    printf 'GATE_HOME=%q\n' "$E/gate-home" &&
    printf 'mkdir -p "$GATE_HOME/cfg" "$GATE_HOME/proj"\n'
  } > "$w" || { SCRIPT="$script_save"; instr_bad 'фикстура: обёртка gate не записана'; return; }
  extract "$SCRIPT" "^python3 - \"\\\$GATE_HOME\" <<'PYSEED'\$" '^PYSEED$' 1 >> "$w" \
    || { SCRIPT="$script_save"; bad "T53 извлечение отказало"; return; }
  SCRIPT="$script_save"
  mk_append "$w" 'echo WIRE_DONE' || { instr_bad 'фикстура: хвост обёртки gate не дописан'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T53 обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  # CONSTRAINT: 0 -- ключ на месте, 1 -- ключа нет в ПРОЧИТАННОМ seed (model
  # seed на месте), 3 -- settings.json не прочитан/не тот seed: ПУСТО != НОЛЬ,
  # нечитаемый файл не читается «ключа нет»; stderr -- в лог зуба
  local py53=0
  python3 -c 'import json,sys
try:
    s = json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write("ПРИБОР НЕДОСТУПЕН: settings.json gate не прочитан: %s\n" % e); sys.exit(3)
if not isinstance(s, dict) or s.get("model") != "gate-offline-model":
    sys.stderr.write("ПРИБОР НЕДОСТУПЕН: settings.json gate -- не seed PYSEED\n"); sys.exit(3)
sys.exit(0 if s.get("disableDeepLinkRegistration") == "disable" else 1)' \
      "$E/gate-home/cfg/settings.json" || py53=$?
  if [[ $py53 -eq 0 ]]; then
    bad 'T53 ВАКУУМНАЯ ЗЕЛЕНЬ: выключатель жив при снятом ключе'
    return
  fi
  if [[ $py53 -ne 1 ]]; then instr_bad "settings.json gate не измерен (rc=$py53)"; return; fi
  ok 'T53 мутант снятия gate-выключателя краснеет предметно (ключа нет)'
}

# T54: [559-fix5] оба варианта CLAUDE_PATCH_SKIP_KIT_BENCH исполняют ПОДЛИННЫЙ
# блок стендов кита (4599-4706) ВМЕСТЕ с блоком раскатки (4708-4799): стенды --
# с изолированными моками трёх инструментов; при skip в логе «ПРОПУЩЕНЫ» и
# стенды не званы, без skip -- три имени и счёт 3. Сообщение target-ветки
# утверждает ТОЛЬКО неизмеренность раскатки живого дома и отсылает к статусу
# стендов отдельным блоком; вырезание блока стендов краснит зуб.
t54() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T54 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_bench_mocks "$E/kit-mock" || { instr_bad 'фикстура: моки стендов не записаны'; return; }
  local w="$E/kit-mock/stage.sh"
  build_bench_rollout_wrap "$w" "$E/img/fake-target" "$SCRIPT" || { bad "T54 извлечение отказало"; return; }
  local variant calls nm
  for variant in skip normal; do
    mk_run rm -f "$E/obs/bench.calls" || { instr_bad "фикстура: перечень вызовов стендов не сброшен ($variant)"; return; }
    if [[ "$variant" == skip ]]; then
      WR_RC=0
      WR_OUT=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_LOCAL -u TWEAKCC_CONFIG_DIR \
                 -u CATALYST_TWEAKCC_CACHE -u XDG_CONFIG_HOME \
                 -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
                 CLAUDE_PATCH_SKIP_KIT_BENCH=1 bash "$w" 2>&1) || WR_RC=$?
    else
      wrap_run "$w"
    fi
    if [[ $WR_RC -ne 0 ]]; then bad "T54 ($variant) обёртка rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
    if [[ "$WR_OUT" != *"РАСКАТКА ЖИВОГО ДОМА НЕ ИЗМЕРЯЛАСЬ В STAGING"* ]]; then
      bad "T54 ($variant) честное сообщение об неизмеренной раскатке не напечатано"
      return
    fi
    if [[ "$WR_OUT" == *"уже отработали"* ]]; then
      bad "T54 ($variant) сообщение утверждает отработавшие стенды (ложь при skip-ручке)"
      return
    fi
    if [[ "$WR_OUT" != *"стенд"* || "$WR_OUT" != *"отдельным блоком выше"* ]]; then
      bad "T54 ($variant) сообщение не отсылает к статусу стендов отдельной веткой"
      return
    fi
    calls=0
    if [[ -f "$E/obs/bench.calls" ]]; then
      # CONSTRAINT: отсутствие файла наблюдателя -- штатное «вызова не было»
      # (контракт skip-ручки); существующий, но нечитаемый/сломанный -- отказ
      # прибора, а не ноль
      calls=$(count_uniq_lines "$E/obs/bench.calls") \
        || { bad "T54 ($variant) ПРИБОР НЕДОСТУПЕН: отказ sort/grep перечня вызовов стендов"; return; }
    fi
    if [[ "$variant" == skip ]]; then
      if [[ "$WR_OUT" != *"ПРОПУЩЕНЫ"* ]]; then bad 'T54 (skip) объявление пропуска стендов не напечатано'; return; fi
      if [[ "$calls" != "0" ]]; then bad "T54 (skip) стенды вызваны при skip-ручке (различимых: $calls)"; return; fi
    else
      if [[ "$WR_OUT" == *"ПРОПУЩЕНЫ"* ]]; then bad 'T54 (normal) стенды объявлены пропущенными без ручки'; return; fi
      if [[ "$calls" != "3" ]]; then bad "T54 (normal) различных стендов $calls, ждали 3"; return; fi
      for nm in "Стенд инструментов судьи" "Стенд моделей и цен" "Стенд синхронизации проб"; do
        [[ "$WR_OUT" == *"==> $nm"* ]] || { bad "T54 (normal) заголовок стенда не напечатан: $nm"; return; }
      done
    fi
  done
  # мутант «блок стендов вырезан из target-ветки»: ветка always-skip -- БЕЗ
  # ручки объявляет пропуск и не зовёт стенды; нормальный вариант зуба краснеет
  mk_env || { bad 'T54 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_bench_mocks "$E/kit-mock" || { instr_bad 'фикстура: моки стендов мутанта не записаны'; return; }
  local mut="$E/mut-benchcut.sh"
  mutate_one "$SCRIPT" "$mut" '^__kit_bench_ran=0$' \
    '^if \[\[ "\$\{CLAUDE_PATCH_SKIP_KIT_BENCH:-0\}" == "1" \]\]; then$' 'if true; then' \
    || { bad 'T54 мутация не заложена: ветки стендов на дереве нет'; return; }
  bash -n "$mut" || { bad 'T54 мутант не парсится'; return; }
  w="$E/kit-mock/stage.sh"
  build_bench_rollout_wrap "$w" "$E/img/fake-target" "$mut" || { bad "T54 извлечение отказало (мутант)"; return; }
  mk_run rm -f "$E/obs/bench.calls" || { instr_bad 'фикстура: перечень вызовов стендов мутанта не сброшен'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T54 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  calls=0
  if [[ -f "$E/obs/bench.calls" ]]; then
    calls=$(count_uniq_lines "$E/obs/bench.calls") \
      || { bad 'T54 (мутант) ПРИБОР НЕДОСТУПЕН: отказ sort/grep перечня вызовов стендов'; return; }
  fi
  if [[ "$calls" != "0" || "$WR_OUT" != *"ПРОПУЩЕНЫ"* ]]; then
    bad 'T54 ВАКУУМНАЯ ЗЕЛЕНЬ: вырезание блока стендов не поймано (стенды звались/пропуска не было)'
    return
  fi
  ok 'T54 стенды+раскатка подлинным блоком: skip=ПРОПУЩЕНЫ/0, normal=3 имени, вырезание краснеет'
}

# T55: мутант «ложная строка при skipped benches» -- прежнее «уже отработали»
t55() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T55 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  local mut="$E/mut-rollmsg.sh"
  mutate_one "$SCRIPT" "$mut" '^# CONSTRAINT: строка НЕ утверждает, что стенды кита отработали' \
    '^echo "РАСКАТКА ЖИВОГО ДОМА НЕ ИЗМЕРЯЛАСЬ В STAGING' \
    'echo "РАСКАТКА ЖИВОГО ДОМА НЕ ИЗМЕРЯЛАСЬ В STAGING (--target): раскатка не исполнялась, дом судьи не тронут; независимые проверки канона кита выше уже отработали"' \
    || { bad 'T55 мутация не заложена: честной строки на дереве нет'; return; }
  bash -n "$mut" || { bad 'T55 мутант не парсится'; return; }
  local w="$E/kit-mock/stage.sh"
  build_probes_wrap "$w" "$E/img/fake-target" "$mut" || { bad "T55 извлечение отказало"; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T55 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"уже отработали"* ]]; then
    bad 'T55 ВАКУУМНАЯ ЗЕЛЕНЬ: ложное «уже отработали» не поймано'
    return
  fi
  ok 'T55 мутант ложной строки краснеет предметно (стенды объявлены отработавшими)'
}

# T56: мутант «~other» -- слэс границы дома снят: склейка $HOME+other/dir
t56() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T56 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T56 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/home/other/dir" || { instr_bad 'фикстура: ~other/dir не создан'; return; }
  mk_put "$E/home/other/dir/config.json" '{"ccVersion":"2.1.283","patchOptions":{"otherhome":true}}\n' \
    || { instr_bad 'фикстура: config.json ~other/dir не записан'; return; }
  local mut="$E/mut-tilde.sh"
  mutate_one "$HELPER" "$mut" '^      # \[559-fix4\] CONSTRAINT: слэс границы дома' \
    '^      \[\[ "\$src" == /\* \]\] \|\| src="/\$src"$' '      true' \
    || { bad 'T56 мутация не заложена: слэса границы на дереве нет'; return; }
  bash -n "$mut" || { bad 'T56 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save"; bad "T56 извлечение отказало"; return; }
  HELPER="$helper_save"
  mk_sed "$w" "s|^export TMPDIR=.*|&\nexport TWEAKCC_CONFIG_DIR='~other/dir'|" \
    "export TWEAKCC_CONFIG_DIR='~other/dir'" || { instr_bad 'фикстура: TWEAKCC_CONFIG_DIR обёртки не подставлен'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T56 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"homeother"* ]]; then
    bad 'T56 ВАКУУМНАЯ ЗЕЛЕНЬ: склейка границы дома не поймана'
    return
  fi
  ok 'T56 мутант ~other краснеет предметно (граница дома склеена)'
}

# T57: [559-fix5] предзамковая проверка НАСТОЯЩЕГО claude-patch-all.sh --target:
# TMPDIR/CLAUDE_PATCH_LOCK в защищённом живом доме и общем кэше (включая предков
# $HOME/.cache и $HOME, путь под симлинком и живой XDG-родитель) -- ранний rc=6
# ДО открытия замка: ни mktemp, ни CLI, ни записи; байты/mtime/inode защищённого
# дерева (включая сам замок) не меняются.
# [559-fix6] CONSTRAINT: родители всех случаев создаются ДО первого прогона --
# отказ у несуществующего родителя (ENOENT) не является предметной ранней
# записью; post-snapshot снимается у КАЖДОГО случая ДО любых вердиктов по rc
# (неверный rc не освобождает от измерения дерева); весь массив проходится
# ЦЕЛИКОМ и сводится в один итоговый вердикт -- первый удачный случай не
# закрывает остальные. Custom-source прямой и symlink-вариант проверяет T63.
t57() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T57 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/local-unpacker.mjs" '#!/usr/bin/env node\n// synthetic local build\n' \
    || { instr_bad 'фикстура: local-unpacker.mjs не записан'; return; }
  mk_run mkdir -p "$E/home/.cache/catalyst-tweakcc" "$E/home/.cache/pnpm/x" "$E/xdglive" \
           "$E/home/.claude/x" "$E/home/.npm/x" "$E/home/.local/share/pnpm/x" \
           "$E/home/.local/state/pnpm/x" "$E/home/.local/share/claude/versions" \
    || { instr_bad 'фикстура: защищённые дома не созданы'; return; }
  mk_put "$E/home/.cache/catalyst-tweakcc/sentinel.txt" 'synthetic-cache-sentinel\n' \
    || { instr_bad 'фикстура: sentinel общего кэша не записан'; return; }
  mk_run ln -s "$E/home/.cache" "$E/link-to-cache" || { instr_bad 'фикстура: ссылка на кэш не заложена'; return; }
  # CONSTRAINT: контроль с inode -- замок мог бы создаться и не изменить байты
  # существующих файлов; снимок snap() inode не несёт (isnap_to несёт, с корнем)
  local uid57
  uid57="$(id -u)" || { instr_bad 'отказ id -u'; return; }
  local spec key val msg_pat rc=0 out t57_fail='' ch57=0 chm57=0
  # первый случай -- СУЩЕСТВУЮЩИЙ .cache (живое состояние целиком), затем остальные
  local -a cases=(
    "tmp_cache|TMPDIR=$E/home/.cache|защищённого живого дома"
    "tmp_claude|TMPDIR=$E/home/.claude/x|защищённого живого дома"
    "tmp_versions|TMPDIR=$E/home/.local/share/claude/versions|защищённого живого дома"
    "lock_versions|CLAUDE_PATCH_LOCK=$E/home/.local/share/claude/versions/ti.lock|путь замка"
    "tmp_cachepnpm|TMPDIR=$E/home/.cache/pnpm/x|защищённого живого дома"
    "tmp_symlink|TMPDIR=$E/link-to-cache|защищённого живого дома"
    "tmp_home|TMPDIR=$E/home|предок защищённого живого дома"
    "tmp_local|TMPDIR=$E/home/.local|предок защищённого живого дома"
    "lock_cache|CLAUDE_PATCH_LOCK=$E/home/.cache/catalyst-tweakcc/ti.lock|путь замка"
    "lock_cache2|CLAUDE_PATCH_LOCK=$E/home/.cache/x.lock|путь замка"
    "lock_symlink|CLAUDE_PATCH_LOCK=$E/link-to-cache/ti-sym.lock|путь замка"
    "lock_ancestor|CLAUDE_PATCH_LOCK=$E/home/.local|путь замка"
    "lock_ancestor2|CLAUDE_PATCH_LOCK=$E/home/.cache|путь замка"
    "xdg_parent|XDG_CONFIG_HOME=$E/xdglive TMPDIR=$E/xdglive|живой XDG-родитель"
    "cache_root|CATALYST_TWEAKCC_CACHE=/|идентичность предка"
  )
  for spec in "${cases[@]}"; do
    key="${spec%%|*}"; val="${spec#*|}"; val="${val%|*}"; msg_pat="${spec##*|}"
    local -a assignments=("$val")
    if [[ "$key" == xdg_parent ]]; then
      assignments=("XDG_CONFIG_HOME=$E/xdglive" "TMPDIR=$E/xdglive")
    fi
    snap_to "$E/home" "$E/snap.A" || { instr_bad "снимок snap.A HOME не снят ($key)"; return; }
    isnap_to "$E/home" "$E/isnap.A" || { instr_bad "inode-снимок isnap.A HOME не снят ($key)"; return; }
    # [559-fix7] CONSTRAINT: случай xdg_parent пишет именно в $E/xdglive -- rc и
    # предметный текст не доказывают отсутствия ранней записи; снимок ДО/ПОСЛЕ
    # живого XDG-дома (байты/mtime + inode) снимается у КАЖДОГО случая ДО
    # вердиктов по rc
    snap_to "$E/xdglive" "$E/snap.xdg.A" || { instr_bad "снимок snap.xdg.A не снят ($key)"; return; }
    isnap_to "$E/xdglive" "$E/isnap.xdg.A" || { instr_bad "inode-снимок isnap.xdg.A не снят ($key)"; return; }
    rc=0
    out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
            -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
            -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
            HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
            CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
            "${assignments[@]}" timeout 120 bash "$SCRIPT" --target "$E/img/fake-target" 2>&1) || rc=$?
    # [559-fix6] post-snapshot ДО вердиктов: даже неверный rc измеряется
    snap_to "$E/home" "$E/snap.B" || { instr_bad "снимок snap.B HOME не снят ($key)"; return; }
    isnap_to "$E/home" "$E/isnap.B" || { instr_bad "inode-снимок isnap.B HOME не снят ($key)"; return; }
    snap_to "$E/xdglive" "$E/snap.xdg.B" || { instr_bad "снимок snap.xdg.B не снят ($key)"; return; }
    isnap_to "$E/xdglive" "$E/isnap.xdg.B" || { instr_bad "inode-снимок isnap.xdg.B не снят ($key)"; return; }
    [[ $rc -eq 6 ]] || t57_fail="$t57_fail $key:rc=$rc"
    [[ "$out" == *"$msg_pat"* ]] || t57_fail="$t57_fail $key:без-предмета"
    ch57=0
    changed "$E/snap.A" "$E/snap.B" || ch57=$?
    [[ $ch57 -eq 2 ]] && t57_fail="$t57_fail $key:diff-отказ"
    [[ $ch57 -eq 0 ]] && t57_fail="$t57_fail $key:байты/mtime"
    cmp -s "$E/isnap.A" "$E/isnap.B" || t57_fail="$t57_fail $key:inode"
    # [559-fix7] ранняя запись в XDG -- самостоятельный вердикт случая: снимок
    # xdglive (содержимое, mtime, inode, появившийся замок/temp)
    ch57=0
    changed "$E/snap.xdg.A" "$E/snap.xdg.B" || ch57=$?
    [[ $ch57 -eq 2 ]] && t57_fail="$t57_fail $key:xdg-diff-отказ"
    [[ $ch57 -eq 0 ]] && t57_fail="$t57_fail $key:xdg-запись"
    cmp -s "$E/isnap.xdg.A" "$E/isnap.xdg.B" || t57_fail="$t57_fail $key:xdg-inode"
  done
  # [559-fix6] весь массив пройден -- единый итоговый вердикт
  if [[ -n "$t57_fail" ]]; then bad "T57 ранние отказы разошлись:$t57_fail"; return; fi
  local leftovers
  leftovers="$(find "$E/home" "$E/xdglive" \( -name 'claude-patch-all.*.lock' -o -name 'ti.lock' -o -name 'x.lock' -o -name 'ti-sym.lock' -o -name 'cc-target-isolation.*' \) -print)" \
    || { bad 'T57 ПРИБОР НЕДОСТУПЕН: отказ find остатков замка/temp'; return; }
  [[ -z "$leftovers" ]] || { bad "T57 ранний отказ оставил файл замка: $leftovers"; return; }
  # [559-fix8] контроль чувствительности корня XDG: однофакторный сдвиг ТОЛЬКО
  # mtime_ns самого $E/xdglive (детей нет) обязан менять снимок; подмена корня
  # новым пустым каталогом (другой inode, те же дети) -- inode-снимок
  snap_to "$E/xdglive" "$E/snap.xdg.root.A" || { instr_bad 'снимок snap.xdg.root.A не снят'; return; }
  local py57=0
  python3 - "$E/xdglive" <<'PYROOT57' || py57=$?
import os, sys
st = os.stat(sys.argv[1])
os.utime(sys.argv[1], ns=(st.st_atime_ns, st.st_mtime_ns + 1))
PYROOT57
  [[ $py57 -eq 0 ]] || { instr_bad 'сдвиг mtime корня XDG не заложен'; return; }
  snap_to "$E/xdglive" "$E/snap.xdg.root.B" || { instr_bad 'снимок snap.xdg.root.B не снят'; return; }
  ch57=0
  changed "$E/snap.xdg.root.A" "$E/snap.xdg.root.B" || ch57=$?
  if [[ $ch57 -eq 2 ]]; then instr_bad 'отказ diff снимков корня XDG'; return; fi
  if [[ $ch57 -eq 1 ]]; then bad 'T57 (контроль корня) сдвиг mtime_ns корня XDG при неизменных детях не виден снимку'; return; fi
  isnap_to "$E/xdglive" "$E/isnap.xdg.root.A" || { instr_bad 'inode-снимок isnap.xdg.root.A не снят'; return; }
  mv "$E/xdglive" "$E/xdglive.old" && mkdir "$E/xdglive" \
    || { instr_bad 'подмена корня XDG не заложена'; return; }
  isnap_to "$E/xdglive" "$E/isnap.xdg.root.B" || { instr_bad 'inode-снимок isnap.xdg.root.B не снят'; return; }
  if cmp -s "$E/isnap.xdg.root.A" "$E/isnap.xdg.root.B"; then
    bad 'T57 (контроль корня) подмена корня XDG новым inode не видна inode-снимку'
    return
  fi
  # [559-fix7] мутационный контроль снимка XDG: снята ТОЛЬКО защита XDG-родителя
  # (exit 6 у её FATAL-строки) -- намеренная ранняя запись в $E/xdglive ОБЯЗАНА
  # краснеть именно снимком XDG (замок/temp в живом XDG-доме), не rc: run
  # останавливается у двери образа с rc!=6, и только снимок держит измерение
  local mut57="$E/mut-xdg.sh"
  mutate_one "$HELPER" "$mut57" '^[ \t]*echo "FATAL: изоляция target: \$2 \(\$1\) -- живой XDG-родитель' \
    '^          exit 6$' '          true' \
    || { bad 'T57 (XDG-мутант) мутация не заложена: защиты XDG-родителя на дереве нет'; return; }
  bash -n "$mut57" || { bad 'T57 (XDG-мутант) не парсится'; return; }
  mk_run mkdir -p "$E/mut-kit57/tools" || { instr_bad 'фикстура: каталог мутантного кита не создан'; return; }
  mk_run cp "$mut57" "$E/mut-kit57/tools/target-isolation.sh" || { instr_bad 'фикстура: мутант helper не скопирован'; return; }
  mk_run cp "$SCRIPT" "$E/mut-kit57/claude-patch-all.sh" || { instr_bad 'фикстура: конвейер мутантного кита не скопирован'; return; }
  local f57 b57
  for f57 in "$KIT"/tools/*; do
    b57="$(basename "$f57")" || { bad 'T57 ПРИБОР НЕДОСТУПЕН: отказ basename инструментов кита'; return; }
    [[ "$b57" == target-isolation.sh ]] && continue
    mk_run ln -s "$f57" "$E/mut-kit57/tools/$b57" || { instr_bad "фикстура: ссылка инструмента не заложена ($b57)"; return; }
  done
  snap_to "$E/xdglive" "$E/snap.xdg.mut.A" || { instr_bad 'снимок snap.xdg.mut.A не снят'; return; }
  isnap_to "$E/xdglive" "$E/isnap.xdg.mut.A" || { instr_bad 'inode-снимок isnap.xdg.mut.A не снят'; return; }
  rc=0
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          XDG_CONFIG_HOME="$E/xdglive" TMPDIR="$E/xdglive" \
          timeout 150 bash "$E/mut-kit57/claude-patch-all.sh" --target "$E/img/fake-target" 2>&1) || rc=$?
  snap_to "$E/xdglive" "$E/snap.xdg.mut.B" || { instr_bad 'снимок snap.xdg.mut.B не снят'; return; }
  isnap_to "$E/xdglive" "$E/isnap.xdg.mut.B" || { instr_bad 'inode-снимок isnap.xdg.mut.B не снят'; return; }
  chm57=0
  changed "$E/snap.xdg.mut.A" "$E/snap.xdg.mut.B" || chm57=$?
  if [[ $chm57 -eq 2 ]]; then bad 'T57 (XDG-мутант) ПРИБОР НЕДОСТУПЕН: отказ diff снимков XDG'; return; fi
  # CONSTRAINT: красный итог -- отсутствие И байтового/mtime, И inode изменения
  if [[ $chm57 -ne 0 ]] && cmp -s "$E/isnap.xdg.mut.A" "$E/isnap.xdg.mut.B" ; then
    bad 'T57 (XDG-мутант) ВАКУУМНАЯ ЗЕЛЕНЬ: снятие защиты XDG-родителя не дало ранней записи в живой XDG-дом (замка/temp нет)'
    return
  fi
  # [559-fix8] предметный свидетель: сам файл замка в живом XDG-доме
  if [[ ! -e "$E/xdglive/claude-patch-all.$uid57.lock" ]]; then
    bad 'T57 (XDG-мутант) снимок XDG изменён, но замка claude-patch-all.<uid>.lock в живом XDG-доме нет -- причина не предметная'
    return
  fi
  if [[ $rc -eq 6 && "$out" == *'живой XDG-родитель'* ]]; then
    bad 'T57 (XDG-мутант) прогон отказал rc6 по-прежнему -- мутация не подействовала'
    return
  fi
  ok 'T57 предзамковая проверка: rc=6 по предмету во всех случаях массива (включая защищённый дом /), деревья HOME и XDG нетронуты (байты/mtime/inode, корень включён); сдвиг корня XDG виден снимкам; снятие защиты XDG-родителя краснеет замком в XDG'
}

# T58: [559-fix5] контроли предзамковой проверки: обычный TMPDIR, приватный
# подкаталог HOME ($HOME/staging-tmp), симлинк на безопасный каталог и явный
# безопасный CLAUDE_PATCH_LOCK НЕ отказываются: прогон проходит мимо
# предзамковой проверки, открывает замок в разрешённом месте и умирает у
# двери поддельного образа («не нативный образ») -- не у изоляции
t58() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T58 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/local-unpacker.mjs" '#!/usr/bin/env node\n// synthetic local build\n' \
    || { instr_bad 'фикстура: local-unpacker.mjs не записан'; return; }
  mk_run mkdir -p "$E/home/staging-tmp" "$E/tmp2" "$E/lock" "$E/home/.local/share/claude-neighbor" || { instr_bad 'фикстура: каталоги контролей не созданы'; return; }
  mk_run ln -s "$E/tmp2" "$E/link-to-tmp" || { instr_bad 'фикстура: ссылка на безопасный tmp не заложена'; return; }
  local uid
  uid="$(id -u)" || { bad 'T58 ПРИБОР НЕДОСТУПЕН: отказ id -u'; return; }
  local spec key val lockpath rc=0 out
  local -a cases=(
    "tmp_normal|TMPDIR=$E/tmp|$E/tmp/claude-patch-all.$uid.lock"
    "tmp_privsub|TMPDIR=$E/home/staging-tmp|$E/home/staging-tmp/claude-patch-all.$uid.lock"
    "tmp_versions_neighbor|TMPDIR=$E/home/.local/share/claude-neighbor|$E/home/.local/share/claude-neighbor/claude-patch-all.$uid.lock"
    "tmp_symlink_safe|TMPDIR=$E/link-to-tmp|$E/link-to-tmp/claude-patch-all.$uid.lock"
    "lock_safe|CLAUDE_PATCH_LOCK=$E/lock/t58.lock|$E/lock/t58.lock"
  )
  for spec in "${cases[@]}"; do
    key="${spec%%|*}"; val="${spec#*|}"; val="${val%|*}"; lockpath="${spec##*|}"
    rc=0
    out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
            -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
            -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
            HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
            CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
            "$val" timeout 120 bash "$SCRIPT" --target "$E/img/fake-target" 2>&1) || rc=$?
    if [[ $rc -eq 6 ]]; then
      bad "T58 ($key) предзамковая проверка отказала разрешённому случаю (rc=6) :: ${out%%$'\n'*}"
      return
    fi
    if [[ "$out" == *"FATAL: изоляция target"* ]]; then
      bad "T58 ($key) изоляция отказала разрешённому случаю :: ${out%%$'\n'*}"
      return
    fi
    if [[ "$out" != *"не нативный образ"* ]]; then
      bad "T58 ($key) прогон не дошёл до двери образа (нет свидетеля «не нативный образ»; rc=$rc) :: ${out%%$'\n'*}"
      return
    fi
    if [[ ! -f "$lockpath" ]]; then
      bad "T58 ($key) замок не открыт в разрешённом месте: $lockpath"
      return
    fi
  done
  ok 'T58 контроли: обычный TMPDIR/приватный подкаталог HOME/симлинк/безопасный замок проходят до двери образа'
}

# T59: [559-fix5] мутант «предзамковая проверка снята» -- замок СРАЗУ создаётся
# в общем кэше ДО позднего отказа активации: ранняя запись поймана предметно,
# не только по rc.
# [559-fix6] CONSTRAINT: сперва BASELINE -- прямой реальный прогон с
# СУЩЕСТВУЮЩИМ родителем ($E/home/.cache): нарушение инварианта ранней записи
# фиксируется само по себе, без закладки мутанта (отсутствие иглы на старом
# дереве -- не предметный RED); мутационный контроль отделён ниже
t59() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T59 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/local-unpacker.mjs" '#!/usr/bin/env node\n// synthetic local build\n' \
    || { instr_bad 'фикстура: local-unpacker.mjs не записан'; return; }
  mk_run mkdir -p "$E/home/.cache" || { instr_bad 'фикстура: общий кэш HOME не создан'; return; }
  local uid
  uid="$(id -u)" || { bad 'T59 ПРИБОР НЕДОСТУПЕН: отказ id -u'; return; }
  # --- baseline: прямой прогон, родитель существует -- ранней записи быть не должно
  snap_to "$E/home/.cache" "$E/snap.cache.A" || { instr_bad 'снимок snap.cache.A общего кэша HOME не снят'; return; }
  local rc=0 out
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/home/.cache" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          timeout 150 bash "$SCRIPT" --target "$E/img/fake-target" 2>&1) || rc=$?
  snap_to "$E/home/.cache" "$E/snap.cache.B" || { instr_bad 'снимок snap.cache.B общего кэша HOME не снят'; return; }
  if [[ -e "$E/home/.cache/claude-patch-all.$uid.lock" ]]; then
    bad 'T59 (baseline) ПИСАТЕЛЬ: ранняя запись замка в общий кэш в прямом прогоне'
    return
  fi
  local ch59=0
  changed "$E/snap.cache.A" "$E/snap.cache.B" || ch59=$?
  if [[ $ch59 -eq 2 ]]; then bad 'T59 (baseline) ПРИБОР НЕДОСТУПЕН: отказ diff снимков кэша'; return; fi
  if [[ $ch59 -eq 0 ]]; then
    bad 'T59 (baseline) прямой прогон изменил состояние общего кэша до активации'
    return
  fi
  if [[ $rc -ne 6 ]]; then
    bad "T59 (baseline) прямой прогон с TMPDIR=.cache ответил rc=$rc (ждали 6) :: ${out%%$'\n'*}"
    return
  fi
  # --- мутационный контроль: снятие предзамкового вызова -- ранняя запись ловится
  # CONSTRAINT: мутант обязан видеть tools кита ($HERE обязательной проверки
  # helper-файла) -- иначе он умирает ДО замка кодом 6 «машинерия», и ранняя
  # запись замка не происходит; симлинк не пишет в кит
  mk_run ln -s "$KIT/tools" "$E/tools" || { instr_bad 'фикстура: ссылка на tools кита не заложена'; return; }
  local mut="$E/mut-noprelock.sh"
  # [559-fix7] якорь -- условная форма вызова: прежняя одиночная строка
  # заменена условием, мутация снимает вызов preflight целиком (if true),
  # раняя запись замка в общий кэш возвращается
  mutate_one "$SCRIPT" "$mut" '^  # \[559-fix5\] ворота: предзамковая проверка' \
    '^  if target_isolation_preflight "\$__lock"; then$' '  if true; then' \
    || { bad 'T59 мутация не заложена: предзамковой проверки на дереве нет'; return; }
  bash -n "$mut" || { bad 'T59 мутант не парсится'; return; }
  rc=0
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/home/.cache" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          timeout 150 bash "$mut" --target "$E/img/fake-target" 2>&1) || rc=$?
  if [[ ! -f "$E/home/.cache/claude-patch-all.$uid.lock" ]]; then
    bad 'T59 (мутант) ВАКУУМНАЯ ЗЕЛЕНЬ: ранняя запись замка в общий кэш не поймана (файла нет)'
    return
  fi
  if [[ $rc -eq 0 ]]; then bad "T59 (мутант) прошёл зелёно (rc=0)"; return; fi
  ok 'T59 baseline: прямой прогон без ранней записи; мутант снятия предзамковой проверки краснеет по ранней записи (замок в общем кэше)'
}

# T60: [559-fix5] мутант «защита предка cache снята» -- перечень защищённых
# домов теряет cache-семейство: TMPDIR=$HOME/.cache (предок защищённых
# .cache/pnpm и .cache/catalyst-tweakcc) проходит и СОЗДАЁТ состояние в общем
# кэше -- ранняя запись поймана по созданию/изменению состояния cache
t60() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T60 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T60 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/home/.cache" || { instr_bad 'фикстура: общий кэш HOME не создан'; return; }
  mk_put "$E/home/.cache/sentinel.txt" 'synthetic-cache-sentinel\n' || { instr_bad 'фикстура: sentinel кэша не записан'; return; }
  local mut="$E/mut-cachefam.sh"
  mutate_one "$HELPER" "$mut" '^  for ti_prot in .*$' \
    '^    \[\[ -n "\$ti_prot" \]\] [|][|] continue$' \
    '    [[ -n "$ti_prot" ]] || continue; [[ "$ti_prot" != "$HOME/.cache" && "$ti_prot" != "$HOME/.cache/pnpm" && "$ti_prot" != "${CATALYST_TWEAKCC_CACHE:-$HOME/.cache/catalyst-tweakcc}" ]] || continue' \
    || { bad 'T60 мутация не заложена: перечня защищённых домов на дереве нет'; return; }
  bash -n "$mut" || { bad 'T60 мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mut"
  build_activation_wrap "$w" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save"; bad "T60 извлечение отказало"; return; }
  HELPER="$helper_save"
  wrap_export "$w" TMPDIR "$E/home/.cache" || { instr_bad 'фикстура: TMPDIR обёртки не подменён'; return; }
  wrap_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T60 мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local found60a
  found60a="$(find "$E/home/.cache" -maxdepth 1 -name 'cc-target-isolation.*' -print -quit)" \
    || { bad 'T60 (cache-семейство) ПРИБОР НЕДОСТУПЕН: отказ find temp в общем кэше'; return; }
  if [[ -z "$found60a" ]]; then
    bad 'T60 (cache-семейство) ВАКУУМНАЯ ЗЕЛЕНЬ: temp в общем кэше не создан -- снятие защиты не поймано'
    return
  fi
  # [559-fix6] вторая мутация: снята ТОЛЬКО ветка «предок защищённого дерева
  # внутри живого HOME» -- перечень ЦЕЛИКОМ (включая .cache); сценарий
  # TMPDIR=$HOME: temp проходит и создаёт состояние в КОРНЕ живого HOME.
  # CONSTRAINT: не утверждаем, что запись ушла именно в cache -- второй мутант
  # ловит отношение «предок», а не вложенность в cache
  mk_env || { bad 'T60 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_run mkdir -p "$E/home/.cache" || { instr_bad 'фикстура: общий кэш HOME не создан (предок)'; return; }
  mk_put "$E/home/.cache/sentinel.txt" 'synthetic-cache-sentinel\n' || { instr_bad 'фикстура: sentinel кэша не записан (предок)'; return; }
  local mut2="$E/mut-ancestor.sh"
  mutate_one "$HELPER" "$mut2" '^    if \[\[ "\$ti_prot_real" == "\$1"/\* \]\]; then$' \
    '^      if \[\[ "\$1" == "\$home_real" \|\| "\$1" == "\$home_real"/\* \]\]; then$' '      if false; then' \
    || { bad 'T60 (предок) мутация не заложена: ветки предка на дереве нет'; return; }
  bash -n "$mut2" || { bad 'T60 (предок) мутант не парсится'; return; }
  local w2="$E/wrap2.sh" helper_save2="$HELPER"
  HELPER="$mut2"
  build_activation_wrap "$w2" "$E/img/fake-target" "" "$SCRIPT" 0 || { HELPER="$helper_save2"; bad "T60 (предок) извлечение отказало"; return; }
  HELPER="$helper_save2"
  wrap_export "$w2" TMPDIR "$E/home" || { instr_bad 'фикстура: TMPDIR обёртки не подменён (предок)'; return; }
  wrap_run "$w2"
  if [[ $WR_RC -ne 0 ]]; then bad "T60 (предок) мутант rc=$WR_RC :: ${WR_OUT%%$'\n'*}"; return; fi
  local found60b
  found60b="$(find "$E/home" -maxdepth 1 -name 'cc-target-isolation.*' -print -quit)" \
    || { bad 'T60 (предок) ПРИБОР НЕДОСТУПЕН: отказ find temp в корне HOME'; return; }
  if [[ -z "$found60b" ]]; then
    bad 'T60 (предок) ВАКУУМНАЯ ЗЕЛЕНЬ: temp в корне живого HOME не создан -- снятие ветки предка не поймано'
    return
  fi
  ok 'T60 мутанты: изъятие cache-семейства -- состояние в общем кэше; снятие ветки предка -- состояние в корне живого HOME'
}

# T61: [559-fix5] стадия п.3: target-квитанция раскатки проходит ИМЕННО
# probes-rollout настоящего pipeline-stage-census.py; лог без квитанции и
# канон со снятой альтернативой краснят ИМЕННО probes-rollout.
# [559-fix6] CONSTRAINT: sweep-check потребляет ПОЛНЫЙ синтетический завершённый
# target-лог -- по одному ЯВНОМУ свидетелю на КАЖДУЮ exit-pinned always/cond-skip
# строку текущей таблицы; полноту фикстуры держит сам настоящий sweep-check
# (контроль D: дополнительный неизвестный exit-pin краснит полный лог, а не
# тихо игнорируется). Лог из одной квитанции не годится: API предполагает
# завершённый прогон, и его ответ на неполную фикстуру ничего не доказывает.
t61() {
  RAN=$((RAN + 1))
  local census_py="$KIT/tools/pipeline-stage-census.py" tsv="$KIT/tools/pipeline-stages.tsv"
  [[ -f "$census_py" && -f "$tsv" ]] || { bad 'T61 нет census/tsv канона стадий'; return; }
  mk_env || { bad 'T61 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  # ПОЛНЫЙ синтетический завершённый target-лог: свидетели всех exit-pinned
  # always/cond-skip строк таблицы (21), включая ГВАРД ЖИВОСТИ НА ДЕРЕВЕ: и
  # Подпись ПРОПУЩЕНА; probes-rollout закрыт target-квитанцией
  local full="$E/t61.full.log"
  # CONSTRAINT: весь лог -- ОДИН вызов printf: статус записи несёт каждую строку
  printf '%s\n' \
    '==> Разбор вклеиваемого кода: синтетический свидетель' \
    '==> Зубы якоря heredoc: синтетический свидетель' \
    '==> Разбор блока проверок: синтетический свидетель' \
    'РАСКАТКА ЖИВОГО ДОМА НЕ ИЗМЕРЯЛАСЬ В STAGING (--target): раскатка не исполнялась, дом судьи не тронут; о стендах кита -- их фактический статус напечатан отдельным блоком выше (в т.ч. пропуск по CLAUDE_PATCH_SKIP_KIT_BENCH=1)' \
    '==> Сверка чисел в доках: синтетический свидетель' \
    '==> Гейт наследования замка: синтетический свидетель' \
    '==> Перепись якорей таблицы гейта чисел: синтетический свидетель' \
    '==> Зубы гварда герметичности стендов: синтетический свидетель' \
    '==> Зубы гварда живости ручек: синтетический свидетель' \
    'ГВАРД ЖИВОСТИ НА ДЕРЕВЕ: синтетический свидетель' \
    '==> Пины опций встроенных модов: синтетический свидетель' \
    '==> Зубы гварда пинов опций: синтетический свидетель' \
    '==> Зубы изоляции --target: синтетический свидетель' \
    '==> Зубы окна шага 7: синтетический свидетель' \
    '==> Зубы пола проверок: синтетический свидетель' \
    '==> Перепись исполнителей инструментов: синтетический свидетель' \
    '==> Перепись стадий конвейера: синтетический свидетель' \
    '==> Ценз байткода изменённых модулей: синтетический свидетель' \
    '==> Подпись ПРОПУЩЕНА: синтетический свидетель' \
    '==> Зубы доставки TERM: синтетический свидетель' \
    '==> Гейт карты шагов: синтетический свидетель' \
    > "$full" || { instr_bad 'фикстура: полный синтетический лог не записан'; return; }
  local pyrc=0 refused=''
  # A: полный лог -- rc0 и ноль отсутствующих стадий
  python3 "$census_py" sweep-check --table "$tsv" --log "$full" > "$E/t61.A.out" 2>&1 || pyrc=$?
  if [[ $pyrc -ne 0 ]]; then
    bad "T61 (A) полный синтетический лог не прошёл sweep-check rc=$pyrc :: $(tr '\n' ';' < "$E/t61.A.out")"
    return
  fi
  # CONSTRAINT: `if grep -q` читал отказ чтения (rc2) как «ОТКАЗ-строк нет» --
  # ложная зелень (A); rc0 -- предмет, rc1 -- чисто, прочее -- ПРИБОР-метка
  local a61_rc=0
  grep -q 'ОТКАЗ' "$E/t61.A.out" || a61_rc=$?
  case "$a61_rc" in
    0) bad 'T61 (A) полный лог содержит ОТКАЗ-строки'; return ;;
    1) ;;
    *) bad 'T61 (A) ПРИБОР НЕДОСТУПЕН: отказ grep ОТКАЗ-строк'; return ;;
  esac
  # B: удалена ТОЛЬКО target-квитанция -- rc2 и РОВНО probes-rollout в отказах
  # rc grep -v: 0 -- строки остались (фикстура B), 1 -- лог опустел, 2 -- отказ; 1 и 2 -- отказ прибора
  grep -v 'РАСКАТКА ЖИВОГО ДОМА НЕ ИЗМЕРЯЛАСЬ В STAGING' "$full" > "$E/t61.B.log" \
    || { instr_bad 'фикстура: лог без квитанции (B) не записан'; return; }
  pyrc=0
  python3 "$census_py" sweep-check --table "$tsv" --log "$E/t61.B.log" > "$E/t61.B.out" 2>&1 || pyrc=$?
  if [[ $pyrc -ne 2 ]]; then bad "T61 (B) лог без квитанции ответил rc=$pyrc (ждали 2)"; return; fi
  # CONSTRAINT: счёт через count_matches -- валидный ноль отдаёт предметной
  # красноте ниже, отказ чтения/поиска -- собственная ПРИБОР-метка; `|| true`
  # превращал отказ прибора в предметное несовпадение (тот же класс в (C))
  refused=$(count_matches 'ОТКАЗ: стадия' "$E/t61.B.out") \
    || { bad 'T61 (B) ПРИБОР НЕДОСТУПЕН: отказ grep отказов стадий'; return; }
  if [[ "$refused" != "1" ]]; then bad "T61 (B) отказов стадий $refused, ждали РОВНО 1 :: $(grep 'ОТКАЗ: стадия' "$E/t61.B.out" | tr '\n' ';')"; return; fi
  grep -q "ОТКАЗ: стадия 'probes-rollout'" "$E/t61.B.out" \
    || { bad "T61 (B) единственный отказ -- не probes-rollout"; return; }
  # C: на той же ПОЛНОЙ фикстуре из TSV снята ТОЛЬКО новая TSV-альтернатива --
  # тот же единственный отказ (квитанция больше не проходит)
  local mut_tsv="$E/t61.tsv"
  pyrc=0
  python3 - "$tsv" "$mut_tsv" <<'PYMUT' || pyrc=$?
import sys
src, dst = sys.argv[1:3]
text = open(src, encoding='utf-8').read()
alt = '|РАСКАТКА ЖИВОГО ДОМА НЕ ИЗМЕРЯЛАСЬ В STAGING \\(--target\\)'
if text.count(alt) != 1:
    sys.stderr.write('альтернатива квитанции встречена %d раз (ждали 1)\n' % text.count(alt))
    raise SystemExit(2)
open(dst, 'w', encoding='utf-8').write(text.replace(alt, ''))
PYMUT
  if [[ $pyrc -ne 0 ]]; then bad "T61 (C) мутация канона не заложена (rc=$pyrc)"; return; fi
  pyrc=0
  python3 "$census_py" sweep-check --table "$mut_tsv" --log "$full" > "$E/t61.C.out" 2>&1 || pyrc=$?
  if [[ $pyrc -ne 2 ]]; then bad "T61 (C) sweep-check с мутантом канона ответил rc=$pyrc (ждали 2)"; return; fi
  refused=$(count_matches 'ОТКАЗ: стадия' "$E/t61.C.out") \
    || { bad 'T61 (C) ПРИБОР НЕДОСТУПЕН: отказ grep отказов стадий'; return; }
  if [[ "$refused" != "1" ]]; then bad "T61 (C) отказов стадий $refused, ждали РОВНО 1 :: $(grep 'ОТКАЗ: стадия' "$E/t61.C.out" | tr '\n' ';')"; return; fi
  grep -q "ОТКАЗ: стадия 'probes-rollout'" "$E/t61.C.out" \
    || { bad "T61 (C) снятая альтернатива не покраснела probes-rollout"; return; }
  # D: контроль полноты фикстуры -- ДОПОЛНИТЕЛЬНЫЙ неизвестный exit-pin обязан
  # покраснить полный лог, а не быть тихо проигнорированным
  local tsv_d="$E/t61.tsvD"
  # CONSTRAINT: && -- статус группы несёт ОБЕ ступени; через ; отказ cat гас под rc printf
  { cat "$tsv" && printf 't61-unknown-pin\tНеизвестная стадия источник\tНеизвестная стадия лог\texit\talways\n'; } > "$tsv_d" \
    || { instr_bad 'фикстура: канон с неизвестным exit-pin (D) не записан'; return; }
  pyrc=0
  python3 "$census_py" sweep-check --table "$tsv_d" --log "$full" > "$E/t61.D.out" 2>&1 || pyrc=$?
  if [[ $pyrc -ne 2 ]]; then bad "T61 (D) неизвестный exit-pin не покраснил полный лог (rc=$pyrc)"; return; fi
  grep -q "ОТКАЗ: стадия 't61-unknown-pin'" "$E/t61.D.out" \
    || { bad "T61 (D) отказ не называет неизвестный exit-pin"; return; }
  ok 'T61 квитанция target на ПОЛНОМ логе: probes-rollout проходит; без квитанции/альтернативы -- ровно она одна красна; неизвестный exit-pin краснит'
}

# T62: [559-fix5] холодная сборка: ветка st_dev/mount -- контролируемая подмена
# пробы на копии helper (probe устройства сборки назначается константой):
# заданное ВТОРОЕ устройство -- отказ ПО ПРЕДМЕТУ до install/build; равные
# значения -- успех с редиректами и сборкой в собственном кэше
t62() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T62 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T62 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_cold_mocks "$E/mockbin" || { instr_bad 'фикстура: моки холодной сборки не записаны (A)'; return; }
  mk_run rm -rf "$E/cache/catalyst-tweakcc/$FAKE_SHA" || { instr_bad 'фикстура: запись пина не убрана (A)'; return; }
  local real_dev
  real_dev="$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_dev)' "$E/tmp")" \
    || { bad 'T62 не измерено устройство фикстуры'; return; }
  # A: подменённая проба отвечает вторым устройством (real+1) -- несовпадение
  local mutA="$E/mut-dev-mismatch.sh"
  mutate_one "$HELPER" "$mutA" '^  local d=.*dev_root=.*$' \
    '^  dev_root=.*$' "  dev_root=$((real_dev + 1)) \\" \
    || { bad 'T62 (A) мутация не заложена: пробы устройства на дереве нет'; return; }
  bash -n "$mutA" || { bad 'T62 (A) мутант не парсится'; return; }
  local w="$E/wrap.sh" helper_save="$HELPER"
  HELPER="$mutA"
  build_cold_wrap "$w" "$E/img/fake-target" "$SCRIPT" || { HELPER="$helper_save"; bad "T62 (A) извлечение отказало"; return; }
  HELPER="$helper_save"
  cold_run "$w"
  if [[ $WR_RC -ne 2 ]]; then bad "T62 (A) второе устройство: rc=$WR_RC (ждали 2) :: ${WR_OUT%%$'\n'*}"; return; fi
  if [[ "$WR_OUT" != *"другой ФС"* ]]; then bad 'T62 (A) отказ не назвал предмет (другая ФС)'; return; fi
  # [559-fix6] запуск install/build наблюдается по НЕЗАВИСИМОМУ известному
  # заранее пути ($E-маркер mock-npx.invoked), НЕ по TI_ROOT: TI_ROOT печатается
  # только после ensure_tweakcc и пуст при раннем отказе -- проверка по нему
  # была вакуумной
  if [[ -e "$E/obs/mock-npx.invoked" ]]; then
    bad 'T62 (A) install/build запущен до отказа по устройству (маркер запуска)'
    return
  fi
  if [[ -e "$E/home/.npm/_cacache/ti-marker" ]]; then bad 'T62 (A) писатель дошёл до живого фолбэка до отказа'; return; fi
  # [559-fix6] A2: чувствительность наблюдения -- подмена, ЗАПУСКАЮЩАЯ
  # install/build до отказа по st_dev (мутант A + снятый exit отказа),
  # обязана оставлять маркер; без этого контроля зелень A была бы вакуумной
  local mutA2="$E/mut-dev-refuseoff.sh"
  mutate_one "$mutA" "$mutA2" '^[ ]*echo "FATAL: изоляция target: приватный каталог cold-build' \
    '^      exit 2$' '      true' \
    || { bad 'T62 (A2) мутация не заложена: отказа по устройству на мутанте A нет'; return; }
  bash -n "$mutA2" || { bad 'T62 (A2) мутант не парсится'; return; }
  mk_env || { bad 'T62 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_cold_mocks "$E/mockbin" || { instr_bad 'фикстура: моки холодной сборки не записаны (A2)'; return; }
  mk_run rm -rf "$E/cache/catalyst-tweakcc/$FAKE_SHA" || { instr_bad 'фикстура: запись пина не убрана (A2)'; return; }
  w="$E/wrap.sh"
  HELPER="$mutA2"
  build_cold_wrap "$w" "$E/img/fake-target" "$SCRIPT" || { HELPER="$helper_save"; bad "T62 (A2) извлечение отказало"; return; }
  HELPER="$helper_save"
  cold_run "$w"
  if [[ ! -e "$E/obs/mock-npx.invoked" ]]; then
    bad 'T62 (A2) подмена, запускающая install/build до отказа по st_dev, НЕ оставила маркер -- наблюдение запуска нечувствительно'
    return
  fi
  # B: подменённая проба отвечает измеренным значением -- равенство, успех
  local mutB="$E/mut-dev-equal.sh"
  mutate_one "$HELPER" "$mutB" '^  local d=.*dev_root=.*$' \
    '^  dev_root=.*$' "  dev_root=$real_dev \\" \
    || { bad 'T62 (B) мутация не заложена: пробы устройства на дереве нет'; return; }
  bash -n "$mutB" || { bad 'T62 (B) мутант не парсится'; return; }
  mk_env || { bad 'T62 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_cold_mocks "$E/mockbin" || { instr_bad 'фикстура: моки холодной сборки не записаны (B)'; return; }
  mk_run rm -rf "$E/cache/catalyst-tweakcc/$FAKE_SHA" || { instr_bad 'фикстура: запись пина не убрана (B)'; return; }
  w="$E/wrap.sh"
  HELPER="$mutB"
  build_cold_wrap "$w" "$E/img/fake-target" "$SCRIPT" || { HELPER="$helper_save"; bad "T62 (B) извлечение отказало"; return; }
  HELPER="$helper_save"
  snap_to "$E/home" "$E/snap.home.A" || { instr_bad 'снимок snap.home.A HOME не снят'; return; }
  cold_run "$w"
  if [[ $WR_RC -ne 0 ]]; then bad "T62 (B) равные устройства: rc=$WR_RC (ждали 0) :: ${WR_OUT%%$'\n'*}"; return; fi
  # [559-fix6] положительный контроль маркера: install/build шёл -- маркер быть обязан
  if [[ ! -e "$E/obs/mock-npx.invoked" ]]; then
    bad 'T62 (B) маркер запуска не появился при состоявшемся install/build -- положительный контроль нечувствителен'
    return
  fi
  local rootB ownB d
  rootB=$(ti_var TI_ROOT) || { bad 'T62 (B) ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_ROOT'; return; }
  ownB=$(ti_var TI_CACHE) || { bad 'T62 (B) ПРИБОР НЕДОСТУПЕН: отказ ti_var TI_CACHE'; return; }
  for d in npm-cache xdg-data xdg-cache xdg-state; do
    [[ -f "$rootB/$d/ti-marker" ]] || { bad "T62 (B) писатель $d не дошёл до собственного temp при равных устройствах"; return; }
  done
  [[ -f "$ownB/$FAKE_SHA/dist/index.mjs" ]] || { bad 'T62 (B) запись пина не собрана в собственном кэше при равных устройствах'; return; }
  snap_to "$E/home" "$E/snap.home.B" || { instr_bad 'снимок snap.home.B HOME не снят'; return; }
  local ch62=0
  changed "$E/snap.home.A" "$E/snap.home.B" || ch62=$?
  if [[ $ch62 -eq 2 ]]; then bad 'T62 (B) ПРИБОР НЕДОСТУПЕН: отказ diff снимков HOME'; return; fi
  if [[ $ch62 -eq 0 ]]; then bad 'T62 (B) равные устройства: HOME изменён'; return; fi
  ok 'T62 ветка st_dev: второе устройство -- отказ до install/build (маркер по независимому пути); запуск до отказа ловится; равные -- успех'
}

# T63: [559-fix6] прямой реальный claude-patch-all.sh --target с custom
# TWEAKCC_CONFIG_DIR ВНЕ защитного перечня, замок = существующий непустой
# config.json внутри источника (затем symlink на него): ранний rc=6 ДО
# exec 9>, конфиг и дерево источника байт-в-байт/mtime/inode нетронуты.
# Старое дерево (без source-guard) даёт предметный RED обнулением -- замок
# открывается O_TRUNC по живому конфигу; custom-варианты T57 сюда НЕ входят
# (снимок custom-дома ведётся только здесь).
# CONSTRAINT: post-snapshot снимается ДО вердиктов по rc; мутационный контроль
# (снятие source-guard на копии исправленного helper) идёт ПОСЛЕ прямых
# случаев -- на старом дереве зуб краснеет по предмету, не по отсутствию якоря.
t63() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T63 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/local-unpacker.mjs" '#!/usr/bin/env node\n// synthetic local build\n' \
    || { instr_bad 'фикстура: local-unpacker.mjs не записан'; return; }
  # custom источник ВНЕ защитного перечня: не HOME/.tweakcc, не XDG, не кеш
  mk_run mkdir -p "$E/custom-src/system-prompts" || { instr_bad 'фикстура: custom-источник не создан'; return; }
  mk_put "$E/custom-src/config.json" \
    '{"ccVersion":"2.1.283","patchOptions":{"customsrc":true},"settings":{"custom":"live"}}\n' \
    || { instr_bad 'фикстура: config.json custom-источника не записан'; return; }
  mk_put "$E/custom-src/system-prompts/custom.diff" 'custom-overlay\n' \
    || { instr_bad 'фикстура: накладка custom-источника не записана'; return; }
  mk_run ln -s "$E/custom-src/config.json" "$E/t63-lock-sym" || { instr_bad 'фикстура: ссылка-замок не заложена'; return; }
  local rc=0 out
  local vk lpath
  for vk in direct symlink; do
    case "$vk" in
      direct)  lpath="$E/custom-src/config.json" ;;
      symlink) lpath="$E/t63-lock-sym" ;;
    esac
    snap_to "$E/custom-src" "$E/snap.src.A" || { instr_bad "снимок snap.src.A источника не снят ($vk)"; return; }
    isnap_to "$E/custom-src" "$E/isnap.src.A" || { instr_bad "inode-снимок isnap.src.A источника не снят ($vk)"; return; }
    rc=0
    out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
            -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
            -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
            HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
            CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
            TWEAKCC_CONFIG_DIR="$E/custom-src" CLAUDE_PATCH_LOCK="$lpath" \
            timeout 120 bash "$SCRIPT" --target "$E/img/fake-target" 2>&1) || rc=$?
    # post-snapshot ДО вердиктов: даже неверный rc измеряет живое дерево источника
    snap_to "$E/custom-src" "$E/snap.src.B" || { instr_bad "снимок snap.src.B источника не снят ($vk)"; return; }
    isnap_to "$E/custom-src" "$E/isnap.src.B" || { instr_bad "inode-снимок isnap.src.B источника не снят ($vk)"; return; }
    # предметный свидетель ПЕРВЫЙ: обнуление/запись живого конфиг -- не только rc
    local ch63=0
    changed "$E/snap.src.A" "$E/snap.src.B" || ch63=$?
    if [[ $ch63 -eq 2 ]]; then bad "T63 ($vk) ПРИБОР НЕДОСТУПЕН: отказ diff снимков источника"; return; fi
    if [[ $ch63 -eq 0 ]]; then
      bad "T63 ($vk) живой config.json/источник изменён (обнуление/запись; size config.json=$(stat -c '%s' "$E/custom-src/config.json" || echo n/a))"
      return
    fi
    if ! cmp -s "$E/isnap.src.A" "$E/isnap.src.B"; then
      bad "T63 ($vk) inode-состав источника изменён"
      return
    fi
    if [[ $rc -ne 6 ]]; then
      bad "T63 ($vk) ранний отказ не сработал (rc=$rc) :: ${out%%$'\n'*}"
      return
    fi
    if [[ "$out" != *"внутри источника"* ]]; then
      bad "T63 ($vk) отказ не назвал предмет (замок внутри источника)"
      return
    fi
  done
  # мутационный контроль: снятие source-guard на КОПИИ исправленного helper.
  # [559-fix7] CONSTRAINT: замок мутанта -- НЕСУЩЕСТВУЮЩИЙ файл ВНУТРИ источника:
  # после exec 9>> обнуление невозможно, предметный свидетель -- СОЗДАНИЕ нового
  # файла замка в живом источнике (ранняя запись) и изменение inode/mtime ДО
  # вердикта по rc; ссылку на старое обнуление зуб не предъявляет
  local mut="$E/mut-kit/tools/target-isolation.sh"
  mk_run mkdir -p "$E/mut-kit/tools" || { instr_bad 'фикстура: каталог мутантного кита не создан'; return; }
  mutate_one "$HELPER" "$mut" '^  # \[559-fix6\] ворота: путь замка -- НЕ внутри источника' \
    '^  __ti_guard_inside "\$lock_real" "\$src_real" "путь замка" "источника"$' '  true' \
    || { bad 'T63 мутация не заложена: source-guard на дереве нет'; return; }
  # [559-fix7] источник в preflight держат ДВЕ проверки (docnum:other) -- разыменованная цель
  # и имя-entry; мутант снимает ОБЕ (вторая -- тем же однозначным якорем),
  # иначе несуществующий замок в источнике отвергается оставшейся и свидетель
  # недостижим
  mutate_one "$mut" "$mut" '^  # \[559-fix7\] ворота: имя-entry НЕ внутри источника' \
    '^  __ti_guard_inside "\$lock_entry" "\$src_real" "имя замка" "источника"$' '  true' \
    || { bad 'T63 (вторая) мутация не заложена: guard entry на дереве нет'; return; }
  bash -n "$mut" || { bad 'T63 мутант не парсится'; return; }
  mk_run cp "$SCRIPT" "$E/mut-kit/claude-patch-all.sh" || { instr_bad 'фикстура: конвейер мутантного кита не скопирован'; return; }
  local f b
  for f in "$KIT"/tools/*; do
    b="$(basename "$f")" || { bad 'T63 ПРИБОР НЕДОСТУПЕН: отказ basename инструментов кита'; return; }
    [[ "$b" == target-isolation.sh ]] && continue
    mk_run ln -s "$f" "$E/mut-kit/tools/$b" || { instr_bad "фикстура: ссылка инструмента не заложена ($b)"; return; }
  done
  snap_to "$E/custom-src" "$E/snap.mut.A" || { instr_bad 'снимок snap.mut.A источника не снят'; return; }
  isnap_to "$E/custom-src" "$E/isnap.mut.A" || { instr_bad 'inode-снимок isnap.mut.A источника не снят'; return; }
  rc=0
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          TWEAKCC_CONFIG_DIR="$E/custom-src" CLAUDE_PATCH_LOCK="$E/custom-src/t63-mut.lock" \
          timeout 150 bash "$E/mut-kit/claude-patch-all.sh" --target "$E/img/fake-target" 2>&1) || rc=$?
  # post-snapshot ДО вердикта: создание нового файла замка в источнике --
  # само предметное свидетельство; rc у двери образа не ноль и не предмет
  snap_to "$E/custom-src" "$E/snap.mut.B" || { instr_bad 'снимок snap.mut.B источника не снят'; return; }
  isnap_to "$E/custom-src" "$E/isnap.mut.B" || { instr_bad 'inode-снимок isnap.mut.B источника не снят'; return; }
  if [[ ! -e "$E/custom-src/t63-mut.lock" ]]; then
    bad 'T63 (мутант) ВАКУУМНАЯ ЗЕЛЕНЬ: снятие source-guard не создало замок в живом источнике'
    return
  fi
  local ch63m=0
  changed "$E/snap.mut.A" "$E/snap.mut.B" || ch63m=$?
  if [[ $ch63m -eq 2 ]]; then bad 'T63 (мутант) ПРИБОР НЕДОСТУПЕН: отказ diff снимков источника'; return; fi
  if [[ $ch63m -eq 1 ]]; then
    bad 'T63 (мутант) замок создан, но снимок источника не изменился -- измерение нечувствительно'
    return
  fi
  cmp -s "$E/isnap.mut.A" "$E/isnap.mut.B" \
    && { bad 'T63 (мутант) inode-состав источника не изменился при созданном замке'; return; }
  ok 'T63 custom-источник: замок-в-источнике (прямой и symlink) -- rc=6 до открытия замка, источник нетронут; мутант снятия source-guard краснеет созданием замка в источнике (свидетель -- создание/inode, не обнуление: exec 9>> не усекает)'
}

# T64: [559-fix6] источник helper под set +e, инъекция отказа python3 ДО первой
# записи: target_isolation_preflight возвращает rc 2 (отказ прибора), никакой
# зелени при пустом canonical path. A -- полный отказ python3; B -- отказ
# разрешения ТОЛЬКО путь замка (пустой lock_real в старом дереве молча проходит
# оба стража); C -- мутант снятия явной передачи rc в сценарии B: зелёный
# preflight при пустом canonical path -- мутант краснеет.
# [559-fix7] CONSTRAINT: A и B -- НЕЗАВИСИМЫЕ прогоны: исход КАЖДОГО пишется в
# свой файл и оценивается сам по себе, красный A не отменяет и не подменяет B;
# фактические PF_RC обоих попадают в строку вердикта.
t64() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T64 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T64 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/local-unpacker.mjs" '#!/usr/bin/env node\n// synthetic local build\n' \
    || { instr_bad 'фикстура: local-unpacker.mjs не записан'; return; }
  mk_run mkdir -p "$E/pybinA" "$E/pybinB" || { instr_bad 'фикстура: каталоги моков python3 не созданы'; return; }
  local real_py3
  real_py3="$(command -v python3)" || { bad 'T64 нет настоящего python3 для мока'; return; }
  cat > "$E/pybinA/python3" <<'PYA' || { instr_bad 'фикстура: мок python3 (A) не записан'; return; }
#!/usr/bin/env bash
# СИНТЕТИЧЕСКИЙ полный отказ прибора: python3 не работает ни для одного пути
exit 1
PYA
  cat > "$E/pybinB/python3" <<PYB || { instr_bad 'фикстура: мок python3 (B) не записан'; return; }
#!/usr/bin/env bash
# СИНТЕТИЧЕСКИЙ точечный отказ: python3 падает ТОЛЬКО на аргументе-замке
# (t64.refused.lock), остальные разрешения делает настоящий python3
for a in "\$@"; do
  case "\$a" in *t64.refused.lock*) exit 1 ;; esac
done
exec "$real_py3" "\$@"
PYB
  mk_run chmod +x "$E/pybinA/python3" "$E/pybinB/python3" || { instr_bad 'фикстура: моки python3 не исполнимы'; return; }
  # обёртка: set +e (НЕ set -euo pipefail), helper подключается source-ом
  t64_wrap() {  # $1 обёртка, $2 helper; отказ записи -- rc2
    {
      printf '#!/usr/bin/env bash\n' &&
      printf 'set +e\n' &&
      printf 'export HOME=%q\n' "$E/home" &&
      printf 'export TMPDIR=%q\n' "$E/tmp" &&
      printf 'source %q\n' "$2" &&
      printf 'target_isolation_preflight "%s"\n' "$E/t64.refused.lock" &&
      printf 'echo "T64_PF_RC=$?"\n' &&
      printf 'echo WIRE_DONE\n'
    } > "$1" || return 2
  }
  local t64_fail='' a_pf='' b_pf=''
  # A: полный отказ python3 -- preflight возвращает rc2, отказ назван прибором
  # (исход A сохраняется отдельным файлом и не отменяет B)
  t64_wrap "$E/wrapA.sh" "$HELPER" || { instr_bad 'фикстура: обёртка A не записана'; return; }
  WR_RC=0
  WR_OUT=$(env -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE -u XDG_CONFIG_HOME \
             -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
             HOME="$E/home" TMPDIR="$E/tmp" \
             PATH="$E/pybinA:$PATH" bash "$E/wrapA.sh" 2>&1) || WR_RC=$?
  printf '%s\n' "$WR_OUT" > "$E/t64.A.out" || { instr_bad 'вывод A не записан'; return; }
  a_pf="$(set -o pipefail; sed -n 's/^T64_PF_RC=//p' "$E/t64.A.out" | tail -1)" \
    || { bad 'T64 ПРИБОР НЕДОСТУПЕН: отказ reader T64_PF_RC (A)'; return; }
  [[ "$a_pf" == 2 ]] || t64_fail="$t64_fail A:PF_RC=${a_pf:-нет}"
  grep -q 'ПРИБОР НЕДОСТУПЕН' "$E/t64.A.out" || t64_fail="$t64_fail A:без-предмета"
  # B: отказ разрешения ТОЛЬКО путь замка -- rc2, зелени при пустом пути нет
  # (прогон независим от исхода A)
  t64_wrap "$E/wrapB.sh" "$HELPER" || { instr_bad 'фикстура: обёртка B не записана'; return; }
  WR_RC=0
  WR_OUT=$(env -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE -u XDG_CONFIG_HOME \
             -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
             HOME="$E/home" TMPDIR="$E/tmp" \
             PATH="$E/pybinB:$PATH" bash "$E/wrapB.sh" 2>&1) || WR_RC=$?
  printf '%s\n' "$WR_OUT" > "$E/t64.B.out" || { instr_bad 'вывод B не записан'; return; }
  b_pf="$(set -o pipefail; sed -n 's/^T64_PF_RC=//p' "$E/t64.B.out" | tail -1)" \
    || { bad 'T64 ПРИБОР НЕДОСТУПЕН: отказ reader T64_PF_RC (B)'; return; }
  [[ "$b_pf" == 2 ]] || t64_fail="$t64_fail B:PF_RC=${b_pf:-нет}"
  # C: мутант снятия явной передачи rc (lock_real без || return 2, docnum:other) в сценарии B
  # -- preflight ЗЕЛЕНЕЕТ на пустом canonical path: мутант пойман
  local mut="$E/mut-helper-norc.sh"
  mutate_one "$HELPER" "$mut" '^  # \[559-fix6\] ворота: отказ разрешения пути замка' \
    '^  lock_real="\$\(__ti_real "\$1" "путь замка"\)" \|\| return \$\?$' '  lock_real="$(__ti_real "$1" "путь замка")"' \
    || { bad 'T64 (C) мутация не заложена: явной передачи rc на дереве нет'; return; }
  bash -n "$mut" || { bad 'T64 (C) мутант не парсится'; return; }
  t64_wrap "$E/wrapC.sh" "$mut" || { instr_bad 'фикстура: обёртка C не записана'; return; }
  WR_RC=0
  WR_OUT=$(env -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE -u XDG_CONFIG_HOME \
             -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
             HOME="$E/home" TMPDIR="$E/tmp" \
             PATH="$E/pybinB:$PATH" bash "$E/wrapC.sh" 2>&1) || WR_RC=$?
  if [[ "$WR_OUT" != *"T64_PF_RC=0"* ]]; then
    t64_fail="$t64_fail C:мутант-не-зелёнеет"
  fi
  if [[ -e "$E/t64.refused.lock" ]]; then
    t64_fail="$t64_fail замок-создан"
  fi
  # --- [559-fix8] D: ступени источника preflight -- адресный отказ trim-sed,
  # пустой путь источника, отказ разрешения источника; custom-источник
  # непустой, замок и TMPDIR ВНУТРИ него; каждая ступень отдельно в режимах
  # e (set -euo pipefail, if-форма вызова кита) и p (set +e)
  # CONSTRAINT: cwd обёртки -- нейтральный $E/cwd64: пустой путь источника
  # разрешался бы realpath в cwd, и исход не зависел бы от места запуска зубов
  local real_sed
  real_sed="$(command -v sed)" || { instr_bad 'нет настоящего sed для мока'; return; }
  mk_run mkdir -p "$E/src64/system-prompts" "$E/src64/tmp" "$E/cwd64" "$E/sed64" "$E/py64" \
    || { instr_bad 'каталоги ступеней источника не созданы'; return; }
  mk_put "$E/src64/config.json" '{"ccVersion":"2.1.283","t64":"stage"}\n' \
    || { instr_bad 'конфиг custom-источника не записан'; return; }
  mk_put "$E/src64/system-prompts/t64.diff" 't64-overlay\n' \
    || { instr_bad 'накладка custom-источника не записана'; return; }
  cat > "$E/sed64/python3" <<SEDM || { instr_bad 'мок trim не записан'; return; }
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = '--ti-js-trim' ]; then
    echo "T64MOCK: trim-sed отказ" >&2
    exit 1
  fi
done
exec "$real_py3" "\$@"
SEDM
  cat > "$E/py64/python3" <<PYM || { instr_bad 'мок python3 источника не записан'; return; }
#!/usr/bin/env bash
# CONSTRAINT: trim и realpath получают один путь; отказ адресован realpath.
for a in "\$@"; do
  [ "\$a" != '--ti-js-trim' ] || exec "$real_py3" "\$@"
done
for a in "\$@"; do
  if [ "\$a" = "$E/src64" ]; then
    echo "T64MOCK: python3 отказ на источнике" >&2
    exit 1
  fi
done
exec "$real_py3" "\$@"
PYM
  mk_run chmod +x "$E/sed64/python3" "$E/py64/python3" || { instr_bad 'моки ступеней не исполнимы'; return; }
  t64_stage_wrap() {  # $1 обёртка, $2 helper, $3 режим e|p, $4 путь замка, $5 строка после source ('' -- нет)
    {
      printf '#!/usr/bin/env bash\n' &&
      if [[ "$3" == e ]]; then printf 'set -euo pipefail\n'; else printf 'set +e\n'; fi &&
      printf 'cd %q || exit 3\n' "$E/cwd64" &&
      printf 'source %q\n' "$2" &&
      { [[ -z "$5" ]] || printf '%s\n' "$5"; } &&
      if [[ "$3" == e ]]; then
        printf 'if target_isolation_preflight %q; then r=0; else r=$?; fi\n' "$4"
      else
        printf 'target_isolation_preflight %q\n' "$4" &&
        printf 'r=$?\n'
      fi &&
      printf 'echo "T64_PF_RC=$r"\n' &&
      printf 'exit "$r"\n'
    } > "$1"
  }
  # случай: ключ|каталог мока в PATH ('' -- нет)|переопределение после source|свидетель достижения|предмет|запрещённый текст
  local -a st64=(
    "sed|$E/sed64||T64MOCK: trim-sed отказ|trim TWEAKCC_CONFIG_DIR не выполнен|путь источника конфигурации пуст"
    "empty||__ti_source_path() { :; }||путь источника конфигурации пуст|"
    "py|$E/py64||T64MOCK: python3 отказ на источнике|не разрешён полный путь $E/src64|"
  )
  local sp64 k64 pd64 ov64 reach64 pat64 forb64 md64 rest64 path64 rc64 out64 ch64
  for sp64 in "${st64[@]}"; do
    k64="${sp64%%|*}"; rest64="${sp64#*|}"
    pd64="${rest64%%|*}"; rest64="${rest64#*|}"
    ov64="${rest64%%|*}"; rest64="${rest64#*|}"
    reach64="${rest64%%|*}"; rest64="${rest64#*|}"
    pat64="${rest64%%|*}"; forb64="${rest64#*|}"
    for md64 in e p; do
      snap_to "$E/src64" "$E/snap64.A" || { instr_bad "снимок источника A не снят ($k64/$md64)"; return; }
      isnap_to "$E/src64" "$E/isnap64.A" || { instr_bad "inode-снимок источника A не снят ($k64/$md64)"; return; }
      t64_stage_wrap "$E/wrap64.$k64.$md64.sh" "$HELPER" "$md64" "$E/src64/pf.lock" "$ov64" \
        || { instr_bad "обёртка ступени не записана ($k64/$md64)"; return; }
      path64="$PATH"
      [[ -z "$pd64" ]] || path64="$pd64:$PATH"
      rc64=0
      out64=$(env -u CATALYST_TWEAKCC_CACHE -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK \
                -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
                HOME="$E/home" TMPDIR="$E/src64/tmp" TWEAKCC_CONFIG_DIR="$E/src64" \
                PATH="$path64" bash "$E/wrap64.$k64.$md64.sh" 2>&1) || rc64=$?
      printf '%s\n' "$out64" > "$E/t64.$k64.$md64.out" \
        || { instr_bad "вывод ступени не записан ($k64/$md64)"; return; }
      # предмет до rc-вердикта: дерево источника (включая замок и TMPDIR внутри)
      snap_to "$E/src64" "$E/snap64.B" || { instr_bad "снимок источника B не снят ($k64/$md64)"; return; }
      isnap_to "$E/src64" "$E/isnap64.B" || { instr_bad "inode-снимок источника B не снят ($k64/$md64)"; return; }
      ch64=0
      changed "$E/snap64.A" "$E/snap64.B" || ch64=$?
      if [[ $ch64 -eq 2 ]]; then instr_bad "отказ diff снимков источника ($k64/$md64)"; return; fi
      [[ $ch64 -eq 1 ]] || t64_fail="$t64_fail D-$k64/$md64:источник-байты/mtime"
      cmp -s "$E/isnap64.A" "$E/isnap64.B" || t64_fail="$t64_fail D-$k64/$md64:источник-inode"
      [[ ! -e "$E/src64/pf.lock" ]] || t64_fail="$t64_fail D-$k64/$md64:замок-создан"
      [[ $rc64 -eq 2 ]] || t64_fail="$t64_fail D-$k64/$md64:rc=$rc64"
      [[ "$out64" == *"T64_PF_RC=2"* ]] || t64_fail="$t64_fail D-$k64/$md64:PF_RC-не-2"
      [[ -z "$reach64" || "$out64" == *"$reach64"* ]] || t64_fail="$t64_fail D-$k64/$md64:отказ-не-достигнут"
      [[ "$out64" == *'ПРИБОР НЕДОСТУПЕН'* && "$out64" == *"$pat64"* ]] \
        || t64_fail="$t64_fail D-$k64/$md64:без-предмета"
      [[ -z "$forb64" || "$out64" != *"$forb64"* ]] || t64_fail="$t64_fail D-$k64/$md64:отказ-не-своей-ступени"
    done
  done
  if [[ -n "$t64_fail" ]]; then bad "T64 set +e:$t64_fail"; return; fi
  ok "T64 set +e: A(полный отказ) и B(только замок) НЕЗАВИСИМО rc2 (исходы A=$a_pf B=$b_pf в t64.A.out/t64.B.out), прибор назван; снятие передачи rc зелёнеет на пустом пути и ловится; ступени источника (trim-sed, пустой путь, разрешение) -- rc2 своей ступенью в set -e и set +e, custom-источник с замком и TMPDIR внутри нетронут"
}

# T65: [559-fix7] hard link на живой config.json как замок ВНЕ custom-источника
# (тот же inode): preflight РАЗРЕШАЕТ, открытие замка exec 9>> НЕ меняет
# байты/mtime/inode исходного конфига, прогон останавливается у двери
# поддельного образа. Мутант замены target `exec 9>>` на `exec 9>` обнуляет
# тот же конфиг; RED исходного FIX6 доказывается изменением содержимого,
# а не кодом завершения.
t65() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T65 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/local-unpacker.mjs" '#!/usr/bin/env node\n// synthetic local build\n' \
    || { instr_bad 'фикстура: local-unpacker.mjs не записан'; return; }
  mk_run mkdir -p "$E/hsrc/system-prompts" || { instr_bad 'фикстура: источник hsrc не создан'; return; }
  mk_put "$E/hsrc/config.json" '{"ccVersion":"2.1.283","patchOptions":{"t65":true}}\n' \
    || { instr_bad 'фикстура: config.json hsrc не записан'; return; }
  mk_put "$E/hsrc/system-prompts/t65.diff" 't65-overlay\n' || { instr_bad 'фикстура: накладка hsrc не записана'; return; }
  mk_run ln "$E/hsrc/config.json" "$E/hard.link.lock" || { instr_bad 'фикстура: hard link замка не заложен'; return; }
  local cfg_mtime cfg_ino
  mk_run cp -p "$E/hsrc/config.json" "$E/t65.cfg.orig" || { instr_bad 'фикстура: эталон конфига не снят'; return; }
  cfg_mtime="$(stat -c '%.9Y' "$E/hsrc/config.json")" || { bad 'T65 ПРИБОР НЕДОСТУПЕН: отказ stat mtime живого конфига'; return; }
  cfg_ino="$(stat -c '%i' "$E/hsrc/config.json")" || { bad 'T65 ПРИБОР НЕДОСТУПЕН: отказ stat inode живого конфига'; return; }
  local rc=0 out
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          TWEAKCC_CONFIG_DIR="$E/hsrc" CLAUDE_PATCH_LOCK="$E/hard.link.lock" \
          timeout 120 bash "$SCRIPT" --target "$E/img/fake-target" 2>&1) || rc=$?
  # предмет ПЕРВЫЙ (снимок до вердикта по rc): байты/mtime/inode живого конфига
  if ! cmp -s "$E/hsrc/config.json" "$E/t65.cfg.orig"; then
    bad "T65 живой config.json через hard link изменён (size=$(stat -c '%s' "$E/hsrc/config.json")) -- открытие замка усекло его"
    return
  fi
  local m65 i65
  m65=$(stat -c '%.9Y' "$E/hsrc/config.json") || { bad 'T65 ПРИБОР НЕДОСТУПЕН: отказ stat mtime живого конфига'; return; }
  i65=$(stat -c '%i' "$E/hsrc/config.json") || { bad 'T65 ПРИБОР НЕДОСТУПЕН: отказ stat inode живого конфига'; return; }
  [[ "$m65" == "$cfg_mtime" ]] \
    || { bad 'T65 mtime живого config.json изменён открытием замка'; return; }
  [[ "$i65" == "$cfg_ino" ]] \
    || { bad 'T65 inode живого config.json изменён'; return; }
  if [[ "$out" == *'FATAL: изоляция target'* ]]; then
    bad "T65 разрешённому замку (hard link вне источника) отказано :: ${out%%$'\n'*}"
    return
  fi
  if [[ "$out" != *'не нативный образ'* ]]; then
    bad "T65 прогон не дошёл до двери образа (rc=$rc) :: ${out%%$'\n'*}"
    return
  fi
  # мутационный контроль: append-open заменён на O_TRUNC -- тот же конфиг
  # обнуляется через hard link (свидетель -- байты, не rc прогона)
  local mut="$E/mut-kit/claude-patch-all.sh"
  mk_run mkdir -p "$E/mut-kit/tools" || { instr_bad 'фикстура: каталог мутантного кита не создан'; return; }
  mutate_one "$SCRIPT" "$mut" '^    # \[559-fix7\] ворота: замок target-прогона -- append-open' \
    '^    exec 9>>"\$__lock"$' '    exec 9>"$__lock"' \
    || { bad 'T65 мутация не заложена: append-open замка target на дереве нет'; return; }
  bash -n "$mut" || { bad 'T65 мутант не парсится'; return; }
  local f b
  for f in "$KIT"/tools/*; do
    b="$(basename "$f")" || { bad 'T65 ПРИБОР НЕДОСТУПЕН: отказ basename инструментов кита'; return; }
    mk_run ln -s "$f" "$E/mut-kit/tools/$b" || { instr_bad "фикстура: ссылка инструмента не заложена ($b)"; return; }
  done
  rc=0
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          TWEAKCC_CONFIG_DIR="$E/hsrc" CLAUDE_PATCH_LOCK="$E/hard.link.lock" \
          timeout 150 bash "$mut" --target "$E/img/fake-target" 2>&1) || rc=$?
  if cmp -s "$E/hsrc/config.json" "$E/t65.cfg.orig"; then
    bad 'T65 (мутант) ВАКУУМНАЯ ЗЕЛЕНЬ: exec 9> не обнулил живой config.json через hard link'
    return
  fi
  [[ ! -s "$E/hsrc/config.json" ]] \
    || { bad "T65 (мутант) конфиг изменён, но не обнулён (size=$(stat -c '%s' "$E/hsrc/config.json"))"; return; }
  ok 'T65 hard link вне источника: preflight разрешает, открытие замка не меняет байты/mtime/inode конфига, прогон у двери образа; мутант exec 9> обнуляет тот же конфиг'
}

# T66: [559-fix7] исходящий symlink с ИМЕНЕМ в источнике: custom-source/
# config.json -> непустой файл вне источника и защищённых домов,
# CLAUDE_PATCH_LOCK называет именно имя ссылки В source (затем то же имя через
# symlink-родителя). Реальный главный скрипт обязан вернуть rc6 ДО открытия
# замка; и symlink-entry, и внешний файл сохраняют байты/mtime/inode.
# Мутант снятия guard entry краснеет допуском замка внутрь источника по
# неверному rc и достижением lock-открытия (дверь образа); оставшееся
# неусекающее открытие внешнего файла само по себе не краснит -- контроль
# обязан проверять именно достижение lock-открытия/неверный rc.
# Разрешённый сосед custom-source-other и замок вне источника проходят до
# двери образа (граница сегмента не задевает соседа).
t66() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T66 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/local-unpacker.mjs" '#!/usr/bin/env node\n// synthetic local build\n' \
    || { instr_bad 'фикстура: local-unpacker.mjs не записан'; return; }
  mk_run mkdir -p "$E/csrc/system-prompts" "$E/external" "$E/csrc-other" || { instr_bad 'фикстура: каталоги источника не созданы'; return; }
  mk_put "$E/external/valuable.json" '{"ccVersion":"2.1.283","external":true,"pad":"0123456789"}\n' \
    || { instr_bad 'фикстура: внешний файл не записан'; return; }
  mk_put "$E/csrc/system-prompts/t66.diff" 't66-overlay\n' || { instr_bad 'фикстура: накладка csrc не записана'; return; }
  mk_run ln -s "$E/external/valuable.json" "$E/csrc/config.json" || { instr_bad 'фикстура: ссылка-имя не заложена'; return; }
  mk_run ln -s "$E/csrc" "$E/csrc-link" || { instr_bad 'фикстура: ссылка-родитель не заложена'; return; }
  local ext_mtime ext_ino link_mtime
  mk_run cp -p "$E/external/valuable.json" "$E/t66.ext.orig" || { instr_bad 'фикстура: эталон внешнего файла не снят'; return; }
  ext_mtime="$(stat -c '%.9Y' "$E/external/valuable.json")" || { bad 'T66 ПРИБОР НЕДОСТУПЕН: отказ stat mtime внешнего файла'; return; }
  ext_ino="$(stat -c '%i' "$E/external/valuable.json")" || { bad 'T66 ПРИБОР НЕДОСТУПЕН: отказ stat inode внешнего файла'; return; }
  link_mtime="$(stat -c '%.9Y' "$E/csrc/config.json")" || { bad 'T66 ПРИБОР НЕДОСТУПЕН: отказ stat mtime ссылки-имени'; return; }
  local rc=0 out vk lpath
  for vk in direct parentlink; do
    lpath="$E/csrc/config.json"
    [[ "$vk" == parentlink ]] && lpath="$E/csrc-link/config.json"
    snap_to "$E/csrc" "$E/snap.src.A" || { instr_bad "снимок snap.src.A источника не снят ($vk)"; return; }
    isnap_to "$E/csrc" "$E/isnap.src.A" || { instr_bad "inode-снимок isnap.src.A источника не снят ($vk)"; return; }
    rc=0
    out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
            -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
            -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
            HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
            CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
            TWEAKCC_CONFIG_DIR="$E/csrc" CLAUDE_PATCH_LOCK="$lpath" \
            timeout 120 bash "$SCRIPT" --target "$E/img/fake-target" 2>&1) || rc=$?
    # post-snapshot ДО вердиктов: даже неверный rc измеряет имя и внешний файл
    snap_to "$E/csrc" "$E/snap.src.B" || { instr_bad "снимок snap.src.B источника не снят ($vk)"; return; }
    isnap_to "$E/csrc" "$E/isnap.src.B" || { instr_bad "inode-снимок isnap.src.B источника не снят ($vk)"; return; }
    if ! cmp -s "$E/external/valuable.json" "$E/t66.ext.orig"; then
      bad "T66 ($vk) внешний файл за исходящей ссылкой изменён (обнуление/запись; size=$(stat -c '%s' "$E/external/valuable.json" || echo n/a))"
      return
    fi
    local m66 i66 ml66
    m66=$(stat -c '%.9Y' "$E/external/valuable.json") || { bad "T66 ($vk) ПРИБОР НЕДОСТУПЕН: отказ stat mtime внешнего файла"; return; }
    i66=$(stat -c '%i' "$E/external/valuable.json") || { bad "T66 ($vk) ПРИБОР НЕДОСТУПЕН: отказ stat inode внешнего файла"; return; }
    if [[ "$m66" != "$ext_mtime" || "$i66" != "$ext_ino" ]]; then
      bad "T66 ($vk) mtime/inode внешнего файла изменены"
      return
    fi
    ml66=$(stat -c '%.9Y' "$E/csrc/config.json") || { bad "T66 ($vk) ПРИБОР НЕДОСТУПЕН: отказ stat mtime ссылки-имени"; return; }
    if [[ "$ml66" != "$link_mtime" ]]; then
      bad "T66 ($vk) сама ссылка-имя в источнике изменена"
      return
    fi
    local ch66=0
    changed "$E/snap.src.A" "$E/snap.src.B" || ch66=$?
    if [[ $ch66 -eq 2 ]]; then bad "T66 ($vk) ПРИБОР НЕДОСТУПЕН: отказ diff снимков источника"; return; fi
    if [[ $ch66 -eq 0 ]]; then
      bad "T66 ($vk) дерево источника изменено"
      return
    fi
    # [559-fix8] ворота: inode-снимки источника сравниваются ДО вердикта по rc --
    # подмена ссылки-имени той же целью и mtime видна только inode-entry
    if ! cmp -s "$E/isnap.src.A" "$E/isnap.src.B"; then
      bad "T66 ($vk) inode-entry источника изменён (ссылка-имя подменена)"
      return
    fi
    if [[ $rc -ne 6 ]]; then
      bad "T66 ($vk) замок-имя-в-источнике не отвергнут (rc=$rc) :: ${out%%$'\n'*}"
      return
    fi
    if [[ "$out" != *"внутри источника"* ]]; then
      bad "T66 ($vk) отказ не назвал предмет (имя замка внутри источника)"
      return
    fi
  done
  # [559-fix8] отказ dirname/basename пути замка реальным главным скриптом:
  # каждая утилита отдельно -- отказ с правдоподобным выводом (rc1) и пустой
  # вывод (rc0) дают rc2 ПРИБОР до открытия замка; ссылка-имя, внешний файл и
  # дерево источника нетронуты (байты/mtime/inode), temp и CLI нет.
  # CONSTRAINT: подмена отказывает ТОЛЬКО на аргументе-замке, прочие вызовы
  # (HERE кита, XDG-родитель) делегируются настоящей утилите
  local real_dn real_bn fk fbin fmsg t66_fail='' ml66f m66f i66f f66t
  real_dn="$(command -v dirname)" || { instr_bad 'нет настоящего dirname'; return; }
  real_bn="$(command -v basename)" || { instr_bad 'нет настоящего basename'; return; }
  t66_fake() {  # $1 каталог подмены, $2 утилита, $3 настоящая, $4 действие на аргументе-замке
    mkdir -p "$1" || return 2
    cat > "$1/$2" <<FAKE66 || return 2
#!/usr/bin/env bash
# СИНТЕТИЧЕСКИЙ отказ утилиты ТОЛЬКО на пути замка T66
for a in "\$@"; do
  if [ "\$a" = "$E/csrc/config.json" ]; then $4; fi
done
exec "$3" "\$@"
FAKE66
    chmod +x "$1/$2" || return 2
  }
  t66_fake "$E/fbin-dn-rc1" dirname "$real_dn" "printf '%s\\n' '$E/csrc-other'; exit 1" \
    && t66_fake "$E/fbin-dn-empty" dirname "$real_dn" "exit 0" \
    && t66_fake "$E/fbin-bn-rc1" basename "$real_bn" "printf 'other-name\\n'; exit 1" \
    && t66_fake "$E/fbin-bn-empty" basename "$real_bn" "exit 0" \
    || { instr_bad 'подмены dirname/basename не записаны'; return; }
  for fk in dn-rc1 dn-empty bn-rc1 bn-empty; do
    fbin="$E/fbin-$fk"
    case "$fk" in
      dn-*) fmsg='dirname пути замка' ;;
      *)    fmsg='basename пути замка' ;;
    esac
    snap_to "$E/csrc" "$E/snap.src.fA" || { instr_bad "снимок snap.src.fA источника не снят ($fk)"; return; }
    isnap_to "$E/csrc" "$E/isnap.src.fA" || { instr_bad "inode-снимок isnap.src.fA источника не снят ($fk)"; return; }
    rc=0
    out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
            -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
            -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
            HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
            CLAUDE_PATCH_SKIP_KIT_BENCH=1 PATH="$fbin:$PATH" \
            TWEAKCC_CONFIG_DIR="$E/csrc" CLAUDE_PATCH_LOCK="$E/csrc/config.json" \
            timeout 120 bash "$SCRIPT" --target "$E/img/fake-target" 2>&1) || rc=$?
    # предмет ПЕРВЫЙ: снимки ДО вердикта по rc
    snap_to "$E/csrc" "$E/snap.src.fB" || { instr_bad "снимок snap.src.fB источника не снят ($fk)"; return; }
    isnap_to "$E/csrc" "$E/isnap.src.fB" || { instr_bad "inode-снимок isnap.src.fB источника не снят ($fk)"; return; }
    cmp -s "$E/external/valuable.json" "$E/t66.ext.orig" || t66_fail="$t66_fail $fk:внешний-байты"
    m66f=$(stat -c '%.9Y' "$E/external/valuable.json") || { instr_bad "отказ stat mtime внешнего файла ($fk)"; return; }
    i66f=$(stat -c '%i' "$E/external/valuable.json") || { instr_bad "отказ stat inode внешнего файла ($fk)"; return; }
    [[ "$m66f" == "$ext_mtime" && "$i66f" == "$ext_ino" ]] || t66_fail="$t66_fail $fk:внешний-mtime/inode"
    ml66f=$(stat -c '%.9Y' "$E/csrc/config.json") || { instr_bad "отказ stat mtime ссылки-имени ($fk)"; return; }
    [[ "$ml66f" == "$link_mtime" ]] || t66_fail="$t66_fail $fk:ссылка-имя"
    ch66=0
    changed "$E/snap.src.fA" "$E/snap.src.fB" || ch66=$?
    [[ $ch66 -eq 2 ]] && { instr_bad "отказ diff снимков источника ($fk)"; return; }
    [[ $ch66 -eq 0 ]] && t66_fail="$t66_fail $fk:источник"
    cmp -s "$E/isnap.src.fA" "$E/isnap.src.fB" || t66_fail="$t66_fail $fk:inode-источника"
    [[ $rc -eq 2 ]] || t66_fail="$t66_fail $fk:rc=$rc"
    [[ "$out" == *'ПРИБОР НЕДОСТУПЕН'* && "$out" == *"$fmsg"* ]] || t66_fail="$t66_fail $fk:без-предмета"
    [[ "$out" != *'не нативный образ'* && "$out" != *'Изоляция target'* ]] || t66_fail="$t66_fail $fk:CLI"
    f66t=$(find "$E/tmp" -maxdepth 1 -name 'cc-target-isolation.*' -print -quit) \
      || { instr_bad "отказ find temp ($fk)"; return; }
    [[ -z "$f66t" ]] || t66_fail="$t66_fail $fk:temp"
  done
  if [[ -n "$t66_fail" ]]; then bad "T66 отказ утилит пути замка:$t66_fail"; return; fi
  # положительный контроль: сосед custom-source-other с замком вне источника
  # проходит предзамковую проверку до двери образа
  rc=0
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          TWEAKCC_CONFIG_DIR="$E/csrc" CLAUDE_PATCH_LOCK="$E/csrc-other/ti66-ok.lock" \
          timeout 120 bash "$SCRIPT" --target "$E/img/fake-target" 2>&1) || rc=$?
  if [[ $rc -eq 6 || "$out" == *'FATAL: изоляция target'* ]]; then
    bad "T66 (сосед) разрешённому замку вне источника отказано :: ${out%%$'\n'*}"
    return
  fi
  if [[ "$out" != *'не нативный образ'* || ! -e "$E/csrc-other/ti66-ok.lock" ]]; then
    bad "T66 (сосед) прогон не дошёл до двери образа/замок не открыт (rc=$rc) :: ${out%%$'\n'*}"
    return
  fi
  # мутационный контроль: снят ТОЛЬКО новый guard entry -- замок-имя-в-источнике
  # допускается (неверный rc) и прогон ДОХОДИТ до открытия замка (дверь образа);
  # неусекающее открытие внешнего файла байт не меняет -- и НЕ является
  # свидетелем, свидетель именно допуск/достижение lock-открытия
  local mut="$E/mut-kit/tools/target-isolation.sh"
  mk_run mkdir -p "$E/mut-kit/tools" || { instr_bad 'фикстура: каталог мутантного кита не создан'; return; }
  mutate_one "$HELPER" "$mut" '^  # \[559-fix7\] ворота: имя-entry НЕ внутри источника' \
    '^  __ti_guard_inside "\$lock_entry" "\$src_real" "имя замка" "источника"$' '  true' \
    || { bad 'T66 мутация не заложена: guard entry на дереве нет'; return; }
  bash -n "$mut" || { bad 'T66 мутант не парсится'; return; }
  mk_run cp "$SCRIPT" "$E/mut-kit/claude-patch-all.sh" || { instr_bad 'фикстура: конвейер мутантного кита не скопирован'; return; }
  local f b
  for f in "$KIT"/tools/*; do
    b="$(basename "$f")" || { bad 'T66 ПРИБОР НЕДОСТУПЕН: отказ basename инструментов кита'; return; }
    [[ "$b" == target-isolation.sh ]] && continue
    mk_run ln -s "$f" "$E/mut-kit/tools/$b" || { instr_bad "фикстура: ссылка инструмента не заложена ($b)"; return; }
  done
  # CONSTRAINT: свидетелем мутанта является ДВЕРЬ образа (после проверки
  # `[[ -f "$OUR_PATCH" ]]` tweakcc-patch.js у корня кита) -- mut-kit обязан нести и корневые
  # ФАЙЛЫ кита симлинками, иначе прогон умирает rc2 до двери и допуск замка
  # не доказывается
  for f in "$KIT"/*; do
    [[ -f "$f" ]] || continue
    b="$(basename "$f")" || { bad 'T66 ПРИБОР НЕДОСТУПЕН: отказ basename корневых файлов кита'; return; }
    [[ "$b" == claude-patch-all.sh ]] && continue
    mk_run ln -s "$f" "$E/mut-kit/$b" || { instr_bad "фикстура: ссылка корневого файла не заложена ($b)"; return; }
  done
  rc=0
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          TWEAKCC_CONFIG_DIR="$E/csrc" CLAUDE_PATCH_LOCK="$E/csrc/config.json" \
          timeout 150 bash "$E/mut-kit/claude-patch-all.sh" --target "$E/img/fake-target" 2>&1) || rc=$?
  if [[ $rc -eq 6 ]]; then
    bad "T66 (мутант) замок-имя-в-источнике всё ещё отвергается rc6 -- мутация не подействовала"
    return
  fi
  if [[ "$out" != *'не нативный образ'* ]]; then
    bad "T66 (мутант) прогон не дошёл до lock-открытия/двери образа (rc=$rc) -- допуск не доказан :: ${out%%$'\n'*}"
    return
  fi
  ok 'T66 исходящий symlink с именем в источнике: rc6 до открытия замка (прямой и symlink-родитель), имя, inode-entry и внешний файл нетронуты; отказ dirname/basename пути замка (rc1 и пустой вывод) -- rc2 ПРИБОР до замка реальным скриптом; сосед вне источника проходит до двери; снятие guard entry краснеет допуском замка (неверный rc + дверь образа)'
}

# T67: [559-fix7] отказ resolver реальным главным скриптом. A1 (штатный set -e)
# и A2 (временная копия с set +e) с ПОЛНЫМ отказом python3: exit2, ни нового
# замка, ни temp, ни CLI. A3 -- точечный отказ ТОЛЬКО на разрешении пути замка:
# exit2 до создания замка. B -- точечный отказ ТОЛЬКО на activate (после
# успешного preflight и открытия разрешённого замка): exit2, собственного
# temp/CLI нет; рука воспроизводит последовательность главного скрипта
# (preflight -> exec 9>> разрешённого замка -> activate) подлинными функциями
# helper; полный проход реального кита до activate измеряется отдельно
# T67C-REALKIT. Его место 3b в corpus-tools-bench.sh зарегистрировано.
# Мутации: снятие явного условного выхода в главном скрипте под set +e --
# создание замка; снятие rc-guard activate -- создание temp/неверный код.
# Под штатным set -e фиксируется внешний отказ (exit2), недостижимые строки
# за выданные выполненные не выдаются.
t67() {
  RAN=$((RAN + 1))
  mk_env || { bad 'T67 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  mk_put "$E/local-unpacker.mjs" '#!/usr/bin/env node\n// synthetic local build\n' \
    || { instr_bad 'фикстура: local-unpacker.mjs не записан'; return; }
  mk_run mkdir -p "$E/t67-src/system-prompts" "$E/pybinA" "$E/pybinC" "$E/pybinD" \
    || { instr_bad 'фикстура: каталоги источника и моков не созданы'; return; }
  mk_put "$E/t67-src/config.json" '{"ccVersion":"2.1.283","t67":true}\n' || { instr_bad 'фикстура: config.json t67-src не записан'; return; }
  mk_put "$E/t67-src/system-prompts/t67.diff" 't67-overlay\n' || { instr_bad 'фикстура: накладка t67-src не записана'; return; }
  local real_py3 uid
  real_py3="$(command -v python3)" || { bad 'T67 нет настоящего python3 для мока'; return; }
  uid="$(id -u)" || { bad 'T67 ПРИБОР НЕДОСТУПЕН: отказ id -u'; return; }
  # CONSTRAINT: запусковый -c '' проходит; HERE и JS_TRIM делегируются,
  # иначе A1/A2/M1 отказывали бы до resolver helper.
  cat > "$E/pybinA/python3" <<PYA || { instr_bad 'фикстура: мок python3 (A) не записан'; return; }
#!/usr/bin/env bash
# CONSTRAINT: запусковая проба, HERE и trim не являются resolver helper.
if [ "\$1" = "-c" ]; then
  [ -n "\$2" ] || exit 0
  case "\$2" in *os.path.isfile*|*JS_TRIM*) exec "$real_py3" "\$@" ;; esac
fi
exit 1
PYA
  # CONSTRAINT: отсутствие файла счёта -- ноль (первый вызов); существующий,
  # но нечитаемый счёт или отказ записи -- отказ мока (rc3), не ноль
  cat > "$E/pybinC/python3" <<PYC || { instr_bad 'фикстура: мок python3 (C) не записан'; return; }
#!/usr/bin/env bash
# СИНТЕТИЧЕСКИЙ точечный отказ activate: падает на ВТОРОМ разрешении
# источника t67-src (первое -- preflight, второе -- activate); счёт в stderr
for a in "\$@"; do
  [ "\$a" != '--ti-js-trim' ] || exec "$real_py3" "\$@"
done
for a in "\$@"; do
  case "\$a" in *t67-src*)
    [ -n "\${T67_STATE:-}" ] || { echo "T67MOCK: нет T67_STATE" >&2; exit 3; }
    n=0
    if [ -f "\$T67_STATE/seen" ]; then n=\$(cat "\$T67_STATE/seen") || exit 3; fi
    n=\$((n+1)); printf '%s' "\$n" > "\$T67_STATE/seen" || exit 3
    echo "T67MOCK: src-разрешение #\$n" >&2
    [ "\$n" -ge 2 ] && exit 1 ;;
  esac
done
exec "$real_py3" "\$@"
PYC
  cat > "$E/pybinD/python3" <<PYD || { instr_bad 'фикстура: мок python3 (D) не записан'; return; }
#!/usr/bin/env bash
# СИНТЕТИЧЕСКИЙ точечный отказ preflight: падает ТОЛЬКО на аргументе-замке
# (t67.point.lock), остальные разрешения делает настоящий python3
for a in "\$@"; do
  case "\$a" in *t67.point.lock*) exit 1 ;; esac
done
exec "$real_py3" "\$@"
PYD
  mk_run chmod +x "$E/pybinA/python3" "$E/pybinC/python3" "$E/pybinD/python3" || { instr_bad 'фикстура: моки python3 не исполнимы'; return; }
  # [559-fix8] моки ступеней activate и адресного trim-sed: счёт вызовов в
  # файле состояния $T67_STATE; первое разрешение (preflight) проходит
  local real_sed67
  real_sed67="$(command -v sed)" || { instr_bad 'нет настоящего sed для мока'; return; }
  mk_run mkdir -p "$E/pybinT" "$E/pybinH" "$E/sedbin67" "$E/sedbinK" "$E/cwd67" \
                  "$E/t67s-src/system-prompts" "$E/t67s-src/tmp" \
    || { instr_bad 'каталоги моков ступеней не созданы'; return; }
  mk_put "$E/t67s-src/config.json" '{"ccVersion":"2.1.283","t67":"sed"}\n' \
    || { instr_bad 'конфиг custom-источника trim-sed не записан'; return; }
  mk_put "$E/t67s-src/system-prompts/t67s.diff" 't67s-overlay\n' \
    || { instr_bad 'накладка custom-источника trim-sed не записана'; return; }
  t67_count_mock() {  # $1 файл мока, $2 точный аргумент, $3 имя счётчика, $4 порог отказа, $5 метка, $6 настоящая утилита
    cat > "$1" <<CNT || return 2
#!/usr/bin/env bash
# CONSTRAINT: счётчик включает только -c; heredoc слоёв и чужой trim не считаются.
[ "\$1" = '-c' ] || exec "$6" "\$@"
if [ '$2' != '--ti-js-trim' ]; then
  for a in "\$@"; do
    [ "\$a" != '--ti-js-trim' ] || exec "$6" "\$@"
  done
fi
for a in "\$@"; do
  if [ "\$a" = '$2' ]; then
    [ -n "\${T67_STATE:-}" ] || { echo "T67MOCK: нет T67_STATE" >&2; exit 3; }
    n=0
    if [ -f "\$T67_STATE/$3" ]; then n=\$(cat "\$T67_STATE/$3") || exit 3; fi
    n=\$((n+1))
    printf '%s' "\$n" > "\$T67_STATE/$3" || exit 3
    echo "T67MOCK: $5 #\$n" >&2
    [ "\$n" -ge $4 ] && exit 1
  fi
done
exec "$6" "\$@"
CNT
    chmod +x "$1" || return 2
  }
  t67_count_mock "$E/pybinT/python3" "$E/tmp" tmp.seen 2 'tmp-разрешение' "$real_py3" \
    || { instr_bad 'мок разрешения TMPDIR не записан'; return; }
  t67_count_mock "$E/pybinH/python3" "$E/home" home.seen 3 'home-разрешение' "$real_py3" \
    || { instr_bad 'мок разрешения HOME не записан'; return; }
  t67_count_mock "$E/sedbin67/python3" '--ti-js-trim' sed.seen 2 'trim-sed отказ' "$real_py3" \
    || { instr_bad 'мок trim-sed activate не записан'; return; }
  t67_count_mock "$E/sedbinK/python3" '--ti-js-trim' sed.seen 1 'trim-sed отказ' "$real_py3" \
    || { instr_bad 'мок trim-sed preflight не записан'; return; }
  local t67_fail='' rc=0 out t67_cl=0
  # CONSTRAINT: свидетели «ни замка, ни temp, ни CLI» -- фактические маркеры:
  # файл замка, cc-target-isolation.* в TMPDIR, эхо активации и дверь образа
  t67_clean_run() {  # $1 вывод; 0 = чисто (нет замка/temp/CLI), 1 = есть следы; отказ find -- rc2
    local found67
    found67=$(find "$E/tmp" -maxdepth 1 \( -name "claude-patch-all.$uid.lock" -o -name 'cc-target-isolation.*' \) -print -quit) \
      || return 2
    [[ -z "$found67" ]] && [[ "$1" != *'Изоляция target'* && "$1" != *'не нативный образ'* ]]
  }
  # --- A1: полный отказ resolver, штатный set -e: exit2 ДО замка
  rc=0
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          PATH="$E/pybinA:$PATH" \
          timeout 120 bash "$SCRIPT" --target "$E/img/fake-target" 2>&1) || rc=$?
  [[ $rc -eq 2 ]] || t67_fail="$t67_fail A1:rc=$rc"
  [[ "$out" == *'ПРИБОР НЕДОСТУПЕН'* ]] || t67_fail="$t67_fail A1:без-предмета"
  [[ "$out" == *'не разрешён полный путь'* ]] || t67_fail="$t67_fail A1:отказ-не-в-resolver"
  [[ "$out" != *'realpath отказал для'* ]] || t67_fail="$t67_fail A1:отказ-на-HERE"
  t67_cl=0; t67_clean_run "$out" || t67_cl=$?
  [[ $t67_cl -eq 2 ]] && t67_fail="$t67_fail A1:ПРИБОР-find"
  [[ $t67_cl -eq 1 ]] && t67_fail="$t67_fail A1:замок/temp/CLI"
  # --- A2: тот же отказ на временной копии с set +e -- явный выход держит код
  # CONSTRAINT: копия живёт в КИТ-ОБРАЗНОМ каталоге (tools/ симлинками реального
  # кита): HERE выводится от места самого скрипта, одиночная копия не нашла бы
  # helper и умерла бы rc6 ДО замка, не измеряя предмет
  local kitA2="$E/kitA2"
  mk_run mkdir -p "$kitA2/tools" || { instr_bad 'фикстура: каталог копии A2 не создан'; return; }
  mk_run cp "$SCRIPT" "$kitA2/claude-patch-all.sh" || { instr_bad 'фикстура: конвейер копии A2 не скопирован'; return; }
  local f67 b67
  for f67 in "$KIT"/tools/*; do
    b67="$(basename "$f67")" || { bad 'T67 (A2) ПРИБОР НЕДОСТУПЕН: отказ basename инструментов кита'; return; }
    mk_run ln -s "$f67" "$kitA2/tools/$b67" || { instr_bad "фикстура: ссылка инструмента A2 не заложена ($b67)"; return; }
  done
  local n67a
  n67a=$(count_matches '^set -euo pipefail$' "$kitA2/claude-patch-all.sh") \
    || { bad 'T67 (A2) ПРИБОР НЕДОСТУПЕН: отказ grep set -euo pipefail'; return; }
  [[ "$n67a" == 1 ]] \
    || { bad 'T67 (A2) строка set -euo pipefail не единственная в предмете'; return; }
  mk_run sed -i 's|^set -euo pipefail$|set -euo pipefail; set +e|' "$kitA2/claude-patch-all.sh" \
    || { instr_bad 'фикстура: sed set +e копии A2 отказал'; return; }
  local n67b
  n67b=$(count_matches '^set -euo pipefail; set +e$' "$kitA2/claude-patch-all.sh") \
    || { bad 'T67 (A2) ПРИБОР НЕДОСТУПЕН: отказ grep set +e'; return; }
  [[ "$n67b" == 1 ]] \
    || { bad 'T67 (A2) копия с set +e не заложена'; return; }
  rc=0
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          PATH="$E/pybinA:$PATH" \
          timeout 120 bash "$kitA2/claude-patch-all.sh" --target "$E/img/fake-target" 2>&1) || rc=$?
  [[ $rc -eq 2 ]] || t67_fail="$t67_fail A2:rc=$rc"
  [[ "$out" == *'ПРИБОР НЕДОСТУПЕН'* ]] || t67_fail="$t67_fail A2:без-предмета"
  [[ "$out" == *'не разрешён полный путь'* ]] || t67_fail="$t67_fail A2:отказ-не-в-resolver"
  [[ "$out" != *'realpath отказал для'* ]] || t67_fail="$t67_fail A2:отказ-на-HERE"
  t67_cl=0; t67_clean_run "$out" || t67_cl=$?
  [[ $t67_cl -eq 2 ]] && t67_fail="$t67_fail A2:ПРИБОР-find"
  [[ $t67_cl -eq 1 ]] && t67_fail="$t67_fail A2:замок/temp/CLI"
  # --- A3: точечный отказ ТОЛЬКО на разрешении пути замка (несуществующий замок)
  rc=0
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          PATH="$E/pybinD:$PATH" \
          CLAUDE_PATCH_LOCK="$E/t67.point.lock" \
          timeout 120 bash "$SCRIPT" --target "$E/img/fake-target" 2>&1) || rc=$?
  [[ $rc -eq 2 ]] || t67_fail="$t67_fail A3:rc=$rc"
  [[ "$out" == *'ПРИБОР НЕДОСТУПЕН'* ]] || t67_fail="$t67_fail A3:без-предмета"
  [[ ! -e "$E/t67.point.lock" ]] || t67_fail="$t67_fail A3:замок-создан"
  t67_cl=0; t67_clean_run "$out" || t67_cl=$?
  [[ $t67_cl -eq 2 ]] && t67_fail="$t67_fail A3:ПРИБОР-find"
  [[ $t67_cl -eq 1 ]] && t67_fail="$t67_fail A3:temp/CLI"
  # --- [559-fix8] A4/A5: адресный отказ trim-sed РЕАЛЬНЫМ скриптом (A4 -- set -e,
  # A5 -- копия set +e): непустой custom-источник, замок и TMPDIR ВНУТРИ него;
  # preflight обязан вернуть rc2 своей ступенью, источник нетронут
  # CONSTRAINT: cwd -- нейтральный $E/cwd67: пустой путь источника разрешался бы
  # realpath в cwd, и исход не зависел бы от места запуска зубов
  local k67 kit67
  for k67 in A4 A5; do
    kit67="$SCRIPT"
    [[ "$k67" == A5 ]] && kit67="$kitA2/claude-patch-all.sh"
    rm -rf "$E/state-k" || { instr_bad "состояние мока не очищено ($k67)"; return; }
    mk_run mkdir -p "$E/state-k" || { instr_bad "состояние мока не создано ($k67)"; return; }
    snap_to "$E/t67s-src" "$E/snap67s.A" || { instr_bad "снимок источника A не снят ($k67)"; return; }
    isnap_to "$E/t67s-src" "$E/isnap67s.A" || { instr_bad "inode-снимок источника A не снят ($k67)"; return; }
    rc=0
    out=$(cd "$E/cwd67" && env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
            -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
            -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
            HOME="$E/home" TMPDIR="$E/t67s-src/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
            CLAUDE_PATCH_SKIP_KIT_BENCH=1 T67_STATE="$E/state-k" \
            PATH="$E/sedbinK:$PATH" \
            TWEAKCC_CONFIG_DIR="$E/t67s-src" CLAUDE_PATCH_LOCK="$E/t67s-src/kit.lock" \
            timeout 120 bash "$kit67" --target "$E/img/fake-target" 2>&1) || rc=$?
    # предмет до rc-вердикта: дерево источника (включая замок и TMPDIR внутри)
    snap_to "$E/t67s-src" "$E/snap67s.B" || { instr_bad "снимок источника B не снят ($k67)"; return; }
    isnap_to "$E/t67s-src" "$E/isnap67s.B" || { instr_bad "inode-снимок источника B не снят ($k67)"; return; }
    t67_cl=0
    changed "$E/snap67s.A" "$E/snap67s.B" || t67_cl=$?
    if [[ $t67_cl -eq 2 ]]; then instr_bad "отказ diff снимков источника ($k67)"; return; fi
    [[ $t67_cl -eq 1 ]] || t67_fail="$t67_fail $k67:источник-байты/mtime"
    cmp -s "$E/isnap67s.A" "$E/isnap67s.B" || t67_fail="$t67_fail $k67:источник-inode"
    [[ ! -e "$E/t67s-src/kit.lock" ]] || t67_fail="$t67_fail $k67:замок-создан"
    [[ $rc -eq 2 ]] || t67_fail="$t67_fail $k67:rc=$rc"
    [[ "$out" == *'T67MOCK: trim-sed отказ #1'* ]] || t67_fail="$t67_fail $k67:отказ-не-достигнут"
    [[ "$out" == *'ПРИБОР НЕДОСТУПЕН: trim TWEAKCC_CONFIG_DIR не выполнен'* ]] \
      || t67_fail="$t67_fail $k67:без-предмета"
    [[ "$out" != *'путь источника конфигурации пуст'* ]] || t67_fail="$t67_fail $k67:отказ-не-своей-ступени"
    [[ "$out" != *'Изоляция target'* && "$out" != *'не нативный образ'* ]] \
      || t67_fail="$t67_fail $k67:CLI/дверь-образа"
  done
  # --- B: точечные отказы ТОЛЬКО на activate (после preflight и разрешённого
  # замка) -- подлинная последовательность helper preflight -> exec 9>> ->
  # activate; ступени: второе разрешение источника, разрешение TMPDIR, страж
  # TMPDIR, trim-sed, пустой путь источника; режимы e (set -euo pipefail, формы
  # вызова кита) и p (set +e)
  # CONSTRAINT: замок существует ДО прогона (прежний прогон) -- его байты/mtime/
  # inode свидетельствуют, что отказ activate не пишет в замок; открытие
  # доказывает маркер T67_LOCK_OPEN после exec 9>>
  t67_wrapB() {  # $1 обёртка, $2 helper, $3 режим e|p (по умолчанию p), $4 строка перед activate ('' -- нет)
    {
      printf '#!/usr/bin/env bash\n' &&
      if [[ "${3:-p}" == e ]]; then printf 'set -euo pipefail\n'; else printf 'set +e\n'; fi &&
      printf 'cd %q || exit 3\n' "$E/cwd67" &&
      printf 'export HOME=%q\n' "$E/home" &&
      printf 'export TMPDIR=%q\n' "$E/tmp" &&
      printf 'export TWEAKCC_LOCAL=%q\n' "$E/local-unpacker.mjs" &&
      printf 'export CATALYST_TWEAKCC_CACHE=%q\n' "$E/cache/catalyst-tweakcc" &&
      printf 'export TWEAKCC_CONFIG_DIR=%q\n' "$E/t67-src" &&
      printf 'source %q\n' "$2" &&
      if [[ "${3:-p}" == e ]]; then
        printf 'if target_isolation_preflight %q; then echo "T67_PF_RC=0"; else r=$?; echo "T67_PF_RC=$r"; exit "$r"; fi\n' "$E/t67.act.lock"
      else
        printf 'target_isolation_preflight %q\n' "$E/t67.act.lock" &&
        printf 'echo "T67_PF_RC=$?"\n'
      fi &&
      printf 'exec 9>>%q\n' "$E/t67.act.lock" &&
      printf 'echo T67_LOCK_OPEN\n' &&
      { [[ -z "${4:-}" ]] || printf '%s\n' "$4"; } &&
      printf 'target_isolation_activate\n' &&
      printf 'echo "T67_ACT_RC=$?"\n' &&
      printf 'echo "TI_ROOT=${TARGET_ISOLATION_ROOT:-}"\n' &&
      printf 'echo WIRE_DONE\n'
    } > "$1"
  }
  t67_temp() {  # -> stdout: первый собственный temp в $E/tmp ('' -- нет); отказ find -- rc2
    find "$E/tmp" -maxdepth 1 -name 'cc-target-isolation.*' -print -quit || return 2
  }
  # CONSTRAINT: прогон B/мутанта начинается с НОВОГО замка с известными
  # байтами и без собственного temp -- иначе след прежнего прогона читался бы
  # свидетелем текущего
  t67_pre() {  # $1 метка; 0 -- замок заложен, temp нет; 2 -- отказ прибора
    local tp
    rm -rf "$E/state" || return 2
    mkdir -p "$E/state" || return 2
    rm -f -- "$E/t67.act.lock" || return 2
    printf 'prev-run-lock-%s\n' "$1" > "$E/t67.act.lock" || return 2
    cp -p -- "$E/t67.act.lock" "$E/t67.act.lock.orig" || return 2
    stat -c '%.9Y %i' -- "$E/t67.act.lock" > "$E/t67.act.lock.meta" || return 2
    tp="$(t67_temp)" || return 2
    [[ -z "$tp" ]] || return 2
  }
  local -a bst67=(
    "src|$E/pybinC||T67MOCK: src-разрешение #2|не разрешён полный путь $E/t67-src|"
    "tmp|$E/pybinT||T67MOCK: tmp-разрешение #2|не разрешён полный путь $E/tmp|"
    "guard|$E/pybinH||T67MOCK: home-разрешение #3|не разрешён полный путь $E/home|"
    "sed|$E/sedbin67||T67MOCK: trim-sed отказ #2|trim TWEAKCC_CONFIG_DIR не выполнен|путь источника конфигурации пуст"
    "empty||__ti_source_path() { :; }||путь источника конфигурации пуст|"
  )
  local sp67 bk67 pd67 ov67 reach67 pat67 forb67 md67 rest67 path67 meta67 want67 tp67
  for sp67 in "${bst67[@]}"; do
    bk67="${sp67%%|*}"; rest67="${sp67#*|}"
    pd67="${rest67%%|*}"; rest67="${rest67#*|}"
    ov67="${rest67%%|*}"; rest67="${rest67#*|}"
    reach67="${rest67%%|*}"; rest67="${rest67#*|}"
    pat67="${rest67%%|*}"; forb67="${rest67#*|}"
    for md67 in e p; do
      t67_pre "$bk67.$md67" || { instr_bad "замок/temp B не заложены ($bk67/$md67)"; return; }
      snap_to "$E/t67-src" "$E/snap67.A" || { instr_bad "снимок источника A не снят ($bk67/$md67)"; return; }
      isnap_to "$E/t67-src" "$E/isnap67.A" || { instr_bad "inode-снимок источника A не снят ($bk67/$md67)"; return; }
      t67_wrapB "$E/wrapB.$bk67.$md67.sh" "$HELPER" "$md67" "$ov67" \
        || { instr_bad "обёртка B не записана ($bk67/$md67)"; return; }
      path67="$PATH"
      [[ -z "$pd67" ]] || path67="$pd67:$PATH"
      rc=0
      out=$(env -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u TARGET_ISOLATION_ROOT \
              -u TARGET_ISOLATION_OWNER_TOKEN \
              T67_STATE="$E/state" PATH="$path67" bash "$E/wrapB.$bk67.$md67.sh" 2>&1) || rc=$?
      printf '%s\n' "$out" > "$E/t67.B.$bk67.$md67.out" \
        || { instr_bad "вывод B не записан ($bk67/$md67)"; return; }
      # предмет до rc-вердикта: источник, замок, собственный temp
      snap_to "$E/t67-src" "$E/snap67.B" || { instr_bad "снимок источника B не снят ($bk67/$md67)"; return; }
      isnap_to "$E/t67-src" "$E/isnap67.B" || { instr_bad "inode-снимок источника B не снят ($bk67/$md67)"; return; }
      t67_cl=0
      changed "$E/snap67.A" "$E/snap67.B" || t67_cl=$?
      if [[ $t67_cl -eq 2 ]]; then instr_bad "отказ diff снимков источника ($bk67/$md67)"; return; fi
      [[ $t67_cl -eq 1 ]] || t67_fail="$t67_fail B-$bk67/$md67:источник-байты/mtime"
      cmp -s "$E/isnap67.A" "$E/isnap67.B" || t67_fail="$t67_fail B-$bk67/$md67:источник-inode"
      cmp -s "$E/t67.act.lock" "$E/t67.act.lock.orig" || t67_fail="$t67_fail B-$bk67/$md67:замок-байты"
      meta67="$(stat -c '%.9Y %i' -- "$E/t67.act.lock")" \
        || { instr_bad "stat замка не снят ($bk67/$md67)"; return; }
      want67="$(cat -- "$E/t67.act.lock.meta")" \
        || { instr_bad "метаданные замка ДО не прочитаны ($bk67/$md67)"; return; }
      [[ -n "$want67" && "$meta67" == "$want67" ]] || t67_fail="$t67_fail B-$bk67/$md67:замок-mtime/inode"
      tp67="$(t67_temp)" || { instr_bad "отказ find temp ($bk67/$md67)"; return; }
      [[ -z "$tp67" ]] || t67_fail="$t67_fail B-$bk67/$md67:temp-создан"
      [[ $rc -eq 2 ]] || t67_fail="$t67_fail B-$bk67/$md67:rc=$rc"
      [[ "$out" == *'T67_PF_RC=0'* ]] || t67_fail="$t67_fail B-$bk67/$md67:preflight-не-прошёл"
      [[ "$out" == *'T67_LOCK_OPEN'* ]] || t67_fail="$t67_fail B-$bk67/$md67:замок-не-открыт"
      [[ -z "$reach67" || "$out" == *"$reach67"* ]] || t67_fail="$t67_fail B-$bk67/$md67:отказ-не-на-activate"
      [[ "$out" == *'ПРИБОР НЕДОСТУПЕН'* && "$out" == *"$pat67"* ]] \
        || t67_fail="$t67_fail B-$bk67/$md67:без-предмета"
      [[ -z "$forb67" || "$out" != *"$forb67"* ]] || t67_fail="$t67_fail B-$bk67/$md67:отказ-не-своей-ступени"
      [[ "$out" != *'T67_ACT_RC='* && "$out" != *'Изоляция target'* ]] \
        || t67_fail="$t67_fail B-$bk67/$md67:activate-вернулся/CLI"
      if [[ -n "$tp67" ]]; then
        rm -rf -- "$tp67" || { instr_bad "собственный temp B не убран ($bk67/$md67)"; return; }
      fi
    done
  done
  if [[ -n "$t67_fail" ]]; then bad "T67 отказ resolver:$t67_fail"; return; fi
  # --- M1: снят явный условный выход после preflight (set +e копия) -- замок
  # СОЗДАЁТСЯ при проигнорированном отказе: мутант пойман по файлу замка.
  # CONSTRAINT: мутант тоже живёт в кит-образном каталоге (см. A2)
  local kitM1="$E/kitM1"
  mk_run mkdir -p "$kitM1/tools" || { instr_bad 'фикстура: каталог мутанта M1 не создан'; return; }
  mutate_one "$SCRIPT" "$kitM1/claude-patch-all.sh" '^    # \[559-fix7\] ворота: выход именным кодом' \
    '^    exit "\$\?"$' '    true' \
    || { bad 'T67 (M1) мутация не заложена: явного условного выхода на дереве нет'; return; }
  bash -n "$kitM1/claude-patch-all.sh" || { bad 'T67 (M1) мутант не парсится'; return; }
  for f67 in "$KIT"/tools/*; do
    b67="$(basename "$f67")" || { bad 'T67 (M1) ПРИБОР НЕДОСТУПЕН: отказ basename инструментов кита'; return; }
    mk_run ln -s "$f67" "$kitM1/tools/$b67" || { instr_bad "фикстура: ссылка инструмента M1 не заложена ($b67)"; return; }
  done
  mk_run sed -i 's|^set -euo pipefail$|set -euo pipefail; set +e|' "$kitM1/claude-patch-all.sh" \
    || { instr_bad 'фикстура: sed set +e мутанта M1 отказал'; return; }
  local n67m
  n67m=$(count_matches '^set -euo pipefail; set +e$' "$kitM1/claude-patch-all.sh") \
    || { bad 'T67 (M1) ПРИБОР НЕДОСТУПЕН: отказ grep set +e'; return; }
  [[ "$n67m" == 1 ]] \
    || { bad 'T67 (M1) set +e не наложен на мутант'; return; }
  rc=0
  out=$(env -u CLAUDE_PATCH_SKIP_MODELS -u TWEAKCC_CONFIG_DIR -u CATALYST_TWEAKCC_CACHE \
          -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u CLAUDE_PATCH_LOCK_HELD_BY \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          HOME="$E/home" TMPDIR="$E/tmp" TWEAKCC_LOCAL="$E/local-unpacker.mjs" \
          CLAUDE_PATCH_SKIP_KIT_BENCH=1 \
          PATH="$E/pybinA:$PATH" \
          timeout 120 bash "$kitM1/claude-patch-all.sh" --target "$E/img/fake-target" 2>&1) || rc=$?
  [[ -e "$E/tmp/claude-patch-all.$uid.lock" ]] \
    || { bad 'T67 (M1) ВАКУУМНАЯ ЗЕЛЕНЬ: замок не создан при снятом условном выходе (set +e)'; return; }
  # --- M2: снят rc-guard activate (источник без || exit 2) -- под set +e
  # активация продолжает с пустым src_real; исход -- код, отличный от 2
  # (страж TMPDIR с пустым владельцем даёт rc6), либо собственный temp;
  # пойман тот и другой, совпадение rc2 без temp -- вакуумная зелень
  local m2="$E/mut-act-norc.sh"
  mutate_one "$HELPER" "$m2" '^  # \[559-fix7\] ворота: отказ разрешения источника' \
    '^  src_real="\$\(__ti_real "\$src_path" "источника"\)" \|\| exit \$\?$' \
    '  src_real="$(__ti_real "$src_path" "источника")"' \
    || { bad 'T67 (M2) мутация не заложена: rc-guard activate на дереве нет'; return; }
  bash -n "$m2" || { bad 'T67 (M2) мутант не парсится'; return; }
  # CONSTRAINT: после N7 пустой tmp_real не ведёт к безопасному TMPDIR;
  # достижение mktemp мерится независимым маркером, без записи в корень ФС.
  local m3="$E/mut-act-tmp.sh" m4="$E/mut-act-guard.sh"
  mutate_one "$HELPER" "$m3" '^  # \[559-fix8\] ворота: разрешение TMPDIR в activate' \
    '^  tmp_real="\$\(__ti_real "\$\{TMPDIR:-/tmp\}" TMPDIR\)" \|\| exit \$\?$' \
    '  tmp_real="$(__ti_real "${TMPDIR:-/tmp}" TMPDIR)"' \
    || { bad 'T67 (M3) мутация не заложена: rc-guard разрешения TMPDIR activate на дереве нет'; return; }
  bash -n "$m3" || { bad 'T67 (M3) мутант не парсится'; return; }
  mutate_one "$HELPER" "$m4" '^  # \[559-fix8\] ворота: страж TMPDIR в activate' \
    '^  __ti_guard_tmp "\$tmp_real" "\$src_real" \|\| exit \$\?$' \
    '  __ti_guard_tmp "$tmp_real" "$src_real"' \
    || { bad 'T67 (M4) мутация не заложена: rc-guard стража TMPDIR activate на дереве нет'; return; }
  bash -n "$m4" || { bad 'T67 (M4) мутант не парсится'; return; }
  local ms67 mk67 mh67 mp67 mt67 ov_mut
  for ms67 in "M2|$m2|$E/pybinC" "M3|$m3|$E/pybinT" "M4|$m4|$E/pybinH"; do
    mk67="${ms67%%|*}"; mh67="${ms67#*|}"; mh67="${mh67%%|*}"; mp67="${ms67##*|}"
    t67_pre "$mk67" || { instr_bad "замок/temp мутанта не заложены ($mk67)"; return; }
    printf -v ov_mut 'mktemp(){ printf called > %q; return 1; }' "$E/$mk67.mktemp"
    t67_wrapB "$E/wrap.$mk67.sh" "$mh67" p "$ov_mut" || { instr_bad "обёртка мутанта не записана ($mk67)"; return; }
    rc=0
    out=$(env -u XDG_CONFIG_HOME -u CLAUDE_PATCH_LOCK -u TARGET_ISOLATION_ROOT \
            -u TARGET_ISOLATION_OWNER_TOKEN \
            T67_STATE="$E/state" PATH="$mp67:$PATH" bash "$E/wrap.$mk67.sh" 2>&1) || rc=$?
    if [[ $rc -eq 2 && ! -s "$E/$mk67.mktemp" ]]; then
      bad "T67 ($mk67) ВАКУУМНАЯ ЗЕЛЕНЬ: снятие rc-guard activate не достигло mktemp и не сменило код (rc=2)"
      return
    fi
  done
  ok 'T67 отказ resolver (счётчики только формы -c): полный (set -e и set +e) и точечный (замок) -- exit2 без замка/temp/CLI реальным скриптом; адресный trim-sed реальным скриптом (set -e и set +e) -- rc2 своей ступенью, custom-источник с замком и TMPDIR внутри нетронут; точечные на activate (второе разрешение источника, TMPDIR, страж TMPDIR, trim-sed, пустой путь; set -e и set +e) -- exit2 после разрешённого замка, замок/источник нетронуты, temp/CLI нет (последовательность preflight -> замок -> activate подлинным helper); снятие условного выхода краснеет созданием замка, снятие rc-guard источника/TMPDIR/стража activate -- temp/кодом'
}

# T68: [559-fix7] владелец "/" в __ti_guard_inside: вызов ТОЛЬКО helper-preflight
# в изолированной оболочке, TWEAKCC_CONFIG_DIR=/ и безопасный TMPDIR/замок под
# синтетическим /tmp дают rc6 БЕЗ открытия замка, создания temp и CLI. Прежняя
# форма "$2"/* при владельце / ищет // и возвращает rc0 -- мутант краснеет по
# неверному разрешению; файл в живом / при RED НЕ открывается (обёртка только
# читает).
t68() {
  RAN=$((RAN + 1))
  if [[ ! -f "$HELPER" ]]; then bad 'T68 helper отсутствует (приборная)'; return; fi
  mk_env || { bad 'T68 ПРИБОР НЕДОСТУПЕН: отказ сборки фикстуры'; return; }
  t68_wrap() {  # $1 helper, $2 обёртка; отказ записи -- rc2
    {
      printf '#!/usr/bin/env bash\n' &&
      printf 'set +e\n' &&
      printf 'export HOME=%q\n' "$E/home" &&
      printf 'export TMPDIR=%q\n' "$E/tmp" &&
      printf 'export TWEAKCC_CONFIG_DIR=/\n' &&
      printf 'source %q\n' "$1" &&
      printf 'target_isolation_preflight "%s"\n' "$E/t68.lock" &&
      printf 'echo "T68_RC=$?"\n' &&
      printf 'echo WIRE_DONE\n'
    } > "$2" || return 2
  }
  local rc=0 out t68_rc
  t68_wrap "$HELPER" "$E/wrap68.sh" || { instr_bad 'фикстура: обёртка T68 не записана'; return; }
  # CONSTRAINT: rc6 стража -- это exit ВСЕЙ оболочки обёртки (страж в helper
  # зовёт exit, не return), поэтому вердикт -- код самой обёртки, а не
  # напечатанный маркер: строки после отказа не исполняются
  out=$(env -u XDG_CONFIG_HOME -u CATALYST_TWEAKCC_CACHE -u CLAUDE_PATCH_LOCK \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          bash "$E/wrap68.sh" 2>&1) || rc=$?
  if [[ $rc -ne 6 ]]; then
    bad "T68 источник / не охраняется: rc=$rc (ждали 6) :: $(printf '%s' "$out" | tr '\n' ';')"
    return
  fi
  [[ "$out" == *'лежит внутри'* ]] || { bad 'T68 отказ не назвал предмет (лежит внутри)'; return; }
  [[ ! -e "$E/t68.lock" ]] || { bad 'T68 замок создан на пути, проверяемом только чтением'; return; }
  local f68
  f68=$(find "$E/tmp" -maxdepth 1 -name 'cc-target-isolation.*' -print -quit) \
    || { bad 'T68 ПРИБОР НЕДОСТУПЕН: отказ find temp'; return; }
  [[ -z "$f68" ]] \
    || { bad 'T68 preflight создал temp'; return; }
  # мутант прежней формы: ветка корня снята -- остаётся elif со старым шаблоном
  # "$2"/*, который при владельце / обращается в // и источник / не охраняет:
  # обёртка ДОЖИВАЕТ до конца и печатает rc0 -- контроль чувствительности
  local mut="$E/mut-root.sh"
  mutate_one "$HELPER" "$mut" '^  # \[559-fix7\] ворота: владелец /' \
    '^  if \[\[ "\$2" == "/" \]\]; then$' '  if false; then' \
    || { bad 'T68 мутация не заложена: ветки корня на дереве нет'; return; }
  bash -n "$mut" || { bad 'T68 мутант не парсится'; return; }
  t68_wrap "$mut" "$E/wrap68m.sh" || { instr_bad 'фикстура: обёртка мутанта T68 не записана'; return; }
  rc=0
  out=$(env -u XDG_CONFIG_HOME -u CATALYST_TWEAKCC_CACHE -u CLAUDE_PATCH_LOCK \
          -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
          bash "$E/wrap68m.sh" 2>&1) || rc=$?
  t68_rc="$(set -o pipefail; printf '%s\n' "$out" | sed -n 's/^T68_RC=//p' | tail -1)" \
    || { bad 'T68 (мутант) ПРИБОР НЕДОСТУПЕН: отказ reader T68_RC'; return; }
  if [[ $rc -ne 0 || "$t68_rc" != 0 ]]; then
    bad "T68 (мутант) прежняя форма не зелёнеет на источнике /: rc=$rc T68_RC=${t68_rc:-нет} -- контроль нечувствителен :: $(printf '%s' "$out" | tr '\n' ';')"
    return
  fi
  [[ ! -e "$E/t68.lock" ]] || { bad 'T68 (мутант) замок создан'; return; }
  # --- [559-fix8] корневые границы __ti_guard_protected: защищённый дом / (a),
  # кандидат / -- TMPDIR и путь замка (b), HOME=/ с кандидатом-предком
  # защищённого дома (c); положительный контроль -- системный /tmp при
  # синтетическом HOME внутри tmp
  # CONSTRAINT: обёртка зовёт ТОЛЬКО preflight -- ни mktemp, ни открытия замка:
  # и продукт, и мутант прежней формы не пишут в /
  mk_run mkdir -p "$E/cwd68" "$E/t68-src" || { instr_bad 'каталоги корневых границ не созданы'; return; }
  t68_pwrap() {  # $1 helper, $2 обёртка, $3 HOME, $4 TMPDIR, $5 путь замка, $6 CATALYST_TWEAKCC_CACHE ('' -- не задан)
    {
      printf '#!/usr/bin/env bash\n' &&
      printf 'set +e\n' &&
      printf 'cd %q || exit 3\n' "$E/cwd68" &&
      printf 'export HOME=%q\n' "$3" &&
      printf 'export TMPDIR=%q\n' "$4" &&
      printf 'export TWEAKCC_CONFIG_DIR=%q\n' "$E/t68-src" &&
      { [[ -z "$6" ]] || printf 'export CATALYST_TWEAKCC_CACHE=%q\n' "$6"; } &&
      printf 'source %q\n' "$1" &&
      printf 'target_isolation_preflight %q || exit $?\n' "$5" &&
      printf 'echo "T68_RC=$?"\n' &&
      printf 'echo WIRE_DONE\n'
    } > "$2"
  }
  # случай: ключ|HOME|TMPDIR|путь замка|кэш|ждан rc|предмет|маркер мутанта|строка мутанта
  local -a rt68=(
    "a|$E/home|$E/tmp|$E/t68a.lock|/|6|идентичность предка||"
    "b-tmp|$E/home|/|$E/t68b.lock||6|TMPDIR (/) -- корень ФС|^    # \\[559-fix8\\] ворота: кандидат / -- предок|^    if \\[\\[ \"\\\$1\" == \"/\" \\]\\]; then\$"
    "b-lock|$E/home|$E/tmp|/||6|путь замка (/) -- корень ФС|^    # \\[559-fix8\\] ворота: кандидат / -- предок|^    if \\[\\[ \"\\\$1\" == \"/\" \\]\\]; then\$"
    "c|/|/.local|$E/t68c.lock||6|внутри живого HOME (/)|^      # \\[559-fix8\\] ворота: HOME / -- любой абсолютный|^      if \\[\\[ \"\\\$home_real\" == \"/\" && \"\\\$1\" == /\\* \\]\\]; then\$"
    "pos|$E/home|/tmp|$E/t68p.lock||0|||"
  )
  local sp68 rk68 rh68 rt68v rl68 rc68c rw68 rp68 rm68 rs68 out68 rc68 pf68 t68_fail='' mind68 ind68
  for sp68 in "${rt68[@]}"; do
    IFS='|' read -r rk68 rh68 rt68v rl68 rc68c rw68 rp68 rm68 rs68 <<< "$sp68" \
      || { instr_bad "случай корневой границы не разобран: $sp68"; return; }
    t68_pwrap "$HELPER" "$E/wrap68.$rk68.sh" "$rh68" "$rt68v" "$rl68" "$rc68c" \
      || { instr_bad "обёртка корневой границы не записана ($rk68)"; return; }
    rc68=0
    out68=$(env -u XDG_CONFIG_HOME -u CATALYST_TWEAKCC_CACHE -u CLAUDE_PATCH_LOCK \
              -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
              bash "$E/wrap68.$rk68.sh" 2>&1) || rc68=$?
    [[ $rc68 -eq $rw68 ]] || t68_fail="$t68_fail $rk68:rc=$rc68"
    if [[ "$rw68" == 0 ]]; then
      [[ "$out68" == *'T68_RC=0'* ]] || t68_fail="$t68_fail $rk68:T68_RC-не-0"
    else
      [[ "$out68" == *'FATAL: изоляция target'* && "$out68" == *"$rp68"* ]] || t68_fail="$t68_fail $rk68:без-предмета"
      [[ "$out68" != *'T68_RC='* ]] || t68_fail="$t68_fail $rk68:preflight-вернулся"
    fi
    if [[ "$rl68" != / && -e "$rl68" ]]; then t68_fail="$t68_fail $rk68:замок-создан"; fi
    mind68="$(find "$E/tmp" -maxdepth 1 -name 'cc-target-isolation.*' -print -quit)" \
      || { instr_bad "отказ find temp ($rk68)"; return; }
    [[ -z "$mind68" ]] || t68_fail="$t68_fail $rk68:temp-создан"
  done
  # предметный вердикт ДО мутантов: отсутствие якоря мутанта не заслоняет rc предмета
  if [[ -n "$t68_fail" ]]; then bad "T68 корневые границы защищённых домов:$t68_fail"; return; fi
  for sp68 in "${rt68[@]}"; do
    IFS='|' read -r rk68 rh68 rt68v rl68 rc68c rw68 rp68 rm68 rs68 <<< "$sp68" \
      || { instr_bad "случай корневой границы не разобран: $sp68"; return; }
    # мутант прежней формы ветки: корень снова обращается в // -- обёртка
    # доживает до конца и печатает rc0 (контроль чувствительности ветки)
    [[ -n "$rm68" ]] || continue
    ind68="${rs68%%if*}"; ind68="${ind68#^}"
    mutate_one "$HELPER" "$E/mut-root.$rk68.sh" "$rm68" "$rs68" "${ind68}if false; then" \
      || { bad "T68 ($rk68) мутация не заложена: корневой ветки на дереве нет"; return; }
    bash -n "$E/mut-root.$rk68.sh" || { bad "T68 ($rk68) мутант не парсится"; return; }
    t68_pwrap "$E/mut-root.$rk68.sh" "$E/wrap68m.$rk68.sh" "$rh68" "$rt68v" "$rl68" "$rc68c" \
      || { instr_bad "обёртка мутанта корневой границы не записана ($rk68)"; return; }
    rc68=0
    out68=$(env -u XDG_CONFIG_HOME -u CATALYST_TWEAKCC_CACHE -u CLAUDE_PATCH_LOCK \
              -u TARGET_ISOLATION_ROOT -u TARGET_ISOLATION_OWNER_TOKEN \
              bash "$E/wrap68m.$rk68.sh" 2>&1) || rc68=$?
    pf68="$(set -o pipefail; printf '%s\n' "$out68" | sed -n 's/^T68_RC=//p' | tail -1)" \
      || { instr_bad "отказ reader T68_RC мутанта ($rk68)"; return; }
    if [[ $rc68 -ne 0 || "$pf68" != 0 ]]; then
      t68_fail="$t68_fail $rk68:мутант-не-зеленеет(rc=$rc68,T68_RC=${pf68:-нет})"
    fi
    if [[ "$rl68" != / && -e "$rl68" ]]; then t68_fail="$t68_fail $rk68:мутант-замок-создан"; fi
  done
  if [[ -n "$t68_fail" ]]; then bad "T68 корневые границы защищённых домов (мутанты):$t68_fail"; return; fi
  ok 'T68 источник /: preflight rc6 без замка/temp, прежняя форма "$2"/* даёт rc0 и ловится мутантом; защищённый дом / отвергнут идентичностью предка; кандидат / для TMPDIR/замка и HOME=/ -- rc6 по предмету, прежняя форма их веток даёт rc0; системный /tmp при синтетическом HOME разрешён'
}

# CONSTRAINT: каждый случай получает отдельную фикстуру; ненулевой rc Python
# и текст предметного отказа сохраняются до вердикта зуба.
fix9_case() {
  local label="$1" key="$2" rc=0 out
  RAN=$((RAN + 1))
  mk_env || { instr_bad 'фикстура FIX9 не создана'; return; }
  out=$(python3 - "$key" "$E" "$HELPER" "$SCRIPT" <<'PYFIX9'
import os, pathlib, re, subprocess, sys
key, directory, helper, script = sys.argv[1:]
r = pathlib.Path(directory)
h = r / 'home'
t = r / 'tmp'
env = dict(os.environ, HOME=str(h), TMPDIR=str(t), CATALYST_TWEAKCC_SHA='synthetic')
for name in ('TWEAKCC_CONFIG_DIR', 'CATALYST_TWEAKCC_CACHE', 'XDG_CONFIG_HOME',
             'TARGET_ISOLATION_ROOT', 'TARGET_ISOLATION_OWNER_TOKEN', 'TWEAKCC_LOCAL'):
    env.pop(name, None)

def run(body, *args, extra=None):
    e = dict(env)
    if extra:
        e.update(extra)
    z = subprocess.run(['bash', '-c', 'source "$1"; ' + body, '_', helper,
                        *map(str, args)], env=e, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    print('CASE=%s RC=%d' % (key, z.returncode))
    print(z.stdout, end='')
    return z

def require(value, message):
    if not value:
        print('FAIL: ' + message)
        sys.exit(1)

def reject(extra, lock, handle):
    z = run('target_isolation_preflight "$2"', lock, extra=extra)
    require(z.returncode == 6 and handle in z.stdout, 'rc6 with handle ' + handle)
    require(not lock.exists(), 'lock created')
    require(not list(r.rglob('cc-target-isolation.*')), 'temp created')

if key == 'newline-source':
    s = r / 'source\n leaf'; s.mkdir()
    reject({'TWEAKCC_CONFIG_DIR': str(s)}, s / 'run.lock', 'TWEAKCC_CONFIG_DIR')
elif key == 'newline-real':
    s = r / 'tail\n'; s.mkdir(); (s / 'tmp').mkdir()
    ht = r / 'home-tail'; ht.mkdir(); (ht / '.tweakcc').symlink_to(s)
    reject({'HOME': str(ht)}, r / 'safe.lock', 'источника')
elif key == 'versions':
    v = h / '.local/share/claude/versions'; v.mkdir(parents=True)
    reject({'TMPDIR': str(v)}, r / 'safe.lock', 'TMPDIR')
    reject({}, v / 'run.lock', 'путь замка')
    n = h / '.local/share/claude-neighbor'; n.mkdir()
    z = run('target_isolation_preflight "$2"', n / 'run.lock', extra={'TMPDIR': str(n)})
    require(z.returncode == 0, 'neighbor rejected')
elif key == 'chmod':
    z = run('trap target_isolation_cleanup EXIT; chmod(){ return 1; }; target_isolation_activate')
    require(z.returncode == 2 and '0700' in z.stdout, 'chmod refusal not reached')
    require(not list(t.glob('cc-target-isolation.*')), 'chmod left temp')
elif key == 'marker':
    z = run('trap target_isolation_cleanup EXIT; printf(){ case "${2:-}" in ti-*) return 1 ;; esac; builtin printf "$@"; }; target_isolation_activate')
    require(z.returncode == 2 and 'отметка владения' in z.stdout, 'marker refusal not reached')
    require(not list(t.glob('cc-target-isolation.*')), 'marker left temp')
    z = run('trap target_isolation_cleanup EXIT; printf(){ case "${2:-}" in ti-*) builtin printf foreign > "$TARGET_ISOLATION_ROOT/foreign"; return 1 ;; esac; builtin printf "$@"; }; target_isolation_activate')
    require(z.returncode == 2, 'foreign-entry refusal code')
    roots = list(t.glob('cc-target-isolation.*'))
    require(len(roots) == 1 and (roots[0] / 'foreign').read_text() == 'foreign',
            'foreign entry removed')
    require(not (roots[0] / '.catalyst-ti-owner').exists(), 'failed marker left')
    require(str(roots[0]) in z.stdout, 'refusal did not name root')
elif key in ('basename', 'marker-reader'):
    mock = 'basename' if key == 'basename' else 'sed'
    z = run('target_isolation_activate; ' + mock + '(){ echo SYNTHETIC_FAILURE >&2; return 1; }; '
            'target_isolation_cleanup; rc=$?; [[ -d "$TARGET_ISOLATION_ROOT" ]] || exit 99; exit "$rc"')
    require(z.returncode != 0 and z.returncode != 99 and 'SYNTHETIC_FAILURE' in z.stdout,
            'cleanup failure swallowed or temp removed')
elif key == 'relative':
    (r / 'reldir').mkdir()
    z = run('cd "$2"; trap target_isolation_cleanup EXIT; target_isolation_activate; '
            '[[ "$TARGET_ISOLATION_ROOT" == /* ]] || exit 99', r, extra={'TMPDIR': 'reldir'})
    require(z.returncode == 0, 'relative TMPDIR did not produce absolute root')
    require(not list((r / 'reldir').glob('cc-target-isolation.*')), 'relative temp left')
elif key == 'glob':
    hg = r / 'home[1]*'; (hg / '.cache/x').mkdir(parents=True)
    reject({'HOME': str(hg), 'TMPDIR': str(hg / '.cache/x')}, r / 'safe.lock',
           'лежит внутри защищённого живого дома/общего кэша')
elif key == 'js-trim':
    s = r / 'unicode-source'; s.mkdir()
    z = run('x=$(__ti_source_path); rc=$?; [[ "$x" == "$2" ]] || exit 99; exit "$rc"', s,
            extra={'TWEAKCC_CONFIG_DIR': ' ﻿' + str(s) + '  '})
    require(z.returncode == 0, 'trim differs from JS whitespace set')
elif key == 'controls':
    for name in ('HOME', 'TMPDIR', 'TWEAKCC_CONFIG_DIR', 'CATALYST_TWEAKCC_CACHE', 'XDG_CONFIG_HOME'):
        for ch in ('\x01', '\t', '\r', '\x7f'):
            reject({name: str(r / ('bad' + ch + 'path'))}, r / 'safe.lock', name)
    reject({}, r / 'bad\x01.lock', 'путь замка')
elif key == 'signal':
    text = pathlib.Path(script).read_text()
    start = text.index('echo "==> Зубы изоляции --target"')
    end = text.index('echo "==> Зубы окна шага 7"', start)
    block = text[start:end]
    for code in (130, 143):
        z = subprocess.run(['bash', '-c', 'bash(){ return %d; }; ' % code + block],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print('SIGNAL=%d RC=%d\n%s' % (code, z.returncode, z.stdout))
        require(z.returncode == code, 'child signal mapped to different code')
elif key == 'python-required':
    text = pathlib.Path(script).read_text()
    start = text.index('__kit_script="$0"')
    end = text.index('if [[ ! -f "$HERE/tools/target-isolation.sh" ]]', start)
    block = text[start:end]
    z = subprocess.run(['bash', '-c', 'command(){ [[ "$*" != "-v python3" ]] || return 1; builtin command "$@"; }; '
                        + block, script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print('PYTHON_REQUIRED_RC=%d\n%s' % (z.returncode, z.stdout))
    require(z.returncode == 2 and 'нет python3' in z.stdout, 'missing python not named')
elif key == 'cold-fd':
    text = pathlib.Path(script).read_text()
    start = text.index('    ( cd "$dir.tmp"')
    end = text.index('|| { echo "ERROR: unpacker build failed', start)
    block = re.sub(r'\\\s*$', '', text[start:end].rstrip())
    d = r / 'build.tmp'; d.mkdir()
    body = 'dir="$1/build"; exec 9>"$1/fd.lock"; __ti_cold_wrap(){ bash -c '\
           "'if [[ -e /proc/$$/fd/9 ]]; then echo FD9_IN_CHILD; exit 1; fi'" + '; }; ' + block
    z = subprocess.run(['bash', '-c', body, '_', str(r)],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print('COLD_FD_RC=%d\n%s' % (z.returncode, z.stdout))
    require(z.returncode == 0 and 'FD9_IN_CHILD' not in z.stdout, 'cold child inherited fd9')
else:
    require(False, 'unknown FIX9 case')
print('CASE_OK=' + key)
PYFIX9
  ) || rc=$?
  if [[ $rc -ne 0 ]]; then bad "$label :: ${out//$'\n'/;}"; return; fi
  ok "$label"
}
t69() { fix9_case 'T69 управляющие символы custom-источника A' newline-source; }
t70() { fix9_case 'T70 управляющие символы разрешённого источника B' newline-real; }
t71() { fix9_case 'T71 версии: TMPDIR/замок отвергнуты, сосед разрешён' versions; }
t72() { fix9_case 'T72 отказ chmod убирает собственный temp' chmod; }
t73() { fix9_case 'T73 отказ маркера убирает собственный temp' marker; }
t74() { fix9_case 'T74 отказ basename: ненулевая уборка с причиной, без удаления' basename; }
t75() { fix9_case 'T75 отказ reader маркера: ненулевая уборка с причиной, без удаления' marker-reader; }
t76() { fix9_case 'T76 относительный TMPDIR: абсолютный temp и уборка' relative; }
t77() { fix9_case 'T77 HOME с литеральными [1] и *: rc6' glob; }
t78() { fix9_case 'T78 trim соответствует пробельным символам JS' js-trim; }
t79() { fix9_case 'T79 управляющие символы всех ручек: rc6 до записи' controls; }
t80() { fix9_case 'T80 сигналы дочерней стадии: 130/143 сохранены' signal; }
t81() { fix9_case 'T81 ранний отказ на отсутствии python3 назван' python-required; }
t82() { fix9_case 'T82 холодная сборка не наследует fd9' cold-fd; }

fix10_case() {
  local label="$1" key="$2" out rc=0
  RAN=$((RAN + 1))
  mk_env || { instr_bad 'фикстура FIX10 не создана'; return; }
  out=$(python3 - "$key" "$E" "$HELPER" "$SCRIPT" <<'PYFIX10'
import os, pathlib, subprocess, sys
key, directory, helper, script = sys.argv[1:]
r = pathlib.Path(directory); h = r / 'home'; t = r / 'tmp'
pin = 'a700ade95e2b4114f19dc1697193b863fa2452fd'
env = dict(os.environ, HOME=str(h), TMPDIR=str(t), CATALYST_TWEAKCC_SHA=pin)
for name in ('TWEAKCC_CONFIG_DIR', 'CATALYST_TWEAKCC_CACHE', 'XDG_CONFIG_HOME',
             'TARGET_ISOLATION_ROOT', 'TARGET_ISOLATION_OWNER_TOKEN', 'TWEAKCC_LOCAL',
             'CATALYST_TWEAKCC_REPO'):
    env.pop(name, None)

def require(value, message):
    if not value:
        print('FAIL: ' + message); sys.exit(1)

def execute(body, *args, extra=None, namespace=False):
    e = dict(env); e.update(extra or {})
    cmd = ['bash', '-c', 'source "$1"; ' + body, script, helper, *map(str, args)]
    if namespace:
        cmd = ['unshare', '-rm'] + cmd
    z = subprocess.run(cmd, env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print('CASE=%s RC=%d\n%s' % (key, z.returncode, z.stdout), end='')
    return z

text = pathlib.Path(script).read_text()
if key in ('sha-traversal', 'sha-control', 'sha-grammar', 'repo'):
    start = text.index('CATALYST_TWEAKCC_REPO=')
    end = text.index('# Подменённый источник распаковщика', start)
    block = text[start:end]
    if key == 'repo':
        values = ('owner/.', 'owner/..', '../repo', 'owner/repo\x01', 'owner/repo/extra', '-owner/repo')
        name = 'CATALYST_TWEAKCC_REPO'
    else:
        values = {'sha-traversal': ('../..', '../../escape'),
                  'sha-control': ('x\x01y',),
                  'sha-grammar': ('synthetic', 'A' * 40, 'a' * 39, 'a' * 41, 'main')}[key]
        name = 'CATALYST_TWEAKCC_SHA'
    for value in values:
        z = execute(block, extra={name: value})
        require(z.returncode == 2 and name in z.stdout, name + ' grammar refusal absent')
    z = execute(block, extra={'CATALYST_TWEAKCC_SHA': pin, 'CATALYST_TWEAKCC_REPO': 'owner/repo._-1'})
    require(z.returncode == 0, 'valid grammar rejected')
    if key == 'sha-control':
        z = execute('trap target_isolation_cleanup EXIT; target_isolation_activate',
                    extra={'CATALYST_TWEAKCC_SHA': 'x\x01y'})
        require(z.returncode == 6 and 'кэша' in z.stdout, 'composed cache control refusal absent')
elif key == 'cache-destination':
    src = r / 'cache-source'; (src / pin / 'dist').mkdir(parents=True)
    (src / pin / 'dist/index.mjs').write_text('SYNTHETIC-CACHE\n')
    outside = r / 'outside'; outside.mkdir()
    z = execute('outside="$2"; trap target_isolation_cleanup EXIT; mkdir(){ case "${!#}" in */cc-target-isolation.*/cache) ln -s "$outside" "${!#}"; return $? ;; esac; command mkdir "$@"; }; target_isolation_activate',
                outside, extra={'CATALYST_TWEAKCC_CACHE': str(src)})
    require(z.returncode == 6 and 'назначение кэша' in z.stdout, 'cache destination boundary refusal absent')
    require(not list(outside.iterdir()), 'cache written outside root')
elif key == 'local-control':
    z = execute('target_isolation_preflight "$2"', r / 'safe.lock', extra={'TWEAKCC_LOCAL': 'x\x01y'})
    require(z.returncode == 6 and 'TWEAKCC_LOCAL' in z.stdout, 'local control refusal absent')
    require(not (r / 'safe.lock').exists(), 'local refusal created lock')
elif key in ('bind-tmp', 'bind-lock', 'bind-root', 'identity-layer'):
    v = h / '.local/share/claude/versions'; v.mkdir(parents=True)
    alias = r / 'bind alias'; alias.mkdir()
    owner = v.parent if key in ('bind-root', 'identity-layer') else v
    body = 'mount --bind "$2" "$3" || exit 2; echo BIND_OK; '
    if key == 'bind-lock':
        body += 'target_isolation_preflight "$3/missing/deep/run.lock"'
    elif key == 'identity-layer':
        body += '__ti_guard_identity "$3/missing/deep/run.lock" "путь замка" "$2"'
    else:
        body += 'TMPDIR="$3"; target_isolation_preflight "$4"'
    z = execute(body, owner, alias, r / 'safe.lock', namespace=True)
    require('BIND_OK' in z.stdout, 'bind fixture unavailable')
    require(z.returncode == 6 and ('идентичность' in z.stdout if key == 'identity-layer' else 'защищён' in z.stdout),
            'bind refusal absent for ' + key)
    require(not (alias / 'missing').exists() and not (r / 'safe.lock').exists(), 'bind refusal wrote lock')
elif key == 'mountinfo':
    original = pathlib.Path(helper).read_text()
    altered = original.replace("'/proc/self/mountinfo'", repr(str(r / 'no-mountinfo')))
    copy = r / 'unreadable-helper.sh'; copy.write_text(altered)
    z = execute('source "$2"; __ti_guard_mount_source "$3" TMPDIR "$4"', copy, t, h / '.tweakcc')
    require(z.returncode == 2 and 'ПРИБОР НЕДОСТУПЕН' in z.stdout and 'mountinfo' in z.stdout,
            'mountinfo unreadable refusal absent')
elif key == 'remove':
    z = execute('target_isolation_activate; rm(){ echo SYNTHETIC_REMOVE_FAILURE >&2; return 1; }; target_isolation_cleanup; rc=$?; [[ -d "$TARGET_ISOLATION_ROOT" ]] || exit 99; exit "$rc"')
    require(z.returncode == 2 and 'не убран temp изоляции target' in z.stdout and 'SYNTHETIC_REMOVE_FAILURE' in z.stdout,
            'remove refusal swallowed or root removed')
elif key == 'other-signals':
    start = text.index('echo "==> Зубы изоляции --target"'); end = text.index('echo "==> Зубы окна шага 7"', start)
    for code in (129, 137):
        z = execute('bash(){ return %d; }; ' % code + text[start:end])
        require(z.returncode == 1 and 'стадия зубов убита сигналом %d (rc %d)' % (code - 128, code) in z.stdout,
                'signal stage cause misnamed')
elif key == 'python-launch':
    mock = r / 'python-mock'; mock.mkdir()
    p = mock / 'python3'; p.write_text('#!/usr/bin/env bash\nexit 42\n'); p.chmod(0o700)
    start = text.index('__kit_script="$0"'); end = text.index('if [[ ! -f "$HERE/tools/target-isolation.sh" ]]', start)
    z = execute(text[start:end], extra={'PATH': str(mock) + ':' + env['PATH']})
    require(z.returncode == 2 and 'python3 не запускается (rc 42)' in z.stdout, 'python launch failure misnamed')
else:
    require(False, 'unknown FIX10 case')
print('CASE_OK=' + key)
PYFIX10
  ) || rc=$?
  if [[ $rc -ne 0 ]]; then bad "$label :: ${out//$'\n'/;}"; return; fi
  ok "$label"
}
t83() { fix10_case 'T83 SHA traversal grammar refusal' sha-traversal; }
t84() { fix10_case 'T84 SHA control grammar and composed paths refusal' sha-control; }
t85() { fix10_case 'T85 SHA exact commit grammar' sha-grammar; }
t86() { fix10_case 'T86 cache destination outside root refused before copy' cache-destination; }
t87() { fix10_case 'T87 REPO grammar refusal' repo; }
t88() { fix10_case 'T88 TWEAKCC_LOCAL control refusal' local-control; }
t89() { fix10_case 'T89 bind versions TMPDIR refusal' bind-tmp; }
t90() { fix10_case 'T90 bind versions missing lock refusal' bind-lock; }
t91() { fix10_case 'T91 bind protected root refusal' bind-root; }
t92() { fix10_case 'T92 identity layer refusal independently' identity-layer; }
t93() { fix10_case 'T93 unreadable mountinfo named rc2' mountinfo; }
t94() { fix10_case 'T94 remove failure named rc2 leaves root' remove; }
t95() { fix10_case 'T95 signal 129/137 named cause' other-signals; }
t96() { fix10_case 'T96 python launch failure named rc2' python-launch; }

fix11_case() {
  local label="$1" key="$2" code="${3:-0}" out rc=0
  RAN=$((RAN + 1))
  mk_env || { instr_bad 'фикстура FIX11 не создана'; return; }
  out=$(python3 - "$key" "$code" "$E" "$HELPER" <<'PYFIX11'
import os, pathlib, shutil, subprocess, sys
key, code, directory, helper = sys.argv[1:]
r = pathlib.Path(directory); h = r / 'home'; t = r / 'tmp'
env = dict(os.environ, HOME=str(h), TMPDIR=str(t))
for name in ('TWEAKCC_CONFIG_DIR', 'CATALYST_TWEAKCC_CACHE', 'XDG_CONFIG_HOME',
             'TARGET_ISOLATION_ROOT', 'TARGET_ISOLATION_OWNER_TOKEN', 'TWEAKCC_LOCAL',
             'TARGET_ISOLATION_MOUNTINFO'):
    env.pop(name, None)
lock = r / 'fix11.lock'

def require(value, message):
    if not value:
        print('FAIL: ' + message); sys.exit(1)

def execute(body, *args, namespace=False):
    cmd = ['bash', '-c', 'source "$1"; ' + body, '_', helper, *map(str, args)]
    if namespace:
        cmd = ['unshare', '-rm'] + cmd
    z = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print('CASE=%s/%s RC=%d\n%s' % (key, code, z.returncode, z.stdout), end='')
    return z

if key in ('identity', 'mountinfo'):
    mock = r / 'heredoc-mock'; mock.mkdir()
    py = mock / 'python3'
    needle = 'identities = set()' if key == 'identity' else 'mounts = []'
    real = shutil.which('python3')
    import shlex
    py.write_text('#!/usr/bin/env bash\n'
                  'if [[ "$1" == - ]]; then\n'
                  '  program=$(cat) || exit 99\n'
                  '  if [[ "$program" == *' + shlex.quote(needle) + '* ]]; then\n'
                  '    echo FIX11_HEREDOC_' + key + ' >&2; exit ' + code + '\n'
                  '  fi\n'
                  '  printf "%s\\n" "$program" | ' + shlex.quote(real) + ' "$@"\n'
                  '  exit $?\n'
                  'fi\nexec ' + shlex.quote(real) + ' "$@"\n')
    py.chmod(0o700)
    env['PATH'] = str(mock) + ':' + env['PATH']
    z = execute('if target_isolation_preflight "$2"; then exec 9>>"$2"; target_isolation_activate; else exit $?; fi', lock)
    name = 'идентичность каталогов' if key == 'identity' else 'mountinfo'
    require('FIX11_HEREDOC_' + key in z.stdout, 'target heredoc not reached')
    require(z.returncode == 2 and 'ПРИБОР НЕДОСТУПЕН: %s: python3 rc %s' % (name, code) in z.stdout,
            'unnamed python rc escaped ' + key)
else:
    owner = h / '.local/share/claude'; owner.mkdir(parents=True)
    alias = r / 'bind alias'; alias.mkdir()
    clean = r / 'clean-mountinfo'
    clean.write_bytes(pathlib.Path('/proc/self/mountinfo').read_bytes())
    env['TARGET_ISOLATION_MOUNTINFO'] = str(clean)
    body = ('mount --bind "$2" "$3" || exit 2; echo BIND_OK; '
            '__ti_guard_mount_source "$3" TMPDIR "$2"; rc=$?; '
            'echo MOUNT_CONTROL_RC=$rc; [[ "$rc" == 0 ]] || exit 99; '
            'TMPDIR="$3"; if target_isolation_preflight "$4"; then '
            'exec 9>>"$4"; target_isolation_activate; else exit $?; fi')
    z = execute(body, owner, alias, lock, namespace=True)
    require('BIND_OK' in z.stdout and 'MOUNT_CONTROL_RC=0' in z.stdout, 'clean mountinfo did not pass')
    require(z.returncode == 6 and 'идентичность предка' in z.stdout, 'identity wiring absent')
require(not lock.exists(), 'refusal created lock')
require(not list(t.glob('cc-target-isolation.*')), 'refusal created temp')
print('CASE_OK=%s/%s' % (key, code))
PYFIX11
  ) || rc=$?
  if [[ $rc -ne 0 ]]; then bad "$label :: ${out//$'\n'/;}"; return; fi
  ok "$label"
}
t97() { fix11_case 'T97 identity heredoc rc1 named rc2 before writes' identity 1; }
t98() { fix11_case 'T98 identity heredoc rc42 named rc2 before writes' identity 42; }
t99() { fix11_case 'T99 mountinfo heredoc rc1 named rc2 before writes' mountinfo 1; }
t100() { fix11_case 'T100 mountinfo heredoc rc42 named rc2 before writes' mountinfo 42; }
t101() { fix11_case 'T101 identity wiring with clean mountinfo' wiring; }

fix12_case() {
  local label="$1" key="$2" out rc=0
  RAN=$((RAN + 1))
  mk_env || { instr_bad 'фикстура FIX12 не создана'; return; }
  out=$(python3 - "$key" "$E" "$HELPER" <<'PYFIX12'
import os, pathlib, subprocess, sys
key, directory, helper = sys.argv[1:]
r = pathlib.Path(directory); t = r / 'tmp'; lock = r / 'fix12.lock'
env = dict(os.environ, HOME=str(r / 'home'), TMPDIR=str(t))
for name in ('TWEAKCC_CONFIG_DIR', 'CATALYST_TWEAKCC_CACHE', 'XDG_CONFIG_HOME',
             'TARGET_ISOLATION_ROOT', 'TARGET_ISOLATION_OWNER_TOKEN',
             'TARGET_ISOLATION_MOUNTINFO'):
    env.pop(name, None)

def require(value, message):
    if not value:
        print('FAIL: ' + message); sys.exit(1)

def execute(body, *args):
    z = subprocess.run(['bash', '-c', 'source "$1"; ' + body, '_', helper, *map(str, args)],
                       env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print('CASE=%s RC=%d\n%s' % (key, z.returncode, z.stdout), end='')
    return z

if key == 'real-empty':
    z = execute('__ti_real ""')
    require(z.returncode == 2 and 'target-isolation: пустой путь для разрешения' in z.stdout,
            'empty realpath input did not refuse with rc2')
    z = execute('__ti_real "$2"', t)
    require(z.returncode == 0 and z.stdout == str(t.resolve()) + '\n', 'nonempty realpath control failed')
else:
    before = sorted(str(p.relative_to(t)) for p in t.rglob('*'))
    env['HOME'] = ''
    z = execute('target_isolation_preflight "$2"', lock)
    require(z.returncode == 6 and 'HOME пуст' in z.stdout, 'empty HOME did not refuse with named rc6')
    require(not lock.exists(), 'empty HOME created lock')
    require(before == sorted(str(p.relative_to(t)) for p in t.rglob('*')), 'empty HOME created TMPDIR entries')
print('CASE_OK=' + key)
PYFIX12
  ) || rc=$?
  if [[ $rc -ne 0 ]]; then bad "$label :: ${out//$'\n'/;}"; return; fi
  ok "$label"
}
t102() { fix12_case 'T102 real empty input named rc2 with nonempty control' real-empty; }
t105() { fix12_case 'T105 HOME empty named rc6 before writes' home-empty; }

fix12_needle_case() {
  local label="$1" needle="$2" reason="$3" out rc=0 src dst
  RAN=$((RAN + 1))
  mk_env || { instr_bad 'фикстура иглы FIX12 не создана'; return; }
  src="$E/needle.txt"; dst="$E/mutated.txt"
  mk_put "$src" '# marker\nA x\nA y\nA x\n' || { instr_bad 'фикстура иглы не записана'; return; }
  out=$(mutate_one "$src" "$dst" '^# marker$' "$needle" 'REPLACED' 2>&1) || rc=$?
  if [[ $rc != 2 || "$out" != *"$reason"* ]]; then
    bad "$label rc=$rc :: ${out//$'\n'/;}"; return
  fi
  if [[ -e "$dst" ]]; then bad "$label отказ записал мутант"; return; fi
  mutate_one "$src" "$dst" '^# marker$' '^A x$' 'REPLACED' \
    || { bad "$label контроль одинаковых строк отказал"; return; }
  out=$(cat "$dst") || { instr_bad 'контроль иглы не прочитан'; return; }
  if [[ "$out" != $'# marker\nREPLACED\nA y\nA x' ]]; then
    bad "$label контроль заменил не целевую строку"; return
  fi
  ok "$label"
}
t103() { fix12_needle_case 'T103 mutate_one ambiguous with identical-line control' '^A' 'игла неоднозначна'; }
t104() { fix12_needle_case 'T104 mutate_one empty-matching needle' '||' 'игла пустая'; }

# CONSTRAINT: предмет T106 -- ФИЗИЧЕСКАЯ строка по LF и побайтовая сохранность
# всего файла вне заменённой строки; фикстура несёт CRLF-строки, чтобы нормализация
# переводов строк ловилась как изменение байтов вне цели
fix13_needle_bytes_arm() {  # $1 игла, $2 плечо (crlf|lf); отказ печатает причину, rc 1/2
  local needle="$1" arm="$2" out rc=0 src="$E/needle.txt" dst="$E/mutated.txt" marker='^# marker$'
  [[ "$arm" == lf ]] && marker='^B\r$'
  mk_put "$src" '# marker\nA x\r\nB\r\nC D\n' \
    || { printf 'ПРИБОР НЕДОСТУПЕН: фикстура байтов не записана: %s\n' "$src" >&2; return 2; }
  out=$(mutate_one "$src" "$dst" "$marker" "$needle" 'REPLACED' 2>&1) || rc=$?
  if [[ $rc != 0 ]]; then printf 'rc=%d :: %s\n' "$rc" "${out//$'\n'/;}"; return 1; fi
  if ! python3 - "$dst" "$arm" <<'PYF13'
import sys
dst, arm = sys.argv[1:3]
exp = {'crlf': (b'# marker\n', b'B\r\nC\xe2\x80\xa8D\n'), 'lf': (b'# marker\nA x\r\nB\r\n', b'')}[arm]
got = open(dst, 'rb').read()
sys.exit(0 if got == exp[0] + b'REPLACED\n' + exp[1] else 1)
PYF13
  then printf 'байты вне целевой физической строки изменились\n'; return 1; fi
  return 0
}
t106() {
  local why=''
  RAN=$((RAN + 1))
  mk_env || { instr_bad 'фикстура FIX13 не создана'; return; }
  why=$(fix13_needle_bytes_arm '^A x\r$' crlf) \
    || { bad "T106 mutate_one bytes: CRLF-плечо, игла ^A x\r$ :: $why"; return; }
  why=$(fix13_needle_bytes_arm '^C' lf) \
    || { bad "T106 mutate_one bytes: LF-плечо, игла ^C :: $why"; return; }
  ok 'T106 mutate_one bytes: физическая строка LF, байты вне цели нетронуты'
}

t01; t02; t03; t04; t05; t06; t07; t08; t09; t10; t11; t12; t13; t14; t15
t16; t17; t18; t19; t20; t21; t22; t23; t24; t25; t26; t27; t28; t29; t30
t31; t32; t33; t34; t35; t36; t37; t38; t39; t40; t41; t42; t43; t44; t45
t46; t47; t48; t49; t50; t51; t52; t53; t54; t55; t56; t57; t58; t59; t60
t61; t62; t63; t64; t65; t66; t67; t68
t69; t70; t71; t72; t73; t74; t75; t76; t77; t78; t79; t80; t81; t82
t83; t84; t85; t86; t87; t88; t89; t90; t91; t92; t93; t94; t95; t96
t97; t98; t99; t100; t101; t102; t103; t104; t105; t106

echo
echo "target-isolation-teeth: RAN=$RAN PASSED=$PASSED FAILED=$FAILED (pin EXPECTED_TEETH=$EXPECTED_TEETH)"
if [[ $RAN -ne $EXPECTED_TEETH ]]; then
  echo "ОТКАЗ: прогнанных зубов $RAN, пин $EXPECTED_TEETH -- перечень разошёлся с блоком" >&2
  __DONE=1
  exit 4
fi
if [[ $FAILED -gt 0 ]]; then
  __DONE=1
  exit 1
fi
__DONE=1
exit 0
