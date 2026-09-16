#!/usr/bin/env python3
"""ЕДИНСТВЕННЫЙ дом правила «строка открывает питоновский heredoc».

До сведения домов одна и та же мысль жила отдельными редакциями в конвейере
и в стендах кита, и ошибка каждой молчала: тело, которого страж не увидел,
не проверяется никем и выглядит ровно как «проверено и в порядке». Правило
перенесено из стадии разбора блока проверок конвейера ДОСЛОВНО, вместе с
комментариями-констрейнтами; переписывать его текст запрещено -- форма
доказана мутациями. Зубы ниже держат форму до всякого обращения к дереву:
гейт, чей инструмент слеп, неотличим от гейта, который всё проверил.

Режимы:
  --self-check                зубы якоря на синтетике с известным ответом;
  --bodies <жертва> <каталог> тела питоньих heredoc'ов жертвы: файлы
                              body.<номер>.py в каталоге, число тел
                              печатается ОДНОЙ строкой в stdout --
                              дословный контракт прежней башовой функции
                              стендов кита.

Коды возврата:
  0 -- всё сошлось;
  1 -- зуб не держится (режим --self-check);
  2 -- прибор не может мерить: нет файла жертвы, не создаётся каталог тел,
       heredoc не закрыт, неизвестный режим.
"""
import io
import os
import re
import sys

# Якорь: строка ОТКРЫВАЕТ питоновский heredoc. Круг 28, F-13 держал этот
# признак закрытым списком ХВОСТОВ (конец строки плюс `; then|do|fi|else|done|
# esac`), и список молча отставал от кита: живые формы `python3 - "$p" <<'PY' &`,
# `out=$(python3 - "$c" 2>&1 <<'WRAP'`, `out=$(... <<'TAG' 2>&1` и гейт имён
# переменных `python3 - ... <<'SHVARS' || { ...; }` под него не подходили ВООБЩЕ
# -- ЧЕТЫРЕ питоновских тела не компилировал никто, и слепота выглядела ровно
# как исправность. Белый список хвостов ошибается МОЛЧА, поэтому он заменён на
# признак самого языка: открытие `<<'TAG'` стоит вне кавычек и вне комментария
# (только так отсекается упоминание `echo "python3 - <<'PY'"`), слово python3 --
# КОМАНДА своего сегмента (после ключевых слов и присваиваний окружения), между
# ними нет разделителя команд. Хвост после тега не разбирается: в bash он на
# открытие не влияет. Ошибка в обратную сторону -- ложное открытие -- краснеет
# ВСЛУХ («HEREDOC НЕ ЗАКРЫТ»), а не молча, и это единственное направление
# ошибки, допустимое для гейта.
heredoc_open = re.compile(r"<<'([A-Za-z_][A-Za-z0-9_]*)'")
shell_lead = ('if', '!', 'then', 'else', 'elif', 'do', 'while', 'until',
              'time', '{', '(')
shell_assign = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')


def _shell_cells(line):
    """Индексы символов строки ВНЕ кавычек и ДО начала комментария.

    Кавычки и решают, упоминание перед нами или команда, поэтому разбор идёт по
    символам: `#` внутри кавычек комментария не открывает, `'` внутри двойных
    кавычек строки не открывает, а `$(` восстанавливает НЕЗАКАВЫЧЕННЫЙ контекст
    внутри двойных -- без этого живая форма `BIN="$(python3 - <<'PY'` читалась
    бы как текст в кавычках.
    """
    cells, stack, quote, i, n = [], [], None, 0, len(line)
    while i < n:
        c = line[i]
        if quote in (None, '"') and c == '$' and i + 1 < n and line[i + 1] == '(':
            stack.append(quote)
            quote = None
            cells.extend((i, i + 1))
            i += 2
            continue
        if quote is None and c == ')' and stack:
            quote = stack.pop()
            cells.append(i)
            i += 1
            continue
        if quote is None:
            if c == '\\':
                i += 2
                continue
            if c in '"\'':
                quote = c
                i += 1
                continue
            if c == '#' and (i == 0 or line[i - 1] in ' \t;&|(<>'):
                break
            cells.append(i)
        elif quote == '"' and c == '\\':
            i += 2
            continue
        elif c == quote:
            quote = None
        i += 1
    return cells


def _words(text, base, cells):
    """Слова текста с их индексами; границей служит пробел ВНЕ кавычек."""
    out, i, n = [], 0, len(text)
    while i < n:
        while i < n and text[i] in ' \t' and base + i in cells:
            i += 1
        if i >= n:
            break
        start = i
        while i < n and not (text[i] in ' \t' and base + i in cells):
            i += 1
        out.append((start, i))
    return out


def _is_command_word(line, at, cells):
    """Слово с python3 на позиции at -- КОМАНДА своего сегмента.

    `cat > "$1/python3" <<'TAG'` -- питон тут не запускается, он ПИШЕТСЯ: тело
    heredoc'а башовое, и компиляция его как Python краснит гейт на исправном
    ките (измерено на волне pty: STUBPTY@4823 в corpus-tools-bench.sh). Правило
    «python3 в конце пути» для этого негодно: оно погасило бы и НАСТОЯЩИЙ вызов
    `/usr/bin/python3 - <<'PY'`, то есть закрыло бы гейту глаза на живое тело.
    Различает их позиция слова: у стаба команда -- `cat`, питон стоит аргументом
    редиректа. Тот же вопрос решают копии `python_heredoc_bodies` в стендах кита
    (corpus-tools-bench.sh, build-path-probe.sh, probes-sync-bench.sh) -- правилом
    грубее и в РАЗНЫХ редакциях (только первая отсеивает хвост пути), якоря
    мутации у них нет; сведение их к одному дому идёт отдельной задачей (#220).
    """
    start = 0
    for i in range(at):
        # `>|` и `>&` -- РЕДИРЕКТЫ, а не разделители: приняв их за границу
        # сегмента, гейт сделал бы цель редиректа «командой» и снова принял
        # башовый стаб `cat >| "$d/python3"` за вызов питона.
        if i in cells and line[i] in ';|&({`' and not (
                i and line[i - 1] in '<>' and line[i] in '|&'):
            start = i + 1
    for ws, we in _words(line[start:], start, cells):
        word = line[start + ws:start + we]
        if word in shell_lead or shell_assign.match(word):
            if start + ws <= at < start + we:
                return False    # python3 внутри присваивания -- не команда
            continue
        return start + ws <= at < start + we
    return False


def opener_match(line):
    """Открытие питоновского heredoc'а в строке, либо None."""
    cells = set(_shell_cells(line))
    for m in heredoc_open.finditer(line):
        if m.start() not in cells:
            continue            # упоминание внутри кавычек -- не открытие
        head = line[:m.start()]
        # ВСЕ вхождения, а не первое: строка `cat > "$d/python3" && python3 -
        # <<'PY'` несёт и имя файла, и вызов -- открытие принадлежит тому, до
        # которого от него нет разделителя команд.
        at = head.find("python3")
        while at >= 0:
            end = at + len("python3")
            edge = ((at == 0 or not (head[at - 1].isalnum() or head[at - 1] == '_'))
                    and (end >= len(head)
                         or not (head[end].isalnum() or head[end] == '_')))
            if edge and _is_command_word(line, at, cells) and not any(
                    head[k] in ';|' or (head[k] == '&' and head[k - 1] not in '<>')
                    for k in range(end, len(head)) if k in cells):
                return m
            at = head.find("python3", at + 1)
    return None

def self_check():
    """Зубы якоря: синтетика с известным ответом, ДО всякого дерева."""
    # ЗУБЫ НА ЯКОРЬ (круг 28, F-13). Сужение якоря -- например, возврат к «кончается
    # открытием без хвостов» -- снова оставило бы форму `; then` невидимой, и
    # никакой прогон этого не заметил бы: гейт, не видящий тела, выглядит ровно
    # как гейт, который его проверил. Синтетика с известным ответом краснит
    # такое сужение сама, ДО всякого обращения к дереву.
    for _line, _want in (
        ('if ! python3 - "$PIPELINE" "$mut" <<\'MUTX\'; then', True),
        ('  python3 - "$X" <<\'PY\'', True),
        ('BIN="$(python3 - <<\'PY\'', True),
        ('# пример: python3 - <<\'PY\' и текст', False),
        ('    # python3 - <<\'PY\' с отступом', False),
        # Комментарий обязан гаситься САМ, а не по счастью: скобка в прозе открыла
        # бы новый сегмент, и python3 стал бы в нём первым словом.
        ('# и тогда (python3 - <<\'PY\') упадёт', False),
        ('#python3 - <<\'PY\'', False),
        # Открытие принадлежит СЛЕДУЮЩЕЙ команде: разделитель стоит ДО тега.
        ('python3 -c pass; cat <<\'DATA\'', False),
        ('python3 -c pass & cat <<\'DATA\'', False),
        ('echo "python3 - <<\'PY\'"', False),
        ('grep -n "python3 - <<\'PY\'" kit.sh', False),
        # УПОМИНАНИЕ решают кавычки, а не хвост строки: `; echo done` открытие не
        # отменяет (тело начинается со следующей строки и кончается тегом), и
        # прежний отказ на этой форме был слепотой, а не строгостью.
        ('python3 - <<\'X\'; echo done', True),
        # Четыре живые формы кита, которых прежний якорь не видел ВООБЩЕ.
        ('python3 - "$(dirname "$0")" <<\'SHVARS\' || { echo "упал" >&2; exit 1; }', True),
        ('  out=$(python3 - "$carved" "$list" 0.0.900 "$h900" 2>&1 <<\'WRAP\'', True),
        ('  out=$(CPK="$K" CPH="$home" python3 - <<\'DLONLY40C\' 2>&1', True),
        ('  python3 - "$path" <<\'PY\' &', True),
        # `#` внутри кавычек комментария не открывает -- прежний якорь (`^[^#]*`)
        # на этой форме терял тело молча.
        ('python3 - "$d#tag" <<\'PY\'', True),
        # А вот python3 АРГУМЕНТОМ чужой команды тело не открывает: компилировать
        # башовый ввод grep как Python -- та же краснота на исправном ките.
        ('grep python3 "$f" <<\'DATA\'', False),
        # ИМЯ ФАЙЛА, не интерпретатор: цель редиректа. Форма измерена на волне pty.
        ('  cat > "$1/python3" <<\'STUBPTY\'', False),
        ('cat >> "$d/python3" <<\'T\'', False),
        # Пробел вокруг скобки НЕОБЯЗАТЕЛЕН -- эти три формы гейт раньше принимал
        # за вызов и кормил компилятор башовым телом (найдено аудитом 16.09).
        ('cat >"$d/python3" <<\'T\'', False),
        ('cat >>"$d/python3" <<\'T\'', False),
        ('cat >| "$d/python3" <<\'T\'', False),
        ('cat >|"$d/python3" <<\'T\'', False),
        # А вот ВЫЗОВ по абсолютному пути обязан остаться видимым: правило по форме
        # пути («хвост /python3») погасило бы эту строку вместе со стабом.
        ('/usr/bin/python3 - <<\'PY\'', True),
        ('"$VENV/bin/python3" - <<\'PY\'', True),
        # Смешанная строка: якорь жадный и цепляется за ПОСЛЕДНЕЕ вхождение, поэтому
        # запись файла рядом с вызовом не имеет права погасить тело heredoc'а.
        ('cat > "$d/python3" && python3 - <<\'PY\'', True),
    ):
        if bool(opener_match(_line)) is not _want:
            print("ЯКОРЬ HEREDOC ПОТЕРЯЛ ФОРМУ: ожидалось "
                  + ("принять" if _want else "отвергнуть") + f": {_line!r}")
            sys.exit(1)
    print("ЗУБЫ ЯКОРЯ HEREDOC'ОВ ДЕРЖАТ ФОРМУ")
    return 0


def bodies(victim, out_dir):
    """Тела питоньих heredoc'ов жертвы; каталог тел создаётся при нужде.

    Контракт тот же, что у прежней башовой функции стендов: тела пишутся
    файлами body.<номер>.py в порядке открытия, тело ПУСТОЕ, если между
    открытием и строкой-тегом ничего нет, а число тел печатается одной
    строкой. Незакрытый heredoc -- отказ прибора, а не молчаливый хвост
    файла: башовая форма съедала его до конца файла, и выглядело это
    ровно как «тел нет».
    """
    try:
        lines = io.open(victim, encoding='utf-8').read().split('\n')
    except (OSError, ValueError) as error:
        sys.stderr.write('heredoc-anchor: жертва не читается: %s: %s\n'
                         % (victim, error))
        return 2
    try:
        os.makedirs(out_dir, exist_ok=True)
    except OSError as error:
        sys.stderr.write('heredoc-anchor: каталог тел не создаётся: %s: %s\n'
                         % (out_dir, error))
        return 2
    count = 0
    i = 0
    while i < len(lines):
        m = opener_match(lines[i])
        if not m:
            i += 1
            continue
        tag = m.group(1)
        end = next((j for j in range(i + 1, len(lines))
                    if lines[j] == tag), -1)
        if end < 0:
            sys.stderr.write('heredoc-anchor: heredoc %s не закрыт '
                             '(строка-открытие номер %d файла %s)\n'
                             % (tag, i + 1, victim))
            return 2
        count += 1
        body = lines[i + 1:end]
        with io.open(os.path.join(out_dir, 'body.%d.py' % count), 'w',
                     encoding='utf-8') as fh:
            fh.write('\n'.join(body))
            if body:
                fh.write('\n')
        i = end + 1
    print(count)
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == '--self-check':
        return self_check()
    if len(argv) == 4 and argv[1] == '--bodies':
        return bodies(argv[2], argv[3])
    sys.stderr.write('heredoc-anchor: неизвестный режим: %r\n' % (argv[1:],))
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
