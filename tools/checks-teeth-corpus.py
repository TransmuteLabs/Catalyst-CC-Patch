#!/usr/bin/env python3
"""Зубы проверок судьи, усилия и памяти сессии -- на ПРОДУКТАХ КОРПУСА.

Чем отличается от tools/checks-teeth.py. Тот мутирует БОЕВОЙ образ этой машины
и читает таблицу tools/checks-mutations.tsv, где мутация -- байтовая
подстановка в образ. Здесь нужно то, чего та форма не даёт:
  * мутации ИСХОДНИКА ПАТЧА: его судят 2 проверки pipeline (docnum:subset);
  * мутации, СЧИТАННЫЕ по месту (имя минифицировано и живёт только в своей
    версии), включая вставку равной длины на месте, которое надо найти;
  * ОБЪЯВЛЕННАЯ применимость: с 2.1.269 инструмент диспатча -- фабрика, и часть
    зубов относится к одной форме записи, а не к обеим. Молча подменять зуб на
    другой нельзя: неприменимость печатается.
Оба прибора говорят одно и то же и ни один не заменяет другой.

Мутации образа -- РАВНОЙ ДЛИНЫ: смещения не едут, и объект измерения остаётся
тем же файлом, а не другим.

Приёмка строки: после мутации множество красных = {база} + {названные двери},
ни больше ни меньше. Лишняя красная -- мутация задела чужую дверь и зубом не
является; отсутствие своей -- проверка не поднимается.

Продукты прибор НЕ собирает. Готовятся они так (по одному на версию корпуса):
    cp ~/.local/share/claude-patch/corpus/2.1.270.pristine /tmp/loop270.bin
    node <форк>/dist/index.mjs adhoc-patch --script @tweakcc-patch.js \\
        -p /tmp/loop270.bin --confirm-possible-dangerous-patch
    tools/checks-teeth-corpus.py /tmp/loop270.bin /tmp/loop267.bin

Коды выхода: 0 -- каждый применимый зуб покраснел свою дверь и только её;
1 -- промах (зуб прошёл молча либо задел чужую дверь); 2 -- прибор не может
мерить (нет образа, база не совпала с объявленной); 4 -- длина таблицы зубов
разошлась с объявленной (EXPECTED_MUTATIONS).
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / 'tools' / 'checks-on-image.sh'
PATCH = ROOT / 'tweakcc-patch.js'
# CONSTRAINT: длина таблицы зубов объявлена ЗДЕСЬ и сверяется гейтом чисел
# конвейера (OWNERS, владелец checks-teeth-corpus). Без объявления зуб,
# выпавший из таблицы при правке, уносил бы с собой дверь -- и прибор
# сообщал бы «промахов 0» о наборе, который стал меньше.
EXPECTED_MUTATIONS = 14
# Объявленная разница прибора, а не дефект: эта проверка судит СЛОЙ TWEAKCC,
# которого у продукта «пристинный + только наш adhoc-патч» нет по построению.
BASE = {'CLAUDE.md alternates tried'}


def reds(img, src=None):
    cmd = [str(RUNNER), str(img)] + ([str(src)] if src else [])
    p = subprocess.run(cmd, capture_output=True, text=True)
    out = p.stdout + p.stderr
    return set(re.findall(r'\[FAIL\] (.+)', out)), p.returncode, out


def eq_len(orig, new):
    assert len(new) <= len(orig), (len(orig), len(new))
    return new + b' ' * (len(orig) - len(new))


# ---- мутации образа -------------------------------------------------------

def m_stash_reader(d):
    """Стэш хода перестаёт стоять на ТОМ ЖЕ типизированном читателе."""
    at = d.index(b'__ccJudgeTurn??=new Map()')
    back = d.rindex(b'__c!=="mod"', 0, at)
    return d[:back] + b'__c!=="MOD"' + d[back + 11:]


def m_judge_block_reader(d):
    """Блок судьи перестаёт опознаваться как судья (ход достаётся не ему)."""
    at = d.index(b'tag:"[Judge]"')
    back = d.rindex(b'__c!=="mod"', 0, at)
    return d[:back] + b'__c!=="MOD"' + d[back + 11:]


def m_watch_reader(d):
    """Наблюдатель перестаёт стоять на своём выключателе."""
    at = d.index(b'CLAUDE_IDLE_CARRIER')
    return d[:at] + b'CLAUDE_IDLE_CARRIEQ' + d[at + 19:]


def m_gate_ctx(d):
    """Гейт судьи перестаёт отличать главный луп от субагента."""
    at = d.index(b'agentType==="main")await globalThis.__ccProbe({tag:"[Judge]"')
    return d[:at] + b'agentType==="Main"' + d[at + 18:]


def m_factory_mark(d):
    """Дискриминатор формы лжёт: врезка фабричная, а маркер говорит «метод»."""
    old = b'launching needs the executor (call.runEngine)'
    # ВСЕ вхождения: дискриминатор -- присутствие маркера, а одна подмена из
    # четырёх оставляет его присутствующим и мутацией не является.
    assert old in d
    return d.replace(old, b'launching needs the executor (call.runEngin0)')


def m_tool_identity(d):
    """Личность инструмента в блоке судьи перестаёт быть той, что доказана местом."""
    for old, new in ((b'tool:{name:"Agent"},input:', b'tool:{name:"Agenr"},input:'),
                     (b'tool:this,input:', b'tool:thiz,input:')):
        if old in d:
            at = d.index(old)
            return d[:at] + new + d[at + len(old):]
    raise AssertionError('ни одной формы слота инструмента в образе')


def m_effort_name(d):
    """Связывание усилия перестаёт быть тем именем, которое читает запуск."""
    at = d.index(b'effort:__ccEffort')
    return d[:at] + b'effort:__ccEffor0' + d[at + 17:]


def m_effort_scope(d):
    """Область усилия закрывается ДО чтения: имя невидимо на месте запуска."""
    bind = d.index(b'effort:__ccEffort')
    use = d.index(b'__ccRaw=typeof __ccEffort')
    close = d.index(b'}', bind)
    # первая открывающая скобка после образца превращается в закрывающую:
    # обход уходит в минус, то есть область, открытая связыванием, закрыта.
    op = d.index(b'{', close + 1)
    assert op < use
    return d[:op] + b'}' + d[op + 1:]


KEEP_RX = (rb'return!([A-Za-z_$][\w$]*)\(\)\|\|([A-Za-z_$][\w$]*)'
           rb'\("tengu_[a-z0-9_]+",!1\)\}')


def m_memory_keep_gone(d):
    """Форма «keep» пропала: правка 7 потеряла свой сайт."""
    m = re.search(KEEP_RX, d)
    assert m, 'формы keep в образе нет'
    at = d.index(b'"tengu_', m.start())
    return d[:at] + b'"xengu_' + d[at + 7:]


def m_memory_guard_back(d):
    """Флаговый гард возвращается в тело предиката памяти сессии."""
    m = re.search(rb'if\([A-Za-z_$][\w$]*\(\)!==null\)return!0;'
                  rb'return![A-Za-z_$][\w$]*\(\)\|\|[A-Za-z_$][\w$]*\("tengu_[a-z0-9_]+",!1\)\}', d)
    if m:
        keep = re.search(rb'return!([A-Za-z_$][\w$]*)\(\)\|\|([A-Za-z_$][\w$]*)'
                         rb'\("tengu_[a-z0-9_]+",!1\)\}', m.group(0))
        new = (b'if(!' + keep.group(2) + b'("tengu_aaa",!1))return!1;'
               + b'return!' + keep.group(1) + b'()||' + keep.group(2) + b'("tengu_bbb",!1)}')
        return d[:m.start()] + eq_len(m.group(0), new) + d[m.end():]
    # Образ без раннего возврата (2.1.267/268) не даёт МЕСТА равной длины под
    # гард: минимальный гард `if(!H("tengu_a",!1))return!1;` -- 29 байт, а весь
    # предикат там 56, и вставка не помещается. Эта половина утверждения
    # покрывается на 269/270, где ранний возврат апстрима даёт запас; на
    # 267/268 ту же дверь держит зуб «форма keep пропала». Молча подменять зуб
    # нельзя -- прибор объявляет неприменимость.
    raise NotImplementedError('на этом образе нет раннего возврата: место под гард не равной длины')


# ---- мутации исходника патча ----------------------------------------------

# Площадка обеих подстановок -- регулярка шага 22, НЕ headRx: иначе мутация
# заодно ломает локатор форм и краснит чужую дверь своей причиной.
SITE = '`[{,]agentInput:(${ID})[,}]`'


def s_bare_name_in_regex(src):
    """Захваченное имя уезжает в ИСХОДНИК регулярки голым, в СВОЁМ же шаге."""
    assert SITE in src
    return src.replace(SITE, '`[{,]agentInput:(${ID})[,}]${spread}`', 1)


def s_bare_name_other_step(src):
    """ОТРИЦАТЕЛЬНЫЙ КОНТРОЛЬ: имя из ЧУЖОГО шага -- тревоги быть не должно."""
    assert SITE in src
    return src.replace(SITE, '`[{,]agentInput:(${ID})[,}]${t}`', 1)


def s_drop_adapter_shape(src):
    """Локатор теряет форму-переходник: адаптерный вызов больше не опознаётся."""
    return src.replace(
        '|${ID}\\\\((${ID})\\\\)\\\\.(?:call|execute))$', '|(${ID})XX)$', 1)


def s_drop_group_join(src):
    """Локатор перестаёт брать ту альтернативу, которая совпала."""
    return src.replace('head[2] ?? head[3]', 'head[2] ?? head[2]', 1)


IMAGE_TEETH = [
    ('стэш: читатель не тот', m_stash_reader,
     {'judge stashes the current turn'}),
    ('блок судьи: читатель не тот', m_judge_block_reader,
     {"current turn is the judge's alone", 'judge rides the tool, watcher the dispatcher',
      'judge consulted before dispatch'}),
    ('вахта: читатель не тот', m_watch_reader,
     {'watcher rides the same core'}),
    ('гейт: главный луп не отличается', m_gate_ctx,
     {'judge consulted before dispatch'}),
    ('дискриминатор формы лжёт', m_factory_mark,
     {'judge consulted before dispatch', 'judge rides the tool, watcher the dispatcher'},
     lambda d: b'launching needs the executor (call.runEngine)' in d),
    ('личность инструмента подменена', m_tool_identity,
     {'judge rides the tool, watcher the dispatcher'}),
    ('усилие: имя связывания разошлось', m_effort_name,
     {'effort binding reaches the launch', 'dispatch carries effort'}),
    ('усилие: область закрыта до чтения', m_effort_scope,
     {'effort binding reaches the launch'}),
    ('память сессии: форма keep пропала', m_memory_keep_gone,
     {'session memory forced on'}),
    ('память сессии: гард вернулся', m_memory_guard_back,
     {'session memory forced on'},
     lambda d: re.search(rb'if\([A-Za-z_$][\w$]*\(\)!==null\)return!0;return!', d) is not None),
]

SRC_TEETH = [
    ('голое имя в исходнике регулярки (свой шаг)', s_bare_name_in_regex,
     {'patch source escapes every captured name'}),
    ('голое имя из ЧУЖОГО шага (контроль)', s_bare_name_other_step, set()),
    ('локатор потерял форму-переходник', s_drop_adapter_shape,
     {'patch source keeps both dispatcher shapes'}),
    ('локатор не берёт совпавшую альтернативу', s_drop_group_join,
     {'patch source keeps both dispatcher shapes'}),
]

# CONSTRAINT: гейт двусторонний. Объявление, которое никто не сверяет с
# фактической длиной, протухает молча -- ровно так счётчик становится
# украшением вместо затвора.
_ACTUAL_TEETH = len(IMAGE_TEETH) + len(SRC_TEETH)


def run_one(img, tmp):
    base, rc, _ = reds(img)
    print(f'== база {img.name}: rc={rc} красных={sorted(base)}')
    if base != BASE:
        print('КОНТРОЛЬ ПРОВАЛЕН: база не совпала с объявленной', file=sys.stderr)
        return 2
    d0 = img.read_bytes()
    src0 = PATCH.read_text(encoding='utf-8')
    bad = 0
    for row in IMAGE_TEETH:
        name, fn, want = row[0], row[1], row[2]
        if len(row) > 3 and not row[3](d0):
            print(f'  [Н/П] {name}: неприменимо к этому образу (объявлено)')
            continue
        mut = tmp / 'mutant.bin'
        try:
            d = fn(d0)
        except Exception as e:                       # noqa: BLE001
            print(f'  [ПРИБОР] {name}: {e}'); bad += 1; continue
        assert len(d) == len(d0), (name, len(d), len(d0))
        mut.write_bytes(d)
        got, _, _ = reds(mut)
        delta = got - BASE
        ok = delta == want
        print(f'  [{"ЗУБ" if ok else "МИМО"}] {name}: покраснело {sorted(delta)}'
              + ('' if ok else f' ; ждали {sorted(want)}'))
        bad += 0 if ok else 1
    for name, fn, want in SRC_TEETH:
        ms = tmp / 'mutant-patch.js'
        try:
            s = fn(src0)
        except Exception as e:                       # noqa: BLE001
            print(f'  [ПРИБОР] {name}: {e}'); bad += 1; continue
        if s == src0:
            print(f'  [ПРИБОР] {name}: мутация ничего не изменила'); bad += 1; continue
        ms.write_text(s, encoding='utf-8')
        got, _, _ = reds(img, ms)
        delta = got - BASE
        ok = delta == want
        print(f'  [{"ЗУБ" if ok else "МИМО"}] {name}: покраснело {sorted(delta)}'
              + ('' if ok else f' ; ждали {sorted(want)}'))
        bad += 0 if ok else 1
    print(f'== промахов: {bad}')
    return bad


def main():
    # Продукты называются вызывающим: собирать их здесь значило бы прятать
    # ВТОРОЙ инструмент внутри прибора зубов, и отказ сборки читался бы как
    # промах зуба.
    # Объявленная длина сверяется ДО любого замера: прибор, у которого таблица
    # разошлась с объявлением, мерит не тот набор, и его зелёный ничего не
    # значит. Код 4 -- «объявленная величина не сходится с фактической», тот же
    # класс, что у --expect-sha, а не «гейт не прошёл».
    if _ACTUAL_TEETH != EXPECTED_MUTATIONS:
        print(f'checks-teeth-corpus: ОТКАЗ -- зубов {_ACTUAL_TEETH}, '
              f'объявлено {EXPECTED_MUTATIONS}', file=sys.stderr)
        return 4
    imgs = [Path(a) for a in sys.argv[1:]]
    if not imgs:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    missing = [i for i in imgs if not i.is_file()]
    if missing:
        print('нет продукта: ' + ', '.join(str(i) for i in missing), file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='teeth-corpus-') as td:
        tmp = Path(td)
        worst = 0
        for img in imgs:
            rc = run_one(img, tmp)
            worst = max(worst, rc if rc == 2 else (1 if rc else 0))
        return worst


if __name__ == '__main__':
    sys.exit(main())
