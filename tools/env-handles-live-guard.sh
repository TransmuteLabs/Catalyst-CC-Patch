#!/usr/bin/env bash
# Зуб живости ручек окружения: КАЖДЫЙ ключ `env` наших настроек обязан иметь
# читателя -- либо в живом образе хоста, либо в нашем собственном коде.
# Ручка без читателя нигде -- отказ с именем.
#
# Повод: CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION=99999 стояла в настройках
# неизвестно сколько версий, а хост её не читал ВООБЩЕ (имя жило только в двух
# его перечнях). Ни один прибор не спрашивал «а читает ли хост то, что мы
# объявили», поэтому смерть ручки была ненаблюдаема.
#
# CONSTRAINT: подоболочка; окружения вызывающего не меняет и в ФС не пишет.
# CONSTRAINT: образ читается ТОЛЬКО python latin-1. grep на образе лжёт --
# замерено: `grep -c tweakcc versions/2.1.276` даёт RC=1 (ноль) там, где
# python на том же файле находит 11.
# CONSTRAINT: читатель опознаётся по СТРУКТУРЕ доступа (любой идентификатор
# точка ИМЯ, либо скобочный доступ по строке), а не по минифицированному имени
# объекта окружения: имя объекта меняется от версии к версии, структура -- нет.
# CONSTRAINT: ПУСТО ≠ НОЛЬ. Обязателен положительный контроль: названная ручка
# --control ДОЛЖНА найтись читаемой, иначе вердикт не выносится (код 2).
# CONSTRAINT: наш собственный читатель ищется только в файлах КОДА. Упоминание
# имени в документе читателем не является -- иначе док легализует мёртвую ручку.
# CONSTRAINT: подстановка ${ИМЯ} в ТОМ ЖЕ файле настроек (так конфиг MCP-сервера
# берёт ключ из env) -- полноценный читатель, и находится ЗАМЕРОМ, а не
# декларацией: требовать объявлять руками то, что видно структурно, значит
# плодить декларации, которые протухнут молча.
# CONSTRAINT: --external объявляет потребителя ВНЕ всех осмотренных домов.
# Имя, у которого читатель ЕСТЬ, объявленное --external -- противоречие
# декларации (код 2): владелец назван дважды и один из двух раз неверно.
# CONSTRAINT: поимённый список печатается ТОЛЬКО при отказе; на зелёном -- одна
# строка сводки.
set -u
exec python3 - "$@" <<'PY'
import json, os, re, sys

# CONSTRAINT: .rs входит не для полноты списка, а по замеру: живой читатель
# CLAUDE_OPC_DIR -- std::env::var в 10 файлах claude-hooks, а это ПОТОМКИ
# Claude Code, наследующие наш env. Без .rs гвард объявлял живую ручку
# бесхозной -- ложная тревога того самого класса, который он ловит.
# CONSTRAINT: .md / .toml / .json сюда НЕ входят: упоминание имени в доке
# или в конфиге легализовало бы мёртвую ручку, читателя у неё нет.
CODE_EXT = (".ts", ".tsx", ".js", ".mjs", ".cjs", ".py", ".sh", ".zsh",
            ".bash", ".rs")
# CONSTRAINT: target -- продукт сборки Rust. Он попал сюда вместе с .rs: без
# него гвард читал бы сгенерированный код как наш и мог объявить читателем то,
# чего в исходниках нет (а заодно обходил бы дерево в тысячи раз дольше).
SKIP_DIR = {".git", "node_modules", "dist", "distros", "versions", "__pycache__",
            ".venv", "cache", "tool-results", "target"}
DEFAULT_IMAGE = os.path.expanduser("~/.tweakcc/native-claudejs-orig.js")
DEFAULT_SETTINGS = os.path.expanduser("~/.claude/settings.json")
# Ручка контроля: замерена 19.09 на 2.1.276 -- ровно одно место чтения.
# Её исчезновение обязано ронять ПРИБОР (код 2), а не зеленить предмет.
DEFAULT_CONTROL = "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"


def die_usage(extra=""):
    if extra:
        sys.stderr.write("env-handles-live-guard: %s\n" % extra)
    sys.stderr.write(
        "env-handles-live-guard: вызов: [--settings <файл>] [--image <файл>] "
        "[--ours <каталог> ...] [--external <ИМЯ> ...] [--control <ИМЯ>] "
        "[--label <строка>]\n"
    )
    sys.exit(2)


def parse_args(argv):
    settings, image, ours, control, label = DEFAULT_SETTINGS, DEFAULT_IMAGE, [], DEFAULT_CONTROL, ""
    external = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ("--settings", "--image", "--control", "--label"):
            if i + 1 >= len(argv):
                die_usage()
            v = argv[i + 1]; i += 2
            if a == "--settings": settings = v
            elif a == "--image": image = v
            elif a == "--control": control = v
            else: label = v
        elif a == "--ours":
            if i + 1 >= len(argv):
                die_usage()
            ours.append(argv[i + 1]); i += 2
        elif a == "--external":
            if i + 1 >= len(argv):
                die_usage()
            external.append(argv[i + 1]); i += 2
        else:
            die_usage("неизвестный аргумент: %s" % a)
    return settings, image, ours, control, label, external


def read_image(path):
    if not os.path.isfile(path):
        sys.stderr.write("env-handles-live-guard: образ не прочитан: %s\n" % path)
        sys.exit(2)
    # CONSTRAINT: latin-1 -- образ несёт NUL-байты; любая иная кодировка либо
    # падает, либо молча теряет куски, и «ноль вхождений» становится артефактом.
    return open(path, "r", encoding="latin-1").read()


def reader_in_image(img, name):
    n = re.escape(name)
    forms = [
        r"(?<![A-Za-z0-9_$])[A-Za-z_$][A-Za-z0-9_$]*\." + n + r"(?![A-Za-z0-9_$])",
        # CONSTRAINT: перед `[` обязан стоять индексируемый: идентификатор,
        # `)` или `]`. Без этого условия ЛИТЕРАЛ МАССИВА из одного имени
        # (`["ИМЯ"]` -- ровно та форма, в которой апстрим держит перечни
        # ручек) читается как скобочный доступ, и мёртвая ручка зеленеет.
        # Поймано зубом 12, не рассуждением.
        r"(?<=[A-Za-z0-9_$\)\]])\[\s*[\"']" + n + r"[\"']\s*\]",
    ]
    return sum(len(re.findall(f, img)) for f in forms)


def present_in_image(img, name):
    return len(re.findall(re.escape(name), img))


def collect_our_code(dirs):
    # CONSTRAINT: дом, объявленный --ours и не давший НИ ОДНОГО файла, роняет
    # ПРИБОР (код 2), а не зеленит предмет: молчащий дом неотличим от дома без
    # читателей, и именно так живая ручка получает вердикт «бесхозная».
    out = []
    for d in dirs:
        if not os.path.isdir(d):
            sys.stderr.write("env-handles-live-guard: --ours не каталог: %s\n" % d)
            sys.exit(2)
        before = len(out)
        for dp, dn, fn in os.walk(d):
            dn[:] = [x for x in dn if x not in SKIP_DIR]
            for f in fn:
                if f.endswith(CODE_EXT):
                    p = os.path.join(dp, f)
                    try:
                        if os.path.getsize(p) > 8_000_000:
                            continue
                        out.append(open(p, "r", encoding="utf-8", errors="replace").read())
                    except OSError:
                        continue
        if len(out) == before:
            sys.stderr.write(
                "env-handles-live-guard: ПРИБОР НЕДОСТУПЕН -- дом --ours не дал ни "
                "одного файла расширений %s: %s\n" % (" ".join(CODE_EXT), d))
            sys.exit(2)
    return out


def main():
    settings_p, image_p, ours, control, label, external = parse_args(sys.argv)
    try:
        cfg = json.load(open(settings_p, "r", encoding="utf-8"))
    except (OSError, ValueError) as x:
        sys.stderr.write("env-handles-live-guard: настройки не прочитаны (%s): %s\n" % (settings_p, x))
        sys.exit(2)
    names = sorted((cfg.get("env") or {}).keys())
    tag = "env-handles-live-guard[%s]:" % label
    settings_text = open(settings_p, "r", encoding="utf-8").read()
    ext_set = set(external)

    img = read_image(image_p)
    # Положительный контроль ДО предмета: прибор, не нашедший заведомо живого
    # читателя, не имеет права выносить вердикт об остальных.
    if reader_in_image(img, control) == 0:
        sys.stdout.write(
            "%s ПРИБОР НЕДОСТУПЕН: контрольная ручка %s не найдена читаемой в образе %s\n"
            % (tag, control, image_p)
        )
        sys.exit(2)

    our_code = collect_our_code(ours)

    host, mine, subst, ext, declared_unread, unknown = [], [], [], [], [], []
    contradiction = []
    for n in names:
        has_reader = False
        if reader_in_image(img, n) > 0:
            host.append(n); has_reader = True
        elif sum(t.count(n) for t in our_code) > 0:
            mine.append(n); has_reader = True
        elif ("${%s}" % n) in settings_text:
            subst.append(n); has_reader = True
        elif n in ext_set:
            ext.append(n)
        elif present_in_image(img, n) > 0:
            declared_unread.append(n)      # имя апстрим знает, а значения не читает
        else:
            unknown.append(n)              # имени не знает никто
        if has_reader and n in ext_set:
            contradiction.append(n)
    if contradiction:
        sys.stdout.write(
            "%s ОТКАЗ ДЕКЛАРАЦИИ: у этих ручек читатель НАЙДЕН, а объявлены --external: %s\n"
            % (tag, " ".join(contradiction))
        )
        sys.exit(2)
    extra_ext = [n for n in external if n not in names]

    counts = (
        "ручек %d: читает хост %d, читает наш код %d, подстановка в настройках %d, "
        "объявлено-внешним %d%s, объявлено-но-не-читается %d, не знает никто %d; "
        "лишних деклараций %d (контроль %s)"
        % (len(names), len(host), len(mine), len(subst), len(ext),
           (" (%s)" % " ".join(ext)) if ext else "",
           len(declared_unread), len(unknown), len(extra_ext), control)
    )

    def refuse(code):
        for n in declared_unread:
            sys.stdout.write("МЁРТВАЯ (образ знает имя, значения не читает): %s\n" % n)
        for n in unknown:
            sys.stdout.write("БЕСХОЗНАЯ (читателя нет ни в образе, ни в нашем коде): %s\n" % n)
        sys.stdout.write("%s %s\n" % (tag, counts))
        sys.stdout.write("%s ВЕРДИКТ ЕСТЬ РУЧКА БЕЗ ЧИТАТЕЛЯ\n" % tag)
        sys.exit(code)

    if len(names) == 0:
        sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: в настройках ноль ручек env\n" % tag)
        sys.exit(5)
    if declared_unread or unknown:
        refuse(3)
    sys.stdout.write("%s ВЕРДИКТ ВСЕ РУЧКИ ЖИВЫ -- %s\n" % (tag, counts))
    sys.exit(0)


if __name__ == "__main__":
    main()
PY
