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
интерпретатором, врал нулём на живом дереве, и обе подключательные формы были
им пропущены:
 tools/<имя>                          -- путь с домом;
 $(dirname "$0")/<имя> и $HERE/<имя>  -- сосед по каталогу БЕЗ дома в пути;
 . <путь>/<имя> и source <путь>/<имя> -- ПОДКЛЮЧЕНИЕ, а не запуск;
 bash|sh|python3|node <путь>/<имя>    -- запуск интерпретатором.
Вхождение внутри самого инструмента и строки-комментарии вызовом не
считаются. Проза ЭТОГО файла из поиска исполнителей исключена целиком:
пример формы в докстринге иначе засчитался бы исполнителем настоящего
сироты.

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
}

TOOL_EXTS = ('.sh', '.py', '.js')
# CONSTRAINT: исполнителя ищут только оболочка и питон -- файлы данных и
# разметки вызвать инструмент не могут.
SEARCH_EXTS = ('.sh', '.py')
SKIP_DIRS = {'.git', 'docs', '__pycache__'}
FORM_LABELS = ('tools/<имя>', '$HERE либо $(dirname "$0")',
               'подключение (. либо source)', 'интерпретатор')


def form_regexes(name):
    """Четыре формы вызова одного инструмента (порядок = порядок меток)."""
    n = re.escape(name) + r'(?!\w)'
    return [
        re.compile(r'tools/' + n),
        re.compile(r'(\$HERE|\$\(dirname "\$0"\))/' + n),
        re.compile(r'(?:^|[\s;|&])(?:\.|source)\s+\S*' + n),
        re.compile(r'\b(?:bash|sh|python3|node)\b[^\n]*?/' + n),
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
            for number, line in enumerate(lines, 1):
                if line.lstrip().startswith('#'):
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
              'manual': [], 'callers': {}}
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
    callers = find_callers(kit, names, self_path)
    orphans = [name for name in names
               if name not in MANUAL and not callers[name]]
    result.update(code=1 if orphans else 0, orphans=orphans, tools=names,
                  manual=manual, callers=callers)
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
    if result['code'] == 0:
        print('инструментов %d, из них объявлено ручными %d, без исполнителя %d'
              % (len(result['tools']), len(result['manual']),
                 len(result['orphans'])))


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
        green = measure(kit)
        if green['code'] != 0:
            print('ОТКАЗ: без мутации перепись не зеленеет: code=%d '
                  'refusals=%r orphans=%r'
                  % (green['code'], green['refusals'], green['orphans']))
            return 2
        print('ПРИБОР: контроль без мутации -- зелен')
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
