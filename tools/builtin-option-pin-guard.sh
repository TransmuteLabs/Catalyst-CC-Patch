#!/usr/bin/env bash
# Гвард объявленных пинов опций встроенных модов (#303): каждый пин из
# tools/builtin-option-pins.tsv обязан держаться -- опция в образе, значение
# в образе, значение в настройках.
#
# Повод: встроенный модуль AGENTS.md решает, грузить ли AGENTS.md рядом с
# CLAUDE.md. Опция и её набор значений зависят от версии образа, пин стоит
# в настройках обеих площадок, а прибора, замечающего пропажу пина или
# переименование значений апстримом, не было: пин молча падал бы в ДЕФОЛТ.
#
# CONSTRAINT: подоболочка; в ФС не пишет и окружения вызывающего не меняет.
# CONSTRAINT: образ читается ТОЛЬКО python latin-1 -- grep на образе лжёт
# (замерено: grep -c по образу даёт ноль там, где python находит 11).
# CONSTRAINT: настройки читаются python json, не grep: отказ разбора --
# отказ ПРИБОРА со своим именем, а не «пина нет».
# CONSTRAINT: опция опознаётся по СХЕМНОЙ форме `<имя>:{type:"string"` --
# минифицированной форме объявления опции плагина. Голая подстрока имени
# ЛОЖНА: в живом 2.1.276 литерал instructionFiles встречается в таблицах
# идентификаторов байткода и как поле события, не будучи опцией, и наивный
# поиск давал бы красный на здоровом образе. Значение ищется в кавычковой
# форме "<значение>": голое слово both есть в образе и без перечня значений.
# CONSTRAINT: положительный контроль опирается на ИМЯ ОПЦИИ и ЗНАЧЕНИЯ,
# никогда на идентификатор плагина: строка agents-md@builtin в образе не
# встречается ни разу (идентификатор собирается в рантайме).
# CONSTRAINT: ПУСТО ≠ НОЛЬ: ноль измеренных строк -- отказ прибора, а не
# зелень.
# CONSTRAINT: каждый отказ несёт СВОЁ ИМЯ: два отказа с одним кодом и
# одной строкой неразличимы.
set -u
exec python3 - "$0" <<'PY'
import json, os, sys

TAG = "builtin-option-pin-guard"


def refuse(msg, code):
    sys.stdout.write("%s\n" % msg)
    sys.exit(code)


def main():
    here = os.path.dirname(os.path.abspath(sys.argv[1]))
    settings_p = os.environ.get("CATALYST_SETTINGS_FILE") or os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
        "settings.json")
    image_p = os.environ.get("CATALYST_LIVE_IMAGE") or os.path.expanduser(
        "~/.local/bin/claude")
    tsv_p = os.environ.get("CATALYST_PINS_TSV") or os.path.join(
        here, "builtin-option-pins.tsv")

    try:
        img = open(image_p, "r", encoding="latin-1").read()
    except OSError as x:
        refuse("ПРИБОР НЕДОСТУПЕН: образ %s нечитаем (%s)" % (image_p, x), 2)

    rows = []
    try:
        lines = open(tsv_p, "r", encoding="utf-8").read().splitlines()
    except OSError as x:
        refuse("ПРИБОР НЕДОСТУПЕН: таблица пинов %s нечитаема (%s)" % (tsv_p, x), 2)
    for n, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cells = line.rstrip("\r").split("\t")
        if len(cells) != 4 or not cells[0].strip() or not cells[1].strip() \
                or not cells[2].strip():
            refuse("ПРИБОР НЕДОСТУПЕН: строка %d таблицы %s несёт неверное число "
                   "колонок (нужно РОВНО 4: plugin_id, option, value, основание)"
                   % (n, tsv_p), 2)
        rows.append((cells[0].strip(), cells[1].strip(), cells[2].strip()))

    try:
        cfg = json.load(open(settings_p, "r", encoding="utf-8"))
    except OSError as x:
        refuse("ПРИБОР НЕДОСТУПЕН: настройки %s нечитаемы (%s)" % (settings_p, x), 2)
    except ValueError as x:
        refuse("ПРИБОР НЕДОСТУПЕН: настройки %s не читаются как json (%s)"
               % (settings_p, x), 2)

    measured = unmeasured = red = 0
    for plugin_id, option, value in rows:
        if (option + ':{type:"string"') not in img:
            unmeasured += 1
            sys.stdout.write(
                "НЕ ИЗМЕРЕНО: опции %s нет в образе -- эта версия несёт другую "
                "форму\n" % option)
            continue
        measured += 1
        if ('"%s"' % value) not in img:
            red += 1
            sys.stdout.write(
                "ЗНАЧЕНИЕ ИСЧЕЗЛО: %s нет в образе -- апстрим переименовал набор, "
                "пин молча упадёт в ДЕФОЛТ\n" % value)
            continue
        opts = ((cfg.get("pluginConfigs") or {}).get(plugin_id) or {}).get(
            "options") or {}
        if option not in opts:
            red += 1
            sys.stdout.write(
                "ПИН ОТСУТСТВУЕТ: pluginConfigs[%s].options[%s] нет в %s\n"
                % (plugin_id, option, settings_p))
        elif opts[option] != value:
            red += 1
            sys.stdout.write(
                "ПИН РАЗОШЁЛСЯ: настройки несут %s, объявлено %s\n"
                % (json.dumps(opts[option], ensure_ascii=False), value))

    sys.stdout.write("%s: измерено=%d неизмерено=%d красных=%d\n"
                     % (TAG, measured, unmeasured, red))
    if measured == 0:
        refuse("ПРИБОР НЕ ИЗМЕРИЛ НИЧЕГО: ни одна объявленная форма опции в "
               "образе не найдена -- объявление протухло целиком", 2)
    if red:
        sys.stdout.write("%s: ВЕРДИКТ ОБЪЯВЛЕННЫЙ ПИН НЕ ДЕРЖИТСЯ\n" % TAG)
        sys.exit(1)
    sys.stdout.write("%s: ВЕРДИКТ ПИНЫ НА МЕСТЕ\n" % TAG)
    sys.exit(0)


main()
PY
