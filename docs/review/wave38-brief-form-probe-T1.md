# Бриф волны 38 — проба формы: третий потребитель ядра `__ccProbe` (задача #65, часть T1: механизм + стенд)

Класс диспатча: 1c (новый механизм в прод-контуре — патченный бинарник).
Кит: `/Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch`,
ветка `main`, HEAD `9db078a` (все file:line ниже — по этому дереву; в дереве
есть незакоммиченные правки только в `docs/review/wave35-brief-probe-roots.md`
и `docs/review/wave37-brief-stage-census.md` — их не трогать).

Правило комментариев: код-комментарий фиксирует только констрейнт, который код
не покажет сам (граница, инвариант, «почему не иначе», дом правила). Нарратив
о правке — в отчёт, не в код.

## §0 Предмет и решения (все приняты — открытых вопросов нет)

В образе живут два потребителя общего ядра `globalThis.__ccProbe`: судья
(`tag:"[Judge]"`, внутри `async call(` инструмента Agent) и наблюдатель
(`tag:"[Watch]"`, перед вызовом инструмента в главном диспетчере). Эта волна
добавляет ТРЕТЬЕГО потребителя — пробу формы `tag:"[Form]"`, `dirName:"form"`
— на сайте наблюдателя, и учит ядро детерминированному вердикту без ступени
модели.

Проба формы механически ловит семь классов дефектов формы:

| класс | событие | что читает | вердикт |
|---|---|---|---|
| A1 | бриф передан/записан | последняя непустая строка файла-брифа ≠ `<!-- BRIEF COMPLETE -->` | REFUSE |
| A2 | бриф передан/записан | арма `cargo …` без `RCH_REQUIRE_REMOTE=1 rch exec` или без `> лог 2>&1`; арма есть, а свидетель `[RCH] remote` не назван; назван `Selected worker:` | REFUSE |
| A3 | бриф передан/записан | слова открытой двери вне заборов и вне окна отрицания | REFUSE |
| A4 | бриф передан/записан | ≥ `path_lines_min` строк-путей и ни одной строки правила/перечислителя | WARN |
| B  | SendMessage, текст с головы `РЕШЕНИЕ` | нет `основани` или нет референта (`путь:строка`, `.log`/`.md`/`.diff`, sha ≥ 7 hex) | REFUSE |
| C1 | SendMessage (любой) и отчёт записан | фраза легализации вне заборов | REFUSE |
| C2 | SendMessage (любой) и отчёт записан | `Selected worker:` как свидетель без `[RCH] remote` | WARN |
| F  | Bash | `git commit` без `--only`; `git push` без `origin <ветка>:<ветка>` или с `--force`/`-f`/`--force-with-lease`; в тексте коммита трейлеры `Session:` и `Co-Authored-By:` не соседние | REFUSE |

События-источники (все — ДО исполнения инструмента, на сайте диспетчера):

| инструмент | что оценивается |
|---|---|
| `Agent`/`Task` | каждый путь `*brief*.md`, названный в `prompt` (до 4 уникальных) — файл читается с диска |
| `SendMessage` | пути `*brief*.md` в `message` (как выше); сам `message` — классы B, C1, C2 |
| `Write` | `file_path` рода «бриф» → `content` как будущий файл (A1–A4); рода «отчёт» → C1, C2 |
| `Edit` | пост-состояние файла: текущее содержимое с заменой `old_string`→`new_string` (все вхождения при `replace_all`, иначе первое); классы по роду файла |
| `Bash` | F по тексту команды; плюс heredoc-запись в файл рода «бриф»/«отчёт» (`> путь <<'EOF' … EOF`, `>>`, `tee`, `tee -a`) — тело heredoc как будущий файл (`>>`/`tee -a` — текущий файл + тело) |

Род файла: «бриф» = путь по `brief_path` И голова (первая строка) по
`brief_head`; «отчёт» = путь по `report_path`. Файл рода «бриф» без совпадения
головы — не бриф: классы A к нему не применяются, путь попадает в поле
`skipped` строки журнала.

Решения:

1. Носитель — ядро `__ccProbe`, третий вызов на сайте наблюдателя (тот же
   `SLOT`, тот же `resolveFor`), блок вставляется ПЕРЕД блоком наблюдателя
   (проба формы оценивает текущий вызов раньше, чем наблюдатель читает её
   таблицу).
2. Вердикт детерминированный: модель НЕ вызывается (правило №7 спеки реестра —
   механически решаемое условие модели не отдаётся). Ядро получает новый хук
   `__o.rules` и по его вердикту минует сборку контекста и лестницу.
3. Правила — ДАННЫЕ: все регулярки, пороги, режимы `act` и тексты отказов живут
   в `probes/probes.toml` под `[probe.form]`; в коде нет ни одной регулярки
   классов и ни одного слова из списков (в блоке пробы формы не встречаются
   литералы `cargo`, `RCH_REQUIRE_REMOTE`, `Selected worker`, `выбери`,
   `as-is`, `--only`). Отсутствующий ключ = сломанные настройки (`broken`), не
   тихий дефолт.
4. Режимы `act` по классам: `log_only` (только журнал), `warn` (уведомление в
   очередь `task-notification`, как у наблюдателя), `cancel` (вызов отменён
   броском с `__ccJudgeBlock`, как у судьи). Класс с вердиктом WARN (A4, C2)
   при `cancel` ведёт себя как `warn` — предупреждение никогда не отменяет.
   Дефолт всех классов — `log_only` (инкубация на живом трафике; включение
   `cancel` — правкой конфига, без пересборки образа).
5. Включатель: `CLAUDE_FORM` не задан или пуст → проба ВКЛЮЧЕНА; `0|false|off|no`
   → выключена; любое другое значение — включена (значение попадает в `sw`).
   Отличие от `CLAUDE_JUDGE`/`CLAUDE_IDLE` (там пусто = выключено) намеренное:
   инкубации нужен трафик, а стоковые файлы пользователя (`settings.json`) под
   наши данные не правятся.
6. `arm:!0` в коде, `fail_closed = false` в конфиге: сбой правил пишется в
   журнал как `skip_degraded`, вызов идёт; переключение на отказ при сбое —
   конфигом.
7. Журнал `~/.claude/probes/form/journal.jsonl` — одна строка на ОЦЕНКУ
   (знаменатель), включая `pass`; records — только по срабатываниям
   (`record:false` для PASS). Каталог создаёт ядро (`:2757` — `mkdir` перед
   `appendFile`).
8. Читатель журнала для живой сессии — наблюдатель: его `payload` несёт блок
   `form` (оценок с прошлого тика, срабатываний по классам, последние строки с
   цитатами, число поломок). Источник — процессное состояние
   `globalThis.__ccForm`, а не чтение файла. Курсор окна сдвигается ТОЛЬКО
   после разобранного вердикта советника — новый хук ядра `__o.onVerdict`
   (вызывается после записи строки журнала о вердикте и до `onAct`).
9. Одни байты правил — в образе и на стенде: стенд вырезает блок пробы формы
   из ОБРАЗА (как судью и наблюдателя) и гоняет сценарии через него; режим
   `--form-replay` гоняет ту же функцию оценки по файлам корпуса.
10. Грубый фильтр `pre` (без диска и конфига) — константы кода: пять имён
    инструментов и подстроки-предметы классов (`brief`/`report` + `.md`,
    `git commit`/`git push`); это ПРЕДМЕТЫ классов, а не настраиваемые формы.
    Формы — в конфиге.

## §1 Факты (по дереву `9db078a`)

`tweakcc-patch.js`:
- `const core =` — `:2348`; первая строка ядра `:2362-2364`
  (`'/*__ccCore0*/globalThis.__ccMono??=…'`, `'globalThis.__ccProbe??=async function(__o){'`);
  конец ядра `:3716` (`'/*__ccCore1*/'`).
- `__o.pre` — `:2372`: `'if(__o.pre){let __pr=null;try{__pr=__o.pre()}catch{__pr=null}if(__pr)return}'`
  (выход до диска и до конфига, без строки журнала).
- Головной `let` ядра — `:2406`: `'let __t0=globalThis.__ccMono(),__jfs=null,__jrec=!0,__jgz=!1,__jkeep=500,__nseen={},' +` —
  тот же список (комментарий `:2447`) объявляет `__jtry`, `__deg`, `__jdir` и
  остальные переменные журнала (`__jst`, `__jreq`, `__jres`, `__jurl`,
  `__jatt`, `__jm`, `__jerr1`, `__degb`).
- `__seq` — `:2405`. `__jsave` — `:2617-2644`, страж
  `'if(!__jrec||!__jreq||!__jfs)return null;'`; имя записи
  `{ISO с : и . → -}-{последние 8 знаков key|nokey}-{pid}-{seq 6 цифр}.json`;
  тело: `{...__base,rx,act,http,url,pid,cwd,attempts,request:JSON.parse(__jreq),response:__jres}`.
- `__jlog` — `:2712-2746`: базовые поля `t,sid,pid,title,tool,agent,model,msrc,cfg,ms,sw` + `__oc`;
  строки режутся до 400, массивы до 8 (`__dcut`), объекты — JSON до 400.
  `mkdir(__jdir,{recursive:!0})` перед `appendFile` — `:2757`.
- `__svc={log:__jlog,clip:__clip,num:__num,list:__lkr}` — `:2777`.
  `__num=(__k,__v,__d,__min,__q,__cap)` — `:2450`; `__lkr=(__k,__v,__d,__e0)` — `:2533`.
- Дом проб — `:2548-2553`: `__phome=__o.dirEnv||((CLAUDE_CONFIG_DIR||HOME+"/.claude")+"/probes")`, `__jdir=__phome+"/"+__o.dirName`.
  Слой проекта — `:2815-2848` (обход предков cwd до 24, выключается `__o.dirEnv`).
- Чтение TOML — `:2874-2879`: `__ldt` через `globalThis.Bun.TOML.parse`
  (полный TOML: литеральные строки `'…'` и `'''…'''` несут бэкслеши как есть).
  Слияние — `:2888-2900`: `__eff=(__t,__id)=>({...(__t.defaults||{}),...((__t.probe||{})[__id]||{})})`,
  затем слой проекта поверх. Ключи ядра: `enabled` `:2903`, `disabled_memo_ms`
  `:2904`, `record` `:2915`, `record_gzip` `:2916`, `records_keep` `:2917`,
  `filter` `:2919` (читает `__o.input?.prompt` и `subagent_type` — у пробы
  формы ключа `filter` в конфиге НЕТ), `enforce`/`fail_closed` `:3043-3044`,
  `__jarm` `:3045`.
- `__ask` — `:2918` (`let __ask=!0;`), `gate` — `:2959-2962` (строка журнала
  `outcome:"filtered",by:…` на каждый отказ gate — у пробы формы `gate` НЕ
  используется, чтобы не плодить строк).
- `__uw` — `:2969`. Сборка контекста начинается `:3190`:
  `'let __max=__num("context_chars",__cfg.context_chars,60000,60);' +`,
  `:3191` `'let __ctx=__cut(__max);' +`. Лестница: `__mdls` `:3344-3348`,
  цикл `:3599-3620`, повтор `:3622-3647`; `:3598` — `'let __raw=null,__v="",__errs=[];' +`;
  `:3648` — `'__jerr1=__errs.join(" | ")||null;' +`.
- Деградация — `:3582-3597` (`if(__degb.length&&__en){… __o.onBroken … return}`).
- Хвост реакции — `:3664-3699`: `__bl` (regex по `__o.act`, флаг `mi`),
  `__fc`, `__ocw`, `__jlog({http:__jst,outcome:…,en:…,tries:__jtry,jm:__jm,err1:__jerr1,verdict:…})` `:3680-3686`,
  `if(__fc)await __o.onNoVerdict(…)` `:3695`, `if(__bl&&__en)await __o.onAct(__bl[1].trim(),__svc);` `:3696`,
  `__jarm=!1;` `:3699`; внешний catch `:3700-3708` (перебрасывает `__ccJudgeBlock`).
- Поля `__o`, которые читает ядро сегодня (28): pre, dirEnv, dirName, input,
  ctx, key, rx, act, tag, tool, sw, turn, turnLost, gate, selfId, arm, payload,
  label, promptEnv, fb, modelEnv, urlEnv, tmoEnv, dbg, onBroken, onNoVerdict,
  onAct, onFail. Новых полей этой волны два: `rules`, `onVerdict`.
- Локатор сайта диспетчера — `:2148-2169` (`SLOT={$2:TOOL,$3:input,$4:ctx,$5:key}`);
  `resolveFor` — `:3912-3925` (каждый `$n` из `slots` обязан быть использован, лишний — отказ).
  `TV`/`DI` (очередь уведомлений / id сессии) — `:2323-2328`.
- `judgeCall` — `:3737-3772`; `watchCall` — `:3787-3896` (guard `CLAUDE_IDLE`,
  `pre` по `__ccWatch.nextAt`, `gate` с окнами, `payload`, `onAct` через
  `TV({value:"[fleet-idle] "+__r+…,mode:"task-notification",agentId:DI(),priority:"next"})`).
- Сплайс — `:3937-3975`: `watchBlock='/*__ccProbe0*/'+resolveFor(core+watchCall,SLOT,'watcher')+'/*__ccProbe1*/'`,
  `edits=[{at:m.index,len:0,text:watchBlock},{…judge…}]`. Заголовки шагов:
  `'21 current turn reachable at tool dispatch'` `:2081`,
  `'22 judge consulted before a subagent dispatch'` `:2205`.
- В стоковом образе сайт один: `try{vn=await e.call(Oe,{...o,toolUseId:n,userModified:Ht.userModified??!1},f,p,U)}finally{…}`;
  вставка идёт после `try{` — бросок из пробы обрабатывается тем же путём, что
  бросок из самого инструмента (ошибка становится error-tool_result).

`claude-patch-all.sh`:
- Проверки — `checks = {` `:4421`, `EXPECTED_CHECKS = 119` `:5681`. Перед
  проверками копии ядра схлопываются: `:4415-4419`
  `_probe_dup = re.findall(rb'/\*__ccCore0\*/[\s\S]*?/\*__ccCore1\*/', d)` и
  `for _b in _probe_dup[1:]: d = d.replace(_b, b'', 1)` — третья копия ядра
  схлопывается этим же циклом, проверка «exactly one probe core survives the
  collapse» (`:4645`) остаётся зелёной без правки.
- Проверка «each probe fallback prompt speaks its own vocabulary» (`:4657`) —
  присутствие `__sys=__o.fb}` и форм `act:"BLOCK|STOP|DENY",fb:"You judge one…`,
  `act:"NUDGE",fb:"You watch…`; третий блок ей не мешает (в T2 она получит
  третью форму).
- Стенд проб вызывается `:6109-6111`: `bun "$BENCH" --binary "$BIN"`;
  гейт раскатки — `:1648-1662`: `scripts/probes-sync.sh --diff` (кит против
  `~/.claude/probes`; расхождение = красный конвейер с подсказкой `--to-home`).
- Владельцы чисел (`:1701-1729`): probe-bench —
  `r'^const EXPECTED_SCENARIOS = (\d+);$'` и `r'^const EXPECTED_MUTATIONS = (\d+);$'`.
  Дома числа сценариев стенда: `tools/probe-bench.js:1052` (`82`),
  `claude-patch-all.sh:6087` (`# and drives probe-bench's 82 scenarios through a throwaway probes home —`),
  `tools/docnum-mutations.tsv:28` (`D4	tools/probe-bench.js	const EXPECTED_SCENARIOS = 82;	const EXPECTED_SCENARIOS = 83;	владелец probe-bench`).
  Дома числа мутаций стенда: `tools/probe-bench.js:1060` (`5`), `README.md:122`
  (`probe-bench's 5 recorded mutations`), `tools/docnum-mutations.tsv:65`
  (`D36	README.md	probe-bench's 5 recorded mutations	probe-bench's 6 recorded mutations	объявлено «5 mutations» (владелец probe-bench)`).

`tools/probe-bench.js`:
- Маркеры `/*__ccProbe0*/`…`/*__ccProbe1*/` — `:23-24`; `carveBlocks` `:117-133`;
  `classifyBlocks` `:142-155` (`WATCH_MARK='[fleet-idle] '`, ровно один judge и
  один watch — третий блок сегодня считался бы вторым judge и ронял стенд);
  `locateNames` `:174-215` (слоты `tool:…,input:…,ctx:…,key:…`, `__pool`,
  `agentId`, `sessionTitle`, для watch — очередь по `[fleet-idle] `).
- `ENV_KEYS` `:25`; `baseConfig` `:250-261`; `scenarios = [` `:336`;
  `EXPECTED_SCENARIOS = 82` `:1052`; `EXPECTED_MUTATIONS = 5` `:1060`;
  `homeName` `:1104-1106`; `setScenarioEnvironment` `:1124-1132` (HOME
  переопределён всегда; `CLAUDE_PROBES_DIR=tempDir` без слоя проекта);
  `CHECKS` — массив компараторов `{key, ok, got}` (`passed`, `outcome`, `sid`,
  `poolCalls`, `nudges`, `nudgeIncludes`, `errorIncludes`, `recordCount`,
  `journalLines`, `degStartsWith`, `dispatchIncludes`, …), неизвестный ключ
  ожидания — отказ стенда; `tempDir = mkdtempSync(…'probe-')` `:1431`;
  `{{DIR}}` в `dispatchPrompt` подменяется абсолютным путём каталога фикстур
  `:1581-1587`; сборка сумки сценария `:1589-1663`
  (`tool={name:scenario.toolName||'Agent'}`, `input`, `context` с
  `agentContext:{agentType:'main'}`, `toolUseId:'tool-use-1'`); запуск `:2048`
  (`probes[scenario.probe==='watch'?'watch':'judge']`); `SELF_CHECK_MUTATIONS`
  `:1861-1911` (`{name,poison:{from,to},controlRc,controlCause,mutation:{from,to}}`
  — семантика: `poison` обязан покраснить стенд с `controlRc`/`controlCause`,
  `mutation` компаратора обязана эту красноту ПРОГЛОТИТЬ; так доказывается, что
  компаратор несёт нагрузку; новые записи — строго по этой семантике).

`probes/probes.toml`: `[defaults]` `:1-6` (`max_tokens`, `timeout_ms`,
`enforce = true`, `context_chars`, `retry_context_chars`); `[probe.judge]` `:8-77`;
`[probe.idle-watch]` `:79-107` (файл кончается на `:107`).

`probes/idle-watch/prompt.md` (99 строк): `# СНАЧАЛА ИЩИ ПРИЧИНУ МОЛЧАТЬ` `:16`,
`# ПОТОМ ИЩИ ПРЕДМЕТ` `:43`, `# ФОРМАТ ОТВЕТА` `:63`, `# ЛЕНТА` `:83`,
последняя строка `:99` — `<!-- END OF RULES -->`. Вход советника — `=== FLEET ===`
с JSON `payload` (`spawns_in_window`, `window_min`, `live_works`,
`task_registry_readable`, `current_tool`).
`probes/judge/prompt.md` (347 строк, заголовков `#` нет): последняя строка
`:347` — `<!-- END OF RULES -->`.

Корпус и сборка: стоковый образ 259 —
`~/.local/share/claude-patch/corpus/2.1.259.pristine`, пин
`tools/corpus-versions.txt:40` (`259 2.1.259 884baa38fe1a624be25c4a91568bf5a08b5cf4e7d7acf29b7760e3525d964898`).
Свип строит версию так (`tools/sweep.sh:1035-1041`):

```
env -u CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES -u CLAUDE_PATCH_SKIP_BENCH \
    -u CLAUDE_PATCH_GATE_BUDGET -u CLAUDE_PATCH_SIGN_ID -u TWEAKCC_LOCAL \
    -u CATALYST_TWEAKCC_REPO -u CATALYST_TWEAKCC_SHA \
    -u CLAUDE_PATCH_PROBE_CFG_LOAN \
  CLAUDE_PATCH_SKIP_MODELS=1 CLAUDE_PATCH_FLOOR_IMAGE="$src" \
  bash "$HERE/claude-patch-all.sh" \
  --target "$STATE/bin/$v.wave.bin" --expect-sha "$want" > "$log" 2>&1 8>&-
```

(`$src` — pristine-образ, `$want` — sha из пина, `$STATE=/tmp/cc-matrix`).
Установленный образ `~/.local/share/claude/versions/2.1.259` НЕ трогать.

## §2 Правки ядра (`tweakcc-patch.js`, внутри `const core`)

Все правки — строковые фрагменты в той же манере (одинарные кавычки, `+`).

2.1. Подъём объявления. Строку `:3598` `'let __raw=null,__v="",__errs=[];' +`
удалить там и поставить ПЕРЕД строкой `:3190` (`'let __max=__num("context_chars",…`).
Сразу после неё — хук правил:

```
'let __rl=null;' +
'if(__ask&&__o.rules&&!__degb.length){' +
  'try{__rl=await __o.rules(__cfg,__svc)}' +
  'catch(__re){__rl={broken:"rules-failed:"+__clip(String(__re?.message??__re),160)}}' +
  'if(__rl&&__rl.skip)return;' +
  'if(__rl&&__rl.broken){__deg.push(String(__rl.broken));__degb.push(String(__rl.broken))}' +
  'else if(__rl&&typeof __rl.verdict==="string"&&__rl.verdict){' +
    '__v=__rl.verdict;__jtry=0;__jm="rules";__jst=null;' +
    '__jreq=JSON.stringify(__rl.snapshot??null);__jres=__v;' +
    'if(__rl.record===!1)__jrec=!1}}' +
```

Контракт `__o.rules(__cfg,__svc)` → `null` (правил нет — идёт лестница) |
`{skip:"<причина>"}` (не предмет — выход без строки журнала, как `pre`) |
`{broken:"<причина>"}` (настройки сломаны — деградация тем же путём, что
нечитаемый слой: строка `skip_degraded`/`block_degraded`, `onBroken`) |
`{verdict:"<СЛОВО>: …", snapshot:<объект для records>, record:<bool>, extra:<объект — доп. поля строки журнала>}`.
Комментарий-констрейнт у хука: «вердикт правил минует сборку контекста и
лестницу: механически решённое условие модели не отдаётся (спека реестра, №7);
`__degb` проверяется ДО правил — сломанные настройки идут в деградацию, а не в
оценку по обломку конфига».

2.2. Обход. Перед строкой `:3190` (уже после хука) — `'if(!__v){' +`;
после строки `:3647` (последняя строка блока повтора,
`'__clip(__ce?.message??__ce,80))}}' +`) и ПЕРЕД `:3648`
(`'__jerr1=__errs.join(" | ")||null;' +`) — `'}' +`. Внутри обёрнутого блока
остаются сборка контекста, промт, лестница, `__call`, `__pv`, деградация,
цикл и повтор — все их `let` используются только внутри; хвост `:3648-3699`
читает лишь переменные головного `let` и `__v`.

2.3. Дополнительные поля строки журнала. В вызове `__jlog` `:3680-3686` после
`'verdict:__clip(__v,400)||null'` добавить
`',...(__rl&&__rl.extra&&typeof __rl.extra==="object"?__rl.extra:{})'` (перед
закрывающей `})`). Поля `extra` режутся тем же `__jlog` (строки 400, массивы 8).

2.4. Хук `onVerdict`. После `__jlog` `:3686` (после `}catch{}`) и ПЕРЕД
`:3695` (`'if(__fc)await __o.onNoVerdict(…`) вставить
`'if(__v&&__o.onVerdict)try{await __o.onVerdict(__v,__svc)}catch{}' +` —
вызывается только при разобранном вердикте и только после записи строки
журнала; бросок из него не отнимает `onAct`.

2.5. Ничего другого в ядре не менять; байты фрагментов `:3664` (`__bl`),
`:3670` (`__fc`), `:3679` (`__ocw`), `:3695-3699` остаются как есть — на них
стоят проверки конвейера.

## §3 Потребитель `formCall`

Определяется в `tweakcc-patch.js` рядом с `watchCall` (перед ним), по образцу
`watchCall` `:3787-3896`, со слотами `$2` tool, `$3` input, `$4` ctx, `$5` key
(все четыре обязаны быть использованы — `resolveFor`).

3.1. Guard (по форме наблюдателя, с иным умолчанием — решение 5):

```
'if((()=>{let __s=String(process.env.CLAUDE_FORM??"").trim().toLowerCase();return !(__s==="0"||__s==="false"||__s==="off"||__s==="no")})()&&$4?.agentContext?.agentType==="main")' +
'await globalThis.__ccProbe({' +
  'tag:"[Form]",dirName:"form",arm:!0,label:"FORM",' +
  'rx:"PASS|WARN|REFUSE",act:"REFUSE|WARN",' +
  'fb:"Deterministic form probe: no model is consulted; the verdicts PASS, WARN and REFUSE come from configured rules.",' +
  'sw:process.env.CLAUDE_FORM,dirEnv:process.env.CLAUDE_PROBES_DIR,' +
  'dbg:process.env.CLAUDE_FORM_DEBUG,' +
  'tool:$2,input:$3,ctx:$4,key:$5,' +
  'pre:…, rules:…, onAct:…, onBroken:…, onNoVerdict:()=>{}, onFail:()=>{}' +
'});'
```

3.2. Состояние процесса `globalThis.__ccForm` (создаётся в `pre` при первом
вызове): `{seen:0, evals:0, evalsAt:0, fired:[], cursor:0, cursorIso:null, broken:0, brokenAt:0}`.
`seen` — вызовы инструментов-предметов; `evals` — записанные оценки;
`fired` — кольцо ≤ 64 записей `{t:<__ccMono>, iso, cls, tool, out, q}` по одной
на срабатывание класса (класс, инструмент, `refuse|warn`, первая цитата ≤ 160
знаков); `cursor`/`evalsAt` — отметка последнего разобранного вердикта
советника; `broken`/`brokenAt` — счёт и время последней поломки настроек.

3.3. `pre` (без диска, без конфига):
- имя инструмента не из `Agent|Task|SendMessage|Write|Edit|Bash` → `"not-subject"`;
- `seen++`;
- `brokenAt` моложе 600000 мс → `"broken-memo"` (сломанные настройки не
  перепроверяются на каждом вызове; после починки — не позже 10 минут);
- `SendMessage` → `null` (оценивается всегда);
- `Bash`: команда содержит `git commit`/`git push` (по `/git\s+(?:commit|push)\b/`)
  ИЛИ (`/brief|report/i` И `/\.md\b/`) → `null`, иначе `"not-subject"`;
- `Write`/`Edit`: `file_path` по `/brief|report/i` → `null`, иначе `"not-subject"`;
- `Agent`/`Task`: `prompt` содержит `/brief/i` И `/\.md\b/` → `null`, иначе `"not-subject"`.

3.4. `rules(__cfg,__svc)`:
- собрать `__c` — таблицу правил из `__cfg` (ключи §4); для каждого
  обязательного ключа (§4) отсутствие/пустота → `{broken:"form-rule-missing:<ключ>"}`
  и `__ccForm.broken++`, `brokenAt=now`; таблицы `act`/`text` — при отсутствии
  класса `log_only` / пустая строка (это режимы, не формы);
- собрать события по инструменту (таблица §0): для `Agent`/`SendMessage` —
  извлечь пути по `brief_ref` из `prompt`/`message` (уникальные, до 4; `~` →
  `HOME`; относительный → `process.cwd()`), прочитать каждый через
  `fs/promises`; нечитаемый — `deg`-запись `brief-unreadable:<путь>` в `extra.deg`
  (не поломка); для `Edit` — прочитать файл и построить пост-состояние; для
  `Bash` — heredoc по `heredoc`, цель по `write_redirect`; команда без
  heredoc-записи и без `git commit`/`git push` → `{skip:"not-subject"}`;
- для каждого события вызвать чистую функцию `globalThis.__ccFormEval(ev,__c)`
  (3.6) и род файла `globalThis.__ccFormKind(path,text,__c)` (3.7);
- сложить: `refuse=[…]`, `warn=[…]` (каждая запись `{c,n,q,src}` — класс,
  номер строки, цитата ≤ 160, источник — путь/`message`/`command`);
- вердикт: `refuse.length` → `"REFUSE: "+<классы с числом, напр. "A2×3, A3×1">+" — "+<метка события>+" — "+<первая запись: "A2 :192: <цитата>">`;
  иначе `warn.length` → `"WARN: …"` по той же форме; иначе `"PASS: "+<метка>`.
  Метка события — `<инструмент>:<путь|message|command>`;
- `extra`: `{ev:<инструмент>, cls:[уникальные классы], fired:[{c,n,q,src}…], skipped:[пути рода-по-пути без головы], deg:[…]}`
  (пустые массивы не класть);
- `snapshot` (только при срабатывании; при PASS — `record:false`):
  `{ev, tool, sources:[{src, kind, size}], refuse, warn, text:<первое оценённое тело, клип 40000>}`;
- обновить `__ccForm`: `evals++`; на каждое срабатывание — запись в `fired`
  (кольцо 64);
- запомнить в `__ccForm.last={cls, act:<таблица act>, text:<таблица text>, verdictKind:"refuse"|"warn"|"pass"}` для `onAct`;
- вернуть `{verdict, snapshot, record, extra}`.

3.5. `onAct(__r,__svc)`: режим = самый строгий из `act[класс]` по сработавшим
классам (`cancel` > `warn` > `log_only`). `verdictKind==="refuse"` и режим
`cancel` → бросить `Error` с `__ccJudgeBlock=!0` и текстом
`"Вызов инструмента отменён пробой формы (это НЕ гейт маршрутизации hooks/routing-table.toml). "+__r+" Правило: "+<text[класс] первого сработавшего класса>`.
Иначе, режим `warn` или (`cancel` при `verdictKind==="warn"`) → уведомление
через тот же канал, что у наблюдателя:
`TV({value:"[form] "+__r+"\n(Проба формы, не гейт: решаешь ты. Правило: "+<text>+")",mode:"task-notification",agentId:DI(),priority:"next"})`,
при сбое доставки — `__svc.log({outcome:"warn_undelivered",reason:…})`.
`log_only` → ничего. Все русские строки в JS — как `\u`-эскейпы, по образцу
`watchCall`.
`onBroken(__r,__svc)`: `__ccForm.broken++`, `brokenAt=now`; уведомление
`"[form] проба формы выключена на 10 минут: настройки сломаны ("+__r+")"` тем
же каналом (одно на поломку — memo из `pre`).

3.6. Чистая функция `globalThis.__ccFormEval??=(ev,c)=>{…}` (объявляется в
`formCall` ДО вызова `__ccProbe`, снаружи объекта; регулярки компилируются из
строк `c[ключ]` с флагами из §4 и кэшируются в `globalThis.__ccFormRx` по
строке). Вход: `{kind:"brief"|"report"|"message"|"command", text, path?}`.
Выход: `{refuse:[{c,n,q}], warn:[{c,n,q}]}`. Строки текста — по `\n`;
заборы — строки по `fence` переключают состояние; всё внутри забора не
оценивается классами A3, B, C (A1 смотрит последнюю непустую строку файла
как есть; A2 оценивает строки внутри заборов целиком как команды).

- `kind:"brief"`:
  - A1: последняя непустая строка (после `trimEnd`) ≠ `brief_tail` → `{c:"A1", n:<номер той строки>, q:<строка>}`;
  - A2: кандидаты — строки внутри заборов (вся строка) и, вне заборов, тела
    инлайн-спанов `` `…` `` в строках по `arm_line`; у кандидата снять
    `arm_ellipsis` (пометив `ell=true`), проверить `arm_cmd`; арма без
    `arm_remote` ИЛИ без `arm_log` ИЛИ с `ell` → `{c:"A2", n, q:<кандидат>}`;
    если арм ≥ 1 и во всём тексте нет `witness_remote` →
    `{c:"A2", n:0, q:"арма есть, свидетель [RCH] remote не назван"}`;
    если во всём тексте есть `witness_worker` → `{c:"A2", n:<строка>, q:<строка>}`;
  - A3: вне заборов, по каждой строке первое совпадение `open_door`; совпадение
    отбрасывается, если `negation` совпадает с 16 знаками текста перед ним →
    `{c:"A3", n, q:<строка>}`;
  - A4 (warn): число строк по `path_line` ≥ `path_lines_min` и ни одной строки
    по `rule_line` → `{c:"A4", n:0, q:"строк-путей <N>, строки правила нет"}`;
- `kind:"report"`: C1 — вне заборов первое совпадение `legalize` в строке →
  `{c:"C1", n, q}` (refuse); C2 (warn) — есть `witness_worker` и нет
  `witness_remote` → `{c:"C2", n:<строка witness_worker>, q}`;
- `kind:"message"`: B — если текст по `decision_head`: нет `decision_basis` ИЛИ
  нет `decision_referent` → `{c:"B", n:1, q:<первая строка>}`; C1, C2 — как у отчёта;
- `kind:"command"`: F — если `git_commit` совпал: нет `git_commit_ok` →
  `{c:"F", n:1, q:"git commit без --only"}`; текст коммита — все совпадения
  `git_msg` (группы 1|2|3) как абзацы через `\n\n`, либо тело heredoc при
  `-F -`/`<<`; строки по `trailer_a` и `trailer_b`: обе есть и не соседние
  (модуль разности индексов строк ≠ 1) →
  `{c:"F", n:<строка первого трейлера>, q:"трейлеры Session: и Co-Authored-By: не соседние"}`;
  если `git_push` совпал: нет `git_push_ok` → `{c:"F", n:1, q:"git push без refspec origin <ветка>:<ветка>"}`;
  есть `git_force` → `{c:"F", n:1, q:"git push с принудительной формой"}`.

3.7. `globalThis.__ccFormKind??=(path,text,c)=>` — `"brief"` если путь по
`brief_path` и первая строка текста по `brief_head`; `"report"` если путь по
`report_path`; иначе `null`.

3.8. Уведомления и бросок: имена `TV` и `DI` — те же константы модуля, что у
наблюдателя (`:2323-2328`).

## §4 Правила как данные — `[probe.form]` в `probes/probes.toml`

Дописать в конец файла (после `:107`), дословно:

```toml

[probe.form]
fail_closed = false
records_keep = 300
brief_path = '(?:^|/)(?:\.r17-briefs|\.briefs|docs/review)/[^/]*brief[^/]*\.md$'
brief_ref = '[\w@.~/+-]*brief[\w@.+-]*\.md'
brief_head = '^#\s*(?:бриф|brief|#\d+(?![\w-])|task-\d+(?![\w-]))'
brief_tail = '<!-- BRIEF COMPLETE -->'
report_path = '(?:^|/)[^/]*report[^/]*\.md$'
fence = '^\s*(?:```|~~~)'
arm_line = '^\s*(?:[-*+]|\d+[.)]|\|)\s'
arm_ellipsis = '^\s*(?:…|\.\.\.)\s*'
arm_cmd = '^(?:[A-Z_][A-Z0-9_]*=\S+\s+)*(?:rch\s+exec\s+(?:--\s+)?)?(?:[A-Z_][A-Z0-9_]*=\S+\s+)*cargo\s+(build|test|check|clippy|doc|bench)(?=\s|$)'
arm_remote = 'RCH_REQUIRE_REMOTE=1\s+rch\s+exec'
arm_log = '>\s*\S+\s+2>&1'
witness_remote = '\[RCH\] remote'
witness_worker = 'Selected worker:'
open_door = '(?<![\p{L}\p{N}_])(?:выбери|реши|на (?:твоё|ваше) усмотрение|если нужно|при необходимости|выясни|определи сам|проверь, (?:что|нужно ли)|verify|investigate|choose|decide|if needed|as appropriate|as you see fit)(?![\p{L}\p{N}_])'
negation = '(?:nothing to|no|not|never|нечего|ничего не|не)\s*$'
rule_line = 'правил|rule|перечислител|enumerat|cargo check --all-targets|grep -r|(?<!\S)rg\s'
path_line = '^\s*(?:[-*]\s*)?`?[\w@.+-]+(?:/[\w@.+-]+)+\.\w+`?\s*(?:[—–-].*)?$'
path_lines_min = 10
decision_head = '^\s*РЕШЕНИЕ(?![\p{L}\p{N}_])'
decision_basis = 'основани'
decision_referent = '(?:\S+:\d+|\S+\.(?:log|md|diff)(?![\w-])|(?<![\w/])[0-9a-f]{7,40}(?![\w/]))'
legalize = 'принять ограничение|accept(?:ed)? (?:the )?limitation|известное ограничение|оставляем как есть|deferred|отложено до|workaround|не чиним|(?<![\w-])as-is(?![\w-])'
git_commit = '(?<![\w.-])git\s+commit(?![\w-])'
git_commit_ok = '(?<!\S)--only(?!\S)'
git_msg = '''(?<!\S)-m\s*(?:"([^"]*)"|'([^']*)'|(\S+))'''
git_push = '(?<![\w.-])git\s+push(?![\w-])'
git_push_ok = '(?<!\S)origin\s+[\w./-]+:[\w./-]+(?!\S)'
git_force = '(?<!\S)(?:--force(?:-with-lease)?|-f)(?!\S)'
trailer_a = '^Session:'
trailer_b = '^Co-Authored-By:'
write_redirect = '''(?:>>?|tee(?:\s+-a)?)\s*["']?([^\s"'<>|;&]+\.md)'''
heredoc = '''<<-?\s*["']?(\w+)["']?[^\n]*\n([\s\S]*?)\n\1(?:\n|$)'''

[probe.form.act]
A1 = "log_only"
A2 = "log_only"
A3 = "log_only"
A4 = "log_only"
B = "log_only"
C1 = "log_only"
C2 = "log_only"
F = "log_only"

[probe.form.text]
A1 = "бриф без хвостового маркера <!-- BRIEF COMPLETE --> последней непустой строкой — обрыв всегда выглядит самосогласованным"
A2 = "каждая арма cargo — только RCH_REQUIRE_REMOTE=1 rch exec -- … > <лог> 2>&1, свидетель площадки — строка [RCH] remote; Selected worker: свидетелем не является"
A3 = "исполнительский бриф не несёт открытых дверей: решения принимаются до диспатча"
A4 = "перечень путей без строки правила или перечислителя — перечень окажется неполным"
B = "решение без основания и референта (файл:строка, лог, диф, sha) не принимается"
C1 = "найденную проблему чинить всегда и полно; частичный фикс — только по ЯВНОМУ слову юзера"
C2 = "свидетель удалённой сборки — строка [RCH] remote, а не Selected worker:"
F = "коммит только --only по явным путям; push только origin <ветка>:<ветка> без принудительных форм; трейлеры Session: и Co-Authored-By: соседними строками"
```

Флаги компиляции (фиксированы кодом, по ключу): `u` у всех; дополнительно `i`
у `brief_head`, `open_door`, `negation`, `rule_line`, `decision_basis`,
`decision_referent`, `legalize`; `m` у `trailer_a`, `trailer_b`; `g` только у
`git_msg` (обход `matchAll`), остальные — первое совпадение. Обязательные
ключи (их отсутствие = `broken`): все строковые ключи и `path_lines_min` из
`[probe.form]` выше, кроме `fail_closed`/`records_keep` (ключи ядра).

Комментарии в TOML — только констрейнты: над `brief_head` — что список голов
покрывает конвенции обоих потребителей (`# Бриф`, `# BRIEF #633`, `# #470 —`,
`# TASK-684 —`); над `open_door`/`legalize` — что границы слов сделаны
лукараундами по `\p{L}`, потому что `\b` в JS не знает кириллицы; над
`[probe.form.act]` — что `log_only` есть инкубация и `cancel` включается
здесь без пересборки.

После правки `probes/probes.toml` выполнить раскатку в дом кита:
`bash scripts/probes-sync.sh --to-home` (добавочная таблица; судья и
наблюдатель читают только свои таблицы). Без этого гейт раскатки в конвейере
красный.

## §5 Сплайс

В `tweakcc-patch.js` у сплайса `:3937-3975`: `formBlock='/*__ccProbe0*/'+resolveFor(core+formCall,SLOT,'form')+'/*__ccProbe1*/'`;
первая правка `edits` — `{at:m.index,len:0,text:formBlock+watchBlock}`
(проба формы перед наблюдателем). Заголовок шага — по той же форме, что
`'21 current turn reachable at tool dispatch'` (`:2081`) и
`'22 judge consulted before a subagent dispatch'` (`:2205`): строка
`'23 form probe rides the dispatcher ahead of the watcher'` рядом с шагом 21
(тот же список/та же форма объявления). Всё, что считает шаги (в §1 таких
домов не найдено), пересчитать по своему владельцу.

## §6 Наблюдатель — таблица `form` и курсор

В `watchCall`:
- `payload` дополнить полем `form`, считанным из `globalThis.__ccForm`
  (при отсутствии — `{enabled:false}`):
  `{enabled:true, seen, evals_since:evals-evalsAt, since:cursorIso??"session-start", by_class:{<cls>:<n>…}, last:[≤8 записей {cls,tool,out,q} с t>cursor], broken}`
  (`by_class` и `last` — только записи с `t>cursor`);
- добавить `onVerdict:()=>{let __s=globalThis.__ccForm;if(__s){__s.cursor=globalThis.__ccMono();__s.cursorIso=new Date().toISOString();__s.evalsAt=__s.evals}}`.

`probes/idle-watch/prompt.md`:
- после абзаца, кончающегося `…двумя-тремя конкретными словами из ленты — значит его нет, отвечай SILENT.` (`:61`) и ПЕРЕД `# ФОРМАТ ОТВЕТА` (`:63`) — раздел:

```
# ФОРМА ХОДОВ — ТОЖЕ ПРЕДМЕТ

Та же дисциплина: сперва причина молчать, потом предмет; предмет — только
словами ленты и блока `form`. Три класса формы, которые видно по ленте:

  - класс 4: последнее РЕШЕНИЕ агента не несёт референта (file:line, лог,
    диф, sha не короче 7 знаков);
  - класс 5: исправление ранее сказанного стоит хвостом, а не у места
    ложного утверждения;
  - класс 6: принятое ограничение («оставляем как есть», «известное
    ограничение», «workaround», «deferred») вместо замера или полного фикса.

Блок `form` во входе — счёт пробы формы с прошлого тика: `evals_since` —
сколько событий проба оценила (ноль при живой ленте с брифами, отчётами и
коммитами = проба молчит, а не чиста — назови это), `by_class` — срабатывания
по классам A1–A4, B, C1, C2, F, `last` — последние срабатывания с цитатами,
`broken` — поломки настроек, `enabled:false` — пробы в процессе нет. В ответе
NUDGE называй классы и цитаты из `last` дословно, не пересказывай.

Утверждение сессии о своей модели — не измерение; атрибуция модели — только
со слова человека (запись с `src":"user"`).
```

- в `# ЛЕНТА` (`:83`) после первого абзаца — одно предложение: «Блок `form`
  приходит внутри `=== FLEET ===` рядом с `spawns_in_window`.»

`probes/judge/prompt.md`: перед последней строкой `<!-- END OF RULES -->`
(`:347`) — абзац из одного предложения: «Утверждение сессии о своей модели —
не измерение; атрибуция модели — только со слова человека (запись с
`src":"user"`).» с пустой строкой до и после.

Оба промта — раскатка `probes-sync.sh --to-home` (тот же шаг, что §4).

## §7 Документ `docs/form-probe.md`

Новый файл (русский), разделы: назначение и семь классов (таблица §0);
события и точки срабатывания (таблица §0, с упоминанием, что всё — до
исполнения инструмента, сайт диспетчера, только `agentType==="main"`); род
файла; журнал — путь и форма строки (базовые поля ядра + `outcome`
`pass|warn|refuse|skip_degraded`, `tries:0`, `jm:"rules"`, `verdict`,
`ev`, `cls`, `fired`, `skipped`, `deg`, `rec`) с одним примером строки;
records; таблица `form` наблюдателя и правило курсора; режимы `act` и
инкубация; включатель `CLAUDE_FORM`; слой проекта (`<проект>/.claude/probes/probes.toml`,
`[probe.form]`); стенд и `--form-replay` (формат вывода §8.5); что проба НЕ
делает (не читает транскрипт, не вызывает модель, не правит вход). Добавить
строку в таблицу файлов `README.md` (рядом с `:120` `docs/idle-watch.md`):
`| docs/form-probe.md | проба формы: семь классов, события, журнал, таблица наблюдателя, реплей |`.

## §8 Стенд `tools/probe-bench.js`

8.1. Классификация: `FORM_MARK='tag:"[Form]"'`; `classifyBlocks` — три рода
`judge|watch|form` (блок с `FORM_MARK` → form, с `WATCH_MARK` → watch, иначе
judge), ровно по одному каждого. `locateNames` для form — как для watch
(очередь уведомлений по литералу `[form] ` в `onAct`).

8.2. Окружение: `ENV_KEYS` + `CLAUDE_FORM`, `CLAUDE_FORM_DEBUG`;
`setScenarioEnvironment`: `probe==='form'` → `process.env.CLAUDE_FORM=sw`;
`homeName` → `'form'`; `baseConfig` для form:
`{enforce:true, fail_closed:false, ...FORM_RULES}`, где `FORM_RULES` — таблица
`probe.form` из `probes/probes.toml` КИТА, прочитанная `Bun.TOML.parse`
(одни данные в образе и на стенде; копия регулярок в стенде запрещена).
Сценарий переопределяет поверх (`config:{act:{A1:'cancel'}}` — глубокое
слияние по таблицам `act`/`text`; `config:{arm_cmd:undefined}` удаляет ключ).

8.3. Фикстуры: поле сценария `files:{ '<относительный путь>': '<содержимое>' }`
пишется под `tempDir/work/` перед запуском; `{{DIR}}` в `dispatchPrompt`,
`message`, `command`, `filePath` подменяется на `tempDir/work` (расширить
существующую подмену `:1583-1587`). Сумка сценария: `toolName` из сценария;
`input` для form-сценариев строится по `toolName`: `Agent` — `{prompt, subagent_type, model}`;
`SendMessage` — `{to:'x', message}`; `Write` — `{file_path, content}`;
`Edit` — `{file_path, old_string, new_string, replace_all}`; `Bash` — `{command}`.

8.4. Результат и `CHECKS`: из строки журнала form-сценария в результат
попадают `outcome`, `cls`, `fired`, `skipped`, `deg`, `verdict`; новые ключи
ожиданий: `cls` (точное сравнение массивов через JSON), `firedIncludes`
(хотя бы одна запись `fired` с `q`, содержащей текст), `verdictIncludes`,
`skippedCount`, `rulesKeyIncludes`, `recordRequestIncludes`. `poolCalls` для
form-сценариев обязан быть `0` во всех сценариях (в 36/37 консультируется
наблюдатель — там `poolCalls` считается по нему).

8.5. Реплей: `bun tools/probe-bench.js --binary <образ> --form-replay <путь>…`
— обходит `.md` рекурсивно, род по `__ccFormKind` (бриф/отчёт; остальные
пропускаются с подсчётом), оценивает `__ccFormEval` с `FORM_RULES` кита; на
каждое срабатывание печатает `FORM <файл>:<n> <класс> <refuse|warn> :: <цитата>`;
в конце — `FORM REPLAY files=<всего .md> briefs=<B> reports=<R> other=<O> fired=<F> refuse=<X> warn=<Y>`.
Код выхода 0 при `briefs+reports ≥ 1`, иначе 5 (нечего мерить). В этом режиме
сценарии и self-check не запускаются.

8.6. Сценарии (имена дословно; все `probe:'form'` кроме 36/37; ожидания —
минимум как указано):

1. `form-not-subject` — `toolName:'Read'` → `journalLines:0`, `poolCalls:0`.
2. `form-a1-refuse-logonly` — `Agent`, prompt `бриф: {{DIR}}/.briefs/1-brief.md`, файл `# Бриф 1\n\nтело\n` → `passed:true`, `outcome:'refuse'`, `cls:['A1']`, `nudges:0`, `recordCount:1`.
3. `form-a1-cancel` — то же с `config:{act:{A1:'cancel'}}` → `passed:false`, `errorIncludes:'A1'` и `errorIncludes:'пробой формы'`.
4. `form-a1-warnmode` — `act:{A1:'warn'}` → `passed:true`, `nudges:1`, `nudgeIncludes:'A1'`.
5. `form-a1-pass` — файл с хвостом `<!-- BRIEF COMPLETE -->` → `outcome:'pass'`, `recordCount:0`.
6. `form-kind-head-not-brief` — путь `.briefs/2-brief.md`, голова `# Отчёт` → `outcome:'pass'`, `skippedCount:1`.
7. `form-a2-bare-arm` — строка списка `` - арма `cargo test -p x` `` → `cls:['A2']`, `firedIncludes:'cargo test -p x'`.
8. `form-a2-ellipsis` — `` - `… cargo test -p x > a.log 2>&1` `` → `cls:['A2']`.
9. `form-a2-prose-pass` — абзац вне списка «при чужом `cargo test --workspace` на воркере» + корректная арма в заборе + строка `[RCH] remote` → `outcome:'pass'`.
10. `form-a2-fenced-ok` — забор с `RCH_REQUIRE_REMOTE=1 rch exec -- cargo test -p x > a.log 2>&1` и `cargo fmt --check`, строка `[RCH] remote primary` → `outcome:'pass'`.
11. `form-a2-no-log` — забор с `RCH_REQUIRE_REMOTE=1 rch exec -- cargo check -p x` (без лога) → `cls:['A2']`.
12. `form-a2-witness-worker` — корректная арма, `[RCH] remote`, плюс строка `Selected worker: w1` → `cls:['A2']`, `firedIncludes:'Selected worker'`.
13. `form-a2-witness-missing` — корректная арма, без `[RCH] remote` → `cls:['A2']`, `firedIncludes:'свидетель'`.
14. `form-a3-open-door` — строка «форму выбери одну» → `cls:['A3']`.
15. `form-a3-negation-pass` — «nothing to choose», «не выбирай» → `outcome:'pass'`.
16. `form-a3-fenced-pass` — «выбери» только внутри забора → `outcome:'pass'`.
17. `form-a4-warn` — 10 строк-путей, без строки правила → `outcome:'warn'`, `cls:['A4']`.
18. `form-a4-rule-pass` — те же 10 строк + строка с `grep -r` → `outcome:'pass'`.
19. `form-multi-class` — файл с A1 и A3 → `outcome:'refuse'`, `cls:['A1','A3']`, `verdictIncludes:'A1×1'`.
20. `form-b-refuse` — `SendMessage`, `РЕШЕНИЕ: делаем так` → `cls:['B']`.
21. `form-b-pass` — `РЕШЕНИЕ: … основание: src/a.rs:12` → `outcome:'pass'`.
22. `form-c1-message-refuse` — `SendMessage`, «оставляем как есть» → `cls:['C1']`.
23. `form-c1-report-write-refuse` — `Write` `{{DIR}}/.briefs/3-report.md` с `workaround` вне забора → `cls:['C1']`.
24. `form-c1-fenced-pass` — фраза только в заборе → `outcome:'pass'`.
25. `form-c2-warn` — отчёт с `Selected worker:` и без `[RCH] remote` → `outcome:'warn'`, `cls:['C2']`.
26. `form-edit-poststate` — `Edit` брифа: `old_string` = маркер, `new_string` = маркер + `\nхвост` → `cls:['A1']`.
27. `form-bash-heredoc` — `Bash` `cat > {{DIR}}/.briefs/4-brief.md <<'EOF'\n# Бриф 4\nтело\nEOF` → `cls:['A1']`.
28. `form-bash-heredoc-append` — файл с маркером на диске, `cat >> … <<'EOF'\nхвост\nEOF` → `cls:['A1']`.
29. `form-f-commit-refuse` — `git commit -m x` → `cls:['F']`, `firedIncludes:'--only'`.
30. `form-f-commit-pass` — `git commit --only -m "x\n\nSession: s\nCo-Authored-By: a" -- a.rs` (в JS-строке — настоящие переводы строк) → `outcome:'pass'`.
31. `form-f-trailers-refuse` — `git commit --only -m "x" -m "Session: s" -m "Co-Authored-By: a"` (абзацы через пустую строку — не соседние) → `cls:['F']`, `firedIncludes:'соседние'`.
32. `form-f-push-force` — `git push --force origin main` → `cls:['F']`.
33. `form-f-push-bare` — `git push` → `cls:['F']`.
34. `form-f-push-pass` — `git push origin main:main` → `outcome:'pass'`.
35. `form-unreadable-brief` — prompt ссылается на несуществующий файл → `outcome:'pass'`, `degStartsWith:'brief-unreadable:'`.
36. `form-watch-table` — `probe:'watch'`, `toolName:'Read'`, состояние наблюдателя как у существующего сценария с консультацией; новое поле сценария `formBefore:['form-a1-refuse-logonly','form-a1-refuse-logonly']` — стенд прогоняет названные form-сценарии в том же процессе и с тем же `tempDir` ДО консультации; поле `ticks:2` — консультация дважды; ответ советника `SILENT: ok`; ожидания `dispatchIncludesAt:[['"by_class":{"A1":2}','"evals_since":2'],['"evals_since":0']]` (новый ключ CHECKS: список подстрок по тикам).
37. `form-watch-cursor-holds` — как 36, но ответ советника на первом тике — сбой канала (как в существующем watch-сценарии сбоя пула) → `dispatchIncludesAt:[['"evals_since":2'],['"evals_since":2']]`.
38. `form-config-missing-key` — `config:{arm_cmd:undefined}` → `outcome:'skip_degraded'`, `nudges:1`, `nudgeIncludes:'form-rule-missing:arm_cmd'`, `passed:true`.
39. `form-rx-literal-from-toml` — положительный контроль данных: `rulesKeyIncludes:{arm_remote:'\\s'}` (в строке правила ровно один бэкслеш перед `s`) + сценарий 10 как тело.
40. `form-records-snapshot` — сценарий 2 + `recordCount:1`, `recordRequestIncludes:'"refuse"'`.
41. `form-switch-off` — `switchValue:'off'` → `journalLines:0`.
42. `form-replay-counter` — вызов функции реплея (внутренней функции стенда, той же, что за `--form-replay`) на каталоге с 2 брифами (один без маркера) и 1 отчётом (с `as-is`) → сводка `files=3 briefs=2 reports=1 other=0 fired=2 refuse=2 warn=0` (ключ `replaySummary:'…'`).

Итого 42 записи в `scenarios`. `EXPECTED_SCENARIOS` = 82 + 42 = 124. Дома
числа (все три, одним набором правок): `tools/probe-bench.js:1052` → `124`;
`claude-patch-all.sh:6087` → `probe-bench's 124 scenarios`;
`tools/docnum-mutations.tsv:28` D4 → `const EXPECTED_SCENARIOS = 124;` /
`const EXPECTED_SCENARIOS = 125;`.

8.7. Self-check: две новые мутации в `SELF_CHECK_MUTATIONS` по форме и
семантике `:1861-1911`:
- `form-cls-comparator` — `poison`: в сценарии `form-a1-refuse-logonly`
  ожидание `cls:['A1']` → `cls:['A9']` (`controlRc:1`, `controlCause:'cls'`);
  `mutation`: компаратор `cls` → `ok: () => true` (проглатывает).
- `form-replay-summary` — `poison`: в сценарии 42 ожидаемое `fired=2` →
  `fired=3` (`controlRc:1`, `controlCause:'replaySummary'`); `mutation`:
  компаратор `replaySummary` → `ok: () => true` (проглатывает).
`EXPECTED_MUTATIONS` = 7; дома: `tools/probe-bench.js:1060` → `7`;
`README.md:122` → `probe-bench's 7 recorded mutations` (перечисление в той
же ячейке дополнить двумя словами про класс-компаратор и сводку реплея);
`tools/docnum-mutations.tsv:65` D36 → `probe-bench's 7 recorded mutations` /
`probe-bench's 8 recorded mutations`.

## §9 Границы, запреты, стоп-правило

`paths:` (запись только сюда): `tweakcc-patch.js`, `probes/probes.toml`,
`probes/idle-watch/prompt.md`, `probes/judge/prompt.md`, `tools/probe-bench.js`,
`docs/form-probe.md` (новый), `README.md` (только строка рядом с `:120` и
строка `:122`), `claude-patch-all.sh` (ТОЛЬКО `:6087` — число сценариев; блок
`checks` и `EXPECTED_CHECKS` НЕ трогать — это волна T2),
`tools/docnum-mutations.tsv` (только D4, D36). Дом кита `~/.claude/probes/` —
только через `bash scripts/probes-sync.sh --to-home`. Всё замеченное вне списка
— флагом в отчёт, не правкой.

Запрещено: коммиты (коммитит контроллер после личной верификации; изменения
остаются в рабочем дереве); правка установленного образа
`~/.local/share/claude/versions/*` и `~/.claude/settings.json`; новые регулярки
классов в коде; `git stash`/`reset`/`checkout` чужих правок; локальная сборка
чего бы то ни было кроме bun-стенда; `pkill`/`launchctl` над любыми демонами.

Стоп-правило: неожиданное падение или расхождение с брифом → одна честная
попытка → `BLOCKED` с сырым выводом (первые 60 строк) в отчёте, без глубокой
диагностики и без обхода. Ложная посылка брифа (факт §1 не сходится с деревом)
→ доказательство (`grep`/`sed -n` с выводом) и стоп.

## §10 Приёмка (все команды — из корня кита; выход по `set -o pipefail` или без пайпа)

1. Синтаксис патча: `node --check tweakcc-patch.js`.
2. Итерационная сборка (без установки): каталог `/tmp/w38`, команда — строка
   свипа из §1 с добавкой `CLAUDE_PATCH_SKIP_BENCH=1`, где
   `$src=$HOME/.local/share/claude-patch/corpus/2.1.259.pristine`,
   `$want=884baa38fe1a624be25c4a91568bf5a08b5cf4e7d7acf29b7760e3525d964898`,
   `--target /tmp/w38/259.bin`, лог `/tmp/w38/build.log`. Ожидание: все 119
   проверок зелёные (строка сводки конвейера), пол `3/119` (как у свипа).
   Красная проверка = стоп по стоп-правилу (правка §2 не роняет ни одну из 119).
3. Стенд: `bun tools/probe-bench.js --binary /tmp/w38/259.bin` — 124 сценария
   зелёные, старые 82 без изменений ожиданий;
   `bun tools/probe-bench.js --binary /tmp/w38/259.bin --self-check` — 7/7.
4. Реплей по живому корпусу (только чтение):
   `bun tools/probe-bench.js --binary /tmp/w38/259.bin --form-replay ~/work/SIB/Transmutation/Nexus/conduit/conduit/.r17-briefs ~/work/SIB/Transmutation/Nexus/nexus/nexus-exec/.briefs > /tmp/w38/replay.txt`
   — полный вывод в отчёт (все строки `FORM …` и сводка). Ожидаемых чисел
   нет: список подаётся как измерение.
   Положительный контроль на собственном брифе:
   `bun tools/probe-bench.js --binary /tmp/w38/259.bin --form-replay docs/review > /tmp/w38/replay-self.txt`
   — файл `docs/review/wave38-brief-form-probe-T1.md` (этот бриф) обязан
   дать A2 (в тексте есть строка `witness_worker` — он описывает правило) и
   A3 (сценарии 14–16 несут слова `open_door` вне забора); A1 — нет (хвост
   на месте), A4 — нет (строки правила есть). Ноль срабатываний на этом файле
   = реплей не мерит (стоп-правило).
5. Раскатка: `bash scripts/probes-sync.sh --to-home` — зелёная; затем
   `bash tools/probes-sync-bench.sh` — 7 сценариев / 8 мутаций как прежде.
6. Полный свип одной версии: `bash tools/sweep.sh 259 > /tmp/w38/sweep.log 2>&1`
   — строка `SWEEP 259: exit=0 ok=119 fail=0 … bench=1` и `SWEEP DONE`.
   Свип идёт под `setsid`; ждать по pid лидера (`kill -0`), фоновым запуском —
   не `sleep` в переднем плане дольше таймаута инструмента.
7. Гейт чисел идёт внутри свипа: зелёный свип = три дома 124 и 7 сходятся.
8. Точные счётчики ДО/ПОСЛЕ в отчёте: сценарии 82→124, мутации self-check
   5→7, проверки конвейера 119→119, строк реплея по корпусу.

## §11 Отчёт

Файл `docs/review/wave38-report-T1.md` (русский), разделы: статус
(`DONE`/`BLOCKED`), изменённые файлы с числом строк diff, счётчики ДО/ПОСЛЕ,
вывод стенда (последние 15 строк) и self-check, полный вывод реплея
(§10.4), строка свипа, отклонения от брифа (каждое — с причиной и file:line),
замеченное вне скоупа. Итоговое сообщение контроллеру — четыре строки: статус,
счётчики, путь отчёта, список отклонений одной строкой.

<!-- BRIEF COMPLETE -->
