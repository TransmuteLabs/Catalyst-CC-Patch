# Бриф волны 38 — проба формы, часть T1b: третий потребитель в проверках конвейера, сплайс, потребитель, стенд (задача #65)

Класс диспатча: 1c. Кит `/Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch`,
ветка `main`, HEAD `9db078a` + незакоммиченные правки волны T1 (ядро, TOML,
наблюдатель, промты — см. §0). Все file:line ниже — по ЭТОМУ дереву (с
правками T1), сняты 2026-09-05.

Этот бриф ПРОДОЛЖАЕТ `docs/review/wave38-brief-form-probe-T1.md` (далее «T1»):
разделы T1 §0 (предмет и решения), §3 (потребитель), §7 (документ), §8
(стенд), §11 (отчёт) действуют дословно с поправками ниже; T1 §1 (факты)
ЗАМЕНЁН §1 этого брифа; T1 §2, §4, §6 — СДЕЛАНЫ (в дереве, не переделывать);
T1 §5, §9, §10 — заменены §4, §6, §7 этого брифа. Прочитать оба файла до
любого другого.

Правило комментариев: код-комментарий фиксирует только констрейнт (граница,
инвариант, «почему не иначе», дом правила); нарратив о правке — в отчёт.

## §0 Что уже в дереве (отчёт T1 `docs/review/wave38-report-T1.md`, зелено во всех гейтах)

- `tweakcc-patch.js`: подъём `let __raw=null,__v="",__errs=[];` + хук
  `__o.rules` (`:3191-3208`), обход `'if(!__v){'` (`:3209`) … `'}'` перед
  `__jerr1=`, спред `extra` ДО `verdict:` (пин `claude-patch-all.sh:5135`
  требует `verdict` последним ключом — принято), хук `onVerdict` (`:3711`);
  наблюдатель: поле `form` в payload (`:3908-3917`), `onVerdict` (`:3940`).
- `probes/probes.toml`: `[probe.form]` `:95-135` (34 ключа), `[probe.form.act]`
  `:136-145`, `[probe.form.text]` `:146-154`; раскатано `--to-home`.
- `probes/idle-watch/prompt.md` (122 строки), `probes/judge/prompt.md` (350).

Отказ T1 (верный): семь проверок конвейера пинят РОВНО ДВА блока
`/*__ccProbe0*/…/*__ccProbe1*/` и ровно два `dirEnv:`; третий блок их роняет.
Решение контроллера: опись потребителей выросла с двух до трёх — проверки
правятся В ЭТОЙ ВОЛНЕ поимённо (не ослабление до `>=2`), `EXPECTED_CHECKS`
остаётся 119 (новых проверок нет — они в T2).

## §1 Факты (дерево с правками T1)

`tweakcc-patch.js`:
- `nm = js.match(nrx)` `:2332`; `const TV = siteName(nm[1], 'notification queue')`
  `:2334`; `const DI = siteName(nm[2], 'session id')` `:2335` — JS-переменные,
  которые `watchCall` вклеивает в строку (образец — его `onAct`).
- ядро `:2348-3741`; `__sur=` `:2495`; `__svc={log:__jlog,clip:__clip,num:__num,list:__lkr}` `:2777`;
  `judgeCall` `:3752` (`tag:"[Judge]"` `:3765`); `watchCall` `:3803`
  (`'globalThis.__ccFleet??=[];'` `:3809`, guard + `tag:"[Watch]",dirName:"idle-watch",arm:!1,label:"FLEET",` `:3817`,
  `form:(()=>{…})()` `:3908-3917`, `onVerdict` `:3940`).
- `resolveFor` `:3952-3965`; комментарий «Two homes, one core.» `:3967-3976`;
  `const watchBlock = '/*__ccProbe0*/' + resolveFor(core + watchCall, SLOT, 'watcher') + '/*__ccProbe1*/';` `:3977-3978`;
  `judgeBlock` `:3979-3980`; цикл «assert they came out as themselves»
  `:3985-3997` (`if (!watchBlock.includes(where))`); проверка позиции
  statement `:4003-4009`; `const edits = [ { at: m.index, len: 0, text: watchBlock }, …` `:4014-4022`.
- `step('23 statusline update throttle'` `:4047` — номер 23 ЗАНЯТ; нового
  `step(` не вводить: сплайс формы едет внутри того же кода, что `watchBlock`.

`claude-patch-all.sh` (пины, которые ломает третий блок; блок `checks = {` `:4421`):
- `_probe_uses_the_images_own_names` — тело `:3314-3342`: `blocks` из
  `_probe_full`, `if len(blocks) != 2: return False` `:3315`; `pool` по
  `blocks[0]` `:3321`, сравнение `blocks[1]` `:3327`; `watch = [b … tag:"[Watch]"]`
  `:3330`; `queue`/`session`/`upstream` `:3333-3340`. Вызов `:4635`.
- `_judge_rides_the_tool` — def `:3814`, `if len(ends) != 2 or len(starts) != 2` `:3840`;
  `cores` тождественны `:3848-3850`; `JUDGE`/`WATCH` маркеры `:3856-3858`
  (`JUDGE` содержит `__s===""||` — читатель формы этого куска НЕ содержит и
  под `JUDGE` не подпадает); `judge_sites`/`watch_sites` `:3859-3864`; дом
  судьи `:3868-3879`; дом наблюдателя `:3881-3893`: `b4` — четыре имени
  `tool:(ID),input:(ID),ctx:(ID),key:(ID),` в блоке наблюдателя, `tail = d[ends[wi]:ends[wi]+400]`
  обязан начинаться вызовом диспетчера (`ID=await (tool.call|ID(tool).execute)(inp,{...ctx,toolUseId:key,userModified:…`).
  Вызов `:4633`.
- `_turn_belongs_to_the_judge` — `if len(starts) != 2 or len(ends) != 2` `:3932`;
  далее по каждому ядру `let __t=__o.turn?__o.turn():[];` ровно 1, поставщик
  `turn:()=>{` = судья. Вызов `:4637`.
- `_consumer_uses_no_core_privates` — `if len(blocks) != 2` `:4080`; хвост
  каждого блока после `/*__ccCore1*/` не содержит подстрок `__jlog`, `__clip`,
  `__jdir`, `__jarm`, `__deg`, `__t0` `:4083-4088`. Вызов `:4634`.
- `_bom_stripped_in_our_blocks` — def `:4093`, `if len(blocks) != 2` `:4114`,
  в каждом блоке ровно 2 `^﻿/,""` `:4116` (вход `_probe_full`). Вызов `:5295`.
- `_every_cut_is_named` — def `:4277`, `if len(blocks) != 2` `:4306`; запрет
  `.substring(`/`.substr(` в блоках `:4324-4325`; перепись `.slice(` по всем
  блокам `:4331-4358`, эталон `found == {…}` `:4358-4372` (по СХЛОПНУТОМУ `d`:
  ядро один раз, `(b'-256', False): 1` — кольцо флота наблюдателя). Вызов `:4781`.
- `'settings live in one probes home'` `:5408-5420`:
  `len(re.findall(rb'dirEnv:process\.env\.CLAUDE_PROBES_DIR', d)) == 2` `:5416`,
  `CLAUDE_JUDGE_DIR`/`CLAUDE_IDLE_DIR` == 0 `:5417-5418`.
- Не ломаются третьим блоком (проверено чтением): `'exactly one probe core survives the collapse'`
  `:4645` (по схлопнутому `d`), `'the probes home is computed once'` `:5364`
  (`__phome=` один раз в ядре), `'probe skips before touching the disk'` `:4762`
  (форма `pre` в ядре), `'watcher rides the same core'` `:4682` (guard
  наблюдателя), `'each probe fallback prompt speaks its own vocabulary'` `:4657`
  (две формы присутствуют; третья — в T2), `'judge cancels when it cannot decide'`
  `:5116-5135` (байты хвоста `__jlog` — уже учтено в T1).
- Схлопывание `:4415-4419` снимает копии ЯДРА из 2-го и 3-го блоков; маркеры
  `__ccProbe0/1` и консьюмерские половины остаются.
- Порядок блоков в образе: судья (внутри `async call(` инструмента Agent,
  меньший офсет) — затем на сайте диспетчера форма и наблюдатель.

`tools/probe-bench.js`: `ENV_KEYS` `:25`; `--self-check` `:54`; usage `:70`;
`WATCH_MARK` `:140`; `classifyBlocks` `:142-155`; `locateNames` `:174-215`;
`baseConfig` `:251`; `scenarios` `:336`; `EXPECTED_SCENARIOS = 82` `:1052`;
`EXPECTED_MUTATIONS = 5` `:1060`; `homeName` `:1104`; `setScenarioEnvironment`
`:1123`; `CHECKS` `:1325`; `tempDir` `:1431`; `{{DIR}}` `:1583-1587` (сегодня
`{{DIR}}` без `attachFiles` = ошибка стенда `:1586` — для form-сценариев
подстановка идёт по `files`); `SELF_CHECK_MUTATIONS` `:1861`, в нём отрава
`poison: { from: 'EXPECTED_SCENARIOS = 82;', to: 'EXPECTED_SCENARIOS = 81;' }`
`:1902` — при смене числа литералы отравы переезжают на `124;`/`123;` (иначе
self-check не найдёт строку); `runScenario(probes[scenario.probe === 'watch' ? 'watch' : 'judge'], …)` `:2048`.

`tools/checks-mutations.tsv`: строки C6 (`every cut in the probe is named`,
якорь `вырезано` → `.substring(0,9)`)
и P1 (`settings live in one probes home`, якорь `__o.dirEnv||((process.env.CLAUDE_CONFIG_DIR`)
— якоря остаются валидными; зубы гоняет свип.

Дома чисел: `tools/probe-bench.js:1052` (82), `claude-patch-all.sh:6087`
(`probe-bench's 82 scenarios`), `tools/docnum-mutations.tsv:28` (D4);
`tools/probe-bench.js:1060` (5), `README.md:122` (`probe-bench's 5 recorded mutations`),
`tools/docnum-mutations.tsv:65` (D36).

Корпус/сборка: pristine `~/.local/share/claude-patch/corpus/2.1.259.pristine`,
sha `884baa38fe1a624be25c4a91568bf5a08b5cf4e7d7acf29b7760e3525d964898`.
Конвейер патчит СУЩЕСТВУЮЩУЮ копию: перед сборкой `cp` pristine в
`/tmp/w38/259.bin` (сверить sha), строка свипа — T1 §1 (с
`CLAUDE_PATCH_SKIP_BENCH=1` для итераций).

## §2 Проверки конвейера — семь правок (`claude-patch-all.sh`)

Все правки — только внутри названных тел; докстринги обновить одной фразой
про третьего потребителя там, где они говорят «two»/«both».

2.1. `_probe_uses_the_images_own_names` (`:3314-3342`):
`if len(blocks) != 3: return False`; равенство имени пула — для ВСЕХ блоков
(`for b in blocks[1:]: if re.search(rb'let __pool=typeof (' + ID + rb')==="function"', b).group(1) != pool.group(1): return False`,
с защитой от `None` → `return False`); после проверки наблюдателя добавить:

```python
    form = [b for b in blocks if b'tag:"[Form]"' in b]
    if len(form) != 1:
        return False
    fqueue = set(re.findall(rb'(' + ID + rb')\(\{value:"\[form\] "', form[0]))
    fsession = set(re.findall(rb'agentId:(' + ID + rb')\(\),priority:"next"', form[0]))
    if fqueue != {upstream.group(1)} or fsession != {upstream.group(2)}:
        return False
```

(до `return queue.group(1) == …`; `upstream` уже вычислен выше — перенести
блок формы ПОСЛЕ вычисления `upstream`).

2.2. `_judge_rides_the_tool` (`:3840-3893`): `if len(ends) != 3 or len(starts) != 3`;
после `WATCH = …` добавить
`FORM = (rb'String\(process\.env\.CLAUDE_FORM\?\?""\)\.trim\(\)\.toLowerCase\(\);' rb'return !\(__s==="0"\|\|__s==="false"\|\|__s==="off"\|\|__s==="no"\)\}\)\(\)')`
и `form_sites` по тому же образцу; условие:
`if len(judge_sites) != 1 or len(watch_sites) != 1 or len(form_sites) != 1 or len({judge_sites[0], watch_sites[0], form_sites[0]}) != 3: return False`.
После дома наблюдателя (перед `return True`) — дом формы:

```python
    # The form probe's home: the same statement site as the watcher, directly
    # in front of it, bound to the watcher's own four names -- it evaluates
    # the call the watcher then reports on.
    fi = form_sites[0]
    if ends[fi] != starts[wi]:
        return False
    fb4 = re.search(rb'tool:(' + ID + rb'),input:(' + ID + rb'),ctx:(' + ID
                    + rb'),key:(' + ID + rb'),', d[core_end[fi]:ends[fi]])
    if not fb4 or fb4.groups() != b4.groups():
        return False
```

Докстринг: пункт «the form probe sits directly in front of the watcher at the
same site, with the watcher's four names; three cores byte-identical».

2.3. `_turn_belongs_to_the_judge` (`:3932`): `!= 3`. Комментарий над def
(«The judge and the watcher live at different sites now and each appears
once…» `:3895-3907`) — дополнить: «the form probe shares the watcher's site
and appears once as well».

2.4. `_consumer_uses_no_core_privates` (`:4080`): `!= 3`.

2.5. `_bom_stripped_in_our_blocks` (`:4114`): `!= 3`; докстринг «Our four BOM
strips» → «Our six BOM strips (two per block)».

2.6. `_every_cut_is_named` (`:4306`): `!= 3`; эталон `found` НЕ меняется —
блок формы обязан не нести ни одного среза (констрейнт §3.1).

2.7. `'settings live in one probes home'` (`:5416`): `== 3`; добавить строку
`and len(re.findall(rb'CLAUDE_FORM_DIR', d)) == 0`.

`EXPECTED_CHECKS = 119` не меняется. Любая ДРУГАЯ красная проверка после
сборки = стоп по стоп-правилу (имя, строка пина, байт) — не править.

## §3 Потребитель `formCall` — по T1 §3 с констрейнтами проверок

3.1. Констрейнты, продиктованные проверками (нарушение = красный конвейер):
- во всём тексте `formCall` НЕТ `.slice(`, `.substring(`, `.substr(`, `__sur(`
  (перепись срезов `:4306-4372`): строки режутся только через `__cl` —
  функцию клипа, переданную параметром (в потребителе это `__svc.clip`);
  массивы — `filter((__x,__i,__a)=>__i>=__a.length-N)`; префикс строки до
  совпадения НЕ вырезается — окно отрицания задаётся лукбехиндом (3.3);
- в тексте `formCall` НЕТ подстрок `__jlog`, `__clip`, `__jdir`, `__jarm`,
  `__deg`, `__t0` (ценз приватных `:4083-4088`): имена вида `__dg`, `__cl`,
  `__tm`; ключ объекта `deg:` допустим (это не `__deg`);
- `formCall` НЕ содержит `globalThis.__ccFleet??=[];` и `__s===""||`
  (маркеры наблюдателя и судьи в `_judge_rides_the_tool`);
- guard и голова вызова — ДОСЛОВНО:
  `'if((()=>{let __s=String(process.env.CLAUDE_FORM??"").trim().toLowerCase();return !(__s==="0"||__s==="false"||__s==="off"||__s==="no")})()&&$4?.agentContext?.agentType==="main")' + 'await globalThis.__ccProbe({' + 'tag:"[Form]",dirName:"form",arm:!0,label:"FORM",rx:"PASS|WARN|REFUSE",act:"REFUSE|WARN",' + …`
  затем `fb:"Deterministic form probe: no model is consulted; the verdicts PASS, WARN and REFUSE come from configured rules.",sw:process.env.CLAUDE_FORM,dirEnv:process.env.CLAUDE_PROBES_DIR,dbg:process.env.CLAUDE_FORM_DEBUG,tool:$2,input:$3,ctx:$4,key:$5,`
  (четыре слота подряд в этом порядке — их читает `fb4`);
- уведомления — ровно той же формой, что у наблюдателя: `'+TV+'({value:"[form] "+…,mode:"task-notification",agentId:'+DI+'(),priority:"next"})`
  (оба места — `onAct` и `onBroken`; других `({value:"[form] "` нет);
- отказ: `throw` объекта `Error` с `__ccJudgeBlock=!0` (как у судьи);
- русские строки — `\u`-эскейпами; литералов слов из списков `open_door`/`legalize`
  и строк `cargo`, `RCH_REQUIRE_REMOTE`, `Selected worker`, `--only` в коде нет.

3.2. Размещение: `const formCall =` перед `const watchCall` (`:3803`). Голова
`formCall` — объявления `globalThis.__ccFormEval??=(ev,c,__cl)=>{…};` и
`globalThis.__ccFormKind??=(p,t,c)=>{…};` ДО guard (они нужны стенду и
реплею и не зависят от включателя); затем guard + `await globalThis.__ccProbe({…})`.

3.3. `__ccFormEval(ev,c,__cl)` — T1 §3.6 с поправками:
- регулярки компилируются из `c[ключ]` с флагами T1 §4 и кэшируются в
  `globalThis.__ccFormRx` (ключ кэша — строка + флаги);
- A3: одна составная регулярка `new RegExp("(?<!(?:"+c.negation+")\\s{0,16})(?:"+c.open_door+")","iu")` —
  `c.negation` теперь ГОЛАЯ альтернация (§5); строка с совпадением → `{c:"A3",n,q:__cl(line,160)}`;
- цитаты `q` — `__cl(<строка>,160)`; текст снапшота — `__cl(text,40000)`;
- B: `decision_head` по первой непустой строке сообщения; при совпадении —
  `decision_basis` и `decision_referent` по всему сообщению;
- F: текст коммита — `matchAll` по `git_msg` (флаг `gu`), группы 1|2|3,
  абзацы через `"\n\n"`; heredoc-тело при `<<`; трейлеры — индексы строк по
  `trailer_a`/`trailer_b` (флаги `mu` — но искать по массиву строк `split("\n")`
  с `^`-анкером без `m`), «соседние» = `Math.abs(ia-ib)===1`;
- возврат `{refuse:[{c,n,q}], warn:[{c,n,q}]}`.

3.4. `__ccFormKind(p,t,c)`: `"brief"` если `brief_path` по `p` И `brief_head`
по первой строке `t`; `"report"` если `report_path` по `p`; иначе `null`.

3.5. `pre`, `rules`, `onAct`, `onBroken` — T1 §3.3–3.5 дословно, с именами
по 3.1 (`__dg` вместо `__deg` в тексте; `__ccForm.last` хранит `cls`,
`verdictKind`, таблицы `act`/`text`). `rules` читает файлы через
`await import("node:fs/promises")` (как ядро — по образцу `__rdj` `:2852` /
`__ldt` `:2874`), пост-состояние `Edit` — `replace`/`replaceAll` без срезов;
heredoc/redirect — группы регулярок `heredoc`/`write_redirect`.

## §4 Сплайс (`tweakcc-patch.js:3967-4022`)

- Комментарий «Two homes, one core.» → «Three homes, one core.» + абзац:
  «The FORM PROBE sits in front of the watcher at the dispatcher: it evaluates
  the call the watcher then reports on, so its state is filled before the
  watcher's payload reads it. Same site, same four names.»
- После `judgeBlock` (`:3980`):
  `const formBlock = '/*__ccProbe0*/' + resolveFor(core + formCall, SLOT, 'form') + '/*__ccProbe1*/';`
- Цикл «assert they came out as themselves» (`:3985-3997`): прогнать те же
  четыре пары и для `formBlock` (`typeof ${qm[1]}===`, `${nm[1]}({value:`,
  `agentId:${nm[2]}()`, `let __v=${tm[1]}(__i)`) — отказ `fail(...)` с
  текстом «… into the form block verbatim».
- `edits[0]` (`:4015`): `{ at: m.index, len: 0, text: formBlock + watchBlock }`.
- Нового `step(` не вводить (номер 23 занят `:4047`).

## §5 `probes/probes.toml` — одна правка + раскатка

`negation` (`:115`, сейчас `'(?:nothing to|no|not|never|нечего|ничего не|не)\s*$'`) →
`negation = 'nothing to|no|not|never|нечего|ничего не|не'`; комментарий-констрейнт
над ключом: «голая альтернация: код оборачивает её в лукбехинд
`(?<!(?:…)\s{0,16})` перед `open_door` — окно отрицания без среза строки».
Затем `bash scripts/probes-sync.sh --to-home`.

## §6 Стенд `tools/probe-bench.js` — T1 §8 с поправками

- 8.1: `FORM_MARK = 'tag:"[Form]"'`; `classifyBlocks` — `form` при
  `FORM_MARK`, `watch` при `WATCH_MARK`, иначе `judge`; ровно по одному
  (сообщение об отказе называет найденные счётчики). `locateNames(carved,'form')`:
  пул/агент/заголовок как у watch; очередь — `/(X)\(\{value:"\[form\] "/`.
- 8.2: `baseConfig` для form — `{enforce:true, fail_closed:false, ...FORM_RULES}`,
  `FORM_RULES = Bun.TOML.parse(fs.readFileSync(path.join(__dirname,'..','probes','probes.toml'),'utf8')).probe.form`
  (одни данные в образе и на стенде). Переопределение из сценария — глубокое
  слияние по `act`/`text`; `config:{arm_cmd:undefined}` удаляет ключ.
- 8.3: `files` → `tempDir/work/`; `{{DIR}}` подменяется в `dispatchPrompt`,
  `message`, `command`, `filePath`, `oldString`, `newString`; правило `:1586`
  («`{{DIR}}` без `attachFiles` — ошибка») для form-сценариев заменяется на
  «`{{DIR}}` без `files` — ошибка».
- 8.4: результат form-сценария читает строку журнала `form/journal.jsonl`
  (поля `outcome`, `cls`, `fired`, `skipped`, `deg`, `verdict`); новые ключи
  `CHECKS`: `cls`, `firedIncludes`, `verdictIncludes`, `skippedCount`,
  `rulesKeyIncludes`, `recordRequestIncludes`, `dispatchIncludesAt`,
  `replaySummary` — каждый с `ok` и `got`, как существующие.
- 8.5: `--form-replay <путь>…` (usage `:70` дополнить): блок формы
  компилируется и исполняется один раз с контекстом `agentContext.agentType:'stand'`
  (guard ложен — `__ccProbe` не вызывается, `globalThis.__ccFormEval`/`__ccFormKind`
  объявлены); клип стенда — `(s,n)=>s.length>n?s.slice(0,n)+'…':s` (в стенде
  срезы разрешены); формат вывода — T1 §8.5.
- 8.6: 42 сценария T1 §8.6 (1–42). Для 36/37: `formBefore:[имена]` и
  `ticks:2` — стенд исполняет названные form-сценарии тем же `tempDir` и
  тем же процессом ДО консультации наблюдателя, затем консультацию `ticks` раз;
  `dispatchIncludesAt:[[…],[…]]` — подстроки по тикам.
- 8.7: `EXPECTED_SCENARIOS = 124`, `EXPECTED_MUTATIONS = 7`; две мутации T1
  §8.7; в `SELF_CHECK_MUTATIONS` все литералы старых чисел (`EXPECTED_SCENARIOS = 82;`
  → `124;`, `81;` → `123;`, и любые `EXPECTED_MUTATIONS = 5` → `7`) переезжают —
  найти `grep -n "= 82;\|= 81;\|= 5;\|= 6;" tools/probe-bench.js` внутри
  `SELF_CHECK_MUTATIONS`.
- Дома чисел: `:1052`→124, `claude-patch-all.sh:6087`→`probe-bench's 124 scenarios`,
  `docnum-mutations.tsv:28` D4 → `124;`/`125;`; `:1060`→7, `README.md:122`→
  `probe-bench's 7 recorded mutations` (+два слова о новых мутациях),
  `docnum-mutations.tsv:65` D36 → `7`/`8`.

## §7 Границы, стоп-правило, приёмка

`paths:` — `tweakcc-patch.js`, `claude-patch-all.sh` (ТОЛЬКО тела семи
проверок §2 + `:6087`; `EXPECTED_CHECKS` и прочие проверки не трогать),
`probes/probes.toml` (только `negation` + комментарий), `tools/probe-bench.js`,
`docs/form-probe.md` (новый, T1 §7), `README.md` (строка рядом с `:120` и
`:122`), `tools/docnum-mutations.tsv` (D4, D36),
`tools/emit-check.js` (ТОЛЬКО таблица `parts` — добавить строку
`['formCall', '  const formCall =', '  const watchCall =']` и сменить конец
куска `judgeCall` с `'  const watchCall ='` на `'  const formCall ='`;
санкция контроллера 2026-09-05 — предстадия режет исходник смежными
якорями-объявлениями, третье объявление между `judgeCall` и `watchCall`
требует своего якоря). Дом `~/.claude/probes/` —
только `probes-sync.sh --to-home`. Чужие правки `docs/review/wave35-*`,
`wave37-*` и правки T1 — не откатывать.

Запреты и стоп-правило — T1 §9 дословно (без коммитов; refuse-with-proof;
одна честная попытка → BLOCKED с сырым выводом; никаких `cargo`,
`pkill`/`launchctl`; установленный образ и `~/.claude/settings.json` не
трогать).

Приёмка (из корня кита; `set -o pipefail` или без пайпа; длинные шаги —
фоном с ожиданием по pid, без `sleep` дольше таймаута инструмента):
1. `node --check tweakcc-patch.js`; `python3 -c "import ast,sys;ast.parse(open('claude-patch-all.sh').read().split('PYCHECKS',1)[-1])"` НЕ нужен —
   конвейер сам разбирает блок; достаточно шага 2.
2. `mkdir -p /tmp/w38 && cp ~/.local/share/claude-patch/corpus/2.1.259.pristine /tmp/w38/259.bin && shasum -a 256 /tmp/w38/259.bin`
   (= `884baa38…`), затем строка свипа T1 §1 с `CLAUDE_PATCH_SKIP_BENCH=1`,
   `--target /tmp/w38/259.bin`, лог `/tmp/w38/build.log` → 119/119 `[OK]`,
   `EXIT=0`, пол `3/119`, строка «ЧИСЛА В ДОКАХ СОВПАДАЮТ» с `probe-bench=124`/`7`.
3. `bun tools/probe-bench.js --binary /tmp/w38/259.bin` → `ИТОГ сценариев=124 расхождений=0`;
   `--self-check` → `мутаций=7 ослепили=7`.
4. Реплей: `bun tools/probe-bench.js --binary /tmp/w38/259.bin --form-replay ~/work/SIB/Transmutation/Nexus/conduit/conduit/.r17-briefs ~/work/SIB/Transmutation/Nexus/nexus/nexus-exec/.briefs > /tmp/w38/replay.txt`
   (полный вывод в отчёт) и положительный контроль
   `… --form-replay docs/review > /tmp/w38/replay-self.txt` — файл
   `wave38-brief-form-probe-T1.md` даёт A2 (строка `witness_worker` в тексте
   правила) и A3 (сценарии 14–16 несут слова `open_door`); этот бриф T1b —
   A3 (§3.1 называет литералы) и A2 (та же причина); ноль срабатываний на
   любом из них = реплей не мерит (стоп).
5. `bash scripts/probes-sync.sh --to-home`; `--diff` зелёный;
   `bash tools/probes-sync-bench.sh` → `сценариев=7 расхождений=0`.
6. `bash tools/sweep.sh 259 > /tmp/w38/sweep.log 2>&1` (фоном; ожидание по
   pid лидера `sweep.self.*`) → `SWEEP зубы реестра проверок: ЗЕЛЁНО`,
   `SWEEP 259: exit=0 ok=119 fail=0 … bench=1`, `SWEEP DONE`.
7. Счётчики ДО/ПОСЛЕ: сценарии 82→124, мутации 5→7, проверки 119→119,
   зубы реестра 19→19, строки реплея по корпусам и по `docs/review`.

Отчёт — `docs/review/wave38-report-T1b.md` по T1 §11 (плюс раздел «семь
проверок: диф каждой тремя строками»). Итоговое сообщение — четыре строки.

<!-- BRIEF COMPLETE -->
