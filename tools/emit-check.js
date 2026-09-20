// Exit codes -- the kit's shared table (see the top of claude-patch-all.sh):
//   0  every live gate green
//   1  a refusal on the merits: the template frame or the carrier-door
//      guard diverged
//   2  the instrument cannot measure: probes/judge/body.json is unreadable,
//      or no carrier gate is left to count
//   3  no subject by declaration: every carrier gate in the text belongs to
//      a step switched off in tools/our-steps-off.txt -- there is nothing
//      live to guard, and a green "in place" line here would vouch for a
//      gate the kit itself declares dead
//
// What this tool guards. The probe family (judge consultation, form, idle
// watcher, the shared core) left the patch lane in wave #328: its carrier is
// the mod, and an image built by this kit no longer carries those splices.
// Parsing the injected code retired with them. Two subjects remain that this
// tree still writes:
//   * probes/judge/body.json -- the request template the mod-side probe
//     reads (scripts/probes-sync.sh ships it to the probes home). Its frame
//     must keep the three placeholders, because the truncation notice lives
//     in the header and nowhere else: a template that drops it sends the
//     model a trimmed payload that looks whole.
//   * the carrier doors of the patch source. A splice that stands down at
//     CLAUDE_*_CARRIER=mod must also check the function-hooks door
//     (CLAUDE_CODE_ENABLE_FUNCTION_HOOKS): the mod runs in a separate realm,
//     so CARRIER=mod alone does not prove it loaded, and standing down
//     without that proof leaves the probe with no carrier at all. This
//     class parses fine when the guard is dropped, so it is asserted here
//     structurally (audit #51 F1). The carrier/guard/doorDecl patterns are
//     GENERALIZED on purpose: a new CLAUDE_*_CARRIER gate of any shape is
//     still counted. The EXPECTED count is no longer a constant: it is the
//     gates in the text MINUS the gates of steps switched off in
//     tools/our-steps-off.txt (the same registry the pipeline reads).
//     One gate is left -- the judge system-prompt rule (patch step 26), and
//     step 26 is switched off in the registry, so this tree's live answer
//     today is the exit-3 subject line, never a green one.
const fs = require('fs');
const path = require('path');
// Разбор реестра выключенных шагов -- ЕДИНСТВЕННЫЙ общий дом
// tools/steps-off-registry.js (его зовёт и probe-bench.js): правила разбора
// и сравнение версии-пола не копируются.
const { readStepsOff } = require('./steps-off-registry.js');
const src = fs.readFileSync(
  path.join(__dirname, '..', 'tweakcc-patch.js'), 'utf8');

// --- the template frame ------------------------------------------------------
const TEMPLATE_FRAME =
  '=== SESSION SO FAR ===\n{{CONTEXT}}\n\n=== {{LABEL}} ===\n{{DISPATCH}}';
const bodyPath = path.join(__dirname, '..', 'probes', 'judge', 'body.json');
let bodyUser = null;
try {
  const parsed = JSON.parse(fs.readFileSync(bodyPath, 'utf8'));
  bodyUser = parsed && parsed.messages
    && parsed.messages.find((m) => m.role === 'user');
} catch (e) {
  console.error('ШАБЛОН НЕ ЧИТАЕТСЯ: probes/judge/body.json: ' + e.message);
  process.exit(2);
}
if (!bodyUser) {
  console.error('ШАБЛОН НЕ ЧИТАЕТСЯ: в probes/judge/body.json нет user-сообщения');
  process.exit(2);
}
if (bodyUser.content !== TEMPLATE_FRAME) {
  console.error('РАМКА: шаблон в probes/judge/body.json разошёлся с каноном;'
    + ' получено ' + JSON.stringify(bodyUser.content));
  process.exit(1);
}
console.log('РАМКА ШАБЛОНА НА МЕСТЕ: probes/judge/body.json несёт все три слота');

// --- the carrier doors -------------------------------------------------------
// Шаг-владелец вхождения ищется структурно: ближайший предшествующий литерал
// step('… (скан назад), как в probe-bench.js. Счётчик скобок не годится: он
// меряет байты, а не грамматику.
function owningStep(text, offset) {
  const at = text.lastIndexOf("step('", offset);
  if (at < 0) return null;
  const nameEnd = text.indexOf("'", at + 6);
  if (nameEnd < 0) return null;
  return text.slice(at + 6, nameEnd);
}

// Отказ разбора несёт текст общего модуля (номер строки и путь);
// префикс и код возврата -- дело прибора.
let stepsOff;
try {
  stepsOff = readStepsOff(path.join(__dirname, 'our-steps-off.txt'));
} catch (error) {
  console.error('ДВЕРНОЙ СТОРОЖ НЕ ИЗМЕРЕН: ' + error.message);
  process.exit(2);
}
const offGateAt = (index) => {
  const step = owningStep(src, index);
  return step !== null && stepsOff.has(step)
    ? { step, reason: stepsOff.get(step).reason }
    : null;
};
const liveMatches = (re) => [...src.matchAll(re)].filter((m) => !offGateAt(m.index));

const carrierAll = [...src.matchAll(/String\(process\.env\.CLAUDE_[A-Z0-9_]*CARRIER\?\?""\)/g)];
const nCarrier = carrierAll.length;
const offGates = carrierAll.map((m) => offGateAt(m.index)).filter(Boolean);
const liveCarrier = nCarrier - offGates.length;
if (nCarrier === 0) {
  console.error('ДВЕРНОЙ СТОРОЖ НЕ ИЗМЕРЕН: ни одного carrier-гейта не найдено — якорь пропал');
  process.exit(2);
}
if (liveCarrier === 0) {
  const named = [...new Set(offGates.map((g) => `${g.step} (${g.reason})`))].join('; ');
  console.error('ДВЕРНОЙ СТОРОЖ: ПРЕДМЕТА НЕТ ПО ОБЪЯВЛЕНИЮ — carrier-гейт несёт только выключенный шаг ' + named);
  process.exit(3);
}
const nGuard = liveMatches(/return __\w+!=="mod"\|\|\(__\w+!=="1"&&__\w+!=="true"\)/g).length;
const nDoorDecl = liveMatches(/__\w+=String\(process\.env\.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS\?\?""\)/g).length;
const nBare = liveMatches(/return __\w+!=="mod"\}\)\(\)/g).length;
if (nGuard !== liveCarrier || nDoorDecl !== liveCarrier || nBare !== 0) {
  console.error('ДВЕРНОЙ СТОРОЖ CARRIER-ГЕЙТОВ РАЗОШЁЛСЯ: carrier=' + liveCarrier +
    ', guard=' + nGuard + ', doorDecl=' + nDoorDecl + ', bare(без сторожа)=' + nBare +
    '; ожидалось carrier=guard=doorDecl=' + liveCarrier + ', bare=0. ' +
    'Каждый гейт, стоящий в standby при CARRIER=mod, обязан также проверять ' +
    'открытую дверцу CLAUDE_CODE_ENABLE_FUNCTION_HOOKS, иначе CARRIER=mod при ' +
    'закрытой дверце оставляет пробу без носителя.');
  process.exit(1);
}
console.log('ДВЕРНОЙ СТОРОЖ CARRIER-ГЕЙТОВ НА МЕСТЕ: ' + liveCarrier +
  ' гейт(ов), несёт проверку дверцы function-hooks');
