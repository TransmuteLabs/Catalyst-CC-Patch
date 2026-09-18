#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pipeline-stage-census.py — гейт переписи стадий конвейера claude-patch-all.sh (#63).

Дом канона стадий: tools/pipeline-stages.tsv. Перечень стадий — ПРОЕКЦИЯ из этого
дома (`--list`), а не второй список (правило "перечень = проекция", MEMORY #195).

Корень #63: стадия конвейера не может существовать без объявления двух вещей —
ЧЕМ ловится её провал (колонка pin) и обязана ли она проявиться в логе прогона
(колонка condition). Новая стадия `echo "==> ..."`, добавленная в конвейер без
строки в tsv, роняет гейт census ⇒ автор ОБЯЗАН объявить проверку. Так "стадия
пиняема по умолчанию": молчаливо-зелёная на провале стадия становится невозможной.

Формат строки tsv (РОВНО 5 полей, разделитель — TAB):
    id  <TAB>  src_re  <TAB>  log_re  <TAB>  pin  <TAB>  condition
  id        — уникальный идентификатор стадии (kebab).
  src_re    — регэксп по ТЕКСТУ source-echo '==> ...' (гейт census: покрытие+живучесть).
              Одна строка может покрывать несколько echo (заголовок + пропуск) альтернацией.
  log_re    — регэксп по строке ЛОГА прогона, подтверждающей стадию (успех|пропуск).
              Отличается от src_re, когда echo несёт ${...}: в источнике шаблон,
              в логе — раскрытое значение (напр. ${KIT_BENCH_NAMES[0]} → "Стенд ...").
  pin       — механизм ловли провала: exit | sweep:<field> | EXEMPT:<основание>.
              exit          — провал рушит конвейер (|| exit ЛИБО голая команда под set -e).
              sweep:<field> — поле-подтверждение в tools/sweep.sh (гейт проверяет, что поле живо).
              EXEMPT:<осн.> — стадия намеренно-нефатальна и не сверяется свипом; основание обязательно.
  condition — участие в логе: always | cond-skip | cond-silent.
              always      — confirm обязан быть в логе завершённого прогона.
              cond-skip   — confirm ЛИБО объявленный пропуск обязан быть в логе (log_re покрывает оба).
              cond-silent — из присутствия в логе освобождена (кэш-попадание, пропуск без echo,
                            объявление пропуска печатает другой инструмент); pin всё равно ловит провал.

Гейты:
  census      — покрытие (каждый source-echo '==>' заявлен РОВНО одной строкой tsv),
                живучесть (src_re каждой строки жив в источнике),
                валидность pin (sweep:<field> ⇒ поле живо в sweep.sh),
                валидность condition, счёт строк (== --expected, дом счётчика).
  sweep-check — присутствие: в логе ЗАВЕРШЁННОГО прогона log_re каждой стадии
                с пином exit (always / cond-skip) обязан совпасть. Стадию с пином
                sweep:<field> присутствие НЕ сверяет — её уже ловит своё поле
                вердикта (нет исхода стадии ⇒ поле краснит), а дублирующая сверка
                маскировала бы мутацию этого поля (#63). EXEMPT и cond-silent
                освобождены по объявлению. Предусловие завершённости прогона
                обеспечивает вызывающий (sweep.sh уже гейтит на EXIT=0) — здесь
                ловится молча пропущенная exit-стадия.

Коды выхода: 0 — чисто; 2 — нарушение гейта (дефект найден); 3 — прибор не смог
измерить (нет/нечитаем файл, битый регэксп в каноне); 1 — ошибка употребления.
Режим --self-check: 0 — все зубы зелены + красный контроль сработал; 1 — иначе.
"""

import os
import re
import sys

# Единственный шаблон извлечения стадии: echo "==> <текст>". Захват — <текст> (шаблон
# источника, до раскрытия ${...}). Совпадает с грепом переписи ('echo "==> ' = 34).
ECHO_RE = re.compile(r'echo\s+"==>\s?(.*?)"')
# Строка-комментарий: закомментированный echo — НЕ исполняемая стадия (пример в
# прозе, а не сайт вызова). Реальная стадия никогда не на '#'-строке; счёт-гейт
# --expected подстрахует исчезновение реальной стадии (source-echo станет меньше).
COMMENT_RE = re.compile(r"^\s*#")

PIN_EXIT = "exit"
PIN_SWEEP_PREFIX = "sweep:"
PIN_EXEMPT_PREFIX = "EXEMPT:"
CONDITIONS = ("always", "cond-skip", "cond-silent")

RC_OK = 0
RC_GATE = 2
RC_UNMEASURED = 3
RC_USAGE = 1


class TableError(Exception):
    """Битый канон стадий (tsv): неизмеримо, код 3 (прибор не смог)."""


def parse_table(text):
    """
    Разобрать текст tsv в список строк-стадий (dict с скомпилированными регэкспами).
    Пустые строки и строки-комментарии (# в начале после отступа) пропускаются.
    Битьё формата/регэкспа → TableError.
    """
    rows = []
    seen_ids = set()
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 5:
            raise TableError(
                "строка %d: полей %d, ожидалось 5 (разделитель TAB): %r"
                % (lineno, len(parts), line)
            )
        sid, src_re, log_re, pin, cond = (p.strip() for p in parts)
        if not sid or not src_re or not log_re or not pin or not cond:
            raise TableError("строка %d: пустое поле" % lineno)
        if sid in seen_ids:
            raise TableError("строка %d: id %r повторяется" % (lineno, sid))
        seen_ids.add(sid)
        if cond not in CONDITIONS:
            raise TableError(
                "строка %d: condition %r не из %s" % (lineno, cond, CONDITIONS)
            )
        if not (
            pin == PIN_EXIT
            or pin.startswith(PIN_SWEEP_PREFIX)
            or pin.startswith(PIN_EXEMPT_PREFIX)
        ):
            raise TableError(
                "строка %d: pin %r не exit|sweep:<field>|EXEMPT:<основание>"
                % (lineno, pin)
            )
        if pin.startswith(PIN_SWEEP_PREFIX) and not pin[len(PIN_SWEEP_PREFIX):].strip():
            raise TableError("строка %d: sweep:<field> без имени поля" % lineno)
        if pin.startswith(PIN_EXEMPT_PREFIX) and not pin[len(PIN_EXEMPT_PREFIX):].strip():
            raise TableError("строка %d: EXEMPT:<основание> без основания" % lineno)
        try:
            src_c = re.compile(src_re)
            log_c = re.compile(log_re)
        except re.error as exc:
            raise TableError("строка %d: битый регэксп: %s" % (lineno, exc))
        rows.append(
            {
                "id": sid,
                "src_re": src_re,
                "log_re": log_re,
                "src_c": src_c,
                "log_c": log_c,
                "pin": pin,
                "cond": cond,
                "lineno": lineno,
            }
        )
    return rows


def extract_stage_echoes(source_text):
    """Список (lineno, текст) всех echo \"==> ...\" в источнике."""
    out = []
    for lineno, raw in enumerate(source_text.splitlines(), 1):
        if COMMENT_RE.match(raw):
            continue  # закомментированный echo — не исполняемая стадия
        m = ECHO_RE.search(raw)
        if m:
            out.append((lineno, m.group(1)))
    return out


def run_census(source_text, rows, sweep_text=None, expected=None):
    """
    Гейт census. Возвращает (ok: bool, messages: list[str]).
    messages несут и зелёные строки (для лога), и красные (нарушения) с меткой 'ОТКАЗ:'.
    """
    msgs = []
    ok = True
    echoes = extract_stage_echoes(source_text)
    source_lines = source_text.splitlines()

    # --- Покрытие: каждый source-echo '==>' заявлен РОВНО одной строкой tsv ---
    for lineno, text in echoes:
        claimers = [r["id"] for r in rows if r["src_c"].search(text)]
        if len(claimers) == 0:
            ok = False
            msgs.append(
                "ОТКАЗ: незаявленная стадия (источник:%d): %r — нет строки в каноне"
                % (lineno, text)
            )
        elif len(claimers) > 1:
            ok = False
            msgs.append(
                "ОТКАЗ: стадия (источник:%d) %r заявлена >1 строкой: %s"
                % (lineno, text, ", ".join(claimers))
            )
    msgs.append("перепись: source-echo '==>' найдено: %d" % len(echoes))

    # --- Живучесть: src_re каждой строки совпадает хотя бы с одной строкой источника ---
    for r in rows:
        if not any(r["src_c"].search(sl) for sl in source_lines):
            ok = False
            msgs.append(
                "ОТКАЗ: мёртвая строка канона %r (tsv:%d): src_re не найден в источнике"
                % (r["id"], r["lineno"])
            )

    # --- Валидность pin: sweep:<field> ⇒ поле живо в sweep.sh ---
    for r in rows:
        if r["pin"].startswith(PIN_SWEEP_PREFIX):
            field = r["pin"][len(PIN_SWEEP_PREFIX):].strip()
            if sweep_text is None:
                # без источника sweep поле не сверить — это неполнота гейта, не зелень
                ok = False
                msgs.append(
                    "ОТКАЗ: строка %r несёт sweep:%s, но sweep.sh не подан на сверку"
                    % (r["id"], field)
                )
            else:
                # поле-присваивание вида `<field>=` (после отступа/начала строки)
                fre = re.compile(r"(?m)^\s*%s=" % re.escape(field))
                if not fre.search(sweep_text):
                    ok = False
                    msgs.append(
                        "ОТКАЗ: строка %r: поле sweep %r не найдено в sweep.sh"
                        % (r["id"], field)
                    )

    # --- Счёт строк канона (дом счётчика EXPECTED_STAGES) ---
    if expected is not None:
        if len(rows) != expected:
            ok = False
            msgs.append(
                "ОТКАЗ: строк канона %d, ожидалось %d (EXPECTED_STAGES)"
                % (len(rows), expected)
            )
        else:
            msgs.append("счёт стадий: %d == EXPECTED_STAGES" % len(rows))

    return ok, msgs


def run_sweep_check(rows, log_text):
    """
    Гейт присутствия. Возвращает (ok, messages). Присутствие в логе сверяется ТОЛЬКО
    у стадий с пином exit (always / cond-skip): их провал ловит код выхода, а на
    завершённом прогоне (rc==0) молча пропущенную стадию иначе не видно. Стадия с
    пином sweep:<field> уже пиняема своим полем вердикта (нет исхода ⇒ поле краснит):
    дублирующая сверка присутствия маскировала бы мутацию этого поля (#63). EXEMPT и
    cond-silent освобождены по объявлению. Предполагается ЗАВЕРШЁННЫЙ прогон.
    """
    msgs = []
    ok = True
    checked = 0
    exempt = 0
    for r in rows:
        if r["cond"] == "cond-silent" or r["pin"] != PIN_EXIT:
            exempt += 1
            continue
        checked += 1
        if not r["log_c"].search(log_text):
            ok = False
            msgs.append(
                "ОТКАЗ: стадия %r (%s) не проявилась в логе завершённого прогона "
                "(log_re=%r) — молчаливый пропуск/вакуум"
                % (r["id"], r["cond"], r["log_re"])
            )
    msgs.append(
        "sweep-check: проверено %d (exit-пин, always/cond-skip), "
        "освобождено %d (sweep-поле/EXEMPT/cond-silent)"
        % (checked, exempt)
    )
    return ok, msgs


# --------------------------------------------------------------------------- #
#                               --self-check                                   #
# --------------------------------------------------------------------------- #

# Герметичные фикстуры (в памяти, без файлов). Зелёная пара источник+канон, лог.
_GREEN_SOURCE = "\n".join(
    [
        'echo "==> Alpha stage"',            # always, exit
        'echo "==> Beta ${VER}"',            # always, exit, переменная в хвосте
        'echo "==> ${NAMES[0]}"',            # always, exit, весь текст — переменная
        'echo "==> Gamma runs"',             # cond-skip: заголовок
        'echo "==> Gamma ПРОПУЩЕНА: причины"',  # cond-skip: пропуск
        'echo "Signed-OK marker"',           # не-'==>' подтверждение подписи-аналога
        'echo "==> Delta ПРОПУЩЕНА: нет ОС"',   # подпись-аналог: только '==>' пропуск
        'echo "==> Epsilon quiet"',          # cond-silent
        'echo "==> Zeta swept"',             # sweep:zfield
    ]
)

_GREEN_TABLE = "\n".join(
    [
        "# id\tsrc_re\tlog_re\tpin\tcondition",
        "alpha\tAlpha stage\tAlpha stage\texit\talways",
        "beta\tBeta \\$\\{VER\\}\tBeta \texit\talways",
        "names0\t\\$\\{NAMES\\[0\\]\\}\tNamed value zero\texit\talways",
        "gamma\tGamma runs|Gamma ПРОПУЩЕНА\tGamma runs|Gamma ПРОПУЩЕНА\texit\tcond-skip",
        "delta\tDelta ПРОПУЩЕНА\tSigned-OK marker|Delta ПРОПУЩЕНА\tsweep:sfield\tcond-skip",
        "epsilon\tEpsilon quiet\tEpsilon quiet\tEXEMPT:кэш-попадание молчит\tcond-silent",
        "zeta\tZeta swept\tZeta swept\tsweep:zfield\talways",
    ]
)

_GREEN_SWEEP = "\n".join(
    [
        "    sfield=$(grep -c 'Signed-OK' \"$log\")",
        "    zfield=$(grep -c 'Zeta swept' \"$log\")",
    ]
)

# Лог завершённого прогона: раскрытые значения + все always/cond-skip строки.
_GREEN_LOG = "\n".join(
    [
        "==> Alpha stage",
        "==> Beta 2.1.274",
        "==> Named value zero",
        "==> Gamma runs",
        "Signed-OK marker",
        "==> Epsilon quiet",   # присутствует, но stage cond-silent — не требуется
        "==> Zeta swept",
    ]
)

_GREEN_EXPECTED = 7


def _tooth(name, cond_fn):
    """Вернуть (name, ok). cond_fn() → bool (ожидаемый исход зуба)."""
    try:
        return (name, bool(cond_fn()))
    except Exception as exc:  # зуб, упавший исключением, считается красным
        return (name, False)


def self_check():
    """Герметичная батарея зубов + красный контроль каждого гейта. RC 0/1."""
    teeth = []

    def census(source=_GREEN_SOURCE, table=_GREEN_TABLE, sweep=_GREEN_SWEEP,
               expected=_GREEN_EXPECTED):
        rows = parse_table(table)
        ok, _ = run_census(source, rows, sweep_text=sweep, expected=expected)
        return ok

    def sweep_check(table=_GREEN_TABLE, log=_GREEN_LOG):
        rows = parse_table(table)
        ok, _ = run_sweep_check(rows, log)
        return ok

    # ЗУБ 0 — зелёная база: оба гейта чисты на нетронутых фикстурах.
    teeth.append(_tooth("ЗУБ 0 зелёная-база census", lambda: census() is True))
    teeth.append(_tooth("ЗУБ 0 зелёная-база sweep-check", lambda: sweep_check() is True))

    # ЗУБ 1 — покрытие: незаявленный source-echo '==>' роняет census.
    teeth.append(
        _tooth(
            "ЗУБ 1 покрытие-незаявленной",
            lambda: census(source=_GREEN_SOURCE + '\necho "==> Orphan new stage"') is False,
        )
    )

    # ЗУБ 2 — живучесть: мёртвая строка канона (src_re ни с чем не совпал) роняет census.
    teeth.append(
        _tooth(
            "ЗУБ 2 живучесть-мёртвой-строки",
            lambda: census(
                table=_GREEN_TABLE
                + "\nghost\tNever appears in source XYZ\tanything\texit\talways",
                expected=_GREEN_EXPECTED + 1,
            )
            is False,
        )
    )

    # ЗУБ 3 — дубль-заявка: два ряда на один echo роняют census (>1 заявитель).
    teeth.append(
        _tooth(
            "ЗУБ 3 дубль-заявки",
            lambda: census(
                table=_GREEN_TABLE + "\nalpha2\tAlpha stage\tAlpha stage\texit\talways",
                expected=_GREEN_EXPECTED + 1,
            )
            is False,
        )
    )

    # ЗУБ 4 — валидность pin: битый pin ловится ещё разбором канона (TableError → красно).
    def bad_pin():
        try:
            parse_table(
                _GREEN_TABLE + "\nbadp\tAlpha stage\tAlpha stage\tmaybe\talways"
            )
            return False  # разбор НЕ упал — зуб не сработал
        except TableError:
            return True

    teeth.append(_tooth("ЗУБ 4 битый-pin", bad_pin))

    # ЗУБ 5 — валидность condition: битое condition ловится разбором канона.
    def bad_cond():
        try:
            parse_table(
                _GREEN_TABLE + "\nbadc\tAlpha stage\tAlpha stage\texit\tsometimes"
            )
            return False
        except TableError:
            return True

    teeth.append(_tooth("ЗУБ 5 битое-condition", bad_cond))

    # ЗУБ 6 — висячее поле sweep: sweep:<field> без поля в sweep.sh роняет census.
    teeth.append(
        _tooth(
            "ЗУБ 6 висячее-поле-sweep",
            lambda: census(sweep="    other=$(grep -c foo \"$log\")") is False,
        )
    )

    # ЗУБ 7 — счёт стадий: неверный EXPECTED_STAGES роняет census.
    teeth.append(
        _tooth(
            "ЗУБ 7 неверный-счёт",
            lambda: census(expected=_GREEN_EXPECTED + 5) is False,
        )
    )

    # ЗУБ 8 — присутствие always: убрать строку always-стадии из лога → sweep-check красно.
    teeth.append(
        _tooth(
            "ЗУБ 8 отсутствие-always",
            lambda: sweep_check(
                log="\n".join(
                    l for l in _GREEN_LOG.splitlines() if "Alpha stage" not in l
                )
            )
            is False,
        )
    )

    # ЗУБ 9 — присутствие cond-skip: убрать И confirm, И skip → sweep-check красно.
    teeth.append(
        _tooth(
            "ЗУБ 9 отсутствие-cond-skip",
            lambda: sweep_check(
                log="\n".join(
                    l
                    for l in _GREEN_LOG.splitlines()
                    if "Gamma" not in l  # ни runs, ни ПРОПУЩЕНА (в логе только runs)
                )
            )
            is False,
        )
    )

    # ЗУБ 10 — освобождение cond-silent: убрать строку cond-silent → sweep-check ОСТАЁТСЯ
    # зелёным (положительный контроль освобождения: cond-silent реально не требуется).
    teeth.append(
        _tooth(
            "ЗУБ 10 освобождение-cond-silent",
            lambda: sweep_check(
                log="\n".join(
                    l for l in _GREEN_LOG.splitlines() if "Epsilon quiet" not in l
                )
            )
            is True,
        )
    )

    # ЗУБ 11 — комментарий-echo не стадия: закомментированный 'echo "==> ..."'
    # без строки канона НЕ роняет census (положительный контроль пропуска
    # строк-комментариев; иначе пример в прозе читался бы незаявленной стадией).
    teeth.append(
        _tooth(
            "ЗУБ 11 комментарий-echo-пропущен",
            lambda: census(source=_GREEN_SOURCE + '\n  # пример: echo "==> Commented"') is True,
        )
    )

    # ЗУБ 12 — освобождение sweep:<field> always: убрать строку sweep-стадии (zeta,
    # sweep:zfield) из лога → sweep-check ОСТАЁТСЯ зелёным. Присутствие такой стадии
    # сверяет её поле вердикта, не этот гейт; иначе сверка маскировала бы мутацию
    # поля (#63). Red-first: до фикса #63 сверялись все always/cond-skip и зуб был бы КРАСНЫМ.
    teeth.append(
        _tooth(
            "ЗУБ 12 освобождение-sweep-always",
            lambda: sweep_check(
                log="\n".join(
                    l for l in _GREEN_LOG.splitlines() if "Zeta swept" not in l
                )
            )
            is True,
        )
    )

    # ЗУБ 13 — освобождение sweep:<field> cond-skip: убрать исход sweep-стадии
    # (delta, sweep:sfield — в логе только confirm 'Signed-OK marker') → sweep-check
    # ОСТАЁТСЯ зелёным по той же причине. Red-first: до фикса #63 был бы КРАСНЫМ.
    teeth.append(
        _tooth(
            "ЗУБ 13 освобождение-sweep-cond-skip",
            lambda: sweep_check(
                log="\n".join(
                    l for l in _GREEN_LOG.splitlines() if "Signed-OK marker" not in l
                )
            )
            is True,
        )
    )

    green = sum(1 for _, ok in teeth if ok)
    total = len(teeth)
    for name, ok in teeth:
        sys.stdout.write("  [%s] %s\n" % ("ЗЕЛ" if ok else "КРАС", name))
    sys.stdout.write("ИТОГ зубов=%d зелёных=%d\n" % (total, green))
    return RC_OK if green == total else 1


# --------------------------------------------------------------------------- #
#                                    CLI                                       #
# --------------------------------------------------------------------------- #

USAGE = """\
употребление:
  pipeline-stage-census.py census --source <claude-patch-all.sh> --table <tsv> \\
                                  --sweep <sweep.sh> [--expected N]
  pipeline-stage-census.py sweep-check --table <tsv> --log <runlog>
  pipeline-stage-census.py list --table <tsv>
  pipeline-stage-census.py --self-check
"""


def _read(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except OSError as exc:
        sys.stderr.write("НЕ ИЗМЕРЕНО: не прочитан %s: %s\n" % (path, exc))
        sys.exit(RC_UNMEASURED)


def _opt(argv, name, required=True, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 >= len(argv):
            sys.stderr.write("ошибка: у %s нет значения\n" % name)
            sys.exit(RC_USAGE)
        return argv[i + 1]
    if required:
        sys.stderr.write("ошибка: обязателен %s\n%s" % (name, USAGE))
        sys.exit(RC_USAGE)
    return default


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(USAGE)
        return RC_OK
    if argv[0] == "--self-check":
        return self_check()

    mode = argv[0]
    rest = argv[1:]

    if mode == "list":
        table = _read(_opt(rest, "--table"))
        try:
            rows = parse_table(table)
        except TableError as exc:
            sys.stderr.write("НЕ ИЗМЕРЕНО: битый канон: %s\n" % exc)
            return RC_UNMEASURED
        for r in rows:
            sys.stdout.write("%s\n" % r["id"])
        return RC_OK

    if mode == "census":
        source = _read(_opt(rest, "--source"))
        table = _read(_opt(rest, "--table"))
        sweep = _read(_opt(rest, "--sweep"))
        exp_s = _opt(rest, "--expected", required=False)
        expected = None
        if exp_s is not None:
            try:
                expected = int(exp_s)
            except ValueError:
                sys.stderr.write("ошибка: --expected не число: %r\n" % exp_s)
                return RC_USAGE
        try:
            rows = parse_table(table)
        except TableError as exc:
            sys.stderr.write("НЕ ИЗМЕРЕНО: битый канон: %s\n" % exc)
            return RC_UNMEASURED
        ok, msgs = run_census(source, rows, sweep_text=sweep, expected=expected)
        for m in msgs:
            sys.stdout.write(m + "\n")
        return RC_OK if ok else RC_GATE

    if mode == "sweep-check":
        table = _read(_opt(rest, "--table"))
        log = _read(_opt(rest, "--log"))
        try:
            rows = parse_table(table)
        except TableError as exc:
            sys.stderr.write("НЕ ИЗМЕРЕНО: битый канон: %s\n" % exc)
            return RC_UNMEASURED
        ok, msgs = run_sweep_check(rows, log)
        for m in msgs:
            sys.stdout.write(m + "\n")
        return RC_OK if ok else RC_GATE

    sys.stderr.write("ошибка: неизвестный режим %r\n%s" % (mode, USAGE))
    return RC_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
