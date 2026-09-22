// Teeth of the `$.requestText` door (generator step 34). Run directly:
//   node tools/door-teeth.mjs
// CONSTRAINT: зубы живут В ОДНОМ доме — `door-suite.mjs::run`. Эта батарея их
// только исполняет и печатает; собственного набора у неё нет, иначе
// мутационный контроль меряет не тот набор, что объявлен зелёным.
import { GENERATOR, doorParts, assertDoorSyntax, run, refuse } from './door-suite.mjs';

const PREFIX = 'DOOR-TEETH';
let parts, code, results;
try {
  parts = doorParts();
  code = assertDoorSyntax(parts.code);
  results = await run(code);
} catch (x) {
  refuse(PREFIX, x);
}

console.log('DOOR generator=%s elements=%d bytes=%d stringify_in_door=%d',
  GENERATOR, parts.elements.length, code.length, (code.match(/JSON\.stringify/g) || []).length);

for (const r of results) console.log(r.ok ? '  PASS ' + r.name : '  FAIL ' + r.name + ' ' + r.extra);

// CONSTRAINT: число зубов берётся из ДЛИНЫ перечня результатов, литерального
// пина «ожидается N» в батарее нет — пин числа расходится с телом молча.
const failed = results.filter((r) => !r.ok).length;
console.log(`\n${PREFIX} PASS=${results.length - failed} FAILED=${failed}`);
process.exit(failed ? 1 : 0);
