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
# CONSTRAINT: читатель в НАШЕМ коде опознаётся СТРУКТУРНО -- по формам
# доступа каждого языка, -- а не подстрочным счётом: упоминание имени в
# комментарии, перечне или фикстуре подстрокой читателем не является.
# Имя, упомянутое подстрокой без единой структурной формы, -- отдельное
# состояние УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ, отказ 3 наравне с мёртвыми.
# CONSTRAINT: читатель ТОЛЬКО в продукте сборки (каталог dist) -- отдельный
# код 6: это расхождение сборки и исходника, а не мёртвая ручка, и путать
# их нельзя. dist при этом ОСТАЁТСЯ в SKIP_DIR первого прохода:
# сгенерированный код нашим не становится, второй ходит только по dist и
# только по именам без читателя в исходнике.
# CONSTRAINT: положительный контроль второй стороны --control-ours: имя,
# структурно читаемое в нашем коде. Ненайденное роняет ПРИБОР (код 2) до
# вердикта: сломавшийся предикат молча объявил бы ВСЕ ручки без читателя.
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
# CONSTRAINT: контроль второй стороны, замер 19.09 по домам
# tools/env-guard-ours.txt: 17 структурных мест в 8 файлах; в самом ките --
# process.env.CLAUDE_JUDGE в tweakcc-patch.js (4) и tools/probe-bench.js (1).
# Сломавшийся предикат нашего кода обязан ронять ПРИБОР (код 2), а не
# объявлять все ручки без читателя.
DEFAULT_CONTROL_OURS = "CLAUDE_JUDGE"


def die_usage(extra=""):
    if extra:
        sys.stderr.write("env-handles-live-guard: %s\n" % extra)
    sys.stderr.write(
        "env-handles-live-guard: вызов: [--settings <файл>] [--image <файл>] "
        "[--ours <каталог> ...] [--homes <файл>] [--external <ИМЯ> ...] "
        "[--control <ИМЯ>] [--control-ours <ИМЯ>] [--label <строка>]\n"
    )
    sys.exit(2)


def parse_args(argv):
    settings, image, ours, control, label = DEFAULT_SETTINGS, DEFAULT_IMAGE, [], DEFAULT_CONTROL, ""
    control_ours, homes = DEFAULT_CONTROL_OURS, None
    external = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ("--settings", "--image", "--control", "--control-ours", "--label", "--homes"):
            if i + 1 >= len(argv):
                die_usage()
            v = argv[i + 1]; i += 2
            if a == "--settings": settings = v
            elif a == "--image": image = v
            elif a == "--control": control = v
            elif a == "--control-ours": control_ours = v
            elif a == "--homes": homes = v
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
    if homes and ours:
        die_usage("--homes и --ours взаимно исключают друг друга")
    return settings, image, ours, homes, control, control_ours, label, external


def read_image(path):
    if not os.path.isfile(path):
        sys.stderr.write("env-handles-live-guard: образ не прочитан: %s\n" % path)
        sys.exit(2)
    # CONSTRAINT: latin-1 -- образ несёт NUL-байты; любая иная кодировка либо
    # падает, либо молча теряет куски, и «ноль вхождений» становится артефактом.
    return open(path, "r", encoding="latin-1").read()


def js_reader_forms(name):
    # CONSTRAINT: перед `[` обязан стоять индексируемый: идентификатор,
    # `)` или `]`. Без этого условия ЛИТЕРАЛ МАССИВА из одного имени
    # (`["ИМЯ"]` -- ровно та форма, в которой апстрим держит перечни
    # ручек) читается как скобочный доступ, и мёртвая ручка зеленеет.
    # Поймано зубами 12 (образ) и 34 (наш код), не рассуждением.
    n = re.escape(name)
    return [
        r"(?<![A-Za-z0-9_$])[A-Za-z_$][A-Za-z0-9_$]*\." + n + r"(?![A-Za-z0-9_$])",
        r"(?<=[A-Za-z0-9_$\)\]])\[\s*[\"']" + n + r"[\"']\s*\]",
    ]


def reader_in_image(img, name):
    return sum(len(re.findall(f, img)) for f in js_reader_forms(name))


def py_env_forms(name):
    n = re.escape(name)
    # CONSTRAINT: форма-аргумент требует ИМЕНОВАННЫЙ вызов (getenv /
    # environ.get) -- любая строка в кавычках читателем не считается.
    return [
        r"(?<![A-Za-z0-9_$])os\.environ\[\s*[\"']" + n + r"[\"']\s*\]",
        r"(?<![A-Za-z0-9_$])os\.environ\.get\(\s*[\"']" + n + r"[\"']",
        r"(?<![A-Za-z0-9_$])os\.getenv\(\s*[\"']" + n + r"[\"']",
        r"(?<![A-Za-z0-9_$.])environ\[\s*[\"']" + n + r"[\"']\s*\]",
    ]


def rs_env_forms(name):
    n = re.escape(name)
    # CONSTRAINT: левая граница допускает `:` -- поэтому полный префикс
    # std::env::var / std::env::var_os покрывается той же формой.
    return [
        r"(?<![A-Za-z0-9_$])env::var\(\s*[\"']" + n + r"[\"']",
        r"(?<![A-Za-z0-9_$])env::var_os\(\s*[\"']" + n + r"[\"']",
    ]


def sh_env_forms(name):
    n = re.escape(name)
    # CONSTRAINT: голое ИМЯ без `$` и без `=` читателем не является;
    # префикс окружения `ИМЯ=... команда` отличает от присваивания
    # обязательное слово после значения.
    return [
        r"\$" + n + r"(?![A-Za-z0-9_$])",
        r"\$\{" + n + r"(?![A-Za-z0-9_$])",
        r"(?<![A-Za-z0-9_$])export\s+" + n + r"(?![A-Za-z0-9_$])",
        r"(?<![A-Za-z0-9_$])" + n + r"=\S+(?:[ \t]+\S+)+",
    ]


def reader_in_our_code(txt, name, ext):
    # CONSTRAINT: быстрый подстрочный фильтр -- не ослабление предиката:
    # каждая структурная форма содержит имя как подстроку.
    if name not in txt:
        return 0
    if ext in (".ts", ".tsx", ".js", ".mjs", ".cjs"):
        forms = js_reader_forms(name)
    elif ext == ".py":
        forms = py_env_forms(name)
    elif ext == ".rs":
        forms = rs_env_forms(name)
    else:  # .sh .zsh .bash
        forms = sh_env_forms(name)
    return sum(len(re.findall(f, txt)) for f in forms)


def present_in_image(img, name):
    return len(re.findall(re.escape(name), img))


def code_ext(fname):
    for e in CODE_EXT:
        if fname.endswith(e):
            return e
    return None


def collect_our_code(dirs, strict_empty=True):
    # CONSTRAINT: дом, объявленный --ours и не давший НИ ОДНОГО файла, роняет
    # ПРИБОР (код 2), а не зеленит предмет: молчащий дом неотличим от дома без
    # читателей, и именно так живая ручка получает вердикт «бесхозная».
    # В режиме --homes имя дома СВЕРЕНО с деревом и опечатка исключена: пустой
    # дом -- факт дерева, а не отказ прибора (строгий отказ остаётся у --ours,
    # зуб 14). Возвращает пары (расширение, текст): структурный предикат
    # выбирает формы доступа ПО ЯЗЫКУ файла.
    out = []
    for d in dirs:
        if not os.path.isdir(d):
            sys.stderr.write("env-handles-live-guard: --ours не каталог: %s\n" % d)
            sys.exit(2)
        before = len(out)
        for dp, dn, fn in os.walk(d):
            dn[:] = [x for x in dn if x not in SKIP_DIR]
            for f in fn:
                e = code_ext(f)
                if e is None:
                    continue
                p = os.path.join(dp, f)
                try:
                    if os.path.getsize(p) > 8_000_000:
                        continue
                    out.append((e, open(p, "r", encoding="utf-8", errors="replace").read()))
                except OSError:
                    continue
        if len(out) == before:
            if strict_empty:
                sys.stderr.write(
                    "env-handles-live-guard: ПРИБОР НЕДОСТУПЕН -- дом --ours не дал ни "
                    "одного файла расширений %s: %s\n" % (" ".join(CODE_EXT), d))
                sys.exit(2)
            sys.stderr.write(
                "env-handles-live-guard: дом без кодовых файлов "
                "(имя сверено с деревом, не отказ): %s\n" % d)
    return out


def load_and_verify_homes(path, tag):
    # CONSTRAINT: разделение ИСЧЕРПЫВАЮЩЕЕ: каждый ВИДИМЫЙ каталог-ребёнок
    # корня семьи обязан состоять ровно в одной секции -- [ours] (осматривается)
    # или [foreign] (НЕ осматривается: чужой код не легализует нашу ручку).
    # Каталог вне обоих списков -- дрейф дерева, и ломать обязан ПРИБОР, а не
    # предмет; направление fail-closed: забытый НАШ дом даёт громкую красноту,
    # забытый ЧУЖОЙ давал бы тихую зелень. Корень семьи сам по себе домом не
    # является; скрытые (.имя) дети не дома и не сверяются.
    if not os.path.isfile(path):
        sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: файл разделения не прочитан: %s\n" % (tag, path))
        sys.exit(2)
    root, ours, foreign = None, [], []
    section = None
    for raw in open(path, "r", encoding="utf-8").read().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("root "):
            if root is not None:
                sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: строка root повторяется в %s\n" % (tag, path))
                sys.exit(2)
            root = os.path.expanduser(line[5:].strip())
            continue
        if line == "[ours]":
            section = ours
            continue
        if line == "[foreign]":
            section = foreign
            continue
        if section is None:
            sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: строка вне секции в %s: %s\n" % (tag, path, line))
            sys.exit(2)
        if "/" in line:
            sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: имя ребёнка с разделителем пути в %s: %s\n" % (tag, path, line))
            sys.exit(2)
        section.append(line)
    if root is None:
        sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: нет строки root в %s\n" % (tag, path))
        sys.exit(2)
    if not os.path.isdir(root):
        sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: root не каталог: %s\n" % (tag, root))
        sys.exit(2)
    if not ours:
        sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: секция [ours] пуста в %s\n" % (tag, path))
        sys.exit(2)
    children = sorted(x for x in os.listdir(root)
                      if not x.startswith(".") and os.path.isdir(os.path.join(root, x)))
    declared = set(ours) | set(foreign)
    both = sorted(set(ours) & set(foreign))
    if both:
        sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: каталоги объявлены в обеих секциях: %s\n"
                         % (tag, " ".join(both)))
        sys.exit(2)
    ghost = sorted(declared - set(children))
    if ghost:
        sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: в разделении названы несуществующие каталоги: %s\n"
                         % (tag, " ".join(ghost)))
        sys.exit(2)
    unlisted = [c for c in children if c not in declared]
    if unlisted:
        sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: каталоги-детей %s вне разделения [ours]/[foreign]: %s\n"
                         % (tag, root, " ".join(unlisted)))
        sys.exit(2)
    return [os.path.join(root, x) for x in ours]


def scan_dist_readers(dirs, wanted):
    # CONSTRAINT: второй проход -- ТОЛЬКО каталоги с именем dist и ТОЛЬКО по
    # именам без читателя в исходнике: dist остаётся в SKIP_DIR первого
    # прохода, иначе сгенерированный код стал бы «нашим».
    if not wanted:
        return set()
    found = set()
    for d in dirs:
        for dp, dn, fn in os.walk(d):
            dists = [x for x in dn if x == "dist"]
            dn[:] = [x for x in dn if x not in SKIP_DIR]
            for x in dists:
                for dp2, dn2, fn2 in os.walk(os.path.join(dp, x)):
                    dn2[:] = [y for y in dn2 if y not in SKIP_DIR or y == "dist"]
                    for f in fn2:
                        e = code_ext(f)
                        if e is None:
                            continue
                        p = os.path.join(dp2, f)
                        try:
                            if os.path.getsize(p) > 8_000_000:
                                continue
                            txt = open(p, "r", encoding="utf-8", errors="replace").read()
                        except OSError as x2:
                            # CONSTRAINT: не молча -- непрочитанный файл dist
                            # мог нести единственного читателя.
                            sys.stderr.write(
                                "env-handles-live-guard: файл dist не прочитан (%s): %s\n" % (x2, p))
                            continue
                        for n in wanted:
                            if n not in found and reader_in_our_code(txt, n, e):
                                found.add(n)
    return found


def main():
    settings_p, image_p, ours, homes, control, control_ours, label, external = parse_args(sys.argv)
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

    if homes:
        our_code = collect_our_code(load_and_verify_homes(homes, tag), strict_empty=False)
    else:
        our_code = collect_our_code(ours)
    # Положительный контроль второй стороны: предикат нашего кода, не
    # нашедший заведомо живого читателя, не имеет права выносить вердикт.
    if not any(reader_in_our_code(t, control_ours, e) for e, t in our_code):
        sys.stdout.write(
            "%s ПРИБОР НЕДОСТУПЕН: контрольная ручка нашего кода %s не найдена "
            "читаемой ни в одном файле\n" % (tag, control_ours)
        )
        sys.exit(2)

    host, mine, subst, ext, declared_unread, unknown = [], [], [], [], [], []
    ours_mention_only, contradiction = [], []
    for n in names:
        has_reader = False
        if reader_in_image(img, n) > 0:
            host.append(n); has_reader = True
        elif any(reader_in_our_code(t, n, e) for e, t in our_code):
            mine.append(n); has_reader = True
        elif ("${%s}" % n) in settings_text:
            subst.append(n); has_reader = True
        elif n in ext_set:
            ext.append(n)
        elif any(n in t for _, t in our_code):
            ours_mention_only.append(n)  # наш код знает имя, доступа нет
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

    # Второй проход по dist -- только для имён без читателя в исходнике.
    candidates = set(declared_unread) | set(unknown) | set(ours_mention_only)
    build_only = scan_dist_readers(ours, candidates)
    if build_only:
        declared_unread = [n for n in declared_unread if n not in build_only]
        unknown = [n for n in unknown if n not in build_only]
        ours_mention_only = [n for n in ours_mention_only if n not in build_only]
    build_only = sorted(build_only)

    counts = (
        "ручек %d: читает хост %d, читает наш код %d, подстановка в настройках %d, "
        "объявлено-внешним %d%s, объявлено-но-не-читается %d, "
        "упомянута-но-не-читается %d, только-сборка %d, не знает никто %d; "
        "лишних деклараций %d (контроль %s, контроль-наш %s)"
        % (len(names), len(host), len(mine), len(subst), len(ext),
           (" (%s)" % " ".join(ext)) if ext else "",
           len(declared_unread), len(ours_mention_only), len(build_only),
           len(unknown), len(extra_ext), control, control_ours)
    )

    def refuse(code, verdict):
        for n in build_only:
            sys.stdout.write("ТОЛЬКО-СБОРКА (читатель есть в продукте сборки, в исходнике нет): %s\n" % n)
        for n in declared_unread:
            sys.stdout.write("МЁРТВАЯ (образ знает имя, значения не читает): %s\n" % n)
        for n in ours_mention_only:
            sys.stdout.write("УПОМЯНУТА-НО-НЕ-ЧИТАЕТСЯ (наш код знает имя, доступа нет): %s\n" % n)
        for n in unknown:
            sys.stdout.write("БЕСХОЗНАЯ (читателя нет ни в образе, ни в нашем коде): %s\n" % n)
        sys.stdout.write("%s %s\n" % (tag, counts))
        sys.stdout.write("%s %s\n" % (tag, verdict))
        sys.exit(code)

    if len(names) == 0:
        sys.stdout.write("%s ПРИБОР НЕДОСТУПЕН: в настройках ноль ручек env\n" % tag)
        sys.exit(5)
    if build_only:
        refuse(6, "ВЕРДИКТ ЧИТАТЕЛЬ ТОЛЬКО В СБОРКЕ -- расхождение сборки и исходника")
    if declared_unread or unknown or ours_mention_only:
        refuse(3, "ВЕРДИКТ ЕСТЬ РУЧКА БЕЗ ЧИТАТЕЛЯ")
    sys.stdout.write("%s ВЕРДИКТ ВСЕ РУЧКИ ЖИВЫ -- %s\n" % (tag, counts))
    sys.exit(0)


if __name__ == "__main__":
    main()
PY
