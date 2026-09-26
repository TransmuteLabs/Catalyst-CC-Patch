#!/usr/bin/env node
// Teeth of patch steps 34+32 (the requestText door and its source cut-ins),
// run against the REAL image: the steps' locators must find exactly one site
// of each source there, the emitted cut-ins must carry the SAME F/H as the
// body literal, no wrapper may remain on the body literal, and the code cut
// out of the patched output must perform the policy edits of the REAL plugin
// rule on fixtures shaped like the live request -- and nothing else. The
// lifecycle cut-ins are cut out of the same output and executed on host
// stubs (section 2b): the door call must carry the module's own name and
// generation.
// CONSTRAINT: the image is read as latin-1 so byte offsets stay honest; the
// other steps are switched off through the same STEPS_OFF channel the
// pipeline uses, so this exercises the real step bodies, not copies.
// CONSTRAINT: the rule comes from the plugin module itself (the RULE literal
// is extracted and evaluated), never from a copy of its text here.
//   node tools/swe32-teeth.mjs --scope <unit>[,<unit>...] [--image <claude binary>]
//   node tools/swe32-teeth.mjs --list
// CONSTRAINT (CENSUS.md): без --scope или с неизвестным именем -- код 2 и
// ноль запусков; сборка (секция 1) -- сетап всех юнитов и выполняется всегда.
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const PATCH = path.join(HERE, '..', 'tweakcc-patch.js');
const PLUGIN_RULE = path.join(HERE, '..', '..', 'Catalyst', 'plugins', 'catalyst-swe-request', 'hooks', 'register.ts');
const argv = process.argv.slice(2);
const at = argv.indexOf('--image');
const IMAGE = at !== -1 ? argv[at + 1] : path.join(process.env.HOME ?? '', '.local', 'bin', 'claude');
const STEPS = ['32 request text for devin/swe-2', '34 requestText door'];

// Юниты: steps (сборка), shape (полные формы врезок), lifecycle-<key> (зуб A7
// на той же форме, по юниту на ключ), fixtures (гостей двери на фикстурах),
// late-writer (D7), sandbox (Г3). Сборка едина -- юнит решает, какие
// утверждения исполняются.
const UNITS = ['steps', 'shape',
  ...['zt1', 'en1', 'pe', 'term', 'bn', 'gst', 'ust', 'zwe', 'load', 'disc', 'ztail',
     'xceif', 'death', 'xcecatch', 'reltry', 'wcad', 'xeloop', 'refold', 'wstdied', 'wstwe']
    .map((k) => 'lifecycle-' + k),
  'fixtures', 'late-writer', 'sandbox'];
if (argv.includes('--list')) { console.log(UNITS.join('\n')); process.exit(0); }
const scopeAt = argv.indexOf('--scope');
const scopeNames = scopeAt === -1 || scopeAt + 1 >= argv.length ? [] : argv[scopeAt + 1].split(',').filter((n) => n !== '');
const unknownUnits = scopeNames.filter((n) => !UNITS.includes(n));
if (scopeNames.length === 0 || unknownUnits.length) {
  console.log(`nothing run: scope required (--scope <name>[,<name>...]); known: ${UNITS.join(',')}`);
  process.exit(2);
}
const SEL = new Set(scopeNames);

let pass = 0, failed = 0;
let curUnit = null;
const ran = new Set();
const ok = (cond, name) => {
  if (!SEL.has(curUnit)) return;
  ran.add(curUnit);
  if (cond) { pass++; } else { failed++; console.log(`  FAIL ${name}`); }
};
const unit = (name) => { curUnit = name; };
const rxEsc = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// --- 1. run ONLY steps 34+32 on the real image -------------------------------
unit('steps');
const src = fs.readFileSync(PATCH, 'utf8');
const names = [...src.matchAll(/^step\('([^']+)'/gm)].map((m) => m[1]);
for (const s of STEPS) ok(names.includes(s), `step declared in tweakcc-patch.js: ${s}`);
const off = names.filter((n) => !STEPS.includes(n));
const anchor = 'const STEPS_OFF = [];';
ok(src.split(anchor).length === 2, 'STEPS_OFF anchor is unique');
const scripted = src.replace(anchor, `const STEPS_OFF = ${JSON.stringify(off)};`);
const stat = fs.statSync(IMAGE);
const image = fs.readFileSync(IMAGE, 'latin1');
ok(image.length === stat.size, `image read as latin-1 keeps its byte length (${stat.size})`);
const quiet = console.error; let summary = '';
console.error = (...a) => { summary += a.join(' ') + '\n'; };
let out;
try { out = new Function('js', scripted)(image); } finally { console.error = quiet; }
ok(typeof out === 'string', 'the patch script returned the bundle');
ok(/applied 2 edits:/.test(summary) &&
   summary.includes('34 requestText door') &&
   summary.includes('32 request text for devin/swe-2'),
  'summary reports exactly steps 34+32 applied');
ok(out.length > image.length, 'the output grew');

// --- 2. shape of the patched output -------------------------------------------
unit('shape');
const ID = '[A-Za-z_$][\\w$]*';
ok(out.split('/*swe32*/').length - 1 === 0 && out.split('/*swe32-end*/').length - 1 === 0,
  'no step-32 wrapper remains anywhere in the bundle');
ok(out.split('__ctlApply').length - 1 === 0, 'the retired applier name is gone from the bundle');
const body = new RegExp(`let (${ID})=\\{model:(${ID})\\((${ID})\\.model\\),messages:`).exec(out);
ok(body !== null, 'the body literal is intact and unrewritten');
const FN = body ? body[2] : 'F';
const HN = body ? body[3] : 'H';
// Every name of both cut-ins is a capture of the source form, never a
// minified literal of one version.
const sysCut = new RegExp(
  `(?<sb>${ID})=__ctlSys\\((?<xko>${ID})\\((?<n1>${ID}),(?<hb>${ID}),\\{skipGlobalCacheForSystemPrompt:(?<vo>${ID}),cacheTtl:(?<ls>${ID})\\}\\),` +
  `${rxEsc(FN)}\\(${rxEsc(HN)}\\.model\\)\\)`).exec(out);
ok(sysCut !== null && out.split(sysCut[0]).length === 2,
  'exactly one system cut-in, keyed to the body-literal F(H.model)');
const toolsCut = new RegExp(`let (?<cf>${ID})=__ctlTools\\(\\[\\.\\.\\.(?<fo>${ID}),\\.\\.\\.(?<bde>${ID})\\]\\)`).exec(out);
ok(toolsCut !== null && out.split(toolsCut[0]).length === 2, 'exactly one tools cut-in');
ok(sysCut !== null && toolsCut !== null && sysCut.index < toolsCut.index,
  'the system source is cut in before the tools source');
ok(out.split('globalThis.__ctlRequestTextSettle=__ctlSettle;').length === 2,
  'the settle bridge is assigned exactly once');
// The contentful log literals of the lifecycle cut-ins must remain CALLS
// (paren + backtick): a splice that loses the paren turns the region into
// syntax garbage while the bridge counter stays green.
for (const [lit, where] of [
  ['(`session.start: raised for ', 'Zt raised'],
  ['(`session.start: failed for ', 'Zt failed'],
  ['(`session.start: raised (surface ', 'en raised'],
  ['(`session.start: failed: ', 'en failed'],
]) {
  const n = out.split(lit).length - 1;
  ok(n === 1, `the ${where} log call keeps its exact shape in the patched bundle (found ${n})`);
}
// The lifecycle cut-ins: the SAME full forms with backreferences as the
// needles of claude-patch-all.sh, each exactly one match in the bundle.
const ST = 'globalThis\\.__ctlRequestTextSettle\\?\\.\\(';
// Every form is kept by KEY with its single match: the executable teeth of
// section 2b run exactly the bytes these forms pin.
const lifecycle = [
  ['zt0', 'Zt without a session.start hook settles its own name and generation before continue',
    `if\\((?<ws>${ID})\\.add\\((?<R>${ID})\\),!\\k<R>\\.hooks\\("session\\.start"\\)\\)` +
    `\\{${ST}\\k<R>\\.name,\\k<R>\\.environmentId\\);continue\\}`],
  ['zt1', 'Zt raise chain ends with the settle finally of the same module',
    `\\(\`session\\.start: raised for \\$\\{(?<R>${ID})\\.name\\} \\(loaded later\\)\`\\),` +
    `Promise\\.resolve\\(\\)\\.then\\(\\(\\)=>(?<q>${ID})\\(\\{only:\\k<R>\\.name\\}\\)\\.session\\.start` +
    `\\(\\{cwd:(?<ne>${ID})\\(\\),\\.\\.\\.(?<o>${ID})\\}\\)\\)` +
    `\\.catch\\(\\((?<s>${ID})\\)=>\\{(?<t2>${ID})\\(\`session\\.start: failed for \\$\\{\\k<R>\\.name\\}: ` +
    `\\$\\{(?<l>${ID})\\(\\k<s>\\)\\}\`,\\{level:"error"\\}\\)\\}\\)` +
    `\\.finally\\(\\(\\)=>${ST}\\k<R>\\.name,\\k<R>\\.environmentId\\)\\)`],
  ['en0', 'en captures the initial-load set before the WeakSet',
    `let __ctlLMs=(?<ct>${ID})\\(\\)\\.loadedModules,(?<s>${ID})=new WeakSet\\(__ctlLMs\\);`],
  ['en1', 'en settles every initial-load module right after the session.start try/catch',
    `catch\\((?<e>${ID})\\)\\{(?<t>${ID})\\(\`session\\.start: failed: \\$\\{(?<l>${ID})\\(\\k<e>\\)\\}\`,\\{level:"error"\\}\\)\\}` +
    `for\\(var __ctli=0;__ctli<__ctlLMs\\.length;__ctli\\+\\+\\)` +
    `${ST}__ctlLMs\\[__ctli\\]\\.name,__ctlLMs\\[__ctli\\]\\.environmentId\\);`],
  ['pe', 'Pe: a module whose name left the set is an owner gone, inside the same condition',
    `if\\(!(?<P>${ID})\\.has\\((?<N>${ID})\\.name\\)\\)(?<a>${ID})\\(\\k<N>\\.name\\),(?<b>${ID})\\(\\k<N>\\.name\\),` +
    `(?<c>${ID})\\(\\k<N>\\.name\\),__ctlGone\\(\\k<N>\\.name,\\k<N>\\.environmentId\\)`],
  ['ust', 'USt: every candidate the load did not publish dies before the unadmitted unload',
    `(?<P>${ID})\\((?<Nt>${ID})\\);return\\}\\}finally\\{for\\(let\\[(?<k>${ID}),(?<m>${ID})\\]of (?<St>${ID})\\)if\\(!(?<s>${ID})\\.loadedModules\\.includes\\(\\k<m>\\)\\)__ctlTerm\\(\\k<m>\\.name,\\k<m>\\.environmentId\\);for\\(let\\[\\k<k>,\\k<m>\\]of \\k<St>\\)if\\((?<e>${ID})\\.state\\.unadmitted\\.has\\(\\k<k>\\)\\)\\k<m>\\.discard\\(\\)\\}\\}`],
  ['gst', 'GSt: every candidate the respawn did not publish dies before the unadmitted unload, an absent old module is an owner gone',
    `finally\\{for\\(let\\[(?<k>${ID}),(?<m>${ID})\\]of (?<b>${ID})\\)if\\(!__ctlOk\\|\\|!(?<h>${ID})\\?\\.includes\\(\\k<m>\\)\\)__ctlTerm\\(\\k<m>\\.name,\\k<m>\\.environmentId\\);try\\{for\\(let\\[\\k<k>,\\k<m>\\]of \\k<b>\\)if\\((?<e>${ID})\\.state\\.unadmitted\\.has\\(\\k<k>\\)\\)\\k<m>\\.discard\\(\\)\\}catch\\(__ctle\\)\\{for\\(let\\[\\k<k>,\\k<m>\\]of \\k<b>\\)if\\(\\k<h>\\?\\.includes\\(\\k<m>\\)\\)__ctlTerm\\(\\k<m>\\.name,\\k<m>\\.environmentId\\);throw __ctle\\}\\}let (?<f>${ID})=(?<s>${ID})\\.loadedModules;\\k<s>\\.loadedModules=\\k<h>,\\k<e>\\.state\\.isSetRecord=!0;for\\(let (?<j>${ID}) of \\k<f>\\)\\k<j>\\.retire\\(\\);for\\(let \\k<j> of \\k<f>\\)if\\(!\\k<h>\\.some\\(\\(__ctlx\\)=>__ctlx\\.name===\\k<j>\\.name\\)\\)__ctlGone\\(\\k<j>\\.name,\\k<j>\\.environmentId\\);`],
  ['zwe', 'zwe: a candidate whose scan check fails dies as a generation before it is unloaded',
    `(?<h>${ID})=\\+\\+(?<e>${ID})\\.state\\.environmentCounter,(?<S>${ID})=await (?<g>${ID})\\.load\\(\\k<h>,(?<n>${ID})\\);` +
    `try\\{(?<b>${ID})\\(\\k<n>\\.pluginName,\\k<n>\\.scan,\\k<S>\\.registered\\.map\\(\\((?<v>${ID})\\)=>\\k<v>\\.pattern\\)\\)\\}` +
    `catch\\((?<x>${ID})\\)\\{throw __ctlTerm\\(\\k<n>\\.pluginName,\\k<h>\\),\\k<g>\\.unload\\(\\k<h>\\),\\k<x>\\}`],
  ['load', 'worker load: a refused or timed-out load dies as a generation before its unload',
    `function ${ID}\\((?<e>${ID}),(?<n>${ID}),(?<r>${ID})\\)\\{if\\(\\k<e>\\.died!==void 0\\)return Promise\\.reject\\(new ${ID}\\(\\k<e>\\.died\\)\\);` +
    `\\k<e>\\.names\\.set\\(\\k<n>,\\k<r>\\.pluginName\\);let (?<mc>${ID})=new MessageChannel,(?<pt>${ID})=\\k<mc>\\.port1;` +
    `\\k<e>\\.ports\\.set\\(\\k<n>,\\k<pt>\\),\\k<pt>\\.onmessage=\\((?<fr>${ID})\\)=>${ID}\\(\\k<e>,\\{environmentId:\\k<n>,port:\\k<pt>,frame:\\k<fr>\\.data\\}\\),` +
    `${ID}\\(\\k<pt>\\);let (?<tm>${ID})=${ID}\\(\\k<e>\\.pendingLoads,\\k<n>,${ID}\\(\\k<r>\\.pluginName\\)\\);` +
    `return new Promise\\(\\((?<ok>${ID}),(?<no>${ID})\\)=>\\{if\\(\\k<e>\\.pendingLoads\\.set\\(\\k<n>,(?<obj>\\{resolve:\\((?<ra>${ID})\\)=>\\{clearTimeout\\(\\k<tm>\\),\\k<ok>\\(\\k<ra>\\)\\},` +
    `reject:\\((?<rb>${ID})\\)=>\\{(?<cut>__ctlTerm\\(\\k<r>\\.pluginName,\\k<n>\\),)clearTimeout\\(\\k<tm>\\),\\k<e>\\.names\\.delete\\(\\k<n>\\),(?<pn>${ID})\\(\\k<e>,\\k<n>\\),` +
    `(?<il>${ID})\\(\\k<e>,\\{type:"unload",environmentId:\\k<n>\\}\\),\\k<no>\\(\\k<rb>\\)\\}\\})\\)`],
  // Г11: discard-воронка и СЕМЬ её вызывающих -- по сайту; игла D21 доказывает
  // воронку, эти формы доказывают, что каждый вызывающий доходит до неё.
  ['disc', 'discard: an unpublished candidate discarded through the funnel dies as a generation',
    `discard:(?<cut>\\(\\)=>\\{__ctlTerm\\((?<n>${ID})\\.pluginName,(?<h>${ID})\\),(?<G>${ID})\\(\\)\\}),retire\\(\\)\\{`],
  ['wcad', 'admission: a candidate refused while unadmitted is discarded through the funnel',
    `if\\((?<E>${ID})\\((?<b>${ID})\\.name,(?<M>${ID})\\),(?<e>${ID})\\.state\\.unadmitted\\.has\\(\\k<b>\\.environmentId\\)\\)(?<cut>\\k<b>\\.discard\\(\\);)(?<h2>${ID})\\.push\\(\\k<b>\\)`],
  ['xeloop', 'load: a host-death exit discards every non-admitted candidate through the funnel',
    `function (?<xe>${ID})\\((?<st>${ID})\\)\\{(?<cut>for\\(let (?<w>${ID}) of \\k<st>\\)if\\(!(?<e>${ID})\\(\\k<w>\\)\\)\\k<w>\\.discard\\(\\);)(?<Ee>${ID})\\(\\)\\}`],
  ['refold', 'load: a refold discards every non-admitted candidate of the new set through the funnel',
    `(?<cut>for\\(let (?<Jt>${ID}) of (?<Nt>${ID})\\)if\\((?<ft>${ID})\\.add\\(\\k<Jt>\\.name\\),!(?<e>${ID})\\(\\k<Jt>\\)\\)\\k<Jt>\\.discard\\(\\);)continue`],
  ['wstdied', 'respawn: an early host death discards the admitted set through the funnel',
    `\\.died!==void 0\\)\\{(?<cut>for\\(let (?<x>${ID}) of (?<a>${ID})\\)\\k<x>\\.discard\\(\\);)return\\}`],
  ['wstwe', 'respawn: a refold discards the admitted set through the funnel after remembering their names',
    `(?<h>${ID})=(?<ad>${ID});break\\}(?<cut>for\\(let (?<x>${ID}) of \\k<ad>\\)(?<M>${ID})\\.add\\(\\k<x>\\.name\\),\\k<x>\\.discard\\(\\))\\}`],
  ['ztail', 'zwe tail: a throw after the scan check dies before it is unloaded; the try opens right after the scan-check catch',
    `(?<x>${ID})\\}try\\{[\\s\\S]{0,2000}?releasePresses:\\((?<rp>${ID})\\)=>\\{if\\((?<Mk>${ID})\\.kind!=="unloaded"\\)(?<g>${ID})\\.releasePresses\\((?<h>${ID}),\\k<rp>\\)\\}\\}\\);return (?<r>${ID})\\}catch\\(__ctle\\)\\{(?<cut>throw __ctlTerm\\((?<n>${ID})\\.pluginName,\\k<h>\\),\\k<g>\\.unload\\(\\k<h>\\),__ctle)\\}`],
  ['xceif', 'reload fold: an empty engine.create fold dies before the restore',
    `(?<cut>if\\(!(?<Ie>${ID})\\)\\{__ctlTerm\\((?<xe>${ID})\\.name,\\k<xe>\\.environmentId\\);__ctlWd=1;(?<We>${ID})\\(\\);)let `],
  ['death', 'reload: a built candidate the dead host never published dies before the restore',
    `(?<cut>if\\((?<je>${ID})!==void 0\\)throw __ctlTerm\\((?<xe>${ID})\\.name,\\k<xe>\\.environmentId\\),__ctlWd=1,(?<We>${ID})\\(\\),new )`],
  ['xcecatch', 'reload build: the try runs from the build through the publication and its catch dies the candidate first',
    `(?<r>${ID})\\.loadedModules=(?<X>${ID})\\}(?<cut>catch\\((?<c>${ID})\\)\\{throw (?<xe>${ID})&&__ctlTerm\\(\\k<xe>\\.name,\\k<xe>\\.environmentId\\),__ctlWd\\|\\|(?<We>${ID})\\(\\),\\k<c>\\})` +
    `(?<s>${ID})\\?\\.retire\\(\\)`],
  ['reltry', 'reload: the whole region from the build through the publication is ONE try behind a restore-once flag',
    `let __ctlWd=0;try\\{(?<xe>${ID})=await (?<sv>${ID})\\((?<n>${ID}),(?<F>${ID})\\),\\k<xe>\\.shown=`],
];
const forms = {};
for (const [key, what, rx] of lifecycle) {
  const hits = [...out.matchAll(new RegExp(rx, 'g'))];
  if (hits.length === 1) forms[key] = hits[0];
  ok(hits.length === 1, `lifecycle ${what} (found ${hits.length})`);
}
// The bridge call bytes occur exactly as often as the DECLARED call-bearing
// full forms (Zt without a hook, Zt .finally, en loop): a call outside those
// forms is invisible to them. The negative control proves the predicate bites
// on one extra call.
const CALL = 'globalThis.__ctlRequestTextSettle?.(';
const CALL_FORMS = 3;
const callsOk = (text) => text.split(CALL).length - 1 === CALL_FORMS;
ok(callsOk(out), `settle bridge: the call count equals the call-bearing full forms (found ${out.split(CALL).length - 1})`);
ok(!callsOk(out + ';' + CALL + 'x.name,x.environmentId)'), 'settle bridge: one extra call reddens the call count');
{ // terminate: the cut-in of the module literal's own N/H, within 2000 bytes
  const lits = [...out.matchAll(new RegExp(
    `(?<ft>${ID})\\(\\{name:(?<N>${ID})\\.pluginName,[^{}]*environmentId:(?<H>${ID}),hopKey:`, 'g'))];
  let n = 0;
  if (lits.length === 1) {
    const N = rxEsc(lits[0].groups.N), H = rxEsc(lits[0].groups.H);
    const tms = [...out.slice(lits[0].index, lits[0].index + 2000).matchAll(new RegExp(
      `terminate\\(\\)\\{(?<a>${ID})\\(${N}\\.pluginName\\),(?<b>${ID})\\(${N}\\.pluginName\\),(?<c>${ID})\\(${N}\\.pluginName\\),` +
      `(?<i3>${ID})\\.forgetPresses\\(${N}\\.pluginName\\),__ctlTerm\\(${N}\\.pluginName,${H}\\),(?<z>${ID})\\(\\)\\}`, 'g'))];
    n = tms.length;
    if (n === 1) forms.term = Object.assign(tms[0], { N: lits[0].groups.N, H: lits[0].groups.H });
    // The zwe cut-in belongs to the SAME module: its captures are the
    // literal's own N/H and it closes before the literal, within 2000 bytes.
    const zw = forms.zwe;
    ok(!!zw && zw.groups.n === lits[0].groups.N && zw.groups.h === lits[0].groups.H &&
       zw.index + zw[0].length <= lits[0].index && lits[0].index - zw.index < 2000,
      'lifecycle zwe: the cut-in carries the module literal\'s own N/H and closes before it');
  } else ok(false, 'lifecycle zwe: the cut-in carries the module literal\'s own N/H and closes before it');
  ok(lits.length === 1 && n === 1,
    `lifecycle terminate: the generation death of the module literal's own environmentId (literals ${lits.length}, cut-ins ${n})`);
}
{ // BN: the owner-gone loop right after the retire loop, tail within 600 bytes of the filter head
  const heads = [...out.matchAll(new RegExp(
    `let (?<s>${ID})=${ID}\\(\\),(?<g>${ID})=\\k<s>\\.loadedModules\\.filter\\(\\((?<a>${ID})\\)=>(?<n>${ID})\\.has\\(\\k<a>\\.name\\)\\),`, 'g'))];
  let n = 0;
  if (heads.length === 1) {
    const G = rxEsc(heads[0].groups.g), S = rxEsc(heads[0].groups.s);
    const tails = [...out.slice(heads[0].index, heads[0].index + 2000).matchAll(new RegExp(
      `(?<loops>for\\(let (?<w>${ID}) of ${G}\\)\\k<w>\\.retire\\(\\);for\\(let \\k<w> of ${G}\\)__ctlGone\\(\\k<w>\\.name,\\k<w>\\.environmentId\\);)` +
      `${ID}\\(${ID}\\),${ID}\\(\\),${ID}\\(${S}\\.loadedModules\\),${ID}\\(\`hooks modules unloaded: `, 'g'))]
      .filter((m) => m.index < 600);
    n = tails.length;
    if (n === 1) forms.bn = Object.assign(tails[0], { G: heads[0].groups.g });
  }
  ok(heads.length === 1 && n === 1,
    `lifecycle BN: every unloaded module is an owner gone right after its retire (filters ${heads.length}, cut-ins ${n})`);
}
ok(!/[\r\n]/.test(sysCut[0]) && !/[\r\n]/.test(toolsCut[0]),
  'the cut-ins are one line (minified bundle stays minified)');

// --- 2b. А7: the lifecycle cut-ins run on host stubs ------------------------
// Each tooth takes the bytes its full form matched in the PATCHED output --
// the same match the needle pins -- binds the image's own identifiers
// (captures of that form) to recording stubs through `new Function`, and
// asserts the door call and its arguments. The host itself never runs. Every
// tooth also carries one-edit mutations of its cut-in bytes that must redden
// it, so a tooth green by construction is itself red.
const rec = () => { const f = (...a) => { f.calls.push(a); }; f.calls = []; return f; };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
// CONSTRAINT: two captures with one minified name are ONE variable of the
// image: bound to the same stub they are legal, bound to two different stubs
// the tooth would run a different program -- that collision is a red tooth.
const bind = (pairs, body) => {
  const m = new Map();
  for (const [n, v] of pairs) {
    if (m.has(n) && m.get(n) !== v) throw new Error('parameter names collide: ' + n);
    m.set(n, v);
  }
  return new Function(...m.keys(), body)(...m.values());
};
const swapArgs = (text, call, a1, a2) => {
  const from = `${call}(${a1},${a2})`;
  return text.split(from).length === 2 ? text.replace(from, `${call}(${a2},${a1})`) : null;
};
const edit = (text, from, to) => (text.split(from).length === 2 ? text.replace(from, to) : null);
const a7 = async (name, key, pick, exec, mutations) => {
  unit('lifecycle-' + key);
  if (!SEL.has(curUnit)) return;
  const f = forms[key];
  let text = null, why = '';
  try { text = f ? pick(f) : null; } catch (e) { why = String(e && e.message || e); }
  if (text === null) {
    ok(false, `A7 ${name} (the form was not found${why ? ': ' + why : ''})`);
    for (const [label] of mutations) ok(false, `A7 ${name}: ${label} reddens it`);
    return;
  }
  const verdict = (r) => Array.isArray(r) ? [r[0] === true, String(r[1] || '')] : [r === true, ''];
  let good = false, extra = '';
  try { [good, extra] = verdict(await exec(text, f)); }
  catch (e) { why = String(e && e.message || e); }
  ok(good, `A7 ${name}` + (good ? '' : ` (${why || extra || 'predicate false'})`));
  for (const [label, mutate] of mutations) {
    const raw = mutate(text, f);
    // CONSTRAINT: a mutation may return {text, modes, greenModes} instead of
    // bare bytes: `modes` restricts the composite scenario to exactly the
    // named runs, and every `greenModes` run of the SAME mutant bytes must
    // stay green. Without that control an early scenario's red is credited
    // to a later composite one (gpt6 F1 on #468-FIX6: the reordered-finally
    // mutant reddened `ordering` and never reached `tables-discard`).
    const spec = raw !== null && typeof raw === 'object' && !Array.isArray(raw) && typeof raw.text === 'string';
    const m = spec ? raw.text : raw;
    let bad = true, syntax = false, control = '';
    if (m !== null) {
      try { [bad] = verdict(await exec(spec ? raw : m, f)); }
      catch (e) { syntax = e instanceof SyntaxError; bad = false; }
      for (const gm of (spec && raw.greenModes) || []) {
        try {
          const [green, extra] = verdict(await exec({ text: raw.text, modes: [gm] }, f));
          if (!green) control += (control ? ' | ' : '') + gm + ': ' + extra;
        } catch (e) { control += (control ? ' | ' : '') + gm + ': threw ' + String((e && e.message) || e); }
      }
    }
    // CONSTRAINT: a mutant rejected by the parser never exercised the tooth.
    const red = m !== null && bad === false && !syntax && control === '';
    ok(red, `A7 ${name}: ${label} reddens it` + (m === null ? ' (mutation anchor not unique)' : syntax ? ' (mutant syntax refused)' : control ? ' (green-mode control red: ' + control + ')' : ''));
    console.log(`A7-MUTATION ${red ? 'RED' : 'NOT-RED'} ${key}: ${label}`);
  }
};
await a7('terminate() closes the generation of the module literal', 'term', (f) => f[0], (text, f) => {
  const g = f.groups, T = rec(), FP = rec(), order = [];
  const obj = bind([[g.a, rec()], [g.b, rec()], [g.c, rec()], [g.i3, { forgetPresses: FP }], [g.z, () => order.push('z')],
    [f.N, { pluginName: 'p' }], [f.H, 7], ['__ctlTerm', (...a) => { order.push('term'); T(...a); }]], 'return {' + text + '}');
  obj.terminate();
  return same(T.calls, [['p', 7]]) && same(order, ['term', 'z']) && same(FP.calls, [['p']]);
}, [['owner/generation swap', (t, f) => swapArgs(t, '__ctlTerm', `${f.N}.pluginName`, f.H)]]);
await a7('Pe: owner gone only for a module whose name left the set', 'pe', (f) => f[0], (text, f) => {
  const g = f.groups;
  const run = (has) => {
    const G = rec();
    bind([[g.P, { has: () => has }], [g.N, { name: 'p', environmentId: 5 }], [g.a, rec()], [g.b, rec()], [g.c, rec()], ['__ctlGone', G]], text);
    return G.calls;
  };
  return same(run(false), [['p', 5]]) && same(run(true), []);
}, [['the call leaving its condition', (t) => edit(t, ',__ctlGone(', ';__ctlGone(')]]);
await a7('BN: every retired module is an owner gone after its retire', 'bn', (f) => f.groups.loops, (text, f) => {
  const order = [];
  const mod = (name, id) => ({ name, environmentId: id, retire: () => order.push('retire ' + name) });
  bind([[f.G, [mod('p', 3), mod('q', 4)]], ['__ctlGone', (...a) => order.push('gone ' + a.join('@'))]], text);
  return same(order, ['retire p', 'retire q', 'gone p@3', 'gone q@4']);
}, [['owner/generation swap', (t, f) => swapArgs(t, '__ctlGone', `${f.groups.w}.name`, `${f.groups.w}.environmentId`)]]);
// CONSTRAINT: this fixture executes the image's entire candidate try/finally,
// not a handwritten approximation of its publication order.
function gstBody(out, f, ID) {
  const g = f.groups;
  const lo = out.lastIndexOf(`let ${g.h},${g.b}=new Map,`, f.index);
  if (lo < 0 || f.index - lo > 6000) throw new Error('respawn try head absent');
  const text = out.slice(lo, f.index + f[0].length);
  const one = (rx) => { const m = text.match(rx); if (!m) throw new Error('respawn role absent: ' + rx); return m.groups; };
  const roles = {
    ...one(new RegExp(`let (?<plans>${ID})=(?<source>${ID})\\(${g.e}\\.state\\)\\.filter`)),
    ...one(new RegExp(`let (?<candidate>${ID})=await (?<build>${ID})\\(${g.e},(?<plan>${ID})\\);`)),
    ...one(new RegExp(`${g.b}\\.set\\(${ID}\\.environmentId,${ID}\\),(?<remember>${ID})\\(`)),
    ...one(new RegExp(`let (?<folded>${ID})=await (?<fold>${ID})\\(${g.e},${ID},\\{\\.\\.\\.(?<table>${ID})\\(`)),
    ...one(new RegExp(`let\\{admitted:(?<admitted>${ID}),refused:(?<refused>${ID})\\}=await (?<admit>${ID})\\(`)),
  };
  return { text, g, roles };
}
async function gstScenario(text, f, roles, bind, mode) {
  const g = f.groups, deaths = new Set(), order = [], gone = [];
  let unsafe = false;
  const A = {name:'p', environmentId:3, hooks:()=>false, retire() {}};
  const B = {name:'B', environmentId:4, hooks:()=>false, retire() {}};
  const old = [{name:'p', environmentId:1, retire() { order.push('retire p'); }},
    {name:'q', environmentId:2, retire() { order.push('retire q'); }}];
  const holder = {loadedModules:old};
  for (const m of [A,B]) m.discard = () => {
    order.push('discard '+m.name);
    if (!deaths.has(m.name)) unsafe = true;
    if (mode==='discard' && m===B) throw new Error('discard B');
  };
  const state = {unadmitted:new Set(),knownPlugins:new Map(),lastTable:{}};
  const bindings = [[g.s,holder],[g.e,{state}],
    [roles.source,()=>[{pluginName:'A'},{pluginName:'B'}]],
    [roles.build,async(_e,p)=>p.pluginName==='A'?A:B],
    [roles.remember,()=>{}], [roles.fold,async(_e,a)=>a], [roles.table,()=>({})],
    [roles.admit,async()=>{state.unadmitted.delete(3); if(mode==='body') throw new Error('admission rejected'); return {admitted:[A],refused:[]};}],
    ['__ctlTerm',name=>{deaths.add(name);order.push('term '+name);}],
    ['__ctlGone',(...args)=>gone.push(args)]];
  let error;
  try { await bind(bindings, `return (async()=>{${text}})()`); } catch(e) { if(e instanceof SyntaxError) throw e; error=e.message; }
  const success = mode==='success';
  const passed = !unsafe && deaths.has('B') && deaths.has('p')===!success && holder.loadedModules.includes(A)===success &&
    (success ? error===undefined && same(gone, [['q', 2]]) :
      error===(mode==='discard'?'discard B':'admission rejected') && gone.length===0);
  return [passed, JSON.stringify({mode,error,deaths:[...deaths],order,gone,published:holder.loadedModules.includes(A),unsafe})];
}
await a7('GSt: success publishes A alive; body or discard failure kills every unpublished candidate', 'gst', (f) => {
  const body = gstBody(out, f, ID);
  f.roles = body.roles;
  return body.text;
}, async (text, f) => {
  for (const mode of ['success', 'discard', 'body']) {
    const result = await gstScenario(text, f, f.roles, bind, mode);
    if (!result[0]) return result;
  }
  return true;
}, [['normal-completion flag dropped', (t) => edit(t, '__ctlOk=1;', '__ctlOk=0;')],
  ['discard failure cleanup dropped', (t, f) => edit(t, `catch(__ctle){for(let[${f.groups.k},${f.groups.m}]of ${f.groups.b})if(${f.groups.h}?.includes(${f.groups.m}))__ctlTerm(${f.groups.m}.name,${f.groups.m}.environmentId);throw __ctle}`, 'catch(__ctle){throw __ctle}')],
  ['owner-gone loop dropped', (t, f) => {
    const g=f.groups, loop=`for(let ${g.j} of ${g.f})if(!${g.h}.some((__ctlx)=>__ctlx.name===${g.j}.name))__ctlGone(${g.j}.name,${g.j}.environmentId);`;
    return edit(t,loop,'');
  }],
  ['owner-gone arguments swapped', (t, f) => swapArgs(t,'__ctlGone',`${f.groups.j}.name`,`${f.groups.j}.environmentId`)],
  ['owner-gone name comparison broken', (t) => edit(t,'__ctlx.name===','__ctlx.nome===')],
  ['owner-gone generation stringified', (t, f) => {
    const g=f.groups;
    return edit(t,`__ctlGone(${g.j}.name,${g.j}.environmentId)`,`__ctlGone(${g.j}.name,String(${g.j}.environmentId))`);
  }]]);
await a7('Zt settles a module without a hook at once and a hooked one after its start', 'zt1', (f) => {
  const z0 = forms.zt0;
  if (!z0 || z0.groups.R !== f.groups.R || z0.index >= f.index) throw new Error('the two Zt forms are not one loop body');
  const gap = out.slice(z0.index + z0[0].length, f.index);
  if (!new RegExp(`^${ID}$`).test(gap)) throw new Error('the two Zt forms are not adjacent: ' + JSON.stringify(gap.slice(0, 40)));
  f.t1 = gap;
  return out.slice(z0.index, f.index + f[0].length);
}, async (text, f) => {
  const g = f.groups, S = rec(), log = () => {};
  const mods = [{ name: 'a', environmentId: 5, hooks: () => false }, { name: 'b', environmentId: 6, hooks: () => true }];
  bind([['globalThis', { __ctlRequestTextSettle: S }], [forms.zt0.groups.ws, new WeakSet()], [f.t1, log],
    [g.q, () => ({ session: { start: () => Promise.resolve() } })], [g.ne, () => '/'], [g.o, {}], [g.t2, log], [g.l, String],
    ['__ctlMods', mods]], `for(const ${g.R} of __ctlMods){${text}}`);
  const sync = S.calls.slice();
  await new Promise((r) => setTimeout(r, 0));
  return same(sync, [['a', 5]]) && same(S.calls, [['a', 5], ['b', 6]]);
}, [
  ['the no-hook branch argument swap', (t, f) => edit(t, `(${f.groups.R}.name,${f.groups.R}.environmentId);continue}`,
    `(${f.groups.R}.environmentId,${f.groups.R}.name);continue}`)],
  ['the finally generation field replaced', (t, f) => edit(t, `${f.groups.R}.environmentId))`, `${f.groups.R}.generation))`)],
]);
await a7('en settles every initial-load module after session.start, failed or not', 'en1', (f) => {
  const e0 = forms.en0;
  const head = new RegExp(`try\\{await (?<q>${ID})\\(\\)\\.session\\.start\\(\\{cwd:(?<ne>${ID})\\(\\),surface:(?<sf>${ID}),isInteractive:(?<ii>${ID})\\}\\)\\}$`)
    .exec(out.slice(f.index - 400, f.index));
  if (!e0 || !head || e0.index >= f.index) throw new Error('the en try head or capture not found before the settle loop');
  f.head = head.groups;
  return e0[0] + head[0] + f[0];
}, async (text, f) => {
  const g = f.groups, h = f.head, S = rec();
  const lms = [{ name: 'p', environmentId: 1 }, { name: 'q', environmentId: 2 }];
  await bind([['globalThis', { __ctlRequestTextSettle: S }], [forms.en0.groups.ct, () => ({ loadedModules: lms })],
    [h.q, () => ({ session: { start: async () => { throw new Error('start failed'); } } })], [h.ne, () => '/'],
    [h.sf, 'cli'], [h.ii, true], [g.t, () => {}], [g.l, String]], `return (async()=>{${text}})()`);
  return same(S.calls, [['p', 1], ['q', 2]]);
}, [['owner/generation swap', (t) => swapArgs(t, 'globalThis.__ctlRequestTextSettle?.', '__ctlLMs[__ctli].name', '__ctlLMs[__ctli].environmentId')]]);
await a7('zwe: a failed scan check kills the generation, then unloads, then rethrows', 'zwe', (f) => f[0], async (text, f) => {
  const g = f.groups, T = rec(), U = rec(), order = [];
  const run = (fails, unloadThrows) => bind([[g.e, { state: { environmentCounter: 6 } }],
    [g.g, { load: async () => ({ registered: [{ pattern: 'x' }] }),
      unload: () => { order.push('unload'); if (unloadThrows) throw new Error('unload broke'); } }],
    [g.n, { pluginName: 'p', scan: {} }],
    [g.b, () => { if (fails) throw new Error('scan refused'); }],
    ['__ctlTerm', (...a) => { order.push('term'); T(...a); }]], `return (async()=>{let ${text};return "loaded"})()`);
  let r1;
  try { r1 = await run(true, false); } catch (e) { r1 = 'threw ' + (e && e.message); }
  const t1 = T.calls.slice();
  let r2 = 'no throw';
  try { r2 = await run(true, true); } catch (e) { r2 = 'threw ' + (e && e.message); }
  const r3 = await run(false, false);
  return r1 === 'threw scan refused' && same(t1, [['p', 7]]) && order.join(',') === 'term,unload,term,unload' &&
    r2 === 'threw unload broke' && same(T.calls, [['p', 7], ['p', 7]]) && r3 === 'loaded' && T.calls.length === 2;
}, [['owner/generation swap', (t, f) => swapArgs(t, '__ctlTerm', `${f.groups.n}.pluginName`, f.groups.h)]]);
await a7('worker load: a rejected load kills its generation first, a resolved one does not', 'load', (f) => {
  const whole = f[0];
  const at = whole.indexOf('reject:(');
  const rb = f.groups.rb;
  const openAt = whole.indexOf('=>{', at) + 3;
  const closeAt = whole.lastIndexOf('}}');
  return [whole.slice(openAt, closeAt), rb];
}, (text, f) => {
  const g = f.groups, T = rec(), NO = rec(), IL = rec(), deleted = [], order = [];
  const [body, rb] = Array.isArray(text) ? text : [text, 'rb'];
  const reject = bind([['clearTimeout', () => order.push('clear')], [g.tm, 'timer'], [g.no, NO], [g.e, { names: { delete: (k) => { order.push('delete'); deleted.push(k); } } }],
    [g.n, 9], [g.pn, rec()], [g.il, IL], [g.r, { pluginName: 'p' }], ['__ctlTerm', (...a) => { order.push('term'); T(...a); }]],
    'return (' + rb + ')=>{' + body + '}');
  const err = new Error('load refused');
  reject(err);
  return [same(T.calls, [['p', 9]]) && NO.calls.length === 1 && NO.calls[0][0] === err &&
    same(deleted, [9]) && same(IL.calls[0] && IL.calls[0][1], { type: 'unload', environmentId: 9 }) &&
    order.join(',') === 'term,clear,delete',
    'order=' + order.join(',') + ' T=' + JSON.stringify(T.calls)];
}, [['owner/generation swap', (t, f) => { const [body, rb] = t; const g = f.groups; const from = '__ctlTerm(' + g.r + '.pluginName,' + g.n + ')'; const to = '__ctlTerm(' + g.n + ',' + g.r + '.pluginName)'; const b = body.split(from).join(to); return b === body ? null : [b, rb]; }]]);
await a7('reload: a candidate built for a dead host dies before the restore, even a throwing one', 'death', (f) => f.groups.cut, (text, f) => {
  const g = f.groups, T = rec(), order = [];
  const run = (je, weThrows) => bind([[g.We, () => { order.push('restore'); if (weThrows) throw new Error('restore broke'); }],
    [g.xe, { name: 'p', environmentId: 8 }], ['__ctlTerm', (...a) => { order.push('term'); T(...a); }]],
    'return ((' + g.je + ')=>{var __ctlWd=0;' + text + 'Error("died")})(' + (je === undefined ? 'undefined' : JSON.stringify(je)) + ')');
  let r1;
  try { r1 = run('boom', false); } catch (e) { r1 = e instanceof Error && e.message === 'died' ? 'threw died' : 'wrong ' + e; }
  const t1 = T.calls.slice();
  let r2 = 'no throw';
  try { r2 = run('boom', true); } catch (e) { r2 = 'threw ' + (e && e.message); }
  const r3 = run(undefined, false);
  return [r1 === 'threw died' && same(t1, [['p', 8]]) && r2 === 'threw restore broke' && same(T.calls, [['p', 8], ['p', 8]]) && r3 === undefined && order.join(',') === 'term,restore,term,restore',
    r1 + ' / ' + r2 + ' order=' + order.join(',')];
}, [['owner/generation swap', (t, f) => swapArgs(t, '__ctlTerm', `${f.groups.xe}.name`, `${f.groups.xe}.environmentId`)]]);
// CONSTRAINT: run the original load try, including admission, table await,
// publication and finally; a published A must survive B's discard exception.
function ustBody(out, f, ID) {
  const g = f.groups;
  const marker = `${g.e}.state.isSetRecord=!1;try{`;
  const lo = out.lastIndexOf(marker, f.index);
  if (lo < 0 || f.index - lo > 8000) throw new Error('load try head absent');
  const text = out.slice(lo + marker.length - 4, f.index + f[0].length - 1);
  const one = (rx) => { const m = text.match(rx); if (!m) throw new Error('load role absent: '+rx); return m.groups; };
  const roles = {
    ...one(new RegExp(`for\\(let (?<plan>${ID}) of (?<plans>${ID})\\)\\{if\\((?<unchanged>${ID})\\.has\\(\\k<plan>\\.pluginName\\)\\|\\|(?<refused>${ID})\\.has\\(\\k<plan>\\.pluginName\\)\\|\\|(?<failures>${ID})\\.has\\(\\k<plan>\\.pluginName\\)\\)continue;(?<attempted>${ID})\\.add\\(\\k<plan>\\.pluginName\\),(?<prepare>${ID})\\(`)),
    ...one(new RegExp(`let (?<candidate>${ID})=await (?<build>${ID})\\(${g.e},${ID}\\);`)),
    ...one(new RegExp(`${g.St}\\.set\\(${ID}\\.environmentId,${ID}\\),(?<remember>${ID})\\(${ID}\\.pluginName,${g.e}\\),(?<metric>${ID})\\("plugin_function_hooks_load"\\),(?<log>${ID})\\(`)),
    ...one(new RegExp(`events: .\\+(?<patterns>${ID})\\(${ID}\\.patterns\\)`)),
    ...one(new RegExp(`(?<folded>${ID})=await (?<fold>${ID})\\(${g.e},${ID},${ID}\\?(?<initial>${ID})\\(${g.e},${ID}\\.map\\([^;]+?:(?<changed>${ID})\\(${g.e}\\.state,(?<left>${ID}),(?<names>${ID})\\)\\)`)),
    ...one(new RegExp(`let ${ID}=new Map\\(\\[\\.\\.\\.${ID},\\.\\.\\.(?<kept>${ID})\\]\\.map`)),
    ...one(new RegExp(`refused:(?<refusedMods>${ID})\\}=await (?<admit>${ID})\\(${g.e},\\{built:${ID}\\.flatMap\\([^;]+?plugins:(?<plugins>${ID}),seated:(?<seated>${ID})\\}`)),
    ...one(new RegExp(`if\\(await (?<tables>${ID})\\(${g.Nt}\\),`)),
  };
  return {text, roles};
}
async function ustScenario(text, f, roles, bind, mode) {
  const g=f.groups, deaths=new Set(), order=[];
  let unsafe=false;
  const A={name:'A',environmentId:3,label:'A',hopKey:{kind:'fixture'},patterns:[],hooks:()=>false};
  const B={name:'B',environmentId:4,label:'B',hopKey:{kind:'fixture'},patterns:[],hooks:()=>false};
  const holder={loadedModules:[]}, state={unadmitted:new Set()};
  for(const m of [A,B]) m.discard=()=>{
    order.push('discard '+m.name);
    if(!holder.loadedModules.includes(m)&&!deaths.has(m.name)) unsafe=true;
    if((mode==='discard'||mode==='tables-discard')&&m===B) throw new Error('discard B');
  };
  const names=['A','B'];
  if(mode==='ordering') names.flatMap=()=>{throw new Error('ordering failed');};
  const pairs=[[g.s,holder],[g.e,{state}],[g.St,new Map()],
    [roles.plans,[{pluginName:'A'},{pluginName:'B'}]],
    ...['unchanged','refused','failures','attempted','left','seated'].map(k=>[roles[k],new Set()]),
    ...['prepare','remember','metric','log'].map(k=>[roles[k],()=>{}]),
    [roles.build,async(_e,p)=>p.pluginName==='A'?A:B], [roles.patterns,()=> ''],
    [roles.fold,async(_e,a)=>a], [roles.initial,()=>({})], [roles.changed,()=>({})],
    [roles.names,names],[roles.kept,[]],[roles.plugins,new Map()],
    [roles.admit,async()=>{state.unadmitted.delete(3);return {admitted:[A],refused:[]};}],
    [roles.tables,async()=>{if(mode==='tables'||mode==='tables-discard') throw new Error('tables rejected');}],
    [g.P,a=>{holder.loadedModules=a;order.push('publish');}],
    ['__ctlTerm',name=>{deaths.add(name);order.push('term '+name);}]];
  let error;
  try {await bind(pairs,`return (async()=>{${text}})()`);} catch(e){if(e instanceof SyntaxError)throw e;error=e.message;}
  const published=mode==='success'||mode==='discard';
  const expected={success:undefined,discard:'discard B',ordering:'ordering failed',tables:'tables rejected',
    'tables-discard':'discard B'}[mode];
  const discardedAt=order.indexOf('discard B');
  const collective=mode!=='tables-discard'||discardedAt>=0 &&
    order.indexOf('term A')>=0 && order.indexOf('term A')<discardedAt &&
    order.indexOf('term B')>=0 && order.indexOf('term B')<discardedAt &&
    !order.includes('publish');
  return [!unsafe&&collective&&error===expected&&holder.loadedModules.includes(A)===published&&deaths.has('A')===!published&&deaths.has('B'),
    JSON.stringify({mode,error,deaths:[...deaths],published:holder.loadedModules.includes(A),order,unsafe})];
}
// CONSTRAINT: the extracted reload region ends after its publication catch;
// every failure before publication must mark death before exactly one restore.
function reloadBody(out, f, ID) {
  const g=f.groups, rest=out.slice(f.index,f.index+4000);
  const end=rest.match(new RegExp(`catch\\((?<caught>${ID})\\)\\{throw ${g.xe}&&__ctlTerm\\(${g.xe}\\.name,${g.xe}\\.environmentId\\),__ctlWd\\|\\|(?<restore>${ID})\\(\\),\\k<caught>\\}`));
  if(!end)throw new Error('reload publication catch absent');
  const text=rest.slice(0,end.index+end[0].length);
  const one=rx=>{const m=text.match(rx);if(!m)throw new Error('reload role absent: '+rx);return m.groups;};
  const roles={...end.groups,
    ...one(new RegExp(`${g.xe}\\.shown=(?<shown>${ID})\\(${g.F},(?<showarg>${ID})\\),\\[(?<admitted>${ID})\\]=await (?<fold>${ID})\\(${g.n},\\[${g.xe}\\],(?<table>${ID})\\)`)),
    ...one(new RegExp(`buildFailures\\.get\\((?<name>${ID})\\);throw new (?<error>${ID})\\(`)),
    ...one(new RegExp(`let (?<next>${ID})=(?<old>${ID})\\?(?<holder>${ID})\\.loadedModules\\.map\\([^;]+?:(?<ordering>${ID})\\(\\k<holder>\\.loadedModules,${g.xe},(?<rank>${ID})\\);await (?<tables>${ID})\\(\\k<next>\\)`)),
    ...one(new RegExp(`new ${ID}\\((?<format>${ID})\\(${ID}\\)\\)`)),
  };
  return {text,roles};
}
async function reloadScenario(text,f,r,bind,mode){
  const g=f.groups, candidate={name:'A',environmentId:3}, dead=new Set(), order=[];
  const holder={loadedModules:[]}, state={environmentHost:{},buildFailures:new Map()};
  let restores=0,unsafe=false,error;
  const pairs=[[g.n,{state}],[g.F,{}],[r.showarg,{}],[r.table,{}],[r.name,'A'],[r.rank,()=>0],
    [r.old,null],[r.holder,holder],[r.error,Error],[r.format,String],
    [g.sv,async()=>candidate],[r.shown,()=>true],
    [r.fold,async()=>mode==='fold'||mode==='restoreThrow'?[]:[candidate]],
    [r.ordering,(_a,m)=>{if(mode==='ordering')throw new Error('ordering failed');return[m];}],
    [r.tables,async()=>{if(mode==='tables')throw new Error('tables rejected');if(mode==='dead')state.environmentHost.died='host died';}],
    [r.restore,()=>{restores++;order.push('restore');if(!dead.has('A'))unsafe=true;if(mode==='restoreThrow')throw new Error('restore failed');}],
    ['__ctlTerm',name=>{dead.add(name);order.push('term '+name);}]];
  try{await bind(pairs,`return (async()=>{let ${g.xe},${r.admitted};${text}})()`);}catch(e){if(e instanceof SyntaxError)throw e;error=e.message;}
  const success=mode==='success';
  const expected={ordering:'ordering failed',tables:'tables rejected',dead:'host died',restoreThrow:'restore failed',fold:'A: engine.create failed on reload; the previous version stays loaded'}[mode];
  return [!unsafe&&restores===(success?0:1)&&dead.has('A')===!success&&holder.loadedModules.includes(candidate)===success&&error===expected,
    JSON.stringify({mode,error,restores,order,unsafe,published:holder.loadedModules.includes(candidate)})];
}
await a7('USt: ordering, admitted table rejection and throwing discard preserve publication/death order', 'ust', (f) => {
  const body=ustBody(out,f,ID); f.roles=body.roles; return body.text;
}, async (payload, f) => {
  const text = typeof payload === 'object' && payload !== null ? payload.text : payload;
  const modes = (typeof payload === 'object' && payload !== null && payload.modes) ||
    ['success', 'ordering', 'tables', 'discard', 'tables-discard'];
  for(const mode of modes) {
    const result=await ustScenario(text,f,f.roles,bind,mode);
    if(!result[0])return result;
  }
  return true;
}, [['unpublished death dropped', (t,f) => edit(t,`if(!${f.groups.s}.loadedModules.includes(${f.groups.m}))__ctlTerm(`,`if(!1)__ctlTerm(`)],
  ['published generation killed', (t,f) => edit(t,`if(!${f.groups.s}.loadedModules.includes(${f.groups.m}))__ctlTerm(`,`if(!0)__ctlTerm(`)],
  ['admitted death moved after unadmitted discard', (t,f) => {
    const g=f.groups;
    const death=`for(let[${g.k},${g.m}]of ${g.St})if(!${g.s}.loadedModules.includes(${g.m}))__ctlTerm(${g.m}.name,${g.m}.environmentId);`;
    const discard=`for(let[${g.k},${g.m}]of ${g.St})if(${g.e}.state.unadmitted.has(${g.k}))${g.m}.discard()`;
    // CONSTRAINT (#468-FIX7 П1): the split predicate is the admission marker
    // the extracted finally already reads (`e.state.unadmitted.has(k)` in the
    // discard loop), never a candidate name: in `ordering` the set still holds
    // every candidate, so the moved death stays invisible there and the red
    // lands exactly on `tables-discard`.
    const unadmitted=death.replace('if(!',`if(${g.e}.state.unadmitted.has(${g.k})&&!`);
    const admitted=death.replace('if(!',`if(!${g.e}.state.unadmitted.has(${g.k})&&!`);
    const moved=edit(t,`finally{${death}${discard}`,`finally{${unadmitted}${discard};${admitted}`);
    return moved===null?null:{text:moved,modes:['tables-discard'],greenModes:['ordering']};
  }]]);
await a7('reload: executable ordering, tables, empty fold and host-death exits restore exactly once', 'reltry', (f) => {
  const body=reloadBody(out,f,ID); f.roles=body.roles; return body.text;
}, async (text,f) => {
  for(const mode of ['success','ordering','tables','fold','dead','restoreThrow']) {
    const result=await reloadScenario(text,f,f.roles,bind,mode);
    if(!result[0])return result;
  }
  return true;
}, [['restore-once flag dropped', (t) => edit(t,'__ctlWd||','')],
  ['catch death dropped', (t,f) => edit(t,`${f.groups.xe}&&__ctlTerm(${f.groups.xe}.name,${f.groups.xe}.environmentId),`,'')]]);

// #468-FIX4 (Г11): семь вызывающих discard-воронки -- по зубу и мутации на
// сайт: воронка доказана формой disc, здесь доказывается, что вызывающий
// ДОХОДИТ до неё с правильным набором кандидатов.
await a7('admission: a refused unadmitted candidate reaches the discard funnel', 'wcad', (f) => f[0], (text, f) => {
  const g = f.groups, D = rec();
  const run = (unadmitted) => {
    const b = { name: 'p', environmentId: 7, discard: () => D(['p', 7]) };
    bind([[g.E, () => {}], [g.M, {}], [g.e, { state: { unadmitted: { has: () => unadmitted } } }], [g.b, b], [g.h2, []]], text);
    return D.calls.slice();
  };
  const a = run(true);
  run(false);
  const b = D.calls.slice(a.length);
  return [same(a, [[['p', 7]]]) && b.length === 0, 'true=' + JSON.stringify(a) + ' after=' + JSON.stringify(b)];
}, [['the call dropped', (t) => edit(t, '.discard()', ';void 0')],
  ['unadmitted condition dropped', (t, f) => edit(t, `${f.groups.e}.state.unadmitted.has(${f.groups.b}.environmentId)`, 'true')]]);
await a7('load host-death exit: every non-admitted candidate reaches the funnel', 'xeloop', (f) => f.groups.cut, (text, f) => {
  const g = f.groups, D = rec();
  const st = [{ name: 'aa', discard: () => D('aa') }, { name: 'bbb', discard: () => D('bbb') }, { name: 'cccc', discard: () => D('cccc') }];
  bind([[g.st, st], [g.e, (m) => m.name === 'aa'], [g.Ee, () => {}]], text);
  return same(D.calls, [['bbb'], ['cccc']]);
}, [['the call dropped', (t) => edit(t, '.discard()', ';void 0')]]);
await a7('load refold: every non-admitted candidate of the new set reaches the funnel', 'refold', (f) => f.groups.cut, (text, f) => {
  const g = f.groups, D = rec(), added = [];
  const mk = (name) => ({ name, environmentId: name.length, discard: () => D(name) });
  const Nt = [mk('aa'), mk('bbb')];
  bind([[g.Nt, Nt], [g.ft, { add: (n) => { added.push(n); return true; } }], [g.e, (m) => m.name === 'aa']], text);
  return same(D.calls, [['bbb']]) && same(added, ['aa', 'bbb']);
}, [['the call dropped', (t) => edit(t, '.discard()', ';void 0')]]);
await a7('respawn early death: the admitted set reaches the funnel', 'wstdied', (f) => f.groups.cut, (text, f) => {
  const g = f.groups, D = rec();
  const mk = (name) => ({ name, environmentId: name.length, discard: () => D(name) });
  bind([[g.a, [mk('aa'), mk('bbb')]]], 'return ()=>{' + text + ';return "x"}')();
  return same(D.calls, [['aa'], ['bbb']]);
}, [['the call dropped', (t) => edit(t, '.discard()', ';void 0')]]);
await a7('respawn refold: the admitted set is remembered, then reaches the funnel', 'wstwe', (f) => f.groups.cut, (text, f) => {
  const g = f.groups, D = rec(), added = [];
  const mk = (name) => ({ name, environmentId: name.length, discard: () => D(name) });
  bind([[g.ad, [mk('aa'), mk('bbb')]], [g.M, { add: (n) => added.push(n) }]], 'return ()=>{' + text + '}')();
  return same(D.calls, [['aa'], ['bbb']]) && same(added, ['aa', 'bbb']);
}, [['the call dropped', (t) => edit(t, '.discard()', ';void 0')]]);
// #468-FIX4 (Г2): каждая врезка выше мерит ПОРЯДОК: смерть поколения до
// выгрузки/восстановления, и бросающая выгрузка/восстановление её не отменяет.
await a7('discard: the funnel dies the candidate generation before it unloads', 'disc', (f) => 'return ' + f.groups.cut, (text, f) => {
  const g = f.groups, T = rec(), U = rec();
  const fn = bind([[g.n, { pluginName: 'p' }], [g.h, 5], [g.G, U], ['__ctlTerm', T]], text);
  fn();
  return same(T.calls, [['p', 5]]) && same(U.calls, [[]]);
}, [['owner/generation swap', (t, f) => { const b = t.replace(`__ctlTerm(${f.groups.n}.pluginName,${f.groups.h})`, `__ctlTerm(${f.groups.h},${f.groups.n}.pluginName)`); return b === t ? null : b; }]]);
await a7('zwe tail: a post-scan throw dies the generation, unloads, then rethrows', 'ztail', (f) => f.groups.cut, (text, f) => {
  const g = f.groups, T = rec(), U = rec(), order = [];
  const fn = bind([[g.g, { unload: () => { order.push('unload'); U(); } }], [g.h, 7], [g.n, { pluginName: 'p' }],
    ['__ctlTerm', (...a) => { order.push('term'); T(...a); }]], 'return (__ctle)=>{' + text + '}');
  const err = new Error('label threw');
  let out = '';
  try { fn(err); } catch (e) { out = e === err ? 'same' : 'other'; }
  return out === 'same' && same(U.calls, [[]]) && same(T.calls, [['p', 7]]) && order.join(',') === 'term,unload';
}, [['death dropped', (t, f) => { const b = t.replace(`__ctlTerm(${f.groups.n}.pluginName,${f.groups.h}),`, ''); return b === t ? null : b; }]]);
await a7('reload fold: an empty fold dies the generation before the restore', 'xceif', (f) => f.groups.cut, (text, f) => {
  const g = f.groups, T = rec(), W = rec(), order = [];
  bind([[g.Ie, false], [g.We, () => { order.push('restore'); W(); }], [g.xe, { name: 'p', environmentId: 8 }],
    ['__ctlTerm', (...a) => { order.push('term'); T(...a); }]], 'return ()=>{' + text.replace(/let $/, '') + 'let x=1}}')();
  return same(W.calls, [[]]) && same(T.calls, [['p', 8]]) && order.join(',') === 'term,restore';
}, [['owner/generation swap', (t, f) => { const b = t.replace(`__ctlTerm(${f.groups.xe}.name,${f.groups.xe}.environmentId)`, `__ctlTerm(${f.groups.xe}.environmentId,${f.groups.xe}.name)`); return b === t ? null : b; }]]);
await a7('reload build: a throw before the publication dies the generation before the restore-once', 'xcecatch', (f) => f.groups.cut, (text, f) => {
  const g = f.groups, T = rec(), W = rec(), order = [];
  const fn = bind([[g.We, () => { order.push('restore'); W(); }], [g.xe, { name: 'p', environmentId: 9 }],
    ['__ctlTerm', (...a) => { order.push('term'); T(...a); }]],
    'return (' + g.c + ')=>{var __ctlWd=0;' + text.slice(text.indexOf('{') + 1, -1) + '}');
  const err = new Error('build threw');
  let out = '';
  try { fn(err); } catch (e) { out = e === err ? 'same' : 'other'; }
  return out === 'same' && same(W.calls, [[]]) && same(T.calls, [['p', 9]]) && order.join(',') === 'term,restore';
}, [['owner/generation swap', (t, f) => { const b = t.replace(`__ctlTerm(${f.groups.xe}.name,${f.groups.xe}.environmentId)`, `__ctlTerm(${f.groups.xe}.environmentId,${f.groups.xe}.name)`); return b === t ? null : b; }]]);


// --- 3. run the cut-out door and the cut-in expressions on fixtures -----------
unit('fixtures');
if (SEL.has(curUnit)) {
const doorStart = out.indexOf('var __ctlRules=');
const bridge = 'globalThis.__ctlRequestTextSettle=__ctlSettle;';
const doorEnd = out.indexOf(bridge);
ok(doorStart !== -1 && doorEnd !== -1 && doorEnd > doorStart, 'the door text is present in the output');
const doorText = out.slice(doorStart, doorEnd + bridge.length);
ok(!/[\r\n]/.test(doorText), 'the door is one line (minified bundle stays minified)');
// CONSTRAINT (Г4): the door's refusal logger is a PARAMETER here -- the
// spliced door defines `function __ctlLog(s){T(s,{level:"error"})}` beside
// itself in the image, and this cut-out stops before that definition, so the
// battery supplies its own recording stub.
const logLines = [];
const door = new Function('__ctlLog', doorText + ';return {reg:__ctlRegOp,sys:__ctlSys,tools:__ctlTools,list:__ctlListOp,rules:__ctlRules}')((x) => logLines.push(String(x)));

let modSrc = null;
try {
  modSrc = fs.readFileSync(PLUGIN_RULE, 'utf8');
} catch (x) {
  // Г10: a missing neighbour is a LOUD refusal with the path, not 0 teeth.
  console.log(`SWE32 REFUSED=plugin-rule-missing detail=${PLUGIN_RULE} (${String((x && x.code) || x)})`);
  process.exit(2);
}
const rAt = modSrc.indexOf('export const RULE = ');
ok(rAt !== -1, 'the plugin module exports RULE');
let RULE = null;
if (rAt !== -1) {
  const lit = modSrc.slice(rAt + 'export const RULE = '.length);
  const endAt = lit.indexOf('\n}');
  ok(endAt !== -1, 'the RULE literal is closed at column 0');
  if (endAt !== -1) {
    try { RULE = eval('(' + lit.slice(0, endAt + 2) + ')'); } catch { RULE = null; }
  }
}
ok(RULE !== null && RULE.model === 'devin/swe-2' && Array.isArray(RULE.ops) && RULE.ops.length === 6,
  'the RULE literal evaluates to the six-op policy of the plugin');
if (RULE) await door.reg.run(RULE, { plugin: 'catalyst-swe-request', environmentId: 1 });

// The cut-in expressions are executed with the image's own identifiers bound
// to stubs: the door functions come from the cut-out door text, so the exact
// spliced bytes are what runs here.
const SG = sysCut ? sysCut.groups : { sb: 'S', xko: 'X', n1: 'N1', hb: 'HB', vo: 'VO', ls: 'LS' };
const TG = toolsCut ? toolsCut.groups : { cf: 'CF', fo: 'FO', bde: 'BDE' };
const sysExpr = sysCut ? sysCut[0] : '';
const toolsExpr = toolsCut ? toolsCut[0] : '';
const sysFn = new Function('__ctlSys', SG.xko, SG.n1, SG.hb, SG.vo, SG.ls, FN, HN,
  'var ' + SG.sb + ';' + sysExpr + ';return ' + SG.sb);
const toolsFn = new Function('__ctlTools', TG.fo, TG.bde, toolsExpr + ';return ' + TG.cf);

const Z = "You are a Claude agent, built on Anthropic's Claude Agent SDK.";
const MODELS = "- The most recent Claude models are the Claude 5 family and Haiku 4.5. Model IDs — Fable 5.1: 'claude-fable-5-1', Opus 5: 'claude-opus-5', Sonnet 5: 'claude-sonnet-5', Haiku 4.5: 'claude-haiku-4-5-20251001'. When building AI applications, default to the latest and most capable Claude models.";
const EMOJI_IN = 'For clear communication with the user the assistant MUST avoid using emojis.';
const EMOJI_OUT = 'For clear communication with the user, avoid using emojis.';
const READ_FROM = 'Reads a file from the local filesystem. You can access any file directly by using this tool.';
const READ_TAIL = '\nAssume this tool is able to read all files on the machine. If the User provides a path to a file assume that path is valid.';
const CODING = 'You are a coding agent.';
const ENV_IN = `# Environment\n- Claude Code is available as a CLI in the terminal.\n${MODELS}\n- Fast mode for Claude Code uses Claude Opus.`;
const ENV_OUT = '# Environment\n- Claude Code is available as a CLI in the terminal.\n- Fast mode for Claude Code uses Claude Opus.';
const NOTES_IN = `Notes:\n- Agent threads always have their cwd reset between bash calls.\n${EMOJI_IN}\n- Do not use a colon before tool calls.`;
const NOTES_OUT = `Notes:\n- Agent threads always have their cwd reset between bash calls.\n${EMOJI_OUT}\n- Do not use a colon before tool calls.`;

const blocks = () => [
  { type: 'text', text: 'x-anthropic-billing-header: cc_version=2.1.282' },
  { type: 'text', text: Z, cache_control: { type: 'ephemeral' } },
  { type: 'text', text: ENV_IN },
  { type: 'text', text: NOTES_IN },
];
const toolsFx = () => [
  { name: 'Bash', description: 'Executes a bash command', input_schema: {} },
  { name: 'Read', description: READ_FROM + READ_TAIL, input_schema: { type: 'object' } },
];
const FStub = (m) => m;

const runRequest = (model, sysValue, toolsValue) => {
  const H = { model };
  const sys = sysFn(door.sys, () => sysValue, null, null, null, null, FStub, H);
  const cf = toolsFn(door.tools, toolsValue, []);
  return { sys, cf };
};

{ // F1 the real id: identity lines, models line, emoji, Read
  const fx = blocks(), tl = toolsFx();
  const snapS = JSON.parse(JSON.stringify(fx)), snapT = JSON.parse(JSON.stringify(tl));
  const { sys, cf } = runRequest('devin/swe-2', fx, tl);
  ok(sys[0].text === 'x-anthropic-billing-header: cc_version=2.1.282', 'F1: billing block untouched');
  ok(sys[1].text === CODING && JSON.stringify(sys[1].cache_control) === '{"type":"ephemeral"}',
    'F1: identity line replaced, cache_control kept');
  ok(sys[2].text === ENV_OUT, 'F1: models line removed with its LF');
  ok(sys[3].text === NOTES_OUT, 'F1: emoji sentence reworded in place');
  ok(cf[1].description === 'Reads a file from the local filesystem.' + READ_TAIL, 'F1: Read description trimmed');
  ok(cf[0].description === 'Executes a bash command', 'F1: other tool untouched');
  ok(sys !== fx && cf[1] !== tl[1], 'F1: a new system array and a new tool object for the request');
  ok(sys[0] === fx[0] && cf[0] === tl[0], 'F1: untouched block and tool keep identity');
  ok(JSON.stringify(fx) === JSON.stringify(snapS) && JSON.stringify(tl) === JSON.stringify(snapT),
    'F1: the original arrays are not mutated');
  const again = runRequest('devin/swe-2', blocks(), toolsFx());
  ok(again.sys[1].text === CODING && again.cf[1].description === cf[1].description, 'F1: deterministic on fresh inputs');
}
{ // F2 the disguised id reaches the same rules through the door's unmasking
  const { sys, cf } = runRequest('claude-fable-5-dd-' + [...'devin/swe-2'].reverse().join(''), blocks(), toolsFx());
  ok(sys[1].text === CODING && cf[1].description === 'Reads a file from the local filesystem.' + READ_TAIL,
    'F2: disguised id unmasked inside the door');
}
{ // F3 foreign models: the system array comes back by identity, the tools
  // elements are the same objects (the tools container at the source is a
  // fresh spread array by stock construction, so element identity is the
  // honest predicate there)
  for (const m of ['claude-opus-5', 'devin/swe-20', 'devin/swe-2.5', 'glm-5.3', 'claude-fable-5-dd-3.5-mlg', '']) {
    const fx = blocks(), tl = toolsFx();
    const { sys, cf } = runRequest(m, fx, tl);
    ok(sys === fx && cf[0] === tl[0] && cf[1] === tl[1] && cf.length === tl.length &&
       sys[1].text === Z && cf[1].description === READ_FROM + READ_TAIL,
      `F3: ${JSON.stringify(m)} untouched by identity`);
  }
}
{ // F4 id forms that still name swe-2
  for (const m of ['DEVIN/SWE-2', 'devin/swe-2[1m]', ' devin/swe-2 ']) {
    const { sys } = runRequest(m, blocks(), toolsFx());
    ok(sys[1].text === CODING, `F4: ${JSON.stringify(m)} rewritten`);
  }
}
{ // F5 string system with CRLF
  const H = { model: 'devin/swe-2' };
  const strFx = `${Z}\r\n\r\n# Env\r\n${MODELS}\r\n- next line`;
  const sys = sysFn(door.sys, () => strFx, null, null, null, null, FStub, H);
  ok(sys === `${CODING}\r\n\r\n# Env\r\n- next line`, 'F5: string system with CRLF survives');
}
{ // F6 odd shapes must not throw
  let threw = false;
  try {
    const H = { model: 'devin/swe-2' };
    const sys = sysFn(door.sys, () => [null, 7, { type: 'image' }], null, null, null, null, FStub, H);
    toolsFn(door.tools, [null, { name: 'Read' }, { name: 'Read', description: 5 }], []);
    ok(Array.isArray(sys), 'F6: odd blocks come back without a throw');
  } catch { threw = true; }
  ok(!threw, 'F6: odd shapes do not throw');
}

{ // Г4: отказы двери видны в лог хоста -- строка на отказ, принятые молчат
  const R = { model: 'm', ops: [{ find: 'a', to: 'b' }] };
  const before = logLines.length;
  const why = door.reg.check(R, { plugin: 'p' });
  const lines1 = logLines.slice();
  let run = 'accepted';
  door.reg.run(R, { plugin: 'p' }).catch((e) => { run = String(e && e.message || e); });
  await new Promise((r) => setTimeout(r, 0));
  const line = '$.requestText: register refused for p: the caller carries no module generation (environmentId)';
  ok(why === 'the caller carries no module generation (environmentId)' && run === 'the caller carries no module generation (environmentId)' &&
    JSON.stringify(lines1) === JSON.stringify([line]) && logLines.length - before === 2,
    'G4: a refused register writes one host log line per call through the cut-out door');
  const before2 = logLines.length;
  await door.reg.run(R, { plugin: 'p', environmentId: 1 });
  ok(logLines.length === before2, 'G4: an accepted register writes no host log line');
}

}

// --- 4. D7: a revived late writer fails the step loudly ------------------------
unit('late-writer');
if (SEL.has(curUnit)) {
  const rxLateCall = new RegExp(
    `(${ID})\\(${ID},\\{\\.\\.\\.${ID}\\(${ID},${ID}\\(\\)\\),messages:${ID}\\},` +
    `\\{[^{}]*querySource[^{}]*isMainThread[^{}]*\\}\\)`, 'g');
  const call = rxLateCall.exec(image);
  ok(call !== null, 'D7: the late-writer call site exists in the pristine image');
  if (call) {
    const defRe = new RegExp(`function ${call[1]}\\(${ID},${ID},${ID}\\)\\{return\\}`);
    const def = image.match(defRe);
    ok(def !== null && image.split(def[0]).length === 2,
      'D7: the late-writer stub is a unique empty return in the pristine image');
    if (def && image.split(def[0]).length === 2) {
      // CONSTRAINT: the late writer is step 32's guard, and this second
      // build re-runs the patch on a modified pristine; switching every other
      // step off keeps that build's edit chain short enough to fit the memory
      // budget beside the first build's output still held by the battery.
      const off32 = names.filter((n) => n !== '32 request text for devin/swe-2');
      const scripted32 = src.replace(anchor, `const STEPS_OFF = ${JSON.stringify(off32)};`);
      const revived = image.replace(def[0], def[0].replace('{return}', '{return e}'));
      let err = null;
      let summary2 = '';
      console.error = (...a) => { summary2 += a.join(' ') + '\n'; };
      try { new Function('js', scripted32)(revived); } catch (e) { err = e; }
      finally { console.error = quiet; }
      ok(err !== null && /late writer/.test(String(err && err.message)),
        'D7: a non-empty stub body fails the step with the late-writer reason');
    }
  }
}
// --- 5. Г3: hooks-модуль плагина живёт в СВОЁМ vm-контексте --------------------
// Мост двери -- свойство globalThis ГЛАВНОГО контекста; проверка вызывающего
// не нужна, если песочница его не видит. Доказательство двуногое: структурные
// иглы на образе (контекст создан из Object.create(null), модуль компилируется
// SourceTextModule-ом в ЭТОТ контекст) и исполнение node:vm на такой же
// конструкции.
unit('sandbox');
if (SEL.has(curUnit)) {
  const vm = await import('node:vm');
  const ctxFactory = image.match(/var (?<wa>[A-Za-z_$][\w$]*)=\(\)=>Object\.create\(null\);/);
  ok(ctxFactory !== null && image.split(ctxFactory[0]).length === 2,
    'G3 sandbox: the empty-prototype context factory is unique in the image');
  const ctxBuild = ctxFactory && image.match(new RegExp(
    `let (?<t>[A-Za-z_$][\\w$]*)=${rxEsc(ctxFactory.groups.wa)}\\(\\),(?<o>[A-Za-z_$][\\w$]*)=(?<vmn>[A-Za-z_$][\\w$]*)\\.createContext\\(\\k<t>,\\{codeGeneration:\\{strings:!1,wasm:!1\\}\\}\\);`));
  ok(ctxBuild !== null && image.split(ctxBuild[0]).length === 2,
    'G3 sandbox: the hooks context is a createContext of that factory with code generation off');
  const modCompile = ctxBuild && image.match(new RegExp(
    `new (?<On>[A-Za-z_$][\\w$]*)\\.SourceTextModule\\((?<arg>[A-Za-z_$][\\w$]*)\\((?<inner>[A-Za-z_$][\\w$]*)\\((?<h>[A-Za-z_$][\\w$]*),(?<v>[A-Za-z_$][\\w$]*)\\),\\k<h>,[A-Za-z_$][\\w$]*\\),\\{context:${rxEsc(ctxBuild.groups.o)},identifier:`));
  ok(modCompile !== null && image.split(modCompile[0]).length === 2,
    'G3 sandbox: hooks modules compile as SourceTextModule into that context');
  // CONSTRAINT: the host's globals assignment must run after its context
  // factory. Testing an empty context alone cannot detect a supplied bridge.
  const installPattern = /if\((?<enabled>[A-Za-z_$][\w$]*)\)Object\.assign\((?<globals>[A-Za-z_$][\w$]*),\{[^;]*?setTimeout:(?<timer>[A-Za-z_$][\w$]*)\(!1\),setInterval:\k<timer>\(!0\),clearTimeout:(?<clear>[A-Za-z_$][\w$]*),clearInterval:\k<clear>,console:(?<console>[A-Za-z_$][\w$]*)\((?<wrap>[A-Za-z_$][\w$]*),`\[\$\{(?<plugin>[A-Za-z_$][\w$]*)\}\]`\)\}\);/g;
  const installers = [...image.matchAll(installPattern)];
  ok(installers.length === 1, 'G3 sandbox: the host globals installer is unique');
  // CONSTRAINT (#468-FIX7 П3): the duplicate goes into the IMAGE text beside
  // its original and the uniqueness locator re-runs over the whole mutated
  // image — a stitched pair of extracted fragments never exercised the real
  // locator's count.
  const duplicateRed = installers.length === 1 && (() => {
    const at = installers[0].index + installers[0][0].length;
    const mutated = image.slice(0, at) + installers[0][0] + image.slice(at);
    return [...mutated.matchAll(installPattern)].length !== 1;
  })();
  ok(installers.length === 1 && duplicateRed,
    'G3 sandbox: duplicating the installer reddens its uniqueness check');
  console.log(`A7-MUTATION ${duplicateRed ? 'RED' : 'NOT-RED'} sandbox: duplicated installer`);
  if (ctxFactory && ctxBuild && installers.length === 1) {
    const installer = installers[0], g = installer.groups, c = ctxBuild.groups;
    const factoryReturn = image.match(new RegExp(`return\\{globals:(?<globals>${ID}),context:(?<context>${ID}),makers:`));
    const installerLink = image.match(new RegExp(`,\\{globals:(?<globals>${ID}),context:(?<context>${ID}),vmCall:[^{}]*\\}=(?<from>${ID});`));
    // CONSTRAINT (#468-FIX7 П2): the wrapper locator is extended by content to
    // the installer's FULL call, arguments included — `isInstallingGlobals`
    // and its neighbours — so the executed text carries the flag itself; a
    // locator ending at `host:` could not see a changed argument.
    const factoryCall = image.match(new RegExp(
      `function (?<wrapper>${ID})\\((?<we>${ID}),(?<wt>${ID}),(?<wo>${ID})=\\{\\}\\)\\{let (?<hit>${ID})=(?<cache>${ID})\\(\\k<we>\\.modulePath\\);` +
      `if\\(\\k<hit>\\)return \\k<hit>\\(\\k<we>,\\k<wt>,\\k<wo>\\);let (?<bare>${ID})=(?<factory>${ID})\\(\\k<we>\\.pluginRoot\\);` +
      `return (?<install>${ID})\\(\\{bare:\\k<bare>,args:\\k<we>,host:\\k<wt>,bounds:\\k<wo>,isInstallingGlobals:(?<flag>[^,]*),` +
      `loaded:\\((?<stamped>${ID})\\)=>(?<loadedFn>${ID})\\(\\{args:\\k<we>,context:\\k<bare>\\.context,` +
      `intoEnvironment:\\k<bare>\\.intoEnvironment,stamped:\\k<stamped>\\}\\)\\}\\)\\}`));
    const installerSig = factoryCall && image.match(new RegExp(
      `async function ${rxEsc(factoryCall.groups.install)}\\(\\{bare:(?<sb>${ID}),args:(?<at>${ID}),host:(?<oh>${ID}),` +
      `bounds:(?<br>${ID})=\\{\\},loaded:(?<ld>${ID}),isInstallingGlobals:(?<en>${ID})\\}\\)\\{`));
    // CONSTRAINT (#468-FIX8, gpt6 F1): the factory's parameter is any
    // identifier — a literal minified name would refuse a neutral rename.
    const headOf = (img) => new RegExp(`function ${rxEsc(factoryCall.groups.factory)}\\(${ID}\\)\\{${rxEsc(ctxBuild[0])}`).test(img);
    const factoryHead = factoryCall && headOf(image);
    const renamed = factoryCall && image.replace(new RegExp(`function ${rxEsc(factoryCall.groups.factory)}\\(${ID}\\)\\{(?=${rxEsc(ctxBuild[0])})`),
      `function ${factoryCall.groups.factory}(zzRenamedParam){`);
    const literalHead = (img) => img.includes(`function ${factoryCall.groups.factory}(e){${ctxBuild[0]}`);
    ok(factoryCall !== null && renamed !== image && headOf(renamed),
      'G3 sandbox: the factory head is found under a renamed parameter');
    const renameRed = factoryCall !== null && renamed !== image && !literalHead(renamed);
    console.log(`A7-MUTATION ${renameRed ? 'RED' : 'NOT-RED'} sandbox: literal factory parameter refuses a rename`);
    ok(factoryReturn !== null && image.split(factoryReturn[0]).length === 2 &&
      installerLink !== null && image.split(installerLink[0]).length === 2 &&
      factoryCall !== null && image.split(factoryCall[0]).length === 2 && factoryHead &&
      installerSig !== null && image.split(installerSig[0]).length === 2 &&
      factoryReturn.groups.globals === c.t && factoryReturn.groups.context === c.o &&
      installerLink.groups.globals === g.globals &&
      installerLink.groups.from === installerSig.groups.sb &&
      installerSig.groups.en === g.enabled && factoryCall.groups.flag === '!0',
      'G3 sandbox: factory return feeds the host globals installer through its wrapper');
    // CONSTRAINT (#468-FIX7 П2): the extracted WRAPPER bytes are executed —
    // the factory and the installer run called FROM them, so the enable flag
    // travels the real path; the manual [enabled, true] stand is gone. The
    // remaining entries are only the image-scope helpers the installer body
    // reads (timer factory, clear, console factory, plugin label); the
    // factory's `makers` tail stays unextracted and `wrapMethod` is supplied
    // on the bare result for the console call only.
    const runInstalled = (text, returned = factoryReturn[0], wrapper = factoryCall[0]) => {
      const make = new Function(c.vmn, 'globalThis', ctxFactory[0] + ctxBuild[0] +
        returned.slice(0, -',makers:'.length) + '};');
      const factory = () => {
        const made = make(vm, Object.create(null));
        made.wrapMethod = fn => fn;
        return made;
      };
      const entries = new Map([[c.vmn, vm], [factoryCall.groups.factory, factory],
        [g.timer, () => () => {}], [g.clear, () => {}], [g.console, () => ({log() {}})],
        [g.plugin, 'fixture']]);
      const program = new Function(...entries.keys(),
        installerSig[0] + 'let' + installerLink[0].slice(1) + text +
        'return ' + installerLink.groups.context + ';}' +
        'function ' + factoryCall.groups.cache + '(k){return void 0}' + wrapper +
        'return ' + factoryCall.groups.wrapper + '({pluginRoot:{},modulePath:"fx"},{state:{}},{})');
      return program(...entries.values()).then((context) =>
        vm.runInContext('[typeof __ctlRequestTextSettle, typeof setTimeout, typeof console.log]', context));
    };
    const prior = Object.getOwnPropertyDescriptor(globalThis, '__ctlRequestTextSettle');
    try {
      Object.defineProperty(globalThis, '__ctlRequestTextSettle', {value: () => {}, configurable: true});
      const result = await runInstalled(installer[0]);
      ok(result[0] === 'undefined' && result[1] === 'function' && result[2] === 'function',
        'G3 sandbox: the bridge is unavailable after the actual globals installation');
      const mutant = installer[0].replace(`Object.assign(${g.globals},{`,
        `Object.assign(${g.globals},{__ctlRequestTextSettle:globalThis.__ctlRequestTextSettle,`);
      const red = mutant !== installer[0] && (await runInstalled(mutant))[0] !== 'undefined';
      ok(red, 'G3 sandbox: supplying the bridge in the actual installer reddens isolation');
      console.log(`A7-MUTATION ${red ? 'RED' : 'NOT-RED'} sandbox: bridge supplied by installer`);
      const changedReturn = factoryReturn[0].replace(`globals:${c.t}`, 'globals:globalThis');
      const returnRed = changedReturn !== factoryReturn[0] &&
        (await runInstalled(installer[0], changedReturn))[1] !== 'function';
      ok(returnRed, 'G3 sandbox: a changed factory return breaks the installed context');
      console.log(`A7-MUTATION ${returnRed ? 'RED' : 'NOT-RED'} sandbox: factory globals return changed`);
      const wrapperMut = factoryCall[0].replace('isInstallingGlobals:!0', 'isInstallingGlobals:!1');
      const flagRed = wrapperMut !== factoryCall[0] &&
        (await runInstalled(installer[0], factoryReturn[0], wrapperMut))[1] !== 'function';
      ok(flagRed, 'G3 sandbox: turning isInstallingGlobals off in the wrapper stops the installation');
      console.log(`A7-MUTATION ${flagRed ? 'RED' : 'NOT-RED'} sandbox: isInstallingGlobals off in the wrapper`);
    } finally {
      if (prior) Object.defineProperty(globalThis, '__ctlRequestTextSettle', prior);
      else delete globalThis.__ctlRequestTextSettle;
    }
  }
}

// CONSTRAINT: юнит, не запустивший ни одного утверждения, -- отказ: `--scope
// <unit>` мог бы называть юнит, который ничего не мерит.
const missingUnits = [...SEL].filter((n) => !ran.has(n));
if (missingUnits.length) {
  console.log(`SWE32 REFUSED=units-drift detail=no assertion ran for ${missingUnits.join(',')}`);
  process.exit(2);
}
console.log(`SWE32 scope=${[...SEL].join(',')} PASS=${pass} FAILED=${failed}`);
process.exit(failed === 0 ? 0 : 1);
