#!/usr/bin/env bash
# Гвард герметичности стенда: набор ручек выводится ИЗ ПРЕДМЕТА в момент
# прогона; неклассифицированная ручка -- отказ. Список ручек устаревает
# с правкой предмета и его неполнота невидима прибору -- поэтому не список.
#
# CONSTRAINT: подоболочка; окружение вызывающего не меняет и в ФС не пишет.
# CONSTRAINT: имя, попавшее и в чтения, и в --pinned -- корзина 1 (запинено).
# CONSTRAINT: --declared-machine -- ОТДЕЛЬНАЯ корзина: предмет читает ручку,
# а стенд ОБЪЯВЛЕННО пропускает значение машины. Тот же --pinned лгал бы
# о владельце значения. Одно имя в обеих ролях -- противоречие декларации,
# код 2.
# CONSTRAINT: --pinned/--declared-machine имя, которого предмет не читает --
# не ошибка: число «лишних пинов» в сводке (опечатка в пине ловится с другой
# стороны -- настоящая ручка падает в «унаследовано» и даёт код 3).
# Пустое/невыставленное --pinned имя из чтений -- код 4; пустое
# --declared-machine -- не отказ, но называется в сводке.
# CONSTRAINT: ПУСТО ≠ НОЛЬ: ноль чтений -- код 5, законный ноль только с
# --allow-zero.
# CONSTRAINT: поимённый список печатается ТОЛЬКО при отказе. Гвард зовут
# десятки раз за прогон (110 вызовов в probes-sync-bench), и поимённая
# печать на зелёном давала 770 строк (7 запиненных имён x 110) -- улику
# отказа в них не видно.
set -u
exec python3 - "$@" <<'PY'
import os, re, sys

SVC = set(
    "BASH_SOURCE BASHPID PPID RANDOM LINENO FUNCNAME PIPESTATUS "
    "IFS OLDPWD PWD SHLVL _".split()
)
NAME = r"[A-Za-z_][A-Za-z0-9_]*"
FORMS = [
    re.compile(r"\$\{(" + NAME + r")\:-"),
    re.compile(r"\$\{(" + NAME + r")\}"),
    re.compile(r"\$(" + NAME + r")"),
    re.compile(r"os\.environ\.get\(\"(" + NAME + r")\""),
    re.compile(r"os\.environ\[\"(" + NAME + r")\"\]"),
    re.compile(r"os\.getenv\(\"(" + NAME + r")\""),
    re.compile(r"process\.env\.(" + NAME + r")"),
    re.compile(r"process\.env\[\"(" + NAME + r")\"\]"),
]
ASSIGN = re.compile(r"^[ \t]*(?:local[ \t]+|export[ \t]+)?(" + NAME + r")=")


def die_usage(extra=""):
    if extra:
        sys.stderr.write("stand-env-guard: %s\n" % extra)
    sys.stderr.write(
        "stand-env-guard: вызов: --subject <файл> [--subject <файл> ...] "
        "[--pinned <ИМЯ> ...] [--declared-machine <ИМЯ> ...] "
        "[--label <строка>] [--allow-zero]\n"
    )
    sys.exit(2)


def parse_args(argv):
    subjects, pinned, machine, label, allow_zero = [], [], [], "", False
    i = 1  # argv[0] is "-"
    while i < len(argv):
        a = argv[i]
        if a == "--subject":
            if i + 1 >= len(argv):
                die_usage()
            subjects.append(argv[i + 1]); i += 2
        elif a == "--pinned":
            if i + 1 >= len(argv):
                die_usage()
            pinned.append(argv[i + 1]); i += 2
        elif a == "--declared-machine":
            if i + 1 >= len(argv):
                die_usage()
            machine.append(argv[i + 1]); i += 2
        elif a == "--label":
            if i + 1 >= len(argv):
                die_usage()
            label = argv[i + 1]; i += 2
        elif a == "--allow-zero":
            allow_zero = True; i += 1
        else:
            die_usage()
    return subjects, pinned, machine, label, allow_zero


def extract_file(path):
    try:
        text = open(path, "r", encoding="utf-8", errors="replace").read()
    except OSError:
        sys.stderr.write(
            "stand-env-guard: не удалось прочитать --subject %s\n" % path
        )
        sys.exit(2)
    first_read = {}
    first_assign = {}
    for n, line in enumerate(text.splitlines(), 1):
        m = ASSIGN.match(line)
        if m and m.group(1) not in first_assign:
            first_assign[m.group(1)] = n
        found = set()
        for rx in FORMS:
            found.update(rx.findall(line))
        for name in found:
            if name not in first_read:
                first_read[name] = n
    kept = set()
    for name, rline in first_read.items():
        if name in SVC:
            continue
        a = first_assign.get(name)
        # <= : зуб 6 -- присвоение ДО чтения на той же строке отсеивает.
        if a is not None and a <= rline:
            continue
        kept.add(name)
    return kept


def present(name):
    return name in os.environ


def nonempty(name):
    return present(name) and os.environ.get(name, "") != ""


def dedup(seq):
    out, seen = [], set()
    for n in seq:
        if n not in seen:
            out.append(n)
            seen.add(n)
    return out


def main():
    subjects, pinned_list, machine_list, label, allow_zero = parse_args(sys.argv)
    if not subjects:
        die_usage()
    pinned = dedup(pinned_list)
    machine = dedup(machine_list)
    both = [n for n in pinned if n in set(machine)]
    if both:
        die_usage(
            "имя объявлено и --pinned, и --declared-machine -- владелец "
            "значения назван дважды: %s" % " ".join(both)
        )
    pinned_set = set(pinned)
    machine_set = set(machine)

    reads = set()
    for s in subjects:
        if not os.path.isfile(s):
            sys.stderr.write(
                "stand-env-guard: не удалось прочитать --subject %s\n" % s
            )
            sys.exit(2)
        reads |= extract_file(s)

    extra = [n for n in pinned + machine if n not in reads]
    basket1, basket1m, basket2, basket3 = [], [], [], []
    missing_pins = []
    for name in sorted(reads):
        if name in pinned_set:
            basket1.append(name)
            if not nonempty(name):
                missing_pins.append(name)
        elif name in machine_set:
            basket1m.append(name)
        elif present(name):
            basket2.append(name)
        else:
            basket3.append(name)
    N = len(reads)
    P = len(basket1)
    M = len(basket1m)
    U = len(basket2)
    C = len(basket3)
    K = len(extra)

    # Объявленно-машинные называются ВСЕГДА, даже на зелёном: предел,
    # о котором молчат, неотличим от предела, которого не было.
    def machine_names():
        if not basket1m:
            return ""
        parts = []
        for n in basket1m:
            parts.append(n if nonempty(n) else "%s(не выставлена)" % n)
        return " (%s)" % " ".join(parts)

    def extra_names():
        return " (%s)" % " ".join(extra) if extra else ""

    tag = "stand-env-guard[%s]:" % label
    counts = (
        "читает имён: %d; запинено %d, объявлено-машинных %d%s, "
        "унаследовано %d, чисто %d, лишних пинов %d%s"
        % (N, P, M, machine_names(), U, C, K, extra_names())
    )

    def refuse(code):
        for n in extra:
            sys.stdout.write("лишний пин: %s\n" % n)
        for n in basket1:
            sys.stdout.write("запинено: %s\n" % n)
        for n in basket1m:
            sys.stdout.write("объявлено-машинным: %s\n" % n)
        for n in basket2:
            sys.stdout.write("унаследовано: %s\n" % n)
        for n in basket3:
            sys.stdout.write("чисто: %s\n" % n)
        sys.stdout.write("%s %s\n" % (tag, counts))
        sys.stdout.write("%s ВЕРДИКТ НЕ ГЕРМЕТИЧЕН\n" % tag)
        sys.exit(code)

    if N == 0 and not allow_zero:
        refuse(5)
    # Ветка отказа зуба 4: заявленный пин из чтений пуст/не выставлен.
    if missing_pins:
        refuse(4)
    # Ветка отказа зуба 2: ручка не запинена и присутствует в окружении.
    if U > 0:
        refuse(3)
    sys.stdout.write("%s ВЕРДИКТ ГЕРМЕТИЧЕН -- %s\n" % (tag, counts))
    sys.exit(0)


if __name__ == "__main__":
    main()
PY
