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
3. Логическая строка режется на сегменты по `&&`, `||`, `;`, `|`, `&`
   (вне кавычек; `&` после `>` или `<` -- перенаправление, не оператор).
   Скобки подоболочек сегмент не режут: `( ... ) 9>&- &` -- один сегмент,
   и закрытие на закрывающей скобке действует на всё внутри.
4. Вызов инструмента кита: командное слово сегмента (после снятия
   присваиваний и обёртки `env`/`command`) -- интерпретатор
   (python3|python|node|bash|sh|dash|zsh|perl), и среди аргументов есть
   путь `(tools|scripts)/<имя>.(py|js|sh)` или `claude-patch-all*.sh`.
   Исключения: форма с встроенным кодом (`-c`, `-e`, `-E`, `-`, `-m`,
   `-p`, `--eval`, `--print`) -- путь в ней ДАННЫЕ, а не исполняемый
   файл; `.` и `source` -- не порождение, а включение в этот же процесс.
   Отдельный объявленный слепой класс -- `perl` ЦЕЛИКОМ, в любой форме, а
   не только со встроенным кодом: в ките он встречается ТОЛЬКО встроенным
   кодом, а его слитные ключи (`-0ne`, `-0pi -e`) грамматикой ключей не
   разобраны, поэтому сегмент с `perl` пропускается, а не судится наугад.
5. Требование: на сегменте вызова инструмента присутствует токен `N>&-`
   для КАЖДОГО открытого в этой точке файла fd. Пропуск -- отказ с
   файлом и номером ПЕРВОЙ физической строки логической строки.
6. Строки-ДАННЫЕ (в таблицах `tools/corpus-tools-bench*.sh`: строка
   начинается с двух пробелов и одиночной кавычки) кодом не считаются --
   то же правило, что у переписи замков в tools/lock-probe.sh (утверждение
   9): иначе дословный текст открытия внутри строки массива читался бы как
   настоящее открытие.

Объявленные слепые классы (как heredoc'ы у гейта чисел -- объём измерим,
прозрачность обязательна): вызовы через переменные-пути (`bash "$PROBE_SH"`),
встроенный код (`-c`/`-e`), тела heredoc'ов, функции, ОПРЕДЕЛЁННЫЕ до
открытия замка и вызванные после (правило текстуальное, не потоковое).

Коды выхода (таблица кита):
  0  нарушений нет
  1  нарушение формы: вызов инструмента при открытом замке без `N>&-`
  2  прибор не может мерить: нет файлов, claude-patch-all.sh без `exec 9>`
  5  нечего мерить: ни одно открытие замка не найдено нигде
Режим `--self-check` гоняет синтетические файлы с известными ответами:
грамматика, чья собственная разметка не проверена, -- не прибор.
"""

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
        cur.append("\n" if (sq or dq) else " ")
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


def segments(text):
    """Логическая строка -> сегменты по операторам (вне кавычек)."""
    segs = []
    cur = []
    sq = dq = False
    i = 0
    while i < len(text):
        c = text[i]
        if sq:
            cur.append(c)
            if c == "'":
                sq = False
            i += 1
            continue
        if dq:
            cur.append(c)
            if c == "\\" and i + 1 < len(text):
                cur.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                dq = False
            i += 1
            continue
        if c == "'":
            sq = True
            cur.append(c)
            i += 1
            continue
        if c == '"':
            dq = True
            cur.append(c)
            i += 1
            continue
        two = text[i:i + 2]
        if two in ("&&", "||"):
            segs.append("".join(cur))
            cur = []
            i += 2
            continue
        if c == ";":
            segs.append("".join(cur))
            cur = []
            i += 1
            continue
        if c == "|":
            segs.append("".join(cur))
            cur = []
            i += 1
            continue
        if c == "&" and (i == 0 or text[i - 1] not in "><"):
            segs.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    if cur:
        segs.append("".join(cur))
    return segs


def unquote(tok):
    return tok.strip("\"'")


def command_word(seg):
    """Командное слово сегмента после снятия '(' , присваиваний, env/command."""
    toks = seg.replace("(", " ").replace(")", " ) ").split()
    toks = [t for t in toks if t != ")"]
    i = 0
    while i < len(toks):
        t = toks[i]
        if ASSIGN.match(unquote(t)):
            i += 1
            continue
        if t == "command" or t == "builtin":
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
    opens = set()
    open_events = 0
    violations = []
    for lineno, ltext in strip_comments_split(text.split("\n")):
        if is_data_file and DATA_LINE.match(ltext):
            continue
        for seg in segments(ltext):
            s = seg.strip()
            if not s:
                continue
            word, _ = command_word(seg)
            if word == "exec":
                m = EXEC_CLOSE.match(s)
                if m:
                    opens.discard(int(m.group(1)))
                    continue
                m = EXEC_OPEN.match(s)
                if m:
                    opens.add(int(m.group(1)))
                    open_events += 1
                    continue
                continue
            if opens and tool_spawn(seg):
                closed = {int(x) for x in CLOSE_TOK.findall(seg)}
                for fd in sorted(opens):
                    if fd not in closed:
                        violations.append((lineno, fd, s[:120]))
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
    # (имя, тело, ожидаемые нарушения [(lineno, fd)])
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
]


def self_check():
    root = tempfile.mkdtemp(prefix="lockfd-self.")
    fails = 0
    try:
        for name, body, want in SELF_CASES:
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
