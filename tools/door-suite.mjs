// Extraction and execution of the `$.requestText` door for the two batteries
// beside this file (`door-teeth.mjs`, `door-mutations.mjs`).
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { createHash } from 'crypto';

// CONSTRAINT: путь к генератору выводится от СОБСТВЕННОГО файла батареи
// (import.meta.url), НЕ от каталога запуска: относительный путь делает
// батарею зелёной лишь из одного cwd.
export const GENERATOR = fileURLToPath(new URL('../tweakcc-patch.js', import.meta.url));

// CONSTRAINT: каждый отказ несёт СВОЁ имя — два отказа с одним кодом
// неразличимы; имя печатается вызывающей батареей в строку REFUSED=.
export class DoorSuiteError extends Error {
  constructor(failName, detail) {
    super(failName + (detail ? ': ' + detail : ''));
    this.failName = failName;
    this.detail = detail || '';
  }
}

export function generatorSha256() {
  try {
    // CONSTRAINT: дайджест считается по БАЙТАМ образа генератора — текстовый
    // режим чтения изменил бы длину и сделал сверку до/после ложной.
    return createHash('sha256').update(readFileSync(GENERATOR)).digest('hex');
  } catch (x) {
    throw new DoorSuiteError('generator-missing', GENERATOR + ' (' + String((x && x.code) || x) + ')');
  }
}

export function doorParts() {
  let src;
  try {
    src = readFileSync(GENERATOR, 'utf8');
  } catch (x) {
    throw new DoorSuiteError('generator-missing', GENERATOR + ' (' + String((x && x.code) || x) + ')');
  }
  const m = src.match(/const door = \[\n([\s\S]*?)\n  \]\.join\(''\);/);
  if (!m) throw new DoorSuiteError('door-array-not-extracted', 'no `const door = [ ... ].join()` in ' + GENERATOR);
  let elements;
  try {
    elements = eval('[' + m[1] + ']');
  } catch (x) {
    throw new DoorSuiteError('door-array-not-extracted', 'the array literal does not evaluate: ' + String((x && x.message) || x));
  }
  if (!Array.isArray(elements) || elements.length === 0 || elements.some((e) => typeof e !== 'string')) {
    throw new DoorSuiteError('door-array-not-extracted', 'not a non-empty array of strings');
  }
  return { elements, code: elements.join('') };
}

export function doorCode() {
  return doorParts().code;
}

export function assertDoorSyntax(code) {
  try {
    new Function(code);
  } catch (x) {
    throw new DoorSuiteError('door-code-syntax', String((x && x.message) || x));
  }
  return code;
}

export function buildDoor(code) {
  return new Function(
    code + ';return {reg:__ctlRegOp,unreg:__ctlUnregOp,list:__ctlListOp,apply:__ctlApply,rules:__ctlRules,remove:__ctlRemove}',
  )();
}

// CONSTRAINT: ЕДИНСТВЕННЫЙ дом зубов двери — обе батареи рядом
// (`door-teeth.mjs`, `door-mutations.mjs`) читают ИМЕННО этот перечень. Два
// несовпадающих набора зубов одного предмета означают, что мутационный
// контроль меряет не тот набор, который объявлен зелёным (замерено 22.09).
// CONSTRAINT: мутационная фаза правит текст двери В ПАМЯТИ — `run` получает
// код аргументом и никогда не пишет в генератор.
// CONSTRAINT: перечень результатов имеет ПОСТОЯННУЮ длину при любом исходе —
// зуб, существующий только в ветке отказа, делает число зубов переменным, и
// «столько же зелёных» перестаёт отличаться от «часть не исполнялась».
export async function run(code) {
  const d = buildDoor(code);
  const C = (p) => ({ plugin: p });
  const results = [];
  const t = (name, ok, extra = '') => { results.push({ name, ok: !!ok, extra: String(extra) }); };

  t('T1 op typo key refused', /unknown key "flgs"/.test(String(d.reg.check({ model: 'm', ops: [{ pattern: '^a$', flgs: 'gm', to: 'b' }] }, C('a')) || '')));
  t('T2 rule extra key refused', /unknown key "extra"/.test(String(d.reg.check({ model: 'm', ops: [{ find: 'a', to: 'b' }], extra: 1n }, C('a')) || '')));
  t('T2b good rule accepted', d.reg.check({ model: 'devin/swe-2', ops: [{ find: 'a', to: 'b' }] }, C('p')) === undefined);

  const live = { model: 'devin/swe-2', ops: [{ find: 'a', to: 'b' }] };
  await d.reg.run(live, C('p'));
  live.model = 'EDITED'; live.ops[0].to = 'ZZZ';
  let ls = null, ls2 = null, listThrew = '';
  try { ls = await d.list.run(); ls2 = await d.list.run(); } catch (e) { listThrew = String((e && e.message) || e); }
  t('T3d list does not throw', listThrew === '', listThrew);
  t('T3 snapshot at registration', ls && ls.rules[0].rule.model === 'devin/swe-2' && ls.rules[0].rule.ops[0].to === 'b', ls ? JSON.stringify(ls.rules[0].rule) : 'no list');
  t('T3b no JSON.stringify in door', (code.match(/JSON\.stringify/g) || []).length === 0);
  t('T3c list returns fresh object', !!(ls && ls2 && ls2.rules[0].rule !== ls.rules[0].rule));

  await d.reg.run({ model: 'DEVIN/SWE-2', ops: [{ find: 'q', to: 'r' }] }, C('p'));
  t('T6 case-insensitive upsert', d.rules.length === 1, 'len=' + d.rules.length);

  const id = d.rules[0].id;
  t('T5a foreign unregister refused', d.unreg.check({ id }, C('other')) === 'the id belongs to another plugin');
  t('T5b unknown id passes check', d.unreg.check({ id: 'nobody:x' }, C('other')) === undefined);
  t('T5c unknown id removes nothing', (await d.unreg.run({ id: 'nobody:x' }, C('other'))).removed === false);
  t('T5d signature text', /unregister takes a non-empty string id/.test(String(d.unreg.check({ id: '' }, C('p')) || '')));
  t('T5e remove guards owner', d.remove(id, 'other').removed === false && d.rules.length === 1);

  await d.unreg.run({ id }, C('p'));
  await d.reg.run({ model: 'devin/swe-2', ops: [
    { pattern: '^You are Claude Code\\.$', flags: 'gm', to: 'You are a coding agent.' },
    { pattern: 'a', flags: 'y', to: 'X' },
    { tool: 'Read', find: 'Reads a file.', to: 'Short.' }] }, C('p'));
  const r1 = d.apply({ model: 'devin/swe-2', system: 'x\r\nYou are Claude Code.\r\ny' }, 'devin/swe-2');
  t('T8 CRLF kept + rewritten', r1.system === 'x\r\nYou are a coding agent.\r\ny', JSON.stringify(r1.system));
  const sticky = ['a', 'a', 'a'].map((s) => d.apply({ model: 'devin/swe-2', system: s }, 'devin/swe-2').system);
  t('T9 sticky lastIndex reset', sticky.join('/') === 'X/X/X', sticky.join('/'));
  const fa = [{ type: 'text', text: 'You are Claude Code.' }], b2 = { model: 'claude-opus-4', system: fa };
  const r2 = d.apply(b2, 'claude-opus-4');
  t('T7a foreign model untouched', r2 === b2 && r2.system === fa);
  const na = [{ type: 'text', text: 'nothing here' }], tl = [{ name: 'Read', description: 'untouched' }];
  const r3 = d.apply({ model: 'devin/swe-2', system: na, tools: tl }, 'devin/swe-2');
  t('T7b unchanged system keeps identity', r3.system === na, 'container replaced');
  t('T7c unchanged tools keep identity', r3.tools === tl, 'container replaced');
  const r4 = d.apply({ model: 'devin/swe-2', system: [{ type: 'text', text: 'You are Claude Code.' }], tools: [{ name: 'Read', description: 'Reads a file. More.' }] }, 'devin/swe-2');
  t('T8b array block rewritten', r4.system[0].text === 'You are a coding agent.', r4.system[0].text);
  t('T8c tool rewritten', r4.tools[0].description === 'Short. More.', r4.tools[0].description);

  t('T10 frozen refuses register', /frozen/.test(String(d.reg.check({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, C('p')) || '')));
  let st = null, stThrew = '';
  try { st = await d.list.run(); } catch (e) { stThrew = String((e && e.message) || e); }
  t('T10b counters observable', !!(st && st.frozen === true && st.seen > 0 && st.changed > 0),
    stThrew || JSON.stringify(st && { f: st.frozen, s: st.seen, c: st.changed }));
  return results;
}

// CONSTRAINT: имена зубов — контракт между домом и мутационной батареей:
// мутация называет ОЖИДАЕМЫЙ зуб точным именем, и батарея проверяет, что
// такое имя вообще существует (опечатка иначе молча делает мутацию красной
// по чужому зубу).
export function teethNames(results) {
  return results.map((r) => r.name);
}

// CONSTRAINT: отказ батареи печатается ИМЕНЕМ и выходит кодом 2 — код 1
// закреплён за красным зубом, иначе два разных исхода неразличимы.
export function refuse(prefix, x) {
  if (x instanceof DoorSuiteError) {
    console.log(`${prefix} REFUSED=${x.failName} detail=${x.detail}`);
    process.exit(2);
  }
  throw x;
}
