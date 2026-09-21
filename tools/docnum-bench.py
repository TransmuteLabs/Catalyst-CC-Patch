#!/usr/bin/env python3
"""Зубы гейта чисел (шаг 0d конвейера).

Гейт сам по себе умеет молчать: он молчал трижды, и каждую дыру находили
руками, а не им. Внутри гейта живёт положительный контроль грамматики
(синтетические тексты с известным ответом), но он ничего не говорит о
СВЯЗКЕ гейта с настоящим деревом -- с README, с константами стендов, с
выбором владельца по ближайшему имени. Это она.

Порядок такой: сперва контроль без мутации (пристинный кит обязан быть
зелёным -- иначе краснеет что угодно и стенд ничего не доказывает), затем
каждая записанная мутация по очереди, каждая обязана покраснить гейт СВОЕЙ
причиной.

Гейт вырезается из конвейера по якорю. Якорь пропал -- отказ, а не тихий
пропуск: молча пропущенный стенд это ровно та тишина, ради которой он писан.

Коды выхода (подмножество общей таблицы кита -- см. шапку claude-patch-all.sh):
  0  каждая записанная мутация покраснела своей причиной
  1  зубы не держатся: мутация прошла молча или покраснела ЧУЖОЙ причиной
  2  прибор не может мерить: нет таблицы, строка не о пяти полях, реестр
     владельцев OWNERS не разобрался из вырезанного гейта, токен
     {OWNER:...} таблицы не разрешился (неизвестный владелец или величина,
     якорь владельца найден не один раз), счёт зубов подстановки не равен
     пину EXPECTED_OWNER_TEETH, якорь гейта пропал или встречается не один
     раз,
     ВЫРЕЗАННЫЙ ГЕЙТ НЕ РАЗБИРАЕТСЯ
     (py_compile перед прогоном; круг 25, E-2), ПРИСТИННЫЙ кит уже красный
     (контроль провален, и мутация ничего не докажет), либо выведенный из
     пути корень не несёт подписи кита (круг 24)
  4  объявленное не сходится с фактическим: длина таблицы не равна
     EXPECTED_MUTATIONS либо (режим --anchors) якорь строки не встречается
     в названном файле ровно один раз

Режим `--anchors` -- ПЕРЕПИСЬ ЯКОРЕЙ, отдельная дешёвая стадия. Он не собирает
кит и не гоняет гейт: для каждой строки таблицы проверяется, что её вход
встречается в названном файле ровно раз, и уехавший якорь называется СВОИМ
номером (D2), а не проявляется как «мутация не покраснела» после сорока
прогонов гейта. Повод -- круг 26, находка W-2: волна меняет форму или число, а
таблицы, запинившие прежнюю форму, находятся строго по одной за прогон.
Перепись несёт СВОЙ положительный контроль на синтетике (вход на месте, вход
пропал, вход задвоился, файла нет): без него «уехавших нет» не отличить от
«перепись ничего не смотрела». Она отвечает за ВХОДЫ строк и НЕ проверяет их
пятое поле -- ожидаемый след гейта; тот уезжает за теми же правками и ловится
только полным прогоном.
Один код на два ответа уже стоил кита: вызывающий печатал «мутация не
покраснела» на КАЖДЫЙ ненулевой, включая пропавший якорь (раунд 18, F-9).
Код разбора ДОМИНИРУЕТ над счётом покраснений: пока гейт не разбирается,
ни одному числу этого прогона веры нет.
"""
import ast
import contextlib
import io
import os
import py_compile
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(HERE)

# Круг 24: кит выводится из пути ЭТОГО файла, а ниже копируется ЦЕЛИКОМ
# (shutil.copytree(KIT, ...)). Позванный из копии вне кита, стенд принимает за
# кит произвольный каталог и копирует его: у соседнего стенда это замерено --
# KIT стал корнем файловой системы и 3.8 ГБ уехали в tmp до ручной остановки.
# Ошибка вывода корня ОБЪЯВЛЯЕТСЯ кодом 2 («прибор не может мерить»), а не
# исполняется. Проверка стоит ДО первой копии.
# CONSTRAINT: имён подписи здесь НЕТ -- их дом tools/kit-signature.txt, общий
# для трёх инструментов, которые копируют кит целиком. Своя копия перечня
# расходилась бы молча, и слабейшее из трёх опознаний решало бы, какой чужой
# каталог будет скопирован.
SIGNATURE_HOME = os.path.join('tools', 'kit-signature.txt')


def kit_signature(kit):
    """Перечень из дома; None -- дом нечитаем. Пустой список -- дом пуст.

    CONSTRAINT: пустой список и None -- РАЗНЫЕ отказы и называются по-разному.
    Пусто не ноль: подпись без имён означает смену формы дома, а не «проверять
    нечего», и слить их значило бы отвечать на второй случай диагнозом первого.
    """
    try:
        with open(os.path.join(kit, SIGNATURE_HOME), encoding='utf-8') as fh:
            text = fh.read()
    except OSError:
        return None
    return [line.strip() for line in text.splitlines()
            if line.strip() and not line.lstrip().startswith('#')]


def require_kit_root():
    """Страж стоит В ТОЧКЕ КОПИРОВАНИЯ, а не в шапке модуля.

    Причина та же, что у соседнего стенда: точка самой опасности одна, и новый
    вызывающий не сможет обойти проверку, а двери, которые НИЧЕГО не копируют,
    обязаны работать откуда угодно -- ставить страж в шапку значит запрещать и
    их. Отсутствие подписи -- код 2 «прибор не может мерить».
    """
    names = kit_signature(KIT)
    if names is None:
        sys.stderr.write(
            'docnum-bench: КОРЕНЬ НЕ КИТ -- в «%s» нет читаемой подписи %s.\n'
            '  Стенд копирует кит целиком; запускать только как\n'
            '  tools/docnum-bench.py внутри кита.\n'
            % (KIT, SIGNATURE_HOME))
        sys.exit(2)
    if not names:
        sys.stderr.write(
            'docnum-bench: подпись «%s» пуста -- форма дома сменилась,\n'
            '  опознание недействительно.\n'
            % os.path.join(KIT, SIGNATURE_HOME))
        sys.exit(2)
    missing = [n for n in names if not os.path.isfile(os.path.join(KIT, n))]
    if missing:
        sys.stderr.write(
            'docnum-bench: КОРЕНЬ НЕ КИТ -- в «%s» нет %s.\n'
            '  Стенд копирует кит целиком; запускать только как\n'
            '  tools/docnum-bench.py внутри кита.\n'
            % (KIT, ', '.join(missing)))
        sys.exit(2)

TABLE = os.path.join(HERE, 'docnum-mutations.tsv')
PIPELINE = 'claude-patch-all.sh'
ANCHOR = 'python3 - "$0" <<\'PYDOCS\'\n'
END = '\nPYDOCS\n'
# Круг 28, F-12(б): +1 -- мутация D40 на элидированную форму «все N».
EXPECTED_MUTATIONS = 48
# ПУСТО НЕ НОЛЬ и для самих зубов: «ноль провалов» без счётчика проверок
# неотличим от «зубы не измеряли ничего». Ровно столько проверок обязана
# прогнать teeth(); расхождение -- код 2 (прибор измерил не то, что объявил),
# а не тихая зелень. Этот пин -- сверка самИх зубов, в ran не входит.
EXPECTED_OWNER_TEETH = 19

# Счёт владельца в полях 3-5 таблицы пишется ТОКЕНОМ {OWNER:<id>:<величина>}
# и живёт в одном доме -- у владельца: цифра -- второй дом числа (владелец
# переезжает, цитата отстаёт, вход при этом найден, и зуб краснеет не по
# своей причине). Значения берутся из реестра OWNERS гейта чисел -- вторая
# копия перечня владельцев здесь расходилась бы с гейтом молча.
# CONSTRAINT: форма токена -- ровно {OWNER:<id>:<величина>}; фигурные скобки
# в якорях таблицы живут и в другом смысле (D18 `#{1,6}`, D22
# `\d{4}-\d{2}-\d{2}`), и сканер обязан видеть только свою форму.
OWNER_TOKEN = re.compile(
    r'\{OWNER:([A-Za-z0-9._-]+):([A-Za-z]+)(?::([+-]\d+))?\}')
# CONSTRAINT: мутант, несущий ГОЛОЕ число вместо токена, -- мина: он
# совпадёт со счётом владельца в тот день, когда владелец до него
# дорастёт, и ряд перестанет что-либо менять. Форма со сдвигом
# {OWNER:id:величина:+1} не может совпасть с владельцем по построению.
OWNER_RESIDUE = '{OWNER:'


def read(path):
    return io.open(path, encoding='utf-8').read()


def say(message):
    print('docnum-bench: ' + message, flush=True)


def load():
    if not os.path.exists(TABLE):
        say('ОТКАЗ -- нет таблицы мутаций %s' % TABLE)
        sys.exit(2)
    rows = []
    for line in read(TABLE).splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) != 5:
            say('ОТКАЗ -- строка таблицы не о пяти полях: %r' % line)
            sys.exit(2)
        rows.append(parts)
    return rows


def gate_body(source):
    """Тело гейта чисел из текста конвейера -- без записи и без исполнения."""
    if ANCHOR not in source:
        say('ОТКАЗ -- якорь гейта чисел пропал из %s' % PIPELINE)
        sys.exit(2)
    if source.count(ANCHOR) != 1:
        say('ОТКАЗ -- якорь гейта чисел встречается %d раз в %s: неизвестно, '
            'какое тело проверяется' % (source.count(ANCHOR), PIPELINE))
        sys.exit(2)
    start = source.index(ANCHOR) + len(ANCHOR)
    if END not in source[start:]:
        say('ОТКАЗ -- конец гейта чисел не найден в %s' % PIPELINE)
        sys.exit(2)
    return source[start:source.index(END, start)]


def owners_registry(source):
    """Реестр владельцев из вырезанного гейта: разбор ast, НЕ исполнение.

    CONSTRAINT: импорт гейта запустил бы сам гейт; собственная копия перечня
    владельцев здесь расходилась бы с гейтом молча. Любой отказ чтения --
    код 2: прибор без реестра не может мерить, а молчаливо пустой реестр
    легализовал бы таблицу, чьи токены больше никто не проверяет.
    """
    try:
        tree = ast.parse(gate_body(source))
    except SyntaxError as error:
        say('ОТКАЗ -- гейт чисел не разбирается для чтения OWNERS: %s' % error)
        sys.exit(2)
    assigns = [node for node in tree.body if isinstance(node, ast.Assign)
               and any(isinstance(target, ast.Name) and target.id == 'OWNERS'
                       for target in node.targets)]
    if not assigns:
        say('ОТКАЗ -- в вырезанном гейте нет присваивания OWNERS')
        sys.exit(2)
    if len(assigns) > 1:
        say('ОТКАЗ -- присваиваний OWNERS больше одного: %d' % len(assigns))
        sys.exit(2)
    try:
        owners = ast.literal_eval(assigns[0].value)
    except (ValueError, SyntaxError) as error:
        say('ОТКАЗ -- значение OWNERS не разбирается literal_eval: %s' % error)
        sys.exit(2)
    registry = {}
    for item in owners:
        if not isinstance(item, tuple) or len(item) != 4:
            say('ОТКАЗ -- элемент реестра OWNERS не кортеж из четырёх: %r'
                % (item,))
            sys.exit(2)
        oid, _names, parts, counts = item
        if not isinstance(oid, str) or not isinstance(counts, dict) or \
                (parts is not None and not isinstance(parts, tuple)):
            say('ОТКАЗ -- элемент реестра OWNERS не той формы: %r' % (item,))
            sys.exit(2)
        try:
            # re.M: якоря владельцев вида ^...$ обязаны матчиться построчно,
            # не только в начале и конце файла.
            compiled = {quantity: re.compile(rx, re.M)
                        for quantity, rx in counts.items()}
        except (re.error, TypeError) as error:
            say('ОТКАЗ -- регекспы величин владельца «%s» не компилируются: %s'
                % (oid, error))
            sys.exit(2)
        registry[oid] = (parts, compiled)
    return registry


def owner_value(registry, root, oid, quantity, row, shift=None):
    """Живое значение величины владельца; ПУСТО НЕ НОЛЬ.

    Якорь, найденный ноль или два раза, значит «не знаю, какое число
    цитировать», и прибор обязан сказать это кодом разбора (2), а не мерить
    со случайно-сходящимся ожиданием. Кэша нет: значение обязано следовать
    за владельцем в каждом прогоне подстановки.
    """
    if oid not in registry:
        say('ОТКАЗ -- ряд %s: неизвестный владелец «%s»' % (row, oid))
        sys.exit(2)
    parts, counts = registry[oid]
    if quantity not in counts:
        say('ОТКАЗ -- ряд %s: у владельца «%s» нет величины «%s»'
            % (row, oid, quantity))
        sys.exit(2)
    path = os.path.join(root, PIPELINE if parts is None else os.path.join(*parts))
    try:
        text = read(path)
    except OSError as error:
        say('ОТКАЗ -- файл владельца чисел не читается: %s: %s' % (path, error))
        sys.exit(2)
    found = counts[quantity].findall(text)
    if len(found) != 1:
        say('ОТКАЗ -- у владельца «%s» якорь величины «%s» найден %d раз, '
            'нужно ровно один (%s): %s'
            % (oid, quantity, len(found), counts[quantity].pattern, path))
        sys.exit(2)
    if shift is None:
        return found[0]
    # CONSTRAINT: сдвиг 0 вернул бы значение владельца и дал бы ряд, который
    # ничего не меняет -- ровно ту вакуумную зелень, ради которой сдвиг и
    # заведён. Нечисловая величина со сдвигом -- отказ ПРИБОРА, а не тихое
    # склеивание строки.
    try:
        base = int(found[0])
    except ValueError:
        say('ОТКАЗ -- ряд %s: величина «%s» владельца «%s» не число (%r), '
            'сдвиг неприменим' % (row, quantity, oid, found[0]))
        sys.exit(2)
    step = int(shift)
    if step == 0:
        say('ОТКАЗ -- ряд %s: сдвиг +0 вернул бы значение владельца -- '
            'мутация ничего не меняла бы' % row)
        sys.exit(2)
    return str(base + step)


def substitute(rows, registry, root):
    """Токены {OWNER:...} в полях 3-5 -- живыми значениями владельцев.

    Единственная точка подстановки: перепись и полный прогон получают ряды
    только отсюда -- две точки разошлись бы третьей копией знания.
    CONSTRAINT: нераспознанный остаток и совпавшие поля 3/4 -- код 2, не
    молча: тихий пропуск читался бы как «якорь уехал» и уводил бы следующую
    волну в ложный ремонт, а совпадение дало бы вакуумную зелень.
    """
    out = []
    for name, rel, old, new, want in rows:
        # CONSTRAINT: ряд, чей ВХОД цитирует счёт владельца, а МУТАНТ несёт
        # голое число, -- отложенная мина (класс «якорь заморозил чужой
        # счётчик»): он молча перестанет мутировать, когда владелец дорастёт
        # до этого числа. Мутант обязан либо сам быть токеном (в том числе со
        # сдвигом), либо не содержать цифр вовсе.
        if OWNER_TOKEN.search(old) and not OWNER_TOKEN.search(new) \
                and any(ch.isdigit() for ch in new):
            say('ОТКАЗ -- ряд %s: вход цитирует счёт владельца, а мутант '
                'несёт голое число (%r) -- оно совпадёт со счётом, когда '
                'владелец до него дорастёт; писать {OWNER:id:величина:+1}'
                % (name, new))
            sys.exit(2)
        fields = [old, new, want]
        for index, text in enumerate(fields):
            fields[index] = OWNER_TOKEN.sub(
                lambda match: owner_value(registry, root, match.group(1),
                                          match.group(2), name,
                                          match.group(3)),
                text)
            if OWNER_RESIDUE in fields[index]:
                say('ОТКАЗ -- ряд %s, поле %d: после подстановки остался '
                    'неразрешённый текст вида {OWNER:...' % (name, index + 3))
                sys.exit(2)
        if fields[0] == fields[1]:
            say('ОТКАЗ -- ряд %s: после подстановки вход равен мутации -- '
                'мутация ничего не меняет, зелень была бы вакуумной' % name)
            sys.exit(2)
        out.append((name, rel, fields[0], fields[1], fields[2]))
    return out


def resolved_rows():
    """Ряды с подставленными значениями -- раздача ОБОИМ проходам."""
    return substitute(load(),
                      owners_registry(read(os.path.join(KIT, PIPELINE))), KIT)


def carve(kit):
    """Гейт как отдельный исполняемый файл, вырезанный из конвейера."""
    body = gate_body(read(os.path.join(kit, PIPELINE)))
    path = os.path.join(kit, '.docnum-gate.py')
    io.open(path, 'w', encoding='utf-8').write(body)
    # Круг 25, E-2: след ищется подстрокой в ВЫВОДЕ гейта, а питоновский
    # SyntaxError печатает СТРОКУ ИСХОДНИКА, на которой сломался разбор. У
    # большинства записей таблицы ждём-след лежит дословно в теле гейта
    # (описания синтетических случаев), поэтому мутация, ломающая ТОЛЬКО
    # разбор на строке со своим же следом, читалась как зуб: гейт «краснел
    # своей причиной», доказывая лишь то, что файл можно испортить. Аудитор
    # доказал это на записи D9 -- замена из одних скобок до кортежа держала
    # механизм нетронутым, гейт оставался зелёным по счёту и EXIT=0.
    # Проверка стоит В ТОЧКЕ вырезания: carve() зовут и контролем, и каждой
    # мутацией (мутация может править сам гейт), поэтому провал разбора
    # останавливает прогон ДО любого счёта -- код «прибор не может мерить»
    # доминирует над кодом «зубы не держатся». Паллиатив «след не должен
    # совпадать с правимой строкой» отвергнут контроллером: чинится механизм,
    # а не симптом.
    try:
        py_compile.compile(path, doraise=True)
    except py_compile.PyCompileError as error:
        say('ОТКАЗ -- вырезанный гейт не разбирается: %s' % error)
        sys.exit(2)
    return path


def census(rows, root):
    """Уехавшие якоря: (номер, файл, чем именно не сошлось)."""
    stale = []
    for name, rel, old, _new, _want in rows:
        target = os.path.join(root, rel)
        if not os.path.exists(target):
            stale.append((name, rel, 'нет файла'))
            continue
        seen = read(target).count(old)
        if seen != 1:
            stale.append((name, rel, 'вхождений %d, а нужно ровно одно' % seen))
    return stale


def census_control():
    """Положительный контроль переписи на синтетике.

    Перепись, которая ничего не смотрит, отвечает «уехавших нет» на любое
    дерево. Контроль исполняет её на четырёх заведомых случаях и требует
    ровно три отказа с нужными номерами; расхождение -- код «прибор не
    может мерить», а не тихое зелено.
    """
    work = tempfile.mkdtemp(prefix='docnum-census-control.')
    try:
        io.open(os.path.join(work, 'один.txt'), 'w',
                encoding='utf-8').write('якорь\nхвост\n')
        io.open(os.path.join(work, 'два.txt'), 'w',
                encoding='utf-8').write('якорь\nякорь\n')
        io.open(os.path.join(work, 'без.txt'), 'w',
                encoding='utf-8').write('ничего\n')
        probe = [('K1', 'один.txt', 'якорь', 'иначе', 'след'),
                 ('K2', 'без.txt', 'якорь', 'иначе', 'след'),
                 ('K3', 'два.txt', 'якорь', 'иначе', 'след'),
                 ('K4', 'нет-файла.txt', 'якорь', 'иначе', 'след')]
        got = sorted(name for name, _rel, _why in census(probe, work))
        return got == ['K2', 'K3', 'K4']
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _refusal(caption, run, *needles):
    """Ожидание отказа кодом 2 с названными иглами; None -- сошлось."""
    buffer = io.StringIO()
    code = 'вызов вернулся без отказа'
    try:
        with contextlib.redirect_stdout(buffer):
            run()
    except SystemExit as error:
        code = error.code
    text = buffer.getvalue()
    if code != 2:
        return '%s: ожидался код 2, вышло %r (печать: %s)' % (
            caption, code, text.strip() or 'пусто')
    missing = [needle for needle in needles if needle not in text]
    if missing:
        return '%s: в отказе нет %r (печать: %s)' % (
            caption, missing, text.strip())
    return None


def teeth():
    """Зубы подстановки {OWNER:...} на синтетике (бриф #312, T1-T8).

    Дисциплина census_control: синтетическое дерево, известные ответы,
    расхождение -- код «прибор не может мерить» (2), а не тихая зелень.
    Возвращает (список провалов, число прогнанных проверок); счёт
    растёт В ТОЧКЕ проверки, чтобы потерянный целиком блок занизил его.
    """
    failures = []
    ran = [0]

    def count(ok, message):
        ran[0] += 1
        if not ok:
            failures.append(message)

    work = tempfile.mkdtemp(prefix='docnum-owner-teeth.')
    try:
        gate = ('head\n' + ANCHOR + "OWNERS = (\n"
                "    ('toy', ('toy',), ('toy.txt',),\n"
                "     {'items': r'^ITEMS=(\\d+)'}),\n"
                "    ('toy2', ('toy2',), ('toy2.txt',),\n"
                "     {'items': r'^ITEMS=(\\d+)'}),\n"
                "    ('toy3', ('toy3',), ('toy3.txt',),\n"
                "     {'items': r'^ITEMS=(\\d+)'}),\n"
                ")\n" + END + 'tail\n')
        io.open(os.path.join(work, PIPELINE), 'w', encoding='utf-8').write(gate)
        io.open(os.path.join(work, 'toy.txt'), 'w',
                encoding='utf-8').write('ITEMS=7\n')
        io.open(os.path.join(work, 'toy2.txt'), 'w',
                encoding='utf-8').write('ITEMS=1\nITEMS=2\n')
        io.open(os.path.join(work, 'toy3.txt'), 'w',
                encoding='utf-8').write('нет якоря\n')
        registry = owners_registry(read(os.path.join(work, PIPELINE)))

        # T1: значение живое -- ряд находит вход и ПОСЛЕ сдвига владельца.
        row = ('K1', 'toy.txt', 'держит {OWNER:toy:items} предметов',
               'иначе', 'след')
        got = substitute([row], registry, work)
        count(got[0][2] == 'держит 7 предметов',
              'T1: токен не разрешился значением владельца: %r' % (got[0][2],))
        io.open(os.path.join(work, 'toy.txt'), 'w',
                encoding='utf-8').write('ITEMS=9\n')
        got = substitute([row], registry, work)
        count(got[0][2] == 'держит 9 предметов',
              'T1: значение владельца заморожено, сдвиг 7->9 не виден: %r'
              % (got[0][2],))

        # T2, T3: неизвестный владелец и неизвестная величина названы с рядом.
        for caption, run, needles in [
                ('T2', lambda: substitute(
                    [('K2', 'toy.txt', 'v {OWNER:nosuch:items}', 'иначе',
                      'след')], registry, work),
                 ('K2', 'nosuch')),
                ('T3', lambda: substitute(
                    [('K3', 'toy.txt', 'v {OWNER:toy:nosuch}', 'иначе',
                      'след')], registry, work),
                 ('K3', 'toy', 'nosuch'))]:
            failure = _refusal(caption, run, *needles)
            count(failure is None, failure)

        # T6: форма СО СДВИГОМ даёт значение владельца плюс шаг и следует
        # за ним -- мутант, выраженный сдвигом, не может совпасть со счётом.
        row6 = ('K6', 'toy.txt', 'держит {OWNER:toy:items} предметов',
                'держит {OWNER:toy:items:+1} предметов', 'след')
        got = substitute([row6], registry, work)
        count(got[0][2] == 'держит 9 предметов',
              'T6: вход не разрешился значением владельца: %r' % (got[0][2],))
        count(got[0][3] == 'держит 10 предметов',
              'T6: сдвиг не применился: %r' % (got[0][3],))

        # T7: сдвиг +0 вернул бы значение владельца -- отказ, а не молчание.
        failure = _refusal('T7', lambda: substitute(
            [('K7', 'toy.txt', 'A {OWNER:toy:items}',
              'A {OWNER:toy:items:+0}', 'след')], registry, work), 'K7')
        count(failure is None, failure)

        # T8: сторож замороженного числа. Ряд, чей вход цитирует счёт
        # владельца, а мутант несёт голое число, -- отложенная мина, и
        # сторож обязан назвать ряд ДО подстановки.
        # CONSTRAINT: число мутанта здесь ЗАВЕДОМО НЕ РАВНО счёту владельца
        # (7 против 9), и зуб требует СОБСТВЕННЫХ слов сторожа. Иначе отказ
        # «вход равен мутации» (T5), срабатывающий на равном числе уже ПОСЛЕ
        # подстановки, выдавал бы себя за сторожа: замер показал зелёный зуб
        # при обезоруженном стороже -- два отказа с одним именем ряда
        # неразличимы, зуб обязан требовать ИМЯ отказа.
        failure = _refusal('T8', lambda: substitute(
            [('K8', 'toy.txt', 'держит {OWNER:toy:items} предметов',
              'держит 7 предметов', 'след')], registry, work),
            'K8', 'голое число')
        count(failure is None, failure)

        # T4: нераспознанный остаток {OWNER: обязан назвать ряд и поле.
        for caption, run, needles in [
                ('T4-поле-3', lambda: substitute(
                    [('K4', 'toy.txt', 'X {OWNER:toy:items', 'иначе',
                      'след')], registry, work),
                 ('K4', 'поле 3')),
                ('T4-поле-5', lambda: substitute(
                    [('K4', 'toy.txt', 'вход', 'иначе', 'след {OWNER:toy:}')],
                    registry, work),
                 ('K4', 'поле 5'))]:
            failure = _refusal(caption, run, *needles)
            count(failure is None, failure)

        # T5: подстановка, не меняющая текста, -- вакуумная зелень.
        failure = _refusal('T5', lambda: substitute(
            [('K5', 'toy.txt', 'A {OWNER:toy:items}', 'A {OWNER:toy:items}',
              'след')], registry, work), 'K5')
        count(failure is None, failure)

        # T6: якорь владельца обязан найтись ровно один раз.
        for caption, run, needles in [
                ('T6-дважды', lambda: substitute(
                    [('K6', 'toy2.txt', 'v {OWNER:toy2:items}', 'иначе',
                      'след')], registry, work),
                 ('toy2', 'items', '2', 'toy2.txt')),
                ('T6-ноль', lambda: substitute(
                    [('K6', 'toy3.txt', 'v {OWNER:toy3:items}', 'иначе',
                      'след')], registry, work),
                 ('toy3', 'items', '0', 'toy3.txt'))]:
            failure = _refusal(caption, run, *needles)
            count(failure is None, failure)

        # T7: фигурные скобки чужого смысла сканер не трогает.
        row7 = ('K7', 'd18.txt',
                "BLOCK_MD = re.compile(r'^\\s*(?:#{1,6}\\s)')",
                "MASK = re.compile(r'\\d{4}-\\d{2}-\\d{2}')",
                'след')
        got7 = substitute([row7], registry, work)
        count((got7[0][2], got7[0][3], got7[0][4]) == (row7[2], row7[3],
                                                       row7[4]),
              'T7: сканер съел чужие фигурные скобки: %r' % (got7[0],))

        # T8: реестр OWNERS обязан читаться из гейта или отказать с причиной.
        broken = [
            ('T8-нет-присваивания',
             'head\n' + ANCHOR + "X = 1\n" + END + 'tail\n',
             ('нет присваивания OWNERS',)),
            ('T8-больше-одного',
             'head\n' + ANCHOR + "OWNERS = ()\nOWNERS = ()\n" + END + 'tail\n',
             ('больше одного',)),
            ('T8-не-literal',
             'head\n' + ANCHOR + "OWNERS = () or ()\n" + END + 'tail\n',
             ('literal_eval',)),
            ('T8-не-кортеж-из-четырёх',
             'head\n' + ANCHOR + "OWNERS = (('toy', ('toy',), None),)\n"
             + END + 'tail\n',
             ('не кортеж из четырёх',)),
            ('T8-четвёртый-не-словарь',
             'head\n' + ANCHOR + "OWNERS = (('toy', ('toy',), None, 'x'),)\n"
             + END + 'tail\n',
             ('не той формы',)),
        ]
        for caption, text, needles in broken:
            failure = _refusal(caption,
                               lambda t=text: owners_registry(t), *needles)
            count(failure is None, failure)

        return failures, ran[0]
    finally:
        shutil.rmtree(work, ignore_errors=True)


def owner_teeth():
    """teeth() со сверкой пина: потерянный зуб виден ЧИСЛОМ, а не тишиной.

    Зуб на сам механизм счёта: живёт здесь, вне teeth(), и потому в ran не
    входит. Расхождение -- код 2: прибор измерил не то, что объявил.
    """
    failures, ran = teeth()
    if ran != EXPECTED_OWNER_TEETH:
        say('ОТКАЗ -- зубы подстановки прогнали %d проверок, пин %d: '
            'потерянный зуб -- прибор измерил не то, что объявил'
            % (ran, EXPECTED_OWNER_TEETH))
        sys.exit(2)
    return failures, ran


def main_anchors():
    failures, ran = owner_teeth()
    for failure in failures:
        say('ПОДСТАНОВКА НЕ ДЕРЖИТ -- %s' % failure)
    if failures:
        return 2
    say('ЗУБЫ ПОДСТАНОВКИ: %d/%d' % (ran, EXPECTED_OWNER_TEETH))
    rows = resolved_rows()
    if not census_control():
        say('ПЕРЕПИСЬ НЕ ИЗМЕРЯЛА -- контроль на синтетике не сошёлся')
        return 2
    if len(rows) != EXPECTED_MUTATIONS:
        say('ОТКАЗ -- в таблице %d строк, объявлено %d'
            % (len(rows), EXPECTED_MUTATIONS))
        return 4
    stale = census(rows, KIT)
    for name, rel, why in stale:
        say('ЯКОРЬ %s УЕХАЛ -- %s: %s' % (name, rel, why))
    if stale:
        say('ИТОГ переписи: уехало %d из %d' % (len(stale), len(rows)))
        return 4
    # Граница прибора называется вслух: перепись читает ТРЕТЬЕ поле (вход) и
    # ничего не знает о ПЯТОМ (ожидаемый след гейта). След уезжает за теми же
    # правками -- у D2 он остался на «127 mutations» (docnum:historical), когда
    # вход уже стал 128, и поймал это только полный прогон. Зелёная перепись
    # значит «входы на месте», а не «таблица догнала волну».
    say('ИТОГ переписи: все %d якорей на месте (входы; ожидаемый след строки'
        % len(rows))
    say('  проверяется только полным прогоном гейта)')
    return 0


def run_gate(kit, gate):
    done = subprocess.run([sys.executable, gate, os.path.join(kit, PIPELINE)],
                          capture_output=True, text=True, errors="replace")
    return done.returncode, (done.stdout or '') + (done.stderr or '')


def main():
    failures, ran = owner_teeth()
    for failure in failures:
        say('ПОДСТАНОВКА НЕ ДЕРЖИТ -- %s' % failure)
    if failures:
        return 2
    say('ЗУБЫ ПОДСТАНОВКИ: %d/%d' % (ran, EXPECTED_OWNER_TEETH))
    rows = resolved_rows()
    work = tempfile.mkdtemp(prefix='docnum-bench.')
    try:
        kit = os.path.join(work, 'kit')
        require_kit_root()
        shutil.copytree(KIT, kit, ignore=shutil.ignore_patterns('.git'))
        gate = carve(kit)

        code, out = run_gate(kit, gate)
        if code != 0:
            say('КОНТРОЛЬ ПРОВАЛЕН -- пристинный кит уже красный, мутации ничего')
            say('не докажут. Вывод гейта:')
            for line in out.splitlines():
                print('    ' + line)
            # Класс 2: измерения не было. Прежде здесь стоял код 3, а 3 в
            # таблице кита значит «замок держит другой живой прогон --
            # повторить позже»; повтор тут не помогает никогда (раунд 19, A-4).
            return 2
        say('КОНТРОЛЬ без мутации: ЗЕЛЁНО')

        # Зуб замыкания знаменателя: зелёный вердикт обязан разложить ВСЕ
        # пары «величина × владелец» из OWNERS по двум разрядам --
        # подтверждённые «(утв. N)» и «БЕЗ УТВЕРЖДЕНИЙ В ПРОЗЕ». Вердикт,
        # печатающий реестр объявленного, неотличим от сверившего: молчащий
        # разряд читается так же, как отсутствующий.
        if 'БЕЗ УТВЕРЖДЕНИЙ В ПРОЗЕ:' not in out:
            say('ОТКАЗ -- вердикт не замыкает знаменатель: нет строки '
                '«БЕЗ УТВЕРЖДЕНИЙ В ПРОЗЕ:»')
            return 1
        head_line = [l for l in out.splitlines()
                     if 'СОВПАДАЮТ С ОБЪЯВЛЕННЫМИ' in l]
        tail_line = [l for l in out.splitlines()
                     if l.startswith('БЕЗ УТВЕРЖДЕНИЙ В ПРОЗЕ:')]
        if len(head_line) != 1 or len(tail_line) != 1:
            say('ОТКАЗ -- вердикт не замыкает знаменатель: строк вердикта '
                'СОВПАДАЮТ=%d, БЕЗ УТВЕРЖДЕНИЙ=%d, нужно по одной'
                % (len(head_line), len(tail_line)))
            return 1
        confirmed_n = head_line[0].count('(утв. ')
        bare_text = tail_line[0].split(':', 1)[1].strip()
        bare_n = 0 if bare_text == 'нет' else len(bare_text.split(', '))
        registry = owners_registry(read(os.path.join(kit, PIPELINE)))
        total = sum(len(counts) for _parts, counts in registry.values())
        if confirmed_n + bare_n != total:
            say('ОТКАЗ -- вердикт не замыкает знаменатель: сверено %d, '
                'без утверждений %d, в реестре %d'
                % (confirmed_n, bare_n, total))
            return 1

        reddened = 0
        for name, rel, old, new, want in rows:
            target = os.path.join(kit, rel)
            if not os.path.exists(target):
                say('МУТАЦИЯ %s: FAIL -- нет файла %s' % (name, rel))
                continue
            pristine = read(target)
            seen = pristine.count(old)
            if seen == 0:
                say('МУТАЦИЯ %s: FAIL -- вход не найден дословно в %s' % (name, rel))
                continue
            if seen != 1:
                say('МУТАЦИЯ %s: FAIL -- вход встречается %d раз в %s: мутация '
                    'подтвердилась бы по теневому совпадению' % (name, seen, rel))
                continue
            io.open(target, 'w', encoding='utf-8').write(pristine.replace(old, new))
            # Гейт вырезается заново: мутация могла править сам гейт.
            code, out = run_gate(kit, carve(kit))
            io.open(target, 'w', encoding='utf-8').write(pristine)
            if code == 0:
                say('МУТАЦИЯ %s: ЗЕЛЁНАЯ -- гейт её не увидел' % name)
            elif want not in out:
                say('МУТАЦИЯ %s: КРАСНАЯ НЕ ПО ТОЙ ПРИЧИНЕ (нет «%s»):' % (name, want))
                for line in out.splitlines():
                    print('    ' + line)
            else:
                say('МУТАЦИЯ %s: RED' % name)
                reddened += 1

        say('ИТОГ мутаций=%d покраснели=%d' % (len(rows), reddened))
        if len(rows) != EXPECTED_MUTATIONS:
            say('ОТКАЗ -- в таблице %d строк, объявлено %d'
                % (len(rows), EXPECTED_MUTATIONS))
            return 4
        return 0 if reddened == len(rows) else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--anchors':
        require_kit_root()
        sys.exit(main_anchors())
    if len(sys.argv) > 1:
        say('ОТКАЗ -- неизвестный режим %r' % sys.argv[1])
        sys.exit(2)
    sys.exit(main())
