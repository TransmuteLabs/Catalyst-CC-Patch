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
BENCH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "$0")
EXPECTED_SCENARIOS=7
EXPECTED_MUTATIONS=8
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
MUT_SCENARIO=(x 1 2 3 4 5 6 7 7)
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
  printf 'probe config\n' > "$dst/probes/probes.toml"
  printf 'judge prompt\n' > "$dst/probes/judge/prompt.md"
  printf '{}\n' > "$dst/probes/judge/body.json"
  printf 'idle prompt\n' > "$dst/probes/idle-watch/prompt.md"
  for f in replay.py compact.py validate.py channel.py adjudicate.py README.md; do
    printf 'canon %s\n' "$f" > "$dst/judge/$f"
  done
  printf '/Users/YOUR-USER\n' > "$dst/judge/com.transmutelabs.judge-compact.plist"
}

make_env() {
  local root="$1"
  export CLAUDE_CONFIG_DIR="$root/home"
  export CLAUDE_PROBES_DIR="$root/home/probes"
  export CLAUDE_JUDGE_TOOLS_DIR="$root/home/judge"
  export CLAUDE_LAUNCH_AGENTS_DIR="$root/home/agents"
  export PROBES_SYNC_LOCK="$root/home/probes-sync.lock"
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
  TW_SECOND_LOG=$(cat "$second_log")
  return 0
}

scenario_1() {
  local root
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s1.XXXXXX")
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
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s2.XXXXXX")
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '2 стадии: исходная раскатка отказала'; return; }
  dead=$(dead_pid)
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
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s3.XXXXXX")
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
  dead_start=$(LC_ALL=C ps -o lstart= -p "$dead_holder" 2>/dev/null)
  kill "$dead_holder" 2>/dev/null; wait "$dead_holder" 2>/dev/null
  sleep 1.5
  sleep 60 & live=$!
  live_start=$(LC_ALL=C ps -o lstart= -p "$live" 2>/dev/null)
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
  dead=$(dead_pid)
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
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s5.XXXXXX")
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
run_scenario() {
  case "$1" in 1) scenario_1 ;; 2) scenario_2 ;; 3) scenario_3 ;; 4) scenario_4 ;; 5) scenario_5 ;; 6) scenario_6 ;; 7) scenario_7 ;; 8) scenario_7 ;; *) return 2 ;; esac
}

# Круг 25, E-3: тела heredoc'ов .sh-жертвы, поданные питону, по правилу гейта
# PYCOMPILE конвейера: строка до первого '#' содержит python3 границей слова,
# между python3 и открытием нет '|' ';' '&', строка КОНЧАЕТСЯ открытием
# <<'ТЕГ'; тело -- до строки, равной ТЕГУ дословно. Сегодня у жертвы
# probes-sync.sh таких тел нет, но страж пишется по ПРАВИЛУ, а не по факту
# сегодняшнего файла: первая же мутация в питонье тело потребует этой
# проверки, а не случайности (решение контроллера, волна 25).

scenario_6() {
  local root script live live_start other_start stage owner out rc stage_left owner_left
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s6.XXXXXX")
  mk_kit "$root/kit"; make_env "$root"
  script="$root/kit/scripts/probes-sync.sh"
  bash "$script" --to-home >/dev/null 2>&1 || {
    LAST_EVID='ПОДГОТОВКА_ДОМА_НЕ_СОШЛАСЬ'; rm -rf "$root"
    bad '6 стадии: исходная раскатка отказала'; return; }
  sleep 60 & live=$!
  live_start=$(LC_ALL=C ps -o lstart= -p "$live" 2>/dev/null)
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
  root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-s7.XXXXXX")
  mk_kit "$root/kit"; make_env "$root"
  start=$(date +%s)
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

python_heredoc_bodies() {   # файл-жертва, каталог для тел; печатает число тел
  local f="$1" out="$2" line pre rest mid tag n=0
  local OPEN_RE="<<'([A-Za-z_][A-Za-z0-9_]*)'[[:space:]]*\$"
  tag=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$tag" ]]; then
      if [[ "$line" == "$tag" ]]; then tag=''; continue; fi
      printf '%s\n' "$line" >> "$out/body.$n.py"
      continue
    fi
    pre=${line%%#*}
    [[ "$pre" == *python3* ]] || continue
    [[ "$pre" =~ (^|[^A-Za-z0-9_])python3([^A-Za-z0-9_]|$) ]] || continue
    rest=${pre#*python3}
    mid=${rest%<<*}
    [[ "$mid" == *[\|\;\&]* ]] && continue
    [[ "$pre" =~ $OPEN_RE ]] || continue
    tag=${BASH_REMATCH[1]}
    n=$((n+1)); : > "$out/body.$n.py"
  done < "$f"
  printf '%s\n' "$n"
}

# Страж разбираемости жертвы: bash -n плюс py_compile каждого питоньего тела.
# Провал -- ненулевой возврат; вызывающий переводит его в код «прибор не может
# мерить». Та же пара, что у corpus-tools-bench (круг 24 + 25, E-1).
sh_victim_parses() {   # файл-жертва
  local f="$1" dir n i
  bash -n "$f" 2>/dev/null || return 2
  dir=$(mktemp -d "${TMPDIR:-/tmp}/heredoc.XXXXXX") || return 2
  n=$(python_heredoc_bodies "$f" "$dir")
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
  python3 - "$file" "$n" <<'PY'
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
    old, new = ('           || [[ "$(LC_ALL=C ps -o lstart= -p "$__opid" 2>/dev/null)" == "$__ostart" ]]; then\n',
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
else:
    sys.stderr.write('unknown mutation %d\n' % number)
    raise SystemExit(2)
count = text.count(old)
if count != 1:
    sys.stderr.write('mutation %d anchor count=%d\n' % (number, count))
    raise SystemExit(2)
open(path, 'w', encoding='utf-8').write(text.replace(old, new, 1))
PY
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
  local n root before reddened=0
  for n in 1 2 3 4 5 6 7 8; do
    root=$(mktemp -d "${TMPDIR:-/tmp}/probes-sync-mut.XXXXXX")
    mk_kit "$root/kit"
    if ! mutate "$root" "$n"; then rm -rf "$root"; return 2; fi
    local saved_kit="$KIT"
    KIT="$root/kit"; before=$FAILED; LAST_EVID=''
    run_scenario "$n"
    KIT="$saved_kit"
    if (( FAILED > before )); then
      case "$n:$LAST_EVID" in
        1:*"второй=0"*) reddened=$((reddened + 1)); say '  ok     мутация 1 покраснила сценарий 1 своей причиной' ;;
        2:*"diff_rc=0"*) reddened=$((reddened + 1)); say '  ok     мутация 2 покраснила сценарий 2 своей причиной' ;;
        3:*"B=3"*) reddened=$((reddened + 1)); say '  ok     мутация 3 покраснила сценарий 3 своей причиной' ;;
        4:*"НЕ_НАЗВАНА"*) reddened=$((reddened + 1)); say '  ok     мутация 4 покраснила сценарий 4 своей причиной' ;;
        5:*"rc=1"*) reddened=$((reddened + 1)); say '  ok     мутация 5 покраснила сценарий 5 своей причиной' ;;
        6:*"rc=0"*) reddened=$((reddened + 1)); say '  ok     мутация 6 покраснила сценарий 6 своей причиной' ;;
        7:*"ПУТЬ_ОТКАЗА_ЗАВИС"*) reddened=$((reddened + 1)); say '  ok     мутация 7 покраснила сценарий 7 своей причиной' ;;
        8:*"СИРОТА_ЗАГЛУШКИ"*) reddened=$((reddened + 1)); say '  ok     мутация 8 покраснила сценарий 7 своей причиной' ;;
        *) say "  ПРОВАЛ мутация $n покраснила чужой причиной: $LAST_EVID" ;;
      esac
      FAILED=$before
    else
      say "  ПРОВАЛ мутация $n прошла молча"
    fi
    rm -rf "$root"
  done
  say "probes-sync-bench: SELF-CHECK мутаций=$EXPECTED_MUTATIONS покраснели=$reddened"
  [[ $reddened -eq $EXPECTED_MUTATIONS ]]
}

case "${1:-}" in
  '')
    check_mut_tables || exit 4
    scenario_1; scenario_2; scenario_3; scenario_4; scenario_5; scenario_6; scenario_7
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
