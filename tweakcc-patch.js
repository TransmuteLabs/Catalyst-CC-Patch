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
// A step whose SUBJECT was deleted upstream is neither applied nor failed: it
// lands here, is declared in every summary -- success included -- and never
// stops the run. A step missing from the output must not be readable as
// "nothing happened" when the truth is "nothing was there to patch".
const inapplicable = [];
// A step switched off by the registry (tools/our-steps-off.txt) lands here:
// the body is NOT executed, the state is declared in every summary, and
// nothing is added to `failures` -- a stale locator inside a step that never
// runs has nothing to break. Unlike `inapplicable` (upstream deleted the
// subject) this is OUR decision, and the registry is its only home: turning
// a step back on is a one-line registry edit, never a code revert.
const stepsOff = [];
// Every name a step('…') call declares during this run. The registry arrives
// as injected text, so the only honest check for a typo'd registry name is
// against the names the script has itself declared by the time it ends.
const declaredSteps = [];

// A minified name can contain `$`: in 2.1.239 the session matcher is called
// `$jS`. In a regex SOURCE `$` is the end-of-line anchor, and a name injected
// without escaping NEVER matches: the locator fails not because the build
// changed but because the minifier picked a different letter. In the REPLACEMENT
// STRING `$` is a group reference, and the same name would silently turn into
// someone else's capture. Every CAPTURED name goes through rxEsc before being
// spliced into a template and through repEsc before being spliced into a
// replacement. Group references ($1, $2 ...) that we write ourselves are not
// escaped — they are meant to stay references.
const rxEsc = s => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const repEsc = s => String(s).replace(/\$/g, '$$$$');

// From Claude Code 2.1.242 the bundle is not one module but an entry plus
// ~1400 code-split chunks, handed to us joined with
// `/*__tweakcc_module_boundary_<n>__*/` separators. Minified names are scoped
// to a chunk, so THE SAME LETTER MEANS DIFFERENT THINGS IN DIFFERENT MODULES:
// in 2.1.245 `I` is the fork flag in the agent-launch module and an unrelated
// flag in the voice-stream module, where `I?void 0:{connectFailureCode:...}`
// has nothing to do with forks. Any patch that reads a name at one site and
// then uses it as a pattern must stay inside the module that defines it.
// Before the split this could not happen — there was one module — so patches
// written against 2.1.241 and earlier carry the assumption silently.
const moduleSliceAround = (text, pos) => {
  const boundary = /\n\/\*__tweakcc_module_boundary_\d+__\*\/\n/g;
  let start = 0;
  let end = text.length;
  let m;
  while ((m = boundary.exec(text)) !== null) {
    if (m.index < pos) start = m.index + m[0].length;
    else { end = m.index; break; }
  }
  return [start, end];
};

// A pattern that embeds a CAPTURED name may only be applied inside the module
// that defined the name. The whole-text form takes whichever match comes first,
// and in a split bundle that can be another chunk where the same letters mean
// something else. It is not a theoretical hazard: on 2.1.246 `var <name>=300` --
// the exact shape patch 22 rewrites -- occurs 13 times across the bundle under
// various names, so which one gets rewritten would be the minifier's call, not
// ours. Every such site hands its own capture position to these, and both the
// search and the edit stay inside that one module.
const moduleTextAt = pos => {
  const [start, end] = moduleSliceAround(js, pos);
  return js.slice(start, end);
};
const editModuleAt = (pos, fn) => {
  const [start, end] = moduleSliceAround(js, pos);
  js = js.slice(0, start) + fn(js.slice(start, end)) + js.slice(end);
};

// Each patch is run in isolation and its failure RECORDED rather than thrown,
// so one run reports EVERY broken locator instead of only the first. That
// matters because a new Claude Code release can break several at once, and each
// discovery otherwise costs a full unpack/repack cycle. Nothing is written when
// anything failed: the final throw discards all edits, so a half-patched binary
// is still impossible.
// CONSTRAINT: the single decision home for switched-off steps is
// tools/our-steps-off.txt. The adhoc sandbox has no filesystem and no
// environment (Node --permission, process.env replaced), so script text is
// the only channel the registry can take: claude-patch-all.sh substitutes
// the registry entries into this literal before handing the script to
// tweakcc, keying on this exact line. The empty default keeps a directly
// invoked script fully on -- no pipeline, no registry, every step runs.
const STEPS_OFF = [];

const step = (name, fn) => {
  declaredSteps.push(name);
  if (STEPS_OFF.includes(name)) {
    stepsOff.push(name);
    return;
  }
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
  const ID = '[A-Za-z_$][\\w$]*';
  // The spread that follows the auth fields is upstream's OWN baseURL branch.
  // Where ANTHROPIC_BASE_URL was statically absent the minifier collapsed it to
  // a dead `...!1` (2.1.251-2.1.259); 2.1.261 carries it live as
  // `...<env>.ANTHROPIC_BASE_URL?{baseURL:<env>.ANTHROPIC_BASE_URL}:!1`. Both
  // forms are accepted here, and the injection lands AFTER it — never before.
  // Order is the mechanism, not a detail: later keys win in an object literal,
  // so an injection placed ahead of a LIVE env spread would hand every
  // `claude-*` model to ANTHROPIC_BASE_URL — that is, to the proxy — precisely
  // when that variable is set, which is the ordinary configuration. The
  // caller's own `...<options>` still follows ours, exactly as before, so the
  // caller keeps the last word.
  // The field before the spread is the last auth field of the object: up to
  // 2.1.280 an inline `accessToken??null:null,`, from 2.1.281 the auth pair
  // `apiKey:<o>.apiKey,authToken:<o>.authToken,` (the token logic moved into a
  // helper). Either form anchors the same object; the spread order is unchanged.
  const rx = new RegExp(
    `((?:accessToken\\?\\?null:null,|apiKey:${ID}\\.apiKey,authToken:${ID}\\.authToken,))` +
      `(\\.\\.\\.(?:!1|${ID}\\.ANTHROPIC_BASE_URL\\?\\{baseURL:${ID}\\.ANTHROPIC_BASE_URL\\}:!1),)` +
      `(\\.\\.\\.${ID},)`,
  );
  const m = js.match(rx);
  if (!m) fail('routing site not found');
  const rxAll = js.match(new RegExp(rx.source, 'g'));
  if (rxAll.length !== 1) {
    fail(`routing site is not unique (${rxAll.length} matches)`);
  }

  // The model identifier is captured from the vertex branch `region:<fn>(<model>)`
  // that sits just above the firstParty object inside the SAME function.
  const window = js.slice(Math.max(0, m.index - 2500), m.index);
  const regions = [...window.matchAll(/region:[A-Za-z_$][\w$]*\(([A-Za-z_$][\w$]*)\)/g)];
  if (regions.length === 0) fail('could not capture the model identifier');
  const model = regions[regions.length - 1][1];

  const SUBSCRIPTION_URL = 'https://api.anthropic.com';
  const inject = `baseURL:/^claude/i.test(${model})?${JSON.stringify(SUBSCRIPTION_URL)}:void 0,`;
  js =
    js.slice(0, m.index) +
    m[1] + m[2] + inject + m[3] +
    js.slice(m.index + m[0].length);

  // The destination is only half of the decision. The same options bag carries
  //
  //   fetchOptions: Na({forAnthropicAPI:!0, hasBodyIdleWatchdog:…, url: FOo(k,model,T)})
  //
  // and `Na` reads that `url` to choose between the configured proxy and a
  // direct connection:
  //
  //   let o=_();                                   // HTTPS_PROXY / HTTP_PROXY
  //   if(o){ if(e.url && m(e.url)) return {...r,...h()};   // NO_PROXY match
  //          return {...r, proxy:…, ...h()} }
  //
  // `FOo("firstParty", …)` is `process.env.ANTHROPIC_BASE_URL || <default>`, so
  // with a proxy configured and the ANTHROPIC_BASE_URL host in NO_PROXY -- the
  // ordinary shape of a local gateway on a corporate network -- the request is
  // marked "no proxy needed" for the LOCAL host and then sent to
  // api.anthropic.com by the baseURL above. The connection options describe one
  // destination and the request goes to another.
  //
  // The fix is at the point the url is COMPUTED, not at the consumer: the model
  // variable is already the second argument there on every build in range
  // (2.1.233 `QoS(b,r,v)`, 240 `PQS(b,r,v)`, 242 `KMo(b,n,S)`, 246 `FOo(k,n,T)`),
  // so the same condition can be applied without introducing a name that might
  // not be in scope. Both sites now read one constant, so they cannot drift to
  // different destinations.
  //
  // Latent on a machine with no proxy variables set -- `Na` then returns the
  // same options for any url -- and wrong in the mechanism regardless.
  const foRx = new RegExp(
    `(fetchOptions:${ID}\\(\\{forAnthropicAPI:!0,hasBodyIdleWatchdog:${ID}\\(${ID}\\),url:)` +
      `(${ID}\\(${ID},${rxEsc(model)},${ID}\\)\\}\\))`,
  );
  const foAll = js.match(new RegExp(foRx.source, 'g'));
  if (!foAll) fail('anthropic-API fetch-options site not found');
  if (foAll.length !== 1) {
    fail(`anthropic-API fetch-options site is not unique (${foAll.length} matches)`);
  }
  js = js.replace(
    foRx,
    `$1/^claude/i.test(${repEsc(model)})?${JSON.stringify(SUBSCRIPTION_URL)}:$2`,
  );

  applied.push(
    `routing (model var '${model}'), and the connection options are computed ` +
      `for the same destination`,
  );
});

// --------------------------------------------------------------------------
// 2. DISCOVERY — drop the ANTHROPIC_AUTH_TOKEN requirement in
//    fetchGatewayModelOptions so /model lists the proxy's models without a
//    token (an open /v1/models needs none). `!<tok>` -> `!1` = never bail early.
//
//    This does NOT switch discovery on, and the difference is worth stating:
//    the enclosing function is gated ABOVE by a predicate that requires
//    CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY, firstParty auth and
//    ANTHROPIC_BASE_URL. With that opt-in absent, /model lists no gateway
//    models at all -- with or without this step. What the step removes is the
//    token requirement INSIDE a discovery that is already running.
// --------------------------------------------------------------------------
step('2 discovery', () => {
  // ДВЕ ФОРМЫ ОХРАННИКА, потому что кит патчит и старые версии.
  //
  // До 2.1.248 охранник читался одной строкой:
  //   let <t>=<ns>.ANTHROPIC_AUTH_TOKEN,<r>=<f>();if(!<t>&&!<r>)return;
  // В 2.1.248 апстрим переписал его: появились промежуточные значения и
  // ранний выход стал блоком с журналированием:
  //   let <r>=<ns>.ANTHROPIC_AUTH_TOKEN,<o>=<f>(),<u>=...,<p>=<r>||<u>,
  //   <g>=<h>()?.trim()||<u>;if(!<p>&&!<g>){<log>(...);return}
  // Обе формы гасятся одинаково -- первый конъюнкт становится ложью, ранний
  // выход не срабатывает, открытие моделей идёт дальше. Перебираем формы
  // по очереди и отказываемся, только если НЕ подошла ни одна: иначе новая
  // форма молча оставила бы образ без патча.
  const shapes = [
    /(let ([A-Za-z_$][\w$]*)=[\w$]*\.ANTHROPIC_AUTH_TOKEN,([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\(\);if\(!)\2(&&!\3\)return)/,
    /(let ([A-Za-z_$][\w$]*)=[\w$]*\.ANTHROPIC_AUTH_TOKEN,[^;]{0,240};if\(!)([A-Za-z_$][\w$]*)(&&![A-Za-z_$][\w$]*\)\{)/,
  ];
  let m = null;
  let shape = -1;
  for (let i = 0; i < shapes.length; i++) {
    m = js.match(shapes[i]);
    if (m) { shape = i; break; }
  }
  if (!m) fail('discovery guard not found');

  // В обеих формах группа 1 кончается на `if(!`, а дальше идёт имя, которое
  // мы и заменяем на `1`; хвост группы 4 несёт остаток условия.
  const guarded = shape === 0 ? m[2] : m[3];
  js = js.slice(0, m.index) + m[1] + '1' + m[4] + js.slice(m.index + m[0].length);
  applied.push(`discovery (guard !${guarded} -> !1, форма ${shape === 0 ? 'до 2.1.248' : '2.1.248+'})`);
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
  // `"inherit"` is a SENTINEL, not a model name -- the stock guard tests for it
  // explicitly. Dropping that test from the widened branch left only a
  // truthiness check, and `"inherit"` is truthy: the string was handed to the
  // model-name parser instead of meaning "take the parent's model", so an
  // inheriting agent got a badge built from a parse of the sentinel. The
  // fallback for both "no model" and "inherit" is the agent's resolved model,
  // which is exactly what the badge should name.
  const replacement =
    `else{let ${resolved}=${list}[0];if(${resolved})` +
    `{let ${main}=${getMain}(),${requested}=${input}.model&&${input}.model!=="inherit"` +
    `?${parse}(${input}.model):${resolved};`;

  js = js.slice(0, m.index) + replacement + js.slice(m.index + m[0].length);
  applied.push('model badge (always show when it differs from the main model)');
});

// ==========================================================================
// Ported from tweakcc. These began as replacements for ITS patches, whose
// published 4.3.2 locators no longer matched on CC 2.1.220. That is no longer
// the whole story: since the fork was fixed for the split bundle, tweakcc's
// session-memory and input-chevron patches DO apply and reach these same
// sites first. Each step here therefore applies when the site is in its
// original form and verifies the postcondition when it is not -- see steps 6
// and 7. Each still mirrors the original's behaviour, not just its intent.
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

  // The JSX callee is `<ns>.jsx(` up to 2.1.241 and a bare `<f>(` from 2.1.242,
  // where the ESM output binds the imported helper to a local name instead of
  // reaching through a namespace object, so the namespace part is optional.
  // What actually pins this site is the pair of backreferences in
  // `{color:<themeColor>,dimColor:<isLoading>,children:` together with the
  // memo guard just before it — the callee never carried the specificity.
  //
  // The gap between the two halves is bounded rather than open: the bundle is
  // now a 36 MB join of ~1400 chunks, and an unbounded lazy span is free to
  // pair a head in one module with a tail in another.
  const rx = new RegExp(
    `,\\{isLoading:(${ID}),(?:${ID}:${ID},)*themeColor:(${ID})\\}=${ID},(${ID})=\\2\\?\\?void 0[,;]` +
    `[\\s\\S]{0,600}?if\\([^)]*!==\\3[^)]*\\|\\|[^)]*!==\\1[^)]*\\)${ID}=${ID}(?:\\.${ID})?\\(${ID},\\{color:\\3,dimColor:\\1,children:`
  );
  // Both branches below refuse on ambiguity. A second component with the same
  // destructuring and the same conditional render would let the verify branch
  // report success while the real chevron sat in neither form -- a decoy the
  // step could not tell from the thing it owns.
  const rxAll = new RegExp(rx.source, 'g');
  const candidates = js.match(rxAll) || [];
  if (candidates.length > 1) fail(`input chevron component is ambiguous (${candidates.length} candidates)`);

  const m = js.match(rx);
  if (!m) {
    // tweakcc's own input-chevron patch writes the identical edit and runs
    // first, so "the original form is gone" is the normal case, not a
    // failure. Verify the postcondition -- the chevron's colour is now
    // conditional on the loading state -- and record which colour landed;
    // fail only if the site is neither in its original nor in a patched form.
    const patchedRx = new RegExp(
      `,\\{isLoading:(${ID}),(?:${ID}:${ID},)*themeColor:(${ID})\\}=${ID},(${ID})=\\2\\?\\?void 0[,;]` +
      `[\\s\\S]{0,600}?if\\([^)]*!==\\3[^)]*\\|\\|[^)]*!==\\1[^)]*\\)${ID}=${ID}(?:\\.${ID})?\\(${ID},` +
      `\\{color:\\1\\?\\3:("[^"]*"),dimColor:!1,children:`
    );
    const doneAll = js.match(new RegExp(patchedRx.source, 'g')) || [];
    if (doneAll.length > 1) fail(`patched input chevron is ambiguous (${doneAll.length} candidates)`);
    const done = js.match(patchedRx);
    if (!done) fail('input chevron component not found');
    applied.push(`input chevron colour (idle -> ${JSON.parse(done[4])}, already applied upstream, verified)`);
    return;
  }

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
//
//    What is forced here are the SERVER-side flags. The user-side master
//    switch is untouched and still decides: the entry point returns early on
//    settings.autoMemoryEnabled (default on, cleared by
//    CLAUDE_CODE_DISABLE_AUTO_MEMORY or CLAUDE_CODE_SIMPLE) and on a remote
//    session. With memory switched off in settings this step changes nothing,
//    which is the intended division rather than a gap.
// --------------------------------------------------------------------------
step('7 session memory', () => {
  const ID = '[A-Za-z_$][\\w$]*';

  // Session memory ships switched off behind two gates: an early return in the
  // extraction entry point, and a predicate that decides whether extraction
  // mode is on at all. Both are removed here.
  //
  // Two properties this step deliberately has:
  //
  // 1. The gate shapes are matched WITHOUT pinning the feature-flag names.
  //    Anthropic renames these flags between releases, and a locator keyed on
  //    "tengu_passport_quail" turns a rename into either a loud failure or --
  //    worse -- a silent pass once the fallback stops recognising anything.
  //
  //    The flag class is [a-z0-9_], not [a-z_]. With the narrower class a
  //    rename to `tengu_passport_quail_v2` matched NOTHING, and the verify
  //    branch then read "no gate here" as "already removed" -- a green run on
  //    a build where session memory is still switched off. That is the exact
  //    failure the flag-agnostic form was written to prevent, reintroduced by
  //    a character class.
  //
  //    Uniqueness is NOT bundle-wide. On 2.1.246 the bare-return gate shape
  //    occurs three times (tengu_hawthorn_steeple, tengu_passport_quail,
  //    tengu_vscode_feedback_survey); it is unique only inside the window
  //    after the extraction anchor, which is why the window exists and why it
  //    is measured from the anchor rather than searched bundle-wide. The
  //    extract-mode predicate shape IS unique bundle-wide.
  //
  // 2. Each half is APPLIED when its gate is present and VERIFIED when it is
  //    not. tweakcc's own session-memory patch runs before us and writes the
  //    byte-identical edits, so "already gone" is the normal case, not an
  //    anomaly. What this step owes the user is the postcondition -- no FEATURE
  //    FLAG gates extraction any more -- not the authorship of the edit. A gate
  //    that survives in a form neither of us recognises is a stop: session
  //    memory silently staying off is the failure this step exists to prevent.
  //
  //    The postcondition is deliberately NOT "nothing gates extraction". The
  //    extract-mode predicate is `flag && (isInteractive() || escapeFlag)`, and
  //    only the flag half is ours to force. Collapsing the whole body to
  //    `return!0` -- which both this step and tweakcc used to do -- also turned
  //    extraction on in NON-interactive sessions (print mode, background agents,
  //    SDK), spending a model call per extraction cycle in exactly the contexts
  //    that run unattended. The interactivity term is preserved by carrying the
  //    matched return expression over verbatim rather than re-spelling it.
  //
  //    Absence of the gated shape is therefore no longer accepted on its own:
  //    it cannot tell "already forced" from "reshaped upstream", and the second
  //    reads as success while session memory stays off. The step now asserts the
  //    POSITIVE end state -- exactly one function of the forced shape. Measured
  //    on pristine 2.1.233 / 240 / 242 / 246: gated shape 1, forced shape 0.
  const anchor = 'querySource:"extract_memories",forkLabel:"extract_memories"';
  const anchorIdx = js.indexOf(anchor);
  if (anchorIdx === -1) fail('session-memory extraction anchor not found');

  // (a) the extraction gate, inside the entry point the anchor names.
  // CONSTRAINT: the window is closed on the MODULE boundary, never on a fixed
  // width. The bundle is entry-plus-chunks, minified names are chunk-local
  // (see the scoping note above), and a fixed-width window measured from the
  // anchor crosses into neighbouring chunks -- on 2.1.278 an `if(` from the
  // next chunk then ends inside the window while its closing paren does not,
  // and the balance scan below refuses on text that was never one construct.
  const gateRx = new RegExp(`if\\(!${ID}\\("tengu_[a-z0-9_]+",!1\\)\\)return;`, 'g');
  const moduleEnd = () => {
    const boundary = /\n\/\*__tweakcc_module_boundary_\d+__\*\/\n/g;
    boundary.lastIndex = anchorIdx;
    const m = boundary.exec(js);
    // CONSTRAINT: "strictly after the anchor" is a predicate on the RESULT,
    // not just on where the search starts. A boundary found at or before the
    // anchor does not close this window -- slicing to it yields an empty
    // window that verifies nothing while reading as a pass.
    if (m !== null && m.index > anchorIdx) return m.index;
    // CONSTRAINT: no boundary to close on is an instrument refusal, never a
    // fallback to a wider window -- silently widening would reintroduce, and
    // hide, exactly the cross-module defect the closure exists to remove. The
    // two refusals must stay textually distinct: same-word failures cannot be
    // told apart in a log.
    const total = (js.match(/\/\*__tweakcc_module_boundary_\d+__\*\//g) || []).length;
    if (total === 0) {
      fail(
        `session-memory extraction window cannot be closed on a module boundary: ` +
          `the bundle carries no boundary markers (0) -- not the unpacked ` +
          `module-split form`
      );
    }
    fail(
      `session-memory extraction window cannot be closed on a module boundary: ` +
        `no marker after the anchor (anchorIdx ${anchorIdx}, ${total} boundaries ` +
        `in total) -- the anchor sits in the last module`
    );
  };
  const window = js.slice(anchorIdx, moduleEnd());
  const gates = window.match(gateRx) || [];
  if (gates.length > 1) {
    fail(`session-memory extraction gate is ambiguous (${gates.length} candidates)`);
  }
  const gateDone = gates.length === 1;
  if (gateDone) {
    const gateAt = anchorIdx + window.indexOf(gates[0]);
    js = js.slice(0, gateAt) + js.slice(gateAt + gates[0].length);
  }

  // Postcondition over the SAME MODULE, re-derived from the CURRENT js: the
  // cut above shifted every offset past it, so an end computed before it
  // names a foreign byte. The boundary is searched again, never nudged by
  // the removed length.
  const after = js.slice(anchorIdx, moduleEnd());
  // The wide flag-read detector: the postcondition's eyes. The locator above
  // stays narrow on purpose -- it cuts only the shape it understands -- so the
  // postcondition must NOT mirror it. A guard reshaped into a compound
  // condition, given a !0 default, or read through a member call
  // (`K.read("tengu_…")`, `this.getX("tengu_…")`) is invisible to the narrow
  // form, and "locator found nothing" then reads as "already removed" while
  // the gate is alive. Constraint: bare identifier, optionally `this.`-prefixed
  // or dotted (`ID.ID(`), because that covers every reader shape measured in
  // the 2.1.276 census -- anything wider (arbitrary receivers) would match
  // non-flag call sites.
  const wideReadRx = new RegExp(`(?:this\\.)?${ID}(?:\\.${ID})*\\("tengu_[a-z0-9_]+",(?:!0|!1)\\)`);
  // Structural walk over the window, not the locator's regex: each `if(` gets
  // its condition taken by BRACKET BALANCE (depth 1 back to 0), not by [^)] --
  // conditions nest (the stock entry gate is itself compound on 2.1.272+:
  // `if(!Me&&!H("tengu_passport_quail",!1))`). A condition that still reads a
  // feature flag in front of a return is a stop, whatever the condition's
  // shape; the refusal quotes the condition so the failure is tellable apart
  // from its neighbours. Balance is computed per `if(` over plain characters:
  // a minified condition carries no comments, and its only string literal --
  // the flag name -- cannot contain parens. An `if(` whose parens never close
  // inside the window is an instrument refusal, not a clean pass.
  for (let p = after.indexOf('if('); p !== -1; p = after.indexOf('if(', p + 1)) {
    let depth = 1;
    let condEnd = -1;
    for (let k = p + 3; k < after.length; k++) {
      const c = after[k];
      if (c === '(') depth++;
      else if (c === ')') {
        depth--;
        if (depth === 0) {
          condEnd = k;
          break;
        }
      }
    }
    if (condEnd === -1) {
      fail('session-memory extraction window holds an unbalanced if( -- cannot verify the gate is gone');
    }
    const cond = after.slice(p + 3, condEnd);
    if (!wideReadRx.test(cond)) continue;
    let s = condEnd + 1;
    while (s < after.length && /\s/.test(after[s])) s++;
    if (after.startsWith('return', s)) {
      fail(`session-memory extraction is still gated on a feature flag: if(${cond})`);
    }
  }

  // (b) the extract-mode predicate: `flagA && (!something || flagB)`.
  //
  // THE GUARD IS FOUND INSIDE THE FUNCTION, NOT AS THE FUNCTION'S FIRST BYTES.
  //
  // This locator used to be a single regex over the whole body, and it pinned
  // two things it never needed: that the flag guard is the FIRST statement, and
  // that the body holds nothing besides it and the return. 2.1.270 took the
  // site away without changing either of those in MEANING -- it inserted an
  // early return in front of the guard:
  //   function bat(){if(f0e()!==null)return!0;
  //                  if(!I("tengu_passport_quail",!1))return!1;
  //                  return!ke()||I("tengu_slate_thimble",!1)}
  // (root task #75, the tenth case).
  //
  // The function is identified by the two features it CARRIES, wherever in it
  // they sit: a flag guard that returns !1, and the interactivity return whose
  // second term is the escape-hatch flag. Census by the controller over 22
  // payloads, 2.1.233…2.1.270: exactly ONE such function on every one of them.
  // The search walks BACK from each guard to the nearest parameterless function
  // head -- measured distance head-to-guard: 0 through 2.1.268 (the guard is
  // the first statement) and 25 on 2.1.270; the window below is that
  // measurement with room, and bounded so a build that moved the guard out of
  // this function cannot latch onto an unrelated neighbour above it.
  const bodyAt = (at) => {
    let d = 0;
    for (let i = at; i < js.length && i - at < 3000; i++) {
      const c = js[i];
      if (c === '{') d++;
      else if (c === '}') {
        d--;
        if (d === 0) return js.slice(at, i + 1);
      }
    }
    return null;
  };
  const guardRx = new RegExp(`if\\(!${ID}\\("tengu_[a-z0-9_]+",!1\\)\\)return!1;`);
  const keepRx = new RegExp(`return!${ID}\\(\\)\\|\\|${ID}\\("tengu_[a-z0-9_]+",!1\\)`);
  const fnHeadRx = new RegExp(`function ${ID}\\(\\)\\{`, 'g');
  const HEAD_BACK = 400;
  // Every function that carries BOTH features, found from one of them.
  const carriers = (fromRx) => {
    const out = new Map();
    for (const hit of js.matchAll(new RegExp(fromRx.source, 'g'))) {
      const from = Math.max(0, hit.index - HEAD_BACK);
      const heads = [...js.slice(from, hit.index).matchAll(fnHeadRx)];
      if (!heads.length) continue;
      const h = heads[heads.length - 1];
      const open = from + h.index + h[0].length - 1;
      const body = bodyAt(open);
      // The head must be the one this hit lives IN, not merely one above it.
      if (!body || !body.includes(hit[0])) continue;
      if (!keepRx.test(body)) continue;
      out.set(from + h.index, { open, body, hit: hit[0], hitAt: hit.index });
    }
    return [...out.values()];
  };
  const modes = carriers(guardRx);
  if (modes.length > 1) {
    fail(`session-memory extract-mode predicate is ambiguous (${modes.length} candidates)`);
  }
  const modeDone = modes.length === 1;
  if (modeDone) {
    // ONLY the guard statement is cut. Everything else the predicate does stays
    // where it is -- including 2.1.270's early return, which answers a question
    // about a different thing entirely and is none of this patch's business.
    js = js.slice(0, modes[0].hitAt) + js.slice(modes[0].hitAt + modes[0].hit.length);
  }

  // THE POSTCONDITION IS THE GUARANTEE, NOT ONE SPELLING OF IT.
  //
  // It used to assert a literal end shape -- `function X(){return!Y()||Z(…)}`
  // -- which is what our own edit and the unpacker's OLD edit both happened to
  // produce, because both DELETED the guard statement. The unpacker's locator
  // was itself rebuilt structurally (fork b7546b8) and now NEUTRALISES the flag
  // read instead, leaving `if(!!0)return!1;` -- `!!0` is `false`, so the guard
  // can never again return !1. Same guarantee, different bytes, and the literal
  // assertion called it a failure. A postcondition that names one producer's
  // spelling breaks every time that producer is improved.
  //
  // What has to be true is exactly two things: the predicate still carries the
  // interactivity term (so extraction did NOT become unconditional -- that was
  // the defect this step's comment above describes, and asserting only the
  // absence of the gate would let it back in), and it no longer performs a LIVE
  // flag read that can return !1.
  const finals = carriers(keepRx);
  if (finals.length !== 1) {
    fail(
      `session-memory extract-mode predicate is not identifiable after the edit ` +
        `(${finals.length} functions carry the interactivity return; expected exactly 1)`
    );
  }
  // Same widening as the window half: the ONE allowed flag read is the escape
  // hatch the keepRx match itself carries; any OTHER read in the body -- a
  // compound condition, a !0 default, a member-call reader -- is a live gate
  // the narrow locator cannot see, and the refusal must quote it verbatim: an
  // unquoted failure is indistinguishable from its neighbours and gets fixed
  // blind.
  {
    const bStart = finals[0].open;
    const allowFrom = finals[0].hitAt - bStart;
    const allowTo = allowFrom + finals[0].hit.length;
    for (const r of finals[0].body.matchAll(new RegExp(wideReadRx.source, 'g'))) {
      if (r.index >= allowFrom && r.index < allowTo) continue;
      fail(
        `session-memory extract-mode predicate still performs a live feature-flag ` +
          `read -- ${r[0]} -- extraction may still be off`
      );
    }
  }

  const did = [gateDone ? 'extraction gate' : null, modeDone ? 'extract-mode predicate' : null].filter(Boolean);
  applied.push(
    did.length === 2
      ? 'session memory (extraction gate + extract-mode predicate)'
      : did.length === 0
        ? 'session memory (both gates already removed upstream; postconditions verified)'
        : `session memory (${did[0]}; the other gate already removed upstream, verified)`
  );
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
  let m = js.match(rx);
  let canonical, parse, model, envValue, fallback;
  if (m) {
    [, canonical, parse, model, envValue, fallback] = m;
  } else {
    // 2.1.251 вынес инлайновую проверку в ИМЕНОВАННЫЙ помощник и добавила ему
    // второе условие:
    //   function jw(e,t){ ... let o=a.CLAUDE_CODE_MAX_CONTEXT_TOKENS;
    //                     if(o!==void 0&&o>0&&Gw(e))return o; return q8e}
    //   function Gw(e){let t=Ot(e);return!t.startsWith("claude-")&&!PMe(Ye(t))}
    // Композицию канонизации НЕ угадываем: помощник выписывает её сам, и она
    // читается из его тела -- `parse` это внутреннее Ot, `canonical` -- Ye, чей
    // результат помощник и проверяет. Помощник обязан совпасть ЦЕЛИКОМ, вместе
    // со вторым условием: частичное совпадение означало бы, что мы взяли имя
    // от одной формы, а смысл у неё уже другой.
    const rxHelper = new RegExp(`&&(${ID})\\((${ID})\\)\\)return (${ID});return (${ID})\\}`);
    m = js.match(rxHelper);
    if (!m) fail('context-window default not found');
    const helper = m[1];
    [, , model, envValue, fallback] = m;
    // ДВЕ ФОРМЫ ТЕЛА помощника; обе обязаны совпасть ЦЕЛИКОМ по той же
    // причине, что и раньше (частичное совпадение = имя от одной формы,
    // смысл уже другой). 2.1.251-258:
    //   function Gw(e){let t=Ot(e);return!t.startsWith("claude-")&&!PMe(Ye(t))}
    // 2.1.259 переписала помощника: канонизация вынесена в переменную,
    // добавлены ze-нормализация, тест известности по обеим формам и
    // сравнение в нижнем регистре:
    //   function OL(e){let n=Et(e),r=cr(n),o=ze(r);
    //     if(bge(o)||r!==n&&bge(ze(n)))return!1;
    //     let p=r.toLowerCase();return!p.startsWith("claude-")||p!==o}
    // Ключ, который шаг читает из тела, в обеих формах один по устройству:
    // canonical(parse(model)) -- на 259 это r = cr(Et(e)), группы 3 и 5.
    // Имя помощника локально для чанка (в образе 259 четыре разных OL),
    // поэтому форма пинится телом целиком, а не именем.
    const hb =
      js.match(
        new RegExp(
          `function ${rxEsc(helper)}\\((${ID})\\)\\{let (${ID})=(${ID})\\(\\1\\);` +
            `return!\\2\\.startsWith\\("claude-"\\)&&!(${ID})\\((${ID})\\(\\2\\)\\)\\}`,
        ),
      ) ||
      js.match(
        new RegExp(
          `function ${rxEsc(helper)}\\((${ID})\\)\\{let (${ID})=(${ID})\\(\\1\\),` +
            `(${ID})=(${ID})\\(\\2\\),(${ID})=(${ID})\\(\\4\\);` +
            `if\\((${ID})\\(\\6\\)\\|\\|\\4!==\\2&&\\8\\(\\7\\(\\2\\)\\)\\)return!1;` +
            `let (${ID})=\\4\\.toLowerCase\\(\\);` +
            `return!\\9\\.startsWith\\("claude-"\\)\\|\\|\\9!==\\6\\}`,
        ),
      );
    if (!hb)
      fail(
        `context-window default: '${helper}()' stands where the claude- test was, ` +
          'but its body is not the canonicalise-and-test shape this step reads the ' +
          'lookup key from',
      );
    parse = hb[3];
    canonical = hb[5];
  }

  // The override belongs at the TOP of this function, not at its bottom.
  // On 2.1.246 the function reads:
  //
  //   function PE(e,t){
  //     if(xe(e))return 1e6;                                  // /\[1m\]/i on the id
  //     if(t?.includes(sr.header)&&Uf(e))return 1e6;
  //     if(Vo(e))return 1e6;
  //     let n=oM(e);if(n!==null)return n;
  //     let r=c.CLAUDE_CODE_MAX_CONTEXT_TOKENS;
  //     if(r!==void 0&&r>0&&!P(X(e)).startsWith("claude-"))return r;
  //     return wE }
  //
  // Appending the lookup to the tail put it BEHIND four earlier returns, so an
  // explicit per-model window was silently ignored for every id those
  // heuristics claim -- including any id carrying the `[1m]` suffix. A value the
  // user wrote down by hand is not a fallback for heuristics; it outranks them.
  //
  // The config read is also guarded now. `k()` is
  //   function k(){if(jn())return m.testGlobalConfig;let e=m.readCache();
  //                if(e)return e;
  //                if(!m.enableSettled)throw Error("Config accessed before allowed.");
  //                return Js(je())}
  // -- it THROWS before the config settles. The stock tail was `return wE`, a
  // path that could not throw; appending a config read introduced one on a
  // function the context accounting calls early. A settle-time read now yields
  // no override rather than an exception, which is the same outcome as having
  // no override configured.
  //
  // The value is type-checked: a hand-written config can hold a string or a
  // negative, and returning that from a token-budget function poisons every
  // arithmetic downstream instead of failing where it was written.
  const headWindow = js.slice(Math.max(0, m.index - 900), m.index);
  const headRx = new RegExp(`function (${ID})\\(${rxEsc(model)},(${ID})\\)\\{`, 'g');
  let headMatch = null;
  for (const h of headWindow.matchAll(headRx)) headMatch = h;
  if (!headMatch) {
    fail(
      'context-window function head not found above its default -- refusing to ' +
        'append the override to the tail, where four earlier returns shadow it',
    );
  }
  const insertAt = m.index - headWindow.length + headMatch.index + headMatch[0].length;

  // Хвост НЕ переписывается. Прежде здесь стояла сборка того же текста из тех
  // же групп в том же порядке -- доказуемый no-op на инлайновой форме. Под
  // форму 2.1.251 та же сборка перестала быть тождеством: она развернула бы
  // вызов ДВУХУСЛОВНОГО помощника обратно в ОДНО инлайновое условие, молча
  // потеряв его второй множитель. Единственная правка этого шага -- вставка в
  // голову функции, и её смещение не зависит от хвоста.

  const prelude =
    `let __ccw;try{__ccw=${cfg}().customModelContextWindows}catch{}` +
    `let __ccv=__ccw?.[${model}]??__ccw?.[${canonical}(${parse}(${model}))];` +
    `if(typeof __ccv==="number"&&__ccv>0)return __ccv;`;
  js = js.slice(0, insertAt) + prelude + js.slice(insertAt);

  applied.push(
    `per-model context window (config key 'customModelContextWindows', ` +
      `override placed at the head of '${headMatch[1]}', config read guarded)`,
  );
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
  // ДВЕ ФОРМЫ ОБЪЯВЛЕНИЯ. До 2.1.248 бандлер заворачивал модуль в ленивый
  // инициализатор, и класс объявлялся присваиванием в заранее объявленную
  // переменную: `<X>=class <X> extends Error{...}`. В 2.1.248 бандл ушёл на
  // настоящие ESM-чанки, и класс стал обычным объявлением:
  // `class <X> extends Error{...}`. Ищем по СООБЩЕНИЮ, а не по
  // минифицированному имени -- оно локально для чанка.
  //
  // Различитель записи -- НЕ строки `__esm`/`__commonJS`: их в нагрузке поровну
  // (измерено на пристинных образах: `__esm` 4 и 4, `__commonJS` 18 и 18 в
  // 2.1.247 и 2.1.248) -- это рантайм bun и вендорный npm внутри него, а не
  // обёртки модулей продукта. Ленивая обёртка 247 выглядит как `w(()=>{<X>=...`.
  // Настоящие различители: `import.meta.require("/$bunfs/root/chunk-` -- 0 в 247
  // и 358 в 248 (193 разных чанка); баррель `имя:()=>X` против `export{X as имя}`;
  // и сама форма объявления класса ниже.
  let clsMatch = js.match(
    new RegExp(
      `(${ID})=class \\1 extends Error\\{constructor\\(\\)\\{` +
        `super\\("OAuth refresh token is no longer valid`,
    ),
  );
  if (!clsMatch) {
    clsMatch = js.match(
      new RegExp(
        `class (${ID}) extends Error\\{constructor\\(\\)\\{` +
          `super\\("OAuth refresh token is no longer valid`,
      ),
    );
  }
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
  //
  //     Anchored on the depth-cap neighbourhood that follows
  //     (`<n>=<f>(<l>.agentContext)`), not on the shape alone: the image holds
  //     about thirty other `()?void 0:` sites and the bare shape does not tell
  //     them apart.
  //
  //     The suppression itself is OPTIONAL in the pattern because from 2.1.242
  //     the product no longer does it — the site already reads `<model>=<arg>`.
  //     Making it optional turns that into a match, so the leg becomes a no-op
  //     exactly where there is nothing left to remove, while an ABSENT site
  //     still fails. Dropping the leg outright would instead leave 2.1.241 and
  //     earlier silently unpatched.
  const coord = new RegExp(
    `(let ${ID}=Date\\.now\\(\\),${ID}=)(?:${ID}\\(\\)\\?void 0:)?(${ID},${ID}=${ID}\\(${ID}\\.agentContext\\))`,
  );
  let coordNote;
  if (coord.test(js)) {
    js = js.replace(coord, `$1$2`);
    coordNote = 'coordinator suppression removed';
  } else {
    // 2.1.248 ПЕРЕПИСАЛ этот участок, и подавление там больше не безусловное:
    //   async call({prompt:<p>,subagent_type:<t>,...,model:<m>,...},<ctx>,...){
    //     let <n>=Date.now();
    //     if(<isCoordinator>()&&<ns>.CLAUDE_CODE_COORDINATOR_FORCE_WORKER_INHERIT_MODEL)<m>=void 0;
    //     let <b>=<m>,<j>=<f>(<ctx>.agentContext),...
    // То есть выбранная модель гасится ТОЛЬКО при явно выставленной переменной
    // окружения -- по умолчанию диспатч уже волен выбирать модель, ради чего
    // эта нога и существовала. Удалять env-ветку мы не имеем оснований: это
    // ручка пользователя, а не дефект, и её снятие отняло бы у координаторских
    // сессий заявленное поведение.
    //
    // Но проверка участка остаётся ОБЯЗАТЕЛЬНОЙ: если завтра подавление снова
    // станет безусловным, а якорь будет удалён «за ненадобностью», патч
    // промолчит и образ уедет с погашенной моделью. Поэтому здесь -- утверждение
    // присутствия: участок обязан существовать в одной из двух форм.
    // Two spellings of one site. Through 2.1.259 the timestamp opened its own
    // declaration (`let U=Date.now();`) and exactly one binding stood between
    // the suppression and the depth read. On 2.1.261 the handler destructures
    // in the BODY, so the timestamp joined that declaration as a later clause
    // (`,U=Date.now();`) and the aliases the old signature used to bind now sit
    // in the chain too. Neither is a semantic change, and neither may be
    // pinned: the assertion is about the suppression EXISTING, so it must not
    // fail on the punctuation around it.
    const coord248 = new RegExp(
      `(?:let |,)${ID}=Date\\.now\\(\\);if\\(${ID}\\(\\)&&${ID}\\.` +
        `CLAUDE_CODE_COORDINATOR_FORCE_WORKER_INHERIT_MODEL\\)(${ID})=void 0;` +
        `let ${ID}=\\1,(?:${ID}=${ID},)*${ID}=${ID}\\(${ID}\\.agentContext\\)`,
    );
    if (!coord248.test(js)) fail('coordinator-mode model suppression site not found');
    // Ветка ничего не вырезала -- и строка журнала обязана это сказать. Прежде
    // журнал печатал «coordinator suppression removed» на обеих ветках, то есть
    // на 2.1.248 сообщал о правке, которой не было.
    coordNote = 'coordinator suppression is env-gated upstream, left alone';
  }

  // (b) the fork flag is whatever the launch telemetry reports as is_fork
  const forkMatch = js.match(new RegExp(`is_fork:(${ID}),`));
  if (!forkMatch) fail('fork flag not found (is_fork telemetry)');
  const fork = forkMatch[1];

  // Every `<fork>?void 0:<x>` is one place where a value is thrown away FOR
  // BEING A FORK, which is precisely the defect this patch removes, so they
  // are cleared as a class instead of one bespoke locator per site. The sites
  // are not stable across releases: 2.1.239 has two (the model resolution and
  // the launch options), 2.1.245 has three, because the resolution was split
  // into a lambda plus a second direct call after the plugin hook may replace
  // the model, and the launch options now read the variable that call
  // produces. Chasing each shape separately is what broke here; clearing the
  // class does not care how the calls are arranged.
  //
  // The bounds are the honesty check: an image that reshaped these sites out
  // of existence, or grew a crop of unrelated ones, fails loudly rather than
  // being silently half-patched. The lookbehind keeps `<fork>` from matching
  // the tail of a longer minified name.
  //
  // A CLASS SWEEP NEEDS A BOUNDARY, and the module was not one. Before 2.1.242
  // the bundle is a single module, so `moduleSliceAround` returns the whole
  // image and the sweep ran over ~27 MB looking for a one- or two-letter
  // minified name. On 2.1.233 the fork flag minifies to `L`, and 4.97 MB away
  // from the anchor sits
  //
  //   M=await P(k?{kind:"skip"}:{kind:"default"},O||L?void 0:process.env.ANTHROPIC_VERTEX_PROJECT_ID)
  //
  // where `L` is GOOGLE_APPLICATION_CREDENTIALS -- a different local that
  // happens to share the letter. The sweep took `L?void 0:` out of it, and the
  // count bound (2..6) accepted 3, so the build went out 79/79 green with
  // Vertex project resolution quietly altered: a set GCLOUD_PROJECT became the
  // project id, and a credentials-only setup started passing
  // ANTHROPIC_VERTEX_PROJECT_ID where the product passes nothing.
  //
  // So the boundary is now the ANCHOR's neighbourhood, intersected with the
  // module. Measured distance from `is_fork:` to the real drop sites:
  // 2.1.233 -422 / +3180, 2.1.240 -460 / +3576, 2.1.242 -1053..-478,
  // 2.1.246 -1123..-477. A radius of 20000 covers every one with room to
  // spare and is 250x smaller than the miss it excludes. A build that moves a
  // drop site outside this radius fails the count bound loudly, which is the
  // outcome to want: this sweep must never again be free to roam.
  // `|` and `&` join the exclusion, and that is what the radius was standing in
  // for. Where the flag is the RIGHT operand of someone else's condition the
  // drop is not ours: `O||L?void 0:process.env.ANTHROPIC_VERTEX_PROJECT_ID` on
  // 233 (`L` is GOOGLE_APPLICATION_CREDENTIALS there) and `ae||A?void 0:u` in
  // yoga-layout on 247. Measured on 233/240/242/243/245/246/247: with this
  // exclusion there is not ONE hit outside the radius on any version, while
  // without it there are exactly those two. So the radius stopped being the
  // thing that tells ours from theirs, which it was never able to do -- it
  // only measured distance -- and became a bound the sweep must stay inside.
  // ДВЕ формы подавления, не одна. 2.1.251 оставил все три участка на прежних
  // местах (-1167 / -1060 / -503 от якоря, тот же диапазон, что 2.1.245-247), но
  // переодел два из них: `<fork>?void 0:<model>` стал `<fork>?"inherit":<model>`.
  // "inherit" -- сентинел самого продукта: третий параметр q0() с этим значением
  // означает «взять модель родителя», то есть ровно тот отъём выбора, который
  // этот свип и снимает. Свип по одной старой форме прошёл бы зелёным, оставив
  // форку принудительное наследование по ОБЕИМ дорогам резолва (лямбда и прямой
  // вызов после плагин-хука) -- патч отчитался бы о работе, которой не сделал.
  // Нижняя граница 2 поймала это; она здесь не формальность.
  const droppedRx = new RegExp(
    `(?<![$\\w|&])${rxEsc(fork)}\\?(?:void 0|"inherit"):(${ID})`,
    'g',
  );
  const anchorIdx = js.search(new RegExp(`is_fork:${rxEsc(fork)},`));
  if (anchorIdx < 0) fail('fork telemetry anchor vanished between match and sweep');
  const [mStart, mEnd] = moduleSliceAround(js, anchorIdx);
  const SWEEP_RADIUS = 20000;
  const lo = Math.max(mStart, anchorIdx - SWEEP_RADIUS);
  const hi = Math.min(mEnd, anchorIdx + SWEEP_RADIUS);
  // A real drop that moved out of the radius was invisible to BOTH sides: the
  // patcher still counted >=2 inside and the check only ever looked inside, so
  // the guarantee would be gone with the build green. The module is scanned
  // whole and anything outside the window stops the build.
  const strays = [...js.slice(mStart, mEnd).matchAll(new RegExp(droppedRx.source, 'g'))]
    .filter((mm) => mm.index + mStart < lo || mm.index + mStart >= hi);
  if (strays.length > 0) {
    fail(
      `fork value-drop outside the sweep radius: ${strays.length} site(s) — ` +
        'a drop moved away from the is_fork anchor',
    );
  }
  let body = js.slice(lo, hi);
  const droppedAll = [...body.matchAll(new RegExp(droppedRx.source, 'g'))];
  // 2..4, not 2..6. Measured: 2 on 233/240, 3 on 242..259, 4 from 2.1.260 (the
  // boundary is 260, not 261 -- counted on both platforms over the whole
  // corpus). The upper bound is raised by ONE and only after reading all four:
  // 2.1.259 carries a single spawn descriptor
  //
  //   In={tool_use_id:…,subagentType:<a>.agentType,model:<fork>?void 0:<m>,
  //       parentModel:<p>,permissionMode:<pm>,background:<bg>,fork:<fork>,…}
  //
  // and 2.1.260 SPLIT it in two -- one object keeping parentModel/permissionMode,
  // the other built inside a thunk (`let <C>=()=>…({…,subagentType:<a>.agentType,
  // model:<fork>?void 0:<m>,background:<bg>,cwd:<cwd>})`). One site became two of
  // the same class; no new class appeared. Leaving the bound at 3 would have been
  // right only if the fourth were foreign -- it is not, and leaving that site
  // unswept would have kept the fork's model discarded on that path while the
  // patch reported the drop removed.
  //
  // The bound still has to stay TIGHT: free slots inside a 20 KB window are how
  // a same-letter site that is not a fork drop gets rewritten and counted as one,
  // which is how Vertex resolution was altered on 233 with 79/79 green.
  if (droppedAll.length < 2 || droppedAll.length > 4)
    fail(`fork value-drop sites: expected 2..4, found ${droppedAll.length}`);
  // The one that matters by name. A build where `model:` is no longer among the
  // dropped fields has stopped doing the thing this sweep exists for, and a
  // count alone cannot notice that.
  if (!droppedAll.some((mm) => body.slice(Math.max(0, mm.index - 6), mm.index) === 'model:'))
    fail('fork value-drop sites: the dispatch model is not among them');
  body = body.replace(droppedRx, '$1');
  if (new RegExp(`(?<![$\\w])${rxEsc(fork)}\\?(?:void 0|"inherit"):`).test(body))
    fail('fork value-drop sites survived the sweep');
  // Третья форма сентинела, если она появится, обязана остановить сборку, а не
  // проехать молча. В окне свипа у флага форка есть и законные условные --
  // `<fork>?{systemPrompt:...}`, `<fork>?<ident>:<ident>` -- это ветвление
  // поведения форка, а не отъём значения. Отличает их правая часть: подавление
  // записывается ЛИТЕРАЛОМ (`void 0` или строка-сентинел). Замерено на 251: в
  // окне +-20000 нет ни одного `<fork>?"..."`, кроме двух снятых выше.
  if (new RegExp(`(?<![$\\w|&])${rxEsc(fork)}\\?"`).test(body))
    fail('fork value-drop: an unknown string sentinel sits beside the swept sites');
  js = js.slice(0, lo) + body + js.slice(hi);

  // (c) schema: add the two fields next to the existing `model`
  //
  // 2.1.257 ВЫНЕС строки схемы Agent-tool в именованные константы:
  //   var yt="Agent",bnr="Launch a new agent...",Tnr="The task for the agent to perform",
  //       wnr="A short (3-5 word) description of the task",...
  //   ...description:i().describe(wnr),prompt:i().describe(Tnr),...
  // Прежний пин ждал ЛИТЕРАЛ прямо в вызове describe и на 257 не находил
  // ничего -- шаг падал, а вместе с ним каскадом падал шаг 22.
  //
  // Поэтому аргумент describe допускается в двух видах: сам литерал (сборки
  // до 257) ЛИБО имя, про которое В ЭТОМ ЖЕ образе ДОКАЗАНО объявлением, что
  // оно держит ровно этот текст. Голый `<ID>` без такого доказательства сюда
  // не годится: он принял бы любую строку и якорь перестал бы утверждать, что
  // правится схема ИМЕННО этого инструмента. Имена минифицированы и локальны
  // для чанка, поэтому одного имени мало -- участок дополнительно связан
  // обратной ссылкой: описание и prompt обязаны строиться ОДНИМ И ТЕМ ЖЕ
  // строителем, как это и выглядит в обеих сборках.
  //
  // Замерено: на 252 совпадение одно и строитель `i`, константы нет вовсе; на
  // 257 совпадение одно, строитель `i`, константа `wnr`. Ровно одно совпадение
  // -- это и есть граница: второй участок той же формы означал бы, что рядом
  // появилась схема другого инструмента, и вставка полей могла бы уехать в неё.
  const strConstNames = [
    ...js.matchAll(
      new RegExp(`(?<![$\\w])(${ID})="A short \\(3-5 word\\) description of the task"`, 'g'),
    ),
  ].map((mm) => rxEsc(mm[1]));
  const strFnRx = new RegExp(
    `description:(${ID})\\(\\)\\.describe\\(` +
      `(?:"A short \\(3-5 word\\)[^"]*"${strConstNames.map((n) => `|${n}`).join('')})` +
      `\\),prompt:\\1\\(\\)\\.describe\\(`,
  );
  const strFnAll = [...js.matchAll(new RegExp(strFnRx.source, 'g'))];
  if (strFnAll.length !== 1)
    fail(
      `schema string builder: expected exactly 1 site, found ${strFnAll.length}` +
        ` (describe holds the literal or one of: ${strConstNames.join(',') || 'no hoisted constant'})`,
    );
  const str = strFnAll[0][1];
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
  //
  // WHAT IS PINNED HERE IS THE BINDING, NOT WHERE IT SITS.
  //
  // This locator used to carry one regex per observed SHAPE of the handler's
  // head, and every build that moved the head cost a release: through 2.1.259
  // the binding lived in the PARAMETER LIST
  // (`async call({prompt:e,subagent_type:n,…},C,I,F,B){`); 2.1.261 took the
  // object whole and destructured in the body
  // (`async call(e,t,r,o,d){let{subagent_type:p,…}=e,…`); 2.1.270 dropped the
  // method altogether for a free function with named parameters
  // (`async function <id>({agentInput:e,toolUseContext:n,…}){let{subagent_type:m,…}=e,…`).
  // Three shapes, one meaning — and the third one broke both regexes at once
  // (root task #75, the seventh case).
  //
  // The durable fact underneath all three is the OBJECT PATTERN that binds the
  // tool's own input fields. It is found by what it binds, not by what precedes
  // it: an object with no nested braces that binds BOTH `subagent_type` and
  // `run_in_background`, every one of whose pairs is `key:identifier`.
  //
  // The bare-identifier test is the whole discriminator. From 2.1.260 the image
  // also CONSTRUCTS such an object —
  //   {...e,prompt:n.prompt,…,subagent_type:n.subagentType,…,run_in_background:n.background,…}
  // — and a locator reading only the two key names would have had two
  // candidates to choose between. In a pattern the values are BINDINGS (bare
  // identifiers); in a construction they are expressions. That is a difference
  // of kind, not of spelling.
  //
  // Census by the controller over 22 payloads, 2.1.233…2.1.270 (21 corpus
  // images plus 2.1.270): EXACTLY ONE pattern on every one of them, with the
  // construction present from 260 on and correctly rejected each time.
  //
  // The field is added INSIDE the pattern on all three shapes, so the binding
  // happens wherever that build binds the rest — which is the entire contract
  // the rest of this patch, and patch 22, depend on.
  const inputPatterns = () => {
    const out = [];
    const rx = /\{[^{}]{0,800}?\}/g;
    for (let mm; (mm = rx.exec(js)); ) {
      const t = mm[0];
      if (!t.includes('subagent_type:') || !t.includes('run_in_background:')) continue;
      const pairs = t.slice(1, -1).split(',');
      if (!pairs.every((p) => /^[$\w]+:[$\w]+$/.test(p.trim()))) continue;
      out.push({ at: mm.index, text: t });
    }
    return out;
  };
  const pats = inputPatterns();
  if (pats.length === 0) {
    fail(
      'agent tool input pattern not found — no brace-free object binds both ' +
        'subagent_type and run_in_background to bare identifiers',
    );
  }
  if (pats.length !== 1) {
    fail(`agent tool input pattern is not unique (${pats.length} candidates)`);
  }
  // Both names are checked here, before EITHER is written: `__ccEffort` is
  // inserted a few lines below, and a later `includes('__ccE…')` test would
  // then match its own prefix and refuse on a clean build.
  if (js.includes('__ccEffort')) fail('__ccEffort already present — refusing to shadow it');
  if (js.includes('__ccLvl')) fail('__ccLvl already present — refusing to shadow it');
  const pat = pats[0];
  js =
    js.slice(0, pat.at) +
    `${pat.text.slice(0, -1)},effort:__ccEffort}` +
    js.slice(pat.at + pat.text.length);

  // (c) attach it to the definition handed to the launch — the field the
  //     runtime turns into an effort permission layer.
  //     The `=` is load-bearing: the CALLEE destructures its parameters with
  //     the very same shape (`function*<run>({agentDefinition:<e>,promptMessages:…`)
  //     and substituting a conditional there is a syntax error, not a no-op.
  //     Anchoring on the assignment picks the caller's object literal.
  const defRx = new RegExp(`(=\\{agentDefinition:)(${ID})(,promptMessages:)`);
  if (!defRx.test(js)) fail('launch agentDefinition site not found');
  // The schema field is a free string, so whatever the model types arrives here
  // verbatim and used to be attached to the definition unchecked -- an
  // unvalidated model-supplied value reaching an internal effort layer.
  //
  // The vocabulary is the product's own, read off 2.1.246:
  //   R  = ["low","medium","high","xhigh","max"]
  //   ze = {med:"medium"}        <- aliases the product itself normalises
  //   Xe = {ultracode:"xhigh"}
  // Those aliases are accepted and folded here rather than rejected, because
  // the product accepts them everywhere else; anything outside the vocabulary
  // is dropped, which lands the dispatch on the definition's own effort exactly
  // as if none had been passed.
  //
  // The comparison is done the way the product does it, not the way this list
  // happens to be spelled. Its own string parser is
  //   Wt(e){let t=e.trim().toLowerCase(),n=ze[t]??t;return x(n)?n:void 0}
  // -- trim and case-fold FIRST, alias second, membership last. An exact-match
  // test against the raw value was stricter than every other surface of the
  // product: `"Medium"`, `"HIGH"` or a stray leading space were dropped here
  // and accepted everywhere else, and a dropped effort is silent -- the
  // dispatch simply lands on the definition's default. `ultracode` is folded
  // too, from the product's second alias table; `Wt` itself does not know it,
  // but the vocabulary is one vocabulary.
  //
  // Numeric efforts belong to the OTHER parser (`ae`, which parseInts and
  // range-checks). This field is declared a string, so a number is outside its
  // domain rather than a case it drops -- not an omission.
  //
  // The field TYPE is deliberately left a string. Swapping it for an enum
  // schema would reject a bad value more loudly, but a wrong guess about which
  // local is the enum builder hard-fails the whole Agent tool, and this list is
  // duplicated from the image rather than shared with it. Dropping is the
  // failure mode that cannot take the tool down with it.
  const EFFORTS = '["low","medium","high","xhigh","max"]';
  js = js.replace(
    defRx,
    `$1((()=>{let __ccRaw=typeof __ccEffort==="string"?__ccEffort.trim().toLowerCase():__ccEffort;` +
      `let __ccLvl=__ccRaw==="med"?"medium":__ccRaw==="ultracode"?"xhigh":__ccRaw;` +
      `return __ccLvl&&${EFFORTS}.includes(__ccLvl)?{...$2,effort:__ccLvl}:$2})())$3`,
  );

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
    `dispatch model+effort (fork flag '${fork}', ${coordNote}, ` +
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

  // ДВЕ ФОРМЫ ЭКСПОРТА. До 2.1.248 -- баррель бандлера
  // (`isCoordinatorMode:()=><local>`); в 2.1.248 -- настоящее ESM-предложение
  // (`export{...,<local> as isCoordinatorMode,...}`). Нам нужно ЛОКАЛЬНОЕ имя,
  // и обе формы его дают; грепать по всему образу нельзя -- минифицированные
  // имена локальны для чанка, поэтому привязка берётся из самого экспорта.
  let exportMatch = js.match(new RegExp(`isCoordinatorMode:\\(\\)=>(${ID})`));
  if (!exportMatch) exportMatch = js.match(new RegExp(`(${ID}) as isCoordinatorMode`));
  if (!exportMatch) fail('isCoordinatorMode export not found');
  const isCoordinator = exportMatch[1];

  // ЦЕПОЧКА ЧАНКОВ (2.1.248). Раньше экспорт, предикат и гейт лежали в одном
  // модуле, и области видимости хватало. В 2.1.248 бандл разложен на ~193
  // ESM-чанка, и экспорт стоит в чанке-ФАСАДЕ: он лишь импортирует имя из
  // соседнего чанка и переэкспортирует его
  // (`import{W3,...}from"...chunk-q9dprqyd.js";export{...,W3 as isCoordinatorMode}`).
  // Определение предиката при этом лежит в 16 МБ от экспорта. Имя локально для
  // чанка -- в нагрузке три РАЗНЫХ `function js(){...}`, -- поэтому связывать
  // по имени глобально нельзя: определяющим считается только тот чанк, который
  // это имя ЭКСПОРТИРУЕТ, и таких обязан быть ровно один.
  let anchor13 = exportMatch.index;
  let scope13 = moduleTextAt(anchor13);

  const aliasRx = new RegExp(`function ${rxEsc(isCoordinator)}\\(\\)\\{return (${ID})\\(\\)\\}`);
  let aliasMatch = scope13.match(aliasRx);
  if (!aliasMatch) {
    const owners = [...js.matchAll(new RegExp(aliasRx.source, 'g'))].filter(hit =>
      new RegExp(
        `export\\{[^}]*(?<![$\\w])${rxEsc(isCoordinator)}(?![$\\w])[^}]*\\}`,
      ).test(moduleTextAt(hit.index)),
    );
    if (owners.length !== 1) {
      fail(
        `coordinator predicate ${isCoordinator}() is not a plain alias ` +
          `(модулей, экспортирующих это имя вместе с определением: ${owners.length})`,
      );
    }
    anchor13 = owners[0].index;
    scope13 = moduleTextAt(anchor13);
    aliasMatch = scope13.match(aliasRx);
  }
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
  // Гейт тоже может жить в СВОЁМ чанке (2.1.248: предикат в одном, гейт в
  // другом, помощник в третьем). Ищем его по ФОРМЕ, а не по имени, и требуем
  // ровно одно совпадение на всю нагрузку: имя `gate` уже вшито в форму через
  // rxEsc, так что найденное совпадение привязано к предикату, а единственность
  // не даёт спутать его с одноимённой функцией другого чанка.
  let anchorGate = anchor13;
  let gateMatch = scope13.match(gateRx);
  if (!gateMatch) {
    const found = [...js.matchAll(new RegExp(gateRx.source, 'g'))];
    if (found.length !== 1) {
      fail(`coordinator interactive veto not found (совпадений формы: ${found.length})`);
    }
    anchorGate = found[0].index;
    gateMatch = found[0];
  }
  const envTruthy = gateMatch[2];
  editModuleAt(anchorGate, body =>
    body.replace(
      gateRx,
      `$1&&!${repEsc(envTruthy)}(process.env.CLAUDE_CODE_COORDINATOR_INTERACTIVE)$3`,
    ),
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
//     to match resumed session." and silently undoing #13's opt-in. All five
//     call sites funnel through that one function, and it returns a message
//     ONLY when it actually flipped the mode, so returning early from it is the
//     whole behaviour change: no mode flip, no message.
//
//     Four of the five do more than surface that message, and an earlier
//     version of this comment claimed otherwise. Measured on pristine 2.1.246:
//     five call sites, and the two print-path ones, the interactive resume and
//     the picker each also rebuild `agentDefinitions` from a fresh load inside
//     the same `if(returned)`; only the `modeApi?.matchSessionMode` site does
//     nothing but push the warning. That reload exists to re-sync the agent set
//     with the mode the flip just imposed. With no flip there is nothing to
//     re-sync — the definitions loaded at startup already match the process's
//     own mode — so skipping it is part of the same single behaviour change
//     rather than a side effect of it.
//
//     What the session FILE ends up holding differs by entry point, and only
//     the interactive ones rewrite it. `saveMode(isCoordinatorMode()
//     ?"coordinator":"normal")` has three call sites on 2.1.246 — /clear, the
//     interactive resume and the picker — so there the record is rewritten from
//     the LIVE predicate and ends up agreeing with the process. The print path
//     (`-p --resume`) has NO mode writer: its window holds neither a `saveMode`
//     call nor a `type:"mode"` write, so the recorded mode stays as it was.
//     (The same earlier comment named `eHt(...)` as that writer; in 2.1.246
//     `eHt` is `dirname` imported from `path` — a directory walk, unrelated.)
//     Leaving it stale is the deliberate half: the key declares the ENVIRONMENT
//     authoritative for this run only, and a later resume without the key is
//     meant to fall back to the session's own record.
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

  // ДВЕ ФОРМЫ ЭКСПОРТА. До 2.1.248 -- баррель бандлера
  // (`isCoordinatorMode:()=><local>`); в 2.1.248 -- настоящее ESM-предложение
  // (`export{...,<local> as isCoordinatorMode,...}`). Нам нужно ЛОКАЛЬНОЕ имя,
  // и обе формы его дают; грепать по всему образу нельзя -- минифицированные
  // имена локальны для чанка, поэтому привязка берётся из самого экспорта.
  let exportMatch = js.match(new RegExp(`isCoordinatorMode:\\(\\)=>(${ID})`));
  if (!exportMatch) exportMatch = js.match(new RegExp(`(${ID}) as isCoordinatorMode`));
  if (!exportMatch) fail('isCoordinatorMode export not found');
  const isCoordinator = exportMatch[1];

  // Обе формы экспорта, как и у предиката выше: баррель бандлера до 2.1.248 и
  // ESM-предложение начиная с неё.
  let matcherMatch = js.match(new RegExp(`matchSessionMode:\\(\\)=>(${ID})`));
  if (!matcherMatch) matcherMatch = js.match(new RegExp(`(${ID}) as matchSessionMode`));
  if (!matcherMatch) fail('matchSessionMode export not found');
  const matcher = matcherMatch[1];

  // Как и в шаге 13: экспорт может стоять в чанке-фасаде, а определение -- в
  // том чанке, который это имя экспортирует. Правим именно его.
  let anchor14 = matcherMatch.index;
  let scope14 = moduleTextAt(anchor14);
  if (!new RegExp(`function ${rxEsc(matcher)}\\(`).test(scope14)) {
    const defs = [...js.matchAll(new RegExp(`function ${rxEsc(matcher)}\\(`, 'g'))].filter(hit =>
      new RegExp(`export\\{[^}]*(?<![$\\w])${rxEsc(matcher)}(?![$\\w])[^}]*\\}`).test(
        moduleTextAt(hit.index),
      ),
    );
    if (defs.length !== 1) {
      fail(
        `resume mode matcher ${matcher}() is not defined in a module that exports it ` +
          `(кандидатов: ${defs.length})`,
      );
    }
    anchor14 = defs[0].index;
    scope14 = moduleTextAt(anchor14);
  }

  // The same env-truthy helper as #13, re-derived from the gate rather than
  // handed over between steps: this must not depend on step order, and the
  // prefix it is captured from is untouched by #13's own edit.
  //
  // Captured from the module the call is injected INTO, not from the whole
  // image. A minified name is scoped to its chunk, so a helper found first
  // somewhere else would be spliced in here as letters that mean something
  // different -- or nothing -- at this site.
  //
  // Где эти места лежат -- зависит от версии, и предполагать нельзя ничего.
  // На 233/240 модуль вообще один. На 242..247 предикат, матчер и помощник
  // соседи в одном модуле, и вызов по имени законен. На 248 их четыре разных
  // места: помощник в своём чанке, гейт в другом, определения предиката и
  // матчера в третьем, фасад с реэкспортом -- в 16 МБ от них. Поэтому поиск
  // помощника ограничен модулем вставки, и его ОТСУТСТВИЕ там -- не отказ, а
  // переход на вторую ветку ниже.
  const helperMatch = scope14.match(
    new RegExp(`\\{if\\(!(${ID})\\(process\\.env\\.CLAUDE_CODE_COORDINATOR_MODE\\)\\)return!1;`),
  );
  // Выражение, которым проверяется наша переменная. Если помощник виден в этом
  // же чанке -- зовём его по имени, как раньше.
  let force;
  if (helperMatch) {
    force = `${repEsc(helperMatch[1])}(process.env.CLAUDE_CODE_COORDINATOR_FORCE)`;
  } else {
    // 2.1.248: помощник живёт в СВОЁМ чанке и в чанк матчера не импортируется
    // (проверено: среди 45 его импортов чанка-помощника нет). Вписать туда имя
    // из чужого чанка нельзя -- оно там не разрешится, и это ровно тот случай,
    // от которого предупреждает отказ выше.
    //
    // Поэтому подставляется ЕГО ЖЕ ТЕЛО, дословно: помощник ищется по форме,
    // форма обязана быть единственной на всю нагрузку (измерено: по одному
    // вхождению и в 2.1.247, и в 2.1.248), и найденный текст функции целиком
    // становится вызываемым на месте выражением -- у него снимается только имя,
    // чтобы ничего не затенять. Прежняя редакция вписывала ПЕРЕСКАЗ с тем же
    // списком значений, и одна ветка продукта (`typeof === "boolean"`) в нём
    // отсутствовала: на аргументе из process.env она недостижима, но текст
    // расходился с телом, о котором говорил этот же комментарий. Если апстрим
    // изменит помощника, форма перестанет совпадать и патч откажет вслух, а не
    // разойдётся с продуктом молча.
    const truthyRx = new RegExp(
      `function (${ID})\\((${ID})\\)\\{if\\(!\\2\\)return!1;` +
        `if\\(typeof \\2==="boolean"\\)return \\2;` +
        `let (${ID})=String\\(\\2\\)\\.toLowerCase\\(\\)\\.trim\\(\\);` +
        `return\\["1","true","yes","on"\\]\\.includes\\(\\3\\)\\}`,
      'g',
    );
    const truthy = [...js.matchAll(truthyRx)];
    if (truthy.length !== 1) {
      fail(
        'coordinator env-truthy helper: ожидалась ровно одна функция известной формы, ' +
          `найдено ${truthy.length} — отказываюсь вписывать семантику, которую не опознал`,
      );
    }
    // Имя снимается, тело остаётся байт в байт. `repEsc` обязателен: текст
    // уходит в строку замены `String.replace`, где `$` -- управляющий символ, а
    // в минифицированных именах он законен.
    const helperText = truthy[0][0];
    const anon = helperText.replace(/^function\s+[A-Za-z_$][\w$]*/, 'function ');
    if (anon === helperText) {
      fail('coordinator env-truthy helper: не снять имя с найденной функции');
    }
    force = `(${repEsc(anon)})(process.env.CLAUDE_CODE_COORDINATOR_FORCE)`;
  }

  // Anchored on the shape, not on the message literals: the guard, the live
  // read of the predicate and the "coordinator" comparison identify the
  // function even if the wording of the warnings changes.
  const matcherRx = new RegExp(
    `(function ${rxEsc(matcher)}\\((${ID})\\)\\{if\\(!\\2\\)return;)` +
      `(let ${ID}=${rxEsc(isCoordinator)}\\(\\),${ID}=\\2==="coordinator";)`,
  );
  if (!matcherRx.test(scope14)) {
    fail(`resume mode matcher ${matcher}() does not have the expected shape`);
  }
  editModuleAt(anchor14, body => body.replace(matcherRx, `$1if(${force})return;$3`));

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

  // Two shapes, because 2.1.242 rewrote the effect.
  //
  // OLD (<= 2.1.241) — the deadlock described above, in full:
  //   ...&&<mode>!=="search",<head>=8+(<chips>?1:0),<pad>=2,
  //      <rows>=Math.max(1,Math.floor((<height>-<head>-<pad>)/3));
  //   if(<React>.useEffect(()=>{if(!<more>)return;let <slack>=<rows>*2;
  //        if(<focus>+<slack>>=<filtered>.length)<more>(<rows>*3)},
  //        [<focus>,<rows>,<filtered>.length,<more>]),
  //      <logs>.length===0&&!<loading>)return null;
  //
  // NEW (>= 2.1.242) — upstream closed the deadlock the same way this patch
  // did, by adding the LOADED length to the dependencies, and then bounded the
  // scan: a ref counts consecutive requests that brought no new match and the
  // effect gives up after five. The counter resets whenever the focus or the
  // filtered length moves, so a steady trickle of matches keeps it going; what
  // still fails is the case this patch exists for — one session sitting more
  // than five fruitless pages deep, which the search reports as "no results"
  // while the file is on disk.
  //
  // So the edit is no longer "add the growth signal" (upstream has it) but
  // "do not let the give-up counter stop a scan the user explicitly asked
  // for". Outside search mode the cap is left exactly as upstream wrote it.
  // Termination is unchanged and does not rely on the counter: onRequestMore
  // returns immediately once it reaches the end of the file list, so the
  // loaded length stops changing, no dependency moves, and the effect stops.
  const rxNew = new RegExp(
    `&&(${ID})!=="search",(${ID})=8\\+\\((${ID})\\?1:0\\),(${ID})=2,` +
      `(${ID})=Math\\.max\\(1,Math\\.floor\\(\\((${ID})-\\2-\\4\\)/3\\)\\),` +
      `(${ID})=(${ID})\\.length,(${ID})=(${ID})\\(\\{focusedIndex:-1,visible:-1,empty:0\\}\\);` +
      `if\\((${ID})\\(\\(\\)=>\\{if\\(!(${ID})\\)return;let (${ID})=\\9\\.current;` +
      `if\\(\\13\\.focusedIndex!==(${ID})\\|\\|\\13\\.visible!==(${ID})\\.length\\)` +
      `\\9\\.current=\\{focusedIndex:\\14,visible:\\15\\.length,empty:0\\};` +
      `let (${ID})=\\5\\*2;` +
      `if\\(\\14\\+\\16>=\\15\\.length&&\\9\\.current\\.empty<(${ID})\\)` +
      `\\9\\.current\\.empty\\+\\+,\\12\\(\\5\\*3\\)\\},` +
      `\\[\\14,\\5,\\15\\.length,\\7,\\12\\]\\),\\8\\.length===0&&!(${ID})\\)return null;`,
  );
  const mNew = js.match(rxNew);
  if (mNew) {
    js = js.replace(
      rxNew,
      '&&$1!=="search",$2=8+($3?1:0),$4=2,' +
        '$5=Math.max(1,Math.floor(($6-$2-$4)/3)),' +
        '$7=$8.length,$9=$10({focusedIndex:-1,visible:-1,empty:0});' +
        'if($11(()=>{if(!$12)return;let $13=$9.current;' +
        'if($13.focusedIndex!==$14||$13.visible!==$15.length)' +
        '$9.current={focusedIndex:$14,visible:$15.length,empty:0};' +
        'let $16=$5*2;' +
        'if($1==="search"||($14+$16>=$15.length&&$9.current.empty<$17))' +
        '$9.current.empty++,$12($5*3)},' +
        '[$14,$5,$15.length,$7,$12,$1]),$8.length===0&&!$18)return null;',
    );
    applied.push(
      `/resume search loads the sessions it has not read yet, past the ` +
        `give-up counter (mode var '${mNew[1]}', filtered list '${mNew[15]}', ` +
        `loaded list '${mNew[8]}', cap '${mNew[17]}', +${js.length - before} bytes)`,
    );
    return;
  }

  const rxOld = new RegExp(
    `&&(${ID})!=="search",(${ID})=8\\+\\((${ID})\\?1:0\\),(${ID})=2,` +
      `(${ID})=Math\\.max\\(1,Math\\.floor\\(\\((${ID})-\\2-\\4\\)/3\\)\\);` +
      `if\\((${ID})\\.useEffect\\(\\(\\)=>\\{if\\(!(${ID})\\)return;let (${ID})=\\5\\*2;` +
      `if\\((${ID})\\+\\9>=(${ID})\\.length\\)\\8\\(\\5\\*3\\)\\},` +
      `\\[\\10,\\5,\\11\\.length,\\8\\]\\),(${ID})\\.length===0&&!(${ID})\\)return null;`,
  );
  const m = js.match(rxOld);
  if (!m) fail('/resume auto-load-more effect not found (neither shape)');

  js = js.replace(
    rxOld,
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
  const MULTI_OPS = ['>>>=', '===', '!==', '**=', '<<=', '>>=', '&&=', '||=', '??=', '>>>', '=>', '&&', '||', '??', '==', '!=', '+=', '-=', '*=', '%=', '&=', '|=', '^=', '<=', '>=', '<<', '>>', '**', '?.'];
  const REGEX_PUNCT = new Set(['(', ',', '=', ':', '[', '!', '&', '|', '?', '{', ';', '+', '-', '*', '%', '<', '>', '~', '^']);
  const REGEX_KW = new Set(['return', 'typeof', 'case', 'do', 'else', 'in', 'of', 'new', 'delete', 'void', 'throw', 'instanceof', 'yield', 'await']);
  const HEADER_KW = new Set(['if', 'while', 'for', 'with', 'catch', 'switch']);
  const STMT_KW = new Set(['else', 'do', 'try', 'finally']);
  const lexModule = (text) => {
    const tokens = [];
    const spans = [];
    const events = [];
    let i = 0;
    const n = text.length;
    let mode = 'code';
    let brace = 0;
    const parenStack = [];
    const interpStack = [];
    const braceStack = [];
    let spanStart = 0;
    let spanMode = 'code';
    const mark = (nextMode) => {
      if (nextMode !== spanMode) {
        if (i > spanStart) spans.push({ start: spanStart, end: i, mode: spanMode });
        spanStart = i;
        spanMode = nextMode;
      }
      mode = nextMode;
    };
    const emit = (type, start, end, value, extra) => {
      const tok = { type: type, start: start, end: end, value: value };
      if (extra) tok.headerClose = true;
      tokens.push(tok);
    };
    // CONSTRAINT: a '/' misread as division where it opens a regex either
    // fails the lexer self-check loudly or leaves a stray token the shadow
    // scan sees; a '/' misread as regex where it divides hides declarations.
    // Every ambiguous case is decided as division.
    const decideSlash = (prev) => {
      if (!prev) return true;
      if (prev.type === 'punct' && prev.value === '}') return !!prev.stmtClose;
      if (prev.type === 'punct' && REGEX_PUNCT.has(prev.value)) return true;
      if (prev.type === 'op') return true;
      if (prev.type === 'id' && !prev.prop && REGEX_KW.has(prev.value)) return true;
      if (prev.type === 'punct' && prev.value === ')' && prev.headerClose) return true;
      return false;
    };
    while (i < n) {
      const c = text[i];
      if (mode === 'line') {
        if (c === '\n') { i++; mark('code'); }
        else i++;
        continue;
      }
      if (mode === 'block') {
        if (c === '*' && text[i + 1] === '/') { i += 2; mark('code'); }
        else i++;
        continue;
      }
      if (mode === 'sq' || mode === 'dq') {
        const q = mode === 'sq' ? "'" : '"';
        if (c === '\\') { i += 2; continue; }
        if (c === q) { i++; mark('code'); continue; }
        i++;
        continue;
      }
      if (mode === 'tmpl') {
        if (c === '\\') { i += 2; continue; }
        if (c === '`') { i++; mark('code'); continue; }
        if (c === '$' && text[i + 1] === '{') {
          events.push({ ch: '{', pos: i + 1 });
          braceStack.push({ stmtPos: false });
          i += 2;
          interpStack.push(brace);
          brace++;
          mark('code');
          continue;
        }
        i++;
        continue;
      }
      if (mode === 'regex') {
        if (c === '\\') { i += 2; continue; }
        if (c === '[') {
          i++;
          while (i < n) {
            if (text[i] === '\\') { i += 2; continue; }
            if (text[i] === ']') { i++; break; }
            i++;
          }
          continue;
        }
        if (c === '/') {
          i++;
          while (i < n && 'gimsuyvd'.includes(text[i])) i++;
          mark('code');
          continue;
        }
        i++;
        continue;
      }
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') { i++; continue; }
      if (c === '/' && text[i + 1] === '/') { mark('line'); i += 2; continue; }
      if (c === '/' && text[i + 1] === '*') { mark('block'); i += 2; continue; }
      if (c === "'") { i++; mark('sq'); continue; }
      if (c === '"') { i++; mark('dq'); continue; }
      if (c === '`') { i++; mark('tmpl'); continue; }
      if (c === '/') {
        const slashOpensRegex = decideSlash(tokens[tokens.length - 1]);
        if (slashOpensRegex) { mark('regex'); i++; continue; }
        emit('punct', i, i + 1, '/');
        i++;
        continue;
      }
      if (c === '}') {
        const start = i;
        brace--;
        // CONSTRAINT: `}` интерполяции не является токеном кода. `${` токена
        // тоже не даёт, поэтому токенная глубина считалась только по
        // закрывающей -- и уезжала на -1 за каждую `${...}`, порождая ложные
        // деклараторы в checkOptsForms (живой случай: L278, Ctn).
        const isInterpClose = interpStack.length && brace === interpStack[interpStack.length - 1];
        if (isInterpClose) {
          events.push({ ch: '}', pos: start });
          if (braceStack.length) braceStack.pop();
          interpStack.pop();
          i++;
          mark('tmpl');
          continue;
        }
        const braceRec = braceStack.length ? braceStack.pop() : { stmtPos: false };
        events.push({ ch: '}', pos: start });
        const closeTok = { type: 'punct', start: start, end: start + 1, value: '}' };
        closeTok.stmtClose = braceRec.stmtPos;
        tokens.push(closeTok);
        i++;
        continue;
      }
      if (c === '{') {
        const stmtPrev = tokens[tokens.length - 1];
        const stmtPos = !stmtPrev
          || (stmtPrev.type === 'punct' && (stmtPrev.value === ';' || stmtPrev.value === '{' || stmtPrev.value === '}'))
          || (stmtPrev.type === 'punct' && stmtPrev.value === ')' && stmtPrev.headerClose)
          || (stmtPrev.type === 'id' && STMT_KW.has(stmtPrev.value));
        braceStack.push({ stmtPos: stmtPos });
        events.push({ ch: '{', pos: i });
        emit('punct', i, i + 1, '{');
        brace++;
        i++;
        continue;
      }
      if (c === '(') {
        const prev = tokens[tokens.length - 1];
        parenStack.push(!!(prev && prev.type === 'id' && !prev.prop && HEADER_KW.has(prev.value)));
        emit('punct', i, i + 1, '(');
        i++;
        continue;
      }
      if (c === ')') {
        const isHeader = parenStack.length ? parenStack.pop() : false;
        emit('punct', i, i + 1, ')', isHeader);
        i++;
        continue;
      }
      if (/[A-Za-z_$]/.test(c)) {
        const s = i;
        i++;
        while (i < n && /[\w$]/.test(text[i])) i++;
        emit('id', s, i, text.slice(s, i));
        // CONSTRAINT: an identifier after '.' or '?.' is a property name, never a keyword: p.catch(f)/2 divides.
        // The spread '...' lexes as three '.' tokens, and a keyword after it stays a keyword: [...typeof /{/] holds a regex.
        const idTok = tokens[tokens.length - 1];
        const idBefore = tokens[tokens.length - 2];
        const idBefore2 = tokens[tokens.length - 3];
        if (idBefore && ((idBefore.type === 'punct' && idBefore.value === '.' && !(idBefore2 && idBefore2.type === 'punct' && idBefore2.value === '.')) || (idBefore.type === 'op' && idBefore.value === '?.'))) idTok.prop = true;
        continue;
      }
      if ((c >= '0' && c <= '9') || (c === '.' && text[i + 1] >= '0' && text[i + 1] <= '9')) {
        const s = i;
        if (text.slice(i, i + 2) === '0x' || text.slice(i, i + 2) === '0X' || text.slice(i, i + 2) === '0b' || text.slice(i, i + 2) === '0B' || text.slice(i, i + 2) === '0o' || text.slice(i, i + 2) === '0O') {
          i += 2;
          while (i < n && /[0-9a-fA-F]/.test(text[i])) i++;
        } else {
          while (i < n && /[0-9]/.test(text[i])) i++;
          if (text[i] === '.') { i++; while (i < n && /[0-9]/.test(text[i])) i++; }
          if (text[i] === 'e' || text[i] === 'E') {
            i++;
            if (text[i] === '+' || text[i] === '-') i++;
            while (i < n && /[0-9]/.test(text[i])) i++;
          }
        }
        emit('num', s, i, text.slice(s, i));
        continue;
      }
      if ((c === '+' || c === '-') && text[i + 1] === c) {
        emit('punct', i, i + 2, c + c);
        i += 2;
        continue;
      }
      let mop = null;
      for (const op of MULTI_OPS) {
        if (text.startsWith(op, i)) { mop = op; break; }
      }
      if (mop) { emit('op', i, i + mop.length, mop); i += mop.length; continue; }
      if (c === ';' && brace === 0) events.push({ ch: ';', pos: i });
      emit('punct', i, i + 1, c);
      i++;
    }
    if (n > spanStart) spans.push({ start: spanStart, end: n, mode: spanMode });
    const stateAt = (pos) => {
      let lo = 0;
      let hi = spans.length - 1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        const s = spans[mid];
        if (pos < s.start) hi = mid - 1;
        else if (pos >= s.end) lo = mid + 1;
        else return s.mode;
      }
      return 'missing';
    };
    return { tokens: tokens, events: events, brace: brace, mode: mode, interp: interpStack.length, paren: parenStack.length, stateAt: stateAt };
  };
  const parseImportSpecs = (modText) => {
    const specs = [];
    const others = [];
    const lx = lexModule(modText);
    const rx = /import\s*(?:([A-Za-z_$][\w$]*)\s*,\s*)?\{([^}]*)\}\s*from\s*"([^"]+)"\s*;/g;
    let m;
    while ((m = rx.exec(modText)) !== null) {
      if (lx.stateAt(m.index) !== 'code') continue;
      const path = m[3];
      for (const raw of m[2].split(',')) {
        const part = raw.trim();
        if (!part) continue;
        const asM = part.match(/^([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)$/);
        if (asM) specs.push({ exportName: asM[1], local: asM[2], path: path });
        else if (/^[A-Za-z_$][\w$]*$/.test(part)) specs.push({ exportName: part, local: part, path: path });
      }
    }
    const rxNs = /import\s*\*\s*as\s+([A-Za-z_$][\w$]*)\s*from\s*"([^"]+)"/g;
    while ((m = rxNs.exec(modText)) !== null) {
      if (lx.stateAt(m.index) !== 'code') continue;
      others.push({ kind: 'namespace', local: m[1], path: m[2] });
    }
    const rxDef = /import\s+([A-Za-z_$][\w$]*)\s*from\s*"([^"]+)"/g;
    while ((m = rxDef.exec(modText)) !== null) {
      if (lx.stateAt(m.index) !== 'code') continue;
      others.push({ kind: 'default', local: m[1], path: m[2] });
    }
    return { specs: specs, others: others };
  };
  const takeSiteLocal = (found, exportName, path, others) => {
    const sother = found.length === 0 ? others.find((o) => o.path === path) : null;
    if (sother) fail(`${exportName} is imported from ${path} in the site module only as a ${sother.kind} import (unsupported form)`);
    if (found.length === 0) fail(`${exportName} is not imported from ${path} in the site module`);
    if (found.length !== 1) fail(`${exportName} imported ${found.length} times`);
    return found[0].local;
  };
  const findReader = () => {
    const rxReader = new RegExp(
      'function ' + ID + '\\((' + ID + '),(' + ID + '),(' + ID + ')\\)\\{return \\1\\?\\.type==="assistant"&&\\1\\.isApiErrorMessage===!0&&\\1\\.truncatedAfterOutput===!0&&\\((' + ID + ')\\(\\3\\)==="subagent"\\|\\|\\4\\(\\3\\)==="main"&&\\2\\.options\\.isNonInteractiveSession\\)&&(' + ID + ')\\("tengu_truncated_response_recovery",!0\\)\\}',
      'g',
    );
    const hits = Array.from(js.matchAll(rxReader));
    if (hits.length !== 1)
      fail('truncation recovery reader: expected exactly one predicate, found ' + hits.length);
    return { pos: hits[0].index, CLSr: hits[0][4], GATEr: hits[0][5] };
  };
  const resolveRecoveryNames = () => {
    const reader = findReader();
    const readerSlice = moduleSliceAround(js, reader.pos);
    const rparse = parseImportSpecs(js.slice(readerSlice[0], readerSlice[1]));
    const rspecs = rparse.specs;
    const rothers = rparse.others;
    const oneLocal = (name) => {
      const found = rspecs.filter((s) => s.local === name);
      if (found.length === 0) {
        const rother = rothers.find((o) => o.local === name);
        if (rother) fail('truncation recovery reader: ' + name + ' is a ' + rother.kind + ' import (unsupported form)');
      }
      if (found.length !== 1) fail('truncation recovery reader: ' + name + ' imported ' + found.length + ' times');
      return found[0];
    };
    const clsR = oneLocal(reader.CLSr);
    const gateR = oneLocal(reader.GATEr);
    const siteSlice = moduleSliceAround(js, constStart);
    const sparse = parseImportSpecs(js.slice(siteSlice[0], siteSlice[1]));
    const sspecs = sparse.specs;
    const localsOf = (expName, fromPath) => sspecs.filter((s) => s.exportName === expName && s.path === fromPath);
    return {
      CLSs: takeSiteLocal(localsOf(clsR.exportName, clsR.path), clsR.exportName, clsR.path, sparse.others),
      GATEs: takeSiteLocal(localsOf(gateR.exportName, gateR.path), gateR.exportName, gateR.path, sparse.others),
      CLSr: reader.CLSr,
      GATEr: reader.GATEr,
    };
  };
  const FN_HEADER_KW = new Set(['if', 'while', 'for', 'with', 'catch', 'switch']);
  const ASSIGN_OPS = new Set(['+=', '-=', '*=', '%=', '&=', '|=', '^=', '**=', '<<=', '>>=', '>>>=', '&&=', '||=', '??=']);
  const OPTS_FIELDS = new Set(['querySource', 'isNonInteractiveSession']);
  const matchingOpen = (closeCh) => (closeCh === ')' ? '(' : closeCh === ']' ? '[' : '{');
  // Nested function scopes as byte intervals: arrow and function/method
  // bodies (a), bodies whose `(` is not a header paren (b), parameter parens
  // (c), and concise arrow bodies (d). The construct's own body brace is
  // passed in and excluded -- the construct itself is not "nested".
  const nestedFnScopes = (toks, ownBodyOpen) => {
    const scopes = [];
    const stack = [];
    const parenOpenOf = {};
    for (let i = 0; i < toks.length; i++) {
      const t = toks[i];
      if (t.type === 'punct' && (t.value === '(' || t.value === '[' || t.value === '{')) {
        stack.push({ ch: t.value, openIdx: i });
      } else if (t.type === 'punct' && (t.value === ')' || t.value === ']' || t.value === '}')) {
        const fr = stack.pop();
        if (!fr || fr.ch !== matchingOpen(t.value)) continue;
        if (fr.ch === '(') {
          parenOpenOf[i] = fr.openIdx;
          const jn0 = i + 1;
          const nx = jn0 < toks.length ? toks[jn0] : null;
          if (nx && nx.type === 'op' && nx.value === '=>') scopes.push([toks[fr.openIdx].start, t.end]);
        } else if (fr.ch === '{') {
          const before = fr.openIdx > 0 ? toks[fr.openIdx - 1] : null;
          let fnScope = false;
          if (before && before.type === 'op' && before.value === '=>') fnScope = true;
          else if (before && before.type === 'punct' && before.value === ')') {
            const openIdx = parenOpenOf[fr.openIdx - 1];
            if (openIdx !== undefined) {
              const kw = openIdx > 0 ? toks[openIdx - 1] : null;
              if (!(kw && kw.type === 'id' && FN_HEADER_KW.has(kw.value))) {
                fnScope = true;
                scopes.push([toks[openIdx].start, toks[fr.openIdx - 1].end]);
              }
            }
          }
          if (fnScope && fr.openIdx !== ownBodyOpen) scopes.push([toks[fr.openIdx].start, t.end]);
        }
      } else if (t.type === 'op' && t.value === '=>') {
        const jn1 = i + 1;
        const nx = jn1 < toks.length ? toks[jn1] : null;
        if (nx && nx.type === 'punct' && nx.value === '{') continue;
        let d = 0;
        let j = i + 1;
        while (j < toks.length) {
          const u = toks[j];
          if (u.type === 'punct' && (u.value === '(' || u.value === '[' || u.value === '{')) d++;
          else if (u.type === 'punct' && (u.value === ')' || u.value === ']' || u.value === '}')) {
            if (d === 0) break;
            d--;
          } else if (d === 0 && u.type === 'punct' && (u.value === ',' || u.value === ';')) break;
          j++;
        }
        if (j > i + 1) {
          const endPos = j < toks.length ? toks[j].start : toks[toks.length - 1].end;
          scopes.push([toks[jn1].start, endPos]);
        }
      }
    }
    return scopes;
  };
  // Declarator positions of var|let|const lists: right after the keyword or
  // after a comma at the keyword's depth; a declarator starting with { or [
  // contributes the whole template inside.
  const declIntervals = (toks) => {
    const out = [];
    const depthAt = [];
    let d = 0;
    for (let i = 0; i < toks.length; i++) {
      depthAt[i] = d;
      const t = toks[i];
      if (t.type === 'punct' && (t.value === '(' || t.value === '[' || t.value === '{')) d++;
      else if (t.type === 'punct' && (t.value === ')' || t.value === ']' || t.value === '}')) d--;
    }
    for (let k = 0; k < toks.length; k++) {
      const kw = toks[k];
      if (!(kw.type === 'id' && (kw.value === 'var' || kw.value === 'let' || kw.value === 'const'))) continue;
      const d0 = depthAt[k];
      let i = k + 1;
      let wantDeclarator = true;
      while (i < toks.length) {
        const t = toks[i];
        // CONSTRAINT: закрывающая скобка НА глубине ключевого слова тоже
        // кончает список: заголовок for(let X of Y) закрывается `)` на d0,
        // и без этого проход проваливается в тело цикла.
        if (t.type === 'punct' && (t.value === ')' || t.value === ']' || t.value === '}') && depthAt[i] <= d0) break;
        if (t.type === 'punct' && t.value === ';' && depthAt[i] === d0) break;
        if (wantDeclarator) {
          if (t.type === 'punct' && (t.value === '{' || t.value === '[')) {
            let dd = 0;
            let j = i;
            while (j < toks.length) {
              const u = toks[j];
              if (u.type === 'punct' && (u.value === '(' || u.value === '[' || u.value === '{')) dd++;
              else if (u.type === 'punct' && (u.value === ')' || u.value === ']' || u.value === '}')) {
                dd--;
                if (dd === 0) break;
              }
              j++;
            }
            if (j < toks.length) out.push([t.start, toks[j].end]);
            i = j + 1;
          } else {
            out.push([t.start, t.end]);
            i++;
          }
          wantDeclarator = false;
        } else {
          if (t.type === 'punct' && t.value === ',' && depthAt[i] === d0) wantDeclarator = true;
          i++;
        }
      }
    }
    return out;
  };
  const inCatchParens = (toks, i) => {
    let dd = 0;
    for (let j = i - 1; j >= 0; j--) {
      const u = toks[j];
      if (u.type === 'punct' && u.value === ')') dd++;
      else if (u.type === 'punct' && u.value === '(') {
        if (dd === 0) {
          const kw = j > 0 ? toks[j - 1] : null;
          return !!(kw && kw.type === 'id' && kw.value === 'catch');
        }
        dd--;
      }
    }
    return false;
  };
  // A position belongs to the construct when it is inside its bounds and in
  // no nested function scope.
  const constructOwns = (built, relPos) => {
    if (relPos < built.relStart || relPos >= built.relEnd) return false;
    for (const scope of built.nestedScopes) {
      if (relPos >= scope[0] && relPos < scope[1]) return false;
    }
    return true;
  };
  const checkOptsForms = (built, opts) => {
    const toks = built.tokens.filter((t) => t.start >= built.relStart && t.start < built.relEnd);
    const start = built.ownBodyOpen > 0 ? built.ownBodyOpen + 1 : 0;
    const decls = declIntervals(toks);
    const inIntervals = (t, list) => list.some((iv) => t.start >= iv[0] && t.start < iv[1]);
    for (let i = start; i < toks.length; i++) {
      const t = toks[i];
      if (!(t.type === 'id' && t.value === opts)) continue;
      if (inIntervals(t, built.nestedScopes)) continue;
      const prev = i > 0 ? toks[i - 1] : null;
      const jn = i + 1;
      const next = jn < toks.length ? toks[jn] : null;
      const isProp = !!(prev && prev.type === 'punct' && prev.value === '.'
        && !(i >= 2 && toks[i - 2].type === 'punct' && toks[i - 2].value === '.'));
      if (isProp) continue;
      const inDecl = inIntervals(t, decls);
      const isKey = !!(prev && prev.type === 'punct' && (prev.value === '{' || prev.value === ',')
        && next && next.type === 'punct' && next.value === ':');
      if (isKey && !inDecl) continue;
      const d1 = !!(prev && prev.type === 'id'
          && (prev.value === 'var' || prev.value === 'let' || prev.value === 'const'
            || prev.value === 'function' || prev.value === 'class'))
        || !!(prev && prev.type === 'punct' && prev.value === '*'
          && i >= 2 && toks[i - 2].type === 'id' && toks[i - 2].value === 'function')
        || inDecl;
      if (d1) fail('streaming fallback site: ' + built.id + ' declares ' + opts + ' again');
      const d2 = inCatchParens(toks, i);
      if (d2) fail('streaming fallback site: ' + built.id + ' catch binds ' + opts);
      const d3 = !!(next && ((next.type === 'punct' && next.value === '=')
          || (next.type === 'op' && ASSIGN_OPS.has(next.value))))
        || !!(next && next.type === 'punct' && (next.value === '++' || next.value === '--'))
        || !!(prev && prev.type === 'punct' && (prev.value === '++' || prev.value === '--'))
        || !!(prev && prev.type === 'punct' && prev.value === '('
          && i >= 2 && toks[i - 2].type === 'id' && toks[i - 2].value === 'for'
          && next && next.type === 'id' && (next.value === 'in' || next.value === 'of'));
      if (d3) fail('streaming fallback site: ' + built.id + ' rebinds ' + opts);
      let d4msg = null;
      if (next && next.type === 'punct' && next.value === '.') {
        const fld = jn + 1 < toks.length ? toks[jn + 1] : null;
        const after2 = jn + 2 < toks.length ? toks[jn + 2] : null;
        const writesAhead = !!(after2 && ((after2.type === 'punct' && (after2.value === '=' || after2.value === '++' || after2.value === '--'))
          || (after2.type === 'op' && ASSIGN_OPS.has(after2.value))));
        const bumpedBehind = !!(prev && prev.type === 'punct' && (prev.value === '++' || prev.value === '--'));
        const deleted = !!(prev && prev.type === 'id' && prev.value === 'delete');
        if (fld && fld.type === 'id' && OPTS_FIELDS.has(fld.value) && (writesAhead || bumpedBehind || deleted))
          d4msg = 'writes ' + opts + '.' + fld.value;
      }
      if (!d4msg && next && next.type === 'punct' && next.value === '[') {
        let dd = 0;
        let j = jn;
        while (j < toks.length) {
          const u = toks[j];
          if (u.type === 'punct' && (u.value === '(' || u.value === '[' || u.value === '{')) dd++;
          else if (u.type === 'punct' && (u.value === ')' || u.value === ']' || u.value === '}')) {
            dd--;
            if (dd === 0) break;
          }
          j++;
        }
        const after3 = j + 1 < toks.length ? toks[j + 1] : null;
        if (after3 && ((after3.type === 'punct' && after3.value === '=')
          || (after3.type === 'op' && ASSIGN_OPS.has(after3.value)))) d4msg = 'writes ' + opts + '[…]';
      }
      if (d4msg) fail('streaming fallback site: ' + built.id + ' ' + d4msg);
    }
  };
  const buildSiteConstruct = (constAbs, regionAbs) => {
    const siteSlice = moduleSliceAround(js, constAbs);
    const mod = js.slice(siteSlice[0], siteSlice[1]);
    const lx = lexModule(mod);
    if (lx.brace !== 0 || lx.mode !== 'code' || lx.interp !== 0 || lx.paren !== 0)
      fail('streaming fallback site: lexer depth did not return to 0 (' + lx.brace + ', mode ' + lx.mode + ')');
    const relConst = constAbs - siteSlice[0];
    const relRegion = regionAbs - siteSlice[0];
    if (lx.stateAt(relConst) !== 'code')
      fail('streaming fallback site: lexer state at the telemetry constant is ' + lx.stateAt(relConst));
    if (lx.stateAt(relRegion) !== 'code')
      fail('streaming fallback site: lexer state at the partial-finalize region is ' + lx.stateAt(relRegion));
    let depth = 0;
    let stmtStart = 0;
    let found = null;
    for (const ev of lx.events) {
      if (ev.ch === '{') depth++;
      else if (ev.ch === '}') {
        depth--;
        if (depth === 0) {
          if (stmtStart <= relRegion && relRegion < ev.pos + 1)
            found = { relStart: stmtStart, relEnd: ev.pos + 1 };
          stmtStart = ev.pos + 1;
        }
      } else if (ev.ch === ';' && depth === 0) stmtStart = ev.pos + 1;
    }
    const notGen = 'streaming fallback site: the enclosing construct is not an async generator taking \'' + opts + '\'';
    if (!found) fail(notGen);
    if (relConst < found.relStart || relConst >= found.relEnd)
      fail('streaming fallback site: the telemetry constant is outside the enclosing construct');
    const raw = mod.slice(found.relStart, found.relEnd).replace(/^\s+/, '');
    const hm = raw.match(new RegExp('^async function\\*(' + ID + ')\\(([^)]*)\\)\\{'));
    if (!hm) fail(notGen);
    const paramNames = [];
    let pd = 0;
    let cur = '';
    for (const ch of hm[2]) {
      if (ch === '(' || ch === '[' || ch === '{') pd++;
      else if (ch === ')' || ch === ']' || ch === '}') pd--;
      else if (ch === ',' && pd === 0) { paramNames.push(cur); cur = ''; continue; }
      cur += ch;
    }
    if (cur.trim()) paramNames.push(cur);
    const names = paramNames.map((p) => p.trim().replace(/=[\s\S]*$/, '').trim()).filter(Boolean);
    if (!names.includes(opts)) fail('streaming fallback site: the enclosing construct does not take \'' + opts + '\' as a parameter');
    const siteToks = lx.tokens.filter((t) => t.start >= found.relStart && t.start < found.relEnd);
    let ownBodyOpen = -1;
    if (siteToks.length > 4 && siteToks[0].value === 'async' && siteToks[1].value === 'function'
      && siteToks[2].value === '*' && siteToks[3].type === 'id' && siteToks[4].value === '(') {
      let dd = 0;
      for (let j = 4; j < siteToks.length; j++) {
        const u = siteToks[j];
        if (u.type === 'punct' && u.value === '(') dd++;
        else if (u.type === 'punct' && u.value === ')') {
          dd--;
          if (dd === 0) {
            const jn = j + 1;
            if (jn < siteToks.length && siteToks[jn].value === '{') ownBodyOpen = jn;
            break;
          }
        }
      }
    }
    return {
      id: hm[1],
      relStart: found.relStart,
      relEnd: found.relEnd,
      absEnd: siteSlice[0] + found.relEnd,
      mod: mod,
      modStart: siteSlice[0],
      tokens: lx.tokens,
      ownBodyOpen: ownBodyOpen,
      nestedScopes: nestedFnScopes(siteToks, ownBodyOpen),
    };
  };
  const shadowScan = (built, clsName, gateName) => {
    const constructRelEnd = built.relEnd;
    const toks = built.tokens.filter((t) => t.start >= built.relStart && t.start < constructRelEnd);
    for (let i = 0; i < toks.length; i++) {
      const t = toks[i];
      if (t.type !== 'id' || (t.value !== clsName && t.value !== gateName)) continue;
      const prevTok = i > 0 ? toks[i - 1] : null;
      const isMember = !!(prevTok && prevTok.value === '.');
      let called = false;
      const nextTok = toks[i + 1] || null;
      if (nextTok && nextTok.type === 'punct' && nextTok.value === '(') {
        let pd = 1;
        let j = i + 2;
        while (j < toks.length) {
          const u = toks[j];
          if (u.type === 'punct' && u.value === '(') pd++;
          else if (u.type === 'punct' && u.value === ')') {
            pd--;
            if (pd === 0) break;
          }
          j++;
        }
        const jn = j + 1;
        const after = jn < toks.length ? toks[jn] : null;
        const isDefBrace = !!(after && after.type === 'punct' && after.value === '{');
        called = !isDefBrace;
      }
      if (!isMember && !called)
        fail('streaming fallback site: ' + t.value + ' is bound or referenced other than by a call inside ' + built.id);
    }
  };

  // The shared backoff helper: min(500*2^(n-1), cap) with up to 25% jitter.
  const backoffMatch = js.match(new RegExp(
    `function (${ID})\\((${ID}),(${ID}),(${ID})=32000\\)\\{let (${ID})=Math\\.min\\(500\\*Math\\.pow\\(2,\\2-1\\),\\4\\),`,
  ));
  if (!backoffMatch) fail('shared retry backoff helper not found');
  const backoff = backoffMatch[1];

  // 1. The per-request counters, declared in one long `let` run:
  //    <qo>=3,<un>={value:0},<staleMax>=2,<stale>=0,<connRetry>=0,<flag>=!1,
  //    <idleMax>=1,<idle>=0,
  //
  //    The run grows between releases — 2.1.245 inserts `<alias>=<qo>` and
  //    `<map>=new Map` right after `{value:0}` — so a bounded stretch of extra
  //    simple declarations is allowed in the middle and carried through
  //    untouched. The two counters this patch raises are still identified by
  //    their position in the tail run, which has kept its shape.
  //
  //    From 2.1.281 the tail carries one more pair between <connRetry> and
  //    <flag>: <truncMax>=1,<trunc>=0 -- the budget and counter of the
  //    StreamTruncated retry. The pair is optional here and carried through
  //    untouched: its budget has exactly one reader, the cap site in 3, and is
  //    raised there, so it has one home.
  const rxBudget = new RegExp(
    `(${ID})=3,(${ID})=\\{value:0\\},((?:${ID}=[^,;]{1,24},){0,8})` +
      `(${ID})=2,(${ID})=0,(${ID})=0,(?:(${ID})=1,(${ID})=0,)?(${ID})=!1,(${ID})=1,(${ID})=0,`,
  );
  const nBudget = (js.match(new RegExp(rxBudget.source, 'g')) || []).length;
  if (nBudget !== 1) fail(`streaming retry budgets: expected exactly one site, found ${nBudget}`);
  const mBudget = js.match(rxBudget);
  js = js.replace(
    rxBudget,
    (all, qo, un, mid, staleMax, stale, conn, truncMax, trunc, flag, idleMax, idle) =>
      `${qo}=3,${un}={value:0},${mid}${staleMax}=300,${stale}=0,${conn}=0,` +
      (truncMax === undefined ? '' : `${truncMax}=1,${trunc}=0,`) +
      `${flag}=!1,${idleMax}=300,${idle}=0,`,
  );

  // 2. The linear wait on the stale-connection retry inside the finalize
  //    branch: `if(<req>=null,!<idle>)await <sleep>(100*<stale>,<signal>)`.
  //    From 2.1.281 the reset is the last operand of a comma list inside the
  //    same `if(`, so the character before it is either `if(` or `,`; it is
  //    captured and written back as it was.
  const rxWait = new RegExp(
    `(if\\(|,)(${ID})=null,!(${ID})\\)await (${ID})\\(100\\*(${ID}),(${ID})\\);continue (${ID})\\}`,
  );
  const nWait = (js.match(new RegExp(rxWait.source, 'g')) || []).length;
  if (nWait !== 1) fail(`streaming retry wait: expected exactly one site, found ${nWait}`);
  js = js.replace(rxWait, `$1$2=null,!$3)await $4(${repEsc(backoff)}($5),$6);continue $7}`);

  // 3. The connection-retry cap taken from the max-retries setting:
  //    `let <cap>=<maxRetries>();if(<isConn>&&<stop>===null&&<n><<cap>){`
  //    From 2.1.281 the cap splits on the error code: a StreamTruncated
  //    error counts against its own budget (<truncMax>, declared =1 in the run
  //    of 1.) and its own counter, every other connection error against the
  //    setting as before:
  //    `let <isTr>=<err>?.code==="StreamTruncated",<cap>=<isTr>?<truncMax>:<maxRetries>();
  //     if(<isConn>&&<stop>===null&&(<isTr>?<trunc>:<n>)<<cap>){`
  //    Both arms are raised: a truncated stream left at one retry would be
  //    finalized as a half answer after a single break, which is the outcome
  //    this step exists to prevent. Exactly one of the two forms must be
  //    present, exactly once.
  const rxCapSingle = new RegExp(
    `let (${ID})=(${ID})\\(\\);if\\((${ID})&&(${ID})===null&&(${ID})<\\1\\)\\{`,
  );
  const rxCapSplit = new RegExp(
    `let (${ID})=(${ID})\\?\\.code==="StreamTruncated",(${ID})=\\1\\?(${ID}):(${ID})\\(\\);` +
      `if\\((${ID})&&(${ID})===null&&\\(\\1\\?(${ID}):(${ID})\\)<\\3\\)\\{`,
  );
  const nCapSingle = (js.match(new RegExp(rxCapSingle.source, 'g')) || []).length;
  const nCapSplit = (js.match(new RegExp(rxCapSplit.source, 'g')) || []).length;
  if (nCapSingle + nCapSplit !== 1)
    fail(
      `streaming connection-retry cap: expected exactly one site across both forms, ` +
        `found ${nCapSingle} (single budget) + ${nCapSplit} (truncation split)`,
    );
  // CONSTRAINT: the StreamTruncated budget of 1. has exactly one reader, the
  // split cap; a budget without that reader, a split cap reading another name,
  // or a second reader in the budget's module would leave that retry at 1
  // (measured on 2.1.281/282: two occurrences in the module, the declaration
  // and the cap read)
  const truncMax = mBudget[7];
  if ((truncMax === undefined) !== (nCapSplit === 0))
    fail(
      `streaming retry budgets: the StreamTruncated budget is ${truncMax === undefined ? 'absent' : `'${truncMax}'`}, ` +
        `the truncation-split cap ${nCapSplit === 0 ? 'absent' : 'present'}`,
    );
  if (truncMax !== undefined) {
    const mCap = js.match(rxCapSplit);
    if (mCap[4] !== truncMax)
      fail(`streaming connection-retry cap: the split cap reads '${mCap[4]}', not the StreamTruncated budget '${truncMax}'`);
    const [bs, be] = moduleSliceAround(js, mBudget.index);
    if (mCap.index < bs || mCap.index >= be)
      fail(`streaming connection-retry cap: the split cap is outside the module of the StreamTruncated budget '${truncMax}'`);
    const reads = (js.slice(bs, be).match(new RegExp(`(?<![\\w$])${rxEsc(truncMax)}(?![\\w$])`, 'g')) || []).length;
    if (reads !== 2)
      fail(`streaming retry budgets: the StreamTruncated budget '${truncMax}' occurs ${reads} times in its module, expected 2 (the declaration and the cap read)`);
  }
  if (nCapSingle === 1) {
    js = js.replace(rxCapSingle, 'let $1=$2();if($3&&$4===null&&$5<Math.max($1,300)){');
  } else {
    js = js.replace(
      rxCapSplit,
      'let $1=$2?.code==="StreamTruncated",$3=$1?Math.max($4,300):Math.max($5(),300);' +
        'if($6&&$7===null&&($1?$8:$9)<$3){',
    );
  }

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
  const nGate = (js.match(new RegExp(rxGate.source, 'g')) || []).length;
  if (nGate !== 1) fail(`thinking-only retry gate: expected exactly one site, found ${nGate}`);
  const mGate = js.match(rxGate);
  js = js.replace(rxGate, 'if($2===null&&($3?$4<$5:$6<$7)){');

  // CONSTRAINT: this yield is the only producer of truncatedAfterOutput.
  // Readers are two: the recovery reader, whose predicate is repeated here
  // through the classifier and the gate the site imports, and the WebSearch
  // formatter, which reads the marker as text.
  // The expression repeats the body of the reader predicate, not the
  // caller's whole predicate. The caller also applies !needsFollowUp, loop
  // state above the turn.step hook chain, not observable here. When a hook
  // yields tool_use in this same step, stock skips recovery, emits the
  // marker, and continues the turn with the tool follow-up; this site leaves
  // that path stock. A hook that has started yielding tool_use changes the
  // outcome of this leg.
  // Names are taken from the site module's imports, not from the reader:
  // the two sites are different bundle files, so one spelling is not one binding.
  // The shadow scan covers the whole enclosing construct, header and the
  // text after the splice included, because declarations are hoisted.
  // The recovery gate is an upstream kill-switch and is not inlined.
  // The site is parsed FROM THE TELEMETRY CONSTANT, not by one long regexp
  // pinning the shape of a whole instruction. That was the sixth case of the
  // root defect "the locator pins a written form instead of a stable
  // structure": the old pattern swallowed text up to `error:<ID> instanceof
  // Error?` INSIDE the telemetry object, so 2.1.267 -- which lawfully hoisted
  // that repeated expression into a variable (`error:NN,`) -- stopped
  // matching. Two hazards lived in the same pattern: the replacement REBUILT
  // the swallowed tail from its own guess about the shape, and it took the
  // THROWN value from the telemetry field. On 2.1.265 the field happened to
  // name the same identifier that was thrown; on 2.1.267 the field reads a
  // STRING (`NN=...` built from the error) while the instruction throws the
  // raw error carried by its own tail `}),<ID>}`. Widening the old pattern
  // alone would have produced `throw NN` -- a thrown string instead of an
  // Error, green and silent. So every operand now gets its own shape control
  // and its own refusal, and the constant occurs five times in the image
  // (measured on 2.1.265 and 2.1.267, darwin and linux) --
  // the site is the only occurrence whose preceding text ends with
  // `break <label>}throw <fn>(`.
  const CONST = '"tengu_streaming_fallback_to_non_streaming"';
  const rxCandidate = new RegExp(`break (${ID})\\}throw (${ID})\\($`);
  const candidates = [];
  for (const occ of js.matchAll(new RegExp(CONST, 'g'))) {
    const before = js.slice(Math.max(0, occ.index - 200), occ.index);
    const mPref = before.match(rxCandidate);
    if (mPref) {
      candidates.push({
        label: mPref[1],
        constStart: occ.index,
        // The offset of the throw keyword is computed FROM THE SHAPE the
        // regexp has just proved -- `break <label>}throw <fn>(` -- and never
        // searched for inside the matched text: a label whose minified name
        // happened to contain `throw` would move an indexOf-based offset, and
        // the splice below would then cut at the wrong byte and corrupt the
        // image with no refusal anywhere.
        throwStart:
          occ.index -
          mPref[0].length +
          'break '.length +
          mPref[1].length +
          '}'.length,
      });
    }
  }
  if (candidates.length !== 1) {
    fail(
      `streaming fallback site: expected exactly one telemetry occurrence ` +
        `preceded by 'break <label>}throw <fn>(', found ${candidates.length}`,
    );
  }
  const { label, constStart, throwStart } = candidates[0];
  const constEnd = constStart + CONST.length;

  // The request options object, from the model field of the telemetry
  // payload. 2.1.257 wrapped the model in a call: it was `{model:<opts>.model,`
  // and became `{model:<fn>(<opts>.model),`. The wrapper is allowed and only
  // the inner object is captured, because the recovery branch below reads
  // `isNonInteractiveSession` and `querySource` off it. Confusing the wrapper
  // with the object is the costliest mistake here: `recoverable` would
  // silently read fields of a function.
  const mOpts = js
    .slice(constEnd, constEnd + 200)
    .match(new RegExp(`,\\{model:(?:${ID}\\()?(${ID})\\.model\\)?`));
  if (!mOpts) fail('streaming fallback site: the request options object not found after the telemetry constant');
  const opts = mOpts[1];

  // The thrown value is the instruction's OWN tail `}),<ID>}` -- never the
  // telemetry field, which on 2.1.267 holds a string built from the error.
  const mThrown = js.slice(constEnd, constEnd + 1200).match(/\}\),([A-Za-z_$][\w$]*)\}/);
  if (!mThrown) fail('streaming fallback site: the thrown value not found after the telemetry object');
  const thrown = mThrown[1];

  // Form control of the telemetry object -- the role the old
  // `error:<ID> instanceof Error?` tail used to carry. Both marker fields of
  // the partial-finalize telemetry must be present between the constant and
  // the object's close; their composition and order are identical on 2.1.265
  // and 2.1.267, only the minified names differ.
  const telemetryBody = js.slice(constEnd, constEnd + mThrown.index);
  if (
    !telemetryBody.includes(',attemptNumber:') ||
    !telemetryBody.includes('any_stream_event_yielded:')
  )
    fail('streaming fallback site: the telemetry object is not the partial-finalize one');

  // The rewritable region ends where the candidate's `throw` begins, so the
  // pattern is anchored to the END of the slice and the label -- already
  // known from the anchor -- goes in as a literal.
  //
  // Two forms. Up to 2.1.280 the usage accrual is inlined between the marker
  // and the break (`,<c>!=="credited")<c>="credited",<acc>+=<expr>;break`) and
  // is part of the region. From 2.1.281 the accrual is a function called
  // BEFORE the marker (`$0(),yield <ar>({...});break <label>}`), so it stays
  // outside the region and runs before any throw spliced in here; the region
  // is the marker alone. Exactly one form must match.
  const rxRegionCredited = new RegExp(
    `,yield (${ID})\\(\\{content:([^;]{0,1400}?),error:"server_error"` +
      `(?:,truncatedAfterOutput:([^,;{}]{0,80}))?((?:,[^;]{0,300}?)?)\\}\\),(${ID})!=="credited"\\)` +
      `\\5="credited",(${ID})\\+=([^;]{0,300}?);break ${rxEsc(label)}\\}$`,
  );
  const rxRegionPlain = new RegExp(
    `,yield (${ID})\\(\\{content:([^;]{0,1400}?),error:"server_error"` +
      `(?:,truncatedAfterOutput:([^,;{}]{0,80}))?((?:,[^;]{0,300}?)?)\\}\\);break ${rxEsc(label)}\\}$`,
  );
  const regionSliceStart = Math.max(0, throwStart - 2500);
  const regionSlice = js.slice(regionSliceStart, throwStart);
  const mRegionCredited = regionSlice.match(rxRegionCredited);
  const mRegionPlain = regionSlice.match(rxRegionPlain);
  if (mRegionCredited && mRegionPlain)
    fail('streaming partial-finalize region: both the inline-accrual and the plain form match');
  const mRegion = mRegionCredited || mRegionPlain;
  if (!mRegion) fail('streaming partial-finalize region not found before the telemetry throw');
  const regionStart = regionSliceStart + mRegion.index;
  const [, arFn, content, truncExpr, extraTail] = mRegion;
  let CLSs;
  let GATEs;
  let CLSr;
  let GATEr;
  let built = null;
  let constructId = '';
  let accWindowEnd = constStart + 4000;
  if (!mRegionCredited || truncExpr !== undefined) {
    built = buildSiteConstruct(constStart, regionStart);
    constructId = built.id;
    accWindowEnd = built.absEnd;
    checkOptsForms(built, opts);
    if (truncExpr !== undefined) {
      const names = resolveRecoveryNames();
      CLSs = names.CLSs;
      GATEs = names.GATEs;
      CLSr = names.CLSr;
      GATEr = names.GATEr;
      shadowScan(built, CLSs, GATEs);
    }
  }
  let credited;
  let acc;
  let accExpr;
  if (mRegionCredited) {
    [, , , , , credited, acc, accExpr] = mRegionCredited;
  } else {
    // The grounding below needs the accrual expression. In this form it is
    // not in the region; the first inline accrual after the telemetry
    // constant (the retry path of the same function) reads the same options
    // object and serves as the witness.
    const rxAcc = new RegExp(`(${ID})!=="credited"\\)\\1="credited",(${ID})\\+=([^;]{0,300}?);`, 'g');
    let mAcc = null;
    for (const cand of js.slice(constStart, accWindowEnd).matchAll(rxAcc)) {
      if (constructOwns(built, constStart + cand.index - built.modStart)) {
        mAcc = cand;
        break;
      }
    }
    if (!mAcc) fail('streaming partial-finalize: no usage accrual owned by ' + constructId + ' after the telemetry constant');
    accExpr = mAcc[3];
  }

  // Захваченный объект обязан быть ТЕМ САМЫМ объектом запроса, а не обёрткой
  // вокруг него: ниже у него читаются `isNonInteractiveSession` и
  // `querySource`, и ошибка здесь не покраснела бы ничем -- ветка
  // восстановления просто перестала бы срабатывать, а сборка осталась зелёной.
  // Заземление берётся из соседнего выражения того же участка: начисление
  // передаёт `querySource` того же объекта. Замерено: на 252 объект `d`, на
  // 257 -- `f`, и в обоих случаях начисление его подтверждает.
  if (!accExpr.includes(`${opts}.querySource`))
    fail(
      `streaming partial-finalize: the captured options object '${opts}' is not ` +
        'the one the accrual reads querySource from -- the model expression ' +
        'shape changed and the capture landed on the wrapper',
    );

  // The edit is a SPLICE BY OFFSET, not a String.replace: everything from the
  // throw keyword on -- the telemetry call the upstream minifier wrote --
  // stays in the image byte for byte and is never rebuilt. Splicing by
  // concatenation is exactly why escaping `$` (repEsc) is FORBIDDEN here
  // rather than optional: a plain concatenation has no replacement-string
  // syntax, so a doubled `$` from repEsc would reach the image as a literal
  // and corrupt the spliced name.
  let replacement;
  const recoverable =
    truncExpr === undefined
      ? undefined
      : `((${CLSs}(${opts}.querySource)==="subagent"||${CLSs}(${opts}.querySource)==="main"&&${opts}.isNonInteractiveSession)&&${GATEs}("tengu_truncated_response_recovery",!0)&&(${truncExpr}))`;
  if (mRegionCredited && truncExpr === undefined) {
    // No truncation marker in this build: nothing downstream can recover from
    // it, so the half answer is simply not finalized.
    replacement =
      `,${credited}!=="credited")${credited}="credited",` +
      `${acc}+=${accExpr};throw ${thrown}}`;
  } else if (mRegionCredited) {
    replacement =
      `,${recoverable}?yield ${arFn}({content:${content},` +
      `error:"server_error",truncatedAfterOutput:${truncExpr}${extraTail}})` +
      `:void 0,${credited}!=="credited")${credited}="credited",` +
      `${acc}+=${accExpr};` +
      `if(!${recoverable})throw ${thrown};break ${label}}`;
  } else if (truncExpr === undefined) {
    replacement = `;throw ${thrown}}`;
  } else {
    replacement =
      `,${recoverable}?yield ${arFn}({content:${content},` +
      `error:"server_error",truncatedAfterOutput:${truncExpr}${extraTail}})` +
      `:void 0;if(!${recoverable})throw ${thrown};break ${label}}`;
  }
  js = js.slice(0, regionStart) + replacement + js.slice(throwStart);

  const namesProse = CLSs
    ? `; classifier '${CLSs}', flag gate '${GATEs}', reader '${CLSr}'/'${GATEr}', construct '${constructId}'`
    : '';
  applied.push(
    `a broken stream is retried, never finalized as a half answer ` +
      (truncExpr === undefined
        ? `(recovery splice skipped: no truncation marker in this build${namesProse}) `
        : `(stock yield where the reader predicate accepts the marker: ` +
          `subagent lanes and non-interactive main lanes, under the recovery flag${namesProse}) `) +
      `(backoff '${backoff}', budgets ${mBudget[4]}/${mBudget[10]}` +
      `${nCapSplit === 1 ? ` and the StreamTruncated budget '${mBudget[7]}'` : ''} -> 300, ` +
      `dropped content gate on '${mGate[1]}', thrown var '${thrown}', ` +
      `${truncExpr === undefined ? 'no truncation marker in this build' : `truncation marker kept for the recoverable lane ('${truncExpr}')`}, ` +
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

  // Восстановление ОКНА при resume здесь НЕ делается -- сознательно.
  //
  // Что было и почему снято (2026-08-27, решение юзера): предыдущая правка
  // дописывала в assistant-запись транскрипта своё поле и читала его на
  // возобновлении, а размер окна восстанавливала одним битом -- «нёс ли
  // идентификатор приписку [1m]». Обе половины плохи. Запись -- это наши
  // данные в стоковом файле пользователя: транскрипт переставал быть тем, что
  // написал бы чистый клиент. Бит [1m] -- это один класс окна из всех: окно
  // вычисляется из ИДЕНТИФИКАТОРА (шаг 10, customModelContextWindows), и в
  // реальном парке это 258000, 424000, 924000, 972576 и далее; приписку [1m]
  // несут 2 ключа из 538.
  //
  // Честный итог: восстановить окно нечем. Единственный стоковый след модели в
  // транскрипте -- эхо сервера в message.model, и оно не равно запрошенному
  // иду (замер: запрос `grok-4.6` -> ответ `grok-4.6-build`, и этот же ответ
  // шлюз в запросе отвергает; для claude-модели с 1M эхо приходит без
  // приписки). Без новых данных на диске или без смены поведения (возобновлять
  // на ТЕКУЩЕЙ модели вместо записанной) окно вернуть нельзя. Пока такого
  // решения нет -- здесь сток, а не половинчатый механизм.
});

// ---------------------------------------------------------------------------
// Ported from tweakcc's own patch set. The reason WAS that its patched bundle
// no longer parsed ("SyntaxError: Unexpected identifier"), so every
// customization it carried was silently discarded -- that was a defect in its
// parse gate, fixed in the fork, and tweakcc's patches now reach the image.
// These three stay ours because they are located independently rather than by
// porting tweakcc's regexes, two of which still fail on their own terms here.
// Each one shares a site with a tweakcc patch that is off in the config today
// and would collide the moment it is switched on, so each applies-or-verifies
// rather than assuming it is the only writer.

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
  if (!decl.test(moduleTextAt(m.index))) {
    // tweakcc's statusline patch rewrites this same constant when its knob is
    // set; its locator does not match this build's class-field site today, but
    // "not 300" must not mean "fail the run" the moment it does. Accept any
    // value the debounce already carries and say which; fail only if the
    // declaration is missing entirely.
    const anyDecl = new RegExp(`var ${rxEsc(constName)}=(\\d+)\\b`);
    const found = moduleTextAt(m.index).match(anyDecl);
    if (!found) fail(`statusline throttle constant '${constName}' has no declaration in its module`);
    applied.push(`statusline throttle already ${found[1]}ms upstream (constant '${constName}'); left as is`);
    return;
  }
  editModuleAt(m.index, body => body.replace(decl, `var ${repEsc(constName)}=${THROTTLE_MS}`));
  applied.push(`statusline throttle 300 -> ${THROTTLE_MS}ms (constant '${constName}')`);
});

step('24 bypass permissions under sudo', () => {
  // CONSTRAINT: two independent guards refuse bypassPermissions under root euid
  // and SHARE the same error text. Site A -- exported refuseBypassUnderRoot(),
  // condition isRootOutsideDeliberateSandbox(). Site B -- startup inline check,
  // condition process.getuid()===0. A locator on the shared console.error/exit
  // body resolves BOTH on 2.1.272/273 but MISSES site B on 2.1.274, where
  // upstream spliced `await <telemetry>(...)` between console.error and
  // process.exit: the continuous body literal stops matching while the guard
  // stays fully live. The old body-count form then saw count===1 and reported
  // "the other already neutralised upstream" -- false; site B was live. So each
  // guard is neutralised by its OWN structural anchor; site B by its CONDITION
  // (a false condition makes the guarded exit unreachable whatever the
  // rewritable body becomes); and a site located NEITHER live nor
  // already-neutralised is a hard failure, never a silently absorbed count.
  //
  // Site A anchor includes the isRoot condition to stay site-specific (the bare
  // body is shared with site B on 272/273). Neutralise the body.
  const guardA =
    'isRootOutsideDeliberateSandbox())console.error("--dangerously-skip-permissions ' +
    'cannot be used with root/sudo privileges for security reasons"),process.exit(1)';
  const doneA = 'isRootOutsideDeliberateSandbox())void 0';
  const condB = 'process.getuid()===0&&process.env.IS_SANDBOX!=="1"';
  const doneB = '!1&&process.env.IS_SANDBOX!=="1"';
  for (const [label, live, done] of [['A', guardA, doneA], ['B', condB, doneB]]) {
    const nLive = js.split(live).length - 1;
    const nDone = js.split(done).length - 1;
    if (nLive + nDone === 0) {
      fail(
        `root/sudo guard site ${label} located neither live nor neutralised — ` +
          `upstream may have reworded it; re-check before neutralising`,
      );
    }
    if (nLive + nDone > 1) {
      fail(`root/sudo guard site ${label} matched ${nLive + nDone} times, expected exactly one`);
    }
    if (nLive === 1) js = js.split(live).join(done);
  }
  // Postcondition: no LIVE guard survives. Assert on the STRUCTURES -- the error
  // text lingers in the bun string pool and in site B's now-dead body, so a bare
  // text search would false-positive.
  if (js.split(guardA).length - 1 !== 0) fail('root/sudo guard site A survived neutralisation');
  if (js.split(condB).length - 1 !== 0) fail('root/sudo guard site B survived neutralisation');
  applied.push('root/sudo refusal neutralised at both guards (site A body, site B condition)');
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
  // CONSTRAINT: the anchor keys on exactly these two property names -- they are
  // the session-options pair the prompt-head builder reads, and upstream has
  // spelled them out verbatim on every release so far (251 through 266) while
  // the shapes AROUND them changed twice. The property-ACCESS half
  // (`\1.isNonInteractiveSession`) must not be weakened to a bare literal: the
  // same two KEYS also sit on a trap object
  // `{isNonInteractive:!1,hasAppendSystemPrompt:!1}` in another array, and a
  // key-only anchor would light that one up and splice the rule into the
  // wrong list.
  const ANCHOR = new RegExp(
    'isNonInteractive:(' + ID + ')\\.isNonInteractiveSession,' +
    'hasAppendSystemPrompt:\\1\\.hasAppendSystemPrompt',
  );
  // CONSTRAINT: uniqueness is asserted BEFORE anything is edited, on the
  // global count. Minified names are chunk-local since 2.1.242, so a second
  // same-shaped site is a live possibility, and the check block at the end of
  // this script asks only whether text EXISTS somewhere, never WHERE it sits:
  // it cannot cover for a rewrite of the wrong same-shaped site.
  const sites = [...js.matchAll(new RegExp(ANCHOR.source, 'g'))];
  if (sites.length !== 1) fail(`expected 1 system-prompt options site, found ${sites.length}`);
  const OPTS = sites[0][1];
  const aStart = sites[0].index;

  // 2.1.265 hoisted the builder call out of the array that carries the prompt
  // (`t=Zo([Wo,tGt({...}),...])` became `hs=Eqt({...});...n=ns([fa,hs,...])`),
  // so the options object no longer has to sit INSIDE the array it feeds, and
  // a regex that pins the old layout refuses. From the anchor, walk LEFT to
  // the nearest `{` -- it opens the options object. The char before it must be
  // `(` (the object is an argument of the builder call), and what stands
  // before the call name decides the form: `<ID>=` is the hoisted form (the
  // array carries the RESULT by name), anything else is the inline form (the
  // call itself is an array element).
  const window80 = at => JSON.stringify(js.slice(Math.max(0, at - 40), at + 40));
  let oi = -1;
  for (let i = aStart - 1; i >= Math.max(0, aStart - 200); i--) {
    if (js[i] === '{') { oi = i; break; }
  }
  if (oi === -1)
    fail(`no object literal within 200 chars left of the options site (${window80(aStart)})`);
  if (js[oi - 1] !== '(')
    fail(`options object is not a call argument (${window80(oi)})`);
  let ci = oi - 2;
  if (ci < 0 || !/[\w$]/.test(js[ci]))
    fail(`no call name left of the options object (${window80(oi - 1)})`);
  while (ci - 1 >= 0 && /[\w$]/.test(js[ci - 1])) ci--;
  if (!/^[A-Za-z_$]/.test(js[ci]))
    fail(`call name left of the options object is not an identifier (${window80(ci)})`);
  let TARGET = null;
  if (js[ci - 1] === '=') {
    let ti = ci - 2;
    if (ti < 0 || !/[\w$]/.test(js[ti]))
      fail(`'=' before the builder call is not an assignment (${window80(ci)})`);
    while (ti - 1 >= 0 && /[\w$]/.test(js[ti - 1])) ti--;
    if (!/^[A-Za-z_$]/.test(js[ti]))
      fail(`assignment target before the builder call is not an identifier (${window80(ci)})`);
    TARGET = js.slice(ti, ci - 1);
  }

  // The array is found by BALANCE, not by shape. Every `].filter(Boolean)` in
  // the bundle is a candidate; from its `]` the walk counts brackets of all
  // three kinds leftwards, skipping string literals: a quote met while
  // walking left is the CLOSING delimiter, its opener is the next same-kind
  // quote behind an EVEN number of backslashes, and none within the window
  // means the quote never closes there -- that candidate is dropped (a
  // mismatched `{`/`(` where the balance should open drops it too). The
  // bracket pair that opens as `[` is the candidate's array. A candidate
  // passes only if it is OUR array: the anchor lies inside it (inline form),
  // or its body carries TARGET as a whole token (hoisted form -- `hs2` is not
  // `hs`).
  const LIT = '].filter(Boolean)';
  const passing = [];
  let at = js.indexOf(LIT);
  while (at !== -1) {
    const fi = at;
    const floor = Math.max(0, fi - 1000);
    let i = fi - 1;
    let depth = 0;
    let open = -1;
    let done = false;
    while (i >= floor) {
      const c = js[i];
      if (c === "'" || c === '"' || c === '`') {
        let j = i - 1;
        let found = -1;
        while (j >= floor) {
          if (js[j] === c) {
            let bs = 0;
            let k = j - 1;
            while (k >= floor && js[k] === '\\') { bs++; k--; }
            if (bs % 2 === 0) { found = j; break; }
          }
          j--;
        }
        if (found === -1) break; // unterminated quote: drop this candidate
        i = found - 1;
        continue;
      }
      if (c === ']' || c === '}' || c === ')') depth++;
      else if (c === '[' || c === '{' || c === '(') {
        depth--;
        if (depth < 0) {
          if (c === '[') { open = i; done = true; }
          break;
        }
      }
      i--;
    }
    if (done) {
      const body = js.slice(open + 1, fi);
      const ok =
        TARGET === null
          ? aStart >= open && aStart < fi
          : new RegExp('(^|[\\[,.\\s])' + rxEsc(TARGET) + '([,\\]\\s.]|$)').test(body);
      if (ok) passing.push({ fi, len: body.length });
    }
    at = js.indexOf(LIT, at + 1);
  }
  // CONSTRAINT: exactly one candidate may pass. Two passing arrays would mean
  // two lists equally entitled to the rule, and picking either silently is the
  // minifier's call, not ours.
  if (passing.length !== 1)
    fail(`expected 1 system-prompt assembly array, found ${passing.length}`);
  const fi = passing[0].fi;
  // Plausibility bounds: the prompt-head array is small on every known
  // version (129 chars on 2.1.263, 21 on 2.1.265/266). A walk that crossed a
  // statement boundary would hand back a huge "array"; a stray `[]` would be
  // tiny. Both are refusals, not patches.
  if (passing[0].len < 10 || passing[0].len > 2000)
    fail(`system-prompt assembly array body is ${passing[0].len} chars, outside [10,2000]`);

  // Волна 31 (K-3): то же правило для правила в системном промпте --
  // выключенный судья не должен оставлять свой текст. Инлайн-читатель
  // (каноническая форма __envon объявлена в ядре, сюда не видна).
  const insertion =
    ',...((()=>{let __s=String(process.env.CLAUDE_JUDGE??"").trim().toLowerCase();' +
    'if(__s===""||__s==="0"||__s==="false"||__s==="off"||__s==="no")return !1;' +
    'let __c=String(process.env.CLAUDE_JUDGE_CARRIER??"").trim().toLowerCase();let __d=String(process.env.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS??"").trim().toLowerCase();return __c!=="mod"||(__d!=="1"&&__d!=="true")})()' +
    `&&${OPTS}?.agentContext?.agentType==="main"?` +
    '[' + JSON.stringify(RULE) + ']' +
    ':[])';
  // CONSTRAINT: the edit is an offset splice, never String.replace -- in a
  // replacement string `$&`, "$`", "$'" and `$1`..`$9` are replace's own
  // syntax and would rewire the rule text or the spliced names. Spliced by
  // index, the bytes land in the image exactly as written here.
  js = js.slice(0, fi) + insertion + js.slice(fi);
  applied.push(`system prompt: dispatch-cancellation rule (options '${OPTS}')`);
});


// --------------------------------------------------------------------------
// 27. THE FULL-BYPASS MODE BYPASSES EVERYTHING.
//     The "ask" decision carries the circuitBreaker field; some circuit
//     breakers are marked bypassImmune in the registry, and the full-bypass mode
//     has no effect on them — the request reaches the human. Practical case:
//     removal whose path does not resolve statically (glob, `~`, the working
//     directory and its ancestors) is marked `dangerousRemoval` with immunity,
//     and a session started with a full-bypass key still stops on it.
//     Only the full-bypass branch is patched: in the other modes the circuit
//     breaker works as before, and the predicate's second consumer (picking a
//     representative among several results of one command) is untouched.
// --------------------------------------------------------------------------
step('27 full-bypass mode keeps only the peer-machine immunity', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const before = js.length;

  // f=p&&l?.behavior==="ask"?_B(l.decisionReason,FMn):void 0;
  // Anchored on shape, not on names: p is the mode predicate computed a line
  // above, l the accumulated decision, FMn the immunity predicate.
  // 2.1.257 дописал в ТУ ЖЕ цепочку `let` следующее объявление, и выражение
  // кончается теперь ЗАПЯТОЙ, а не точкой с запятой. Терминатор захватывается и
  // воспроизводится дословно: замена ниже собирает строку заново, и жёстко
  // вписанная `;` разорвала бы цепочку -- соседнее объявление превратилось бы в
  // присваивание необъявленной переменной. Ослабить пин, не тронув замену, было
  // бы хуже отказа: сборка стала бы зелёной и сломанной.
  const rx = new RegExp(
    `(${ID})=(${ID})&&(${ID})\\?\\.behavior==="ask"\\?` +
      `(${ID})\\(\\3\\.decisionReason,(${ID})\\):void 0([;,])`,
  );
  const m = js.match(rx);
  if (!m) fail('bypass-immunity site not found');

  // The neighboring line must turn out to be the full-bypass-mode branch:
  // without this cross-check the locator could land on a same-shaped form in a
  // different gate.
  const head = js.slice(Math.max(0, m.index - 260), m.index);
  if (!head.includes('"bypassPermissions"')) {
    fail('bypass-immunity site is not the permission-mode branch');
  }

  // Реестр предохранителей РАСТЁТ от версии к версии, и перечень здесь -- не
  // закрытый список, а замер. На 2.1.246 иммунными были двое; замер 2026-09-01:
  //   2.1.252: dangerousRemoval, isolatePeerMachines, restrictedMode
  //   2.1.257: те же плюс outsideReadsBlocked
  //   (backgroundOperator и suspiciousWindowsPath -- bypassImmune:!1 в обеих)
  //
  // Сужение ниже адресное: иммунитет снимается ИМЕНОВАННО у dangerousRemoval,
  // поэтому всякий новый предохранитель сохраняет иммунитет по умолчанию. Это и
  // есть причина писать правку через имя, а не через «оставить только первый».
  //
  // Writing `void 0` here dropped BOTH. isolatePeerMachines is the guard that
  // keeps one machine's session from acting on another machine through a peer
  // channel -- it is not the friction this step exists to remove, and a session
  // holding a full-bypass key is exactly the session that should still stop
  // there. Only dangerousRemoval's immunity is lifted now.
  //
  // The narrowing goes into the PREDICATE, not around the call: whatever
  // traversal the helper does over composite decision reasons is preserved
  // unchanged, and the only difference is which breaker the predicate admits.
  // The parameter name is deliberately long-ish -- a one-letter name could
  // shadow a binding the surrounding minified scope relies on.
  if (!js.includes('dangerousRemoval')) {
    fail(
      'bypass-immunity narrowing targets `dangerousRemoval`, which is absent ' +
        'from this build -- the breaker was renamed and this step would strip nothing',
    );
  }
  js =
    js.slice(0, m.index) +
    `${m[1]}=${m[2]}&&${m[3]}?.behavior==="ask"?` +
      `${m[4]}(${m[3]}.decisionReason,(__ccbr)=>` +
      `__ccbr.circuitBreaker!=="dangerousRemoval"&&${m[5]}(__ccbr)):void 0${m[6]}` +
    js.slice(m.index + m[0].length);

  applied.push(
    `full-bypass mode lifts only the dangerousRemoval immunity, peer-machine ` +
      `isolation still stops (flag '${m[1]}', mode predicate '${m[2]}', ` +
      `decision '${m[3]}', immunity predicate '${m[5]}', ${js.length - before} bytes)`,
  );
});


// --------------------------------------------------------------------------
// 28. Refusal fallback: the routes table reads the config seam, and the top
//     of the lineup is reachable again -- both ONLY while the operator has
//     set CLAUDE_CODE_REFUSAL_FALLBACK_ROUTES.
//     Upstream consults `e.routesOverride ?? <stock table>()` on both refusal
//     lanes but ships the seam EMPTY (`function <seam>(){return}`), so the
//     stock table always wins. And a firstParty-only predicate quietly swaps
//     the armed model claude-opus-5 -> claude-opus-4-8 wherever it is asked
//     for, keeping the top of the lineup out of the fallback chain.
//
//     The predicate itself stays STOCK: it has THREE consumers, not two, and
//     they want different things. Applied to the MAPPED TARGET (the `DJ`
//     ternary) it silently rewrites a configured {"bio":"claude-opus-5"}
//     back to claude-opus-4-8 -- that reading is disarmed BY THE HANDLE.
//     Applied to the ARMED model (`UOn`) the same downgrade is PROTECTION,
//     not censorship: without it a firstParty user who configured nothing
//     would trade "refusal of opus-5, recover through opus-4-8" for a
//     self-retry of the very same model, because the catch-all lane is
//     already gated by armedTargetIsRefusingModel -- a regression this
//     patch must not introduce, so `UOn` is not touched in ANY case. And
//     the lineup exclusion `!<pred>(<x>)` inside the find runs
//     UNCONDITIONALLY on the walk_down_opus_lineup path (sticky-model
//     selection and suppression), not only on refusals -- ungating it
//     outright would let the most expensive top of the lineup be picked
//     where nobody asked for it, with no switch to turn it off.
//
//     Hence opt-in: with the handle unset (or rejected by the parser) the
//     image behaves exactly like stock; with the handle set the operator
//     has asked for his targets to be respected, and both disarms come
//     alive. The cloud-provider branch of the `DJ` ternary (`<L>`) is NOT
//     measured and NOT touched: patching on unproven semantics is forbidden
//     by the same rule that forbids a locator resting on an unproven scope.
//
//     ALL edits below go through editModuleAt, never over the whole text.
//     The predicate's minified name is ALSO a string constant of an
//     unrelated chunk (on 2.1.270 `$On` is "Teammate prompt must not be a
//     mailbox protocol frame..." in chunk-jb9wm99y.js, exported as
//     PROTOCOL_FRAME_PROMPT_ERROR), and the seam's letters recur across the
//     bundle under other scopes -- the total count is platform-dependent
//     (the linux build renames the seam outright), so no whole-bundle
//     number pins anything; the only occurrences inside the refusal module
//     are the definition and the two call sites, which is why every edit
//     here is scoped to that one module -- a whole-text edit would land on
//     whichever chunk the minifier happened to spell the same.
// --------------------------------------------------------------------------
step('28 refusal fallback routes from config, top of lineup reachable', () => {
  const ID = '[A-Za-z_$][\\w$]*';

  // --- site A: bring the routesOverride seam to life -----------------------
  // The seam's minified name is deliberately NOT pinned: both refusal lanes
  // call it as `routesOverride:<name>()`, so the CALL SITES name the
  // function (root #75 -- a locator that pins a minified name breaks on the
  // next build for no structural reason). Two lanes, one name, or refuse.
  const callSites = [...js.matchAll(new RegExp(`routesOverride:(${ID})\\(\\)`, 'g'))];
  const seamNames = [...new Set(callSites.map((m) => m[1]))];
  if (callSites.length !== 2 || seamNames.length !== 1) {
    fail(
      `routesOverride seam: expected exactly 2 call sites naming one ` +
        `function, found ${callSites.length} call site(s) ` +
        `(${seamNames.join(', ') || 'no name captured'})`,
    );
  }
  const seam = seamNames[0];

  // The empty definition is located STRUCTURALLY: which module holds it is a
  // fact to be measured, not assumed. Two shapes are live and both are taken:
  //   * SAME-MODULE (measured through 2.1.278): the definition sits between the
  //     same pair of boundaries as its call sites;
  //   * SPLIT (measured on 2.1.280): upstream moved the definition into another
  //     chunk -- `function _kn(){return}` in chunk-7kwd28ae.js against both
  //     `routesOverride:_kn()` in chunk-dt8bvbsd.js -- and the calling module
  //     reaches it through an ESM import.
  // What has to be proven is IDENTITY of the symbol, and co-membership was only
  // ever a proxy for it. The split shape proves it by a chain instead: the
  // definition is UNIQUE in the whole image, the module holding it EXPORTS that
  // name, the calling module IMPORTS that name, and the calling module does not
  // bind it itself. One definition in existence plus a caller that imports
  // rather than declares leaves the call site no other referent.
  // CONSTRAINT: every name test is BOUNDED. On 2.1.280 the seam is spelled
  // `_kn`, which also occurs as a SUBSTRING inside `tengu_virtual_knuth` and
  // `tengu_known_marketplaces_fallback_write` in the very module that calls it:
  // an unbounded count reads 4 where the bounded one reads 3 (one import, two
  // call sites). A locator that counts substrings counts the wrong thing.
  const seamDef = `function ${rxEsc(seam)}\\(\\)\\{return\\}`;
  const bounded = n => `(?<![\\w$])${rxEsc(n)}(?![\\w$])`;
  const seamModule = moduleTextAt(callSites[0].index);
  const [callModStart] = moduleSliceAround(js, callSites[0].index);
  const inCall = [...seamModule.matchAll(new RegExp(seamDef, 'g'))];
  // Where the edit lands. The seam's BODY is rewritten, so the edit follows the
  // definition into whichever module owns it -- never the call module, which on
  // the split shape holds no definition to rewrite.
  let seamDefPos;
  if (inCall.length === 1) {
    seamDefPos = callModStart + inCall[0].index;
  } else if (inCall.length > 1) {
    fail(
      `шов routesOverride определён ${inCall.length} раза в модуле своего вызова ` +
        `(имя '${seam}') -- какое из них править, не определено`,
    );
  } else {
    const all = [...js.matchAll(new RegExp(seamDef, 'g'))];
    if (all.length !== 1) {
      fail(
        `шов routesOverride: пустое определение '${seam}' встречается во всём ` +
          `образе ${all.length} раз (в модуле вызова -- ни разу), тождество символа ` +
          `не доказуемо`,
      );
    }
    seamDefPos = all[0].index;
    const defModule = moduleTextAt(seamDefPos);
    // The definition's module must ANNOUNCE the name, and the call module must
    // ASK for it. Either half alone is satisfied by coincidence: a module may
    // export a name nobody imports, and an import list may name a symbol this
    // module never calls. Together with uniqueness they pin the referent.
    const exported = (defModule.match(/export\{[^}]*\}/g) || []).some(x =>
      new RegExp(bounded(seam)).test(x),
    );
    const imported = (seamModule.match(/import\{[^}]*\}from"[^"]*"/g) || []).some(x =>
      new RegExp(bounded(seam)).test(x),
    );
    // A local binding in the call module would SHADOW the import, and then the
    // call site's referent is that binding, not the definition found above.
    const shadowed = new RegExp(
      `(?:function|var|let|const|class)\\s+${rxEsc(seam)}(?![\\w$])`,
    ).test(seamModule);
    if (!exported || !imported || shadowed) {
      fail(
        `шов routesOverride: тождество символа '${seam}' не доказано через ` +
          `связку модулей: экспорт в модуле определения=${exported}, ` +
          `импорт в модуле вызова=${imported}, собственное связывание в модуле ` +
          `вызова=${shadowed}`,
      );
    }
  }

  // BOTH call sites must sit in that same module. The whole-text pin above
  // would still pass if the unpacker's module boundaries had split the two
  // refusal lanes apart -- the edit would revive one lane's seam while the
  // other kept calling the empty stock stub, and neither fail() nor the
  // on-image check can see a lane they never look at.
  const seamCalls = seamModule.match(new RegExp(`routesOverride:${rxEsc(seam)}\\(\\)`, 'g')) || [];
  if (seamCalls.length !== 2) {
    fail(
      `routesOverride call sites have split across modules: expected both 2 ` +
        `in the seam's module, found ${seamCalls.length} -- the edit would ` +
        `cover only part of the refusal lanes`,
    );
  }

  // The replacement body uses NOT ONE captured name -- only `process.env`,
  // `JSON`, `Object`, `Array` and `console`: a `$` inside a minified name
  // spliced into a replacement is a group reference and into a pattern an
  // anchor, so a body borrowing the seam's own name could silently edit a
  // different function. The env key follows the mechanism's existing
  // controls (CATCH_ALL / DISABLE / NO_MODEL_FALLBACK) rather than taste:
  // the ~/.claude.json accessor is NOT PROVEN to be in scope at the seam,
  // and a locator may not rest on an unproven scope. Nothing is ever
  // WRITTEN anywhere on any path -- the config is only read; the one stderr
  // line below goes to the console, not to a user file.
  //
  // The parse result -- including `undefined` -- is cached in the closure,
  // because site B now calls the seam on hot refusal-lane walks and a
  // JSON.parse per call would be a tax the stock image never pays. The
  // cache key is the RAW value of the variable, not the fact of a first
  // read: the image itself rewrites the environment mid-process (it layers
  // settings over `process.env`, a warm restart re-enters `main()` with
  // `Object.assign(process.env,<e>.env)` in the same process, and the
  // plugin surface's `env.set` writes `process.env[<name>]=<value>` with
  // no allowlist), and the first seam call happens mid-session, so a cache
  // keyed by first read would serve a stale table on live roads. The cache
  // holds the PAIR (raw string, parsed value): the hot path is one property
  // read and one string compare, and the parse reruns only when the string
  // has CHANGED. An unset variable is normalized to "" so the key is
  // comparable on every call. The rejection print is therefore exactly
  // once per DISTINCT rejected value, not once per process: an operator
  // who sets a wrong value twice must be told twice -- that is the correct
  // behaviour, not a regression.
  //
  // The cache is `var`, not `let`: the seam is a function declaration and
  // hoists, so a call textually ABOVE the insertion point must already
  // work; a `let` there would sit in the temporal dead zone and throw a
  // ReferenceError exactly where the promise is "behaves like stock".
  // `var` at module top level can collide with a foreign one in the glued
  // bundle, so the name is required to be unused over the WHOLE image --
  // measured on the 2.1.270 stock: 0 occurrences of '__rfr'.
  const cache = '__rfr';
  if (new RegExp(`(?<![\\w$])${rxEsc(cache)}(?![\\w$])`).test(js)) {
    fail(`cache name '${cache}' is already used in the bundle`);
  }

  // The config parse failure is CLOSED on purpose: any invalid value -- not
  // an object, an array, a key whose value is neither a string nor a
  // non-empty array of strings, or a string that is empty after trimming
  // whitespace -- returns undefined, and the consumer takes the stock table
  // WHOLE. A string that trims to nothing is not a route name: the consumer
  // would resolve an empty target and silently lose that route while both
  // site-B disarms are already live (measured by execution). The SAME test
  // runs on every MEMBER of an array value, and it is not symmetry for its
  // own sake: an array is a chain of hops, so an empty member is an empty
  // hop -- the identical harm one level down. The first form of this reader
  // tested members only for `typeof === "string"`, and execution over the
  // value domain caught it: `{"k":["",""]}` was accepted whole while
  // `{"k":""}` was already rejected. Rejecting the
  // one key and keeping the rest would hand the consumer half a table,
  // which is worse than no table: some routes would silently keep their
  // stock destinations while the config claims to own them. The rejection
  // is announced once per DISTINCT rejected value and only when the
  // variable was non-empty -- whoever never set it sees nothing by
  // construction.
  editModuleAt(seamDefPos, (body) =>
    body.replace(
      new RegExp(seamDef),
      `var ${repEsc(cache)};function ${repEsc(seam)}(){` +
        `let e=process.env.CLAUDE_CODE_REFUSAL_FALLBACK_ROUTES??"";` +
        `if(${repEsc(cache)}===void 0||${repEsc(cache)}.s!==e){` +
        `let v=void 0;` +
        `if(e){try{let r=JSON.parse(e);` +
        `if(r!==null&&typeof r==="object"&&!Array.isArray(r)){` +
        `let ok=!0;for(let k of Object.keys(r)){let x=r[k];` +
        `if(typeof x==="string"){if(x.trim()!=="")continue;ok=!1;break}` +
        `if(Array.isArray(x)&&x.length>0&&x.every((y)=>typeof y==="string"&&y.trim()!==""))continue;ok=!1;break}` +
        `if(ok)v=r}}catch{}` +
        `if(v===void 0)console.error("CLAUDE_CODE_REFUSAL_FALLBACK_ROUTES is not a valid routes object; using the stock refusal fallback table")}` +
        `${repEsc(cache)}={s:e,v:v}}` +
        `return ${repEsc(cache)}.v}`,
    ),
  );
  applied.push(
    `refusal-fallback routes from config (seam '${seam}', 2 call site(s), ` +
      `env key 'CLAUDE_CODE_REFUSAL_FALLBACK_ROUTES')`,
  );

  // --- site B: the downgrade and the lineup exclusion become opt-in -------
  // The predicate itself is left STOCK (see the step header): only its two
  // harmful readings are gated by the handle.
  //
  // The entry point is the DOWNGRADE READER -- the one function whose entire
  // body is "predicate holds ? the downgrade constant : the input". That is
  // this step's subject stated as BEHAVIOUR, so it survives a rewrite of
  // whatever surrounds it. The earlier form entered through a constants-and-
  // predicate BUNDLE, which required the two `var`s and the predicate to be
  // textually adjacent and the predicate's body to be exactly two conjuncts.
  // 2.1.276 interposed an unrelated function between them and grew the body
  // to three conjuncts with the model comparison moved inside a `.some()`
  // callback: the subject never moved, the locator did.
  //
  // Whole-text uniqueness is required HERE and not on the constant, because
  // the constant is not unique: 2.1.276 carries two bindings of
  // "claude-opus-4-8" and two of "claude-opus-5", so a locator entering
  // through the string alone can land on the foreign one. The reader is
  // unique; the constant is then checked THROUGH it -- uniqueness says there
  // is one such function, the content string says it is the opus downgrade.
  const readerRx =
    `function (${ID})\\((${ID})\\)\\{return (${ID})\\(\\2\\)\\?(${ID}):\\2\\}`;
  const readerAll = js.match(new RegExp(readerRx, 'g'));
  if (!readerAll || readerAll.length !== 1) {
    fail(
      `mapped-target downgrade reader: expected exactly 1 match over the ` +
        `whole text, found ${readerAll ? readerAll.length : 0}`,
    );
  }
  const bundle = js.match(new RegExp(readerRx));
  const [, B, , A, F] = bundle;

  // Shape alone would also fit an unrelated `p(x)?K:x` if upstream ever
  // leaves only one of those; the content string is what makes the match an
  // identification rather than a coincidence.
  if (!new RegExp(`(?<![\\w$.])${rxEsc(F)}="claude-opus-4-8"`).test(js)) {
    fail(
      `downgrade constant '${F}' is not bound to "claude-opus-4-8" -- the ` +
        `reader found is not the opus downgrade`,
    );
  }
  // Cosmetic: it only names the constants in the applied line, and no edit
  // below mentions it. Its absence must therefore NOT fail the step -- a
  // locator may not refuse over something the edit does not use.
  const mHit = js.match(
    new RegExp(`${rxEsc(F)}="claude-opus-4-8",(${ID})="claude-opus-5"`),
  );
  const M = mHit ? mHit[1] : '(not adjacent)';

  // The opt-in shapes written below NAME the seam (`<S>()`), so what has to
  // hold is that the name RESOLVES to our seam inside site B's module. The
  // earlier form asked instead whether site B sits in the module of the
  // seam's CALL SITES -- a proxy that held only while definition and calls
  // shared one chunk (through 2.1.278) and that measures the wrong module
  // once they split: on 2.1.280 the definition and site B are both in
  // chunk-7kwd28ae.js while the two `routesOverride:<S>()` calls are in
  // chunk-dt8bvbsd.js, so the proxy refuses an edit that is in fact sound.
  // The seam's letters are not unique: on the 2.1.270 stock the whole image
  // carries them 16 times on darwin and 23 on linux, of which ours are the
  // definition and the two call sites alone -- every other binding of those
  // letters is foreign, so resolution must be PROVEN, never assumed.
  // Two shapes resolve, and nothing else does:
  //   * site B in the DEFINITION's module -- the name is in lexical scope;
  //   * site B elsewhere -- only if that module IMPORTS the name (bounded)
  //     and does not bind it itself, which would shadow the import.
  // This check is also what scopes the reader: it is located over the whole
  // text, so its module membership is proven here rather than assumed.
  const seamDefBounds = moduleSliceAround(js, seamDefPos);
  const bundleBounds = moduleSliceAround(js, bundle.index);
  if (bundleBounds[0] !== seamDefBounds[0]) {
    const bMod = moduleTextAt(bundle.index);
    const importedInB = (bMod.match(/import\{[^}]*\}from"[^"]*"/g) || []).some(x =>
      new RegExp(bounded(seam)).test(x),
    );
    const shadowedInB = new RegExp(
      `(?:function|var|let|const|class)\\s+${rxEsc(seam)}(?![\\w$])`,
    ).test(bMod);
    if (!importedInB || shadowedInB) {
      fail(
        `site B cannot reach the seam '${seam}': the downgrade reader sits at ` +
          `offset ${bundle.index}, outside the module that defines the seam ` +
          `(offset ${seamDefPos}), and that module ` +
          `${importedInB ? 'imports the name but also binds it itself (the import is shadowed)' : 'does not import the name'} ` +
          `-- the edit would spawn an unresolvable or foreign reference`,
      );
    }
  }

  // Structural pin instead of a pin on the written shape: within the SAME
  // module the predicate must be READ exactly twice (every mention minus its
  // own definition). A reader added upstream must fail here loudly rather
  // than silently survive a dead predicate.
  const modText = moduleTextAt(bundle.index);
  const mentions = [
    ...modText.matchAll(new RegExp(`(?<![\\w$])${rxEsc(A)}(?![\\w$])`, 'g')),
  ].length;
  const readers = mentions - 1;
  if (readers !== 2) {
    fail(`число читателей предиката понижения изменилось: ${readers}`);
  }

  // Reading 1 -- the lineup exclusion inside the find. On 2.1.270 the
  // module reads `pFn().find((s)=>Vq(je(s))&&!$On(s)&&r(s))`, and this walk
  // runs unconditionally on the walk_down_opus_lineup path (sticky-model
  // selection and suppression), which is exactly why it may only open
  // together with the handle. The `!` is part of the locator so the edit
  // lands on the EXCLUSION, not on some other call of the predicate; the
  // argument name is captured here, never borrowed from the bundle.
  const exclRx = `!${rxEsc(A)}\\((${ID})\\)`;
  const exclHits = modText.match(new RegExp(exclRx, 'g')) || [];
  if (exclHits.length !== 1) {
    fail(
      `lineup exclusion site: expected exactly one !<pred>(<x>) in the ` +
        `module, found ${exclHits.length}`,
    );
  }
  const exclArg = modText.match(new RegExp(exclRx))[1];

  // Reading 2 -- the mapped-target downgrade. `<B>` is the reader this step
  // entered through, so it is already known and already proven unique over
  // the whole text and resident in this module; the ternary is located
  // THROUGH its name: `<W>()?<B>(<x>.id):<L>(<x>.id)`. The `<L>` branch is
  // deliberately NOT touched: its semantics (the cloud-provider family
  // default) is not measured, and a locator may not rest on an unproven
  // scope any more than an edit may rest on unproven semantics.
  const ternRx = `(${ID})\\(\\)\\?${rxEsc(B)}\\((${ID})\\.id\\):(${ID})\\(\\2\\.id\\)`;
  const ternHits = modText.match(new RegExp(ternRx, 'g')) || [];
  if (ternHits.length !== 1) {
    fail(
      `mapped-target downgrade ternary: expected exactly one ` +
        `<W>()?<B>(<x>.id):<L>(<x>.id) in the module, found ${ternHits.length}`,
    );
  }
  const [, W, t, L] = modText.match(new RegExp(ternRx));

  // With the handle UNSET both forms collapse to the stock ones:
  // `!(<S>()===void 0&&<A>(<x>))` is `!<A>(<x>)`, and
  // `<W>()?(<S>()===void 0?<B>(<x>.id):<x>.id):<L>(<x>.id)` is
  // `<W>()?<B>(<x>.id):<L>(<x>.id)`. With the handle SET both disarms are
  // live: the exclusion is gone and the mapped target is no longer
  // downgraded. The armed-model downgrade in `UOn` is NOT here on purpose.
  editModuleAt(bundle.index, (body) =>
    body
      .replace(
        new RegExp(exclRx),
        `!(${repEsc(seam)}()===void 0&&${repEsc(A)}(${repEsc(exclArg)}))`,
      )
      .replace(
        new RegExp(ternRx),
        `${repEsc(W)}()?(${repEsc(seam)}()===void 0?${repEsc(B)}(${repEsc(t)}.id):` +
          `${repEsc(t)}.id):${repEsc(L)}(${repEsc(t)}.id)`,
      ),
  );
  applied.push(
    `top-of-lineup reachable as a refusal fallback, opt-in with the routes ` +
      `config (predicate '${A}' kept stock, seam '${seam}', ` +
      `constants '${F}'/'${M}')`,
  );
});


// --------------------------------------------------------------------------
// 29. The mod API's per-plugin session model budget stops being a hardcoded
//     ceiling and becomes an operator-set one -- with the handle unset there
//     is NO cap at all.
//
//     Measured on 2.1.270 (live darwin image, offset 169291447):
//       var <a>=0.8;var <b>=4;var <c>=256;var <CAP>=2000000;var <warn>=<CAP>*<a>;
//       reserve:(r,s)=>{let d=<pend>.get(r)??0;
//         if((<spent>.get(r)??0)+d>=<CAP>)
//           throw new <E>(`${r}: $.model.complete: the session's model budget
//                          for this plugin is spent`);<pend>.set(r,d+s)}
//     The ceiling is 2 000 000 input+output tokens PER PLUGIN PER PROCESS and
//     it is a bare literal: upstream ships no handle beside it. The counter
//     only grows, so once it is reached EVERY later `$.model.complete` throws
//     for the rest of the process.
//
//     Why that is not someone else's problem: a mechanism that asks the model
//     on EVERY tool call spends the ceiling inside one working session. Our
//     dispatch judge is exactly such a mechanism, and being enforce +
//     fail_closed it converts its own resource exhaustion into a POLICY
//     denial -- on 2026-09-14 the whole subagent fan-out went down until the
//     process was restarted, with all three rungs refusing at once in 31 ms:
//       err_<rung> = "$.model.complete: the session's model budget ... is spent"
//     Restarting clears it because the counter lives in process memory; it is
//     therefore a ceiling on how long ONE session may work, not on cost.
//
//     The edit does NOT delete the accounting and does NOT touch the refusal:
//     it replaces only the ceiling's INITIALISER. With the handle unset the
//     comparison `>= Infinity` is never true, and the 80% warning (whose
//     threshold is derived as ceiling*0.8, i.e. Infinity too) never fires --
//     so no message is left claiming a limit that no longer exists. With the
//     handle set to a positive finite number the stock shape returns whole,
//     ceiling and warning together; a garbage value is NOT silently taken as
//     zero, it falls back to no cap.
//
//     The ceiling's minified name is NOT pinned (root #75): it is READ OUT of
//     the comparison that the refusal guards, and the refusal itself is found
//     by its own user-visible message. The declaration is then required to be
//     unique INSIDE that refusal's module -- the same letters under another
//     scope are a different variable, and the bundle is split into ~1400
//     chunks.
// --------------------------------------------------------------------------
step('29 mod-API session model budget ceiling becomes operator-set', () => {
  const ID = '[A-Za-z_$][\\w$]*';

  // CONSTRAINT: two different zeros. "The mechanism is gone" -- upstream
  // deleted the mod-session budget WHOLE -- is not a failure: the subject of
  // this step no longer exists, and refusing for that would drop every later
  // patch for nothing. "The shape moved" -- the anchor below no longer
  // matches while the mechanism lives -- IS a failure, exactly as before.
  // The distinction is made by five witnesses naming the machinery from five
  // sides; the threshold is ALL FIVE dead. One reworded literal must not
  // retire the step: the first upstream rephrase of a message string would
  // silently turn this patch off.
  const WITNESSES = [
    "the session's model budget for this plugin is spent",
    ' session tokens spent',
    'budget for this plugin',
    'new Map,n=new Map;return{reserve:',
    'budgets.model',
  ];
  if (WITNESSES.every((w) => !js.includes(w))) {
    inapplicable.push(
      '29 mod-API model budget: апстрим удалил механизм бюджета мод-сессии ' +
        'целиком (пять свидетелей мертвы); предмет правки отсутствует',
    );
    return;
  }

  const guard = new RegExp(
    'if\\(\\(' + ID + '\\.get\\((' + ID + ')\\)\\?\\?0\\)\\+' + ID + '>=(' + ID + ')\\)' +
    'throw new ' + ID + '\\(`\\$\\{\\1\\}: \\$\\.model\\.complete: ' +
    "the session's model budget for this plugin is spent`\\)",
    'g',
  );
  const sites = [...js.matchAll(guard)];
  if (sites.length !== 1) {
    fail(
      `the mod-API budget refusal must occur exactly once, found ${sites.length} -- ` +
      `more than one site would mean the ceiling is consulted where this edit does not reach`,
    );
  }
  const cap = sites[0][2];
  const at = sites[0].index;

  // Uniqueness is required in the module that DEFINES the name, not in the
  // whole bundle: a whole-text count would be the minifier's call, not ours.
  const declSrc = 'var ' + rxEsc(cap) + '=(\\d+);';
  const mod = moduleTextAt(at);
  const decls = mod.match(new RegExp(declSrc, 'g')) || [];
  if (decls.length !== 1) {
    fail(
      `the ceiling '${cap}' must be declared exactly once in the refusal's module, ` +
      `found ${decls.length} -- the locator would rewrite an unrelated constant`,
    );
  }
  const stock = new RegExp(declSrc).exec(mod)[1];

  // The ceiling is read on EVERY consult, not once at module init. Step 28
  // already paid for the eager form of exactly this: the image moves its own
  // environment around while the process runs (settings, a warm restart, the
  // plugin platform's env.set), so a value read at load time can be the wrong
  // one by the time the guard consults it. An object with Symbol.toPrimitive
  // keeps that one site and stays a drop-in for a number: every use of this
  // name inside its module coerces it -- the guard's `>=`, the derived warning
  // threshold's `*`, and the warning text's template slot -- measured on the
  // 2.1.270 image, where the name occurs 4 times in this module (and 19 more
  // times ELSEWHERE in the bundle as unrelated bindings, which is why the
  // rewrite is scoped to the module and never to the image).
  //
  // Boundary, measured and deliberate: the derived warning threshold
  // (`var <w>=<cap>*<f>`) coerces ONCE, at module init. With the handle unset
  // -- the shipped default -- that freezes it at Infinity, so the 80 % notice
  // can never fire and the image cannot announce a limit that does not exist.
  // A handle set in the environment BEFORE the module loads is picked up by it
  // too; one set later tightens the ceiling without moving the notice. The
  // notice is informational, the ceiling is the guarantee, and only the
  // ceiling is made live here.
  editModuleAt(at, text =>
    text.replace(new RegExp(declSrc), () =>
      // ZERO IS NO CAP, and so is every other value that is not a usable
      // positive ceiling: unset, empty, non-numeric, negative, NaN. The
      // fall-through is Infinity in ALL of them on purpose -- an operator
      // writing 0 means "no budget ceiling", never "a ceiling of nothing",
      // and a value nobody can read must not quietly reintroduce the limit
      // it was written to remove.
      'var ' + cap + '={[Symbol.toPrimitive](){' +
      'let v=process.env.CLAUDE_CODE_MOD_MODEL_BUDGET;' +
      'if(v===void 0||v==="")return Infinity;' +
      'let n=Number(v);' +
      'return Number.isFinite(n)&&n>0?n:Infinity}};',
    ),
  );
  applied.push(
    `29 mod-API model budget: ceiling '${cap}' (stock ${stock}) now reads ` +
    `CLAUDE_CODE_MOD_MODEL_BUDGET; unset or unusable = no cap`,
  );
});

// --------------------------------------------------------------------------
// 30. The mod API's PER-CALL maxTokens ceiling stops being a hardcoded limit
//     and becomes an operator-set one -- with the handle unset there is NO
//     cap at all.
//
//     This is the SECOND door of the same room. Step 29 removed the budget a
//     plugin may spend across the process; this one removes the ceiling on a
//     SINGLE `$.model.complete`. Removing only the first leaves a mechanism
//     that may now call the model forever, but never with a reply longer than
//     8192 tokens -- and our dispatch judge's own recorded attempts ask for
//     24000. A limit that blocks the known consumer is not addressed by
//     lifting the limit beside it.
//
//     Measured on 2.1.270 (pristine darwin image, offset 174322645; the same
//     shape on linux at 194611162 under a different minified name -- sMt vs
//     cMt -- which is why nothing here is pinned by name):
//       var <LIM>=8192;
//         if(s!==void 0&&(!Number.isInteger(s)||s<1||s><LIM>))
//           throw new <E>(`${d}: $.model.complete: maxTokens must be an
//                          integer from 1 to ${<LIM>} (got ${String(s)})`);
//
//     2.1.276 SPLIT that one guard into three parts, and the split is the
//     reason the old locator found nothing (measured on both platforms,
//     pristine image, linux offset 198525450):
//       async function <f>({model:e,prompt:n,system:r,maxTokens:s},g,h){
//         if(s!==void 0&&(!Number.isInteger(s)||s<1))
//           throw new <E>(`${g}: $.model.complete: maxTokens must be a
//                          positive integer (got ${String(s)})`);
//         let w=<resolve>(e); ...
//         let <CEIL>=Math.min(<T>(w).upperLimit,<CAP>);
//         if(s!==void 0&&s><CEIL>)
//           throw new <E>(`${g}: $.model.complete: maxTokens ${s} is past
//                          what ${w} can produce in one reply (${<CEIL>})`);
//         let[L,B]=<th>(w),U=Math.min((s??<DEF>)+B,<CEIL>);
//     The CORRECTNESS half (`Number.isInteger`, `<1`) now stands on its own
//     and is not touched -- it refuses values the API could not use at all.
//     What moved is the ceiling: it is no longer a bare literal but the
//     smaller of what the model can physically produce and a SHARED cap
//     (64000 on 2.1.276). Only the shared cap is policy; `.upperLimit` is a
//     fact about the model.
//
//     The edit therefore sits on the ceiling's own BINDING, not on the
//     shared cap's declaration. That is not a stylistic choice: the cap is
//     handed to a second consumer in an unrelated request path, so rewriting
//     it where it is declared would move a ceiling this step never measured.
//     Sitting on the binding also makes the blast radius exact -- the
//     binding is a `let` inside the entry function, so every reader of it
//     (the refusal, the message slot, and the clamp that sets the request's
//     real max_tokens) is served by one replacement and none can be missed.
//
//     `<DEF>` (256 on 2.1.270) is deliberately NOT touched: it is the value a
//     caller gets by NOT passing maxTokens, and any caller that wants more
//     passes more. A default a consumer can lift is not a ceiling, and
//     rewriting it would change replies nobody asked us to change.
//
//     With the handle unset our term is Infinity, so the ceiling collapses
//     to `min(<model>.upperLimit, Infinity)` -- the model's own limit and
//     nothing else. The shared cap is gone; the physical one stays. This is
//     a DELIBERATE and named difference from the 2.1.270 edition of this
//     step, which left no bound at all and made the refusal announce "from 1
//     to Infinity": back then the guard carried no per-model term, so there
//     was nothing else to fall back to. Now there is, and keeping it is
//     strictly better -- the refusal names a real number, and the clamp that
//     builds the request cannot ask for what the model cannot produce.
//     What the API accepts beyond that remains the API's answer to give.
//
//     The ceiling's minified name is NOT pinned (root #75): it is READ OUT
//     of the comparison inside the refusal, and the refusal is found by its
//     own user-visible message. The locator does not pin the shape around
//     it either -- that is exactly what broke here: the earlier form welded
//     the three conditions of the old guard together as one closed `if`, so
//     upstream splitting them left the site in place and the locator behind.
// --------------------------------------------------------------------------
step('30 mod-API per-call maxTokens ceiling becomes operator-set', () => {
  const ID = '[A-Za-z_$][\\w$]*';

  // The refusal is found by its own user-visible message; the ceiling's
  // minified name is READ OUT of the comparison that refusal guards, and is
  // never pinned (root #75).
  const guard = new RegExp(
    'if\\((' + ID + ')!==void 0&&\\1>(' + ID + ')\\)throw new ' + ID + '\\(' +
    '`\\$\\{' + ID + '\\}: \\$\\.model\\.complete: maxTokens \\$\\{\\1\\} ' +
    'is past what \\$\\{' + ID + '\\} can produce in one reply ' +
    '\\(\\$\\{\\2\\}\\)`\\)',
    'g',
  );
  const sites = [...js.matchAll(guard)];
  if (sites.length !== 1) {
    fail(
      `the mod-API maxTokens ceiling refusal must occur exactly once, found ${sites.length} -- ` +
      `more than one site would mean the limit is consulted where this edit does not reach`,
    );
  }
  const ceil = sites[0][2];
  const at = sites[0].index;

  // The ceiling is a LOCAL binding of the entry function, so rewriting the
  // binding alone serves EVERY reader of it. That is also why the shared
  // constant it is built from is not rewritten where it is declared: that
  // constant has a second consumer in an unrelated request path (measured on
  // 2.1.276), and a ceiling somebody else depends on is not this step's
  // subject. The `.upperLimit` term is likewise left alone -- it is what the
  // model can physically produce, which is a fact, not a policy.
  const bindSrc =
    'let ' + rxEsc(ceil) + '=Math\\.min\\((' + ID + '\\(' + ID +
    '\\)\\.upperLimit),(' + ID + ')\\);';
  const mod = moduleTextAt(at);
  const binds = mod.match(new RegExp(bindSrc, 'g')) || [];
  if (binds.length !== 1) {
    fail(
      `the ceiling '${ceil}' must be bound exactly once in the refusal's module as ` +
      `min(<model>.upperLimit, <shared cap>), found ${binds.length}`,
    );
  }
  const [, modelTerm, cap] = mod.match(new RegExp(bindSrc));

  // The ceiling governs TWO things, not one: this refusal, and the
  // max_tokens the request actually carries. The clamp is pinned so that a
  // build which stops clamping -- or starts clamping with something else --
  // fails here loudly instead of silently changing what an unset handle
  // means for the bytes that leave the process.
  const clampSrc =
    '=Math\\.min\\(\\(' + ID + '\\?\\?' + ID + '\\)\\+' + ID + ',' +
    rxEsc(ceil) + '\\)';
  const clamps = mod.match(new RegExp(clampSrc, 'g')) || [];
  if (clamps.length !== 1) {
    fail(
      `the request's max_tokens must be clamped by the ceiling '${ceil}' exactly once, ` +
      `found ${clamps.length} -- the edit's reach and the request's bound have parted`,
    );
  }

  // Read on EVERY consult, not once at module init -- the same reason steps
  // 28 and 29 carry: the image moves its own environment around while the
  // process runs, so a value read at load time can be the wrong one by the
  // time the guard consults it. An inline expression replaces the coercing
  // object of the earlier edition because this binding now feeds arithmetic
  // AND a message slot from the same place, and a number is right in both
  // without a hint.
  editModuleAt(at, text =>
    text.replace(new RegExp(bindSrc), () =>
      // ZERO IS NO CAP, exactly as in step 29, and so is every other value
      // that is not a usable positive ceiling: unset, empty, non-numeric,
      // negative, NaN. An operator writing 0 means "no per-call ceiling",
      // never "a ceiling of nothing", and a value nobody can read must not
      // quietly reintroduce the limit it was written to remove.
      'let ' + ceil + '=Math.min(' + modelTerm + ',' +
      '(()=>{let v=process.env.CLAUDE_CODE_MOD_MAX_TOKENS;' +
      'if(v===void 0||v==="")return Infinity;' +
      'let n=Number(v);' +
      'return Number.isFinite(n)&&n>0?n:Infinity})());',
    ),
  );
  applied.push(
    `30 mod-API per-call maxTokens: ceiling '${ceil}' (stock min(${modelTerm}, ${cap})) ` +
    `now reads CLAUDE_CODE_MOD_MAX_TOKENS; unset or unusable leaves only what the ` +
    `model itself can produce`,
  );
});


// Third door of the same room. Steps 29 and 30 removed two CEILINGS; this one
// removes a LOSS -- three parameters a mod sends and the mod-API silently drops.
//
// MEASURED, 2026-09-14/15, on this machine's judge records (6894 of them,
// including the .gz ones -- a first census that read only the 385 uncompressed
// files was invalid and is not the basis here):
//
//   carrier PATCH (our own splice transport): 0 empty answers out of 6358
//     attempts; the FIRST rung of the ladder serves 96% of verdicts, which is
//     the design -- one model works, the rest are fallback.
//   carrier MOD ($.model.complete): deepseek-flash 83% empty, glm-5.3 80%
//     empty, and the ladder walks to its LAST and dearest rung in 69% of
//     verdicts against a designed ~0%.
//
// The difference is not the models and not the prompt. The mod-API entry
// destructures exactly `{model, prompt, system, maxTokens}` and its validator
// announces "takes { model, prompt }", so `effort`, `timeoutMs` and the
// snake_case `max_tokens` are dropped without a word. The judge sends all
// three. Absent `timeoutMs` there is no time bound at all on that road: a
// probe hung for 24 minutes and the records hold a 19-minute attempt.
//
// Nothing new has to be built for this -- the downstream call already takes
// every one of them, `iMt` just never hands them over:
//
//   LR({... ,max_tokens:v=1024, timeout:P, thinking:V, extraBodyParams:me, ...})
//     extraBodyParams flows into the BODY:  {...thinking, ...betas, metadata, ...me, ...}
//     timeout flows into the SDK:  create(body,{signal, ...P!==void 0&&{timeout:P}, ...})
//
// So the edit is a pass-through at one site, in the shape the image already
// uses for optional members (`...cond&&{key:value}`).
//
// The alias is deliberate, not sloppiness: `max_tokens` is the name our own
// splice reads on the patch carrier, so every mod already written for that
// road keeps working when it is run as a mod. `maxTokens` wins when both are
// present -- the documented name outranks the alias -- and the alias is
// assigned BEFORE the ceiling guard so it cannot slip past the check that
// step 30 governs.
//
// `effort` travels verbatim, exactly as the splice sends it on the other road
// (`__obj.reasoning_effort=__e.effort`). Validating the vocabulary here would
// invent a rule the other road does not enforce, and the two roads disagreeing
// about which efforts exist is a worse defect than a typo reaching a provider
// (that typo is #141 and belongs to both roads at once).
step('31 mod-API forwards per-call effort, timeout and the token alias', () => {
  const ID = '[A-Za-z_$][\\w$]*';

  // ---- the 2.1.280 shape: upstream took over effort and timeoutMs ---------
  // MEASURED on 2.1.280 stock (chunk-dt8bvbsd.js): the entry now destructures
  // `{model,prompt,system,maxTokens,effort,timeoutMs}` and upstream itself
  //   (a) validates effort against its own list and forwards it as
  //       `output_config.effort` -- the channel the harness already used, and
  //       the one measured honored 2026-07-27;
  //   (b) validates timeoutMs, caps it (`Math.min(<ms>,<ceiling>)`) and races
  //       the provider call against it with a real AbortController.
  // Both are strictly better than this step's own forwarding, so on this shape
  // the step does NOT re-add them. Two live channels carrying one value is a
  // conflict, not redundancy: our `extraBodyParams.reasoning_effort` and
  // upstream's `output_config.effort` would both reach the gateway.
  //
  // What upstream did NOT do, and what this step still carries here:
  //   * `max_tokens` as an alias of `maxTokens` -- absent from the entry;
  //   * the CAUSE of an answer. The return became an object
  //     (`{isAnswered,reason:"empty-reply",usage}` / `{isAnswered,text,usage}`),
  //     which is progress, but "the model stayed silent", "everything went to
  //     thinking blocks" and "the answer was cut at max_tokens" STILL arrive
  //     as the one reason "empty-reply" -- the exact indistinguishability of
  //     #153/#190. `stop_reason` and the block types sit in the response
  //     object at this point and are still dropped.
  //
  // CONSTRAINT: the `detail` FLAG is gone on this shape, and its absence is
  // the point, not an omission. The flag existed ONLY to keep the stock return
  // a plain string for mods that depend on `""` being falsy. Upstream's return
  // is already an object, so that contract no longer exists to protect: the
  // two fields are added UNCONDITIONALLY. A reader that ignores them is
  // unaffected, and `readComplete` in our own mod recognises the envelope by
  // its own fields, so it takes them the moment they appear.
  const headB = new RegExp(
    'async function (' + ID + ')\\(\\{model:(' + ID + '),prompt:(' + ID + '),system:(' + ID +
      '),maxTokens:(' + ID + '),effort:(' + ID + '),timeoutMs:(' + ID + ')\\},([^)]*)\\)\\{',
    'g',
  );
  const headsB = [...js.matchAll(headB)];
  if (headsB.length > 1) {
    fail(
      `the mod-API entry (2.1.280 shape) must occur exactly once, found ${headsB.length} -- ` +
        `a second entry would take calls this edit never reaches`,
    );
  }
  if (headsB.length === 1) {
    const hB = headsB[0];
    const [hbWhole, fnB, aMdlB, aPrmB, aSysB, aMaxB, aEffB, aTmoB, aRestB] = hB;

    // The RETURN of the same entry, anchored as ONE unit and name-free: the
    // two bindings, the log template and BOTH arms of the ternary, tied by
    // backreferences. The reason literal is CAPTURED, never pinned: it is
    // upstream's wording and this step does not own it.
    const tailB = new RegExp(
      'let (' + ID + ')=(' + ID + ')\\((' + ID + ')\\.content,""\\),(' + ID + ')=(' + ID +
        ')\\(\\3\\.usage\\);return (' + ID + ')\\((`[^`]*`)\\),' +
        '\\1===""\\?\\{isAnswered:!1,reason:"([^"]*)",usage:\\4\\}:' +
        '\\{isAnswered:!0,text:\\1,usage:\\4\\}\\}',
      'g',
    );
    const tailsB = [...js.matchAll(tailB)];
    if (tailsB.length !== 1) {
      fail(
        `the mod-API return (2.1.280 shape) must occur exactly once, found ` +
          `${tailsB.length} -- the cause fields would reach only one of several returns`,
      );
    }
    const tB = tailsB[0];
    const [tbWhole, tXeB, tJoinB, tResB, tHtB, tUfB, tLogB, tTplB, tReasonB] = tB;

    const dB = tB.index - hB.index;
    if (dB < 0 || dB > 4000) {
      fail(
        `the mod-API return sits ${dB} bytes from its entry -- outside the entry ` +
          `the response binding is not in scope`,
      );
    }

    // POSITIVE CONTROL for the field this edit reads: `stop_reason` has to
    // exist in the module that owns the entry, or `<res>.stop_reason` would be
    // a field invented by this patch rather than one dropped by upstream.
    // EMPTY IS NOT ZERO: an edit that reads a field nobody produces writes
    // `null` forever and looks like a working detail channel.
    const entryModule = moduleTextAt(hB.index);
    if (!/stop_reason/.test(entryModule)) {
      fail(
        `the entry's module carries no 'stop_reason' -- the cause field this ` +
          `step forwards is not produced here`,
      );
    }

    for (const name of ['__mcAlias', '__mcSt', '__mcBl', '__mcBlk']) {
      if (js.indexOf(name) !== -1) {
        fail(`the name '${name}' already occurs in the image -- this step would rebind it`);
      }
    }

    // CONSTRAINT: every replacement is repEsc'd. The replacement carries
    // CAPTURED minified names and the captured log TEMPLATE, and a `$` in
    // either is read by String.replace as a substitution token ($& is the
    // whole match) -- the template measured here already begins
    // `$.model.complete (...)`.
    editModuleAt(hB.index, text =>
      text
        .replace(
          hbWhole,
          repEsc(
            'async function ' + fnB + '({model:' + aMdlB + ',prompt:' + aPrmB + ',system:' +
              aSysB + ',maxTokens:' + aMaxB + ',effort:' + aEffB + ',timeoutMs:' + aTmoB +
              ',max_tokens:__mcAlias},' + aRestB + '){' +
              // Before upstream's ceiling and integer guards on purpose: an
              // aliased value must be validated exactly like a direct one.
              'if(' + aMaxB + '===void 0&&__mcAlias!==void 0)' + aMaxB + '=__mcAlias;',
          ),
        )
        .replace(
          tbWhole,
          repEsc(
            'let ' + tXeB + '=' + tJoinB + '(' + tResB + '.content,""),' + tHtB + '=' + tUfB +
              '(' + tResB + '.usage);let __mcSt=' + tResB + '.stop_reason??null,' +
              '__mcBl=(Array.isArray(' + tResB + '.content)?' + tResB + '.content:[])' +
              '.map((__mcBlk)=>({type:__mcBlk&&__mcBlk.type,' +
              'len:typeof(__mcBlk&&__mcBlk.text)==="string"?__mcBlk.text.length:0}));' +
              'return ' + tLogB + '(' + tTplB + '),' + tXeB + '===""?{isAnswered:!1,reason:"' +
              tReasonB + '",usage:' + tHtB + ',stopReason:__mcSt,blocks:__mcBl}:' +
              '{isAnswered:!0,text:' + tXeB + ',usage:' + tHtB +
              ',stopReason:__mcSt,blocks:__mcBl}}',
          ),
        ),
    );
    applied.push(
      `31 mod-API (2.1.280 shape): max_tokens forwarded as an alias of maxTokens ` +
        `through '${fnB}', and the return carries {stopReason, blocks} beside ` +
        `upstream's {isAnswered, text|reason, usage} -- effort and timeoutMs are ` +
        `upstream's own on this build and are NOT re-added`,
    );
    return;
  }

  // Both needles are name-free: minified identifiers differ across PLATFORMS
  // and across versions. Measured on three images -- darwin 2.1.270 stock and
  // patched name the parts `iMt/LR/s/m/S/C/D/P`, linux 2.1.268 names the same
  // parts `hTt/cR/o/p/_/A/D/P`, and both needles still matched exactly once
  // with the call sitting 483 bytes inside the head on every one of them.
  const head = new RegExp(
    'async function (' + ID + ')\\(\\{model:(' + ID + '),prompt:(' + ID + '),system:(' + ID +
    '),maxTokens:(' + ID + ')\\},([^)]*)\\)\\{',
    'g',
  );
  // CONSTRAINT: the parameter tail after the destructured object is captured
  // whole and spliced back VERBATIM -- this step uses none of the tail's
  // parts. 2.1.270 spelled it `{plugin:<id>,budget:<id>},<id>`; 2.1.274
  // deleted the budget mechanism upstream and spells it `<id>,<id>`. Pinning
  // the tail's shape would couple this step to a mechanism it does not touch,
  // and `[^)]*` is exact for both forms: no parenthesis can occur in that
  // span. The exactly-once requirement below is NOT relaxed -- a weaker
  // locator must not become a weaker guarantee.
  const heads = [...js.matchAll(head)];
  if (heads.length !== 1) {
    fail(
      `the mod-API entry must occur exactly once, found ${heads.length} -- ` +
      `a second entry would take calls this edit never reaches`,
    );
    return;
  }
  const h = heads[0];
  const [hWhole, fn, aMdl, aPrm, aSys, aMax, aRest] = h;

  const call = new RegExp(
    'await (' + ID + ')\\(\\{querySource:"hook_prompt",model:(' + ID + '),max_tokens:(' + ID +
    '),thinking:(' + ID + '),skipSystemPromptPrefix:!0,',
    'g',
  );
  const calls = [...js.matchAll(call)];
  if (calls.length !== 1) {
    fail(
      `the mod-API provider call must occur exactly once, found ${calls.length} -- ` +
      `the forwarded fields would reach only one of several call sites`,
    );
    return;
  }
  const c = calls[0];
  const [cWhole, cFn, cMdl, cTok, cThk] = c;

  // The call has to live INSIDE the entry, or the names this step introduces
  // are out of scope there and the edit produces a ReferenceError at runtime
  // instead of a missed patch -- a failure that the registry, which reads
  // bytes, would not catch.
  const delta = c.index - h.index;
  if (delta < 0 || delta > 2000) {
    fail(
      `the mod-API provider call sits ${delta} bytes from its entry -- outside the ` +
      `entry the forwarded names are not in scope`,
    );
    return;
  }

  // The RETURN of the same entry, where the answer loses its cause. The image
  // hands the mod `xut(content,"")` -- a join of the text blocks ONLY:
  //
  //   var xut=(e,n)=>e.flatMap((r)=>r.type==="text"&&r.text!==void 0?[r.text]:[]).join(n);
  //
  // so "the model stayed silent", "everything went into thinking blocks" and
  // "the answer was cut at max_tokens" all arrive as the same empty string,
  // while `stop_reason`, the block types and `usage` sit RIGHT THERE in the
  // response object and are dropped (measured 2026-09-15, offsets 171707700
  // and 168695607 of the patched darwin 2.1.272; the provider call returns the
  // full API message -- its tail reads `...stop_reason:to.stop_reason...`, so
  // the field exists at this point). That indistinguishability is the whole
  // reason the judge's lower rungs could not be diagnosed: they report "empty"
  // and nothing else (#153, #190).
  //
  // The needle is name-free and anchors the tail as ONE unit: the binding, the
  // log template and the return of that same binding, tied by a backreference.
  const tail = new RegExp(
    'let (' + ID + ')=(' + ID + ')\\((' + ID + ')\\.content,""\\);return (' + ID +
    ')\\((`[^`]*`)\\),\\1\\}',
    'g',
  );
  const tails = [...js.matchAll(tail)];
  if (tails.length !== 1) {
    fail(
      `the mod-API return must occur exactly once, found ${tails.length} -- ` +
      `the detail channel would reach only one of several returns`,
    );
    return;
  }
  const tl = tails[0];
  const [tWhole, tXe, tJoin, tRes, tLog, tTpl] = tl;

  const tDelta = tl.index - h.index;
  if (tDelta < 0 || tDelta > 2000) {
    fail(
      `the mod-API return sits ${tDelta} bytes from its entry -- outside the ` +
      `entry the detail flag is not in scope`,
    );
    return;
  }

  // Our own names must not already exist anywhere in the bundle: a collision
  // would silently rebind someone else's identifier.
  for (const name of ['__mcEff', '__mcTmo', '__mcAlias', '__mcDetail', '__mcBlk']) {
    if (js.indexOf(name) !== -1) {
      fail(`the name '${name}' already occurs in the image -- this step would rebind it`);
      return;
    }
  }

  editModuleAt(h.index, text =>
    text
      // CONSTRAINT: repEsc on every replacement. Each one splices CAPTURED
      // minified names and, below, the captured log TEMPLATE -- and a `$` in
      // either is read by String.replace as a substitution token ($& is the
      // whole match). The template measured here already begins
      // `$.model.complete (...)`, so the hazard is live, not hypothetical.
      .replace(
        hWhole,
        repEsc(
          'async function ' + fn + '({model:' + aMdl + ',prompt:' + aPrm + ',system:' + aSys +
          ',maxTokens:' + aMax + ',effort:__mcEff,timeoutMs:__mcTmo,max_tokens:__mcAlias' +
          ',detail:__mcDetail},' +
          aRest + '){' +
          // Before the ceiling guard on purpose -- see the header.
          'if(' + aMax + '===void 0&&__mcAlias!==void 0)' + aMax + '=__mcAlias;',
        ),
      )
      .replace(
        tWhole,
        // The default road is untouched: without the flag the entry still
        // returns the plain string, so every mod written against the stock
        // surface -- ours and anyone else's -- keeps its contract, INCLUDING
        // the falsiness of "" that an `if (!answer)` depends on. Only a caller
        // that asks for detail gets an object, and it asks by a name that
        // cannot exist in a stock image (checked above).
        repEsc(
          'let ' + tXe + '=' + tJoin + '(' + tRes + '.content,"");return ' + tLog + '(' + tTpl +
          '),__mcDetail===true?{text:' + tXe + ',stopReason:' + tRes + '.stop_reason??null,' +
          'blocks:(Array.isArray(' + tRes + '.content)?' + tRes + '.content:[]).map((__mcBlk)=>' +
          '({type:__mcBlk&&__mcBlk.type,len:typeof(__mcBlk&&__mcBlk.text)==="string"' +
          '?__mcBlk.text.length:0})),usage:' + tRes + '.usage??null}:' + tXe + '}',
        ),
      )
      .replace(
        cWhole,
        repEsc(
          'await ' + cFn + '({querySource:"hook_prompt",model:' + cMdl + ',max_tokens:' + cTok +
          ',thinking:' + cThk + ',skipSystemPromptPrefix:!0,' +
          // A non-finite or non-positive timeout means NO bound, never a bound of
          // zero: a mod asking for an unusable value must not have its call cut
          // instantly. Same reading of unusable values as steps 29 and 30.
          '...Number.isFinite(__mcTmo)&&__mcTmo>0&&{timeout:__mcTmo},' +
          '...typeof __mcEff==="string"&&__mcEff!==""&&{extraBodyParams:{reasoning_effort:__mcEff}},',
        ),
      ),
  );
  applied.push(
    `31 mod-API forwards effort (as reasoning_effort), timeoutMs (as timeout) and ` +
    `max_tokens (alias of maxTokens) through '${fn}' into '${cFn}', and returns ` +
    `{text, stopReason, blocks, usage} when the caller passes detail:true`,
  );
});


// 34. The requestText door. Five insertions into the image, each keyed to a
//     construction site of the flag noun so the door rides the machinery the
//     host already trusts:
//       * the noun builder, a sibling of the flag builder, calling the same
//         host invoker with "requestText.register"/"unregister"/"list";
//       * the factory key -- the SAME literal the host builds both the noun
//         name table and the plugin `$` from (a key added anywhere else would
//         leave the noun absent from the registry and from `$`);
//       * the three operation names in the host's prefix list. They are
//         MANDATORY, but the reason first written here was the wrong one: the
//         plugin-provided branch is gated by a comparison against
//         "interface.call", so THAT branch alone would not divert the call.
//         The gate that actually decides is the SCAN gate in the dispatcher
//         (`rGe`, DOOR-DESIGN.md section 14): `knownArgs.get(plugin).scan`
//         throws BEFORE `check` ever runs when the scan does not know the
//         operation, so an unlisted name is refused before our code sees it.
//         Two further consequences ride on the listing: the operation becomes
//         interceptable by other plugins' hooks, and the official plugin test
//         harness admits only listed names;
//       * the op implementations, the rule table and the applier, inserted
//         right after the flag.value op record -- the module that owns the
//         request-body site, so the site's call shares its scope;
//       * the dispatcher entries, beside flag.value's own.
//     CONSTRAINT: a `check` message is a BARE phrase -- the `<plugin>: <op>: `
//     prefix and the ` (host check)` suffix are added by the host.
//     CONSTRAINT: a `check` that returns an empty string is still a refusal
//     (the host reads `!==void 0`) -- never return "".
//     CONSTRAINT: the rule table freezes on the FIRST application: on a
//     continued server turn the host may omit `system`/`tools`, and a rule
//     arriving mid-turn would silently not apply until the turn ended.
//     CONSTRAINT: rewritten bodies are NEW objects: the arrays the request
//     loop keeps for retries and inheritance checks must not be mutated. The
//     container is replaced ONLY when an element actually changed -- a body
//     nothing matched comes back with its own `system`/`tools` arrays, by
//     identity, which is what the contract promises.
//     CONSTRAINT: a rule is validated against a CLOSED key set and stored as a
//     hand-built SNAPSHOT of the fields the validator proved to be strings.
//     Two defects follow from the alternatives and both were live: an unknown
//     key (`flgs` for `flags`) compiled a rule that silently never matched, and
//     `JSON.parse(JSON.stringify(rule))` at read time THREW synchronously
//     inside `Promise.resolve(...)` on a rule holding a BigInt, a cycle or a
//     throwing `toJSON` -- one plugin's rule killed `list()` for everyone, and
//     a frozen table cannot be unregistered. There is no `JSON.stringify` in
//     this door: `list()` cannot throw BY CONSTRUCTION.
//     CONSTRAINT: ownership is checked against the stored `owner` FIELD, never
//     against a prefix of the id string, and `__ctlRemove` carries its own
//     guard -- the door does not rely on the host always calling `check`
//     before `run`. An id nobody owns passes `check` and removes nothing, so
//     the refusal phrase never lies about a rule that does not exist.
//     CONSTRAINT: the id is built from the LOWERCASED model because `mre`
//     matches case-insensitively; keyed by the exact string, `devin/swe-2` and
//     `DEVIN/SWE-2` would live as two rules and both would apply.
//     CONSTRAINT: `find` is literal and replaces EVERY occurrence; `pattern`
//     obeys its own flags (without `g`, the first occurrence only) and its
//     `to` is subject to $-substitution ($&, $1). Neither is a defect -- both
//     are the String/RegExp contracts -- but a rule author who assumes one
//     behaves like the other writes a bug no validator can see.
//     CONSTRAINT: the model is DATA now, matched by a TOKEN-BOUNDARY predicate,
//     `^<model>(?![\w.-])`. This is a DECISION, not an observation: ids in this
//     program do carry form suffixes (`claude-opus-5[1m]`), and a rule measured
//     on a model must keep applying to them. The consequence, stated plainly:
//     ANY character outside `[\w.-]` continues the match -- `[1m]`, a colon, a
//     slash, even a trailing space. `devin/swe-2.1` and `devin/swe-20` do not
//     match. The corollary is the trap: a rule whose model is the bare vendor
//     (`devin`) catches `devin/swe-2` as well -- a rule names its model in full.
//     CONSTRAINT: a compiled RegExp is REUSED across requests, so `__ctlOne`
//     resets lastIndex before every replace. MEASURED, correcting the earlier
//     wording: only `y` WITHOUT `g` carries a position across requests --
//     `String.prototype.replace` zeroes lastIndex itself for a global regexp.
//     The reset stays because it is correct under every flag and costs one
//     statement; without it a sticky rule fires on every OTHER body.
//     Runs BEFORE step 32 by file order. CONSTRAINT, corrected: this is a
//     FILE CONVENTION, not a correctness requirement -- the two steps splice at
//     non-overlapping offsets and commute, and a function declaration hoists
//     regardless. The order is kept so the diff reads in dependency order and
//     the anchors stay stable.
step('34 requestText door', () => {
  const ID = '[A-Za-z_$][\\w$]*';

  const rxNoun = new RegExp(
    `var (${ID})=\\((${ID})\\)=>(${ID})\\(\\{value:\\((${ID}),(${ID})\\)=>\\2\\("flag\\.value",\\{name:\\4,fallback:\\5\\}\\)\\}\\);`, 'g');
  const nounSites = [...js.matchAll(rxNoun)];
  if (nounSites.length !== 1) fail(`requestText door: flag noun builder: expected exactly 1 site, found ${nounSites.length}`);
  const [noun] = nounSites;
  const NOUN = noun[1];
  const VH = noun[3];
  // CONSTRAINT: the parameter names here are OUR OWN, carrying a prefix no
  // minifier produces. The factory passes an ARGUMENT, never a name, so
  // borrowing the flag builder's minified parameter bought nothing and
  // risked everything: a method parameter that happens to collide with it
  // would shadow the invoker, and the door would build -- silently -- dead.
  const nounBuilder =
    `var __ctlRT=(__ctlH)=>${VH}({register:(__ctlA)=>__ctlH("requestText.register",__ctlA),` +
    `unregister:(__ctlA)=>__ctlH("requestText.unregister",{id:__ctlA}),` +
    `list:()=>__ctlH("requestText.list",{})});`;
  js = js.slice(0, noun.index + noun[0].length) + nounBuilder +
    js.slice(noun.index + noun[0].length);

  const rxFactory = new RegExp(`,flag:(${ID})\\(${rxEsc(NOUN)}\\((${ID})\\)\\)\\}\\}`, 'g');
  const factorySites = [...js.matchAll(rxFactory)];
  if (factorySites.length !== 1) fail(`requestText door: interface factory literal: expected exactly 1 site, found ${factorySites.length}`);
  const [factory] = factorySites;
  const factoryKey = `,requestText:${factory[1]}(__ctlRT(${factory[2]}))`;
  js = js.slice(0, factory.index + factory[0].length - 2) + factoryKey + '}}' +
    js.slice(factory.index + factory[0].length);

  const rxNames = /("prompt\.read","flag\.value",)("tool\.list")/g;
  const nameSites = [...js.matchAll(rxNames)];
  if (nameSites.length !== 1) fail(`requestText door: operation name list: expected exactly 1 site, found ${nameSites.length}`);
  const [names] = nameSites;
  const namesAdd = '"requestText.register","requestText.unregister","requestText.list",';
  js = js.slice(0, names.index + names[1].length) + namesAdd +
    js.slice(names.index + names[1].length);

  const rxOpImpl = new RegExp(
    `var (${ID})=\\{check:\\((${ID})\\)=>(${ID})\\(\\)\\?(${ID})\\(\\2\\):"reads a feature flag[^"]*",run:\\((${ID})\\)=>Promise\\.resolve\\((${ID})\\(\\5\\.name,\\5\\.fallback\\)\\)\\};`, 'g');
  const opSites = [...js.matchAll(rxOpImpl)];
  if (opSites.length !== 1) fail(`requestText door: flag.value op record: expected exactly 1 site, found ${opSites.length}`);
  const [op] = opSites;
  const DQT = op[1];
  // One line, no newlines and no //-comments: this lands inside the
  // minified image; the break-up below is source readability only.
  const door = [
    'var __ctlRules=[],__ctlFrozen=!1,__ctlSeen=0,__ctlChanged=0;',
    'function __ctlEsc(s){return s.replace(/[.*+?^${}()|[\\]\\\\]/g,"\\\\$&")}',
    'var __ctlRK={model:1,ops:1},__ctlOK={find:1,pattern:1,flags:1,to:1,tool:1};',
    'function __ctlBad(r){',
    'if(!r||typeof r!=="object")return "takes { model, ops }";',
    'for(var rk in r)if(!__ctlRK[rk])return "unknown key \\""+rk+"\\" on the rule; takes { model, ops }";',
    'if(typeof r.model!=="string"||r.model==="")return "model must be a non-empty string";',
    'if(!Array.isArray(r.ops)||r.ops.length===0)return "ops must be a non-empty array";',
    'for(var i=0;i<r.ops.length;i++){var o=r.ops[i];',
    'if(!o||typeof o!=="object")return "ops["+i+"] must be an object";',
    'for(var ok in o)if(!__ctlOK[ok])return "ops["+i+"]: unknown key \\""+ok+"\\"";',
    'if(o.find!==void 0&&o.pattern!==void 0)return "ops["+i+"] takes exactly one of find / pattern, not both";',
    'var hf=typeof o.find==="string"&&o.find!=="",hp=typeof o.pattern==="string"&&o.pattern!=="";',
    'if(hf===hp)return "ops["+i+"] takes exactly one of find / pattern, a non-empty string";',
    'if(hf&&o.flags!==void 0)return "ops["+i+"].flags applies to pattern only";',
    'if(typeof o.to!=="string")return "ops["+i+"].to must be a string";',
    'if(o.flags!==void 0&&(typeof o.flags!=="string"||/[^gimsuy]/.test(o.flags)))return "ops["+i+"].flags may only contain gimsuy";',
    'if(o.tool!==void 0&&(typeof o.tool!=="string"||o.tool===""))return "ops["+i+"].tool must be a non-empty string";',
    'if(hp){try{new RegExp(o.pattern,o.flags||"")}catch(x){return "ops["+i+"].pattern does not compile: "+String(x&&x.message||x)}}}',
    'return}',
    'function __ctlSnap(r){var ops=[],i;for(i=0;i<r.ops.length;i++){var o=r.ops[i],s={to:o.to};',
    'if(typeof o.find==="string")s.find=o.find;else{s.pattern=o.pattern;if(o.flags!==void 0)s.flags=o.flags}',
    'if(o.tool!==void 0)s.tool=o.tool;ops.push(s)}return {model:r.model,ops:ops}}',
    'function __ctlCompile(r,owner){',
    'var ops=[],i;for(i=0;i<r.ops.length;i++){var o=r.ops[i];',
    'ops.push(typeof o.find==="string"&&o.find!==""?{find:o.find,to:o.to,tool:o.tool}:{re:new RegExp(o.pattern,o.flags||""),to:o.to,tool:o.tool})}',
    'return {id:owner+":"+String(r.model).toLowerCase(),owner:owner,model:r.model,mre:new RegExp("^"+__ctlEsc(r.model)+"(?![\\\\w.-])","i"),ops:ops,matched:0,raw:__ctlSnap(r)}}',
    'function __ctlUpsert(r,owner){',
    'var c=__ctlCompile(r,owner),i;',
    'for(i=0;i<__ctlRules.length;i++)if(__ctlRules[i].id===c.id){__ctlRules[i]=c;return {id:c.id}}',
    '__ctlRules.push(c);return {id:c.id}}',
    'function __ctlFind(id){var i;for(i=0;i<__ctlRules.length;i++)if(__ctlRules[i].id===id)return __ctlRules[i];return null}',
    'function __ctlOwnBad(e,c){if(!e||typeof e.id!=="string"||e.id==="")return "unregister takes a non-empty string id";',
    'var r=__ctlFind(e.id);if(r&&r.owner!==String(c&&c.plugin||"?"))return "the id belongs to another plugin";return}',
    'function __ctlRemove(id,owner){',
    'var i;for(i=0;i<__ctlRules.length;i++)if(__ctlRules[i].id===id){',
    'if(__ctlRules[i].owner!==owner)return {removed:!1};__ctlRules.splice(i,1);return {removed:!0}}',
    'return {removed:!1}}',
    'function __ctlOne(t,o){if(o.find!==void 0)return t.split(o.find).join(o.to);o.re.lastIndex=0;return t.replace(o.re,o.to)}',
    'function __ctlText(t,ops){var i;for(i=0;i<ops.length;i++)t=__ctlOne(t,ops[i]);return t}',
    'function __ctlApply(b,model){',
    '__ctlFrozen=!0;__ctlSeen++;',
    'if(!b||typeof b!=="object"||__ctlRules.length===0)return b;',
    'var sys=[],tls=[],i,j,ch=!1;',
    'for(i=0;i<__ctlRules.length;i++){var r=__ctlRules[i];',
    'if(!r.mre.test(model))continue;',
    'r.matched++;',
    'for(j=0;j<r.ops.length;j++)(r.ops[j].tool===void 0?sys:tls).push(r.ops[j])}',
    'if(sys.length===0&&tls.length===0)return b;',
    'if(sys.length){',
    'if(typeof b.system==="string"){var s2=__ctlText(b.system,sys);if(s2!==b.system){b.system=s2;ch=!0}}',
    'else if(Array.isArray(b.system)){var c1=!1,a1=b.system.map(function(k){var x;',
    'return k&&typeof k==="object"&&typeof k.text==="string"&&(x=__ctlText(k.text,sys))!==k.text?(c1=!0,Object.assign({},k,{text:x})):k});',
    'if(c1){b.system=a1;ch=!0}}}',
    'if(tls.length&&Array.isArray(b.tools)){var c2=!1,a2=b.tools.map(function(t){',
    'if(!t||typeof t.name!=="string"||typeof t.description!=="string")return t;',
    'var d=t.description,k;',
    'for(k=0;k<tls.length;k++)if(tls[k].tool===t.name)d=__ctlOne(d,tls[k]);',
    'return d===t.description?t:(c2=!0,Object.assign({},t,{description:d}))});',
    'if(c2){b.tools=a2;ch=!0}}',
    'if(ch)__ctlChanged++;',
    'return b}',
    'var __ctlFrozenMsg="the rule table is frozen (first request already applied); a rule must be registered from session.start";',
    'var __ctlRegOp={check:(e,c)=>__ctlFrozen?__ctlFrozenMsg:__ctlBad(e),run:(e,c)=>Promise.resolve(__ctlUpsert(e,String(c&&c.plugin||"?")))};',
    'var __ctlUnregOp={check:(e,c)=>__ctlFrozen?__ctlFrozenMsg:__ctlOwnBad(e,c),run:(e,c)=>Promise.resolve(__ctlRemove(e.id,String(c&&c.plugin||"?")))};',
    'var __ctlListOp={run:()=>Promise.resolve({frozen:__ctlFrozen,seen:__ctlSeen,changed:__ctlChanged,rules:__ctlRules.map(function(r){return {id:r.id,owner:r.owner,model:r.model,matched:r.matched,rule:__ctlSnap(r.raw)}})})};',
  ].join('');
  js = js.slice(0, op.index + op[0].length) + door + js.slice(op.index + op[0].length);

  const rxDispatch = new RegExp(`"flag\\.value":${rxEsc(DQT)},`, 'g');
  const dispatchSites = [...js.matchAll(rxDispatch)];
  if (dispatchSites.length !== 1) fail(`requestText door: dispatcher entry: expected exactly 1 site, found ${dispatchSites.length}`);
  const [dispatch] = dispatchSites;
  const dispatchAdd =
    '"requestText.register":__ctlRegOp,"requestText.unregister":__ctlUnregOp,"requestText.list":__ctlListOp,';
  js = js.slice(0, dispatch.index + dispatch[0].length) + dispatchAdd +
    js.slice(dispatch.index + dispatch[0].length);

  applied.push(
    `34 requestText door: noun builder beside '${NOUN}', factory key 'requestText', ` +
    `3 names in the op list, rule table + applier + 3 dispatcher entries beside '${DQT}'`,
  );
});


// 32. Devin's SWE-2 endpoint refuses a request whose text presents the caller
//     as Claude: the stock request came back 403, and the same request with
//     its text edited came back 200 (A/B of 2026-09-22, program
//     Catalyst-programs/2026-09-22-tool-descriptions; the classifier scores
//     stock fragments in combination, so each request FORM was measured
//     separately: headless main, custom subagent, general-purpose subagent).
//     That measurement is why the DOOR exists; the edits themselves are no
//     longer baked into this patch -- they are data now, registered through
//     the $.requestText noun (step 34) by the catalyst-swe-request plugin and
//     applied here, at the one site where the outgoing body is assembled and
//     model, system and tools are all in hand. A request whose model -- by its
//     real id or by the proxy's disguise that patch 9 undoes -- matches no
//     rule passes the site byte for byte, and the applier builds new blocks
//     and new tool objects on the body it owns.
//     CONSTRAINT: this cannot move to the mod API. The identity prefix is
//     prepended to the system prompt AFTER the prompt.section hooks ran, and
//     tool.describe carries neither the model nor the agent.
//     CONSTRAINT: the Read sentence lives only in the legacy description
//     branch; a lean-description request never carries it, so there the
//     Read edit is a no-op by construction, not a missed site.
step('32 request text for devin/swe-2', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const rx = new RegExp(`let (${ID})=\\{model:(${ID})\\((${ID})\\.model\\),messages:`, 'g');
  const sites = [...js.matchAll(rx)];
  if (sites.length !== 1) fail(`request body site: expected exactly 1, found ${sites.length}`);
  const [m] = sites;
  const rf = m[1];
  // The statement right after the body literal reads `<rf>.messages`; the
  // rewrite is spliced in front of it, so the literal itself is never parsed.
  const after = new RegExp(`;(${ID})=(${ID})&&${rxEsc(rf)}\\.messages\\.some\\(`, 'g');
  after.lastIndex = m.index;
  const a = after.exec(js);
  if (a === null || a.index - m.index > 4000) fail('statement after the request body not found');

  // CONSTRAINT (DOOR-DESIGN 9.6/11.3): among the request-body consumers there
  // is a late writer -- it publishes tools/system/messages from the result of
  // a three-argument call whose callee body is an EMPTY return today. If
  // upstream revives that writer, stock fields overwrite the applier's
  // rewrite AFTER the door ran, and the carrier's refusal returns silently.
  // The stub is pinned FROM THE CALL (the second argument spreads
  // <f>(<p>,<g>()), the third carries querySource and isMainThread), never
  // from the name: a second, same-name ONE-parameter function lives in the
  // MCP cache digest parser, and the minified name changes every version.
  const rxLateCall = new RegExp(
    `(${ID})\\(${ID},\\{\\.\\.\\.${ID}\\(${ID},${ID}\\(\\)\\),messages:${ID}\\},` +
      `\\{[^{}]*querySource[^{}]*isMainThread[^{}]*\\}\\)`, 'g');
  const lateCalls = [...js.matchAll(rxLateCall)];
  if (lateCalls.length !== 1) fail(`late writer call: expected exactly 1 site, found ${lateCalls.length}`);
  const rxLateDef = new RegExp(
    `function ${rxEsc(lateCalls[0][1])}\\(${ID},${ID},${ID}\\)\\{([^{}]*)\\}`, 'g');
  const lateDefs = [...js.matchAll(rxLateDef)];
  if (lateDefs.length !== 1) {
    fail(`late writer ${lateCalls[0][1]}: expected exactly 1 three-parameter definition, ` +
      `found ${lateDefs.length}`);
  }
  if (lateDefs[0][1] !== 'return') {
    fail(`late writer ${lateCalls[0][1]}: the stub body is no longer an empty return ` +
      `(${JSON.stringify(lateDefs[0][1])}) -- it would overwrite system/tools with ` +
      `stock values after the rule applier ran`);
  }

  const DISGUISE = 'claude-fable-5-dd-';
  const runtime =
    `/*swe32*/${rf}=(function(__r){` +
    `var __m=String(__r.model==null?"":__r.model);` +
    `if(__m.indexOf(${JSON.stringify(DISGUISE)})===0)` +
    `__m=__m.slice(${DISGUISE.length}).split("").reverse().join("");` +
    `return __ctlApply(__r,__m.trim())})(${rf});/*swe32-end*/`;
  js = js.slice(0, a.index + 1) + runtime + js.slice(a.index + 1);

  applied.push(
    `32 request text for devin/swe-2: request body site found, rule applier ` +
    `wired in front of the '${rf}.messages' statement (1 site; the rules ` +
    `themselves live in the catalyst-swe-request plugin)`,
  );
});

// 33. The turn.step hook validator refuses a tool chunk whose id is not
//     /^[\w-]+$/. Devin's SWE-2 names its calls `call_<hex>#<hex>`, so with
//     ANY turn.step hook installed -- a pure pass-through included -- the
//     re-yielded tool chunk is "the wrong shape", the hook is left mid-stream,
//     the chunk is dropped, the input deltas land on a text block and the
//     client reports tengu_malformed_tool_use_response (measured 2026-09-22,
//     program Catalyst-programs/2026-09-22-tool-descriptions; the same id
//     passes the whole chain when no turn.step hook is installed). The rule
//     becomes "non-empty, no whitespace" and the message names the new rule.
//     The locator pins the whole `case"tool"` arm, not the regexp: the same
//     regexp guards six unrelated ids elsewhere in the bundle.
//     CONSTRAINT: this cannot move to the mod API -- the refusal is applied to
//     the hook's OUTPUT, before any of the hook's own code could act on it.
step('33 turn.step tool chunk id', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  const FROM_RX = '/^[\\w-]+$/';
  const TO_RX = '/^\\S+$/';
  const FROM_MSG = '"{ index, id, name } (an id of letters, digits, _ or -)"';
  const TO_MSG = '"{ index, id, name } (a non-empty id without whitespace)"';
  const rx = new RegExp(
    `case"tool":return (${ID})&&typeof (${ID})\\.id==="string"&&${rxEsc(FROM_RX)}\\.test\\(\\2\\.id\\)` +
    `&&typeof \\2\\.name==="string"\\?void 0:${rxEsc(FROM_MSG)}`,
    'g',
  );
  const sites = [...js.matchAll(rx)];
  if (sites.length !== 1) fail(`tool chunk validator: expected exactly 1 site, found ${sites.length}`);
  const [m] = sites;
  const to = m[0].replace(FROM_RX, () => TO_RX).replace(FROM_MSG, () => TO_MSG);
  js = js.slice(0, m.index) + to + js.slice(m.index + m[0].length);
  applied.push(`33 turn.step tool chunk id: ${FROM_RX} -> ${TO_RX} (1 site)`);
});


// The gate lives at the very END on purpose: it was once placed mid-file, and
// the four steps written after it ran unguarded — a broken locator among them
// was recorded and never read, so the build reported success while the patch
// was missing (that is exactly how step 26 first shipped as a no-op).

// A registry name no declared step answers to is an instrument failure, not a
// patch outcome: the entry disables nothing, and a green run would leave the
// operator believing a step is off when it never was. The name must ride the
// message so the typo is audible. An empty registry, an absent one (injected
// as empty) and a registry whose every name matched are all normal states --
// this fires on ghosts only, never wider.
const ghosts = STEPS_OFF.filter(name => !declaredSteps.includes(name));
if (ghosts.length > 0) {
  throw new Error(
    `multi-provider patch: steps-off registry names step(s) no code declares: ` +
    `${ghosts.join(', ')} -- nothing was disabled by them (nothing written)`,
  );
}

if (failures.length > 0) {
  // Two very different causes produce the same list of "site not found", and
  // they need opposite responses: a CONTAINER change (the bundle stopped being
  // one module and became an entry plus ~1400 code-split chunks at 2.1.242, or
  // the unpacker handed back only part of it) means no locator can match and
  // the fix is in the unpacker; a RENAME of minified identifiers means the
  // locators need re-grounding one by one. Saying which is cheap -- the module
  // boundaries the unpacker inserts are countable -- and not saying it costs an
  // hour of grepping in the wrong direction.
  const boundaries = (js.match(/\/\*__tweakcc_module_boundary_\d+__\*\//g) || []).length;
  // `inapplicable` is deliberately outside `total`: a step with no subject is
  // not a failed patch, and counting it here would drop the run for a state
  // upstream created. It is still DECLARED in the message -- going silent is
  // the one thing this verdict must never do.
  const total = failures.length + applied.length;
  const shape =
    applied.length === 0
      ? `\n  EVERY locator missed and the payload is ${js.length} bytes with ` +
        `${boundaries} module boundaries. Zero boundaries on a version at or after ` +
        `2.1.242 means the unpacker returned an incomplete bundle; a boundary count ` +
        `in the usual range means the CONTAINER is intact and the names moved. ` +
        `A whole-bundle grep will mislead either way -- minified names are scoped ` +
        `to their chunk.`
      : `\n  ${applied.length} of ${total} still applied (${boundaries} module ` +
        `boundaries), so the container is intact and these particular sites moved.`;
  throw new Error(
    `multi-provider patch: ${failures.length} of ${total} patches ` +
    `could not be applied (nothing written):\n  - ${failures.join('\n  - ')}` +
    (stepsOff.length > 0
      ? `\noff by steps-off registry, body not executed (tools/our-steps-off.txt):` +
        `\n  - ${stepsOff.join('\n  - ')}`
      : '') +
    (inapplicable.length > 0
      ? `\ninapplicable in this build (subject deleted upstream, nothing to patch):` +
        `\n  - ${inapplicable.join('\n  - ')}`
      : '') +
    shape,
  );
}

// The inapplicable section rides the SUCCESS line too: a step that went
// missing must be visible in every outcome, not only in a failure report --
// silence here is exactly the no-op defect the end-of-file gate exists for.
console.error(
  `multi-provider patch: applied ${applied.length} edits:\n  - ${applied.join('\n  - ')}` +
    (stepsOff.length > 0
      ? `\noff by steps-off registry, body not executed (tools/our-steps-off.txt):` +
        `\n  - ${stepsOff.join('\n  - ')}`
      : '') +
    (inapplicable.length > 0
      ? `\ninapplicable in this build (subject deleted upstream, nothing to patch):` +
        `\n  - ${inapplicable.join('\n  - ')}`
      : ''),
);

return js;
