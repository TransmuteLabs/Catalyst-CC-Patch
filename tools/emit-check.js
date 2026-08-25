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
// goes unnoticed while nobody calls it. That happened both times.
const parts = [
  ['core', '  const core =', '  const judgeCall ='],
  ['judgeCall', '  const judgeCall =', '  const watchCall ='],
  ['watchCall', '  const watchCall =', '  // Вклейка по СМЕЩЕНИЮ'],
];

let total = '';
const sizes = [];
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
  total += val;
}

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
