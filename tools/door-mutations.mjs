// Mutation control for the teeth of the `$.requestText` door. Run directly:
//   node tools/door-mutations.mjs
import { GENERATOR, doorCode, assertDoorSyntax, generatorSha256, run, teethNames, refuse } from './door-suite.mjs';

const PREFIX = 'DOOR-MUTATIONS';
let base, shaBefore;
try {
  shaBefore = generatorSha256();
  base = assertDoorSyntax(doorCode());
} catch (x) {
  refuse(PREFIX, x);
}
console.log('DOOR generator=%s sha256_before=%s', GENERATOR, shaBefore);

const base0 = await run(base);
const red0 = base0.filter((r) => !r.ok).map((r) => r.name);
console.log('BASELINE teeth=%d red=%s', base0.length, red0.length ? red0.join(' | ') : 'none');
const KNOWN = new Set(teethNames(base0));

// CONSTRAINT: мутация правит текст двери В ПАМЯТИ; ожидаемый зуб назван
// ИМЕНЕМ — «ожидается N красных» числом не пинуется.
// CONSTRAINT: мутация объявляется ЯКОРЕМ, а не функцией правки: якорь обязан
// встречаться в двери РОВНО ОДИН раз (проверяется ниже), иначе правка молча
// уезжает на чужой сайт — измеренный класс «локатор без единственности».
// CONSTRAINT: якорь берётся СТРУКТУРНЫЙ (предикат целиком), не «до первой `;`»:
// точка с запятой встречается ВНУТРИ строковых литералов сообщений, и обрезка
// по ней рвёт синтаксис вместо снятия проверки (замерено 22.09).
// CONSTRAINT: каждый зуб дома обязан иметь СВОЮ мутацию — непокрытый зуб
// неотличим от вакуумного (зелёного по построению); полнота покрытия
// проверяется ниже отдельной ветвью отказа.
const MUT = [
  ['M1 drop op whitelist', 'for(var ok in o)if(!__ctlOK[ok])', 'for(var ok in o)if(!1&&!__ctlOK[ok])', 'T1 op typo key refused'],
  ['M2 drop rule whitelist', 'for(var rk in r)if(!__ctlRK[rk])', 'for(var rk in r)if(!1&&!__ctlRK[rk])', 'T2 rule extra key refused'],
  ['M3 raw = live object', 'raw:__ctlSnap(r)}}', 'raw:r}}', 'T3 snapshot at registration'],
  ['M4 list returns stored object', 'rule:__ctlSnap(r.raw)', 'rule:r.raw', 'T3c list returns fresh object'],
  ['M5 id keeps exact case', 'String(r.model).toLowerCase()', 'r.model', 'T6 case-insensitive upsert'],
  ['M6 owner by string prefix', 'var r=__ctlFind(e.id);if(r&&r.owner!==String(c&&c.plugin||"?"))', 'if(e.id.indexOf(String(c&&c.plugin||"?")+":")!==0)', 'T5b unknown id passes check'],
  ['M7 drop remove guard', 'if(__ctlRules[i].owner!==owner)return {removed:!1};', '', 'T5e remove guards owner'],
  ['M8 system container always new', 'if(c1){b.system=a1;ch=!0}}', 'b.system=a1;}', 'T7b unchanged system keeps identity'],
  ['M9 tools container always new', 'if(c2){b.tools=a2;ch=!0}', 'b.tools=a2;', 'T7c unchanged tools keep identity'],
  ['M10 drop lastIndex reset', 'o.re.lastIndex=0;', '', 'T9 sticky lastIndex reset'],
  ['M11 unregister text reverted', 'unregister takes a non-empty string id', 'takes { id }, a non-empty string', 'T5d signature text'],
  // Вторая половина: зубы, остававшиеся без мутационного контроля до 22.09 —
  // расхождение двух наборов зубов прятало их непокрытость.
  ['M12 every rule refused', 'if(typeof r.model!=="string"||r.model==="")', 'if(1||typeof r.model!=="string"||r.model==="")', 'T2b good rule accepted'],
  ['M13 snapshot via stringify', 'rule:__ctlSnap(r.raw)}', 'rule:JSON.parse(JSON.stringify(r.raw))}', 'T3b no JSON.stringify in door'],
  ['M14 list throws', 'run:()=>Promise.resolve({frozen:__ctlFrozen', 'run:()=>Promise.resolve({frozen:__ctlNoSuchBinding.x', 'T3d list does not throw'],
  ['M15 unregister ignores owner', 'if(r&&r.owner!==String(c&&c.plugin||"?"))return "the id belongs to another plugin"', 'if(!1)return "the id belongs to another plugin"', 'T5a foreign unregister refused'],
  ['M16 remove reports a phantom removal', 'return {removed:!1}}function __ctlOne', 'return {removed:!0}}function __ctlOne', 'T5c unknown id removes nothing'],
  ['M17 string branch inert', 'var s2=__ctlText(b.system,sys);', 'var s2=b.system;', 'T8 CRLF kept + rewritten'],
  ['M18 foreign model matched', 'if(!r.mre.test(model))continue;', 'if(!1)continue;', 'T7a foreign model untouched'],
  ['M19 array branch inert', '(x=__ctlText(k.text,sys))!==k.text', '(x=k.text)!==k.text', 'T8b array block rewritten'],
  ['M20 tool branch inert', 'if(tls[k].tool===t.name)d=__ctlOne(d,tls[k]);', 'if(!1)d=__ctlOne(d,tls[k]);', 'T8c tool rewritten'],
  ['M21 freeze never set', 'function __ctlApply(b,model){__ctlFrozen=!0;', 'function __ctlApply(b,model){__ctlFrozen=!1;', 'T10 frozen refuses register'],
  ['M22 changed counter inert', 'if(ch)__ctlChanged++;', 'if(!1)__ctlChanged++;', 'T10b counters observable'],
];

// CONSTRAINT: якорь без ЕДИНСТВЕННОСТИ — отказ батареи, не заметка: ноль
// вхождений означает уехавший сайт, два и более — правку не того сайта.
const badAnchor = MUT
  .map(([name, a]) => [name, a, base.split(a).length - 1])
  .filter(([, , n]) => n !== 1)
  .map(([name, a, n]) => `${name}: ${n} hits for ${JSON.stringify(a.slice(0, 40))}`);
if (badAnchor.length) {
  console.log(`${PREFIX} REFUSED=anchor-not-unique detail=${badAnchor.join('; ')}`);
  process.exit(2);
}

// CONSTRAINT: покрытие ПОЛНОЕ — зуб без своей мутации неотличим от зелёного
// по построению; отказ называет непокрытые зубы поимённо.
const covered = new Set(MUT.map(([, , , expect]) => expect));
const uncovered = teethNames(base0).filter((n) => !covered.has(n));
if (uncovered.length) {
  console.log(`${PREFIX} REFUSED=teeth-without-mutation detail=${uncovered.join('; ')}`);
  process.exit(2);
}

// CONSTRAINT: ожидаемый зуб называется ТОЧНЫМ именем и обязан существовать в
// доме зубов — опечатка иначе неотличима от настоящего промаха мутации.
const unknown = MUT.filter(([, , , expect]) => !KNOWN.has(expect)).map(([name, , , expect]) => name + ' -> ' + expect);
if (unknown.length) {
  console.log(`${PREFIX} REFUSED=expect-not-a-tooth detail=${unknown.join('; ')}`);
  process.exit(2);
}

// CONSTRAINT: число мутаций — ДЛИНА этого массива результатов; инертная
// мутация (код не изменился либо зуб не покраснел) — ОТКАЗ батареи, не пропуск.
const results = [];
for (const [name, anchor, repl, expect] of MUT) {
  const c = base.replace(anchor, repl);
  if (c === base) {
    console.log('INERT  ', name, '<-- mutation did not change the code');
    results.push({ name, red: false });
    continue;
  }
  let red;
  try { red = (await run(c)).filter((r) => !r.ok).map((r) => r.name); }
  catch (e) { red = ['THREW: ' + e.message]; }
  // CONSTRAINT: совпадение по ПОЛНОМУ имени зуба — сравнение по префиксу `T3`
  // зачло бы красноту соседей `T3b`/`T3c`/`T3d` как попадание мутации.
  const hit = red.includes(expect);
  results.push({ name, red: hit });
  if (hit) console.log('RED    ', name, '->', red.join(' | '));
  else console.log('GREEN!!', name, '-> expected', expect, 'but red =', red.length ? red.join(' | ') : 'none');
}

// CONSTRAINT: файл генератора не трогается НИ ПРИ КАКОМ исходе — расхождение
// дайджеста до/после есть отказ батареи, а не заметка в логе.
const shaAfter = generatorSha256();
console.log('sha256_after=%s', shaAfter);
if (shaAfter !== shaBefore) {
  console.log(`${PREFIX} REFUSED=generator-mutated detail=sha256 ${shaBefore} -> ${shaAfter}`);
  process.exit(2);
}

const ok = results.filter((r) => r.red).length;
console.log(`\n${PREFIX} RED=${ok} FAILED=${results.length - ok} BASELINE_RED=${red0.length}`);
process.exit((results.length - ok || red0.length) ? 1 : 0);
