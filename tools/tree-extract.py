#!/usr/bin/env python3
"""Извлечение виртуальной ФС bun-standalone образа в реальное дерево.

Формат таблицы модулей не дублируется: разбор — tools/bytecode-census.py
(parse_graph). Здесь только раскладка файлов и байтовая перезапись литерала.

Коды: 0 — сделано; 2 — прибор не может мерить (строка «ПРИБОР: …»).
Ноль вхождений литерала /$bunfs/root/ — код 2, не успех (ПУСТО ≠ НОЛЬ).
"""

from __future__ import print_function

import argparse
import importlib.util
import os
import re
import struct
import sys


LIT = b'/$bunfs/root/'

# MUT anchors are unique on purpose: --self-check replaces exactly one copy.
REWRITE_ENABLED = True  # MUT_REWRITE
BUNFS_ROOT_SUFFIX = '/$bunfs/root/'  # MUT_BUNFS_PREFIX
ZERO_HITS_IS_ERROR = True  # MUT_ZERO_HITS

VIRTUAL_ROOTS = ('/$bunfs/root/', 'B:/~BUN/root/', 'B:\\~BUN\\root\\')


class InstrumentError(Exception):
    """Прибор не может мерить; line уже начинается с «ПРИБОР: »."""

    def __init__(self, line):
        super(InstrumentError, self).__init__(line)
        self.line = line


def _load_census():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.environ.get('TREE_CENSUS') or os.path.join(here, 'bytecode-census.py')
    if not os.path.isfile(path):
        raise InstrumentError(
            'ПРИБОР: нет bytecode-census.py ({}) — таблицу модулей разобрать нечем'.format(path))
    spec = importlib.util.spec_from_file_location('tree_extract_bc', path)
    if spec is None or spec.loader is None:
        raise InstrumentError('ПРИБОР: bytecode-census.py не загружается: {}'.format(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def parse_image(image):
    bc = _load_census()
    try:
        return bc.parse_graph(image)
    except bc.InstrumentError as e:
        raise InstrumentError(e.line)


def stub_version(image):
    try:
        data = open(image, 'rb').read()
    except OSError as e:
        raise InstrumentError('ПРИБОР: образ не читается: {}: {}'.format(image, e))
    found = re.findall(br'bun-v[0-9][0-9.]*', data)
    if not found:
        raise InstrumentError(
            'ПРИБОР: стаб bun (bun-v…) в образе не найден ({})'.format(image))
    return found[0].decode('ascii', 'replace')


def split_virtual(name):
    s = name.decode('utf-8', 'replace') if isinstance(name, bytes) else name
    for pref in VIRTUAL_ROOTS:
        if s.startswith(pref):
            rest = s[len(pref):].replace('\\', '/')
            if not rest or rest.endswith('/'):
                raise InstrumentError(
                    'ПРИБОР: имя модуля без файла после корня виртуальной ФС: {}'.format(s))
            return rest
    raise InstrumentError(
        'ПРИБОР: имя модуля не из виртуальной ФС bun: {}'.format(s))


def dest_for(name, tree):
    rest = split_virtual(name)
    suffix = BUNFS_ROOT_SUFFIX.strip('/').replace('\\', '/')
    return os.path.join(tree, suffix, rest)


def make_prefix(tree):
    tree_abs = os.path.abspath(tree)
    # КОНСТРЕЙНТ: префикс ОБЯЗАН сохранять подстроку $bunfs.
    # В бою путь модуля виртуальный — CLI не читает исходник верхнего кадра
    # стека для фрагмента у ошибки. Предикат этого чтения в 2.1.273 linux —
    # единственный вызов xg() в chunk-mdeqame7.js (минифицированное имя и
    # файл чанка — координаты этой версии, не вечные):
    #   xg(n){return n.includes("$bunfs")||n.includes("~BUN")||n.includes("/snapshot/")||n.startsWith("node:")}
    # Резолв модулей от подстроки не зависит (замерено A/B на шести входах).
    # Проверка остаётся как требование ВЕРНОСТИ СТЕНДА БОЮ: в бою путь
    # виртуальный, в дереве файлы лежат на диске по-настоящему.
    # ЧЕСТНАЯ ГРАНИЦА: наблюдаемого различия A/B найти НЕ УДАЛОСЬ — 50 входов
    # плюс 15 внутренних, фрагмент исходника не показан ни разу (ветка xg
    # живёт в ink-обработчике zs, который на этом bun не рендерится). То есть
    # требование конструктивное, а не подтверждённое замером; нашедшему вход,
    # где A и B расходятся, — превратить его в зуб, а не подпирать словами.
    prefix = (tree_abs + BUNFS_ROOT_SUFFIX).encode('utf-8')
    if b'$bunfs' not in prefix:  # MUT_BUNFS_CHECK
        raise InstrumentError(
            'ПРИБОР: префикс не содержит $bunfs — виртуальный путь боя не сохранён, стенд читал бы исходник для фрагмента у стека: {!r}'.format(
                prefix.decode('utf-8', 'replace')))
    return prefix


def write_meta(tree, fields):
    path = os.path.join(tree, '.tree-meta')
    lines = []
    for key in sorted(fields):
        val = fields[key]
        if '\n' in val or '\r' in val:
            raise InstrumentError('ПРИБОР: значение мета {} содержит перевод строки'.format(key))
        lines.append('{}={}\n'.format(key, val))
    with open(path, 'w', encoding='utf-8') as fh:
        fh.writelines(lines)


def read_meta(tree):
    path = os.path.join(tree, '.tree-meta')
    if not os.path.isfile(path):
        raise InstrumentError('ПРИБОР: нет метаданных дерева ({})'.format(path))
    fields = {}
    with open(path, encoding='utf-8') as fh:
        for raw in fh:
            line = raw.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                raise InstrumentError('ПРИБОР: кривая строка мета: {!r}'.format(line))
            key, val = line.split('=', 1)
            fields[key] = val
    return fields


def extract(image, tree):
    if not os.path.isfile(image):
        raise InstrumentError('ПРИБОР: нет образа: {}'.format(image))
    base, modules = parse_image(image)
    if not modules:
        raise InstrumentError('ПРИБОР: таблица модулей пуста ({})'.format(image))
    os.makedirs(tree, exist_ok=True)
    prefix = make_prefix(tree)
    stub = stub_version(image)
    total = 0
    hits = 0
    hit_files = 0
    cli_rel = None
    for name, (contents, _bc_len, _rec) in modules.items():
        dest = dest_for(name, tree)
        parent = os.path.dirname(dest)
        if parent:
            os.makedirs(parent, exist_ok=True)
        data = bytes(contents)
        n = data.count(LIT)
        if n and REWRITE_ENABLED:
            data = data.replace(LIT, prefix)
            hits += n
            hit_files += 1
        elif n and not REWRITE_ENABLED:
            hits += n
            hit_files += 1
        with open(dest, 'wb') as fh:
            fh.write(data)
        total += len(data)
        rest = split_virtual(name)
        if rest == 'cli':
            suffix = BUNFS_ROOT_SUFFIX.strip('/').replace('\\', '/')
            cli_rel = os.path.join(suffix, rest)
    if ZERO_HITS_IS_ERROR and hits == 0:
        raise InstrumentError(
            'ПРИБОР: ноль вхождений литерала /$bunfs/root/ — переписывать нечего, '
            'это не успех ({})'.format(image))
    if REWRITE_ENABLED and hits == 0 and not ZERO_HITS_IS_ERROR:
        pass
    if not REWRITE_ENABLED:
        # Hits were counted so the caller can see the literal is present;
        # files on disk still have the virtual path and bun will not resolve it.
        hits_written = 0
        files_written = 0
    else:
        hits_written = hits
        files_written = hit_files
    if cli_rel is None:
        raise InstrumentError(
            'ПРИБОР: в образе нет модуля cli ({})'.format(image))
    write_meta(tree, {
        'image': os.path.abspath(image),
        'stub': stub,
        'prefix': prefix.decode('utf-8', 'replace'),
        'cli': cli_rel,
        'modules': str(len(modules)),
        'rewrites': str(hits_written),
        'rewrite_files': str(files_written),
        'suffix': BUNFS_ROOT_SUFFIX,
        'base': str(base),
    })
    print(
        'extracted {} modules, {} bytes, rewrites={} files={} -> {}'.format(
            len(modules), total, hits_written, files_written, os.path.abspath(tree)))
    return 0


def update(tree, src):
    if not os.path.isdir(tree):
        raise InstrumentError('ПРИБОР: нет дерева: {}'.format(tree))
    if not os.path.isdir(src):
        raise InstrumentError('ПРИБОР: нет источника обновления: {}'.format(src))
    meta = read_meta(tree)
    prefix = meta.get('prefix', '').encode('utf-8')
    if not prefix:
        raise InstrumentError('ПРИБОР: в мета нет prefix ({})'.format(tree))
    if b'$bunfs' not in prefix:  # same invariant as extract
        raise InstrumentError(
            'ПРИБОР: prefix в мета не содержит $bunfs: {!r}'.format(
                prefix.decode('utf-8', 'replace')))
    updated = 0
    scanned = 0
    src = os.path.abspath(src)
    for dirpath, dirnames, filenames in os.walk(src, followlinks=False):
        dirnames.sort()
        filenames.sort()
        for name in filenames:
            if name == '.tree-meta':
                continue
            src_path = os.path.join(dirpath, name)
            rel = os.path.relpath(src_path, src)
            dest = os.path.join(tree, rel)
            try:
                data = open(src_path, 'rb').read()
            except OSError as e:
                raise InstrumentError(
                    'ПРИБОР: не прочитать {}: {}'.format(src_path, e))
            scanned += 1
            if LIT in data and prefix not in data:
                data = data.replace(LIT, prefix)
            if os.path.isfile(dest):
                try:
                    old = open(dest, 'rb').read()
                except OSError:
                    old = None
                if old == data:
                    continue
            parent = os.path.dirname(dest)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(dest, 'wb') as fh:
                fh.write(data)
            updated += 1
    print('updated {} modules (scanned {})'.format(updated, scanned))
    return 0


def _split_stitch(text):
    bnd = re.compile(r'\n/\*__tweakcc_module_boundary_(\d+)__\*/\n')
    parts = bnd.split(text)
    if not parts:
        return []
    return [parts[0]] + [parts[i] for i in range(2, len(parts), 2)]


def update_from_stitch(tree, orig_path, new_path):
    """Записать в дерево только срезы сшивки, которые изменились."""
    if not os.path.isdir(tree):
        raise InstrumentError('ПРИБОР: нет дерева: {}'.format(tree))
    meta = read_meta(tree)
    prefix = meta.get('prefix', '')
    if not prefix:
        raise InstrumentError('ПРИБОР: в мета нет prefix ({})'.format(tree))
    try:
        orig = open(orig_path, encoding='utf-8').read()
        new = open(new_path, encoding='utf-8').read()
    except OSError as e:
        raise InstrumentError('ПРИБОР: сшивка не читается: {}'.format(e))
    except UnicodeDecodeError as e:
        raise InstrumentError('ПРИБОР: сшивка не UTF-8: {}'.format(e))
    o_slices = _split_stitch(orig)
    n_slices = _split_stitch(new)
    if len(o_slices) != len(n_slices):
        raise InstrumentError(
            'ПРИБОР: число модулей сшивки разошлось {} vs {}'.format(
                len(o_slices), len(n_slices)))
    files = []
    for dirpath, _dirnames, filenames in os.walk(tree, followlinks=False):
        for name in filenames:
            if name == '.tree-meta':
                continue
            files.append(os.path.join(dirpath, name))
    lit = '/$bunfs/root/'
    updated = 0
    for o, n in zip(o_slices, n_slices):
        if o == n:
            continue
        matched = None
        for path in files:
            try:
                data = open(path, encoding='utf-8').read()
            except (OSError, UnicodeDecodeError):
                continue
            unre = data.replace(prefix, lit)
            if unre == o:
                matched = path
                break
        if matched is None:
            raise InstrumentError(
                'ПРИБОР: изменённый модуль сшивки не найден в дереве')
        rewritten = n.replace(lit, prefix)
        with open(matched, 'w', encoding='utf-8') as fh:
            fh.write(rewritten)
        updated += 1
    print('updated {} modules from stitch'.format(updated))
    return 0


def emit_fixture(path, patched=False, with_literal=True):
    """Мини-образ, который parse_graph принимает. Не продукт, только зубы."""
    bc = _load_census()
    trailer = bc.TRAILER
    rec_size = bc.REC_SIZE
    chunk = b'// chunk-n93bke93\nexport {}\n'
    filler_a = b'// a.js\nexport {}\n'
    filler_b = b'// b.js\nexport {}\n'
    if with_literal:
        imprt = b'import "/$bunfs/root/chunk-n93bke93.js";\n'
    else:
        imprt = b'import "./chunk-n93bke93.js";\n'
    tweak = b'  console.log("4.3.3 (tweakcc)");\n' if patched else b''
    cli = (
        imprt
        + b'if (process.argv.includes("--version")) {\n'
        + b'  console.log("2.1.273 (Claude Code)");\n'
        + tweak
        + b'  process.exit(0);\n'
        + b'}\n'
        + b'console.log("fixture-cli");\n'
    )
    items = [
        (b'/$bunfs/root/cli', cli),
        (b'/$bunfs/root/chunk-n93bke93.js', chunk),
        (b'/$bunfs/root/a.js', filler_a),
        (b'/$bunfs/root/b.js', filler_b),
    ]
    stub = b'bun-v1.4.3\n'
    parts = [stub]
    pos = len(stub)
    records = []
    for name, contents in items:
        n_off, n_len = pos, len(name)
        parts.append(name)
        pos += n_len
        c_off, c_len = pos, len(contents)
        parts.append(contents)
        pos += c_len
        rec = bytearray(rec_size)
        struct.pack_into('<4I', rec, 0, n_off, n_len, c_off, c_len)
        records.append(bytes(rec))
    table_off = pos
    table = b''.join(records)
    parts.append(table)
    pos += len(table)
    modules_len = len(table)
    footer = struct.pack('<II', table_off, modules_len) + b'\0' * 16
    if len(footer) != 24:
        raise InstrumentError('ПРИБОР: внутренняя длина footer != 24')
    payload = b''.join(parts)
    if len(payload) != pos:
        raise InstrumentError('ПРИБОР: внутренняя длина payload разошлась')
    body = payload + footer + trailer
    data = struct.pack('<Q', len(body)) + body
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(data)
    # Round-trip through the same parser the extract path uses.
    _base, mods = parse_image(path)
    if len(mods) != 4:
        raise InstrumentError(
            'ПРИБОР: фикстура не разбирается как 4 модуля (получилось {})'.format(len(mods)))
    print('fixture {} bytes, patched={}, literal={} -> {}'.format(
        len(data), int(patched), int(with_literal), os.path.abspath(path)))
    return 0


def meta_get(tree, key):
    fields = read_meta(tree)
    if key not in fields:
        raise InstrumentError('ПРИБОР: в мета нет ключа {} ({})'.format(key, tree))
    sys.stdout.write(fields[key] + '\n')
    return 0


def _main(argv):
    ap = argparse.ArgumentParser(
        description='Extract bun virtual FS from a standalone image into a real tree.')
    sub = ap.add_subparsers(dest='cmd')

    p_ex = sub.add_parser('extract', help='extract image into tree and rewrite /$bunfs/root/')
    p_ex.add_argument('--image', required=True)
    p_ex.add_argument('--out', required=True)

    p_up = sub.add_parser('update', help='copy changed modules from --from into an existing tree')
    p_up.add_argument('--tree', required=True)
    p_up.add_argument('--from', dest='src', required=True)

    p_fx = sub.add_parser('emit-fixture', help='write a tiny parseable image for --self-check')
    p_fx.add_argument('--out', required=True)
    p_fx.add_argument('--patched', action='store_true')
    p_fx.add_argument('--no-literal', action='store_true')

    p_st = sub.add_parser('stub-version', help='print bun-v… of the image stub')
    p_st.add_argument('--image', required=True)

    p_mg = sub.add_parser('meta-get', help='print one .tree-meta field')
    p_mg.add_argument('--tree', required=True)
    p_mg.add_argument('--key', required=True)

    p_us = sub.add_parser(
        'update-from-stitch',
        help='write only changed stitch slices back into the tree')
    p_us.add_argument('--tree', required=True)
    p_us.add_argument('--orig', required=True)
    p_us.add_argument('--new', required=True)

    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_usage(sys.stderr)
        raise InstrumentError('ПРИБОР: нет команды')
    if args.cmd == 'extract':
        return extract(args.image, args.out)
    if args.cmd == 'update':
        return update(args.tree, args.src)
    if args.cmd == 'emit-fixture':
        return emit_fixture(args.out, patched=args.patched, with_literal=not args.no_literal)
    if args.cmd == 'stub-version':
        print(stub_version(args.image))
        return 0
    if args.cmd == 'meta-get':
        return meta_get(args.tree, args.key)
    if args.cmd == 'update-from-stitch':
        return update_from_stitch(args.tree, args.orig, args.new)
    raise InstrumentError('ПРИБОР: неизвестная команда {}'.format(args.cmd))


def main(argv=None):
    try:
        return _main(argv)
    except InstrumentError as e:
        sys.stderr.write(e.line + '\n')
        return 2


if __name__ == '__main__':
    sys.exit(main())
