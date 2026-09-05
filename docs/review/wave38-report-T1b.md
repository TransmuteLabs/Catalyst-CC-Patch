# Отчёт волны 38 (T1b) — третий потребитель написан целиком; сборка остановлена СТРУКТУРНЫМ пином вне paths

Статус: **BLOCKED (own diff green; unexpected red in tools/emit-check.js)**.
Всё, что бриф T1b называет (§2 семь правок, §3 потребитель, §4 сплайс, §5
negation, §6 стенд 124/7 + `--form-replay`, документ, дома чисел), лежит в
дереве; собственный код проверен насколько возможно без сборки (`node
--check` обоих JS, разбор эмитнутого текста formCall вне образа — парсится).
Сборка не начинается: предстадия конвейера `tools/emit-check.js` (файл ВНЕ
paths §7) режет `tweakcc-patch.js` якорями `core → judgeCall → watchCall →
resolveFor`, и мандатное §3.2 размещение `const formCall =` ПЕРЕД
`const watchCall` оставляет ДВА объявления в куске judgeCall. Правка
emit-check — три строки, но стоп-правило диспатча («любая красная проверка
конвейера, кроме семи из §2 → стоп, не править её») и категоричное «вне
списка не менять НИКАК» запрещают её без санкции контроллера. Отказ — не
«нельзя», а «нельзя без выхода за paths»; прецедент T1 — та же форма.

## 1. Изменённые файлы (только paths-скоуп §7)

| файл | diff (numstat, против HEAD) | что легло |
|---|---|---|
| `tweakcc-patch.js` | +309/−12 (включая +42/−2 волны T1) | §3: `const formCall` (3 объявления до guard: `__ccFormC`/`__ccFormEval`/`__ccFormKind`, guard, probe-объект с pre/rules/onAct/onBroken); §4: комментарий «Three homes», `formBlock`, цикл имён для watcher+form, `edits[0] = formBlock + watchBlock` |
| `claude-patch-all.sh` | +63/−26 | §2: семь проверок ×3 потребителя (тела ниже) + строка «probe-bench's 124 scenarios» (бывшая :6087, теперь :6124) |
| `probes/probes.toml` | +63/−0 (включая +61 T1) | §5: `negation` → голая альтернация + комментарий-констрейнт |
| `tools/probe-bench.js` | +608/−38 | §6: FORM_MARK/classify 3 родов, locateNames form, FORM_RULES из TOML кита, mergeConfig (deep, undefined=удаление), 42 сценария, 8 новых ключей CHECKS, `--form-replay` (вариадик), тики/formBefore, зачистка `__ccForm`/`__ccFormRx`, 82→124, 5→7, литералы отравы 124/123, две мутации |
| `docs/form-probe.md` | НОВЫЙ, 112 строк | T1 §7 дословно по составу разделов |
| `README.md` | +2/−1 | строка `docs/form-probe.md` рядом с :120; :122 → «7 recorded mutations … the form class comparator and the replay summary» |
| `tools/docnum-mutations.tsv` | +2/−2 | D4 → `124;`/`125;`, D36 → `7`/`8` |

Раскатка `bash scripts/probes-sync.sh --to-home` — зелёная; `--diff` — зелёный
(плейсхолдер plist — прежнее поведение скрипта).

## 2. Семь проверок: диф каждой тремя строками

Все семь — ПО МЕСТУ, счётчики 2→3, эталоны не ослаблены; проверить сборкой
не удалось (упала раньше блока checks — см. §4).

1. `_probe_uses_the_images_own_names` — `len(blocks)!=2`→`!=3`; равенство
   пула стало циклом `for b in blocks[1:]` с защитой от `None`; добавлен блок
   формы (fqueue/fssession множествами против upstream) ПОСЛЕ вычисления
   `upstream`, до `return queue…`. Комментарий «Both copies…» → «Every copy…
   Three consumers now carry it». СТАТУС: написано.
2. `_judge_rides_the_tool` — `!=2`→`!=3`; добавлены `FORM` (инвертированный
   читатель, без `__s===""||`) и `form_sites`; условие
   `len({judge,watch,form})!=3`; после дома наблюдателя — дом формы
   (`ends[fi]!=starts[wi]`, `fb4.groups()!=b4.groups()`). Докстринг: пункт о
   форме + «three cores byte-identical» (заменил «two cores»). СТАТУС: написано.
3. `_turn_belongs_to_the_judge` — оба счётчика `!=3`; комментарий над def
   дополнен «the form probe shares the watcher's site and appears once as
   well». СТАТУС: написано.
4. `_consumer_uses_no_core_privates` — `!=3`; докстринг «both blocks» → «all
   three blocks (judge, form, watcher)». СТАТУС: написано.
5. `_bom_stripped_in_our_blocks` — `!=3`; докстринг «Our four BOM strips» →
   «Our six BOM strips (two per block)», «Two blocks (judge and observer)» →
   «Three blocks (judge, form, watcher)». СТАТУС: написано.
6. `_every_cut_is_named` — `!=3`; эталон `found` НЕ меняется (блок формы без
   срезов — констрейнт §3.1, проверен грепом по тексту formCall: ноль
   `.slice(`/`.substring(`/`.substr(`/`__sur(`); докстринг дополнен фразой о
   форме. СТАТУС: написано.
7. `'settings live in one probes home'` — `dirEnv:…CLAUDE_PROBES_DIR` `==3`;
   добавлено `and len(re.findall(rb'CLAUDE_FORM_DIR', d)) == 0`. СТАТУС: написано.

`EXPECTED_CHECKS = 119` не тронут. Греп по всем `ccProbe0/1/ccCore0/1` в
конвейере подтвердил: якорные резки блоков живут только в этих семи + в
`tools/emit-check.js` (вне образа, см. §4).

## 3. Счётчики ДО/ПОСЛЕ (§7.7)

| величина | ДО | ПОСЛЕ | примечание |
|---|---|---|---|
| сценарии probe-bench | 82 | 124 (написано) | прогон НЕ состоялся — нет собранного образа |
| мутации self-check | 5 | 7 (написано) | прогон НЕ состоялся |
| проверки конвейера | 119 | 119 (не менялись) | сборка падает ДО блока checks |
| пол проверок | 3/119 | 3/119 (ожидается) | не измерялось |
| зубы реестра | 19 | 19 | свип не запускался |
| строки реплея (корпус / docs/review) | — | — | режим написан, не мерился |

Выполненные шаги приёмки: §7.1 `node --check tweakcc-patch.js` → OK (обе
попытки, до и после фиксов); раскатка+`--diff` → зелёные. §7.2 — BLOCKED
(§4). §7.3–§7.6 — не выполнялись (зависят от образа).

## 4. Блокер: сырой вывод (§7.2, командная строка свипа + CLAUDE_PATCH_SKIP_BENCH=1, --target /tmp/w38/259.bin)

```
Target binary: /private/tmp/w38/259.bin
Source digest: 884baa38fe1a624be25c4a91568bf5a08b5cf4e7d7acf29b7760e3525d964898  /private/tmp/w38/259.bin
==> Разбор вклеиваемого кода
<anonymous_script>:46
    '});';
         ^

SyntaxError: Unexpected token ';'
    at new Function (<anonymous>)
    at Object.<anonymous> (.../tools/emit-check.js:70:15)
    ...
Node.js v22.23.2
EXIT=1
```

Механизм (доказательство): `tools/emit-check.js:28-30`

```python
  ['core', '  const core =', '  const judgeCall ='],
  ['judgeCall', '  const judgeCall =', '  const watchCall ='],
  ['watchCall', '  const watchCall =', '  const resolveFor ='],
```

кусок judgeCall = текст от `const judgeCall =` до `const watchCall =`;
поскольку §3.2 мандатно ставит `const formCall =` между ними, кусок содержит
ДВА выражения-объявления (`'…});';` затем `const formCall =`), а emit-check
оборачивает кусок как ОДНО выражение `return (…)`. Греп подтверждает:
`const formCall присутствует в куске judgeCall: True`. Файл не входит в
paths §7; стоп-правило диспатча запрещает править красную проверку конвейера
вне семи из §2. Чинится тремя строками (см. adjudication 1).

Внутри «одной честной попытки» найдены и исправлены ДВА собственных дефекта
(не блокер): лишние `}` в хвосте `onAct` и в конце `rules` — эмитнутый текст
formCall теперь разбирается автономно (проверено `new Function` с async-обёрткой
и подстановкой слотов — тем же способом, что emit-check).

## 5. Отклонения от брифа

- **Д1 (сценарий 38).** T1 §8.6-38 ожидает `outcome:'skip_degraded'`; я
  написал `'block_degraded'`. Причина: мандатная голова §3.1 несёт `arm:!0`,
  а ядро пишет `outcome:__o.arm?"block_degraded":"skip_degraded"`
  (tweakcc-patch.js, ветка деградации; T1 §2.5/T1b ядро не открывают) —
  «skip_degraded» при `arm:!0` недостижим. Прочие ожидания сценария 38
  (`nudges:1`, `nudgeIncludes:'form-rule-missing:arm_cmd'`, `passed:true`)
  сохранены. Уведомление onBroken не бросает — вызов проходит, т.е.
  поведение «skip», слово в журнале «block_degraded».
- **Д2 (цитаты класса F).** T1 §3.6 давал цитату «git commit без --only»
  дословно; §3.1 T1b запрещает литерал `--only` в коде потребителя.
  Разрешение: цитата собирается из конфига — `"git commit: нет "+c.git_commit_ok`
  (аналогично push) — литерала в коде нет, сценарий 29
  (`firedIncludes:'--only'`) удовлетворён источником образца из TOML.
- **Д3 (флаги brief_ref).** Таблица флагов T1 §4 говорит «g только у
  git_msg», но перечисление путей (до 4 уникальных) требует `matchAll`;
  brief_ref компилируется с `"gu"` в rules. Противоречие внутри T1,
  разрешено в пользу работоспособности.
- **Д4 (errorIncludes).** Сценарий 3 требует ДВЕ подстроки ('A1' и 'пробой
  формы'); компаратор errorIncludes расширен до массива (строка остаётся
  валидной — обратная совместимость).

## 6. Adjudication requests (решает контроллер)

1. **ГЛАВНЫЙ — санкция на `tools/emit-check.js` (вне paths, 3 строки):**
   добавить в `parts` строку `['formCall', '  const formCall =', '  const watchCall =']`
   и сменить конец куска judgeCall с `'  const watchCall ='` на
   `'  const formCall ='`. Без этого сборка не начинается вовсе (§4).
   После санкции волна прогоняется по приёмке §7.2–§7.6 без других правок —
   всё остальное уже в дереве. Альтернатива — контроллер правит сам.
2. Подтвердить Д1 (слово исхода при сломанных настройках формы) либо
   потребовать иное решение (смена `arm` трогает ядро и не открыта этой
   волной).
3. Подтвердить Д2 (форма F-цитат из конфига) — иначе сценарий 29 требует
   иного якоря.
4. Подтвердить Д3 (`"gu"` у brief_ref) либо дать иную форму перечисления.

## 7. Замеченное вне скоупа (флагом, без правок)

- `tools/emit-check.js` — якорная таблица не знает formCall (сам блокер, §4).
  Других якорных резок исходника патча нет (греп по tools/, scripts/,
  claude-patch-all.sh).
- Прочего не замечено; чужие правки `docs/review/wave35-*`, `wave37-*` и
  правки T1 не тронуты.

## Self-Check: PASSED

Созданные/изменённые файлы существуют (`git status`: 7 файлов paths-скоупа
изменены, `docs/form-probe.md` новый, отчёт новый); счётчики — дословный
вывод запущенных команд (`node --check` ×2 OK; `shasum` pristine совпал;
numstat в §1; `probes-sync --diff` пуст = зелёный; EXIT=1 сборки в §4 —
сырой хвост лога); статус BLOCKED соответствует телу: доставленное
проверено на уровне синтаксиса и фактов §1, недоставленное (сборка, стенд,
реплеи, свип) названо с причиной и доказательством.
