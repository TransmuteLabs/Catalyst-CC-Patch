#!/usr/bin/env bash
# Герметичный стенд синхронизации проб: замок писателей и видимость стадий.
#
# Коды выхода (подмножество общей таблицы кита):
#   0 -- каждый сценарий сошёлся, каждая мутация покраснила свой сценарий
#   1 -- сценарий разошёлся либо мутация прошла молча
#   2 -- прибор не может мерить: якорь правки-зуба или условие ожидания
#        не достигнуто, либо замена СЛОМАЛА РАЗБОР жертвы (круг 25, E-3) --
#        покраснение разбором ничего не доказывает, прогон останавливается
#        до счёта покраснений
#   4 -- probes-sync-bench: объявленные числа таблиц не сходятся, либо
#        сверка покрытия нашла дверь без своего зуба (круг 25, E-4:
#        непокрытая дверь не доказывает ничего)
set -u

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# CONSTRAINT: путь к инструментам стенда снимается ЗДЕСЬ, один раз: self_check
# ниже переназначает KIT на игрушечный кит (копию, которую сам же мутирует),
# и инструмент, взятый из $KIT, читался бы из мутируемой копии -- мутация
# прибора стала бы невидимой.
REAL_KIT=$KIT
BENCH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "$0")
EXPECTED_SCENARIOS=19
EXPECTED_MUTATIONS=24
# Бюджеты ожиданий, в шагах по 0.05 с. Пять секунд мерили скорость МАШИНЫ, а
# не свойство замка: под свипом первый писатель до `cp` за них не доходит, и
# прибор объявлял отказ там, где дефекта нет.
WAIT_READY_STEPS=600      # 30 с -- вход первого писателя в cp
WAIT_DEATH_STEPS=200      # 10 с -- смерть писателя после освобождения
# Круг 25, E-4: номер сценария, который красит каждая мутация. Таблица
# отдельная от самих мутаций, и сверка ниже требует, чтобы КАЖДЫЙ сценарий
# был чьим-то зубом -- как check_mut_tables у corpus-tools-bench. До этой
# волны сверялись только длины, и дыра жила латентно, пока покрытие было
# случайно полным. Исключения -- только поимённо в UNMUTATED_OK с написанной
# причиной; сегодня их нет.
MUT_SCENARIO=(x 1 2 3 4 5 6 7 7 8 9 10 11 12 13 14 15 16 17 18 19 10 10 10 10)
# Улика, по которой признаётся СВОЯ причина покраснения: подстрока LAST_EVID
# сценария. Дом перечня мутаций ОДИН -- EXPECTED_MUTATIONS; и обход
# self_check, и эта таблица, и MUT_SCENARIO обязаны сойтись с ним длиной.
# Волна 190: обход жил собственным литеральным перечнем `for n in 1..9`, и
# десятая мутация не запускалась вовсе -- счётчик расходился с объявлением,
# а строки о ней не было НИ ОДНОЙ (перечень = проекция, четвёртый случай).
MUT_EVID=(x 'второй=0' 'diff_rc=0' 'B=3' 'НЕ_НАЗВАНА' 'rc=1' 'rc=0' \
          'ПУТЬ_ОТКАЗА_ЗАВИС' 'СИРОТА_ЗАГЛУШКИ' 'ОДНО_НАПРАВЛЕНИЕ' 'исходник=0' \
          'вне_истории=0' 'СЛОВО_РАЗОШЛОСЬ_С_ДЕЛОМ' 'запускает НЕ' \
          'ПРИЧИНА_НЕ_НАЗВАНА' 'РАСХОЖДЕНИЕ_НЕ_НАЗВАНО' 'ПРЕДМЕТ_НЕ_НАЗВАН' \
          'ВЛАДЕЛЕЦ_НЕ_УЗНАН' 'НЕПОКРЫТИЕ_НЕ_НАЗВАНО' 'НЕДОСТУПЕН_НЕ_НАЗВАН' \
          'ПЛАТФОРМА_НЕ_НАЗВАНА' 'нечитаем_назван=0' 'битый_назван=0' 'ПУСТОЙ_НЕ_НЕИЗМЕРЕНО' \
          'свидетель=0')
UNMUTATED_OK=''
FAILED=0
RUN=0
LAST_EVID=''
TW_RC1=''; TW_RC2=''; TW_DIFF=''; TW_DIFF_RC=''; TW_REASON=''; TW_SECOND_LOG=''

say() { printf '%s\n' "$*"; }
ok() { RUN=$((RUN + 1)); say "  ok     $*"; }
bad() { RUN=$((RUN + 1)); FAILED=$((FAILED + 1)); say "  ПРОВАЛ $*"; }

check_mut_tables() {
  local n missing=""
  if (( ${#MUT_SCENARIO[@]} != EXPECTED_MUTATIONS + 1 )); then
    say "probes-sync-bench: ОТКАЗ -- в MUT_SCENARIO записей $(( ${#MUT_SCENARIO[@]} - 1 )), а мутаций $EXPECTED_MUTATIONS"
    return 1
  fi
  if (( ${#MUT_EVID[@]} != EXPECTED_MUTATIONS + 1 )); then
    say "probes-sync-bench: ОТКАЗ -- в MUT_EVID записей $(( ${#MUT_EVID[@]} - 1 )), а мутаций $EXPECTED_MUTATIONS"
    return 1
  fi
  for n in $(seq 1 $EXPECTED_MUTATIONS); do
    [[ -n "${MUT_EVID[$n]}" ]] && continue
    say "probes-sync-bench: ОТКАЗ -- у мутации $n не объявлена своя улика покраснения"
    return 1
  done
  for n in $(seq 1 $EXPECTED_SCENARIOS); do
    printf '%s\n' "${MUT_SCENARIO[@]}" | grep -qx "$n" || missing="$missing $n"
  done
  if [[ -n "${missing:-}" ]]; then
    say "probes-sync-bench: ОТКАЗ -- без своей мутации сценарии:${missing}"
    say "  исключений нет; всякое будущее -- поимённо в UNMUTATED_OK с причиной"
    return 1
  fi
  return 0
}

dead_pid() {
  sh -c 'exit 0' &
  local pid=$!
  wait "$pid"
  printf '%s' "$pid"
}

mk_kit() {
  local dst="$1" f
  mkdir -p "$dst/scripts" "$dst/probes/judge" "$dst/probes/idle-watch" "$dst/judge"
  cp "$KIT/scripts/probes-sync.sh" "$dst/scripts/probes-sync.sh"
  # Стенд копируется в игрушечный кит, потому что сценарий 7 меряет ЕГО путь
  # отказа: мутация правит копию, а сценарий исполняет её, а не работающий файл.
  mkdir -p "$dst/tools"
  cp "$BENCH" "$dst/tools/probes-sync-bench.sh"
  # Образец plist кладётся ДО опроса набора: пара plist добавляется условно
  # (по наличию плейсхолдера), и на отсутствующем файле скрипт назвал бы её
  # частью набора -- игрушечный канон получил бы ЗАПОЛНЕННЫЙ plist и поехал
  # бы в каталог агентов.
  printf '/Users/YOUR-USER\n' > "$dst/judge/com.transmutelabs.judge-compact.plist"
  # CONSTRAINT: игрушечный канон строится ПО НАБОРУ, КОТОРЫЙ НАЗЫВАЕТ САМ
  # СКРИПТ (--list), а не по копии перечня здесь. Копия -- второй экземпляр
  # той же проекции: 15.09 перечень раскатки пополнился (recstore.py,
  # fresh-runs.py, зубы), а список здесь остался прежним, и 8 сценариев
  # (docnum:subset -- замер 15.09 на тогдашнем наборе) покраснели «исходная
  # раскатка отказала», не найдя канонной стороны новых пар. Прежняя правка
  # разбирала объявления sed'ом -- это знало про TOOL_FILES, но не про
  # PROBE_FILES и не про пару дома словарей: те так и лежали копиями ниже.
  local __names __list_rc __err
  __err="$(dirname "$dst")/list-err" || { printf 'ПРИБОР НЕДОСТУПЕН: не получен путь журнала опроса набора\n' >&2; exit 2; }
  __names=$(bash "$dst/scripts/probes-sync.sh" --list 2>"$__err"); __list_rc=$?
  # Положительный контроль: молчащий или отказавший опрос означает, что
  # игрушечный канон вышел бы пустым МОЛЧА.
  if [[ $__list_rc -ne 0 || -z "$__names" ]]; then
    say "probes-sync-bench: ОТКАЗ -- скрипт не назвал набор (--list rc=$__list_rc): $(cat "$__err" 2>&1)"
    exit 2
  fi
  local __rel
  while IFS= read -r __rel; do
    [[ -n "$__rel" ]] || continue
    mkdir -p "$(dirname "$dst/$__rel")"
    printf 'canon %s\n' "$__rel" > "$dst/$__rel"
  done <<< "$__names"
}

make_env() {
  local root="$1"
  export CLAUDE_CONFIG_DIR="$root/home"
  export CLAUDE_PROBES_DIR="$root/home/probes"
  export CLAUDE_JUDGE_TOOLS_DIR="$root/home/judge"
  export CLAUDE_LAUNCH_AGENTS_DIR="$root/home/agents"
  export PROBES_SYNC_LOCK="$root/home/probes-sync.lock"
  # CONSTRAINT: платформа владельца расписания пинится Дарвином для каждого
  # сценария, который не ставит свою: без пина Linux-машина позвала бы
  # НАСТОЯЩИЙ crontab, а стенд не имеет права читать боевые расписания --
  # подмена прибора только через CLAUDE_CRONTAB_CMD и только в сценариях
  # 15-18, где заглушка лежит во временном каталоге стенда.
  export CLAUDE_SCHEDULE_PLATFORM=Darwin
  mkdir -p "$CLAUDE_CONFIG_DIR" "$CLAUDE_LAUNCH_AGENTS_DIR"
}

wait_file() {   # <путь> [шагов по 0.05 с]
  local path="$1" left="${2:-$WAIT_READY_STEPS}"
  while [[ ! -e "$path" && $left -gt 0 ]]; do
    sleep 0.05
    left=$((left - 1))
  done
  [[ -e "$path" ]]
}

# Ограниченное ожидание смерти процесса. Голое `wait` потолка не имеет: если
# писатель не умирает (его передний ребёнок держит сигнал), стенд встаёт
# навсегда, а вместе с ним весь свип.
wait_death() {   # <pid> [шагов по 0.05 с]; 0 -- умер, 1 -- бюджет исчерпан
  local pid="$1" left="${2:-$WAIT_DEATH_STEPS}"
  while kill -0 "$pid" 2>/dev/null && (( left > 0 )); do
    sleep 0.05
    left=$((left - 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

# Пляска двух писателей. Режим `signal` -- заглушка сообщает о входе файлом
# ready (боевой случай сценария 1); режим `silent` -- НЕ сообщает никогда
# (случай, на котором меряется путь отказа). Обе стороны исполняют ОДИН код:
# копия рано или поздно разошлась бы с боевой.
#
# Возврат: 0 -- дошли до вердикта удачного пути (TW_RC1/TW_RC2/TW_DIFF/TW_DIFF_RC
# заполнены); 1 -- путь отказа отработал и НАЗВАЛ причину в TW_REASON.
two_writers() {   # <корень> <signal|silent>
  local root="$1" mode="$2" script stub ready release first_log second_log first_pid
  script="$root/kit/scripts/probes-sync.sh"
  stub="$root/stub"; mkdir -p "$stub"
  ready="$root/ready"; release="$root/release"
  if [[ "$mode" == signal ]]; then
    cat > "$stub/cp" <<'CP'
#!/usr/bin/env bash
if [[ ! -e "$SYNC_BENCH_READY" ]]; then
  : > "$SYNC_BENCH_READY"
  while [[ ! -e "$SYNC_BENCH_RELEASE" ]]; do sleep 0.05; done
fi
exec /bin/cp "$@"
CP
  else
    cat > "$stub/cp" <<'CP'
#!/usr/bin/env bash
# О входе НЕ сообщает: ready не появится никогда -- ровно тот вход, на котором
# путь отказа обязан кончиться, а не зависнуть. Свой номер пишет ДО ожидания:
# по нему сценарий 7 проверяет, что заглушка не осталась сиротой.
printf '%s\n' "$$" > "$SYNC_BENCH_STUBPID"
while [[ ! -e "$SYNC_BENCH_RELEASE" ]]; do sleep 0.05; done
exec /bin/cp "$@"
CP
  fi
  chmod +x "$stub/cp"
  first_log="$root/first.log"; second_log="$root/second.log"
  PATH="$stub:$PATH" SYNC_BENCH_READY="$ready" SYNC_BENCH_RELEASE="$release" \
    SYNC_BENCH_STUBPID="$root/stub.pid" \
    bash "$script" --to-home >"$first_log" 2>&1 &
  first_pid=$!
  if ! wait_file "$ready"; then
    # Освобождение ПЕРВЫМ действием, ДО сигнала: заглушка ждёт release, а bash
    # не доставляет сигнал, пока исполняется его ПЕРЕДНИЙ ребёнок. kill без
    # освобождения не убивает никого, а следом голое `wait` встаёт навсегда.
    : > "$release"
    kill "$first_pid" 2>/dev/null
    wait_death "$first_pid" || kill -9 "$first_pid" 2>/dev/null
    wait "$first_pid" 2>/dev/null
    TW_REASON='УСЛОВИЕ_НЕ_ДОСТИГНУТО: первый писатель не вошёл в cp'
    return 1
  fi
  bash "$script" --to-home >"$second_log" 2>&1; TW_RC2=$?
  : > "$release"
  if ! wait_death "$first_pid"; then
    kill -9 "$first_pid" 2>/dev/null
    wait "$first_pid" 2>/dev/null
    TW_REASON='ПИСАТЕЛЬ_НЕ_УМЕР: после освобождения первый писатель не завершился в бюджете'
    return 1
  fi
  wait "$first_pid"; TW_RC1=$?
  TW_DIFF=$(bash "$script" --diff 2>&1); TW_DIFF_RC=$?
  # Пустой журнал второго писателя допустим: вердикт строится по кодам TW_RC*, журнал — улика.
  TW_SECOND_LOG=$(cat "$second_log") || true
  return 0
}

scenario_1() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s1.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  if ! two_writers "$root" signal; then
    LAST_EVID="$TW_REASON"
    rm -rf "$root"
    bad '1 замок писателей: путь отказа назвал причину'
    return
  fi
  LAST_EVID="первый=$TW_RC1 второй=$TW_RC2 diff=$TW_DIFF_RC :: $TW_SECOND_LOG :: $TW_DIFF"
  rm -rf "$root"
  if [[ $TW_RC1 -eq 0 && $TW_RC2 -eq 3 && $TW_DIFF_RC -eq 0 ]]; then
    ok '1 два писателя: второй получает 3, после первого дом чист'
  else
    bad "1 два писателя: ждали 0/3/0, получили $TW_RC1/$TW_RC2/$TW_DIFF_RC"
  fi
}

scenario_2() {
  local root script dead stale live out rc live_holder
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s2.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '2 стадии: исходная раскатка отказала'; return; }
  dead=$(dead_pid) || { LAST_EVID="мёртвый PID не добыт (dead_pid rc=$?)"; rm -rf "$root"
    bad '2 стадии: свободный мёртвый PID не добыт -- номер стадии взять нечем'; return; }
  stale="$CLAUDE_PROBES_DIR/probes.toml.sync-new.$dead"
  sleep 30 & live_holder=$!
  live="$CLAUDE_PROBES_DIR/probes.toml.sync-new.$live_holder"
  local live_owner="$CLAUDE_PROBES_DIR/probes.toml.sync-owner.$live_holder"
  printf 'stale\n' > "$stale"; printf 'live\n' > "$live"
  printf '%s\t%s\n' "$live_holder" "$(LC_ALL=C ps -o lstart= -p "$live_holder" 2>/dev/null)" > "$live_owner"
  out=$(bash "$script" --diff 2>&1); rc=$?
  bash "$script" --to-home >/dev/null 2>&1
  # Наличие снимается ДО уборки дерева и проверяется по снятым значениям:
  # `CLAUDE_PROBES_DIR` лежит ВНУТРИ `$root`, и проверка после `rm -rf "$root"`
  # читает удалённое -- мёртвая стадия «убрана» всегда, живая «снесена» всегда.
  local stale_left live_left
  stale_left=$([[ -e "$stale" ]] && echo 1 || echo 0)
  live_left=$([[ -e "$live" ]] && echo 1 || echo 0)
  LAST_EVID="diff_rc=$rc stale=$([[ $stale_left == 1 ]] && echo ОСТАЛАСЬ_СТАДИЯ || echo убрана) live=$([[ $live_left == 1 ]] && echo цела || echo СНЕСЕНА_ЖИВАЯ) :: $out"
  kill "$live_holder" 2>/dev/null; wait "$live_holder" 2>/dev/null
  rm -rf "$root"
  if [[ $rc -ne 1 || "$out" != *"sync-new.$dead"* ]]; then
    bad '2 стадии: --diff не назвал осиротевшую стадию кодом 1'; return
  fi
  if [[ $stale_left == 1 ]]; then
    bad '2 стадии: писатель не убрал стадию мёртвого pid'; return
  fi
  if [[ $live_left == 0 ]]; then
    bad '2 стадии: писатель снял стадию живого pid'; return
  fi
  ok '2 стадии: --diff называет осиротевшую, писатель убирает только мёртвую'
}

scenario_3() {
  local root script stub dead_holder dead_start live live_start logA logB logC logD rcA rcB rcC rcD
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s3.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  # Ноги flock(1)/perl flock(2) гасятся заглушками с кодом «не могу»: тогда
  # скрипт обязан спуститься на третью ступень лестницы -- каталог-замок.
  stub="$root/stub"; mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$stub/flock"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$stub/perl"
  chmod +x "$stub/flock" "$stub/perl"
  # Держатель умирает: его метку старта снимаем ДО смерти. Номер после смерти
  # достаётся чужому процессу -- его играет живой sleep. lstart даёт СЕКУНДЫ:
  # метки двух процессов, родившихся в одну секунду, СОВПАДАЮТ, поэтому между
  # смертью держателя и рождением чужака выдерживается зазор больше секунды.
  sleep 60 & dead_holder=$!
  # Ненулевой код ps здесь ОЖИДАН в гонке: держатель мог умереть до снимка.
  # Код проверяется на месте: пустая метка без имени причины сливалась бы
  # с «метки совпали» ниже и прятала сломанный снимок за чужим вердиктом.
  dead_start=$(LC_ALL=C ps -o lstart= -p "$dead_holder" 2>/dev/null) || {
    LAST_EVID="метку держателя снять не удалось (ps rc=$?)"
    kill "$dead_holder" 2>/dev/null; wait "$dead_holder" 2>/dev/null
    rm -rf "$root"
    bad '3 замок с меткой старта: метку умирающего держателя снять не удалось'; return; }
  kill "$dead_holder" 2>/dev/null; wait "$dead_holder" 2>/dev/null
  sleep 1.5
  sleep 60 & live=$!
  live_start=$(LC_ALL=C ps -o lstart= -p "$live" 2>/dev/null) || {
    LAST_EVID="метку чужака снять не удалось (ps rc=$?)"
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
    rm -rf "$root"
    bad '3 замок с меткой старта: метку живого чужака снять не удалось'; return; }
  if [[ -z "$dead_start" || -z "$live_start" || "$dead_start" == "$live_start" ]]; then
    kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
    LAST_EVID="dead_start=[$dead_start] live_start=[$live_start]"
    rm -rf "$root"
    bad '3 замок с меткой старта: прибор не развёл метки держателя и чужака'
    return
  fi
  logA="$root/A.log"; logB="$root/B.log"; logC="$root/C.log"; logD="$root/D.log"
  # A: живой владелец, метка СВОЯ -- замок обязан признаться живым (3).
  mkdir -p "$PROBES_SYNC_LOCK.d"
  printf '%s\t%s\n' "$live" "$live_start" > "$PROBES_SYNC_LOCK.d/pid"
  PATH="$stub:$PATH" bash "$script" --to-home >"$logA" 2>&1; rcA=$?
  # B: номер жив (чужой процесс), метка ЧУЖАЯ (мёртвого держателя) -- замок
  # обязан быть ПЕРЕХВАЧЕН, а не признан живым (0).
  mkdir -p "$PROBES_SYNC_LOCK.d"
  printf '%s\t%s\n' "$live" "$dead_start" > "$PROBES_SYNC_LOCK.d/pid"
  PATH="$stub:$PATH" bash "$script" --to-home >"$logB" 2>&1; rcB=$?
  # C: строка ПРЕЖНЕЙ формы (без таба), pid жив -- решает один kill -0 (3).
  mkdir -p "$PROBES_SYNC_LOCK.d"
  printf '%s\n' "$live" > "$PROBES_SYNC_LOCK.d/pid"
  PATH="$stub:$PATH" bash "$script" --to-home >"$logC" 2>&1; rcC=$?
  # D: строка прежней формы, pid мёртв -- замок протух и берётся (0).
  mkdir -p "$PROBES_SYNC_LOCK.d"
  printf '%s\n' "$dead_holder" > "$PROBES_SYNC_LOCK.d/pid"
  PATH="$stub:$PATH" bash "$script" --to-home >"$logD" 2>&1; rcD=$?
  LAST_EVID="A=$rcA B=$rcB C=$rcC D=$rcD :: A:$(cat "$logA") | B:$(cat "$logB") | C:$(cat "$logC") | D:$(cat "$logD")"
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  rm -rf "$root"
  if [[ $rcA -ne 3 ]]; then
    bad "3 замок: живой владелец со своей меткой обязан держать замок (3), получили A=$rcA"
    return
  fi
  if [[ $rcB -ne 0 ]]; then
    bad "3 замок: мёртвый держатель с чужой меткой обязан быть перехвачен (0), получили B=$rcB"
    return
  fi
  if [[ $rcC -ne 3 ]]; then
    bad "3 замок: прежняя форма с живым pid обязана держать замок (3), получили C=$rcC"
    return
  fi
  if [[ $rcD -ne 0 ]]; then
    bad "3 замок: прежняя форма с мёртвым pid обязана перехватываться (0), получили D=$rcD"
    return
  fi
  ok '3 замок: метка старта различает живого владельца и переиспользованный номер'
}

scenario_4() {
  local root script dead stale out rc left named
  # Корень канонизируется через cd+pwd: TMPDIR на macOS кончается слешем,
  # mktemp отдаёт путь с двойным слешем, а скрипт внутри канонизирует свой
  # ROOT через `cd ... && pwd` -- без этого сравнение ПОЛНОГО пути в выводе
  # --diff со строкой $stale расходилось бы на форме записи, не на сути.
  root=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s4.XXXXXX")" && pwd)
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '4 стадия на канонной стороне: исходная раскатка отказала'; return; }
  dead=$(dead_pid) || { LAST_EVID="мёртвый PID не добыт (dead_pid rc=$?)"; rm -rf "$root"
    bad '4 стадия на канонной стороне: свободный мёртвый PID не добыт -- номер стадии взять нечем'; return; }
  # --from-home кладёт стадии на КАНОННУЮ сторону (dst="$A", дерево
  # репозитория): обломок прошлого прогона имитируется файлом именно там.
  stale="$root/kit/probes/probes.toml.sync-new.$dead"
  printf 'обломок прошлого --from-home\n' > "$stale"
  out=$(bash "$script" --diff 2>&1); rc=$?
  [[ "$out" == *"$stale"* ]] && named=1 || named=0
  bash "$script" --to-home >/dev/null 2>&1
  # Наличие снимается ДО уборки дерева (см. сценарий 2).
  left=$([[ -e "$stale" ]] && echo 1 || echo 0)
  LAST_EVID="diff_rc=$rc канон=$([[ $named == 1 ]] && echo названа || echo НЕ_НАЗВАНА) убрана=$([[ $left == 1 ]] && echo НЕТ || echo да) :: $out"
  rm -rf "$root"
  if [[ $rc -ne 1 || $named -ne 1 ]]; then
    bad '4 стадия на канонной стороне: --diff не назвал её кодом 1'
    return
  fi
  if [[ $left -eq 1 ]]; then
    bad '4 стадия на канонной стороне: писатель не убрал обломок'
    return
  fi
  ok '4 стадии: обломок на канонной стороне назван отчётом и убран писателем'
}

scenario_5() {
  local root script live out rc
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s5.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '5 живая стадия: исходная раскатка отказала'; return; }
  sleep 60 & live=$!
  printf 'идёт\n' > "$CLAUDE_PROBES_DIR/probes.toml.sync-new.$live"
  printf '%s\t%s\n' "$live" "$(LC_ALL=C ps -o lstart= -p "$live" 2>/dev/null)" \
    > "$CLAUDE_PROBES_DIR/probes.toml.sync-owner.$live"
  out=$(bash "$script" --diff 2>&1); rc=$?
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  LAST_EVID="rc=$rc :: $out"
  rm -rf "$root"
  if [[ $rc -ne 0 ]]; then
    bad "5 живая стадия: --diff обязан вернуть 0, получил $rc"
    return
  fi
  ok '5 стадии: --diff не считает расхождением стадию живого писателя'
}
# Отказ сверки НАЗЫВАЕТ ОБА направления. Расхождение не говорит, чья сторона
# верна, а команды чинки уничтожают работу каждая на своей стороне: совет,
# знающий одно направление, ведёт читателя в потерю ровно в том случае, ради
# которого объявлен `--from-home` (правка сделана в доме -- штатный случай для
# промтов судьи). Сценарий строит именно его.
scenario_8() {
  local root script out rc has_to has_from
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s8.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '8 направление отказа: исходная раскатка отказала'; return; }
  printf 'правка, сделанная В ДОМЕ\n' > "$CLAUDE_PROBES_DIR/judge/prompt.md"
  out=$(bash "$script" --diff 2>&1); rc=$?
  [[ "$out" == *"--to-home"* ]] && has_to=1 || has_to=0
  [[ "$out" == *"--from-home"* ]] && has_from=1 || has_from=0
  LAST_EVID="rc=$rc :: $out"
  rm -rf "$root"
  if (( rc != 1 )); then
    LAST_EVID="НЕ_РАСХОЖДЕНИЕ rc=$rc :: $LAST_EVID"
    bad "8 направление отказа: правка в доме обязана быть расхождением (1), получили $rc"
    return
  fi
  if (( has_to != 1 || has_from != 1 )); then
    LAST_EVID="ОДНО_НАПРАВЛЕНИЕ to-home=$has_to from-home=$has_from :: $LAST_EVID"
    bad '8 направление отказа: назван не весь выбор -- совет уничтожил бы правку в доме'
    return
  fi
  ok '8 отказ сверки называет оба направления и потерю каждого'
}

# Принимает номер СЦЕНАРИЯ (не мутации): отображение мутация -> сценарий
# живёт в MUT_SCENARIO и нигде больше. Прежняя редакция несла собственный
# case по номеру МУТАЦИИ -- пятая копия того же перечня, и номер 10 в ней
# отсутствовал: десятая мутация «проходила молча», не запустив ничего.
# Код возврата означает РОВНО одно -- есть ли такая функция (2 = нет).
# Вердикт сценария едет через FAILED/LAST_EVID: сценарий, кончившийся
# ненулевой командой, иначе читался бы как «сценария не существует».
run_scenario() {
  declare -F "scenario_$1" >/dev/null || return 2
  "scenario_$1"
  return 0
}

# Круг 25, E-3: тела heredoc'ов .sh-жертвы, поданные питону, по правилу гейта
# PYCOMPILE конвейера: строка до первого '#' содержит python3 границей слова,
# между python3 и открытием нет '|' ';' '&', строка КОНЧАЕТСЯ открытием
# <<'ТЕГ'; тело -- до строки, равной ТЕГУ дословно. Сегодня у жертвы
# probes-sync.sh таких тел нет, но страж пишется по ПРАВИЛУ, а не по факту
# сегодняшнего файла: первая же мутация в питонье тело потребует этой
# проверки, а не случайности (решение контроллера, волна 25).

# ЦЕНЗ ДОМА. Пары раскатки -- проекция канона, и то, чего в перечне нет, для
# них не существует: recstore.py, fresh-runs.py и два зуба прожили только в
# доме, не попав в репозиторий вовсе (измерено 15.09). Сценарий держит ОБА
# конца: исходник мимо канона обязан НАЗЫВАТЬСЯ и краснить, а данные машины
# (записи, метки, личный config.json) в ценз попадать НЕ имеют права -- иначе
# дверь кричала бы на каждом живом доме и её бы отключили.
scenario_9() {
  local root script out rc out2 rc2 out3 rc3
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s9.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '9 ценз дома: исходная раскатка отказала'; return; }

  out=$(bash "$script" --diff 2>&1); rc=$?

  mkdir -p "$CLAUDE_JUDGE_TOOLS_DIR/records" "$CLAUDE_JUDGE_TOOLS_DIR/labelled"
  printf '{}' > "$CLAUDE_JUDGE_TOOLS_DIR/records/mod-1.json"
  printf 'x'  > "$CLAUDE_JUDGE_TOOLS_DIR/labelled/rec.md"
  printf '{}' > "$CLAUDE_JUDGE_TOOLS_DIR/config.json"
  out2=$(bash "$script" --diff 2>&1); rc2=$?

  printf 'print(1)\n' > "$CLAUDE_JUDGE_TOOLS_DIR/newtool.py"
  out3=$(bash "$script" --diff 2>&1); rc3=$?

  LAST_EVID="чистый=$rc данные=$rc2 исходник=$rc3 :: назван=$(printf '%s' "$out3" | grep -c 'не занесён в канон')"
  rm -rf "$root"
  if [[ $rc -ne 0 || $rc2 -ne 0 ]]; then
    bad "9 ценз дома: чистый дом или данные машины покрасили сверку ($rc/$rc2)"
  elif [[ $rc3 -eq 0 ]]; then
    bad '9 ценз дома: исходник мимо канона НЕ покрасил сверку'
  elif ! printf '%s' "$out3" | grep -q 'не занесён в канон: judge/newtool.py'; then
    bad '9 ценз дома: покраснело, но имя исходника мимо канона не названо'
  else
    ok '9 ценз дома: исходник мимо канона назван и красит, данные машины -- нет'
  fi
}

# ЦЕНЗ РЕПОЗИТОРИЯ. «Лежит в каталоге канона» и «живёт в репозитории» -- не
# одно и то же, и ценз по первому даёт ложное зелёное в том самом случае,
# ради которого написан: строка `judge/bench/` в .gitignore (её целью были
# записи прогонов) прятала от git положенные рядом зубы, и find их видел, а
# клон репозитория -- нет. Сценарий держит ШЕСТЬ состояний: git есть --
# источник git; вне git без свидетеля -- НЕ ИЗМЕРЕНО; свидетель заказан и
# не найден или битый -- ПРИБОР НЕДОСТУПЕН (exit 2); свидетель цел без
# путей под judge/ -- НЕ ИЗМЕРЕНО (слепота ≠ чистота); свидетель цел с
# путями под judge/ -- ценз по множеству свидетеля, вердикт называет источник.
scenario_10() {
  local root script out1 rc1 out2 rc2 out3 rc3 out4 rc4 out5 rc5 out6 rc6 out7 rc7 victim wit
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s10.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  victim='judge/replay.py'
  wit="$root/TRACKED.txt"
  unset CATALYST_TRACKED_WITNESS || true
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '10 ценз репозитория: исходная раскатка отказала'; return; }

  out1=$(bash "$script" --diff 2>&1); rc1=$?

  # Индекс получает ЧАСТЬ judge/: положительный контроль цензa требует хотя бы
  # одного отслеживаемого файла, иначе слепота неотличима от чистоты.
  (cd "$root/kit" && git init -q && git add judge/compact.py) >/dev/null 2>&1 || {
    LAST_EVID='ПРИБОР: git init/add отказал'; rm -rf "$root"
    bad '10 ценз репозитория: подготовка индекса отказала'; return; }
  out2=$(bash "$script" --diff 2>&1); rc2=$?

  (cd "$root/kit" && git add judge) >/dev/null 2>&1
  out3=$(bash "$script" --diff 2>&1); rc3=$?

  # Дальше -- не git: свидетель подменяет индекс только вне рабочего дерева.
  rm -rf "$root/kit/.git"

  out4=$(CATALYST_TRACKED_WITNESS="$root/NO-SUCH-WITNESS" bash "$script" --diff 2>&1); rc4=$?

  printf '%s\n' \
    '# Свидетель индекса дерева Catalyst-CC-Patch, снят с ОРИГИНАЛА при снятии снимка.' \
    'TREE=Catalyst-CC-Patch' \
    'HEAD=deadbeef' \
    'COUNT=99' \
    'judge/compact.py' > "$wit"
  out5=$(CATALYST_TRACKED_WITNESS="$wit" bash "$script" --diff 2>&1); rc5=$?

  printf '%s\n' \
    '# Свидетель индекса дерева Catalyst-CC-Patch, снят с ОРИГИНАЛА при снятии снимка.' \
    'TREE=Catalyst-CC-Patch' \
    'HEAD=deadbeef' \
    'COUNT=1' \
    'scripts/probes-sync.sh' > "$wit"
  out6=$(CATALYST_TRACKED_WITNESS="$wit" bash "$script" --diff 2>&1); rc6=$?

  printf '%s\n' \
    '# Свидетель индекса дерева Catalyst-CC-Patch, снят с ОРИГИНАЛА при снятии снимка.' \
    'TREE=Catalyst-CC-Patch' \
    'HEAD=cafebabe' \
    'COUNT=1' \
    'judge/compact.py' > "$wit"
  out7=$(CATALYST_TRACKED_WITNESS="$wit" bash "$script" --diff 2>&1); rc7=$?

  # CONSTRAINT: у обоих отказов свидетеля ОДИН код (2) и одна общая строка
  # «ПРИБОР НЕДОСТУПЕН» -- по ним мутация, снявшая первый отказ, неотличима от
  # здорового кода: поток доходит до второго отказа и отдаёт тот же код с той
  # же строкой. Поэтому улика несёт ИМЯ каждого отказа отдельно.
  LAST_EVID="без_git=$rc1 вне_истории=$rc2 всё_в_индексе=$rc3 нет_файла=$rc4 битый=$rc5 пустой=$rc6 свидетель=$rc7 :: назван=$(printf '%s' "$out7" | grep -c "вне репозитория: $victim") источник=$(printf '%s' "$out7" | grep -c 'по свидетелю снимка') нечитаем_назван=$(printf '%s' "$out4" | grep -c 'свидетель индекса нечитаем') битый_назван=$(printf '%s' "$out5" | grep -c 'свидетель индекса битый (COUNT=')"
  rm -rf "$root"
  if [[ $rc1 -ne 0 ]]; then
    bad "10 ценз репозитория: канон вне git обязан быть НЕ ИЗМЕРЕНО, а не расхождением (rc=$rc1)"
  elif ! printf '%s' "$out1" | grep -q 'ЦЕНЗ РЕПОЗИТОРИЯ: НЕ ИЗМЕРЕНО'; then
    bad '10 ценз репозитория: канон вне git промолчал вместо НЕ ИЗМЕРЕНО'
  elif [[ $rc2 -eq 0 ]]; then
    bad '10 ценз репозитория: файл вне истории НЕ покрасил сверку'
  elif ! printf '%s' "$out2" | grep -q "вне репозитория: $victim"; then
    bad '10 ценз репозитория: покраснело, но имя файла вне истории не названо'
  elif [[ $rc3 -ne 0 ]]; then
    bad "10 ценз репозитория: всё под индексом, а сверка всё равно красная (rc=$rc3)"
  elif [[ $rc4 -ne 2 ]]; then
    bad "10 свидетель отсутствует: заказанный и не найденный обязан быть ПРИБОР НЕДОСТУПЕН (rc=2), получили $rc4"
  elif ! printf '%s' "$out4" | grep -q 'ПРИБОР НЕДОСТУПЕН: свидетель индекса нечитаем'; then
    bad '10 свидетель отсутствует: код 2 без ИМЕННОГО отказа «свидетель индекса нечитаем»'
  elif [[ $rc5 -ne 2 ]]; then
    bad "10 свидетель битый: COUNT≠путей обязан быть ПРИБОР НЕДОСТУПЕН (rc=2), получили $rc5"
  elif ! printf '%s' "$out5" | grep -q 'ПРИБОР НЕДОСТУПЕН: свидетель индекса битый (COUNT='; then
    bad '10 свидетель битый: код 2 без ИМЕННОГО отказа «свидетель индекса битый (COUNT=…)»'
  elif [[ $rc6 -ne 0 ]]; then
    LAST_EVID="ПУСТОЙ_НЕ_НЕИЗМЕРЕНО $LAST_EVID"
    bad "10 свидетель без judge/: обязан быть НЕ ИЗМЕРЕНО, а не расхождением (rc=$rc6)"
  elif ! printf '%s' "$out6" | grep -q 'ЦЕНЗ РЕПОЗИТОРИЯ: НЕ ИЗМЕРЕНО'; then
    LAST_EVID="ПУСТОЙ_НЕ_НЕИЗМЕРЕНО $LAST_EVID"
    bad '10 свидетель без judge/: промолчал вместо НЕ ИЗМЕРЕНО'
  elif printf '%s' "$out6" | grep -q 'вне репозитория:'; then
    LAST_EVID="ПУСТОЙ_НЕ_НЕИЗМЕРЕНО $LAST_EVID"
    bad '10 свидетель без judge/: пустое множество прочитано как всё вне истории'
  elif [[ $rc7 -eq 0 ]]; then
    bad '10 свидетель цел: файл вне свидетеля НЕ покрасил сверку'
  elif ! printf '%s' "$out7" | grep -q "вне репозитория: $victim"; then
    bad '10 свидетель цел: покраснело, но имя файла вне свидетеля не названо'
  elif ! printf '%s' "$out7" | grep -q 'по свидетелю снимка (HEAD=cafebabe)'; then
    bad '10 свидетель цел: вердикт не назвал источник (свидетель снимка)'
  else
    ok '10 ценз репозитория: шесть состояний -- git, вне git, нет свидетеля, битый, без judge/, по свидетелю'
  fi
}

# НАБОР НАЗЫВАЕТ САМ ИНСТРУМЕНТ (`--list`). Потребителям перечня -- стенду
# инструментов судьи и mk_kit этого стенда -- запрещено держать свою копию:
# копия разошлась с набором в первый же день пополнения (#193), и стенд судьи
# покраснел на СВОЕЙ неполноте, а не на предмете (#195). Сценарий сводит СЛОВО
# и ДЕЛО: названное сверяется с РАЗЛОЖЕННЫМ, а не с другим списком. Поэтому
# же тут не пишется ожидаемое число -- любое число здесь было бы седьмой
# копией перечня.
scenario_11() {
  local root script out rc rel named home_files missing made err
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s11.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  err="$root/find-err"

  out=$(bash "$script" --list 2>&1); rc=$?
  named=$(printf '%s\n' "$out" | grep -c .) || true

  # Перечисление -- ЧТЕНИЕ: make_env создаёт только корень конфига и каталог
  # агентов, а дома проб и инструментов рождаются лишь раскаткой.
  made=нет
  [[ -e "$CLAUDE_PROBES_DIR" || -e "$CLAUDE_JUDGE_TOOLS_DIR" ]] && made=ДА

  # Каждое названное имя обязано разрешаться в файл КАНОНА.
  missing=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    [[ -f "$root/kit/$rel" ]] || missing=$((missing + 1))
  done <<< "$out"

  bash "$script" --to-home >/dev/null 2>&1
  home_files=$(find "$CLAUDE_PROBES_DIR" "$CLAUDE_JUDGE_TOOLS_DIR" -type f 2>"$err" | grep -c .) || true

  LAST_EVID="list_rc=$rc названо=$named разложено=$home_files нет_в_каноне=$missing дома_создал=$made"
  if [[ -s "$err" ]]; then
    LAST_EVID="ОТКАЗ_ОБХОДА_ДОМОВ :: $(head -2 "$err") :: $LAST_EVID"
  fi
  local walk_failed=0
  [[ -s "$err" ]] && walk_failed=1
  rm -rf "$root"
  if [[ $walk_failed -eq 1 ]]; then
    bad '11 набор: обход домов отказал -- прибор не мерил, а не «сошлось»'
  elif [[ $rc -ne 0 ]]; then
    bad "11 набор: --list отказал (rc=$rc)"
  elif [[ $named -eq 0 ]]; then
    bad '11 набор: --list назвал ПУСТО'
  elif [[ "$made" == 'ДА' ]]; then
    bad '11 набор: --list создал дома -- перечисление обязано быть чтением'
  elif [[ $missing -ne 0 ]]; then
    bad "11 набор: названо $missing имён, которых в каноне нет"
  elif [[ $named -ne $home_files ]]; then
    LAST_EVID="СЛОВО_РАЗОШЛОСЬ_С_ДЕЛОМ :: $LAST_EVID"
    bad "11 набор: слово и дело разошлись -- названо $named, разложено $home_files"
  else
    ok "11 набор: инструмент называет ровно то, что раскатывает, и ничего не трогает"
  fi
}

scenario_6() {
  local root script live live_start other_start stage owner out rc stage_left owner_left
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s6.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '6 стадии: исходная раскатка отказала'; return; }
  sleep 60 & live=$!
  live_start=$(LC_ALL=C ps -o lstart= -p "$live" 2>/dev/null) || __live_ps_rc=$?
  [ "${__live_ps_rc:-0}" -le 1 ] || { printf 'ПРИБОР НЕДОСТУПЕН: не прочитать время старта живого процесса (код %s)\n' "$__live_ps_rc" >&2; exit 2; }
  __live_ps_rc=0
  other_start='Mon Jan  1 00:00:00 2001'
  [[ "$live_start" != "$other_start" ]] || other_start='Tue Jan  2 00:00:00 2001'
  stage="$CLAUDE_PROBES_DIR/probes.toml.sync-new.$live"
  owner="$CLAUDE_PROBES_DIR/probes.toml.sync-owner.$live"
  printf 'stale\n' > "$stage"
  printf '%s\t%s\n' "$live" "$other_start" > "$owner"
  out=$(bash "$script" --diff 2>&1); rc=$?
  bash "$script" --to-home >/dev/null 2>&1
  stage_left=$([[ -e "$stage" ]] && echo 1 || echo 0)
  owner_left=$([[ -e "$owner" ]] && echo 1 || echo 0)
  LAST_EVID="rc=$rc stage=$stage_left owner=$owner_left live=$live_start чужая=$other_start :: $out"
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  rm -rf "$root"
  if (( rc != 1 )) || [[ "$out" != *"sync-new.$live"* ]]; then
    bad '6 стадии: переиспользованный номер с чужой меткой не объявлен расхождением'; return
  fi
  if [[ "$stage_left" != 0 || "$owner_left" != 0 ]]; then
    LAST_EVID="ОСТАЛСЯ_ЧУЖОЙ_ВЛАДЕЛЕЦ stage=$stage_left owner=$owner_left :: $out"
    bad '6 стадии: прополка не сняла стадию вместе с владельцем'; return
  fi
  ok '6 стадии: номер жив, но чужая lstart делает стадию мёртвой; стадия и владелец убраны'
}

scenario_7() {   # путь отказа обязан КОНЧАТЬСЯ, а не виснуть
  local root start elapsed rc pid wd stub_pid orphan
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s7.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  start=$(date +%s) || { printf 'ПРИБОР НЕДОСТУПЕН: не получено время старта замера пути отказа\n' >&2; exit 2; }
  bash "$KIT/tools/probes-sync-bench.sh" --hang-case "$root" >"$root/hang.log" 2>&1 &
  pid=$!
  ( sleep 90; kill -9 "$pid" 2>/dev/null ) &
  wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  elapsed=$(( $(date +%s) - start ))
  # Сирота проверяется ДО собственного освобождения: освободишь раньше --
  # заглушка выйдет сама, и утечка станет невидимой.
  stub_pid=$(cat "$root/stub.pid" 2>/dev/null || true)
  orphan=нет
  if [[ -n "$stub_pid" ]] && kill -0 "$stub_pid" 2>/dev/null; then orphan=да; fi
  : > "$root/release" 2>/dev/null || true
  [[ -n "$stub_pid" ]] && wait_death "$stub_pid" 100 >/dev/null 2>&1 || true
  LAST_EVID="rc=$rc секунд=$elapsed сирота=$orphan :: $(cat "$root/hang.log" 2>/dev/null)"
  if (( rc != 0 )) || (( elapsed >= 90 )); then
    LAST_EVID="ПУТЬ_ОТКАЗА_ЗАВИС rc=$rc секунд=$elapsed"
    rm -rf "$root"
    bad '7 путь отказа обязан кончиться отказом, а не зависнуть'
    return
  fi
  if [[ "$orphan" == да ]]; then
    LAST_EVID="СИРОТА_ЗАГЛУШКИ pid=$stub_pid остался жив после пути отказа"
    rm -rf "$root"
    bad '7 путь отказа обязан освободить заглушку, а не бросить её'
    return
  fi
  rm -rf "$root"
  ok '7 первый писатель не вошёл в cp: путь отказа кончился в бюджете и не бросил сироту'
}

# ВЛАДЕЛЕЦ РАСПИСАНИЯ (волна 235): сверка была слепа по платформе (владелец
# искался только циклом по *judge-compact.plist, которого на Linux нет по
# построению) и молчала при нуле владельцев (скобка вместо вердикта, exit 0 --
# снос расписания на машине с предметом неотличим от исправности). Сценарии
# 12-19 держат ОБЕ беды: платформа подменяется дверцей
# CLAUDE_SCHEDULE_PLATFORM, прибор -- CLAUDE_CRONTAB_CMD; ветка чужой
# платформы мертва на живой машине, и зуб в мёртвой ветке ничего не меряет.
scenario_12() {
  local root script plist out rc
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s12.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '12 владелец Darwin: исходная раскатка отказала'; return; }
  # Фикстура -- заполненный агент: цель указывает на раскатанный compact.py,
  # аргументы покрывают весь набор проб. Имя обязано кончаться на
  # judge-compact.plist -- по этому хвосту сверка и ищет владельца.
  plist="$CLAUDE_LAUNCH_AGENTS_DIR/bench.judge-compact.plist"
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '<key>Label</key><string>bench.judge-compact</string>\n'
    printf '<key>ProgramArguments</key>\n<array>\n'
    printf '<string>/usr/bin/python3</string>\n'
    printf '<string>%s/compact.py</string>\n' "$CLAUDE_JUDGE_TOOLS_DIR"
    printf '<string>--probe</string>\n'
    printf '<string>judge,failover</string>\n'
    printf '</array>\n</dict>\n</plist>\n'; } > "$plist"
  out=$(CLAUDE_SCHEDULE_PLATFORM=Darwin bash "$script" --diff 2>&1); rc=$?
  LAST_EVID="rc=$rc :: $out"
  rm -rf "$root"
  if [[ $rc -ne 0 ]]; then
    bad "12 владелец Darwin: верный агент обязан давать зелёную сверку, получили $rc"; return
  fi
  if [[ "$out" != *"запускает раскатанный compact.py"* \
     || "$out" != *"покрывает пробу judge"* \
     || "$out" != *"покрывает пробу failover"* ]]; then
    bad '12 владелец Darwin: цель или покрытие не названы зелёными строками'; return
  fi
  if [[ "$out" == *расходится* ]]; then
    bad '12 владелец Darwin: верный агент покрасил сверку'; return
  fi
  ok '12 владелец Darwin: цель верна, обе пробы набора покрыты, сверка зелёная'
}

scenario_13() {
  local root script out rc
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s13.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '13 без владельца Darwin: исходная раскатка отказала'; return; }
  # Каталог агентов пуст, предмета прополки нет: нулевой предмет обязан быть
  # зелёным, но С названной причиной и механизмом -- молчание не различимо
  # с исправностью.
  out=$(CLAUDE_SCHEDULE_PLATFORM=Darwin bash "$script" --diff 2>&1); rc=$?
  LAST_EVID="rc=$rc :: $out"
  rm -rf "$root"
  if [[ $rc -ne 0 ]]; then
    bad "13 без владельца Darwin: пустой предмет обязан быть зелёным, получили $rc"; return
  fi
  if [[ "$out" != *"(владельца расписания нет; предмета тоже нет: записей 0, шардов 0 — заводить нечего. Владельцем на Darwin будет launchd-агент)"* ]]; then
    LAST_EVID="ПРИЧИНА_НЕ_НАЗВАНА $LAST_EVID"
    bad '13 без владельца Darwin: зелёность не назвала причину и механизм'; return
  fi
  ok '13 без владельца Darwin: нулевой предмет зелёен с названной причиной'
}

scenario_14() {
  local root script out rc
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s14.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '14 без владельца Darwin: исходная раскатка отказала'; return; }
  mkdir -p "$CLAUDE_PROBES_DIR/judge/records"
  printf '{}' > "$CLAUDE_PROBES_DIR/judge/records/rec-1.json"
  out=$(CLAUDE_SCHEDULE_PLATFORM=Darwin bash "$script" --diff 2>&1); rc=$?
  LAST_EVID="rc=$rc :: $out"
  rm -rf "$root"
  if [[ $rc -ne 1 ]]; then
    LAST_EVID="РАСХОЖДЕНИЕ_НЕ_НАЗВАНО $LAST_EVID"
    bad "14 без владельца Darwin: предмет без владельца обязан краснить (1), получили $rc"; return
  fi
  if [[ "$out" != *"расходится: владельца расписания нет, а предмет прополки есть (записей 1, шардов 0)"* ]]; then
    LAST_EVID="ПРЕДМЕТ_НЕ_НАЗВАН $LAST_EVID"
    bad '14 без владельца Darwin: расхождение не назвало предмет живым счётом'; return
  fi
  ok '14 без владельца Darwin: предмет прополки без владельца назван счётом и краснит'
}

scenario_15() {
  local root script stub out rc
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s15.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '15 без владельца Linux: исходная раскатка отказала'; return; }
  # Код 1 -- ШТАТНОЕ «таблицы нет»: заглушка обязана отвечать кодом прибора,
  # а не выходить из строя. Настоящий crontab не зовётся: подмена прибором
  # стенда, фикстуры только во временном каталоге.
  stub="$root/stub"; mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stub/crontab"
  chmod +x "$stub/crontab"
  mkdir -p "$CLAUDE_PROBES_DIR/judge/records"
  printf '{}' > "$CLAUDE_PROBES_DIR/judge/records/rec-1.json"
  out=$(CLAUDE_SCHEDULE_PLATFORM=Linux CLAUDE_CRONTAB_CMD="$stub/crontab" bash "$script" --diff 2>&1); rc=$?
  LAST_EVID="rc=$rc :: $out"
  rm -rf "$root"
  if [[ $rc -ne 1 ]]; then
    LAST_EVID="РАСХОЖДЕНИЕ_НЕ_НАЗВАНО $LAST_EVID"
    bad "15 без владельца Linux: предмет без владельца обязан краснить (1), получили $rc"; return
  fi
  if [[ "$out" != *"расходится: владельца расписания нет, а предмет прополки есть (записей 1, шардов 0)"* ]]; then
    LAST_EVID="ПРЕДМЕТ_НЕ_НАЗВАН $LAST_EVID"
    bad '15 без владельца Linux: расхождение не назвало предмет живым счётом'; return
  fi
  ok '15 без владельца Linux: crontab-таблицы нет, предмет назван счётом и краснит'
}

scenario_16() {
  local root script stub cron_line out rc
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s16.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '16 владелец Linux: исходная раскатка отказала'; return; }
  stub="$root/stub"; mkdir -p "$stub"
  cron_line="17 * * * * $CLAUDE_JUDGE_TOOLS_DIR/compact.py --probe judge,failover"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$cron_line" > "$stub/crontab"
  chmod +x "$stub/crontab"
  out=$(CLAUDE_SCHEDULE_PLATFORM=Linux CLAUDE_CRONTAB_CMD="$stub/crontab" bash "$script" --diff 2>&1); rc=$?
  LAST_EVID="rc=$rc :: $out"
  rm -rf "$root"
  if [[ $rc -ne 0 ]]; then
    bad "16 владелец Linux: строка с целью и полным покрытием обязана давать зелёную сверку, получили $rc"; return
  fi
  if [[ "$out" != *"расписание crontab запускает раскатанный compact.py"* ]]; then
    LAST_EVID="ВЛАДЕЛЕЦ_НЕ_УЗНАН $LAST_EVID"
    bad '16 владелец Linux: строка-владелец не распознана сверкой'; return
  fi
  if [[ "$out" != *"расписание crontab покрывает пробу judge"* \
     || "$out" != *"расписание crontab покрывает пробу failover"* ]]; then
    LAST_EVID="ВЛАДЕЛЕЦ_НЕ_УЗНАН $LAST_EVID"
    bad '16 владелец Linux: покрытие проб набора не названо зелёными строками'; return
  fi
  ok '16 владелец Linux: строка crontab с целью и полным покрытием зелёная'
}

scenario_17() {
  local root script stub cron_line out rc
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s17.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '17 покрытие Linux: исходная раскатка отказала'; return; }
  stub="$root/stub"; mkdir -p "$stub"
  cron_line="17 * * * * $CLAUDE_JUDGE_TOOLS_DIR/compact.py --probe judge"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$cron_line" > "$stub/crontab"
  chmod +x "$stub/crontab"
  out=$(CLAUDE_SCHEDULE_PLATFORM=Linux CLAUDE_CRONTAB_CMD="$stub/crontab" bash "$script" --diff 2>&1); rc=$?
  LAST_EVID="rc=$rc :: $out"
  rm -rf "$root"
  if [[ $rc -ne 1 ]]; then
    LAST_EVID="НЕПОКРЫТИЕ_НЕ_НАЗВАНО $LAST_EVID"
    bad "17 покрытие Linux: частичное покрытие обязано краснить (1), получили $rc"; return
  fi
  if [[ "$out" != *"расходится: расписание crontab не покрывает пробу failover"* ]]; then
    LAST_EVID="НЕПОКРЫТИЕ_НЕ_НАЗВАНО $LAST_EVID"
    bad '17 покрытие Linux: непокрытая проба набора не названа по имени'; return
  fi
  ok '17 покрытие Linux: непокрытая проба набора названа и краснит'
}

scenario_18() {
  local root script stub out rc
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s18.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '18 отказ прибора Linux: исходная раскатка отказала'; return; }
  stub="$root/stub"; mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 2\n' > "$stub/crontab"
  chmod +x "$stub/crontab"
  out=$(CLAUDE_SCHEDULE_PLATFORM=Linux CLAUDE_CRONTAB_CMD="$stub/crontab" bash "$script" --diff 2>&1); rc=$?
  LAST_EVID="rc=$rc :: $out"
  rm -rf "$root"
  if [[ $rc -ne 1 ]]; then
    LAST_EVID="НЕДОСТУПЕН_НЕ_НАЗВАН $LAST_EVID"
    bad "18 отказ прибора Linux: неизмеримое обязано краснить (1), получили $rc"; return
  fi
  if [[ "$out" != *"ПРИБОР НЕДОСТУПЕН: crontab -l вернул код 2"* ]]; then
    LAST_EVID="НЕДОСТУПЕН_НЕ_НАЗВАН $LAST_EVID"
    bad '18 отказ прибора Linux: отказ прибора не назван с кодом'; return
  fi
  ok '18 отказ прибора Linux: код 2 краснит сверку как ПРИБОР НЕДОСТУПЕН'
}

scenario_19() {
  local root script out rc
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s19.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
  [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '19 чужая платформа: исходная раскатка отказала'; return; }
  out=$(CLAUDE_SCHEDULE_PLATFORM=Plan9 bash "$script" --diff 2>&1); rc=$?
  LAST_EVID="rc=$rc :: $out"
  rm -rf "$root"
  if [[ $rc -ne 1 ]]; then
    LAST_EVID="ПЛАТФОРМА_НЕ_НАЗВАНА $LAST_EVID"
    bad "19 чужая платформа: неизвестная платформа обязана краснить (1), получили $rc"; return
  fi
  if [[ "$out" != *"расходится: прибор не знает владельца расписания для платформы Plan9"* ]]; then
    LAST_EVID="ПЛАТФОРМА_НЕ_НАЗВАНА $LAST_EVID"
    bad '19 чужая платформа: незнакомая платформа не названа в вердикте'; return
  fi
  ok '19 чужая платформа: незнакомая платформа названа и краснит (fail-closed)'
}

# Правило открытия -- ЕДИНСТВЕННЫЙ дом tools/heredoc-anchor.py (у этой копии
# никогда не было ни отсева стаба, ни якоря мутации); инструмент берётся из
# НАСТОЯЩЕГО кита (REAL_KIT), а не из переназначаемого KIT. Отказ инструмента
# (код 2) -- «прибор не может мерить», а не «тел нет».
python_heredoc_bodies() {   # файл-жертва, каталог для тел; печатает число тел
  local __n __rc
  __n=$(python3 "$REAL_KIT/tools/heredoc-anchor.py" --bodies "$1" "$2"); __rc=$?
  (( __rc == 0 )) || return 2
  printf '%s\n' "$__n"
}

# Страж разбираемости жертвы: bash -n плюс py_compile каждого питоньего тела.
# Провал -- ненулевой возврат; вызывающий переводит его в код «прибор не может
# мерить». Та же пара, что у corpus-tools-bench (круг 24 + 25, E-1).
sh_victim_parses() {   # файл-жертва
  local f="$1" dir n i
  bash -n "$f" 2>/dev/null || return 2
  dir=$(mktemp -d "${TMPDIR:-/tmp}/heredoc.XXXXXX") || return 2
  n=$(python_heredoc_bodies "$f" "$dir") || return 2
  # BSD seq при пустом диапазоне (seq 1 0) печатает «1 0» ВНИЗ, а не пустоту:
  # без этой проверки страж гонял бы py_compile по несуществующим файлам
  # и краснел на жертвах без питоньих тел (замерено на этой машине).
  if (( n > 0 )); then
    for i in $(seq 1 "$n"); do
      python3 -m py_compile "$dir/body.$i.py" 2>/dev/null || { rm -rf "$dir"; return 2; }
    done
  fi
  rm -rf "$dir"
  return 0
}

mutate() {
  # Круг 28, F-15: объявление и присваивание РАЗДЕЛЕНЫ. В форме
  # `local root="$1" n="$2" file="$root/…"` все слова раскрываются ДО
  # исполнения local, и `$root` в третьем слове брал значение ЛОКАЛИ
  # ВЫЗЫВАЮЩЕГО (динамическая область видимости bash): пока mutate звали из
  # self_check, где `root` есть, строка работала случайно; вызов с верхнего
  # уровня под `set -u` ронял скрипт «root: unbound variable».
  local root n file
  root="$1"; n="$2"
  # Жертва мутаций 7 и 8 -- САМ СТЕНД в копии кита: она меряет его путь отказа.
  case "$n" in
    7|8) file="$root/kit/tools/probes-sync-bench.sh" ;;
    *) file="$root/kit/scripts/probes-sync.sh" ;;
  esac
  local __pyrc=0
  python3 - "$file" "$n" 2>"$root/mutate.err" <<'PY' || __pyrc=$?
import sys
path, number = sys.argv[1], int(sys.argv[2])
text = open(path, encoding='utf-8').read()
if number == 1:
    old, new = "\n  acquire_sync_lock\n", "\n  : # mutation: writer lock removed\n"
elif number == 2:
    old, new = "\n  report_sync_stages\n", "\n  : # mutation: stage report removed\n"
elif number == 3:
    # Сравнение метки старта выключается: живость снова решает один kill -0,
    # переиспользованный номер читается как живой владелец.
    old, new = ('           || [[ "$__ps_lstart" == "$__ostart" ]]; then\n',
                '           || true; then  # mutation: label ignored, kill -0 decides\n')
elif number == 4:
    # Обход возвращается к одной домашней стороне: обломок на канонной
    # стороне снова невидим ни отчёту, ни прополке.
    old, new = ('for ((__i=0; __i<${#PAIR_A[@]}; __i++)); do\n',
                'for ((__i=0; __i<0; __i++)); do  # mutation: canon side not walked\n')
elif number == 5:
    # Проверка живости в отчёте выключается: каждая стадия снова расходится.
    old, new = ('  if sync_stage_writer_alive "$1"; then\n',
                '  if false; then  # mutation: every stage counts as divergence\n')
elif number == 6:
    old, new = ('[[ "$__now" == "$__owner_start" ]]', 'true  # mutation: owner lstart ignored')
elif number == 7:
    # Вся починка снимается разом -- порядок И потолки: ветка возвращается к
    # форме, измеренной 2026-08-31, где путь отказа висел вечно. Свойство
    # «путь отказа кончается» несут обе ноги вместе, поэтому зуб на зависание
    # может быть только таким.
    old, new = ('    : > "$release"\n'
                '    kill "$first_pid" 2>/dev/null\n'
                '    wait_death "$first_pid" || kill -9 "$first_pid" 2>/dev/null\n'
                '    wait "$first_pid" 2>/dev/null\n',
                '    kill "$first_pid" 2>/dev/null; wait "$first_pid" 2>/dev/null\n')
elif number == 8:
    # Снимается ТОЛЬКО освобождение: потолки на месте, зависания нет -- но
    # заглушка остаётся сиротой навсегда. Своя причина у этой ноги приходит
    # не через зависание, а через проверку сироты.
    old, new = ('    : > "$release"\n    kill "$first_pid" 2>/dev/null\n',
                '    kill "$first_pid" 2>/dev/null  # mutation: release withheld\n')
elif number == 9:
    # Отказ возвращается к ДОСЛОВНОЙ прежней редакции: одна строка, одно
    # направление. Расхождение остаётся расхождением (код прежний), но выбора
    # у читателя больше нет -- и совет уничтожает правку, сделанную в доме.
    old = ('    echo "ИТОГ: расходится файлов: $DIFFERS$__also" >&2\n'
           '    echo "  Направление НЕ выводится из расхождения -- решает человек:" >&2\n'
           '    echo "    bash $0 --to-home     канон -> дом  (потеряет правки, сделанные В ДОМЕ)" >&2\n'
           '    echo "    bash $0 --from-home   дом -> канон  (потеряет правки, сделанные В КАНОНЕ)" >&2\n'
           '    echo "  Стороны: канон $ROOT, дом проб $PROBES_HOME, дом инструментов $TOOLS_HOME" >&2\n')
    new = '    echo "ИТОГ: расходится файлов: $DIFFERS$__also (раскатать: bash $0 --to-home)" >&2\n'
elif number == 10:
    # Ценз со стороны дома выключается: исходник, живущий только в доме,
    # снова невидим -- ровно состояние, в котором четыре инструмента судьи
    # прожили вне репозитория.
    old, new = ('    if [[ ! -f "$ROOT/judge/$__rel" ]]; then\n',
                '    if false; then  # mutation: home census blinded\n')
elif number == 11:
    # Нога отслеживаемости выключается ЦЕЛИКОМ: файл, лежащий в каталоге
    # канона, но не попавший в индекс, снова читается как занесённый --
    # ровно ложное зелёное, которое дала строка `judge/bench/` в .gitignore.
    old = '    elif [[ "$TRACK_CENSUS" == \'да\' ]]; then\n'
    new = '    elif false; then  # mutation: repo census blinded\n'
elif number == 12:
    # Перечень начинает ПЕРЕсчитывать набор: последняя пара называется дважды.
    # Мутация выбрана так, чтобы бить ТОЛЬКО сверку слова с делом: канон
    # строится по этому же перечню, и мутация, роняющая --list в отказ, убила
    # бы саму подготовку (прибор перестал бы мерить вместо того, чтобы
    # покраснеть). Дубль перезаписывает свой же файл -- канон остаётся полон,
    # а названное расходится с разложенным ровно на единицу.
    old = ('  for ((__i=0; __i<__pairs; __i++)); do printf \'%s\\n\' "${PAIR_N[$__i]}"; done\n')
    new = ('  for ((__i=0; __i<__pairs; __i++)); do printf \'%s\\n\' "${PAIR_N[$__i]}"; done\n'
           '  printf \'%s\\n\' "${PAIR_N[$((__pairs-1))]}"  # mutation: set over-reported\n')
elif number == 13:
    # Сверка цели владельца расписания инвертируется: верно заполненный агент
    # объявляется чужим. Сценарий 12 держит зелёное состояние владельца, и его
    # краснота обязана прийти строкой цели, а не посторонним кодом.
    old, new = ('        if grep -qF "$TOOLS_HOME/compact.py" "$__pl"; then\n',
                '        if false; then  # mutation: schedule target always diverges\n')
elif number == 14:
    # Зелёный вердикт нулевого предмета замолкает: код возврата не меняется,
    # но причина и механизм не называются -- ровно то молчание, что чинила
    # волна 235 (беда B).
    old, new = ('      echo "(владельца расписания нет; предмета тоже нет: записей $__sched_rec, шардов $__sched_shard — заводить нечего. Владельцем на $SCHEDULE_PLATFORM будет $__sched_owner_kind)"\n',
                '      :  # mutation: zero-subject reason silenced\n')
elif number == 15:
    # Предметный вердикт слепнет: предмет прополки при отсутствии владельца
    # снова читается как зелёное -- красная строка не печатается, код
    # выравнивается на ноль (беда B, Darwin-нога).
    old, new = ('    if [[ "$((__sched_rec+__sched_shard))" -gt 0 ]]; then\n',
                '    if false; then  # mutation: subject verdict blinded\n')
elif number == 16:
    # Linux-ветка владельца мертвеет: платформа Linux падает в умолчание
    # «не знает владельца», и предметный вердикт не выполняется вовсе (беда A).
    old, new = ('    Linux)\n',
                '    Linux-Never)  # mutation: linux owner branch dead\n')
elif number == 17:
    # Распознавание строки-владельца выключается: crontab отвечает кодом 0,
    # но ни одна строка не признаётся владельцем -- зелёные строки владельца
    # исчезают при неизменном коде возврата.
    old, new = ('          [[ "$__cline" == *"$TOOLS_HOME/compact.py"* ]] || continue\n',
                '          continue  # mutation: crontab owner line never matched\n')
elif number == 18:
    # Покрытие проверяет только первую пробу набора: частичное покрытие снова
    # зелёное -- зуб сценария 17 существует именно против этой слепоты.
    old, new = ('  for __probe in $SCHEDULE_PROBES; do\n',
                '  for __probe in judge; do  # mutation: coverage checks first probe only\n')
elif number == 19:
    # Отказ прибора проглатывается: код 2 читается как ответ 0, неизмеримое
    # становится молчаливым зелёным -- fail-closed выключен целиком.
    old, new = ('      __cron_out="$("$CRONTAB_CMD" -l)" || __cron_rc=$?\n',
                '      __cron_out="$("$CRONTAB_CMD" -l)" || __cron_rc=0  # mutation: instrument failure swallowed\n')
elif number == 20:
    # Незнакомая платформа замолкает: расхождение остаётся (DIFFERS растёт),
    # но вердикт не называет причину -- читатель видит счёт без имени беды.
    old, new = ('      echo "расходится: прибор не знает владельца расписания для платформы $SCHEDULE_PLATFORM"\n',
                '      :  # mutation: unknown platform silent\n')
elif number == 21:
    old = ('        printf \'ПРИБОР НЕДОСТУПЕН: свидетель индекса нечитаем: %s\\n\' "$__wit" >&2\n'
           '        exit 2\n')
    new = ('        TRACK_CENSUS=\'нет\'\n'
           '        echo "ЦЕНЗ РЕПОЗИТОРИЯ: НЕ ИЗМЕРЕНО -- канон не в рабочем дереве git ($__git_probe)"\n'
           '        __wit_ready=0\n')
elif number == 22:
    old = ('        printf \'ПРИБОР НЕДОСТУПЕН: свидетель индекса битый (COUNT=%s, путей=%s): %s\\n\' "$__wit_count" "$__wit_npaths" "$__wit" >&2\n'
           '        exit 2\n')
    new = ('        TRACK_CENSUS=\'нет\'\n'
           '        echo "ЦЕНЗ РЕПОЗИТОРИЯ: НЕ ИЗМЕРЕНО -- канон не в рабочем дереве git ($__git_probe)"\n'
           '        __wit_broken=1\n')
elif number == 23:
    old, new = ('      if [[ "$__wit_judge" -eq 0 ]]; then\n',
                '      if false; then  # mutation: empty witness treated as tracked census\n')
elif number == 24:
    old, new = ('        __git_ls=$(printf \'%s\\n\' "$__wit_paths" | grep -Fx "judge/$__rel") || true\n',
                '        __git_ls="judge/$__rel"  # mutation: witness membership always tracked\n')
else:
    sys.stderr.write('unknown mutation %d\n' % number)
    raise SystemExit(2)
count = text.count(old)
if count != 1:
    sys.stderr.write('mutation %d anchor count=%d\n' % (number, count))
    raise SystemExit(2)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
PY
  # Код питоньего этапа обязан быть прочитан: при ненайденном якоре правка НЕ
  # ВНОСИТСЯ, жертва остаётся валидной, и прогон сценария на нетронутом ките
  # даёт зелёное, неотличимое от «зуб слеп». Отказ прибора не имеет права
  # читаться как вердикт о зубе -- отсюда отдельный код 3.
  if (( __pyrc != 0 )); then
    say "  НЕИЗМЕРИМО мутация $n: правка не внесена (код $__pyrc): $(cat "$root/mutate.err")"
    return 3
  fi
  # Круг 25, E-3: замена сломала разбор -- прибор не может мерить. До стража
  # текст влетал в жертву свободно, и сломанный разбор держался только на
  # случайности (следи этой таблицы привязаны к коду возврата). Отдельный
  # класс от «якорь не найден» и с доминированием над счётом покраснений:
  # self_check ниже останавливается целиком.
  if ! sh_victim_parses "$file"; then
    say "  мутация $n сломала РАЗБОР жертвы -- замена невалидна, прибор чинится до следующего вердикта"
    return 2
  fi
  return 0
}

self_check() {
  local n root before reddened=0 unmeasurable=0 mrc
  for ((n = 1; n <= EXPECTED_MUTATIONS; n++)); do
    root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-mut.XXXXXX") || { printf 'ПРИБОР НЕДОСТУПЕН: не создан временный каталог\n' >&2; exit 2; }
    [ -n "$root" ] || { printf 'ПРИБОР НЕДОСТУПЕН: путь временного каталога пуст\n' >&2; exit 2; }
    mk_kit "$root/kit"
    mrc=0; mutate "$root" "$n" || mrc=$?
    # Код 3 -- правка не внесена: этот зуб неизмерим, но остальные измеримы,
    # и обход продолжается. Остановка здесь оставила бы хвост таблицы НЕ
    # ИЗМЕРЕННЫМ, а счёт покраснений -- ложно полным.
    if (( mrc == 3 )); then unmeasurable=$((unmeasurable + 1)); rm -rf "$root"; continue; fi
    # Код 2 -- разбор жертвы сломан: замена невалидна, прибор чинится до
    # следующего вердикта.
    if (( mrc != 0 )); then rm -rf "$root"; return 2; fi
    local saved_kit="$KIT"
    KIT="$root/kit"; before=$FAILED; LAST_EVID=''
    run_scenario "${MUT_SCENARIO[$n]}" || { say "  ОТКАЗ ПРИБОРА: сценария ${MUT_SCENARIO[$n]} нет (мутация $n)"; rm -rf "$root"; return 2; }
    KIT="$saved_kit"
    if (( FAILED > before )); then
      if [[ "$LAST_EVID" == *"${MUT_EVID[$n]}"* ]]; then
        reddened=$((reddened + 1))
        say "  ok     мутация $n покраснила сценарий ${MUT_SCENARIO[$n]} своей причиной"
      else
        say "  ПРОВАЛ мутация $n покраснила чужой причиной: $LAST_EVID"
      fi
      FAILED=$before
    else
      say "  ПРОВАЛ мутация $n прошла молча"
    fi
    rm -rf "$root"
  done
  say "probes-sync-bench: SELF-CHECK мутаций=$EXPECTED_MUTATIONS покраснели=$reddened неизмеримо=$unmeasurable"
  [[ $reddened -eq $EXPECTED_MUTATIONS ]]
}

case "${1:-}" in
  '')
    check_mut_tables || exit 4
    # Обход -- по объявленному числу, не по литеральному перечню: дописанный
    # scenario_N, забытый в перечне, иначе молча не исполняется, а RUN всё
    # равно сходится с EXPECTED_SCENARIOS, если число тоже забыли поднять.
    for __s in $(seq 1 "$EXPECTED_SCENARIOS"); do
      run_scenario "$__s" || {
        say "probes-sync-bench: ОТКАЗ -- объявлено сценариев $EXPECTED_SCENARIOS, а scenario_$__s не определён"
        exit 4; }
    done
    say "probes-sync-bench: ИТОГ сценариев=$RUN расхождений=$FAILED"
    [[ $RUN -eq $EXPECTED_SCENARIOS ]] || exit 4
    [[ $FAILED -eq 0 ]] || exit 1
    ;;
  --self-check)
    check_mut_tables || exit 4
    self_check || exit $?
    ;;
  --hang-case)
    # Служебный режим: исполняет пляску двух писателей в режиме silent и
    # печатает исход. Зовётся сценарием 7 из КОПИИ кита.
    if two_writers "$2" silent; then
      say "ХОД: дошли до удачного пути (в режиме silent это невозможно)"
      exit 1
    fi
    say "ХОД: $TW_REASON"
    exit 0 ;;
  *) say "probes-sync-bench: ОТКАЗ -- неизвестный режим $1" >&2; exit 2 ;;
esac
