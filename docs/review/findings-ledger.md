# Audit findings ledger — our 25 steps vs 2.1.246 upstream

Voice 1: opus-auditor, step-driven conformance. 25/25 steps located, 14 clean,
11 with findings. Full text in that agent's transcript. Voice 2 (gpt-sol,
consumer tracing) still running — do NOT start the fix wave until it lands;
one wave for the whole list.

Adjudication column is MINE, not the auditor's.

| # | Sev | Step | Module/span | Defect | Adjudication |
|---|---|---|---|---|---|
| F1 | HIGH | 19 broken stream | 361 s16 | Deletes the ONLY writer of `truncatedAfterOutput:!0`; the reader `GJn` survives, so `tengu_truncated_response_recovery` can never fire. Upstream added this recovery AFTER step 19 was written. | **CONFIRMED by my own count**: assignment `?!0:void 0` = 1 in pristine, 0 in installed; occurrences 8 vs 7; reader still present in installed. FIX. |
| F2 | HIGH | 22 judge | 361 s14 | Locator matches ONE dispatch site. A second tool-invocation site (REPL sandbox, `zss`/`POt`) carries the Agent tool (`ya`="REPL" is the only exclusion) and is never judged, nor counted by the watcher. Silent pass in a fail-closed mechanism. | Pending my verification of the second site and whether REPL ships enabled. If confirmed: FIX (widen locator to both shapes). |
| F3 | MED-HIGH | 19 broken stream | 361 s16 | Drops `!Cr` (has-real-content) from the retry gate, so a break AFTER text was yielded now retries with the partial already committed to the transcript and to the next request's message array. The step comment claims "the consumer already drops a trailing assistant whose stop_reason is null" — auditor enumerated the drop sites and found none in the query loop (`d3s` has zero callers). | Pending my check of the comment's claim. If the drop really is absent: FIX. |
| F4 | MED | 7 session memory | 133 s7 | `_Z(){…return !ge()||flagB}` -> `return!0`. `ge` = module 28 `Rd` = `!isInteractive()`. Forcing true switches memory extraction on for HEADLESS runs and makes the non-interactive exit await the drain. Step comment only ever mentions the two flags, never the interactivity test. | Likely FIX: keep the interactivity term, force only the flags. |
| F5 | MED | 20 session model restore | 484 s1 | Our prefix skips ALL THREE verdicts for non-claude ids, not just `unknown_family`: `not_allowed` (module 133 `Z`, reads `availableModels` + policySettings) and `retired` are bypassed too. | Likely FIX: bypass only the family verdict. |
| F6 | MED | 27 bypass immunity | 361 s4 | Registry (module 42) has TWO `bypassImmune:!0` entries — `dangerousRemoval` and `isolatePeerMachines`. The step comment names only the first. | Decide deliberately: is dropping isolatePeerMachines immunity intended? |
| F7 | LOW-MED | 1 routing | 361 s5 | `baseURL` forced to api.anthropic.com while `fetchOptions` were computed for `FOo(...)` = ANTHROPIC_BASE_URL -> with HTTPS_PROXY + NO_PROXY containing the local host, the corporate proxy is skipped. Also flips `_baseURLIsExplicit`, killing `_applyCredentialBaseURL`. | Verify then decide. |
| F8 | LOW | 14 coordinator force | 361 s2 | Edit sound; TWO comment claims false (4 of 5 call sites also reload agent definitions; `eHt` is a directory walk, not the print-path mode writer — `saveMode` has no caller on `-p --resume`). | Comment fix + confirm the stale-record hazard. |
| F9 | LOW | 17 resume search | 1077 s1 | Search mode bypasses the 2.1.242 give-up counter as well as the proximity test. Comment owns it; termination argument verified. | Accept, already documented. |
| F10 | LOW | 10 context window | 133 s6 | New `k()` call introduces a throw ("Config accessed before allowed") on a path that previously returned the 200K default. Also the lookup sits below `xe(e)`/`Vo`/`oM`, so a `[1m]` entry is unreachable. | FIX both. |
| F11 | LOW | 12 dispatch effort | 361 s13 | Our `effort` schema field is a free string, unlike every upstream producer which runs `vT` (module 144 `ae`) and warns; an unrecognised value degrades silently to "high" via module 144 `ce`. | FIX: validate + warn. |
| F12 | INFO | 8 custom model costs | 133 s1,s2 | Two upstream existence guards became constants; outcome unchanged. | Accept. |
| F13 | INFO | 12 leg (a) | — | No-op on 2.1.246, exactly as its comment predicts. | Accept. |

## Clean (14): steps 2, 3, 4, 6, 9, 11, 13, 15, 18, 21, 23, 24, 25, 26.

## Separate defect, already root-caused by me (not from the fan)

`User message display` refuses on 2.1.242/243/245. Cause measured on the real
payloads: the owning module (190 on 242) contains ZERO chalk-shaped call sites,
so `findChalkVar(moduleText)` returns undefined and the split-bundle refusal
fires. On 246 the owning module 1036 has exactly ONE such site (`h1`) — it
passes by a hair. The user's config needs no chalk at all (`styling: []`,
`foregroundColor: "default"`, `backgroundColor: null`). Full fix: express colour
and styling as props on the `Text` element the patch already emits (ink supports
color/backgroundColor/bold/italic/underline/strikethrough/inverse) and drop the
chalk dependency entirely. Trap to avoid: the whole-file chalk winner on 242 is
`b`, and module 190's prologue also binds a name `b` — a DIFFERENT binding. That
coincidence is the `l0` defect in reverse.

---

# Voice 2 (gpt-sol, consumer tracing) — landed. Convergence and additions.

Both voices independently produced F1, F2, F3, F5, F6 from different starting
points (voice 1 walked our script, voice 2 walked the spans and traced readers).
Independent convergence on five findings is the strongest signal in this fan.

## New from voice 2, adjudicated by me

| # | Sev | Owner | Defect | My adjudication |
|---|---|---|---|---|
| G1 | MED (user-visible daily) | tweakcc `mcpStartup` | `e=!D(process.env.MCP_CONNECTION_NONBLOCKING)` -> `false`. `D` returns true only for "0"/"false"/"no"/"off", false for undefined; so pristine computes `e=true` and the consumer `if(t){…running fully async (nonblocking);return}` takes the NONBLOCKING path. Forcing `false` selects the BLOCKING path — the exact opposite of the patch's own description ("CC startup will be much faster"). | **CONFIRMED by my own read of D, the expression, and the consumer branch.** Also orphans the env var: 2 occurrences pristine, 1 installed (schema registration only). The user runs five MCP servers, so this has been slowing every start. FIX in the fork. |
| G2 | MED | tweakcc `showMoreItemsInSelectMenus` | Deletes the divisor that converts physical rows into item count: `Math.floor((kp-Rs)/Cp)` -> `kp-Rs` (module 528 s3, 22b->5b) and `Math.floor((fe-10)/2)` -> `fe-3` (module 1318 s1, 21b->4b). `Cp` is 3 for expanded and 2 for compact-vertical. | **CONFIRMED against the span map itself.** Menus can list 2-3x more items than there are rows. FIX in the fork: raise the cap without dropping the divisor. |
| G3 | LOW | ours, step 4 | `model:"inherit"` now yields a redundant badge. | **CONFIRMED — see the disagreement below.** |

## The one disagreement between the voices — resolved by me

**Step 4 (model badge), module 1036 span 2.** Voice 1 called it clean, arguing
"the new `e.model?z_(e.model):l` keeps `m` defined, so the dropped
`e.model!=="inherit"` test cannot make `z_` see `"inherit"`". That reasoning is
wrong: `"inherit"` is a truthy string, so `e.model?` takes the true arm and
`z_("inherit")` is exactly what runs. `m!==l` then holds even when the agent's
model equals the main model, and the badge renders with no override to show.
Voice 2 is right. Severity Low. Fix: restore the sentinel test —
`m = e.model && e.model!=="inherit" ? z_(e.model) : l`.

Note for future fans: voice 1 was the stronger auditor overall (it caught F1 and
the comment-vs-code mismatches), and it is still the one that got this wrong. A
single voice, however good, is not a verdict.

## Attribution conflict to settle before the fix wave

F4 / voice-2 #7 (`_Z(){return!0}`, module 133 span 7). Voice 1 attributes the
edit to OUR step 7. Voice 2 says the physical edit is tweakcc's `sessionMemory`
patch and our step 7 only asserts-or-verifies the same postcondition. This
decides WHICH repo the fix lands in. Settle by reading both writers before
editing anything.

---

# Round 2 (claim-truth / goal-backward voice) — landed, adjudicated by me

| # | Sev | Defect | My adjudication |
|---|---|---|---|
| R2-1 | HIGH | The premise of the wave's own second hook is false: `pis(e,t)` filters `!Xn(s,fn)&&!Xn(s,ya)`, and `fn`="Agent" — so the dispatch tool never reaches the REPL sandbox map. The hook there guarded nothing and added a probe call to every tool call a sandboxed program makes. | **CONFIRMED by my own byte reading**, independently of the report: module-scoped import `rJb as fn` @6478093 -> export `y as rJb` @2884322 -> `y="Agent"` @2877197 (same module 2875971..2884886, one string assignment). Chain `R=pis(t.options.tools,Fe(t))` -> `aVe(R,…)`/`our(v,R,…)` -> `POt(R.filter(c=>!Xn(c,ya)))` -> `zss(u,…)` all verified. FIXED. |
| R2-2 | HIGH | "There are exactly two dispatch sites" is false: `claude mcp serve` is a third executor and it DOES carry the Agent tool. | **CONFIRMED**: `gE()` starts `[C2e,…]` (C2e = the tool, `name:fn`); the serve handler's list is `h3e(o,{skipReplFilter:!0,skipSimpleModeFilter:l})` which excludes only `zg`/`Sh`/`rv`/"StructuredOutput"; `l=u==="http"` is false on the stdio transport the CLI hard-codes, so the http allowlist is not applied. FIXED — but not by adding a third hook. |
| — | — | (my own conclusion, not the report's) The census itself is the defect: the number of dispatchers is not a constant. | The judge now rides `Agent.call`, the one funnel all three executors pass through (the tool declares no `executor`, so the 2.1.239 adapter falls through to it). The product refuses a launch from exactly there too — the nesting-depth cap throws out of this method. |
| R2-3 | MED-HIGH | Step 19's recoverable lane was a strict subset of the reader (`||e==="sdk"` dropped). | Already fixed in the tree before this round landed; the report audited HEAD. |
| R2-4 | MED | Step 12's effort normaliser was exact-match while the product's own parser trims and case-folds first. | **CONFIRMED against `Wt(e){let t=e.trim().toLowerCase(),n=ze[t]??t;return x(n)?n:void 0}`.** A dropped effort is silent — the dispatch lands on the definition's default. FIXED: the emitted normaliser now trims and case-folds before the alias fold. Numeric efforts belong to the other parser (`ae`) and are outside a string field's domain — not an omission. |
| R2-5 | MED | The duplicate-block collapse silently changed WHICH block the per-block gates describe. | **CONFIRMED and the reasoning it rested on ("removal only takes text away") was wrong for the class it was defending.** FIXED by construction: the collapse now removes duplicate CORES (`/*__ccCore0*/…/*__ccCore1*/`), and the two consumers each appear exactly once, so every calibrated count means what it meant. The site check runs on the UNCOLLAPSED bytes. |

## Declined, with reasons (F5 of round 1 — step 20 skips all three verdicts)

Not a defect: a documented contract. Measured on 246: `not_allowed` is `!mE(a)&&!Z(a)`, and `Z(e,t)` returns TRUE when the user has no `availableModels` restriction (`if(!r)return!0`), so keeping it would decline a proxy model only where the check is first-party-shaped anyway; `retired` is `Ob(e)`, keyed on the first-party deprecation table, so it is false for a proxy id regardless. The step's comment already states the contract: under a gateway a non-claude id is restored as-is and the gateway validates it at request time. No change.

## Gate hardening this round (each mutation-tested)

* `_probe_hooks_both_sites` -> `_judge_rides_the_tool`. Five mutations, 5/5 caught. Two of them were only caught after fixes: the gate used to RAISE (aborting the whole verify stage — no verdicts at all) on a missing marker, and it normalised the four call-site names, which proved they were consistent but not that they were the RIGHT ones. Names are now built into the tail regex from the call itself.
* Note on my own test discipline: mutation 5 first "passed" because it edited a name that block did not contain — an empty mutation reads exactly like a caught one. Every mutation now asserts it changed the bytes.

---

# Critique fan on the relocation itself — voice 1 (mechanism attack). Adjudicated.

| # | Sev | Defect | My adjudication |
|---|---|---|---|
| C1-1 | MED-HIGH (mine, introduced by this wave) | The shared core read AND DELETED `__ccJudgeTurn[key]`. With judge and watcher in one block the judge was written first and got the entry; after the relocation the watcher runs at the dispatcher BEFORE the call enters the tool, so it destroyed the turn the judge was about to read. | **CONFIRMED, and live**: `~/.claude/settings.json` carries `CLAUDE_JUDGE=1` and `CLAUDE_IDLE=1`. Not a crash and not a refusal — a judge reasoning without the thinking that motivated the dispatch, on the first dispatch of a session and on every watcher window after. Root fixed: the core no longer knows the map; it asks its caller (`__o.turn`), and only the judge supplies one. Ownership is structural, not positional. New gate `current turn is the judge's alone` pins it: no core may mention the map, exactly one supplier, the supplier is the judge block, and the turn key equals the record key. |
| C1-2 | — | Coverage: the site gate asserted structure only and could never have seen C1-1. | Accepted and closed by the gate above — the property it now pins is textual ownership, which is checkable statically; a runtime handoff test would need a live dispatch, which no gate in this pipeline can drive. |
| C1-3 | LOW | My dispatch brief claimed the judge now runs AFTER the depth cap. Inverted: it runs at the top of the method, before the tool's own guards — the same position it held in front of the dispatcher. | Brief error, not a code defect. The conclusion (nothing above the splice point but destructuring, so a cancellation leaves nothing half-done) holds and was verified by the voice independently. Placement rationale now stated in the code. |

## Adjudication requests answered by measurement

1. Both probes enabled — verified in settings (above). The defect was live, not hypothetical.
2. `wd.id === toolUseId`: `for(let He of _n) addTool(He, ot)` where `_n = ot.message.content.filter(b=>b.type==="tool_use")` — the executor is fed the very blocks that later carry `toolUseId`. Identity holds structurally.
3. No detached invocation of `call` proven only for the sites opened (main, serve, the 240 adapter arrow), not for all 1343 `.call(` occurrences. **Accepted as residual risk with the right polarity**: such a route would make `this.name` throw and kill that dispatch loudly, which is the failure direction this mechanism is built for.
4. Serve-mode judgement sees no conversation (`messages: []`) — acknowledged limitation, already stated in the code. The judge's primary material (brief, model, class marker) is in the dispatch payload, which it always has.
5. Severity: I rate C1-1 above the voice's "Medium" — the degraded input is exactly what the mechanism was built to reason over. Fixed regardless of rating.

## 246 — установка закрыта (2026-08-26)

- Сборка `2.1.246.staging`: **81 гейт OK, 0 FAIL**, дым `2.1.246 (Claude Code)`, гейт интерфейса 1.
- Батарея мутаций по `_turn_belongs_to_the_judge` (4 мутации, каждая с проверкой на непустоту):
  реальный образ True, все четыре мутации False. Гейт закрыт.
- Установлено `mv "$V.staging" "$V"`; `~/.local/bin/claude` — симлинк на versions/2.1.246,
  подпись валидна. **Сессии держат старый инод — нужен рестарт.**
- Коммит `98585c8`, отправлен в origin/main.

### Список моделей: требование юзера «базовый набор antropic, но прокси должны быть»

Метод — замер, не рассуждение. Три сверки:

1. **Нагрузка с нагрузкой** (пристин / прежняя сборка / новая). Прежняя сборка давала ровно +1
   к каждому из шести легаси-ключей (`claude-3-haiku-20240307` 0→1, `claude-3-5-sonnet-20240620`
   0→1, `claude-opus-4-1-20250805` 10→11 …). Новая сборка совпадает с пристинной по всем шести.
   NB: первая попытка сверяла ИЗВЛЕЧЁННУЮ нагрузку пристина с ЦЕЛЫМ бинарником сборки — разные
   объекты, ложная тревога. Сверять только одноимённое с одноимённым.
2. **Отрисованный экран** списка на pty (изолированный CLAUDE_CONFIG_DIR, живой прокси).
   Прежний образ рисует Sonnet 3.5 и Opus 4.1; новый — нет.
3. **Счётчик позиций** при одинаковом размере окна: было 2 видимых + «+33 models» = 35,
   стало 2 + «+19 models» = 21. Разница **ровно 14** — размер вшитого списка tweakcc
   (`CUSTOM_MODELS` в `src/patches/modelSelector.ts`). Прокси отдаёт 14 моделей; 21 = 7 штатных
   Anthropic + 14 прокси. Ни одна модель прокси не потеряна.

Побочно: чтение экрана по отдельным именам ненадёжно — список перерисовывается поверх себя, и
разные прогоны дают разные подмножества имён. Считать надо позиции, а не совпадения строк.

Прокси-модели приходят НЕ от tweakcc, а от продуктового обнаружения по шлюзу
(`.filter(m=>/(claude|anthropic)/i.test(m.id))`, наши шаги 2 и 9), поэтому выключение
model-customizations их не задевает по устройству — и это подтверждено замером.

## Адъюдикация критика-потребителей (2026-08-26)

Критик выработал контекст и вернул хендофф вместо отчёта. Кандидаты разобраны мной лично;
каждый проверен по нагрузке, а не по цитате.

**C-провенанс — СНЯТ.** Критик: «`246.wave.bin` не содержит ни одного нашего маркера».
Проверено: сборка 22:41 (`log/wave-246.log`) упала ФАТАЛЬНО на `hash storage failed` —
это гонка двух конвейеров, ради которой и вводилась блокировка, — и оборвалась ДО наших
патчей. Отсюда 0 гейтов и отсутствие блоков. Конвейер отработал правильно: не установил.
Урок: перед разбором артефакта смотреть лог сборки, которая его породила.

**C1 — ПОДТВЕРЖДЁН, ВЫСШАЯ ВАЖНОСТЬ, дефект мой.** `mcp serve` строит контекст
`D={...,agentContext:{agentType:"main",agentId:U()},...}` БЕЗ `toolUseId` и зовёт
`s.call(m.data,D,Oe,…)` (246-pristine, смещение ~31 036 723). Судья теперь едет на
инструменте, значит этот маршрут он встречает по устройству — следствие моего же переноса.
`key` = undefined → `String(undefined).slice(-8)` = `"ndefined"`, имя записи
`<ts>-ndefined.json` ПОСТОЯННО на всём маршруте.
Последствие тяжелее, чем «файл перетёрся»: `rec` — это КЛЮЧ СОЕДИНЕНИЯ журнала с корпусом
(`judge/validate.py:98` `labels.setdefault(rec,{})[kind]=item`, `judge/adjudicate.py:210`),
поэтому одинаковое имя молча склеивает разметку двух РАЗНЫХ консультаций.
У `__o.key` ровно один потребитель — имя файла (`tweakcc-patch.js:1924`).
Фикс корневой: уникальность имени гарантирует ЯДРО для любого вызывающего, а не отдельный
маршрут — ключ остаётся честным (отсутствует, когда его нет).

**C2 — ПРИНЯТ.** `rxTool` опознаёт метод по форме деструктуризации; проверка уникальности
не привязывает совпадение к самому инструменту. Найден устойчивый якорь: в теле настоящего
метода сразу за сигнатурой стоит отказ по глубине `"subagent_launch","subagent_depth_cap"` —
РОВНО ОДНО вхождение на каждой из четырёх нагрузок (233/240/242/246). Привязать к нему.

**C3 — ЧАСТИЧНО, переименование.** `_judge_both_shapes(src)` читает ИСХОДНИК патча, а не образ,
и обещает именем больше, чем меряет. Но покрытие по образу уже есть и сильнее, чем счёл критик:
`_judge_rides_the_tool` строит хвостовое выражение из имён самого вызова и допускает обе формы
(`tool.call` | `ID(tool).execute`). Исходниковая проверка законна как страж от удаления ветки —
дефект в ИМЕНИ. Переименовать в то, что она меряет.

**C4 — ПОДТВЕРЖДЁН.** Ни один гейт не связывает имя файла записи с `__o.key`: подмена
`String(__o.key)` на константу оставляет всё зелёным. Закрывается гейтом вместе с C1.

**C5 — ОТКЛОНЁН.** Шаг 21 копит ленту для каждого потокового блока, а потребляет только судья.
Производитель не может знать заранее, какой блок станет диспатчем; лента ограничена 64 с
вытеснением старейшего. Это не дефект.

**C6 — ПРИНЯТ.** Документация утверждает, что ядро внедряется один раз, тогда как реализация
кладёт две копии (вторая инертна из-за `??=`). Док-правда: привести доки к реализации.

**C7 — ПРИНЯТ КАК РАЗМЕН.** Судья спрашивается раньше собственных гардов инструмента
(глубина/бюджет), поэтому возможна консультация по диспатчу, который инструмент потом
отклонит. Диспатч всё равно был авторски составлен; цена — одна консультация. Записать явно.

### Волна фиксов по адъюдикации — закрыта (коммит `8a2c771`)

- **C1 (корень).** Имя записи стало `<время>-<ключ|nokey>-<pid>-<счётчик>`; уникальность
  гарантирует ЯДРО для любого вызывающего, ключ остаётся честным. Новый гейт
  «одна консультация — одно имя записи» связывает имя с `__o.key` и с обоими разделителями.
  Батарея 6 мутаций (каждая с проверкой на непустоту): прежняя форма имени, ключ→константа
  (случай, названный критиком непокрытым), счётчик убран, pid убран, безключевой случай
  не назван, два счётчика (расхождение ядер) — все шесть красные, образ зелёный.
- **C2.** Локатор требует самоопознания инструмента (`"subagent_launch","subagent_depth_cap"`).
  Проверено прогоном патчера как функции: пристин проходит на всех 4 нагрузках; подмена
  признака даёт ЕДИНСТВЕННЫЙ отказ — наш, с нашим текстом.
- **C3.** Гейт переименован в `patch source keeps both dispatcher shapes` + оговорка,
  почему проверка по образу здесь невозможна.
- **C6 + найденное сверх критика.** Доки приведены к реализации. Раздел про судью описывал
  СТАРОЕ место («непосредственно перед `e.call(…)`») — это адрес наблюдателя. Переписан;
  добавлены принятый размен (судья раньше собственных гардов инструмента) и маршрут без
  идентификатора. «Ядро внедряется однократно» → пишется однократно, кладётся у каждого
  потребителя, вторая копия инертна через `??=`, сборка проверяет побайтовое совпадение.

Гейты 82/82 на 2.1.246; 233 и 240 на предыдущем коммите дали 81/81 (гейтов стало 82).

## Задача №8 — заземление (разведка, правок нет)

Цель: resume должен восстанавливать ВЫБРАННУЮ модель, а не эхо ответа. Сегодня
`Xt(e,o)` берёт `s.message.model` — это то, что вернул API, а не то, что выбрал человек;
поля запрошенной модели в записи транскрипта нет.

Заземлено по нагрузкам (все четыре версии диапазона, замеры именонезависимые):
- записей ассистента — **8**; из них **6** уже несут идиому опционального поля
  `...<v>!==void 0&&{effort:<v>}`, **3** — `...<v>&&{advisorModel:<v>}`. То есть добавление
  соседнего поля идёт продуктовым способом, а не изобретается нами.
- **Структурный якорь для врезки: 4 совпадения** на каждой версии —
  `...<fn>(<S>.querySource,<S>.spawnedBySkill,…),type:"assistant",uuid:`; имя объекта
  настроек `<S>` извлекается из самого якоря (`i` в 233/240, `s` в 242/246 — литерал
  не годится).
- В той же области доступен **`<S>.model`** — модель запроса вызывающего, в отличие от
  `message.model`. Перезаписывать `message.model` НЕЛЬЗЯ: API действительно ответил той
  моделью, запись должна остаться правдивой. Поле кладётся СОСЕДНИМ.

Замечание о методе (обжёгся сам): первый замер искал в 233 по именам из 246 и дал ложные
нули, а внутри 246 литеральное `nt` совпало лишь на 4 точках из 6 — имена различаются и
МЕЖДУ версиями, и МЕЖДУ точками одной нагрузки. Все числа выше перемерены шаблоном с
обратной ссылкой на захват.

Открыто до реализации: сторона чтения (`Xt`) должна предпочитать новое поле, с падением
обратно на `message.model` для старых транскриптов, где поля нет.

## Раунд аудита: два голоса (2026-08-26)

### Голос «перекрытые фиксы апстрима» — ОТВЕТ ОТРИЦАТЕЛЬНЫЙ, и это результат
Перепись всех 25 живых шагов (1-4, 6-15, 17-27; 5 и 16 отсутствуют), каждый локатор
прогнан по всем четырём нагрузкам, с нулями, подтверждёнными положительным контролем.
Вывод: **ни одного случая, когда наша замена молча выбрасывает изменение апстрима.**
Все изменения 233→246 у наших дверей — либо вне переписываемого куска, либо захвачены и
воспроизведены из групп, либо это ровно тот дефект, ради которого шаг существует.
Голос честно перечислил три места, где заземление неполное (класс `$U`/`S0e` рядом с
шагом 11; привязка третьего аргумента `GJn`; второе место `defRx`) — последнее я разобрал сам.

### Голос «атака на механизмы + правдивость утверждений» — две находки по ПРОВЕРКАМ
Обе подтверждены мной лично.

**A1 (ВЫСШАЯ). Гейт `agent model schema relaxed` не меряет ничего.** Он ищет форму
`.enum(["sonnet","opus","haiku","fable"])` — форму zod-v3, которой с 2.1.224 нет вовсе.
Замер: 0 вхождений в 233/240/242/246/247, в том числе в НЕПРОПАТЧЕННЫХ образах. Значит
проверка зелена и на неправленом бинарнике: различающая сила нулевая, а строка отчёта
утверждает обратное. Штатная форма сегодня `model:<enum>(["sonnet",…])` (замерено: ровно 1
на каждой версии), шаг 3 переписывает её в `model:<str>()`, заимствуя построитель у соседнего
`subagent_type:<str>()`. Двусторонняя замена проверена: пристин — штатный enum 1, пар 0;
собранный — enum 0, пар 1. Обе половины переключаются.

**A2 (ВЫСОКАЯ). Гейт интерфейса теряет код выхода ровно на том пути, ради которого написан.**
Внутренний цикл дозора (после первой отрисовки) на смерть процесса делает `break` БЕЗ
`GATE_EXITED=1` и без чтения статуса; далее блок `if [[ $GATE_EXITED -eq 0 ]]` принудительно
ставит `GATE_RC=0`, и ветка RENDERED отчитывается успехом. Внешний цикл тот же случай
обрабатывает правильно. То есть падение через 1-9 секунд после отрисовки, чей текст не
попал под шаблоны (`Maximum call stack size exceeded`, фатал уровня среды, голый выход с
кодом) — проходит как зелёная сборка.

**A3 (низкая). Список безобидных классов ошибок наполовину мёртв.** `BENIGN` содержит
`Connectionrefused`, `Connectionerror`, `fetchfailed` — ни один не может совпасть с
шаблоном `[A-Z][A-Za-z]*Error`, который его единственный потребитель. Живой элемент один.
Направление отказа безопасное (ложный FATAL, не ложный пропуск), но здоровая сборка может
быть отвергнута.

**A4 (низкая). Обнаружение отказов tweakcc односторонне** — привязано к глифу, отступу и
английской фразе. Дрейф формата снова открывает дыру «чистый пропуск выглядит как успех».

### Разобрано мной сверх аудиторов: второе место `defRx`
Шаг 12 прикладывает усилие к определению агента ЗАМЕНОЙ ПЕРВОГО совпадения, а мест два на
всех пяти версиях. Второе — возобновление припаркованного агента, и там **апстрим сам**
кладёт усилие: `<opt>?.effort!==void 0?{...<def>,effort:<opt>.effort}:<def>` (замерено на
233/240/242/246/247). То есть наша правка одного места ВЕРНА — но верна за счёт поведения
апстрима, которое ничем не проверяется: уберут его — усилие тихо пропадёт на возобновлении
при всех зелёных гейтах. Это тот же класс, что я чинил у судьи (привязка к тому, что апстрим
волен изменить). Закрывается гейтом: каждое место запуска обязано нести усилие одним из двух
путей. На собранном образе замерено: наша врезка 1, обычных мест 1, и у него апстрим кладёт.

### №8: сторона чтения заземлена (247)

Читатель — `Xt(e,o)` @16115421 (247). Идёт по транскрипту С КОНЦА и берёт эхо ответа:

    for(let i=e.length-1;i>=0;i--){let s=e[i];
      if(s?.type!=="assistant"||s.isMeta||typeof s.message?.model!=="string"||s.message.model===yt)continue;
      let a=s.message.model,l=ct();

`_i(e,o)` — тонкая обёртка: `let t=Xt(e,o);return t.kind==="ok"?t.model:void 0`.

Важно: **шаг 20 уже оборачивает эту же функцию** («session model restore keeps a proxy model»),
то есть новое поле протягивается в существующую врезку, а не рядом с ней — иначе получится
два хозяина одного участка (класс, который сейчас проверяет отдельный аудитор).

Сторона записи (заземлено выше): `<S>.model` — модель, которой ВЫДАЁТСЯ запрос
(`new Nh(s.model,s.fallbackModel,"model_blocked")`, резолв под bedrock производится из неё),
в отличие от `message.model`. Якорь врезки — 4 совпадения на каждой версии.

Порядок работ: сначала запись поля, потом предпочтение его при чтении, с откатом на
`message.model` для старых транскриптов, где поля нет. Оба конца — одна волна, иначе
поле пишется и никем не читается.

---

## Раунд 2 (аудиторы: кросс-взаимодействия 25 правок · достижимость каждой правки). Адъюдикация 2026-08-27

### ПОДТВЕРЖДЕНО И ИСПРАВЛЕНО

**R2-1 (высокая). Потребитель зонда тянулся к именам, приватным для ядра.**
Механизм: `watchCall` вклеивается в область видимости диспатчера, ядро —
закрытая функция на `globalThis`. Его `onAct`-catch звал `__jlog`/`__clip`
голыми именами. Заземление на байтах установленного 2.1.247: ядро закрывается
`}};` на 186469613, единственное `let __jlog=` этого блока — на 186450430
(внутри), использование — на 186472085 (снаружи). Строка `nudge_undelivered`
не могла быть записана НИКОГДА; собственный пустой `catch{}` глотал
ReferenceError.
Почему не видели: гейт спрашивал ПРИСУТСТВИЕ текста, а стенд `emit-check.js`
только РАЗБИРАЕТ вклеиваемый код — свободное имя в JS это ошибка исполнения,
не разбора. Диагноз аудитора («стенд склеивает куски в одну область») неверен
в механизме, но находка верна.
Корень: ядро не передавало потребителю своих услуг. Исправлено передачей —
`let __svc={log:__jlog,clip:__clip}` и вторым аргументом во ВСЕ четыре колбэка
(`onAct`/`onNoVerdict`/`onBroken`/`onFail`), а не правкой одного места.
Гейты: (1) в `emit-check.js` — статический разбор области видимости каждого
потребителя (любое `__`-имя, не объявленное самим потребителем и не за точкой,
= падение); отрицательный контроль воспроизводит дефект и называет `__jlog
__clip`. (2) на образе — `consumers do not reach into the core`: в хвосте
каждого блока после `/*__ccCore1*/` нет ни одного приватного имени ядра, плюс
положительная половина (запись идёт через переданные услуги).

**R2-2 (средняя, найдено при почин.). `_judge_catch_scope` поддерживался руками.**
Окно объявлений было фиксированной длины, всё что за ним — вписано списком
(`__jlog`, `__jdir`, `__cut`). Список, который ведёт человек, перестаёт
соответствовать коду в первый раз, когда никто не вспомнил. Заменён честным
обходом объявлений тела ядра до его верхнеуровневого `try` (26 имён, без
локальных имён вложенных функций). Проверен в обе стороны на реальном тексте.
Побочно: `__cut` из ручного списка не нужен вовсе — catch его не читает.

**R2-3 (средняя). Недоказанная привязка helper'а в шаге 14.**
Шаг брал env-truthy helper ПЕРВЫМ по всему образу, а вставлял его вызов в
модуль `matchSessionMode`. Имена в расщеплённом бандле локальны для чанка.
Замер: на 247 все три места в модуле 375, на 242 — 433, на 246 — 360, на
233/240 бандл односоставный. Живого дефекта нет; привязка теперь берётся из
модуля вставки и падает с объяснением, если helper'а там нет.

**R2-4 (низкая, O1 аудитора). Порядок шагов 12→22 был молчаливым условием.**
Шаг 12 дописывает `effort:__ccEffort` в тот самый параметрический паттерн,
который переписывает шаг 22. Обратный порядок ронял бы 12-й с сообщением не о
том. Вписана проверка маркера — она же доказывает, что два независимо
написанных локатора нашли ОДИН метод.

**R2-5 (claim-truth, три места).** Обещания шагов 2, 7 и 19 читались шире, чем
покрытие. Дописаны границы: шаг 2 не ВКЛЮЧАЕТ discovery (выше него гейт на
CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY + firstParty + ANTHROPIC_BASE_URL);
шаг 7 форсирует серверные флаги, пользовательский мастер-выключатель остаётся
за юзером; шаг 19 покрывает интерактивные лейны, невзаимодействующий
recoverable-лейн намеренно сохраняет штатное поведение.

### ОТКЛОНЕНО С ЗАЗЕМЛЕНИЕМ

**Достижимость №4 (шаг 20 «проверяет env, а не конфиг»).** В образе 247:
`case"firstParty":return process.env.ANTHROPIC_BASE_URL||Tc().BASE_API_URL`.
Наш контур — firstParty, значит переменная и ЕСТЬ резолвер адреса, а не
случайный носитель. Без неё у не-claude модели нет достижимого адреса, и
восстановление вернуло бы сессию на модель, до которой запрос не дойдёт.
Условие шага корректно.

**Q-A (совпадение букв предиката и флага fork в будущем).** Падение громкое
(счёт свипа вне диапазона), молчаливой потери нет. Не дефект текущего кода.

### ГИГИЕНА
Q-C: устаревший `/tmp/cc-matrix/js/246-staging.js` удалён (мой промежуточный
артефакт; калибровка по нему дала бы ложный FAIL).

### СХОДИМОСТЬ
Раунд 2 дал находки ⇒ он не последний. Нужны ДВА подряд раунда с нулём.

### R2-6 (ВЫСШАЯ, найдено мной при проверке чужой находки) — судья на 242/243/245 молча ехал не по своему каналу

Ядро содержит `let __pool=typeof <движок>==="function"?<движок>:null`, где
`<движок>` — имя штатного однократного запроса, захваченное по определению
`async function X({messages:…,systemPrompt:…})`. Имя пропускалось через
`repEsc` — экранирование для СТРОКИ ЗАМЕНЫ (`$` там читается как ссылка на
группу). Но блок зонда давно вклеивается **срезом по смещению**, а не через
`String.replace`: раскрытия `$$`→`$` не происходит.

Замер имён движка по версиям: 233=`sje`, 240=`Q2e`, **242=`$A`**, 246=`TA`,
247=`zA`. Замер собранных образов: 233/240/246/247 — имя дословное;
**242/243/245 — `$$A`**.

`typeof` на несвязанном имени НЕ бросает — возвращает `"undefined"`. Значит
`__pool=null`, `__http` становится истиной, и консультация уходит сырым HTTP
на адрес по умолчанию вместо штатного контура клиента. Это смена канала:
другой путь, другие настройки соединения, другой счёт. Молча.

Почему 83 гейта пропустили: все они проверяют ФОРМУ `typeof <имя>==="function"`,
а `$$A` — совершенно правильное с виду имя (`$` входит в класс идентификатора).
Форма совпадала, смысл — нет.

Установленная 247 не затронута (в `zA` доллара нет), поэтому в бою это не
проявлялось; сломана была треть поддерживаемого диапазона.

**Исправлено полностью:**
1. `siteName()` вместо `repEsc()` для всех ЧЕТЫРЁХ имён, вклеиваемых срезом
   (движок, очередь напоминаний, id сессии, аксессор заголовка) — дословно.
2. Тот же helper падает, если имя содержит `$` с цифрой: слоты блока пишутся
   `$1`..`$9` и раскрываются в этом же тексте, такое имя съело бы себя само.
3. Самопроверка в патчере: все четыре имени обязаны дословно присутствовать в
   собранных блоках — иначе сборка стоит.
4. Гейт образа `probe names match the image bindings`: имя пула сверяется с
   ОПРЕДЕЛЕНИЕМ движка в образе, имена очереди и сессии — с настоящим
   вызовом очереди выше по образу; блоки зонда вырезаются перед сверкой,
   чтобы имя не подтверждалось тем же текстом, который проверяется.
   Контроли: 247/233 (исправленные) — проходит; 242 (`$$A`) — падает.
5. Утверждение о модулях в шаге 22: определение движка и ОБА дома зонда
   обязаны лежать в одном модуле, иначе имя там не связано. Замер: 374 на
   247, 360 на 246, 433 на 242; у 233/240 модуль один. Расхождение теперь
   останавливает сборку, а не меняет канал молча.
6. Заголовок шага 22 утверждал ПРОТИВОПОЛОЖНОЕ («намеренно прямой HTTP, а не
   штатный однократный запрос») — текст от первого дизайна, канал сменили, а
   абзац остался. Переписан.

Класс: «форма совпадает, привязка не проверена». Тот же, что R2-3 (helper по
всему образу) и R2-1 (имя из чужой области). Урок: имя, вклеиваемое как ТЕКСТ,
проверяется сверкой с настоящей привязкой образа, а не формой.

### R2-7 (средняя, попутно). Стенд сценариев был мёртв до моей правки.
`carveBlock` берёт ПЕРВЫЙ блок `/*__ccProbe0*/`. После переезда судьи на
инструмент первым в образе идёт судейский блок, где нет `onAct` наблюдателя,
и стенд падал на настройке («free name not found: notify») — все 36 сценариев.
Не замечено, потому что конвейер стенд не вызывает. Локатор починен под новую
сигнатуру; добавлен сценарий `watch-nudge-undelivered` (очередь бросает) —
ровно тот путь, что был мёртв по R2-1. ОСТАЁТСЯ: стенд по-прежнему разбирает
один блок на все сценарии — нужна разводка «блок на потребителя», иначе
судейские и наблюдательские сценарии идут через один и тот же карв.

## Раунд 5 (линзы A-E; голоса: fable «семантика пропатченного продукта», grok «апстрим + два процесса», gpt-luna ×2 «граница доверия» и «что уходит с машины»). Адъюдикация 2026-08-27

### fable — ЧИСТО по всем четырём семантическим линзам (проверено мной по коду)
- `Xt` идёт по ленте НАЗАД и возвращает последнюю валидную assistant-запись → смена `/model`
  в середине сессии восстанавливается по последней записи, а не по первой.
- Суффикс `[1m]` пере-выводится из живого состояния, а не берётся из записи → 1M-контекст
  при resume не теряется.
- Гейт области судьи `agentType==="main"` проверен в коде — судья не срабатывает внутри форка.
- Состояние наблюдателя — process-local `globalThis`, потолок «1 на 30 минут» на СЕССИЮ.

### grok — 8 находок. Адъюдикация ниже. Общий знаменатель семи из восьми:
пин считает КОЛИЧЕСТВО там, где гарантия требует ОПОЗНАНИЯ каждого места.
Слак («2..6», «==4», «OR двух форм») покупает переносимость между версиями ценой
молчания на лишнем/пропущенном месте. Правильная замена везде одна: опознавать
каждое место положительным признаком, и падать на неопознанном.

- **R5-1 (высшая) ПОДТВЕРЖДЕНО (проверено мной лично до компакции).** Апстрим дописывает
  `advisorModel`/`effort` ПОСЛЕ `type:"assistant"`, наш `requestedModel` стоит ДО. В
  объектном литерале побеждает последний ключ. Сегодня в пристине `requestedModel` = 0
  (контроль: 6 в собранном), поэтому дефект не живой — но НИ ОДНА из 89 проверок не
  запрещает второй ключ того же имени. Фикс: проверка «на каждом из 4 литералов
  `requestedModel` встречается РОВНО ОДИН раз». Хвост литерала 100-111 байт, разбор по
  балансу скобок работает — измерено. Разрешать конфликт молча (двигать наше поле в
  конец) НЕЛЬЗЯ: если апстрим введёт одноимённое поле с другим смыслом, нужен человек.
- **R5-2 (высшая) ПОДТВЕРЖДЕНО, сценарий 3 — реальная дыра.** Патчер пинит `writes.length
  !== 4` по своей форме, проверка 26 — `from_request == 4` по ДРУГОЙ эвристике
  (`.querySource,` + `.spawnedBySkill` в 400 байтах назад). Пятый настоящий сайт без этих
  двух строк в окне: оба считают 4, оба зелёные, resume на нём снова берёт эхо. Фикс:
  инвариант на ВСЕ 8 сайтов — 4 наших + 4 опознанных чужих (helper-конструктор, api-error,
  два field-by-field rebuild'а `/feedback`); девятый сайт любой формы валит сборку.
- **R5-3 (высшая) ПОДТВЕРЖДЕНО, обе половины.** (а) `2..6` при текущих 3 на 247 оставляет
  три свободных слота: новый не-fork `A?void 0:x` в тех же 20k будет снесён молча (класс
  уже случался — на 233 `L` сняли с Vertex). (б) настоящий fork-дроп за радиусом 20k
  невидим и патчеру, и проверке. Фикс: опознавать каждый хит в радиусе положительным
  признаком (отбрасываемое значение — модель/поле из известного набора), и сканировать
  ВЕСЬ образ, требуя, чтобы каждый хит вне радиуса был в опознанном списке
  (Vertex на 233, yoga-layout на 247).
- **R5-4 (средняя) ПОДТВЕРЖДЕНО частично, разложено на четыре независимых.**
  (а) `title` из `__ttl()` не клипуется → неограниченная строка журнала; (б) элементы
  `deg` не клипуются поштучно (`__dcut` ограничивает ЧИСЛО, не длину; `unparsed:` несёт
  сообщение парсера); (в) `probes.toml` читается без повтора — сохранение файла на месте
  даёт рваный разбор, и судья считает enforce+fail_closed включёнными → ложные отмены;
  (г) debug-файлы на фиксированных именах затираются двумя процессами. Все четыре чиню.
  Про `flock`: в `node:fs/promises` его нет; единственная реальная гарантия для дозаписи —
  ОГРАНИЧЕННАЯ строка (одна `write()` с O_APPEND), поэтому (а)+(б) и есть фикс атомарности,
  а не паллиатив.
- **R5-5 (средняя) ПОДТВЕРЖДЕНО.** Проверка 12 равняет `undisguise` со ВСЕМИ
  `/(claude|anthropic)/i.test(`, а шаг 9 патчит только `.filter(...)`. Не-filter вхождение
  у апстрима → красная сборка при живой гарантии. Фикс: считать только `.filter`-форму.
- **R5-6 (средняя) ПОДТВЕРЖДЕНО.** `_stream_finalize_ok` выбирает ветку по НАЛИЧИЮ БАЙТ
  `truncatedAfterOutput` во всём образе. Пул строк переживает нейтрализацию ветки —
  измерено на шаге 24 (`root/sudo privileges`). Фикс: выбирать ветку по коду в области
  финализации, а не по строке где угодно.
- **R5-7 (средняя) ПОДТВЕРЖДЕНО.** Проверка 21 — OR двух исторических форм: обе в образе
  → зелено по мёртвой, пока живой UI идёт в третью. Фикс: XOR (ровно одна форма).
- **R5-8 (средняя) ИНФОРМАЦИОННО.** Таблица точных пинов; действенное в ней покрыто R5-2
  и R5-3, остальные пины дают ЧЕСТНЫЙ красный (шаг не патчит — полупатча нет).

### gpt-luna «что уходит с машины» — 2 по существу + 1 расхождение кода и комментария
- **R5-9 ПО ЗАМЫСЛУ, но НЕ ОБЪЯВЛЕНО.** В консультацию уходит лента текущего хода: текст,
  `thinking`, имя инструмента + 400 знаков его входа, 300 знаков КАЖДОГО `tool_result`.
  Содержательного отбора нет — только усечение по длине. Это и есть материал, по которому
  судья судит готовность брифа, так что механизм верен; дефект в том, что нигде не
  ЗАЯВЛЕНО, что именно уходит. Фикс — раздел в `docs/judge-architecture.md`.
- **R5-10 ПОДТВЕРЖДЕНО (низшая).** Комментарий judge-врезки утверждает «every failure path
  is fail-open», а код держит fail-closed (`__jarm` при enforce+fail_closed, `onNoVerdict`
  /`onFail` бросают). Комментарий врёт — правится.

### Найдено мной в этом же раунде (не аудиторами)
- **R5-11 ИСПРАВЛЕНО.** Все 8 числовых настроек читались как `Number(x||default)`:
  отрицательный `threshold` делал `__n>=__th` всегда истинным → наблюдатель НАВСЕГДА
  немой без единой записи о причине; нечисловой давал NaN → порог переставал применяться
  вовсе. Введён `__num` с деградацией в журнал. Побочно вскрыто: строка `filtered` не
  несла `deg`, а гейт по замыслу отказывает на БОЛЬШИНСТВЕ вызовов — доклад испарялся
  ровно там, где рождается. Обе половины закрыты; 3 сценария стенда (отрицательный,
  нечисловой, положительный контроль на валидном не-дефолтном).
- **R5-12 ИСПРАВЛЕНО.** `records/` рос без предела: 31 МБ, 1134 файла, ~130/день, ни
  одного `unlink` во всём патчере. Введён `records_keep` (дефолт 500, min 1 через `__num`),
  подрезка на записи. Привязка к ЗАПИСИ намеренная: `record = false` значит «перестать
  писать», а не «стереть накопленное».
- **R5-13 ИСПРАВЛЕНО.** У стенда не было инварианта на число сценариев — того самого,
  что `EXPECTED_CHECKS` даёт реестру проверок. Потерянный при правке сценарий оставлял
  «N сценариев вели себя как задано» зелёным. Добавлены `EXPECTED_SCENARIOS = 40` и
  запрет одноимённых сценариев.

### СХОДИМОСТЬ
Раунд 5 дал 13 находок → сходимость (два подряд нулевых раунда) начинается не раньше 7-го.

### Волна раунда 5, часть 1 — ЗАКРЫТА (образ 2.1.247, 92 проверки, 43 сценария, ноль падений)
- **R5-11 полнота.** Первая версия чинила 8 мест из ~17: тем же сырым `Number(x||default)`
  читались `max_tokens` (5 мест), `timeout_ms`, `rung.context_chars`, `rung.timeout_ms` (2).
  Поймала это МОЯ ЖЕ новая проверка (`Number(__cfg.` == 0) — фикс был неполон, проверка
  оказалась права. Слоение между домами (`||`) сохранено дословно: заменены только финальный
  `|| default` и голый `Number()`, поэтому ни у одной настройки не сменился победитель.
- **Подчинённый дефект, вскрытый стендом.** С `__nseen` (один доклад на настройку, а не на
  читателя) сообщение забирал ПЕРВЫЙ читатель — леджер попыток, чей дефолт `null`. Человек
  читал «using null», хотя ушло 1200. Леджер РЕГИСТРИРУЕТ бюджет, а не выбирает его →
  у него теперь тихое чтение (`__q`), доклад идёт от пути отправки, который дефолт знает.
  Найдено сценарием `budget-negative`, не рассуждением.
- **R5-12 закрыто и измерено:** `records-pruned` (3 засеяны + 1 записана, keep=2 → осталось
  2) и `records-keep-zero-refused` (keep=0 отвергнут, 4 файла целы, деградация названа).
  Подрезка и срабатывает, и ОСТАНАВЛИВАЕТСЯ; свежая запись переживает подрезку.
- **R5-13 закрыто:** `EXPECTED_SCENARIOS = 43` + запрет одноимённых сценариев.
- **R5-9 закрыто:** `docs/judge-architecture.md` §9b «What leaves the machine» — таблица
  того, что именно уходит и с каким пределом (400 знаков входа инструмента, 300 знаков
  КАЖДОГО его результата, текст и `thinking` целиком, лента до `context_chars`), плюс
  прямое «содержательного отбора нет, рычаг — `enabled=false` или `filter`».
- **R5-1 + R5-2 закрыты одной проверкой** `nothing writes the requested model a second time`:
  перепись всех 8 сайтов `type:"assistant",uuid:` (измерено: 8 на 233/240/242/243/245/246/247,
  из них 4 from-request — на КАЖДОЙ версии, пристин и патч) + разбор хвоста литерала по
  балансу скобок с запретом второго ключа `requestedModel`. Хвосты 123-134 байта.
  Мутант-контроль: ключ, дописанный после `effort:Ze` (ровно то, что сделал бы апстрим), →
  красная; девятый сайт любой формы → красная. Разрешать столкновение молча (двигать наше
  поле в конец) намеренно НЕ стали: одноимённое поле апстрима может значить другое.

### Остаток раунда 5 — в работе
R5-3 (свип fork: слак 2..6 и радиус 20k), R5-4 (клип title и элементов deg; повтор чтения
`probes.toml`; pid в именах debug-файлов), R5-5 (проверка 12 считает не ту форму),
R5-6 (выбор ветки по строке из пула), R5-7 (OR двух форм вместо XOR), R5-10 (комментарий
про fail-open противоречит коду).

### Найдено мной при подготовке волны (не аудиторами)
- **R5-14 (низшая, doc-truth).** `judge/README.md` перечисляет debug-файл
  `last-response.json` «(HTTP status + raw body)». Положительный контроль: в патчере
  `last-request` — 1 вхождение, `last-response` — 0. Файл не пишется НИКОГДА. Ответ лежит
  в записи (`response`) рядом с породившим его запросом, поэтому правится ДОКУМЕНТ, а не
  добавляется вторая копия под фиксированным именем.
- **R5-4(а) шире, чем звучало.** Клип одного `title` гарантии не даёт: неограниченными
  остаются `cls` (захват регуляркой `[\w-]+` по тексту диспатча), `by` на пути
  `gate-failed:`+сообщение исключения, `err1`, `uw`, `sw`. Граница поставлена в САМОМ
  `__jlog` — обход всех строковых полей `__base` (400 знаков; массивы 8 элементов по 300),
  то есть граница принадлежит журналу, а не автору каждого поля, и новый вызывающий не
  может внести неограниченное поле просто не подумав. `rec` намеренно вне обхода: он
  добавляется ПОСЛЕ и он ключ соединения корпуса, а не проза.
  Про атомарность честно: `flock` в `node:fs/promises` нет, поэтому ограниченная строка И
  ЕСТЬ довод атомарности — одна `write()` под O_APPEND не перемежается, а любая строка,
  которую этот код теперь способен породить, укладывается в одну.

### Заземление, добытое измерением (для волны, не гипотезы)
- **Дискриминатор fork-дропов — структурный, не дистанционный.** Все настоящие дропы стоят
  после `,` / `:` / `=`; оба ложных (Vertex `O||L?void 0:` на 233, yoga `ae||A?void 0:u`
  на 247) — после `||`, где флаг лишь правый операнд чужого условия. С исключением `|&`
  на всех семи версиях НОЛЬ хитов вне радиуса, без него — ровно те два. Счёт: 2 на 233/240,
  3 на 242..247 ⇒ граница 2..3, а не 2..6. После патча строгих хитов 0, `||`-предварённые
  целы (233: 1, 247: 1).
- **Ветка `_stream_finalize_ok` выбирается по КОДУ у места финализации.** Ровно один
  `truncatedAfterOutput:` в пределах 3000 байт от якоря `tengu_streaming_partial_finalized`
  на 246/247 (расстояние 748) и ноль на 233/240/242/243/245 — одинаково в пристине и после
  патча. Строка в пуле без восстановления теперь ветку не переключит.
- **Перепись assistant-сайтов:** 8 на каждой из семи версий, из них 4 from-request —
  пристин и патч. Хвост литерала 123-134 байта.

### R5-15 (высшая по классу, найдено моей же волной) — блок проверок не разбирался НИКЕМ до сборки
Лишняя скобка в проверке `resume search pages in the tail` обнаружилась только ПОСЛЕ стадии
патча: `bash -n` считает heredoc данными, `node --check` про python ничего не знает, а
`tools/emit-check.js` разбирает вклеиваемый JS и не смотрит на проверки. Итог прогона —
`SyntaxError` вместо вердикта и 94 проверки, которые не выполнились НИ ОДНА. Гейт, который
не может исполниться, — не мягкий гейт, а отсутствующий; это третий случай того же класса
в кампании (мёртвый `emit-check.js` дважды, стенд, которого никто не звал).

Закрыто шагом `==> Разбор блока проверок` сразу после разбора вклеиваемого кода: heredoc
вырезается из самого скрипта и компилируется. Якорь ищется через `startswith`, а не
подстрокой, — в самой предполётной проверке маркер упомянут строкой, и поиск подстрокой
нашёл бы её саму вместо блока, который она защищает. Контроли: на живом файле «БЛОК
ПРОВЕРОК РАЗБИРАЕТСЯ (1924 строк)» rc=0; на копии с внесённой незакрытой скобкой —
«НЕ РАЗБИРАЕТСЯ: строка 1917: '(' was never closed» rc=1. `set -euo pipefail` действует,
значит ненулевой код останавливает конвейер до записи чего бы то ни было.

## Раунд 6, голос 1 (grok, линза K «стенд как программа»). Адъюдикация 2026-08-27
Аудитор назвал мутацию вклеиваемого кода для КАЖДОГО из 43 сценариев — пустых строк нет,
то есть ни один сценарий не пуст по построению. Находки — о том, что сценарий пинит НЕ ТО,
что обещает его комментарий.

- **R6-1 ПОДТВЕРЖДЕНО (проверено мной по коду).** `watch-threshold-valid-nondefault` не
  отличает порог 2 от порога, молча заменённого на 1: гейт возвращает `"fleet-busy:"+__n`,
  то есть СЧЁТ, а не порог, и при двух метках `2>=2` и `2>=1` истинны одинаково. Фикстура
  меняется на ОДНУ метку: соблюдённый порог 2 пропускает консультацию (`1>=2` ложь),
  подменённый на 1 — отказывает. Теперь различает.
- **R6-2 ПОДТВЕРЖДЕНО.** Объявление подрезки проверялось только со стороны шапки
  (`headerExcludes`). Перенос объявления из `__lbl` в хвост `__disp` — ровно то, что
  комментарий запрещает, — оставлял сценарий зелёным. Добавлена проверка `dispatchExcludes`
  и поставлена на `dispatch-truncated`, чья нагрузка слова «подрезан» не содержит.
- **R6-3 ПОДТВЕРЖДЕНО.** `watch-live-work` был сшит из двух предметов: гейта live-work и
  проектного слоя (`projectLayer` + `cfg`). Правка обхода слоя красила сценарий под именем,
  говорящим про живую работу. Разделены: слой уехал в собственный `watch-project-layer`,
  где гейт намеренно пропускает, чтобы вердикт решал ТОЛЬКО слой.
- **R6-4 ПОДТВЕРЖДЕНО, четыре из пяти.** `no-verdict-failopen` требовал лишь
  `{passed:true}` — добавлены `outcome:'empty'` и `poolCalls:2` (ступень + автоматическая
  повторная); `filtered` не требовал `by`, хотя три отказа делит один `outcome` и
  различает их именно это поле — добавлено `by:'classes_skip'`; `records-pruned` требовал
  только «осталось 2», что одинаково верно для подрезки, удалившей ТОЛЬКО ЧТО ЗАПИСАННУЮ
  запись и оставившей две засеянных, — добавлен счёт засеянных (`recordSeeds: 1`);
  `dispatch-whole` не требовал длины — добавлено требование, что весь прогон дошёл целиком
  (через содержимое, а не длину: длина пересказывала бы устройство входного объекта и
  устарела бы при добавлении поля). Пятое (`probe-absent-from-file` не пинит мерж
  `[defaults]`) ПРИНЯТО К СВЕДЕНИЮ без правки: мерж defaults пинит соседний
  `defaults-overridden`, дублировать нечего.
- **R6-5 ОТКЛОНЕНО обоснованно самим аудитором** — `block-not-enforced` и
  `watch-nudge-not-enforced` краснеют от одной формулы, но это два РАЗНЫХ потребителя с
  разными ожидаемыми строками, а не дубликат покрытия.
- **R6-6 ПОДТВЕРЖДЕНО, оснастка.** (а) `globalThis.__ccRecSeq` — четвёртый глобал, который
  пишет вклеенный код, и единственный, которого не было в снимке: он переживал сценарий.
  (б) Блок восстановления начинался с `chdir`, и бросок там пропускал ВСЁ остальное —
  восстановление не то место, где можно сдаваться рано; каждый шаг теперь независим.
  (в) `ENV_KEYS` перечислял 13 переменных, а вклеенный код читает 14 — измерено
  положительным контролем; нет `CLAUDE_JUDGE_TIMEOUT_MS`, и СВЕРХ названного аудитором нет
  `ANTHROPIC_BASE_URL` (последний адрес судьи). Родительская оболочка меняла срок и адрес
  во всех судейских сценариях сразу. Обе добавлены.

## Раунд 6, голос 2 (fable-auditor, линзы F+G: возврат к стоку / первый запуск на чистой машине)

Адъюдикация моя, каждое центральное утверждение перепроверено чтением.

| id | вердикт | суть | что проверил лично |
|----|---------|------|--------------------|
| R6-7 (F1) | ПРИНЯТО | Инструкции возврата нет нигде, кроме хвоста успешного прогона; README устарел | README: 8 секций (`grep '^#'` — положит. контроль), ни одной про restore; «78 checks» в строках 14/72/97 против EXPECTED_CHECKS=94; «Verified on 2.1.239» против установленного 2.1.247 |
| R6-8 (F2) | ПРИНЯТО | Печатаемый рецепт `cp "$BIN.orig" "$BIN"` нарушает доктрину этого же кита (живой inode) | Заголовок 14-26 мандатирует staging+rename; 2862-2870 печатает `cp`; дельта 247 против стока — 80960 байт, смещения едут |
| R6-9 (F3) | ПРИНЯТО, узкий | standalone `claude_patch.py` по tweakcc-патченному образу без `.orig` снимет `.orig` уже с патчем | guard 272-275 смотрит только на ROUTING_MARKER; пристинность `.orig` не проверяется нигде |
| R6-10 (F4) | ПРИНЯТО с поправкой | Дефолтный прогон пинит tweakcc на ЖИВОЙ ПАТЧЕНЫЙ образ; при несовпадении версий бэкап tweakcc перезаписывается патчеными байтами навсегда, после чего `--restore` печатает успех и возвращает патч | Поправка: «живое расхождение» из отчёта — снимок моего свипа (ccVersion ехал 240→243 при мне), не состояние машины. Но триггер реален: строки 200-217 показывают, что стейджинг есть ТОЛЬКО у `--update`, дефолт берёт живой бинарник с PATH; `startup.ts:112` — `realVersion!==backedUpVersion` → unlink + `backupNativeBinary` (копия ТЕКУЩЕГО); `installationBackup.ts:103-122` — restore пишет байты вслепую. Прямо сейчас ccVersion=243 при живом патченом 247 — состояние достижимо, и создаёт его наш же свип |
| R6-11 (F5) | ПРИНЯТО | Cleanup хранит бинарник, удерживаемый живым процессом, но не его `.orig` — отката на прошлую версию нет | keep-list 2811 — только текущая пара; замер: `2.1.239` есть, `2.1.239.orig` нет |
| R6-12 (F6) | ОПИСАНИЕ | Исходы проб на чистой машине поимённо; дефекта не заявлено | принято как карта, отдельной правки не требует |
| R6-13 (F7) | ПРИНЯТО | `fail_closed` не имеет env-носителя (только `__cfgbad` и `__cfg.fail_closed`), а боевой конфиг ставит `scripts/probes-sync.sh`, на который в дереве НОЛЬ ссылок | грепы: 2459 — единственная сборка `__fcl`; `probes-sync` — 0 попаданий по содержимому при существующем `scripts/probes-sync.sh` |
| R6-14 (F8) | ПРИНЯТО, ВЫСШАЯ | Запасной промт написан словарём судьи (`OK/WARN/BLOCK`) и лежит в общем core; парсер наблюдателя принимает только `SILENT|NUDGE` — при пропавшем промте каждая его консультация оплачивается и структурно не может дать вердикт | 2625-2634 (текст промта) против 2964 (`rx:"SILENT|NUDGE"`); ветки «словарь другой» в core нет |
| R6-15 (F9) | ПРИНЯТО | FATAL на чистом `~/.tweakcc` называет из выходов только люк `ALLOW_TWEAKCC_FAILURES=1` | 383-397 прочитаны; правильные первые действия в тексте не названы |
| R6-16 (F10) | ПРИНЯТО | Распознаватель принимает ЛЮБОЙ нативный образ по имени `claude`; проверки, что это Claude Code, нет | блок 217-258 прочитан целиком: только 4-байтовые магии, ни version-строк, ни маркеров |
| R6-17 (F11) | ПРИНЯТО, минор | Устаревший путь `~/.claude/judge/prompt.md` в доке и комментарии; фактический дом — `~/.claude/probes/judge/` | judge/README.md:698, tweakcc-patch.js:2623, docs/brief-judge-validate.md:22,80; рантайм-лейбл несёт верный путь |

Итог раунда 6: 6 находок от голоса 1 + 11 от голоса 2. Сходимость (два подряд нулевых раунда) не начата.

### Поправки к отчёту голоса 2 (мои, по перепроверке)

- **F11 частично неверен.** `docs/brief-judge-validate.md` — не устаревшая дока, а
  ХРОНИКА: в шапке стоит `Status: CHRONICLE` и прямая оговорка, что пути записаны
  так, как назывались тогда, и переписывать их нельзя. Аудитор процитировал строки
  22 и 80 как расхождение, не прочитав шапку. Правятся только два места, где старый
  путь выдаётся за сегодняшний: `judge/README.md:698` и `tweakcc-patch.js:2623`.
- **F7 расщеплён.** Достижимость боевой позы — принято и починено (kit и README
  называют `scripts/probes-sync.sh`). Env-носитель для `fail_closed` — ОТКЛОНЁН:
  у настройки уже есть дом (`probes.toml`), а второй дом для одного значения это
  ровно тот класс, который кит запрещает собственной проверкой «budget has one
  home». Асимметрия с `enforce` намеренная и теперь записана в README.
- **F8 подтверждён с уточнением:** дефект уже был НАЗВАН комментарием на самом
  гейте («the fallback prompt contains none of its vocabulary: the consultation
  would be payment for a guaranteed silence»), но закрыт только на ветке
  `__degb.length && __en`. При пустом конфиге `__en` ложно, гейт не срабатывает, и
  происходит ровно описанное. Комментарий переписан, иначе после фикса он лгал бы.

### Дефект, внесённый самой волной (найден `bash -n`, до сборки)

Одиночный апостроф в английском комментарии (`someone else's tool`) внутри heredoc,
который сидит в подстановке команд `$( ... )`, рвёт разбор ВСЕГО файла: bash ищет
закрывающую скобку, уважая кавычки, поэтому непарный апостроф открывает строку и
поглощает остаток. Ошибка всплыла на строке 693 — за тысячу строк от причины, в
другом heredoc. Констрейнт записан у самой границы heredoc. Класс закрыт тем, что
синтаксическая ошибка делает скрипт незапускаемым — тихого варианта у неё нет.

### Дефект в собственной правке F4 (найден до сборки, перечитыванием)

`PRISTINE_SRC="$BIN.orig"` неверен на пути `--update`: там `$BIN` оканчивается на
`.staging`, а пристинная копия лежит под именем БЕЗ суффикса (claude_patch.py:373).
Починка отравленного бэкапа молча вырождалась бы в предупреждение ровно на том
пути, где пристинные байты гарантированно есть. Форма: `${BIN%.staging}.orig`.

## Раунд 7, голос 1 (fable-auditor, линза N: атака на механизмы волны раунда 6)

Все десять находок — на коде, который я написал в предыдущей волне. Адъюдикация моя.

| id | вердикт | суть | проверка |
|----|---------|------|----------|
| R7-1 (A) | ПРИНЯТО к измерению, механизм назван неверно | Шаг 0b срабатывает и при `--only-ours` (условие смотрит только на TARGET и DO_UPDATE), а стадия tweakcc при этом пропускается — сборка из пристинной копии теряет ЕГО патчи | Условие 0b и `ONLY_OURS` на 428 прочитаны: пересечение реально. Названная аудитором проверка (`each probe fallback…`) — НЕ та: наши патчи при `--only-ours` накладываются. Ловят ли пропажу tweakcc-патчей другие проверки — измеряю прогоном, а не рассуждением |
| R7-2 (B) | ПРИНЯТО | Отравленный `.orig` не лечится и путём `--update`: `--download-only` копирует пристинные байты, только если бэкапа НЕТ; существующий патченый сохраняется, и ошибка 0b советует круг, который не размыкается | claude_patch.py:380-384 и 389-390 — обе ветки под `if not backup.exists()` |
| R7-3 (C) | ПРИНЯТО, ВЫСШАЯ | Мой собственный текст в README и в хвосте конвейера утверждает обратное коду: без `probes.toml` и с `CLAUDE_JUDGE=enforce` отменяется КАЖДЫЙ диспатч, а не проходит | `__en=__o.sw==="enforce"||…` (2458) + `prompt-missing` в `__degb` (2634) + гейт (2803). Сама фраза противоречит своему же придаточному |
| R7-4 (D) | ПРИНЯТО | Страж чинит бэкап из источника, чью пристинность не проверяет: `.orig`, снятый ДО нового guard'а, может нести патчи tweakcc при нулевом НАШЕМ маркере — и будет объявлен «восстановлен» | 548 смотрит только `OUR_MARKER`; TWEAKCC_MARKER добавлен этой же волной именно из-за этого класса |
| R7-5 (E) | ПРИНЯТО | Комментарий обещает «Detect it on every run», код пропускает обнаружение при `--only-ours` | 543-544 против 546 |
| R7-6 (F) | ПРИНЯТО как уточнение | `--target` обходит 0b, а новый отказ распознавателя людей на `--target` и отправляет: покрытие там «отравить-и-починить», а не «не отравить» | 323 (`-z "$TARGET"`) против 289-290 |
| R7-7 (G) | ПРИНЯТО | «skipped N candidate(s) **ahead of it** on PATH» перестало быть правдой: обход больше не останавливается на принятом образе | 278 против отсутствия `break` после 270 |
| R7-8 (H) | ПРИНЯТО | Ключ дедупликации — realpath; две ЖЁСТКИЕ ссылки на один inode дают два «разных образа» и ложный отказ | 250-253 |
| R7-9 (I) | ПРИНЯТО | 0b считает соседство по имени тождеством версии: устаревший `.orig` рядом с фиксированным именем даёт молчаливый откат версии, поданный как пересборка | 324 |
| R7-10 (J) | ПРИНЯТО | Прерванная починка бэкапа оставляет обрезанный файл, который навсегда читается как чистый (маркера в нём нет) | 549 — `cp` на месте |

Итог: раунд 7 не нулевой. Сходимость не начата.

### Дефекты волны раунда 7, найденные СОБСТВЕННЫМИ прогонами (до свипа)

1. **Сверка версий в 0b отвергала совпадающие версии.** Пропатченный образ печатает
   `--version` ДВУМЯ строками (своя и строка версии tweakcc), а `awk '{print $1}'`
   брал первое поле каждой: сравнивалось «2.1.247⏎4.3.3» с «2.1.247». Ложный отказ
   на КАЖДОМ дефолтном прогоне. Свип этого не поймал бы никогда — он ходит через
   `--target`, а 0b там не исполняется. Форма: `awk 'NR==1{print $1; exit}'`,
   исправлено в обоих местах (0b и страж бэкапа).
2. **R7-1 измерен, а не принят на слово.** 0b действительно срабатывал при
   `--only-ours`; сборка из пристинной копии теряла патчи tweakcc, и ловила это
   ровно ОДНА проверка из 95 — `CLAUDE.md alternates tried`. Названная аудитором
   проверка (`each probe fallback…`) была зелёной: механизм в отчёте неверен,
   вывод верен. После правки 0b на этом флаге не срабатывает, патчер отказывает
   громко и перечисляет 11 ненайденных сайтов, живой образ не тронут.
3. **Ни одна из 95 проверок не покрывала носитель `enforce` в переключателе** —
   мутант с `__en` без `__o.sw` собрался начисто. Теперь это держит стенд
   (`no-config-enforce-cancels`), мутация краснит ровно его.

## Раунд 7, голос 2 (grok-auditor, линза: перепись полноты по финальному состоянию)

17 расхождений. Адъюдикация моя; два центральных перепроверены лично.

**R7-11 (F1) — ПРИНЯТО, МЕНЯЕТ ЗАМЫСЕЛ.** Шаг 0b не снимает зависимость от чужого
бэкапа. `applyCustomization` для нативной установки БЕЗУСЛОВНО зовёт
`restoreNativeBinaryFromBackup` (patches/index.ts:619-621 в пиннутом SHA), то есть
пишет байты бэкапа поверх ccInstallationPath — а это после 0b мой стейджинг.
Пристинная копия затирается ДО патчей tweakcc. Мой проверочный прогон прошёл лишь
потому, что бэкап совпадал с пристинными байтами. Полное исправление — проверять и
чинить бэкап ДО стадии tweakcc, а не после, плюс утверждение после стадии, что в
цели нет нашего маркера. Мой комментарий «removes the dependency on a third party's
backup being intact» ложен и переписывается.

**R7-12 (F14) — ПРИНЯТО.** Мой комментарий «8 occurrences on 2.1.247»: `grep -c`
вернул 8 СТРОК, вхождений 11 (`grep -o | wc -l`). Величина названа не той, что
вернул инструмент.

Принято без оговорок, все — мой текст или мой код: F2 (README «каждая установка
оставляет .orig» — ложно для первого дефолтного и `--target`), F3 (комментарий
распознавателя всё ещё «take the first entry»), F4 («non-image candidate(s)» теперь
включает образы, не являющиеся Claude Code), F5 (нечитаемые кандидаты дают «not on
PATH»), F6 (проверка пристинности в 0b слабее, чем в 2b и `_is_pristine` — нет
маркера tweakcc), F7 (`--download-only` пишет `copy2` на месте — тот самый обрыв,
который 2b объявляет недопустимым; обрезанный файл потом считается пристинным),
F8 (`patch_binary` хранит любой существующий `.orig` без `_is_pristine`), F9 (мой
человеческий рецепт в 2b — `cp` на месте, запрещённый соседним комментарием), F10
(то же в `claude_patch.py:350`), F11 (README про запасной промт безусловен, а при
enforce консультации нет), F12 (предупреждение хвоста привязано к `probes.toml`, а
описывает отмену от `prompt.md`), F13 (`docs/idle-watch.md` и `idle-watch/README.md`
всё ещё объясняют пропуск отсутствием словаря — правил только комментарий в ядре),
F15 (README «cleanup хранит только текущую версию» против моего же изменения в той
же волне), F16 (README «только после дыма» преуменьшает поздние гейты), F17 (README
приписывает 95 проверок файлу `tweakcc-patch.js`).

Отдельно принят вывод переписи гарантий: НИ ОДНА новая гарантия конвейера (0b,
страж, распознаватель, cleanup, `--download-only`) не закреплена ни проверкой, ни
сценарием — все 95 проверок суть байтовый поиск по собранному образу и по
устройству не видят путей сборки. Это пробел класса, а не отдельная находка.

Итог: раунд 7 не нулевой (10 + 17). Сходимость не начата.

## Волна 8 — применена (раунд 7, скрипты 21–25 + две правки по ходу)

| скрипт | что закрыл | файл |
|---|---|---|
| 21 | страж бэкапа tweakcc переехал из «после стадии» в **шаг 1b, до неё** (`--apply` первым делом восстанавливает бэкап ПОВЕРХ цели, значит сборка начинается с бэкапа, а не с моей стейджинг-копии); после стадии — утверждение «в цели нет нашего маркера»; тест пристинности в 0b теперь отвергает и `.orig` с меткой `tweakcc`; снят ложный комментарий «0b делает сборку независимой от чужого бэкапа» | claude-patch-all.sh |
| 22 | все три записи `.orig`/бэкапа — атомарно (`copy2` во `.new` + `os.replace`); `patch_binary` **умирает**, а не хранит непристинный `.orig`; отказ снимать снимок с цели, прошедшей стадию tweakcc; печатаемый рецепт восстановления — по переименованию; счётчик в комментарии честный (11 вхождений, `grep -c` показывает 8, потому что считает СТРОКИ) | claude_patch.py |
| 23 | комментарий распознавателя описывал «берём первый образ» при правиле «ровно один»; подпись «non-image candidate(s)» при том, что в списке теперь и настоящие образы чужих продуктов; PATH из одних нечитаемых файлов давал «claude не на PATH» | claude-patch-all.sh |
| 24/24b | README: `.orig` оставляет не «каждая установка», а `--update`; запасной промт при `enforce` не используется вовсе; cleanup хранит и версию живой сессии; переключение сборки — после проверок И дыма И интерфейса И стенда; строка таблицы приписывала 95 проверок не тому файлу. docs/idle-watch.md: причина пропуска консультации описана через «нет правил — нечем судить», а не через устаревшее «у запасного промта чужой словарь». claude-patch-all.sh: хвостовое предупреждение привязывало отмену к `probes.toml`, хотя отменяет отсутствие `prompt.md` | README.md, docs/idle-watch.md, claude-patch-all.sh |
| 25 | **класс-пробел раунда**: все 95 проверок — байтовые поиски по СОБРАННОМУ образу, ветка сборки (0b, стейджинг, въезд переименованием, сохранность чужого бэкапа) не покрыта ничем, а свип ходит через `--target` и в неё не заходит. Разовый прогон из `/tmp` перенесён в кит как `tools/build-path-probe.sh`: случай (a) патченый живой + пристинная копия, случай (b) чистая машина, случай (c) **отрицательный контроль** — та же (a) против копии конвейера с выключенным триггером 0b, и хотя бы одно утверждение (a) обязано покраснеть | tools/build-path-probe.sh, README.md |

Две правки по ходу применения (мои же дефекты, найдены личной вычиткой диффа, не аудитором):
* скрипт 23 сложил в один список `seen` две роли — ключи инодов для дедупликации и ответ на «нашёлся ли вообще claude». Работало по совпадению типов. Полный фикс: отдельный `candidates`, заполняемый ДО любого чтения содержимого; `seen` остался только дедупликацией.
* комментарии той же правки были написаны по-русски внутри английского блока — переписаны на язык блока, с оглядкой на запрет одиночного апострофа в этом heredoc.
* зонд читал инод только диалектом BSD (`stat -f%i`); на GNU это молча дало бы `none`, что читается как «файл исчез», а не как «не тем диалектом спросили».

## Раунд 8 — два голоса, шесть линз; адъюдикация

Голос 1 (линзы J единицы, L одновременность, M второй экземпляр ядра);
голос 2 (линзы H время, I канал, ведущий себя неправильно). Каждое утверждение
ниже проверено мной лично чтением файла; там, где сказано «замер» — числами.

### Принято к исправлению (волна 9)

| № | суть | доказательство |
|---|---|---|
| M2 | **корень шире поданного**: гейт наблюдателя даёт прошлой метке диспатча перебить ЧИТАЕМЫЙ реестр задач. Аудитор увидел частный случай (диспатч, отменённый судьёй), корень — любая метка о прошлом, включая давно завершённый диспатч | замер по `~/.claude/probes/idle-watch/journal.jsonl`, 559 строк: `live-work` 345, `fleet-busy` 56, `window-not-filled` 13. Реестр читаем, и всё равно 56 раз тишина по меткам. Врезки: наблюдатель `tweakcc-patch.js:3128` (главный диспетчер), судья `:3131` (внутрь `call` тула) — метка кладётся ДО броска |
| M2-док | `docs/idle-watch.md:32-36` «одна врезка, сразу после судейской», «наблюдатель никогда не доходит до отменённого вызова» | врезок две, порядок обратный |
| M1 | `prompt.extra.md` читается только из проектного слоя (`:2614`), как и сказано в `judge-architecture.md:217`; `probe-core.md:36` и `idle-watch.md:178` перечисляют его в ДОМАШНЕМ каталоге | греп по `prompt.extra` даёт ровно два чтения, оба проектные |
| J1 | три ответа на «бюджет вывода без конфига»: 300 (`:2683`, ветка catch — она же штатная при отсутствии `body.json`, потому что `if(!__tplr)throw`), 1200 (`:2721`), 1200 (`:2729`) | док фиксирует замер 434-2120 токенов и то, что 1200 однажды урезал отмену в молчание |
| J5 | срезы ленты `slice(0,400)` и `slice(0,300)` без объявления, при собственной конвенции ядра | проверка `judge declares every truncation` (`claude-patch-all.sh:2471`) — перечень запрещённых конкретных срезов, а не утверждение свойства; имя шире содержания |
| J8 | циклы подрезки меряют полом `__b=max(60,__n)`, маркерная фаза — `__n` | при `context_chars` 1..59 фаза гонится за недостижимой целью |
| J4 | срез рвёт суррогатную пару; одинокий суррогат уезжает в JSON и в текст, который читает модель | `__clip` и `__fit` режут по code units |
| L1 | одновременная подрезка `records/`: ENOENT соседа обрывает остаток списка и уходит в канал настоящего отказа | |
| L2 | `records_keep` — горизонт, общий для всех сессий; расчёт ёмкости в доке ведётся от одного писателя | |
| M4 | комментарий ядра называет `.claude/judge` и `CLAUDE_JUDGE_DIR` | код ходит в `.claude/probes` (`:2317`), читает `CLAUDE_PROBES_DIR` (`:2949`, `:2989`) |
| M5 | домашний путь проб вычислен двумя одинаковыми выражениями, и два имени (`__jdir`, `__dir`) держат одно значение | |
| H1 | интервалы, `nextAt`, окно, остывание и метки — на стенных часах, обрыв ступени — на таймере цикла; `ms` в журнале может выйти отрицательным | |
| H2/H5 | подрезка режет по лексикографическому `sort()`; счётчик в имени без ведущих нулей (`10` раньше `9`) | исполнимая часть: своя только что записанная запись не должна попадать под нож |
| H3 | `judge-architecture.md:287` «порог по умолчанию 60 с (`timeout_ms` в поставке)» | поставка `probes/probes.toml:3` — `240000` |
| H4 | комментарий обещает повтор «на половине дедлайна», код передаёт полный `rung.timeout_ms` | правится КОД: повтор шлёт короткий хвост, полный бюджет противоречит его смыслу |
| I1 | `judge-architecture.md:539` «всякий путь отказа — fail-open» | поставка судьи: `enforce=true` + `fail_closed=true`, то есть отменяет |
| I2 | словарь сверяется с учётом регистра (`"gm"`, `:2785`), поэтому `ok: fine` = «нет вердикта», а при fail_closed «нет вердикта» = отмена | правило действия (`:2859`, `"m"`) обязано получить флаг вместе с разбором, иначе `block:` запишется как отмена и не отменит |
| I4 | модель, которая ответила, нигде не записана | гейтом делать нельзя: шлюз штатно отвечает другим идом (`grok-4.6` → `grok-4.6-build`) |
| I5 | тело OpenAI с content-МАССИВОМ (`String([...])`=`"[object Object]"`, truthy — до чтения блоков не доходит) и тело с BOM не разбираются | наш же `judge/channel.py` массив разбирает; для файлов BOM снимается, для тела канала — нет |
| I6 | обрыв на потолке вывода становится полноценной отменой с неполной причиной; `finish_reason` не читается | вердикт сохраняется, обрыв ОБЪЯВЛЯЕТСЯ — выбрасывать решение значило бы превратить настоящий BLOCK в «нет вердикта» |
| J2/J3 | «78 проверок» трижды, «36 сценариев», потолок «3000 → 8000» как текущий | факт: `EXPECTED_CHECKS = 95`, `EXPECTED_SCENARIOS = 48`, поставка `max_tokens = 24000` |

### Отклонено

* **J7** «один литерал в двух единицах» (`8000` как мс и как знаки; `60000` как коэффициент и как дефолт) — ловушка редактирования, дефекта нет, чинить нечего.
* **I3** «вердиктное слово на своей строке внутри цитаты формата становится вердиктом» — свойство строчного протокола, а не дефект. Разбор уже берёт ПЕРВУЮ вердиктную строку; требование «вердикт первой строкой» стоит в промте; запрет на строку не первую сломает рассуждающие модели, ради которых лояльность и вводилась (замер 2026-08-20: с объяснением впереди модель тратила бюджет и обрывалась ДО строки вердикта). Улучшающей правки разбора не существует — проверено перебором вариантов.
* **дубли ключей JSON (last-wins)** — семантика `JSON.parse`, не наша.

### Покрытие

17 новых проверок по собранному образу (95 → 112) и 5 сценариев стенда (48 → 53).
Отдельно отмечаю честно: **BOM покрыт только байтовой проверкой** — стенд ходит
через pool-канал, где тело не бывает текстом с BOM; сценарий на него потребовал бы
HTTP-приёмника и в эту волну не вошёл.

---

## Волна 9 — итог применения (2026-08-27)

Волна применена скриптами 31-43. Два дефекта нашли НЕ аудиторы, а собственные
гейты на первой сборке, где им дали заговорить.

### G1 — столкновение имени `__c2` (нашла проверка, поймала мою же правку)

Скрипт 33 назвал новую локальную переменную разбора `__c2`. Ровно этот
идентификатор запрещён проверкой `judge counts trimmed records honestly`
(`claude-patch-all.sh:2299`, `len(re.findall(rb'__c2', d)) == 0`): так звался
счётчик вызовов подрезки, чьё удаление проверка и доказывает.

Починено во ВКЛЕИВАЕМОМ КОДЕ (`__c2` → `__cv`), не ослаблением запрета.
Запрет и есть гарантия; пропустить тёзку значило бы снять единственное, что
стоит между нами и возвращением счётчика.

### G2 — сентинел «никогда» на монотонных часах (нашёл стенд зондов)

Волна 9 перевела все длительности зонда на `globalThis.__ccMono`. Одно
сохранённое число за ними не поехало: `last` наблюдателя (момент прошлой
консультации) инициализировался нулём и сравнивался как
`__now-__s.last<__cd`.

* при `Date.now()` ноль = 1970 = «никогда, давно»;
* при `performance.now()` ноль = **старт текущего процесса**.

Свежая сессия читается как «только что говорил» и молчит целый кулдаун после
заполнения окна, записывая в журнал `cooldown`, неотличимый от настоящего.
В проде это прячет окно, пока `cooldown_min <= window_min` (оба дефолта 30);
подняв кулдаун выше окна — настройка, которую файл предлагает, — получаем
немого наблюдателя ровно на разницу. То самое «луп работает, флот стоит»,
ради которого он и существует, созданное его собственной бухгалтерией.

Замер стенда до правки: **14 из 15 сценариев наблюдателя** — `by=cooldown`,
канал 0.

Починено в корне: «никогда» = `null`, значение вне пространства значений.
Оно верно при ОБЕИХ ветках `__ccMono` — и при `performance.now`, и при
запасной `Date.now`, — чем ноль не был никогда.

Перепись всех сравнений с `__ccMono()` (`__t0`, `__s0`, метки `__ccFleet`,
`__s.start`, `__s.nextAt`, `__s.last`): единственным несогласованным был
`__s.last`. Отметки флота кладутся и фильтруются одними и теми же часами
(`tweakcc-patch.js:3125` и `:3169`), `__ccWatch`/`__ccFleet` живут только в
`globalThis` и на диск не переживают.

### Перепись срезов стала проверкой и расширена

Раунд 8 заменил перечень известных плохих подрезок переписью `.slice(0,` по
собранному ядру, и перепись сразу нашла ещё четыре, которых в перечне не было.
Она была ручной. Теперь это проверка `every cut in the probe is named`, и
расширена на **каждый** `.slice(` в обоих блоках зонда: хвостовой и
двусторонний срез теряют текст так же молча, а форма «срез с головы» была лишь
той, которую мы искали.

Объявлены четыре найденные подрезки:

| место | было | стало | почему важно |
|---|---|---|---|
| эхо неверной настройки | `String(__v).slice(0,24)` | `__clip(__v,24)` | обрезанное значение читается как ДРУГОЕ значение — ровно тот отказ, ради конца которого сообщение и написано |
| страховочный обрез массива в строке журнала | `__v2.slice(0,8).map(...)` | `__dcut(__v2,8)` | тот же поэлементный клип, плюс объявление; все массивы, реально доходящие сюда, уже режутся `__dcut` |
| ид ответившей модели, HTTP-путь | `String(__sv).slice(0,80)` | `__clip(__sv,80)` | обрезанный ид не «короче», а НЕВЕРЕН, при том что поле существует как улика подмены модели |
| ид ответившей модели, pool-путь | `String(__sv2).slice(0,80)` | `__clip(__sv2,80)` | то же |

Остаток переписи (15 срезов) — структурные: BOM ×3, половины суррогатной пары,
пара кавычек `JSON.stringify`, копия массива, кольцо отметок флота,
восьмизначный хвост ключа в имени записи, список жертв подрезки, и четыре
объявляющих (`__dcut`, `__clip`, голова диспатча, голова/хвост ленты).

### `budget-negative` — честно устаревшее ожидание

Стенд ждал `1200`. Волна 9 свела три ответа на «бюджет вывода, когда ничего не
сказано» (300 в теле raw-HTTP и 1200 дважды на pool-пути) к одному `__mtd=8000`.
Ожидание обновлено до 8000.

### Ни одна из двух новых проверок не пустая — названы мутации

| мутация образа | что краснеет |
|---|---|
| новый безымянный `.slice(0,99)` внутри блока зонда | `every cut in the probe is named` |
| `__clip(__sv,80)` → `String(__sv).slice(0,80)` (снять объявление) | `every cut in the probe is named` |
| `{last:null,...}` → `{last:0,...}` | `the watcher's "never" is not a clock reading` |
| убрать страж `__s.last!==null&&` | та же проверка И сценарий `watch-never-spoke-no-cooldown` |
| `__cd` → `0` (кулдаун не срабатывает никогда) | сценарий `watch-cooldown` |

Пара двусторонняя: кулдаун обязан срабатывать на настоящей прошлой
консультации и не срабатывать без неё.

**Граница, объявленная честно:** каждый сценарий наблюдателя сам засевает
`globalThis.__ccWatch`, поэтому собственный инициализатор образа
(`??={last:null,...}`) стендом не исполняется вовсе. Половину «инициализатор»
держит проверка блока (краснеет на `last:0`), половину «страж» — сценарий.
Два инструмента, ни один по отдельности не есть гарантия. Записано
комментарием рядом со сценарием.

### Покрытие волны 9

Проверок 112 → **114**, сценариев стенда 53 → **54**.
Сборка 2.1.247: `ok=114 fail=0`, гейт интерфейса зелёный, стенд 54/54.

---

## Волна 9 — что нашли собственные снасти на прогонах (2026-08-27)

Три дефекта подряд, и ни один не пришёл от аудитора: их нашли запуск,
положительный контроль и первый в жизни прогон инструмента.

### G3 — зелёная сводка над загрязнённым артефактом

Первый свип был убит на ходу (я правил `claude-patch-all.sh`, пока bash его
исполнял — bash читает по байтовому смещению). Убиты были цикл и конвейер,
но **не их потомки**. Уцелевший `node … --apply` от tweakcc сохранил
унаследованный дескриптор лога и продолжил патчить **тот же файл образа**,
которым уже пользовался перезапущенный свип.

Улика в `sweep-233.log`: два блока `Customizations applied successfully!`,
причём второй — ПОСЛЕ нашей верификации, плюс дыра в 603 нулевых байта между
переплетёнными потоками. Количественное подтверждение: `tweakcc=32` в грязном
прогоне против `16` в чистом, ровно вдвое.

Побочно вскрылось: **`grep -c` на логе с NUL-байтом не печатает ничего и
выходит с 1**, поэтому `ok=$(grep -c …)` дал бы пустую строку и сводка
прочиталась бы как `ok= fail=`.

Снасть переделана: все счётчики `grep -a -c` и проверяются на числовость;
лог с NUL помечается `ЛОГ СМЕШАН(NUL)`; требуется **ровно одно** применение
tweakcc и **ровно одно** наше на прогон (это и поймало бы инцидент само);
прогон уходит в собственную группу процессов, чтобы убиваться с потомками;
отказ стартовать, если жив процесс предыдущего прогона.

### G4 — страж, который не мог сработать

Страж «жив ли предыдущий прогон» я написал через `$2 ~ /claude-patch-all\.sh$/`.
В `ps -eo pid,args` `$2` — это интерпретатор (`bash`), путь скрипта — `$3`.
Проверка не могла найти ничего никогда. Поймано **положительным контролем**:
подставной `bash <dir>/claude-patch-all.sh` страж прошёл насквозь. После
правки находит его и отказывает с rc=1, на чистой машине молчит.

Заодно снято самосовпадение: `ps | awk '/шаблон/'` находит собственную
командную строку awk, поэтому снимок `ps` снимается ДО запуска awk.

### G5 — зонд ветки сборки не исполнил ни одного случая

`tools/build-path-probe.sh` написан в волне 8 и запущен впервые сегодня.
Он отказал на первой строке: «`2.1.247.orig` несёт наш маркер». Замер по всем
семи исходникам свипа: `ours=0 tweakcc=0` — все чисты. Врал прибор:

```
marks() { grep -c -a -F "$OUR_MARKER" "$1" 2>/dev/null || echo 0; }
```

`grep -c` при нуле совпадений печатает `0` И выходит с 1, поэтому `|| echo 0`
срабатывает ПОВЕРХ напечатанного и функция возвращает `"0\n0"`. Все сравнения
читают это как «не ноль»:

| строка | проверка | факт |
|---|---|---|
| 81 | `== 0` «живой бинарь без наших патчей» | не могла сработать никогда |
| 85 | `!= 0` «исходник не чист» | срабатывала на любом чистом — это и есть отказ |
| 149 | `== 0` «бэкап tweakcc остался чист» | не могла выполниться никогда |
| 206 | `!= 0` «бэкап отравлен», в ОТРИЦАТЕЛЬНОМ КОНТРОЛЕ | считалась покрасневшей безусловно |

То есть зонд не исполнил ни одного случая, а его отрицательный контроль — тот
самый, что доказывает неукрашательность утверждений, — сам был украшением.
README при этом утверждал, что ветка сборки покрыта.

Корень починен, и добавлена **самопроверка прибора до доверия к нему**:
временный файл с маркером и без, ожидание `1` и `0` (и `0` на отсутствующем).
Контроль: со старым помощником самопроверка падает с уликой
`есть=1 нет=0\n0 отсутствует=0`, с новым проходит.

Прогон после починки:

```
case a  ok  взял ветку staging; подменил переименованием (inode 1400418091 -> 1400418240);
            стейджинг не остался; сборка несёт наши патчи; бэкап tweakcc стоковый
case b  ok  пропатчил на месте, как и должен; стейджинг не остался; несёт наши патчи
case c  red «staging branch not taken» — мутация красит 1 утверждение случая (a)
```

### Гейт чисел расширен с доков на код

Первая редакция читала `README.md` и `docs/*.md`. Тот же скан по коду нашёл
ещё три текущих утверждения: `drives 37 scenarios` в конвейере и дважды
`the 95 checks` — в заголовке того самого зонда, который объясняет, что
проверки ветку сборки не видят.

Два действительно исторических числа НЕ освобождены пометкой, а переписаны так,
что число исчезло: смысл фразы «94 checks that never ran» был в том, что не
отработала НИ ОДНА, а не в том, что их было 94. Число, которому нужна
индульгенция, всё равно будет прочитано следующим человеком как текущее.

Контроли гейта: протухшее число в заголовке инструмента → rc=1 с именем файла
и строки; протухшее в комментарии конвейера → rc=1; журнал кампании со своими
историческими «22 checks» → rc=0.

### Общий вывод волны

`|| echo <дефолт>` после команды, которая ПЕЧАТАЕТ при неуспехе, не подставляет
значение, а дописывает второе. `grep -c` — ровно такая команда. Этот дефект
встретился в волне трижды: в `marks()`, в моей же однострочной проверке бэкапа
и как класс — в счётчиках свипа. Форма без этой ловушки:
`n=$(cmd); case "$n" in ''|*[!0-9]*) echo 0;; *) echo "$n";; esac`.

---

## Round 9 — fresh-eyes on waves 6–9 (HEAD 8d5e90b). Two voices + my own measurement.

Voices: `fable-auditor` (lenses N/O as F1–F2), `grok-auditor` (lenses N/O as G1–G4).
Both worked against the tree equal to `8d5e90b`; I held every fix until both
returned so their citations could not drift under them.

Findings: 0 highest, 5 medium, 2 low. All confirmed by me personally by reading
the files, and all fixed in wave 10 (`/tmp/cc-matrix/wave10/48..53`).

### F1 [medium, fable] — the one text cut that skipped the seam repair
`tweakcc-patch.js` `let __disp=__dtr?__dsrc.slice(0,__dmax):__dsrc;` was the only
cut of model-read text not wrapped in `__sur`, while the comment introducing
`__sur` asserted "Every slice in this code runs through here". False in both
directions: cuts that are NOT text (the fleet ring, the prune victim list, the
key suffix, the JSON quote pair) must not go through it, and the dispatch head,
which should have, did not.

The check could not have caught it — `no cut leaves a lone surrogate` pins the
two `__sur` sites that exist, so no mutation of the dispatch cut reddens it.
Fixed by giving the CENSUS a second axis instead of adding a third pinned site:
`_every_cut_is_named` now keys on `(argument, inside __sur)`. Two sites share the
argument `0,__k` (`__clip` cuts characters, `__dcut` cuts a list) and only the
axis separates them.

Proof the axis adds power: unwrapping `__clip`'s cut leaves the argument multiset
identical (`0,__k` still twice) and reddens the census anyway.

### G1 [medium, grok] — three defects in the build-path probe's negative control
1. The mutation `sed 's/&& grep -q -a -F "$OUR_MARKER" "$BIN"; then/&& false;
   then/'` was unanchored and rewrote TWO lines — 0b's trigger (:364) and the
   post-stage assertion (:663) — while its own comment promised the post-stage
   assertion was "left alone". Measured: unanchored 2 lines, anchored 1.
2. The verdict was "at least one of case (a)'s assertions reddened", with
   `rc != 0` among the counters — so any mutant that merely crashes the pipeline
   passed as proof about the staging branch. The required red is now NAMED (the
   staging announcement); the rest are additional evidence; `rc` is reported and
   never counted.
3. The assertion 0b exists for could not fire in either direction. tweakcc's
   startupCheck refreshes its backup only when `realVersion !== backedUpVersion`;
   the probe placed a patched binary and a same-version `.orig` side by side and
   never touched the recorded version, so the backup was never rewritten in ANY
   case and `marks(backup) == 0` held by construction. The probe now seeds the
   mismatch before every run — the state 0b's own comment calls "not exotic" —
   and snapshots/restores the config the way it already did the backup. That
   snapshot, until now, was protecting a file nothing wrote to.

### F2 [low, fable] — absence passing as cleanliness
`[[ "$(marks "$TWEAKCC_BACKUP")" == 0 ]] && ok "tweakcc's backup is still stock"`
— `marks()` answers 0 for a stock file AND for a missing one (its own self-test
asserts exactly that). Now an explicit three-way: missing is its own finding with
its own words.

### G2 [medium, grok] — one floor in the comparison, another in the arithmetic
The marker phase's loop condition was moved onto `__b = max(60, __n)` and its
step left on `__n`: `__fit(__i,Math.max(60,__w[__i]-(__tot+__mc-__n)))`. The
check pinned the comparison only, so the mixed state was green. At the legal
setting `context_chars=0` (`__n=0`, `__b=60`) the phase over-cuts by the whole
floor — in exactly the corner the comment above it says the two disagree. The
check now pins the arithmetic in both directions.

### G3 [medium, grok] — a scenario with no specification counted as conforming
`checkMismatch: if (!expected) return false` — `false` means "no disagreement".
The authors met this defect once (the comment above `missing-prompt` records it,
and the two spec-less scenarios were the two REFUSALS) and closed it by writing
the two missing specifications rather than by closing the door. Now: a load-time
assertion names any scenario without `expected` and exits 2, and `checkMismatch`
reads a missing specification as a MISMATCH if the door is ever edited away.
Proven: `expected:` renamed at one site → `exit=2`, `сценарии без expected: ok`.

### G4 [low, grok] — a salvage that can cost more than the attempt
`Math.max(1000,Math.round(rung/2))` with `timeout_ms` sanitised at min=1: any
rung under 2000 ms gets a retry LONGER than the rung it rescues. The check pinned
`/2` and never saw the floor. Now clamped above by the rung, and the rung is read
once into `__rt` — reading config twice in one statement is the defect named four
lines above for `__rcc`.

### M1 [mine] — a measurement in a comment that the journal did not support
The comment claimed "Measured 2026-08-23: 29% of dispatches hit the cap, and one
BLOCK cancelled a sound call over our own truncation."

Counted over the judge's own 709 records carrying a DISPATCH block: **34 of 163
on 2026-08-23 (21%), 63 of 709 overall (8.9%)** — not 29%. The cut ones need no
marker to identify: they plateau at exactly 4000 payload characters, the cap then.

The causal half is TRUE and now names its evidence:
`2026-08-23T18-52-35-972Z-bSujKvKU`, cut at 4000, blocked with "бриф — последний
пункт раздела «Rules of this dispatch» оборван на середине слова". I nearly
recorded this half as false by stopping at the first BLOCK mentioning truncation
(`2026-08-24T03-48-11-854Z`, 2707 chars, complete text, blocked for a missing
`<!-- BRIEF COMPLETE -->` marker — a sound BLOCK, not ours). First match is not
the match.

Also recorded in the comment: nothing has been cut since the cap rose to 16000 —
largest dispatch on record is 7447 characters. The declaration is exercised only
by the bench, and the comment now says so instead of letting a reader assume the
field tests it.

### M2 [mine, prompt layer] — the verdict token read as a question
One verdict in 715, `BLOCK: нет — вызов корректен по всем трём осям`
(`2026-08-22T08-10-23-617Z`, glm-5.3), cancelled a call the judge was approving:
the model answered `BLOCK:` as a question rather than printing it as a decision.

NOT fixed in the parser. The ratified design is "better a false cancellation than
a silent pass", and teaching the parser to read "BLOCK: нет" as approval is the
move toward silent passes that principle refuses. Fixed in the prompt, which
printed the three forms and never said the token IS the decision.

### Withdrawn [mine]
"The judge's prompt describes a tail marker `[диспатч подрезан: …]` that the code
no longer emits." I read that text out of an **08-23 record**, i.e. the prompt as
it was captured then, and compared it against today's code. The live
`~/.claude/probes/judge/prompt.md:56-64` describes the header form correctly.
Comparing a historical artifact with current code is the like-with-like rule, and
I broke it. Withdrawn before it reached a fix.

### Accepted from grok's adjudication list, re-read personally
- `context_chars`/`dispatch_chars` at `min=0` vs `min=1` elsewhere: NOT a defect
  at that axis. `__num`'s `min` is a rejection floor with a declared degradation;
  `dispatch_chars=1` would empty the brief just as `0` does, so raising the floor
  fixes nothing. Zero carries three meanings by key — off, garbage, empty text —
  and each is declared. Kept.
- The 0b comment's claim that the poison state "is not exotic": now load-bearing,
  since the probe reaches it deliberately.

### Instrument note
`judge declares every truncation` reddened when F1's fix landed — it pins the
dispatch cut's exact text. Updated to the wrapped form. A check that notices its
own subject being repaired is a check with teeth.

### R1 [mine, lens R — the gate ladder; RAISED, fix not yet designed]

The ladder is 0 → 0b → 1 → 1b → 2 → 3 → 4 → 5 → 5a2 → 5a3 → 5b. Asked of it:
which stage catches which corruption, and is there a corruption no stage catches.

Measured on the current tree:

| where | positional anchors |
|---|---|
| `tweakcc-patch.js` (the patcher) | module-boundary markers 3, anchor windows 17, offset searches 14 |
| the 112-entry check block | **0 of every kind** — no boundary marker, no offset, no window, no distance |

And of the checks themselves: 65 of 112 are bare `re.search` — existence only.

So the patcher decides WHERE, and the checks only confirm that some text exists
SOMEWHERE in the collapsed payload. The text they look for is the text the
patcher wrote. If site selection is ever wrong — a same-shaped site in the wrong
chunk, which is exactly the hazard chunk-local minified names created from
2.1.242 — the patcher writes its replacement into the wrong module and all 114
checks stay green, because they find precisely what was written.

What the three behavioural gates cover instead: `--version` (smoke), one TUI
render on a pty (interface), the probes (bench). A wrong-site edit outside those
paths — resume paging, the model picker, the provider lane — is touched by none.

NOT yet a confirmed defect: it requires that a wrong-site application be
reachable given the patcher's own bounding. That is the question to settle, and
the answer decides the shape of the fix — most likely that a check pinning text
the patcher wrote must also assert it lies inside the module the patcher aimed
at, rather than anywhere in the image.

Held for adjudication with round 10's two returns rather than designed alone
mid-round.

### R1 — resolved, and it narrowed to one site (R1a, fixed)

The open half of R1 was "is a wrong-site application reachable at all". Answered
by counting rather than by argument. Of 32 patch announcements in
`tweakcc-patch.js`:

* 31 bind their edit either to a MODULE (`moduleTextAt` / `editModuleAt`) or to
  an explicit refusal on ambiguity (`if (x.length !== 1) fail(...)`,
  `if (candidates.length > 1) fail(...)`).
* 1 did neither: the system-prompt dispatch-cancellation rule matched with a
  non-global regex and rewrote with a non-global `js.replace`, which takes the
  FIRST match silently. Nothing asserted there was only one.

My first census put two sites in the unguarded column; the second, the statusline
throttle, turned out to be bound more tightly than most — it goes through
`moduleTextAt`/`editModuleAt`, and my pattern simply did not know those helper
names. A census is only as good as its vocabulary, and the way to find that out
is to read every hit rather than trust the count.

So R1's broad form does NOT hold: the check block's position-blindness is a
second, weaker instrument standing behind a first instrument that IS
position-aware in 31 of 32 sites. Rebuilding 112 checks to be position-aware
would be the wrong fix. The right one was to make the first instrument uniform.

R1a: that site now counts its matches globally and refuses on anything but one,
in the idiom its 31 neighbours already use. Whether the count is in fact 1 on
every version is not something I can assert from having written the assertion --
the sweep across 233/240/242/243/245/246/247 is what measures it, and it is
running. A refusal on some version would itself be the finding.

---

## Раунд 10 — закрыт волной 11 (`5de4c77`)

Два голоса, обе линзы новые: «прогон, оборванный посередине» (17 находок:
F1-F3 высшие, F4-F9 средние, F10-F17 низкие) и «писатель против читателя»
(5 находок). Итого 22 — сходимость не начата.

Отчёты голосов существовали ТОЛЬКО в транскрипте: голос Q прямо написал
«Report file not created — my operating rules are read-only». После компакции
контекста они были бы потеряны. Вытащены из `.jsonl` и положены на диск:
`round10-mech-partial-state.md`, `round10-claim-writers-readers.md`.
УРОК ПРОЦЕССА: диспатч аудитора обязан либо разрешать запись отчёта, либо
контроллер обязан сохранять `<result>` в файл СРАЗУ по приходу.

Все 22 починены. Пять — раньше (F1/F2/F3/P1/P3), шестнадцать — волной 11.
Разбор каждой правки и её доказательства — в сообщении коммита `5de4c77`.

Два побочных результата волны, важнее части находок:

1. **Две проверки покраснели на свипе по делу** — они пинят дословную форму
   слияния слоёв конфига, в которую F15 вставил `__cfgseen`. Механизм
   сработал: правка ядра не проходит мимо проверок.
2. **Перепись после правок: три НОВЫЕ гарантии ядра не были запинены ничем**
   (`prompt-truncated`, `body-no-placeholder`, `rec-write`). Добавлены три
   проверки, 114 → 117. Первая редакция проверки на `body-no-placeholder`
   оказалась беззубой: пинила нагрузку без её ОХРАНЫ, и мутация
   `if(__miss.length&&!1)` проходила зелёной. Класс повторяется — тот же, что
   у F2 прошлой волны. **Правило: проверка пинит ветку вместе с условием,
   иначе она проверяет только присутствие текста.**

Гейты на `5de4c77`: свип 246+247 `ok=117 fail=0` со `smoke=1 iface=1 bench=1`
(стенд 56 сценариев); зонд пути сборки зелёный, контроль краснит две ассерции;
три названные мутации краснят три новые проверки поимённо.

Решение юзера 2026-08-27: пока идёт сходимость, каждая волна меряется на
246+247 (~10 мин), полный прогон с 233 — один раз, когда сходимость достигнута.
`sweep.sh` научен брать список версий и отказываться на неизвестном имени ДО
создания снимка кита.

## Волна 12 — A1 + A6: замок заменён структурно (не залатан)

Утренняя правка (добивание потомства перед снятием каталога-замка) лечила
симптом. Замер показал, что настоящий flock(2) достижим и на macOS — через
`perl`, который у кита уже в обязательных инструментах (строка 301). Это
снимает ОБА дефекта по устройству, а не проверками:

- **A1** (убитый прогон отпускает замок, пока живы его дети-писатели) —
  замок живёт в описании открытого файла, дети наследуют дескриптор.
- **A6** (гонка перехвата: два претендента сносят каталоги друг друга) —
  протокола перехвата больше нет, протухших замков не бывает.

Лестница: flock(1) → perl flock(2) → каталог. На каждой ступени rc=1
(«занято», ответ ядра) отличается от прочих кодов («прибор не сработал») —
короткое `|| true` здесь читало бы поломку как «свободно».

Замеры (`/tmp/lockprobe/probe.sh` — первые 203 строки кита + тело):
```
контроль-1: замок взят [perl flock(2)]   rc=0
контроль-2: замок взят [perl flock(2)]   rc=0     <- «отказ» не печатается на ровном месте
1. держатель жив                         -> rc=3 отказ
2. держатель убит SIGKILL, дети живы      -> rc=3 отказ
3. добиты ВСЕ дети (их было два)          -> rc=0 замок взят
достижимость рубежа (perl-заглушка rc=2)  -> NOTE + [каталог ...lock.d], rc=0
```
Проба сперва «провалила» ступень 3: держателем оставался неучтённый
`sleep 60` из самого `HOLD` (ppid=1). Это не дефект замка, а неполнота пробы —
и заодно подтверждение, что `lsof` из текста отказа называет держателя.

Дескриптор 9 в ките больше нигде не используется (проверено грепом), в доках
замок не описан — правки доков не требуется.

`__kill_kids` оставлен, но сменил основание: не «отпустить замок», а не
оставлять после убитого прогона `node`, продолжающий править бинарник.

Почему не поставить flock(1) вместо этого (вопрос юзера): установка ничего не
добавляет — это тонкая обёртка над тем же flock(2), который perl уже вызывает.
В homebrew он приходит из keg-only `util-linux`, то есть не попадает в PATH без
отдельной правки; при этом ступень 1 УЖЕ берёт flock(1), если он есть, поэтому
на linux-хосте и после ручной установки он используется сам собой. Ставить —
значит добавить зависимость, сохранив всю лестницу на случай «ещё не поставлен».

## Волна 12 — возврат окна 1M при resume (вне списка раунда 11; повод — скриншот юзера)

Юзер показал строку состояния: **Opus 5, контекст 269k/200k**. Первая моя реакция
(«сессия держит старый inode, нужен рестарт») ОШИБОЧНА и снята: юзер поправил, что
образ новый. Проверил прибор — номер `CC v2.1.238` рисует плагин `claude-hud`,
который кэширует версию по mtime ШИМА `~/.local/bin-shims/claude`, а шим не
меняется при подмене образа за ним; кэш заморожен с 16 августа. Сам бинарь
отвечает `2.1.247`. Дефект чужой (плагин), наружу не публикуется.

Значит 269k/200k — живое поведение ТЕКУЩЕГО образа с уже применённым шагом 20b.

**Корень.** Шаг 20b (коммит 85715d9) закрыл ИДЕНТИФИКАТОР (эхо шлюза), а окно —
нет, и прямо стрипал суффикс в расчёте на сток. Сток же решает так:

```js
if((o&&fe(o)||n!==void 0&&fe(n))&&kt(a)&&(y(a)===r||o&&S(ee(y(o)))===S(a)))
    return{kind:"ok",model:a+"[1m]"};
```

Суффикс берётся ТОЛЬКО из текущей модели (`o`/`n`). Транскрипт (`a`) не участвует
никогда: в стоке там эхо сервера, а сервер клиентскую пометку `[1m]` не несёт.
Итог — сессия с миллионным окном возвращается на 200k, держа 269k контекста.
Моя ошибка адъюдикации: половину шага я засчитал за целое.

**Фикс.** Признак «запрошенная модель несла `[1m]`» снимается в читателе (там
сырое поле ещё в руках) и добавляется третьим слагаемым в то же условие. Оба
стоковых стража остаются: `kt(a)` (модель умеет 1M) и хвостовая скобка
(семейство совпадает) — мы РАЗРЕШАЕМ вернуть окно, а не навязываем его.

**Замеры.**
- форма условия в 2.1.247 сошлась; имена `o/fe/n/kt/a`;
- совпадений во ВСЁМ образе — ровно 1 (однофамильца не заденет);
- отрицательный контроль регулярки (`+"[2m]"` вместо `+"[1m]"`) — не ловится;
- в СОБРАННОМ образе оба участка на месте и в ОДНОМ теле цикла:
  `let a=…,__ccReq1m=…,l=ct();` … `if((__ccReq1m||o&&fe(o)||…`;
- сборка 2.1.247 по дереву волны: `118/118`, дым, гейт интерфейса, стенд 56,
  ноль `[BAD]`.

**Контроли проверки №118 (пинит ОБЕ половины; каждая краснит по отдельности).**
| мутация (равная длина) | что воспроизводит | результат |
|---|---|---|
| `/\[1m\]$/i` → `/\[9m\]$/i` в читателе | признак всегда ложен | `[FAIL]` №118, OK=117 |
| `__ccReq1m` → `undefined` в условии | условие не читает признак | `[FAIL]` №118, OK=117 |

Обе сборки отказались ставить образ. Дерево от мутаций очищено, снимок удалён.

**Открыто по этому шагу:** сквозного замера «resume реально вернул 1M» ещё нет —
байтовая форма и семантика доказаны, живой прогон resume на собранном образе НЕ
проводился. Не выдавать за проверенное.

## Волна 14 (найдено при контролях волны 13, 2026-08-27)

### W14-1 — сборка может молча идти НЕ из тех байтов, что назвал оператор
Механизм: tweakcc восстанавливает `~/.tweakcc/native-binary.backup` поверх
цели до всякого патча. Ветка на строке ~724 ловила только случай «в бэкапе
НАШИ патчи»; расхождение двух РАЗНЫХ стоковых образов одной версии не
замечал никто.
Наблюдение: цель с одной изменённой строкой (`y(a)===r` → `y(a)!==r`)
собралась в образ БЕЗ этого изменения; `OK=118 FAIL=0`, `Done.`, дважды
подряд. Извлечённая tweakcc «оригинальная» нагрузка
(`~/.tweakcc/native-claudejs-orig.js`) несла `===`, то есть вход подменён до
стадии патчей. Конвейер к подмене непричастен: `.orig` он не делал («No
pristine copy beside the binary»).
Последствие: всё, проверенное на названной цели, к отгруженному образу не
относится, и сигнала об этом нет.
Фикс: страж перед вызовом tweakcc — цель без нашего маркера + расхождение
байтов + СОВПАДЕНИЕ версий ⇒ FATAL с двумя названными дверями (продвинуть
цель в бэкап либо собирать из бэкапа). Отказ, а не автопочинка: какой из
двух образов истина, знает только человек. `cmp` объявлен обязательным
инструментом (иначе 127 → `!` → ложный отказ).
Контроли: отрицательный — `--target mut3.pristine` даёт rc=1 и отказ до
сборки; положительный — сборка с нормальной целью (см. w14-build.log).

### Методический урок — контроль мутацией ОБРАЗА через пересборку недействителен
Мутация входного образа стирается восстановлением бэкапа, и прогон выглядит
успешным (`OK=118`). Пересборку под контроль звать незачем: блок проверок —
heredoc `python3 - "$BIN" "$OUR_PATCH"` в claude-patch-all.sh, его можно
извлечь по якорю и гонять по мутированному СОБРАННОМУ образу за секунды.
Верность прибора подтверждена: на чистом образе извлечённый блок даёт те же
118/118, rc=0.
Так доказан третий пин проверки 118 (страж семейства): мутация
`&&kt(a)&&(__ccReq1m||(y(a)===r||` → `!==` равной длины ⇒ rc=1, OK=117,
краснеет ровно `a resumed session keeps the 1M window it was using`.

## Раунд 14 (2026-08-28) — после порта 2.1.248 и переезда корпуса

Голоса: перепись/правдивость утверждений (13 находок: 2 высоких, 8 средних,
3 низких) и атака на механизмы (6: 1 средняя, 3 низких, 2 информационных).
Отчёты: `round14-auditor-grok.md`, `round14-auditor-fable.md`.

Волна 16 — приняты и починены ВСЕ, кроме двух пунктов ниже.

| # | Важность | Что | Как починено |
|---|---|---|---|
| G1 | высокая | `record_pin` переписывал список под живым `read` — хвост первой закачки молча пропускался, rc=0 | список читается в память до цикла, пины копятся и пишутся одной перезаписью после него |
| G2 | высокая | лежащий образ без пина пинился по байтам ДИСКА, реестр не спрашивали | без пина версия качается из реестра и сверяется; расхождение — отказ |
| G3 | средняя | «193 обращения import.meta.require» — это 193 чанка при 358 обращениях | формулировка в комментарии кода приведена к измеренному |
| G4 | средняя | «__esm больше не встречается» — ложный различитель (4 против 4, 18 против 18) | комментарий шага 11 называет настоящие различители с числами |
| G5 | средняя | «подставляется ЕЁ ЖЕ тело» — вставлялся пересказ без ветки boolean; проверка сверяла только словарь | вставляется ТЕЛО продукта дословно (снято имя), проверка сравнивает тело целиком |
| G6 | средняя | журнал шага 12 писал «suppression removed» и там, где ничего не вырезал | строка журнала называет исполнившуюся ветку |
| G7 | средняя | комментарий проверки «никакой путь не отбрасывает модель» лгал для 248 | комментарий говорит, что пинится на каждой записи |
| G8 | средняя | комментарий шага 14 «три сайта в одном модуле на каждой версии» — на 248 их четыре | комментарий переписан по измерению |
| G9 | средняя | «отказов пять» — их семь после trap | число исправлено |
| G10 | средняя | гонка за замок кончалась бодрым `SWEEP DONE` | держатель называется в момент отказа, бюджет ожидания, «НЕ ИЗМЕРЕНО», отдельный хвост и ненулевой код |
| G11 | низкая | mktemp-копия текла при отказе копирования себя | trap ставится до первой записи |
| G12 | низкая | без perl прогон шёл лидером без своей сессии | отсутствие perl — отказ |
| G13 | низкая | два наполнителя писали в один `.part` | уникальное временное имя на процесс |
| F-M1 | средняя | метка «+dirty» не видела неотслеживаемое и проиндексированное | метка берётся из `status --porcelain` |
| F-L1 | низкая | два свипа делили сводку | свой замок свипа, дескриптор закрывается у детей |
| F-L2 | низкая | свип всегда выходил нулём | код возврата повторяет исход |
| F-L3 | низкая | отказ «нет shasum» жил внутри `$(...)` | инструмент хеша выбирается на старте, в обоих скриптах |
| F-I1 | инфо | окно fork-проверки ±20000 шире модуля правки | окно привязано к модулю, как у шага 12 |
| F-I2 | инфо | первый пин — доверие первой закачке | архив сверяется с `dist.integrity`/`shasum` реестра в `download_binary` (это же закрывает и путь `--update`) |

Не приняты к правке (с основанием):
* Сообщение коммита 36914a5 содержит неточности G3/G4 — коммит запушен, переписывание
  истории требует отдельного решения юзера; настоящий дом этих утверждений —
  комментарии кода, они исправлены.
* Собственное объяснение отказа 240-248 («замок держит потомок прошлого прогона»)
  ОПРОВЕРГНУТО собственным прибором: после выхода одиночного прогона замок
  свободен немедленно. Кто держал его в 01:20:53, установить не удалось —
  следов не осталось. Отсюда правка G10: держатель записывается в момент отказа.

## Волна 17 — гейт чисел (0d): владелец счёта + собственные зубы

Повод: прогон 2.1.250 упал на гейте чисел ДО единого патча —
`README.md:111 «12 scenarios» — объявлено «56 scenarios»`. Разбор причины (а не
обход): гейт строил ОДНУ карту объявленных чисел из `EXPECTED_CHECKS` и
`EXPECTED_SCENARIOS` стенда probe-bench, а счётчиков сценариев в ките стало три
(probe-bench 56, judge-tools-bench 18, corpus-tools-bench 12) плюс два счётчика
мутаций. Честное утверждение README про corpus-tools-bench сверялось с
константой probe-bench. Правка формулировки README была бы легализацией дефекта.

| # | что сделано | доказательство |
|---|---|---|
| 17.1 | у числа появился ВЛАДЕЛЕЦ: реестр `OWNERS` (pipeline, probe-bench, judge-tools-bench, corpus-tools-bench, docnum-bench), владелец выбирается по БЛИЖАЙШЕМУ имени в окне 400 символов | мутации D1, D3, D4 |
| 17.2 | значение по умолчанию только для сценариев (probe-bench) — у счёта мутаций без имени владельца ОТКАЗ, а не догадка | D8 (пустой DEFAULTS краснит), D2 |
| 17.3 | в словарь добавлены существительные мутаций (mutations / мутаций / мутации) — раньше счёт мутаций не проверялся вовсе | D2 |
| 17.4 | у числа обязана быть ЛЕВАЯ ГРАНИЦА: `scenario_18` отдавал свои цифры как самостоятельный счёт | D5 |
| 17.5 | промежуточные слова обязаны быть СЛОВАМИ (`[\w-]+`): в коде `return 1` через два токена от строки со словом «мутации» читалось как счёт | D9 |
| 17.6 | внутри гейта положительный контроль грамматики: синтетические тексты с известным ответом, прогон ДО настоящих файлов | самопроверка 17/17 на каждой сборке |
| 17.7 | связка гейта с деревом проверяется стендом `tools/docnum-bench.py` (шаг 0e): контроль без мутации обязан быть ЗЕЛЁНЫМ, затем каждая из записанных мутаций обязана покраснить гейт СВОЕЙ причиной | 9/9 RED, контроль зелёный, ~1 с |
| 17.8 | мутации лежат данными (`tools/docnum-mutations.tsv`), а не в коде стенда: их вход — нарочно неверный счёт, а гейт сканирует прозу в .md/.sh/.js/.py | контроль остаётся зелёным |

Уроки волны, оба воспроизводят класс «проверка не может упасть»:
- 17.4 и 17.5 нашёл НЕ я и не аудитор, а собственный положительный контроль
  стенда на первом же прогоне. Обе дыры были в грамматике ДО этой волны и
  молчали лишь потому, что существительное «мутации» в словарь не входило.
- Вход мутации D5 после починки 17.5 стал ловиться ВТОРЫМ правилом — мутация
  краснела, но не то, что проверяла. Заменён на вход, изолирующий ровно левую
  границу (`scenario_18 сценариев`). Мутация, которая краснеет по чужой
  причине, доказывает чужое правило.

### Волна 17б — стенд корпусных инструментов, прогнанный впервые

Стенд волны 16 (`tools/corpus-tools-bench.sh`) был написан, но НИ РАЗУ не
прогнан: в тот момент шёл настоящий прогон конвейера, и стенд отказывался по
собственному предусловию. Прогнанный после установки 2.1.250, он выдал три
дефекта в себе самом — ни одного в проверяемых инструментах.

| # | дефект | класс |
|---|---|---|
| 17б.1 | сценарии 7 и 9 держали замок и искали лог держателя в `$C/state`, а свип живёт в `$C/corpus/state` — путь был выписан вторым местом и разошёлся | проверка НЕ МОЖЕТ ПРОЙТИ |
| 17б.2 | мутация 5 «применялась» молча: `perl -0pi -e` не жалуется на несовпавший шаблон, а `grep -q .` подтверждал лишь непустоту файла | применение не доказано |
| 17б.3 | мутация 5 подставляла ПУСТЫЕ строки: `$version`/`$got` в правой части замены — переменные perl, а не шелла. Наполнитель падал на пустом пине, сценарий 11 оставался зелёным ПО ЧУЖОЙ ПРИЧИНЕ | мутация не воспроизводит дефект |

Починено полностью: каталог состояния выводится одним местом (`use_corpus`),
каждая мутация обязана доказать, что изменила файл (сравнение до/после), у
мутации 5 экранированы доллары. Итог 12/12 сценариев и 6/6 мутаций.

Третий раз за волну повторился один класс: **мутация, краснеющая по чужой
причине, доказывает чужое правило**. Первый раз — вход D5 гейта чисел стал
ловиться вторым правилом; второй — та же D5 после починки; третий — здесь.

### Замеры волны на HEAD 75b7443
- 2.1.250: ok=114 fail=0, установлена, лаунчер переведён.
- свип корпуса 246/247/248 (оба формата бандла): по ok=114 fail=0.
- стенды: docnum 9/9, judge-tools 18/18 и 10/10, corpus-tools 12/12 и 6/6,
  зонды 56/56, самопроверка грамматики 17/17.
- объявлено непокрытым: образ 250 собран bun 1.4.1 (нет ни в npm, ни в
  релизах — тег 404), стенд зондов гоняет на 1.4.0 и говорит об этом вслух.

### Волна 18 — раунд 15 (два аудитора, 21 находка), закрыт целиком

Правки по адъюдикации раунда 15. Три предмета: грамматика гейта чисел,
дом формата списка корпуса, зубы стенда корпусных инструментов.

| # | дефект | что сделано |
|---|---|---|
| 18.1 | гейт чисел видел одну форму фразы из девяти: собственная проба показала, что 8 из 9 форм обычной прозы проходят мимо | грамматика переписана на токены с якорем НА СУЩЕСТВИТЕЛЬНОМ (REACH=5 в пределах предложения), обратная форма требует связки; 34 случая положительного контроля |
| 18.2 | владелец числа выбирался по ближайшему имени без защиты от ничьей и от общего слова («the bench covers 56 scenarios») | ничья и общее слово ближе имени — ОТКАЗ, а не догадка; регистр имени снимается `casefold` |
| 18.3 | гейт читал `.md` целиком, а код `.sh`/`.py`/`.js` — только комментарии; граница была неявной и один раз уже дала ложную находку в коде | проза и код разделены явно, немаркированные строки заменяются пустыми (номера строк сохраняются) |
| 18.4 | пометки освобождения были словами естественного языка: «subset» в соседнем предложении освобождал чужое утверждение, «это НЕ подмножество» работал как разрешение | пометки — явные токены `docnum:historical|subset|example`, область действия — ПРЕДЛОЖЕНИЕ |
| 18.5 | формат списка корпуса читали два `while read`, и трактовки разошлись: строка без пина — отказ у свипа и повод записать пин у наполнителя; лишнее поле глотали оба; одна версия под двумя метками считалась двумя измеренными | разбор переехал в `tools/corpus-list.py` — единственный дом формата; оба инструмента читают его |
| 18.6 | пин платформозависим, а список этого не говорил: корпус с другой машины отвергался бы поштучно с текстом «образ подменён» | список НАЗЫВАЕТ платформу; расхождение и отсутствие строки — свои причины отказа |
| 18.7 | пин сверялся с ИСХОДНИКОМ, а конвейер получал КОПИЮ, сделанную минутами позже | копия сверяется с пином в момент, когда идёт в конвейер; три отказа копии (не сделана / не читается / не сходится) — свои |
| 18.8 | вердикт свипа потреблял один код возврата: NUL в логе, два применения, ноль прошедших проверок, непройденный дым/интерфейс/стенд зондов печатались и не мешали сказать «красных нет» | вердикт потребляет ВСЕ девять полей, каждое со своей причиной в строке |
| 18.9 | нечитаемый образ объявлялся подменённым: пустой хеш сравнивался с пином | `sha256_of` отличает «не прочитать» от расхождения |
| 18.10 | метка происхождения снимка снималась ПОСЛЕ копирования и описывала дерево на конец копии | метка снимается до и сверяется после, расхождение объявляется |
| 18.11 | стенд корпусных инструментов, отключив дверь мутацией, пускал свип в НАСТОЯЩИЙ конвейер: боевой замок, сеть, чужое состояние tweakcc | конвейер игрушечного кита — заглушка, печатающая маркеры вердикта; замок свой |
| 18.12 | `--self-check` считал зубом ЛЮБОЙ отказ сценария, включая посторонний | у каждой мутации записан СЛЕД, который она обязана оставить; красное по чужой причине = провал стенда. Поймало сразу: мутация «платформа не названа» краснела соседней веткой |

Стенд вырос с 12 сценариев и 6 мутаций до 32 и 25: каждая дверь разбора
списка, все три отказа копии, каждое из девяти полей вердикта и позитивный
контроль (чистый лог обязан быть зелёным) — со своей мутацией.

Два урока волны, оба уже были в памяти и оба повторились:
- **проверка, опирающаяся на строку, которую краснит мутация, съедает свой
  зуб**: сценарий 8 требовал, чтобы вырезанная функция содержала `git status
  --porcelain`, — ровно то, что мутация 3 и заменяет; «якорь не найден» стало
  неотличимо от «дефект воспроизведён». Якорь переехал на имя входа функции.
- **дверь, которую держат ДВЕ независимые ветки, одной мутацией не краснится**:
  отказ «платформа не названа» держат и `declared is None`, и сравнение с
  платформой машины. Мутация одной меняет лишь ФОРМУЛИРОВКУ — это её честный
  след; а enforcement пинится отдельным сценарием чужой платформы.

**Разобрано и оставлено как есть (с основанием, не «принято ограничение»).**
Имя файла корпуса `<версия>.pristine` выводится в ДВУХ местах: `sweep.sh:185`
(`src_of`) и `fetch-corpus.sh:100`. Это тот же силуэт, что дефект 18.5 (два
дома одного формата), но не тот же класс: расхождение суффикса не молчит --
свип сразу отказывает «нет пристинных образов», наполнитель качает под новым
именем, и оба состояния краснят стенд (сценарии 2, 3, 10-12 держат имя
третьим отражением). Дефект 18.5 был молчащим: две трактовки ОДНОГО файла
давали разные вердикты, и ни один прогон этого не показывал.

## Волна 19 — фикс-волна раунда 16 (адъюдикация контроллера)

Раунд 16 (две линзы: grok — «остаточное состояние и переписи», fable — «батарея
ложных пропусков/срабатываний») дал 26 находок. Все приняты; ни одна не
легализована. Раунд НЕ нулевой, счёт сходимости не начат.

### Живые дефекты инструментов
- **H1** (высокая) `tools/sweep.sh` — сводка обрезалась только перед циклом
  версий: отказ на любой из четырнадцати дверей оставлял на диске зелёный
  вердикт ПРОШЛОГО прогона. Теперь сразу после взятия замка пишется строка
  «ПРОГОН НАЧАТ … вердикта ещё нет». Предел объявлен в комментарии: три двери
  ДО замка сводку не трогают, потому что писать раньше замка — затирать строки
  живого свипа-ровесника. Сценарий 34 + мутация 27.
- **Собственная находка волны**: зелёный вердикт `SWEEP DONE` уходил ТОЛЬКО в
  поток вывода, красный — ещё и в сводку. В файле, который читают после
  прогона, «идёт», «отказал» и «всё зелено» выглядели одинаково. Теперь
  зелёный хвост пишется и в сводку (пинится тем же сценарием 34).
- **LIVE-2** (средняя) `sweep.sh 900 900` мерил один файл дважды и печатал «все
  2 версий измерены» — тот самый обман счёта, ради которого разбор списка
  отвергает дубль версии. Повтор аргумента — отказ. Сценарий 35 + мутация 28.
- **LIVE-1/M3** (средняя) `tools/fetch-corpus.sh` — `sha256_of` без защиты от
  пустого результата: нечитаемый образ объявлялся ПОДМЕНЁННЫМ (пустой хеш
  против пина). Защита поставлена во всех трёх местах сверки. Сценарий 36 +
  мутация 29.
- **L1** (низкая) имя `<версия>.pristine` строили свип и наполнитель порознь;
  одностороннее изменение суффикса оставляло свип на старых байтах с
  сошедшимися пинами. Дом — `tools/corpus-file-name.sh`. Структурный сценарий
  37 + мутация 30 (стенд намеренно держит имена литералами: выводи он их той же
  функцией, обе стороны поехали бы вместе и расхождение осталось бы невидимым).
- **M1** (средняя) ручку `CLAUDE_PATCH_LOCK` читали конвейер и свип, но не
  `tools/build-path-probe.sh` и `tools/lock-probe.sh`. Зонд пути теперь читает
  ручку; зонд замка её ПИНИТ своей песочницей (иначе вызывающий уводил ребёнка
  на свой файл, пока утверждения смотрят на песочницу). Общий файл сюда
  подключить нельзя — преамбулу конвейера lock-probe исполняет отдельно,
  вырезав из файла, — поэтому форма запинена сценарием 38 (+ мутация 31), и это
  объявлено в комментарии.
- **M2** (средняя) держателям-perl в сценариях 7/9/33 не закрывался дескриптор
  9 — замок САМОГО стенда. Закрыт (`9>&-`).
- **R2** (остаточное состояние, не находка) свип оставлял снимок кита в
  рабочем каталоге при обрыве и отказе — снят трапом (сценарий 39 + мутация
  32); пропатченные копии `bin/*.wave.bin` копились сотнями мегабайт (6.2 ГБ на
  диске к моменту волны) — копия зелёной версии удаляется, копия КРАСНОЙ
  остаётся уликой (сценарий 44 + мутация 37).

### Зубы стенда корпусных инструментов (беззубые двери)
- **MUT-C/MUT-D** (высокая) правки `corpus-list.py` — PIN-регексп и `label in
  labels` — оставляли 33/33 и 26/26 зелёными. Добавлены сценарии 40 (дубль
  метки), 41 (пин не 64 знака), 42 (версия не по форме) + мутации 33-35.
- Рассинхрон пяти таблиц мутаций больше не сдвигает описания молча:
  `--table-check` сверяет длины до первого прогона (сценарий 43 + мутация 36).
  Сам сценарий укорачивает таблицу по якорю НАЧАЛА СТРОКИ: первая редакция
  искала имя таблицы где угодно и резала строку соседнего кода — теневая цель.
- Итог стенда: 44 сценария / 37 мутаций, оба режима зелёные.

### Гейт чисел (0d) — ложные пропуски и срабатывания
Ложные ПРОПУСКИ: падежи «проверкам»/«мутациям»/«сценариях» (FN5/FN6); скобка
как связка (FN3); сокращение «шт.» больше не рвёт предложение (FN4); REACH
5→8 (FN2, FN7 — html-комментарий теперь маскируется); докстринги `.py`
читаются РАЗБОРОМ через `ast` (FN8); печатаемые строки `.sh` — только
содержимое кавычек, иначе `>&2` дал бы разбору цифру 2 (FN9); счёт словом не
пропускается молча, а ТРЕБУЕТ цифру, и только вплотную к существительному
(FN1).
Ложные СРАБАТЫВАНИЯ: маркер сноски `[^1]` маскируется (FP1); запятая и
двоеточие рвут пару «число чужого предмета + наше существительное» (FP2/FP3);
элементы списка, строки таблицы, заголовки и пустая строка стали границами
блока (FP4/FP5); диапазон «от 10 до 40» не счёт (FP8); составное «~300-МБ» и
прикидка не счёт (собственная находка при прогоне по дереву); у конвейера
появились ИМЕНА, и правило «назови владельца» стало общим для всех величин —
«судья делает 2 проверки» больше не сверяется со 114 (FP6/FP7), для приращения
и чужого предмета заведены пометки `docnum:delta` и `docnum:other`.
**Q3 (совпадение константы соседа) закрыт, а не документирован**: владельца
называет ПРЕДЛОЖЕНИЕ; два владельца одной величины в предложении — отказ
(FP9 закрыт тем же правилом). Ветка равного расстояния осталась для имён ЗА
предложением и получила свой случай (TIE2).
**MUT-A/MUT-B** (связка «стало» и русская половина общего слова) получили свои
случаи и мутации D15/D16. Таблица гейта: 29 мутаций, шесть перенаведены после
правок; шесть новых мутаций были ЗЕЛЁНЫМИ с первого захода и перенаведены на
настоящую цель — то есть таблица снова поймала беззубую запись.
Гейт по дереву: ЗЕЛЁНО, самопроверка грамматики 63/63.

### Квантор README:111
Утверждение «every refusal door of the sweep, the fetcher and the list parser»
опровергнуто пересчётом дверей (линза B). Строка переписана как СПИСОК того,
что покрыто, с явной оговоркой, что это список, а не квантор. Дописаны строки
`tools/corpus-file-name.sh`, `tools/image-check.py`, `tools/site.d.ts` (три
файла жили без строки в таблице).

**Волна 19 закрыта: коммит `974cdb4`, запушен `2c65536..974cdb4` после
ancestor-guard'а.** Гейты на финальном дереве: corpus-tools-bench 45/45 и 38/38;
docnum-bench контроль ЗЕЛЁНО и 29/29; judge-tools-bench 18/18 и 10/10; гейт
чисел ЗЕЛЁНО, самопроверка грамматики 63/63; свип 246+247 -- каждая версия
`ok=114 fail=0`, `SWEEP DONE`. Живьём проверено и то, что чинила волна: в сводке
стоит зелёный вердикт, копии `bin/246|247.wave.bin` удалены, снимок кита не
остался. Прибрано 1.8 ГБ протухших копий прошлых прогонов.

Раунд 17 (следующий) начинается с нуля: счётчик сходимости (два подряд раунда с
нулём находок) по-прежнему НЕ НАЧАТ -- раунд 16 дал 26 находок.

## Волна 21 (фикс раунда 18) -- ЗАКРЫТА: коммит `17d1196`, запушен `e323e5e..17d1196`

32 находки раунда 18 (F/G/E/H/W) закрыты одной волной; полный отчёт --
`wave21-report.md`. Ядро волны: ЕДИНАЯ таблица кодов возврата кита (0/1/2/3/4/
5/6), каждый инструмент объявляет своё подмножество в шапке, каждый вызывающий
ветвится по КЛАССУ. Ключевые: код 6 вместо 3 у неподтверждённой заявки
владения замком; часовой `__DONE` против кода 0 при обрыве на ошибке
подстановки (bash 3.2) плюс правило 3 гейта форм; классы отказа названы у всех
потребителей приборов; `probe-bench --self-check` наконец ВЫЗЫВАЕТСЯ гейтом.

Найдено ПРИ ПРОВЕРКЕ самой волны и починено в ней же:
* `grep -a -c` на логе с NUL молча возвращает 0 для НЕ-ASCII образцов -- поле
  `tw` вердикта свипа зеленело неизвестно сколько; лечится `LC_ALL=C`;
* `checks-on-image.sh` -- пропавший якорь ехал кодом 1 при обещанном 2;
* `backup-divergence-probe.sh` -- объявленный код 2 БЫЛ НЕДОСТИЖИМ; разведено
  с контролями (нет якоря -> 2, случай без причины -> 2, пристинный -> 0);
* `build-path-probe.sh` и `sweep.sh` не различали классы предполётных
  приборов; заведены двери + сценарии 63/64/65 + мутации;
* **W-2, дефект самой волны**: предполёт стенда наследовал
  `SWEEP_LEADER/SWEEP_KIT/SWEEP_SELF` -> игрушечные свипы брали НАСТОЯЩИЙ кит и
  сорок минут гоняли настоящие сборки по живому `~/.tweakcc`, диск в ноль.
  Снятие бухгалтерии в обоих пусковых стенда + сценарий 66 (живой прогон под
  протёкшим окружением ПЛЮС форма снятия из копии кита -- исполняющийся файл
  зубам недоступен по устройству).

Приборы на финальном дереве: corpus-tools-bench 66/0 и 65/65; probe-bench 56/0
и 5/5; judge-tools-bench 18/18 и 10/10; docnum-bench 36/36; гейт чисел ЗЕЛЁНО
(грамматика 72/72); lock-probe ЗЕЛЁНО; backup-divergence-probe 11 случаев;
checks-on-image на собранном и на пристинном; kit-build ЗЕЛЁНО; свип 246+247 --
обе версии `exit=0 ok=114 fail=0 forms=1 floor=1`, `SWEEP DONE`.

Счётчик сходимости (два подряд раунда с нулём находок) по-прежнему НЕ НАЧАТ:
раунд 18 дал 32 находки. Следующий -- раунд 19, свежие линзы.

## Раунд 19 -> ВОЛНА 22 (закрыта, коммит db50d70, 14 файлов, +700/-143)

Источники: аудитор A (объявлено <-> достижимо <-> прочитано) -- 11 находок;
аудитор B (наследование от вызывающего + касания вне дерева) -- 15 находок;
свип контроллера -- 6 находок (последний sys.exit(СТРОКОЙ) в ките; класс
разборщика при несобираемой платформе; вызывающий, называющий причину за
прибор; порядок «аргументы против замка» в конвейере; два режима разом = 1;
отсутствие node = 1). Принято 32, отклонён один компромисс аудитора (пин
замка к /tmp -- окно подмены; приватный TMPDIR безопаснее).

Гейты финального состояния (все зелёные):
* стенд корпусных инструментов: 72 сценария / 72 мутации;
* гейт чисел: 36/36, грамматика 72/72;
* стенд судейских инструментов 18/18 + 10/10; стенд зондов 56 + 5/5;
* зонд пути сборки: случаи a,b,c,d,u,r,x -- зелёные, контроли краснят;
* lock-probe, backup-divergence-probe, checks-on-image (собранный и пол),
  kit-build -- зелёные;
* свип 246+247: `exit=0 ok=114 fail=0 tweakcc=36/35 ours=1 smoke=1 iface=1
  bench=1 forms=1 floor=1`, SWEEP DONE.

Счётчик сходимости НЕ начат: раунд 19 дал находки. Следующий -- раунд 20,
новые линзы (непрочитанное аудитором B: ~3300 строк тел проверок конвейера и
judge/*.py).

## Раунд 20 -> ВОЛНА 23 (в работе)

Источники: аудитор C (тела проверок конвейера, ~3300 строк) -- 10 находок;
аудитор D (judge/*.py и вклеиваемое ядро) -- 11 находок. Принято 21 из 21,
адъюдикация -- round20-adjudication.md.

Плюс ДВЕ находки собственного свипа контроллера, обе оплачены инцидентом того
же дня (2026-08-28):

* **Цель --target не проверялась на пристинность.** Прогон с --target по уже
  пропатченной ЖИВОЙ установке отдал tweakcc пропатченные байты: тот
  восстановил свой бэкап поверх них, доложил FATAL -- и оставил установку
  ИЗМЕНЁННОЙ (7bd34ef... -> d16236b...), пока прогон докладывал отказ.
  Починка: страж 0b2 -- --target на байтах, несущих нашу метку или метку
  tweakcc, отказывает кодом 4 ДО распаковщика и ДО стадии tweakcc.
  Зубы: случай (p) зонда пути сборки + его контроль (страж отключён, первый
  гейт за ним подменён заглушкой -- контроль стоит секунды, не сборку).
* **Гейты, которым образ не нужен, стояли ПОСЛЕ стадии tweakcc.** Отказ в
  любом из них (сегодня -- новый гейт раскатки судейских инструментов)
  оставлял цель уже переписанной чужой стадией: staging-файл после отказа
  нёс метку tweakcc, и повторный прогон по нему снова кормил tweakcc
  непристинными байтами. Та же форма, которую 0b убрал с пути по умолчанию, и
  которую на --target не убирал никто. Починка: весь блок гейтов кита
  (разбор вклеиваемого кода, разбор блока проверок, формы оболочки, стенд
  инструментов судьи, раскатка, 0d числа, 0e зубы чисел) перенесён ВЫШЕ
  стадии tweakcc; после неё осталось только ПРИМЕНЕНИЕ наших патчей.

### Что волна 23 нашла в себе самой (собственные измерения, не аудиторы)

* **Памятка выключенной пробы (D-3) в первой редакции ломала ратифицированное
  свойство «настройки читаются на КАЖДОЙ консультации».** Ранний выход из ядра
  стоял ДО чтения конфига: в одном процессе первая выключенная проба уводила в
  тишину все последующие консультации той же пробы (probe-bench: 6 сценариев
  подряд без единого исхода), а в бою включённая обратно проба молчала бы ещё
  до минуты. Фикс СУЖЕН по измерению: настройки читаются всегда, памятка гасит
  только ПОВТОРНУЮ строку журнала и знает подпись настроек, по которым принято
  решение, — любая их правка возвращает строку немедленно. Зубы: два сценария
  probe-bench (`disabled-memo-holds`, `disabled-memo-yields-to-settings`,
  ключ ожидания `journalLines`, поддержка нескольких прогонов в сценарии).
* **Новый предполёт зубов реестра не был закрыт стендом корпусных
  инструментов** — игрушечные свипы стенда упирались в настоящий прибор
  (нет собранного образа ⇒ «мерить нечем» ⇒ отказ свипа кодом 2), и 30
  сценариев падали не по своей причине. Прибор заглушён по образцу зонда пути
  сборки, добавлены сценарии 75-78 (позвали и объявили вердикт; красный
  останавливает свип; выключатель объявляет пропуск; «мерить нечем» — свой
  класс) и их мутации.
* **Новая проверка «every cut in the probe is named» покраснела на собранном
  образе**: маркер класса диспатча режется `.slice(16,-1)`, а перепись срезов
  этого не знала. Срез объявлен в описи как структурный (снимает `[dispatch-
  class:` и `]` с уже сматченного маркера).
* **Требование юзера от 2026-08-28** («проверять только на последних 5
  версиях») вбито в свип как ПОВЕДЕНИЕ ПО УМОЛЧАНИЮ, а не как памятка
  оператору: `SWEEP_LAST_N_DEFAULT=5`, сортировка корпуса по номеру версии,
  срез хвоста, объявление набора в сводке; `SWEEP_LAST_N=0` возвращает весь
  корпус, версии аргументами перекрывают всё. Зубы: сценарии 73/74 стенда
  корпусных инструментов (умолчание берёт ровно 5 НОВЕЙШИХ из семи игрушечных
  версий, записанных в перемешанном порядке; ручка меняет размер набора).

### Сборка волны 23

`w23-build5.log`: 116 проверок OK / 0 FAIL; пол проверок 3 из 116, все
объявлены; стенд инструментов судьи 27 сценариев / 0 расхождений; зубы гейта
чисел 37 мутаций / 37 покраснели; гейт интерфейса поднял TUI в одноразовом
доме; стенд зондов 58 сценариев + 5 мутаций ослепили 5. Образ вдвинут
(`mv 2.1.250.staging 2.1.250`), метка наших патчей на месте, `--version`
печатает 2.1.250 + tweakcc 4.3.3.

Корпус пополнен 2.1.250 из РЕЕСТРА (пин 506d7362...), и он побайтно совпал с
локальным `2.1.250.orig` -- то есть пристинная копия рядом с установкой
действительно пристинная. Набор по умолчанию теперь 245,246,247,248,250.

## Раунд 21 (в работе) -- линзы E и F

Аудиторы: grok-4.6 по линзе E (атомарность записи и обрыв на середине),
opus по линзе F (одновременность инструментов кита). Тексты линз --
`round21-lens-E.md`, `round21-lens-F.md`.

### Находка контроллера, оплаченная этим же диспатчем: судья читает СВОЙ предмет как «уже отправленный голос»

Веер раунда 21 ушёл двумя вызовами В ОДНОМ сообщении -- ровно так, как этого
требует наш же процесс для классов audit/critique/analysis. Судья отменил
ВТОРОЙ вызов (fable, линза F) со словами «веер -- это идентичный повтор уже
отправленного голоса (fable, линза F, тот же реф-файл и тот же файл отчёта)».
Никакого прежнего fable-голоса не было: до этого ушёл ровно один вызов --
grok-4.6 по ДРУГОЙ линзе.

Причина видна в записи консультации
(`~/.claude/probes/judge/records/2026-08-28T13-21-58-535Z-r4mUHhNp.json`,
`request.messages[1]`, смещения ~23100 и ~23550): лента хода, которую получает
судья, содержит ОБА вызова текущего ассистентского сообщения -- в том числе
ТОТ САМЫЙ вызов, который судья и судит, -- а ниже тот же вызов приходит ещё раз
как `=== DISPATCH ===`. Ничто в ленте не помечает, что эти блоки ещё НЕ
исполнены и что один из них -- предмет консультации. Судья честно прочитал
собственный предмет как уже случившийся факт.

Симптом двусторонний, и вторая сторона в том же ходу: консультация по
grok-вызову выдала WARN «одиночный вызов класса audit при дефолте-паре» --
то есть НЕ увидела вееровым голосом соседний вызов, стоящий в той же ленте.
Так что сегодня проверка веера в судье ненадёжна в ОБЕ стороны: соседа по
сообщению она то принимает за прошлое, то не видит вовсе.

Важность: высшая. Отменяется не случайный вызов, а именно та форма диспатча,
которую предписывает процесс (веер ≥2 одним сообщением); ложная отмена по
устройству механизма, а не по редкому совпадению.

Направление починки (полное, не косметическое): вызовы ТЕКУЩЕГО ассистентского
сообщения обязаны приходить в ленту помеченными как «выпущены этим же ходом,
ещё не исполнены», а предмет консультации -- отдельной меткой. Тогда предмет
никогда не считается прошлым голосом, а соседи по сообщению впервые становятся
видны судье именно как веер (чинится и WARN про «одинокий голос»).

Наблюдение к проверке (не утверждение): в той же ленте блок размышления
приходит пустым (`{"src":"assistant","text":"[thinking] "}`). Надо выяснить,
это редакция на стороне поставщика или потеря содержимого на нашей стороне.

### Раунд 21, линза E (grok-4.6): 10 находок (1 высшей, 3 высокой, 6 низкой важности)

Отчёт -- `round21-auditor-E.md`. Нумерация аудитора E-1..E-10 (в его тексте
помечены как F-1..F-10; переименованы здесь, чтобы не путать с линзой F).

**E-1 (высшая) ПОДТВЕРЖДЕНА ЛИЧНЫМ ЗАМЕРОМ, не разбором кода.** Цикл версий
свипа гоняет настоящие сборки через ЖИВОЙ `~/.tweakcc` -- изоляции нет ни
переменной, ни снимком (`tools/sweep.sh:686-693` снимает люки конвейера, но
дом tweakcc не трогает; `TWEAKCC_CONFIG_DIR` в ките не встречается ни разу).
Замер во время идущего свипа, на версии 245:

    ~/.tweakcc/native-binary.backup  376109392 байт == размер 2.1.245.pristine
    config.json: ccVersion 2.1.245, ccInstallationPath /private/tmp/cc-matrix/bin/245.wave.bin

То есть бэкап живой установки уже заменён байтами КОРПУСНОЙ версии, а не той,
что установлена. Зелёный `SWEEP DONE` оставляет дом tweakcc настроенным на
последнюю версию набора; `tweakcc --restore` после такого прогона бьёт в живую
установку чужим образом. Убийство между `unlink` и `copyFile` бэкапа
уничтожает точку восстановления совсем. Это тот же класс, что инциденты волн
21-22, но для НАСТОЯЩИХ прогонов свипа он не закрывался: скраб получили только
игрушечные прогоны стенда, а `restore_one` -- только зонд пути сборки.

Ремонт после ТЕКУЩЕГО прогона тривиален и источник авторитетный: набор
кончается на 250, а пристинные байты 2.1.250 у нас сверены с реестром
(`2.1.250.orig`, пин 506d7362...). Чинить сам механизм -- волной 24.

Остальные девять (кратко, полный текст в отчёте): E-2 патч цели на месте на
путях `--target`/`--update`/`--only-ours` с окном между unlink и записью;
E-3 закачка первой установки версии идёт в КОНЕЧНОЕ имя (обрезок потом
считается «уже есть»); E-4 `probes-sync.sh` атомарен по файлу, не по комплекту
(смешанный дом судьи); E-5 `LIST.new` наполнителя не снимается трапом;
E-6 `set-model-costs.py` пишет реестр виденных и кэш до успеха json, бэкап
`~/.claude.json` неатомарным copy2; E-7 дописывания в сводку свипа без
проверки успеха; E-8 `judge/adjudicate.py:264` и `validate.py:538` стирают
`--out`, оборванная последняя строка `labels.jsonl`; E-9 SIGKILL оставляет
`dist/*.tmp.<pid>` и ~250-МБ копии образа от воркеров `checks-teeth.py`;
E-10 `probe-bench.js --json` пишет поверх без staging.

Объявлено чистым: `compact.py`, `probes-migrate.py`, путь по умолчанию
(staging + `mv`), лаунчер (tmp + replace), json цен (tmp + replace),
`restore_one` зонда, закачка корпуса в `.part` + `mv`, стенды в своём mktemp,
страж 0b2.

### Раунд 21, линза F (opus): 8 находок (4 высокой важности, 4 низкой)

Отчёт -- `round21-auditor-F.md`. Входной факт «три замка на дескрипторах
9/8/6» подтверждён по коду (`claude-patch-all.sh:219`, `sweep.sh:133`,
`fetch-corpus.sh:79`) и объявлен НЕПОЛНЫМ: четвёртый замок стенда корпусных
инструментов (`corpus-tools-bench.sh:68`) сидит на дескрипторе 9 -- том самом,
по которому конвейер доказывает наследование (`claude-patch-all.sh:186-198`);
живого столкновения сегодня нет, проверено (F-7, низкой важности).

Высокой важности:

* **F-1.** `tools/checks-teeth.py` (новый в волне 23) меряет ЖИВОЙ образ
  `~/.local/bin/claude` вообще без замка, и зовут его из предполёта свипа
  (`sweep.sh:595`), который замка конвейера в этот момент не держит. Чужой
  `--update` между `base = image.read_bytes()` (:201) и
  `shutil.copyfile(image, ...)` (:138) даёт ЛОЖНО-КРАСНЫЙ вердикт свипа с
  причиной, называющей проверки кита.
* **F-2.** `sweep.sh:243-245` отдаёт код 1 («отказ по существу») на живом
  ЧУЖОМ конвейере, тогда как таблица кодов того же файла (:36-38) относит это
  к классу 3, а двумястами строками ниже тот же случай получает 3 и ожидание в
  600 с. Текст сообщения вдобавок называет чужой законный прогон «предыдущим».
* **F-3.** Предусловие стенда «идёт настоящий прогон»
  (`corpus-tools-bench.sh:120-131`) снимается ОДИН раз, а игрушечные свипы
  внутри сканируют весь `ps`: конвейер оператора, стартовавший в пятиминутное
  окно стенда, краснит сценарий чужим отказом, и свип выходит кодом 1.
* **F-8.** Гейт интерфейса (`claude-patch-all.sh:4861-4864`) поднимает
  настоящую сессию продукта с БОЕВЫМ `HOME`, а дом проб выводится из `HOME`
  (`tweakcc-patch.js:2359`), не из `CLAUDE_CONFIG_DIR` -- та же дыра, которую
  `probe-bench.js:904-909` закрыл после измеренного инцидента со 144 записями.
  Механизм проверен; срабатывание пробы в 150-секундной сессии аудитором НЕ
  проверено и так и объявлено.

Низкой важности: F-4 `probes-sync.sh:48` пишет plist в реальный
`$HOME/Library/LaunchAgents` мимо объявленной на :38 ручки; F-5 стажирование
через фиксированное `$dst.sync-new` (:88) склеивает две версии при двух
одновременных `--to-home`; F-6 замок наполнителя стоит на каталоге корпуса,
а защищает ещё и список со своей ручкой, плюс фиксированный
`corpus-versions.txt.new`; F-9 трап свипа (:84) сносит снимок кита, не дождавшись
порождённого из него живого конвейера; F-10 прополка своих tmp в
`compact.py:76-82` навсегда пропускает файл с переиспользованным pid.

Отдельным разделом -- 13 мест, проверенных БЕЗ дефектов (в том числе замер:
`pgrep -x claude` действительно находит живые сессии, страж «живая сессия
исполняет образ» работает).

### Итог раунда 21

18 находок аудиторов + находка контроллера про судью = **19**. Счётчик
сходимости остаётся НУЛЁМ; раунд 22 -- после волны 24, с новыми линзами.

### Волна 23 закоммичена: `da1a297`

21 файл, +2202/-738, запушено после ancestor-guard (впереди origin был ровно
один свой коммит). Свип по набору 245 246 247 248 250: все пять
`exit=0 ok=116 fail=0 ... floor=1`, `SWEEP DONE`, красных нет; дерево на момент
снимка свипа и на момент коммита совпадает (проверено по mtime: ни один файл
дерева не менялся после снимка).

Ремонт живого `~/.tweakcc` после прогона (последствие E-1): содержимое
`native-binary.backup` оказалось верным (sha сошёлся с `2.1.250.orig`, то есть
набор кончился на установленной версии), но `ccInstallationPath` остался
указывать на `/private/tmp/cc-matrix/bin/245.wave.bin` -- каталог, которого уже
нет. Поле возвращено на живую установку, копия конфига до правки --
`~/.tweakcc/config.json.bak-w23-repair`. Отдельная деталь к E-1: `ccVersion`
доехал до 2.1.250, а `ccInstallationPath` застрял на ПЕРВОЙ версии набора --
значит поле обновляется не в тех же местах, что версия.

## ИНЦИДЕНТ 2026-08-28 17:25 -- ПЕРЕЗАГРУЗКА МАШИНЫ СНЕСЛА ВЕСЬ `/tmp/cc-matrix`

Машина перезагрузилась (`kern.boottime` = Fri Aug 28 17:25:34 2026, uptime на
момент обнаружения -- 20 минут). macOS чистит `/tmp` при загрузке. Унесено
ЦЕЛИКОМ:

* `/tmp/cc-matrix/review/findings-ledger.md` -- журнал кампании за все 21 раунд;
* `/tmp/cc-matrix/review/round21-auditor-E.md` и `-F.md` -- полные отчёты
  аудиторов раунда 21 (34 КБ и 33.9 КБ);
* все логи сборок и свипов (`w23-build5.log`, `w23-sweep.log`, `sweep-summary.txt`,
  логи предполётов);
* каталог задач сессии `/private/tmp/claude-501/...` -- транскрипты субагентов.

**Что восстановлено и чем.** Журнал восстановлен ПОЛНОСТЬЮ из транскрипта
сессии (`~/.claude/projects/.../9632494b-....jsonl`, 131 МБ): все 49 записей
heredoc'ом в `findings-ledger.md` (одна из них -- первичная перезапись `>`,
остальные -- дописывания) выбраны в порядке следования и склеены. Итог --
1944 строки, 206 КБ, хвост совпадает с последним дописыванием (ремонт
`~/.tweakcc` после свипа). Новый дом -- `~/.local/share/claude-patch/review/`,
рядом с корпусом, то есть вне `/tmp` и вне досягаемости прополок конвейера.

**Что НЕ восстановлено.** Полные тексты отчётов аудиторов раунда 21: их писали
субагенты в `/tmp`, их собственные транскрипты лежали там же. Уцелели сводки
обоих (в этом журнале выше, с file:line по каждой находке) -- для волны 24
этого достаточно, разбор каждой находки я всё равно веду по коду сам. Потеряны
разделы «проверено без дефектов» и подробная аргументация.

**Находка (высокой важности, в волну 24).** «Дом отчёта вне транскрипта» был
выбран в `/tmp` -- каталоге, который ОС чистит при каждой загрузке. Журнал
кампании пережил 21 раунд только потому, что машина не перезагружалась 17 дней.
Тот же класс, что переезд корпуса из каталога установок: дом обязан быть вне
досягаемости чужой уборки, а уборка бывает не только своя. Полная починка:
канонический дом журнала и отчётов раундов -- в git-репозитории кита
(`docs/review/`), то есть с историей и вне машины; гейт чисел (0d) обходит всё
дерево по расширениям и на 206 КБ исторической прозы даст лавину «число без
владельца» -- значит журналы кампании исключаются ИМЕНОВАННО (сегодня в гейте
уже есть ровно одно такое исключение, `JOURNAL = 'judge-patch-spec.md'`), и
список исключённого гейт обязан ПЕЧАТАТЬ, иначе дыра растёт молча.

## ДОМ ОТЧЁТОВ ПЕРЕЕХАЛ В ПРОЕКТ (2026-08-28, требование юзера)

Формулировка юзера: «какого хрена агенты пишут во временный каталог когда есть
у тебя папка проекта? исключить отчеты там не судьба просто?». Сделано сразу,
не отложено в волну.

* Канонический дом журнала и отчётов раундов -- `docs/review/` В РЕПОЗИТОРИИ
  кита. История, пуш наружу, переживание перезагрузки -- всё бесплатно.
  `/tmp` из этого маршрута убран совсем.
* Гейт чисел (0d): `JOURNAL` (одно имя) заменён на `JOURNALS` (имена) +
  `JOURNAL_DIRS` (дома-каталоги). Каталог, а не перечень имён: отчётов по
  раунду бывает несколько, и забытое имя молча вернуло бы лавину чужих чисел.
* Исключение ОБЪЯВЛЯЕТСЯ в потоке сборки вместе с числом исключённых файлов
  («СВЕРКА ЧИСЕЛ: журналы кампании не сканируются (...) -- файлов: N»): дыра,
  о которой не сказано, растёт молча.
* Объявленный дом обязан СУЩЕСТВОВАТЬ -- иначе переименование каталога
  оставило бы исключение, не закрывающее ничего, и это выглядело бы как охват.
  Гейт отказывает с названной причиной.
* Зубы: две новые мутации таблицы гейта чисел. D38 снимает `JOURNAL_DIRS` --
  гейт обязан покраснеть НА САМОМ ЖУРНАЛЕ (`docs/review/findings-ledger.md`),
  то есть исключение доказано несущим. D39 уводит дом на несуществующий
  каталог -- гейт обязан отказать своей причиной. Прогон: контроль зелёный,
  мутаций 39, покраснели 39.
* `scripts/kit-build.sh`: обход `docs/*.md` нерекурсивен НАМЕРЕННО (и копия, и
  сверка полноты) -- журнал кампании живёт в репозитории, но в комплект не
  едет. Констрейнт записан рядом с обеими сторонами.
* Процессное следствие: в каждом диспатче аудитору путь отчёта теперь
  `<кит>/docs/review/roundNN-auditor-X.md`. Ни один субагент больше не пишет
  результат в `/tmp`.

## ВОЛНА 24 -- ФИКС-ВОЛНА КРУГА 21 (в работе)

Линзы круга 21: E -- атомарность записи (10 находок), F -- одновременность
инструментов (8), плюс находка контроллера про судью. Ниже -- что сделано, с
зубом на каждый механизм. Зуб = названная мутация, которая краснит СВОЮ
проверку СВОЕЙ причиной; без неё утверждение в этой волне не принимается.

### Судья видит, какие вызовы -- его собственный ход (находка контроллера)

Лента хода несла судье ОБА `[tool Agent]`-блока текущего сообщения, включая
тот, который он и судит. Он отменял его как «повтор уже отправленного голоса»,
а соседа по тому же сообщению не засчитывал в веер -- симптом двусторонний.
Метки -- ПОЛЯ (`now`, `self`), а не префиксы текста: содержимому ленты доверять
нельзя, поля же подделать нечем. Правка в ядре (`tweakcc-patch.js`), в обоих
промтах, проверка реестра `the judge sees which calls are its own turn`,
мутация J1 в `checks-mutations.tsv`.

### E-4 / F-5 / F-4 -- раскатка проб (`scripts/probes-sync.sh`)

* E-4: раскатка идёт В ДВА ПРОХОДА (разложить весь набор -> ввести
  переименованиями). Пропавший исходник шестого файла больше не оставляет дом
  с пятью новыми и пятью старыми. Остаточное окно -- жёсткое убийство МЕЖДУ
  переименованиями -- объявлено в коде: закрыть его без подмены каталога
  целиком нельзя, а подменять дом нельзя (рядом лежат журналы машины).
* F-5: имя стадии несёт pid.
* F-4: plist едет в `LAUNCH_AGENTS_DIR`, а не во вшитый `$HOME/...`. Ручка
  `CLAUDE_LAUNCH_AGENTS_DIR` была ОБЪЯВЛЕНА и не действовала на этом пути.
* Зубы: сценарии 28-29 стенда инструментов, мутации M21-M23.

### E-3 -- загрузка образа (`claude_patch.py`)

Распаковка шла через КОНЕЧНОЕ имя на пути ПЕРВОЙ установки версии: оборванная
оставляла огрызок, который следующий прогон читает как «уже установлено».
Лечится в `download_binary` (свойство принадлежит загрузке, а не вызывающим):
временное имя с pid, fsync, `os.replace`, уборка обломка на любом исключении.
`.download` добавлен в список транзитных имён, иначе обломок был бы САМЫМ
СВЕЖИМ по mtime и выбирался бы целью. Зубы: сценарий 30, мутации M24-M25.

### E-6 -- цены и бэкап конфига (`set-model-costs.py`)

* Один дом атомарной записи (`write_json_atomically`) для трёх писателей:
  реестр виденных, кэш каталога, сам конфиг. Все трое писали приём вручную и
  БЕЗ fsync.
* Бэкап `~/.claude.json` брался `shutil.copy2` ПРЯМО в конечное имя: убитый
  прогон оставлял огрызок под именем бэкапа, а огрызок бэкапа хуже отсутствия
  -- именно его берут для отката. Теперь копия либо есть целиком, либо её нет.
* Имя стадии НАМЕРЕННО не из семьи назначения: конвейер прополаывает бэкапы
  глобом `~/.claude.json.backup.*`, и стадия вида `<бэкап>.part.<pid>` вытеснила
  бы из тройки свежих НАСТОЯЩИЙ бэкап.
* АДЪЮДИКАЦИЯ, часть находки ОТКЛОНЕНА: «реестр виденных и кэш пишутся до
  успеха json» -- не дефект. Оба файла -- журналы ВНЕШНИХ наблюдений (что
  прокси показал в листинге; что ответил models.dev), и утверждения про запись
  конфига они не несут. Перенос их записи «после успеха» терял бы факты:
  провал записи конфига заставлял бы перекачивать каталог. Потребитель
  (`load_seen` -> ростер) от этого не страдает: id, записанный без последующей
  записи цен, будет оценён следующим успешным прогоном.
* Зубы: сценарий 31, мутации M26-M27.

### E-10 -- отчёт стенда проб (`tools/probe-bench.js --json`)

Писался поверх конечного имени. Теперь стадия с pid, fsync, переименование,
уборка обломка. Свойство пинится ФОРМОЙ и это объявлено: исполнить ветку можно
только полным прогоном под bun по собранному образу. Зубы: сценарий 32, M28.

### F-10 -- прополка временных имён (`judge/compact.py`)

Живой pid НЕ доказывает, что файл чей-то: номера переиспользуются, и сирота,
чей номер достался долгоживущему процессу, не снималась НИКОГДА. Добавлен
второй признак, не зависящий от номера: возраст (`TMP_HELD_SECONDS`, сутки).
Свежий tmp живого писателя не трогается; в сводке появился счётчик
«tmp при живом pid». Зубы: сценарий 33, мутация M29 (плюс обновлённый якорь
M10, который эта правка сдвинула).

### E-5 / F-6 -- список корпуса (`tools/fetch-corpus.sh`)

Стадия называлась фиксированно (`<список>.new`) и не убиралась на сбое. Замок
наполнителя стоит на КОРПУСЕ, а список живёт в ките: два прогона с разными
корпусами и одним списком брали каждый свой замок и писали в один файл, после
чего один переименовывал ЧУЖУЮ половину поверх списка. Теперь pid в имени плюс
уборка на любом исключении. ОБЪЯВЛЕННОЕ остаточное: два таких прогона могут
потерять ОБНОВЛЕНИЕ пина -- это не порча и замка не требует, пин выводим заново
(строка без пина заставляет перекачать образ из реестра). Зубы: сценарии 81-82
стенда корпуса, мутации 81-82; проверки обломка в сценариях 52 и 69 переведены
на глоб -- точное имя перестало бы находить что-либо и ушло бы в пустоту.

### Найдено САМОПРОВЕРКОЙ стенда, не аудитором: два писателя сводки свипа

Мутация 42 перестала краснить свой сценарий СВОЕЙ причиной, и это вскрыло
дефект в правке E-7 той же волны: у сводки свипа оказалось ДВА писателя
(ранний блок с перенаправлением и `sum_line`) с ДВУМЯ проверками, а ВТОРОЕ
обнуление (`: > "$SUMMARY"` перед циклом версий) не имело проверки вообще.
Для работы двух проверок хватало, для зубов нет: мутация, снявшая одну,
гасилась отказом другой. Сведено к одному писателю `sum_write` (reset|add) с
единственным кодом возврата; `sum_reset`/`sum_line` -- его лица с разными
причинами отказа. Мутация 42 перенацелена на эту единственную проверку.

Урок в общую копилку: ДВЕ независимые проверки одной гарантии выглядят как
надёжность, а на деле делают гарантию непроверяемой -- ни одна мутация не
может её сломать, и стенд молчит о том, что где-то рядом проверки нет вовсе.

### Найдено ПРОГОНОМ стенда после волны 24: три дефекта в правках самой волны

Полный прогон 84 сценариев после правок F-3/F-8/F-9 дал три расхождения. Все
три -- в коде, написанном этой же волной, и ни одно не нашлось бы чтением.

* **Доделка F-9: снос снимка на ШТАТНОМ хвосте.** Ожидание жильцов было
  добавлено только в EXIT-трап, а хвост успешного прогона по-прежнему сносил
  снимок безусловным `rm -rf "$HERE"` (строка 935). Гарантия «снимок не
  сносится из-под живого процесса» держалась ровно на половине выходов -- на
  отказах. Сведено к одному примитиву `__drop_kit_when_idle`, который зовут и
  трап, и хвост; попутно закрыт второй дефект той же правки: при нулевом
  бюджете (`SWEEP_KIT_DRAIN=0`) цикл `while (( __wait_left > 0 ))` не
  исполнялся НИ РАЗУ, `__users` оставался пустым, и снимок сносился без
  единого взгляда на жильцов. Теперь проверка всегда хотя бы одна. Ручка
  объявлена в шапке свипа и в README. Зуб: мутация 87 (возврат безусловного
  `rm -rf "$HERE"` в хвост) краснит сценарий 84.

* **F-3 отказывал стенду на его собственной декорации.** Предусловие
  `require_no_real_run`, снимаемое заново перед каждым игрушечным свипом,
  считало настоящим прогоном поддельный `claude-patch-all.sh`, который
  сценарий 45 поднимает НАМЕРЕННО -- чтобы проверить страж живых прогонов в
  самом свипе. Сценарий 45 краснел чужой причиной. Вычитание своих идёт по
  временному корню стенда (`$ROOT`): ни один настоящий прогон оператора там не
  живёт. Вычитание стоит ПОСЛЕ блока стража, чтобы форма стража осталась
  канонической (её сверяет сценарий 57).

  Вторая половина того же дефекта: `exit 3` внутри `require_no_real_run` не
  прерывал стенд, потому что свип зовут ТОЛЬКО из подстановки команд
  (`out=$(run_sweep ...)`), а `exit` там кончает подстановку. Настоящий
  прогон, начавшийся посреди стенда, дал бы сценарию отказ предусловия ВМЕСТО
  вывода свипа -- то есть ровно ту красноту по чужой причине, ради
  предотвращения которой F-3 и вводился. Теперь предусловие оставляет отметку
  на диске, а `ok`/`bad` её читают и прерывают прогон классом 3. Зубы:
  сценарии 85 (обе стороны вычитания) и 86 (отметка переживает подстановку,
  верхний уровень её читает), мутации 85-86 -- по ФОРМЕ в копии кита, потому
  что предусловие исполняется из ЖИВОГО файла стенда и мутации недоступно
  (тот же класс, что у сценария 66; объявлено в коде).

* **Сравнение форм стража сравнивало не то.** `guard_form` резал блок от
  первого `=$(ps -eo pid,args)`, а правка F-9 завела в свипе ВТОРОЙ снимок
  процессов ВЫШЕ стража -- диапазон начинался с него. В стенде же якорь
  исчез вовсе: страж переехал в функцию с пайпом. Обе половины сравнения
  оказались не тем, чем назывались, а сценарий 57 сообщал «блок не найден».
  Якорь переставлен на голову стража -- «| awk '» в конце строки; у соседних
  вызовов awk идёт с `-v`, так что якорь единствен в каждом доме.

**Фикстура, доказывавшая не то.** Сценарий 84 оставлял «жильца» снимка через
`bash -c 'sleep 25' "$0"`. Это ПРОСТАЯ команда, и bash заменяет себя на неё
через exec: в `ps` остаётся `sleep 25` БЕЗ пути снимка (измерено 2026-08-28).
Ни свип, ни сам сценарий такого жильца не видели -- сценарий краснел, доказывая
«декорация не оставила следа» вместо своего предмета. Точка с запятой
(`'sleep 25; true'`) отменяет оптимизацию. Урок тот же, что и с двумя
писателями: КРАСНЫЙ сценарий обязан быть прочитан до конца -- причина его
красноты бывает не та, что в его имени.

## Круг 26, линза K (границы настроек) — адъюдикация контроллёра, 2026-08-31

Аудитор: 14 находок (5 высших, 4 высоких, 4 средних, 1 низкая), отчёт
`docs/review/round26-lens-K.md`. **Приняты все четырнадцать.** Ни одна не
списана на «так задумано»: каждая либо меняет измеряемую величину молча, либо
объявляет не то число, которое применилось.

Корень у половины один и он назван в K-9: санитайзер `__num` проверяет
КОНЕЧНОСТЬ и НИЖНЮЮ границу, но не тип и не верхнюю. Отсюда:

* K-1 `timeout_ms` больше 2^31−1 проходит, `setTimeout` сжимает задержку в 1 мс,
  а журнал пишет запрошенное число — при `fail_closed` это отмена каждого
  диспатча с ложным объявлением потолка;
* K-9 `timeout_ms = true` становится законной единицей (1 мс);
* K-8 `max_tokens = 0` вообще не доходит до `__num` (ноль ложен в JS) и
  оставляет 1200 из живого `body.json`, а тот же 0 без шаблона даёт 8000 с
  объявлением — два ответа на одно значение. Стенд этого не ловит, потому что
  гоняет без шаблона: сценарий с `body.json` обязателен.

Вторая семья — булевы ручки, у которых «истина» понимается по-разному:
K-2 (`enforce = 1` и `fail_closed = "true"` молча выключают гейт, который в
файле выглядит включённым), K-3 (`CLAUDE_JUDGE=0` пробу ВКЛЮЧАЕТ: непустая
строка истинна), K-10 (три несовместимых соглашения в одном ките;
`CLAUDE_PATCH_SKIP_MODELS=true` не пропускает синхрон цен), K-12
(`live_kinds = []` — не дефолт, а «ни одного рода»).

Третья — пустой результат, неотличимый от успеха: K-4 (`SWEEP_LAST_N=08`
восьмерично, ветка «весь корпус» не берётся, срез падает под `set -u`, и прогон
объявляет «все 0 версий измерены, красных нет» кодом 0 — при том что в этом же
ките есть `validated_nonnegative_integer` с `10#`), K-5 (`--limit=-N` —
отрицательный срез: записи молча выпадают, а на `-5` из пяти пустота
объявляется кодом 5 «нечего мерить»), K-11 (негодный образец в
`filter.classes_judge` ловится и становится «не совпало» — судья снаружи жив, по
делу мимо всех).

Остальные приняты как названы: K-6 (одна ручка `context_chars`, два смысла у
ядра и python, плюс молчаливый пол 60), K-7 (`--older-than-hours -1` и `nan`
сжимают всё живое, включая сегодняшнее), K-13 (`--timeout` без проверки, и
соседний toml в МИЛЛИсекундах при аргументе в секундах), K-14
(`--jobs<1` молча становится 1 там, где соседи отказывают кодом 2).

**Разбор запросов на адъюдикацию.** Согласен с аудитором по 1, 3, 4, 5, 7, 8:
`attach_*=0` — это «выкл», а не «безлимит», и так запинено стендом;
`--older-than-hours 0` буквален; `GATE_BUDGET=0` отказывает названо;
`dispatch_chars=0` объявляет усечение; расхождение дефолта `attach_chars`
40000/30000 живёт только при выкинутом ключе. По запросу 2 решаю в пользу
ЖЁСТКОГО варианта: молчаливый пол 60 внутри `__cut` снимается подъёмом `min` у
`context_chars` до 60 — заплатка, о которой не пишут в журнал, неотличима от
дефекта. Запрос 6 (`timeout_ms` отсутствует → 8000) — не находка этого круга,
но 8 с ядро само называет тесными: в волну не берём, держим в виду. Запрос 10
(разные дефолты `effort`: `high` в python, `low` в `body.json`) НЕ мерился —
это отдельный предмет, и он идёт в волну как ЗАМЕР, а не как правка.

Волна фиксов — общая с линзой L, одним списком, после её отчёта.

## Круг 26, линза L (gpt-5.6-sol) — повторный запуск и остатки: 9 находок

Отчёт: `docs/review/round26-lens-L.md` (записан контроллером: у аудитора запрет
записи в дерево; текст пришёл в ответе целиком). **Принято 9 из 9.** Координаты
каждой перепроверены контроллером лично по дереву `1b4f7f7`.

**Корень семьи — фильтр перечисляет ИСКЛЮЧЕНИЯ вместо того, чтобы называть
ДОПУСТИМОЕ.** Отрицательный список нельзя дописать до полноты: он не знает имён,
которых ещё не придумали.

* L-2 `skip = (".orig", ".staging", ... )` — суффиксы; `.claude-patched-XXXXXX`
  под них не подпадает, а по mtime он САМЫЙ СВЕЖИЙ, то есть выбирается целью
  именно в первозапускном состоянии, где ошибиться дороже всего.
* L-6 `!__x.endsWith(".gz")` — та же форма в ядре: `old.json.gz.tmp.<pid>`
  считается горячей записью и вытесняет настоящую. Комментарий в `compact.py`
  этот исход ОПИСЫВАЕТ («tmp занимает место, вытесняя настоящую запись») и
  оставляет как есть — описанный дефект остаётся дефектом, а комментарий,
  который его узаконивает, хуже молчания.
* L-7 фиксированное `<backup>.new` — то же самое со стороны имени: имя без
  владельца делится между писателями.

Три остальных — **конечное имя, выданное за завершённую запись**: L-3
(`writeFile` бьёт прямо в `records/<имя>`), L-4 (`shutil.copy2` прямо в
доказательную базу, а идемпотентность проверяется СУЩЕСТВОВАНИЕМ имени), плюс
L-5/L-9 — **граница строки, которую писатель не восстанавливает**: склейка
съедает не только оборванный объект, но и ПЕРВУЮ СЛЕДУЮЩУЮ успешную запись.
Толерантный читатель из прошлого круга закрыл половину случая и замаскировал
вторую: предупреждение про «одну строку» печатается там, где потеряно две.

L-1 стоит отдельно: `rm -rf` обломка исполняется РАНЬШЕ проверки живых
процессов, при том что в этом же файле уже есть примитив, который так не делает
(`__drop_kit_when_idle`, строка 149), и конвейер намеренно запускается без
дескриптора замка (`8>&-`) — то есть осиротевший ребёнок штатно не держит ничего.

**Разбор запросов на адъюдикацию.**

1. **Да.** `__drop_kit_when_idle` становится ЕДИНСТВЕННЫМ примитивом сноса
   снимка: принимает путь аргументом (по умолчанию `$HERE`), для чужих обломков
   вызывается с нулевым бюджетом дренажа, и проверка стоит непосредственно перед
   `rm -rf`. Своего бюджета ожидания чужой обломок не получает: ждать за мёртвый
   прогон — не наше дело, а вот снести из-под живого — наше.
2. **Да, единый контракт:** писатель ВОССТАНАВЛИВАЕТ границу перед append —
   если файл непуст и последний байт не `\n`, полезная нагрузка предваряется
   `\n`. Оба дома: `journal.jsonl` (ядро) и `labels.jsonl` (`validate.py`,
   `adjudicate.py`). Толерантный читатель остаётся — он теперь ловит ровно то,
   для чего заявлен: ОДНУ потерянную строку.
3. **Да.** Существование имени — не завершённость копии. Копия идёт через
   `.new.<pid>` + `os.replace`; уже существующий target принимается только если
   совпадает с источником по байтам, иначе перезаписывается.
4. **Владелец — ЯДРО, и оно называет допустимое положительно:** прополка берёт
   только `*.json`. Одним движением закрывается и вытеснение настоящей записи, и
   снос чужого tmp в миг между верификацией и `replace`. Stage `compact.py`
   остаётся в том же каталоге — `os.replace` не ходит между файловыми системами,
   и после положительного фильтра он ядру невидим. Комментарий, признающий
   потерю, переписывается под новый инвариант.
5. **Да, параллельный запуск — поддерживаемая поверхность:** страж живых
   процессов в `sweep.sh` существует ровно потому, что «оператор вправе собирать
   в соседнем окне». `.new` → `.new.<pid>`. **Правки L-7 и L-2 обязаны лечь
   ОДНОЙ волной:** `.new.<pid>` не подпадает под суффиксный `endswith(".new")`,
   то есть починка одной в одиночку открывает новый класс остатка в другой.
6. **Вне волны, по замеру, а не по усмотрению.** На живой машине сейчас: в
   `~/.claude/probes/judge/records/` остатков `tmp|new` — 0; каталогов
   `mkdtemp` от `channel.py` — 0; каталог версий содержит ровно
   `2.1.250 2.1.250.orig 2.1.251 2.1.251.orig`. Ни один потребитель их не
   читает, роста не измерено. Появится непустая популяция — станет своей
   находкой; сейчас это была бы правка без предмета.

**Своя атака контроллера к волне** (сверх списков аудиторов): положительный
фильтр ядра меняет и то, что ядро НЕ удалит. Волна обязана показать мутацией,
что при `records_keep=N` в окне остаётся ровно N ФАЙЛОВ `*.json`, а посторонняя
форма не удаляется и не считается — оба утверждения, не одно.

**Волна 31 — одна на оба списка (23 находки), тремя брифами по файлам,
последовательно:** ядро `tweakcc-patch.js` · оболочки `sweep.sh` +
`claude_patch.py` + `probes-sync.sh` · инструменты `judge/*.py`. Гейт прежний:
119 проверок, стенды с зубами, свип 246 247 248 250 251.

## Круг 26, находка контроллера W-1 — зубы реестра меряют НЕ ТОТ образ

Найдено при приёмке волны 31 (не аудитором — контроллером на прогоне).

Стадия зубов в `tools/sweep.sh:823` зовёт `python3 "$TEETH_PY"` БЕЗ `--image`, а
умолчание прибора — `~/.local/bin/claude` (`tools/checks-teeth.py:261`), то есть
УСТАНОВЛЕННЫЙ образ. Свип при этом собирает и меряет СВОИ образы из корпуса.
Контроль прибора («названный образ обязан быть зелёным до мутаций»,
`checks-teeth.py:314-322`) проверяет чужой артефакт.

Замерено на дереве `e9b172b`:
`bash tools/checks-on-image.sh ~/.local/bin/claude` → **107 [OK] / 12 [FAIL]**,
код 1. Двенадцать красных — ровно те, чьи формы поменяла волна 31 (judge/
watcher/ladder/fail-closed/numeric-settings/archive-window). Установленный
бинарник собран волной 30, пины описывают волну 31.

**Следствие, которое важнее самой красноты:** после ЛЮБОЙ волны, меняющей
запиненные формы, стадия зубов не может мерить ПО УСТРОЙСТВУ — до переустановки.
Свип честно объявляет код 2 «прибор не мерит» и ничего зелёного не заявляет
(это в нём хорошо), но зелёным он в этом окне не бывает никогда, и причина
названа тремя альтернативами сразу — «якорь мутации, длина замены или контроль»,
— из которых операторy не видно, какая сработала.

**Решение (моё, к исполнению в этой же волне, после брифов 2-3):** стадия зубов
получает образ, собранный ИЗ СНИМКА КИТА этого прогона, и передаёт его
`--image`. Прибор обязан мерить тот артефакт, который прогон и строит: контроль
на чужом образе — это «сравнение разноимённого». Отдельной строкой — причина
отказа контроля называется своим именем («образ собран прежним китом»), а не
дизъюнкцией трёх.

Пока не сделано — состояние волны 31 описывается честно: ядро проверено
реестром 119/119 на образе, собранном исполнителем репликацией обеих
образ-пишущих стадий, а ЗУБЫ на новых формах НЕ ИЗМЕРЕНЫ.

## Круг 26, находка контроллера W-2 — запиненную форму держат НЕСКОЛЬКО таблиц, и находятся они по одной за прогон

Найдено на приёмке волны 31. Волна поменяла формы и числа; за ней НЕ догнали:

1. 16 пинов реестра проверок в `claude-patch-all.sh` (нашлись при сборке образа);
2. два числа в `README.md` и цитата в новом комментарии `sweep.sh` (нашлись
   гейтом чисел);
3. якорь `--update` в `tools/build-path-probe.sh` (нашёлся на свипе, код 2);
4. четыре якоря в `tools/docnum-mutations.tsv` — D1, D2, D4, D7 (нашлись внутри
   конвейера как «ИТОГ мутаций=40 покраснели=36, ГЕЙТ ЧИСЕЛ БЕЗ ЗУБОВ»);
5. раскатка `~/.claude/judge` отставала на 4 файла (нашлась внутри конвейера).

Каждый слой поймал СВОЁ и объявил честно — ни один не зазеленел без измерения,
и это в ките хорошо. Плохо другое: **они находятся строго по одному за прогон**,
а прогон стоит сборки. Пять последовательных отказов там, где предмет один —
«форма изменилась, её копии не догнали».

**Решение (моё, к исполнению первым предметом следующей волны):** ранняя стадия
переписи якорей. Для таблиц, чьи якоря — литералы ИСХОДНИКА
(`tools/docnum-mutations.tsv`), проверка тривиальна и уже написана при этом
разборе: каждая строка обязана иметь ровно одно вхождение своего `from` в
названном файле; уехавший якорь называется своим идентификатором (`D1`), а не
проявляется как «мутация не покраснела» после сорока прогонов.

**Границу инструмента назвать обязательно.** Для `tools/checks-mutations.tsv`
та же проверка НЕДЕЙСТВИТЕЛЬНА: её якоря — литералы СОБРАННОГО ОБРАЗА, где
части строк патча уже склеены, а `\uXXXX` развёрнуты. Контроллер прогнал по
исходнику и получил три «уехавших» (C1, C6, C7) — это артефакт сравнения
разноимённого, а не находка. Владелец этой таблицы — `checks-teeth.py` на
собранном образе, и после W-1 он получает образ прогона.

## Круг 26, находка контроллера W-3 — читатель env-ручки обрывал конвейер молча на самом частом случае

Найдено на приёмке волны 31 замером, а не разбором: установка 2.1.251 прошла
целиком (реестр 119 OK / 0 FAIL, симлинк переведён, `--version` = 2.1.251), а
`bash claude-patch-all.sh` вернул **1** без единой строки после «Swapped the
verified build over the previous one». Лог обрывался ровно на месте свапа.

**Корень.** Волна 31 (бриф 2, правка K-10) ввела единый читатель истинности
env-ручек `__envon` и поставила его на шесть сайтов в форме

```
__envon CLAUDE_PATCH_SKIP_MODELS; __env_rc=$?
```

`__envon` честно возвращает 1 для НЕВЫСТАВЛЕННОЙ ручки. В `claude-patch-all.sh`
шапка объявляет `set -euo pipefail` (:96), а при `set -e` статус команды,
стоящей ОТДЕЛЬНЫМ оператором, — это обрыв. Скрипт выходил кодом 1 сразу после
свапа, не дойдя до синхрона цен и окон. Измерено под нужной оболочкой:

```
bash -c 'set -e; f() { return 1; }; f; rc=$?; echo "ДОШЛИ rc=$rc"'   -> код 1, вывода нет
bash -c 'set -e; f() { return 1; }; rc=0; f || rc=$?; echo "ДОШЛИ rc=$rc"' -> ДОШЛИ rc=1, код 0
```

**Почему прибор этого не видел — два слоя разом.**

1. Свип и зонд пути сборки ВСЕГДА экспортируют `CLAUDE_PATCH_SKIP_MODELS=1`;
   при выставленной ручке `__envon` возвращает 0, и обрыва нет. Ветка
   «ручка снята» недостижима для свипа ПО УСТРОЙСТВУ — ровно тот класс, ради
   которого в ките заведено правило «мерить пространство входов, а не случаи».
2. Стенд корпусных инструментов проверял эти сайты **грепом ФОРМЫ**
   (`corpus-tools-bench.sh`, сценарий 109, шесть строк `grep -q '__envon X;'`)
   и был доволен: он пинил НАПИСАНИЕ, а написание было ровно тем, что обрывает
   конвейер. Проверка формы засчитала дефект как выполненное требование.

**Фикс — полный, все шесть сайтов** (`claude-patch-all.sh:5807`,
`tools/sweep.sh:768,838,898`, `tools/lock-probe.sh:77`,
`tools/build-path-probe.sh:111`): форма `rc=0` + `__envon ИМЯ || rc=$?`. Слева
от `||` статус ошибкой не считается. У зондов и свипа `set -e` сегодня нет —
форма правится и там: она не должна зависеть от того, какие флаги включит
следующая правка шапки.

**Зубы — на поведение, а не на написание.** Сценарий 109 больше не грепает
форму: для каждого из шести потребителей берутся ЕГО байты (тело `__envon` +
строки сайта вызова, вычитанные из файла) и исполняются под `set -euo pipefail`
со СНЯТОЙ ручкой; засчитывается только достигнутая следующая строка. Мутация
128 возвращает сломанную форму на сайте `claude-patch-all.real` и обязана
покраснить 109 следом `ОБРЫВ_НА_СНЯТОЙ_РУЧКЕ`.

**Общее правило, вынесенное из находки:** проверка, пинящая ФОРМУ записи
вместо поведения, легализует любой дефект, попавший в пин. Там, где можно
исполнить сам предмет с его собственными байтами, греп формы — не зубы.

**Свип того же класса по всем стендам (контроллер, тот же разбор).** Грепов
всего 33; по ИСХОДНИКУ (а не по выводу прогона) читают четыре места:
`corpus-tools-bench.sh:1025` (имя замка во всех четырёх домах читает одну
ручку), `:1095` (у probe-bench есть своя таблица причин), `:1247-1252`
(объявление и все использования `SWEEP_ENV_SCRUB`), `:1379` (своё имя ручки
пропуска у каждого из трёх пусковых). Ни одно из них НЕ повторяет дефект W-3:
у каждого рядом стоит половина, мерящая ПОВЕДЕНИЕ (живой прогон под
протёкшим окружением, занятый замок, самопроверка probe-bench), а причина, по
которой вторая половина пинит форму, названа в самом коде — пусковой живёт в
ИСПОЛНЯЕМОМ файле, а зубы правят только копии. Дефектом форму-пин делает не
сам факт пина, а отсутствие исполняемой половины там, где предмет исполним:
у шести сайтов `__envon` её не было, и ветка «ручка снята» была недостижима
для свипа по устройству.

**Поправка к зубам W-3, найденная самим стендом.** Первая редакция новой
проверки искала сайт по строке `__envon ИМЯ || ` и при её отсутствии молча
пропускала потребителя. Тогда пять СТАРЫХ мутаций (118-120, 122, 123 — они
вырезают читателя, заменяя строку на `:`) стали краснить сценарий 109 следом
`ОБРЫВ_НА_СНЯТОЙ_РУЧКЕ`, то есть объявлять удалённый читатель обрывом.
Правило «мутация обязана покраснить свой сценарий СВОЕЙ причиной» поймало это
на первом же self-check: `покраснели=123`, пять расхождений следа, EXIT=1 —
без него подмена причины прошла бы молча и зелено.

Разведено на два счётчика и два следа: `САЙТ_ЧИТАТЕЛЯ_ПРОПАЛ` (читателя не
стало — старые пять мутаций) и `ОБРЫВ_НА_СНЯТОЙ_РУЧКЕ` (сайт на месте, но
обрывается — мутация 128). Сайт ищется формой, ДОПУСКАЮЩЕЙ обе записи
(`|| rc=$?` и `; rc=$?`): иначе возврат сломанной формы читался бы как
исчезновение сайта, и мутация 128 краснила бы чужой причиной.

## Круг 26, W-2 ЗАКРЫТ — перепись якорей стала стадией конвейера

Повод: класс повторился на приёмке W-3. Прогон конвейера со снятой ручкой дошёл
до стадии зубов гейта чисел и отказал — «ИТОГ мутаций=40 покраснели=38», два
уехавших якоря (D2 за числом в README, D7 за `EXPECTED_MUTATIONS`). Точность
цены: отказ случился ДО первой сборки (стадия 0e стоит перед распаковщиком), то
есть стоил пре-флайта и сорока прогонов гейта, а не полного билда.

Сделано, а не отложено:

1. `tools/docnum-bench.py --anchors` — перепись: каждая строка таблицы обязана
   иметь ровно одно вхождение своего ВХОДА в названном файле; уехавший назван
   своим номером. Класс отказа — 4 («объявленные байты не те, что названы»).
2. Своя пара зубов у переписи: положительный контроль на синтетике (вход на
   месте / пропал / задвоился / файла нет). Замерено, что контроль краснит
   и СЛЕПУЮ перепись (всегда «уехавших нет»), и ПАНИКЁРА (всегда «всё уехало»).
3. Стадия вписана в конвейер ПЕРЕД зубами гейта — отдельным объявлением и своей
   таблицей кодов.
4. Проверено мутацией на живом дереве: сдвиг одного пробела в якоре D2 даёт
   `ЯКОРЬ D2 УЕХАЛ -- README.md: вхождений 0`, код 4; файл восстановлен
   байт-в-байт.

**Граница названа вслух.** Перепись читает ТРЕТЬЕ поле строки (вход) и ничего
не знает о ПЯТОМ (ожидаемый след гейта). Это не теория: у D2 след остался на
«127 mutations», когда вход уже стал 128, перепись прошла зелено, и поймал
это только полный прогон. Поэтому зелёная перепись объявляет ровно «входы на
месте», а не «таблица догнала волну» — и говорит это своей же строкой вывода.

## Круг 26, W-4 — ПОСЫЛКА ПРОЧИТАНА НЕВЕРНО (исправление контроллера)

Первая редакция этого раздела утверждала, что фоновый свип был УБИТ в 09:34 и
оставил `~/.tweakcc/config.json` с `ccVersion = "0.0.0-probe"`. Это неверно, и
ошибка моя. Свип не был убит — он ВИСЕЛ: `lsof` показал живой `bash` (pid
75797), державший `/tmp/cc-matrix/sweep.lock`. Вывод «мёртв» вышел из неполного
фильтра: я грепал `ps` по строке `sweep.sh`, а лидер прогона называется
`sweep.self.WOzlPa` и под фильтр не попадал; пустой ответ я прочитал как
отсутствие процесса. Ровно тот случай, что записан в ките: пустой результат —
не доказательство отсутствия.

Следствие: `ccVersion = "0.0.0-probe"` был не обломком, а ШТАТНЫМ рабочим
состоянием ЖИВОГО зонда, и я записал поверх него снимок. Прогон после этого
загрязнён мной, остановлен своей же дверью (`sweep.sh --stop`); его вердикт по
пяти версиям НЕ ИЗМЕРЕН и засчитан не будет.

**Что остаётся — как МЕХАНИЗМ, а не как наблюдение.** Случай SIGKILL объявлен
в шапке зонда (`tools/build-path-probe.sh:51-52`), но два читателя живого
состояния о маркере не знают, и это проверяемо по коду: `:451` снимает
`$TWEAKCC_CFG` в снимок БЕЗУСЛОВНО (следующий зонд закрепил бы чужой обломок
как «пристинное»), а `claude-patch-all.sh:2489` при неравенстве `CFG_VER`
уходит в ветку освежения бэкапа tweakcc — точка возврата человека
переписывается по значению, оставленному предыдущим прогоном. Измеренного
случая за этим НЕТ: это гипотеза о механизме, и в задаче #43 она помечена
именно так. Стражи ставятся всё равно — механизм дефектен независимо от того,
задел ли дефект сегодняшнего потребителя.


## Круг 26, находка контроллера W-5 — сценарий 1 стенда синхронизации проб ВИСНЕТ навсегда на своём же пути отказа

Измерено: корпусный свип на дереве `91ee76c` простоял **3 часа 32 минуты** без
единой строки в логе. Не отказ, не смерть — заклинивание. Дерево процессов на
момент замера:

```
75797 bash /tmp/cc-matrix/sweep.self.WOzlPa            (лидер, держит sweep.lock)
76852  └ tools/build-path-probe.sh
81118     └ tools/build-path-probe.sh
81119        └ claude-patch-all.sh
69553           └ tools/probes-sync-bench.sh
69582              └ scripts/probes-sync.sh --to-home   (первый писатель)
69595                 └ stub/cp                          (ждёт release)
81996                    └ (sleep)
```

**Механика.** Сценарий 1 поднимает первого писателя в фоне с подменённым `cp`,
который сообщает о входе файлом `ready` и ждёт файла `release`. Дальше:

```bash
if ! wait_file "$ready"; then
  kill "$first_pid" 2>/dev/null; wait "$first_pid" 2>/dev/null
  ...
```

`wait_file` даёт 100 шагов по 0.05 c — **5 секунд**. Под свипом машина занята
(зонд пути сборки форкает конвейеры), первый писатель до `cp` за 5 секунд не
доходит: в замере `ready` появился в 09:39 при корне сценария от 09:38. Ветка
отказа посылает TERM первому писателю — но `bash` НЕ доставляет сигнал, пока
исполняется его передний ребёнок, а ребёнок этот — заглушка, ждущая `release`,
которого ветка отказа не создаёт НИКОГДА. `wait "$first_pid"` встаёт навсегда.
Взаимная блокировка: заглушка ждёт файл, который создаётся только на удачном
пути; удачный путь недостижим, потому что прибор уже ушёл в отказ.

Проверено на живом прогоне: создание `release` руками разблокировало цепочку за
секунды, свип продолжил работу и снова начал писать в лог.

**Цена по устройству:** висит не сценарий, а ВЕСЬ свип — у его пред-стадий нет
часового. «Прогон идёт» и «прогон встал» выглядят одинаково: пустой хвост лога.

**К исполнению (волна 32):**

1. Ветка отказа освобождает заглушку ПЕРВЫМ действием (`: > "$release"`), и
   только потом сигналит и ждёт. Освобождение до сигнала — не украшение: без
   него сигнал недоставим по устройству bash.
2. Ожидание смерти писателя — ОГРАНИЧЕННОЕ, с названной причиной по исчерпании
   бюджета, а не голое `wait`. То же на удачном пути: сегодня и он не имеет
   потолка.
3. Бюджет `wait_file` поднять и назвать константой: 5 секунд меряют скорость
   МАШИНЫ, а не свойство замка, и под нагрузкой прибор объявляет отказ там, где
   дефекта нет (ложный отказ — тоже неверное измерение).
4. Зубы: сценарий, в котором `ready` не появляется НИКОГДА, обязан кончиться
   отказом в пределах своего бюджета. Мутация, снимающая освобождение из ветки
   отказа, обязана краснить его по таймауту, а не вешать стенд.

## 2026-08-31 — справочник классов и моделей в промте судьи принят из соседней сессии

Происхождение: правка сделана ДРУГОЙ сессией прямо в доме
(`~/.claude/probes/judge/prompt.md`, 14:30) и передана сюда сообщением как
корпусному владельцу. Принята по слову юзера. Проверялась замером, а не на
слово:

- дифф — три куска, все внутри «СПРАВОЧНИКА КЛАССОВ И МОДЕЛЕЙ» (строки
  173-245); запись класса 1c сверена отдельно и совпадает ДОСЛОВНО;
- каждое из пяти утверждений сверено с ДРУГИМИ домами: эффективный гейт
  (`hooks/routing-table.toml` + машинный `routing-override.toml`) и файлы
  агентов. `deepseek-v4-pro` в базе оставлен намеренно («в базе всё полное»),
  но оверрайд снял его из scout/research/audit — то есть промт называл в scout
  ПЕРВЫМ ту модель, которую эффективный гейт уже не пропускает; `stealth/
  ox-alpha` живёт только как «экс-» (преемник glm-5.3-flash); в scout
  `qwen3.8-flash` ратифицирован, `glm-5.3-flash` — нет, и правка написала
  именно так; четыре ратификации research подтверждены оверрайдом (:240).

**Уточнение к формулировке «только данные».** Правка вносит и обязательства —
«в паре с параллельным скаутом», «гарды в диспатче: инкрементальный отчёт,
ограниченные команды», «в паре с grounding-полосой», «не предлагай его в
вердиктах». Решающих правил судьи (три предмета, сторона умолчания, пороги
отмены) они не трогают, но менять то, ЧЕГО судья требует от диспатча, они
могут. Названо здесь, чтобы следующий замер корпуса не приписал сдвиг форме
правил.

**Почему это вообще потребовало действия.** Правка легла только в дом, а
раскатка кита сверяет дом с каноном и ОТКАЗЫВАЕТ на расхождении
(`probes-sync.sh --diff` → `расходится файлов: 1`, код 1): следующий прогон
конвейера был заблокирован, а штатная починка `--to-home` затёрла бы правку
каноном. Канон приведён к дому байт-в-байт, `--diff` → 0.

**Правило, подтверждённое этим случаем:** у промта судьи РОВНО ОДИН источник —
канон кита; правка в доме живёт до первой раскатки. Сосед записал у себя
смежное: вход или выход модели из пула затрагивает четыре дома (документ,
плагин/оверрайд, файлы агентов, справочник судьи).

**Отдельно, к сведению:** перечень агентов, загруженный в ЭТУ сессию при
старте, устарел — он несёт перевёрнутый пересказ про glm-5.3-flash в scout
(«ратифицирован… half the wall time»), тогда как файл на диске исправлен в
14:16 и говорит обратное. Факты ратификации брать с диска, а не из стартового
перечня сессии.

## 2026-08-31 — W-5 ЗАКРЫТА волной 32 (проверено контроллером лично)

Исполнено по запиненному дизайну `docs/review/wave32-brief-hang.md` с
поправкой №1. Ветка отказа сценария 1 теперь освобождает заглушку ПЕРВЫМ
действием, до сигнала; ожидание смерти ограничено (`wait_death`, добивание
`kill -9` по исчерпании бюджета); `wait_file` получил названные константы
`WAIT_READY_STEPS=600` / `WAIT_DEATH_STEPS=200` — 30 секунд вместо пяти, чтобы
прибор не мерил скорость машины. Общий кусок вынесен в `two_writers`, который
делят сценарий 1 и режим `--hang-case`.

Зуб — сценарий 7: игрушечный прогон с заглушкой, которая о входе НЕ сигналит
никогда; путь отказа обязан кончиться в бюджете и не бросить сироту. Ноги
запинены порознь, каждая краснеет СВОЕЙ причиной:

* мутация 7 снимает всю починку разом (порядок и потолки) → `ПУТЬ_ОТКАЗА_ЗАВИС`
  (в прогоне контроллера красное пришло от часового: `Killed: 9`);
* мутация 8 удерживает ТОЛЬКО освобождение — потолки на месте, зависания нет,
  но заглушка остаётся сиротой → `СИРОТА_ЗАГЛУШКИ`. Проверка сироты идёт ДО
  собственного освобождения сценария, иначе заглушка выйдет сама и утечка
  станет невидимой.

Гейты в прогоне КОНТРОЛЛЕРА (без пайпов, код читается прямо):

```
bash -n tools/probes-sync-bench.sh                → SYNTAX=0
bash tools/probes-sync-bench.sh                   → SCEN=0, 40 с, сценариев=7 расхождений=0
bash tools/probes-sync-bench.sh --self-check      → SELF=0, 140 с, мутаций=8 покраснели=8
python3 tools/docnum-bench.py --anchors           → 0, все 40 якорей на месте
python3 tools/docnum-bench.py                     → 0, мутаций=40 покраснели=40
```

**Отклонения исполнителя, адъюдицированы контроллером.** Три названы им самим и
приняты: (1) он сам нашёл и починил отсутствующую ветку `8) scenario_7` в
диспетчере `run_scenario` — без неё мутация 8 проходила МОЛЧА, то есть зуб был
бы вакуозным; (2) комментарий «Жертва мутации 7» → «Жертва мутаций 7 и 8»;
(3) снят устаревший комментарий вместе со строкой, которую он описывал.

**Отклонение, которое исполнитель НЕ назвал и не мог поймать своими тремя
гейтами:** дописанный им хвост строки 131 README попал под гейт чисел —
владелец чисел «7 сценариев и 8 мутаций» опознавался общим словом «стенд», а
не именем `probes-sync-bench` (три расхождения на одной строке), плюс хвост был
написан по-английски внутри русской строки. Переписано контроллером: имя
владельца стоит вплотную к числам, порядковые номера мутаций из текста убраны
(они читались бы как счётчики), язык строки выровнен. После правки гейт чисел
зелёный обоими режимами. Урок в общий счёт: **гейты, названные в брифе, не
покрывают доки, которые исполнитель правит попутно** — док-гейт гоняет
контроллер, а не автор правки.

## 2026-08-31, W-4 — посылка ИЗМЕРЕНА, читается вторым чтением

Прежняя редакция W-4 объявляла маркер в живом конфиге гипотезой о механизме.
Сегодня он снят с машины прямо во время работы:

```
~/.tweakcc/config.json   ccVersion='0.0.0-probe'   mtime 15:58:33
pid 26337 bash /tmp/cc-matrix/kit.mFTfX4/tools/build-path-probe.sh   START 15:58:33
pid 26338   └ .../cc-build-path-probe.QklpUw/kit/claude-patch-all.sh
pid 38038 bash .../tools/build-path-probe.sh   (стадия свипа, лидер sweep.self.2mXgVe)
```

Маркер принадлежит ЖИВОМУ зонду идущего свипа, а не убитому предшественнику.
Это второй раз, когда это состояние встречается, и первый, когда оно опознано
верно: в прошлый раз я прочитал его как обломок и записал поверх, загрязнив
чужой прогон. Проверка, которая различает: mtime конфига против времени старта
живого `build-path-probe` по pid — по ИМЕНИ процесса фильтровать нельзя, лидеры
называются `sweep.self.XXXXXX`.

Следствие для стража: отказ верен в обоих чтениях (второй зонд, снявший чужое
одолженное состояние, вернёт его человеку как «пристинное»), но ТЕКСТ отказа не
имеет права утверждать смерть предшественника. Оба чтения и проверка для второго
вписаны в брифе поправкой №2.

Побочно измерено: два зонда пути сборки делят ОДИН живой `~/.tweakcc` без
взаимного исключения. Порчи сегодня не случилось только потому, что страж
отказал рано. Отдельного механизма (замок вокруг одолженного дома) волна не
ставит НАМЕРЕННО: отказ второго зонда закрывает единственный путь порчи —
снятие чужого одолженного состояния в свой снимок. Если найдётся путь, который
отказ не закрывает, это отдельная находка.

## 2026-08-31, НОВАЯ НАХОДКА — числа внутри питоновских heredoc'ов гейт чисел НЕ ВИДИТ

Измерено на двух строках одинаковой формы в одном файле:

```
tools/build-path-probe.sh:217   echo "build-path-probe K: сценариев=1 мутаций=1 ..."   -> гейт КРАСНЕЕТ
tools/build-path-probe.sh:346   print("build-path-probe L: сценариев=4 мутаций=4 ...") -> гейт МОЛЧИТ
```

Разница только структурная: 217 — шелловская проза, 346 лежит внутри
питоновского heredoc `PY_LSOF`. Ни `docnum:`-пометки, ни объявленного владельца
у 346 нет — то есть число живёт негейтированным и может протухнуть молча.

Класс дефекта: сканер прозы гейта не заходит внутрь питоновских тел, а счётчики
приборы печатают именно оттуда. Гейт синтаксиса heredoc'и перечисляет ВСЕ
(круг 28, F-13 закрыл ровно это для синтаксиса) — гейт чисел ту же перепись не
получил. Сколько ещё чисел спрятано в heredoc'ах кита — НЕ ИЗМЕРЕНО.

Находка НЕ относится к W-4 и в её волну не вносится: у неё свой предмет
(перепись мест, где кит печатает счётчики) и свои зубы. Открыта отдельной
задачей, не закрыта пометкой и не отложена молча.

## 2026-08-31 — W-4 ЗАКРЫТА волной 32 (проверено контроллером лично)

Два стража по запиненному дизайну `docs/review/wave32-brief-marker.md` с тремя
поправками контроллера.

**Канон маркера** — `claude-patch-all.sh:2366`, верхний уровень рядом с
`TWEAKCC_CFG`. Дом выбран не по вкусу: конвейер не делает `source` ни одного
файла и получить значение извне не может, а зонд читать чужой файл умеет.
Столбец 0 — констрейнт, а не оформление: зонд достаёт значение якорем
`^TWEAKCC_PROBE_CFG_MARKER=`, и отступ оставил бы его без маркера. Литерала
`0.0.0-probe` в зонде не осталось ни одного.

**Страж зонда** — `tools/build-path-probe.sh:552-574`, вплотную перед снятием
снимка и ПОСЛЕ разбора случаев: случаи, которые конфиг не одалживают (`l`, `k`),
работают при любом его содержимом. Отказ кодом 2 называет ОБА чтения маркера и
не утверждает ни одного как факт.

**Страж конвейера** — `claude-patch-all.sh:2504`, ДО сравнения `CFG_VER` с
версией цели. После сравнения он был бы недостижим по существу: маркер никогда
не равен настоящей версии, поток уже ушёл бы мимо.

**Зубы.** Случай `k` зонда: игрушечный `HOME` с маркером, дочерний `--case r`,
отказ до изменения файла (сверка sha256 до и после). Контроль краснит по
ОТСУТСТВИЮ ТЕКСТА стража, а не по коду ребёнка — без стража ребёнок исполняет
`r` и падает по соседней причине (в прогоне контроллера `child rc=1`), и такой
красный доказывал бы не ту дверь. Страж конвейера: двенадцатый случай таблицы
истинности `backup-divergence-probe` плюс мутация, снимающая ветку из
ИЗВЛЕЧЁННОГО текста.

Гейты в прогоне КОНТРОЛЛЕРА: SYNTAX_PIPE/PROBE/BDP=0; BDP=0 («таблица из 12
случаев и 1 мутации сошлась»); CASE_K=0; CASE_L=0; ANCHORS=0; DOCNUM=0
(мутаций=40 покраснели=40).

**Ложное объявление, пойманное контроллером и исправленное (поправка №3).**
Первая редакция объявила `EXPECTED_SCENARIOS=1` у прибора с ДЕСЯТЬЮ случаями
(`CASES=abcdurxplk`) — счёт одного случая K, выданный за счёт владельца. Гейт
был при этом ЗЕЛЁНЫМ: он охранял ровно то число, которое ему объявили. Это хуже
отсутствия объявления — выглядит как истина и краснит любую честную будущую
прозу. Исправлено на сумму по самопроверяющимся случаям (K 1/1 + L 4/4 = 5/5),
строки случаев потеряли счётную форму при неизменном поведении.

**Собственная мутация контроллера — проверка, что объявление не декоративно.**
`EXPECTED_SCENARIOS=5` -> `6`, прогон гейта чисел:

```
DOCNUM=2
README.md:127 «build-path-probe has 5 scenarios and 5 mut» — объявлено «6 scenarios» (владелец build-path-probe)
```

Потребитель живой, владелец опознан по имени. Константа возвращена на 5.

**Урок волны, второй подряд того же корня.** В задаче #44 гейт, названный в
брифе, не покрыл доки, которые исполнитель правил попутно. Здесь ЗЕЛЁНЫЙ гейт не
покрыл ИСТИННОСТЬ того, что ему объявили. Общее: **гейт доказывает согласие
между собой и объявлением, а не соответствие объявления миру** — соответствие
проверяет только тот, кто знает предмет. Оба раза это поймал контроллер личным
чтением, а не прогоном.

## 2026-08-31 — ДОБОР к W-4: страж конвейера убивал сам зонд (ошибка дизайна контроллера)

Свип на `292846c` ОТКАЗАЛ: зонд пути сборки, 7 провалившихся утверждений от
ОДНОЙ причины. Из его лога (`a.log:239`):

```
FATAL: tweakcc's config has ccVersion=0.0.0-probe, the
  build-path probe marker. Continuing would make tweakcc refresh its backup
```

`seed_version_mismatch` вписывает маркер НАМЕРЕННО — зонду нужно расхождение
версий, чтобы tweakcc пошёл освежать бэкап, это и есть предмет его сценария.
Страж отказывал ровно на этом значении: зонд клал сам себя. Бриф запинил страж
на строку, которую зонд сеет по своему устройству — ошибка автора брифа, не
исполнителя.

**Почему всплыло только в свипе.** Тяжёлые случаи зонда исполнителю запрещены
(они собирают образы), лёгкие `k`/`l` конвейер не запускают. Запрет верен;
неверно было не предвидеть коллизию «страж в конвейере против зонда, который
этот конвейер запускает». Правило на будущее: **страж, поставленный в конвейер,
меряется против КАЖДОГО прибора, который конвейер вызывает**, и до отправки.

**Решение.** Одалживающий объявляет заём сам: `CLAUDE_PATCH_PROBE_CFG_LOAN=1`
ставится ТОЛЬКО в `run_pipeline` зонда, рядом с таким же объявленным
`CLAUDE_PATCH_SKIP_MODELS=1`. Страж при ней не отказывает, но и НЕ МОЛЧИТ —
печатает объявление с именем ручки. Три чтения маркера покрыты и после правки:
человек при живом зонде — отказ; человек после убитого зонда — отказ; сам зонд —
работа с объявлением.

**Смежный разрыв, найденный контроллером сверх брифа.** Ручка ОСЛАБЛЯЕТ гейт, а
список снятия операторской среды у `tools/sweep.sh` её не знал: экспортированное
значение прошло бы во все пять сборок и распространило объявление займа на
прогоны, которые ничего не одалживали. Ручка добавлена в `env -u` с основанием в
комментарии — по тому же правилу, по которому там сняты SKIP_BENCH и
GATE_BUDGET.

**Зубы:** случай 13 `backup-divergence-probe` проверяет ОБА условия (страж не
отказал И напечатал объявление; молчаливый пропуск — провал случая), мутация 2
заставляет стража игнорировать заём и краснит случай 13 своей причиной.

**Вердикт свипа — ИЗМЕРЕН, впервые с волны 31.** Дерево `292846c+dirty`:

```
зонд пути сборки ЗЕЛЁНО · корпусные инструменты ЗЕЛЁНО · зубы реестра ЗЕЛЁНО
246/247/248/250/251: exit=0 ok=119 fail=0
```

**Порядок исправлен.** Прошлый раз коммит и отправка шли ДО свипа, и красное
уехало в origin. Теперь свип гоняется по рабочему дереву, коммит — только по
зелёному вердикту.

## 2026-08-31 — НАХОДКА: корни зонда копятся без потолка И одновременно НЕЛЬЗЯ чистить вслепую

Измерено при переходе на 2.1.252, два отказа подряд, оба честные и оба про
окружение, а не про патчи.

**Отказ первый — диск.** Том данных: 431 Gi из 460, свободно **428 Mi**. Зонд
пути сборки отдал код 2 («прибор не может мерить»), а не 1 («патч не сошёлся»):
`echo: write error: No space left on device`. Граница кодов кита окупилась
прямо здесь — при коде 1 разбор ушёл бы искать съехавшие участки там, где их
нет, и «чинить» работающие патчи под симптом кончившегося диска.

Причина наполнения — в том числе своя: `KEEP_ROOT=1` оставляет корень упавшего
прогона «для разбора», каждый по **2.2 ГБ**, и они копятся БЕЗ ПОТОЛКА. Четыре
накопленных корня = 8.8 ГБ, диск в ноль, сборки невозможны физически.

**Отказ второй — мой собственный страж, первый настоящий случай.** Упавший по
ENOSPC прогон засеял живой конфиг маркером (mtime 23:17:27) и умер, не вернув
исходное. Следующий прогон отказался снимать этот обломок в свой снимок — то
есть ровно то поведение, ради которого W-4 и делалась. Страж сработал верно.

**Ошибка контроллера, которая из этого вышла.** Чистку я сделал глобом по всем
корням (23:20) — и снёс вместе с прочими корень того упавшего прогона, а в нём
`config.json.snapshot`: ЕДИНСТВЕННЫЙ путь возврата, на который указывает первая
дверь стража. Восстановление пошло по второй двери (знаю настоящую версию
измерением: установлено 2.1.251, и это же значение конфиг нёс сегодня после
штатной остановки свипа). Ключей в файле до и после — 5 и 5, менялось только
`ccVersion`.

**Класс дефекта.** Корень упавшего прогона — НЕ мусор: пока живой конфиг несёт
маркер, этот корень является единственным путём назад. Но и копиться без
потолка он не может — упирает диск и кладёт все сборки на машине. Сегодня оба
свойства столкнулись, и я разрешил столкновение неверно: удалил всё, включая
несущий путь возврата.

Правильная прополка обязана различать: корень, чей возврат ЗАВЕРШИЛСЯ, удаляем
свободно; корень, чей возврат НЕ завершился, держим и НАЗЫВАЕМ — он адресат
первой двери стража. Отличать нужно по следу в самом корне, а не по времени и
не по размеру. Открыто отдельной задачей.

## 2026-09-01 — 2.1.252 измерена: наши патчи целы, слой tweakcc неполон по ВНЕШНИМ данным

Свип по одной версии на дереве `e48e211+dirty`:

```
зонд пути сборки ЗЕЛЁНО (полный набор случаев abcdurxplk) · корпусные инструменты ЗЕЛЁНО
зубы реестра ЗЕЛЁНО
SWEEP 252: exit=0 ok=119 fail=0 tweakcc=14 bench=1
```

**Наши 25 шагов: ноль съехавших участков** — лучший из переходов (на 251 мимо
шли четыре участка плюс патч форка).

**Но `tweakcc=14` против 33-36 у соседей.** Разбор: не легли 19 ТЕКСТОВЫХ
правок (System Prompt / Tool Description / Agent Prompt / Skill / Data /
System Reminder). Причина названа самим прогоном (`sweep-252.log:298`):

```
Prompts file not found for Claude Code v2.1.252. This version was released
within the past day or so and will be supported within a few hours.
```

Источник данных — `systemPromptDownload.ts:42` форка:
`raw.githubusercontent.com/Piebald-AI/tweakcc/refs/heads/main/data/prompts/prompts-<версия>.json`.
Замер 2026-09-01: `2.1.251 -> 200`, `2.1.252 -> 404`. То есть дефекта нет ни у
нас, ни у апстрима — данных под новую версию ЕЩЁ НЕ ОПУБЛИКОВАЛИ.

Ложная тревога, снятая замером: `getModuleLoaderFunction: failed to find module
loader function` есть и в `sweep-250.log`, и в `sweep-251.log` — не регрессия
252, и патч всё равно лёг (`✓ Script patch applied`).

**Решение юзера (2026-09-01):** ждать файл промтов и ставить ПОЛНОЙ. Установка
сейчас молча унесла бы 19 правок, которые на живой 2.1.251 ЕСТЬ.

## 2026-09-01 — НАХОДКА: счётчик `tweakcc=N` свип ПЕЧАТАЕТ, но ничем не ГЕЙТИТ

Тот же прогон: падение 33 -> 14 прошло вердиктом «красных нет». Число выводится
(`sweep.sh:1076`, счёт строк `^    ✓ ` в логе сборки) и попадает в сводку, но ни
одна дверь на него не смотрит. Молчаливая потеря покрытия ЦЕЛОГО слоя выглядит
как зелёный прогон.

Сегодня потеря объяснилась внешней причиной и оказалась безобидной. Механизм от
этого не перестаёт быть дефектным: ровно так же прошло бы и падение от НАШЕЙ
правки, сломавшей интеграцию с tweakcc. Тот же класс, что уже ловился в ките
дважды: печатается — значит кто-то считает это важным; не гейтится — значит
никто этого не проверяет.

Открыто отдельной задачей: у счёта должен быть объявленный ожидаемый уровень (с
владельцем, как у прочих чисел кита) и дверь, отличающая «данных ещё нет»
(внешняя причина, объявляется) от «стало меньше по нашей вине» (отказ).

## 2026-09-01 — переход на 2.1.252 состоялся ПОЛНОЙ сборкой

Файл промтов апстрима под новую версию опубликовался
(`prompts-2.1.252.json` перешёл с 404 на 200 в тот же день), и решение юзера
«ждать данные, потом ставить полной» стало исполнимым.

Свип по одной версии на дереве `9f7e5f0`:

```
SWEEP зонд пути сборки: ЗЕЛЁНО
SWEEP стенд корпусных инструментов: ЗЕЛЁНО
SWEEP зубы реестра проверок: ЗЕЛЁНО
SWEEP 252: exit=0 ok=119 fail=0 tweakcc=35 bench=1
SWEEP DONE (дерево 9f7e5f0): все 1 версий измерены, красных нет
```

Счётчик tweakcc поднялся с прежних четырнадцати к уровню соседей — то есть
текстовые правки апстрима легли, а не были молча унесены. Именно это условие
и разделяло «ставить сейчас» и «ждать»: на прошлом замере счёт стоял на
четырнадцати ровно потому, что данных под версию ещё не было.

Установка штатным путём кита (`--update 2.1.252`): все проверки конвейера
зелёные при нуле красных, пол на пристинном образе сошёлся, счёт применённых
правок tweakcc в логе установки тот же, что намерил свип. Симлинк переведён
на новую версию, `claude --version` отвечает `2.1.252`. Предыдущие две версии
и их пристинные копии оставлены — их исполняют живые сессии.

**Наших патчей мимо не прошло ни одного.** Второй переход подряд без
съехавших участков (после 251, где апстрим переписал выбор модели plan-режима
и мимо ушли четыре шага плюс патч форка).

## 2026-09-01/02 — переход на 2.1.257: четыре съехавших участка, расхождение имён staging, дом объявленных непроходов

Решение юзера: «надо обновить несмотря на не все патчи» — файл промтов апстрима
под 257 ещё не опубликован, текстовый слой tweakcc заведомо неполон (`tweakcc=13`
против соседского уровня 33-36), и это принято сознательно. Отдельным ответом
юзер выбрал «чинить 4 участка, потом ставить».

### Мимо прошли четыре наших шага из двадцати пяти

Ни один байт при этом не был записан: расхождение поймано сборкой, живая
установка не пострадала. Диагноз каждого — от КРАСНОГО замера на образе 257,
не от чтения:

| шаг | что переписал апстрим | чем чинилось |
|---|---|---|
| 12 | строки схемы подняты в КОНСТАНТЫ: `description:F().describe(K)` вместо литерала | якорь стал константо-осведомлённым: сперва собираются имена констант с нужным литералом, затем `describe(` принимает литерал ЛИБО одно из этих имён |
| 19 | выражение модели завёрнуто в вызов: `{model:g(A.model)}` вместо `{model:A.model}` | хвост регекспа ловит выражение модели и объект опций ПОРОЗНЬ, плюс перекрёстная сверка: захваченный объект обязан быть тем самым, из которого начисление читает `querySource` — иначе захват сел на обёртку |
| 22 | — | чистый каскад двенадцатого, своей правки не потребовал |
| 27 | терминатор участка сменился с `;` на `,` | терминатор ЗАХВАТЫВАЕТСЯ и воспроизводится; в реестре обновлён комментарий с измеренной реальностью (252: dangerousRemoval, isolatePeerMachines, restrictedMode; 257 добавил outsideReadsBlocked) |

Проверка `full bypass keeps peer-machine immunity` покраснела по той же причине,
что и шаг 27: она пинила `:void 0;`. Обе её ветви ослаблены до `:void 0[;,]` —
терминатор не входит в гарантию, которую проверка стережёт.

**Обратная совместимость трёх переписанных форм измерена по ВСЕМУ корпусу**,
двенадцать версий 2.1.233 → 2.1.257: новые формы совпадают ровно там, где
совпадали старые, плюс 257. Строитель схемы шага 12 опознан на каждой версии
(`F`, `H`, `D`, `I`, `i`); перекрёстная сверка шага 19 истинна на всех
двенадцати; терминатор шага 27 — `;` на всех старых и `,` только на 257.

### Установка вскрыла расхождение имён staging между нашими же двумя файлами

Первая установка оставила пусковой указывающим на `2.1.257.staging.24891`, без
`2.1.257`, без `.orig`, и пол проверок молча пропустился. Корень: `claude_patch.py`
именует staging как `<версия>.staging.<pid>` (строки 629, 700), когда версия уже
установлена, а оболочка снимала ГОЛЫЙ суффикс `.staging` в трёх местах. Чинено
одним общим помощником (`__strip_staging` / `__has_staging`, форма суффикса —
`\.staging(\.[0-9]+)?$`), границей (суффикс в имени есть, а опознанной формы
нет ⇒ код 6: ломается договор между нашими файлами) и отказом вместо тихого
пропуска пола на пути `--update`.

Первая редакция границы сломала документированный режим `--target`: зонд пути
сборки покраснел на десяти утверждениях, цитируя мой же текст. Граница сужена
до проверки ФОРМЫ суффикса и только на `DO_UPDATE -eq 1`.

Итог установки: `claude --version` → 2.1.257, симлинк переведён, `2.1.257.orig`
на месте, 119 OK / 0 FAIL, пол измерен (3 из 119 на пристинном, все объявлены),
интерфейсный гейт зелёный, стенд зондов 82 сценария.

### Дом объявленных непроходов tweakcc (структурная блокировка кита)

После установки кит в дереве стал СТРУКТУРНО красным: единственный законный
непроход апстрима (`✗ Clear screen command` на 257) валил зонд пути сборки на
сценариях (a) и (b), каскадом на семь утверждений, и свип отказывался. Сказать
«вот эта одна правка на этой версии» было НЕЧЕМ: слепая ручка
`CLAUDE_PATCH_ALLOW_TWEAKCC_FAILURES` гасит весь слой разом, и обе стороны
вычищают её НАМЕРЕННО — `tools/build-path-probe.sh:814` запускает конвейер с
явно очищенной ручкой, `tools/sweep.sh:1032` вытирает её из окружения
оператора. То есть выбор стоял между «ослепнуть везде» и «стоять».

Чинено корнем: данные — `tools/tweakcc-known-misses.txt` (TAB, `версия / имя
правки / причина`), сверка — `__tw_reconcile_misses()` в конвейере, ДВУСТОРОННЯЯ:

* объявленный и случившийся непроход → NOTE, гейт держится на остальных;
* НЕ объявленный непроход → отказ с именем правки и подсказкой обеих дверей;
* объявленный, но НЕ случившийся → тоже отказ: односторонняя сверка сделала бы
  из записи вечную индульгенцию, пережившую свою причину;
* запись привязана к версии и соседнюю НЕ покрывает.

Версия берётся из БАЙТОВ образа, а не из переменной выше по тексту: та
присваивается только на одной ветке, и под `set -euo pipefail` сверка на другой
ветке уронила бы прогон по неопределённой переменной. Опасность поймана в
собственной правке ДО прогона.

Гейт был переразведён: прежние две ветви `elif` схлопнуты в одну, иначе ветка
«крестиков нет» до сверки не доходила — а именно она ловит устаревшую запись.

### Зубы: случай (m) зонда пути сборки

Шесть сценариев (объявленный+случившийся, необъявленный, объявленный-но-не-
случившийся, объявленный для СОСЕДНЕЙ версии, образ без отметки версии, чистая
версия) и пять мутаций, каждая краснит СВОЙ сценарий своей причиной. Гоняется
сама функция конвейера над игрушечными файлами, включая байты с NUL.

### Счётчики зонда сами были незагейчены

По ходу вскрылось: `EXPECTED_SCENARIOS`/`EXPECTED_MUTATIONS` зонда пути сборки
стояли ГОЛЫМИ объявлениями — их читал только гейт чисел в прозе, а сам прибор
не сверял их ни с чем. Правка таблицы случая без правки числа проходила молча,
то есть счётчик владельца страдал ровно тем классом, который кит чинит у
соседей. Введены вклады случаев (K 1/1, L 4/4, M 6/5), отказ кодом 4 при
расхождении суммы, и сверка вклада с ДЛИНОЙ таблицы внутри L и M. Код 4 внесён
в таблицу кодов зонда. Контроли: подмена суммы → отказ 4 до чтения маркера;
занижение вклада M при сходящейся сумме → отказ 4 изнутри случая; непорченая
копия в том же мини-ките → 0 (положительный контроль, что причина не в стенде).

### Чего сверка НЕ закрывает

Задача #48 («счётчик tweakcc=N печатается, но ничем не гейтится») этой сверкой
НЕ закрыта, и путать две вещи нельзя. Сверка видит `✗` — правка ПРОБОВАЛАСЬ и не
легла. Падение 33 → 14, из-за которого задача и заведена, было другим: данных под
версию не было вовсе, правки не пробовались, крестиков не печаталось ни одного —
для сверки это чистая версия. Ровно в этом состоянии живёт и сегодняшняя 257
(`tweakcc=13` при соседском уровне 33-36 и ОДНОМ крестике): ось «сколько правок
вообще легло» остаётся без двери. Её починка — объявленный уровень с владельцем и
дверь, отличающая «данные апстрима ещё не опубликованы» от «стало меньше по нашей
вине» — идёт отдельной волной, задача #48 остаётся открытой.

### Наблюдение, вынесенное задачей

Свип дважды отказал на занятом замке при отсутствии живой сборки. Причина
найдена через `lsof`: дескриптор 9 (замок конвейера) наследуется внуками-
заглушками стендов (`probes-sync-s7.*/stub/cp`, `sleep 90`), которые переживают
родителя сиротами. Класс шире одного дескриптора — открыто задачей #49.

**ФИНАЛЬНЫЙ СВИП НА ЭТОМ ДЕРЕВЕ (снимок `da095c5+dirty`, 03:24):** зонд пути
сборки ЗЕЛЁНО, стенд корпусных инструментов ЗЕЛЁНО, зубы реестра ЗЕЛЁНО;
248/250/251/252 — `exit=0 ok=119 fail=0`, tweakcc 33/33/36/36; **257 —
КРАСНАЯ «прогонов tweakcc 0»** при `ok=119 fail=0 tweakcc=13`. Это не
дефект 257 и не дефект дома непроходов: конвейер на 257 отработал ЗЕЛЕНО —
tweakcc кончил баннером «Customizations applied with some failures», рядом
с ним NOTE конвейера об объявленном непроходе, — а свип считал прогоном
ТОЛЬКО полный баннер «successfully». Свип читал законный частичный прогон
как отсутствие прогона. Чинится волной 34a (ниже), не легализуется.

## 2026-09-02 — промт судьи: линза, а не класс, оправдывает fable (`fab97b5`)

Повод. За трое суток 30.08–02.09 fable нёс 48 из 82 Anthropic-диспатчей. По
чтению самих брифов часть fable-полос несла ТОЛЬКО перечень — claim-truth,
авторские вопросы, мутационный свип, трассу по названному пути, — под который
плейбук рассчитывает opus. Гейт здесь слеп по устройству: класс `audit`
допускает fable всегда; судья линзу не читал вовсе. Решение юзера: делить
линзы по полосам и звать веер нельзя (дороже одного прохода fable); парную и
дельта-проверки не вводить; нужна подсказка судьи.

Правило (`probes/judge/prompt.md`, раздел «ЛИНЗА, А НЕ КЛАСС»). Перечень —
работа opus; поиск неназванного — fable; одной фразы-хвоста («сверх
вопросов», «beyond the questions», «классы дефектов вне вопросов», «findings
outside this list») достаточно. Названное свойство с неперечисленными
экземплярами — перечень. Возврат называет ДВА выхода: тот же диспатч на opus,
либо вписать линзу «найди неназванное» и оставить fable — сходимость не
режется, дописывается строка брифа. Связка линз в одной полосе не делится.

Стенд. Изолированный дом `/tmp/lens-bench` (копия `probes.toml`, 25 живых
записей fable-диспатчей, свои метки), `validate.py run --project-layer off`.
deepseek-v4-flash xhigh — боевая первая ступень. Старый промт: 0 возвратов
по линзе из 8 полос с перечнем (контроль — правило и есть переменная).
v3: 5 возвратов, 1 пустая консультация канала (в v2 та же запись — 3/3
возврат), 2 WARN на записях, к которым файл брифа не был приложен (по
правилу: чего не видел — не вменять). 17 полос с хвостом — 17 пропусков.
glm-5.3 max на v2 — 23/25. Между повторами deepseek 7 нестабильных, из них
по существу (OK↔BLOCK) три: две записи без брифа и одна пограничная
(свойство названо, но экземпляры вне форм объявлены сутью работы).

Честная поправка к меткам. 5 из 25 моих меток были неверны, пока я судил по
ОПИСАНИЮ диспатча, а не по тексту брифа: три полосы несли хвост «beyond»
(fable по правилу), две — шесть/семь авторских вопросов без хвоста (opus).
Метка ставится по тексту брифа; описание диспатча — не основание.

Что не закрыто. Запись без приложенного файла брифа даёт WARN, а не возврат —
на живых диспатчах файл прикладывается (`attach_files = 3`), стенд этого
не воспроизводит. Нестабильность deepseek по ВЕЕРУ (WARN↔BLOCK на одной и
той же записи при неизменном тексте правила веера) — вне этого правила, не
чинилось. Метки 25 записей унесены в дом доказательной базы
(`validate.py label`). Гейт чисел кита на каноне зелёный.

## 2026-09-02 — волна 34a: свип читал законный частичный прогон tweakcc как «прогонов 0»

Повод. Финальный свип волны 33 (выше) красил 257 причиной «прогонов tweakcc
0» при зелёном конвейере. Корень в `tools/sweep.sh`: `twruns` считал только
баннер «Customizations applied successfully», а прогон с объявленным
непроходом (дом `tools/tweakcc-known-misses.txt`, волна 33) кончается ДРУГИМ
баннером — «Customizations applied with some failures». До волны 33 такой
прогон конвейер валил сам, и свип второго баннера никогда не видел; дом
непроходов сделал частичный прогон законным, а свип этого не узнал.

Правка (`tools/sweep.sh`). Прогон = полный баннер ИЛИ частичный:
`twruns = twok + twpart`. Частичный законен только рядом с NOTE конвейера
об объявленных непроходах (`^NOTE: объявленные непроходы tweakcc на `): без
NOTE конвейер отказал бы сам, поэтому «частичный баннер без NOTE» — отдельная
красная причина «частичный прогон tweakcc без объявленных непроходов»
(страж от прогона, где реконсиляция обойдена).

Зубы (`tools/corpus-tools-bench.sh`). Заглушка конвейера печатает баннер по
`STUB_TWEAK`: `notw` — ни одного, `parttw` — частичный + NOTE,
`parttw_undeclared` — частичный БЕЗ NOTE, иначе полный. Сценарий 114 —
частичный прогон с объявленными непроходами ЗЕЛЁНЫЙ (rc 0, «SWEEP DONE»);
сценарий 115 — частичный без NOTE КРАСНЫЙ своей причиной. Две мутации
`tools/sweep.sh`: возврат к `twruns=$twok` краснит 114 причиной «прогонов
tweakcc 0»; выкус стража NOTE (`:`) даёт 115 «SWEEP DONE» вместо красной.
Счётчики стенда 113/128 → **115/130**; README и якоря D1/D2/D7 таблицы
гейта чисел (`tools/docnum-mutations.tsv`) переведены на 115/130 — перепись
якорей ловит именно эту правку (второй прогон `--update 2.1.258` ниже вернул
код 4 «уехало 3 из 40», пока якоря стояли на 113/128).

Первый прогон стенда после установки 258: «ОТКАЗ -- исполнено 113 сценариев
из 115» — функции `scenario_114/115` были, а в списке вызовов диспетчера
(`run_all`, строка `scenario_111; scenario_112; scenario_113`) их не было;
страж счётчика стенда (`RUN != EXPECTED_SCENARIOS`) поймал это сам.
Вызовы добавлены (правка через rename, не truncate: в этот момент шёл
`--self-check` с того же файла, а bash читает скрипт по ходу исполнения).
Урок: у нового сценария ТРИ дома — функция, список вызовов, `EXPECTED_SCENARIOS`.
Измерение. `--self-check`: **мутаций=130, покраснели=130**; мутация 129
(`twruns=$twok`) краснит сценарий 114 причиной «прогонов tweakcc 0»,
мутация 130 (страж NOTE снят) краснит 115 через «SWEEP DONE» — обе своей
причиной. Чистый прогон стенда после правки диспетчера — предполёт свипа
каденции (снимок `fab97b5+dirty`): **сценариев=115, расхождений=0**
(`/tmp/cc-matrix/log/corpus-tools-bench.log`). Свип — в записи перехода на
2.1.258.

## 2026-09-02 — переход на 2.1.258: три прогона, два законных отказа, установка

Реестр npm показал 2.1.258 при установленной 2.1.257. Пин корпуса — из байтов
реестра (`tools/fetch-corpus.sh`; строка `tools/corpus-versions.txt` о трёх
полях, пин `-` до записи): `b631361941…17c78`.

Слой промтов tweakcc (проверено для ВСЕХ версий корпуса по
`Piebald-AI/tweakcc/data/prompts/prompts-<v>.json`): 2.1.245…2.1.252 —
есть; 2.1.257 и 2.1.258 — 404. Тонкий текстовый слой на 257/258 (в свипе
`tweakcc=13`) — отсутствие ВНЕШНИХ данных, не наш дефект; при появлении
файла апстрима слой поднимется без правок кита.

Прогон 1 (`--update 2.1.258`): FATAL «правка tweakcc не легла, и она НЕ
объявлена для 2.1.258: ✗ Clear screen command» — код 1, дом непроходов волны
33 сработал по назначению: та же правка, что на 257, для 258 не была
объявлена. Поправка к моему отчёту «ничего не записано»: символическая
ссылка не тронута, но tweakcc успел записать свои правки в свежескачанный
`versions/2.1.258` (дайджест `d8b6d583…`, не пин) — пристинные байты лежали
в `2.1.258.orig`. Объявлен ряд `2.1.258<TAB>Clear screen command<TAB>…`.

Прогон 2: конвейер увидел «живой файл уже несёт правки», собрал из `.orig` в
`2.1.258.staging.60595` (дайджест = пин, проверено) и вернул **код 4** на
переписи якорей гейта чисел: «ЯКОРЬ D1/D2/D7 УЕХАЛ … уехало 3 из 40» —
якоря `tools/docnum-mutations.tsv` стояли на 113/128, а волна 34a перевела
README и стенд на 115/130. Гейт отработал по назначению; якоря переведены
(D1 «115 scenarios», D2 «130 recorded mutations», D7
`EXPECTED_MUTATIONS=130`), перепись 40/40, зубы гейта 40/40.

Прогон 3: **ЗЕЛЁНО, код 0.** 119 OK / 0 FAIL; стенды судьи 44/0, цен 12/0,
проб 7/0; перепись 40/40; зубы гейта чисел 40/40; tweakcc — 14 правок легли,
1 объявленный непроход (`Clear screen command`), NOTE конвейера рядом;
пол проверок 3/119, все объявлены; интерфейс поднялся; зонды 82/82,
самопроверка 5/5. Сборка перекинута `mv` в `versions/2.1.258`, ссылка
`~/.local/bin/claude -> versions/2.1.258`; `claude --version` = 2.1.258.
Уборка: снесены `2.1.252` и сирота `2.1.258.staging.60595` (осталась от
красного прогона 2 — уборка зелёного прогона собирает такие по маске
`2.1.*`); `2.1.257` + `.orig` оставлены — их исполняют живые сессии.

Наблюдение (не дефект, названо вслух): красный прогон `--update` поверх
уже лежащей версии оставляет свою staging-копию (190 МБ) до ближайшего
зелёного прогона; серия красных перезапусков копит по копии на прогон.
Механизм сбора есть (уборка зелёного прогона), утечки без потолка нет.

**Свип каденции ЗЕЛЁНЫЙ (дерево `fab97b5+dirty`, набор по умолчанию — последние
5 версий корпуса).** Предполёт: зонд пути сборки ЗЕЛЁНО, стенд корпусных
инструментов ЗЕЛЁНО (115/0), зубы реестра ЗЕЛЁНО, дом tweakcc свой.

```
250 exit=0 ok=119 fail=0 tweakcc=33 ours=1 smoke=1 iface=1 bench=1 forms=1 floor=1
251 exit=0 ok=119 fail=0 tweakcc=36 ours=1 smoke=1 iface=1 bench=1 forms=1 floor=1
252 exit=0 ok=119 fail=0 tweakcc=36 ours=1 smoke=1 iface=1 bench=1 forms=1 floor=1
257 exit=0 ok=119 fail=0 tweakcc=13 ours=1 smoke=1 iface=1 bench=1 forms=1 floor=1
258 exit=0 ok=119 fail=0 tweakcc=13 ours=1 smoke=1 iface=1 bench=1 forms=1 floor=1
# SWEEP DONE: все 5 версий измерены, красных нет
```

**257 позеленела ровно правкой 34a** — те же байты версии, тот же
`tweakcc=13`, что на красном прогоне 03:24; изменился ВЕРДИКТ свипа, а не
сборка. 258 читается так же (частичный баннер + NOTE = прогон). Счётчик
`tweakcc=N` по-прежнему ничем не гейтится — задача #48, отдельно.
