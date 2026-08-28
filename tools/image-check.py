#!/usr/bin/env python3
"""Признать файл ЦЕЛЫМ образом Claude Code — или отказать, назвав причину.

Зачем отдельный прибор. Авто-детект по PATH задаёт образу два вопроса
(магия нативного образа; содержит ли он `@anthropic-ai/claude-code`), а ветка
`--target` не задавала НИ ОДНОГО: файл существует — значит цель. При этом
шапка самого конвейера советует человеку путь `<версия>.staging`, а такой
файл остаётся на диске ровно после ОБОРВАННОЙ загрузки. Оборванный образ
проходит обе проверки авто-детекта (магия в первых четырёх байтах цела,
маркер продукта лежит задолго до конца файла) и падает потом внутри
распаковщика сообщением про сломанный бандл — то есть про следствие, а не
про причину.

Поэтому здесь три вопроса, а не два:
  1) магия — Mach-O (тонкий, обе разрядности и порядок байт), Mach-O fat, ELF;
  2) принадлежность продукту — вхождение `@anthropic-ai/claude-code`;
  3) ПОЛНОТА — заголовки образа сами объявляют, где заканчиваются его части;
     файл, который короче объявленного, оборван, и это видно ДО распаковки.

Третий вопрос — не теоретический: он и есть тот случай, ради которого прибор
написан. Проверяются те части, которые лежат в хвосте файла и потому первыми
теряются при обрыве: у Mach-O — сегменты, таблица символов и блок подписи; у
fat — каждый срез; у ELF — таблица секций.

Коды выхода (подмножество общей таблицы кита — см. шапку claude-patch-all.sh):
  0  образ целый
  1  отказ с названной причиной на stderr: магия, принадлежность, полнота
  2  контракт вызова нарушен: не ровно один аргумент (прибор не мерил ничего)
Объявление «0 или 1» было уже факта: код 2 существовал и склеивался
вызывающим с отказом об образе (раунд 18, F-1).
"""
import os
import struct
import sys

MAGIC_THIN = {
    b'\xcf\xfa\xed\xfe': ('<', 64),   # MH_MAGIC_64, little-endian
    b'\xce\xfa\xed\xfe': ('<', 32),   # MH_MAGIC,    little-endian
    b'\xfe\xed\xfa\xcf': ('>', 64),   # MH_CIGAM_64, big-endian
    b'\xfe\xed\xfa\xce': ('>', 32),   # MH_CIGAM,    big-endian
}
MAGIC_FAT = (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')  # 32- и 64-битный fat
MAGIC_ELF = b'\x7fELF'

LC_SEGMENT, LC_SYMTAB, LC_SEGMENT_64, LC_CODE_SIGNATURE = 0x01, 0x02, 0x19, 0x1d

PRODUCT = b'@anthropic-ai/claude-code'


def contains(path, marker):
    # Потоково, с перехлёстом: маркер может лечь на границу блоков, и наивный
    # поиск внутри блока промахнулся бы на одних сборках и сработал на других.
    overlap = len(marker) - 1
    tail = b''
    with open(path, 'rb') as fh:
        while chunk := fh.read(8 << 20):
            if marker in tail + chunk:
                return True
            tail = chunk[-overlap:] if overlap else b''
    return False


def macho_end(fh, base, size):
    """Наибольшее смещение конца, объявленное заголовками одного среза Mach-O.

    Возвращает (конец, число_разобранных_команд) или (None, причина).
    """
    fh.seek(base)
    magic = fh.read(4)
    if magic not in MAGIC_THIN:
        return None, 'срез по смещению %d не Mach-O' % base
    endian, bits = MAGIC_THIN[magic]
    # После магии в заголовке лежат cputype, cpusubtype, filetype, ncmds,
    # sizeofcmds, flags (шесть 4-байтовых полей), а у 64-битного варианта ещё
    # поле reserved. Читаем ровно столько, сколько объявляет разрядность.
    want = 28 if bits == 64 else 24
    hdr = fh.read(want)
    if len(hdr) < want:
        return None, 'заголовок Mach-O обрывается'
    _cputype, _cpusub, _ftype, ncmds, sizeofcmds, _flags = struct.unpack(
        endian + '6i', hdr[:24])
    if ncmds < 0 or sizeofcmds < 0:
        return None, 'заголовок Mach-O объявляет ncmds=%d sizeofcmds=%d' % (ncmds, sizeofcmds)
    end = base + (32 if bits == 64 else 28) + sizeofcmds
    if end > size:
        return None, 'таблица команд загрузки обрывается (объявлено %d, файл %d)' % (end, size)
    off = base + (32 if bits == 64 else 28)
    for _ in range(ncmds):
        fh.seek(off)
        head = fh.read(8)
        if len(head) < 8:
            return None, 'команда загрузки обрывается'
        cmd, cmdsize = struct.unpack(endian + '2I', head)
        if cmdsize < 8:
            return None, 'команда загрузки объявляет размер %d' % cmdsize
        body = fh.read(cmdsize - 8)
        if cmd in (LC_SEGMENT, LC_SEGMENT_64):
            wide = cmd == LC_SEGMENT_64
            need = 16 + (32 if wide else 16)
            if len(body) >= need:
                vals = struct.unpack(endian + ('4Q' if wide else '4I'), body[16:16 + (32 if wide else 16)])
                fileoff, filesize = vals[2], vals[3]
                end = max(end, base + fileoff + filesize)
        elif cmd == LC_SYMTAB and len(body) >= 16:
            _symoff, _nsyms, stroff, strsize = struct.unpack(endian + '4I', body[:16])
            end = max(end, base + stroff + strsize)
        elif cmd == LC_CODE_SIGNATURE and len(body) >= 8:
            dataoff, datasize = struct.unpack(endian + '2I', body[:8])
            end = max(end, base + dataoff + datasize)
        off += cmdsize
    return end, None


def declared_end(path, size):
    """(конец, причина-отказа). Конец = сколько байт объявляет сам образ."""
    with open(path, 'rb') as fh:
        head = fh.read(4)
        if head in MAGIC_THIN:
            return macho_end(fh, 0, size)
        if head in MAGIC_FAT:
            wide = head == b'\xca\xfe\xba\xbf'
            nraw = fh.read(4)
            if len(nraw) < 4:
                return None, 'заголовок fat обрывается'
            (narch,) = struct.unpack('>I', nraw)
            if narch > 64:
                return None, 'заголовок fat объявляет %d срезов' % narch
            end = 8 + narch * (32 if wide else 20)
            for i in range(narch):
                fh.seek(8 + i * (32 if wide else 20))
                rec = fh.read(32 if wide else 20)
                if len(rec) < (32 if wide else 20):
                    return None, 'запись среза fat обрывается'
                if wide:
                    _ct, _cs, off, sz, _al, _rs = struct.unpack('>2i2Q2I', rec[:32])
                else:
                    _ct, _cs, off, sz, _al = struct.unpack('>5I', rec[:20])
                end = max(end, off + sz)
            return end, None
        if head == MAGIC_ELF:
            fh.seek(0)
            ident = fh.read(16)
            if len(ident) < 16:
                return None, 'заголовок ELF обрывается'
            wide = ident[4] == 2
            endian = '<' if ident[5] == 1 else '>'
            fh.seek(16)
            rest = fh.read(48 if wide else 36)
            if len(rest) < (48 if wide else 36):
                return None, 'заголовок ELF обрывается'
            if wide:
                _t, _m, _v, _entry, _phoff, shoff = struct.unpack(endian + '2HI3Q', rest[:32])
                shentsize, shnum = struct.unpack(endian + '2H', rest[42:46])
            else:
                _t, _m, _v, _entry, _phoff, shoff = struct.unpack(endian + '2HI3I', rest[:20])
                shentsize, shnum = struct.unpack(endian + '2H', rest[30:34])
            return max(shoff + shnum * shentsize, 0), None
    return None, 'первые байты не похожи ни на Mach-O, ни на fat, ни на ELF'


def main():
    if len(sys.argv) != 2:
        sys.stderr.write('usage: image-check.py <path>\n')
        return 2
    path = sys.argv[1]
    try:
        size = os.path.getsize(path)
    except OSError as exc:
        sys.stderr.write('ОТКАЗ: %s не читается (%s)\n' % (path, exc))
        return 1
    try:
        head = open(path, 'rb').read(4)
    except OSError as exc:
        sys.stderr.write('ОТКАЗ: %s не читается (%s)\n' % (path, exc))
        return 1
    if not (head in MAGIC_THIN or head in MAGIC_FAT or head == MAGIC_ELF):
        what = 'шелл-скрипт' if head.startswith(b'#!') else 'не нативный образ'
        sys.stderr.write('ОТКАЗ: %s -- %s\n' % (path, what))
        return 1
    if not contains(path, PRODUCT):
        sys.stderr.write(
            'ОТКАЗ: %s -- нативный образ, но не Claude Code\n'
            '  (в файле нет строки %s)\n' % (path, PRODUCT.decode()))
        return 1
    end, why = declared_end(path, size)
    if end is None:
        sys.stderr.write('ОТКАЗ: %s -- %s\n' % (path, why))
        return 1
    if end > size:
        sys.stderr.write(
            'ОТКАЗ: %s ОБОРВАН -- заголовки объявляют %d байт, на диске %d '
            '(не хватает %d).\n'
            '  Так выглядит файл, оставшийся от прерванной загрузки: имя\n'
            '  <версия>.staging рядом с установленной версией. Магия и маркер\n'
            '  продукта в нём целы, поэтому проверка "это Claude Code" его\n'
            '  пропускает, а распаковщик падает позже и жалуется на бандл.\n'
            '  Возьмите штатные байты: python3 claude_patch.py --download-only <версия>\n'
            % (path, end, size, end - size))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
