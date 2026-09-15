#!/usr/bin/env python3
"""Замер ТОЛЬКО новых запусков судьи-мода.

Граница «нового запуска» — машинная, не календарная: поле `sid` у мод-записей
появилось вместе с плагином 0.1.4 (задача #174). Запись без `sid` физически не
может принадлежать сессии, стартовавшей после установки, поэтому отбор по
наличию `sid` не требует ни часов, ни предположений о времени установки.

ИСТОЧНИК — УЛИКИ, НЕ ЖУРНАЛ. Дорог записи мод-строк две: улика (`records/`)
пишется первой, строка журнала — отдельным `$.fs.write` следом, под catch
(`register.ts` appendJournal). Вторая дорога теряет часть записей, и первая
редакция этого прибора, читавшая журнал, объявила «новых запусков НОЛЬ» при
живых уликах с `sid`. Журнал здесь читается только как ВТОРОЙ прибор — чтобы
назвать размер потери, а не чтобы отбирать по нему.

Прибор обязан УМЕТЬ ЗАГОВОРИТЬ: при нуле новых запусков он печатает
«НЕ ИЗМЕРЕНО» и отдаёт код 5, а не молчит и не печатает нули — пустой результат
без положительного контроля недействителен.

Коды: 0 — измерено; 5 — новых запусков нет; 2 — отказ прибора (нечитаемый дом).
"""
import collections
import datetime
import glob
import gzip
import json
import os
import sys

HOME = os.path.expanduser("~")
# JUDGE_HOME существует ради положительного контроля: без сменного дома нельзя
# доказать, что «НЕ ИЗМЕРЕНО» означает отсутствие данных, а не поломку прибора.
JDIR = os.environ.get("JUDGE_HOME") or os.path.join(HOME, ".claude", "probes", "judge")
RDIR = os.path.join(JDIR, "records")

# Отказ вызова мод-API по бюджету отличается от пустого ответа ступени: первый
# пишется в улику как err_<модель>, второй как raw_<модель> нулевой длины.
BUDGET_MARK = "model budget"

# Своя обрезка судьи. Ответ ровно такой длины упёрся в потолок ПРИБОРА, а не в
# потолок провайдера — считать отдельно, иначе «медиана длины» врёт о том,
# сколько модель реально вернула.
#
# CONSTRAINT: потолков ДВА, потому что улики двух эпох лежат в одном доме.
# Мод 0.1.6 (bc36e05) поднял обрезку до 2000 и завёл поле rawLen_<модель> с
# длиной ДО обрезки; улики старше несут только обрезанный raw_ при потолке 500.
# Сводить их одним числом нельзя: «упёрся» у старой улики и у новой — разные
# события. Длину брать из rawLen_, когда она есть, — тогда медиана перестаёт
# быть медианой потолка.
RAW_CAPS = (500, 2000)


def load_json(path):
    """Улика может лежать сжатой: компактор дожимает записи на месте."""
    op = gzip.open if path.endswith(".gz") else open
    try:
        with op(path, "rt", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def read_records():
    """Все мод-улики дома: (имя без .gz, содержимое, mtime)."""
    out = []
    for p in glob.glob(os.path.join(RDIR, "*")):
        base = os.path.basename(p)
        canon = base[:-3] if base.endswith(".gz") else base
        if not canon.startswith("mod-"):
            continue
        d = load_json(p)
        if isinstance(d, dict):
            out.append((canon, d, os.path.getmtime(p)))
    out.sort(key=lambda r: r[2])
    return out


def journal_names():
    """Имена улик, которые упоминает журнал (сведённый файл плюс шарды)."""
    names = set()
    rows = 0
    paths = [os.path.join(JDIR, "journal.jsonl")]
    paths += sorted(glob.glob(os.path.join(JDIR, "journal.jsonl.shard.*")))
    for p in paths:
        if not os.path.exists(p):
            continue
        try:
            with open(p, encoding="utf-8") as fh:
                for ln in fh:
                    ln = ln.strip()
                    if not ln:
                        continue
                    try:
                        d = json.loads(ln)
                    except Exception:
                        continue
                    rows += 1
                    r = d.get("rec")
                    if r:
                        b = os.path.basename(str(r))
                        names.add(b[:-3] if b.endswith(".gz") else b)
        except Exception as x:
            print("ОТКАЗ ПРИБОРА: не прочитан %s: %s" % (p, x), file=sys.stderr)
            raise SystemExit(2)
    return names, rows


def measure(recs, title):
    """Ступени: звана / пусто / ответ / упёрлось в обрезку / отказ бюджета."""
    empty = collections.Counter()
    nonempty = collections.Counter()
    capped = collections.Counter()
    lens = collections.defaultdict(list)
    budget = collections.Counter()
    other = collections.Counter()
    called = collections.Counter()

    for _, d, _ in recs:
        for k, v in d.items():
            if k.startswith("raw_"):
                m = k[4:]
                s = str(v)
                called[m] += 1
                if s.strip() == "":
                    empty[m] += 1
                else:
                    nonempty[m] += 1
                    real = d.get("rawLen_" + m)
                    if isinstance(real, int):
                        # Длина известна точно: обрезка видна сравнением, а не
                        # догадкой по совпадению с потолком.
                        lens[m].append(real)
                        if real > len(s):
                            capped[m] += 1
                    else:
                        lens[m].append(len(s))
                        if len(s) in RAW_CAPS:
                            capped[m] += 1
            elif k.startswith("err_"):
                m = k[4:]
                called[m] += 1
                if BUDGET_MARK in str(v):
                    budget[m] += 1
                else:
                    other[m] += 1

    print()
    print("=== %s: улик %d ===" % (title, len(recs)))
    if not called:
        print("  ни одна ступень не звана — мерить нечего")
        return
    print("%-18s %6s %7s %6s %6s %8s %9s %9s" %
          ("ступень", "звана", "бюджет", "пусто", "ответ", "%пусто", "обрезан", "медиана"))
    for m in sorted(called, key=lambda x: -called[x]):
        tot = empty[m] + nonempty[m]
        pe = (empty[m] / tot * 100) if tot else 0.0
        ls = sorted(lens[m])
        med = ls[len(ls) // 2] if ls else 0
        print("%-18s %6d %7d %6d %6d %7.1f%% %9d %9d" %
              (m, called[m], budget[m], empty[m], nonempty[m], pe, capped[m], med))
    if sum(other.values()):
        print("  прочие ошибки (не бюджет): %s" % dict(other))
    print("  ЧИТАТЬ ТАК: «бюджет» — отказ мод-API до вызова модели; «пусто» —")
    print("  модель звана и вернула пустое. Это РАЗНЫЕ явления, не складывать.")


def main():
    if not os.path.isdir(JDIR):
        print("ОТКАЗ ПРИБОРА: нет дома улик %s" % JDIR, file=sys.stderr)
        return 2
    if not os.path.isdir(RDIR):
        print("ОТКАЗ ПРИБОРА: нет каталога улик %s" % RDIR, file=sys.stderr)
        return 2

    recs = read_records()
    fresh = [r for r in recs if r[1].get("sid")]
    jnames, jrows = journal_names()
    lost = [r for r in recs if r[0] not in jnames]

    print("мод-улик всего            : %d" % len(recs))
    print("из них новых (несут sid)  : %d" % len(fresh))
    print("строк журнала (со шардами): %d" % jrows)
    print("мод-улик БЕЗ строки журнала: %d (%.1f%%)" %
          (len(lost), (len(lost) / len(recs) * 100) if recs else 0.0))

    if not fresh:
        # Положительный контроль: прибор доказывает, что умеет говорить, называя
        # то, что он ВИДИТ, а не только то, чего не нашёл.
        newest = max((r[2] for r in recs), default=0)
        print()
        print("НЕ ИЗМЕРЕНО: новых запусков нет ни одного.")
        if newest:
            print("  самая свежая мод-улика: %s (без sid)" %
                  datetime.datetime.fromtimestamp(newest).strftime("%Y-%m-%dT%H:%M:%S"))
        print("  причина ожидаемая: живой процесс держит СТАРЫЙ образ плагина;")
        print("  улики с sid появятся только у сессий, стартовавших после 0.1.4.")
        return 5

    by_sid = collections.OrderedDict()
    for name, d, mt in fresh:
        by_sid.setdefault(d["sid"], []).append((name, d, mt))

    print()
    print("=== запуски (sid) ===")
    for sid, rows in by_sid.items():
        ts = sorted(r[2] for r in rows)
        fmt = lambda t: datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%dT%H:%M:%S")
        kinds = collections.Counter(str(r[1].get("kind") or "—") for r in rows)
        print("  %s  вызовов=%d  %s … %s" % (sid, len(rows), fmt(ts[0]), fmt(ts[-1])))
        print("      исходы: %s" % dict(kinds))

    measure(recs, "ВСЕ мод-улики (фон, включая запуски до 0.1.4)")
    measure(fresh, "НОВЫЕ запуски — БАЗОВАЯ ЛИНИЯ")
    return 0


if __name__ == "__main__":
    sys.exit(main())
