// Exit codes -- the kit's shared table (see the top of claude-patch-all.sh):
//   0  every live gate green
//   1  a refusal on the merits: the template frame or the carrier-door
//      guard diverged
//   2  the instrument cannot measure: probes/judge/body.json is unreadable,
//      or no carrier gate is left to count
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
//     still counted, so CARRIER_GATES below must stay the MEASURED count.
//     One gate is left -- the judge system-prompt rule (patch step 26);
//     four more lived in steps 21/22 and left with them.
const fs = require('fs');
const path = require('path');
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
const CARRIER_GATES = 1;
const nCarrier = (src.match(/String\(process\.env\.CLAUDE_[A-Z0-9_]*CARRIER\?\?""\)/g) || []).length;
const nGuard = (src.match(/return __\w+!=="mod"\|\|\(__\w+!=="1"&&__\w+!=="true"\)/g) || []).length;
const nDoorDecl = (src.match(/__\w+=String\(process\.env\.CLAUDE_CODE_ENABLE_FUNCTION_HOOKS\?\?""\)/g) || []).length;
const nBare = (src.match(/return __\w+!=="mod"\}\)\(\)/g) || []).length;
if (nCarrier === 0) {
  console.error('ДВЕРНОЙ СТОРОЖ НЕ ИЗМЕРЕН: ни одного carrier-гейта не найдено — якорь пропал');
  process.exit(2);
}
if (nCarrier !== CARRIER_GATES || nGuard !== CARRIER_GATES ||
    nDoorDecl !== CARRIER_GATES || nBare !== 0) {
  console.error('ДВЕРНОЙ СТОРОЖ CARRIER-ГЕЙТОВ РАЗОШЁЛСЯ: carrier=' + nCarrier +
    ', guard=' + nGuard + ', doorDecl=' + nDoorDecl + ', bare(без сторожа)=' + nBare +
    '; ожидалось carrier=guard=doorDecl=' + CARRIER_GATES + ', bare=0. ' +
    'Каждый гейт, стоящий в standby при CARRIER=mod, обязан также проверять ' +
    'открытую дверцу CLAUDE_CODE_ENABLE_FUNCTION_HOOKS, иначе CARRIER=mod при ' +
    'закрытой дверце оставляет пробу без носителя.');
  process.exit(1);
}
console.log('ДВЕРНОЙ СТОРОЖ CARRIER-ГЕЙТОВ НА МЕСТЕ: ' + CARRIER_GATES +
  ' гейт, несёт проверку дверцы function-hooks');
