// Claude Code multi-provider patch, as a tweakcc `adhoc-patch --script` script.
//
//   npx tweakcc adhoc-patch --script @tweakcc-patch.js
//
// Input : global `js`  (the full Claude Code bundle, ~21.6M chars)
// Output: `return js`
//
// Unlike the byte-neutral in-binary patcher (patch_claude_routing.py), tweakcc
// unpacks and repacks the bun bundle, so edits may change length freely — no
// injection/reclaim balancing is needed.
//
// Every site is located by a STRUCTURAL REGEX that keys on stable tokens and
// captures the minified identifiers, so the script survives both per-version
// and per-platform minifier drift. Any site that cannot be found aborts the
// whole patch rather than silently producing a half-patched binary.
//
// AFTER RUNNING THIS on macOS you MUST re-sign, because tweakcc signs ad-hoc
// with an identifier derived from the file name — the login keychain's ACL for
// "Claude Code-credentials" then denies access and Claude Code reports
// "Not logged in":
//
//   codesign -f -i com.anthropic.claude-code -s "<Apple Development identity>" <binary>

const fail = msg => {
  throw new Error(`multi-provider patch: ${msg}`);
};

const applied = [];
const failures = [];

// Минифицированное имя может содержать `$`: в 2.1.239 сессионный матчер
// зовётся `$jS`. В ИСХОДНИКЕ регулярки `$` — якорь конца строки, и имя,
// вклеенное без экранирования, не совпадает НИКОГДА: локатор падает не потому,
// что сборка изменилась, а потому что минификатор выбрал другую букву. В СТРОКЕ
// ЗАМЕНЫ `$` — ссылка на группу, и то же имя молча превратится в чужой захват.
// Всякое ЗАХВАЧЕННОЕ имя проходит через rxEsc перед вклейкой в шаблон и через
// repEsc перед вклейкой в замену. Групповые ссылки ($1, $2 …), которые мы
// пишем сами, не экранируются — они и должны остаться ссылками.
const rxEsc = s => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const repEsc = s => String(s).replace(/\$/g, '$$$$');

// Each patch is run in isolation and its failure RECORDED rather than thrown,
// so one run reports EVERY broken locator instead of only the first. That
// matters because a new Claude Code release can break several at once, and each
// discovery otherwise costs a full unpack/repack cycle. Nothing is written when
// anything failed: the final throw discards all edits, so a half-patched binary
// is still impossible.
const step = (name, fn) => {
  try {
    fn();
  } catch (error) {
    failures.push(`${name}: ${String(error.message).replace(/^multi-provider patch: /, '')}`);
  }
};

// --------------------------------------------------------------------------
// 1. ROUTING — per-model API base URL.
//    claude-* -> api.anthropic.com (subscription/OAuth);
//    anything else -> undefined -> the SDK falls back to ANTHROPIC_BASE_URL.
//    Site: the final firstParty client-options object in getAnthropicClient.
// --------------------------------------------------------------------------
step('1 routing', () => {
  const rx = /(accessToken\?\?null:null,)(\.\.\.!1,\.\.\.)([A-Za-z_$][\w$]*)(,)/;
  const m = js.match(rx);
  if (!m) fail('routing site not found');

  // The model identifier is captured from the vertex branch `region:<fn>(<model>)`
  // that sits just above the firstParty object inside the SAME function.
  const window = js.slice(Math.max(0, m.index - 2500), m.index);
  const regions = [...window.matchAll(/region:[A-Za-z_$][\w$]*\(([A-Za-z_$][\w$]*)\)/g)];
  if (regions.length === 0) fail('could not capture the model identifier');
  const model = regions[regions.length - 1][1];

  const inject = `baseURL:/^claude/i.test(${model})?"https://api.anthropic.com":void 0,`;
  js =
    js.slice(0, m.index) +
    m[1] + inject + m[2] + m[3] + m[4] +
    js.slice(m.index + m[0].length);

  applied.push(`routing (model var '${model}')`);
});

// --------------------------------------------------------------------------
// 2. DISCOVERY — drop the ANTHROPIC_AUTH_TOKEN requirement in
//    fetchGatewayModelOptions so /model lists the proxy's models without a
//    token (an open /v1/models needs none). `!<tok>` -> `!1` = never bail early.
// --------------------------------------------------------------------------
step('2 discovery', () => {
  const rx = /(let ([A-Za-z_$][\w$]*)=[\w$]*\.ANTHROPIC_AUTH_TOKEN,([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\(\);if\(!)\2(&&!\3\)return)/;
  const m = js.match(rx);
  if (!m) fail('discovery guard not found');

  js = js.slice(0, m.index) + m[1] + '1' + m[4] + js.slice(m.index + m[0].length);
  applied.push(`discovery (guard !${m[2]} -> !1)`);
});

// --------------------------------------------------------------------------
// 3. AGENT MODEL SCHEMA — the Agent tool hard-validates its `model` parameter
//    against a 4-way zod enum, rejecting external/proxy ids at the SCHEMA level
//    even though the resolver downstream passes unknown ids through unchanged.
//    Relax it to a free string so subagents can use proxy models too.
//    (Distinct from tweakcc's own allowCustomAgentModels, which targets the
//    agent *frontmatter* schema — already z.string() since CC 2.1.83.)
// --------------------------------------------------------------------------
//    TWO SHAPES, both supported — 2.1.224 moved this schema to zod v4, where
//    the builders are standalone helpers rather than methods on a namespace:
//      <= 2.1.222   model:S.enum(["sonnet","opus","haiku","fable"])
//      >= 2.1.224   model:xr(["sonnet","opus","haiku","fable"])
//    The v4 form has no namespace to hang `.string()` off, so the replacement
//    borrows the STRING builder from a sibling field in the same object
//    literal — `subagent_type:` is a plain string there, as are `description`
//    and `prompt`, which makes the captured helper a string schema by
//    construction and keeps it correct in that module's scope.
step('3 agent model schema', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  let m = js.match(new RegExp(`(${ID})\\.enum\\(\\["sonnet","opus","haiku","fable"\\]\\)`));
  if (m) {
    js = js.slice(0, m.index) + `${m[1]}.string()` + js.slice(m.index + m[0].length);
    applied.push(`agent model schema, v3 form (zod alias '${m[1]}')`);
  } else {
    const rx = new RegExp(`model:(${ID})\\(\\["sonnet","opus","haiku","fable"\\]\\)`);
    m = js.match(rx);
    if (!m) fail('agent-tool model enum not found');

    // The string builder, taken from the sibling field just above.
    const before = js.slice(Math.max(0, m.index - 800), m.index);
    const sibling = [...before.matchAll(new RegExp(`subagent_type:(${ID})\\(\\)`, 'g'))].pop();
    if (!sibling) fail('could not capture the string schema builder');
    const str = sibling[1];

    js = js.slice(0, m.index) + `model:${str}()` + js.slice(m.index + m[0].length);
    applied.push(`agent model schema, v4 form (enum '${m[1]}' -> string '${str}')`);
  }
});

// --------------------------------------------------------------------------
// 4. MODEL BADGE — show the subagent's model in the transcript whenever it
//    differs from the main-loop model.
//
//    Stock behaviour renders the badge only when the model was passed as a TOOL
//    PARAMETER; agents that pin `model:` in their frontmatter therefore show no
//    model anywhere in the UI. Dropping the `e.model` requirement fixes that;
//    `s` must stay defined, so it falls back to the resolved model (making the
//    `s!==o` half of the test inert and leaving `o!==i` to decide).
// --------------------------------------------------------------------------
step('4 model badge', () => {
  // NOTE: every identifier class must allow `$` — minified names legitimately
  // contain it (2.1.220 spelled the parse helper `Ei`, 2.1.222 spells it `$i`),
  // and a bare \w+ silently stops matching the moment one shows up.
  const ID = '[A-Za-z_$][\\w$]*';
  const rx = new RegExp(
    `else if\\((${ID})\\.model&&\\1\\.model!=="inherit"\\)` +
    `\\{let (${ID})=(${ID})\\[0\\];if\\(\\2\\)` +
    `\\{let (${ID})=(${ID})\\(\\),(${ID})=(${ID})\\(\\1\\.model\\);`
  );
  const m = js.match(rx);
  if (!m) fail('model badge site not found');

  const [, input, resolved, list, main, getMain, requested, parse] = m;
  const replacement =
    `else{let ${resolved}=${list}[0];if(${resolved})` +
    `{let ${main}=${getMain}(),${requested}=${input}.model?${parse}(${input}.model):${resolved};`;

  js = js.slice(0, m.index) + replacement + js.slice(m.index + m[0].length);
  applied.push('model badge (always show when it differs from the main model)');
});

// ==========================================================================
// Ported from tweakcc — these three of ITS patches fail to apply on CC 2.1.220
// (its published 4.3.2 locators no longer match), so they are disabled in
// ~/.tweakcc/config.json and re-implemented here against locators verified
// against 2.1.220. Each mirrors the original's behaviour, not just its intent.
// ==========================================================================

// --------------------------------------------------------------------------
// 6. INPUT CHEVRON COLOUR — colour the prompt chevron by loading state instead
//    of dimming it: theme colour while busy, `chevronIdleThemeColor` when idle.
//    The value is a THEME colour name, which this UI's Text component accepts
//    directly (the bundle elsewhere passes e.g. `color:"planMode"`).
//
//    Step 5 (auto-accept plan mode) was REMOVED: it skipped the Ready-to-code
//    dialog by calling the accept handler and returning null, and after leaving
//    plan mode the session froze. The stock dialog is back.
// --------------------------------------------------------------------------
step('6 input chevron colour', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const IDLE_COLOR = 'success';   // mirrors settings.inputBox.chevronIdleThemeColor

  const rx = new RegExp(
    `,\\{isLoading:(${ID}),(?:${ID}:${ID},)*themeColor:(${ID})\\}=${ID},(${ID})=\\2\\?\\?void 0[,;]` +
    `[\\s\\S]*?if\\([^)]*!==\\3[^)]*\\|\\|[^)]*!==\\1[^)]*\\)${ID}=${ID}\\.jsxs?\\(${ID},\\{color:\\3,dimColor:\\1,children:`
  );
  const m = js.match(rx);
  if (!m) fail('input chevron component not found');

  const [, isLoading, , color] = m;
  const oldPart = `color:${color},dimColor:${isLoading}`;
  const newPart = `color:${isLoading}?${color}:${JSON.stringify(IDLE_COLOR)},dimColor:!1`;
  const at = m.index + m[0].lastIndexOf(oldPart);

  js = js.slice(0, at) + newPart + js.slice(at + oldPart.length);
  applied.push(`input chevron colour (idle -> ${IDLE_COLOR})`);
});

// --------------------------------------------------------------------------
// 7. SESSION MEMORY — force-enable extraction and past-session search, which
//    are otherwise gated behind server-side feature flags.
//    Two gates on 2.1.220 (the legacy ones tweakcc also tries are simply absent
//    here, and its legacy token-limit/threshold knobs no longer have anchors):
//      a) the extraction entry point bails on `tengu_passport_quail`
//      b) the extract-mode predicate ANDs that flag with `tengu_slate_thimble`
//    Past-session search needs no patch — this build already ships it
//    (`tengu_session_search_toggled` telemetry is present).
// --------------------------------------------------------------------------
step('7 session memory', () => {
  const ID = '[A-Za-z_$][\\w$]*';

  const anchor = 'querySource:"extract_memories",forkLabel:"extract_memories"';
  const anchorIdx = js.indexOf(anchor);
  if (anchorIdx === -1) fail('session-memory extraction anchor not found');

  const window = js.slice(anchorIdx, anchorIdx + 8000);
  const gate = window.match(new RegExp(`if\\(!${ID}\\("tengu_passport_quail",!1\\)\\)return;`));
  if (!gate) fail('session-memory extraction gate not found');

  const gateAt = anchorIdx + gate.index;
  js = js.slice(0, gateAt) + js.slice(gateAt + gate[0].length);

  const modeRx = new RegExp(
    `(function ${ID}\\(\\))\\{if\\(!${ID}\\("tengu_passport_quail",!1\\)\\)return!1;` +
    `return!${ID}\\(\\)\\|\\|${ID}\\("tengu_slate_thimble",!1\\)\\}`
  );
  const mode = js.match(modeRx);
  if (!mode) fail('session-memory extract-mode predicate not found');

  js = js.slice(0, mode.index) + `${mode[1]}{return!0}` + js.slice(mode.index + mode[0].length);

  applied.push('session memory (extraction gate + extract-mode predicate)');
});

// --------------------------------------------------------------------------
// 8. COST ACCOUNTING FOR NON-ANTHROPIC MODELS.
//
//    Usage from subagents already lands in the session total — they run the
//    same query engine (runAgent.ts imports `query`), every request is billed
//    in the single API layer, and the counter is a process-global singleton
//    keyed by model id, so a proxy model already shows up as its own row in
//    `/cost`. What is WRONG is the price: a model missing from the built-in
//    MODEL_COSTS table falls back to the default main-loop model's tier, and
//    when that misses too (e.g. `claude-fable-5[1m]`, whose table key is
//    `claude-fable-5`) to DEFAULT_UNKNOWN_MODEL_COST = $5/$25 per Mtok. Every
//    proxy model is therefore billed at Opus-4.5 rates.
//
//    Claude Code already has an override hook — `additionalModelCostsCache` —
//    but it is SERVER-owned: the bootstrap response overwrites the whole key
//    (and its "skip write when unchanged" check compares it, so a hand-written
//    value guarantees the very write that erases it). Merge a user-owned key
//    on top instead: `customModelCosts` in ~/.claude.json, which nothing else
//    reads or writes. The config is a plain `{...defaults, ...JSON.parse}` with
//    no schema stripping, so the key survives read/write round-trips.
//
//    Both read sites are patched — the cost calculator AND the spend-limit
//    "is this model's cost known?" predicate — so the budget subsystem stops
//    treating proxy models as unpriced.
//
//    Entry shape (USD per Mtok), keyed by the exact model id:
//      "kimi-k3": { inputTokens, outputTokens, promptCacheWriteTokens,
//                   promptCacheReadTokens, webSearchRequests,
//                   promptCacheWrite1hTokens? }
// --------------------------------------------------------------------------
step('8 custom model costs', () => {
  const rx = /([A-Za-z_$][\w$]*)\(\)\.additionalModelCostsCache/g;
  const sites = [...js.matchAll(rx)];
  if (sites.length === 0) fail('model-cost override site not found');

  // Replace back-to-front so earlier indices stay valid.
  for (const m of sites.reverse()) {
    const cfg = m[1];
    const merged = `{...${cfg}().additionalModelCostsCache,...${cfg}().customModelCosts}`;
    js = js.slice(0, m.index) + merged + js.slice(m.index + m[0].length);
  }

  applied.push(`custom model costs (${sites.length} site(s), config key 'customModelCosts')`);
});

// 9. This proxy serves its models to gateway discovery under DISGUISED ids: it
//    prefixes `claude-fable-5-dd-` and REVERSES the real name, so `glm-5.2`
//    arrives as `claude-fable-5-dd-2.5-mlg`. The disguise exists only to pass
//    Claude Code's own gateway filter, which drops every id not matching
//    /(claude|anthropic)/i — but a `claude` prefix is load-bearing in three
//    unrelated mechanisms downstream, and the disguise breaks all three:
//      * routing (patch 1) sends anything `claude*` to api.anthropic.com, where
//        no such model exists -> "It may not exist or you may not have access";
//      * the context-window resolver honours CLAUDE_CODE_MAX_CONTEXT_TOKENS only
//        for models whose canonical name does NOT start with `claude-`, so every
//        proxy model is pinned to the 200K default;
//      * cost lookup (patch 8) misses `customModelCosts`, which is keyed by real
//        model names, and silently bills at the Fable tier instead.
//    Undo the disguise at the point the ids enter the client, so every consumer
//    downstream sees the real id. Ids without the prefix pass through untouched,
//    so a proxy that does not disguise is unaffected. The filter is inlined at
//    two call sites (model discovery and bootstrap); both are rewritten.
step('9 gateway model de-disguise', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const PREFIX = 'claude-fable-5-dd-';
  const rx = new RegExp(
    `\\.filter\\(\\((${ID})\\)=>/\\(claude\\|anthropic\\)/i\\.test\\(\\1\\.id\\)\\)`,
    'g',
  );
  const sites = [...js.matchAll(rx)];
  if (sites.length === 0) fail('gateway model filter not found');

  // Back-to-front so earlier indices stay valid.
  for (const m of sites.reverse()) {
    const p = m[1];
    const at = m.index + m[0].length;
    const undisguise =
      `.map((${p})=>${p}.id.startsWith(${JSON.stringify(PREFIX)})` +
      `?{...${p},id:[...${p}.id.slice(${PREFIX.length})].reverse().join("")}` +
      `:${p})`;
    js = js.slice(0, at) + undisguise + js.slice(at);
  }

  applied.push(`gateway model de-disguise (${sites.length} site(s), prefix '${PREFIX}')`);
});

// 10. Context window per model. Claude Code resolves one flat window per model
//     and falls back to a 200K default for anything it does not know, which is
//     every proxy model. Its only escape hatch, CLAUDE_CODE_MAX_CONTEXT_TOKENS,
//     is a single number for all of them — useless when kimi-k3-256k wants 256K,
//     grok-4.5 2M and gpt-5.6 400K. Replace the default with a per-model lookup
//     in a user-owned config key, consulted by raw id first and then by
//     canonical name (which lowercases and strips date suffixes). The env
//     override is checked earlier in the same function, so it still wins;
//     unlisted models keep the built-in default.
step('10 per-model context window', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const cfgMatch = js.match(new RegExp(`return (${ID})\\(\\)\\.autoCompactWindowsCache`));
  if (!cfgMatch) fail('config accessor not found (autoCompactWindowsCache)');
  const cfg = cfgMatch[1];

  const rx = new RegExp(
    `&&!(${ID})\\((${ID})\\((${ID})\\)\\)\\.startsWith\\("claude-"\\)\\)` +
      `return (${ID});return (${ID})\\}`,
  );
  const m = js.match(rx);
  if (!m) fail('context-window default not found');

  const [, canonical, parse, model, envValue, fallback] = m;
  const lookup = `${cfg}().customModelContextWindows`;
  const replacement =
    `&&!${canonical}(${parse}(${model})).startsWith("claude-"))return ${envValue};` +
    `return ${lookup}?.[${model}]??${lookup}?.[${canonical}(${parse}(${model}))]??${fallback}}`;
  js = js.slice(0, m.index) + replacement + js.slice(m.index + m[0].length);

  applied.push(`per-model context window (config key 'customModelContextWindows')`);
});

// --------------------------------------------------------------------------
// 11. DEAD SUBSCRIPTION LOGIN MUST NOT KILL THE PROXY LANE.
//     getAnthropicClient bails with OAuthRefreshDeadError ("Login expired ·
//     Please run /login") when there is no api key, no OAuth tokens, no
//     explicit Authorization header AND the refresh token is known dead. That
//     is an Anthropic-credential condition, but the check sits ABOVE the
//     per-model dispatch, so once the subscription login expired mid-session
//     every proxy request died with it too — subagents surfaced it as "Agent
//     terminated early due to an API error: Login expired".
//
//     A proxy request needs no Anthropic credential, so the throw is narrowed
//     to the requests that actually do: a claude-* model, or no proxy
//     configured at all (without ANTHROPIC_BASE_URL a non-claude model still
//     goes to api.anthropic.com, and there "Login expired" is the honest
//     answer rather than the SDK's obscure "Could not resolve authentication
//     method").
//
//     Surviving the throw is not enough on its own: the SDK's validateHeaders
//     rejects a request carrying neither x-api-key nor authorization UNLESS
//     they are explicitly nulled. So the proxy lane nulls both, exactly as the
//     bedrock branch above already does. The headers object is mutated in
//     place because the client options captured it by reference
//     (`ARGS={defaultHeaders:<p>,...}`) before this point — and it is mutated
//     only inside the branch that used to throw, so a session holding any
//     credential keeps its current behaviour untouched.
// --------------------------------------------------------------------------
step('11 proxy lane survives an expired login', () => {
  const ID = '[A-Za-z_$][\\w$]*';

  // The class, found by the message it is constructed with rather than by its
  // minified name.
  const clsMatch = js.match(
    new RegExp(
      `(${ID})=class \\1 extends Error\\{constructor\\(\\)\\{` +
        `super\\("OAuth refresh token is no longer valid`,
    ),
  );
  if (!clsMatch) fail('OAuthRefreshDeadError class not found');
  const cls = clsMatch[1];

  const throwStmt = `throw new ${cls};`;
  const sites = [];
  for (let at = js.indexOf(throwStmt); at !== -1; at = js.indexOf(throwStmt, at + 1)) {
    sites.push(at);
  }
  if (sites.length !== 1) fail(`expected 1 throw site, found ${sites.length}`);
  const throwAt = sites[0];

  // Walk back from the `)` that closes the guard to its `if(`.
  if (js[throwAt - 1] !== ')') fail('throw is not the body of an if statement');
  let open = -1;
  for (let i = throwAt - 1, depth = 0; i >= 0; i--) {
    if (js[i] === ')') depth++;
    else if (js[i] === '(') {
      depth--;
      if (depth === 0) { open = i; break; }
    }
  }
  if (open < 2 || js.slice(open - 2, open) !== 'if') fail('guard `if(` not found');
  const condition = js.slice(open + 1, throwAt - 1);

  // The headers object comes out of the condition's own `!<fn>(<headers>).value`
  // term, so it is whatever that code actually reads — not a guess.
  const headersMatch = condition.match(new RegExp(`!${ID}\\((${ID})\\)\\.value`));
  if (!headersMatch) fail('could not capture the headers object from the guard');
  const headers = headersMatch[1];

  // The model identifier comes from patch 1's own injection, which also proves
  // both sites sit in the same function. Patch 1 must therefore run first.
  const routeAt = js.indexOf('baseURL:/^claude/i.test(', throwAt);
  if (routeAt === -1) fail('routing injection not found after the guard (run patch 1 first)');
  if (routeAt - throwAt > 4000) fail('routing injection too far away to share scope');
  const model = js.slice(routeAt, routeAt + 200).match(
    new RegExp(`^baseURL:/\\^claude/i\\.test\\((${ID})\\)`),
  )[1];

  // The credential-absence terms of the guard, without the dead-refresh-token
  // test: `!<apiKey>&&!<oauthTokens>&&!<fn>(<headers>).value`.
  const credentialsAbsent = condition.slice(0, condition.indexOf('.value') + '.value'.length);

  const proxyLane = `!/^claude/i.test(${model})&&process.env.ANTHROPIC_BASE_URL`;
  const replacement =
    // The bail stays, but only for requests that really need the credential.
    `if(${condition}){if(!(${proxyLane}))${throwStmt}}` +
    // Nulling the auth headers is deliberately NOT tied to the dead-refresh
    // branch above. A dead refresh token is only one of the states with no
    // credential to send; a keychain entry that is simply gone leaves the
    // guard false and used to die one step later inside the SDK instead, whose
    // "Could not resolve authentication method" Claude Code reports as
    // "Not logged in · Please run /login" (its classifier matches on the
    // "x-api-key" substring of that message — verified against the binary).
    // Both states are the same defect for the proxy lane, so both are covered.
    `if(${credentialsAbsent}&&${proxyLane})` +
    `${headers}.Authorization=null,${headers}["X-Api-Key"]=null;`;

  js = js.slice(0, open - 2) + replacement + js.slice(throwAt + throwStmt.length);

  applied.push(
    `proxy lane survives an expired login (model var '${model}', headers var '${headers}')`,
  );
});

// --------------------------------------------------------------------------
// 12. A DISPATCH MAY CHOOSE ITS MODEL AND EFFORT — INCLUDING A FORK.
//
//     Three separate places drop the caller's routing choice, and each one
//     alone is enough to make a dispatch run on the parent's (expensive)
//     model while everything upstream believes otherwise:
//
//     (a) COORDINATOR MODE discards the call's `model` for EVERY dispatch
//         (`<model> = isCoordinatorMode() ? undefined : <model>`). With
//         CLAUDE_CODE_COORDINATOR_MODE set, only an agent definition's
//         frontmatter model has any effect; a model named in the call is
//         silently ignored. That is worse than an error for a routing gate
//         that accepts the call's model as proof of where the work went.
//     (b) THE FORK PATH drops it twice more — once when resolving the agent
//         model, once in the child's launch options.
//     (c) EFFORT has no carrier at all for a fork: it is read from the agent
//         DEFINITION (`definition.effort` becomes a permission layer), and a
//         fork's definition is synthetic, so a fork can never carry one.
//
//     Forking exists to move work off the parent's context — but a fork that
//     must also run the parent's model can only ever be as expensive as the
//     parent, which defeats using it for cheap fan-out.
//
//     So: honour the model in all three places, and add `effort` /
//     `dispatch_class` to the tool schema. `effort` is attached to the agent
//     definition used for the launch, which is the field the runtime already
//     reads — declaring it without wiring it would satisfy a routing gate
//     while the request still went out at the vendor's default effort, which
//     is the exact defect such a gate exists to catch. `dispatch_class` is
//     inert here by design: it carries the caller's routing class to the
//     PreToolUse gate, which is the only consumer.
// --------------------------------------------------------------------------
step('12 dispatch may choose model and effort (forks included)', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const before = js.length;

  // (a) coordinator mode: `let <t>=Date.now(),<model>=<isCoordinator>()?void 0:<arg>,`
  const coord = new RegExp(`(let ${ID}=Date\\.now\\(\\),(${ID})=)${ID}\\(\\)\\?void 0:(${ID}),`);
  const coordMatch = js.match(coord);
  if (!coordMatch) fail('coordinator-mode model suppression not found');
  js = js.replace(coord, `$1$3,`);

  // (b) the fork flag is whatever the launch telemetry reports as is_fork
  const forkMatch = js.match(new RegExp(`is_fork:(${ID}),`));
  if (!forkMatch) fail('fork flag not found (is_fork telemetry)');
  const fork = forkMatch[1];
  const dropped = `${rxEsc(fork)}\\?void 0:(${ID})`;

  // resolve site: getAgentModel(<defModel>(<agent>,<main>),<main>,<override>,...)
  const resolveRx = new RegExp(`(=${ID}\\(${ID}\\(${ID},(${ID})\\),\\2,)${dropped},`);
  if (!resolveRx.test(js)) fail('fork model-resolution site not found');
  js = js.replace(resolveRx, `$1$3,`);

  // launch options: `model:<fork>?void 0:<override>,override:`
  const launchRx = new RegExp(`(model:)${dropped}(,override:)`);
  if (!launchRx.test(js)) fail('fork launch-options model site not found');
  js = js.replace(launchRx, `$1$2$3`);

  // (c) schema: add the two fields next to the existing `model`
  const strFnMatch = js.match(
    new RegExp(`description:(${ID})\\(\\)\\.describe\\("A short \\(3-5 word\\)`),
  );
  if (!strFnMatch) fail('schema string builder not found');
  const str = strFnMatch[1];
  const bgField = new RegExp(`(,)(run_in_background:${ID}\\(\\)\\.optional\\(\\)\\.describe\\("Agents run in the background)`);
  if (!bgField.test(js)) fail('schema insertion point not found');
  const newFields =
    `,effort:${str}().optional().describe(` +
    `"Optional reasoning effort for this agent: low|medium|high|xhigh|max. ` +
    `Overrides the agent definition's effort. The only way to set one on a fork, ` +
    `whose definition is synthetic."),` +
    `dispatch_class:${str}().optional().describe(` +
    `"Optional routing class for this dispatch. Not used by Claude Code itself; ` +
    `it is read by the PreToolUse routing gate when one is configured.")`;
  js = js.replace(bgField, `${repEsc(newFields)}$1$2`);

  // (c) destructure effort in the tool's call handler, alongside the rest
  const callRx = new RegExp(`(async call\\(\\{prompt:${ID},subagent_type:${ID},[^}]{0,400}?)(\\},${ID},)`);
  const callMatch = js.match(callRx);
  if (!callMatch) fail('agent tool call handler not found');
  if (js.includes('__ccEffort')) fail('__ccEffort already present — refusing to shadow it');
  js = js.replace(callRx, `$1,effort:__ccEffort$2`);

  // (c) attach it to the definition handed to the launch — the field the
  //     runtime turns into an effort permission layer.
  //     The `=` is load-bearing: the CALLEE destructures its parameters with
  //     the very same shape (`function*<run>({agentDefinition:<e>,promptMessages:…`)
  //     and substituting a conditional there is a syntax error, not a no-op.
  //     Anchoring on the assignment picks the caller's object literal.
  const defRx = new RegExp(`(=\\{agentDefinition:)(${ID})(,promptMessages:)`);
  if (!defRx.test(js)) fail('launch agentDefinition site not found');
  js = js.replace(defRx, `$1__ccEffort?{...$2,effort:__ccEffort}:$2$3`);

  // (d) the prompt text still told the model the override was pointless
  const schemaDoc = 'Ignored for subagent_type: "fork" \\u2014 forks always inherit the parent model.';
  if (!js.includes(schemaDoc)) fail('fork model schema description not found');
  js = js.replace(
    schemaDoc,
    'For subagent_type: "fork" it selects the model the fork runs on \\u2014 the fork still ' +
      'inherits your full context, so choose one whose context window fits it.',
  );

  const toolDoc = 'and always runs on your model \\u2014 a \\`model\\` override is ignored)';
  if (!js.includes(toolDoc)) fail('fork tool-description text not found');
  js = js.replace(toolDoc, '; it runs on your model unless you pass a \\`model\\` override)');

  applied.push(
    `dispatch model+effort (fork flag '${fork}', coordinator suppression removed, ` +
      `+${js.length - before} bytes)`,
  );
});

// --------------------------------------------------------------------------
// 13. COORDINATOR MODE IN AN INTERACTIVE SESSION, WITHOUT LOSING FORK.
//
//     Upstream gate:
//       function <yv>(){
//         if(!<envTruthy>(process.env.CLAUDE_CODE_COORDINATOR_MODE))return!1;
//         if(<isInteractive>()&&!<isRemoteWorkspace>()&&!<Y>.CLAUDE_CODE_REMOTE)return!1;
//         return!0}
//     so the mode only ever engages headless or remote. The only env that can
//     defeat the second line is CLAUDE_CODE_REMOTE, and that is NOT a viable
//     switch: it also changes which token the client sends
//     (`accessToken ?? (REMOTE ? CLAUDE_CODE_OAUTH_TOKEN||… : undefined)`), arms
//     the trusted-device policy check, and turns on disk persistence branches
//     that stay quiet locally — the same class of collateral that made
//     ANTHROPIC_API_KEY the wrong fix in patch #11. So the interactive veto gets
//     its own opt-in instead, parsed by the binary's OWN env-truthy helper
//     (captured from line 1) so "1"/"true"/"yes"/"on" all behave as elsewhere.
//
//     Second edit: coordinator mode also disables fork outright
//     (`if(<isCoordinatorMode>())return"disabled"` in the fork-source resolver),
//     which would silently undo patch #12 for anyone who turns the mode on. The
//     restriction reads as a product choice — a coordinator is meant to hand
//     work to workers rather than fork itself — not a technical constraint, and
//     the two features are orthogonal in the code, so the line goes.
//
//     Both sites are reached from the module's own export map rather than by
//     guessing minified names: isCoordinatorMode:()=><P> gives the predicate,
//     whose body `return <yv>()` gives the gate. That also lets the fork edit
//     ASSERT that the call it deletes is that same predicate.
// --------------------------------------------------------------------------
step('13 coordinator mode may run interactively (fork preserved)', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const before = js.length;

  const exportMatch = js.match(new RegExp(`isCoordinatorMode:\\(\\)=>(${ID})`));
  if (!exportMatch) fail('isCoordinatorMode export not found');
  const isCoordinator = exportMatch[1];

  const aliasRx = new RegExp(`function ${rxEsc(isCoordinator)}\\(\\)\\{return (${ID})\\(\\)\\}`);
  const aliasMatch = js.match(aliasRx);
  if (!aliasMatch) fail(`coordinator predicate ${isCoordinator}() is not a plain alias`);
  const gate = aliasMatch[1];

  // (a) let the mode survive an interactive session when explicitly opted in.
  //
  //     The switch is parsed by the gate's OWN env-truthy helper — captured out
  //     of the CLAUDE_CODE_COORDINATOR_MODE test right next to it — so "1",
  //     "true", "yes" and "on" mean here exactly what they mean for the
  //     variable that already gates this function, and nothing new can drift
  //     from it. (A hand-rolled parser was tried first and measurably did NOT
  //     behave the same in the running binary, so this reuses the helper the
  //     product itself trusts rather than a re-derivation of it.)
  const gateRx = new RegExp(
    `(function ${rxEsc(gate)}\\(\\)\\{if\\(!(${ID})\\(process\\.env\\.CLAUDE_CODE_COORDINATOR_MODE\\)\\)return!1;` +
      `if\\(${ID}\\(\\)&&!${ID}\\(\\)&&!${ID}\\.CLAUDE_CODE_REMOTE)(\\)return!1;return!0\\})`,
  );
  const gateMatch = js.match(gateRx);
  if (!gateMatch) fail('coordinator interactive veto not found');
  const envTruthy = gateMatch[2];
  js = js.replace(
    gateRx,
    `$1&&!${repEsc(envTruthy)}(process.env.CLAUDE_CODE_COORDINATOR_INTERACTIVE)$3`,
  );

  // (b) stop the mode from disabling fork.
  //
  //     Two shapes in the wild. Up to 2.1.231 the resolver is ONE function that
  //     opens with the coordinator check and falls through a chain of env and
  //     rollout tests; from 2.1.232 it is split in two, the outer one caching
  //     the source and the coordinator check sitting before that cache. Both
  //     put the check first, so both are matched by their own anchor and the
  //     deleted call is asserted to be the coordinator predicate either way.
  const forkGateShapes = [
    // 2.1.232+: `let <e>=<state>();if(<isCoordinator>())return"disabled";if(<Y>.CLAUDE_CODE_FORK_SUBAGENT===!1)…`
    new RegExp(
      `(let ${ID}=${ID}\\(\\);)if\\((${ID})\\(\\)\\)return"disabled";` +
        `(if\\(${ID}\\.CLAUDE_CODE_FORK_SUBAGENT===!1\\)return"disabled";)`,
    ),
    // ≤2.1.231: `function <f>(){if(<isCoordinator>())return"disabled";if(<Y>.CLAUDE_CODE_FORK_SUBAGENT===!0)return"env";…`
    new RegExp(
      `(function ${ID}\\(\\)\\{)if\\((${ID})\\(\\)\\)return"disabled";` +
        `(if\\(${ID}\\.CLAUDE_CODE_FORK_SUBAGENT===!0\\)return"env";)`,
    ),
  ];
  const forkGateRx = forkGateShapes.find(rx => rx.test(js));
  if (!forkGateRx) fail('fork source resolver not found (neither shape)');
  const forkGateMatch = js.match(forkGateRx);
  if (forkGateMatch[2] !== isCoordinator) {
    fail(
      `fork resolver gates on ${forkGateMatch[2]}(), not the coordinator predicate ` +
        `${isCoordinator}() — refusing to delete a check I have not identified`,
    );
  }
  js = js.replace(forkGateRx, `$1$3`);

  applied.push(
    `interactive coordinator mode via CLAUDE_CODE_COORDINATOR_INTERACTIVE ` +
      `(gate '${gate}', predicate '${isCoordinator}', fork no longer disabled by it, ` +
      `+${js.length - before} bytes)`,
  );
});

// --------------------------------------------------------------------------
// 14. the environment may override a resumed session's recorded mode.
//
//     Every session records `{"type":"mode","mode":"normal"|"coordinator"}`,
//     and on resume `matchSessionMode(session.mode)` drags the PROCESS back to
//     whatever the session was started in — printing "Exited coordinator mode
//     to match resumed session." and silently undoing #13's opt-in. The five
//     call sites (interactive resume, the picker, --continue, -p --resume, and
//     the CLI resume path) all funnel through that one function and do nothing
//     but surface its return value as a warning, so returning early from it is
//     the whole behaviour change: no mode flip, no message.
//
//     Dropping the session's mode is safe to leave permanent — after resume the
//     record is rewritten from the LIVE predicate (`saveMode(isCoordinatorMode()
//     ?"coordinator":"normal")` at the interactive sites, `eHt(...)` at the
//     print ones), so the file ends up agreeing with the process rather than
//     being left stale.
//
//     Opt-in only, and via its own key: an unconditional bail would strand
//     anyone who relies on a resumed session keeping its mode, and the point of
//     the key is precisely that abandoning the session is not always an option.
//     It overrides in BOTH directions, because the environment is the thing
//     being declared authoritative — not "coordinator wins".
// --------------------------------------------------------------------------
step('14 environment overrides a resumed session mode', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const before = js.length;

  const exportMatch = js.match(new RegExp(`isCoordinatorMode:\\(\\)=>(${ID})`));
  if (!exportMatch) fail('isCoordinatorMode export not found');
  const isCoordinator = exportMatch[1];

  const matcherMatch = js.match(new RegExp(`matchSessionMode:\\(\\)=>(${ID})`));
  if (!matcherMatch) fail('matchSessionMode export not found');
  const matcher = matcherMatch[1];

  // The same env-truthy helper as #13, re-derived from the gate rather than
  // handed over between steps: this must not depend on step order, and the
  // prefix it is captured from is untouched by #13's own edit.
  const helperMatch = js.match(
    new RegExp(`\\{if\\(!(${ID})\\(process\\.env\\.CLAUDE_CODE_COORDINATOR_MODE\\)\\)return!1;`),
  );
  if (!helperMatch) fail('coordinator env-truthy helper not found');
  const envTruthy = helperMatch[1];

  // Anchored on the shape, not on the message literals: the guard, the live
  // read of the predicate and the "coordinator" comparison identify the
  // function even if the wording of the warnings changes.
  const matcherRx = new RegExp(
    `(function ${rxEsc(matcher)}\\((${ID})\\)\\{if\\(!\\2\\)return;)` +
      `(let ${ID}=${rxEsc(isCoordinator)}\\(\\),${ID}=\\2==="coordinator";)`,
  );
  if (!matcherRx.test(js)) {
    fail(`resume mode matcher ${matcher}() does not have the expected shape`);
  }
  js = js.replace(
    matcherRx,
    `$1if(${repEsc(envTruthy)}(process.env.CLAUDE_CODE_COORDINATOR_FORCE))return;$3`,
  );

  applied.push(
    `environment overrides a resumed session mode via CLAUDE_CODE_COORDINATOR_FORCE ` +
      `(matcher '${matcher}', predicate '${isCoordinator}', +${js.length - before} bytes)`,
  );
});

// --------------------------------------------------------------------------
// 15. the agent list shows WHICH agent and WHICH model, not just a name.
//
//     A row in the task/agent list renders `name ?? agentType` on the left and
//     `elapsed · ↓ N tokens` on the right. Passing `name` to a dispatch — the
//     natural thing to do when five agents run at once — therefore REPLACES the
//     only signal of what was actually spawned, and the model is never shown at
//     all. Five parallel scouts on five different vendors look identical to
//     five copies of the default.
//
//     The data is already on the task record (`agentType`, `model`, and
//     `selectedAgent` from the dispatch), so this is a display gap, not a
//     plumbing one. The edit goes into the status-parts builder rather than the
//     row component: the row is React-compiler output whose memo slots are
//     positional, while this function is plain and its result already drives
//     the column-width calculation, so a longer string widens the column
//     instead of being truncated.
//
//     `model` is the per-dispatch override and is undefined whenever the model
//     came from the agent definition's frontmatter — which is the normal case
//     for the pinned vendor agents — hence the fallback to selectedAgent.model.
// --------------------------------------------------------------------------
step('15 agent list shows agent type and model', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const before = js.length;

  // let <tok>=<task>.progress?.tokenCount,
  //     <arrow>=<task>.progress?.lastActivity?<glyphs>.arrowDown:<glyphs>.arrowUp,
  //     <text>=<tok>!==void 0&&<tok>>0?`${<arrow>} ${<fmt>(<tok>)} tokens`:""
  const rx = new RegExp(
    `(${ID})=(${ID})\\.progress\\?\\.tokenCount,(${ID})=\\2\\.progress\\?\\.lastActivity\\?` +
      `(${ID})\\.arrowDown:\\4\\.arrowUp,(${ID})=\\1!==void 0&&\\1>0\\?` +
      '`\\$\\{\\3\\} \\$\\{(' + ID + ')\\(\\1\\)\\} tokens`:""',
  );
  const m = js.match(rx);
  if (!m) fail('agent-row status parts builder not found');

  js = js.replace(
    rx,
    '$1=$2.progress?.tokenCount,$3=$2.progress?.lastActivity?$4.arrowDown:$4.arrowUp,' +
      '$5=[$2.agentType,$2.model??$2.selectedAgent?.model,' +
      '$1!==void 0&&$1>0?`${$3} ${$6($1)} tokens`:""].filter(Boolean).join(" \\xB7 ")',
  );

  applied.push(
    `agent list shows agent type and model (task var '${m[2]}', token var '${m[1]}', ` +
      `+${js.length - before} bytes)`,
  );
});

// --------------------------------------------------------------------------
// 17. /resume search reaches sessions that are not loaded yet.
//
//     The picker loads sessions in pages: the first 50 (rxi), then more on
//     demand through the onRequestMore callback, which reads the next slice of
//     the on-disk file list and appends whatever survives the loader filters.
//     The picker asks for more from one effect:
//
//       useEffect(()=>{if(!s)return;let Ze=Ge*2;
//                      if(Z+Ze>=et.length)s(Ge*3)},[Z,Ge,et.length,s])
//
//     `et` is the list AFTER filtering, and the effect's only growth signal is
//     `et.length`. With no query that is fine — every loaded session lands in
//     `et`, so each page makes the list longer and re-arms the effect. With a
//     query it deadlocks: the batch that comes back contains no match, `et`
//     does not grow, none of the four dependencies change, and the effect never
//     runs again. Pagination stops while most sessions are still unread, and
//     the search reports "no results" for a session that is sitting on disk.
//
//     The deep-search index is a constant null in this build, so the substring
//     filter over loaded logs is the ONLY search there is — nothing else can
//     reach the unloaded tail.
//
//     Fix: while the search UI is open, keep asking for more, and take the
//     growth signal from the loaded list `e` rather than the filtered one. The
//     loop is bounded by the loader itself — onRequestMore returns immediately
//     once nextIndex reaches the end of the file list, so `e.length` stops
//     changing and the effect stops re-running. Outside search mode the
//     condition is unchanged, so the ordinary scroll-to-load path and its
//     startup cost stay exactly as they were.
// --------------------------------------------------------------------------
step('17 /resume search loads the sessions it has not read yet', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const before = js.length;

  // ...&&<mode>!=="search",<head>=8+(<hasChips>?1:0),<pad>=2,
  //    <rows>=Math.max(1,Math.floor((<height>-<head>-<pad>)/3));
  // if(<React>.useEffect(()=>{if(!<more>)return;let <slack>=<rows>*2;
  //      if(<focus>+<slack>>=<filtered>.length)<more>(<rows>*3)},
  //      [<focus>,<rows>,<filtered>.length,<more>]),
  //    <logs>.length===0&&!<loading>)return null;
  const rx = new RegExp(
    `&&(${ID})!=="search",(${ID})=8\\+\\((${ID})\\?1:0\\),(${ID})=2,` +
      `(${ID})=Math\\.max\\(1,Math\\.floor\\(\\((${ID})-\\2-\\4\\)/3\\)\\);` +
      `if\\((${ID})\\.useEffect\\(\\(\\)=>\\{if\\(!(${ID})\\)return;let (${ID})=\\5\\*2;` +
      `if\\((${ID})\\+\\9>=(${ID})\\.length\\)\\8\\(\\5\\*3\\)\\},` +
      `\\[\\10,\\5,\\11\\.length,\\8\\]\\),(${ID})\\.length===0&&!(${ID})\\)return null;`,
  );
  const m = js.match(rx);
  if (!m) fail('/resume auto-load-more effect not found');

  js = js.replace(
    rx,
    '&&$1!=="search",$2=8+($3?1:0),$4=2,$5=Math.max(1,Math.floor(($6-$2-$4)/3));' +
      'if($7.useEffect(()=>{if(!$8)return;let $9=$5*2;' +
      'if($1==="search"||$10+$9>=$11.length)$8($5*3)},' +
      '[$10,$5,$11.length,$8,$1,$12.length]),$12.length===0&&!$13)return null;',
  );

  applied.push(
    `/resume search loads the sessions it has not read yet ` +
      `(mode var '${m[1]}', filtered list '${m[11]}', loaded list '${m[12]}', ` +
      `+${js.length - before} bytes)`,
  );
});

// --------------------------------------------------------------------------
// 18. A NAMED agent carries its agent type into the task list.
//
//     Patch #15 puts the agent type and the model in the row's status parts,
//     reading `agentType` off the task record. That works for a plain dispatch:
//     both local-agent constructors set `agentType: <definition>.agentType ??
//     "general-purpose"`.
//
//     Pass `name` and the dispatch becomes an in-process TEAMMATE instead, and
//     that record is built from a different literal — `identity`, `prompt`,
//     `model`, and no agent type at all. So the row shows the model and nothing
//     else: five teammates on the same model are indistinguishable, which is
//     the exact case #15 existed to fix.
//
//     The type is not missing, only dropped. The spawn handler resolves the
//     definition from `agent_type` two lines earlier (it even logs
//     `agent_type=… found=…`) and then builds the spawn directive without it.
//     So this is a plumbing gap, and it is fixed as one: the directive carries
//     the agent type, the task record stores it, and #15's display picks it up
//     with no display-side change.
// --------------------------------------------------------------------------
step('18 a named agent carries its agent type into the task list', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const before = js.length;

  // The spawn directive built by the in-process spawn handler, anchored on the
  // debug line that already proves `agent_type` is in scope right there:
  //   w(`[handleSpawnInProcess] agent_type=${<type>}, found=${!!<def>}`)}
  //   let <directive>={name:<n>,teamName:<team>,prompt:<p>,color:<c>,
  //                    planModeRequired:<plan>??!1,model:<model>};
  const rxDirective = new RegExp(
    'agent_type=\\$\\{(' + ID + ')\\}, found=\\$\\{!!(' + ID + ')\\}`\\)\\}' +
      `let (${ID})=\\{name:(${ID}),teamName:(${ID}),prompt:(${ID}),color:(${ID}),` +
      `planModeRequired:(${ID})\\?\\?!1,model:(${ID})\\};`,
  );
  const mDirective = js.match(rxDirective);
  if (!mDirective) fail('in-process teammate spawn directive not found');
  js = js.replace(
    rxDirective,
    'agent_type=${$1}, found=${!!$2}`)}' +
      'let $3={name:$4,teamName:$5,prompt:$6,color:$7,' +
      'planModeRequired:$8??!1,model:$9,agentType:$1};',
  );

  // The teammate task record:
  //   type:"in_process_teammate",status:"running",identity:<id>,
  //   prompt:<directive>.description??<prompt>,model:<model>,
  const rxRecord = new RegExp(
    `type:"in_process_teammate",status:"running",identity:(${ID}),` +
      `prompt:(${ID})\\.description\\?\\?(${ID}),model:(${ID}),`,
  );
  const mRecord = js.match(rxRecord);
  if (!mRecord) fail('in-process teammate task record not found');
  js = js.replace(
    rxRecord,
    'type:"in_process_teammate",status:"running",identity:$1,' +
      'prompt:$2.description??$3,model:$4,agentType:$2.agentType,',
  );

  applied.push(
    `a named agent carries its agent type into the task list ` +
      `(type var '${mDirective[1]}', directive var '${mDirective[3]}', ` +
      `record directive var '${mRecord[2]}', +${js.length - before} bytes)`,
  );
});

// --------------------------------------------------------------------------
// 19. A BROKEN STREAM IS RETRIED LIKE ANY OTHER REQUEST, AND NEVER LEAVES HALF
//     AN ANSWER BEHIND.
//
//     When the response stream dies after content has arrived, the reader does
//     not throw — it finalizes whatever came, appends an "API Error: … The
//     response above may be incomplete." message and leaves the loop. The outer
//     retry machinery (attempts, backoff, retry-after, the model fallback
//     chain) is never consulted, because from its side the request SUCCEEDED.
//
//     Measured on 2.1.233 against a probe that streams a block and then emits
//     an api_error frame (scratchpad/midstream.py). Three attempts, then:
//
//       assistant | PARTIAL-ANSWER-CUT-HERE
//       assistant | API Error: Server error mid-response. …may be incomplete.
//       result    | subtype: success
//
//     Two defects, one site. The truncated answer is committed as a normal
//     assistant message — for a subagent it is handed to the orchestrator as
//     the agent's result — and the run is reported as SUCCESS. A half answer
//     that claims to be whole is worse than a failure: nothing downstream can
//     tell it apart from a complete one.
//
//     The reader does already discard partials and re-run — that is how the
//     same probe succeeds when it breaks the stream only once. The budget is
//     just tiny: 2 connection retries, 1 idle-timeout retry, with a linear
//     100ms*attempt wait. So the fix is in three parts:
//
//       * raise both budgets to 300, matching the request-level retry loop;
//       * wait with the same backoff that loop uses — min(500*2^(n-1), 32000)
//         plus jitter — instead of the linear one, so a proxy that is down for
//         minutes is waited out rather than hammered;
//       * on exhaustion THROW the underlying error instead of finalizing the
//         partial, so the non-streaming fallback, the request retry loop and
//         the model fallback chain all still get their turn, and a turn that
//         truly cannot be completed fails honestly.
//
//     Worst case per request is ~300 waits capped at ~40s, i.e. a few hours —
//     the same order as the retry watchdog's park, and bounded by the same
//     user abort.
// --------------------------------------------------------------------------
step('19 a broken stream is retried, never finalized as a half answer', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const before = js.length;

  // The shared backoff helper: min(500*2^(n-1), cap) with up to 25% jitter.
  const backoffMatch = js.match(new RegExp(
    `function (${ID})\\((${ID}),(${ID}),(${ID})=32000\\)\\{let (${ID})=Math\\.min\\(500\\*Math\\.pow\\(2,\\2-1\\),\\4\\),`,
  ));
  if (!backoffMatch) fail('shared retry backoff helper not found');
  const backoff = backoffMatch[1];

  // 1. The per-request counters, declared in one long `let` run:
  //    <qo>=3,<un>={value:0},<staleMax>=2,<stale>=0,<connRetry>=0,<flag>=!1,
  //    <idleMax>=1,<idle>=0,
  const rxBudget = new RegExp(
    `(${ID})=3,(${ID})=\\{value:0\\},(${ID})=2,(${ID})=0,(${ID})=0,(${ID})=!1,(${ID})=1,(${ID})=0,`,
  );
  const mBudget = js.match(rxBudget);
  if (!mBudget) fail('streaming retry budgets not found');
  js = js.replace(rxBudget, '$1=3,$2={value:0},$3=300,$4=0,$5=0,$6=!1,$7=300,$8=0,');

  // 2. The linear wait on the stale-connection retry inside the finalize
  //    branch: `if(<req>=null,!<idle>)await <sleep>(100*<stale>,<signal>)`
  const rxWait = new RegExp(
    `if\\((${ID})=null,!(${ID})\\)await (${ID})\\(100\\*(${ID}),(${ID})\\);continue (${ID})\\}`,
  );
  const mWait = js.match(rxWait);
  if (!mWait) fail('streaming retry wait not found');
  js = js.replace(rxWait, `if($1=null,!$2)await $3(${repEsc(backoff)}($4),$5);continue $6}`);

  // 3. The connection-retry cap taken from the max-retries setting:
  //    `let <cap>=<maxRetries>();if(<isConn>&&<stop>===null&&<n><<cap>){`
  const rxCap = new RegExp(
    `let (${ID})=(${ID})\\(\\);if\\((${ID})&&(${ID})===null&&(${ID})<\\1\\)\\{`,
  );
  const mCap = js.match(rxCap);
  if (!mCap) fail('streaming connection-retry cap not found');
  js = js.replace(rxCap, 'let $1=$2();if($3&&$4===null&&$5<Math.max($1,300)){');

  // 4. The retry that already discards a partial and re-runs the request is
  //    gated on `!<hasRealContent>` — it only fires after a thinking-only
  //    yield. A mid-stream death AFTER text has arrived skips it and falls
  //    into the finalize branch, which is how the half answer is born.
  //    Measured: the same probe succeeds (FULL-ANSWER-OK, one assistant
  //    message) when the stream breaks once, because that path is taken;
  //    three breaks exhaust the old budget of 2 and finalize. Dropping the
  //    content gate lets the existing retry handle a broken stream the same
  //    way regardless of what has been yielded. The consumer already drops a
  //    trailing assistant whose stop_reason is still null, which this path
  //    never stamps.
  // if(!<hasContent>&&<stop>===null&&(<idle>?<idleN><<idleMax>:<staleN><<staleMax>)){
  const rxGate = new RegExp(
    `if\\(!(${ID})&&(${ID})===null&&\\((${ID})\\?(${ID})<(${ID}):(${ID})<(${ID})\\)\\)\\{`,
  );
  const mGate = js.match(rxGate);
  if (!mGate) fail('thinking-only retry gate not found');
  js = js.replace(rxGate, 'if($2===null&&($3?$4<$5:$6<$7)){');

  // 5. If the 300 retries still cannot complete the stream, do not leave a
  //    half answer marked as success. Throw the original error instead of
  //    emitting the synthetic "may be incomplete" message; the request loop
  //    and the model fallback then get their turn, and a turn that cannot
  //    be completed fails honestly.
  const rxFinal = new RegExp(
    `,yield (${ID})\\(\\{content:([^;]{0,1400}?),error:"server_error"\\}\\),(${ID})!=="credited"\\)` +
      `\\3="credited",(${ID})\\+=([^;]{0,300}?);break (${ID})\\}` +
      `throw (${ID})\\("tengu_streaming_fallback_to_non_streaming",\\{model:(${ID})\\.model,` +
      `error:(${ID}) instanceof Error\\?`,
  );
  const mFinal = js.match(rxFinal);
  if (!mFinal) fail('streaming partial-finalize site not found');
  js = js.replace(
    rxFinal,
    ',$3!=="credited")$3="credited",$4+=$5;throw $9}' +
      'throw $7("tengu_streaming_fallback_to_non_streaming",{model:$8.model,' +
      'error:$9 instanceof Error?',
  );

  applied.push(
    `a broken stream is retried, never finalized as a half answer ` +
      `(backoff '${backoff}', budgets ${mBudget[3]}/${mBudget[7]} -> 300, ` +
      `dropped content gate on '${mGate[1]}', error var '${mFinal[9]}', ` +
      `+${js.length - before} bytes)`,
  );
});

// --------------------------------------------------------------------------
// 20. SESSION MODEL RESTORE — a proxy model is a model too.
//     On resume the client reads the last assistant message's model and
//     decides whether it may restore it. The recognised set is FIRST-PARTY
//     ONLY (`y3u = Object.values(sd).map(e => e.firstParty)` plus `-eap` ids
//     and the current default), so ANY proxy model — glm-*, grok-*, gpt-*,
//     kimi-*, deepseek-* — is classified `unknown_family`, declined, and the
//     session silently comes back on the default claude model:
//       "Session model X could not be restored (not a model this version of
//        Claude Code recognizes) — using opus instead."
//     In this dual-lane setup that is a real loss: the session was
//     deliberately put on a vendor model and returns spending the
//     subscription. When a gateway is configured, a non-claude id is
//     restored as-is; the gateway validates it at request time and says so
//     plainly if it is gone. claude-* ids keep the stock retired /
//     not-allowed / unknown-family handling untouched.
// --------------------------------------------------------------------------
step('20 session model restore', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  // let c = !(r.has($o(a)) || bpt(a) || Ld(a) === o) ? "unknown_family"
  //       : !VD(a) && !ju(a) ? "not_allowed" : Pxt(a) ? "retired" : void 0;
  const rx = new RegExp(
    `let (${ID})=!\\((${ID})\\.has\\((${ID})\\((${ID})\\)\\)\\|\\|(${ID})\\(\\4\\)\\|\\|` +
      `(${ID})\\(\\4\\)===(${ID})\\)\\?"unknown_family":!(${ID})\\(\\4\\)&&!(${ID})\\(\\4\\)\\?` +
      `"not_allowed":(${ID})\\(\\4\\)\\?"retired":void 0;`,
  );
  const m = js.match(rx);
  if (!m) fail('session model restore verdict site not found');
  js = js.replace(
    rx,
    'let $1=process.env.ANTHROPIC_BASE_URL&&!/^claude/i.test($4)?void 0:' +
      '!($2.has($3($4))||$5($4)||$6($4)===$7)?"unknown_family":' +
      '!$8($4)&&!$9($4)?"not_allowed":$10($4)?"retired":void 0;',
  );
  applied.push(`session model restore keeps a proxy model (verdict var '${m[1]}', model var '${m[4]}')`);
});

// --------------------------------------------------------------------------
// 21. JUDGE, part 1 of 2 — keep the CURRENT turn reachable from tool dispatch.
//     In streaming EVERY content block leaves as its OWN assistant message
//     (content is a one-element array), so the message that reaches the tool
//     executor carries the tool_use block ALONE — the thinking that motivated
//     the dispatch travelled earlier, in a different message. The full turn
//     only exists in the loop's accumulator, which the executor never sees.
//     Stash a snapshot of it keyed by tool_use id. Keyed by id rather than
//     hung on the context object because the loop REASSIGNS that object
//     (`Z={...Z,messages:...}`), so object identity is not a reliable bridge.
//     The extra argument to addTool is ignored by the callee; it exists only
//     to carry the side effect without restructuring the statement.
// --------------------------------------------------------------------------
step('21 current turn reachable at tool dispatch', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  // if(!Ju)Ye.push(Dl); ... for(let wd of Xu)bt.streamingToolExecutor.addTool(wd,Dl)
  const rx = new RegExp(
    `if\\(!(${ID})\\)(${ID})\\.push\\((${ID})\\);([\\s\\S]{0,240}?)` +
      `\\.streamingToolExecutor\\.addTool\\((${ID}),\\3\\)`,
  );
  const m = js.match(rx);
  if (!m) fail('current-turn accumulator / addTool site not found');
  // Gated on the same switch as the judge itself: an entry is removed only when
  // the judge READS it, so with the judge off nothing would ever clear this map
  // — it would sit at its 64-entry cap holding message arrays for a feature that
  // is not running. Off has to mean off.
  const stash =
    '(process.env.CLAUDE_JUDGE?((globalThis.__ccJudgeTurn??=new Map()),' +
    'globalThis.__ccJudgeTurn.set($5.id,$2.includes($3)?$2.slice():[...$2,$3]),' +
    'globalThis.__ccJudgeTurn.size>64&&globalThis.__ccJudgeTurn.delete(globalThis.__ccJudgeTurn.keys().next().value),0):0)';
  js = js.replace(rx, `if(!$1)$2.push($3);$4.streamingToolExecutor.addTool($5,$3,${stash})`);
  applied.push(`judge: current turn stashed by tool_use id (accumulator '${m[2]}', message '${m[3]}')`);
});

// --------------------------------------------------------------------------
// 22. JUDGE, part 2 of 2 — consult a local model BEFORE a subagent dispatch.
//     Site: the single tool invocation inside the executor, where the call is
//     already resolved but not yet executed. The context handed to the judge
//     is the same one the server-side advisor sees (the request's message
//     array) PLUS the current turn — which advisor never gets, because its
//     view is the request body, i.e. the state BEFORE the model answered.
//     Deliberately a plain HTTP call and not the bundle's own single-shot
//     query helper: that helper is invoked with constructors that live in
//     another module's scope, so reaching it would need a lazily-initialised
//     bridge that may never run. A direct request depends on no minified
//     binding at all.
//     OFF unless CLAUDE_JUDGE is set; every failure path is fail-open, so a
//     dead proxy degrades to today's behaviour instead of breaking dispatch.
//     Subagent dispatches are not judged (agentType must be "main").
// --------------------------------------------------------------------------
step('22 judge consulted before a subagent dispatch', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  // se=await e.call(E,{...n,toolUseId:t,userModified:X.userModified??!1},o,i,p)
  // Форма вызова инструмента сменилась в 2.1.239: прямой `e.call(w,ctx,…)`
  // уехал за адаптер `hii(e).execute(w,ctx,…)`, где
  // `hii(e) = e.executor ?? {execute:(…)=>e.call(…)}`. Держатся ОБЕ формы:
  // сборки с прямым вызовом ещё в ходу, и локатор, знающий только новую,
  // сломался бы на них ровно так же.
  //
  // Судья цепляется за САМ инструмент, а не за адаптер: `.name` есть у `e`,
  // у обёртки его нет. В прямой форме имя инструмента ловится группой 2, в
  // адаптерной — группой 3; дальше обе сводятся к одному имени, и номера групп
  // наружу не торчат.
  const rx = new RegExp(
    `(${ID})=await (?:(${ID})\\.call|${ID}\\((${ID})\\)\\.execute)` +
      `\\((${ID}),\\{\\.\\.\\.(${ID}),toolUseId:(${ID}),` +
      `userModified:(${ID})\\.userModified\\?\\?!1\\},(${ID}),(${ID}),(${ID})\\)`,
  );
  const m = js.match(rx);
  if (!m) fail('tool dispatch call site not found');
  const TOOL = m[2] ?? m[3];
  const SLOT = { $1: m[1], $2: TOOL, $3: m[4], $4: m[5], $5: m[6], $6: m[7] };
  // Судья едет НА СОБСТВЕННОМ одиночном запросе клиента
  // (queryModelWithoutStreaming), а не на своём HTTP-вызове: эта функция идёт
  // через ту же фабрику клиента, что и любой другой запрос, поэтому пул
  // моделей и обе его полосы — клиентские. `claude-*` остаётся на подписочной
  // полосе (патч 1), всё остальное уходит в прокси. Свой HTTP-путь увёл бы
  // claude-модели на api.anthropic.com по цене API — другой договор и другой
  // счёт. Имя находится структурно по сигнатуре, а не по минифицированному
  // написанию: оно меняется от сборки к сборке.
  const qrx = new RegExp(
    `async function (${ID})\\(\\{messages:${ID},systemPrompt:${ID},thinkingConfig:${ID},` +
      `tools:${ID},signal:${ID},options:${ID}\\}\\)`,
  );
  const qm = js.match(qrx);
  if (!qm) fail('single-shot query engine not found');
  // Минифицированное имя может содержать `$`, а строка замены трактует `$` как
  // ссылку на группу — экранируем прежде, чем вклеивать в замену.
  const QM = repEsc(qm[1]);
  // Everything the operator tunes lives in files read ON EVERY CALL, not in the
  // binary: a judge whose wording can only change by re-patching cannot be
  // iterated on. body.json is a full request template with {{CONTEXT}} and
  // {{DISPATCH}} placeholders, so model, parameters and message layout are all
  // editable; prompt.md is the shorthand when only the instruction changes.
  // Substituted text goes through JSON.stringify minus its outer quotes, so a
  // quote or newline in the transcript cannot break the template's JSON.
  const judge =
    'if(process.env.CLAUDE_JUDGE&&($2.name==="Agent"||$2.name==="Task")&&$4?.agentContext?.agentType==="main"){' +
    // Every consultation is journaled, not just the ones run with debug on:
    // a WARN has no channel to the model (the dispatch proceeds, and the
    // tool_result the model later sees comes from the agent itself), and a
    // fail-open skip is invisible by construction. Without an append-only
    // record both are indistinguishable from a judge that was never asked —
    // the "switched off at both ends" failure. Declared OUTSIDE the try so
    // the catch can still record why a consultation was skipped.
    'let __t0=Date.now(),__jfs=null,__jrec=!0,__jgz=!1,__jreq=null,__jres=null,__jst=null,' +
    // __jtry=0, а не 1: до первой попытки попыток НОЛЬ. Единица заявляла
    // попытку там, где бросило ДО лестницы.
    // __pdir объявлен ЗДЕСЬ, а не внутри try: catch — соседний блок, и
    // let из try в нём не виден. Измерено на живом вызове: путь пропуска
    // падал с ReferenceError ДО записи в журнал, диспатч получал
    // "__pdir is not defined", а журнал не получал ничего.
    // __jarm: судейство обязано вынести решение. Взводится, когда вызов
    // не отфильтрован и включены enforce+fail_closed; снимается, когда
    // решение вынесено. Если управление уходит в catch со взведённым
    // флагом — это молчаливый пропуск, и он отменяется.
    '__jtry=0,__jerr1=null,__jm=null,__jurl=null,__jatt=[],__pdir=null,__jarm=!1,' +
    // Любой catch{} без следа превращает поломку в тихую деградацию: битый
    // конфиг молча снимал enforce и fail_closed, а журнал показывал штатную
    // работу. Деградации собираются и попадают в журнал полем deg; те, что
    // задевают САМО СУЖДЕНИЕ, копятся отдельно и отменяют вызов.
    '__deg=[],__degb=[],' +
    // Список деградаций режется с объявлением: молча отброшенная шестая
    // строка означает, что человек чинит пять файлов, перезапускает и
    // получает отмену снова.
    '__dcut=(__l,__k)=>__l.length<=__k?__l:__l.slice(0,__k).concat('+
      '"[\\u043f\\u043e\\u043a\\u0430\\u0437\\u0430\\u043d\\u044b \\u043d\\u0435 \\u0432\\u0441\\u0435: \\u0435\\u0449\\u0451 "+(__l.length-__k)+"]"),' +
    // Всякое усечение в журнале и записи объявляется — той же конвенцией,
    // что и подрезка ленты: обрыв вердикта посреди слова читается как
    // полный вердикт, а обрезанный ответ упавшей попытки — как весь её след.
    '__clip=(__s,__k)=>{let __x=String(__s??"");return __x.length<=__k?__x:'+
      '__x.slice(0,__k)+" [\\u0432\\u044b\\u0440\\u0435\\u0437\\u0430\\u043d\\u043e "+'+
      '(__x.length-__k)+" \\u0437\\u043d\\u0430\\u043a\\u043e\\u0432]"},' +
    '__jdir=process.env.CLAUDE_JUDGE_DIR||((process.env.HOME||".")+"/.claude/judge");' +
    // The journal line is an INDEX, not evidence: its verdict is clipped and
    // the material the judge actually saw is nowhere in it, so neither
    // "did it judge correctly" nor "train a smaller model on these" can be
    // answered from it. The full request/response pair is written beside it,
    // one file per consultation, and the journal line carries its name.
    'let __jsave=async(__ts,__base)=>{if(!__jrec||!__jreq||!__jfs)return null;' +
      'let __n=__ts.replace(/[:.]/g,"-")+"-"+String($5).slice(-8)+".json"+(__jgz?".gz":"");' +
      'try{await __jfs.mkdir(__jdir+"/records",{recursive:!0});' +
        'let __rq;try{__rq=JSON.parse(__jreq)}catch{__rq=__jreq}' +
        'let __data=JSON.stringify({...__base,http:__jst,url:__jurl,pid:process.pid,' +
          'cwd:process.cwd(),attempts:__jatt,request:__rq,response:__jres},null,1);' +
        'let __out=__data;' +
        'if(__jgz){try{let __z=await import("node:zlib");__out=__z.gzipSync(Buffer.from(__data))}' +
          'catch{__n=__n.replace(/\\.gz$/,"")}}' +
        'await __jfs.writeFile(__jdir+"/records/"+__n,__out);return __n}' +
      'catch(__re){try{console.error("[Judge] record write failed: "+(__re?.message??__re))}catch{}return null}};' +
    // `ms` and `sw` exist because both were unobservable before: a `block`
    // line and a `block_not_enforced` line differ only by a state the record
    // never held, and the latency tax — the feature's whole running cost —
    // was measurable only by watching a session with a stopwatch.
    'let __jlog=async(__o)=>{let __ts=new Date().toISOString();' +
      'let __base={t:__ts,tool:$2.name,agent:$3?.subagent_type,model:$3?.model,' +
        'ms:Date.now()-__t0,sw:process.env.CLAUDE_JUDGE||null,...__o};' +
      'let __rn=await __jsave(__ts,__base);' +
      'let __r=JSON.stringify(__rn?{...__base,rec:__rn}:__base);' +
      // На свежей установке каталога судьи ещё нет, а отмен там больше всего:
      // дописка без mkdir теряла в журнале ровно те строки, по которым человек
      // и должен понять, что чинить (в stderr они уходили, в журнал — нет).
      'try{if(!__jfs)throw new Error("fs unavailable");' +
        'try{await __jfs.appendFile(__jdir+"/journal.jsonl",__r+"\\n")}' +
        'catch(__ae){if(__ae?.code!=="ENOENT")throw __ae;' +
          'await __jfs.mkdir(__jdir,{recursive:!0});' +
          'await __jfs.appendFile(__jdir+"/journal.jsonl",__r+"\\n")}}' +
      'catch(__we){try{console.error("[Judge] journal write failed: "+' +
        '(__we?.message??__we)+" | "+__r)}catch{}}};' +
    'try{' +
      'let __t=globalThis.__ccJudgeTurn?.get($5)||[];globalThis.__ccJudgeTurn?.delete($5);' +
      // Provenance, not just role. Claude Code files tool results, injected
      // reminders, task notifications and peer messages under the SAME "user"
      // role as something the human typed, so a judge shown bare role labels
      // reads the dispatcher's own text as the user's sanction — measured: a
      // dispatch was waved through because the main loop had written "this is
      // a sanctioned probe" a second earlier. Only a turn that is neither a
      // tool result nor an injected block keeps the "user" label.
      // Три дефекта подряд (вывод локальной команды, аргументы слэш-команды,
      // резюме компакции) были одним и тем же классом: Claude Code кладёт под
      // роль "user" всё новые виды записей, и каждый находился ПО ИНЦИДЕНТУ.
      // Поэтому неизвестная обёртка, уцелевшая в классе "user", попадает в
      // журнал полем uw — класс становится измеримым, а не сюрпризом.
      'let __uw=[];' +
      'let __arr=[...($4.messages||[]),...__t].map((__M)=>{let __m=__M?.message;if(!__m)return null;' +
        'let __c=Array.isArray(__m.content)?__m.content:[{type:"text",text:String(__m.content??"")}];' +
        'let __bt=__c.map((__b)=>__b?.type==="text"?__b.text:' +
        '__b?.type==="thinking"?"[thinking] "+__b.thinking:' +
        '__b?.type==="tool_use"?"[tool "+__b.name+"] "+JSON.stringify(__b.input).slice(0,400):' +
        '__b?.type==="tool_result"?"[result] "+String(typeof __b.content==="string"?__b.content:JSON.stringify(__b.content)).slice(0,300):' +
        '"["+__b?.type+"]").join("\\n");if(!__bt)return null;' +
        // Provenance comes from the ENVELOPE first (isMeta / toolUseResult are
        // what Claude Code itself uses to tell synthetic and tool messages
        // apart) and only falls back to sniffing wrapper markers.
        'let __role=__m.role||__M.type||"?";' +
        'if(__role==="user")__role=(__M?.toolUseResult!==void 0||__c.some((__x)=>__x?.type==="tool_result"))' +
          // Вывод локальной команды приходит под ролью "user" — это ОТВЕТ
          // ПРОГРАММЫ на действие человека, а не его слова. Измерено стендом
          // 2026-08-21: блоки <local-command-stdout> оседали в единственном
          // происхождении, которому судья даёт вес санкции, и после
          // закрепления оседали НАВСЕГДА. Сам вызов команды — действие
          // человека, но не указание судье, поэтому у него своя метка.
          '?"tool-output":__M?.isCompactSummary?"compaction-summary":' +
          '(__bt.includes("<local-command-stdout")||' +
            '__bt.includes("<local-command-stderr"))?"tool-output":' +
          // <command-args> несёт СОБСТВЕННЫЕ слова человека («веди полосу
          // lane-16, без агентов и без скриптов»), а не имя команды. Измерено
          // стендом 2026-08-21 по стенограммам проекта: 24 непустых блока, все
          // — распоряжения. Значит запись с непустыми аргументами это речь
          // человека со всеми правами санкции; голый вызов вроде /model —
          // действие человека, но не указание судье.
          '(/<command-args>\\s*[^\\s<]/.test(__bt))?"user":' +
          '(__bt.includes("<command-name>")||__bt.includes("<command-message>")||' +
            '__bt.includes("<command-args>"))?"user-command":' +
          '((__M?.isMeta||__M?.isVisibleInTranscriptOnly||' +
            '__bt.includes("<system-reminder")||__bt.includes("<task-notification")||' +
            '__bt.includes("<cross-session-message")||__bt.includes("[SYSTEM NOTIFICATION")||' +
            '__bt.includes("[Request interrupted by user"))?"injected":"user");' +
        'if(__role==="user"){let __wm=/^\\s*<([a-z][a-z0-9-]*)/i.exec(__bt);' +
          'if(__wm&&["command-name","command-message","command-args"].indexOf(__wm[1].toLowerCase())<0' +
            '&&__uw.indexOf(__wm[1])<0)__uw.push(__wm[1])}' +
        'return{src:__role,text:__bt}}).filter(Boolean);' +
      'let __fs=await import("node:fs/promises");__jfs=__fs;' +
      'let __dir=process.env.CLAUDE_JUDGE_DIR||((process.env.HOME||".")+"/.claude/judge");' +
      // The judge stays project-agnostic on purpose: it rules on the event, the
      // logic and the rules, not on what a project is about. What a project MAY
      // do is restate the rules for itself — a nearest `.claude/judge` above the
      // cwd layers over the global one (config keys merge, `prompt.extra.md` is
      // appended, a full `prompt.md`/`body.json` replaces). An explicit
      // CLAUDE_JUDGE_DIR turns layering off: a probe must get exactly what it
      // was handed.
      '__pdir=null;' +
      // Отсутствие слоя и НЕЧИТАЕМЫЙ слой — разные события: первое значит
      // "правил нет", второе "правила есть, но я их не прочёл". Пока оба
      // давали одно и то же (access().catch(()=>!1)), проектные правила
      // исчезали молча, а обход ехал выше и подхватывал ЧУЖОЙ слой.
      // Различать надо не ENOENT против всего прочего, а "пути нет" против
      // "путь есть, доступа нет". Обычный файл по имени .claude у предка
      // даёт ENOTDIR, петля ссылок — ELOOP; оба значат "такого каталога
      // нет" и к "слой есть, но я его не прочёл" отношения не имеют, а
      // отменяли ВСЁ поддерево при исправном судье. Незнакомый код не
      // отменяет ничего, но и не исчезает: он называется в журнале.
      'let __pcode=(__er)=>{let __c=String(__er?.code||"");' +
        'return __c==="EACCES"||__c==="EPERM"?2:' +
        '(__c==="ENOENT"||__c==="ENOTDIR"||__c==="ELOOP"||__c==="ENAMETOOLONG"?0:3)};' +
      'if(!process.env.CLAUDE_JUDGE_DIR)try{let __p=process.cwd();' +
        'for(let __i=0;__i<24;__i++){let __c=__p+"/.claude/judge";' +
          'let __has=await Promise.all([__c+"/config.json",__c+"/prompt.md",' +
            '__c+"/prompt.extra.md",__c+"/body.json"].map((__f)=>' +
            '__fs.access(__f).then(()=>({c:1})).catch((__er)=>' +
              '({c:__pcode(__er),e:String(__er?.code||"ERR")}))));' +
          'let __no=__has.find((__x)=>__x.c===2),__un=__has.find((__x)=>__x.c===3);' +
          'if(__no){__deg.push("layer-unreadable:"+__c+" ("+__no.e+")");' +
            '__degb.push("layer-unreadable:"+__c+" ("+__no.e+")");' +
            'if(__c!==__dir)__pdir=__c;break}' +
          'if(__un)__deg.push("layer-unknown:"+__c+" ("+__un.e+")");' +
          'if(__has.some((__x)=>__x.c===1)){if(__c!==__dir)__pdir=__c;break}' +
          'let __up=__p.replace(/\\/[^\\/]*$/,"");if(!__up||__up===__p)break;__p=__up}}catch{}' +
      // Читалка объявляет исход: null — файла нет, !1 — файл есть, но не
      // прочитан или не разобран. Молчаливый разбор превращал битый конфиг
      // в пустой объект, а с ним терялись enforce, fail_closed, лестница и
      // max_tokens — судья выглядел работающим и пропускал всё подряд.
      'let __rdj=async(__f)=>{try{return await __fs.readFile(__f,"utf8")}' +
        'catch(__er){let __k=__pcode(__er);' +
          'if(__k===2){__deg.push("unreadable:"+__f+" ("+String(__er?.code)+")");' +
            '__degb.push("unreadable:"+__f+" ("+String(__er?.code)+")")}' +
          'else if(__k===3)__deg.push("unread-unknown:"+__f+" ("+' +
            'String(__er?.code||__er?.message)+")");' +
          'return null}};' +
      // BOM невидим, а JSON.parse его не принимает: человек получал отмену
      // с сообщением, где сломавший символ не виден, и выйти из неё чтением
      // было нельзя. Пустой файл называется пустым, а не "неожиданным
      // концом ввода": это обычное промежуточное состояние записи, и
      // человек должен узнать причину с первого взгляда.
      'let __ldj=async(__f)=>{let __x=await __rdj(__f);if(__x===null)return null;' +
        'if(__x.charCodeAt(0)===65279)__x=__x.slice(1);' +
        'if(!__x.trim()){__deg.push("empty:"+__f);__degb.push("empty:"+__f);return !1}' +
        'try{return JSON.parse(__x)}catch(__pe){__deg.push("unparsed:"+__f+": "+' +
          '__clip(__pe?.message??__pe,60));' +
          '__degb.push("unparsed:"+__f+": "+__clip(__pe?.message??__pe,60));return !1}};' +
      'let __cfg={},__cfgbad=!1;' +
      'let __c0=await __ldj(__dir+"/config.json");' +
      'if(__c0===!1)__cfgbad=!0;else if(__c0)__cfg=__c0;' +
      'if(__pdir){let __c1=await __ldj(__pdir+"/config.json");' +
        'if(__c1===!1)__cfgbad=!0;else if(__c1)__cfg={...__cfg,...__c1}}' +
      'if(__cfg.record===!1)__jrec=!1;' +
      'if(__cfg.record_gzip===!0)__jgz=!0;' +
      'let __ask=!0;' +
      'if(__cfg.filter){let __f=__cfg.filter,__pm=String($3?.prompt??""),' +
        '__cl=(/\\[dispatch-class:([\\w-]+)\\]/.exec(__pm)||[])[1]||"",' +
        '__ag=String($3?.subagent_type??""),' +
        '__mt=(__l,__s)=>Array.isArray(__l)&&__l.length>0&&__l.some((__r)=>{try{return new RegExp(__r).test(__s)}catch{return !1}});' +
        'let __by=null;' +
        'if(__mt(__f.classes_skip,__cl))__by="classes_skip";' +
        'else if(__mt(__f.agents_skip,__ag))__by="agents_skip";' +
        'else if((Array.isArray(__f.classes_judge)&&__f.classes_judge.length>0)||' +
          '(Array.isArray(__f.agents_judge)&&__f.agents_judge.length>0)){' +
          'if(!(__mt(__f.classes_judge,__cl)||__mt(__f.agents_judge,__ag)))' +
            '__by=__cl?"not_in_judge_list":"no_class_marker"}' +
        'if(__by){__ask=!1;await __jlog({outcome:"filtered",by:__by,cls:__cl||null})}}' +
      // enforce/fail_closed вычисляются ДО консультации: обязательство
      // вынести решение должно быть известно и на пути отказа, где ни
      // вердикта, ни __cfg уже не прочитать.
      // Непонятый конфиг = enforce и fail_closed НЕИЗВЕСТНЫ. Считать их
      // выключенными значит выключать гейт одним битым файлом, поэтому
      // здесь они считаются включёнными: ложная отмена дешевле пропуска.
      'let __en=process.env.CLAUDE_JUDGE==="enforce"||__cfg.enforce===!0||__cfgbad;' +
      'let __fcl=__cfgbad||__cfg.fail_closed===!0;' +
      'if(__ask){__jarm=__en&&__fcl;' +
      // The transcript is handed over as a JSON ARRAY, not as labelled lines.
      // A text prefix cannot carry trust: content and label share one
      // namespace, so any line inside a tool output, a file, a web page or a
      // peer's letter that begins with "user: " is indistinguishable from the
      // real label (demonstrated 2026-08-20 by printing exactly such a line).
      // As a JSON value the same text is escaped into `text` and can never
      // become a sibling `src` key. Trimming drops whole oldest entries —
      // slicing the serialised string would hand over broken JSON.
      // Подрезка ленты. Требования, каждое куплено инцидентом:
      // (1) носители распоряжений человека — его реплики и резюме компакции —
      //     не выбрасываются целиком, а режутся: выброшенный носитель это молча
      //     потерянное распоряжение;
      // (2) доля считается на КЛАСС, а не на запись (поштучный потолок резюме
      //     давал 64% ленты при задуманных 30%, и ход работы вытеснялся весь);
      // (3) незакреплённая запись, удаление которой увело бы ленту НИЖЕ бюджета,
      //     укорачивается под зазор — иначе лента обнулялась, а судья выносил
      //     обычный вердикт вслепую;
      // (4) все пороги в ДЛИНЕ JSON, а не текста: экранирование раздувает
      //     управляющий символ вшестеро, и текстовые пороги промахивались в обе
      //     стороны. Маркер добавляется последним и оплачивается точно;
      // (5) стоимость — линейная. Сначала ушла квадратичность по СЕРИАЛИЗАЦИИ
      //     (stringify всего массива на каждое удаление), затем квадратичность
      //     по ЧИСЛУ УДАЛЕНИЙ: splice двух массивов и повторный поиск самой
      //     длинной записи на каждый шаг давали 5-10 секунд на ленте в 40-60
      //     тысяч записей — и это на КАЖДУЮ ступень лестницы, до запроса.
      //     Поэтому удаление помечает, а не вырезает; массив уплотняется один
      //     раз; выбрасывание внутри доли идёт одним курсором с головы.
      'let __cut=(__n)=>{' +
        'let __b=Math.max(60,__n),__pb=Math.floor(__b*0.35),__sb=Math.floor(__b*0.3);' +
        'let __d=0,__dp=0;' +
        'let __cs=(__x)=>JSON.stringify(__x).length+1;' +
        'let __a=__arr.slice(),__w=__a.map(__cs),__dd=new Array(__a.length).fill(!1),__tot=2;' +
        // Исходный текст записи хранится отдельно: подрезанная запись может
        // быть подрезана ВТОРОЙ раз, и считать вырезанное от прошлого среза
        // значит называть в метке лишь последний шаг.
        'let __ot=new Array(__a.length).fill(null);' +
        'for(let __k=0;__k<__w.length;__k++)__tot+=__w[__k];' +
        'let __pr=(__x)=>__x&&(__x.src==="user"||__x.src==="compaction-summary");' +
        'let __isu=(__x)=>__x&&__x.src==="user";' +
        'let __iss=(__x)=>__x&&__x.src==="compaction-summary";' +
        // Текст режется с ОБОИХ концов: начало несёт распоряжение, хвост резюме —
        // разделы «все сообщения пользователя» и «незакрытые задачи». Цель задаётся
        // в JSON-длине; текстовый предел подбирается по фактической цене, потому
        // что коэффициент экранирования у разного содержимого разный.
        'let __fit=(__i,__tc)=>{if(__w[__i]<=__tc)return 0;' +
          // Вторая подрезка идёт от ИСХОДНОГО текста, а не от прошлого среза:
          // иначе метка называет вырезанное только последним шагом (мерено:
          // "вырезано 123 знаков" там, где от 200004 знаков осталось 4), а
          // прошлая метка выпадает из текста вместе со следом первой подрезки.
          // Заодно исчезает и сама возможность вложенных меток.
          'let __t=__ot[__i]!==null?__ot[__i]:String(__a[__i].text);' +
          'let __lim=Math.max(8,__tc-60),__nx=null,__c=0;' +
          'for(let __z=0;__z<10;__z++){' +
            'let __h=Math.min(__t.length,Math.floor(__lim*0.55));' +
            'let __tl=Math.max(0,Math.min(__lim-__h-44,__t.length-__h));' +
            '__nx={src:__a[__i].src,text:__t.slice(0,__h)+" [\\u0432\\u044b\\u0440\\u0435\\u0437\\u0430\\u043d\\u043e "+(__t.length-__h-__tl)+" \\u0437\\u043d\\u0430\\u043a\\u043e\\u0432] "+(__tl?__t.slice(-__tl):"")};' +
            '__c=__cs(__nx);if(__c<=__tc||__lim<=8)break;' +
            '__lim=Math.max(8,Math.floor(__lim*__tc/__c*0.9))}' +
          'let __g=__w[__i]-__c;if(__g<=0)return 0;' +
          '__ot[__i]=__t;__a[__i]=__nx;__w[__i]=__c;__tot-=__g;return __g};' +
        'let __al=(__k)=>!__dd[__k];' +
        'let __sum=(__f)=>{let __r=0;for(let __k=0;__k<__a.length;__k++)if(__al(__k)&&__f(__a[__k]))__r+=__w[__k];return __r};' +
        'let __long=(__f)=>{let __i=-1,__L=-1;for(let __k=0;__k<__a.length;__k++)' +
          'if(__al(__k)&&__f(__a[__k])&&__w[__k]>__L){__L=__w[__k];__i=__k}return __i};' +
        'let __cnt=(__f)=>{let __r=0;for(let __k=0;__k<__a.length;__k++)if(__al(__k)&&__f(__a[__k]))__r++;return __r};' +
        'let __del=(__i,__p)=>{if(__dd[__i])return 0;__dd[__i]=!0;__tot-=__w[__i];__d++;if(__p)__dp++;return __w[__i]};' +
        'let __head=()=>{for(let __k=0;__k<__a.length;__k++)if(__al(__k))return __k;return -1};' +
        // Подрезанных считается столько, сколько их ОСТАЛОСЬ в ленте: счёт
        // вызовов __fit завышал (одна запись режется дважды, а подрезанную
        // потом может вытеснить) — на реальной ленте 39 против 4 живых.
        'let __ctd=()=>{let __r=0;for(let __k=0;__k<__a.length;__k++)'+
          'if(__al(__k)&&__ot[__k]!==null)__r++;return __r};' +
        // Внутри доли класса сначала укорачивается САМАЯ ДЛИННАЯ запись (это
        // сходится за считанные шаги), а добор идёт выбрасыванием с головы одним
        // курсором: размер не признак важности, но и повторный поиск длиннейшей
        // на каждое удаление — это N² на марафонской ленте.
        'let __cap=(__f,__lim)=>{let __s1=__sum(__f);' +
          'for(let __g=0;__g<64&&__s1>__lim;__g++){' +
            'let __i=__long(__f);if(__i<0||__w[__i]<=240)break;' +
            'let __gg=__fit(__i,Math.max(120,__w[__i]-(__s1-__lim)));if(!__gg)break;__s1-=__gg}' +
          'let __cur=0,__c1=__cnt(__f);' +
          'while(__s1>__lim&&__c1>1&&__cur<__a.length){' +
            'if(!__al(__cur)||!__f(__a[__cur])){__cur++;continue}' +
            '__s1-=__del(__cur,!0);__c1--;__cur++}};' +
        '__cap(__iss,__sb);__cap(__isu,__pb);' +
        'for(let __k=0;__k<__a.length&&__tot>__b;__k++){' +
          'if(!__al(__k)||__pr(__a[__k]))continue;' +
          'if(__tot-__w[__k]>=__b){__del(__k,!1);continue}' +
          'if(__w[__k]>120)__fit(__k,__w[__k]-(__tot-__b));else __del(__k,!1)}' +
        // Последний рубеж: незакреплённого не осталось. Режется самая длинная
        // запись; голова выбрасывается, только если резать больше нечего.
        'for(let __g=0;__g<20000&&__tot>__b;__g++){' +
          'let __i=__long(()=>!0);if(__i<0)break;' +
          'if(__w[__i]>120&&__fit(__i,Math.max(60,__w[__i]-(__tot-__b))))continue;' +
          'let __h2=__head();if(__h2<0||__cnt(()=>!0)<=1)break;__del(__h2,__pr(__a[__h2]))}' +
        '__a=__a.filter((__x,__k)=>__al(__k));__w=__a.map(__cs);' +
        '__ot=__ot.filter((__x,__k)=>__al(__k));' +
        '__dd=new Array(__a.length).fill(!1);' +
        // Маркер обязан называть и ПОТЕРЯННОЕ среди закреплённого: счёт одних
        // выживших выглядит благополучно ровно тогда, когда распоряжение ушло.
        // Он добавляется последним и оплачивается ужиманием ленты на свою цену;
        // на крошечном бюджете переходит в краткую форму, иначе не помещается сам.
        'if(__d>0||__ctd()>0){' +
          'let __cd=0;let __mt=()=>"[\\u043b\\u0435\\u043d\\u0442\\u0430 \\u043f\\u043e\\u0434\\u0440\\u0435\\u0437\\u0430\\u043d\\u0430: \\u0432\\u044b\\u0442\\u0435\\u0441\\u043d\\u0435\\u043d\\u043e "+__d+" \\u0437\\u0430\\u043f\\u0438\\u0441\\u0435\\u0439; \\u0437\\u0430\\u043a\\u0440\\u0435\\u043f\\u043b\\u0435\\u043d\\u043e \\u0440\\u0435\\u043f\\u043b\\u0438\\u043a \\u0447\\u0435\\u043b\\u043e\\u0432\\u0435\\u043a\\u0430: "+__cnt(__isu)+", \\u0440\\u0435\\u0437\\u044e\\u043c\\u0435 \\u043a\\u043e\\u043c\\u043f\\u0430\\u043a\\u0446\\u0438\\u0438: "+__cnt(__iss)' +
            '+(__dp?"; \\u0412\\u042b\\u0422\\u0415\\u0421\\u041d\\u0415\\u041d\\u041e \\u0417\\u0410\\u041a\\u0420\\u0415\\u041f\\u041b\\u0401\\u041d\\u041d\\u042b\\u0425: "+__dp:"")+((__cd=__ctd())?"; \\u043f\\u043e\\u0434\\u0440\\u0435\\u0437\\u0430\\u043d\\u043e \\u043f\\u043e \\u0442\\u0435\\u043a\\u0441\\u0442\\u0443: "+__cd:"")+"]";' +
          'let __sm=()=>"[\\u043f\\u043e\\u0434\\u0440\\u0435\\u0437\\u0430\\u043d\\u043e "+__d+"]";' +
          'if(__cs({src:"injected",text:__mt()})*4>__n)__mt=__sm;' +
          'let __mc=__cs({src:"injected",text:__mt()})+120;' +
          'for(let __g=0;__g<20000&&__tot+__mc>__n&&__a.length>0;__g++){' +
            'let __i=__long(()=>!0);if(__i<0)break;' +
            'if(__w[__i]>120&&__fit(__i,Math.max(60,__w[__i]-(__tot+__mc-__n))))continue;' +
            'let __h4=__head();' +
            'if(__cnt(()=>!0)<=1&&(__h4<0||!__fit(__h4,Math.max(24,__n-__mc-4))))break;' +
            'let __h3=__head();if(__h3<0||__cnt(()=>!0)<=1)break;__del(__h3,__pr(__a[__h3]))}' +
          '__a=__a.filter((__x,__k)=>__al(__k));' +
          '__w=__a.map(__cs);__ot=__ot.filter((__x,__k)=>__al(__k));' +
          '__dd=new Array(__a.length).fill(!1);' +
          '__a.unshift({src:"injected",text:__mt()})}' +
        'return JSON.stringify(__a)};' +
      'let __max=Number(__cfg.context_chars||60000);' +
      'let __ctx=__cut(__max);' +
      'let __disp=JSON.stringify($3).slice(0,Number(__cfg.dispatch_chars||4000));' +
      'let __emb=(__s)=>JSON.stringify(String(__s)).slice(1,-1);' +
      'let __sys=process.env.CLAUDE_JUDGE_PROMPT;' +
      'if(!__sys&&__pdir)__sys=await __rdj(__pdir+"/prompt.md");' +
      'if(!__sys)__sys=await __rdj(__dir+"/prompt.md");' +
      // Дописка проекта читается той же читалкой: её немое исчезновение —
      // ровно тот случай, что и немое исчезновение проектного конфига.
      'if(__pdir){let __ex=await __rdj(__pdir+"/prompt.extra.md");' +
        'if(__ex&&__ex.trim())__sys=(__sys||"")+"\\n\\n=== \\u041f\\u0420\\u0410\\u0412\\u0418\\u041b\\u0410 ' +
          '\\u042d\\u0422\\u041e\\u0413\\u041e \\u041f\\u0420\\u041e\\u0415\\u041a\\u0422\\u0410 ===\\n"+__ex}' +
      // Запасной промпт обязан уметь ОТМЕНЯТЬ: в прежнем слова BLOCK не было
      // вовсе, а единственный не-OK исход, который он предлагал (SWAP),
      // записывался как ok и пропускал вызов. Гейт был формально жив и
      // содержательно выключен, а журнал полон "ok".
      // Метка называет путь, как и все остальные: на свежей установке это
      // ЕДИНСТВЕННЫЙ отказ, который человек увидит, и из "prompt-missing"
      // без пути не следует, что создать надо ~/.claude/judge/prompt.md.
      'if(!__sys){let __pmm="prompt-missing:"+__dir+"/prompt.md"+' +
        '(__pdir?" | "+__pdir+"/prompt.md":"");' +
        '__deg.push(__pmm);__degb.push(__pmm);' +
        '__sys="You judge one about-to-run subagent dispatch. You do NOT rewrite it: "+' +
        '"you either let it run or CANCEL it and say why. Answer with ONE line, "+' +
        '"the verdict FIRST: OK:<why> or WARN:<why> or BLOCK:<what is wrong and what "+' +
        '"to do instead>. BLOCK cancels the dispatch. Your own prompt file is "+' +
        '"missing, so judge on the general rule: a dispatch must name its model and "+' +
        '"class, the class must match what the brief actually does, and an expensive "+' +
        '"model on closed mechanical work is a reason to BLOCK."}' +
      // A chain, not a single model: the judge shares its channel with the very
      // fleet it judges, so when the fleet is busy the judge is the one that
      // times out — and a silent fail-open is indistinguishable from blanket
      // approval. The next model gets the same question instead.
      // A ladder of attempts, not a list of names: each rung may carry its own
      // deadline, budget and transcript size, because the reasons a rung fails
      // differ — a congested provider needs a longer deadline, a reasoning
      // model a larger budget, an oversized transcript a shorter tail. A bare
      // string stays valid shorthand for {model:<name>}.
      'let __mdls=(process.env.CLAUDE_JUDGE_MODEL?[process.env.CLAUDE_JUDGE_MODEL]:' +
        '(Array.isArray(__cfg.models)&&__cfg.models.length?__cfg.models:[__cfg.model||"glm-5.3"]))' +
        '.map((__x)=>typeof __x==="string"?{model:__x}:__x).filter((__x)=>__x&&__x.model);' +
      'if(!__mdls.length)__mdls=[{model:"glm-5.3"}];' +
      'let __tplr=null;' +
      'if(__pdir)__tplr=await __rdj(__pdir+"/body.json");' +
      'if(!__tplr)__tplr=await __rdj(__dir+"/body.json");' +
      // Битый шаблон тела на исход не влияет (встроенное тело работает), но
      // положивший свой шаблон обязан узнать, что тот не применён.
      'if(__tplr){try{JSON.parse(__tplr.replace(/\\{\\{[A-Z]+\\}\\}/g,"x"))}' +
        'catch(__be){__deg.push("unparsed-body:"+__clip(__be?.message??__be,60));__tplr=null}}' +
      'let __mkb=(__cx,__e)=>{let __mdl=__e.model;try{if(!__tplr)throw new Error("no template");' +
        'let __tpl=__tplr.replace(/\\{\\{PROMPT\\}\\}/g,__emb(__sys)).replace(/\\{\\{MODEL\\}\\}/g,__emb(__mdl))' +
          '.replace(/\\{\\{CONTEXT\\}\\}/g,__emb(__cx)).replace(/\\{\\{DISPATCH\\}\\}/g,__emb(__disp));' +
        // One home per setting. The template carries its own model and budget,
        // so without this override `models` and `max_tokens` from config.json
        // are silent no-ops — measured twice: first with the model, then with
        // a 1200-token ceiling that truncated a cancel verdict into silence.
        'let __obj=JSON.parse(__tpl);__obj.model=__mdl;' +
        'let __mt=__e.max_tokens||__cfg.max_tokens;if(__mt)__obj.max_tokens=Number(__mt);' +
        'if(__e.effort)__obj.reasoning_effort=__e.effort;' +
        'return JSON.stringify(__obj)}catch{' +
        'return JSON.stringify({model:__mdl,max_tokens:Number(__e.max_tokens||__cfg.max_tokens||300),' +
          'messages:[{role:"system",content:__sys},' +
          '{role:"user",content:"=== SESSION SO FAR ===\\n"+__cx+"\\n\\n=== DISPATCH ===\\n"+__disp}]})}};' +
      'let __pool=typeof ' + QM + '==="function"?' + QM + ':null;' +
      'let __purl=(()=>{let __u=process.env.CLAUDE_JUDGE_URL||__cfg.url||process.env.ANTHROPIC_BASE_URL||"http://127.0.0.1:8317";__u=String(__u).replace(/\\/+$/,"");return /\\/v1$/.test(__u)?__u+"/chat/completions":__u+"/v1/chat/completions"})();' +
      // Пул — путь по умолчанию. Сырой HTTP остаётся ТОЛЬКО как явно названный
      // адрес (проба стенда бьёт в свой приёмник) или как страховка, если
      // связывания с пулом в этой сборке не нашлось: судья, потерявший канал,
      // обязан деградировать, а не молчать.
      'let __http=!!(process.env.CLAUDE_JUDGE_URL||__cfg.url||__cfg.raw_http===!0)||!__pool;' +
      '__jurl=__http?__purl:"pool";' +
      'let __tmo=Number(process.env.CLAUDE_JUDGE_TIMEOUT_MS||__cfg.timeout_ms||8000);' +
      'let __call=async(__cx,__ms,__e)=>{' +
        'let __s0=Date.now(),__a={model:__e.model,via:__http?"http":"pool",ctx_chars:__cx.length,' +
          'timeout_ms:__ms,max_tokens:__e.max_tokens||__cfg.max_tokens||null,' +
          'effort:__e.effort||null};__jatt.push(__a);' +
        'let __ac=new AbortController(),__to=setTimeout(()=>__ac.abort(),__ms);' +
        // Ответ и статус гасятся в НАЧАЛЕ попытки: запрос писался каждой
        // попыткой, а ответ только удачной, и запись склеивала запрос
        // последней попытки с ответом ранней, молча.
        '__jres=null;__jst=null;' +
        'try{' +
          'if(__http){let __b=__mkb(__cx,__e);__jreq=__b;' +
            'if(process.env.CLAUDE_JUDGE_DEBUG)try{await __fs.writeFile(__dir+"/last-request.json",__b)}catch{}' +
            'let __r=await fetch(__purl,{method:"POST",signal:__ac.signal,' +
              'headers:{"content-type":"application/json"},body:__b});' +
            'let __t=await __r.text();__jst=__r.status;__jres=__t;__a.resp=__clip(__t,800);' +
            '__a.ms=Date.now()-__s0;__a.http=__r.status;' +
            'if(!__r.ok)throw new Error("HTTP "+__r.status);return __t}' +
          // Усилие едет полем options, а не полем тела: тело здесь не наше, его
          // собирает клиент. Ограничение вывода — maxOutputTokensOverride, оно
          // же единственный дом бюджета на этом пути.
          'let __ut="=== SESSION SO FAR ===\\n"+__cx+"\\n\\n=== DISPATCH ===\\n"+__disp;' +
          '__jreq=JSON.stringify({via:"pool",model:__e.model,effort:__e.effort||null,' +
            'max_tokens:Number(__e.max_tokens||__cfg.max_tokens||1200),' +
            'messages:[{role:"system",content:__sys},{role:"user",content:__ut}]});' +
          'let __r2=await __pool({messages:[{type:"user",message:{role:"user",content:__ut},' +
              'uuid:(globalThis.crypto?.randomUUID?.()||String(Date.now())),' +
              'timestamp:new Date().toISOString()}],' +
            'systemPrompt:[__sys],thinkingConfig:{type:"disabled"},tools:[],signal:__ac.signal,' +
            'options:{model:__e.model,isNonInteractiveSession:!0,hasAppendSystemPrompt:!1,' +
              'agents:[],mcpTools:[],querySource:"hook_prompt",toolChoice:void 0,' +
              'maxOutputTokensOverride:Number(__e.max_tokens||__cfg.max_tokens||1200),' +
              'effortValue:__e.effort||void 0,agentId:$4?.agentId,agentContext:$4?.agentContext,' +
              'getToolPermissionContext:async()=>$4?.getAppState?.()?.toolPermissionContext}});' +
          'let __t2=JSON.stringify(__r2);__jres=__t2;__a.resp=__clip(__t2,800);' +
          '__a.ms=Date.now()-__s0;' +
          '__jst=__r2?.isApiErrorMessage?"api_error":200;__a.http=__jst;' +
          // Текст ошибки пула ОБЯЗАН доехать до журнала: без него в ledger висит
          // «api error from the pool» без причины, а причина (лимит темпа, отказ
          // апстрима, неизвестная модель) требует разного лечения. Реальный
          // случай: три отказа подряд на одной ступени, и разобрать их было нечем.
          'if(__r2?.isApiErrorMessage){let __et="";' +
            'try{__et=(__r2.message?.content||[]).filter((__b)=>__b?.type==="text")' +
              '.map((__b)=>__b.text).join(" ").slice(0,300)}catch{}' +
            'throw new Error("api error from the pool: "+(__et||"(\u0431\u0435\u0437 \u0442\u0435\u043a\u0441\u0442\u0430)"))}' +
          'return __t2}' +
        'catch(__xe){__a.ms=Date.now()-__s0;' +
          '__a.error=String(__xe?.name||"Error")+": "+String(__xe?.message??__xe).slice(0,120);throw __xe}' +
        'finally{clearTimeout(__to)}};' +
      // The transcript IS the cost: a 60 KB consultation hit the deadline twice
      // running (measured 2026-08-20) and fail-open waved both dispatches
      // through in silence — a judge that switches itself off under load reads,
      // in every report, exactly like a judge that approved everything. So a
      // failed call is retried once against a short tail on half the deadline;
      // a late verdict beats no verdict, and the journal keeps both facts.
      // The verdict is demanded as the FIRST line of the reply, so the first
      // verdict-shaped line in `content` IS the decision. Measured 2026-08-20:
      // with the explanation first, a reasoning model spent its whole budget
      // deciding to cancel and was cut off before printing the line — the
      // dispatch then sailed through, because silence reads as consent. A
      // reasoning-only reply keeps the old rule (take the LAST such line) so a
      // verdict merely rehearsed mid-thought cannot outrank the conclusion.
      // Две формы ответа, потому что канала два: у прокси это choices[].message,
      // у пула — AssistantMessage с массивом блоков. Разбор один, чтобы правило
      // «вердикт первой строкой» не разошлось между каналами.
      'let __pv=(__r0)=>{let __j;try{__j=JSON.parse(__r0)}catch{__j=null}' +
        'let __mm=__j?.choices?.[0]?.message||{};' +
        'let __rx=/^\\s*(?:OK|BLOCK|STOP|DENY|WARN):.*$/gm;' +
        'let __bl=Array.isArray(__j?.message?.content)?__j.message.content:' +
          '(Array.isArray(__j?.content)?__j.content:null);' +
        'let __ct=String(__mm.content??"");' +
        'if(!__ct&&__bl)__ct=__bl.filter((__b)=>__b?.type==="text")' +
          '.map((__b)=>__b.text).join("\\n");' +
        'let __c1=(__ct.match(__rx)||[])[0];if(__c1)return __c1.trim();' +
        'let __rr=[__mm.reasoning,__mm.reasoning_content,__bl?__bl.filter((__b)=>' +
          '__b?.type==="thinking").map((__b)=>__b.thinking).join("\\n"):""]' +
          '.filter(Boolean).join("\\n");' +
        // Ответ без строки вердикта — НЕ вердикт. Прежде сюда падал сырой
        // текст модели, и любой ответ мимо словаря (например SWAP: из старого
        // запасного промпта) записывался как ok и пропускал вызов.
        'return ((String(__rr).match(__rx)||[]).pop()||"").trim()};' +
        // Поломка настроек или промпта — это не «работай по умолчанию», а
        // «я не знаю, по каким правилам судить». Под enforce такой вызов
        // отменяется с названием файла, а не пропускается молча.
        'if(__degb.length&&__en){' +
          'try{await __jlog({outcome:"block_degraded",tries:__jtry,jm:null,' +
            'cfg:__pdir||null,deg:__dcut(__deg,5)})}catch{}' +
          'let __e3=new Error("\\u0412\\u044b\\u0437\\u043e\\u0432 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043e\\u0442\\u043c\\u0435\\u043d\\u0451\\u043d: \\u043d\\u0430\\u0441\\u0442\\u0440\\u043e\\u0439\\u043a\\u0438 \\u0441\\u0443\\u0434\\u044c\\u0438 \\u0441\\u043b\\u043e\\u043c\\u0430\\u043d\\u044b ("+__dcut(__degb,3).join("; ")+"). \\u042d\\u0442\\u043e \\u041d\\u0415 \\u0433\\u0435\\u0439\\u0442 \\u043c\\u0430\\u0440\\u0448\\u0440\\u0443\\u0442\\u0438\\u0437\\u0430\\u0446\\u0438\\u0438. \\u0421\\u043a\\u0430\\u0436\\u0438 \\u043e\\u0431 \\u044d\\u0442\\u043e\\u043c \\u0447\\u0435\\u043b\\u043e\\u0432\\u0435\\u043a\\u0443: \\u043f\\u043e\\u043a\\u0430 \\u0444\\u0430\\u0439\\u043b \\u043d\\u0435 \\u043f\\u043e\\u0447\\u0438\\u043d\\u0435\\u043d, \\u0441\\u0443\\u0434\\u044c\\u044f \\u043d\\u0435 \\u0437\\u043d\\u0430\\u0435\\u0442, \\u043f\\u043e \\u043a\\u0430\\u043a\\u0438\\u043c \\u043f\\u0440\\u0430\\u0432\\u0438\\u043b\\u0430\\u043c \\u0441\\u0443\\u0434\\u0438\\u0442\\u044c.");' +
          '__e3.__ccJudgeBlock=!0;throw __e3}' +
      'let __raw=null,__v="",__errs=[];' +
      'for(let __i=0;__i<__mdls.length;__i++){let __e=__mdls[__i];' +
        'try{__jtry=__i+1;__jm=__e.model;' +
          '__raw=await __call(__e.context_chars?__cut(Number(__e.context_chars)):__ctx,' +
            'Number(__e.timeout_ms||__tmo),__e);' +
          '__v=__pv(__raw);if(__v)break;' +
          // A 2xx with no verdict (budget spent on reasoning, finish_reason
          // "length") is a failure like any other — the chain must move on, or
          // the judge stops at the first model that answers with nothing.
          '__errs.push(__jm+": empty verdict")}' +
        'catch(__ce){__raw=null;__errs.push(__jm+": "+String(__ce?.name||"Error")+": "+' +
          '__clip(__ce?.message??__ce,80))}}' +
      // The automatic last rung: the same ladder step the config could have
      // spelled out — last model, short tail — kept so that a ladder written
      // without one still survives an oversized transcript. `retry_context_chars: 0`
      // switches it off for a ladder that already ends in a short-tail rung.
      'if(!__v&&Number(__cfg.retry_context_chars??8000)>0){' +
        'let __e=__mdls[__mdls.length-1];' +
        '__jtry=__mdls.length+1;__jm=__e.model;__jerr1=__errs.join(" | ")||null;' +
        // Повтор обёрнут так же, как ступень: без обёртки его падение
        // уходило во внешний catch, тот писал "skip" и НЕ отменял вызов —
        // молчаливый пропуск ровно там, ради чего заведён fail_closed.
        'try{__raw=await __call(__cut(Number(__cfg.retry_context_chars??8000)),' +
          'Number(__e.timeout_ms||__tmo),__e);__v=__pv(__raw);' +
          'if(!__v)__errs.push(__jm+": empty verdict")}' +
        'catch(__ce){__raw=null;__errs.push(__jm+": "+String(__ce?.name||"Error")+": "+' +
          '__clip(__ce?.message??__ce,80))}}' +
      '__jerr1=__errs.join(" | ")||null;' +
      'if(process.env.CLAUDE_JUDGE_DEBUG){console.error("[Judge] "+__v.slice(0,300));' +
        'try{await __fs.writeFile(__dir+"/last-verdict.txt",__v)}catch{}}' +
      // The judge does not rewrite the dispatch — it CANCELS it and says why.
      // Rewriting would produce a model/effort pair that nothing validates:
      // the deterministic gate runs earlier in this same function, so a
      // substitution made here would sail past it. A refusal is strictly more
      // restrictive than what the gate already allowed, so ordering stops
      // mattering. Thrown rather than hand-built: a tool that throws already
      // surfaces to the model as an error tool_result, which is exactly
      // "stop, and here is what is wrong" — and it couples to no minified name.
      'let __bl=/^(?:BLOCK|STOP|DENY):\\s*([\\s\\S]+)$/m.exec(__v);' +
      // Отмена по исчерпанию лестницы — дефект КАНАЛА, отмена по вердикту —
      // дефект СУЖДЕНИЯ, и лечатся они разным. Пока обе писались как "empty"
      // (то же слово, что у пропущенного вызова при fail_closed:false), снаружи
      // они были неотличимы ни друг от друга, ни от пропуска.
      'let __fc=!__v&&__en&&__fcl;' +
      // Журнал не смеет увести управление мимо решений ниже: сбой записи
      // при готовом BLOCK ушёл бы во внешний catch и стал бы пропуском.
      'try{await __jlog({http:__jst,outcome:__bl?(__en?"block":"block_not_enforced"):' +
        '(/^\\s*WARN:/.test(__v)?"warn":__v?"ok":(__fc?"block_no_verdict":"empty")),' +
        'en:__en?(process.env.CLAUDE_JUDGE==="enforce"?"env":"config"):null,' +
        '...(__uw.length?{uw:__uw.slice(0,5)}:{}),' +
        '...(__deg.length?{deg:__dcut(__deg,5)}:{}),' +
        'tries:__jtry,jm:__jm,cfg:__pdir||null,err1:__jerr1,' +
        'verdict:__clip(__v,400)||null})}catch{}' +
      // Принцип юзера (2026-08-20): «лучше ложная отмена, чем молчаливый
      // пропуск». Провал ВСЕЙ лестницы — это и есть молчаливый пропуск: судья
      // не сказал ничего, а вызов ушёл. При `fail_closed` он вместо этого
      // отменяется. Ставка осознанная: отказ канала останавливает диспатчи, но
      // ступень по подписке лежит только вместе с самим клиентом, так что
      // полный провал означает, что сессии и так нечем работать. Выключается
      // одним ключом конфига, без пересборки бинарника.
      'if(__fc){' +
        'let __e0=new Error("\\u0412\\u044b\\u0437\\u043e\\u0432 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043e\\u0442\\u043c\\u0435\\u043d\\u0451\\u043d: \\u0441\\u0443\\u0434\\u044c\\u044f \\u043d\\u0435 \\u043f\\u043e\\u043b\\u0443\\u0447\\u0438\\u043b \\u0432\\u0435\\u0440\\u0434\\u0438\\u043a\\u0442 \\u043d\\u0438 \\u043d\\u0430 \\u043e\\u0434\\u043d\\u043e\\u0439 \\u0441\\u0442\\u0443\\u043f\\u0435\\u043d\\u0438 (' + '"+String(__jerr1||"").slice(0,200)+"' + '). \\u042d\\u0442\\u043e \\u041d\\u0415 \\u0433\\u0435\\u0439\\u0442 \\u043c\\u0430\\u0440\\u0448\\u0440\\u0443\\u0442\\u0438\\u0437\\u0430\\u0446\\u0438\\u0438. \\u0421\\u043a\\u0430\\u0436\\u0438 \\u043e\\u0431 \\u044d\\u0442\\u043e\\u043c \\u0447\\u0435\\u043b\\u043e\\u0432\\u0435\\u043a\\u0443 \\u0438 \\u0441\\u0434\\u0435\\u043b\\u0430\\u0439 \\u0440\\u0430\\u0431\\u043e\\u0442\\u0443 \\u0431\\u0435\\u0437 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043b\\u0438\\u0431\\u043e \\u043f\\u043e\\u0432\\u0442\\u043e\\u0440\\u0438 \\u043f\\u043e\\u0437\\u0436\\u0435, \\u043a\\u043e\\u0433\\u0434\\u0430 \\u043a\\u0430\\u043d\\u0430\\u043b \\u043e\\u0436\\u0438\\u0432\\u0451\\u0442.");' +
        '__e0.__ccJudgeBlock=!0;throw __e0}' +
      'if(__bl&&__en){' +
                // tweakcc unpacks and repacks the bundle as BYTES, so a literal
        // non-ASCII character injected here comes back double-encoded and
        // the model reads mojibake (measured 2026-08-20). Emitted escaped,
        // it is ASCII on the wire and correct in the running string.
        'let __er=new Error("\\u0412\\u044b\\u0437\\u043e\\u0432 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043e\\u0442\\u043c\\u0435\\u043d\\u0451\\u043d \\u0441\\u0443\\u0434\\u044c\\u0451\\u0439 \\u0432\\u044b\\u0437\\u043e\\u0432\\u043e\\u0432 (\\u044d\\u0442\\u043e \\u041d\\u0415 \\u0433\\u0435\\u0439\\u0442 \\u043c\\u0430\\u0440\\u0448\\u0440\\u0443\\u0442\\u0438\\u0437\\u0430\\u0446\\u0438\\u0438 hooks/routing-table.toml). \\u041f\\u0440\\u0438\\u0447\\u0438\\u043d\\u0430: "+__bl[1].trim());' +
        '__er.__ccJudgeBlock=!0;throw __er}' +
      // Решение вынесено — обязательство снято. Снимается ПОСЛЕДНИМ: всё,
      // что бросит раньше, обязано отменить вызов, а не пропустить его.
      '__jarm=!1;' +
    '}}catch(__e){if(__e&&__e.__ccJudgeBlock)throw __e;' +
      'let __rs=String(__e?.name||"Error")+": "+__clip(__e?.message??__e,200);' +
      'try{await __jlog({outcome:__jarm?"block_no_verdict":"skip",tries:__jtry,jm:__jm,' +
        'cfg:__pdir||null,err1:__jerr1,reason:__rs})}catch{}' +
      // Отказ судьи при взведённом обязательстве — не пропуск, а отмена:
      // сюда приходит и падение до лестницы (конфиг, тело, подрезка), где
      // вердикта нет и быть не может.
      'if(__jarm){let __e2=new Error("\\u0412\\u044b\\u0437\\u043e\\u0432 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043e\\u0442\\u043c\\u0435\\u043d\\u0451\\u043d: \\u0441\\u0443\\u0434\\u044c\\u044f \\u043d\\u0435 \\u0441\\u043c\\u043e\\u0433 \\u0432\\u044b\\u043d\\u0435\\u0441\\u0442\\u0438 \\u0440\\u0435\\u0448\\u0435\\u043d\\u0438\\u0435 ("+__rs+"). \\u042d\\u0442\\u043e \\u041d\\u0415 \\u0433\\u0435\\u0439\\u0442 \\u043c\\u0430\\u0440\\u0448\\u0440\\u0443\\u0442\\u0438\\u0437\\u0430\\u0446\\u0438\\u0438. \\u0421\\u043a\\u0430\\u0436\\u0438 \\u043e\\u0431 \\u044d\\u0442\\u043e\\u043c \\u0447\\u0435\\u043b\\u043e\\u0432\\u0435\\u043a\\u0443 \\u0438 \\u0441\\u0434\\u0435\\u043b\\u0430\\u0439 \\u0440\\u0430\\u0431\\u043e\\u0442\\u0443 \\u0431\\u0435\\u0437 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043b\\u0438\\u0431\\u043e \\u043f\\u043e\\u0432\\u0442\\u043e\\u0440\\u0438 \\u043f\\u043e\\u0437\\u0436\\u0435.");' +
        '__e2.__ccJudgeBlock=!0;throw __e2}' +
      'if(process.env.CLAUDE_JUDGE_DEBUG)console.error("[Judge] skipped: "+(__e?.message??__e));}}';
  // Вклейка по СМЕЩЕНИЮ, а не через String.replace: номера групп разъезжаются
  // между двумя формами вызова, а строка замены ещё и читает `$` как ссылку.
  // Срез по m.index не трактует ничего, а сам вызов возвращается на место
  // дословно (m[0]) — переписывать его нам незачем.
  const judgeResolved = judge.replace(/\$([1-9])/g, (t, d) => {
    const v = SLOT['$' + d];
    if (!v) fail(`judge body references ${t}, which this call shape does not bind`);
    return v;
  });
  js = js.slice(0, m.index) + judgeResolved + m[0] + js.slice(m.index + m[0].length);
  applied.push(
    `judge: consulted before dispatch (tool '${TOOL}', input '${m[4]}', context '${m[5]}')`,
  );
});

// ---------------------------------------------------------------------------
// Ported from tweakcc's own patch set, which cannot apply on this build at all:
// its patched bundle no longer parses ("SyntaxError: Unexpected identifier"),
// so EVERY customization it carries is silently absent. These three are the
// ones worth owning ourselves; located independently rather than by porting
// tweakcc's regexes, two of which already fail on their own terms here.

step('23 statusline update throttle', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const THROTTLE_MS = 500;   // mirrors settings.misc.statuslineThrottleMs
  // The scheduler debounces its refresh through one module constant; the
  // constant is what tweakcc's "statusline-update-throttle" ends up rewriting
  // too, but it reaches it through a 1000-character regex over the React
  // callback. Anchor on the debounce CALL SITE instead, which names the
  // constant, then rewrite the single declaration it points at.
  const site = new RegExp(
    `#(${ID})\\(\\)\\{this\\.#(${ID})\\?\\.\\(\\),this\\.#\\2=this\\.#(${ID})` +
      `\\.setTimeout\\(\\(\\)=>\\{this\\.#\\2=null,this\\.#(${ID})\\(\\)\\},(${ID})\\)\\}`,
  );
  const m = js.match(site);
  if (!m) fail('statusline debounce call site not found');
  const constName = m[5];
  const decl = new RegExp(`var ${rxEsc(constName)}=300\\b`);
  if (!decl.test(js)) fail(`statusline throttle constant '${constName}' is not the expected 300`);
  js = js.replace(decl, `var ${repEsc(constName)}=${THROTTLE_MS}`);
  applied.push(`statusline throttle 300 -> ${THROTTLE_MS}ms (constant '${constName}')`);
});

step('24 bypass permissions under sudo', () => {
  // Two independent guards refuse bypassPermissions when euid is 0: the inline
  // check on the startup path and the exported refuseBypassUnderRoot(). tweakcc
  // rewrites only the FIRST — String.match stops there — which leaves the
  // second one live and the setting half-applied. Both are neutralised here.
  const guard =
    'console.error("--dangerously-skip-permissions cannot be used with root/sudo ' +
    'privileges for security reasons"),process.exit(1)';
  const count = js.split(guard).length - 1;
  if (count === 0) fail('root/sudo refusal not found');
  if (count !== 2) fail(`expected 2 root/sudo refusals, found ${count} — re-check before neutralising`);
  js = js.split(guard).join('void 0');
  applied.push(`root/sudo refusal neutralised at ${count} sites`);
});

step('25 CLAUDE.md alternate filenames', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  // Every memory file — user, project, local, parent-directory walk — is read
  // through this one function, so a wrapper around it covers all of them. The
  // storage-backed branch returns "absent" WITHOUT throwing, which is why
  // tweakcc's approach (patch the catch clause) misses the common case here.
  const ALTS = [
    'AGENTS.md', 'GEMINI.md', 'CRUSH.md', 'QWEN.md',
    'IFLOW.md', 'WARP.md', 'copilot-instructions.md',
  ];
  const rx = new RegExp(
    `async function (${ID})\\((${ID}),(${ID}),(${ID}),(${ID})\\)\\{try\\{let (${ID}),(${ID})=!1;` +
      `if\\(\\5\\)\\{let (${ID})=await (${ID})\\(\\5\\);switch\\(\\8\\.kind\\)\\{case"absent":` +
      `return\\{info:null,includePaths:\\[\\]\\};`,
  );
  const m = js.match(rx);
  if (!m) fail('memory-file loader not found');
  const [, fn, a, b, c, d] = m;
  const inner = `${fn}$cc`;
  // The alternate is read from the filesystem (descriptor dropped): a storage
  // descriptor names ONE key, so reusing it would hand back CLAUDE.md's bytes
  // under the alternate's name — worse than not finding the file.
  const wrapper =
    `async function ${fn}(${a},${b},${c},${d}){` +
      `let __r=await ${inner}(${a},${b},${c},${d});` +
      `if(__r&&__r.info)return __r;` +
      `let __p=String(${a}??"");` +
      `if(!/(^|[\\\\/])CLAUDE\\.md$/.test(__p))return __r;` +
      `let __c=String(${c}??"");` +
      `let __sw=(__s,__n)=>/(^|[\\\\/])CLAUDE\\.md$/.test(__s)?__s.slice(0,-9)+__n:__s;` +
      `for(let __n of ${JSON.stringify(ALTS)}){` +
        `try{let __x=await ${inner}(__sw(__p,__n),${b},__c?__sw(__c,__n):${c},void 0);` +
        `if(__x&&__x.info)return __x}catch{}}` +
      `return __r}`;
  const declAt = js.indexOf(m[0]);
  js =
    js.slice(0, declAt) +
    wrapper +
    m[0].replace(`async function ${fn}(`, `async function ${inner}(`) +
    js.slice(declAt + m[0].length);
  applied.push(`CLAUDE.md alternates: ${ALTS.join(', ')} (loader '${fn}')`);
});

// 26. The main loop learns the RULE, not the judge. Until now a cancelled
// dispatch arrived as a bare error out of nowhere: measured, the model read it
// as the routing gate firing and reissued the same call. Telling it up front
// that a cancellation carries a correction removes the blind retry — and the
// text deliberately does not name a judge, so the model has no addressee to
// argue with, only a rule to follow. Injected at the very site the advisor
// uses for its own instructions, and only for the main loop: `agentContext` is
// in scope right there, and subagents never dispatch, so they get nothing.
step('26 dispatch-cancellation rule in the system prompt', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const RULE =
    'A subagent dispatch may be reviewed before it runs. If one is cancelled, ' +
    'the tool result states the reason: treat that reason as a correction to apply. ' +
    'Reissue the dispatch only with the change it names, and never repeat the identical call ' +
    '- an unchanged retry cannot succeed. This review is separate from the permission system ' +
    'and from any routing gate, so do not attribute a cancellation to either.';
  const rx = new RegExp(
    '(\\{isNonInteractive:(' + ID + ')\\.isNonInteractiveSession,' +
    'hasAppendSystemPrompt:\\2\\.hasAppendSystemPrompt\\}\\),' +
    '\\.\\.\\.' + ID + ',\\.\\.\\.' + ID + '\\?\\[' + ID + '\\]:\\[\\])' +
    '\\]\\.filter\\(Boolean\\)',
  );
  const m = js.match(rx);
  if (!m) throw new Error('system-prompt assembly site not found');
  js = js.replace(
    rx,
    '$1,...(process.env.CLAUDE_JUDGE&&$2?.agentContext?.agentType==="main"?' +
      JSON.stringify(RULE).replace(/^/, '[').replace(/$/, ']') +
      ':[])].filter(Boolean)',
  );
  applied.push(`system prompt: dispatch-cancellation rule (options '${m[2]}')`);
});


// --------------------------------------------------------------------------
// 27. РЕЖИМ ПОЛНОГО ПРОПУСКА ПРОПУСКАЕТ ВСЁ.
//     Решение «спросить» несёт поле circuitBreaker; часть предохранителей
//     помечена в реестре как bypassImmune, и на них режим полного пропуска не
//     действует — запрос доходит до человека. Практический случай: удаление,
//     чей путь не разрешается статически (glob, `~`, рабочий каталог и его
//     предки), помечено `dangerousRemoval` с иммунитетом, и сессия, запущенная
//     с ключом полного пропуска, всё равно останавливается на нём.
//     Правится ТОЛЬКО ветка полного пропуска: в остальных режимах предохранитель
//     работает как прежде, и второй потребитель предиката (выбор представителя
//     среди нескольких результатов одной команды) не затрагивается.
// --------------------------------------------------------------------------
step('27 full-bypass mode admits no immunity', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const before = js.length;

  // f=p&&l?.behavior==="ask"?_B(l.decisionReason,FMn):void 0;
  // Якорится на форме, а не на именах: p — предикат режима, вычисленный строкой
  // выше, l — накопленное решение, FMn — предикат иммунитета.
  const rx = new RegExp(
    `(${ID})=(${ID})&&(${ID})\\?\\.behavior==="ask"\\?` +
      `(${ID})\\(\\3\\.decisionReason,(${ID})\\):void 0;`,
  );
  const m = js.match(rx);
  if (!m) fail('bypass-immunity site not found');

  // Соседняя строка обязана оказаться веткой режима полного пропуска: без этой
  // сверки локатор мог бы сесть на однотипную форму в другом гейте.
  const head = js.slice(Math.max(0, m.index - 260), m.index);
  if (!head.includes('"bypassPermissions"')) {
    fail('bypass-immunity site is not the permission-mode branch');
  }

  js = js.slice(0, m.index) + `${m[1]}=void 0;` + js.slice(m.index + m[0].length);

  applied.push(
    `full-bypass mode admits no circuit-breaker immunity ` +
      `(flag '${m[1]}', mode predicate '${m[2]}', decision '${m[3]}', ${js.length - before} bytes)`,
  );
});


// The gate lives at the very END on purpose: it was once placed mid-file, and
// the four steps written after it ran unguarded — a broken locator among them
// was recorded and never read, so the build reported success while the patch
// was missing (that is exactly how step 26 first shipped as a no-op).
if (failures.length > 0) {
  throw new Error(
    `multi-provider patch: ${failures.length} of ${failures.length + applied.length} patches ` +
    `could not be applied (nothing written):\n  - ${failures.join('\n  - ')}` +
    (applied.length ? `\n  applied OK: ${applied.length}` : ''),
  );
}

console.error(`multi-provider patch: applied ${applied.length} edits:\n  - ${applied.join('\n  - ')}`);

return js;
