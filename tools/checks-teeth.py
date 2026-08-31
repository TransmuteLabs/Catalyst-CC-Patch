#!/usr/bin/env python3
"""Зубы реестра проверок: мутация СОБРАННОГО образа обязана краснить свою проверку.

Зачем. Пол проверок (`checks-on-image.sh --floor`) доказывает, что проверка
КРАСНА на стоке. Это не то же самое, что «краснеет, когда свойство умирает»:
предыдущий круг аудита показал проверки, чьё имя обещает свойство, а тело пинит лишь
токен -- свойство можно было убить, не тронув токена, и проверка оставалась
зелёной. Здесь у каждой такой проверки появляется НАЗВАННАЯ мутация, которая
воспроизводит именно этот дефект.

Почему мутируется собранный образ, а не исходник. Мутация входа стирается:
tweakcc восстанавливает свой бэкап поверх названной цели до всякого патча, и
сборка выглядит успешной (измерено 2026-08-27). Форма контроля -- та же, что у
`checks-on-image.sh`: правим уже собранные байты и гоняем по ним реестр.

Мутации РАВНОЙ ДЛИНЫ: замена дополняется пробелами до длины якоря, длиннее
якоря -- отказ прибора. Смещения от этого не едут, и образ остаётся тем же
объектом измерения, а не другим файлом.

Коды выхода (подмножество общей таблицы кита -- шапка claude-patch-all.sh):
  0  каждая мутация покраснела СВОЮ проверку и только её
  1  мутация прошла молча либо покрасила чужую дверь
  2  прибор не может мерить: якорь пропал/слишком широк, замена длиннее якоря,
     либо КОНТРОЛЬ провален -- названный образ красен ещё до мутаций; сюда же
     относится нарушенный контракт вызова: --jobs < 1 (круг 26, K-14)
  4  длина таблицы разошлась с объявленной (EXPECTED_MUTATIONS)
  3  замок конвейера держит живая сборка -- НЕ МЕРИЛИ, повтор поможет
  5  мерить нечего: на этой машине нет собранного образа
  6  сломано окружение либо машинерия замка: нет bash, нет
     tools/checks-on-image.sh, замок не открыть или flock не работает --
     повтор НЕ поможет
"""

from __future__ import annotations

import argparse
import fcntl
import glob
import io
import os
import time
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor
from concurrent.futures.process import BrokenProcessPool
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLE = ROOT / "tools" / "checks-mutations.tsv"
RUNNER = ROOT / "tools" / "checks-on-image.sh"
EXPECTED_MUTATIONS = 19
ID = rb"[A-Za-z_$][A-Za-z0-9_$]*"
# Приманка кладётся ЗАВЕДОМО вне окна (оно +-20000 байт в обе стороны): так мутация
# отличает сужение по окну от поиска по всему образу.
DECOY_BACK = 2_000_000


class Refusal(Exception):
    """Прибор не может мерить (класс 2)."""


class LockMachineryBroken(Exception):
    """Замок не открыть или flock не работает -- класс 6 (круг 28, F-1).

    Один код на два ответа стоил киту десяти минут в круге 18, F-2: сломанная
    машинерия выглядела занятым замком. Здесь тот же класс дефекта: OSError
    на open() замка (нет каталога, нет права) возвращал None -- то же значение,
    что и «flock занят живой сборкой», -- и вызывающий объявлял код 3 «повтор
    поможет» там, где держателя нет вовсе. Свип на 3 уходит ждать
    несуществующего держателя. Занятость и поломка теперь РАЗНЫЕ ответы.
    """


def default_image() -> Path | None:
    link = Path.home() / ".local" / "bin" / "claude"
    if link.is_symlink():
        target = Path(os.path.realpath(link))
        if target.is_file():
            return target
    if link.is_file():
        return link
    return None


def read_table() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for line in io.open(TABLE, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 7:
            raise Refusal(f"строка таблицы не из семи полей: {parts[:2]}")
        rows.append(dict(zip(("id", "check", "kind", "anchor", "repl", "also", "note"),
                             parts)))
    return rows


def edits_literal(base: bytes, row: dict[str, str]) -> list[tuple[int, bytes]]:
    anchor = row["anchor"].encode()
    repl = row["repl"].encode()
    if len(repl) > len(anchor):
        raise Refusal(f"{row['id']}: замена длиннее якоря ({len(repl)} > {len(anchor)})")
    repl = repl.ljust(len(anchor))
    spots = [m.start() for m in re.finditer(re.escape(anchor), base)]
    if not spots:
        raise Refusal(f"{row['id']}: якорь не найден в образе")
    if len(spots) > 8:
        raise Refusal(f"{row['id']}: якорь слишком широк -- {len(spots)} вхождений")
    return [(s, repl) for s in spots]


def edits_c10(base: bytes) -> list[tuple[int, bytes]]:
    """Дебаунс возвращается к стоку, а приманка того же имени ложится вдали.

    Прежняя форма искала `var <имя>=500` по ВСЕМУ образу (сужение по
    модулю в упакованном образе мертво -- маркеров там ноль), и такая пара
    оставляла её зелёной при стоковом троттлинге.
    """
    m = re.search(rb"\.setTimeout\(\(\)=>\{this\.#" + ID + rb"=null,this\.#" + ID
                  + rb"\(\)\},(" + ID + rb")\)\}", base)
    if not m:
        raise Refusal("C10: место дебаунса не найдено")
    name = m.group(1)
    decl = re.search(rb"var " + re.escape(name) + rb"=500\b", base)
    if not decl:
        raise Refusal("C10: объявление дебаунса со значением 500 не найдено")
    decoy = m.start() - DECOY_BACK
    if decoy < 0:
        raise Refusal("C10: некуда положить приманку -- образ короче отступа")
    return [
        (decl.start(), b"var " + name + b"=300"),
        (decoy, b"var " + name + b"=500"),
    ]


DERIVED = {"C10": edits_c10}


def pipeline_lock_path() -> str:
    """Тот же дом замка, что у конвейера (claude-patch-all.sh) и зонда пути."""
    named = os.environ.get("CLAUDE_PATCH_LOCK")
    if named:
        return named
    tmp = os.environ.get("TMPDIR") or "/tmp"
    return os.path.join(tmp, "claude-patch-all.%d.lock" % os.getuid())


def hold_read_lock() -> "io.BufferedWriter | None":
    """Разделяемый замок на время замера.

    None -- замок занят: его держит живая сборка (код 3, повтор поможет).
    LockMachineryBroken -- замок НЕ открыть либо flock не работает (код 6,
    повтор НЕ поможет): см. класс -- там история, почему различие обязано
    быть явным.

    Прибор МЕРЯЕТ ЖИВОЙ ОБРАЗ и копирует его четырнадцать раз. Сборка в это
    время вносит новый образ переименованием: копия попадала на файл, который
    уже не тот, и прибор объявлял КРАСНОЕ -- дефект, которого нет (круг 21,
    F-1). Замок разделяемый: два замера друг другу не мешают, а сборка держит
    исключительный и просто не пускает нас в своё окно.
    """
    path = pipeline_lock_path()
    try:
        fh = open(path, "a")
    except OSError as exc:
        raise LockMachineryBroken(
            f"файл замка не открывается: {path}: {exc}") from exc
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        # Единственная ошибка flock, означающая ЗАНЯТОСТЬ (EWOULDBLOCK/EAGAIN):
        # держатель есть, и это ответ класса 3.
        fh.close()
        return None
    except OSError as exc:
        fh.close()
        raise LockMachineryBroken(
            f"flock не работает на {path}: {exc}") from exc
    return fh


WORKER_TMP_HELD_SECONDS = 6 * 3600


def weed_worker_leftovers() -> int:
    """Копии образа, пережившие SIGKILL воркера.

    Каждая -- сотни мегабайт, а имя было СЛУЧАЙНЫМ: опознать ничьё было нечем,
    и обломки копились без предела (круг 21, E-9). Имя теперь несёт pid, и
    ничьим считается только доказанно ничей: мёртвый номер либо возраст больше
    порога (переиспользованный номер -- та же ловушка, что у прополки записей).
    """
    tmp = os.environ.get("TMPDIR") or "/tmp"
    removed = 0
    for path in glob.glob(os.path.join(tmp, "checks-teeth.[0-9]*.*.bin")):
        suffix = os.path.basename(path).split(".")[1]
        try:
            pid = int(suffix)
        except ValueError:
            continue
        try:
            stat = os.stat(path)
        except FileNotFoundError:
            continue
        alive = True
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            alive = False
        except (PermissionError, OverflowError, ValueError):
            alive = True
        if alive and (time.time() - stat.st_mtime) < WORKER_TMP_HELD_SECONDS:
            continue
        try:
            after = os.stat(path)
        except FileNotFoundError:
            continue
        if (after.st_ino, after.st_mtime_ns) != (stat.st_ino, stat.st_mtime_ns):
            continue                   # подменён между замером и снятием -- не наш
        try:
            os.unlink(path)
        except FileNotFoundError:
            continue
        removed += 1
    return removed


def reds(image: Path) -> tuple[list[str], str]:
    done = subprocess.run(["bash", str(RUNNER), str(image)],
                          capture_output=True, text=True)
    out = done.stdout
    red = [l.strip()[7:] for l in out.splitlines() if l.strip().startswith("[FAIL] ")]
    green = [l for l in out.splitlines() if l.strip().startswith("[OK] ")]
    if not red and not green:
        raise Refusal("реестр не назвал ни одной проверки: " + (out or done.stderr)[-500:])
    return red, out


def run_one(args) -> tuple[str, str, list[str], list[str]]:
    mid, check, image, edits, want = args
    # pid в имени -- единственный признак, по которому обломок убитого воркера
    # опознаётся как ничей (см. weed_worker_leftovers).
    handle, path = tempfile.mkstemp(prefix="checks-teeth.%d." % os.getpid(), suffix=".bin")
    os.close(handle)
    try:
        shutil.copyfile(image, path)
        with open(path, "r+b") as fh:
            for off, data in edits:
                fh.seek(off)
                fh.write(data)
        red, _ = reds(Path(path))
    finally:
        os.unlink(path)
    return mid, check, red, want


def main() -> int:
    ap = argparse.ArgumentParser(description="зубы реестра проверок")
    ap.add_argument("--image", help="собранный образ (по умолчанию -- цель ~/.local/bin/claude)")
    ap.add_argument("--jobs", type=int, default=3, help="сколько мутаций мерить разом")
    ap.add_argument("--id", help="прогнать только названные строки таблицы (через запятую)")
    opts = ap.parse_args()

    # Код 2 «контракт вызова» -- тот же, которым соседи validate/adjudicate
    # отвергают --jobs < 1 (круг 28, F-10). Прежний молчаливый подъём
    # max(1, opts.jobs) означал, что объявленный параллелизм и настоящий --
    # разные числа (круг 26, K-14). Проверка стоит ДО поисков раннера и
    # образа: нарушенный контракт вызова не зависит от того, есть ли на
    # машине образ, и не должен занимать замок.
    if opts.jobs < 1:
        print("checks-teeth: --jobs должен быть не меньше 1", file=sys.stderr)
        return 2

    if not RUNNER.is_file():
        print("checks-teeth: нет tools/checks-on-image.sh -- мерить нечем", file=sys.stderr)
        return 6
    if shutil.which("bash") is None:
        print("checks-teeth: нет bash", file=sys.stderr)
        return 6

    image = Path(opts.image) if opts.image else default_image()
    if image is None or not image.is_file():
        print("checks-teeth: собранного образа на этой машине нет -- пропуск", file=sys.stderr)
        return 5

    # Замок берётся ДО первого чтения образа и держится до конца замера.
    # Круг 28, F-1: занятость (3) и поломку машинерии (6) нельзя отвечать
    # одним кодом -- свип на 3 ждёт держателя, которого при поломке нет.
    try:
        lock = hold_read_lock()
    except LockMachineryBroken as exc:
        print("checks-teeth: НЕ МЕРИЛИ -- машинерия замка сломана, повтор НЕ поможет "
              f"({exc})", file=sys.stderr)
        return 6
    if lock is None:
        print("checks-teeth: НЕ МЕРИЛИ -- замок конвейера держит живая сборка "
              f"({pipeline_lock_path()}); образ меняется под руками, повтор поможет",
              file=sys.stderr)
        return 3
    freed = weed_worker_leftovers()
    if freed:
        print(f"checks-teeth: убрано копий образа от убитых воркеров: {freed}", flush=True)

    try:
        rows = read_table()
    except Refusal as exc:
        print(f"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}", file=sys.stderr)
        return 2
    picked = None
    if opts.id:
        picked = {x.strip() for x in opts.id.split(",") if x.strip()}
        unknown = picked - {r["id"] for r in rows}
        if unknown:
            print(f"checks-teeth: ОТКАЗ ПРИБОРА -- нет таких строк: {sorted(unknown)}",
                  file=sys.stderr)
            return 2
    if len(rows) != EXPECTED_MUTATIONS:
        print(f"checks-teeth: ОТКАЗ -- мутаций {len(rows)}, объявлено {EXPECTED_MUTATIONS}",
              file=sys.stderr)
        return 4

    # Контроль: названный образ обязан быть ЗЕЛЁНЫМ до мутаций. Иначе краснота
    # ничего не докажет -- она была и без нас.
    try:
        red, _ = reds(image)
    except Refusal as exc:
        print(f"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}", file=sys.stderr)
        return 2
    if red:
        print("checks-teeth: КОНТРОЛЬ ПРОВАЛЕН -- образ красен ещё до мутаций:",
              file=sys.stderr)
        for name in red:
            print("    " + name, file=sys.stderr)
        return 2
    print(f"checks-teeth: КОНТРОЛЬ без мутации: ЗЕЛЁНО ({image})", flush=True)

    base = image.read_bytes()
    jobs = []
    try:
        for row in rows:
            if picked is not None and row["id"] not in picked:
                continue
            if row["kind"] == "derived":
                edits = DERIVED[row["id"]](base)
            elif row["kind"] == "literal":
                edits = edits_literal(base, row)
            else:
                raise Refusal(f"{row['id']}: неизвестный вид мутации {row['kind']}")
            want = {row["check"]}
            want |= {x.strip() for x in row["also"].split(";") if x.strip()}
            jobs.append((row["id"], row["check"], str(image), edits, sorted(want)))
    except Refusal as exc:
        print(f"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}", file=sys.stderr)
        return 2
    del base

    bad = 0
    try:
        with ProcessPoolExecutor(max_workers=opts.jobs) as pool:
            for mid, check, red, want in pool.map(run_one, jobs):
                if check not in red:
                    bad += 1
                    print(f"checks-teeth: МУТАЦИЯ {mid}: ПРОШЛА МОЛЧА -- «{check}» осталась зелёной",
                          flush=True)
                    if red:
                        print("    покраснели вместо неё: " + ", ".join(red), flush=True)
                elif sorted(red) != want:
                    bad += 1
                    others = [n for n in red if n not in want]
                    missing = [n for n in want if n not in red]
                    print(f"checks-teeth: МУТАЦИЯ {mid}: КРАСНЫЕ НЕ ТЕ, ЧТО ОБЪЯВЛЕНЫ -- "
                          + ("лишние: " + ", ".join(others) + " " if others else "")
                          + ("не покраснели: " + ", ".join(missing) if missing else ""), flush=True)
                else:
                    print(f"checks-teeth: МУТАЦИЯ {mid}: RED «{'» + «'.join(want)}»", flush=True)
    except BrokenProcessPool:
        # Воркер умер (SIGKILL/OOM): мутации НЕ ИЗМЕРЕНЫ. Класс 2, а не 1 --
        # по таблице инструмента 1 значит «мутация прошла молча», и свип
        # объявлял бы красным китом сломанный прибор.
        print("checks-teeth: НЕ МЕРИЛ -- воркер умер (SIGKILL/OOM), "
              "мутации не измерены", file=sys.stderr, flush=True)
        return 2
    print(f"checks-teeth: ИТОГ мутаций={len(jobs)} прошло молча/чужой дверью={bad}", flush=True)
    lock.close()                       # замок снимается ПОСЛЕ последнего замера
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
