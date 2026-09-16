# wave165: сдвиг пина распаковщика 970fc30 → 59fd2d4 и перезамер состава слоя на linux

BLOCKED (own diff green; unexpected red in tools/bun-drift.sh, tools/reap-heavy.sh, tools/tree-run.sh)
Коммитов нет.

## Машины

### Мак (дом кита, задача A)

```
uname -a: Darwin mmm4p.local 25.6.0 Darwin Kernel Version 25.6.0: Fri Jul 31 19:17:26 PDT 2026; root:xnu-12377.161.14~5/RELEASE_ARM64_T6041 arm64
date:     Wed Sep 16 13:55:12 MSK 2026
дом кита: /Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch
```

### usbox (задача B)

```
uname -a: Linux ds7992137 6.12.0-211.51.1.el10_2.x86_64 #1 SMP PREEMPT_DYNAMIC Mon Sep  7 15:43:02 EDT 2026 x86_64 GNU/Linux
date:     Wed Sep 16 10:55:53 AM UTC 2026
HOME:     /Users/maratkarimov  (подтверждено ssh-выводом ls; это Linux, не Darwin)
```

## Задача A — правка пина в ките (мак)

### Счёт вхождений ДО правки

Команда: `grep -o -F <SHA> claude-patch-all.sh | wc -l`

- старый `970fc30e03605d47cb873d0fd595a6623210d579`: **2**
- новый `59fd2d46d04b04e90d0cd1ffedf418d7ee6f9030`: **0**

Положительный контроль (имя переменной живёт в файле): `grep -n -F CATALYST_TWEAKCC_SHA` нашёл строки 635, 636, 645, 2294, 2517, 2529, 4374, 4379, 4380, 4396, 4398, 4406, 4407, 4423.

Строки со старым SHA:

- `:4374` `CATALYST_TWEAKCC_SHA="${CATALYST_TWEAKCC_SHA:-970fc30e03605d47cb873d0fd595a6623210d579}"`
- `:4379` `&& "$CATALYST_TWEAKCC_SHA" == "970fc30e03605d47cb873d0fd595a6623210d579" ]] \`

Правка: оба вхождения `970fc30e03605d47cb873d0fd595a6623210d579` заменены на `59fd2d46d04b04e90d0cd1ffedf418d7ee6f9030` в `claude-patch-all.sh` (ровно две строки).

### Счёт вхождений ПОСЛЕ правки

Команда та же: `grep -o -F <SHA> claude-patch-all.sh | wc -l`

- старый `970fc30e03605d47cb873d0fd595a6623210d579`: **0**
- новый `59fd2d46d04b04e90d0cd1ffedf418d7ee6f9030`: **2**

Строки с новым SHA:

- `:4374` `CATALYST_TWEAKCC_SHA="${CATALYST_TWEAKCC_SHA:-59fd2d46d04b04e90d0cd1ffedf418d7ee6f9030}"`
- `:4379` `&& "$CATALYST_TWEAKCC_SHA" == "59fd2d46d04b04e90d0cd1ffedf418d7ee6f9030" ]] \`

`git diff` по этим двум строкам — только замена SHA, больше ничего в этих хунках. Коммита нет.

HEAD кита на момент архива: `b5e68e67f56824e5ffe96d34642aa1654b0f5bb0`. Размер `git archive --format=tar HEAD`: 5355520 байт.

## Задача B — перезамер на usbox

Архив HEAD + только правка пина (рабочее дерево мака несёт чужую незакоммиченную волну — в замер она не едет).

### Образ

`sha256sum ~/.local/share/claude/versions/2.1.273.orig` на usbox:

```
6c752e2cc7c110c9df15f26d8d134d438c5ae95dbd610efc1a308bf7f9c5f6c1  /Users/maratkarimov/.local/share/claude/versions/2.1.273.orig
```

Совпало с объявленным `6c752e2cc7c110c9df15f26d8d134d438c5ae95dbd610efc1a308bf7f9c5f6c1`. Живых `claude-patch-all` / `tweakcc` на usbox в момент старта не было.

### Доставка кита

- `git archive --format=tar HEAD` (HEAD = `b5e68e67f56824e5ffe96d34642aa1654b0f5bb0`) через ssh в `$HOME/ccpatch/w165pin`
- EXTRACT_OK, `claude-patch-all.sh` 682002 байт, режим `-rwxr-xr-x`
- правка пина в копии: BEFORE old=2 new=0; python count old=2; AFTER old=0 new=2
- строки копии те же: `:4374` и `:4379` несут `59fd2d46d04b04e90d0cd1ffedf418d7ee6f9030`

Копия образа: `cp -p` в `$HOME/ccpatch/w165pin/target-2.1.273`, sha256 копии тот же `6c752e2cc7c110c9df15f26d8d134d438c5ae95dbd610efc1a308bf7f9c5f6c1`.

### Прогон 1 (неожиданное падение)

Полная команда:

```
cd /Users/maratkarimov/ccpatch/w165pin
./claude-patch-all.sh --target /Users/maratkarimov/ccpatch/w165pin/target-2.1.273 --expect-sha 6c752e2cc7c110c9df15f26d8d134d438c5ae95dbd610efc1a308bf7f9c5f6c1
```

Обёртка: `nohup ./run-wave.sh` пишет stdout+stderr в `run.log`, код в `run.rc`. PID обёртки 3117039.

`run.rc`: `1`

Сырой `run.log` целиком:

```
Обязательные инструменты: codesign НЕ требуется -- хозяин linux, подписать можно только на своей ОС
Target binary: /Users/maratkarimov/ccpatch/w165pin/target-2.1.273
Source digest: 6c752e2cc7c110c9df15f26d8d134d438c5ae95dbd610efc1a308bf7f9c5f6c1  /Users/maratkarimov/ccpatch/w165pin/target-2.1.273
==> Разбор вклеиваемого кода
ВКЛЕИВАЕМЫЙ КОД РАЗБИРАЕТСЯ; core=28846, judgeCall=4706, formCall=11721, watchCall=4338, всего 49811
ВСЕ ИМЕНА ВО ВКЛЕИВАЕМОМ КОДЕ РАЗРЕШАЮТСЯ
РАМКА ОДИНАКОВА НА ВСЕХ ТРЁХ ПУТЯХ
==> Разбор блока проверок
БЛОК ПРОВЕРОК РАЗБИРАЕТСЯ (3148 строк)
РАЗОБРАНО heredoc'ов конвейера 7; .sh-файлов 20 с heredoc'ами 45; файлов .py 25
==> Формы оболочки
ФОРМЫ ОБОЛОЧКИ, КОТОРЫЕ МОЛЧАТ:
  tools/bun-drift.sh: EXIT-трап без часового завершения -- обрыв на ошибке подстановки вернёт 0
  tools/reap-heavy.sh: EXIT-трап без часового завершения -- обрыв на ошибке подстановки вернёт 0
  tools/tree-run.sh: EXIT-трап без часового завершения -- обрыв на ошибке подстановки вернёт 0
ГЕЙТ ИМЁН ПЕРЕМЕННЫХ УПАЛ
EXIT=1
```

Слой tweakcc не вызывался. Копия образа после прогона 1 всё ещё `6c752e2cc7c110c9df15f26d8d134d438c5ae95dbd610efc1a308bf7f9c5f6c1`.

Файлы из находки гейта в скоупе записи этой задачи не лежат. `git status --short` дома кита на маке (не правка): ` M tools/bun-drift.sh`, ` M tools/tree-run.sh`; `tools/reap-heavy.sh` без метки.

### Прогон 2 (честный повтор той же команды)

Команда та же. Старый вывод сохранён в `run.log.1` / `run.rc.1`. PID обёртки 3130176. `date` usbox после повтора: `Wed Sep 16 11:01:09 AM UTC 2026`.

`run.rc`: `1`

Сырой `run.log` целиком (байт-в-байт тот же отказ):

```
Обязательные инструменты: codesign НЕ требуется -- хозяин linux, подписать можно только на своей ОС
Target binary: /Users/maratkarimov/ccpatch/w165pin/target-2.1.273
Source digest: 6c752e2cc7c110c9df15f26d8d134d438c5ae95dbd610efc1a308bf7f9c5f6c1  /Users/maratkarimov/ccpatch/w165pin/target-2.1.273
==> Разбор вклеиваемого кода
ВКЛЕИВАЕМЫЙ КОД РАЗБИРАЕТСЯ; core=28846, judgeCall=4706, formCall=11721, watchCall=4338, всего 49811
ВСЕ ИМЕНА ВО ВКЛЕИВАЕМОМ КОДЕ РАЗРЕШАЮТСЯ
РАМКА ОДИНАКОВА НА ВСЕХ ТРЁХ ПУТЯХ
==> Разбор блока проверок
БЛОК ПРОВЕРОК РАЗБИРАЕТСЯ (3148 строк)
РАЗОБРАНО heredoc'ов конвейера 7; .sh-файлов 20 с heredoc'ами 45; файлов .py 25
==> Формы оболочки
ФОРМЫ ОБОЛОЧКИ, КОТОРЫЕ МОЛЧАТ:
  tools/bun-drift.sh: EXIT-трап без часового завершения -- обрыв на ошибке подстановки вернёт 0
  tools/reap-heavy.sh: EXIT-трап без часового завершения -- обрыв на ошибке подстановки вернёт 0
  tools/tree-run.sh: EXIT-трап без часового завершения -- обрыв на ошибке подстановки вернёт 0
ГЕЙТ ИМЁН ПЕРЕМЕННЫХ УПАЛ
EXIT=1
```

EXIT без пайпа: содержимое `run.rc` = `1` (оба прогона). Обёртка дописала `EXIT=1` в лог отдельной командой после скрипта.

Слой tweakcc снова не вызывался. Строки «попыток по слою кода 49, из них легло 14», посекционный состав Always/Misc/Features, число накладок промтов — не сняты: конвейер остановился на гейте форм оболочки.

## Сверка с объявлениями

Не выполнялась: измеренного состава слоя нет. `tools/tweakcc-expected-inert.txt` и `tools/tweakcc-expected-applied.txt` **не переписывались**.

| объявление | ожидалось | измерено этим прогоном |
|---|---|---|
| `applied.txt:147` «попыток по слою кода 49, из них легло 14» | 49 попыток / 14 лёгших | не снято |
| Always 6✓+1⊘+1○=8 | как в строке | не снято |
| Misc 6✓+1⊘+23○=30 | как в строке | не снято |
| Features 2✓+2≡+1⊘+6○=11 | как в строке | не снято |
| итог 14 ✓ + 0 ✗ + 30 ○ + 3 ⊘ + 2 ≡ = 49 | как в строке | не снято |
| `inert.txt:119-123` пять строк 2.1.273 | Thinking block styling ⊘, Thinker symbol speed ⊘, Conversation title ⊘, Worktree mode ≡, MCP non-blocking ≡ | не снято |
| накладки промтов / объявленные не легшими | 0 / 0 в опорной строке | не снято |
| итоговый код возврата конвейера | (опора не фиксирует rc) | **1** (оба прогона, `run.rc`) |

Дописано в шесть строк (119-123 и 147): **ничего**.

Строки 2.1.272 (`inert.txt:114-118` и `applied.txt:146`) не трогались. Ограничение: linux-образа 2.1.272 на usbox нет, маковский файл — другие байты; перезамер 2.1.272 этим прогоном нечем.

## Счётчики per-file (запись в скоупе)

- `claude-patch-all.sh`: 2 замены SHA (`:4374`, `:4379`). Счёт `grep -o -F` ДО: old=2 new=0; ПОСЛЕ: old=0 new=2. Других вхождений пина в этом файле нет.
- `tools/tweakcc-expected-inert.txt`: 0 правок. `git diff --stat` по файлу пуст.
- `tools/tweakcc-expected-applied.txt`: 0 правок. `git diff --stat` по файлу пуст.
- `docs/review/wave165-pin-bump.md`: новый файл отчёта.

Вне скоупа не писалось. Коммита нет.

## RED (неожиданный, не в скоупе)

Оба прогона, сырой вывод выше. Гейт напечатал три пути и вышел 1. Правка этих трёх файлов этой задачей запрещена (нет в `paths:`); подгонять кит под зелёный прогон запрещено стоп-правилом.

## Adjudication requests

1. Изоляция «закоммиченный HEAD `b5e68e67f56824e5ffe96d34642aa1654b0f5bb0` + только правка пина» не доходит до слоя tweakcc: гейт форм оболочки (`claude-patch-all.sh:2989`) выходит 1 на `tools/bun-drift.sh`, `tools/reap-heavy.sh`, `tools/tree-run.sh`. Два прогона, одинаковый сырой вывод. Как мерить состав слоя на новом пине — решение контроллера; исполнитель кит под гейт не подгоняет.

## Self-Check: PASSED

- отчёт существует: `/Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch/docs/review/wave165-pin-bump.md`
- пин на маке: old SHA 0 вхождений, new SHA 2 вхождения, строки 4374 и 4379
- пин в копии usbox: AFTER old=0 new=2, те же строки
- sha256 образа и копии: `6c752e2cc7c110c9df15f26d8d134d438c5ae95dbd610efc1a308bf7f9c5f6c1`
- `run.rc` / `run.rc.1` прочитаны без пайпа, оба `1`
- expected-файлы не изменены
- git commit не выполнялся
- строка статуса совпадает с телом: BLOCKED, не DONE
