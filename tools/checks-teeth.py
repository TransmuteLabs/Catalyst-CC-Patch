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
     либо КОНТРОЛЬ провален -- названный образ красен ещё до мутаций
  4  длина таблицы разошлась с объявленной (EXPECTED_MUTATIONS)
  5  мерить нечего: на этой машине нет собранного образа
  6  сломано окружение: нет bash или tools/checks-on-image.sh
"""

from __future__ import annotations

import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLE = ROOT / "tools" / "checks-mutations.tsv"
RUNNER = ROOT / "tools" / "checks-on-image.sh"
EXPECTED_MUTATIONS = 14
ID = rb"[A-Za-z_$][A-Za-z0-9_$]*"
# Приманка кладётся ЗАВЕДОМО вне окна (оно +-20000 байт в обе стороны): так мутация
# отличает сужение по окну от поиска по всему образу.
DECOY_BACK = 2_000_000


class Refusal(Exception):
    """Прибор не может мерить (класс 2)."""


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
    handle, path = tempfile.mkstemp(prefix="checks-teeth.", suffix=".bin")
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
    with ProcessPoolExecutor(max_workers=max(1, opts.jobs)) as pool:
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
    print(f"checks-teeth: ИТОГ мутаций={len(jobs)} прошло молча/чужой дверью={bad}", flush=True)
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
