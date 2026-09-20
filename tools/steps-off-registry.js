// ЕДИНСТВЕННЫЙ дом разбора реестра выключенных шагов (tools/our-steps-off.txt).
// CONSTRAINT: правила разбора живут ЗДЕСЬ и только здесь; их зовут
// tools/probe-bench.js и tools/emit-check.js. Вторая копия на любом языке
// расходится молча -- ровно тот класс, ради которого реестр появился.
//
// Формат записи: <имя шага ровно как в step('…')> TAB <версия-пол> TAB <причина>.
// Версия-пол -- первая версия, ОБРАЗЫ которой собираются уже без шага; пол
// сравнивается с версией образа кортежами целых (строки ставят «2.1.9» выше
// «2.1.10»). Отсутствующий файл -- НОРМА (все шаги включены): дом реестра
// заводится первой выключенной записью.
//
// Разбор кидает Error с номером строки и путём; печать и код возврата --
// дело ПРИБОРА (префиксы у приборов разные), текст сообщения переносится
// дословно.
'use strict';

const fs = require('node:fs');

function versionTuple(text, what) {
  if (!/^[0-9]+(?:\.[0-9]+)*$/.test(text)) {
    throw new Error(`версия не разбирается в кортеж целых -- ${what}: ${text}`);
  }
  return text.split('.').map(Number);
}

function tupleLeq(a, b) {
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x < y;
  }
  return true;
}

// Пустая строка и строка-комментарий пропускаются; неразобранная строка --
// отказ с её номером; две строки на одно имя -- отказ (читатель взял бы
// первую, а человек правил вторую).
function readStepsOff(stepsPath) {
  const off = new Map();
  if (stepsPath === null || !fs.existsSync(stepsPath)) return off;
  let raw;
  try {
    raw = fs.readFileSync(stepsPath, 'utf8');
  } catch (error) {
    throw new Error(`реестр ${stepsPath} не читается: ${error.message}`);
  }
  const lines = raw.split('\n');
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (!line.trim() || line.trim().startsWith('#')) continue;
    const parts = line.split('\t');
    if (parts.length !== 3 || parts.some((part) => !part)) {
      throw new Error(`неразобранная строка ${i + 1} в ${stepsPath}: нужны три поля через TAB (имя шага TAB версия-пол TAB причина)`);
    }
    if (off.has(parts[0])) {
      throw new Error(`две строки на шаг «${parts[0]}» в ${stepsPath}`);
    }
    off.set(parts[0], { floor: parts[1], reason: parts[2] });
  }
  return off;
}

// CLI-вход для приборов (зубы checks-teeth): печать и код возврата живут
// здесь, семантика разбора -- только в readStepsOff выше.
if (require.main === module) {
  const stepsPath = process.argv[2] ?? null;
  try {
    const off = readStepsOff(stepsPath);
    console.log(`записей: ${off.size}`);
  } catch (error) {
    console.error(`модуль steps-off-registry: ${error.message}`);
    process.exitCode = 2;
  }
}

module.exports = { readStepsOff, versionTuple, tupleLeq };
