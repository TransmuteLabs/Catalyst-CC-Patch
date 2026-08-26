// Parsing the injected code BEFORE the image build. The injection breaks
// silently: the patcher itself is syntactically intact, while a program glued
// from hundreds of string pieces may not parse at all — and that is visible
// only on the live binary.
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(
  path.join(__dirname, '..', 'tweakcc-patch.js'), 'utf8');

// Pieces are cut out by anchors, not by bracket balancing: anchors are
// adjacent declarations, they change together with the code and do not drift
// apart silently. A COMMENT anchor does not have this property: moving the
// comment elsewhere in the file leaves the check without its piece, and exit 2
// goes unnoticed while nobody calls it. That happened three times. The third
// was the plainest: the last anchor here still pointed at a comment, the
// comment was translated to English, and the anchor stopped matching text that
// no longer existed. Rewording is not a code change, so nothing warned. Every
// anchor below is now a declaration, and a comment must never become one
// again — a comment is prose and prose gets edited for reasons that have
// nothing to do with this file.
const parts = [
  ['core', '  const core =', '  const judgeCall ='],
  ['judgeCall', '  const judgeCall =', '  const watchCall ='],
  ['watchCall', '  const watchCall =', '  const resolveFor ='],
];

let total = '';
const sizes = [];
const vals = {};
for (const [name, from, to] of parts) {
  const a = src.indexOf(from);
  const b = src.indexOf(to, a);
  if (a < 0 || b < 0) { console.error('ЯКОРЬ НЕ НАЙДЕН: ' + name); process.exit(2); }
  // The piece tail is the comment of the next declaration: the anchor sits on
  // the declaration line, not on its first character. Stripped before parsing.
  const expr = src.slice(a + from.length, b)
    .replace(/(?:\s*(?:\/\/[^\n]*|\/\*[\s\S]*?\*\/))*\s*$/, '')
    .trim().replace(/;$/, '');
  // External patcher names: filled in with plausible minified ones.
  // Free patcher names (minified names found by locators, escapers) are stubbed
  // IN BULK via the scope: listing them one by one means fixing this check on
  // every new locator.
  //
  // But the stub is given ONLY to names the patcher declares somewhere.
  // A stub for everything silently swallows a typo and a nonexistent name —
  // that is exactly how a literal `esc` once got in here: the piece "parsed",
  // while on a live run the patcher would crash with ReferenceError.
  const declared = new Set(
    [...src.matchAll(/\b(?:const|let|var|function)\s+([A-Za-z_$][\w$]*)/g)]
      .map((m) => m[1]));
  const scope = new Proxy({}, {
    has: (_t, k) => typeof k === 'string',
    get: (_t, k) => {
      // `with` asks the scope itself for @@unscopables — that is not a name
      // from the piece, and answering it with a throw means crashing the check
      // right there.
      if (typeof k === 'symbol') return undefined;
      if (!declared.has(k)) {
        throw new ReferenceError('свободное имя, нигде не объявленное: ' + k);
      }
      return /Esc$/.test(k) ? (x) => x : k;
    },
  });
  const val = new Function('__scope', 'with(__scope){return (' + expr + ')}')(scope);
  if (typeof val !== 'string') { console.error('НЕ СТРОКА: ' + name); process.exit(2); }
  sizes.push(name + '=' + val.length);
  vals[name] = val;
  total += val;
}

// The consumer's own scope was checked here by hand for a while, and the
// re-implementation is gone: resolving scopes is a compiler's job, and the
// hand-written one proved it by calling six names free on its first run --
// they were the tail of a single `let a=…,b=…,c=…` chain it did not read to
// the end. The question it asked is now asked below, of tsc, which does not
// have to be taught what a declaration list is.
//
// The structural half of the rule -- a consumer must never NAME something
// private to the core, even where the name would happen to resolve -- is not
// dropped with it: it is checked on the finished image, in the build's
// 'consumers do not reach into the core'.

// The tool-call slots are the same ones the patcher fills in.
const resolved = total.replace(/\$([1-9])/g, (_, d) => '__slot' + d);
try {
  new Function('__slot1', '__slot2', '__slot3', '__slot4', '__slot5',
    '"use strict";return (async()=>{' + resolved + '})');
} catch (e) {
  console.error('ВКЛЕИВАЕМЫЙ КОД НЕ РАЗБИРАЕТСЯ: ' + e.message);
  process.exit(1);
}
console.log('ВКЛЕИВАЕМЫЙ КОД РАЗБИРАЕТСЯ; ' + sizes.join(', ') +
  ', всего ' + resolved.length);

// A name the block does not declare has to come from the site it is spliced
// into. Whether it does is a scope question, and scope questions belong to a
// compiler. The block is already valid JavaScript, so it can be handed to one
// as it stands: no build step, not one shipped byte changed, and no regex of
// ours pretending to resolve scopes.
//
// It is asked exactly one thing -- does every name resolve -- because that is
// the class that has cost this file four incidents: `__pdir` read from a
// neighbouring block, and `__jlog`/`__clip` reached for across the core's
// boundary, where the record they were supposed to write could never be
// written. Both parse perfectly; a free name is a RUNTIME error, and the lines
// holding them are failure handlers, which is to say lines nobody reaches
// until the day they matter.
//
// Types are a different question and are deliberately not asked: the host is
// untyped, and the answers would be noise that trains a human to skip the
// output.
//
// tools/site.d.ts is the contract -- everything the site provides, written
// down. A name that stops being provided turns red here instead of at the
// moment the failure handler finally runs.
const os = require('os');
const { spawnSync } = require('child_process');
const NAME_ERRORS = /error TS(2304|2552|2584|2591):/;
const tsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'cc-scope-'));
try {
  const blockPath = path.join(tsDir, 'block.js');
  fs.writeFileSync(blockPath, `async function __spliceSite(){\n${resolved}\n}\n`);
  const tsc = spawnSync('tsc', [
    '--noEmit', '--allowJs', '--checkJs',
    '--target', 'es2022', '--lib', 'es2022',
    '--module', 'esnext', '--moduleResolution', 'bundler',
    '--skipLibCheck', '--noImplicitAny', 'false',
    path.join(__dirname, 'site.d.ts'), blockPath,
  ], { encoding: 'utf8' });
  // A check that quietly skips itself is the shape this file has been bitten
  // by three times already, so a missing compiler is a failure, not a notice.
  if (tsc.error) {
    console.error('ПРОВЕРКА ИМЁН НЕ ВЫПОЛНЕНА: tsc не запустился (' +
      (tsc.error.code === 'ENOENT' ? 'не найден; установить: brew install typescript'
                                   : tsc.error.message) + ')');
    process.exit(2);
  }
  const unresolved = String(tsc.stdout || '')
    .split('\n')
    .filter((line) => NAME_ERRORS.test(line));
  if (unresolved.length) {
    console.error('ИМЕНА, КОТОРЫЕ НЕ РАЗРЕШАЮТСЯ В ОБЛАСТИ ВКЛЕЙКИ:');
    for (const line of unresolved) {
      console.error('  ' + line.split(path.sep).pop());
    }
    process.exit(1);
  }
  console.log('ВСЕ ИМЕНА ВО ВКЛЕИВАЕМОМ КОДЕ РАЗРЕШАЮТСЯ');
} finally {
  fs.rmSync(tsDir, { recursive: true, force: true });
}

// A line-end anchor inside the injected code's own regexes is NOT a slot,
// and warning about it means training yourself to ignore noise. The dangerous
// form is different: String.replace replacement sequences ($&, $`, $', $0),
// which would substitute someone else's capture silently if the text ended up
// on the replacement side. That class has already bitten this patcher, which
// is why it is the one being checked.
const stray = total.match(/\$[&`'0]/g);
if (stray) {
  console.error('ЗАМЕЩАЮЩИЕ ПОСЛЕДОВАТЕЛЬНОСТИ В ТЕЛЕ: ' + stray.join(' '));
  process.exit(1);
}

// The frame is what the model actually reads, and it has THREE producers: the
// pool path builds it inline, the template path's fallback builds it again,
// and body.json carries it as a template. They drifted once and it was not
// caught by anything: body.json said "=== ДИСПАТЧ ===" while both built-ins
// said "=== DISPATCH ===", and worse, the template had no {{LABEL}} at all —
// so the truncation notice, which lives in the header and nowhere else, was
// dropped on that path. A trimmed payload reached the model looking whole.
// The bench cannot see this: it drives the pool path only, and standing up an
// HTTP receiver to reach the template path costs more than the invariant is
// worth. So the invariant is asserted as text, here, where the pipeline
// already calls us.
const BUILTIN_FRAME = '"=== SESSION SO FAR ===\\n"+__cx+"\\n\\n=== "+__lbl+" ==='
  + '\\n"+__disp';
const builtins = total.split(BUILTIN_FRAME).length - 1;
if (builtins !== 2) {
  console.error('РАМКА: встроенных вхождений ' + builtins + ', ожидалось 2 '
    + '(pool и запасное тело обязаны нести один текст)');
  process.exit(1);
}
const TEMPLATE_FRAME =
  '=== SESSION SO FAR ===\n{{CONTEXT}}\n\n=== {{LABEL}} ===\n{{DISPATCH}}';
const bodyPath = path.join(__dirname, '..', 'probes', 'judge', 'body.json');
const bodyUser = JSON.parse(fs.readFileSync(bodyPath, 'utf8'))
  .messages.find((m) => m.role === 'user');
if (!bodyUser || bodyUser.content !== TEMPLATE_FRAME) {
  console.error('РАМКА: шаблон в probes/judge/body.json разошёлся со встроенным;'
    + ' получено ' + JSON.stringify(bodyUser && bodyUser.content));
  process.exit(1);
}
console.log('РАМКА ОДИНАКОВА НА ВСЕХ ТРЁХ ПУТЯХ');
