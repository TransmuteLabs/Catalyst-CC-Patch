#!/usr/bin/env node
// Teeth of patch step 35 (the StatusLine render site), run against the REAL
// image. The step's five locators must find exactly one site each there; the
// output must differ from the input in exactly five contiguous spans — the
// two table rows, the live pace, the layout slot and the inserted site
// component; the emitted component must parse and answer every
// hooked/configured combination with the hook order constant; each locator
// must fail BY ITS OWN site name when its anchor is spoiled; and the stock
// slot form must be gone from the output while present once in the input.
// CONSTRAINT: the image is read as latin-1 so byte offsets stay honest; the
// other steps are switched off through the same STEPS_OFF channel the
// pipeline uses, so this exercises the real step body, not a copy of it.
// CONSTRAINT: the default --image is the PRISTINE 2.1.282 — the active
// binary already carries the patch and is not this battery's subject.
//   node tools/statusline35-teeth.mjs [--image <claude binary>]
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));
const PATCH = path.join(HERE, '..', 'tweakcc-patch.js');
const argv = process.argv.slice(2);
const at = argv.indexOf('--image');
const PRISTINE = path.join(process.env.HOME ?? '', '.local', 'share', 'catalyst-cc', 'pristine');
const IMAGE = at !== -1 ? argv[at + 1] : path.join(PRISTINE, '2.1.282.orig');
const OLD280 = path.join(PRISTINE, '2.1.280.orig');
const STEP = '35 StatusLine render site';
// The teeth count is pinned: a tooth lost in an edit is a refusal, not a
// shorter green run.
const EXPECTED_TEETH = 6;

const ID = '[A-Za-z_$][\\w$]*';
const SITE_TOKENS = ['component table', 'surface table', 'live pace', 'layout slot', 'render hooks namespace'];
const results = [];
const tooth = (name, outcome, detail = '') => {
  if (outcome === true) results.push(`  PASS ${name}`);
  else if (outcome === false) results.push(`  FAIL ${name}${detail ? ' — ' + detail : ''}`);
  else results.push(`  ${outcome}${detail ? ' — ' + detail : ''}`);
};

// --- harness: run ONLY step 35 over a given bundle text ----------------------
const src = fs.readFileSync(PATCH, 'utf8');
const names = [...src.matchAll(/^step\('([^']+)'/gm)].map(m => m[1]);
if (!names.includes(STEP)) { console.log('[REFUSED] step 35 is not declared in tweakcc-patch.js'); process.exit(2); }
const off = names.filter(n => n !== STEP);
const anchor = 'const STEPS_OFF = [];';
if (src.split(anchor).length !== 2) { console.log('[REFUSED] STEPS_OFF anchor is not unique'); process.exit(2); }
const scripted = src.replace(anchor, `const STEPS_OFF = ${JSON.stringify(off)};`);

const runStep = (text) => {
  const quiet = console.error; let summary = '';
  console.error = (...a) => { summary += a.join(' ') + '\n'; };
  let out;
  try { out = new Function('js', scripted)(text); } finally { console.error = quiet; }
  return { out, summary };
};

// --- the battery's OWN locators: the brief's anchors, not the step's ---------
const findSites = (text) => {
  const one = (rx, tag) => {
    const all = [...text.matchAll(rx)];
    if (all.length !== 1) throw new Error(`${tag}: expected exactly 1 site, found ${all.length}`);
    return all[0];
  };
  const comp = one(/PromptHint:"PromptHintSite",AbovePrompt:"AbovePromptSite",Pane:"PaneSite"\}/g, 'component table');
  const surf = one(new RegExp(`AbovePrompt:\\["terminal","desktop"\\],Pane:(${ID})\\}`, 'g'), 'surface table');
  const pace = one(new RegExp(`(${ID})=(${ID})\\.component==="PromptHint",`, 'g'), 'live pace');
  const slot = one(new RegExp(
    `(${ID})==="prompt"&&!(${ID})\\.show&&!(${ID})&&(${ID})&&(${ID})\\((${ID}),\\{transcript:(${ID}),vimMode:(${ID})\\}\\)`, 'g'), 'layout slot');
  const ns = one(new RegExp(`(${ID})\\.useRenderInput\\("PromptHint",`, 'g'), 'render hooks namespace');
  const windowStart = Math.max(0, slot.index - 6000);
  const fns = [...text.slice(windowStart, slot.index).matchAll(new RegExp(`function (${ID})\\(`, 'g'))];
  if (fns.length === 0) throw new Error('layout function boundary: no function declaration in the window');
  const fnAt = windowStart + fns[fns.length - 1].index;
  return { comp, surf, pace, slot, ns, fnAt };
};

const buildExpected = (sites, text) => {
  const { comp, surf, pace, slot, ns, fnAt } = sites;
  const UL = ns[1], CE = slot[5], SL = slot[6], CONF = slot[4], TR = slot[7], VIM = slot[8];
  const decl =
    `function __ctlStatusLineSite(__ctlP){var __ctlC=__ctlP.configured,` +
    `__ctlH=${UL}.useHasRenderHooks("StatusLine"),` +
    `__ctlIn=${UL}.useRenderInput("StatusLine",()=>({requestId:"status-line",props:{configured:__ctlC}}),[__ctlC]),` +
    `__ctlD=${UL}.useRenderDrawing(__ctlIn,()=>__ctlC?${CE}(${SL},{transcript:__ctlP.transcript,vimMode:__ctlP.vimMode}):null);` +
    `return __ctlH?__ctlD.node:__ctlC?${CE}(${SL},{transcript:__ctlP.transcript,vimMode:__ctlP.vimMode}):null}`;
  const edits = [
    ['S1', comp.index + comp[0].length - 1, comp.index + comp[0].length - 1, ',StatusLine:"StatusLineSite"'],
    ['S2', surf.index + surf[0].length - 1, surf.index + surf[0].length - 1, ',StatusLine:["terminal"]'],
    ['S3', pace.index, pace.index + pace[0].length,
      `${pace[1]}=${pace[2]}.component==="PromptHint"||${pace[2]}.component==="StatusLine",`],
    ['S4', slot.index, slot.index + slot[0].length,
      `${slot[1]}==="prompt"&&!${slot[2]}.show&&!${slot[3]}&&${CE}(__ctlStatusLineSite,{configured:${CONF},transcript:${TR},vimMode:${VIM}})`],
    ['FN', fnAt, fnAt, decl],
  ].sort((a, b) => b[1] - a[1]);
  let out = text;
  for (const e of edits) out = out.slice(0, e[1]) + e[3] + out.slice(e[2]);
  return { out, edits };
};

try {
  const stat = fs.statSync(IMAGE);
  const image = fs.readFileSync(IMAGE, 'latin1');
  if (image.length !== stat.size) { console.log('[REFUSED] image read as latin-1 lost bytes'); process.exit(2); }
  const sites = findSites(image);
  const { out: runOut, summary } = runStep(image);

  // T1: the step applied with its witness line.
  tooth('T1 the step applied and its witness line names the site', runOut !== undefined && typeof runOut === 'string'
    && /applied 1 edits:/.test(summary) && summary.includes('35 StatusLine render site:'));

  // T2: the output differs from the input in exactly five contiguous spans —
  // the battery rebuilds the output from the input with its own five splices
  // and requires equality, so a sixth change anywhere breaks it.
  const expected = buildExpected(sites, image);
  const ordered = expected.edits.every((e, i, a) => i === 0 || a[i - 1][1] >= e[2]);
  tooth('T2 the output differs in exactly the five spans (S1, S2, S3, S4, function), disjoint and ordered',
    runOut === expected.out && ordered,
    runOut === expected.out ? '' : `rebuild mismatch (ordered=${ordered})`);

  // T3: the emitted site component parses and answers every hooked x
  // configured combination; the three hooks are called in a constant order
  // whatever the flags are, and with no hooks the result is the stock shape.
  const fnHead = 'function __ctlStatusLineSite(';
  const fnStart = runOut.indexOf(fnHead);
  let t3 = fnStart !== -1;
  if (t3) {
    let depth = 0, i = runOut.indexOf('{', fnStart), fnEnd = -1, inStr = null;
    for (; i < runOut.length; i++) {
      const c = runOut[i];
      if (inStr) { if (c === '\\') i++; else if (c === inStr) inStr = null; continue; }
      if (c === '"' || c === "'") inStr = c;
      else if (c === '{') depth++;
      else if (c === '}') { depth--; if (depth === 0) { fnEnd = i + 1; break; } }
    }
    t3 = fnEnd !== -1;
    if (t3) {
      const decl = runOut.slice(fnStart, fnEnd);
      const UL = /([\w$]+)\.useRenderInput\("StatusLine",/.exec(decl)?.[1];
      const pair = new RegExp(`(${ID})\\((${ID}),\\{transcript:`).exec(decl);
      const CE = pair?.[1], SL = pair?.[2];
      t3 = UL === sites.ns[1] && CE === sites.slot[5] && SL === sites.slot[6];
      if (t3) {
        const body = decl.split(`${UL}.`).join('UL.').split(`${CE}(${SL},`).join('CE(SL,')
          + ';return __ctlStatusLineSite;';
        const siteFn = new Function('UL', 'CE', 'SL', body);
        const PROPS = { transcript: 'TR-35', vimMode: true };
        const mk = (hooked) => {
          const calls = [];
          const ULs = {
            useHasRenderHooks: () => { calls.push('has'); return hooked; },
            useRenderInput: () => { calls.push('input'); return { requestId: 'status-line' }; },
            useRenderDrawing: () => { calls.push('draw'); return { node: 'HOOKED' }; },
          };
          return [ULs, calls];
        };
        const CEf = (t, p) => ({ t, p });
        const cases = [
          [false, false, null, ['has', 'input', 'draw']],
          [false, true, { t: 'ENGINE', p: { transcript: PROPS.transcript, vimMode: PROPS.vimMode } }, ['has', 'input', 'draw']],
          [true, false, 'HOOKED', ['has', 'input', 'draw']],
          [true, true, 'HOOKED', ['has', 'input', 'draw']],
        ];
        for (const [hooked, configured, want, wantCalls] of cases) {
          const [ULs, calls] = mk(hooked);
          const r = siteFn(ULs, CEf, 'ENGINE')({ configured: configured, ...PROPS });
          t3 = t3 && JSON.stringify(r) === JSON.stringify(want) && JSON.stringify(calls) === JSON.stringify(wantCalls);
        }
      }
    }
  }
  tooth('T3 the emitted component parses and answers hooked x configured with a constant hook order', t3);

  // T4: the same step on the pristine of the older line — applied or a NAMED
  // refusal, both lawful; an unnamed crash is the red outcome. No image on
  // this machine is NOT-MEASURED and never counts as green.
  if (!fs.existsSync(OLD280)) {
    tooth('T4 the step on the pristine 2.1.280 applies or refuses by name', 'NOT-MEASURED 2.1.280 (нет образа)');
  } else {
    let line = null, lawful = true;
    try {
      const r = runStep(fs.readFileSync(OLD280, 'latin1'));
      lawful = /applied 1 edits:/.test(r.summary) && r.summary.includes(STEP);
      line = lawful ? 'applied' : 'no witness in an otherwise quiet run';
    } catch (e) {
      const msg = String(e.message);
      const stepLines = msg.split('\n').filter(l => l.includes(`- ${STEP}:`));
      lawful = stepLines.length > 0 && stepLines.every(l => SITE_TOKENS.some(t => l.includes(t))
        || l.includes('layout function') || l.includes('status-line consumer'));
      line = stepLines[0]?.trim() ?? msg.split('\n')[0];
    }
    tooth('T4 the step on the pristine 2.1.280 applies or refuses by name', lawful, `measured: ${line}`);
  }

  // T5: the locator teeth — spoil each site's anchor with a single
  // replacement and demand the failure names THAT site and no other.
  {
    const spoils = [
      ['S1', 'component table',
        sites.comp[0], sites.comp[0].replace('Pane:"PaneSite"', 'Pane:"PaneSitX"')],
      ['S2', 'surface table',
        'AbovePrompt:["terminal","desktop"],Pane:', 'AbovePrompt:["terminal","desktoX"],Pane:'],
      ['S3', 'live pace',
        sites.pace[0], sites.pace[0].replace('"PromptHint"', '"PromptHinX"')],
      ['S4', 'layout slot',
        sites.slot[0], sites.slot[0].replace('==="prompt"', '==="promptX"')],
      ['S5', 'render hooks namespace',
        `${sites.ns[1]}.useRenderInput("PromptHint",`, `${sites.ns[1]}.useRenderInput("PromptHinX",`],
    ];
    // S3b: the pace test stays, but the selector it feeds moves into the NEXT function —
    // the test no longer decides the pace, and the step must refuse by the pace name.
    {
      const pAt = image.indexOf(sites.pace[0]);
      const SEL = '?"live":"steady"}';
      const selEnd = image.indexOf(SEL, pAt) + SEL.length;
      const region = image.slice(pAt, selEnd);
      spoils.push(['S3b', 'live pace', region,
        region.slice(0, -SEL.length) + '?"steady":"steady"}function __ctlProbeOtherPace(){return !0?"live":"steady"}']);
    }
    // F1–F3: the layout function boundary guards — the region from the last
    // `function NAME(` before the slot to the slot's end, spoiled three ways.
    {
      const sAt = image.indexOf(sites.slot[0]);
      const fnAt = image.lastIndexOf('function ', sAt);
      const region = image.slice(fnAt, sAt + sites.slot[0].length);
      const slotOff = sAt - fnAt;
      spoils.push(['F1', 'layout function boundary', region, '0,' + region]);
      spoils.push(['F2', 'layout function boundary', region,
        region.slice(0, slotOff) + 'function (){};' + region.slice(slotOff)]);
      spoils.push(['F3', 'layout function is not the status-line consumer', region,
        region.split('.statusLine;').join('.statusLinE;')]);
    }
    let t5 = true, t5detail = '';
    for (const [id, token, spoilAnchor, spoilText] of spoils) {
      if (image.split(spoilAnchor).length !== 2) { t5 = false; t5detail += ` ${id}:anchor-count`; continue; }
      let threw = null;
      try { runStep(image.replace(spoilAnchor, spoilText)); } catch (e) { threw = String(e.message); }
      const others = SITE_TOKENS.filter(t => t !== token);
      const good = threw !== null && threw.includes(`- ${STEP}: StatusLine site: ${token}`)
        && !others.some(t => threw.includes(`StatusLine site: ${t}`));
      if (!good) { t5 = false; t5detail += ` ${id}:${threw === null ? 'no-throw' : 'wrong-name'}`; }
    }
    tooth('T5 each spoiled anchor makes the step refuse by its own site name', t5, t5detail.trim());
  }

  // T6: the stock slot form is gone from the output and present once in the input.
  const stockRx = /==="prompt"&&![\w$]+\.show&&![\w$]+&&[\w$]+&&[\w$]+\([\w$]+,\{transcript:/g;
  tooth('T6 the stock slot form occurs once in the input and never in the output',
    (image.match(stockRx) ?? []).length === 1 && (runOut.match(stockRx) ?? []).length === 0);
} catch (x) {
  console.log(`[REFUSED] ${String(x && x.message || x)}`);
  process.exit(2);
}

for (const line of results) console.log(line);
const pass = results.filter(l => l.startsWith('  PASS')).length;
const failed = results.filter(l => l.startsWith('  FAIL')).length;
const notmeasured = results.filter(l => l.includes('NOT-MEASURED')).length;
if (results.length !== EXPECTED_TEETH) {
  console.log(`[REFUSED] teeth count ${results.length} != EXPECTED_TEETH ${EXPECTED_TEETH}`);
  process.exit(2);
}
console.log(`STATUSLINE35 PASS=${pass} FAILED=${failed} NOT-MEASURED=${notmeasured} TEETH=${results.length}`);
process.exit(failed === 0 ? 0 : 1);
