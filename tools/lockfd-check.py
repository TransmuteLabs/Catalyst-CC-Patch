#!/usr/bin/env python3
"""Гейт наследования замка (форма).

Замок кита живёт в дескрипторе (`exec 9>"$LOCK"`), а дети наследуют
дескрипторы: bash не ставит close-on-exec на перенаправление. Инструмент,
вызванный без `N>&-`, получает копию дескриптора, и его осиротевший ВНУК
держит замок за давно закончившийся прогон -- измерено дважды отказавшим
свипом (держатели по lsof: `probes-sync-s7.*/stub/cp`, `sleep 90` -- внуки
стенда, чей родитель ушёл). Починка -- единообразная: КАЖДЫЙ вызов
инструмента кита после открытия замка закрывает его дескриптор. Этот гейт
делает пропуск ВИДИМЫМ, чтобы дисциплина не держалась на памяти автора у
каждого нового вызова.

ГРАММАТИКА (изменение грамматики = изменение self-check случаев вместе с ней):

1. Сканируются `*.sh` корня кита, `tools/`, `scripts/`. Открытие замка:
   сегмент с командным словом `exec` и перенаправлением `N>` или `N>>`
   (N -- цифра), не `N>&...` и не `N<>...`. С этого места файла fd «открыт».
   Глобальное `exec N>&-` снимает требование до следующего открытия.
2. Логическая строка: текст до перевода строки ВНЕ кавычек; `\\`-перенос
   склеивает; `#`-комментарий (на границе слова, вне кавычек) отрезается;
   тела heredoc (`<<TAG` ... `TAG`) пропускаются целиком -- это данные.
3. Сегменты разделяются переводами логических строк, `&&`, `||`, `;`,
   `|`, `&` вне кавычек (`&` после `>`/`<` -- часть перенаправления).
   Подоболочки `( ... )` и группы `{ ...; }` образуют вложенные области,
   независимо от числа строк. Перенаправление `N>&-` на ЗАКРЫВАЮЩЕЙ
   границе применяется при входе в тело, включая вложенные области,
   но не к соседним командам. Повторное `exec N>` в теле открывает fd снова.
   Скобки присваивания `ИМЯ=( ... )`, раскрытия параметров и арифметики
   не являются границами подоболочки. Кавычки/экранирование сохраняются:
   текст `N>&-` внутри аргумента закрытием не считается.
4. Вызов инструмента кита: командное слово сегмента (после снятия
   присваиваний и обёртки `exec`/`env`/`command`/`builtin`) -- интерпретатор
   (python3|python|node|bash|sh|dash|zsh|perl), и среди аргументов есть
   путь `(tools|scripts)/<имя>.(py|js|sh)` или `claude-patch-all*.sh`.
   Исключения: форма с встроенным кодом (`-c`, `-e`, `-E`, `-`, `-m`,
   `-p`, `--eval`, `--print`) -- путь в ней ДАННЫЕ, а не исполняемый
   файл; `.` и `source` -- не порождение, а включение в этот же процесс.
   Отдельный объявленный слепой класс -- `perl` ЦЕЛИКОМ, в любой форме, а
   не только со встроенным кодом: в ките он встречается ТОЛЬКО встроенным
   кодом, а его слитные ключи (`-0ne`, `-0pi -e`) грамматикой ключей не
   разобраны, поэтому сегмент с `perl` пропускается, а не судится наугад.
   Присваивание `ИМЯ=( ... )` само не порождает процесс. Его содержимое
   проверяется тем же правилом интерпретатора/пути/встроенного кода.
   Сегмент с `${ИМЯ[@]}` или `${ИМЯ[*]}` (без кавычек либо в двойных)
   считается вызовом, если ранее массив нёс инструмент. Закрытие на
   присваивании не переносится на раскрытие. Учёт текстуальный: прежняя
   метка инструмента не стирается последующим присваиванием, поскольку
   оно может находиться в неисполненной ветке. Неизвестный массив на
   командной позиции и неразобранное содержимое с путём инструмента
   считаются неоднозначными вызовами, а не доказательством отсутствия вызова.
5. Требование: для КАЖДОГО открытого в этой точке fd есть отдельное
   закрытие на сегменте вызова либо на границе объемлющей области.
   Пропуск -- отказ с файлом и первой физической строкой сегмента;
   для массива -- со строкой раскрытия и строкой исходного присваивания.
   Неразобранная граница не даёт доказательства закрытия: тело проверяется
   без него. Незакрытое присваивание с инструментом также даёт отказ.
6. Строки-ДАННЫЕ (в таблицах `tools/corpus-tools-bench*.sh`: строка
   начинается с двух пробелов и одиночной кавычки) кодом не считаются --
   то же правило, что у переписи замков в tools/lock-probe.sh (утверждение
   9): иначе дословный текст открытия внутри строки массива читался бы как
   настоящее открытие.

Объявленные слепые классы (как heredoc'ы у гейта чисел -- объём измерим,
прозрачность обязательна): вызовы через переменные-пути (`bash "$PROBE_SH"`),
встроенный код (`-c`/`-e`), тела heredoc'ов, функции, ОПРЕДЕЛЁННЫЕ до
открытия замка и вызванные после (правило текстуальное, не потоковое).
Подстановки команд и скалярные командные переменные не вычисляются;
вычисление массива через eval/nameref/поэлементные записи не моделируется.
Эти ограничения действуют и при классификации содержимого массива;
неизвестное раскрытие массива на командной позиции даёт отказ по пункту 4,
а уже известная метка инструмента сохраняется консервативно.

Коды выхода (таблица кита):
  0  нарушений нет
  1  нарушение формы: вызов инструмента при открытом замке без `N>&-`
  2  прибор не может мерить: нет файлов, claude-patch-all.sh без `exec 9>`
  5  нечего мерить: ни одно открытие замка не найдено нигде
Режим `--self-check` гоняет синтетические файлы с известными ответами:
грамматика, чья собственная разметка не проверена, -- не прибор.
"""

from dataclasses import dataclass
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(HERE)

INTERPRETERS = {"python3", "python", "node", "bash", "sh", "perl", "dash", "zsh"}
INLINE_OPTS = {"-c", "-e", "-E", "-", "-m", "-p", "--eval", "--print"}
TOOL_PATH = re.compile(r"(?:tools|scripts)/[\w.+-]+\.(?:py|js|sh)\b|claude-patch-all[\w.-]*\.sh")
EXEC_OPEN = re.compile(r"^exec\s+(\d)>{1,2}(?![&=])")
EXEC_CLOSE = re.compile(r"^exec\s+(\d)>&-")
CLOSE_TOK = re.compile(r"(?<!\d)(\d)>&-")
HEREDOC = re.compile(r"<<(?!<)-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Строки-данные таблиц мутаций: только в corpus-tools-bench*.sh (см. пункт 6).
DATA_FILE = re.compile(r"^corpus-tools-bench.*\.sh$")
DATA_LINE = re.compile(r"^  '")


def strip_comments_split(lines):
    """Физические строки -> логические: (lineno, text). Кавычки трекаются,
    комментарии отрезаются, heredoc-тела пропускаются."""
    out = []
    i = 0
    cur = []
    cur_start = None
    sq = dq = False
    n = len(lines)
    while i < n:
        phys = lines[i]
        i += 1
        if cur_start is None:
            cur_start = i  # phys -- строка номер i (1-based, i уже инкрементирован)
        j = 0
        cont = False
        while j < len(phys):
            c = phys[j]
            if sq:
                cur.append(c)
                if c == "'":
                    sq = False
                j += 1
                continue
            if dq:
                cur.append(c)
                if c == "\\" and j + 1 < len(phys) and phys[j + 1] in '"\\$`':
                    cur.append(phys[j + 1])
                    j += 2
                    continue
                if c == '"':
                    dq = False
                j += 1
                continue
            # вне кавычек
            if c == "'":
                sq = True
                cur.append(c)
                j += 1
                continue
            if c == '"':
                dq = True
                cur.append(c)
                j += 1
                continue
            if c == "#" and (j == 0 or phys[j - 1] in " \t;&|()"):
                break  # комментарий до конца физической строки
            if c == "\\" and j == len(phys) - 1:
                cont = True  # перенос логической строки
                j += 1
                continue
            cur.append(c)
            j += 1
        cur.append("\n" if (sq or dq or cont) else " ")
        if sq or dq or cont:
            continue
        text = "".join(cur)
        cur = []
        lineno = cur_start
        cur_start = None
        out.append((lineno, text))
        # heredoc-маркеры этой логической строки: тела пропустить
        for tag in HEREDOC.findall(text):
            while i < n:
                body = lines[i]
                i += 1
                if body.strip("\t") == tag:
                    break
    if cur:
        out.append((cur_start or n, "".join(cur)))
    return out


@dataclass
class Token:
    kind: str
    text: str
    line: int


@dataclass
class Group:
    kind: str
    body: list
    suffix: list


ARRAY_ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\+?=$")
ARRAY_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\[[@*]\]\}")


def shell_tokens(logical):
    """Кавычки и раскрытия принадлежат слову, не структуре составной команды."""
    result = []
    for line, text in logical:
        i = 0
        while i < len(text):
            if text[i].isspace():
                line += text[i] == "\n"
                i += 1
                continue
            start = i
            token_line = line
            c = text[i]
            if c in "();|&" or (c in "{}" and
                    (i + 1 == len(text) or text[i + 1].isspace() or text[i + 1] in ";&|")):
                i += 1
                if text[start:i] in (";", "|", "&") and text[i:i + 1] == c:
                    i += 1
                result.append(Token("op", text[start:i], line))
                continue
            quote = None
            expansion = []
            while i < len(text):
                c = text[i]
                if c == "\\" and quote != "'":
                    line += text[i:i + 2].count("\n")
                    i += min(2, len(text) - i)
                    continue
                if quote:
                    if c == quote:
                        quote = None
                    line += c == "\n"
                    i += 1
                    continue
                if c in "'\"`":
                    quote = c
                    i += 1
                    continue
                if text[i:i + 2] in ("${", "$("):
                    expansion.append("}" if text[i + 1] == "{" else ")")
                    i += 2
                    continue
                if expansion:
                    if c == "(" and expansion[-1] == ")":
                        expansion.append(")")
                    elif c == expansion[-1]:
                        expansion.pop()
                    line += c == "\n"
                    i += 1
                    continue
                if c.isspace() or c in "();|" or (c == "&" and
                        (i == start or text[i - 1] not in "><")):
                    break
                i += 1
            result.append(Token("word", text[start:i], token_line))
        result.append(Token("op", "\n", line))
    return result


def command_tree(tokens):
    """Граница замыкается до обхода тела; незамкнутая область не даёт закрытий."""
    pos = 0

    def parse(end=None):
        nonlocal pos
        nodes, current, cases = [], [], []

        def flush():
            if current:
                nodes.append(current[:])
                current.clear()

        while pos < len(tokens):
            tok = tokens[pos]
            nxt = tokens[pos + 1] if pos + 1 < len(tokens) else None
            if tok.kind == "word" and ARRAY_ASSIGN.fullmatch(tok.text) and nxt and nxt.text == "(":
                begin = pos
                pos += 2
                depth = 1
                while pos < len(tokens) and depth:
                    part = tokens[pos]
                    if part.kind == "op":
                        depth += (part.text == "(") - (part.text == ")")
                    pos += 1
                value = " ".join(t.text for t in tokens[begin + 2:pos - (not depth)])
                current.append(Token("bad-array" if depth else "array", tok.text + "(" + value + ")", tok.line))
                continue
            if tok.kind == "word":
                if tok.text == "case" and (not current or current[-1].text in ("then", "do", "else")):
                    cases.append(False)
                elif tok.text == "in" and cases:
                    cases[-1] = True
                elif tok.text == "esac" and cases:
                    cases.pop()
                current.append(tok)
                pos += 1
                continue
            if cases and cases[-1] and tok.text in ("(", ")"):
                if tok.text == ")":
                    cases[-1] = False
                    flush()
                pos += 1
                continue
            if tok.text == end:
                flush()
                pos += 1
                suffix = []
                while pos < len(tokens) and tokens[pos].kind == "word":
                    suffix.append(tokens[pos])
                    pos += 1
                return nodes, suffix
            if tok.text == "(" and nxt and nxt.text == ")" and current:
                # Скобки объявления функции не создают подоболочку.
                pos += 2
                continue
            if tok.text in ("(", "{"):
                flush()
                pos += 1
                body, suffix = parse(")" if tok.text == "(" else "}")
                nodes.append(Group(tok.text, body, suffix))
                continue
            if tok.text == ";;" and cases:
                cases[-1] = True
            flush()
            pos += 1
        flush()
        return nodes, []

    return parse()[0]


def array_refs(text, with_lines=False):
    """Одиночные кавычки и экранированный доллар не раскрывают массив."""
    i = 0
    quote = None
    while i < len(text):
        c = text[i]
        if c == "\\" and quote != "'":
            i += 2
            continue
        if c == quote:
            quote = None
        elif c in "'\"" and quote is None:
            quote = c
        elif quote != "'":
            match = ARRAY_REF.match(text, i)
            if match:
                yield (match.group(1), text[:i].count("\n")) if with_lines else match.group(1)
                i = match.end()
                continue
        i += 1


def closed_fds(tokens):
    return {int(t.text[0]) for t in tokens
            if t.kind == "word" and CLOSE_TOK.fullmatch(t.text)}


def unquote(tok):
    return tok.strip("\"'")


def command_word(seg):
    """Командное слово после присваиваний и обёрток пункта 4."""
    toks = [t.text for t in shell_tokens([(1, seg)]) if t.kind == "word"]
    i = 0
    while i < len(toks):
        t = toks[i]
        if ASSIGN.match(unquote(t)):
            i += 1
            continue
        if t in ("exec", "command", "builtin"):
            i += 1
            continue
        if t == "env":
            i += 1
            while i < len(toks):
                t2 = toks[i]
                if t2 == "-u":
                    i += 2
                    continue
                if t2.startswith("-") or ASSIGN.match(unquote(t2)):
                    i += 1
                    continue
                break
            continue
        break
    return toks[i] if i < len(toks) else "", toks[i + 1:] if i < len(toks) else []


def tool_spawn(seg):
    """Сегмент порождает инструмент кита? (пункт 4 грамматики)"""
    word, args = command_word(seg)
    if unquote(word) not in INTERPRETERS:
        return False
    if unquote(word) == "perl":
        return False  # perl почти всегда -e; объявленный слепой класс
    for a in args:
        ua = unquote(a)
        if ua in INLINE_OPTS:
            return False
        if ua.startswith("-") and not ua.startswith("-u"):
            continue
        if TOOL_PATH.search(a):
            return True
    return False


def scan_file(path, is_data_file):
    """-> (violations, open_events). violations: [(lineno, fd, text)]"""
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    open_events = 0
    violations = []
    arrays = {}
    logical = [(line, value) for line, value in strip_comments_split(text.split("\n"))
               if not (is_data_file and DATA_LINE.match(value))]

    def walk(nodes, opens):
        nonlocal open_events
        for node in nodes:
            if isinstance(node, Group):
                local = opens - closed_fds(node.suffix)
                walk(node.body, local)
                if node.kind == "{":
                    # Перенаправления группы временные; exec без них остаётся в оболочке.
                    redirected = closed_fds(node.suffix)
                    opens.difference_update(opens - local - redirected)
                    opens.update(local - redirected)
                continue
            seg = " ".join(t.text for t in node)
            for token in node:
                if token.kind not in ("array", "bad-array"):
                    continue
                name, value = token.text.split("=", 1)
                name = name.rstrip("+")
                body = value[1:-1]
                word, args = command_word(body)
                inline = unquote(word) == "perl" or (
                    unquote(word) in INTERPRETERS and
                    any(unquote(a) in INLINE_OPTS for a in args))
                origins = arrays.setdefault(name, set())
                refs = list(array_refs(body))
                for ref in refs:
                    origins.update(arrays.get(ref, {token.line}))
                if tool_spawn(body) or (TOOL_PATH.search(body) and not inline):
                    origins.add(token.line)
                if token.kind == "bad-array" and origins:
                    for fd in sorted(opens):
                        violations.append((token.line, fd, f"не разобрано присваивание {name}, строка {token.line}"))
            commands = [t for t in node if t.kind == "word"]
            if not commands:
                continue
            s = " ".join(t.text for t in commands)
            m = EXEC_CLOSE.match(s)
            if m and commands[0].text == "exec":
                opens.difference_update(closed_fds(commands))
                continue
            m = EXEC_OPEN.match(s)
            if m and commands[0].text == "exec":
                opens.add(int(m.group(1)))
                open_events += 1
                continue
            word, _ = command_word(s)
            uses = []
            for token in commands:
                for name, offset in array_refs(token.text, with_lines=True):
                    origins = arrays.get(name)
                    if origins or (origins is None and name in set(array_refs(word))):
                        source = ",".join(map(str, sorted(origins))) if origins else "неизвестна"
                        line = token.line + offset
                        uses.append((line, f"массив {name}, присваивание: {source}; раскрытие: {line}"))
            if opens and (tool_spawn(s) or uses):
                lineno = uses[0][0] if uses else commands[0].line
                detail = "; ".join(u[1] for u in uses)
                snippet = (detail + ": " if detail else "") + seg[:120]
                for fd in sorted(opens - closed_fds(commands)):
                    violations.append((lineno, fd, snippet))

    walk(command_tree(shell_tokens(logical)), set())
    return violations, open_events


def scan_tree(root):
    files = sorted(
        glob.glob(os.path.join(root, "*.sh"))
        + glob.glob(os.path.join(root, "tools", "*.sh"))
        + glob.glob(os.path.join(root, "scripts", "*.sh"))
    )
    if not files:
        return None, "ни одного *.sh не найдено -- прибор смотрит не туда"
    all_v = []
    total_opens = 0
    pipeline_open = False
    for f in files:
        base = os.path.basename(f)
        v, n_open = scan_file(f, bool(DATA_FILE.match(base)))
        total_opens += n_open
        if base == "claude-patch-all.sh" and n_open > 0:
            pipeline_open = True
        for lineno, fd, snippet in v:
            all_v.append((os.path.relpath(f, root), lineno, fd, snippet))
    if total_opens == 0:
        return None, "ни одно открытие замка не найдено -- нечего мерить"
    if not pipeline_open and os.path.exists(os.path.join(root, "claude-patch-all.sh")):
        return None, "claude-patch-all.sh без `exec 9>` -- прибор смотрит не туда"
    return all_v, None


SELF_CASES = [
    # (имя, тело, нарушения [(lineno, fd)], необязательные фрагменты диагностик)
    ("open-then-bare-call",
     "exec 9>\"$L\"\nbash tools/x.sh\n",
     [(2, 9)]),
    ("open-then-closed-call",
     "exec 9>\"$L\"\nbash tools/x.sh 9>&-\n",
     []),
    ("global-close-frees",
     "exec 9>\"$L\"\nexec 9>&-\nbash tools/x.sh\n",
     []),
    ("call-before-open",
     "bash tools/x.sh\nexec 9>\"$L\"\n",
     []),
    ("continuation-line",
     "exec 9>\"$L\"\nenv -u A \\\n  bash tools/x.sh\n",
     [(2, 9)]),
    ("non-tool-commands",
     "exec 9>\"$L\"\ncurl -s http://x\nsed -i '' s/a/b/ f\n",
     []),
    ("tool-in-comment",
     "exec 9>\"$L\"\n# bash tools/x.sh\n",
     []),
    ("wrong-fd-closed",
     "exec 9>\"$L\"\nbash tools/x.sh 8>&-\n",
     [(2, 9)]),
    ("close-next-line-does-not-save",
     "exec 9>\"$L\"\nbash tools/x.sh\nsleep 1 9>&-\n",
     [(2, 9)]),
    ("scripts-path",
     "exec 7>\"$L\"\nbash scripts/y.sh\n",
     [(2, 7)]),
    ("heredoc-body-is-data",
     "exec 9>\"$L\"\ncat > f <<'EOF'\nexec 9>\"$Z\"\nbash tools/x.sh\nEOF\n",
     []),
    ("and-chain-first-bare",
     "exec 9>\"$L\"\nbash tools/x.sh && bash tools/y.sh 9>&-\n",
     [(2, 9)]),
    ("exec-inside-quotes-is-data",
     "exec 9>\"$L\"\nperl -e 'exec 9>\"z\"'\nbash tools/x.sh 9>&-\n",
     []),
    ("two-fds-both-required",
     "exec 9>\"$L\"\nexec 6>\"$M\"\nbash tools/x.sh 9>&-\n",
     [(3, 6)]),
    ("data-line-in-bench",
     None,  # особый случай: имя файла corpus-tools-bench.sh
     []),
    ("subshell-close-covers",
     "exec 9>\"$L\"\n( bash tools/x.sh ) 9>&- &\n",
     []),
    ("pipeline-self",
     "exec 9>\"$L\"\nbash \"$K/claude-patch-all.sh\"\n",
     [(2, 9)]),
    ("inline-code-is-data",
     "exec 9>\"$L\"\nbash -c 'echo tools/x.sh'\npython3 - tools/x.sh <<'P'\nP\n",
     []),
    ("append-open-counts",
     "exec 9>>\"$L\"\nbash tools/x.sh\n",
     [(2, 9)]),
    ("env-wrapped-closed",
     "exec 9>\"$L\"\nenv -u A -u B bash tools/x.sh 9>&- || {\n",
     []),
    ("multiline-subshell-closed",
     'exec 9>"$L"\n(\n bash tools/x.sh\n) 9>&- &\n', []),
    ("multiline-subshell-open",
     'exec 9>"$L"\n(\n bash tools/x.sh\n) &\n', [(3, 9)]),
    ("multiline-group-closed",
     'exec 9>"$L"\n{\n bash tools/x.sh;\n} 9>&-\n', []),
    ("multiline-group-open",
     'exec 9>"$L"\n{\n bash tools/x.sh;\n}\n', [(3, 9)]),
    ("nested-outer-close",
     'exec 9>"$L"\n(\n {\n  bash tools/x.sh\n }\n) 9>&-\n', []),
    ("nested-no-close",
     'exec 9>"$L"\n(\n {\n  bash tools/x.sh\n }\n)\n', [(4, 9)]),
    ("boundary-wrong-fd",
     'exec 9>"$L"\n(\n bash tools/x.sh\n) 8>&-\n', [(3, 9)]),
    ("boundary-two-fds",
     'exec 9>"$L"\nexec 8>"$M"\n(\n bash tools/x.sh\n) 8>&- 9>&-\n', []),
    ("boundary-does-not-cover-sibling",
     'exec 9>"$L"\n( bash tools/x.sh ) 9>&-; bash tools/y.sh\n', [(2, 9)]),
    ("inner-close-does-not-cover-outer",
     'exec 9>"$L"\n(\n ( bash tools/x.sh ) 9>&-\n bash tools/y.sh\n)\n', [(4, 9)]),
    ("multiple-body-segments",
     'exec 9>"$L"\n( bash tools/x.sh; bash tools/y.sh ) 9>&-\n', []),
    ("body-close-not-boundary",
     'exec 9>"$L"\n( bash tools/x.sh; bash tools/y.sh 9>&- )\n', [(2, 9)]),
    ("quoted-close-is-data",
     'exec 9>"$L"\n( bash tools/x.sh ) >"9>&-"\n', [(2, 9)]),
    ("subshell-global-close-is-local",
     'exec 9>"$L"\n( exec 9>&- )\nbash tools/x.sh\n', [(3, 9)]),
    ("boundary-reopened-in-body",
     'exec 9>"$L"\n(\n exec 9>"$M"\n bash tools/x.sh\n) 9>&-\n', [(4, 9)]),
    ("array-segment-close",
     'exec 9>"$L"\nA=(python3 tools/x.py)\n"${A[@]}" 9>&-\n', []),
    ("array-open",
     'exec 9>"$L"\nA=(python3 tools/x.py)\n"${A[@]}"\n', [(3, 9)],
     ['массив A, присваивание: 2; раскрытие: 3']),
    ("array-assignment-close-not-inherited",
     'exec 9>"$L"\nA=(python3 tools/x.py) 9>&-\n"${A[@]}"\n', [(3, 9)]),
    ("array-inline-code",
     'exec 9>"$L"\nA=(python3 -c "print(\'tools/x.py\')")\n"${A[@]}"\n', []),
    ("array-non-tool",
     'exec 9>"$L"\nA=(printf hello)\n"${A[@]}"\n', []),
    ("array-assignment-not-spawn",
     'exec 9>"$L"\nA=(python3\n tools/x.py)\n', []),
    ("array-before-open",
     'A=(python3 tools/x.py)\nexec 9>"$L"\n${A[@]}\n', [(3, 9)]),
    ("array-star-open",
     'exec 9>"$L"\nA=(bash tools/x.sh)\n"${A[*]}"\n', [(3, 9)]),
    ("array-star-closed",
     'exec 9>"$L"\nA=(bash tools/x.sh)\n"${A[*]}" 9>&-\n', []),
    ("array-unquoted-closed",
     'exec 9>"$L"\nA=(bash tools/x.sh)\n${A[@]} 9>&-\n', []),
    ("array-exec-env-boundary",
     'exec 9>"$L"\nA=(python3\n tools/x.py --cols "${SIZE[0]}")\n(\n exec env X=1 "${A[@]}"\n) 9>&- &\n', []),
    ("array-exec-env-open",
     'exec 9>"$L"\nA=(python3\n tools/x.py --cols "${SIZE[0]}")\n(\n exec env X=1 "${A[@]}"\n) &\n', [(5, 9)],
     ['массив A, присваивание: 2; раскрытие: 5']),
    ("array-single-quoted-is-data",
     'exec 9>"$L"\nA=(bash tools/x.sh)\nprintf \'${A[@]}\'\n', []),
    ("array-escaped-is-data",
     'exec 9>"$L"\nA=(bash tools/x.sh)\nprintf "\\${A[@]}"\n', []),
    ("array-copy-open",
     'exec 9>"$L"\nA=(bash tools/x.sh)\nB=("${A[@]}")\n"${B[@]}"\n', [(4, 9)]),
    ("array-reassignment-conservative",
     'exec 9>"$L"\nA=(bash tools/x.sh)\nA=(printf hello)\n"${A[@]}"\n', [(4, 9)]),
    ("array-unknown-command-open",
     'exec 9>"$L"\n"${UNKNOWN[@]}"\n', [(2, 9)]),
    ("array-unknown-command-closed",
     'exec 9>"$L"\n"${UNKNOWN[@]}" 9>&-\n', []),
    ("array-ambiguous-path-open",
     'exec 9>"$L"\nA=("$RUNNER" tools/x.py)\n"${A[@]}"\n', [(3, 9)]),
    ("array-unclosed-refused",
     'exec 9>"$L"\nA=(python3 tools/x.py\n', [(2, 9)]),
    ("case-pattern-not-subshell-boundary",
     'exec 9>"$L"\n(\n case "$x" in\n x) bash tools/x.sh;;\n esac\n) 9>&-\n', []),
    ("case-pattern-open",
     'exec 9>"$L"\n(\n case "$x" in\n x) bash tools/x.sh;;\n esac\n)\n', [(4, 9)]),
    ("exec-direct-open",
     'exec 9>"$L"\nexec bash tools/x.sh\n', [(2, 9)]),
    ("exec-direct-closed",
     'exec 9>"$L"\nexec bash tools/x.sh 9>&-\n', []),
    ("array-continuation-expansion-line",
     'exec 9>"$L"\nA=(python3 tools/x.py)\nexec env X=1 \\\n "${A[@]}"\n', [(4, 9)],
     ['массив A, присваивание: 2; раскрытие: 4']),
    ("array-continuation-expansion-closed",
     'exec 9>"$L"\nA=(python3 tools/x.py)\nexec env X=1 \\\n "${A[@]}" 9>&-\n', []),
    ("array-multiline-word-expansion-line",
     'exec 9>"$L"\nA=(python3 tools/x.py)\nprintf "prefix\n${A[@]}"\n', [(4, 9)],
     ['массив A, присваивание: 2; раскрытие: 4']),
    ("group-global-close-persists",
     'exec 9>"$L"\n{ exec 9>&-; }\nbash tools/x.sh\n', []),
    ("group-boundary-close-temporary",
     'exec 9>"$L"\n{ bash tools/x.sh; } 9>&-\nbash tools/y.sh\n', [(3, 9)]),
]


def self_check():
    root = tempfile.mkdtemp(prefix="lockfd-self.")
    fails = 0
    try:
        for case in SELF_CASES:
            name, body, want = case[:3]
            fname = "case.sh"
            if name == "data-line-in-bench":
                # Правило данных привязано к ИМЕНИ файла: кладём в подкаталог
                # под настоящим именем, иначе случай мерял бы не своё.
                os.makedirs(os.path.join(root, name), exist_ok=True)
                fname = os.path.join(name, "corpus-tools-bench.sh")
                body = "exec 9>\"$L\"\n  'bash tools/x.sh -- exec 9>\"$Z\"'\n"
            path = (os.path.join(root, fname) if os.path.sep in fname
                    else os.path.join(root, name + "-" + fname))
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(body)
            got, _opens = scan_file(path, bool(DATA_FILE.match(os.path.basename(path))))
            if len(case) == 4:
                details = [snippet for _ln, _fd, snippet in got]
                if len(details) != len(case[3]) or any(
                        expected not in actual for expected, actual in zip(case[3], details)):
                    fails += 1
                    print(f"self-check: FAIL {name}: диагностика {details}, ожидалось {case[3]}", file=sys.stderr)
            got = [(ln, fd) for ln, fd, _s in got]
            if got != list(want):
                fails += 1
                print(f"self-check: FAIL {name}: ожидалось {list(want)}, получено {got}", file=sys.stderr)
        # позитивный контроль прибора: без нарушений self-check обязан молчать,
        # а с посаженным -- краснеть; выше это и замерено. Отдельно: пустой
        # файл не даёт ни открытий, ни нарушений и не путает разметку.
        empty = os.path.join(root, "empty.sh")
        open(empty, "w").close()
        got, _opens = scan_file(empty, False)
        if got:
            fails += 1
            print(f"self-check: FAIL empty: {got}", file=sys.stderr)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    if fails:
        print(f"lockfd-check --self-check: ПРОВАЛ -- {fails} случаев разметки не сошлись", file=sys.stderr)
        return 1
    print(f"lockfd-check --self-check: все {len(SELF_CASES) + 1} случаев грамматики сошлись с известными ответами")
    return 0


def main():
    if "--self-check" in sys.argv[1:]:
        return self_check()
    violations, why = scan_tree(KIT)
    if why:
        code = 5 if "нечего мерить" in why else 2
        print(f"lockfd-check: ОТКАЗ -- {why}", file=sys.stderr)
        return code
    if violations:
        print("lockfd-check: ОТКАЗ -- вызов инструмента кита при открытом замке без N>&-:", file=sys.stderr)
        for rel, lineno, fd, snippet in violations:
            print(f"  {rel}:{lineno}: fd {fd} не закрыт: {snippet}", file=sys.stderr)
        return 1
    print("lockfd-check: каждый вызов инструмента кита после открытия замка закрывает его дескриптор")
    return 0


if __name__ == "__main__":
    sys.exit(main())
