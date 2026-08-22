// Разбор вклеиваемого кода ДО сборки образа. Вклейка ломается молча: патчер
// сам по себе синтаксически цел, а склеенная из сотен строковых кусков
// программа может не разбираться вовсе — и это видно только на живом бинарнике.
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(
  path.join(__dirname, '..', 'tweakcc-patch.js'), 'utf8');

// Куски вырезаются по якорям, а не по балансировке скобок: якоря — соседние
// объявления, они меняются вместе с кодом и молча не разъезжаются.
const parts = [
  ['core', '  const core =', '  const judgeCall ='],
  ['judgeCall', '  const judgeCall =', '\n  // Канал наблюдателя'],
  ['watchCall', '  const watchCall =', '  // Вклейка по СМЕЩЕНИЮ'],
];

let total = '';
const sizes = [];
for (const [name, from, to] of parts) {
  const a = src.indexOf(from);
  const b = src.indexOf(to, a);
  if (a < 0 || b < 0) { console.error('ЯКОРЬ НЕ НАЙДЕН: ' + name); process.exit(2); }
  // Хвост куска — комментарий следующего объявления: якорь стоит на строке
  // объявления, а не на первом его знаке. Снимается перед разбором.
  const expr = src.slice(a + from.length, b)
    .replace(/(?:\s*(?:\/\/[^\n]*|\/\*[\s\S]*?\*\/))*\s*$/, '')
    .trim().replace(/;$/, '');
  // Внешние имена патчера: подставляются правдоподобными минифицированными.
  // Свободные имена патчера (найденные локаторами минифицированные имена,
  // экранировщики) подставляются ОПТОМ через область видимости: перечислять их
  // поимённо значит чинить эту проверку при каждом новом локаторе.
  //
  // Но заглушка ставится ТОЛЬКО тем именам, которые патчер где-то объявляет.
  // Заглушка на всё подряд молча проглатывает опечатку и несуществующее имя —
  // именно так сюда однажды попал литеральный `esc`: кусок «разобрался», а на
  // живом прогоне патчер упал бы ReferenceError.
  const declared = new Set(
    [...src.matchAll(/\b(?:const|let|var|function)\s+([A-Za-z_$][\w$]*)/g)]
      .map((m) => m[1]));
  const scope = new Proxy({}, {
    has: (_t, k) => typeof k === 'string',
    get: (_t, k) => {
      // `with` спрашивает @@unscopables у самой области видимости — это не имя
      // из куска, и отвечать на него броском значит валить проверку на месте.
      if (typeof k === 'symbol') return undefined;
      if (!declared.has(k)) {
        throw new ReferenceError('свободное имя, нигде не объявленное: ' + k);
      }
      return /Esc$/.test(k) ? (x) => x : k;
    },
  });
  const val = new Function('__scope', 'with(__scope){return (' + expr + ')}')(scope);
  if (typeof val !== 'string') { console.error('НЕ СТРОКА: ' + name); process.exit(2); }
  sizes.push(name + '=' + val.length);
  total += val;
}

// Слоты вызова инструмента — те же, что подставляет патчер.
const resolved = total.replace(/\$([1-9])/g, (_, d) => '__slot' + d);
try {
  new Function('__slot1', '__slot2', '__slot3', '__slot4', '__slot5',
    '"use strict";return (async()=>{' + resolved + '})');
} catch (e) {
  console.error('ВКЛЕИВАЕМЫЙ КОД НЕ РАЗБИРАЕТСЯ: ' + e.message);
  process.exit(1);
}
console.log('ВКЛЕИВАЕМЫЙ КОД РАЗБИРАЕТСЯ; ' + sizes.join(', ') +
  ', всего ' + resolved.length);

// Якорь конца строки в собственных регулярках вклеиваемого кода — это НЕ
// слот, и предупреждать о нём значит приучить себя к шуму. Опасна другая
// форма: замещающие последовательности String.replace ($&, $`, $', $0),
// которые подставили бы чужой захват молча, окажись текст в правой части
// замены. Класс уже кусал этот патчер, поэтому проверяется именно он.
const stray = total.match(/\$[&`'0]/g);
if (stray) {
  console.error('ЗАМЕЩАЮЩИЕ ПОСЛЕДОВАТЕЛЬНОСТИ В ТЕЛЕ: ' + stray.join(' '));
  process.exit(1);
}
