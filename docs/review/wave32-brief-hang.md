# Волна 32, бриф: путь отказа сценария 1 probes-sync-bench обязан КОНЧАТЬСЯ

Класс задачи: механизм в тест-инструментальном контуре, прод-радиус нулевой.
Дизайн запинен полностью — открытых вопросов НЕТ, решений принимать не нужно.

## Что сломано (уже измерено контроллером, перепроверять не надо)

`tools/probes-sync-bench.sh`, `scenario_1`. Сценарий поднимает первого писателя
в фоне с подменённым `cp`; заглушка сообщает о входе файлом `ready` и ждёт
файла `release`. Ветка отказа сегодня такая:

```bash
  if ! wait_file "$ready"; then
    kill "$first_pid" 2>/dev/null; wait "$first_pid" 2>/dev/null
```

`bash` НЕ доставляет сигнал, пока исполняется его ПЕРЕДНИЙ ребёнок, а этот
ребёнок — заглушка, ждущая `release`, который создаётся только на удачном
пути. `kill` не убивает никого, голое `wait` встаёт навсегда. Вместе со
сценарием виснет весь свип: у пред-стадий конвейера часового нет. Замерено
2026-08-31 — простой 3 ч 32 мин. Вход в ветку случился потому, что бюджет
`wait_file` = 100 шагов по 0.05 с (5 секунд), а под нагрузкой первый писатель
до `cp` за 5 секунд не доходит.

## Скоуп записи (paths)

Трогать ТОЛЬКО:
- `tools/probes-sync-bench.sh`
- `README.md` (одна строка про счётчики стенда, см. §6)

Замеченное вне этих файлов — строкой в отчёт, не правкой.

## 1. Бюджеты — названными константами

Рядом с `EXPECTED_SCENARIOS` / `EXPECTED_MUTATIONS` (файл, строки 18-19)
добавить:

```bash
# Бюджеты ожиданий, в шагах по 0.05 с. Пять секунд мерили скорость МАШИНЫ, а
# не свойство замка: под свипом первый писатель до `cp` за них не доходит, и
# прибор объявлял отказ там, где дефекта нет.
WAIT_READY_STEPS=600      # 30 с -- вход первого писателя в cp
WAIT_DEATH_STEPS=200      # 10 с -- смерть писателя после освобождения
```

`wait_file` принимает бюджет вторым аргументом со значением по умолчанию:

```bash
wait_file() {   # <путь> [шагов по 0.05 с]
  local path="$1" left="${2:-$WAIT_READY_STEPS}"
```

Остальное тело `wait_file` НЕ менять.

## 2. Ограниченное ожидание смерти — новая функция

Сразу после `wait_file` добавить:

```bash
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
```

## 3. Одна реализация пляски двух писателей на оба случая

Копии кода в контроле рано или поздно разойдутся с боевой, и зелёный зуб будет
доказывать копию. Поэтому тело сценария 1 выносится в функцию, которой
пользуются И сценарий 1, И новый случай зависания.

Добавить функцию `two_writers` (место — прямо перед `scenario_1`):

```bash
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
# путь отказа обязан кончиться, а не зависнуть.
while [[ ! -e "$SYNC_BENCH_RELEASE" ]]; do sleep 0.05; done
exec /bin/cp "$@"
CP
  fi
  chmod +x "$stub/cp"
  first_log="$root/first.log"; second_log="$root/second.log"
  PATH="$stub:$PATH" SYNC_BENCH_READY="$ready" SYNC_BENCH_RELEASE="$release" \
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
```

Объявить рядом с `LAST_EVID` (строка ~29) глобальные:

```bash
TW_RC1=''; TW_RC2=''; TW_DIFF=''; TW_DIFF_RC=''; TW_REASON=''; TW_SECOND_LOG=''
```

## 4. scenario_1 переписывается через two_writers

Тело `scenario_1` целиком заменить на:

```bash
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
```

ВАЖНО: следы, по которым self_check узнаёт мутации 1 (`второй=0`), сохранены
дословно — строка `LAST_EVID` удачного пути имеет тот же вид, что была.

## 5. Новый случай зависания: режим стенда + сценарий 7 + мутация 7

### 5.1 mk_kit кладёт в игрушечный кит сам стенд

В `mk_kit`, после строки `cp "$KIT/scripts/probes-sync.sh" ...`, добавить:

```bash
  # Стенд копируется в игрушечный кит, потому что сценарий 7 меряет ЕГО путь
  # отказа: мутация правит копию, а сценарий исполняет её, а не работающий файл.
  mkdir -p "$dst/tools"
  cp "$BENCH" "$dst/tools/probes-sync-bench.sh"
```

### 5.2 Скрытый режим

В финальном `case "${1:-}"` добавить ветку ПЕРЕД веткой `*)`:

```bash
  --hang-case)
    # Служебный режим: исполняет пляску двух писателей в режиме silent и
    # печатает исход. Зовётся сценарием 7 из КОПИИ кита.
    if two_writers "$2" silent; then
      say "ХОД: дошли до удачного пути (в режиме silent это невозможно)"
      exit 1
    fi
    say "ХОД: $TW_REASON"
    exit 0 ;;
```

### 5.3 Сценарий 7

```bash
scenario_7() {   # путь отказа обязан КОНЧАТЬСЯ, а не виснуть
  local root start elapsed rc pid wd
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
  # Часовой убивает только названный процесс; заглушка -- отдельный процесс и
  # переживёт его, поэтому освобождение ставится и здесь, до сноса корня.
  : > "$root/release" 2>/dev/null || true
  LAST_EVID="rc=$rc секунд=$elapsed :: $(cat "$root/hang.log" 2>/dev/null)"
  if (( rc != 0 )) || (( elapsed >= 90 )); then
    LAST_EVID="ПУТЬ_ОТКАЗА_ЗАВИС rc=$rc секунд=$elapsed"
    rm -rf "$root"
    bad '7 путь отказа обязан кончиться отказом, а не зависнуть'
    return
  fi
  rm -rf "$root"
  ok '7 первый писатель не вошёл в cp: путь отказа кончился в бюджете'
}
```

### 5.4 Мутация 7

В `mutate` выбор жертвы становится зависимым от номера. Заменить строку
`file="$root/kit/scripts/probes-sync.sh"` на:

```bash
  # Жертва мутации 7 -- САМ СТЕНД в копии кита: она меряет его путь отказа.
  case "$n" in
    7) file="$root/kit/tools/probes-sync-bench.sh" ;;
    *) file="$root/kit/scripts/probes-sync.sh" ;;
  esac
```

В питоньем теле, перед `else:` с `unknown mutation`, добавить:

```python
elif number == 7:
    # Освобождение снимается из ветки отказа: заглушка снова ждёт файл,
    # которого не будет, и путь отказа виснет вместо того, чтобы кончиться.
    old, new = ('    : > "$release"\n    kill "$first_pid" 2>/dev/null\n',
                '    kill "$first_pid" 2>/dev/null  # mutation: release withheld\n')
```

### 5.5 Счётчики и таблицы

- `EXPECTED_SCENARIOS=7`, `EXPECTED_MUTATIONS=7`
- `MUT_SCENARIO=(x 1 2 3 4 5 6 7)`
- в `self_check` цикл `for n in 1 2 3 4 5 6 7`
- в `case "$n:$LAST_EVID"` self_check добавить арм ПЕРЕД `*)`:
  `7:*"ПУТЬ_ОТКАЗА_ЗАВИС"*) reddened=$((reddened + 1)); say '  ok     мутация 7 покраснила сценарий 7 своей причиной' ;;`
- в диспетчере `run_scenario` добавить вызов `scenario_7` тем же способом,
  каким там перечислены сценарии 1-6 (посмотри, как это сделано, и повтори
  форму дословно).

## 6. README

Найти строку таблицы про `tools/probes-sync-bench.sh` и в ней:
число сценариев 6 → 7, число мутаций 6 → 7. Добавить в конец описания стенда
одно предложение:

`Scenario 7 measures the bench's OWN refusal path: with a stub that never
signals its entry, the failure branch must END rather than hang — it releases
the stub BEFORE signalling, because bash delivers no signal while its foreground
child runs, and every wait carries a budget; mutation 7 withholds that release
and the scenario reddens by its watchdog.`

Числа в README читает гейт чисел; владельца менять не нужно, имя стенда уже
стоит рядом.

## Контракт исполнения

- НЕ коммить. Изменения оставить в рабочем дереве; коммитит контроллер после
  личной проверки диффа.
- Стоп-правило: неожиданное падение или расхождение с брифом → ОДНА честная
  попытка → отчёт BLOCKED с сырым выводом, без глубокой диагностики.
  Хеджированная диагностика в отчёте = задача уходит классом вверх.
- Право на отказ с доказательством: если пункт брифа уже выполнен или посылка
  ложна — приложи доказательство (grep/diff/вывод) и остановись. Придумывать
  дифф запрещено.
- Комментарии в коде — только констрейнты (граница, инвариант, «почему не
  иначе»). Нарратив правки — в отчёт, не в код. Комментарии из брифа
  переноси дословно: они и есть констрейнты.

## Гейты (все три обязательны, форма без пайпа)

```
bash -n tools/probes-sync-bench.sh; echo "SYNTAX=$?"
bash tools/probes-sync-bench.sh > /tmp/psb.log 2>&1; echo "SCEN=$?"; tail -3 /tmp/psb.log
bash tools/probes-sync-bench.sh --self-check > /tmp/psb-self.log 2>&1; echo "SELF=$?"; tail -3 /tmp/psb-self.log
```

Ожидается: `SYNTAX=0`; `SCEN=0` с итогом `сценариев=7 расхождений=0`;
`SELF=0` с итогом `мутаций=7 покраснели=7`.

НЕ подтверждай гейт формой `команда | tail -N; echo $?` — `$?` там код хвоста
пайпа, упавший прогон выглядит зелёным.

## Отчёт (коротко)

status, изменённые файлы, три строки гейтов дословно, счётчики ДО и ПОСЛЕ
(сценариев 6→7, мутаций 6→7), список мест, где пришлось отступить от брифа
(с причиной), и всё замеченное вне скоупа.

<!-- BRIEF COMPLETE -->

---

# ПОПРАВКА КОНТРОЛЛЕРА №1

Твой отказ принят как ВЕРНЫЙ, замер перепроверен контроллером лично. Ошибка в
брифе, не в работе: мутацию 7 я написал против СТАРОЙ формы ветки (`kill` +
голое `wait`), где снятие освобождения давало вечное зависание. После §2 ветка
несёт потолок `wait_death`, и снятие одного освобождения зависания больше не
даёт — ты это измерил (`MUT7_RC=0 ELAPSED=35s`), и это правда.

Оба твоих отступления РАТИФИЦИРОВАНЫ: чисел 6/6 в README действительно не было
(проверил строку 131 сам — посылка брифа ложна, твоя формулировка «7 сценариев
и 7 мутаций» верна по форме, число мутаций ниже меняется на 8); явная цепочка
`scenario_7` в ветке `''` необходима, иначе RUN≠EXPECTED_SCENARIOS.

## Адъюдикация: свойство несут ДВЕ ноги, и у каждой свой зуб

Свойство «путь отказа кончается» держат порядок (освобождение ДО сигнала) И
потолок ожидания. По отдельности ни одна нога через ЗАВИСАНИЕ не наблюдаема:
снимешь потолок — освобождение всё равно выпустит заглушку; снимешь
освобождение — потолок всё равно добьёт писателя. Это не дефект починки, а
защита в глубину. Значит зубов нужно два, и второй меряет ДРУГОЕ свойство.

Снятое освобождение оставляет заглушку СИРОТОЙ навсегда — процесс, ждущий
файла, которого не будет. В починенном коде утечки нет (освобождение стоит
всегда), поэтому проверка сироты — честный зуб именно этой ноги.

## П1. Заглушка режима silent записывает свой номер

В `two_writers`, тело silent-заглушки заменить на:

```bash
#!/usr/bin/env bash
# О входе НЕ сообщает: ready не появится никогда -- ровно тот вход, на котором
# путь отказа обязан кончиться, а не зависнуть. Свой номер пишет ДО ожидания:
# по нему сценарий 7 проверяет, что заглушка не осталась сиротой.
printf '%s\n' "$$" > "$SYNC_BENCH_STUBPID"
while [[ ! -e "$SYNC_BENCH_RELEASE" ]]; do sleep 0.05; done
exec /bin/cp "$@"
```

В строке запуска первого писателя добавить переменную (обе стороны запускаются
одной строкой; signal-заглушка её просто не читает):

```bash
  PATH="$stub:$PATH" SYNC_BENCH_READY="$ready" SYNC_BENCH_RELEASE="$release" \
    SYNC_BENCH_STUBPID="$root/stub.pid" \
    bash "$script" --to-home >"$first_log" 2>&1 &
```

## П2. scenario_7: сирота проверяется ДО собственного освобождения

Хвост `scenario_7` после `elapsed=...` заменить на:

```bash
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
```

Объявить `stub_pid` и `orphan` в `local` строке `scenario_7`.

## П3. Мутация 7 переписывается, добавляется мутация 8

Заменить питонью ветку `elif number == 7:` на две:

```python
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
```

Выбор жертвы: `7|8)` вместо `7)`.

## П4. Счётчики и таблицы

- `EXPECTED_MUTATIONS=8` (сценариев остаётся 7)
- `MUT_SCENARIO=(x 1 2 3 4 5 6 7 7)` — обе новые мутации краснят сценарий 7
- цикл self_check `for n in 1 2 3 4 5 6 7 8`
- армы в `case "$n:$LAST_EVID"`:
  - `7:*"ПУТЬ_ОТКАЗА_ЗАВИС"*) reddened=$((reddened + 1)); say '  ok     мутация 7 покраснила сценарий 7 своей причиной' ;;`
  - `8:*"СИРОТА_ЗАГЛУШКИ"*) reddened=$((reddened + 1)); say '  ok     мутация 8 покраснила сценарий 7 своей причиной' ;;`

## П5. README

В строке 131: «7 сценариев и 7 мутаций» → «7 сценариев и 8 мутаций». Последнее
предложение (про mutation 7) заменить на:

`Scenario 7 measures the bench's OWN refusal path: with a stub that never
signals its entry, the failure branch must END rather than hang — it releases
the stub BEFORE signalling, because bash delivers no signal while its foreground
child runs, and every wait carries a budget. Both legs are pinned separately:
mutation 7 reverts the whole apparatus and the scenario reddens by its
watchdog, while mutation 8 withholds only the release — no hang then, but the
stub is left an orphan, and the scenario reddens on the orphan check it runs
BEFORE its own cleanup release.`

## Гейты (те же три, форма без пайпа)

Ожидается: `SYNTAX=0`; `SCEN=0` с `сценариев=7 расхождений=0`;
`SELF=0` с `мутаций=8 покраснели=8`.

Контракт прежний: НЕ коммить, стоп-правило, право на отказ с доказательством.

<!-- BRIEF COMPLETE -->
