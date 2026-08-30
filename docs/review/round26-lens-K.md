# Круг 26, линза K — границы настроек

Аудитор: свежий контекст, только чтение. HEAD `60534e28c32e8229ac8bca5a48c15f5a1d927f15` (как в брифе: `60534e2`). Дерево: незакоммичены только `docs/review/round26-brief-K.md` и `round26-brief-L.md`. Живой дом `~/.claude/probes/probes.toml` прочитан. Живой образ `~/.local/bin/claude` → `versions/2.1.251`; в нём строки `bad-setting:` (2), `attach_files`/`attach_total`/`records_keep`/`dispatch_chars`/`retry_context_chars` (по 4) — патч на месте. Конвейер `claude-patch-all.sh` не запускался, `~/.tweakcc` и живой образ не трогались, `target-warden` не трогался.

Линза: по каждой найденной ручке — кто читает, что на негодном значении, достижима ли ветка. Глубокий источник — код, не чужой отчёт. Где стоит «замерено» — исполнялось то же выражение в `python3`/`bash`/`bun`/`node`, не полный конвейер.

## Перепись (что реально открыто)

**probes.toml, ядро `tweakcc-patch.js` (`__num` / `__svc.num`):**
`max_tokens`, `timeout_ms`, `enforce`, `context_chars`, `retry_context_chars`, `dispatch_chars`, `fail_closed`, `attach_files`, `attach_chars`, `attach_total`, `records_keep`, `window_min`, `threshold`, `cooldown_min`, `live_kinds`, `live_threshold`, `live_recheck_ms`, `enabled`, `record`, `record_gzip`, `disabled_memo_ms`, `filter.*`, `url`, `raw_http`, `models[]` (`model`, `effort`, `context_chars`, `timeout_ms`, `max_tokens`), `body.json.max_tokens`.

**Переменные образа (судья/наблюдатель):**
`CLAUDE_JUDGE`, `CLAUDE_JUDGE_{PROMPT,MODEL,URL,TIMEOUT_MS,DEBUG}`, `CLAUDE_IDLE` и те же суффиксы, `CLAUDE_PROBES_DIR`.

**`claude-patch-all.sh`:**
`CLAUDE_PATCH_{LOCK,LOCK_HELD_BY,SIGN_ID,SKIP_BENCH,SKIP_MODELS,ALLOW_TWEAKCC_FAILURES,FLOOR_IMAGE,GATE_BUDGET}`, `CATALYST_TWEAKCC_{SHA,REPO,CACHE}`, `TWEAKCC_LOCAL`, `TWEAKCC_CONFIG_DIR`, `CLAUDE_PROBES_DIR`, `CLAUDE_CONFIG_DIR`.

**`tools/sweep.sh` и зонды:**
`SWEEP_LAST_N`, `SWEEP_STATE_DIR`, `SWEEP_LOCK_BUDGET`, `SWEEP_SKIP_{BUILD_PROBE,TOOLS_BENCH,CHECKS_TEETH}`, `SWEEP_KIT_DRAIN`, `SWEEP_KEEP_LIVE_TWEAKCC`, `CORPUS_DIR`, `CORPUS_LIST`, `KEEP_ROOT`.

**argparse:**
`judge/validate.py` `--repeat/--jobs/--limit/--timeout`; `judge/adjudicate.py` `--jobs/--limit/--timeout`; `judge/replay.py` `--limit/--timeout`; `judge/compact.py` `--older-than-hours`; `tools/checks-teeth.py` `--jobs`. `--attach-*` у `judge/*.py` нет (в брифе как место поиска; в дереве ручки вложений живут только в toml+ядре).

## Находки

### K-1 (высшая). `timeout_ms` больше 2^31−1 молча становится 1 мс, журнал называет огромное число

Кто читает: ядро, `tweakcc-patch.js:3206` (`__o.tmoEnv||__cfg.timeout_ms`, дефолт 8000, min 1); ступень лестницы `:3387` и `:3420` (`rung.timeout_ms`); env `CLAUDE_JUDGE_TIMEOUT_MS` / `CLAUDE_IDLE_TIMEOUT_MS`. `__num` верхней границы не имеет (`:2354–2360`). Дальше задержка идёт в `setTimeout`:

```
tweakcc-patch.js:3213
'__to=setTimeout(()=>{__mine=!0;__ac.abort()},__ms);'
```

При срабатывании журнал пишет запрошенное число, не применённое:

```
tweakcc-patch.js:3286
'__a.error=(__mine?"our cap "+__ms+"ms fired -> ":'
```

Конкретное значение: `timeout_ms = 2147483648` (и `4294967296`, `9999999999`, `1e20`). Замерено в `bun` (рантайм образа) и `node`: `setTimeout(fn, 2147483648)` даёт `TimeoutOverflowWarning: … Timeout duration was set to 1` и стреляет за 1–14 мс. `__num` это число принимает: оно конечное и ≥1, `bad-setting` нет.

Что ломается: каждая ступень лестницы обрывается почти сразу. При живых `enforce=true` и `fail_closed=true` это отмена каждого диспатча. Строка журнала при этом говорит «our cap 2147483648ms fired» — объявление называет не то число, которое сработало.

Ветка достижима: toml, env `CLAUDE_JUDGE_TIMEOUT_MS`, поле ступени. Живой toml держит 240000 (240 с, ниже потолка) — дыра не в поставке, в отсутствии потолка.

### K-2 (высшая). `enforce` и `fail_closed` истинны только как boolean `true`; `1` и `"true"` выключают гейт молча

```
tweakcc-patch.js:2852
'let __en=__o.sw==="enforce"||__cfg.enforce===!0||__cfgbad;'
tweakcc-patch.js:2853
'let __fcl=__cfgbad||__cfg.fail_closed===!0;'
```

Кто читает: только ядро (python-инструменты эти ключи не применяют). Bun TOML принимает чужой тип: замерено `Bun.TOML.parse` — `enforce = 1` → число 1, `fail_closed = "true"` → строка `"true"`. В JS `1 === true` и `"true" === true` — ложь.

Конкретные значения:
* `enforce = 1` (JSON-стиль) → `__en` ложно, если выключатель env не равен в точности `enforce` и файл разобран. Судья консультацию проводит, отмену не исполняет (`block_not_enforced`).
* `fail_closed = "true"` → `__fcl` ложно. Исчерпание лестницы — пропуск, не отмена.
* Вместе: гейт выглядит включённым в toml и выключен по делу.

Сломанный разбор файла наоборот считает оба ключа включёнными (`__cfgbad`). Чужой тип разобранного файла — дыра, которую этот контур как раз чинил для «не разобралось».

### K-3 (высшая). `CLAUDE_JUDGE=0` (и `false`/`off`/`1`) включает пробу, а не выключает

```
tweakcc-patch.js:3512
'if(process.env.CLAUDE_JUDGE&&($2.name==="Agent"||$2.name==="Task")'
```

Любая непустая строка в JS истинна. Замерено: `"0"`, `"false"`, `"off"`, `"1"` → `probe_on=true`. `sw==="enforce"` истинно только для литерала `enforce`; при `CLAUDE_JUDGE=0` enforce берётся из toml. Живой `~/.claude/probes/probes.toml` держит `enforce = true` — проба не просто жива, она ещё и отменяет.

Конкретное значение: `CLAUDE_JUDGE=0`. Чтобы выключить, переменную нужно снять или поставить в пустую строку. Симметрично `CLAUDE_IDLE` (`tweakcc-patch.js:3562`).

Достижимо: обычная env-ручка «0 = выкл», которой в этом месте нет.

### K-4 (высшая). `SWEEP_LAST_N` с ведущими нулями — восьмеричная; `08` даёт зелёный прогон нуля версий

```
tools/sweep.sh:543–556
  __n="${SWEEP_LAST_N:-$SWEEP_LAST_N_DEFAULT}"
  case "$__n" in ''|*[!0-9]*)
    echo "SWEEP ОТКАЗ: SWEEP_LAST_N='$__n' -- не число" >&2; exit 2 ;;
  esac
  if (( __n == 0 )) || (( __n >= ${#ALL[@]} )); then
    SRC=("${ALL[@]}")
    ...
    SRC=("${__sorted[@]: -__n}")
```

`case` принимает любую строку из цифр, включая ведущие нули. Арифметика bash — восьмеричная. `set -u` (шапка `:70`), `set -e` нет: ошибка «value too great for base» не останавливает прогон.

Замерено под `set -u` на массиве из 10 элементов:

* `SWEEP_LAST_N=08` (и `0008`): `(( 08 == 0 ))` падает, ветка «весь корпус» не берётся, `${arr[@]: -08}` падает, `SRC` длины 0. Дальше цикл по версиям пуст, `RED=0`, хвост:

```
tools/sweep.sh:1143
line="SWEEP DONE (дерево $SWEPT_STATE): все ${#SRC[@]} версий измерены, красных нет"
```

  Итог: `SWEEP DONE: все 0 версий измерены, красных нет`, код 0. Пустой результат неотличим от успеха.

* `SWEEP_LAST_N=0010` (и `010`): восьмеричная 8, меряются 8 последних версий, не 10. Объявление несёт строку `0010`.

Рядом тот же кит уже умеет иначе: `validated_nonnegative_integer` в `claude-patch-all.sh:5238` считает `$((10#$digits))` и отвергает переполнение. На `SWEEP_LAST_N` это не перенесено.

`SWEEP_LAST_N=abc` / `-1` / `1.5` / пусто — отказ кодом 2, названо. Ноль (без ведущих нулей) — весь корпус, как написано.

### K-5 (высшая). `--limit=-N` — отрицательный срез: записи пропадают, пустой набор прикидывается «нечего мерить»

Три читателя, одна форма:

```
judge/validate.py:107
    return files[-limit:] if limit else files
judge/adjudicate.py:61
    return files[-limit:] if limit else files
judge/replay.py:236–237
    if args.limit:
        files = files[-args.limit:]
```

`type=int` принимает отрицательное. `validate.py:706–713` отвергает `--repeat<1` и `--jobs<1` (код 2) и не смотрит на `--limit`.

Замерено на пяти файлах `r1..r5.json` через `record_files`:

| `--limit` | результат |
|-----------|-----------|
| 0 | все пять (0 = «без потолка») |
| 2 | `r4, r5` |
| −1 | `r2, r3, r4, r5` (первая выпала) |
| −4 | `r5` |
| −5 | `[]` |
| −6 | `[]` |

Конкретное значение: `--limit=-1` молча выкидывает самую старую запись и гоняет остальные; `--limit=-5` на пяти файлах даёт пустой список → `validate.py:594–597` / `adjudicate.py:258–262` код 5 «записи не найдены». Записи на диске есть; причина названа неверно. Пустота неотличима от пустого каталога.

### K-6 (высокая). `context_chars`: двое читают одну ручку по-разному; 0…59 в ядре молча становятся 60

Ядро:

```
tweakcc-patch.js:2987
'let __max=__num("context_chars",__cfg.context_chars,60000,0);'
tweakcc-patch.js:2885
'let __b=Math.max(60,__n),__pb=Math.floor(__b*0.35),__sb=Math.floor(__b*0.3);'
```

`__num` с min=0 принимает 0 и 59 без `bad-setting`. `__cut` поднимает бюджет до 60 JSON-знаков всей ленты (с двух концов, с пинами user/compaction).

Python, только `--project-layer recompose`:

```
judge/validate.py:205–212
    limit = int(context_chars)
    if limit < 0:
        raise ValueError('context_chars не может быть отрицательным')
    ... content=str(...)[-limit:]
```

Замерено: `s[-0:]` — вся строка (в Python `-0 == 0`); `s[-5:]` — хвост из пяти знаков одного user-сообщения.

Конкретные значения:
* `context_chars = 0`: ядро режет к 60; python не режет вовсе.
* `context_chars = 59`: ядро 60; python — последние 59 знаков каждого user-сообщения.
* даже штатные 60000: ядро считает JSON-длину всей ленты; python — текст хвоста user-ролей. Одна ручка, два смысла.

На пути по умолчанию (`project_layer=record`) python ручку не применяет — реплика идёт как записана. Расхождение живое на `recompose`.

### K-7 (высокая). `compact.py --older-than-hours -1` и `nan` сжимают всё живое

```
judge/compact.py:38
    p.add_argument('--older-than-hours', type=float, default=24)
judge/compact.py:44
    cutoff = time.time() - a.older_than_hours * 3600
```

Нет проверки знака, NaN, inf. launchd-шаблон (`judge/com.transmutelabs.judge-compact.plist:11–12`) передаёт `24`; ручка достижима с командной строки.

Замерено `--dry-run` на двух свежих `rec.json`:

* `--older-than-hours -1` → cutoff в будущем → «сжал бы» оба.
* `--older-than-hours nan` → `mtime > nan` всегда ложно → оба.
* `--older-than-hours 0` → cutoff≈сейчас → оба (буквально «старше нуля часов»; спорно как дефект, см. адъюдикацию).
* `--older-than-hours inf` → ничего не сжимает.
* `--older-than-hours 24` → оба пропущены (свежие).

Конкретные значения: `-1` и `nan`. Без `--dry-run` это gzip+unlink всех записей окна, включая сегодняшние. Код выхода 0, счётчик «сжато: N» выглядит как штатный проход.

### K-8 (высокая). `max_tokens=0` на живом шаблоне — не «негодное», а «нет ручки»: остаётся 1200 из `body.json`

```
tweakcc-patch.js:3190–3191
'let __mt=__e.max_tokens||__cfg.max_tokens;'
'if(__mt)__obj.max_tokens=__num("max_tokens",__mt,__obj.max_tokens??__mtd,1);'
```

`0` в JS ложно: `__num` (min 1) не вызывается, `bad-setting` нет. Живой `~/.claude/probes/judge/body.json:3` (и копия в ките) держит `"max_tokens": 1200`. Комментарий в том же файле ядра (`:3147–3149`) называет 1200 числом, которое однажды обрезало отмену в тишину; пол ядра без шаблона — 8000 (`:3155`).

Конкретное значение: `max_tokens = 0` при наличии `body.json` → в провайдера уходит 1200, журнал молчит. Тот же 0 без шаблона (стенд `budget-negative`) идёт в `__num` и даёт 8000 с `bad-setting`. Два разных ответа на одно значение.

`max_tokens = -5` на живом шаблоне *доходит* до `__num` (число истинно) и подставляет дефолт `__obj.max_tokens??8000` = **1200 из шаблона**, не 8000. Стенд без `body.json` этого не ловит.

Python `compose_body` (`validate.py:251–252`) на recompose пишет `max_tokens` как есть, без `__num`: `-5` и `0` уедут в API.

### K-9 (высокая). `__num` не проверяет тип: boolean `true` становится валидной единицей

```
tweakcc-patch.js:2354–2360
'__num=(__k,__v,__d,__min,__q)=>{if(__v===void 0||__v===null||__v==="")return __d;'
  'let __x=Number(__v);'
  'if(!Number.isFinite(__x)||__x<__min){ ... return __d}'
  'return __x}'
```

`Number(true)===1`, `1>=min` для `timeout_ms` (min 1) и `max_tokens` (min 1) — «ok», без `bad-setting`. Bun TOML `timeout_ms = true` разбирается как boolean.

Замерено тем же `__num` в node:
* `timeout_ms=true` → used 1, why ok → дедлайн 1 мс (плюс K-1, если бы число было огромным; здесь оно «законная» единица).
* `max_tokens=true` → 1 токен вывода.
* `context_chars=false` → 0 (min 0) → дальше пол 60 из K-6.
* `timeout_ms=false` → 0 < 1 → дефолт 8000, *есть* `bad-setting`.

Конкретное значение: `timeout_ms = true` в toml. Ветка достижима: TOML это принимает, ядро не отвергает.

### K-10 (средняя). Три несовместимых «истинности» env в одном ките

Замерено:

| ручка | условие | `=0` | `=true` | `=1` |
|---|---|---|---|---|
| `CLAUDE_JUDGE` | непустая строка (`tweakcc-patch.js:3512`) | **вкл** | вкл | вкл |
| `CLAUDE_PATCH_SKIP_MODELS` | `== "1"` (`claude-patch-all.sh:5731`) | не скип | **не скип** | скип |
| `SWEEP_SKIP_BUILD_PROBE` | `-n` (`tools/sweep.sh:692`) | **скип** | скип | скип |
| `KEEP_ROOT` | `-n` (`tools/lock-probe.sh:81–82`) | **оставить корень** | оставить | оставить |

Конкретные значения, которые расходятся с ожиданием «как соседняя ручка»:
* `CLAUDE_PATCH_SKIP_MODELS=true` — синхрон цен **идёт** (не скип).
* `SWEEP_SKIP_BUILD_PROBE=0` — зонд **пропущен**, и это объявлено строкой с `=0`.
* `KEEP_ROOT=0` — рабочий корень **не** удаляется.

Не молчание в строгом смысле (скип-ветки sweep объявляют себя), но одна семья ручек, три языка, и `SKIP_MODELS=true` меняет измеряемое (свежесть цен) без объявления пропуска.

### K-11 (средняя). Дырявый regex в `filter.classes_judge` — судья никого не судит

```
tweakcc-patch.js:2758
'__mt=(__l,__s)=>Array.isArray(__l)&&__l.length>0&&__l.some((__r)=>{try{return new RegExp(__r).test(__s)}catch{return !1}});'
```

Негодный образец ловится и становится «не совпало». Если задан непустой `classes_judge`/`agents_judge` и ни один образец не матчится — `by=not_in_judge_list` / `no_class_marker`, `__ask=false`, консультации нет, диспатч идёт.

Конкретное значение: `filter.classes_judge = ["1e("]` (незакрытая группа). Журнал пишет `filtered`, не `skip` из-за поломки. Снаружи — судья «работает», по делу — все вызовы мимо. В живом toml фильтра нет; ветка жива, как только ключ появится.

### K-12 (средняя). `live_kinds = []` отключает live-work, пустой массив не дефолт

```
tweakcc-patch.js:3592
'__lk=__c.live_kinds||["local_agent","remote_agent","in_process_teammate"],'
```

`[]` в JS истинно — дефолт не подставляется. `__lk.includes(type)` всегда ложно, `__lv.length===0`, порог live-work не берётся. Наблюдатель теряет молчание «флот занят по реестру» и идёт в окно/метки.

Конкретное значение: `live_kinds = []`. Отсутствующий ключ — дефолт трёх родов; пустой массив — другой смысл. Не-массив (число) бросит `.includes` в `gate-failed:…`.

### K-13 (средняя). `validate.py --timeout` — секунды, яд — 0/−1/nan; соседний toml в миллисекундах

```
judge/validate.py:666
    run.add_argument('--timeout', type=float, default=180)
```

После разбора нет проверки (в отличие от `--jobs`/`--repeat`). Замерено разбором реального парсера: `0`, `-1`, `nan`, `inf` принимаются.

Дальше `channel.py`:
* pool: `subprocess.run(..., timeout=timeout)` — замерено `timeout=0` и `timeout=-1`: сразу `TimeoutExpired` («таймаут через 0 с» / «через -1 с»).
* http: `urllib.request.urlopen(..., timeout=timeout)` — `0` → `URLError: [Errno 36] Operation now in progress`; `-1` → `ValueError: Timeout value out of range`; `nan` → `ValueError: Invalid value NaN`.

Конкретные значения: `--timeout 0` и `--timeout -1`. Все прогоны становятся ERROR; сводка выглядит как мёртвый канал, аргумент не отвергнут. Копирование `timeout_ms = 240000` из toml в `--timeout 240000` — это 240000 **секунд** (~67 ч), не 240 с. Единицы разные, имена рядом. Поведение `inf` на живом сокете не мерил.

### K-14 (низкая). `checks-teeth.py --jobs` ≤0 молча становится 1

```
tools/checks-teeth.py:351
        with ProcessPoolExecutor(max_workers=max(1, opts.jobs)) as pool:
```

Соседи (`validate`/`adjudicate`) на `--jobs<1` отдают код 2. Здесь `type=int` принимает 0 и −1, `max(1, x)` поднимает до 1, объявления нет. Замерено: `max(1,0)=1`, `max(1,-1)=1`. На вердикт мутаций не влияет (всё равно по одной), меняется только заявленный параллелизм. `ThreadPoolExecutor(0)` у соседей без clamp бросил бы `ValueError` — у adjudicate это не доходит, его режут раньше.

## Произведение вложений (запрос брифа)

Три потолка: `attach_files` / `attach_chars` / `attach_total`. Ядро:

```
tweakcc-patch.js:3042–3046
'let __atn=__num("attach_files",__cfg.attach_files,0,0);'
'let __atc=__num("attach_chars",__cfg.attach_chars,40000,0);'
'let __atb=__num("attach_total",__cfg.attach_total,90000,0);'
'if(__atn>0&&__atc>0&&__atb>0){...'
```

Связь **не рвётся в сторону «безлимит»**:
* любой из трёх = 0 → блок выключен целиком. Стенд `attach-total-zero-is-off` (`tools/probe-bench.js:906–912`) это пинит. 0 здесь ключ «выкл», не «нет потолка».
* отсутствует `attach_files` → дефолт ядра 0 → выкл (наблюдатель флота без путей).
* отсутствует `attach_total` → дефолт 90000, вложения живут.
* отсутствует `attach_chars` → дефолт ядра **40000**, не 30000 из toml. Произведение 3×40000=120000 при `attach_total=90000` упрётся в суммарный. Расхождение дефолтов — только при выкинутом ключе; в живом toml ключ стоит.

Код не проверяет `attach_total == attach_files * attach_chars`. Связь — соглашение поставленных чисел и AND>0, не инвариант. Python-инструменты вложений не читают (нет `--attach-*`).

## Что проверено и чисто (запрос + место)

Отрицательные утверждения только с местом и запросом.

* `records_keep=0` — отказ, дефолт 500, журнал `bad-setting`. `tweakcc-patch.js:2745` min 1; стенд `tools/probe-bench.js:823–826`. Запрос: чтение `__num("records_keep"` и сценария `records-keep-zero-refused`.
* `max_tokens=-5` без шаблона — отказ, 8000, журнал. Стенд `budget-negative` (`probe-bench.js:830–833`). На **живом** шаблоне дефолт другой — это K-8, не чистое.
* `window_min=0` / `threshold=0` / `threshold="abc"` — min 1, дефолт, журнал. Комментарий ядра `:2340–2349` и сценарии `watch-threshold-*` в `probe-bench.js`. Запрос: `__svc.num("threshold"` `:3589`.
* `retry_context_chars=0` — выключает спасательную ступень, так и задумано (`tweakcc-patch.js:3397–3404`). Запрос: `__rcc>0`.
* `SWEEP_LAST_N` не-цифры — код 2, названо (`sweep.sh:544–545`). Запрос: `case ... *[!0-9]*`.
* `CLAUDE_PATCH_GATE_BUDGET` не целое / больше 2^63−1 — FATAL, `claude-patch-all.sh:5216–5238`. Замерено извлечённой функцией: `abc`, `-1`, `1.5`, `9223372036854775808` → rc=2. `0005` → 5 (десятичное). `0` принимается — см. адъюдикацию.
* `--jobs<1` / `--repeat<1` у `validate.py:706–713` и `--jobs<1` у `adjudicate.py:251–255` — код 2, замерено на живом образе (`--jobs 0` → «должен быть не меньше 1», exit 2).
* `CATALYST_TWEAKCC_SHA` пустая — подставляется пин `a89c9dae…` (`claude-patch-all.sh:2227`). Запрос: `${CATALYST_TWEAKCC_SHA:-a89c9dae…}`.
* `TWEAKCC_LOCAL=0` — `-n` истинно, `-f 0` ложно, `ERROR: … does not exist`, exit 1 (`:2242–2243`).
* `image-check.py` / `corpus-list.py` — не числовые ручки; лишняя арность код 2 (шапки файлов). Не гонял на мусорных файлах в этом круге.

`dispatch_chars=0`: `__num` min 0 принимает; `__disp` пуст, но ярлык `__lbl` объявляет «подрезан: показано 0 из N» (`tweakcc-patch.js:3006–3012, 3089–3090`). Пустота отличима от целого диспатча. См. адъюдикацию.

## Запросы на адъюдикацию

1. **`attach_total=0` / `attach_files=0` = выкл, не безлимит.** Запинено стендом, комментарий ядра это говорит. Я принял как допустимое. Искал, не рвётся ли произведение в «без потолка» — нет.
2. **`context_chars` пол 60** внутри `__cut` — заплатка против расхождения маркера и бюджета (`tweakcc-patch.js:2968–2973`). Я всё равно вынес K-6, потому что `__num` принимает 0…59 без журнала, и python на тех же числах делает другое. Если пол — часть контракта, его надо либо журналировать, либо поднять min до 60.
3. **`--older-than-hours 0`:** буквально «старше нуля часов» = всё уже записанное. Не вынес отдельной находкой; `-1` и `nan` вынес.
4. **`GATE_BUDGET=0`:** валидатор принимает (`rc=0 out=0`). Цикл `while (( i < GATE_BUDGET ))` (`claude-patch-all.sh:5404`) не входит ни разу, гейт всегда FATAL «within 0s». Отказ назван, пустота не прикидывается успехом. Не находка.
5. **`dispatch_chars=0`:** пустой диспатч с объявлением усечения. Не находка по правилу «пустота должна быть отличима».
6. **`timeout_ms` отсутствует** → молча 8000 мс (`__num` первая строка). Поставка 240000. 8 с комментарии ядра сами называют тесными. Не вынес: это штатный дефолт санитайзера на «нет ключа», не на негодное значение.
7. **Дефолт `attach_chars` 40000 в ядре vs 30000 в toml** — только если ключ выкинуть. При живом toml не проявляется. Не находка.
8. **`validate.py` не читает `timeout_ms`/`attach_*` из toml** на пути `record`. Это реплика записанного запроса, не второй судья. Принял. Расхождение начинается на `recompose` (K-6, хвост K-8).
9. **`SWEEP_KIT_DRAIN=abc`/`-5`/`1.5`:** арифметика даёт «не >0», один проход проверки жильцов, снимок может снестись. Похоже на уже чиненный нулевой бюджет (`sweep.sh:157–159`). Не углублял.
10. **`effort` мусор / разный дефолт** (`high` в python `configured_models`, `low` в `body.json`, дырка в fallback-теле ядра). Не мерил ответ провайдера. Не находка без замера канала.

## Что не мерил

* Не запускал `claude-patch-all.sh`, свип, живую консультацию судьи, не ставил мусор в боевой `probes.toml`.
* Не подставлял `timeout_ms=2147483648` в живой процесс — замер `setTimeout` в bun/node + чтение того, что ядро передаёт в `setTimeout`.
* `CLAUDE_JUDGE=0` — истинность строки в JS + чтение `if(process.env.CLAUDE_JUDGE`; сессию не поднимал.
* `--timeout inf` на живом HTTP не гонял.
* `tools/costs-bench.py`, `docnum-bench.py`, `listener.py` — не числовые границы поставки (listener: порт зашит 9317).
* `scripts/probes-sync.sh` в этом круге не читал (линза — границы значений, не замок раскатки; замок чинили в круге 25).

## Сводка

Находок: **5 высших, 4 высоких, 4 средних, 1 низкая** (14). Самая важная — K-1: огромный `timeout_ms` проходит `__num`, `setTimeout` сжимает его в 1 мс, журнал врёт, что сработал запрошенный потолок; при `fail_closed` это отмена каждого диспатча.
