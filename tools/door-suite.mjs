// Extraction and execution of the `$.requestText` door for the two batteries
// beside this file (`door-teeth.mjs`, `door-mutations.mjs`).
import { readFileSync } from 'fs';
import { fileURLToPath, pathToFileURL } from 'url';
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

// CONSTRAINT: дом применяет правила в ДВУХ источниках запроса — system
// (`__ctlSys`) и tools (`__ctlTools`); settle-мост живёт на globalThis и
// читается оттуда, не экспортом (в образе его зовёт чужой сегмент).
// CONSTRAINT: `term` и `gone` берутся через `typeof`: дверь без одной из
// врезок обязана давать КРАСНЫЕ зубы поимённо, а не ReferenceError на сборке
// батареи, глотающий весь перечень результатов.
// CONSTRAINT: `__ctlLog` is the image's host-log binding, spliced beside the
// door (Г4); here it is a parameter, so a battery records the lines the door
// writes and a missing call is a red tooth, not an unobservable one.
export function buildDoor(code, log = () => {}) {
  return new Function(
    '__ctlLog',
    code + ';return {reg:__ctlRegOp,unreg:__ctlUnregOp,list:__ctlListOp,sys:__ctlSys,tools:__ctlTools,settle:__ctlSettle,' +
      'term:typeof __ctlTerm==="function"?__ctlTerm:void 0,gone:typeof __ctlGone==="function"?__ctlGone:void 0,' +
      'rules:__ctlRules,remove:__ctlRemove,dead:__ctlDead}',
  )(log);
}

// Scope contract (Catalyst-programs/2026-09-26-scoped-runs/CENSUS.md): a run
// names its units, there is no key for "everything", and no scope or an
// unknown name runs nothing. The mutation battery alone passes ALL: a
// mutation's red set is measured against the whole battery.
export const ALL = Symbol('all door teeth');
const CORE = new Set(['T1', 'T2', 'T2b', 'T3d', 'T3', 'T3b', 'T3c', 'T6', 'T5a', 'T5b', 'T5c', 'T5d', 'T5e',
  'T8', 'T9', 'T7a', 'T7b', 'T7c', 'T8b', 'T8c', 'T10e']);
const GEN_ENTRIES = ['T28', 'T29', 'T30'];
const GEN_VALUES = [['a', 'undefined', () => undefined], ['b', 'NaN', () => NaN], ['c', 'Infinity', () => Infinity],
  ['d', '"3"', () => '3'], ['e', 'object valueOf 3', () => ({ valueOf() { return 3; } })], ['f', 'null', () => null],
  ['g', '-1', () => -1], ['h', '1.5', () => 1.5], ['i', '2**53', () => 2 ** 53]];
export const UNITS = ['core', 'T10', 'T10b', 'T10c', 'T10d', 'T10f', 'T10g', 'T10h', 'T10i', 'T10j', 'T10k', 'T10l',
  'T11a', 'T11b', 'T11c', 'T12a', 'T12b', 'T13a', 'T13b', 'T13c', 'T13d', 'T14a', 'T14b', 'T14c', 'T15', 'T16',
  'T17', 'T18', 'T19', 'T20a', 'T20b', 'T20c', 'T20d', 'T20e', 'T20f', 'T20g', 'T20h', 'T21a', 'T21b', 'T22',
  'T23', 'T24a', 'T24b', 'T25a', 'T25b', 'T26a', 'T26b', 'T27',
  ...GEN_ENTRIES.flatMap((e) => GEN_VALUES.map(([k]) => e + k)), 'T32', 'T33a', 'T33b', 'T33c', 'T34', 'T35',
  'T36a', 'T36b', 'T36c', 'T37a', 'T37b', 'T37c', 'T38'];
export const unitOf = (name) => { const tag = name.split(' ')[0]; return CORE.has(tag) ? 'core' : tag; };
export const scopeLine = (known) =>
  `nothing run: scope required (--scope <name>[,<name>...]); known: ${known.join(',')}`;
// `--list` prints the units and exits 0; no scope, an empty one or an
// unknown name prints the contract line and refuses before anything runs.
export function scopeFromArgv(argv, known, prefix) {
  if (argv.includes('--list')) { console.log(known.join('\n')); process.exit(0); }
  const at = argv.indexOf('--scope');
  const names = at === -1 || at + 1 >= argv.length ? [] : argv[at + 1].split(',').filter((n) => n !== '');
  const unknown = names.filter((n) => !known.includes(n));
  if (names.length === 0 || unknown.length) {
    console.log(scopeLine(known));
    throw new DoorSuiteError('scope-required', unknown.length ? 'unknown: ' + unknown.join(',') : 'no --scope');
  }
  return new Set(names);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.slice(2).includes('--list')) console.log(UNITS.join('\n'));
  else { console.log(scopeLine(UNITS)); process.exitCode = 2; }
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
const REPL = 'the module generation was replaced; a newer load of this plugin owns its rules';
const NOGEN = 'the caller carries no module generation (environmentId)';
const UNLOADED = 'the calling module is no longer loaded';
const MODEL_WS = 'model must not begin or end with whitespace';
const BAD_GEN = 'the generation is not a nonnegative safe integer environment id';
const ID_WS = 'unregister takes an id without surrounding whitespace';
// CONSTRAINT: id — непрозрачный токен двери. Зубы берут id ЗАПИСИ из ответа
// register; id правила, которого нет, собирается той же формулой, что
// `__ctlId` (длина владельца — префикс: разделитель в имени владельца или
// модели не склеивает два id).
const idOf = (owner, model) => owner.length + ':' + owner + ':' + String(model).toLowerCase();

export async function run(code, scope) {
  const fromArgv = scope === undefined;
  const sel = fromArgv ? scopeFromArgv(process.argv.slice(2), UNITS) : scope;
  const on = (unit) => sel === ALL || sel.has(unit);
  const C = (p, g) => ({ plugin: p, environmentId: g });
  const results = [];
  const t = (name, ok, extra = '') => { results.push({ name, ok: !!ok, extra: String(extra), unit: unitOf(name) }); };
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const logs = () => { const f = (s) => { f.lines.push(String(s)); }; f.lines = []; return f; };
  // CONSTRAINT: список может быть проитериан только через этого помощника —
  // голый `await list.run()` под мутацией «list бросает» роняет батарею
  // целиком, и краснота зубов теряется вместе с результатами.
  const safeList = async (g) => {
    try { return await g.list.run(); } catch (e) { return { threw: String((e && e.message) || e) }; }
  };

  if (on('core')) {
  const d = buildDoor(code);
  t('T1 op typo key refused', /unknown key "flgs"/.test(String(d.reg.check({ model: 'm', ops: [{ pattern: '^a$', flgs: 'gm', to: 'b' }] }, C('a', 1)) || '')));
  t('T2 rule extra key refused', /unknown key "extra"/.test(String(d.reg.check({ model: 'm', ops: [{ find: 'a', to: 'b' }], extra: 1n }, C('a', 1)) || '')));
  t('T2b good rule accepted', d.reg.check({ model: 'devin/swe-2', ops: [{ find: 'a', to: 'b' }] }, C('p', 1)) === undefined);

  const live = { model: 'devin/swe-2', ops: [{ find: 'a', to: 'b' }] };
  await d.reg.run(live, C('p', 1));
  live.model = 'EDITED'; live.ops[0].to = 'ZZZ';
  let ls = null, ls2 = null, listThrew = '';
  try { ls = await d.list.run(); ls2 = await d.list.run(); } catch (e) { listThrew = String((e && e.message) || e); }
  t('T3d list does not throw', listThrew === '', listThrew);
  t('T3 snapshot at registration', !!(ls && ls.rules[0] && ls.rules[0].rule.model === 'devin/swe-2' && ls.rules[0].rule.ops[0].to === 'b'),
    ls && ls.rules[0] ? JSON.stringify(ls.rules[0].rule) : 'no rule');
  t('T3b no JSON.stringify in door', (code.match(/JSON\.stringify/g) || []).length === 0);
  t('T3c list returns fresh object', !!(ls && ls2 && ls.rules[0] && ls2.rules[0] && ls2.rules[0].rule !== ls.rules[0].rule));

  await d.reg.run({ model: 'DEVIN/SWE-2', ops: [{ find: 'q', to: 'r' }] }, C('p', 1));
  t('T6 case-insensitive upsert', d.rules.length === 1, 'len=' + d.rules.length);

  const id = d.rules[0] ? d.rules[0].id : idOf('p', 'none');
  t('T5a foreign unregister refused', d.unreg.check({ id }, C('other', 1)) === 'the id belongs to another plugin');
  t('T5b unknown id passes check', d.unreg.check({ id: idOf('nobody', 'x') }, C('other', 1)) === undefined);
  // CONSTRAINT: `run` несёт те же гарды, что `check`, — отказанная регистрация
  // обязана РЕДЖЕКТИТЬСЯ, и зуб ловит отказ, а не роняет батарею: мутация
  // guards иначе глотала бы все последующие зубы одним броском.
  let t5cRemoved = null, t5cThrew = '';
  try { t5cRemoved = (await d.unreg.run({ id: idOf('nobody', 'x') }, C('other', 1))).removed; }
  catch (e) { t5cThrew = String((e && e.message) || e); }
  t('T5c unknown id removes nothing', t5cRemoved === false && t5cThrew === '', t5cThrew || String(t5cRemoved));
  t('T5d signature text', /unregister takes a non-empty string id/.test(String(d.unreg.check({ id: '' }, C('p', 1)) || '')));
  t('T5e remove guards owner', d.remove(id, 'other').removed === false && d.rules.length === 1);

  // CONSTRAINT: отказ этого снятия под мутацией (владелец вершины подменён)
  // не роняет перечень — его краснеет T5e, а не батарея целиком.
  try { await d.unreg.run({ id }, C('p', 1)); } catch { /* T5e carries it */ }
  // CONSTRAINT: эта регистрация идёт поверх tomb своего поколения (А3) —
  // её отказ под мутацией краснеет зубы ниже поимённо, а не роняет батарею.
  try {
    await d.reg.run({ model: 'devin/swe-2', ops: [
      { pattern: '^You are Claude Code\\.$', flags: 'gm', to: 'You are a coding agent.' },
      { pattern: 'a', flags: 'y', to: 'X' },
      { tool: 'Read', find: 'Reads a file.', to: 'Short.' }] }, C('p', 1));
  } catch { /* T8/T9/T8b/T8c carry it */ }
  const r1 = d.sys('x\r\nYou are Claude Code.\r\ny', 'devin/swe-2');
  t('T8 CRLF kept + rewritten', r1 === 'x\r\nYou are a coding agent.\r\ny', JSON.stringify(r1));
  const sticky = ['a', 'a', 'a'].map((s) => d.sys(s, 'devin/swe-2'));
  t('T9 sticky lastIndex reset', sticky.join('/') === 'X/X/X', sticky.join('/'));
  const fa = [{ type: 'text', text: 'You are Claude Code.' }];
  const r2 = d.sys(fa, 'claude-opus-4');
  t('T7a foreign model untouched', r2 === fa && r2[0].text === 'You are Claude Code.');
  const na = [{ type: 'text', text: 'nothing here' }], tl = [{ name: 'Read', description: 'untouched' }];
  const r3 = d.sys(na, 'devin/swe-2');
  const r3t = d.tools(tl);
  t('T7b unchanged system keeps identity', r3 === na, 'container replaced');
  t('T7c unchanged tools keep identity', r3t === tl, 'container replaced');
  const r4s = d.sys([{ type: 'text', text: 'You are Claude Code.' }], 'devin/swe-2');
  const r4t = d.tools([{ name: 'Read', description: 'Reads a file. More.' }]);
  t('T8b array block rewritten', r4s[0].text === 'You are a coding agent.', r4s[0].text);
  t('T8c tool rewritten', r4t[0].description === 'Short. More.', r4t[0].description);
  // Поколения: контекст без environmentId — громкий отказ с фразой.
  t('T10e context without environmentId refused',
    d.reg.check({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, { plugin: 'p' }) === 'the caller carries no module generation (environmentId)',
    String(d.reg.check({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, { plugin: 'p' })));
  }

  // Заморозки нет (#468): регистрация принимается и ПОСЛЕ состоявшегося
  // запроса, эффект — со следующего `__ctlSys`.
  if (on('T10')) {
    const g = buildDoor(code);
    const fx0 = [{ type: 'text', text: 'You are Claude Code.' }];
    g.sys(fx0, 'devin/swe-2');
    await g.reg.run({ model: 'devin/swe-2', ops: [{ pattern: '^You are Claude Code\\.$', flags: 'gm', to: 'You are a coding agent.' }] }, C('p', 1));
    const fx1 = [{ type: 'text', text: 'You are Claude Code.' }];
    const after = g.sys(fx1, 'devin/swe-2');
    t('T10 registration after a request is accepted',
      fx0[0].text === 'You are Claude Code.' && after[0].text === 'You are a coding agent.',
      'before=' + fx0[0].text + ' after=' + after[0].text);
  }
  // Один снимок таблицы на запрос: регистрации между `__ctlSys` и
  // `__ctlTools` этот запрос не меняют. Правило-цепочка делает утечку
  // видимой: заменяющая op читает ВЫХОД снимочной op — только живая таблица
  // могла бы применить её к этому же запросу.
  if (on('T10b')) {
    const g = buildDoor(code);
    await g.reg.run({ model: 'm', ops: [{ tool: 'Read', find: 'a', to: 'b' }] }, C('p', 1));
    g.sys([], 'm');
    await g.reg.run({ model: 'm', ops: [{ tool: 'Read', find: 'b', to: 'c' }] }, C('p', 1));
    const out = g.tools([{ name: 'Read', description: 'a text' }]);
    t('T10b pick frozen between sys and tools', out[0].description === 'b text', out[0].description);
  }
  // `__ctlTools` без предшествующего `__ctlSys` — тождество.
  if (on('T10c')) {
    const g = buildDoor(code);
    await g.reg.run({ model: 'm', ops: [{ tool: 'Read', find: 'old', to: 'new' }] }, C('p', 1));
    const arr = [{ name: 'Read', description: 'old text' }];
    const out = g.tools(arr);
    t('T10c tools without sys is identity', out === arr);
  }
  // Счётчики считают ЗАПРОСЫ: seen на каждый `__ctlSys` (включая пустую
  // таблицу и чужую модель), changed ровно один раз на запрос.
  if (on('T10d')) {
    const g = buildDoor(code);
    g.sys('x', 'm');
    await g.reg.run({ model: 'm', ops: [{ find: 'a', to: 'b' }, { tool: 'Read', find: 'old', to: 'new' }] }, C('p', 1));
    g.sys('aaa', 'm');
    g.tools([{ name: 'Read', description: 'zzz' }]);
    g.sys('zzz', 'm');
    g.tools([{ name: 'Read', description: 'old' }]);
    g.sys('aaa', 'm');
    g.tools([{ name: 'Read', description: 'old' }]);
    g.sys('zzz', 'other');
    let st = null, stThrew = '';
    try { st = await g.list.run(); } catch (e) { stThrew = String((e && e.message) || e); }
    t('T10d counters count requests',
      !!(st && st.seen === 5 && st.changed === 3 && st.rules.length === 1 && st.rules[0].matched === 3 &&
        st.rules[0].gen === 1 && !('frozen' in st)),
      stThrew || JSON.stringify(st && { seen: st.seen, changed: st.changed, matched: st.rules[0] && st.rules[0].matched, frozen: st.frozen }));
  }
  // Регистрация поколения выше максимума заменяет правило того же id
  // АТОМАРНО (matched с нуля, поколение новое).
  if (on('T10f')) {
    const g = buildDoor(code);
    await g.reg.run({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, C('p', 1));
    g.sys('aaa', 'm');
    await g.reg.run({ model: 'm', ops: [{ find: 'a', to: 'c' }] }, C('p', 2));
    const l = await safeList(g);
    t('T10f newer generation replaces the same id',
      !!(l.rules && l.rules.length === 1 && l.rules[0].gen === 2 && l.rules[0].matched === 0 && l.rules[0].rule.ops[0].to === 'c'),
      JSON.stringify(l.rules || l.threw));
  }
  // Правило прежнего поколения с ДРУГИМ id живёт до settle; settle снимает
  // его и поднимает порог, не меняя ссылку `__ctlRules`.
  if (on('T10g')) {
    const g = buildDoor(code);
    await g.reg.run({ model: 'm1', ops: [{ find: 'a', to: 'b' }] }, C('p', 1));
    await g.reg.run({ model: 'm2', ops: [{ find: 'c', to: 'd' }] }, C('p', 1));
    await g.reg.run({ model: 'm1', ops: [{ find: 'a', to: 'e' }] }, C('p', 2));
    let l = await safeList(g);
    const before = l.rules ? l.rules.length : -1;
    const ref = g.rules;
    globalThis.__ctlRequestTextSettle('p', 2);
    l = await safeList(g);
    t('T10g old-generation rule lives until settle',
      before === 2 && !!(l.rules && l.rules.length === 1 && l.rules[0].model === 'm1' && l.rules[0].gen === 2) && g.rules === ref && ref.length === 1,
      'before=' + before + ' after=' + JSON.stringify(l.rules || l.threw));
  }
  // Регистрация/снятие id, чья вершина несёт поколение СТАРШЕ вызывающего, —
  // отказ с фразой (Р8: старшинство держится на уровне правила).
  if (on('T10h')) {
    const g = buildDoor(code);
    const { id } = await g.reg.run({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, C('p', 5));
    const regRefused = g.reg.check({ model: 'm', ops: [{ find: 'a', to: 'c' }] }, C('p', 2));
    const unregRefused = g.unreg.check({ id }, C('p', 2));
    t('T10h younger generation refused with the named phrase',
      regRefused === REPL && unregRefused === regRefused,
      regRefused + ' / ' + unregRefused);
  }
  // Тот же порог поднимается и settle без регистрации.
  if (on('T10i')) {
    const g = buildDoor(code);
    globalThis.__ctlRequestTextSettle('p', 5);
    const refused = g.reg.check({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, C('p', 3));
    const accepted = g.reg.check({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, C('p', 5));
    t('T10i settle raises the generation floor',
      refused === 'the module generation was replaced; a newer load of this plugin owns its rules' && accepted === undefined,
      String(refused) + ' / ' + String(accepted));
  }
  // Идентичная перерегистрация сохраняет matched, поколение обновляется.
  if (on('T10j')) {
    const g = buildDoor(code);
    await g.reg.run({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, C('p', 1));
    g.sys('aaa', 'm');
    await g.reg.run({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, C('p', 2));
    const l = await safeList(g);
    t('T10j identical re-registration keeps matched',
      !!(l.rules && l.rules.length === 1 && l.rules[0].matched === 1 && l.rules[0].gen === 2),
      JSON.stringify(l.rules || l.threw));
  }
  // Все зубы ниже исполняются через `tt`: брошенное исключение (мутация,
  // отсутствующая врезка) делает красным СВОЙ зуб, а не роняет перечень.
  const tt = async (name, fn) => {
    if (!on(unitOf(name))) return;
    try { const [ok, extra] = await fn(); t(name, ok, extra); }
    catch (e) { t(name, false, 'THREW: ' + String((e && e.message) || e)); }
  };
  const R1 = { model: 'm', ops: [{ find: 'a', to: 'b' }] };
  const R2 = { model: 'm', ops: [{ find: 'a', to: 'c' }] };
  const R3 = { model: 'm', ops: [{ find: 'a', to: 'd' }] };
  const view = (l) => JSON.stringify(l.rules ? l.rules.map((r) => [r.id, r.gen, r.matched, r.rule.ops[0].to]) : l.threw);
  // terminate(h) — смерть поколения h (Р6): снимается правило ровно этого
  // поколения, правило другого id старшего поколения живо.
  await tt('T10k terminate removes exactly the dead generation', async () => {
    const g = buildDoor(code);
    await g.reg.run({ model: 'm1', ops: [{ find: 'a', to: 'b' }] }, C('p', 1));
    await g.reg.run({ model: 'm2', ops: [{ find: 'a', to: 'b' }] }, C('p', 2));
    g.term('p', 2);
    const l = await safeList(g);
    return [!!(l.rules && l.rules.length === 1 && l.rules[0].gen === 1 && l.rules[0].model === 'm1' && g.rules.length === 1), view(l)];
  });
  // Уход владельца (Р7) снимает ВСЕ его вершины, скрытые (`tomb`) тоже;
  // чужой владелец не задет.
  await tt('T10l owner gone removes every vertex', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run(R1, C('p', 1));
    await g.reg.run({ model: 'm2', ops: [{ find: 'a', to: 'b' }] }, C('p', 1));
    await g.unreg.run({ id }, C('p', 2));
    await g.reg.run(R1, C('q', 1));
    g.gone('p', 2);
    const l = await safeList(g);
    return [!!(l.rules && l.rules.length === 1 && l.rules[0].owner === 'q' && g.rules.length === 1), view(l) + ' raw=' + g.rules.length];
  });
  // flags входят в тождество правила: правило с другими flags — НЕ тот же
  // текст, matched не переносится, применяется новое.
  await tt('T11a flags are part of rule identity', async () => {
    const g = buildDoor(code);
    await g.reg.run({ model: 'm', ops: [{ pattern: 'a', flags: 'g', to: 'x' }] }, C('p', 1));
    g.sys('q', 'm');
    await g.reg.run({ model: 'm', ops: [{ pattern: 'a', flags: 'i', to: 'x' }] }, C('p', 2));
    const out = g.sys('aAa', 'm');
    const l = await safeList(g);
    return [out === 'xAa' && !!(l.rules && l.rules.length === 1 && l.rules[0].matched === 1), JSON.stringify(out) + ' ' + view(l)];
  });
  // Снимок одного запроса отдаётся ОДНОМУ `__ctlTools`: второй вызов
  // tools без нового `__ctlSys` — тождество.
  await tt('T11b second tools after a request is identity', async () => {
    const g = buildDoor(code);
    await g.reg.run({ model: 'm', ops: [{ tool: 'Read', find: 'old', to: 'new' }] }, C('p', 1));
    g.sys('x', 'm');
    const first = g.tools([{ name: 'Read', description: 'old' }]);
    const arr = [{ name: 'Read', description: 'old' }];
    const second = g.tools(arr);
    return [first[0].description === 'new' && second === arr, first[0].description + ' / ' + (second === arr ? 'identity' : second[0].description)];
  });
  // `__ctlSys` сбрасывает снимок прежнего запроса ПЕРВЫМ действием — и при
  // пустой таблице: tool-правило снято, запрос другой модели — tools тождество.
  // CONSTRAINT: снятие своего поколения оставляет tomb (А3), и таблица пуста
  // только после settle этого поколения — без settle зуб не проходит ветку
  // пустой таблицы, и снятый сброс снимка зеленеет (замерено 26.09).
  await tt('T11c sys resets the pick of an earlier request', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run({ model: 'm', ops: [{ tool: 'Read', find: 'old', to: 'new' }] }, C('p', 1));
    g.sys('x', 'm');
    await g.unreg.run({ id }, C('p', 1));
    g.settle('p', 1);
    if (g.rules.length !== 0) return [false, 'table not empty before the second request: raw=' + g.rules.length];
    g.sys('x', 'other');
    const arr = [{ name: 'Read', description: 'old' }];
    const out = g.tools(arr);
    return [out === arr, out === arr ? 'identity' : out[0].description];
  });
  // Прямой `run` (мимо `check`) отказывает теми же фразами.
  const refusals = async (op, arg) => {
    const g = buildDoor(code);
    const why = async (c) => { try { await op(g)(arg, c); return 'accepted'; } catch (e) { return String((e && e.message) || e); } };
    g.settle('p', 5);
    g.term('q', 4);
    const got = [await why({ plugin: 'p' }), await why(C('p', 3)), await why(C('q', 4)), await why({ plugin: 'environment 7', environmentId: 7 })];
    const want = [NOGEN, REPL, REPL, UNLOADED];
    return [got.every((x, i) => x === want[i]), JSON.stringify(got)];
  };
  await tt('T12a register run refuses on its own', () => refusals((g) => g.reg.run, R1));
  await tt('T12b unregister run refuses on its own', () => refusals((g) => g.unreg.run, { id: idOf('p', 'm') }));
  // Р6, замена: смерть поколения 2 возвращает правило поколения 1 как было
  // (его содержимое, его matched); поколение 2 больше не регистрирует.
  await tt('T13a terminate rolls a replacement back', async () => {
    const g = buildDoor(code);
    await g.reg.run(R1, C('p', 1));
    g.sys('a', 'm'); g.sys('a', 'm');
    await g.reg.run(R2, C('p', 2));
    g.sys('a', 'm');
    g.term('p', 2);
    const l = await safeList(g);
    const why = g.reg.check(R3, C('p', 2));
    return [!!(l.rules && l.rules.length === 1 && l.rules[0].gen === 1 && l.rules[0].matched === 2 &&
      l.rules[0].rule.ops[0].to === 'b') && g.sys('a', 'm') === 'b' && why === REPL, view(l) + ' ' + why];
  });
  // Р6, тождество: побайтная перерегистрация несёт matched; откат к
  // поколению 1 сохраняет ТЕКУЩИЙ счёт.
  await tt('T13b terminate rolls an identical re-registration back', async () => {
    const g = buildDoor(code);
    await g.reg.run(R1, C('p', 1));
    g.sys('a', 'm'); g.sys('a', 'm'); g.sys('a', 'm');
    await g.reg.run({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, C('p', 2));
    const mid = await safeList(g);
    g.sys('a', 'm');
    g.term('p', 2);
    const l = await safeList(g);
    return [!!(mid.rules && mid.rules[0].matched === 3 && l.rules && l.rules.length === 1 && l.rules[0].gen === 1 && l.rules[0].matched === 4),
      view(mid) + ' -> ' + view(l)];
  });
  // Р6, снятие: `unregister` поколения 2 скрывает правило поколения 1
  // (не применяется, не листится); смерть поколения 2 его возвращает.
  await tt('T13c terminate rolls an unregister back', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run(R1, C('p', 1));
    const rm = await g.unreg.run({ id }, C('p', 2));
    const hidden = await safeList(g);
    const off = g.sys('a', 'm');
    g.term('p', 2);
    const l = await safeList(g);
    return [rm.removed === true && !!(hidden.rules && hidden.rules.length === 0) && off === 'a' &&
      !!(l.rules && l.rules.length === 1 && l.rules[0].gen === 1) && g.sys('a', 'm') === 'b',
      JSON.stringify(rm) + ' ' + view(hidden) + ' ' + off + ' -> ' + view(l)];
  });
  // Р6, цепочка: откат пропускает звенья мёртвых поколений в любом порядке
  // смертей.
  await tt('T13d terminate rolls through a chain in any order', async () => {
    const chain = async (first, second) => {
      const g = buildDoor(code);
      await g.reg.run(R1, C('p', 1));
      await g.reg.run(R2, C('p', 2));
      await g.reg.run(R3, C('p', 3));
      g.term('p', first); g.term('p', second);
      return safeList(g);
    };
    const a = await chain(2, 3), b = await chain(3, 2);
    const at1 = (l) => !!(l.rules && l.rules.length === 1 && l.rules[0].gen === 1 && l.rules[0].rule.ops[0].to === 'b');
    return [at1(a) && at1(b), view(a) + ' / ' + view(b)];
  });
  // Р9: снятие поколением 2 правила поколения 1 окончательно после settle(2).
  await tt('T14a settle finalises an older-generation unregister', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run(R1, C('p', 1));
    await g.unreg.run({ id }, C('p', 2));
    g.settle('p', 2);
    const raw = g.rules.length;
    g.term('p', 2);
    const l = await safeList(g);
    return [raw === 0 && g.rules.length === 0 && !!(l.rules && l.rules.length === 0), 'raw=' + raw + ' ' + view(l)];
  });
  // Р9 (А3): снятие правила СВОЕГО поколения скрывает его сразу — не
  // применяется и не листится.
  await tt('T14b own-generation unregister hides the rule at once', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run(R1, C('p', 1));
    const rm = await g.unreg.run({ id }, C('p', 1));
    const l = await safeList(g);
    const out = g.sys('a', 'm');
    return [rm.removed === true && !!(l.rules && l.rules.length === 0) && out === 'a',
      JSON.stringify(rm) + ' ' + view(l) + ' ' + out];
  });
  // Р13: снятие поколением 3 не отменяется регистрацией живого поколения 2.
  await tt('T14c older generation cannot register over a younger unregister', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run(R1, C('p', 1));
    await g.unreg.run({ id }, C('p', 3));
    const why = g.reg.check(R2, C('p', 2));
    let run = 'accepted';
    try { await g.reg.run(R2, C('p', 2)); } catch (e) { run = String((e && e.message) || e); }
    return [why === REPL && run === REPL, why + ' / ' + run];
  });
  // Р7: уход владельца поднимает порог до environmentId + 1.
  await tt('T15 owner gone raises the floor past the leaving generation', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run(R1, C('p', 4));
    await g.unreg.run({ id }, C('p', 5));
    g.gone('p', 5);
    const at5 = g.reg.check(R1, C('p', 5)), at6 = g.reg.check(R1, C('p', 6));
    return [g.rules.length === 0 && at5 === REPL && at6 === undefined, 'raw=' + g.rules.length + ' ' + at5 + ' / ' + at6];
  });
  // Р8: регистрация порог не поднимает; старшинство — на уровне правила.
  await tt('T16 registration does not raise the floor', async () => {
    const g = buildDoor(code);
    await g.reg.run(R1, C('p', 1));
    await g.reg.run({ model: 'm2', ops: [{ find: 'a', to: 'b' }] }, C('p', 2));
    let other = 'accepted';
    try { await g.reg.run({ model: 'm3', ops: [{ find: 'a', to: 'b' }] }, C('p', 1)); } catch (e) { other = String((e && e.message) || e); }
    const same = g.reg.check({ model: 'm2', ops: [{ find: 'a', to: 'c' }] }, C('p', 1));
    return [other === 'accepted' && same === REPL, other + ' / ' + same];
  });
  // Р10: settle(2) обрезает откат к поколению < 2 — смерть поколения 2
  // после этого правило удаляет, а не возвращает поколение 1.
  await tt('T17 settle trims the rollback chain', async () => {
    const g = buildDoor(code);
    await g.reg.run(R1, C('p', 1));
    await g.reg.run(R2, C('p', 2));
    g.settle('p', 2);
    g.term('p', 2);
    const l = await safeList(g);
    return [g.rules.length === 0 && !!(l.rules && l.rules.length === 0), view(l)];
  });
  // id инъективен: разделитель внутри имени владельца или модели не склеивает
  // записи двух владельцев, и register одного не накрывает запись другого.
  await tt('T18 owner and model separators never merge two ids', async () => {
    const g = buildDoor(code);
    const a = await g.reg.run({ model: 'c', ops: [{ find: 'x', to: 'y' }] }, C('a:b', 1));
    const b = await g.reg.run({ model: 'b:c', ops: [{ find: 'x', to: 'z' }] }, C('a', 1));
    await g.reg.run({ model: 'b:c', ops: [{ find: 'x', to: 'w' }] }, C('a', 2));
    const l = await safeList(g);
    const own = (o) => l.rules && l.rules.find((r) => r.owner === o);
    return [a.id !== b.id && g.rules.length === 2 && !!(own('a:b') && own('a:b').id === a.id && own('a:b').rule.ops[0].to === 'y' &&
      own('a') && own('a').id === b.id && own('a').rule.ops[0].to === 'w'),
      JSON.stringify([a.id, b.id]) + ' ' + view(l)];
  });
  // А3 (смысл Р13): снятие поколением g оставляет tomb поколения g и без
  // цепочки — старшее живое поколение не отменяет снятие, сделанное младшим.
  await tt('T19 own-generation unregister outranks an older generation', async () => {
    const g = buildDoor(code);
    const r = { model: 'm', ops: [{ find: 'X', to: 'Y' }] }, old = { model: 'm', ops: [{ find: 'X', to: 'OLD' }] };
    const { id } = await g.reg.run(r, C('p', 3));
    const rm = await g.unreg.run({ id }, C('p', 3));
    const why = g.reg.check(old, C('p', 2));
    let run = 'accepted';
    try { await g.reg.run(old, C('p', 2)); } catch (e) { run = String((e && e.message) || e); }
    const out = g.sys('X', 'm');
    return [rm.removed === true && why === REPL && run === REPL && out === 'X', JSON.stringify(rm) + ' ' + why + ' / ' + run + ' / ' + out];
  });
  // А2: сценарии свидетеля opus (critic-468F1-opus/green-mutants-witness.mjs),
  // по зубу на поведенческую правку, которую прежние зубы не красили.
  const RT = (to) => ({ model: 'm', ops: [{ find: 'a', to }] });
  await tt('T20a settle touches only its own owner', async () => {
    const g = buildDoor(code);
    await g.reg.run(RT('Q'), C('q', 1));
    g.settle('p', 5);
    const out = g.sys('a', 'm');
    return [out === 'Q', out];
  });
  await tt('T20b own-generation unregister keeps the chain of its head', async () => {
    const g = buildDoor(code);
    await g.reg.run(RT('one'), C('p', 1));
    const { id } = await g.reg.run(RT('two'), C('p', 2));
    await g.unreg.run({ id }, C('p', 2));
    const why = g.reg.check(RT('x'), C('p', 1));
    const l = await safeList(g);
    return [why === REPL && !!(l.rules && l.rules.length === 0), String(why) + ' ' + view(l)];
  });
  await tt('T20c settle keeps the link of the settled generation', async () => {
    const g = buildDoor(code);
    await g.reg.run(RT('one'), C('p', 1));
    await g.reg.run(RT('two'), C('p', 2));
    await g.reg.run(RT('three'), C('p', 3));
    g.settle('p', 2);
    g.term('p', 3);
    const out = g.sys('a', 'm');
    return [out === 'two', out];
  });
  await tt('T20d a late settle never lowers the floor', async () => {
    const g = buildDoor(code);
    g.settle('p', 5);
    g.settle('p', 1);
    const why = g.reg.check(RT('x'), C('p', 2));
    return [why === REPL, String(why)];
  });
  await tt('T20e owner gone never lowers the floor', async () => {
    const g = buildDoor(code);
    g.settle('p', 5);
    g.gone('p', 2);
    const why = g.reg.check(RT('x'), C('p', 4));
    return [why === REPL, String(why)];
  });
  await tt('T20f same-generation re-registration keeps the chain', async () => {
    const g = buildDoor(code);
    await g.reg.run(RT('one'), C('p', 1));
    await g.reg.run(RT('two'), C('p', 2));
    await g.reg.run(RT('two2'), C('p', 2));
    g.term('p', 2);
    const out = g.sys('a', 'm');
    return [out === 'one', out];
  });
  await tt('T20g same-generation unregister keeps the chain', async () => {
    const g = buildDoor(code);
    await g.reg.run(RT('one'), C('p', 1));
    const { id } = await g.reg.run(RT('two'), C('p', 2));
    await g.unreg.run({ id }, C('p', 2));
    g.term('p', 2);
    const out = g.sys('a', 'm');
    return [out === 'one', out];
  });
  await tt('T20h settle keeps an unregister of a newer generation', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run(RT('one'), C('p', 1));
    await g.unreg.run({ id }, C('p', 3));
    g.settle('p', 1);
    g.term('p', 3);
    const out = g.sys('a', 'm');
    return [out === 'one', out];
  });
  // А4: модель сравнивается в нижнем регистре, как id (Р4: matched
  // переносится), а свёртка регистра предиката модели совпадает с
  // toLowerCase и вне ASCII (знак Кельвина U+212A -> k).
  await tt('T21a model case does not reset matched', async () => {
    const g = buildDoor(code);
    await g.reg.run({ model: 'M', ops: [{ find: 'a', to: 'b' }] }, C('p', 1));
    g.sys('a', 'm');
    await g.reg.run({ model: 'm', ops: [{ find: 'a', to: 'b' }] }, C('p', 2));
    const l = await safeList(g);
    return [!!(l.rules && l.rules.length === 1 && l.rules[0].matched === 1 && l.rules[0].gen === 2), view(l)];
  });
  await tt('T21b model match folds case like the id', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run({ model: 'devin/swe-k', ops: [{ find: 'a', to: 'b' }] }, C('p', 1));
    const out = g.sys('a', 'devin/swe-K');
    return [id === idOf('p', 'devin/swe-K') && out === 'b', id + ' ' + out];
  });
  // Q1: обрезка settle проходит цепочку глубже первого звена (Р10).
  await tt('T22 settle trims a chain at depth three', async () => {
    const g = buildDoor(code);
    await g.reg.run(R1, C('p', 1));
    await g.reg.run(R2, C('p', 2));
    await g.reg.run(R3, C('p', 3));
    g.settle('p', 2);
    g.term('p', 3);
    g.term('p', 2);
    const l = await safeList(g);
    return [g.rules.length === 0 && !!(l.rules && l.rules.length === 0), view(l) + ' raw=' + g.rules.length];
  });
  // Q2: снятие вершины-tomb — {removed:false}: плагину не сообщают о снятии,
  // которого не было.
  await tt('T23 a second unregister of a tomb removes nothing', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run(R1, C('p', 1));
    const first = await g.unreg.run({ id }, C('p', 2));
    const second = await g.unreg.run({ id }, C('p', 2));
    return [first.removed === true && second.removed === false, JSON.stringify([first, second])];
  });
  // Q3: регистрация поверх tomb своего поколения принимается, откат —
  // к цели tomb; исключение в теле run — реджект с сообщением, не бросок.
  await tt('T24a register over its own generation tomb', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run(R1, C('p', 1));
    await g.unreg.run({ id }, C('p', 2));
    let got = 'rejected';
    try { got = (await g.reg.run(R2, C('p', 2))).id; } catch (e) { got = 'rejected: ' + String((e && e.message) || e); }
    const live = g.sys('a', 'm');
    g.term('p', 2);
    const back = g.sys('a', 'm');
    return [got === id && live === 'c' && back === 'b', got + ' ' + live + ' -> ' + back];
  });
  await tt('T24b run turns an exception into a rejection', async () => {
    const g = buildDoor(code);
    const boom = () => { throw new Error('boom'); };
    const outcome = (f) => {
      let p;
      try { p = f(); } catch (e) { return Promise.resolve('sync throw: ' + String((e && e.message) || e)); }
      return Promise.resolve(p).then(() => 'resolved', (e) => 'rejected: ' + String((e && e.message) || e));
    };
    const a = await outcome(() => g.reg.run({ get model() { return boom(); }, ops: [{ find: 'a', to: 'b' }] }, C('p', 1)));
    const b = await outcome(() => g.unreg.run({ get id() { return boom(); } }, C('p', 1)));
    return [a === 'rejected: boom' && b === 'rejected: boom', a + ' / ' + b];
  });
  // Q4: модель и id с обрамляющими пробелами — громкий отказ: `__ctlModel`
  // обрезает модель запроса, и такое правило не совпало бы никогда.
  await tt('T25a model with surrounding whitespace refused', async () => {
    const g = buildDoor(code);
    const rule = { model: ' m ', ops: [{ find: 'a', to: 'b' }] };
    const why = g.reg.check(rule, C('p', 1));
    let run = 'accepted';
    try { await g.reg.run(rule, C('p', 1)); } catch (e) { run = String((e && e.message) || e); }
    return [why === MODEL_WS && run === MODEL_WS && g.rules.length === 0, String(why) + ' / ' + run];
  });
  await tt('T25b id with surrounding whitespace refused', async () => {
    const g = buildDoor(code);
    const { id } = await g.reg.run(R1, C('p', 1));
    const why = g.unreg.check({ id: ' ' + id }, C('p', 1));
    let run = 'accepted';
    try { await g.unreg.run({ id: id + ' ' }, C('p', 1)); } catch (e) { run = String((e && e.message) || e); }
    return [why === ID_WS && run === ID_WS && g.rules.length === 1, String(why) + ' / ' + run];
  });
  // Q-AR4: мёртвые поколения ниже порога владельца стираются в settle и в
  // уходе владельца — они уже отказаны порогом; живая смерть выше порога
  // остаётся.
  const deadBelow = (g, o, f) => Object.keys((g.dead && g.dead[o]) || {}).filter((k) => +k < f).length;
  await tt('T26a settle buries dead generations below the floor', async () => {
    const g = buildDoor(code);
    g.term('p', 1); g.term('p', 2); g.term('p', 4);
    g.settle('p', 3);
    const n = deadBelow(g, 'p', 3), at4 = g.reg.check(R1, C('p', 4)), at5 = g.reg.check(R1, C('p', 5));
    return [n === 0 && !!(g.dead && g.dead.p && g.dead.p[4] === 1) && at4 === REPL && at5 === undefined, 'below=' + n + ' ' + at4 + ' / ' + at5];
  });
  await tt('T26b owner gone buries dead generations below the floor', async () => {
    const g = buildDoor(code);
    g.term('p', 1); g.term('p', 6);
    g.gone('p', 3);
    const n = deadBelow(g, 'p', 4), at6 = g.reg.check(R1, C('p', 6)), at5 = g.reg.check(R1, C('p', 5));
    return [n === 0 && !!(g.dead && g.dead.p && g.dead.p[6] === 1) && at6 === REPL && at5 === undefined, 'below=' + n + ' ' + at6 + ' / ' + at5];
  });
  // Б1 (#468-FIX3): повторная смерть того же поколения -- без эффекта: ни
  // одна живая вершина не откатывается второй раз.
  await tt('T27 a repeated generation death changes nothing', async () => {
    const g = buildDoor(code);
    await g.reg.run(R1, C('p', 1));
    await g.reg.run(R2, C('p', 2));
    const live = g.sys('a', 'm');
    g.term('p', 2); g.term('p', 2);
    const after = g.sys('a', 'm');
    return [live === 'c' && after === 'b' && g.rules.length === 1 &&
      JSON.stringify(g.dead && g.dead.p) === '{"2":1}', live + ' -> ' + after + ' rules=' + g.rules.length];
  });
  // Б2 (#468-FIX3), Г4/Г5 (#468-FIX4): поколение вне домена __ctlGen
  // (безопасное целое >= 0), -- отказ БЕЗ изменения состояния в каждой точке входа (term /
  // gone / settle-мост) и ровно одна строка в лог хоста: вызывающие врезки
  // возврат выбрасывают. Строка "3" не превращает порог в "31" -- живые
  // поколения 5 и 30 принимаются после отказанного ухода.
  const badGenTeeth = [
    ['T28', 'term', (g, v) => g.term('p', v), (g) => [JSON.stringify(g.dead && g.dead.p) === '{}' || !(g.dead && g.dead.p), String(JSON.stringify(g.dead && g.dead.p))]],
    ['T29', 'gone', (g, v) => g.gone('p', v), (g) => [g.rules.length === 1 && g.reg.check(R1, C('p', 1)) === undefined &&
      g.reg.check(R1, C('p', 5)) === undefined && g.reg.check(R1, C('p', 30)) === undefined, 'rules=' + g.rules.length + ' at5=' + g.reg.check(R1, C('p', 5)) + ' at30=' + g.reg.check(R1, C('p', 30))]],
    ['T30', 'settle', (g, v) => g.settle('p', v), (g) => [g.rules.length === 1 && g.reg.check(R1, C('p', 1)) === undefined, 'rules=' + g.rules.length]],
  ];
  for (const [tag, entry, call, probe] of badGenTeeth) {
    for (const [k, label, value] of GEN_VALUES) {
      await tt(`${tag}${k} ${entry} refuses an out-of-domain generation (${label})`, async () => {
        const L = logs();
        const g = buildDoor(code, L);
        await g.reg.run(R1, C('p', 1));
        const v = value();
        const why = call(g, v);
        const [ok, detail] = probe(g);
        const line = `$.requestText: ${entry} refused for p: ${BAD_GEN} (got ${typeof v === 'number' ? String(v) : typeof v})`;
        return [why === BAD_GEN && ok && same(L.lines, [line]), String(why) + ' ' + detail + ' log=' + JSON.stringify(L.lines)];
      });
    }
  }
  // Г6: повторная смерть уже мёртвого поколения не трогает более новую живую
  // вершину того же id и не уменьшает таблицу.
  await tt('T32 a repeated death of a dead generation keeps a newer live head', async () => {
    const g = buildDoor(code);
    await g.reg.run(R1, C('p', 1));
    g.term('p', 2);
    await g.reg.run(R2, C('p', 3));
    const before = g.sys('a', 'm'), n0 = g.rules.length;
    g.term('p', 2);
    const after = g.sys('a', 'm');
    return [before === 'c' && after === 'c' && n0 === 1 && g.rules.length >= n0, before + ' -> ' + after + ' rules ' + n0 + ' -> ' + g.rules.length];
  });
  // Г4: отказ вызова (check и run) пишет одну строку в лог хоста; принятые
  // вызовы не пишут ничего; бросающий лог не подменяет отказ.
  await tt('T33a a refused register writes one host log line per call', async () => {
    const L = logs();
    const g = buildDoor(code, L);
    const why = g.reg.check(R1, { plugin: 'p' });
    let run = 'accepted';
    try { await g.reg.run(R1, { plugin: 'p' }); } catch (e) { run = String((e && e.message) || e); }
    const line = `$.requestText: register refused for p: ${NOGEN}`;
    return [why === NOGEN && run === NOGEN && same(L.lines, [line, line]), JSON.stringify(L.lines)];
  });
  await tt('T33b a refused unregister writes one host log line', async () => {
    const L = logs();
    const g = buildDoor(code, L);
    const { id } = await g.reg.run(R1, C('p', 1));
    const why = g.unreg.check({ id }, C('other', 1));
    return [why === 'the id belongs to another plugin' &&
      same(L.lines, ['$.requestText: unregister refused for other: the id belongs to another plugin']), JSON.stringify(L.lines)];
  });
  await tt('T33c accepted calls write no host log line', async () => {
    const L = logs();
    const g = buildDoor(code, L);
    const a = g.reg.check(R1, C('p', 1));
    const { id } = await g.reg.run(R1, C('p', 1));
    const b = g.unreg.check({ id }, C('p', 1));
    await g.unreg.run({ id }, C('p', 1));
    g.term('p', 1); g.settle('p', 2); g.gone('p', 2);
    return [a === undefined && b === undefined && L.lines.length === 0, JSON.stringify(L.lines)];
  });
  await tt('T34 a throwing host log never replaces the refusal', async () => {
    const g = buildDoor(code, () => { throw new Error('log down'); });
    const got = [g.term('p', undefined), g.gone('p', NaN), g.settle('p', 'x'), g.reg.check(R1, { plugin: 'p' })];
    let run = 'accepted';
    try { await g.reg.run(R1, { plugin: 'p' }); } catch (e) { run = String((e && e.message) || e); }
    return [same(got, [BAD_GEN, BAD_GEN, BAD_GEN, NOGEN]) && run === NOGEN, JSON.stringify(got) + ' / ' + run];
  });
  await tt('T35 a throwing death keeps subsequent deaths and unloads running', async () => {
    const L = logs(), g = buildDoor(code, L), unloaded = [];
    g.dead.p = new Proxy(Object.create(null), { set() { throw new Error('death storage failed'); } });
    let threw = false;
    try {
      for (const [owner, gen] of [['p', 1], ['q', 2]]) {
        g.term(owner, gen);
        unloaded.push(owner);
      }
    } catch { threw = true; }
    return [!threw && g.dead.q?.[2] === 1 && same(unloaded, ['p', 'q']) &&
      L.lines.length === 1 && L.lines[0].startsWith('$.requestText: term refused for p:'),
      `threw=${threw} unloaded=${JSON.stringify(unloaded)} logs=${JSON.stringify(L.lines)}`];
  });
  for (const [suffix, v] of [['a', -1], ['b', 1.5], ['c', 2 ** 53]]) {
    await tt(`T36${suffix} register refuses generation ${v}`, async () => {
      const g = buildDoor(code);
      let reason;
      try { await g.reg.run(R1, C('p', v)); } catch (e) { reason = e.message; }
      return [g.reg.check(R1, C('p', v)) === NOGEN && reason === NOGEN && g.rules.length === 0,
        JSON.stringify({reason, rules: g.rules.length})];
    });
    await tt(`T37${suffix} unregister refuses generation ${v}`, async () => {
      const g = buildDoor(code);
      const { id } = await g.reg.run(R1, C('p', 1));
      let reason;
      try { await g.unreg.run({ id }, C('p', v)); } catch (e) { reason = e.message; }
      return [g.unreg.check({ id }, C('p', v)) === NOGEN && reason === NOGEN && g.rules.length === 1 &&
        g.sys('a', 'm') === 'b', JSON.stringify({reason, rules: g.rules.length})];
    });
  }
  // CONSTRAINT: одно значение домена — своя строка вывода: check и run
  // обязаны совпадать с единым домом `__ctlGen` (tweakcc-patch.js:4720,
  // Number.isSafeInteger(g)&&g>=0). Принятое поколение регистрирует живое
  // правило и снимается СВОИМ term; отклонённое не оставляет правила.
  // T36/T37 пинят ноги register/unregister по грани; этот перечень пинит весь
  // домен как свойство: гард, разошедшийся между входами, краснит строку
  // своего значения, а не молчит.
  for (const [label, v, accepted] of [
    ['-1', -1, false], ['0', 0, true], ['1', 1, true], ['1.5', 1.5, false],
    ['9007199254740991', 2 ** 53 - 1, true], ['9007199254740992', 2 ** 53, false],
    ['NaN', NaN, false], ['"3"', '3', false],
  ]) {
    await tt(`T38 generation ${label} ${accepted ? 'accepted and removable by its term' : 'refused with no rule stored'}`, async () => {
      const g = buildDoor(code);
      const why = g.reg.check(R1, C('p', v));
      let reason;
      try { await g.reg.run(R1, C('p', v)); } catch (e) { reason = String((e && e.message) || e); }
      if (accepted) {
        const before = g.sys('a', 'm');
        g.term('p', v);
        return [why === undefined && reason === undefined && before === 'b' &&
          g.rules.length === 0 && g.sys('a', 'm') === 'a', JSON.stringify({why, reason, before})];
      }
      return [why === NOGEN && reason === NOGEN && g.rules.length === 0,
        JSON.stringify({why, reason, rules: g.rules.length})];
    });
  }
  // CONSTRAINT: the static unit list is the scope's vocabulary: a unit that
  // ran no tooth, or a tooth outside every declared unit, is a refusal --
  // otherwise `--scope <unit>` could name a unit that runs nothing.
  const ran = [...new Set(results.map((r) => r.unit))];
  const want = sel === ALL ? UNITS : UNITS.filter((u) => sel.has(u));
  if (!same([...ran].sort(), [...want].sort())) {
    throw new DoorSuiteError('units-drift', 'declared ' + want.join(',') + ' ran ' + ran.join(','));
  }
  if (fromArgv) console.log(`DOOR-SUITE scope=${[...sel].join(',')} units=${ran.length} teeth=${results.length}`);
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
