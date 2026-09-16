# W151: наблюдаемое снаружи при ручке CLAUDE_CODE_REFUSAL_FALLBACK_ROUTES (заземление под прибор поведения)

Машина: Darwin mmm4p.local 25.6.0, arm64 (uname -a). Дата: 2026-09-16 12:54 MSK.
Образ: `~/.local/bin/claude` -> `~/.local/share/claude/versions/2.1.273` (Mach-O arm64).
ПАТЧЕННОСТЬ: в байтах 2.1.273 — `CLAUDE_CODE_REFUSAL_FALLBACK_ROUTES` x2, `__rfr` x5, `routesOverride` x4;
в `2.1.273.orig` — 0 / 0 / 4 (grep -o | wc -l — вхождения, не строки). Образ боевой — патченный, шаг 28 в нём жив.

## 1. Площадка шага 28 в текущем образе

Чанк: `$bunfs/root/chunk-nq62bgfy.js` (6 062 542 байта; единственный в дереве с `routesOverride` и `__rfr`).
Все координаты — смещения в извлечённом файле:

- Бандл констант+предикат @2301667, голова дословно:
  `var GCn="claude-opus-4-8",sKo="claude-opus-5";function zCn(e){return zMe()&&xR(e)===sKo}`
- Читатель понижения qCn сразу за ним: `function qCn(e){return zCn(e)?GCn:e}`
- Исключение верха в find @2302221 (KCn): `return Zqn().find((s)=>h5(ze(s))&&!(jNe()===void 0&&zCn(s))&&r(s))`
- Тернар понижения цели @2302427 (Bot): `let s=KCn(fl()?(jNe()===void 0?qCn(r.id):r.id):WCn(r.id),"exact")`
- Шов (патченное тело) @2303990: `var __rfr;function jNe(){let e=process.env.CLAUDE_CODE_REFUSAL_FALLBACK_ROUTES??"";...}`
  с console.error(...) при невалидном значении.
- Оба вызова `routesOverride:jNe()` В ТОМ ЖЕ чанке: @4626948 (нон-стрим лена) и @4648259 (дельта-лена).
- Упоминаний zCn в модуле ровно 3 (деф @2301722, qCn @2301778, find @2302239) — согласуется со структурным пином
  патча «читателей предиката ровно 2» (tweakcc-patch.js:5373-5380).

Сравнение с 2.1.270: в ките (tweakcc-patch.js:5382-5384) для 2.1.270 зафиксирована СТОКОВАЯ форма
`pFn().find((s)=>Vq(je(s))&&!$On(s)&&r(s))` — ИМЯ ЧАНКА для 2.1.270 там НЕ названо; назван только ложный друг
`chunk-jb9wm99y.js` (tweakcc-patch.js:5188-5191: там `$On` — строковая константа «Teammate prompt...», не предикат).
Имена уехали ($On->zCn, pFn->Zqn, Vq/je->h5/ze), ФОРМА совпала 1-в-1 (после патча — с опт-ин скобкой).
Как обеспечено «ближайшее объявление перед площадкой»: zMe/xR разрешены не «первым совпадением по дереву», а
семантической привязкой к телу zCn в ЕГО модуле (zMe = конъюнкция firstParty-условий, xR = канонизация id,
та же роль в k7/JWe/BCn @2304601-2304639); Pe — единственное определение с телом firstParty/bedrock/vertex
(chunk-yvbqdrex.js @26909). Совпадений им по чужим чанкам не использовано.

## 2. Механизм (для прибора; всё с цитатами выше)

- Стоковые таблицы маршрутов (chunk-nq62bgfy.js @2298805-2298947):
  `var VVo=3,KVo={bio:"claude-opus-5",cyber:"claude-opus-4-8"},YVo={cyber:"claude-opus-4-8"},XVo={bio:"claude-opus-4-8",cyber:"claude-opus-4-8"}`
  QVo(e): BNe(e) (мёртвая ветвь — `function BNe(e){return!1}` @2298619) -> XVo; e=opus-5 -> YVo; иначе KVo.
  Категории: "cyber","bio" (PK @2298619), "frontier_llm","reasoning_extraction" (qVo), прочее -> "other".
- Дорожка отказа зажигается при `Ts.stop_reason==="refusal" && _d!==void 0` (@4626600-4626948), где
  `_d = h.refusalFallbackModel ?? (h.serverRefusalFallback!==void 0&&!Cn ? h.serverRefusalFallback.model : void 0)`.
  Потребитель vdt @2299904: `routesOverride ?? QVo(n)`, затем цепочка через resolveTarget=Bot.
- Итог A/B на дорожке (предсказание из кода): refusal категории "bio" на модели не-opus-5:
  сток -> fallback claude-opus-4-8 (цель KVo "claude-opus-5" понижена qCn / исключена в KCn),
  ручка -> fallback claude-opus-5 (оба обезвреживания живы). Виден в model следующего запроса.
- Pe() (chunk-yvbqdrex.js @26909): "firstParty" — ветка ПО УМОЛЧАНИЮ (ANTHROPIC_BASE_URL не сбивает);
  сбивают gateway/bedrock/foundry/aws/google/mantle/vertex ручки.
- zMe() (chunk-g4c6ggz4.js @1017807): `Pe()==="firstParty"&&Md()&&!Ld()&&CS()===null&&ese().length===0`.
  Md() @970021 = `en()?.accessToken!=null`; gge() @953626: CLAUDE_CODE_OAUTH_TOKEN даёт
  `{accessToken, refreshToken:null, expiresAt:null, scopes:rG()}`, rG() = ["user:inference"] (CLAUDE_CODE_OAUTH_SCOPES перекрывает).
- Walk_down_opus_lineup (sticky/подавление): Ddt @2301507 -> KCn(...,"walk_down_opus_lineup");
  вызывающие: bXn @3637845 (servedFallbackModel-машина) и lnn @3638491 (visibleModel/serverLane/shouldLogSuppression);
  serverLane -> serverRefusalFallback (chunk-jg6m528z.js @221113). Arm обхода требует VCn->Fm(n,"refusal_fallback",e)
  (Fm — кросс-чанковое имя, в этом диспатче не доведено) либо org-состояния.

## 3. Пробы A/B (быстрый цикл bun <дерево>/$bunfs/root/cli; стаб 127.0.0.1, положительный контроль есть)

| # | команда | с ручкой | без ручки | различает | код |
|---|---------|----------|-----------|-----------|-----|
| R0-R2 | `cli --version` | invalid/`{}`: stdout == сток (`2.1.273 (Claude Code)` + tweakcc), stderr пусто | то же | НЕТ | 0/0/0 |
| R3a-c | `cli -p "hi" --model claude-opus-5` + стаб, ANTHROPIC_API_KEY | все три: `Invalid API key · Fix external API key` | то же | НЕТ (дорога закрыта валидатором ключа до всякой модели) | 1/1/1 |
| R4a-c | то же + OAuth-креды файлом | `OAuth session expired and could not be refreshed` | то же | НЕТ (refresh ушёл на реальный хост; дорога закрыта, снята чтобы не слать фейки в сеть) | 1/1/1 |
| R6a-c | то же + CLAUDE_CODE_OAUTH_TOKEN (env; refreshToken:null — refresh невозможен) | `Failed to authenticate. API Error: 401 Invalid bearer token` | то же | НЕТ (401 НЕ от стаба: в его логе только GET /v1/models — какая-то auth-проверка идёт мимо ANTHROPIC_BASE_URL) | 1/1/1 |
| стаб | POST /v1/messages refusal-SSE (stop_reason:"refusal", stop_details.category:"bio") | дорожка отказа НЕ ДОШЛА ни в одной пробе (auth-стены выше) | — | — | — |
| каталог | GET /v1/models?limit=1000 (discovery) | одинаковый одиночный GET во всех шести прогонах | тот же | НЕТ | - |

Положительный контроль стаба: curl с model=positive-control/ctl — model из тела логируется (401/SSE отдаются).
Вывод: на всех дорогах, дошедших до измерения, ручка НЕ различима; до дорожек отказа пробы не дошли —
вооружение `_d` требует org/серверного состояния (serverRefusalFallback), офлайн невоспроизводимого.

## 4. Кандидаты наблюдаемого для прибора (из кода, ранжир по силе)

1. model следующего запроса при refusal "bio" на не-opus-5: 4-8 (сток) против opus-5 (ручка). Требует зажжённой дорожки.
2. stderr-строка `CLAUDE_CODE_REFUSAL_FALLBACK_ROUTES is not a valid routes object; using the stock refusal fallback table`
   (console.error в шве; раз на ОТЛИЧНОЕ невалидное значение). Доступна только при вызове шова дорожкой (обе routesOverride в ленах).
   В --version шов не зовётся — измерено (R1 stderr пуст).
3. visibleModel/serverLane (sticky/подавление, Ddt/lnn) — пре-запрос; arm не доведён (Fm — кросс-чанк).
4. /model список: zCn в каталог НЕ входит (3 упоминания, все в refusal-модуле) — предсказание «не различает»; не мерено (нужен pty-REPL).

## 5. DECLARED (tools/checks-on-image.sh:163-221) — факты

- Что объявляет: режим пола (`--floor`) гоняет блок проверок НА ПРИСТИННОМ образе и требует равенство
  «зелёные на стоке == DECLARED» (точнее: extra = зелена-без-строки = «порог ниже стокового пола» = отказ,
  missing = строка-есть-но-красна = «объявление устарело» = отказ; :208-218). Цитата причинника :214/:217.
- Состав: 6 строк (:163-189). Из шага 28 там ТОЛЬКО `'the armed model keeps its stock downgrade'` (:176-177,
  причина «сторожит сохранность стокового свойства -- зелена на стоке по замыслу»).
- Последствия отсутствия строки про верх линейки: НЕТ — проверки `top of the lineup is a reachable fallback`
  и `refusal fallback routes come from the config` (реестр claude-patch-all.sh:8278-8279) проверяют НАШИ формы
  и на пристинном образе КРАСНЫ по замыслу; red-проверка не может сидеть в DECLARED (missing-ветка отказала бы
  каждый прогон пола). Внести строку про верх в DECLARED значило бы сломать пол.
- Требование README:148 («каждое из двух обезвреживаний — opt-in на своей строке») живёт в доме ЗУБОВ
  tools/checks-mutations.tsv, не в перечне пола: V1 шов (:38), V2 тернар DJ (:39), V3 связка констант с двойной
  дверью — верх + сторож вооружённой модели (:40), V4 исключение в find, derived (:41). Итог: намеренное
  различие, не пробел; подтверждено claude-patch-all.sh:8268-8280 («Every record here has a mutation... the
  armed-model record rides the constants mutation's second door, declared in that row»).

## 6. НЕ ИЗМЕРЕНО

- Поведенческий A/B дорожек отказа (оба обезвреживания) — не воспроизведён офлайн: отказ провайдера эмулируется
  стабом, но вооружение `_d` (serverRefusalFallback) требует org-состояния; три auth-дороги измерены и закрыты (таблица).
- /model список через pty — не гонялся; код-предсказание «не различает» (3 упоминания zCn, все в refusal-модуле).
- Arm стикки/подавления через Fm(n,"refusal_fallback",e) — имя кросс-чанковое, в этом диспатче не разрешено.
- Ветвь cloud-provider тернара (WCn/L) — по-прежнему не замерена (README:448: "not measured and does NOT change").

Уборка: стаб убит по сохранённому PID; дерево tree273/, стабы и логи удалены (свои артефакты).
