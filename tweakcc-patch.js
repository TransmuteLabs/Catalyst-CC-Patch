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
// A name that is spliced into text by OFFSET must go in exactly as the
// image spells it. repEsc is for the replacement side of String.replace,
// where `$` opens a group reference; on a plain splice it doubles the
// dollar and produces a DIFFERENT identifier. That is not hypothetical: on
// 2.1.242/243/245 the single-shot query engine is called `$A`, the probe
// asked for `$$A`, and since `typeof` does not throw on an unbound name the
// judge quietly fell back to raw HTTP on a third of the supported range.
// Every shape check passed -- `$$A` looks like a perfectly good name.
//
// The one thing a raw name must not contain is `$` followed by a digit:
// the block's slots are written `$1`..`$9` and are expanded in this same
// text, so such a name would be eaten by its own slot syntax. It stops the
// build instead.
const siteName = (name, what) => {
  // A name spliced into a replacement string meets String.replace's own syntax.
  // `$1`..`$9` were the first collision found (an engine called `$A` is not one,
  // but `$1` would swallow a capture) — and `$$` is the second: it is a legal
  // JavaScript identifier AND the escape for a literal dollar, so a name
  // containing it arrives one `$` shorter than it left. `$&`, "$`" and `$'`
  // cannot occur inside an identifier, but they cost nothing to refuse and the
  // refusal is what makes this list a rule rather than a patch over two cases.
  const bad = /\$(?:[1-9]|\$|&|`|'|<)/.exec(String(name));
  if (bad) {
    fail(
      `the ${what} name '${name}' contains '${bad[0]}', which String.replace ` +
      `reads as its own syntax — the name would reach the image altered`,
    );
  }
  return String(name);
};

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
  const ID = '[A-Za-z_$][\\w$]*';
  const rx = /(accessToken\?\?null:null,)(\.\.\.!1,\.\.\.)([A-Za-z_$][\w$]*)(,)/;
  const m = js.match(rx);
  if (!m) fail('routing site not found');

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
    m[1] + inject + m[2] + m[3] + m[4] +
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
  const WIN = 8000;
  const gateRx = new RegExp(`if\\(!${ID}\\("tengu_[a-z0-9_]+",!1\\)\\)return;`, 'g');
  const window = js.slice(anchorIdx, anchorIdx + WIN);
  const gates = window.match(gateRx) || [];
  if (gates.length > 1) {
    fail(`session-memory extraction gate is ambiguous (${gates.length} candidates)`);
  }
  const gateDone = gates.length === 1;
  if (gateDone) {
    const gateAt = anchorIdx + window.indexOf(gates[0]);
    js = js.slice(0, gateAt) + js.slice(gateAt + gates[0].length);
  }

  // Postcondition over the SAME text as before, not the same width: the slice
  // shrank by whatever was cut, and re-reading 8000 characters would pull in
  // trailing code that was never part of this entry point.
  const after = js.slice(anchorIdx, anchorIdx + WIN - (gateDone ? gates[0].length : 0));
  if (new RegExp(`if\\(!${ID}\\("tengu_[a-z0-9_]+",!1\\)\\)\\s*return[^;]*;`).test(after)) {
    fail('session-memory extraction is still gated on a feature flag');
  }

  // (b) the extract-mode predicate: `flagA && (!something || flagB)`.
  const modeRx = new RegExp(
    `(function ${ID}\\(\\))\\{if\\(!${ID}\\("tengu_[a-z0-9_]+",!1\\)\\)return!1;` +
      `return!${ID}\\(\\)\\|\\|${ID}\\("tengu_[a-z0-9_]+",!1\\)\\}`,
    'g'
  );
  const modes = js.match(modeRx) || [];
  if (modes.length > 1) {
    fail(`session-memory extract-mode predicate is ambiguous (${modes.length} candidates)`);
  }
  const modeDone = modes.length === 1;
  if (modeDone) {
    const modeAt = js.indexOf(modes[0]);
    const head = modes[0].slice(0, modes[0].indexOf('{'));
    // Keep everything the predicate returns once its flag guard is gone. Slicing
    // it out of the match keeps the minified names of the interactivity helper
    // and the escape-hatch flag reader out of this locator entirely.
    const GUARD_END = 'return!1;';
    const body = modes[0].slice(modes[0].indexOf(GUARD_END) + GUARD_END.length, -1);
    js = js.slice(0, modeAt) + `${head}{${body}}` + js.slice(modeAt + modes[0].length);
  }
  if (new RegExp(modeRx.source).test(js)) {
    fail('session-memory extract-mode predicate still consults its feature flags');
  }
  const forcedRx = new RegExp(
    `function ${ID}\\(\\)\\{return!${ID}\\(\\)\\|\\|${ID}\\("tengu_[a-z0-9_]+",!1\\)\\}`,
    'g'
  );
  const forced = js.match(forcedRx) || [];
  if (forced.length !== 1) {
    fail(
      `session-memory extract-mode predicate is not in the forced shape ` +
        `(${forced.length} matches; expected exactly 1) -- it was neither patched ` +
        `here nor left in the shape tweakcc writes, so extraction may still be off`
    );
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
  const m = js.match(rx);
  if (!m) fail('context-window default not found');

  const [, canonical, parse, model, envValue, fallback] = m;

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

  // Tail first: editing from the end keeps the head offset valid.
  js =
    js.slice(0, m.index) +
    `&&!${canonical}(${parse}(${model})).startsWith("claude-"))return ${envValue};` +
    `return ${fallback}}` +
    js.slice(m.index + m[0].length);

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
    const coord248 = new RegExp(
      `let ${ID}=Date\\.now\\(\\);if\\(${ID}\\(\\)&&${ID}\\.` +
        `CLAUDE_CODE_COORDINATOR_FORCE_WORKER_INHERIT_MODEL\\)(${ID})=void 0;` +
        `let ${ID}=\\1,${ID}=${ID}\\(${ID}\\.agentContext\\)`,
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
  const droppedRx = new RegExp(`(?<![$\\w|&])${rxEsc(fork)}\\?void 0:(${ID})`, 'g');
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
  // 2..3, not 2..6. Measured: 2 on 233/240, 3 on 242..247. The old upper bound
  // left three free slots inside a 20 KB window, so a new same-letter site that
  // was not a fork drop would be rewritten and counted as one -- which is how
  // Vertex resolution was altered on 233 with 79/79 green.
  if (droppedAll.length < 2 || droppedAll.length > 3)
    fail(`fork value-drop sites: expected 2..3, found ${droppedAll.length}`);
  // The one that matters by name. A build where `model:` is no longer among the
  // dropped fields has stopped doing the thing this sweep exists for, and a
  // count alone cannot notice that.
  if (!droppedAll.some((mm) => body.slice(Math.max(0, mm.index - 6), mm.index) === 'model:'))
    fail('fork value-drop sites: the dispatch model is not among them');
  body = body.replace(droppedRx, '$1');
  if (new RegExp(`(?<![$\\w])${rxEsc(fork)}\\?void 0:`).test(body))
    fail('fork value-drop sites survived the sweep');
  js = js.slice(0, lo) + body + js.slice(hi);

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
  // Both names are checked here, before EITHER is written: `__ccEffort` is
  // inserted a few lines below, and a later `includes('__ccE…')` test would
  // then match its own prefix and refuse on a clean build.
  if (js.includes('__ccEffort')) fail('__ccEffort already present — refusing to shadow it');
  if (js.includes('__ccLvl')) fail('__ccLvl already present — refusing to shadow it');
  js = js.replace(callRx, `$1,effort:__ccEffort$2`);

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
  const rxBudget = new RegExp(
    `(${ID})=3,(${ID})=\\{value:0\\},((?:${ID}=[^,;]{1,24},){0,8})` +
      `(${ID})=2,(${ID})=0,(${ID})=0,(${ID})=!1,(${ID})=1,(${ID})=0,`,
  );
  const mBudget = js.match(rxBudget);
  if (!mBudget) fail('streaming retry budgets not found');
  js = js.replace(rxBudget, '$1=3,$2={value:0},$3$4=300,$5=0,$6=0,$7=!1,$8=300,$9=0,');

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
  // 2.1.246 added `truncatedAfterOutput:<hasOutput>&&!<isToolUse>?!0:void 0` to
  // this marker, and with it a RECOVERY the earlier releases had no equivalent
  // of. The field has exactly one producer -- this yield -- and one meaningful
  // reader:
  //
  //   function GJn(e,t,n){return e?.type==="assistant"&&e.isApiErrorMessage===!0
  //     &&e.truncatedAfterOutput===!0&&t.options.isNonInteractiveSession
  //     &&wl(n)==="main"&&we("tengu_truncated_response_recovery",!0)}
  //
  // whose consumer nudges the model with "Your response above was cut off
  // mid-stream. Resume directly from where it stops" and re-runs the turn, up to
  // WJn=3 attempts -- PRESERVING the partial answer instead of discarding it.
  // In that same case the marker is suppressed from the output stream, so it
  // never reaches the user as a half answer.
  //
  // Deleting the yield outright therefore killed a strictly better recovery in
  // the sessions it was written for, while doing the right thing everywhere
  // else: for an INTERACTIVE session GJn is false, nothing suppresses the
  // marker, and "The response above may be incomplete." is exactly the half
  // answer this leg exists to prevent.
  //
  // So the leg now splits on the same conditions the reader uses, expressed with
  // values in scope at this site: the session flag, the main-loop lane, and the
  // marker's own truthiness.
  //
  // The lane test must be the reader's WHOLE test, not the half of it that is
  // easy to spell. `GJn` asks `wl(n)==="main"`, and that classifier is
  //
  //   function kD(e){if(e===void 0)return;
  //     if(e.startsWith("repl_main_thread")||e==="sdk")return"main";
  //     if(e.startsWith("agent:")||e==="hook_agent")return"subagent";
  //     return"auxiliary"}
  //
  // -- so `querySource:"sdk"` is a main-loop lane too, and an earlier version of
  // this guard tested only the prefix. The subset is invisible in every check
  // that pins the guard's own text: an SDK session that truncated took the throw
  // while upstream's recovery stood ready for it. Both arms of the classifier
  // are spelled out here. Where they hold, the stock yield and break
  // run untouched and the recovery gets its turn; everywhere else the throw
  // stands. If any of them is missing from a build the expression is falsy and
  // the behaviour is exactly what it was before this change.
  //
  // Measured: the field exists on 2.1.246 and on NO earlier build in range
  // (233/240/242 carry zero occurrences), so the capture is optional and older
  // builds keep the unconditional throw -- there is no recovery there to
  // preserve.
  const rxFinal = new RegExp(
    `,yield (${ID})\\(\\{content:([^;]{0,1400}?),error:"server_error"` +
      `(?:,truncatedAfterOutput:([^,;{}]{0,80}))?((?:,[^;]{0,300}?)?)\\}\\),(${ID})!=="credited"\\)` +
      `\\5="credited",(${ID})\\+=([^;]{0,300}?);break (${ID})\\}` +
      `throw (${ID})\\("tengu_streaming_fallback_to_non_streaming",\\{model:(${ID})\\.model,` +
      `error:(${ID}) instanceof Error\\?`,
  );
  const mFinal = js.match(rxFinal);
  if (!mFinal) fail('streaming partial-finalize site not found');
  // Every captured value below is spliced into a replacement string whose
  // pattern is this 11-group RegExp, so there `$1`..`$9` are live backreferences
  // and `$$` collapses. Five of them were escaped and six were not; the six were
  // `$`-free on 233/240/242/246/247, which is why nothing broke. `accExpr` is the
  // one to watch -- it captures up to 300 characters of arbitrary expression, not
  // an identifier -- but minified identifiers may carry `$` too. repEsc on all of
  // them, so the discipline holds by construction instead of by measurement.
  const [
    ,
    arFn,
    content,
    truncExpr,
    extraTail,
    credited,
    acc,
    accExpr,
    label,
    throwFn,
    opts,
    errVar,
  ] = mFinal;

  const tail =
    `throw ${throwFn}("tengu_streaming_fallback_to_non_streaming",` +
    `{model:${opts}.model,error:${errVar} instanceof Error?`;

  if (truncExpr === undefined) {
    // No truncation marker in this build: nothing downstream can recover from
    // it, so the half answer is simply not finalized.
    js = js.replace(
      rxFinal,
      `,${repEsc(credited)}!=="credited")${repEsc(credited)}="credited",` +
        `${repEsc(acc)}+=${repEsc(accExpr)};throw ${repEsc(errVar)}}${repEsc(tail)}`,
    );
  } else {
    const recoverable =
      `(${opts}.isNonInteractiveSession&&` +
      `(${opts}.querySource?.startsWith("repl_main_thread")||${opts}.querySource==="sdk")&&` +
      `(${truncExpr}))`;
    js = js.replace(
      rxFinal,
      `,${repEsc(recoverable)}?yield ${repEsc(arFn)}({content:${repEsc(content)},` +
        `error:"server_error",truncatedAfterOutput:${repEsc(truncExpr)}${repEsc(extraTail)}})` +
        `:void 0,${repEsc(credited)}!=="credited")${repEsc(credited)}="credited",` +
        `${repEsc(acc)}+=${repEsc(accExpr)};` +
        `if(!${repEsc(recoverable)})throw ${repEsc(errVar)};break ${repEsc(label)}}${repEsc(tail)}`,
    );
  }

  applied.push(
    `a broken stream is retried, never finalized as a half answer ` +
      `(interactive lanes; the non-interactive recoverable lane keeps the stock ` +
      `partial-plus-nudge by design) ` +
      `(backoff '${backoff}', budgets ${mBudget[3]}/${mBudget[7]} -> 300, ` +
      `dropped content gate on '${mGate[1]}', error var '${errVar}', ` +
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
    'globalThis.__ccJudgeTurn.size>64&&(()=>{' +
    'let __k=globalThis.__ccJudgeTurn.keys().next().value;' +
    // Вытеснение -- УСЕЧЕНИЕ материала судьи, и оно обязано быть объявлено, как
    // всякое другое: без метки `turn()` возвращал пустой список, и «хода не
    // было» не отличалось от «ход вытеснен» (круг 20, D-11). Список потерянных
    // сам ограничен и вытесняется по тому же правилу -- он память, а не архив.
    '(globalThis.__ccJudgeTurnLost??=new Set()).add(__k);' +
    'globalThis.__ccJudgeTurnLost.size>256&&globalThis.__ccJudgeTurnLost.delete(' +
      'globalThis.__ccJudgeTurnLost.values().next().value);' +
    'globalThis.__ccJudgeTurn.delete(__k)})(),0):0)';
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
//     The consultation rides the bundle's OWN single-shot query helper, so
//     `claude-*` stays on the subscription lane and everything else goes to
//     the proxy, at the client's prices and through the client's connection
//     settings. A raw HTTP request is the fallback, not the design: it is
//     taken only when an address is named explicitly (CLAUDE_JUDGE_URL, the
//     probe's url key, raw_http) or when the helper's binding is absent from
//     this build.
//     (An earlier version of this comment claimed the opposite -- plain HTTP
//     by design, on the grounds that the helper's scope was unreachable. That
//     was the first design; the lane changed and the paragraph did not. What
//     makes the helper reachable is that its definition and both probe homes
//     share one module, which patch 22 now asserts rather than assumes.)
//     OFF unless CLAUDE_JUDGE is set. Fail-open is the DEFAULT, not a
//     property of every path: with `enforce` and `fail_closed` both on, the
//     obligation is armed (`__jarm`) and a consultation that reaches no
//     decision cancels the dispatch -- that is what fail_closed is for, and
//     `onNoVerdict`/`onFail` throw. Without them a dead proxy degrades to
//     today's behaviour instead of breaking dispatch. The paragraph used to
//     say "every failure path is fail-open", which described the first design
//     and had been false since fail_closed existed.
//     Subagent dispatches are not judged (agentType must be "main").
// --------------------------------------------------------------------------
step('22 judge consulted before a subagent dispatch', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  // se=await e.call(E,{...n,toolUseId:t,userModified:X.userModified??!1},o,i,p)
  // The tool-call shape changed in 2.1.239: the direct `e.call(w,ctx,…)` moved
  // behind an adapter `hii(e).execute(w,ctx,…)`, where
  // `hii(e) = e.executor ?? {execute:(…)=>e.call(…)}`. BOTH shapes are kept:
  // builds with the direct call are still in use, and a locator knowing only
  // the new one would break on them in exactly the same way.
  //
  // The judge latches onto the TOOL ITSELF, not the adapter: `e` has `.name`,
  // the wrapper does not. In the direct shape the tool name is caught by group
  // 2, in the adapter shape by group 3; both then reduce to one name, and the
  // group numbers do not stick out.
  const rx = new RegExp(
    `(${ID})=await (?:(${ID})\\.call|${ID}\\((${ID})\\)\\.execute)` +
      `\\((${ID}),\\{\\.\\.\\.(${ID}),toolUseId:(${ID}),` +
      `userModified:(${ID})\\.userModified\\?\\?!1\\},(${ID}),(${ID}),(${ID})\\)`,
  );
  const m = js.match(rx);
  if (!m) fail('tool dispatch call site not found');
  const TOOL = m[2] ?? m[3];
  // Only what the watcher's body actually reads is bound. The locator still
  // captures the result variable and the userModified holder -- they pin the
  // call's SHAPE, which is what keeps this pattern from matching some other
  // call -- but a captured group is not automatically a slot.
  const SLOT = { $2: TOOL, $3: m[4], $4: m[5], $5: m[6] };

  // THE SECOND SITE IS THE TOOL ITSELF, NOT ANOTHER DISPATCHER.
  //
  // An earlier form of this step hooked a second DISPATCHER -- the executor
  // the REPL sandbox hands to model-written JavaScript -- on the reading that
  // the sandbox's tool map excludes only REPL itself. Measured afterwards on
  // pristine 233/240/242/246, that reading was wrong: the array reaching the
  // sandbox is built by a filter one call earlier, which drops the dispatch
  // tool BY NAME.
  //
  //   pis(e,t){ … let o=e.filter((s)=>!Xn(s,fn)&&!Xn(s,ya)&&!UI(s)); … }
  //   fn = "Agent"  (module-local import, resolved through its exporter)
  //   ya = "REPL"
  //   R=pis(t.options.tools,Fe(t)) -> aVe(R,…)/our(v,R,…) -> POt(R.filter(…))
  //
  // So a dispatch cannot occur inside a REPL program at all, and a hook there
  // guarded nothing while adding a probe call to every tool call a sandboxed
  // program makes.
  //
  // The lesson is not "there were two dispatchers, now there are three": it is
  // that the NUMBER of dispatchers is not a constant, so anchoring a
  // fail-closed mechanism to a census of them is unsound by construction.
  // `claude mcp serve` is a third executor, `gE()` puts the dispatch tool in
  // its list (only zg/Sh/rv/"StructuredOutput" are excluded, and the http-only
  // allowlist is not applied to the stdio transport the CLI hard-codes), and it
  // builds `agentContext:{agentType:"main"}` -- i.e. an unhooked path on which
  // a dispatch really can happen.
  //
  // Every one of them ends in the SAME place: the dispatch tool's own `call`.
  // The tool declares no `executor`, so the 2.1.239 adapter
  // (`e.executor??{execute:(…)=>e.call(…)}`) falls through to it as well. The
  // product refuses a launch from exactly here too -- the nesting-depth cap
  // throws out of this method -- so a throw at this point is the product's own
  // idiom for "this dispatch does not happen", not an idiom we invented.
  //
  // The head is unique: exactly ONE occurrence on each of 2.1.233, 240, 242
  // and 246.
  // The whole signature is taken, up to and including the opening brace: the
  // block is a sequence of statements and has to land INSIDE the body, and the
  // parameter pattern has to move in with it. `[^{}]*` in the pattern is not
  // decoration -- a nested destructuring or a default value would need
  // different handling, and this refuses instead of mangling one.
  const rxTool = new RegExp(
    `async call\\((\\{prompt:${ID},subagent_type:${ID},description:${ID},` +
      `model:${ID},[^{}]*\\}),(${ID})((?:,${ID})*)\\)\\{`,
  );
  const mTool = js.match(rxTool);
  if (!mTool) fail('dispatch tool call implementation not found');
  const allTool = js.match(new RegExp(rxTool.source, 'g'));
  if (allTool.length !== 1) {
    fail(`dispatch tool call implementation is not unique (${allTool.length} matches)`);
  }
  // Shape is not identity, and uniqueness of the shape does not make it one.
  // A later build could carry ONE unrelated method with the same four leading
  // fields while the real one changed, and both checks above would still pass
  // while the judge was installed where it can never fire. In a mechanism that
  // fails CLOSED that is not a missed edit, it is a silent pass.
  //
  // The dispatch tool names itself in its own first statements: it is the only
  // place in the image that refuses a launch by the nesting-depth cap. Measured
  // on the four payloads in range: exactly one occurrence each, 179-193
  // characters past the start of the match (2.1.233 and 240 at 193, 242 at 180,
  // 246 at 179), so the window below is the measurement with room, not a guess.
  const DEPTH_CAP = '"subagent_launch","subagent_depth_cap"';
  if (!js.slice(mTool.index, mTool.index + 600).includes(DEPTH_CAP)) {
    fail(
      'the matched call implementation is not the dispatch tool ' +
        '(no depth-cap refusal among its first statements)',
    );
  }
  // Patch 12 destructures `effort` in THIS handler's parameter pattern, and
  // this step rewrites that pattern into the body. The order is therefore
  // load-bearing in one direction: run this step first and #12's locator no
  // longer matches the signature it expects, because the signature is no
  // longer the one it was written against. That failure would be loud but
  // would name the wrong thing. Asserting the marker also proves the two
  // locators, written independently, landed on the SAME method.
  if (!mTool[1].includes('effort:__ccEffort')) {
    fail(
      'the dispatch tool signature carries no effort binding from patch 12 ' +
        '(run patch 12 first — it destructures effort in the pattern this step rewrites)',
    );
  }

  // The parameter pattern moves into the body verbatim, so the destructuring
  // that the original signature performed still happens, in the same order and
  // with the same failure on a null input; the judge runs after it, on the
  // whole object under a name of our own.
  const TOOL_IN = '__ccIn';
  const SLOT_TOOL = {
    // `this` is the tool. Every route into this method binds it -- `e.call(…)`
    // at the main dispatcher, `s.call(…)` in serve mode, and the adapter's
    // arrow, which calls `e.call(…)` too. A future build that detaches the
    // method would make `$2.name` throw, i.e. cancel the dispatch: the right
    // polarity for a mechanism that fails closed, and loud instead of silent.
    $2: 'this',
    $3: TOOL_IN,
    $4: mTool[2],
    // The dispatcher puts `toolUseId` in the context it builds; serve mode
    // does not, and an undefined key degrades the record name and the turn
    // stash without stopping anything -- the judge's own material is the brief
    // and the model, both of which are in the input.
    $5: `${mTool[2]}.toolUseId`,
  };
  // The judge rides the client's OWN single-shot query
  // (queryModelWithoutStreaming), not its own HTTP call: this function goes
  // through the same client factory as any other request, so the model pool
  // and both of its lanes are the client's. `claude-*` stays on the
  // subscription lane (patch 1), everything else goes to the proxy. A dedicated
  // HTTP path would route claude-models to api.anthropic.com at API prices —
  // a different contract and a different bill. The name is located
  // structurally by signature, not by its minified spelling: it changes from
  // build to build.
  const qrx = new RegExp(
    `async function (${ID})\\(\\{messages:${ID},systemPrompt:${ID},thinkingConfig:${ID},` +
      `tools:${ID},signal:${ID},options:${ID}\\}\\)`,
  );
  const qm = js.match(qrx);
  if (!qm) fail('single-shot query engine not found');
  // A minified name can contain `$`, and the replacement string reads `$` as
  // a group reference — escape it before splicing into the replacement.
  const QM = siteName(qm[1], 'single-shot query engine');
  // The name is spliced into a block that lands at two DIFFERENT sites, and a
  // minified name is scoped to its chunk: it means the helper only inside the
  // module that defines it. Anywhere else `typeof` quietly answers
  // "undefined", the pool is null and the consultation falls back to raw HTTP
  // without a word -- the lane changes and nothing says so. Measured across the
  // range: the definition and both homes share one module (374 on 2.1.247, 360
  // on 246, 433 on 242; 233 and 240 have a single module altogether). Asserted
  // rather than assumed, because a future split would be silent.
  const [qLo, qHi] = moduleSliceAround(js, qm.index);
  for (const [label, at] of [['watcher', m.index], ['judge', mTool.index]]) {
    if (at < qLo || at >= qHi) {
      fail(
        `the single-shot query engine is defined in a different module than the ` +
          `${label} home — its name would not resolve there and the consultation ` +
          `would silently fall back to raw HTTP`,
      );
    }
  }
  // Everything the operator tunes lives in files read ON EVERY CALL, not in the
  // binary: a judge whose wording can only change by re-patching cannot be
  // iterated on. body.json is a full request template with {{CONTEXT}} and
  // {{DISPATCH}} placeholders, so model, parameters and message layout are all
  // editable; prompt.md is the shorthand when only the instruction changes.
  // Substituted text goes through JSON.stringify minus its outer quotes, so a
  // quote or newline in the transcript cannot break the template's JSON.
  // The notification-queue locator stands ABOVE the core, because the core
  // itself needs the session-id source name: both consumers write the journal,
  // and the pid a record used to be addressed by points at nothing after the
  // process dies — the OS reuses it, while the session transcript lives under
  // the session's own name. The block used to sit lower, and the core could
  // not reference it.
  // The watcher's channel: the pending-notification queue is the same one
  // mid-thread background-task results arrive through. It does NOT cancel
  // execution but inserts text into the thread, and that is the only form fit
  // for a reminder: from inside the executing tool the message array is
  // unreachable at all (injections are collected only AFTER the whole batch),
  // so a judge-style throw is wrong here by construction, not by taste.
  const nrx = new RegExp(
    `(?:^|[^.\\w$])(${ID})\\(\\{mode:"task-notification",agentId:(${ID})\\(\\)`,
  );
  const nm = js.match(nrx);
  if (!nm) fail('pending-notification queue not found');
  const TV = siteName(nm[1], 'notification queue');
  const DI = siteName(nm[2], 'session id');

  // The session-title accessor. The locator requires an ARGUMENT: in the hook
  // schemas the same property name carries a zod string
  // (`session_title:H().optional()`), and a locator without an argument would
  // latch onto that. The name itself is declared in several scopes in the
  // image, so the binding at the injection point is NOT proven — the call
  // below is guarded by a shape check, not by faith in a name.
  const trx = new RegExp(`session_title:(${ID})\\([\\w$]+[.\\w$]*\\)`);
  const tm = js.match(trx);
  if (!tm) fail('session title accessor not found');
  const TTL = siteName(tm[1], 'session title accessor');

  const core =
    // Intervals and schedules are measured on a MONOTONIC clock, timestamps
    // are not. The wall clock is the only thing that can name the moment a
    // consultation happened, and the only thing that must never be used to
    // measure how long it took: it steps backwards on an NTP correction and
    // forwards across a sleep. Both were live: `ms` in the journal could come
    // out NEGATIVE while the caller was still waiting, and a step back left
    // `nextAt` in the future -- muting the watcher with no journal line at all,
    // since `pre` writes nothing by design.
    //
    // Installed at the head of the CORE because the core is prepended to both
    // blocks, so in the watcher this line runs one statement before the fleet
    // mark is pushed. A second copy is inert by the same `??=` that guards the
    // core itself, and the one home of the text is this string.
    '/*__ccCore0*/globalThis.__ccMono??=(()=>{let __p=globalThis.performance;' +
      'return __p&&typeof __p.now==="function"?()=>Math.round(__p.now()):()=>Date.now()})();' +
    'globalThis.__ccProbe??=async function(__o){' +
    // The filter runs BEFORE any I/O. For a probe called on every tool call,
    // a "cheap count after reading settings" bankrupts it twice: walking up
    // the tree costs up to 96 filesystem accesses per call, and the refusal is
    // written as a line into the journal — the very one a human reads. The
    // predicate works purely from memory and writes NOTHING: a skipped pass is
    // not a consultation outcome but its absence. A predicate throw leads to a
    // full pass, not to a skip: a filter failure must not blind the probe.
    'if(__o.pre){let __pr=null;try{__pr=__o.pre()}catch{__pr=null}if(__pr)return}' +
    // Проба, выключенная настройкой, платила полную цену КАЖДОГО вызова:
    // обход проектного слоя, два чтения TOML и строка журнала -- при том, что
    // ответ известен заранее. Дешёвый предфильтр `pre` тут не спасает: он
    // читает состояние ПОТРЕБИТЕЛЯ, а оно выставляется в его же `gate`, до
    // которого ветка disabled не доходит никогда (круг 20, D-3). Памятка
    // принадлежит ЯДРУ и решению ядра (общее ядро не хранит состояние
    // потребителя) и живёт по идентификатору пробы.
    //
    // Памятка гасит ПОВТОРНУЮ СТРОКУ ЖУРНАЛА, а не чтение настроек. Первая
    // редакция выходила из ядра ДО чтения конфига, и это ломало
    // ратифицированное свойство «конфиг и промт читаются на КАЖДОЙ
    // консультации»: включённая обратно проба молчала бы ещё до минуты, а в
    // одном процессе выключение одной пробы уводило в тишину все последующие
    // консультации той же пробы (измерено probe-bench: 6 сценариев подряд не
    // получали НИ одного исхода docnum:subset). Настройки читаются всегда;
    // памятка знает
    // подпись тех настроек, по которым принято решение, и любая их правка
    // возвращает строку журнала немедленно.
    'let __offs=(globalThis.__ccOff??={});' +
    // Every consultation is journaled, not just the ones run with debug on:
    // a WARN has no channel to the model (the dispatch proceeds, and the
    // tool_result the model later sees comes from the agent itself), and a
    // fail-open skip is invisible by construction. Without an append-only
    // record both are indistinguishable from a judge that was never asked —
    // the "switched off at both ends" failure. Declared OUTSIDE the try so
    // the catch can still record why a consultation was skipped.
    // One number per consultation, taken at the START and used by both the
    // record name and the debug artefacts. Taken at the end it named only the
    // record, and the debug files -- written DURING the ladder -- had nothing
    // but the pid: two consultations running at once in one process (parallel
    // tool calls in a single turn) overwrote each other's last-request and
    // last-verdict, so the pair a human read belonged to neither.
    'let __seq=globalThis.__ccRecSeq=(globalThis.__ccRecSeq??0)+1;' +
    'let __t0=globalThis.__ccMono(),__jfs=null,__jrec=!0,__jgz=!1,__jkeep=500,__nseen={},' +
    '__jreq=null,__jres=null,__jst=null,' +
    // __jtry=0, not 1: before the first attempt there are ZERO attempts. A one
    // claimed an attempt where the throw happened BEFORE the ladder.
    // __pdir is declared HERE, not inside the try: the catch is a neighboring
    // block, and a let from the try is not visible in it. Measured on a live
    // call: the skip path crashed with ReferenceError BEFORE the journal write,
    // the dispatch got "__pdir is not defined", and the journal got nothing.
    // __jarm: the judgment must reach a decision. Armed when the call is not
    // filtered out and enforce+fail_closed are on; released once the decision
    // is made. If control reaches the catch with the flag still armed — that is
    // a silent pass, and it gets cancelled.
    '__jtry=0,__jerr1=null,__jm=null,__jurl=null,__jatt=[],__pdir=null,__jarm=!1,' +
    // Any catch{} without a trace turns a breakage into quiet degradation: a
    // broken config silently removed enforce and fail_closed while the journal
    // showed routine operation. Degradations are collected and land in the
    // journal as the deg field; the ones touching THE JUDGMENT ITSELF are
    // gathered separately and cancel the call.
    '__deg=[],__degb=[],' +
    // Every numeric setting was read as `Number(x||default)`, which normalizes
    // the falsy typos and lets through the two that matter. A NEGATIVE value
    // passes: `threshold=-1` makes `__n>=__th` always true and indexes the
    // window past its end, so nextAt becomes NaN and the watcher goes
    // PERMANENTLY silent -- the one mechanism answering for the fleet, mute
    // with nothing in the journal. A non-numeric value passes too, the other
    // way: `threshold="abc"` yields NaN, `__n>=NaN` is false, and the gate
    // stops applying at all. `||` cannot tell "absent" from "invalid"; this
    // does, keeps the default, and says so in the journal, because a setting
    // silently ignored is a guarantee silently dropped.
    // No `let` here and a comma at the end: this whole block is ONE declaration
    // list (`let __t0=…,__jtry=…,__deg=[],…,__jdir=…;`), so a second `let`
    // inside it parses as a binding NAMED `let` — a strict-mode reserved word,
    // and the emit gate refuses the block outright.
    '__num=(__k,__v,__d,__min,__q)=>{if(__v===void 0||__v===null||__v==="")return __d;' +
      'let __x=Number(__v);' +
      'if(!Number.isFinite(__x)||__x<__min){' +
        'if(!__q&&!__nseen[__k]){__nseen[__k]=1;' +
          '__deg.push("bad-setting:"+__k+"="+__clip(__v,24)+" (need >="+__min+"), using "+__d)}' +
        'return __d}' +
      'return __x},' +
    // The degradation list is cut with a declaration: a silently dropped sixth
    // line means the human fixes five files, restarts, and gets the
    // cancellation again.
    // Two bounds, not one: __k caps HOW MANY lines are kept and 300 caps how
    // long each of them may be. Only the count was capped before, so one entry
    // built from a parser message plus a path was unbounded — and an unbounded
    // journal line is what makes an append from two sessions able to tear,
    // there being no flock in node:fs/promises to fall back on.
    // A non-string element is clipped by its JSON, not by String(): the
    // latter turns any object into the fifteen characters "[object Object]",
    // which is a silent loss of the value in the one place that was supposed
    // to be declaring its losses. Both current callers pass string lists, so
    // this changes nothing for them; it matters for whoever passes the next
    // list, who will not read this line first.
    '__dcut=(__l,__k)=>(__l.length<=__k?__l:__l.slice(0,__k)).map((__i)=>__clip(typeof __i==="string"?__i:JSON.stringify(__i),300))'+
      '.concat(__l.length<=__k?[]:('+
      '["[\\u043f\\u043e\\u043a\\u0430\\u0437\\u0430\\u043d\\u044b \\u043d\\u0435 \\u0432\\u0441\\u0435: \\u0435\\u0449\\u0451 "+(__l.length-__k)+"]"])),' +
    // Every truncation in the journal and the record is declared — by the same
    // convention as trimming the transcript: a verdict cut mid-word reads as a
    // complete verdict, and a truncated failed-attempt reply as its whole
    // trace.
    // A cut is measured in UTF-16 code units, so it can land BETWEEN the halves
    // of a surrogate pair and leave an unpaired one at the seam. That is not a
    // cosmetic loss: the fragment goes into JSON and then into text a model
    // reads, where an unpaired surrogate is either an error or a replacement
    // character standing where an emoji was. Every cut of TEXT A MODEL WILL
    // READ runs through here -- the clip, both halves of the transcript trim,
    // and the dispatch head -- so the seam is repaired in ONE place: a
    // trailing high half and a leading low half are dropped.
    //
    // The sentence used to say "every slice", which was false in both
    // directions: cuts that are not text (the fleet ring, the prune victim
    // list, the key suffix of a record name, the JSON quote pair) must NOT
    // pass through here -- they have no seam -- and the dispatch head, which
    // should have, did not. The pipeline's cut census records both facts per
    // site, so neither half of that can drift again unnoticed.
    '__sur=(__x)=>{let __s0=String(__x);' +
      'if(__s0.length){let __c0=__s0.charCodeAt(0);' +
        'if(__c0>=56320&&__c0<=57343)__s0=__s0.slice(1)}' +
      'if(__s0.length){let __c1=__s0.charCodeAt(__s0.length-1);' +
        'if(__c1>=55296&&__c1<=56319)__s0=__s0.slice(0,-1)}' +
      'return __s0},' +
    '__clip=(__s,__k)=>{let __x=String(__s??"");return __x.length<=__k?__x:'+
      '__sur(__x.slice(0,__k))+" [\\u0432\\u044b\\u0440\\u0435\\u0437\\u0430\\u043d\\u043e "+'+
      '(__x.length-__k)+" \\u0437\\u043d\\u0430\\u043a\\u043e\\u0432]"},' +
    // The probes home is computed ONCE. It used to be spelled out twice, in
    // two identical expressions, and derived two names for one and the same
    // string -- so an edit to either would have sent the journal to a different
    // home than the settings, and nothing would have said so.
    '__phome=__o.dirEnv||((process.env.HOME||".")+"/.claude/probes"),' +
    '__jdir=__phome+"/"+__o.dirName;' +
    // The journal line is an INDEX, not evidence: its verdict is clipped and
    // the material the judge actually saw is nowhere in it, so neither
    // "did it judge correctly" nor "train a smaller model on these" can be
    // answered from it. The full request/response pair is written beside it,
    // one file per consultation, and the journal line carries its name.
    // The session id is obtained the same way the watcher addresses its
    // reminder: `Di()` in the image returns exactly `sessionId` (the `Pd`
    // wrapper is the identity), and absent a session, the main agent's id. It
    // also names the transcript file, so the journal line becomes joinable
    // with the correspondence — something pid never gave. The throw is
    // swallowed: the journal line is the only thing a human judges the
    // mechanism by, and losing it over a field is worse than losing the field.
    'let __sid=()=>{try{return ' + DI + '()}catch{return null}};' +
    // The dispatch model is RESOLVED, not copied from the call: a third of
    // dispatches name no model explicitly — it comes from the agent definition
    // or is inherited from the main loop. A journal writing only the explicit
    // ones undercounted that third, and the "who worked with what" census lied.
    // The resolution source is placed alongside (msrc): a dispatch by
    // inheritance and a dispatch with an explicit model are different facts,
    // and telling them apart is the journal reader's job, not a guess.
    'let __mdl=()=>{try{let __m=__o.input?.model;if(__m)return{m:__m,s:"call"};' +
      'let __a=__o.input?.subagent_type;if(!__a)return{m:void 0,s:void 0};' +
      'let __d=(__o.ctx?.options?.agentDefinitions?.activeAgents||[])' +
        '.find((__x)=>__x?.agentType===__a);' +
      'let __dm=__d?.model;' +
      'if(__dm&&__dm!=="inherit")return{m:__dm,s:"agent"};' +
      'let __im=__o.ctx?.options?.mainLoopModel;' +
      'if(__im)return{m:__im,s:__dm==="inherit"?"inherit":"main"};' +
      'return{m:void 0,s:__d?"unresolved":"no-def"}}catch{return{m:void 0,s:"error"}}};' +
    // Session title: the accessor's name is declared in several scopes in the
    // image, and a wrong binding would return a stack parse instead of a
    // string — silently. The shape check turns an unprovable assumption into a
    // measurable one: not a string means the field is absent, not garbage in
    // the journal.
    'let __ttl=()=>{try{let __i=__sid();if(!__i)return void 0;' +
      'let __v=' + TTL + '(__i);' +
      'return typeof __v==="string"&&__v?__v:void 0}catch{return void 0}};' +
    'let __jsave=async(__ts,__base)=>{if(!__jrec||!__jreq||!__jfs)return null;' +
      // The record's NAME is the join key of the whole corpus: the journal
      // line points at it through `rec`, and judge/validate.py indexes labels
      // by that basename. Two consultations under one name do not merely
      // overwrite a file -- they merge two different judgements under one
      // label, and nothing in the data says it happened.
      //
      // The tool-use id cannot carry that guarantee. `claude mcp serve` builds
      // its context WITHOUT one -- `agentContext:{agentType:"main",agentId:…}`
      // and no `toolUseId` field at all -- so `String(undefined).slice(-8)`
      // gave every consultation on that whole route the same `-ndefined` name.
      // That route reaches the judge BY CONSTRUCTION: the judge rides the tool
      // precisely so that no executor can miss it, which is exactly why the
      // name may no longer assume the caller had an id to give.
      //
      // So uniqueness is the CORE's guarantee, held for every caller present
      // and future, while the key stays honest -- named `nokey` when the route
      // has none, rather than stringified into a word that reads like a bug.
      // pid separates processes, the counter separates calls inside one.
            // The counter is zero-padded because the name is SORTED, and an unpadded
      // one sorts 10 before 9. The ISO stamp keeps the order between different
      // milliseconds; within one millisecond the counter is the only tiebreak,
      // and unpadded it inverted -- so a prune at the horizon could take the
      // newer of two records written in the same millisecond. Six digits is
      // past any process lifetime here (one per consultation); beyond it the
      // order breaks again, and only inside a single millisecond.
      'let __n=__ts.replace(/[:.]/g,"-")+"-"' +
        '+(__o.key==null?"nokey":String(__o.key).slice(-8))' +
        '+"-"+process.pid+"-"+String(__seq).padStart(6,"0")+".json"+(__jgz?".gz":"");' +
      'try{await __jfs.mkdir(__jdir+"/records",{recursive:!0});' +
        'let __rq;try{__rq=JSON.parse(__jreq)}catch{__rq=__jreq}' +
        // rx/act — only here, not in the shared base: the base also feeds the
        // journal line. The corpus parser needs the vocabulary so as not to
        // hardcode the judge's OK/WARN/BLOCK into the tools: the watcher's
        // classes are its own, and its annotation cannot be expressed in the
        // judge's words. The vocabulary has one source — the caller in the
        // binary; a copy in config.json would drift from it silently.
        'let __data=JSON.stringify({...__base,rx:__o.rx,act:__o.act,' +
          'http:__jst,url:__jurl,pid:process.pid,' +
          'cwd:process.cwd(),attempts:__jatt,request:__rq,response:__jres},null,1);' +
        'let __out=__data;' +
        'if(__jgz){try{let __z=await import("node:zlib");__out=__z.gzipSync(Buffer.from(__data))}' +
          'catch{__n=__n.replace(/\\.gz$/,"")}}' +
        'await __jfs.writeFile(__jdir+"/records/"+__n,__out);' +
        // Two things this loop must not do.
        //
        // It must not delete the record THIS consultation just wrote. Names are
        // ordered by a wall-clock stamp, so a clock stepped backwards makes the
        // newest file sort earliest and the horizon eats it first -- the one
        // record whose loss is guaranteed to matter, because it is the one
        // someone is about to read. Excluding it by name costs nothing and holds
        // whatever the clock does. (Records from OTHER processes cannot be
        // ordered against ours under a rolled-back clock by any means available
        // here -- mtime comes from the same clock -- so the guarantee is exactly
        // this one, and it is stated as such.)
        //
        // And it must not read a neighbour's success as its own failure. Two
        // live sessions prune the same directory and pick overlapping victims;
        // the loser used to get ENOENT, abandon the REST of its list, and report
        // "record prune failed" -- the same channel a real prune failure uses,
        // which is how a benign race devalues the one message that means
        // something. A file already gone is the outcome this loop wanted.
        'try{let __ls=(await __jfs.readdir(__jdir+"/records")).filter((__x)=>__x!==__n);' +
          'if(__ls.length>=__jkeep){__ls.sort();' +
            'for(let __old of __ls.slice(0,__ls.length-__jkeep+1))' +
              'try{await __jfs.unlink(__jdir+"/records/"+__old)}' +
              'catch(__ue){if(__ue?.code!=="ENOENT")throw __ue}}}' +
        'catch(__pe){try{console.error(__o.tag+" record prune failed: "' +
          '+(__pe?.message??__pe))}catch{}}' +
        'return __n}' +
      'catch(__re){try{console.error(__o.tag+" record write failed: "+(__re?.message??__re))}catch{}' +
        // В __deg, но НЕ в __degb: недоступный каталог записей портит
        // корпус, а не сам вердикт, и отменять из-за прав на диске
        // чужие вызовы было бы хуже болезни.
        'try{__deg.push("rec-write:"+String(__re?.code??"")+" "+__clip(__re?.message??__re,48))}catch{}' +
        'return null}};' +
    // `ms` and `sw` exist because both were unobservable before: a `block`
    // line and a `block_not_enforced` line differ only by a state the record
    // never held, and the latency tax — the feature's whole running cost —
    // was measurable only by watching a session with a stopwatch.
    'let __jlog=async(__oc)=>{let __ts=new Date().toISOString();' +
      'let __mv=__mdl();' +
      // pid стоит в строке журнала НЕ как адрес -- адрес это sid, а pid система
      // переиспользует. Это ПОДПИСЬ ПИСАТЕЛЯ: стенд (tools/probe-bench.js)
      // отличает свою протечку в живой дом проб от работы чужой сессии только
      // по ней, а до этого журнальная половина его атрибуции была мертва --
      // pid стоял лишь в ЗАПИСИ, и протечка, выраженная одной дозаписью
      // журнала (запись не пишется при record=false), объявлялась чужой.
      'let __base={t:__ts,sid:__sid(),pid:process.pid,title:__ttl(),tool:__o.tool.name,' +
        'agent:__o.input?.subagent_type,model:__mv.m,msrc:__mv.s,' +
        'cfg:__pdir||null,' +
        'ms:globalThis.__ccMono()-__t0,sw:__o.sw||null,...__oc};' +
      // Bound every string the line carries, whatever put it there.
      'for(let __k2 in __base){let __v2=__base[__k2];' +
        'if(typeof __v2==="string")__base[__k2]=__clip(__v2,400);' +
        'else if(Array.isArray(__v2))__base[__k2]=__dcut(__v2,8);' +
        // The third arm is what makes the name of this guarantee true. A
        // value that was neither string nor array used to go into the line
        // untouched, so one object field could carry an unbounded string
        // inside it and "the line is bounded" would be decoration. Numbers,
        // booleans and null are short by construction; objects are not.
        'else if(__v2&&typeof __v2==="object")__base[__k2]=__clip(JSON.stringify(__v2),400)}' +
      'let __rn=await __jsave(__ts,__base);' +
      'let __r=JSON.stringify(__rn?{...__base,rec:__rn}:__base);' +
      // On a fresh install the judge's directory does not exist yet, and that
      // is where cancellations are most numerous: an append without mkdir lost
      // exactly the lines by which the human was supposed to understand what to
      // fix (they went to stderr, not to the journal).
      'try{if(!__jfs)throw new Error("fs unavailable");' +
        'try{await __jfs.appendFile(__jdir+"/journal.jsonl",__r+"\\n")}' +
        'catch(__ae){if(__ae?.code!=="ENOENT")throw __ae;' +
          'await __jfs.mkdir(__jdir,{recursive:!0});' +
          'await __jfs.appendFile(__jdir+"/journal.jsonl",__r+"\\n")}}' +
      'catch(__we){try{console.error(__o.tag+" journal write failed: "+' +
        '(__we?.message??__we)+" | "+__r)}catch{}}};' +
    // The core's services, handed to the consumer as an ARGUMENT.
    // Not a convenience: the core is a closed function assigned to
    // globalThis, while a consumer's call sits in the scope of the site
    // it was spliced into. Everything declared here is invisible there.
    // The watcher's queueing-failure handler used to call `__jlog` and
    // `__clip` by their bare names, which are free variables at that
    // site: the call threw ReferenceError, its own `catch{}` swallowed
    // it, and the `nudge_undelivered` line the comment beside it
    // promises could never be written. Nothing saw it -- the check
    // asked whether the text was present, and free names are a RUNTIME
    // error, so neither the parse stand nor the text checks can see
    // one. Passing them makes the dependency structural: a consumer
    // that gets no services cannot call them by accident.
    // Per-consultation, not global: __jlog closes over THIS call's
    // directory, tag and timers, so a shared copy would attribute one
    // consultation's lines to another whenever two overlap.
    'let __svc={log:__jlog,clip:__clip,num:__num};' +
    'try{' +
      // The turn snapshot is the JUDGE's material and the judge's alone, so the
      // core only asks its caller for it. It used to read and DELETE the stash
      // itself, which made the map's single-consumer contract depend on which
      // consumer happened to run the core first -- and the two consumers do not
      // even sit at the same site any more. The watcher, which has no use for a
      // turn, would then have destroyed it before the judge was reached: not a
      // crash and not a refusal, just a judge suddenly reasoning without the
      // thinking that motivated the dispatch, on the first call of a session
      // and on every watcher window afterwards. Ownership is now structural
      // rather than positional.
      'let __t=__o.turn?__o.turn():[];' +
      'if(!__t.length&&__o.turnLost&&__o.turnLost())__deg.push("turn-evicted");' +
      // Provenance, not just role. Claude Code files tool results, injected
      // reminders, task notifications and peer messages under the SAME "user"
      // role as something the human typed, so a judge shown bare role labels
      // reads the dispatcher's own text as the user's sanction — measured: a
      // dispatch was waved through because the main loop had written "this is
      // a sanctioned probe" a second earlier. Only a turn that is neither a
      // tool result nor an injected block keeps the "user" label.
      // Three defects in a row (local command output, slash-command arguments,
      // the compaction summary) were one and the same class: Claude Code keeps
      // filing new kinds of entries under the "user" role, and each was found
      // THROUGH AN INCIDENT. Therefore an unknown wrapper surviving in the
      // "user" class lands in the journal as the uw field — the class becomes
      // measurable instead of a surprise.
      'let __fs=await import("node:fs/promises");__jfs=__fs;' +
      // One home for all probes: everyone's settings live in the probes.toml
      // next door; each probe keeps a directory for its prompt, template,
      // journal and records. Both are computed in the preamble, ABOVE the try,
      // because the catch journals too and a binding from the try is not
      // visible there.
      // A probe stays project-agnostic on purpose: it rules on the event, the
      // logic and the rules, not on what a project is about. What a project MAY
      // do is restate the rules for itself — a nearest `.claude/probes` above
      // the cwd layers over the global one (config keys merge, `prompt.extra.md`
      // is appended, a full `prompt.md`/`body.json` replaces). An explicit
      // CLAUDE_PROBES_DIR turns layering off: a probe must get exactly what it
      // was handed. (The names in this comment were `.claude/judge` and
      // CLAUDE_JUDGE_DIR until the two probes were given one home; the code
      // moved and the comment did not.)
      '__pdir=null;let __phomeP=null;' +
      // An absent layer and an UNREADABLE layer are different events: the
      // first means "no rules", the second "there are rules but I could not
      // read them". While both produced the same thing
      // (access().catch(()=>!1)), project rules vanished silently and the walk
      // went higher and picked up a FOREIGN layer.
      // The distinction is not ENOENT versus everything else, but "no such
      // path" versus "the path exists, no access". A plain file named .claude
      // at an ancestor gives ENOTDIR, a symlink loop gives ELOOP; both mean
      // "no such directory", have nothing to do with "the layer exists but I
      // could not read it", yet they cancelled the WHOLE subtree with a healthy
      // judge. An unfamiliar code cancels nothing but does not vanish either:
      // it is named in the journal.
      'let __pcode=(__er)=>{let __c=String(__er?.code||"");' +
        'return __c==="EACCES"||__c==="EPERM"?2:' +
        '(__c==="ENOENT"||__c==="ENOTDIR"||__c==="ELOOP"||__c==="ENAMETOOLONG"?0:3)};' +
      'if(!__o.dirEnv)try{let __p=process.cwd();' +
        'for(let __i=0;__i<24;__i++){let __ch=__p+"/.claude/probes",__c=__ch+"/"+__o.dirName;' +
          'let __has=await Promise.all([__ch+"/probes.toml",__c+"/prompt.md",' +
            '__c+"/prompt.extra.md",__c+"/body.json"].map((__f)=>' +
            '__fs.access(__f).then(()=>({c:1})).catch((__er)=>' +
              '({c:__pcode(__er),e:String(__er?.code||"ERR")}))));' +
          'let __no=__has.find((__x)=>__x.c===2),__un=__has.find((__x)=>__x.c===3);' +
          'if(__no){__deg.push("layer-unreadable:"+__c+" ("+__no.e+")");' +
            '__degb.push("layer-unreadable:"+__c+" ("+__no.e+")");' +
            'if(__c!==__jdir){__pdir=__c;__phomeP=__ch}break}' +
          'if(__un)__deg.push("layer-unknown:"+__c+" ("+__un.e+")");' +
          'if(__has.some((__x)=>__x.c===1)){if(__c!==__jdir){__pdir=__c;__phomeP=__ch}break}' +
          'let __up=__p.replace(/\\/[^\\/]*$/,"");if(!__up||__up===__p)break;__p=__up}}catch{}' +
      // The reader declares its outcome: null — no file, !1 — the file exists
      // but was not read or not parsed. A silent parse turned a broken config
      // into an empty object, and with it enforce, fail_closed, the ladder and
      // max_tokens were lost — the judge looked alive and passed everything.
      'let __rdj=async(__f)=>{try{return await __fs.readFile(__f,"utf8")}' +
        'catch(__er){let __k=__pcode(__er);' +
          'if(__k===2){__deg.push("unreadable:"+__f+" ("+String(__er?.code)+")");' +
            '__degb.push("unreadable:"+__f+" ("+String(__er?.code)+")")}' +
          'else if(__k===3)__deg.push("unread-unknown:"+__f+" ("+' +
            'String(__er?.code||__er?.message)+")");' +
          'return null}};' +
      // A BOM is invisible and JSON.parse rejects it: the human got a
      // cancellation with a message where the breaking character cannot be
      // seen, and there was no way out of it by reading. An empty file is
      // called empty, not "unexpected end of input": it is an ordinary
      // intermediate state of a record, and the human must recognize the cause
      // at first glance.
      'let __ldj=async(__f)=>{let __x=await __rdj(__f);if(__x===null)return null;' +
        'if(__x.charCodeAt(0)===65279)__x=__x.slice(1);' +
        'if(!__x.trim()){__deg.push("empty:"+__f);__degb.push("empty:"+__f);return !1}' +
        'try{return JSON.parse(__x)}catch(__pe){__deg.push("unparsed:"+__f+": "+' +
          '__clip(__pe?.message??__pe,60));' +
          '__degb.push("unparsed:"+__f+": "+__clip(__pe?.message??__pe,60));return !1}};' +
      // The TOML parser belongs to the image's runtime (bun). Its absence is a
      // journal event, not an empty object: empty settings silently remove
      // enforce, the ladder and the budgets.
      'let __ldt=async(__f)=>{let __x=await __rdj(__f);if(__x===null)return null;' +
        'if(__x.charCodeAt(0)===65279)__x=__x.slice(1);' +
        'if(!__x.trim()){__deg.push("empty:"+__f);__degb.push("empty:"+__f);return !1}' +
        'let __tp=globalThis.Bun?.TOML?.parse;' +
        'if(typeof __tp!=="function"){__deg.push("no-toml-parser:"+__f);' +
          '__degb.push("no-toml-parser:"+__f);return !1}' +
        'try{return __tp(__x)}catch(__pe){' +
        'let __x2=await __rdj(__f);' +
        'if(__x2!==null&&__x2!==__x){if(__x2.charCodeAt(0)===65279)__x2=__x2.slice(1);' +
          'try{return __tp(__x2)}catch{}}' +
        '__deg.push("unparsed:"+__f+": "+' +
          '__clip(__pe?.message??__pe,60));' +
          '__degb.push("unparsed:"+__f+": "+__clip(__pe?.message??__pe,60));return !1}};' +
      // A probe's effective settings: [defaults] under its own table, the
      // project layer on top in the same order. A probe not named in the file
      // gets bare defaults — not an error but the absence of its own edits.
      'let __eff=(__t,__id)=>__t&&typeof __t==="object"' +
        '?{...(__t.defaults||{}),...((__t.probe||{})[__id]||{})}:{};' +
      // __cfgseen -- «настроечный слой ВООБЩЕ был прочитан». Без него строка
      // журнала не отличала «файла настроек нет» от «файл есть и говорит
      // enforce=false»: оба давали en:null. Первое -- свойство машины (kit не
      // раскатан), второе -- решение человека, и лечатся они по-разному.
      'let __cfg={},__cfgbad=!1,__cfgseen=!1;' +
      'let __c0=await __ldt(__phome+"/probes.toml");' +
      'if(__c0===!1)__cfgbad=!0;else if(__c0){__cfgseen=!0;__cfg=__eff(__c0,__o.dirName)}' +
      'if(__phomeP){let __c1=await __ldt(__phomeP+"/probes.toml");' +
        'if(__c1===!1)__cfgbad=!0;else if(__c1){__cfgseen=!0;__cfg={...__cfg,...__eff(__c1,__o.dirName)}}}' +
      // Disabling a probe is a setting, not a missing file: the registry must
      // be able to silence one consumer without touching the others.
      'if(__cfg.enabled===!1){' +
        'let __dm=__num("disabled_memo_ms",__cfg.disabled_memo_ms,60000,0),' +
          // Подпись -- РОВНО те настройки, по которым принято решение (оба
          // слоя уже слиты в __cfg) плюс их дома. Строка журнала повторяется
          // не раньше срока, но ЛЮБАЯ правка настроек печатает её сразу:
          // читатель журнала видит каждое новое состояние, а не одно на минуту.
          '__sg=__o.dirName+"|"+__phome+"|"+(__phomeP||"")+"|"+JSON.stringify(__cfg),' +
          '__pv=__offs[__o.dirName];' +
        'if(!(__pv&&__pv.s===__sg&&__pv.u>globalThis.__ccMono())){' +
          '__offs[__o.dirName]={u:globalThis.__ccMono()+__dm,s:__sg};' +
          'await __jlog({outcome:"skip_disabled",memo_ms:__dm})}' +
        'return}' +
      'if(__cfg.record===!1)__jrec=!1;' +
      'if(__cfg.record_gzip===!0)__jgz=!0;' +
      '__jkeep=__num("records_keep",__cfg.records_keep,500,1);' +
      'let __ask=!0;' +
      'if(__cfg.filter){let __f=__cfg.filter,__pm=String(__o.input?.prompt??""),' +
        // Первое совпадение по промпту угоняется цитатой: бриф, пересказывающий
        // чужой диспатч, несёт чужой маркер РАНЬШЕ собственного (круг 20, D-8).
        // Собираются ВСЕ маркеры; один класс -- он и есть, несколько РАЗНЫХ --
        // неоднозначность, и она не даёт пропустить вызов мимо судьи: пропуск по
        // классу отменяется, консультация идёт, расхождение объявлено.
        '__cls=[...new Set((String(__pm).match(/\\[dispatch-class:[\\w-]+\\]/g)||[])' +
          '.map((__s)=>__s.slice(16,-1)))],' +
        '__amb=__cls.length>1,' +
        '__cl=__cls.length===1?__cls[0]:"",' +
        '__ag=String(__o.input?.subagent_type??""),' +
        '__mt=(__l,__s)=>Array.isArray(__l)&&__l.length>0&&__l.some((__r)=>{try{return new RegExp(__r).test(__s)}catch{return !1}});' +
        'let __by=null;' +
        'if(__amb)__deg.push("dispatch-class-ambiguous:"+__dcut(__cls,4));' +
        'if(!__amb&&__mt(__f.classes_skip,__cl))__by="classes_skip";' +
        'else if(__mt(__f.agents_skip,__ag))__by="agents_skip";' +
        'else if(!__amb&&((Array.isArray(__f.classes_judge)&&__f.classes_judge.length>0)||' +
          '(Array.isArray(__f.agents_judge)&&__f.agents_judge.length>0))){' +
          'if(!(__mt(__f.classes_judge,__cl)||__mt(__f.agents_judge,__ag)))' +
            '__by=__cl?"not_in_judge_list":"no_class_marker"}' +
        'if(__by){__ask=!1;await __jlog({outcome:"filtered",by:__by,cls:__cl||null,' +
          '...(__deg.length?{deg:__dcut(__deg,5)}:{})})}}' +
      // The probe's own cheap count: receives the ALREADY-read settings and
      // returns a reason not to call the model. The judge does not set one —
      // its consultation is unconditional; without it the watcher's
      // consultation would become a permanent expense line on every tool call.
      'if(__ask&&__o.gate){let __g=null;try{__g=await __o.gate(__cfg,__svc)}catch(__ge){' +
        '__g="gate-failed:"+String(__ge?.message??__ge)}' +
        'if(__g){__ask=!1;await __jlog({outcome:"filtered",by:String(__g),cls:null,' +
          '...(__deg.length?{deg:__dcut(__deg,5)}:{})})}}' +
      // The transcript is built AFTER the filter and the cheap count, not
      // before them: the watcher is called on every tool call, and parsing the
      // whole history for the sake of an immediate refusal would be paying for
      // work that is not needed. Taking the thread snapshot stayed above —
      // otherwise a filtered-out call would leave an entry in the turns table
      // forever.
      'let __uw=[];' +
      'let __arr=[...(__o.ctx.messages||[]),...__t].map((__M)=>{let __m=__M?.message;if(!__m)return null;' +
        'let __c=Array.isArray(__m.content)?__m.content:[{type:"text",text:String(__m.content??"")}];' +
        'let __bt=__c.map((__b)=>__b?.type==="text"?__b.text:' +
        '__b?.type==="thinking"?"[thinking] "+__b.thinking:' +
        // Declared, like every other cut in this code. These two were bare
        // slices: a tool_use input longer than 400 characters reached the judge
        // looking WHOLE, and a brief that had lost its tail read as a brief
        // that never had one -- the same shape of defect as the dispatch label
        // that once cut a brief without saying so, one level down, on the
        // transcript entries. The marker costs about 27 characters on top of
        // the nominal cap; the cap is here to bound the payload, and it still
        // does.
        '__b?.type==="tool_use"?"[tool "+__b.name+"] "+__clip(JSON.stringify(__b.input),400):' +
        '__b?.type==="tool_result"?"[result] "+__clip(String(typeof __b.content==="string"?__b.content:JSON.stringify(__b.content)),300):' +
        '"["+__b?.type+"]").join("\\n");if(!__bt)return null;' +
        // Provenance comes from the ENVELOPE first (isMeta / toolUseResult are
        // what Claude Code itself uses to tell synthetic and tool messages
        // apart) and only falls back to sniffing wrapper markers.
        'let __role=__m.role||__M.type||"?";' +
        'if(__role==="user")__role=(__M?.toolUseResult!==void 0||__c.some((__x)=>__x?.type==="tool_result"))' +
          // Local command output arrives under the "user" role — it is a
          // PROGRAM's answer to a human action, not the human's words. Measured
          // on the bench 2026-08-21: <local-command-stdout> blocks settled into
          // the single provenance the judge gives sanction weight to, and after
          // pinning they settled FOREVER. Invoking the command itself is a human
          // action but not an instruction to the judge, so it gets its own
          // label.
          '?"tool-output":__M?.isCompactSummary?"compaction-summary":' +
          '(__bt.includes("<local-command-stdout")||' +
            '__bt.includes("<local-command-stderr"))?"tool-output":' +
          // <command-args> carries the human's OWN words ("keep lane-16
          // going, no agents, no scripts"), not the command name. Measured on
          // the bench 2026-08-21 over the project's transcripts: 24 non-empty
          // blocks, all directives. So an entry with non-empty arguments is
          // human speech with full sanction rights; a bare invocation like
          // /model is a human action but not an instruction to the judge.
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
      // enforce/fail_closed are computed BEFORE the consultation: the
      // obligation to reach a decision must also be known on the failure path,
      // where neither the verdict nor __cfg can be read anymore.
      // An unparsed config = enforce and fail_closed UNKNOWN. Treating them as
      // off would mean one broken file switches the gate off, so here they
      // count as on: a false cancellation is cheaper than a silent pass.
      'let __en=__o.sw==="enforce"||__cfg.enforce===!0||__cfgbad;' +
      'let __fcl=__cfgbad||__cfg.fail_closed===!0;' +
      'if(__ask){__jarm=!!__o.arm&&__en&&__fcl;' +
      // The transcript is handed over as a JSON ARRAY, not as labelled lines.
      // A text prefix cannot carry trust: content and label share one
      // namespace, so any line inside a tool output, a file, a web page or a
      // peer's letter that begins with "user: " is indistinguishable from the
      // real label (demonstrated 2026-08-20 by printing exactly such a line).
      // As a JSON value the same text is escaped into `text` and can never
      // become a sibling `src` key. Trimming drops whole oldest entries —
      // slicing the serialised string would hand over broken JSON.
      // Trimming the transcript. Requirements, each paid for by an incident:
      // (1) the carriers of human directives — the human's own turns and the
      //     compaction summary — are cut, never dropped whole: a dropped carrier
      //     is a silently lost directive;
      // (2) the share is counted per CLASS, not per entry (a per-item summary
      //     cap gave 64% of the transcript against the intended 30%, and the
      //     whole work thread got displaced);
      // (3) an unpinned entry whose removal would take the transcript BELOW the
      //     budget is shortened to fit the gap — otherwise the transcript
      //     emptied out and the judge issued an ordinary verdict blind;
      // (4) all thresholds in JSON LENGTH, not text: escaping inflates a control
      //     character sixfold, and text thresholds missed in both directions.
      //     The marker is added last and paid for exactly;
      // (5) the cost is linear. First the SERIALIZATION quadratic went
      //     (stringify of the whole array on every removal), then the
      //     REMOVAL-COUNT quadratic: splicing two arrays and re-searching for
      //     the longest entry on every step gave 5-10 seconds on a 40-60
      //     thousand-entry transcript — and that on EVERY rung of the ladder,
      //     before the request. Hence removal marks instead of cutting out; the
      //     array is compacted once; discarding within a share goes with a
      //     single cursor from the head.
      'let __cut=(__n)=>{' +
        'let __b=Math.max(60,__n),__pb=Math.floor(__b*0.35),__sb=Math.floor(__b*0.3);' +
        'let __d=0,__dp=0;' +
        'let __cs=(__x)=>JSON.stringify(__x).length+1;' +
        'let __a=__arr.slice(),__w=__a.map(__cs),__dd=new Array(__a.length).fill(!1),__tot=2;' +
        // The entry's original text is stored separately: a trimmed entry may
        // be trimmed a SECOND time, and counting the cut from the previous cut
        // would name only the last step in the label.
        'let __ot=new Array(__a.length).fill(null);' +
        'for(let __k=0;__k<__w.length;__k++)__tot+=__w[__k];' +
        'let __pr=(__x)=>__x&&(__x.src==="user"||__x.src==="compaction-summary");' +
        'let __isu=(__x)=>__x&&__x.src==="user";' +
        'let __iss=(__x)=>__x&&__x.src==="compaction-summary";' +
        // The text is cut from BOTH ends: the head carries the directive, the
        // summary tail carries the "all user messages" and "open tasks" sections.
        // The target is set in JSON length; the text limit is fitted to the actual
        // cost, because the escaping ratio differs per content.
        'let __fit=(__i,__tc)=>{if(__w[__i]<=__tc)return 0;' +
          // The second trim works from the ORIGINAL text, not the previous
          // cut: otherwise the label names only what the last step cut
          // (measured: "123 characters cut out" where 4 remained of 200004),
          // and the previous label falls out of the text together with the
          // first trim's trace. Nested labels become impossible as a side
          // effect.
          'let __t=__ot[__i]!==null?__ot[__i]:String(__a[__i].text);' +
          'let __lim=Math.max(8,__tc-60),__nx=null,__c=0;' +
          'for(let __z=0;__z<10;__z++){' +
            'let __h=Math.min(__t.length,Math.floor(__lim*0.55));' +
            'let __tl=Math.max(0,Math.min(__lim-__h-44,__t.length-__h));' +
            '__nx={src:__a[__i].src,text:__sur(__t.slice(0,__h))+" [\\u0432\\u044b\\u0440\\u0435\\u0437\\u0430\\u043d\\u043e "+(__t.length-__h-__tl)+" \\u0437\\u043d\\u0430\\u043a\\u043e\\u0432] "+(__tl?__sur(__t.slice(-__tl)):"")};' +
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
        // The trimmed are counted as many as REMAIN in the transcript:
        // counting __fit calls overcounted (one entry is cut twice, and a
        // trimmed one may later be displaced) — 39 against 4 live on a real
        // transcript.
        'let __ctd=()=>{let __r=0;for(let __k=0;__k<__a.length;__k++)'+
          'if(__al(__k)&&__ot[__k]!==null)__r++;return __r};' +
        // Within a class share the LONGEST entry is shortened first (it
        // converges in a few steps), and the remainder is filled by discarding
        // from the head with a single cursor: size is not a sign of importance,
        // but re-searching for the longest on every removal is N² on a marathon
        // transcript.
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
        // The last line of defense: nothing unpinned is left. The longest
        // entry is cut; the head is discarded only when there is nothing left
        // to cut.
        'for(let __g=0;__g<20000&&__tot>__b;__g++){' +
          'let __i=__long(()=>!0);if(__i<0)break;' +
          'if(__w[__i]>120&&__fit(__i,Math.max(60,__w[__i]-(__tot-__b))))continue;' +
          'let __h2=__head();if(__h2<0||__cnt(()=>!0)<=1)break;__del(__h2,__pr(__a[__h2]))}' +
        '__a=__a.filter((__x,__k)=>__al(__k));__w=__a.map(__cs);' +
        '__ot=__ot.filter((__x,__k)=>__al(__k));' +
        '__dd=new Array(__a.length).fill(!1);' +
        // The marker must also name what was LOST among the pinned: a count of
        // survivors alone looks healthy exactly when a directive has gone. It
        // is added last and paid for by shrinking the transcript by its own
        // cost; on a tiny budget it degrades to the short form, otherwise it
        // does not fit itself.
        'if(__d>0||__ctd()>0){' +
          'let __cd=0;let __mt=()=>"[\\u043b\\u0435\\u043d\\u0442\\u0430 \\u043f\\u043e\\u0434\\u0440\\u0435\\u0437\\u0430\\u043d\\u0430: \\u0432\\u044b\\u0442\\u0435\\u0441\\u043d\\u0435\\u043d\\u043e "+__d+" \\u0437\\u0430\\u043f\\u0438\\u0441\\u0435\\u0439; \\u0437\\u0430\\u043a\\u0440\\u0435\\u043f\\u043b\\u0435\\u043d\\u043e \\u0440\\u0435\\u043f\\u043b\\u0438\\u043a \\u0447\\u0435\\u043b\\u043e\\u0432\\u0435\\u043a\\u0430: "+__cnt(__isu)+", \\u0440\\u0435\\u0437\\u044e\\u043c\\u0435 \\u043a\\u043e\\u043c\\u043f\\u0430\\u043a\\u0446\\u0438\\u0438: "+__cnt(__iss)' +
            '+(__dp?"; \\u0412\\u042b\\u0422\\u0415\\u0421\\u041d\\u0415\\u041d\\u041e \\u0417\\u0410\\u041a\\u0420\\u0415\\u041f\\u041b\\u0401\\u041d\\u041d\\u042b\\u0425: "+__dp:"")+((__cd=__ctd())?"; \\u043f\\u043e\\u0434\\u0440\\u0435\\u0437\\u0430\\u043d\\u043e \\u043f\\u043e \\u0442\\u0435\\u043a\\u0441\\u0442\\u0443: "+__cd:"")+"]";' +
          'let __sm=()=>"[\\u043f\\u043e\\u0434\\u0440\\u0435\\u0437\\u0430\\u043d\\u043e "+__d+"]";' +
          // __b, not __n: every loop above trims towards __b = max(60, __n), and
          // the marker phase chased __n. With context_chars set below 60 the
          // two disagree, the phase pursues a target the rest of the function
          // will never reach, and it exits on its break conditions instead of
          // on the budget -- so "paid for by shrinking the transcript by its own
          // cost" stops being true exactly where the budget is tightest.
          'if(__cs({src:"injected",text:__mt()})*4>__b)__mt=__sm;' +
          'let __mc=__cs({src:"injected",text:__mt()})+120;' +
          'for(let __g=0;__g<20000&&__tot+__mc>__b&&__a.length>0;__g++){' +
            'let __i=__long(()=>!0);if(__i<0)break;' +
            'if(__w[__i]>120&&__fit(__i,Math.max(60,__w[__i]-(__tot+__mc-__b))))continue;' +
            'let __h4=__head();' +
            'if(__cnt(()=>!0)<=1&&(__h4<0||!__fit(__h4,Math.max(24,__b-__mc-4))))break;' +
            'let __h3=__head();if(__h3<0||__cnt(()=>!0)<=1)break;__del(__h3,__pr(__a[__h3]))}' +
          '__a=__a.filter((__x,__k)=>__al(__k));' +
          '__w=__a.map(__cs);__ot=__ot.filter((__x,__k)=>__al(__k));' +
          '__dd=new Array(__a.length).fill(!1);' +
          '__a.unshift({src:"injected",text:__mt()})}' +
        'return JSON.stringify(__a)};' +
      'let __max=__num("context_chars",__cfg.context_chars,60000,0);' +
      'let __ctx=__cut(__max);' +
      // Dispatch trimming is declared by the same convention as transcript
      // trimming. The dispatch is the one object whose completeness the judge
      // actually judges, and a mute cut mid-word must be read by it as an
      // unfinished brief.
      //
      // Counted in the judge's own records: with the cap at 4000, 34 of the 163
      // dispatches on 2026-08-23 were cut (63 of 709 overall), and record
      // 2026-08-23T18-52-35-972Z-bSujKvKU is one of them -- a sound call
      // cancelled with "бриф -- последний пункт раздела «Rules of this
      // dispatch» оборван на середине слова". That BLOCK is what this
      // declaration exists for.
      //
      // Untested in the field since: the cap is 16000 now and the largest
      // dispatch on record is 7447 characters, so nothing has been cut since it
      // was raised. The bench is the only thing exercising this path.
      'let __dsrc=String(__o.payload!==void 0?(typeof __o.payload==="function"?' +
        'await __o.payload():__o.payload):JSON.stringify(__o.input));' +
      'let __dmax=__num("dispatch_chars",__cfg.dispatch_chars,16000,0);' +
      'let __dtr=__dsrc.length>__dmax;' +
      // Through the seam repair, like every other cut of text a model reads.
      // Without it the brief the judge decides on could end in half a
      // surrogate pair -- a replacement character standing where an emoji
      // was, or a parse error, depending on whose JSON reads it next.
      'let __disp=__dtr?__sur(__dsrc.slice(0,__dmax)):__dsrc;' +
      // The declaration sits in the block's HEADER, not its tail: the tail is
      // the caller's text, and a brief ending in such a line would declare
      // itself truncated BY US and beg for leniency the judge is bound by its
      // prompt to give. The same provenance forgery the src field protects the
      // transcript from. We write the header, and it is printed BEFORE the
      // payload.
      'let __lbl=String(__o.label||"DISPATCH")+(__dtr?" — подрезан: показано "' +
        '+__dmax+" из "+__dsrc.length+" знаков":"");' +
      'let __emb=(__s)=>JSON.stringify(String(__s)).slice(1,-1);' +
      'let __sys=__o.promptEnv;' +
      'if(!__sys&&__pdir)__sys=await __rdj(__pdir+"/prompt.md");' +
      'if(!__sys)__sys=await __rdj(__jdir+"/prompt.md");' +
      // The project's appendix is read by the same reader: its silent
      // disappearance is exactly the same case as the silent disappearance of
      // the project config.
      'if(__pdir){let __ex=await __rdj(__pdir+"/prompt.extra.md");' +
        'if(__ex&&__ex.trim())__sys=(__sys||"")+"\\n\\n=== \\u041f\\u0420\\u0410\\u0412\\u0418\\u041b\\u0410 ' +
          '\\u042d\\u0422\\u041e\\u0413\\u041e \\u041f\\u0420\\u041e\\u0415\\u041a\\u0422\\u0410 ===\\n"+__ex}' +
      // The fallback prompt must be able to CANCEL: the old one had no word
      // BLOCK at all, and the only non-OK outcome it offered (SWAP) was
      // recorded as ok and let the call through. The gate was formally alive
      // and substantively off, and the journal was full of "ok".
      // The label names the path, like all the others: on a fresh install this
      // is the ONLY refusal the human will see, and from a "prompt-missing"
      // without a path it does not follow that ~/.claude/probes/judge/prompt.md is
      // what needs creating.
      // The fallback prompt belongs to the caller, for the same reason `rx` and
      // `act` do: the core does not know what a verdict sounds like. It used to
      // hold the judge's own text -- OK/WARN/BLOCK -- and hand it to BOTH probes.
      // The watcher's parser accepts only SILENT|NUDGE, so on any machine without
      // ~/.claude/probes/idle-watch/prompt.md every watcher consultation ran the
      // whole ladder, was paid for, and could not produce a verdict by
      // construction: the model answered "OK", the parser refused it, the journal
      // recorded `empty`, and the next cooldown did it again. Silence that costs
      // money and reads as health.
      'if(!__sys){let __pmm="prompt-missing:"+__jdir+"/prompt.md"+' +
        '(__pdir?" | "+__pdir+"/prompt.md":"");' +
        '__deg.push(__pmm);__degb.push(__pmm);' +
        '__sys=__o.fb}' +
      // Половина свода правил читается как целый свод: обрыв на середине
      // оставляет законный текст, и ни один разбор его не отвергнет. Признак
      // целостности вносится в сам файл -- последняя строка-хвост, которую
      // копирование обязано донести. Нет хвоста -- промт усечён (или это
      // чужой файл), правила применяются частично, и это объявляется.
      // В __degb, а не только в __deg: неполный свод правил -- это дефект
      // САМОГО СУЖДЕНИЯ, а такие отменяют вызов при enforce+fail_closed.
      'else if(__sys!==__o.fb&&__sys.indexOf("<!-- END OF RULES -->")<0){' +
        'let __ptr="prompt-truncated:"+(__pdir?__pdir:__jdir)+"/prompt.md";' +
        '__deg.push(__ptr);__degb.push(__ptr)}' +
      // A chain, not a single model: the judge shares its channel with the very
      // fleet it judges, so when the fleet is busy the judge is the one that
      // times out — and a silent fail-open is indistinguishable from blanket
      // approval. The next model gets the same question instead.
      // A ladder of attempts, not a list of names: each rung may carry its own
      // deadline, budget and transcript size, because the reasons a rung fails
      // differ — a congested provider needs a longer deadline, a reasoning
      // model a larger budget, an oversized transcript a shorter tail. A bare
      // string stays valid shorthand for {model:<name>}.
      'let __mdls=(__o.modelEnv?[__o.modelEnv]:' +
        '(Array.isArray(__cfg.models)&&__cfg.models.length?__cfg.models:[__cfg.model||"glm-5.3"]))' +
        '.map((__x)=>typeof __x==="string"?{model:__x}:__x).filter((__x)=>__x&&__x.model);' +
      'if(!__mdls.length)__mdls=[{model:"glm-5.3"}];' +
      // ONE answer to "what output budget when nothing says otherwise". There
      // were three: 300 in the raw-HTTP fallback body, 1200 twice on the pool
      // path. All three are below what this judge was MEASURED to spend -- a
      // reasoning model at `high` spends 434-2120 tokens on a verdict, and 1200
      // is the number that once truncated a cancellation into silence (see
      // docs/judge-architecture.md). 8000 is the ceiling that measurement
      // argued for; the shipped probes.toml asks for more, and a template
      // carries its own. This is only the floor under a machine that has said
      // nothing at all -- and on such a machine the judge must still be able to
      // finish a sentence.
      'let __mtd=8000;' +
      'let __tplr=null;' +
      'if(__pdir)__tplr=await __rdj(__pdir+"/body.json");' +
      'if(!__tplr)__tplr=await __rdj(__jdir+"/body.json");' +
      // A broken body template does not change the outcome (the built-in body
      // works), but whoever dropped in their own template must learn that it
      // was not applied.
      'if(__tplr){try{JSON.parse(__tplr.replace(/\\{\\{[A-Z]+\\}\\}/g,"x"))}' +
        'catch(__be){__deg.push("unparsed-body:"+__clip(__be?.message??__be,60));__tplr=null}}' +
      // Разбор -- не единственное, что обязан выдержать развёрнутый шаблон.
      // Тот же инвариант, что гейт канона проверяет в дереве, проверяется и
      // здесь, на файле, который РЕАЛЬНО пошёл в дело: подстановки нет --
      // шаблон не применяется (встроенная рамка работает) и это названо.
      'if(__tplr){let __miss=["{{LABEL}}","{{CONTEXT}}","{{DISPATCH}}"]' +
        '.filter((__ph)=>__tplr.indexOf(__ph)<0);' +
        'if(__miss.length){__deg.push("body-no-placeholder:"+__miss.join(","));__tplr=null}}' +
      'let __mkb=(__cx,__e)=>{let __mdl=__e.model;try{if(!__tplr)throw new Error("no template");' +
        'let __tpl=__tplr.replace(/\\{\\{PROMPT\\}\\}/g,__emb(__sys)).replace(/\\{\\{MODEL\\}\\}/g,__emb(__mdl))' +
          '.replace(/\\{\\{CONTEXT\\}\\}/g,__emb(__cx)).replace(/\\{\\{DISPATCH\\}\\}/g,__emb(__disp))' +
          // {{LABEL}} is not decoration: the header is where the truncation
          // notice lives, and __lbl is the only thing carrying it. A template
          // without this substitution silently dropped BOTH the probe's own
          // name (the watcher signs itself FLEET, not DISPATCH) and the
          // "trimmed: showing N of M" notice — so on the template path a
          // trimmed payload reached the model looking whole. The built-in
          // frames below always interpolated __lbl; only the template path
          // lost it, and the bench never covered that path, which is why it
          // survived. Frame text here and in both built-ins must stay
          // byte-identical.
          '.replace(/\\{\\{LABEL\\}\\}/g,__emb(__lbl));' +
        // One home per setting. The template carries its own model and budget,
        // so without this override `models` and `max_tokens` from config.json
        // are silent no-ops — measured twice: first with the model, then with
        // a 1200-token ceiling that truncated a cancel verdict into silence.
        'let __obj=JSON.parse(__tpl);__obj.model=__mdl;' +
        'let __mt=__e.max_tokens||__cfg.max_tokens;' +
        'if(__mt)__obj.max_tokens=__num("max_tokens",__mt,__obj.max_tokens??__mtd,1);' +
        'if(__e.effort)__obj.reasoning_effort=__e.effort;' +
        'return JSON.stringify(__obj)}catch{' +
        'return JSON.stringify({model:__mdl,' +
          'max_tokens:__num("max_tokens",__e.max_tokens||__cfg.max_tokens,__mtd,1),' +
          'messages:[{role:"system",content:__sys},' +
          '{role:"user",content:"=== SESSION SO FAR ===\\n"+__cx+"\\n\\n=== "+__lbl+" ===\\n"+__disp}]})}};' +
      'let __pool=typeof ' + QM + '==="function"?' + QM + ':null;' +
      'let __purl=(()=>{let __u=__o.urlEnv||__cfg.url||process.env.ANTHROPIC_BASE_URL||"http://127.0.0.1:8317";__u=String(__u).replace(/\\/+$/,"");return /\\/v1$/.test(__u)?__u+"/chat/completions":__u+"/v1/chat/completions"})();' +
      // The pool is the default path. Raw HTTP remains ONLY as an explicitly
      // named address (the bench probe hits its own receiver) or as a fallback
      // if no pool binding was found in this build: a judge that lost its
      // channel must degrade, not go silent.
      'let __http=!!(__o.urlEnv||__cfg.url||__cfg.raw_http===!0)||!__pool;' +
      '__jurl=__http?__purl:"pool";' +
      'let __tmo=__num("timeout_ms",__o.tmoEnv||__cfg.timeout_ms,8000,1);' +
      'let __call=async(__cx,__ms,__e)=>{' +
        'let __s0=globalThis.__ccMono(),__a={model:__e.model,via:__http?"http":"pool",ctx_chars:__cx.length,' +
          'timeout_ms:__ms,' +
          'max_tokens:__num("max_tokens",__e.max_tokens||__cfg.max_tokens,null,1,!0),' +
          'effort:__e.effort||null};__jatt.push(__a);' +
        'let __ac=new AbortController(),__mine=!1,' +
        '__to=setTimeout(()=>{__mine=!0;__ac.abort()},__ms);' +
        // The response and status are cleared at the START of the attempt: the
        // request was written by every attempt but the response only by a
        // successful one, and the record silently glued the last attempt's
        // request to an early one's response.
        '__jres=null;__jst=null;' +
        'try{' +
          'if(__http){let __b=__mkb(__cx,__e);__jreq=__b;' +
            'if(__o.dbg)try{await __fs.writeFile(' +
              '__jdir+"/last-request."+process.pid+"."+__seq+".json",__b)}catch{}' +
            'let __r=await fetch(__purl,{method:"POST",signal:__ac.signal,' +
              'headers:{"content-type":"application/json"},body:__b});' +
            'let __t=await __r.text();__jst=__r.status;__jres=__t;__a.resp=__clip(__t,800);' +
            // Recorded, never gated on. The gateway answers with an id that is
            // NOT the one asked for as a matter of routine (a build suffix, a
            // family alias), and refusing those would refuse the whole proxy
            // lane. But when a ladder rung is answered by something other than
            // the model it addressed, that has to be legible afterwards: the
            // attempt named only what it REQUESTED, so a verdict from an
            // unexpected model was indistinguishable from one from the right
            // one.
            'try{let __sv=JSON.parse(String(__t).replace(/^\\uFEFF/,""))?.model;' +
              'if(__sv&&__sv!==__e.model)__a.served=__clip(__sv,80)}catch{}' +
            '__a.ms=globalThis.__ccMono()-__s0;__a.http=__r.status;' +
            'if(!__r.ok)throw new Error("HTTP "+__r.status);return __t}' +
          // Effort rides in the options field, not the body: the body here is
          // not ours, the client assembles it. The output limit is
          // maxOutputTokensOverride, also the single budget home on this path.
          'let __ut="=== SESSION SO FAR ===\\n"+__cx+"\\n\\n=== "+__lbl+" ===\\n"+__disp;' +
          '__jreq=JSON.stringify({via:"pool",model:__e.model,effort:__e.effort||null,' +
            'max_tokens:__num("max_tokens",__e.max_tokens||__cfg.max_tokens,__mtd,1),' +
            'messages:[{role:"system",content:__sys},{role:"user",content:__ut}]});' +
          'let __r2=await __pool({messages:[{type:"user",message:{role:"user",content:__ut},' +
              'uuid:(globalThis.crypto?.randomUUID?.()||String(Date.now())),' +
              'timestamp:new Date().toISOString()}],' +
            'systemPrompt:[__sys],thinkingConfig:{type:"disabled"},tools:[],signal:__ac.signal,' +
            'options:{model:__e.model,isNonInteractiveSession:!0,hasAppendSystemPrompt:!1,' +
              'agents:[],mcpTools:[],querySource:"hook_prompt",toolChoice:void 0,' +
              'maxOutputTokensOverride:__num("max_tokens",__e.max_tokens||__cfg.max_tokens,__mtd,1),' +
              'effortValue:__e.effort||void 0,agentId:__o.ctx?.agentId,agentContext:__o.ctx?.agentContext,' +
              'getToolPermissionContext:async()=>__o.ctx?.getAppState?.()?.toolPermissionContext}});' +
          'let __t2=JSON.stringify(__r2);__jres=__t2;__a.resp=__clip(__t2,800);' +
          'let __sv2=__r2?.message?.model;' +
          'if(__sv2&&__sv2!==__e.model)__a.served=__clip(__sv2,80);' +
          '__a.ms=globalThis.__ccMono()-__s0;' +
          '__jst=__r2?.isApiErrorMessage?"api_error":200;__a.http=__jst;' +
          // The pool's error text MUST reach the journal: without it the ledger
          // hangs on "api error from the pool" with no cause, and the cause (a
          // rate limit, an upstream refusal, an unknown model) calls for
          // different treatment. Real case: three refusals in a row on one rung,
          // and there was nothing to analyze them with.
          'if(__r2?.isApiErrorMessage){let __et="";' +
            'try{__et=(__r2.message?.content||[]).filter((__b)=>__b?.type==="text")' +
              '.map((__b)=>__b.text).join(" ")}catch{}' +
            'throw new Error("api error from the pool: "+(__clip(__et,300)||"(\u0431\u0435\u0437 \u0442\u0435\u043a\u0441\u0442\u0430)"))}' +
          'return __t2}' +
        'catch(__xe){__a.ms=globalThis.__ccMono()-__s0;__a.timed_out=__mine||void 0;' +
          // Our own cap and a foreign failure arrive as one line, "Request was
          // aborted". Measured 2026-08-23: a rung spent three days dying on ITS
          // OWN timeout while the journal read it as model flakiness. The cause
          // must be named on the spot: the treatment differs (the cap is
          // adjustable, the upstream is not).
          // Our own OUTPUT cap arrives in the pool's text ("api error from the
          // pool"), the way our own timeout used to arrive as the words
          // "Request was aborted": in the journal both read as a provider
          // failure while the cure is a setting. The cause is named on the spot
          // — the treatment differs.
          // The message is cut by a DECLARING clip: a bare slice(0,120) chopped
          // off the phrase "To configure this behavior…", that is, exactly the
          // part naming the tool (measured 2026-08-24).
          'let __em=String(__xe?.message??__xe);' +
          'let __ob=/exceeded the (\\d+) output token/.exec(__em);' +
          '__a.budget=__ob?Number(__ob[1]):void 0;' +
          '__a.error=(__mine?"our cap "+__ms+"ms fired -> ":' +
            '(__ob?"our output budget "+__ob[1]+" exhausted -> ":""))' +
            '+String(__xe?.name||"Error")+": "+__clip(__em,200);throw __xe}' +
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
      // Two reply shapes because there are two channels: the proxy gives
      // choices[].message, the pool an AssistantMessage with an array of blocks.
      // One parser, so the "verdict on the first line" rule does not diverge
      // between channels.
      // A BOM is invisible and JSON.parse rejects it -- the same fact the
      // settings reader was taught two waves ago, and the channel body was
      // never told. A gateway that prefixes one turns a spoken verdict into
      // "the channel said nothing", which under fail_closed is a cancellation.
      'let __pv=(__r0)=>{let __j;' +
        'try{__j=JSON.parse(String(__r0).replace(/^\\uFEFF/,""))}catch{__j=null}' +
        'let __mm=__j?.choices?.[0]?.message||{};' +
        // Case-insensitive, and the ACT regex below with it. The vocabulary is
        // a set of WORDS, not a set of glyph sequences: a model answering
        // "ok: fine" is answering in the vocabulary. Matching case-sensitively
        // filed that under "no verdict", and "no verdict" under fail_closed is
        // a CANCELLATION -- so a lower-case approval cancelled the call it
        // approved, and in advise a lower-case refusal passed in silence.
        // Both regexes must carry the flag or the pair splits: the outcome word
        // would be recorded from one and the action taken from the other.
        'let __rx=new RegExp("^\\\\s*(?:"+__o.rx+"):.*$","gmi");' +
        'let __bl=Array.isArray(__j?.message?.content)?__j.message.content:' +
          '(Array.isArray(__j?.content)?__j.content:null);' +
        // `content` in the OpenAI slot may be a STRING or an array of parts.
        // String() on the array yielded "[object Object]" -- truthy, so the
        // block reader below was never reached, and a perfectly good verdict
        // became an empty one. Our own judge/channel.py has read that shape
        // since it was written; the injected parser had not.
        'let __ct=Array.isArray(__mm.content)?__mm.content.filter((__b)=>' +
          '__b?.type==="text"||typeof __b?.text==="string").map((__b)=>__b.text).join("\\n")' +
          ':String(__mm.content??"");' +
        'if(!__ct&&__bl)__ct=__bl.filter((__b)=>__b?.type==="text")' +
          '.map((__b)=>__b.text).join("\\n");' +
        // An answer cut at the output ceiling still carries its verdict -- the
        // verdict is demanded FIRST, and it is the reason that loses its tail.
        // Throwing the whole thing away would turn a real BLOCK into "no
        // verdict", i.e. into the very cancellation-without-a-reason this
        // mechanism exists to avoid. So the decision stands and the cut is
        // DECLARED, the same way every other truncation in this code is: the
        // notice rides the reason text that reaches the main loop.
        // Полоса pool отдаёт AssistantMessage: её `stop_reason` лежит ВНУТРИ
        // `.message` -- ровно там, откуда этот же разбор берёт содержимое
        // (`__j?.message?.content`). Верхнеуровневая форма для неё не
        // существует, и обрыв на потолке уходил в вердикт без объявления --
        // в полосе по умолчанию (круг 20, D-2).
        'let __cut1=__j?.choices?.[0]?.finish_reason==="length"' +
          '||__j?.stop_reason==="max_tokens"' +
          '||__j?.message?.stop_reason==="max_tokens"?' +
          '" [\\u043e\\u0442\\u0432\\u0435\\u0442 \\u043e\\u0431\\u043e\\u0440\\u0432\\u0430\\u043d ' +
          '\\u043d\\u0430 \\u043f\\u043e\\u0442\\u043e\\u043b\\u043a\\u0435 ' +
          '\\u0432\\u044b\\u0432\\u043e\\u0434\\u0430]":"";' +
        'let __c1=(__ct.match(__rx)||[])[0];if(__c1)return __c1.trim()+__cut1;' +
        'let __rr=[__mm.reasoning,__mm.reasoning_content,__bl?__bl.filter((__b)=>' +
          '__b?.type==="thinking").map((__b)=>__b.thinking).join("\\n"):""]' +
          '.filter(Boolean).join("\\n");' +
        // A reply without a verdict line is NOT a verdict. Raw model text used
        // to fall through here, and any answer outside the vocabulary (SWAP:
        // from the old fallback prompt, for example) was recorded as ok and let
        // the call through.
        'let __cv=((String(__rr).match(__rx)||[]).pop()||"").trim();' +
        'return __cv?__cv+__cut1:""};' +
        // Broken settings or a broken prompt is not "fall back to defaults"
        // but "I do not know what rules to judge by". Under enforce such a call
        // is cancelled with the file named, not silently passed.
        'if(__degb.length&&__en){' +
          // A probe that does not cancel the call blocked nothing either —
          // writing "block_degraded" for it would name both a cancellation and
          // a silence with one word.
          'try{await __jlog({outcome:__o.arm?"block_degraded":"skip_degraded",' +
            'tries:__jtry,jm:null,deg:__dcut(__deg,5)})}catch{}' +
          'await __o.onBroken(__dcut(__degb,3).join("; "),__svc);' +
          // The judge does not return from here — its onBroken throws. A probe
          // that returns does not know which rules to judge by, and asking
          // anyway would be paying for an answer we already know is worthless.
          // (The fallback prompt itself is no longer the reason: it now speaks
          // each probe's own vocabulary. It used to speak only the judge's, so
          // for the watcher this branch was the ONLY thing standing between a
          // missing prompt and an endless series of paid, unparsable
          // consultations — and it stands only while enforce is on.)
          'return}' +
      'let __raw=null,__v="",__errs=[];' +
      'for(let __i=0;__i<__mdls.length;__i++){let __e=__mdls[__i];' +
        'try{__jtry=__i+1;__jm=__e.model;' +
          '__raw=await __call(__e.context_chars?' +
            '__cut(__num("rung.context_chars",__e.context_chars,__max,0)):__ctx,' +
            '__num("rung.timeout_ms",__e.timeout_ms,__tmo,1),__e);' +
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
      // The budget is asked for ONCE: it used to be computed twice in the same
      // statement, once to decide whether to retry and once to size the tail,
      // so a config read that answered differently between the two calls would
      // have retried with a size nobody chose.
      'let __rcc=__num("retry_context_chars",__cfg.retry_context_chars,8000,0);' +
      'if(!__v&&__rcc>0){' +
        'let __e=__mdls[__mdls.length-1];' +
        '__jtry=__mdls.length+1;__jm=__e.model;__jerr1=__errs.join(" | ")||null;' +
        // The retry is wrapped the same way as a rung: unwrapped, its failure
        // went to the outer catch, which wrote "skip" and did NOT cancel the
        // call — a silent pass exactly where fail_closed exists to prevent one.
        // Half the deadline, as this block has claimed since it was written. The
        // code passed the FULL rung timeout, which with the shipped 240 s and
        // three rungs made the worst case four full rungs of blocking wait --
        // and a retry that can cost as much as the thing it is rescuing is not
        // a cheap salvage, it is a fourth attempt. The tail it sends is short
        // by construction, so the shorter clock matches the work.
        // Bound above by the rung, not only below by a second: with a rung under
        // two seconds the bare floor made the salvage cost MORE than the attempt
        // it salvages. Read once into __rt -- twice in one statement is the
        // defect named four lines up for __rcc.
        'let __rt=__num("rung.timeout_ms",__e.timeout_ms,__tmo,1);' +
        'try{__raw=await __call(__cut(__rcc),' +
          'Math.min(__rt,Math.max(1000,Math.round(__rt/2))),' +
          '__e);__v=__pv(__raw);' +
          'if(!__v)__errs.push(__jm+": empty verdict")}' +
        'catch(__ce){__raw=null;__errs.push(__jm+": "+String(__ce?.name||"Error")+": "+' +
          '__clip(__ce?.message??__ce,80))}}' +
      '__jerr1=__errs.join(" | ")||null;' +
      'if(__o.dbg){console.error(__o.tag+" "+__clip(__v,300));' +
        'try{await __fs.writeFile(' +
          '__jdir+"/last-verdict."+process.pid+"."+__seq+".txt",__v)}catch{}}' +
      // The judge does not rewrite the dispatch — it CANCELS it and says why.
      // Rewriting would produce a model/effort pair that nothing validates:
      // the deterministic gate runs earlier in this same function, so a
      // substitution made here would sail past it. A refusal is strictly more
      // restrictive than what the gate already allowed, so ordering stops
      // mattering. Thrown rather than hand-built: a tool that throws already
      // surfaces to the model as an error tool_result, which is exactly
      // "stop, and here is what is wrong" — and it couples to no minified name.
      // The `i` here is not decoration: it is the other half of the flag on the
      // verdict regex. With only one of the two, a lower-case BLOCK would be
      // RECORDED as a block and not ACTED on -- a silent pass written in the
      // journal as a cancellation, which is worse than either honest outcome.
      'let __bl=new RegExp("^(?:"+__o.act+"):\\\\s*([\\\\s\\\\S]+)$","mi").exec(__v);' +
      // A cancellation from ladder exhaustion is a CHANNEL defect, a
      // cancellation by verdict is a JUDGMENT defect, and they are treated
      // differently. While both were written as "empty" (the same word as a
      // skipped call under fail_closed:false), from the outside they were
      // indistinguishable from each other and from a pass.
      'let __fc=!__v&&__en&&__fcl;' +
      // The journal must not steer control past the decisions below: a write
      // failure with a BLOCK ready would go to the outer catch and become a
      // pass. The outcome word is the very class the model named, not the
      // judge's "block". The core does not know the vocabulary: it comes from
      // the caller in __o.rx, and a "block" hardcoded here would write into the
      // watcher's journal that it cancelled a dispatch — one and the same word
      // as a real judge cancellation, indistinguishable. For the judge's
      // OK/WARN/BLOCK the word comes out as before, character for character.
      'let __ocw=String((/^\\s*([A-Za-z]+):/.exec(__v||"")||[])[1]||"ok").toLowerCase();' +
      'try{await __jlog({http:__jst,outcome:__bl?(__en?__ocw:__ocw+"_not_enforced"):' +
        '(__v?__ocw:(__fc?"block_no_verdict":"empty")),' +
        'en:__en?(__o.sw==="enforce"?"env":"config"):(__cfgseen?"off":"no-config"),' +
        '...(__uw.length?{uw:__dcut(__uw,5)}:{}),' +
        '...(__deg.length?{deg:__dcut(__deg,5)}:{}),' +
        'tries:__jtry,jm:__jm,err1:__jerr1,' +
        'verdict:__clip(__v,400)||null})}catch{}' +
      // The user's principle (2026-08-20): "a false cancellation is better
      // than a silent pass". A failure of the WHOLE ladder is precisely a
      // silent pass: the judge said nothing and the call went through. Under
      // `fail_closed` it is cancelled instead. The trade-off is deliberate: a
      // channel failure stops dispatches, but the subscription rung exists only
      // together with the client itself, so a total failure means the sessions
      // have nothing to work with anyway. Switched off by one config key, no
      // rebuild of the binary.
      'if(__fc)await __o.onNoVerdict(__clip(String(__jerr1||""),200),__svc);' +
      'if(__bl&&__en)await __o.onAct(__bl[1].trim(),__svc);' +
      // The decision has been made — the obligation is released. Released
      // LAST: anything that throws earlier must cancel the call, not pass it.
      '__jarm=!1;' +
    '}}catch(__e){if(__e&&__e.__ccJudgeBlock)throw __e;' +
      'let __rs=String(__e?.name||"Error")+": "+__clip(__e?.message??__e,200);' +
      'try{await __jlog({outcome:__jarm?"block_no_verdict":"skip",tries:__jtry,jm:__jm,' +
        'err1:__jerr1,reason:__rs})}catch{}' +
      // A judge failure with the obligation armed is a cancellation, not a
      // pass: what arrives here is also a crash before the ladder (config,
      // body, trimming), where there is and can be no verdict.
      'if(__jarm)await __o.onFail(__rs,__svc);' +
      'if(__o.dbg)console.error(__o.tag+" skipped: "+(__e?.message??__e));}};' +
    // The core is emitted at BOTH sites and is byte-identical at both -- it
    // has to be, because neither site is guaranteed to run before the other:
    // `claude mcp serve` never reaches the main dispatcher, and the main loop
    // reaches the tool only when a dispatch actually happens. `??=` makes the
    // second copy inert at runtime; these markers let the verify stage collapse
    // it in the TEXT, so every check that counts occurrences keeps counting one
    // core and means what it meant when it was calibrated.
    '/*__ccCore1*/';

  // The judge is the core's first consumer. What is judge-specific lives HERE
  // and only here: when to call, what to show, which vocabulary to judge by,
  // and what to answer a verdict with. The refusal texts were carried over
  // VERBATIM: they reach the model as a tool error, and editing their wording
  // changes what the model will read — that is a separate decision, not a side
  // effect of the split into a core.
  //
  // The judge's reaction is a throw. It is tied to no minified name: a tool
  // that throws an exception already comes back to the model as an error.
  const judgeCall =
    // The judge deliberately runs at the TOP of the method, ahead of the tool's
    // own guards (nesting depth, teammate and agent-type checks, budgets) --
    // the same position it held when it sat in front of the dispatcher's call.
    // Nothing above it in the body does anything but destructure, so a
    // cancellation leaves nothing half-done.
    'if(process.env.CLAUDE_JUDGE&&($2.name==="Agent"||$2.name==="Task")' +
      '&&$4?.agentContext?.agentType==="main")' +
    'await globalThis.__ccProbe({' +
      'tag:"[Judge]",dirName:"judge",arm:!0,' +
      // Read AND remove, in one place: step 21 fills this map for every tool
      // call, and its comment states the contract -- an entry goes away when
      // the judge reads it. Taken above the gate so a call the gate filters out
      // does not leave an entry behind forever.
      'turn:()=>{let __x=globalThis.__ccJudgeTurn?.get($5);' +
        'globalThis.__ccJudgeTurn?.delete($5);return __x||[]},' +
      'turnLost:()=>globalThis.__ccJudgeTurnLost?.has($5)||!1,' +
      // The verdict vocabulary is a parameter, not a property of the core: the
      // watcher has its own.
      'rx:"OK|BLOCK|STOP|DENY|WARN",act:"BLOCK|STOP|DENY",' +
      // Fallback text beside the vocabulary it has to speak.
      'fb:"You judge one about-to-run subagent dispatch. You do NOT rewrite it: "+' +
        '"you either let it run or CANCEL it and say why. Answer with ONE line, "+' +
        '"the verdict FIRST: OK:<why> or WARN:<why> or BLOCK:<what is wrong and "+' +
        '"what to do instead>. BLOCK cancels the dispatch. Your own prompt file "+' +
        '"is missing, so judge on the general rule: a dispatch must name its "+' +
        '"model and class, the class must match what the brief actually does, "+' +
        '"and an expensive model on closed mechanical work is a reason to BLOCK.",' +
      'sw:process.env.CLAUDE_JUDGE,dirEnv:process.env.CLAUDE_PROBES_DIR,' +
      'promptEnv:process.env.CLAUDE_JUDGE_PROMPT,modelEnv:process.env.CLAUDE_JUDGE_MODEL,' +
      'urlEnv:process.env.CLAUDE_JUDGE_URL,tmoEnv:process.env.CLAUDE_JUDGE_TIMEOUT_MS,' +
      'dbg:process.env.CLAUDE_JUDGE_DEBUG,' +
      'tool:$2,input:$3,ctx:$4,key:$5,' +
      'onAct:(__r)=>{let __e=new Error("\\u0412\\u044b\\u0437\\u043e\\u0432 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043e\\u0442\\u043c\\u0435\\u043d\\u0451\\u043d \\u0441\\u0443\\u0434\\u044c\\u0451\\u0439 \\u0432\\u044b\\u0437\\u043e\\u0432\\u043e\\u0432 (\\u044d\\u0442\\u043e \\u041d\\u0415 \\u0433\\u0435\\u0439\\u0442 \\u043c\\u0430\\u0440\\u0448\\u0440\\u0443\\u0442\\u0438\\u0437\\u0430\\u0446\\u0438\\u0438 hooks/routing-table.toml). \\u041f\\u0440\\u0438\\u0447\\u0438\\u043d\\u0430: "+__r);__e.__ccJudgeBlock=!0;throw __e},' +
      'onNoVerdict:(__r)=>{let __e=new Error("\\u0412\\u044b\\u0437\\u043e\\u0432 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043e\\u0442\\u043c\\u0435\\u043d\\u0451\\u043d: \\u0441\\u0443\\u0434\\u044c\\u044f \\u043d\\u0435 \\u043f\\u043e\\u043b\\u0443\\u0447\\u0438\\u043b \\u0432\\u0435\\u0440\\u0434\\u0438\\u043a\\u0442 \\u043d\\u0438 \\u043d\\u0430 \\u043e\\u0434\\u043d\\u043e\\u0439 \\u0441\\u0442\\u0443\\u043f\\u0435\\u043d\\u0438 (' + '"+__r+"' + '). \\u042d\\u0442\\u043e \\u041d\\u0415 \\u0433\\u0435\\u0439\\u0442 \\u043c\\u0430\\u0440\\u0448\\u0440\\u0443\\u0442\\u0438\\u0437\\u0430\\u0446\\u0438\\u0438. \\u0421\\u043a\\u0430\\u0436\\u0438 \\u043e\\u0431 \\u044d\\u0442\\u043e\\u043c \\u0447\\u0435\\u043b\\u043e\\u0432\\u0435\\u043a\\u0443 \\u0438 \\u0441\\u0434\\u0435\\u043b\\u0430\\u0439 \\u0440\\u0430\\u0431\\u043e\\u0442\\u0443 \\u0431\\u0435\\u0437 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043b\\u0438\\u0431\\u043e \\u043f\\u043e\\u0432\\u0442\\u043e\\u0440\\u0438 \\u043f\\u043e\\u0437\\u0436\\u0435, \\u043a\\u043e\\u0433\\u0434\\u0430 \\u043a\\u0430\\u043d\\u0430\\u043b \\u043e\\u0436\\u0438\\u0432\\u0451\\u0442.");__e.__ccJudgeBlock=!0;throw __e},' +
      'onBroken:(__r)=>{let __e=new Error("\\u0412\\u044b\\u0437\\u043e\\u0432 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043e\\u0442\\u043c\\u0435\\u043d\\u0451\\u043d: \\u043d\\u0430\\u0441\\u0442\\u0440\\u043e\\u0439\\u043a\\u0438 \\u0441\\u0443\\u0434\\u044c\\u0438 \\u0441\\u043b\\u043e\\u043c\\u0430\\u043d\\u044b ("+__r+"). \\u042d\\u0442\\u043e \\u041d\\u0415 \\u0433\\u0435\\u0439\\u0442 \\u043c\\u0430\\u0440\\u0448\\u0440\\u0443\\u0442\\u0438\\u0437\\u0430\\u0446\\u0438\\u0438. \\u0421\\u043a\\u0430\\u0436\\u0438 \\u043e\\u0431 \\u044d\\u0442\\u043e\\u043c \\u0447\\u0435\\u043b\\u043e\\u0432\\u0435\\u043a\\u0443: \\u043f\\u043e\\u043a\\u0430 \\u0444\\u0430\\u0439\\u043b \\u043d\\u0435 \\u043f\\u043e\\u0447\\u0438\\u043d\\u0435\\u043d, \\u0441\\u0443\\u0434\\u044c\\u044f \\u043d\\u0435 \\u0437\\u043d\\u0430\\u0435\\u0442, \\u043f\\u043e \\u043a\\u0430\\u043a\\u0438\\u043c \\u043f\\u0440\\u0430\\u0432\\u0438\\u043b\\u0430\\u043c \\u0441\\u0443\\u0434\\u0438\\u0442\\u044c.");__e.__ccJudgeBlock=!0;throw __e},' +
      'onFail:(__r)=>{let __e=new Error("\\u0412\\u044b\\u0437\\u043e\\u0432 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043e\\u0442\\u043c\\u0435\\u043d\\u0451\\u043d: \\u0441\\u0443\\u0434\\u044c\\u044f \\u043d\\u0435 \\u0441\\u043c\\u043e\\u0433 \\u0432\\u044b\\u043d\\u0435\\u0441\\u0442\\u0438 \\u0440\\u0435\\u0448\\u0435\\u043d\\u0438\\u0435 ("+__r+"). \\u042d\\u0442\\u043e \\u041d\\u0415 \\u0433\\u0435\\u0439\\u0442 \\u043c\\u0430\\u0440\\u0448\\u0440\\u0443\\u0442\\u0438\\u0437\\u0430\\u0446\\u0438\\u0438. \\u0421\\u043a\\u0430\\u0436\\u0438 \\u043e\\u0431 \\u044d\\u0442\\u043e\\u043c \\u0447\\u0435\\u043b\\u043e\\u0432\\u0435\\u043a\\u0443 \\u0438 \\u0441\\u0434\\u0435\\u043b\\u0430\\u0439 \\u0440\\u0430\\u0431\\u043e\\u0442\\u0443 \\u0431\\u0435\\u0437 \\u0441\\u0443\\u0431\\u0430\\u0433\\u0435\\u043d\\u0442\\u0430 \\u043b\\u0438\\u0431\\u043e \\u043f\\u043e\\u0432\\u0442\\u043e\\u0440\\u0438 \\u043f\\u043e\\u0437\\u0436\\u0435.");__e.__ccJudgeBlock=!0;throw __e}' +
    '});';



  // The watcher is the second consumer of the same core. There are exactly
  // four differences: when to call, what to show, which prompt to judge by,
  // and how to answer.
  const watchCall =
    // The fleet counter runs on EVERY tool call, not only on a dispatch:
    // without a shared timestamp there is nowhere to take "dispatches within
    // the window" from. The current dispatch is counted BEFORE the count — the
    // thread a subagent was started in is silent by construction, and no
    // separate condition for that is needed.
    'globalThis.__ccFleet??=[];' +
    'if($2.name==="Agent"||$2.name==="Task"){globalThis.__ccFleet.push(globalThis.__ccMono());' +
      'if(globalThis.__ccFleet.length>256)globalThis.__ccFleet=globalThis.__ccFleet.slice(-256)}' +
    'if(process.env.CLAUDE_IDLE&&$4?.agentContext?.agentType==="main")' +
    'await globalThis.__ccProbe({' +
      'tag:"[Watch]",dirName:"idle-watch",arm:!1,label:"FLEET",' +
      // Its own vocabulary: the watcher has nothing to permit or forbid; it
      // either stays silent or names the subject.
      'rx:"SILENT|NUDGE",act:"NUDGE",' +
      // Same vocabulary as `rx` above, in prose: a fallback speaking the judge's
      // words could never be parsed here.
      'fb:"You watch the subagent fleet of one running session. You do NOT "+' +
        '"cancel or rewrite anything: you either stay quiet or name what is "+' +
        '"being missed. Answer with ONE line, the verdict FIRST: "+' +
        '"SILENT:<why nothing is needed> or NUDGE:<what work the fleet should "+' +
        '"be doing right now>. Your own prompt file is missing, so judge on the "+' +
        '"general rule: a main loop working while its fleet sits idle is the "+' +
        '"subject; a loop waiting on work it already dispatched is not.",' +
      'sw:process.env.CLAUDE_IDLE,dirEnv:process.env.CLAUDE_PROBES_DIR,' +
      'promptEnv:process.env.CLAUDE_IDLE_PROMPT,modelEnv:process.env.CLAUDE_IDLE_MODEL,' +
      'urlEnv:process.env.CLAUDE_IDLE_URL,tmoEnv:process.env.CLAUDE_IDLE_TIMEOUT_MS,' +
      'dbg:process.env.CLAUDE_IDLE_DEBUG,' +
      'tool:$2,input:$3,ctx:$4,key:$5,' +
      // The cheap count: window, threshold, cooldown. The window must fill
      // first — a session younger than the window has nothing to be reproached
      // with, it has not missed anything yet. The filter predicate knows
      // exactly one number and not a single file.
      'pre:()=>{let __s=globalThis.__ccWatch;' +
        'return __s&&__s.nextAt>globalThis.__ccMono()?"not-yet":null},' +
      'gate:(__c,__svc)=>{let __now=globalThis.__ccMono(),' +
        '__w=__svc.num("window_min",__c.window_min,30,1)*60000,__th=__svc.num("threshold",__c.threshold,1,1),' +
        '__cd=__svc.num("cooldown_min",__c.cooldown_min,30,1)*60000,' +
        '__lth=__svc.num("live_threshold",__c.live_threshold,1,1),' +
        '__lk=__c.live_kinds||["local_agent","remote_agent","in_process_teammate"],' +
        '__rc=__svc.num("live_recheck_ms",__c.live_recheck_ms,60000,1000);' +
        // `last` is the moment of the previous consultation and `null` is
        // its absence. It cannot be a 0: this clock is monotonic and its
        // zero is the start of THIS process, so a fresh session read as
        // "spoke a moment ago" and served a full cooldown of silence the
        // instant its window filled. A sentinel has to be outside the
        // value space, not at one end of it.
        'let __s=globalThis.__ccWatch??={last:null,start:__now};' +
        '__s.w=__w;' +
        'let __tr=null;try{__tr=$4?.taskRegistry?.all?.()}catch{}' +
        '__s.reg=!!__tr;' +
        'let __lv=__tr?Object.values(__tr).filter((__x)=>(__x?.status==="running"' +
          '||__x?.status==="pending")&&__x?.isBackgrounded!==!1' +
          '&&__lk.includes(__x?.type)):[];' +
        '__s.lv=__lv.length;' +
        'if(__tr&&__lv.length>=__lth){__s.nextAt=__now+__rc;' +
          'return "live-work:"+__lv.length}' +
        'let __f=(globalThis.__ccFleet||[]).filter((__x)=>__now-__x<__w);' +
        'let __n=__f.length;__s.n=__n;' +
        // Every refusal names the MOMENT before which it cannot change: the
        // window expires at its own mark, the cooldown at its own, and the
        // fleet count drops below the threshold when the (n-threshold+1)-th
        // mark by seniority leaves the window. The marks lie in arrival order,
        // so that is an index. A new dispatch only pushes that moment back, so
        // an early estimate is safe: it costs one extra full pass, not a miss.
        // A mark is a record of a PAST dispatch; the registry is the present.
        // When the registry is readable and says the fleet is not busy, we HAVE
        // the answer, and deferring to a mark instead is preferring hearsay to
        // the witness. Two states did exactly that: a dispatch the judge
        // cancelled leaves its mark behind (the mark is pushed here, on the main
        // dispatcher, and the judge throws later, inside the tool call), and a
        // dispatch that finished five minutes ago leaves one too. Either muted
        // the watcher for the REST OF THE WINDOW -- 30 minutes by default --
        // which is the "loop working, fleet idle" state it exists to notice,
        // hidden by its own bookkeeping. Measured on the live journal before
        // this change: 345 live-work refusals against 56 fleet-busy ones, i.e.
        // the registry is readable in practice and the mark path still fired.
        //
        // What a mark can still testify to is a dispatch made moments ago that
        // has not reached the registry yet. So it silences for exactly that
        // settling time and no longer -- the same `live_recheck_ms` the live
        // branch above uses, for the same reason.
        //
        // With an UNREADABLE registry nothing else is left, and the window and
        // threshold keep their old meaning. That is the only path where they
        // still apply, and the journal names which one was taken.
        'if(__tr){let __lm=__n?__f[__n-1]:0;' +
          'if(__n&&__now-__lm<__rc){__s.nextAt=__lm+__rc;return "dispatch-settling:"+__n}}' +
        'else if(__n>=__th){__s.nextAt=__f[__n-__th]+__w;return "fleet-busy:"+__n}' +
        'if(__now-__s.start<__w){__s.nextAt=__s.start+__w;return "window-not-filled"}' +
        'if(__s.last!==null&&__now-__s.last<__cd){__s.nextAt=__s.last+__cd;return "cooldown"}' +
        '__s.last=__now;__s.nextAt=__now+__cd;return null},' +
      'payload:()=>JSON.stringify({spawns_in_window:globalThis.__ccWatch?.n??0,' +
        'window_min:Math.round((globalThis.__ccWatch?.w??0)/60000),' +
        'live_works:globalThis.__ccWatch?.lv??0,' +
        'task_registry_readable:globalThis.__ccWatch?.reg??!1,' +
        'current_tool:$2.name}),' +
      // The reaction: queueing. A queueing error is swallowed — a reminder
      // that crashed a working call would be worse than a missed reminder.
      // Both fields were MEASURED against the installed image, not taken from
      // the typescript-src reconstruction — it diverged at this spot since
      // 2.1.239 and cost a separate run. In the image the main-loop filter is
      // `dA(e)=e.agentId===Di()`, that is, the entry is addressed by the SESSION
      // id, not by the absence of a field.
      // Priority "next": the drain threshold equals "later" only in a thread
      // where Sleep fired, so an entry with "later" would wait for Sleep
      // indefinitely — the journal would write "nudge", the queue would accept
      // the entry, and there would be no delivery.
      'onAct:async(__r,__svc)=>{try{' + TV + '({value:"[fleet-idle] "+__r+"\\n(\\u041d\\u0430\\u043f\\u043e\\u043c\\u0438\\u043d\\u0430\\u043d\\u0438\\u0435 \\u043d\\u0430\\u0431\\u043b\\u044e\\u0434\\u0430\\u0442\\u0435\\u043b\\u044f \\u0437\\u0430 \\u0444\\u043b\\u043e\\u0442\\u043e\\u043c, \\u0430 \\u043d\\u0435 \\u0433\\u0435\\u0439\\u0442: \\u0440\\u0435\\u0448\\u0430\\u0435\\u0448\\u044c \\u0442\\u044b.)",' +
        'mode:"task-notification",agentId:' + DI + '(),priority:"next"})}' +
        // A queueing failure is NOT swallowed silently. A silent catch here
        // would mean "the journal writes nudge, there is no delivery" — the
        // very shape of a mechanism formally alive and substantively off.
        // Crashing a working call over a reminder is still forbidden, so the
        // outcome goes to the journal.
        'catch(__ne){try{await __svc.log({outcome:"nudge_undelivered",' +
          'reason:__svc.clip(String(__ne?.message??__ne),200)})}catch{}}},' +
      // The watcher is fail-open: no verdict, broken settings, a channel
      // failure — all of it stays in the journal and stops NOTHING.
      'onNoVerdict:()=>{},onBroken:()=>{},onFail:()=>{}' +
    '});';

  // Injection by OFFSET, not via String.replace: group numbers diverge between
  // the two call shapes, and the replacement string additionally reads `$` as
  // a reference. The slice at m.index interprets nothing, and the call itself
  // goes back in place verbatim (m[0]) — we have no business rewriting it.
  // A slot the body never mentions is a slot nobody maintains: it survives a
  // rename of the thing it pointed at without a sound. So the resolution is
  // checked in BOTH directions -- every `$n` the text uses must be bound, and
  // every slot the map binds must be used.
  const resolveFor = (text, slots, where) => {
    const used = new Set();
    const out = text.replace(/\$([1-9])/g, (t, digit) => {
      const v = slots['$' + digit];
      if (!v) fail(`${where} body references ${t}, which that site does not bind`);
      used.add('$' + digit);
      return v;
    });
    for (const k of Object.keys(slots)) {
      if (!used.has(k)) fail(`${where} binds ${k}, which its body never uses`);
    }
    return out;
  };

  // Two homes, one core.
  //
  // The WATCHER belongs to the main dispatcher: it is a heartbeat over every
  // tool call the main loop makes, and the dispatch count it keeps is a
  // by-product taken along the way. Moving it onto the dispatch tool would
  // leave it blind on every session that dispatches nothing -- which is
  // precisely the state it exists to notice.
  //
  // The JUDGE belongs to the tool: it has exactly one subject, and the tool is
  // the one place every dispatcher must pass through. That is what makes the
  // count of dispatchers stop mattering.
  const watchBlock =
    '/*__ccProbe0*/' + resolveFor(core + watchCall, SLOT, 'watcher') + '/*__ccProbe1*/';
  const judgeBlock =
    '/*__ccProbe0*/' + resolveFor(core + judgeCall, SLOT_TOOL, 'judge') + '/*__ccProbe1*/';

  // The names went in as text; assert they came out as themselves. A future
  // escaping mistake would otherwise produce a plausible-looking identifier
  // that is bound to nothing, and every shape check would still pass.
  for (const [what, name, where] of [
    ['single-shot query engine', qm[1], `typeof ${qm[1]}===`],
    ['notification queue', nm[1], `${nm[1]}({value:`],
    ['session id', nm[2], `agentId:${nm[2]}()`],
    ['session title accessor', tm[1], `let __v=${tm[1]}(__i)`],
  ]) {
    if (!watchBlock.includes(where)) {
      fail(`the ${what} name '${name}' did not survive into the watcher block verbatim`);
    }
  }
  if (!judgeBlock.includes(`typeof ${qm[1]}===`)) {
    fail(`the single-shot query engine name '${qm[1]}' did not survive into the judge block verbatim`);
  }

  // The watcher block is a sequence of STATEMENTS, so the byte it is spliced in
  // front of has to begin one. The main site's match starts right after a
  // `try{` (the result variable was declared earlier), and a build that moved
  // the call into an expression position must stop here loudly instead of
  // emitting something that cannot parse.
  const prev = js.slice(0, m.index).trimEnd().slice(-1);
  if (!(prev === ';' || prev === '{' || prev === '}')) {
    fail(
      `main dispatch call site is not in statement position (preceded by ` +
        `'${prev}') -- refusing to splice statements there`,
    );
  }

  // Later offset first: splicing the earlier one would move every index after
  // it, and both match indices were taken from the same string.
  const edits = [
    { at: m.index, len: 0, text: watchBlock },
    {
      at: mTool.index,
      len: mTool[0].length,
      text:
        `async call(${TOOL_IN},${mTool[2]}${mTool[3]}){` +
        `let ${mTool[1]}=${TOOL_IN};` +
        judgeBlock,
    },
  ];
  for (const e of [...edits].sort((x, y) => y.at - x.at)) {
    js = js.slice(0, e.at) + e.text + js.slice(e.at + e.len);
  }

  applied.push(
    `judge: consulted inside the dispatch tool's own call (context ` +
      `'${mTool[2]}', input pattern re-bound as '${TOOL_IN}'); watcher on the ` +
      `main dispatcher (tool '${TOOL}', input '${m[4]}', context '${m[5]}')`,
  );
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
  // Two independent guards refuse bypassPermissions when euid is 0: the inline
  // check on the startup path and the exported refuseBypassUnderRoot(). Both
  // are neutralised here.
  //
  // tweakcc's own patch for this rewrites only the FIRST -- its regex is not
  // global and String.match stops there -- which leaves the second live and the
  // setting half-applied. That patch is condition-gated off in the config
  // today, and the older form of this step demanded EXACTLY two occurrences,
  // so the day the knob is switched on the count becomes 1 and this step fails
  // the whole run. The comment above already named the collision; the step did
  // not act on it. It does now: whatever the count, every LIVE guard is
  // neutralised, and zero live guards is a verified postcondition rather than
  // a failure.
  const guard =
    'console.error("--dangerously-skip-permissions cannot be used with root/sudo ' +
    'privileges for security reasons"),process.exit(1)';
  const count = js.split(guard).length - 1;
  if (count === 0) {
    // Nothing live -- but prove the refusal is actually gone rather than
    // reworded, or this branch turns a moved guard into a green run.
    if (js.includes('cannot be used with root/sudo privileges')) {
      fail('root/sudo refusal survives in an unrecognised form');
    }
    applied.push('root/sudo refusal (already neutralised upstream; verified)');
    return;
  }
  if (count > 2) fail(`found ${count} root/sudo refusals, expected at most 2 — re-check before neutralising`);
  js = js.split(guard).join('void 0');
  applied.push(
    count === 2
      ? 'root/sudo refusal neutralised at 2 sites'
      : `root/sudo refusal neutralised at 1 site (the other was already neutralised upstream)`,
  );
});

step('25 CLAUDE.md alternate filenames', () => {
  const ID = '[A-Za-z_$][\\w$]*';
  // Every memory file -- user, project, local, parent-directory walk -- is read
  // through this one function, so a wrapper around it covers all of them. The
  // storage-backed branch returns "absent" WITHOUT throwing, which is why
  // editing the reader's catch clause misses the common case; the fork's
  // 2.1.233+ matcher was rewritten to wrap for the same reason and emits the
  // BYTE-IDENTICAL wrapper this step does. Keep the two in step: the detector
  // below recognises that exact opening.
  //
  // tweakcc runs first, so when its agents-md patch is enabled the loader
  // arrives already wrapped and this step VERIFIES rather than wraps. Wrapping
  // a wrapper would work but would read the alternates twice under two lists.
  const ALTS = [
    'AGENTS.md', 'GEMINI.md', 'CRUSH.md', 'QWEN.md',
    'IFLOW.md', 'WARP.md', 'copilot-instructions.md',
  ];

  // The detector keys on the wrapper's FIXED-LENGTH opening only. An earlier
  // version spanned `[\s\S]{0,600}?` to the closing `return __r}` so it could
  // read the alternates out of the body -- and that bound is a function of the
  // alternates list, which is user-editable: measured, the seven-name wrapper
  // leaves 216 bytes of headroom and detection fails silently once the
  // serialised list passes 309 bytes, at which point the loader gets wrapped
  // twice. A byte bound must never gate a correctness decision on a
  // user-sized string. The body is inspected separately, scoped to the module.
  const wrappedRx = new RegExp(
    `async function (${ID})\\((${ID}),(${ID}),(${ID}),(${ID})\\)\\{let __r=null;` +
      `try\\{__r=await (${ID})\\(\\2,\\3,\\4,\\5\\)\\}catch\\((${ID})\\)\\{__r=null\\}` +
      `if\\(__r&&__r\\.info\\)return __r;`,
  );
  const already = js.match(wrappedRx);
  if (already) {
    const fn = already[1];
    const inner = already[6];
    // Everything from here is checked INSIDE the wrapper's own module: a
    // bundle-wide search for `async function <inner>(` is satisfied by an
    // unrelated chunk-local function of the same minified name, which is the
    // one assumption this file exists to refuse.
    const mod = moduleTextAt(already.index);
    const innerRx = new RegExp(`async function ${rxEsc(inner)}\\(`);
    if (!innerRx.test(mod)) {
      fail(`memory-file loader wrapper delegates to '${inner}', which its own module does not define`);
    }
    const body = mod.slice(mod.indexOf(already[0]) + already[0].length);
    const tail = body.slice(0, body.indexOf(`async function ${inner}(`));
    // Presence of a wrapper is not the postcondition. Two things are: it must
    // offer alternates, and it must DROP the storage descriptor when reading
    // one -- a descriptor names a single stored key, so a wrapper that passed
    // it through would answer with CLAUDE.md's own bytes under the alternate's
    // name. That is a wrong answer, not a missing one, so it fails here.
    const offered = ALTS.filter(n => tail.includes(JSON.stringify(n)));
    if (offered.length === 0) {
      fail(`memory-file loader '${fn}' is wrapped but offers no alternate filenames`);
    }
    // `[^)]*` does NOT work here: the alternate call's own arguments contain
    // parentheses (`__sw(__p,__n)`), so a negated-paren class stops before the
    // `,void 0` it is looking for and the check fails on correct output. It did
    // exactly that on the first run.
    if (!new RegExp(`await ${rxEsc(inner)}\\([\\s\\S]{0,240}?,void 0\\)`).test(tail)) {
      fail(`memory-file loader '${fn}' is wrapped but does not drop the storage descriptor for alternates`);
    }
    const missing = ALTS.filter(n => !offered.includes(n));
    applied.push(
      `CLAUDE.md alternates: ${offered.join(', ')} (loader '${fn}', already wrapped upstream, verified)` +
        (missing.length ? ` -- NOT offered by the upstream list: ${missing.join(', ')}` : ''),
    );
    return;
  }

  const rx = new RegExp(
    `async function (${ID})\\((${ID}),(${ID}),(${ID}),(${ID})\\)\\{try\\{let (${ID}),(${ID})=!1;` +
      `if\\(\\5\\)\\{let (${ID})=await (${ID})\\(\\5\\);switch\\(\\8\\.kind\\)\\{case"absent":` +
      `return\\{info:null,includePaths:\\[\\]\\};`,
  );
  const m = js.match(rx);
  if (!m) fail('memory-file loader not found');
  const [, fn, a, b, c, d] = m;
  const inner = `${fn}$cc`;
  // The initial read is guarded like the alternates: the reader converts its
  // own filesystem failures to a null-info result, but a throw that escapes it
  // would otherwise skip the alternates entirely -- the wrapper promises to be
  // exit-agnostic and this is one of the exits.
  const wrapper =
    `async function ${fn}(${a},${b},${c},${d}){` +
      `let __r=null;try{__r=await ${inner}(${a},${b},${c},${d})}catch(__e){__r=null}` +
      `if(__r&&__r.info)return __r;` +
      `let __p=String(${a}??"");` +
      `if(!/(^|[\\\\/])CLAUDE\\.md$/.test(__p))return __r;` +
      `let __c=String(${c}??"");` +
      `let __sw=(__s,__n)=>/(^|[\\\\/])CLAUDE\\.md$/.test(__s)?__s.slice(0,-9)+__n:__s;` +
      `for(let __n of ${JSON.stringify(ALTS)}){` +
        `try{let __x=await ${inner}(__sw(__p,__n),${b},__c?__sw(__c,__n):${c},void 0);` +
        `if(__x&&__x.info)return __x}catch{}}` +
      `return __r||{info:null,includePaths:[]}}`;
  const declAt = js.indexOf(m[0]);
  js =
    js.slice(0, declAt) +
    wrapper +
    // The pattern is a literal STRING, so `$` in it is matched verbatim and must
    // NOT be escaped -- repEsc there would make the search fail. The replacement
    // is the opposite: `inner` is built as `${fn}$cc`, so a loader name ending in
    // `$` yields `$$` and collapses to one dollar. The wrapper would then call a
    // name one character longer than the function it renamed.
    m[0].replace(`async function ${fn}(`, `async function ${repEsc(inner)}(`) +
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
  // The one site in this file that rewrote by a NON-GLOBAL replace without
  // asserting how many times its pattern matched: `replace` would have taken
  // the first silently. Counted across all 32 announcements, 31 bound their
  // edit either to a module (moduleTextAt/editModuleAt) or to an explicit
  // `!== 1` refusal; this was the exception, and the check block cannot cover
  // for it -- every one of its 112 entries asks whether the text EXISTS
  // somewhere, none where it sits, so a rewrite of the wrong same-shaped site
  // would be found by exactly the checks looking for what was just written.
  // Minified names are chunk-local since 2.1.242, which is what makes a second
  // same-shaped site a live possibility rather than a theoretical one.
  const all = [...js.matchAll(new RegExp(rx.source, 'g'))];
  if (all.length !== 1) fail(`expected 1 system-prompt assembly site, found ${all.length}`);
  js = js.replace(
    rx,
    '$1,...(process.env.CLAUDE_JUDGE&&$2?.agentContext?.agentType==="main"?' +
      JSON.stringify(RULE).replace(/^/, '[').replace(/$/, ']') +
      ':[])].filter(Boolean)',
  );
  applied.push(`system prompt: dispatch-cancellation rule (options '${m[2]}')`);
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
  const rx = new RegExp(
    `(${ID})=(${ID})&&(${ID})\\?\\.behavior==="ask"\\?` +
      `(${ID})\\(\\3\\.decisionReason,(${ID})\\):void 0;`,
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

  // The registry on 2.1.246 marks exactly two breakers bypassImmune:
  //   dangerousRemoval:      {bypassImmune:!0, classifierRouted:!0}
  //   isolatePeerMachines:   {bypassImmune:!0, classifierRouted:!1}
  //   backgroundOperator / suspiciousWindowsPath: bypassImmune:!1
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
      `__ccbr.circuitBreaker!=="dangerousRemoval"&&${m[5]}(__ccbr)):void 0;` +
    js.slice(m.index + m[0].length);

  applied.push(
    `full-bypass mode lifts only the dangerousRemoval immunity, peer-machine ` +
      `isolation still stops (flag '${m[1]}', mode predicate '${m[2]}', ` +
      `decision '${m[3]}', immunity predicate '${m[5]}', ${js.length - before} bytes)`,
  );
});


// The gate lives at the very END on purpose: it was once placed mid-file, and
// the four steps written after it ran unguarded — a broken locator among them
// was recorded and never read, so the build reported success while the patch
// was missing (that is exactly how step 26 first shipped as a no-op).
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
    shape,
  );
}

console.error(`multi-provider patch: applied ${applied.length} edits:\n  - ${applied.join('\n  - ')}`);

return js;
