#!/usr/bin/env node
// Teeth of patch step 33 (turn.step tool chunk id), run against the REAL
// image: the step's locator must find exactly one `case"tool"` arm there, the
// output must differ from the image in that arm and nowhere else, and the
// validator function taken from the output must accept devin's `call_…#…` id
// while still refusing empty and whitespace-bearing ids. The same function
// taken from the UNPATCHED image is the mutation control: it must refuse the
// devin id, or the tooth has no bite. CONSTRAINT: the image is read as
// latin-1 so byte offsets stay honest; the other steps are switched off
// through the same STEPS_OFF channel the pipeline uses.
//   node tools/swe33-teeth.mjs [--image <claude binary>]
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const PATCH = path.join(HERE, '..', 'tweakcc-patch.js');
const argv = process.argv.slice(2);
const at = argv.indexOf('--image');
const IMAGE = at !== -1 ? argv[at + 1] : path.join(process.env.HOME ?? '', '.local', 'bin', 'claude');
const STEP = '33 turn.step tool chunk id';

let pass = 0, failed = 0;
const ok = (cond, name) => { if (cond) { pass++; } else { failed++; console.log(`  FAIL ${name}`); } };

// --- 1. run ONLY step 33 on the real image ---------------------------------
const src = fs.readFileSync(PATCH, 'utf8');
const names = [...src.matchAll(/^step\('([^']+)'/gm)].map(m => m[1]);
ok(names.includes(STEP), 'step 33 is declared in tweakcc-patch.js');
const off = names.filter(n => n !== STEP);
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
ok(/applied 1 edits:/.test(summary) && summary.includes(STEP), 'summary reports exactly step 33 applied');

// --- 2. the output differs in the tool arm and nowhere else ------------------
const OLD_RX = '/^[\\w-]+$/', NEW_RX = '/^\\S+$/';
const OLD_MSG = '"{ index, id, name } (an id of letters, digits, _ or -)"';
const NEW_MSG = '"{ index, id, name } (a non-empty id without whitespace)"';
ok(out.length === image.length + (NEW_RX.length - OLD_RX.length) + (NEW_MSG.length - OLD_MSG.length),
  `output length moved by exactly the two replacements (${out.length - image.length})`);
let head = 0; while (head < image.length && image[head] === out[head]) head++;
let tail = 0; while (tail < image.length - head && image[image.length - 1 - tail] === out[out.length - 1 - tail]) tail++;
// The common prefix runs into the regexp and the common suffix into the
// message, so the changed span is narrower than the arm: the window around
// it must hold the arm's head, the old pair on the image side and the new
// pair on the output side.
const changed = image.length - tail - head;
ok(changed > 0 && changed < 200, `the changed span is one arm, not a region (${changed} chars)`);
const winIn = image.slice(head - 120, image.length - tail + 40), winOut = out.slice(head - 120, out.length - tail + 40);
ok(winIn.includes('case"tool":return ') && winIn.includes(OLD_RX) && winIn.includes(OLD_MSG),
  'the single changed span sits in the tool arm of the validator');
ok(winOut.includes('case"tool":return ') && winOut.includes(NEW_RX) && winOut.includes(NEW_MSG) && !winOut.includes(OLD_RX) && !winOut.includes(OLD_MSG),
  'the changed arm carries the new regexp and the new message only');
ok(out.split(NEW_MSG).length === 2, 'the new message occurs exactly once in the output');
ok(image.split(OLD_RX).length === out.split(OLD_RX).length + 1, 'exactly one occurrence of the old regexp left the bundle; the others stand');

// --- 3. run the validator taken from the output, and from the image ---------
const ID = '[A-Za-z_$][\\w$]*';
const fnRx = new RegExp(
  `function (${ID})\\((${ID})\\)\\{let (${ID})=typeof \\2\\.index==="number"&&\\2\\.index>=0;switch\\(\\2\\.kind\\)\\{` +
  `case"text":case"thinking":return \\3&&typeof \\2\\.text==="string"\\?void 0:"\\{ index, text \\}";case"tool":[^]{0,900}?` +
  `default:return"known kind \\(text, thinking, tool, input, stop, engine\\)"\\}\\}`, 'g');
const take = (text, tag) => {
  const found = [...text.matchAll(fnRx)];
  ok(found.length === 1, `${tag}: the chunk-shape validator is found exactly once (${found.length})`);
  if (found.length !== 1) return null;
  return new Function(`${found[0][0]};return ${found[0][1]};`)();
};
const patched = take(out, 'output');
const stock = take(image, 'image');
const DEVIN = 'call_b55511b292e54d4abacddfb9#64b90bc174714d2aba716bcbd6fdfbe6';
const tool = (id, extra = {}) => ({ kind: 'tool', index: 1, id, name: 'Read', ...extra });
if (patched) {
  ok(patched(tool(DEVIN)) === undefined, 'patched: devin call_…#… id passes');
  ok(patched(tool('toolu_01ABCdef-xyz')) === undefined, 'patched: a stock id still passes');
  ok(patched(tool('a/b:c.d')) === undefined, 'patched: punctuation without whitespace passes');
  const msg = '{ index, id, name } (a non-empty id without whitespace)';
  ok(patched(tool('')) === msg, 'patched: empty id refused with the new message');
  for (const bad of ['a b', 'a\tb', 'a\nb', ' x', 'x ']) ok(patched(tool(bad)) === msg, `patched: whitespace id ${JSON.stringify(bad)} refused`);
  ok(patched(tool(7)) === msg && patched({ kind: 'tool', index: 1, id: DEVIN }) === msg, 'patched: non-string id and missing name refused');
  ok(patched(tool(DEVIN, { index: -1 })) === msg && patched(tool(DEVIN, { index: 'x' })) === msg, 'patched: a bad index still refused');
  ok(patched({ kind: 'text', index: 0, text: 'x' }) === undefined && patched({ kind: 'text', index: 0 }) === '{ index, text }', 'patched: the text arm is untouched');
  ok(patched({ kind: 'input', index: 1, json: '{' }) === undefined && patched({ kind: 'engine', ref: 3 }) === undefined, 'patched: input and engine arms untouched');
  ok(patched({ kind: 'nope' }) === 'known kind (text, thinking, tool, input, stop, engine)', 'patched: the default arm is untouched');
}
if (stock) { // mutation control: the tooth bites on the stock validator
  ok(stock(tool(DEVIN)) === '{ index, id, name } (an id of letters, digits, _ or -)', 'control: the stock validator refuses the devin id');
  ok(stock(tool('toolu_01ABCdef-xyz')) === undefined, 'control: the stock validator passes a stock id');
}
console.log(`SWE33 PASS=${pass} FAILED=${failed}`);
process.exit(failed === 0 ? 0 : 1);
