#!/usr/bin/env python3
"""Дверь против инструмента-сироты: прибор есть, его числа сторожатся гейтом
чисел, а исполнителя нет. Такая тишина уже была замерена на живом дереве:
корпусный прибор зубов не звал никто, пока его зубы считались сторожимыми.
Перепись ниже называет каждого инструмента без исполнителя.

Знаменатель берётся из пары источников и сверяется между собой:
  * владельцы чисел из блока OWNERS гейта чисел конвейера -- блок вырезается
    из heredoc по якорям и разбирается декларативно (ast), тем же приёмом,
    каким стенд зубов читает сам гейт;
  * файлы каталога инструментов (оболочка, питон, node).
Владелец, чей файл не найден среди инструментов, -- расхождение источников:
знаменателю, у которого половина не сходится, веры нет, и это «прибор не
может мерить», а не находка.

Вызовом считается ЛЮБАЯ из измеренных форм -- ценз, ловивший только запуск
интерпретатором, врал нулём на живом дереве, и обе подключательные формы,
как и потребление из node-кода, были им пропущены:
 tools/<имя>                          -- путь с домом;
 $(dirname "$0")/<имя> и $HERE/<имя>  -- сосед по каталогу БЕЗ дома в пути;
 . <путь>/<имя> и source <путь>/<имя> -- ПОДКЛЮЧЕНИЕ, а не запуск;
 bash|sh|python3|node <путь>/<имя>    -- запуск интерпретатором;
 require('…/<имя>') и import('…/<имя>') -- потребление из node-кода.
Вхождение внутри самого инструмента и строки-комментарии вызовом не
считаются; комментарий распознаётся ПО ЯЗЫКУ файла (решётка у оболочки
и питона, // и /* у node). Проза ЭТОГО файла из поиска исполнителей
исключена целиком: пример формы в докстринге иначе засчитался бы
исполнителем настоящего сироты.

Ручные инструменты объявлены списком ниже, каждый с основанием одной строкой:
объявление без основания -- отказ самого гейта, объявление на несуществующий
файл -- тоже (устаревшее объявление прячет сироту).

Коды выхода:
  0  у каждого необъявленного ручным инструмента есть исполнитель
  1  найдена сирота -- все названы, каждая своей строкой
  2  прибор не может мерить: якорь гейта чисел пропал, задвоен или не
     разбирается; каталог инструментов пуст; владелец чисел называет файл,
     которого нет; объявленный ручным файл не существует; объявление без
     основания
"""
import ast
import io
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(HERE)
PIPELINE = 'claude-patch-all.sh'
# CONSTRAINT: якорь и конец -- те же, которыми стенд зубов вырезает сам гейт
# чисел; собственный якорь разъехал бы с конвейером при первой же правке.
ANCHOR = 'python3 - "$0" <<\'PYDOCS\'\n'
END = '\nPYDOCS\n'

# CONSTRAINT: основание обязательно -- список без оснований выродился бы в
# список исключений, закрывающий произвольные имена.
MANUAL = {
    'listener.py': 'подслушивающий стенд для ручных проб',
    'probes-migrate.py': 'разовая миграция',
    # CONSTRAINT: основание называет, ПОЧЕМУ исполнителя нет и кто запускает;
    # «удобно держать ручным» основанием не является.
    'reap-heavy.sh': 'прополка диска запускается оператором с явным --apply; '
                     'линейный прогон звать её не должен: возраст и размер -- '
                     'не основание сносить то, что читает живой замер',
    'tree-run.sh': 'запускалка бун-стенда для отладочного цикла оператора '
                   '(дерево виртуальной ФС без пересборки образа); конвейер '
                   'её не зовёт',
}

TOOL_EXTS = ('.sh', '.py', '.js')
# CONSTRAINT: исполнителя ищут оболочка, питон и node: .js-инструмент
# потребляется require/import другого .js, и это вызов той же силы, что
# запуск интерпретатором. Файлы данных и разметки искателями не являются --
# вызвать инструмент они не могут.
SEARCH_EXTS = ('.sh', '.py', '.js')
SKIP_DIRS = {'.git', 'docs', '__pycache__'}
FORM_LABELS = ('tools/<имя>', '$HERE либо $(dirname "$0")',
               'подключение (. либо source)', 'интерпретатор',
               'require либо import (node)')


def comment_prefixes(fname):
    """Префиксы строки-комментария по ЯЗЫКУ осматриваемого файла.

    CONSTRAINT: пропуск комментариев обязан знать язык: у .js комментарий
    начинается с // или /*, и решёточный пропуск засчитал бы закомментированный
    пример require потребителем.
    """
    if fname.endswith('.js'):
        return ('//', '/*')
    return ('#',)


def js_module_pattern(name):
    """Имя для require/import: расширение .js в аргументе опционально."""
    base = name[:-3] if name.endswith('.js') else name
    return re.escape(base) + r'(?:\.js)?'


def form_regexes(name):
    """Пять форм вызова одного инструмента (порядок = порядок меток)."""
    n = re.escape(name) + r'(?!\w)'
    return [
        re.compile(r'tools/' + n),
        re.compile(r'(\$HERE|\$\(dirname "\$0"\))/' + n),
        re.compile(r'(?:^|[\s;|&])(?:\.|source)\s+\S*' + n),
        re.compile(r'\b(?:bash|sh|python3|node)\b[^\n]*?/' + n),
        re.compile(r'\b(?:require|import)\s*\(\s*["\'][^"\']*?'
                   + js_module_pattern(name) + r'["\']\s*\)'),
    ]


def owners_from_pipeline(kit):
    """(список (id, путь|None), причина отказа | None) из блока OWNERS."""
    path = os.path.join(kit, PIPELINE)
    if not os.path.isfile(path):
        return None, 'нет %s в %s' % (PIPELINE, kit)
    text = io.open(path, encoding='utf-8').read()
    if ANCHOR not in text:
        return None, 'якорь гейта чисел пропал из %s' % PIPELINE
    if text.count(ANCHOR) != 1:
        return None, 'якорь гейта чисел встречается в %s не один раз' % PIPELINE
    start = text.index(ANCHOR) + len(ANCHOR)
    if END not in text[start:]:
        return None, 'конец гейта чисел не найден в %s' % PIPELINE
    body = text[start:text.index(END, start)]
    try:
        tree = ast.parse(body)
    except SyntaxError as error:
        return None, 'вырезанный гейт чисел не разбирается: %s' % error
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == 'OWNERS'
                        for t in node.targets)):
            continue
        if not isinstance(node.value, ast.Tuple):
            return None, 'блок OWNERS не кортеж'
        owners = []
        for elt in node.value.elts:
            if not (isinstance(elt, ast.Tuple) and len(elt.elts) >= 3
                    and isinstance(elt.elts[0], ast.Constant)
                    and isinstance(elt.elts[0].value, str)):
                return None, 'строка OWNERS не разобрана как (id, имена, файл, величины)'
            ident = elt.elts[0].value
            where = elt.elts[2]
            if isinstance(where, ast.Constant) and where.value is None:
                owners.append((ident, None))
            elif (isinstance(where, ast.Tuple)
                  and all(isinstance(c, ast.Constant)
                          and isinstance(c.value, str) for c in where.elts)):
                owners.append((ident, os.path.join(*[c.value for c in where.elts])))
            else:
                return None, 'владелец %s: файл не разобран декларативно' % ident
        return owners, None
    return None, 'блок OWNERS не найден в вырезанном гейте чисел'


def tool_names(kit):
    tools = os.path.join(kit, 'tools')
    if not os.path.isdir(tools):
        return []
    return sorted(name for name in os.listdir(tools)
                  if name.endswith(TOOL_EXTS)
                  and os.path.isfile(os.path.join(tools, name)))


# CONSTRAINT: у двери описания знаменатель ШИРЕ, чем у двери сироты. Сирота --
# про исполнителя, и файлы данных туда не входят: у таблицы мутаций
# исполнителя не бывает по природе. Состав же в README описывает и данные,
# и первый замер этой двери показал ровно такой пробел.
DESCRIBED_EXTS = TOOL_EXTS + ('.txt', '.tsv')


def described_names(kit):
    tools = os.path.join(kit, 'tools')
    if not os.path.isdir(tools):
        return []
    return sorted(name for name in os.listdir(tools)
                  if name.endswith(DESCRIBED_EXTS)
                  and os.path.isfile(os.path.join(tools, name)))


def described(kit, names):
    """Две стороны описания: (не названные в README, названные без файла).

    CONSTRAINT: таблица состава в README -- ПРОЕКЦИЯ каталога инструментов, и
    без читателя она расходится молча в обе стороны. Измерено на живом дереве:
    два прибора (checks-mutations.tsv и checks-teeth-corpus.py) не были
    названы в README вовсе. Отсутствие README -- «не с чем сверять», то есть
    отказ прибора, а не пустая перепись.
    """
    readme = os.path.join(kit, 'README.md')
    if not os.path.isfile(readme):
        return None, None, 'нет %s: состав сверять не с чем' % readme
    text = io.open(readme, encoding='utf-8').read()
    silent = [n for n in described_names(kit)
              if ('tools/' + n) not in text]
    ghost = sorted({m for m in re.findall(r'`(tools/[A-Za-z0-9_./-]+)`', text)
                    if not os.path.isfile(os.path.join(kit, m))})
    return silent, ghost, None


def find_callers(kit, names, self_path):
    """Вызывающие каждого инструмента: имя -> [(файл, строка, форма)]."""
    regexes = {name: form_regexes(name) for name in names}
    callers = {name: [] for name in names}
    for root, dirs, files in os.walk(kit):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fname in files:
            if not fname.endswith(SEARCH_EXTS):
                continue
            path = os.path.join(root, fname)
            if os.path.abspath(path) == self_path:
                continue
            try:
                lines = io.open(path, encoding='utf-8',
                                errors='replace').read().splitlines()
            except OSError:
                continue
            rel = os.path.relpath(path, kit)
            prefixes = comment_prefixes(fname)
            for number, line in enumerate(lines, 1):
                if line.lstrip().startswith(prefixes):
                    continue
                for name in names:
                    # CONSTRAINT: вхождение внутри САМОГО инструмента -- не
                    # вызов: пример использования в докстроке прибора иначе
                    # засчитывается его единственным исполнителем.
                    if rel == os.path.join('tools', name):
                        continue
                    for label, rx in zip(FORM_LABELS, regexes[name]):
                        if rx.search(line):
                            callers[name].append((rel, number, label))
                            break
    return callers


def measure(kit, self_path=None):
    """Перепись одного дерева. Ничего не печатает.

    Возвращает словарь: code, refusals, orphans, tools, manual, callers.
    """
    result = {'code': 2, 'refusals': [], 'orphans': [], 'tools': [],
              'manual': [], 'callers': {}, 'silent': [], 'ghost': []}
    owners, why = owners_from_pipeline(kit)
    if owners is None:
        result['refusals'].append(why)
        return result
    names = tool_names(kit)
    if not names:
        result['refusals'].append(
            'каталог инструментов пуст: %s' % os.path.join(kit, 'tools'))
        return result
    for ident, rel in owners:
        if rel is None or not rel.startswith('tools' + os.sep):
            continue
        if os.path.basename(rel) not in names:
            result['refusals'].append(
                'владелец чисел %s называет файл %s, которого нет среди '
                'инструментов -- источники знаменателя разошлись' % (ident, rel))
            return result
    manual = sorted(name for name in MANUAL if name in names)
    for name in sorted(MANUAL):
        if not MANUAL[name].strip():
            result['refusals'].append(
                'инструмент %s объявлен ручным без основания' % name)
            return result
        if name not in names:
            result['refusals'].append(
                'объявленный ручным %s не существует -- устаревшее объявление '
                'прячет сироту' % name)
            return result
    silent, ghost, why = described(kit, names)
    if why is not None:
        result['refusals'].append(why)
        return result
    callers = find_callers(kit, names, self_path)
    orphans = [name for name in names
               if name not in MANUAL and not callers[name]]
    result.update(code=1 if (orphans or silent or ghost) else 0,
                  orphans=orphans, tools=names, manual=manual,
                  callers=callers, silent=silent, ghost=ghost)
    return result


def report(result, verbose=False):
    for line in result['refusals']:
        print('ОТКАЗ: %s' % line)
    if result['code'] == 2:
        return
    if verbose:
        for name in result['tools']:
            if name in MANUAL:
                print('ПРИБОР: %s -- РУЧНОЙ (%s)' % (name, MANUAL[name]))
                continue
            hits = result['callers'][name]
            if not hits:
                print('ПРИБОР: %s -- исполнителей НЕТ' % name)
                continue
            shown = ', '.join('%s:%d [%s]' % h for h in hits[:4])
            extra = '' if len(hits) <= 4 else ' (+%d ещё)' % (len(hits) - 4)
            print('ПРИБОР: %s -- исполнители: %s%s' % (name, shown, extra))
    for name in result['orphans']:
        print('ОТКАЗ: сирота -- %s: исполнителей нет ни в одной форме вызова'
              % name)
    for name in result['silent']:
        print('ОТКАЗ: прибор вне описания -- tools/%s: в README о нём ни слова'
              % name)
    for rel in result['ghost']:
        print('ОТКАЗ: описание без прибора -- README называет %s, которого в '
              'дереве нет' % rel)
    if result['code'] == 0:
        print('инструментов %d, из них объявлено ручными %d, без исполнителя %d,'
              ' вне описания %d, описаний без файла %d'
              % (len(result['tools']), len(result['manual']),
                 len(result['orphans']), len(result['silent']),
                 len(result['ghost'])))


def self_check():
    """Положительный контроль на временном дереве: сирота названа, без неё -- зелено."""
    work = tempfile.mkdtemp(prefix='orphan-stand-gate.')
    try:
        kit = os.path.join(work, 'kit')
        os.makedirs(os.path.join(kit, 'tools'))
        io.open(os.path.join(kit, PIPELINE), 'w', encoding='utf-8').write(
            'echo конвейер-заглушка\n' + ANCHOR
            + "OWNERS = (\n"
              "    ('toy-bench', ('toy-bench',), ('tools', 'called-one.sh'),\n"
              "     {'mutations': r'^EXPECTED_MUTATIONS = (\\d+)$'}),\n"
              ")\n" + END)
        io.open(os.path.join(kit, 'run.sh'), 'w', encoding='utf-8').write(
            '#!/usr/bin/env bash\nbash tools/called-one.sh\n')
        readme = os.path.join(kit, 'README.md')
        io.open(readme, 'w', encoding='utf-8').write(
            'toy contents\n`tools/called-one.sh`\n`tools/zz-fake-orphan.sh`\n'
            + ''.join('`tools/%s`\n' % name for name in MANUAL))
        io.open(os.path.join(kit, 'tools', 'called-one.sh'), 'w',
                encoding='utf-8').write('#!/usr/bin/env bash\nexit 0\n')
        for name in MANUAL:
            io.open(os.path.join(kit, 'tools', name), 'w',
                    encoding='utf-8').write('')
        fake = os.path.join(kit, 'tools', 'zz-fake-orphan.sh')
        io.open(fake, 'w', encoding='utf-8').write(
            '#!/usr/bin/env bash\nexit 0\n')
        red = measure(kit)
        if red['code'] != 1 or red['orphans'] != ['zz-fake-orphan.sh']:
            print('ОТКАЗ: контроль не покраснел именем фиктивного инструмента:'
                  ' code=%d orphans=%r' % (red['code'], red['orphans']))
            return 2
        print('ПРИБОР: контроль с фиктивной сиротой -- покраснен, названа по имени')
        os.remove(fake)
        # Строка описания снимается ВМЕСТЕ с файлом: иначе дверь описания
        # законно краснит зелёный контроль «описанием без прибора», и зуб
        # сироты мерил бы уже красное дерево.
        io.open(readme, 'w', encoding='utf-8').write(
            'toy contents\n`tools/called-one.sh`\n'
            + ''.join('`tools/%s`\n' % name for name in MANUAL))
        green = measure(kit)
        if green['code'] != 0:
            print('ОТКАЗ: без мутации перепись не зеленеет: code=%d '
                  'refusals=%r orphans=%r'
                  % (green['code'], green['refusals'], green['orphans']))
            return 2
        print('ПРИБОР: контроль без мутации -- зелен')

        # Зубы JS-формы потребления (node): require -- вызов, удаление
        # единственного require рождает сироту, require в комментарии
        # потребителем НЕ считается. Каждый зуб ставится на ЗЕЛЁНОМ дереве
        # и снимается после замера.
        js_lib = os.path.join(kit, 'tools', 'zz-js-lib.js')
        js_user = os.path.join(kit, 'tools', 'called-two.js')
        io.open(js_lib, 'w', encoding='utf-8').write(
            "'use strict';\nmodule.exports = {};\n")
        io.open(js_user, 'w', encoding='utf-8').write(
            "#!/usr/bin/env node\nconst lib = require('./zz-js-lib.js');\n")
        io.open(os.path.join(kit, 'run.sh'), 'a', encoding='utf-8').write(
            'node tools/called-two.js\n')
        io.open(readme, 'a', encoding='utf-8').write(
            '`tools/zz-js-lib.js`\n`tools/called-two.js`\n')
        js_green = measure(kit)
        js_hits = js_green['callers'].get('zz-js-lib.js', [])
        if (js_green['code'] != 0 or len(js_hits) != 1
                or FORM_LABELS[4] not in js_hits[0][2]):
            print('ОТКАЗ: require из описанного инструмента не засчитан '
                  'потребителем своей формой: code=%d hits=%r'
                  % (js_green['code'], js_hits))
            return 2
        print('ПРИБОР: контроль require-потребления -- зелен, форма названа')
        io.open(js_user, 'w', encoding='utf-8').write(
            "#!/usr/bin/env node\nconst lib = null;\n")
        js_red = measure(kit)
        if js_red['code'] != 1 or js_red['orphans'] != ['zz-js-lib.js']:
            print('ОТКАЗ: удаление единственного require не назвало сироту: '
                  'code=%d orphans=%r' % (js_red['code'], js_red['orphans']))
            return 2
        print('ПРИБОР: удаление единственного require -- сирота названа')
        io.open(js_user, 'w', encoding='utf-8').write(
            "#!/usr/bin/env node\n// const lib = require('./zz-js-lib.js');\n")
        js_cmt = measure(kit)
        if js_cmt['code'] != 1 or js_cmt['orphans'] != ['zz-js-lib.js']:
            print('ОТКАЗ: закомментированный require засчитан потребителем: '
                  'code=%d orphans=%r' % (js_cmt['code'], js_cmt['orphans']))
            return 2
        print('ПРИБОР: require в комментарии -- потребителем НЕ считается')
        os.remove(js_lib)
        os.remove(js_user)
        io.open(os.path.join(kit, 'run.sh'), 'w', encoding='utf-8').write(
            '#!/usr/bin/env bash\nbash tools/called-one.sh\n')
        io.open(readme, 'w', encoding='utf-8').write(
            'toy contents\n`tools/called-one.sh`\n'
            + ''.join('`tools/%s`\n' % name for name in MANUAL))

        # Зубы ВТОРОЙ двери. Каждая мутация ставится на ЗЕЛЁНОМ дереве и
        # снимается после замера: краснота на уже красном не доказывала бы
        # ничего (круг 28 -- красный контроль зубов не мерит).
        quiet = os.path.join(kit, 'tools', 'zz-undocumented.tsv')
        io.open(quiet, 'w', encoding='utf-8').write('id\tчто\n')
        silent = measure(kit)
        if silent['code'] != 1 or silent['silent'] != ['zz-undocumented.tsv']:
            print('ОТКАЗ: дверь описания не назвала прибор вне README: '
                  'code=%d silent=%r' % (silent['code'], silent['silent']))
            return 2
        print('ПРИБОР: контроль с неописанным прибором -- покраснен, назван по имени')
        os.remove(quiet)

        io.open(readme, 'a', encoding='utf-8').write('`tools/zz-no-such.py`\n')
        ghost = measure(kit)
        if ghost['code'] != 1 or ghost['ghost'] != ['tools/zz-no-such.py']:
            print('ОТКАЗ: дверь описания не назвала описание без файла: '
                  'code=%d ghost=%r' % (ghost['code'], ghost['ghost']))
            return 2
        print('ПРИБОР: контроль с описанием без файла -- покраснен, назван по пути')

        os.remove(readme)
        blind = measure(kit)
        if blind['code'] != 2 or not any('состав сверять не с чем' in r
                                         for r in blind['refusals']):
            print('ОТКАЗ: без README дверь описания не отказала прибором: '
                  'code=%d refusals=%r' % (blind['code'], blind['refusals']))
            return 2
        print('ПРИБОР: без README -- отказ прибора, а не пустая перепись')
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    if len(argv) > 1 and argv[1] == '--self-check':
        return self_check()
    if len(argv) > 1 and argv[1] == '--callers':
        result = measure(KIT, self_path=os.path.abspath(__file__))
        report(result, verbose=True)
        return result['code']
    if len(argv) > 1:
        print('ПРИБОР: неизвестный режим %r' % argv[1])
        return 2
    result = measure(KIT, self_path=os.path.abspath(__file__))
    report(result)
    return result['code']


if __name__ == '__main__':
    sys.exit(main(sys.argv))
