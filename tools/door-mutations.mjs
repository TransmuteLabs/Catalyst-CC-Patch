// Mutation control for the teeth of the `$.requestText` door. Run directly:
//   node tools/door-mutations.mjs --scope <mutation>[,<mutation>...] | --list
import { GENERATOR, doorCode, assertDoorSyntax, generatorSha256, run, teethNames, refuse, ALL, scopeFromArgv } from './door-suite.mjs';

const PREFIX = 'DOOR-MUTATIONS';
let base, shaBefore;
try {
  shaBefore = generatorSha256();
  base = assertDoorSyntax(doorCode());
} catch (x) {
  refuse(PREFIX, x);
}
console.log('DOOR generator=%s sha256_before=%s', GENERATOR, shaBefore);


// CONSTRAINT: мутация правит текст двери В ПАМЯТИ; ожидаемый зуб назван
// ИМЕНЕМ — «ожидается N красных» числом не пинуется.
// CONSTRAINT: красный набор мутации сверяется ТОЧНО (А6): пятое поле
// строки — прочие зубы, которые мутация честно красит; лишний красный или
// недостающий — провал батареи, а не пометка. Набор «содержит ожидаемый»
// молча принимал бы мутацию, уехавшую на чужой предмет.
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
  ['M5 id keeps exact case', 'String(m).toLowerCase()', 'm', 'T6 case-insensitive upsert',
   ['T5e remove guards owner', 'T21a model case does not reset matched']],
  ['M6 owner by string prefix', 'var r=__ctlFind(e.id);if(r&&r.owner!==String(c&&c.plugin||"?"))', 'if(e.id.indexOf(String(c&&c.plugin||"?")+":")!==0)', 'T5b unknown id passes check',
   ['T5c unknown id removes nothing', 'T10h younger generation refused with the named phrase', 'T10l owner gone removes every vertex', 'T11c sys resets the pick of an earlier request', 'T13c terminate rolls an unregister back', 'T14a settle finalises an older-generation unregister', 'T14b own-generation unregister hides the rule at once', 'T14c older generation cannot register over a younger unregister', 'T15 owner gone raises the floor past the leaving generation', 'T19 own-generation unregister outranks an older generation', 'T20b own-generation unregister keeps the chain of its head', 'T20g same-generation unregister keeps the chain', 'T20h settle keeps an unregister of a newer generation', 'T23 a second unregister of a tomb removes nothing', 'T24a register over its own generation tomb', 'T33c accepted calls write no host log line']],
  ['M7 drop remove guard', 'if(r.owner!==owner||r.tomb)return {removed:!1};', 'if(r.tomb)return {removed:!1};', 'T5e remove guards owner'],
  ['M8 system container always new', 'if(c1){__ctlChanged++;__ctlPick.sys=!0;return a1}}', 'if(1){__ctlChanged++;__ctlPick.sys=!0;return a1}}', 'T7b unchanged system keeps identity'],
  ['M9 tools container always new', 'if(c2){if(!p.sys)__ctlChanged++;return a2}', 'if(1){if(!p.sys)__ctlChanged++;return a2}', 'T7c unchanged tools keep identity'],
  ['M10 drop lastIndex reset', 'o.re.lastIndex=0;', '', 'T9 sticky lastIndex reset'],
  ['M11 unregister text reverted', 'unregister takes a non-empty string id', 'takes { id }, a non-empty string', 'T5d signature text'],
  // Вторая половина: зубы, остававшиеся без мутационного контроля до 22.09 —
  // расхождение двух наборов зубов прятало их непокрытость.
  ['M12 every rule refused', 'check:(e,c)=>__ctlCallBad(e,c,!0),', 'check:(e,c)=>"model must be a non-empty string",', 'T2b good rule accepted',
   ['T1 op typo key refused', 'T2 rule extra key refused', 'T10e context without environmentId refused', 'T10h younger generation refused with the named phrase', 'T10i settle raises the generation floor', 'T13a terminate rolls a replacement back', 'T14c older generation cannot register over a younger unregister', 'T15 owner gone raises the floor past the leaving generation', 'T16 registration does not raise the floor', 'T19 own-generation unregister outranks an older generation', 'T20b own-generation unregister keeps the chain of its head', 'T20d a late settle never lowers the floor', 'T20e owner gone never lowers the floor', 'T25a model with surrounding whitespace refused', 'T26a settle buries dead generations below the floor', 'T26b owner gone buries dead generations below the floor', 'T29a gone refuses an out-of-domain generation (undefined)', 'T29b gone refuses an out-of-domain generation (NaN)', 'T29c gone refuses an out-of-domain generation (Infinity)', 'T30a settle refuses an out-of-domain generation (undefined)', 'T30b settle refuses an out-of-domain generation (NaN)', 'T30c settle refuses an out-of-domain generation (Infinity)', 'T29d gone refuses an out-of-domain generation ("3")', 'T29e gone refuses an out-of-domain generation (object valueOf 3)', 'T29f gone refuses an out-of-domain generation (null)', 'T30d settle refuses an out-of-domain generation ("3")', 'T30e settle refuses an out-of-domain generation (object valueOf 3)', 'T30f settle refuses an out-of-domain generation (null)', 'T33a a refused register writes one host log line per call', 'T33c accepted calls write no host log line', 'T34 a throwing host log never replaces the refusal', 'T29g gone refuses an out-of-domain generation (-1)', 'T29h gone refuses an out-of-domain generation (1.5)', 'T29i gone refuses an out-of-domain generation (2**53)', 'T30g settle refuses an out-of-domain generation (-1)', 'T30h settle refuses an out-of-domain generation (1.5)', 'T30i settle refuses an out-of-domain generation (2**53)', 'T36a register refuses generation -1', 'T36b register refuses generation 1.5', 'T36c register refuses generation 9007199254740992', 'T38 generation -1 refused with no rule stored', 'T38 generation 0 accepted and removable by its term', 'T38 generation 1 accepted and removable by its term', 'T38 generation 1.5 refused with no rule stored', 'T38 generation 9007199254740991 accepted and removable by its term', 'T38 generation 9007199254740992 refused with no rule stored', 'T38 generation NaN refused with no rule stored', 'T38 generation "3" refused with no rule stored']],
  ['M13 snapshot via stringify', 'rule:__ctlSnap(r.raw)}', 'rule:JSON.parse(JSON.stringify(r.raw))}', 'T3b no JSON.stringify in door'],
  ['M14 list throws', 'run:()=>Promise.resolve({seen:__ctlSeen', 'run:()=>Promise.resolve({seen:__ctlNoSuchBinding.x', 'T3d list does not throw',
   ['T3 snapshot at registration', 'T3c list returns fresh object', 'T10d counters count requests', 'T10f newer generation replaces the same id', 'T10g old-generation rule lives until settle', 'T10j identical re-registration keeps matched', 'T10k terminate removes exactly the dead generation', 'T10l owner gone removes every vertex', 'T11a flags are part of rule identity', 'T13a terminate rolls a replacement back', 'T13b terminate rolls an identical re-registration back', 'T13c terminate rolls an unregister back', 'T13d terminate rolls through a chain in any order', 'T14a settle finalises an older-generation unregister', 'T14b own-generation unregister hides the rule at once', 'T17 settle trims the rollback chain', 'T18 owner and model separators never merge two ids', 'T20b own-generation unregister keeps the chain of its head', 'T21a model case does not reset matched', 'T22 settle trims a chain at depth three']],
  ['M15 unregister ignores owner', 'if(r&&r.owner!==String(c&&c.plugin||"?"))return "the id belongs to another plugin"', 'if(!1)return "the id belongs to another plugin"', 'T5a foreign unregister refused',
   ['T33b a refused unregister writes one host log line']],
  ['M16 remove reports a phantom removal', 'return {removed:!1}}function __ctlSettle', 'return {removed:!0}}function __ctlSettle', 'T5c unknown id removes nothing'],
  ['M17 string branch inert', 'var s2=__ctlText(b,sys);', 'var s2=b;', 'T8 CRLF kept + rewritten',
   ['T9 sticky lastIndex reset', 'T10d counters count requests', 'T11a flags are part of rule identity', 'T13a terminate rolls a replacement back', 'T13c terminate rolls an unregister back', 'T20a settle touches only its own owner', 'T20c settle keeps the link of the settled generation', 'T20f same-generation re-registration keeps the chain', 'T20g same-generation unregister keeps the chain', 'T20h settle keeps an unregister of a newer generation', 'T21b model match folds case like the id', 'T24a register over its own generation tomb', 'T27 a repeated generation death changes nothing', 'T32 a repeated death of a dead generation keeps a newer live head', 'T37a unregister refuses generation -1', 'T37b unregister refuses generation 1.5', 'T37c unregister refuses generation 9007199254740992', 'T38 generation 0 accepted and removable by its term', 'T38 generation 1 accepted and removable by its term', 'T38 generation 9007199254740991 accepted and removable by its term']],
  ['M18 foreign model matched', '||!r.mre.test(m))continue;', '||!1)continue;', 'T7a foreign model untouched',
   ['T10d counters count requests']],
  ['M19 array branch inert', '(x=__ctlText(k.text,sys))!==k.text', '(x=k.text)!==k.text', 'T8b array block rewritten',
   ['T10 registration after a request is accepted']],
  ['M20 tool branch inert', 'if(p.ops[i].tool===k.name)d=__ctlOne(d,p.ops[i]);', 'if(!1)d=__ctlOne(d,p.ops[i]);', 'T8c tool rewritten',
   ['T10b pick frozen between sys and tools', 'T10d counters count requests', 'T11b second tools after a request is identity']],
  // Волна #468: заморозки нет — зубы поколений, снимка на запрос и счётчиков
  // запросов несут СВОИ мутации, по одной на зуб.
  ['M21 generation guard disabled', 'if(!__ctlGen(g))return "the caller', 'if(!1)return "the caller', 'T10e context without environmentId refused',
   ['T12a register run refuses on its own', 'T12b unregister run refuses on its own', 'T33a a refused register writes one host log line per call', 'T34 a throwing host log never replaces the refusal',
    'T36a register refuses generation -1', 'T36b register refuses generation 1.5', 'T36c register refuses generation 9007199254740992',
    'T37a unregister refuses generation -1', 'T37b unregister refuses generation 1.5', 'T37c unregister refuses generation 9007199254740992',
    'T38 generation -1 refused with no rule stored', 'T38 generation 1.5 refused with no rule stored', 'T38 generation 9007199254740992 refused with no rule stored', 'T38 generation NaN refused with no rule stored', 'T38 generation "3" refused with no rule stored']],
  ['M22 string change not counted', 'if(s2!==b){__ctlChanged++;__ctlPick.sys=!0;return s2}', 'if(s2!==b){__ctlPick.sys=!0;return s2}', 'T10d counters count requests'],
  ['M23 late registration dropped', '__ctlRules.push(cr);return', 'return', 'T10 registration after a request is accepted',
   ['T3 snapshot at registration', 'T3c list returns fresh object', 'T6 case-insensitive upsert', 'T5a foreign unregister refused', 'T5e remove guards owner', 'T8 CRLF kept + rewritten', 'T9 sticky lastIndex reset', 'T8b array block rewritten', 'T8c tool rewritten', 'T10b pick frozen between sys and tools', 'T10d counters count requests', 'T10f newer generation replaces the same id', 'T10g old-generation rule lives until settle', 'T10h younger generation refused with the named phrase', 'T10j identical re-registration keeps matched', 'T10k terminate removes exactly the dead generation', 'T10l owner gone removes every vertex', 'T11a flags are part of rule identity', 'T11b second tools after a request is identity', 'T13a terminate rolls a replacement back', 'T13b terminate rolls an identical re-registration back', 'T13c terminate rolls an unregister back', 'T13d terminate rolls through a chain in any order', 'T14b own-generation unregister hides the rule at once', 'T14c older generation cannot register over a younger unregister', 'T16 registration does not raise the floor', 'T18 owner and model separators never merge two ids', 'T19 own-generation unregister outranks an older generation', 'T20a settle touches only its own owner', 'T20b own-generation unregister keeps the chain of its head', 'T20c settle keeps the link of the settled generation', 'T20f same-generation re-registration keeps the chain', 'T20g same-generation unregister keeps the chain', 'T20h settle keeps an unregister of a newer generation', 'T21a model case does not reset matched', 'T21b model match folds case like the id', 'T23 a second unregister of a tomb removes nothing', 'T24a register over its own generation tomb', 'T25b id with surrounding whitespace refused', 'T27 a repeated generation death changes nothing', 'T29a gone refuses an out-of-domain generation (undefined)', 'T29b gone refuses an out-of-domain generation (NaN)', 'T29c gone refuses an out-of-domain generation (Infinity)', 'T30a settle refuses an out-of-domain generation (undefined)', 'T30b settle refuses an out-of-domain generation (NaN)', 'T30c settle refuses an out-of-domain generation (Infinity)', 'T29d gone refuses an out-of-domain generation ("3")', 'T29e gone refuses an out-of-domain generation (object valueOf 3)', 'T29f gone refuses an out-of-domain generation (null)', 'T30d settle refuses an out-of-domain generation ("3")', 'T30e settle refuses an out-of-domain generation (object valueOf 3)', 'T30f settle refuses an out-of-domain generation (null)', 'T32 a repeated death of a dead generation keeps a newer live head', 'T33b a refused unregister writes one host log line', 'T29g gone refuses an out-of-domain generation (-1)', 'T29h gone refuses an out-of-domain generation (1.5)', 'T29i gone refuses an out-of-domain generation (2**53)', 'T30g settle refuses an out-of-domain generation (-1)', 'T30h settle refuses an out-of-domain generation (1.5)', 'T30i settle refuses an out-of-domain generation (2**53)', 'T37a unregister refuses generation -1', 'T37b unregister refuses generation 1.5', 'T37c unregister refuses generation 9007199254740992', 'T38 generation 0 accepted and removable by its term', 'T38 generation 1 accepted and removable by its term', 'T38 generation 9007199254740991 accepted and removable by its term']],
  ['M24 tools also applies live ops', 'var p=__ctlPick;__ctlPick=null;',
   'var p=__ctlPick;__ctlPick=null;if(p&&__ctlRules.length)p={ops:p.ops.concat(__ctlRules[__ctlRules.length-1].ops),sys:p.sys};',
   'T10b pick frozen between sys and tools'],
  ['M25 tools reads the live table', 'var p=__ctlPick;__ctlPick=null;',
   'var p=__ctlPick||{ops:__ctlRules.flatMap(function(r){return r.ops}),sys:!1};__ctlPick=null;', 'T10c tools without sys is identity',
   ['T11b second tools after a request is identity']],
  ['M26 replacement keeps the old rule', '__ctlRules[i]=cr;return', '__ctlRules[i]=r;return', 'T10f newer generation replaces the same id',
   ['T8 CRLF kept + rewritten', 'T9 sticky lastIndex reset', 'T8b array block rewritten', 'T8c tool rewritten', 'T10g old-generation rule lives until settle', 'T10j identical re-registration keeps matched', 'T11a flags are part of rule identity', 'T13a terminate rolls a replacement back', 'T18 owner and model separators never merge two ids', 'T20c settle keeps the link of the settled generation', 'T21a model case does not reset matched', 'T24a register over its own generation tomb', 'T27 a repeated generation death changes nothing', 'T32 a repeated death of a dead generation keeps a newer live head']],
  ['M27 settle removes nothing', 'r.gen<gen||r.tomb&&r.gen<=gen', '!1', 'T10g old-generation rule lives until settle',
   ['T11c sys resets the pick of an earlier request', 'T14a settle finalises an older-generation unregister']],
  ['M28 per-rule seniority disabled', 'if(r&&r.owner===o&&r.gen>g)return __ctlRepl;', 'if(!1)return __ctlRepl;', 'T10h younger generation refused with the named phrase',
   ['T14c older generation cannot register over a younger unregister', 'T16 registration does not raise the floor', 'T19 own-generation unregister outranks an older generation', 'T20b own-generation unregister keeps the chain of its head']],
  ['M29 settle raises no floor', 'if(!(owner in __ctlFloor)||gen>__ctlFloor[owner])__ctlFloor[owner]=gen;', '', 'T10i settle raises the generation floor',
   ['T12a register run refuses on its own', 'T12b unregister run refuses on its own', 'T20d a late settle never lowers the floor', 'T20e owner gone never lowers the floor', 'T26a settle buries dead generations below the floor']],
  ['M30 identical re-reg always replaces', 'if(!r.tomb&&__ctlSame(r.raw,cr.raw))cr.matched=r.matched;', '', 'T10j identical re-registration keeps matched',
   ['T13b terminate rolls an identical re-registration back', 'T21a model case does not reset matched']],
  ['M31 exhausted rollback keeps the dead head', 'if(v===void 0){__ctlRules.splice(i,1);return}', 'if(v===void 0)return;', 'T10k terminate removes exactly the dead generation',
   ['T17 settle trims the rollback chain', 'T22 settle trims a chain at depth three', 'T38 generation 0 accepted and removable by its term', 'T38 generation 1 accepted and removable by its term', 'T38 generation 9007199254740991 accepted and removable by its term']],
  ['M32 owner gone removes nothing', 'if(__ctlRules[i].owner===owner)__ctlRules.splice(i,1);', 'if(!1)__ctlRules.splice(i,1);', 'T10l owner gone removes every vertex',
   ['T15 owner gone raises the floor past the leaving generation']],
  // Фикс-волна #468 (Р6-Р13): по мутации на новый зуб.
  ['M33 flags left out of identity', 'K="find,pattern,flags,to,tool".split(",")', 'K="find,pattern,to,tool".split(",")', 'T11a flags are part of rule identity'],
  ['M34 tools keeps the pick', '__ctlPick=null;if(!p||', 'if(!p||', 'T11b second tools after a request is identity'],
  ['M35 sys keeps an earlier pick', '__ctlSeen++;__ctlPick=null;', '__ctlSeen++;', 'T11c sys resets the pick of an earlier request'],
  ['M36 register run skips the call check', 'try{var m=__ctlCallBad(e,c,!0);', 'try{var m=__ctlBad(e);', 'T12a register run refuses on its own',
   ['T14c older generation cannot register over a younger unregister', 'T19 own-generation unregister outranks an older generation', 'T33a a refused register writes one host log line per call', 'T34 a throwing host log never replaces the refusal', 'T36a register refuses generation -1', 'T36b register refuses generation 1.5', 'T36c register refuses generation 9007199254740992', 'T38 generation -1 refused with no rule stored', 'T38 generation 1.5 refused with no rule stored', 'T38 generation 9007199254740992 refused with no rule stored', 'T38 generation NaN refused with no rule stored', 'T38 generation "3" refused with no rule stored']],
  ['M37 unregister run skips the call check', 'try{var m=__ctlCallBad(e,c,!1);', 'try{var m=__ctlOwnBad(e,c);', 'T12b unregister run refuses on its own',
   ['T37a unregister refuses generation -1', 'T37b unregister refuses generation 1.5', 'T37c unregister refuses generation 9007199254740992']],
  ['M38 rollback carries matched across different text', 'if(!v.tomb&&!r.tomb&&__ctlSame(v.raw,r.raw))', 'if(!v.tomb&&!r.tomb)', 'T13a terminate rolls a replacement back'],
  ['M39 rollback drops the current matched', 'if(!v.tomb&&!r.tomb&&__ctlSame(v.raw,r.raw))v.matched=r.matched;', '', 'T13b terminate rolls an identical re-registration back'],
  ['M40 older-rule unregister keeps no rollback target', 'prev:r.gen===g?r.prev:r}', 'prev:r.gen===g?r.prev:void 0}', 'T13c terminate rolls an unregister back',
   ['T20h settle keeps an unregister of a newer generation', 'T24a register over its own generation tomb']],
  ['M41 rollback skips one dead generation only', 'while(v&&D&&D[v.gen])v=v.prev;', 'if(v&&D&&D[v.gen])v=v.prev;', 'T13d terminate rolls through a chain in any order'],
  ['M42 settle keeps a finalised unregister', '||r.tomb&&r.gen<=gen)', ')', 'T14a settle finalises an older-generation unregister',
   ['T11c sys resets the pick of an earlier request']],
  ['M43 own-generation unregister keeps the rule visible', '__ctlRules[i]={id:id,owner:owner,gen:g,tomb:!0,', 'if(r.gen!==g)__ctlRules[i]={id:id,owner:owner,gen:g,tomb:!0,', 'T14b own-generation unregister hides the rule at once',
   ['T11c sys resets the pick of an earlier request', 'T19 own-generation unregister outranks an older generation', 'T20b own-generation unregister keeps the chain of its head']],
  ['M44 seniority ignores an unregister', 'if(r&&r.owner===o&&r.gen>g)', 'if(r&&!r.tomb&&r.owner===o&&r.gen>g)', 'T14c older generation cannot register over a younger unregister',
   ['T19 own-generation unregister outranks an older generation', 'T20b own-generation unregister keeps the chain of its head']],
  ['M45 owner gone floor stops at the leaving generation', '__ctlFloor[owner]=gen+1;', '__ctlFloor[owner]=gen;', 'T15 owner gone raises the floor past the leaving generation'],
  ['M46 registration raises the floor', 'cr=__ctlCompile(e,o),i;cr.gen=g;', 'cr=__ctlCompile(e,o),i;cr.gen=g;if(!(o in __ctlFloor)||g>__ctlFloor[o])__ctlFloor[o]=g;', 'T16 registration does not raise the floor'],
  ['M48 id without the owner length', 'return o.length+":"+o+":"+', 'return o+":"+', 'T18 owner and model separators never merge two ids',
   ['T21b model match folds case like the id']],
  ['M47 settle keeps the rollback chain', 'for(var v=r;v.prev;v=v.prev)if(v.prev.gen<gen){v.prev=void 0;break}', '', 'T17 settle trims the rollback chain',
   ['T22 settle trims a chain at depth three']],
  // Фикс-волна #468-FIX2 (А2-А4, Q1-Q4, Q-AR4): по мутации на новый зуб;
  // M50-M57 -- сценарии X3..X14 свидетеля opus.
  ['M49 own-generation unregister without a chain deletes', '__ctlRules[i]={id:id,owner:owner,gen:g,tomb:!0,', 'if(r.gen===g&&!r.prev)__ctlRules.splice(i,1);else __ctlRules[i]={id:id,owner:owner,gen:g,tomb:!0,', 'T19 own-generation unregister outranks an older generation'],
  ['M50 settle touches every owner', 'if(r.owner!==owner)continue;if(r.gen<gen', 'if(r.gen<gen', 'T20a settle touches only its own owner'],
  ['M51 own-generation unregister with a chain deletes', '__ctlRules[i]={id:id,owner:owner,gen:g,tomb:!0,', 'if(r.gen===g&&r.prev)__ctlRules.splice(i,1);else __ctlRules[i]={id:id,owner:owner,gen:g,tomb:!0,', 'T20b own-generation unregister keeps the chain of its head',
   ['T20g same-generation unregister keeps the chain']],
  ['M52 settle trims the link of the settled generation', 'if(v.prev.gen<gen){v.prev=void 0;break}', 'if(v.prev.gen<=gen){v.prev=void 0;break}', 'T20c settle keeps the link of the settled generation',
   ['T20h settle keeps an unregister of a newer generation']],
  ['M53 settle may lower the floor', 'if(!(owner in __ctlFloor)||gen>__ctlFloor[owner])__ctlFloor[owner]=gen;', '__ctlFloor[owner]=gen;', 'T20d a late settle never lowers the floor'],
  ['M54 owner gone may lower the floor', '(!(owner in __ctlFloor)||gen+1>__ctlFloor[owner])', '(!0)', 'T20e owner gone never lowers the floor'],
  ['M55 same-generation re-registration drops the chain', 'cr.prev=r.gen===g?r.prev:r;', 'cr.prev=r.gen===g?void 0:r;', 'T20f same-generation re-registration keeps the chain',
   ['T24a register over its own generation tomb']],
  ['M56 same-generation unregister drops the chain', 'prev:r.gen===g?r.prev:r}', 'prev:r.gen===g?void 0:r}', 'T20g same-generation unregister keeps the chain'],
  ['M57 settle drops an unregister of a newer generation', 'r.gen<gen||r.tomb&&r.gen<=gen', 'r.gen<gen||r.tomb', 'T20h settle keeps an unregister of a newer generation'],
  ['M58 model identity keeps exact case', 'if(a.model.toLowerCase()!==b.model.toLowerCase()||', 'if(a.model!==b.model||', 'T21a model case does not reset matched'],
  ['M59 model predicate folds case without unicode', '","iu"),ops:ops,', '","i"),ops:ops,', 'T21b model match folds case like the id'],
  ['M60 settle trims one link only', 'for(var v=r;v.prev;v=v.prev)if(v.prev.gen<gen){v.prev=void 0;break}', 'if(r.prev&&r.prev.gen<gen){r.prev=void 0}', 'T22 settle trims a chain at depth three'],
  ['M61 unregister of a tomb reports a removal', 'if(r.owner!==owner||r.tomb)return {removed:!1};', 'if(r.owner!==owner)return {removed:!1};', 'T23 a second unregister of a tomb removes nothing'],
  ['M62 register over a tomb reads its missing text', 'if(!r.tomb&&__ctlSame(r.raw,cr.raw))cr.matched', 'if(__ctlSame(r.raw,cr.raw))cr.matched', 'T24a register over its own generation tomb',
   ['T8 CRLF kept + rewritten', 'T9 sticky lastIndex reset', 'T8b array block rewritten', 'T8c tool rewritten']],
  ['M63 register run lets an exception escape', 'Promise.resolve({id:cr.id})}catch(x){return Promise.reject(__ctlErr(x))}', 'Promise.resolve({id:cr.id})}catch(x){throw x}', 'T24b run turns an exception into a rejection'],
  ['M64 unregister run lets an exception escape', 'c.environmentId))}catch(x){return Promise.reject(__ctlErr(x))}', 'c.environmentId))}catch(x){throw x}', 'T24b run turns an exception into a rejection'],
  ['M65 padded model accepted', 'if(r.model!==r.model.trim())return', 'if(!1)return', 'T25a model with surrounding whitespace refused'],
  ['M66 padded id accepted', 'if(e.id!==e.id.trim())return', 'if(!1)return', 'T25b id with surrounding whitespace refused'],
  ['M67 settle keeps dead generations below the floor', 'gen;__ctlBury(owner);', 'gen;', 'T26a settle buries dead generations below the floor'],
  ['M68 owner gone keeps dead generations below the floor', 'gen+1;__ctlBury(owner)}', 'gen+1}', 'T26b owner gone buries dead generations below the floor'],
  // Б2 (#468-FIX3): гард поколения снимается в трёх точках входа. b-вариант
  // заменяет единый дом `__ctlGen` (tweakcc-patch.js:4720) встроенной проверкой
  // typeof+isFinite: NaN и Infinity пропускает (isFinite на них падает, а
  // ветка отказа собирается через &&), undefined и прочие не-числа typeof
  // продолжает отклонять.
  ['M69 term accepts an out-of-domain generation', '{owner=String(owner);if(!__ctlGen(h))return __ctlNoGen("term",owner,h);', '{owner=String(owner);', 'T28a term refuses an out-of-domain generation (undefined)', ['T28g term refuses an out-of-domain generation (-1)', 'T28h term refuses an out-of-domain generation (1.5)', 'T28i term refuses an out-of-domain generation (2**53)', 'T28b term refuses an out-of-domain generation (NaN)', 'T28c term refuses an out-of-domain generation (Infinity)', 'T28d term refuses an out-of-domain generation ("3")', 'T28e term refuses an out-of-domain generation (object valueOf 3)', 'T28f term refuses an out-of-domain generation (null)', 'T34 a throwing host log never replaces the refusal']],
  ['M69b term accepts NaN and Infinity', 'if(!__ctlGen(h))return __ctlNoGen("term",owner,h);', 'if(typeof h!=="number"||Number.isFinite(h)&&(!Number.isSafeInteger(h)||h<0))return __ctlNoGen("term",owner,h);', 'T28b term refuses an out-of-domain generation (NaN)', ['T28c term refuses an out-of-domain generation (Infinity)']],
  ['M70 owner gone accepts an out-of-domain generation', '__ctlGone(owner,gen){owner=String(owner);if(!__ctlGen(gen))return __ctlNoGen("gone",owner,gen);', '__ctlGone(owner,gen){owner=String(owner);', 'T29a gone refuses an out-of-domain generation (undefined)', ['T29g gone refuses an out-of-domain generation (-1)', 'T29h gone refuses an out-of-domain generation (1.5)', 'T29i gone refuses an out-of-domain generation (2**53)', 'T29b gone refuses an out-of-domain generation (NaN)', 'T29c gone refuses an out-of-domain generation (Infinity)', 'T29d gone refuses an out-of-domain generation ("3")', 'T29e gone refuses an out-of-domain generation (object valueOf 3)', 'T29f gone refuses an out-of-domain generation (null)', 'T34 a throwing host log never replaces the refusal']],
  ['M70b owner gone accepts NaN and Infinity', 'if(!__ctlGen(gen))return __ctlNoGen("gone",owner,gen);', 'if(typeof gen!=="number"||Number.isFinite(gen)&&(!Number.isSafeInteger(gen)||gen<0))return __ctlNoGen("gone",owner,gen);', 'T29b gone refuses an out-of-domain generation (NaN)', ['T29c gone refuses an out-of-domain generation (Infinity)', 'T34 a throwing host log never replaces the refusal']],
  ['M71 settle accepts an out-of-domain generation', '__ctlSettle(owner,gen){owner=String(owner);if(!__ctlGen(gen))return __ctlNoGen("settle",owner,gen);', '__ctlSettle(owner,gen){owner=String(owner);', 'T30a settle refuses an out-of-domain generation (undefined)', ['T30g settle refuses an out-of-domain generation (-1)', 'T30h settle refuses an out-of-domain generation (1.5)', 'T30i settle refuses an out-of-domain generation (2**53)', 'T30b settle refuses an out-of-domain generation (NaN)', 'T30c settle refuses an out-of-domain generation (Infinity)', 'T30d settle refuses an out-of-domain generation ("3")', 'T30e settle refuses an out-of-domain generation (object valueOf 3)', 'T30f settle refuses an out-of-domain generation (null)', 'T34 a throwing host log never replaces the refusal']],
  ['M71b settle accepts NaN and Infinity', 'if(!__ctlGen(gen))return __ctlNoGen("settle",owner,gen);', 'if(typeof gen!=="number"||Number.isFinite(gen)&&(!Number.isSafeInteger(gen)||gen<0))return __ctlNoGen("settle",owner,gen);', 'T30b settle refuses an out-of-domain generation (NaN)', ['T30c settle refuses an out-of-domain generation (Infinity)']],
  // Б1 (#468-FIX3): повторная смерть того же поколения откатывает и старшие
  // живые вершины владельца.
  ['M72 a death bleeds into the previous generation', '(__ctlDead[owner]||(__ctlDead[owner]=Object.create(null)))[h]=1;', '(__ctlDead[owner]||(__ctlDead[owner]=Object.create(null)))[h]=1,__ctlDead[owner][h-1]=1;', 'T27 a repeated generation death changes nothing', ['T13a terminate rolls a replacement back', 'T13b terminate rolls an identical re-registration back', 'T13c terminate rolls an unregister back', 'T13d terminate rolls through a chain in any order', 'T20c settle keeps the link of the settled generation', 'T20f same-generation re-registration keeps the chain', 'T20g same-generation unregister keeps the chain', 'T24a register over its own generation tomb', 'T26b owner gone buries dead generations below the floor']],
  // третья ценность каждой тройки -- свой первичный зуб: Infinity проходит
  // монтажную гард, но не полную.
  ['M69c term accepts Infinity', 'if(!__ctlGen(h))return __ctlNoGen("term",owner,h);', 'if(h!==1/0&&(!Number.isSafeInteger(h)||h<0))return __ctlNoGen("term",owner,h);', 'T28c term refuses an out-of-domain generation (Infinity)'],
  ['M70c owner gone accepts Infinity', 'if(!__ctlGen(gen))return __ctlNoGen("gone",owner,gen);', 'if(gen!==1/0&&(!Number.isSafeInteger(gen)||gen<0))return __ctlNoGen("gone",owner,gen);', 'T29c gone refuses an out-of-domain generation (Infinity)'],
  ['M71c settle accepts Infinity', 'if(!__ctlGen(gen))return __ctlNoGen("settle",owner,gen);', 'if(gen!==1/0&&(!Number.isSafeInteger(gen)||gen<0))return __ctlNoGen("settle",owner,gen);', 'T30c settle refuses an out-of-domain generation (Infinity)'],
  // Г5 (#468-FIX4): не-число. Базовый вариант (M73/M74/M75) снимает числовую
  // половину дома `__ctlGen` и гардит приведением Number(): "3", объект с
  // valueOf и null проходят как целые; b-вариант пускает ровно null,
  // c-вариант — ровно объект.
  ['M73 term guard without typeof', 'if(!__ctlGen(h))return __ctlNoGen("term",owner,h);', 'if(!Number.isSafeInteger(Number(h))||h<0)return __ctlNoGen("term",owner,h);', 'T28d term refuses an out-of-domain generation ("3")', ['T28e term refuses an out-of-domain generation (object valueOf 3)', 'T28f term refuses an out-of-domain generation (null)']],
  ['M73b term accepts null', 'if(!__ctlGen(h))return __ctlNoGen("term",owner,h);', 'if(h!==null&&(!Number.isSafeInteger(h)||h<0))return __ctlNoGen("term",owner,h);', 'T28f term refuses an out-of-domain generation (null)'],
  ['M73c term accepts an object', 'if(!__ctlGen(h))return __ctlNoGen("term",owner,h);', 'if(!(typeof h==="object"&&h!==null)&&(!Number.isSafeInteger(h)||h<0))return __ctlNoGen("term",owner,h);', 'T28e term refuses an out-of-domain generation (object valueOf 3)'],
  ['M74 owner gone guard without typeof', 'if(!__ctlGen(gen))return __ctlNoGen("gone",owner,gen);', 'if(!Number.isSafeInteger(Number(gen))||gen<0)return __ctlNoGen("gone",owner,gen);', 'T29d gone refuses an out-of-domain generation ("3")', ['T29e gone refuses an out-of-domain generation (object valueOf 3)', 'T29f gone refuses an out-of-domain generation (null)']],
  ['M74b owner gone accepts null', 'if(!__ctlGen(gen))return __ctlNoGen("gone",owner,gen);', 'if(gen!==null&&(!Number.isSafeInteger(gen)||gen<0))return __ctlNoGen("gone",owner,gen);', 'T29f gone refuses an out-of-domain generation (null)'],
  ['M74c owner gone accepts an object', 'if(!__ctlGen(gen))return __ctlNoGen("gone",owner,gen);', 'if(!(typeof gen==="object"&&gen!==null)&&(!Number.isSafeInteger(gen)||gen<0))return __ctlNoGen("gone",owner,gen);', 'T29e gone refuses an out-of-domain generation (object valueOf 3)'],
  ['M75 settle guard without typeof', 'if(!__ctlGen(gen))return __ctlNoGen("settle",owner,gen);', 'if(!Number.isSafeInteger(Number(gen))||gen<0)return __ctlNoGen("settle",owner,gen);', 'T30d settle refuses an out-of-domain generation ("3")', ['T30e settle refuses an out-of-domain generation (object valueOf 3)', 'T30f settle refuses an out-of-domain generation (null)']],
  ['M75b settle accepts null', 'if(!__ctlGen(gen))return __ctlNoGen("settle",owner,gen);', 'if(gen!==null&&(!Number.isSafeInteger(gen)||gen<0))return __ctlNoGen("settle",owner,gen);', 'T30f settle refuses an out-of-domain generation (null)'],
  ['M75c settle accepts an object', 'if(!__ctlGen(gen))return __ctlNoGen("settle",owner,gen);', 'if(!(typeof gen==="object"&&gen!==null)&&(!Number.isSafeInteger(gen)||gen<0))return __ctlNoGen("settle",owner,gen);', 'T30e settle refuses an out-of-domain generation (object valueOf 3)'],
  // Г6 (#468-FIX4): Ma свидетеля opus -- повторная смерть мёртвого поколения
  // сносит более новые вершины владельца.
  ['M76 a repeated death drops newer heads', '(__ctlDead[owner]||(__ctlDead[owner]=Object.create(null)))[h]=1;', 'var __was=__ctlDead[owner]&&__ctlDead[owner][h];(__ctlDead[owner]||(__ctlDead[owner]=Object.create(null)))[h]=1;if(__was)for(var j=__ctlRules.length-1;j>=0;j--)if(__ctlRules[j].owner===owner&&__ctlRules[j].gen>h)__ctlRules.splice(j,1);', 'T32 a repeated death of a dead generation keeps a newer live head'],
  // Г4 (#468-FIX4): строка лога отказа.
  ['M77 a refused call is not logged', 'if(m!==void 0)__ctlSay(reg?"register":"unregister",c&&c.plugin,m);return m}', 'return m}', 'T33a a refused register writes one host log line per call', ['T33b a refused unregister writes one host log line']],
  ['M78 the refused operation is misnamed', 'reg?"register":"unregister"', '"register"', 'T33b a refused unregister writes one host log line'],
  ['M79 an accepted call is logged', 'if(m!==void 0)__ctlSay(', 'if(!0)__ctlSay(', 'T33c accepted calls write no host log line',
   ['T28a term refuses an out-of-domain generation (undefined)', 'T28b term refuses an out-of-domain generation (NaN)', 'T28c term refuses an out-of-domain generation (Infinity)', 'T28d term refuses an out-of-domain generation ("3")', 'T28e term refuses an out-of-domain generation (object valueOf 3)', 'T28f term refuses an out-of-domain generation (null)', 'T29a gone refuses an out-of-domain generation (undefined)', 'T29b gone refuses an out-of-domain generation (NaN)', 'T29c gone refuses an out-of-domain generation (Infinity)', 'T29d gone refuses an out-of-domain generation ("3")', 'T29e gone refuses an out-of-domain generation (object valueOf 3)', 'T29f gone refuses an out-of-domain generation (null)', 'T30a settle refuses an out-of-domain generation (undefined)', 'T30b settle refuses an out-of-domain generation (NaN)', 'T30c settle refuses an out-of-domain generation (Infinity)', 'T30d settle refuses an out-of-domain generation ("3")', 'T30e settle refuses an out-of-domain generation (object valueOf 3)', 'T30f settle refuses an out-of-domain generation (null)',
    'T33b a refused unregister writes one host log line', 'T28g term refuses an out-of-domain generation (-1)', 'T28h term refuses an out-of-domain generation (1.5)', 'T28i term refuses an out-of-domain generation (2**53)', 'T29g gone refuses an out-of-domain generation (-1)', 'T29h gone refuses an out-of-domain generation (1.5)', 'T29i gone refuses an out-of-domain generation (2**53)', 'T30g settle refuses an out-of-domain generation (-1)', 'T30h settle refuses an out-of-domain generation (1.5)', 'T30i settle refuses an out-of-domain generation (2**53)']],
  ['M80 a throwing log escapes the door', ')}catch(x){}}function __ctlNoGen', ')}finally{}}function __ctlNoGen', 'T34 a throwing host log never replaces the refusal'],
  ['M81 a generation refusal is not logged', 'function __ctlNoGen(op,owner,g){__ctlSay(op,owner,__ctlBadGen,g,!0);return', 'function __ctlNoGen(op,owner,g){return', 'T28a term refuses an out-of-domain generation (undefined)',
   ['T28b term refuses an out-of-domain generation (NaN)', 'T28c term refuses an out-of-domain generation (Infinity)', 'T28d term refuses an out-of-domain generation ("3")', 'T28e term refuses an out-of-domain generation (object valueOf 3)', 'T28f term refuses an out-of-domain generation (null)',
    'T29a gone refuses an out-of-domain generation (undefined)', 'T29b gone refuses an out-of-domain generation (NaN)', 'T29c gone refuses an out-of-domain generation (Infinity)', 'T29d gone refuses an out-of-domain generation ("3")', 'T29e gone refuses an out-of-domain generation (object valueOf 3)', 'T29f gone refuses an out-of-domain generation (null)',
    'T30a settle refuses an out-of-domain generation (undefined)', 'T30b settle refuses an out-of-domain generation (NaN)', 'T30c settle refuses an out-of-domain generation (Infinity)', 'T30d settle refuses an out-of-domain generation ("3")', 'T30e settle refuses an out-of-domain generation (object valueOf 3)', 'T30f settle refuses an out-of-domain generation (null)', 'T28g term refuses an out-of-domain generation (-1)', 'T28h term refuses an out-of-domain generation (1.5)', 'T28i term refuses an out-of-domain generation (2**53)', 'T29g gone refuses an out-of-domain generation (-1)', 'T29h gone refuses an out-of-domain generation (1.5)', 'T29i gone refuses an out-of-domain generation (2**53)', 'T30g settle refuses an out-of-domain generation (-1)', 'T30h settle refuses an out-of-domain generation (1.5)', 'T30i settle refuses an out-of-domain generation (2**53)']],
  ['M82 the refused value loses its number', '(typeof got==="number"?String(got):typeof got)', '(typeof got)', 'T28b term refuses an out-of-domain generation (NaN)',
   ['T28c term refuses an out-of-domain generation (Infinity)', 'T29b gone refuses an out-of-domain generation (NaN)', 'T29c gone refuses an out-of-domain generation (Infinity)', 'T30b settle refuses an out-of-domain generation (NaN)', 'T30c settle refuses an out-of-domain generation (Infinity)', 'T28g term refuses an out-of-domain generation (-1)', 'T28h term refuses an out-of-domain generation (1.5)', 'T28i term refuses an out-of-domain generation (2**53)', 'T29g gone refuses an out-of-domain generation (-1)', 'T29h gone refuses an out-of-domain generation (1.5)', 'T29i gone refuses an out-of-domain generation (2**53)', 'T30g settle refuses an out-of-domain generation (-1)', 'T30h settle refuses an out-of-domain generation (1.5)', 'T30i settle refuses an out-of-domain generation (2**53)']],
  ['M83 term accepts -1', 'if(!__ctlGen(h))return __ctlNoGen("term",owner,h);', 'if(!Number.isSafeInteger(h))return __ctlNoGen("term",owner,h);', 'T28g term refuses an out-of-domain generation (-1)'],
  ['M84 term accepts 1.5', 'if(!__ctlGen(h))return __ctlNoGen("term",owner,h);', 'if(!Number.isFinite(h)||h>Number.MAX_SAFE_INTEGER||h<0)return __ctlNoGen("term",owner,h);', 'T28h term refuses an out-of-domain generation (1.5)'],
  ['M85 term accepts 2**53', 'if(!__ctlGen(h))return __ctlNoGen("term",owner,h);', 'if(!Number.isInteger(h)||h<0)return __ctlNoGen("term",owner,h);', 'T28i term refuses an out-of-domain generation (2**53)'],
  ['M86 gone accepts -1', 'if(!__ctlGen(gen))return __ctlNoGen("gone",owner,gen);', 'if(!Number.isSafeInteger(gen))return __ctlNoGen("gone",owner,gen);', 'T29g gone refuses an out-of-domain generation (-1)'],
  ['M87 gone accepts 1.5', 'if(!__ctlGen(gen))return __ctlNoGen("gone",owner,gen);', 'if(!Number.isFinite(gen)||gen>Number.MAX_SAFE_INTEGER||gen<0)return __ctlNoGen("gone",owner,gen);', 'T29h gone refuses an out-of-domain generation (1.5)'],
  ['M88 gone accepts 2**53', 'if(!__ctlGen(gen))return __ctlNoGen("gone",owner,gen);', 'if(!Number.isInteger(gen)||gen<0)return __ctlNoGen("gone",owner,gen);', 'T29i gone refuses an out-of-domain generation (2**53)'],
  ['M89 settle accepts -1', 'if(!__ctlGen(gen))return __ctlNoGen("settle",owner,gen);', 'if(!Number.isSafeInteger(gen))return __ctlNoGen("settle",owner,gen);', 'T30g settle refuses an out-of-domain generation (-1)'],
  ['M90 settle accepts 1.5', 'if(!__ctlGen(gen))return __ctlNoGen("settle",owner,gen);', 'if(!Number.isFinite(gen)||gen>Number.MAX_SAFE_INTEGER||gen<0)return __ctlNoGen("settle",owner,gen);', 'T30h settle refuses an out-of-domain generation (1.5)'],
  ['M91 settle accepts 2**53', 'if(!__ctlGen(gen))return __ctlNoGen("settle",owner,gen);', 'if(!Number.isInteger(gen)||gen<0)return __ctlNoGen("settle",owner,gen);', 'T30i settle refuses an out-of-domain generation (2**53)'],
  ['M92 death exception escapes', 'catch(x){__ctlSay("term",owner,"generation death failed")}', 'catch(x){throw x}', 'T35 a throwing death keeps subsequent deaths and unloads running'],
  ['M93 negative generations admitted at all inputs', 'Number.isSafeInteger(g)&&g>=0', 'Number.isSafeInteger(g)&&true',
    'T36a register refuses generation -1', ['T37a unregister refuses generation -1',
      'T28g term refuses an out-of-domain generation (-1)', 'T29g gone refuses an out-of-domain generation (-1)',
      'T30g settle refuses an out-of-domain generation (-1)', 'T38 generation -1 refused with no rule stored']],
  ['M94 fractional and unsafe generations admitted at all inputs', 'Number.isSafeInteger(g)&&g>=0', 'Number.isFinite(g)&&g>=0',
    'T36b register refuses generation 1.5', ['T36c register refuses generation 9007199254740992',
      'T37b unregister refuses generation 1.5', 'T37c unregister refuses generation 9007199254740992',
      'T28h term refuses an out-of-domain generation (1.5)', 'T28i term refuses an out-of-domain generation (2**53)',
      'T29h gone refuses an out-of-domain generation (1.5)', 'T29i gone refuses an out-of-domain generation (2**53)',
      'T30h settle refuses an out-of-domain generation (1.5)', 'T30i settle refuses an out-of-domain generation (2**53)',
      'T38 generation 1.5 refused with no rule stored', 'T38 generation 9007199254740992 refused with no rule stored']],
  ['M95 unsafe generation admitted', 'Number.isSafeInteger(g)&&g>=0', 'g===2**53||Number.isSafeInteger(g)&&g>=0',
    'T36c register refuses generation 9007199254740992', ['T37c unregister refuses generation 9007199254740992',
      'T28i term refuses an out-of-domain generation (2**53)', 'T29i gone refuses an out-of-domain generation (2**53)',
      'T30i settle refuses an out-of-domain generation (2**53)', 'T38 generation 9007199254740992 refused with no rule stored']],
  ['M96 unregister accepts -1', 'if(!__ctlGen(g))return "the caller carries no module generation (environmentId)";',
    'if(!__ctlGen(g)&&!(reg===false&&g===-1))return "the caller carries no module generation (environmentId)";',
    'T37a unregister refuses generation -1'],
  ['M97 unregister accepts 1.5', 'if(!__ctlGen(g))return "the caller carries no module generation (environmentId)";',
    'if(!__ctlGen(g)&&!(reg===false&&g===1.5))return "the caller carries no module generation (environmentId)";',
    'T37b unregister refuses generation 1.5'],
  ['M98 unregister accepts 2**53', 'if(!__ctlGen(g))return "the caller carries no module generation (environmentId)";',
    'if(!__ctlGen(g)&&!(reg===false&&g===2**53))return "the caller carries no module generation (environmentId)";',
    'T37c unregister refuses generation 9007199254740992'],
  ['M99 generation zero refused', 'Number.isSafeInteger(g)&&g>=0', 'Number.isSafeInteger(g)&&g>0',
    'T38 generation 0 accepted and removable by its term'],
  // #468-FIX7 (П5): у каждой строки перечня T38 своя адресная мутация —
  // M100-M102 пропускают отказанное значение только через register,
  // M103-M104 расширяют единый дом `__ctlGen` одним значением,
  // M105-M106 снимают term у принятого поколения.
  ['M100 register accepts -1', 'if(!__ctlGen(g))return "the caller carries no module generation (environmentId)";',
    'if(!__ctlGen(g)&&!(reg===true&&g===-1))return "the caller carries no module generation (environmentId)";',
    'T38 generation -1 refused with no rule stored', ['T36a register refuses generation -1']],
  ['M101 register accepts 1.5', 'if(!__ctlGen(g))return "the caller carries no module generation (environmentId)";',
    'if(!__ctlGen(g)&&!(reg===true&&g===1.5))return "the caller carries no module generation (environmentId)";',
    'T38 generation 1.5 refused with no rule stored', ['T36b register refuses generation 1.5']],
  ['M102 register accepts 2**53', 'if(!__ctlGen(g))return "the caller carries no module generation (environmentId)";',
    'if(!__ctlGen(g)&&!(reg===true&&g===2**53))return "the caller carries no module generation (environmentId)";',
    'T38 generation 9007199254740992 refused with no rule stored', ['T36c register refuses generation 9007199254740992']],
  ['M103 generation domain accepts NaN', 'Number.isSafeInteger(g)&&g>=0', 'Number.isSafeInteger(g)&&g>=0||Number.isNaN(g)',
    'T38 generation NaN refused with no rule stored', ['T28b term refuses an out-of-domain generation (NaN)',
      'T29b gone refuses an out-of-domain generation (NaN)', 'T30b settle refuses an out-of-domain generation (NaN)',
      'T34 a throwing host log never replaces the refusal']],
  ['M104 generation domain accepts "3"', 'Number.isSafeInteger(g)&&g>=0', 'Number.isSafeInteger(g)&&g>=0||g==="3"',
    'T38 generation "3" refused with no rule stored', ['T28d term refuses an out-of-domain generation ("3")',
      'T29d gone refuses an out-of-domain generation ("3")', 'T30d settle refuses an out-of-domain generation ("3")']],
  ['M105 term refuses generation 1', 'if(!__ctlGen(h))return __ctlNoGen("term",owner,h);',
    'if(!__ctlGen(h)||h===1)return __ctlNoGen("term",owner,h);',
    'T38 generation 1 accepted and removable by its term', ['T33c accepted calls write no host log line']],
  ['M106 term refuses the top generation 2**53-1', 'if(!__ctlGen(h))return __ctlNoGen("term",owner,h);',
    'if(!__ctlGen(h)||h===2**53-1)return __ctlNoGen("term",owner,h);',
    'T38 generation 9007199254740991 accepted and removable by its term'],
];

// CONSTRAINT: the scope is read and refused BEFORE the baseline battery: no
// scope, or an unknown name, runs nothing (CENSUS.md contract).
let SEL;
try { SEL = scopeFromArgv(process.argv.slice(2), MUT.map(([name]) => name.split(' ')[0]), PREFIX); } catch (x) { refuse(PREFIX, x); }
// CONSTRAINT: a mutation is measured by its exact red set against a green
// baseline; the full suite inside that selected unit is part of its verdict.
const base0 = await run(base, ALL);
const red0 = base0.filter((r) => !r.ok).map((r) => r.name);
console.log('BASELINE teeth=%d red=%s', base0.length, red0.length ? red0.join(' | ') : 'none');
const KNOWN = new Set(teethNames(base0));

// CONSTRAINT: якорь без ЕДИНСТВЕННОСТИ — отказ батареи, не заметка: ноль
// вхождений означает уехавший сайт, два и более — правку не того сайта.
const badAnchor = MUT
  .filter(([name]) => SEL.has(name.split(' ')[0]))
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
const unknown = MUT.flatMap(([name, , , expect, extra = []]) =>
  [expect, ...extra].filter((n) => !KNOWN.has(n)).map((n) => name + ' -> ' + n));
if (unknown.length) {
  console.log(`${PREFIX} REFUSED=expect-not-a-tooth detail=${unknown.join('; ')}`);
  process.exit(2);
}

// CONSTRAINT: число мутаций — ДЛИНА этого массива результатов; инертная
// мутация (код не изменился либо зуб не покраснел) — ОТКАЗ батареи, не пропуск.
const results = [];
for (const [name, anchor, repl, expect, extra = []] of MUT) {
  if (!SEL.has(name.split(' ')[0])) continue;
  const c = base.replace(anchor, repl);
  if (c === base) {
    console.log('INERT  ', name, '<-- mutation did not change the code');
    results.push({ name, red: false });
    continue;
  }
  let red;
  try { red = (await run(c, ALL)).filter((r) => !r.ok).map((r) => r.name); }
  catch (e) { red = ['THREW: ' + e.message]; }
  // CONSTRAINT: совпадение по ПОЛНОМУ имени зуба — сравнение по префиксу `T3`
  // зачло бы красноту соседей `T3b`/`T3c`/`T3d` как попадание мутации.
  const want = new Set([expect, ...extra]);
  const missing = [...want].filter((n) => !red.includes(n));
  const surplus = red.filter((n) => !want.has(n));
  const exact = missing.length === 0 && surplus.length === 0;
  results.push({ name, red: exact });
  if (exact) console.log('RED    ', name, '->', red.join(' | '));
  else console.log('INEXACT', name, '-> missing =', missing.length ? missing.join(' | ') : 'none',
    '; surplus =', surplus.length ? surplus.join(' | ') : 'none');
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
console.log(`\n${PREFIX} scope=${[...SEL].join(',')} RED=${ok} FAILED=${results.length - ok} BASELINE_RED=${red0.length}`);
process.exit((results.length - ok || red0.length) ? 1 : 0);
