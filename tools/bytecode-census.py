#!/usr/bin/env python3
"""Ценз байткода изменённых модулей собранного образа.

Утверждение стенда: ни один модуль, текст которого наш конвейер изменил,
не несёт в собранном образе ненулевой длины байткода. С bun загрузчик
исполняет ПРЕДКОМПИЛИРОВАННЫЙ байткод модуля и никогда не сверяет его с
текстом исходника: текст читается только при нулевой длине байткода.
Правка текста РАВНОЙ длины поэтому мертва в рантайме, оставляя зелёным
весь байтовый реестр сборки, — этот стенд ловит ровно тот случай.

Коды выхода (подмножество таблицы кита): 0 — утверждение подтверждено
(изменённые модули есть, все без байткода); 1 — отказ по существу
(изменённый модуль несёт байткод, либо изменённых не оказалось вовсе);
2 — прибор не может мерить, своя строка на каждую причину, все начинаются
с «ПРИБОР:». Отказы по существу начинаются с «ОТКАЗ:».

Модульный график bun разбирается собственным парсером; внешних
зависимостей нет.
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile


# --- измеренные константы формата (bun, образы claude 2.1.27x) ----------------
# Все числа ниже — факты формата, измеренные на обеих платформах; менять их
# нельзя, не перемерив образ: каждый неверный кандидат даёт ЛОЖНО зелёный
# или ЛОЖНО красный ответ, а не отказ прибора.

# Трейлер appended-секции образа. Ищется ПОСЛЕДНЕЕ вхождение: такая же
# строка может встретиться и внутри текста модуля, а секция в файле одна.
TRAILER = b'\n---- Bun! ----\n'

# Размер одной записи модуля в таблице. modules_len обязан на него
# делиться; остаток означает, что формат графа сменился.
REC_SIZE = 52

# Указатель таблицы (modules_off, modules_len — два u32 LE) лежит ровно на
# столько байтов раньше начала трейлера; оба поля относительны базы.
MODULES_PTR_BACK = 24

# Смещение поля ДЛИНЫ байткода внутри записи — восьмой u32 подряд (пары
# off/len у name, contents, sourcemap, bytecode). Ровно это поле наш форк
# распаковщика обнуляет у изменённых модулей, и ровно его ненулевое
# значение у изменённого модуля здесь объявляется дефектом.
BYTECODE_LEN_OFF = 28

# Шаг, которым перебираются кандидаты базы вниз от выровненного трейлера:
# appended-секция начинается с выровненного так счётчика байтов (u64 LE),
# за которым сразу следует база.
BASE_STEP = 512

# Допуск сверки счётчика кандидата с хвостом файла: секция обязана
# объяснять файл до конца трейлера, всё, что осталось за пределами
# счётчика, — короче этого предела. Длиннее — кандидат не база.
BASE_SLACK = 65536

# Сколько первых записей таблицы обязаны читаться как имена виртуальной
# ФС: этим кандидат на базу отделяется от того, чей «счётчик» сошёлся
# случайно.
BASE_PROBE_RECORDS = 4

# Граница sane-длины имени модуля: настоящие имена короче; длиннее — не
# имя, а мусор, прочитанный как имя (таблица понята неверно).
NAME_LEN_MAX = 512

# Имена модулей живут в виртуальной ФС образа; запись, чьё имя не начинается
# с одного из этих префиксов, означает, что таблица прочитана не там.
NAME_PREFIXES = (b'/$bunfs/', b'B:/~BUN/', b'B:\\~BUN\\')


class InstrumentError(Exception):
    """Прибор не может мерить; line уже начинается с «ПРИБОР: »."""

    def __init__(self, line):
        super().__init__(line)
        self.line = line


def _show(name):
    return name.decode('utf-8', 'replace')


def _sample(names):
    if not names:
        return 'нет'
    head = ', '.join(_show(n) for n in names[:3])
    more = '' if len(names) <= 3 else ' (+ ещё {})'.format(len(names) - 3)
    return '{} шт: {}{}'.format(len(names), head, more)


def _table_names_valid(data, base, modules_off, modules_len):
    # Кандидат на базу подтверждается именами: первые записи таблицы
    # обязаны читаться как имена виртуальной ФС с sane-длиной.
    if modules_len // REC_SIZE < BASE_PROBE_RECORDS:
        return False
    table = base + modules_off
    if table < 0 or table + BASE_PROBE_RECORDS * REC_SIZE > len(data):
        return False
    for i in range(BASE_PROBE_RECORDS):
        rec = table + i * REC_SIZE
        name_off, name_len = struct.unpack_from('<II', data, rec)
        if not 0 < name_len < NAME_LEN_MAX:
            return False
        if not data[base + name_off:base + name_off + name_len].startswith(NAME_PREFIXES):
            return False
    return True


def _recover_base(data, trailer, modules_off, modules_len):
    # Смещения графа относительны базы — начала appended-секции. База
    # восстанавливается сверху вниз: выровненный кандидат читается как
    # счётчик байтов секции, и счётчик обязан объяснять хвост файла вплоть
    # до конца трейлера с малым допуском; подтверждение — имена в таблице.
    end = trailer + len(TRAILER)
    p = (trailer // BASE_STEP) * BASE_STEP
    while p >= 0:
        counter = struct.unpack_from('<Q', data, p)[0]
        slack = end - (p + 8) - counter
        if 0 <= slack < BASE_SLACK and _table_names_valid(data, p + 8, modules_off, modules_len):
            return p + 8
        p -= BASE_STEP
    return None


def parse_graph(path):
    """Разбор образа: (база, модули).

    Модули: имя (байты) -> (contents как memoryview, длина байткода,
    смещение записи в файле). Порядок вставки — порядок записей таблицы;
    поля за пределами восьми u32 (extra, name2, flags) не читаются.
    """
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError as e:
        raise InstrumentError('ПРИБОР: {} не читается: {}'.format(path, e))
    trailer = data.rfind(TRAILER)
    if trailer < 0:
        raise InstrumentError('ПРИБОР: трейлер bun не найден в {}'.format(path))
    if trailer < MODULES_PTR_BACK:
        raise InstrumentError(
            'ПРИБОР: трейлер у самого начала файла, указатель таблицы не '
            'читается ({})'.format(path))
    modules_off, modules_len = struct.unpack_from('<II', data, trailer - MODULES_PTR_BACK)
    if modules_len == 0:
        raise InstrumentError(
            'ПРИБОР: таблица модулей пуста (modules_len=0), мерить нечего ({})'.format(path))
    if modules_len % REC_SIZE != 0:
        raise InstrumentError(
            'ПРИБОР: modules_len={} не делится на {} — формат графа сменился '
            '({})'.format(modules_len, REC_SIZE, path))
    base = _recover_base(data, trailer, modules_off, modules_len)
    if base is None:
        raise InstrumentError(
            'ПРИБОР: база модульного графа не восстановлена ({})'.format(path))
    table = base + modules_off
    if table < 0 or table + modules_len > len(data):
        raise InstrumentError(
            'ПРИБОР: таблица модулей вне файла (modules_off={}, modules_len={}) '
            '— формат графа сменился ({})'.format(modules_off, modules_len, path))
    view = memoryview(data)
    modules = {}
    for i in range(modules_len // REC_SIZE):
        rec = table + i * REC_SIZE
        name_off, name_len, c_off, c_len = struct.unpack_from('<4I', data, rec)
        bc_len = struct.unpack_from('<I', data, rec + BYTECODE_LEN_OFF)[0]
        if not 0 < name_len < NAME_LEN_MAX:
            raise InstrumentError(
                'ПРИБОР: запись #{}: длина имени {} вне (0; {}) — формат графа '
                'сменился ({})'.format(i, name_len, NAME_LEN_MAX, path))
        name = data[base + name_off:base + name_off + name_len]
        if not name.startswith(NAME_PREFIXES):
            raise InstrumentError(
                'ПРИБОР: запись #{}: имя не из виртуальной ФС bun — формат '
                'графа сменился ({})'.format(i, path))
        if name in modules:
            raise InstrumentError(
                'ПРИБОР: имя модуля встречается дважды: {!r} ({})'.format(name, path))
        if base + c_off + c_len > len(data):
            raise InstrumentError(
                'ПРИБОР: запись #{}: contents вне файла — формат графа сменился '
                '({})'.format(i, path))
        modules[name] = (view[base + c_off:base + c_off + c_len], bc_len, rec)
    return base, modules


def strip_staging(path):
    # Суффикс стажировки снимается в той же форме, что и в конвейере
    # (__strip_staging из claude-patch-all.sh): точка восстановления лежит
    # рядом с ЖИВЫМ именем, а не со стажем, включая стаж с номером процесса.
    d, base = os.path.split(path)
    if base.endswith('.staging'):
        base = base[:-len('.staging')]
    else:
        head, sep, tail = base.rpartition('.staging.')
        if sep and tail.isdigit():
            base = head
    return os.path.join(d, base) if d else base


def corpus_root():
    return os.environ.get('CLAUDE_PATCH_CORPUS') or os.path.join(
        os.path.expanduser('~'), '.local', 'share', 'claude-patch', 'corpus')


def corpus_name_from_home(version):
    """Имя файла корпуса для версии — спрашивается у единственного дома.

    Дом tools/corpus-file-name.sh подключается и зовётся той же формой, что и
    у потребителей в оболочке (sweep.sh, fetch-corpus.sh): source, затем
    corpus_file_name <версия>.
    """
    home = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        'corpus-file-name.sh')
    # КОНСТРЕЙНТ: имя корпуса имеет ОДИН дом — смена суффикса обязана
    # доезжать до всех потребителей разом; отказ дома не легализуется
    # догадкой (запасного литерала здесь нет ни в каком виде).
    if not os.path.isfile(home):
        raise InstrumentError(
            'ПРИБОР: дом имени корпуса не найден: {} — имя не разрешить'.format(home))
    proc = subprocess.run(
        ['bash', '-c', '. "$1" && corpus_file_name "$2"', 'corpus-name-home',
         home, version],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise InstrumentError(
            'ПРИБОР: дом имени корпуса отказал (rc={}) для версии {}: {}'.format(
                proc.returncode, version,
                proc.stderr.decode('utf-8', 'replace').strip()))
    name = proc.stdout.decode('utf-8', 'replace').strip()
    if not name or '\n' in name:
        raise InstrumentError(
            'ПРИБОР: дом имени корпуса ответил не одним именем для версии {} '
            '({!r})'.format(version, proc.stdout[:200]))
    return name


def corpus_path(version):
    # Единственная точка разрешения: и рабочий поиск корпуса (resolve_stock),
    # и самоотчёт --print-corpus-name обязаны идти через неё, иначе зуб
    # самопроверки меряет не тот путь, которым живёт конвейер.
    return os.path.join(corpus_root(), corpus_name_from_home(version))


def resolve_stock(args):
    """Пристинный образ: явный --stock, затем близнец .orig, затем корпус."""
    if args.stock:
        if not os.path.isfile(args.stock):
            raise InstrumentError('ПРИБОР: явный --stock недоступен: {}'.format(args.stock))
        return args.stock
    twin = strip_staging(args.built) + '.orig'
    if os.path.isfile(twin):
        return twin
    if not args.version:
        raise InstrumentError(
            'ПРИБОР: пристинного близнеца нет ({}) и нет --version — '
            'имя корпуса спросить не у кого'.format(twin))
    corpus = corpus_path(args.version)
    if os.path.isfile(corpus):
        return corpus
    raise InstrumentError(
        'ПРИБОР: пристинного близнеца нет — проверены {} и {}'.format(twin, corpus))


def measure(stock_path, built_path):
    """Прогон ценза: (код, строки stdout, строка stderr|None, контекст).

    Код 0 — зелено, 1 — отказ по существу, InstrumentError — прибор.
    Контекст несёт изменённые модули для самоконтроля: кортеж (имя,
    смещение записи в собранном, длина байткода стока, длина байткода
    сборки, длина исходника стока, длина исходника сборки).
    """
    b_base, b_mods = parse_graph(built_path)
    s_base, s_mods = parse_graph(stock_path)
    with_bc_stock = sum(1 for v in s_mods.values() if v[1] != 0)
    if with_bc_stock == 0:
        # Ноль байткода в СТОКЕ — не «блоб уже снят», а слепой читатель:
        # зелёный ответ здесь ничего не доказывает.
        raise InstrumentError(
            'ПРИБОР: в стоке ноль модулей с ненулевым байткодом — слепой '
            'читатель, зеленеть запрещено ({})'.format(stock_path))
    only_stock = sorted(set(s_mods) - set(b_mods))
    only_built = sorted(set(b_mods) - set(s_mods))
    if only_stock or only_built:
        raise InstrumentError(
            'ПРИБОР: состав модулей стока и собранного не совпал (только в '
            'стоке: {}; только в собранном: {})'.format(
                _sample(only_stock), _sample(only_built)))
    changed = []
    for name, b in b_mods.items():
        s = s_mods[name]
        # Сравниваются именно БАЙТЫ contents: правка равной длины — тот
        # случай, ради которого стенд существует.
        if b[0] != s[0]:
            changed.append((name, b[2], s[1], b[1], len(s[0]), len(b[0])))
    culprits = [c for c in changed if c[3] != 0]
    with_bc_built = sum(1 for v in b_mods.values() if v[1] != 0)
    n = len(b_mods)
    out = [
        'стоковый : модулей {}, база {}'.format(n, s_base),
        'собранный: модулей {}, база {}'.format(n, b_base),
        'изменённых модулей {}, из них с ненулевым байткодом {}'.format(
            len(changed), len(culprits)),
        'контроль читателя: с байткодом в стоке {}/{}, в собранном {}/{}'.format(
            with_bc_stock, n, with_bc_built, n),
    ]
    for name, _rec, s_bc, b_bc, s_clen, b_clen in culprits:
        out.append('  НЕСЁТ БАЙТКОД: {} (исходник {} -> {} Б, байткод {} -> {})'.format(
            _show(name), s_clen, b_clen, s_bc, b_bc))
    if culprits:
        err = ('ОТКАЗ: изменённые модули несут ненулевой байткод — с bun '
               'исполняется предкомпилированный блоб, а не текст правки: {} из {} '
               '(имена выше)').format(len(culprits), len(changed))
        return 1, out, err, {'changed': changed}
    if not changed:
        err = ('ОТКАЗ: изменённых модулей ноль — собранный образ не отличается '
               'от стока, утверждение стенда не подтверждено ничем')
        return 1, out, err, {'changed': changed}
    return 0, out, None, {'changed': changed}


def plain(stock, built):
    try:
        code, out, err, _ctx = measure(stock, built)
    except InstrumentError as e:
        sys.stderr.write(e.line + '\n')
        return 2
    for line in out:
        print(line)
    if err:
        sys.stderr.write(err + '\n')
    return code


def self_check(stock, built):
    tmp = tempfile.mkdtemp(prefix='bytecode-census.')
    try:
        copy = os.path.join(tmp, os.path.basename(built) or 'image')
        try:
            shutil.copyfile(built, copy)
        except OSError as e:
            raise InstrumentError(
                'ПРИБОР: копия образа не собралась: {}'.format(e))
        try:
            code, out, err, ctx = measure(stock, copy)
        except InstrumentError:
            raise
        if code != 0:
            sys.stderr.write(
                'ПРИБОР: копия без мутации уже красна (код {}), мутировать '
                'нечего — предмет красен\n'.format(code))
            return 2
        for line in out:
            print(line)
        changed = ctx['changed']
        if not changed:
            # Недостижимо при зелёном ответе (зелёность требует изменённых
            # модулей), но самоконтроль не имеет права молчать о пустом предмете.
            sys.stderr.write('ПРИБОР: изменённых модулей нет — мутации не из чего выбрать\n')
            return 2
        name, rec, s_bc, _b_bc, _s_clen, _b_clen = changed[0]
        if s_bc == 0:
            sys.stderr.write(
                'ПРИБОР: первый изменённый модуль {} в стоке без байткода — '
                'вписывать нечего\n'.format(_show(name)))
            return 2
        # Мутация: первому изменённому модулю возвращается ЕГО стоковая длина
        # блоба — ровно то, что стоковый образ нес бы на этом месте.
        with open(copy, 'r+b') as f:
            f.seek(rec + BYTECODE_LEN_OFF)
            f.write(struct.pack('<I', s_bc))
        try:
            code2, out2, _err2, _ctx2 = measure(stock, copy)
        except InstrumentError:
            raise
        for line in out2:
            print(line)
        want = _show(name)
        named = any(want in line for line in out2)
        if code2 != 1 or not named:
            sys.stderr.write(
                'ОТКАЗ: самоконтроль разошёлся: мутант ответил кодом {}{}, а '
                'обязан кодом 1 и именем модуля {}\n'.format(
                    code2, '' if named else ' без имени модуля', want))
            return 1
        print('САМОКОНТРОЛЬ: мутация покраснила стенд своей причиной (модуль {})'.format(want))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description='Ценз байткода изменённых модулей собранного образа claude.')
    ap.add_argument('--built', help='путь к собранному образу')
    ap.add_argument('--stock', help='явный пристинный образ; побеждает оба автопоиска')
    ap.add_argument('--version', help='версия образа, для корпуса, когда близнеца .orig нет')
    ap.add_argument('--print-corpus-name', metavar='ВЕРСИЯ',
                    help='самоотчёт: напечатать ПУТЬ файла корпуса для версии и выйти нулём')
    ap.add_argument('--self-check', action='store_true',
                    help='собственный зуб: мутация обязана краснить стенд')
    args = ap.parse_args(argv)
    if args.print_corpus_name is not None and not args.print_corpus_name:
        ap.error('--print-corpus-name требует непустую версию')
    if args.print_corpus_name is None and not args.built:
        ap.error('без --print-corpus-name обязателен --built')
    try:
        if args.print_corpus_name is not None:
            print(corpus_path(args.print_corpus_name))
            return 0
        stock = resolve_stock(args)
        if args.self_check:
            return self_check(stock, args.built)
        return plain(stock, args.built)
    except InstrumentError as e:
        sys.stderr.write(e.line + '\n')
        return 2


if __name__ == '__main__':
    sys.exit(main())
