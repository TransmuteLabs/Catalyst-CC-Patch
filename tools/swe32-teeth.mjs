#!/usr/bin/env node
// Teeth of patch step 32 (request text for devin/swe-2), run against the REAL
// image: the step's locator must find exactly one request-body site there,
// and the code it emits must perform the four text edits on fixtures shaped
// like the live body -- and nothing else. CONSTRAINT: the image is read as
// latin-1 so byte offsets stay honest; the other steps are switched off
// through the same STEPS_OFF channel the pipeline uses, so this exercises
// the real step body, not a copy of it.
//   node tools/swe32-teeth.mjs [--image <claude binary>]
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const PATCH = path.join(HERE, '..', 'tweakcc-patch.js');
const argv = process.argv.slice(2);
const at = argv.indexOf('--image');
const IMAGE = at !== -1 ? argv[at + 1] : path.join(process.env.HOME ?? '', '.local', 'bin', 'claude');
const STEP = '32 request text for devin/swe-2';

let pass = 0, failed = 0;
const ok = (cond, name) => { if (cond) { pass++; } else { failed++; console.log(`  FAIL ${name}`); } };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// --- 1. run ONLY step 32 on the real image ---------------------------------
const src = fs.readFileSync(PATCH, 'utf8');
const names = [...src.matchAll(/^step\('([^']+)'/gm)].map(m => m[1]);
ok(names.includes(STEP), 'step 32 is declared in tweakcc-patch.js');
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
ok(/applied 1 edits:/.test(summary) && summary.includes('32 request text for devin/swe-2'), 'summary reports exactly step 32 applied');
ok(out.length > image.length, 'the output grew');
const begins = out.split('/*swe32*/').length - 1, ends = out.split('/*swe32-end*/').length - 1;
ok(begins === 1 && ends === 1, `exactly one emitted block (begin=${begins}, end=${ends})`);
const ID = '[A-Za-z_$][\\w$]*';
const site = new RegExp(`let (${ID})=\\{model:(${ID})\\((${ID})\\.model\\),messages:[\\s\\S]{0,4000}?;/\\*swe32\\*/\\1=\\(function\\(__r\\)\\{[\\s\\S]*?\\}\\)\\(\\1\\);/\\*swe32-end\\*/(${ID})=(${ID})&&\\1\\.messages\\.some\\(`).exec(out);
ok(site !== null, 'emitted block sits between the body literal and the statement that reads <rf>.messages');
const rfName = site ? site[1] : 'rf';
const emitted = out.slice(out.indexOf('/*swe32*/'), out.indexOf('/*swe32-end*/') + '/*swe32-end*/'.length);
ok(!/[\r\n]/.test(emitted), 'emitted code is one line (minified bundle stays minified)');

// --- 2. run the emitted code on fixtures ------------------------------------
const rewrite = new Function(rfName, `${emitted}\nreturn ${rfName};`);
const Z = "You are a Claude agent, built on Anthropic's Claude Agent SDK.";
const L = "You are Claude Code, Anthropic's official CLI for Claude.";
const X = "You are Claude Code, Anthropic's official CLI for Claude, running within the Claude Agent SDK.";
const MODELS = "- The most recent Claude models are the Claude 5 family and Haiku 4.5. Model IDs — Fable 5.1: 'claude-fable-5-1', Opus 5: 'claude-opus-5', Sonnet 5: 'claude-sonnet-5', Haiku 4.5: 'claude-haiku-4-5-20251001'. When building AI applications, default to the latest and most capable Claude models.";
const READ_FROM = 'Reads a file from the local filesystem. You can access any file directly by using this tool.';
const READ_TAIL = '\nAssume this tool is able to read all files on the machine. If the User provides a path to a file assume that path is valid.';
const env = `# Environment\n- Claude Code is available as a CLI in the terminal.\n${MODELS}\n- Fast mode for Claude Code uses Claude Opus.`;
const body = (model, sys, tools) => ({ model, messages: [{ role: 'user', content: 'hi' }], system: sys, tools, tool_choice: { type: 'auto' }, max_tokens: 1 });
const blocks = () => [
  { type: 'text', text: 'x-anthropic-billing-header: cc_version=2.1.278' },
  { type: 'text', text: Z, cache_control: { type: 'ephemeral' } },
  { type: 'text', text: env },
];
const tools = () => [
  { name: 'Bash', description: 'Executes a bash command', input_schema: {} },
  { name: 'Read', description: READ_FROM + READ_TAIL, input_schema: { type: 'object' } },
];
const expectRewritten = (r, tag) => {
  ok(r.system[0].text === 'x-anthropic-billing-header: cc_version=2.1.278', `${tag}: billing block untouched`);
  ok(r.system[1].text === 'You are a coding agent.' && same(r.system[1].cache_control, { type: 'ephemeral' }), `${tag}: identity prefix replaced, cache_control kept`);
  ok(r.system[2].text === '# Environment\n- Claude Code is available as a CLI in the terminal.\n- Fast mode for Claude Code uses Claude Opus.', `${tag}: models line removed with its LF`);
  ok(r.tools[1].description === 'Reads a file from the local filesystem.' + READ_TAIL, `${tag}: Read description trimmed`);
  ok(r.tools[0].description === 'Executes a bash command', `${tag}: other tool untouched`);
};
{ // F1 real id, array system
  const sys = blocks(), tl = tools(), snapS = JSON.parse(JSON.stringify(sys)), snapT = JSON.parse(JSON.stringify(tl));
  const b = body('devin/swe-2', sys, tl);
  const r = rewrite(b);
  ok(r === b, 'F1: returns the body it was given');
  expectRewritten(r, 'F1');
  ok(r.system !== sys && r.tools !== tl, 'F1: new arrays on the body');
  ok(r.system[0] === sys[0] && r.tools[0] === tl[0], 'F1: untouched blocks and tools keep identity');
  ok(same(sys, snapS) && same(tl, snapT), 'F1: the original arrays are not mutated');
  ok(r.messages.length === 1 && r.tool_choice.type === 'auto' && r.max_tokens === 1, 'F1: other body fields untouched');
  const again = rewrite(r);
  ok(again.system[1].text === 'You are a coding agent.' && again.tools[1].description === r.tools[1].description, 'F1: idempotent');
}
{ // F2 disguised id
  const r = rewrite(body('claude-fable-5-dd-' + [...'devin/swe-2'].reverse().join(''), blocks(), tools()));
  expectRewritten(r, 'F2 (disguised id)');
}
{ // F3 other models: untouched, identity preserved
  for (const m of ['claude-opus-5', 'devin/swe-20', 'devin/swe-2.5', 'glm-5.3', 'claude-fable-5-dd-3.5-mlg', '', undefined]) {
    const sys = blocks(), tl = tools();
    const r = rewrite(body(m, sys, tl));
    ok(r.system === sys && r.tools === tl && r.system[1].text === Z && r.tools[1].description === READ_FROM + READ_TAIL, `F3: ${JSON.stringify(m)} untouched`);
  }
}
{ // F4 id forms that still name swe-2
  for (const m of ['DEVIN/SWE-2', 'devin/swe-2[1m]', ' devin/swe-2 ']) {
    const r = rewrite(body(m, blocks(), tools()));
    ok(r.system[1].text === 'You are a coding agent.', `F4: ${JSON.stringify(m)} rewritten`);
  }
}
{ // F5 string system, CRLF, prefix L, models line in the middle
  const r = rewrite(body('devin/swe-2', `${L}\r\n\r\n# Env\r\n${MODELS}\r\n- next line`, []));
  ok(r.system === 'You are a coding agent.\r\n\r\n# Env\r\n- next line', 'F5: string system with CRLF');
}
{ // F6 models line last, no terminator; prefix X; leading spaces before the dash
  const r = rewrite(body('devin/swe-2', [{ type: 'text', text: `${X}\n# Env\n  ${MODELS}` }], undefined));
  ok(r.system[0].text === 'You are a coding agent.\n# Env', 'F6: last line removed with the LF before it');
  const r2 = rewrite(body('devin/swe-2', [{ type: 'text', text: MODELS }], undefined));
  ok(r2.system[0].text === '', 'F6: a block that is only the models line becomes empty');
  const r3 = rewrite(body('devin/swe-2', [{ type: 'text', text: `${MODELS}\nafter` }], undefined));
  ok(r3.system[0].text === 'after', 'F6: first-line removal takes its LF');
}
{ // F7 near-misses stay
  const r = rewrite(body('devin/swe-2', [{ type: 'text', text: `${Z} Extra words.\nThe most recent Claude models are X` }], [{ name: 'Read', description: 'Other text. ' + READ_FROM }]));
  ok(r.system[0].text === `${Z} Extra words.\nThe most recent Claude models are X`, 'F7: prefix with extra words and an undashed models sentence stay');
  ok(r.tools[0].description === 'Other text. Reads a file from the local filesystem.', 'F7: Read sentence replaced wherever it occurs');
}
{ // F8 shapes that must not throw
  for (const s of [undefined, null, 42, [null, 7, { type: 'image' }]]) {
    let threw = false;
    try { rewrite(body('devin/swe-2', s, [null, { name: 'Read' }, { name: 'Read', description: 5 }])); } catch { threw = true; }
    ok(!threw, `F8: system ${JSON.stringify(s)} and odd tools do not throw`);
  }
}
{ // F9 the subagent "Notes" line (4th edit): exact sentence reworded in place, neighbours and cache_control kept
  const NOTES = 'Notes:\n- Agent threads always have their cwd reset between bash calls.\n- For clear communication with the user the assistant MUST avoid using emojis.\n- Do not use a colon before tool calls.';
  const FIXED = 'Notes:\n- Agent threads always have their cwd reset between bash calls.\n- For clear communication with the user, avoid using emojis.\n- Do not use a colon before tool calls.';
  const r = rewrite(body('devin/swe-2', [{ type: 'text', text: `${Z}\n\n${NOTES}\n\n<total_tokens>1</total_tokens>`, cache_control: { type: 'ephemeral', ttl: '1h' } }], []));
  ok(r.system[0].text === `You are a coding agent.\n\n${FIXED}\n\n<total_tokens>1</total_tokens>`, 'F9: Notes line reworded in place, neighbours kept');
  ok(same(r.system[0].cache_control, { type: 'ephemeral', ttl: '1h' }), 'F9: cache_control kept');
  const r2 = rewrite(body('devin/swe-2', 'For clear communication with the user the assistant MUST avoid using emojis. Extra', []));
  ok(r2.system === 'For clear communication with the user, avoid using emojis. Extra', 'F9: string system, sentence replaced wherever it occurs');
  const r3 = rewrite(body('devin/swe-2', [{ type: 'text', text: 'For clear communication with the user the assistant must avoid using emojis.' }], []));
  ok(r3.system[0].text === 'For clear communication with the user the assistant must avoid using emojis.', 'F9: near-miss (lowercase must) stays');
  const sys = [{ type: 'text', text: NOTES }];
  const r4 = rewrite(body('glm-5.3', sys, []));
  ok(r4.system === sys && r4.system[0].text === NOTES, 'F9: other model keeps the Notes line');
}
console.log(`SWE32 PASS=${pass} FAILED=${failed}`);
process.exit(failed === 0 ? 0 : 1);
