# #78 — отчёт: тесты форка tweakcc писали в живой дом

Дерево правки: `~/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-tweakcc`
(HEAD на момент работы `a377c40`, изменения НЕ закоммичены — коммитит
контроллер). Кит не трогался, кроме этого файла.

Живой `~/.tweakcc` за всю работу не пострадал: снимок всего дома снят до
первой команды, каждый прогон без подмен окружён md5-сторожем с побайтовым
откатом. Итоговая сверка верхнего уровня дома (md5 + mtime + размер каждого
файла) с этим снимком — совпадение полное, `config.json` тот же
`0ebc88bafa291b0c58459fe5e520b5d0`, mtime `1788676088`; каталоги
`system-prompts` (998) и `prompt-data-cache` (124) — прежней численности.

## 1. Виновник — поимённо

`src/tests/migration.test.ts`, блок `describe('userMessageDisplay migration')`,
5 тестов (строки 10–216 исходного файла).

Механика (прочитана, не выведена): тесты подменяют ТОЛЬКО чтение —
`vi.spyOn(fs, 'readFile')` — и зовут настоящий `readConfigFile()`
(`src/config.ts:243`). Тот нормализует прочитанное, видит `changed === true`
и зовёт `saveConfig()` (`src/config.ts:302`), а в нём — НЕподменённый
`fs.writeFile(CONFIG_FILE, …)` (`src/config.ts:306`). `CONFIG_FILE` собран из
`CONFIG_DIR`, вычисленного на импорте модуля (`src/config.ts:76`), то есть из
живого дома. В файл ложится содержимое мока: `ccVersion: '1.0.0'`,
`settings` из `DEFAULT_SETTINGS`, а `changesApplied` дополнительно сбивается в
`false` ветвью `hasUnappliedSystemPromptChanges(SYSTEM_PROMPTS_DIR)`, которая
читает НАСТОЯЩИЙ каталог промтов. Это ровно та порча, что описана в брифе.

Список подозреваемых из брифа закрыт измерением по одному файлу: писатель
один. Стенд — `scripts/find-live-home-writer.sh` (оставлен в дереве форка),
прогон 52 файлов на КОПИИ дома, живой дом только под сторожем:

```
FILE                                                 EXIT   COPY      LIVE
src/nativeInstallation.test.ts                       0      UNCHANGED UNCHANGED
…
src/tests/config.test.ts                             0      UNCHANGED UNCHANGED
src/tests/deepMergeWithDefaults.test.ts              0      UNCHANGED UNCHANGED
src/tests/migration.test.ts                          0      WRITTEN   UNCHANGED
src/tests/sandboxedScript.test.ts                    0      UNCHANGED UNCHANGED
…
src/tests/xdgConfigHome.test.ts                      0      UNCHANGED UNCHANGED
```
(полная таблица: 52 строки, `WRITTEN` ровно одна; `applyPlan.test.ts` лежит в
`src/tests/`, а не в `src/patches/`, как значилось в брифе — файл проверен,
чист.)

## 2. Разводящий опыт: HOME против TWEAKCC_CONFIG_DIR

Обе переменные держат дом, каждая САМА ПО СЕБЕ. Замерено на виновнике, на
коде ДО фикса.

Опыт A — только `HOME`, `TWEAKCC_CONFIG_DIR` не задан:
```
HOME=<копия>  npx vitest run src/tests/migration.test.ts
EXIT=0   копия: WRITTEN   живой дом: UNCHANGED
```
Причина: `getConfigDir()` падает в ветвь `path.join(os.homedir(), '.tweakcc')`
(`src/config.ts:41`), а `os.homedir()` на macOS читает `HOME`.

Опыт B — только `TWEAKCC_CONFIG_DIR`, `HOME` настоящий:
```
live before: 0ebc88bafa291b0c58459fe5e520b5d0
TWEAKCC_CONFIG_DIR=<копия>/.tweakcc npx vitest run src/tests/migration.test.ts
exit=0
live after : 0ebc88bafa291b0c58459fe5e520b5d0
copy after : c8e825d37848660cbb4cbd12c78bdaa1   (copy before: 0ebc88ba…)
LIVE UNCHANGED
 ✓ src/tests/migration.test.ts (9 tests) 175ms
```
Причина: ветвь явного override (`src/config.ts:37`) старше всех остальных.

Вывод: защищённость прогона контроллера обеспечивалась любой из двух
переменных по отдельности; выбор для фикса сделан в пользу
`TWEAKCC_CONFIG_DIR` — это опора продукта, а не подмена всего домашнего
каталога процесса (подмена `HOME` попутно ломает тесты поиска путей
установки, которые читают настоящий `~/.local/bin/claude`).

## 3. Фикс

Три слоя, все в форке:

1. **Пин дома на весь прогон** — `src/tests/setup/pinConfigHome.ts`,
   подключён как `setupFiles` в `vitest.config.ts`. Ставит
   `TWEAKCC_CONFIG_DIR` на одноразовый каталог (`mkdtemp`, свой на каждый
   файл теста) ДО импорта модулей теста — иначе поздно: `CONFIG_DIR`
   вычисляется один раз, на импорте `config.ts`. Механизм — существующий
   `TWEAKCC_CONFIG_DIR`, нового в порядок разрешения дома не добавлено.
   Стенду оставлена дверь `TWEAKCC_TEST_CONFIG_DIR` (куда целить пин), и она
   ОТКАЗЫВАЕТ, если цель разрешается внутрь дома в работе:
   ```
   Error: TWEAKCC_TEST_CONFIG_DIR points at a real tweakcc config home
   (/Users/maratkarimov/.tweakcc). Point it at a copy instead: the test suite
   never runs against a home in use.
   EXIT=1
   ```
2. **Источник записи у виновника** — `src/tests/migration.test.ts`: блок,
   подменявший только чтение, теперь подменяет и запись
   (`vi.spyOn(fs, 'writeFile')`, `fs.mkdir`). Пин один оставил бы тест,
   который реально пишет на диск, просто в другой каталог.
3. **Найденный по ходу корень, из-за которого опора не работала** —
   `src/config.ts`. См. раздел 5: без этой правки пин по
   `TWEAKCC_CONFIG_DIR` роняет 13 файлов на сборке.

Счётчики тестов:

| | Test Files | Tests |
|---|---|---|
| ДО (полный прогон без подмен, код до фикса) | `52 passed (52)` | `596 passed \| 5 skipped (601)` |
| ПОСЛЕ (полный прогон без подмен) | `53 passed (53)` | `598 passed \| 5 skipped (603)` |

Счёт вырос, и рост объяснён целиком: +1 файл и +2 теста — это новый пин
`src/tests/configHomeUnderCycle.test.ts` (раздел 5). Прежние 596 проходящих
проходят все, скипов по-прежнему 5. Гейт форка `npm run lint`
(`tsc --noEmit && eslint src`) — EXIT 0.

## 4. Зуб

Дом: `src/tests/setup/liveHomeGuard.ts`, подключён как `globalSetup` в
`vitest.config.ts`. Гоняется сам на каждом `npx vitest run` / `npm test`
форка — отдельного вызова со стороны кита не требует (гейтов кита, гоняющих
эту батарею, в дереве кита нет: `Catalyst-tweakcc` упоминается в
`claude-patch-all.sh` только как имя репозитория). Форма ровно из брифа:
снимок содержимого (md5) и mtime `~/.tweakcc/config.json` до прогона, сверка
после; расхождение — исключение в teardown, прогон отдаёт EXIT 1. Зуб только
докладывает и не чинит сам, но кладёт побайтовую копию рядом и называет её
путь.

**ДО фикса — красный (сырой вывод полного прогона на текущем тогда коде):**
```
⎯⎯⎯⎯⎯⎯⎯ Startup Error ⎯⎯⎯⎯⎯⎯⎯⎯
Error: The test run touched the live tweakcc config home: /Users/maratkarimov/.tweakcc/config.json
  before: md5=0ebc88bafa291b0c58459fe5e520b5d0 mtimeMs=1788676088860.3062
  after:  md5=5cb147222913c48007bae70adae15937 mtimeMs=1788715019785.5435
  byte-for-byte copy taken before the run: /var/folders/…/T/tweakcc-live-config-rescue.65691.json
Tests must reach their config home through TWEAKCC_CONFIG_DIR, which
src/tests/setup/pinConfigHome.ts pins to a throwaway directory.
    at Object.teardown (…/src/tests/setup/liveHomeGuard.ts:41:9)

 Test Files  52 passed (52)
      Tests  596 passed | 5 skipped (601)
EXIT=1
```
(живой файл после этого прогона восстановлен побайтово из снимка — md5 снова
`0ebc88ba…`, mtime `1788676088`.)

**ПОСЛЕ фикса — зелёный:**
```
FINAL EXIT=0
live before md5=0ebc88bafa291b0c58459fe5e520b5d0 mtime=1788676088
live after  md5=0ebc88bafa291b0c58459fe5e520b5d0 mtime=1788676088
 Test Files  53 passed (53)
      Tests  598 passed | 5 skipped (603)
```

**Зуб остался живым прибором (контроль на зелёном коде).** Одноразовый тест,
переписавший живой `config.json` его же байтами (содержимое то же, mtime
уехал), зуб поймал:
```
Error: The test run touched the live tweakcc config home: /Users/maratkarimov/.tweakcc/config.json
  before: md5=0ebc88bafa291b0c58459fe5e520b5d0 mtimeMs=1788676088860.3062
  after:  md5=0ebc88bafa291b0c58459fe5e520b5d0 mtimeMs=1788715322667.7534
CONTROL EXIT=1
```
Одноразовый тест удалён, mtime возвращён из снимка.

**Стенд тоже остался живым прибором.** После фикса он целит пин на копию
через `TWEAKCC_TEST_CONFIG_DIR`; одноразовый тест, воспроизводящий прежнее
поведение виновника, он видит, а починенного виновника — нет:
```
FILE                                                 EXIT   COPY      LIVE
src/tests/w78benchcontrol.test.ts                    0      WRITTEN   UNCHANGED
src/tests/migration.test.ts                          0      UNCHANGED UNCHANGED
```
Полный прогон стенда после фикса: 53 строки, все `0 UNCHANGED UNCHANGED`.

## 5. Находка по ходу: опора TWEAKCC_CONFIG_DIR была нерабочей

Пин по `TWEAKCC_CONFIG_DIR` на полном прогоне уронил 13 файлов на сборке и
8 тестов в `searchPaths.test.ts`, все с одной причиной:
```
Error: [vitest] There was an error when mocking a module. …
 ❯ src/patches/modelSelector.ts:3:1
Caused by: TypeError: (0 , expandTilde) is not a function
 ❯ getConfigDir src/config.ts:39:12
 ❯ src/config.ts:76:27
 ❯ src/patches/index.ts:5:1
```
Это цикл импортов: `utils.ts:8` тянет `./patches/modelSelector` →
`./patches/index:5` → `../config` → `config.ts:76` вычисляет `CONFIG_DIR` →
`getConfigDir()` дёргает `expandTilde` из `utils`, который в этот момент ещё
не доинициализирован. Ветвь `TWEAKCC_CONFIG_DIR` — единственная в
`getConfigDir()`, которая разыменовывала партнёра по циклу на импорте,
поэтому дефект и не показывался: живой дом резолвится без единого вызова
наружу. Это же объясняет 13 несобравшихся файлов в замере контроллера — их
давал не `HOME`, а сам `TWEAKCC_CONFIG_DIR`.

Правка (`src/config.ts`): резолвер дома сделан самодостаточным — раскрытие
тильды продублировано локально (константа-функция рядом, комментарий-констрейнт
объясняет, почему дубль намеренный), `debug()` в двух catch-ветвях зовётся
защищённо. Пин на это — `src/tests/configHomeUnderCycle.test.ts`, входит в
граф через `utils` первым импортом. До правки:
```
 FAIL  src/tests/configHomeUnderCycle.test.ts [ src/tests/configHomeUnderCycle.test.ts ]
TypeError: (0 , expandTilde) is not a function
 ❯ getConfigDir src/config.ts:39:12
 Test Files  1 failed (1)
EXIT=1
```
после правки — `2 passed`.

**Флаг по скоупу.** `src/config.ts` — код продукта, а раздел «Скоуп записи»
брифа перечисляет файлы тестов, их опоры и стенд. Правка сделана потому, что
без неё предписанный брифом механизм не работает вовсе (задача блокируется), и
держится в минимуме: поведение `getConfigDir()` для всех пяти ветвей прежнее,
`npm run lint` зелёный. Контроллеру решать, оставить её в этой волне или
вынести.

**Замечено, не тронуто.** Сам цикл `utils.ts → patches/modelSelector →
patches/index → config` остался: `utils.ts:8` импортирует `CUSTOM_MODELS`
ради одной строки `utils.ts:109`. Пока никто больше не разыменовывает
партнёра по циклу на импорте, он не кусается; вынос `CUSTOM_MODELS` в
листовой модуль — правка продукта вне предмета #78.

## 6. Изменённые файлы (форк, без коммита)

```
 M src/config.ts                          (+26/−4)  резолвер дома вне цикла
 M src/tests/migration.test.ts            (+9/−1)   виновник больше не пишет
 M vitest.config.ts                       (+5)      globalSetup + setupFiles
?? src/tests/setup/pinConfigHome.ts                 пин дома (фикс)
?? src/tests/setup/liveHomeGuard.ts                 зуб
?? src/tests/configHomeUnderCycle.test.ts           пин на цикл
?? scripts/find-live-home-writer.sh                 стенд поиска писателя
```

## Self-Check: PASSED

- Названные файлы существуют в дереве форка, отчёт — в дереве кита; коммитов
  не делалось (`git log -1` форка = `a377c40`).
- Счётчики в отчёте — вывод реально прогнанных команд, не пересказ:
  `Test Files 53 passed (53)`, `Tests 598 passed | 5 skipped (603)`, EXIT 0.
- Красных на финальном HEAD рабочего дерева нет: полный `npx vitest run`
  без подмен — 0, `npm run lint` — 0.
- Живой `~/.tweakcc` побайтово и по mtime совпадает со снимком, снятым до
  первой команды.
