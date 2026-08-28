#!/usr/bin/env python3
"""Герметичный стенд для compact.py и прополки временных лаунчеров.

Коды выхода (подмножество общей таблицы кита -- см. шапку claude-patch-all.sh):
  0  всё сошлось: каждая дверь на месте, каждая мутация покраснела свою
  1  дверь не сошлась, либо мутация прошла молча / покрасила чужую
  2  прибор не может мерить: контракт вызова (argparse) либо ПРИСТИННАЯ копия
     дерева уже красная -- контроль провален
  4  объявленное число не сходится с фактическим (EXPECTED_SCENARIOS,
     EXPECTED_MUTATIONS)
"""

from __future__ import annotations

import argparse
import gzip
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import ModuleType
from typing import Callable


# Импорт проверяемого модуля не должен оставлять артефакты в проверяемом дереве.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
COMPACT = ROOT / "judge" / "compact.py"
PATCHER = ROOT / "claude_patch.py"
BENCH = Path(__file__).resolve()
EXPECTED_SCENARIOS = 18
EXPECTED_MUTATIONS = 10
SUMMARY_RE = re.compile(
    r"сжато: (?P<done>\d+), пропущено: (?P<skipped>\d+), "
    r"исчезли под руками: (?P<vanished>\d+), "
    r"архив исчез после сжатия: (?P<gz_gone>\d+), "
    r"исходник исчез до замера: (?P<src_gone>\d+), "
    r"сирот tmp убрано: (?P<orphans>\d+), "
    r"освобождено: [-0-9.]+ МБ"
)


class BenchFailure(AssertionError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BenchFailure(message)


def dead_pid() -> int:
    # Суффикс обязан принадлежать реально завершившемуся процессу: случайное
    # число может оказаться живым pid и превратить проверку в гонку с машиной.
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    os.waitpid(pid, 0)
    return pid


def write_record(path: Path, marker: str) -> dict[str, object]:
    value: dict[str, object] = {"marker": marker, "items": [1, 2, 3]}
    path.write_text(json.dumps(value), encoding="utf-8")
    return value


def make_old(path: Path) -> None:
    stamp = time.time() - 3600
    os.utime(path, (stamp, stamp))


def write_archive(path: Path, value: dict[str, object]) -> None:
    with gzip.open(path, "wt", encoding="utf-8") as stream:
        json.dump(value, stream)


def read_archive(path: Path) -> object:
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        return json.load(stream)


def directory_snapshot(path: Path) -> tuple[tuple[str, int, int], ...]:
    return tuple(
        sorted(
            (entry.name, entry.lstat().st_size, entry.lstat().st_mtime_ns)
            for entry in path.iterdir()
        )
    )


def run_compact(
    directory: Path,
    *,
    older_than_hours: float = 0,
    dry_run: bool = False,
) -> tuple[dict[str, int], str]:
    command = [
        sys.executable,
        str(COMPACT),
        "--dir",
        str(directory),
        "--older-than-hours",
        str(older_than_hours),
    ]
    if dry_run:
        command.append("--dry-run")
    result = subprocess.run(command, capture_output=True, text=True)
    output = result.stdout + result.stderr
    require(result.returncode == 0, f"compact.py rc={result.returncode}\n{output}")
    matches = list(SUMMARY_RE.finditer(result.stdout))
    require(len(matches) == 1, f"итоговая строка compact.py не распознана\n{output}")
    counters = {name: int(value) for name, value in matches[0].groupdict().items()}
    return counters, output


def require_counters(counters: dict[str, int], **expected: int) -> None:
    for name, value in expected.items():
        require(
            counters[name] == value,
            f"счётчик {name}: ожидалось {value}, получено {counters[name]}; все={counters}",
        )


def scenario_1(outputs: list[dict[str, int]]) -> None:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        source = directory / "fresh.json"
        write_record(source, "fresh")
        before = source.read_bytes()
        counters, _ = run_compact(directory, older_than_hours=24)
        outputs.append(counters)
        require_counters(counters, skipped=1, vanished=0)
        require(source.read_bytes() == before, "свежая запись изменилась")
        require({p.name for p in directory.iterdir()} == {source.name}, "состав каталога изменился")


def scenario_2(outputs: list[dict[str, int]]) -> None:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        source = directory / "plain.json"
        value = write_record(source, "plain")
        make_old(source)
        counters, _ = run_compact(directory)
        outputs.append(counters)
        archive = Path(str(source) + ".gz")
        require_counters(counters, done=1, vanished=0)
        require({p.name for p in directory.iterdir()} == {archive.name}, "после сжатия остался неверный состав")
        require(read_archive(archive) == value, "архив не содержит исходный json")


def scenario_3(outputs: list[dict[str, int]]) -> None:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        source = directory / "complete.json"
        value = write_record(source, "complete")
        make_old(source)
        archive = Path(str(source) + ".gz")
        write_archive(archive, value)
        archive_before = archive.read_bytes()
        counters, _ = run_compact(directory)
        outputs.append(counters)
        require_counters(counters, done=1, vanished=0)
        require({p.name for p in directory.iterdir()} == {archive.name}, "исходник рядом с целым архивом не снят")
        require(archive.read_bytes() == archive_before, "целый соседний архив был переписан")
        require(read_archive(archive) == value, "целый соседний архив перестал читаться")


def scenario_4(outputs: list[dict[str, int]]) -> None:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        source = directory / "broken-neighbor.json"
        value = write_record(source, "broken-neighbor")
        make_old(source)
        archive = Path(str(source) + ".gz")
        archive.write_text("не gzip", encoding="utf-8")
        counters, _ = run_compact(directory)
        outputs.append(counters)
        require_counters(counters, done=1, vanished=0)
        require({p.name for p in directory.iterdir()} == {archive.name}, "пересжатие оставило лишние файлы")
        require(read_archive(archive) == value, "нечитаемый архив не заменён правильным json")


def setup_dry_case(directory: Path, variant: str) -> None:
    source = directory / f"{variant}.json"
    value = write_record(source, variant)
    make_old(source)
    archive = Path(str(source) + ".gz")
    if variant == "healthy-neighbor":
        write_archive(archive, value)
    elif variant == "broken-neighbor":
        archive.write_text("не gzip", encoding="utf-8")


def scenario_5(outputs: list[dict[str, int]]) -> None:
    for variant in ("no-archive", "healthy-neighbor", "broken-neighbor"):
        with tempfile.TemporaryDirectory() as live_raw, tempfile.TemporaryDirectory() as dry_raw:
            live_dir, dry_dir = Path(live_raw), Path(dry_raw)
            setup_dry_case(live_dir, variant)
            setup_dry_case(dry_dir, variant)
            live_counters, _ = run_compact(live_dir)
            before = directory_snapshot(dry_dir)
            dry_counters, _ = run_compact(dry_dir, dry_run=True)
            after = directory_snapshot(dry_dir)
            outputs.append(dry_counters)
            require(
                dry_counters["done"] == live_counters["done"],
                f"dry-run {variant}: сжато={dry_counters['done']}, боевой={live_counters['done']}",
            )
            require(before == after, f"dry-run {variant} изменил каталог: {before} -> {after}")
            require_counters(live_counters, vanished=0)
            require_counters(dry_counters, vanished=0)


def scenario_6(outputs: list[dict[str, int]]) -> None:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        source = directory / "invalid.json"
        source.write_text("не json", encoding="utf-8")
        make_old(source)
        before = source.read_bytes()
        counters, _ = run_compact(directory)
        outputs.append(counters)
        require_counters(counters, skipped=1, vanished=0)
        require(source.read_bytes() == before, "битый исходник изменился")
        require({p.name for p in directory.iterdir()} == {source.name}, "после битого json остался архив или tmp")


def scenario_7(outputs: list[dict[str, int]]) -> None:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        stale = directory / f"orphan.json.gz.tmp.{dead_pid()}"
        stale.write_text("tmp", encoding="utf-8")
        counters, _ = run_compact(directory)
        outputs.append(counters)
        require_counters(counters, orphans=1, vanished=0)
        require(not stale.exists(), "сирота tmp мёртвого pid не снята")


def scenario_8(outputs: list[dict[str, int]]) -> None:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        live = directory / f"live.json.gz.tmp.{os.getpid()}"
        live.write_text("tmp", encoding="utf-8")
        counters, _ = run_compact(directory)
        outputs.append(counters)
        require_counters(counters, orphans=0, vanished=0)
        require(live.exists(), "tmp живого процесса снят")


def scenario_9(outputs: list[dict[str, int]]) -> None:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        names = (
            "a.json.gz.tmp.12.34",
            "a.json.gz.tmp.²",
            "a.json.gz.tmp.99999999999999999999",
        )
        for name in names:
            (directory / name).write_text("tmp", encoding="utf-8")
        counters, _ = run_compact(directory)
        outputs.append(counters)
        require_counters(counters, orphans=0, vanished=0)
        require({p.name for p in directory.iterdir()} == set(names), "имя вне формы писателя было снято")


def scenario_10(outputs: list[dict[str, int]]) -> None:
    # Пустой список -- не «ложных исчезновений нет», а «мерить было нечего»:
    # такой сценарий проходит зелёным, ничего не проверив.
    require(bool(outputs), "нечего проверять: ни один сценарий не сдал счётчики")
    bad = [counters for counters in outputs if counters["vanished"] != 0]
    require(not bad, f"ложные исчезновения в сценариях compact.py: {bad}")


def import_patcher() -> ModuleType:
    spec = importlib.util.spec_from_file_location("judge_tools_bench_patcher", PATCHER)
    require(spec is not None and spec.loader is not None, f"не удалось создать spec для {PATCHER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_stale_link(path: Path, target: str = "target") -> None:
    path.symlink_to(target)


def scenario_11(module: ModuleType) -> None:
    with tempfile.TemporaryDirectory() as raw:
        link = Path(raw) / "claude"
        stale = link.with_name(f"claude.tmp.{dead_pid()}")
        make_stale_link(stale)
        module._sweep_stale_launcher_tmps(link)
        require(not stale.exists() and not stale.is_symlink(), "лаунчер tmp мёртвого pid не снят")


def scenario_12(module: ModuleType) -> None:
    with tempfile.TemporaryDirectory() as raw:
        link = Path(raw) / "claude"
        live = link.with_name(f"claude.tmp.{os.getpid()}")
        make_stale_link(live)
        module._sweep_stale_launcher_tmps(link)
        require(live.is_symlink(), "лаунчер tmp живого процесса снят")


def scenario_13(module: ModuleType) -> None:
    with tempfile.TemporaryDirectory() as raw:
        link = Path(raw) / "claude"
        names = ("claude.tmp.²", "claude.tmp.12.34", "claude.tmp.99999999999999999999")
        for name in names:
            make_stale_link(link.parent / name)
        module._sweep_stale_launcher_tmps(link)
        require(
            {p.name for p in link.parent.iterdir()} == set(names),
            "прополка лаунчера сняла имя вне формы писателя",
        )


def scenario_14(module: ModuleType) -> None:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        link = directory / "claude"
        stale = link.with_name(f"claude.tmp.{dead_pid()}")
        make_stale_link(stale, "old-target")
        old_inode = stale.lstat().st_ino
        original_kill = module.os.kill

        def replace_then_report_dead(pid: int, signal: int) -> None:
            del pid, signal
            stale.unlink()
            # Занимаем освобождённый inode до создания замены: сценарий обязан
            # проверять именно подмену записи, а не совпавший номер inode.
            (directory / "inode-holder").write_text("holder", encoding="utf-8")
            make_stale_link(stale, "new-target")
            require(stale.lstat().st_ino != old_inode, "файловая система повторно выдала тот же inode")
            raise ProcessLookupError

        module.os.kill = replace_then_report_dead
        try:
            module._sweep_stale_launcher_tmps(link)
        finally:
            module.os.kill = original_kill
        require(stale.is_symlink(), "новая ссылка снята после подмены")
        require(os.readlink(stale) == "new-target", "после подмены сохранилась не новая ссылка")


def _foreign_live_pid() -> int:
    """pid ЖИВОГО процесса чужого пользователя.

    pid 1 принадлежит root: для обычного пользователя os.kill(1, 0) даёт
    PermissionError -- ровно ту ветку, которая отличает «жив, но не наш» от
    «мёртв». Под root эта ветка недостижима, и сценарий обязан сказать это
    вслух, а не молча пройти: молчаливый пропуск выглядел бы как покрытие.
    """
    require(os.geteuid() != 0, "стенд запущен от root: ветку чужого живого pid не отличить")
    return 1


def scenario_15(module: ModuleType) -> None:
    """Прополка лаунчера не трогает запись ЖИВОГО чужого процесса."""
    with tempfile.TemporaryDirectory() as raw:
        link = Path(raw) / "claude"
        foreign = link.with_name(f"claude.tmp.{_foreign_live_pid()}")
        make_stale_link(foreign)
        module._sweep_stale_launcher_tmps(link)
        require(foreign.is_symlink(), "снята запись живого процесса чужого пользователя")


def scenario_16(outputs: list[dict[str, int]]) -> None:
    """То же в прополке compact.py: чужой живой pid -- не сирота."""
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        foreign = directory / f"x.json.gz.tmp.{_foreign_live_pid()}"
        foreign.write_text("tmp", encoding="utf-8")
        counters, _ = run_compact(directory)
        outputs.append(counters)
        require_counters(counters, orphans=0)
        require(foreign.exists(), "снят tmp живого процесса чужого пользователя")


# Две ветки ниже -- ГОНКИ: файл обязан исчезнуть между exists() и open() либо
# между getsize() и unlink(). Снаружи процесса такое состояние детерминированно
# не создать, поэтому здесь пинится ФОРМА кода: сценарий читает исходник и
# требует, чтобы ветка вела себя так, как решено. Это слабее прогона, но
# сильнее, чем ничего: возврат прежнего поведения краснит стенд.
def scenario_17() -> None:
    """Пропавший архив ведёт к пересжатию, а не к «исчезло под руками»."""
    text = COMPACT.read_text(encoding="utf-8")
    anchor = "            try:\n                with gzip.open(gz, 'rt', encoding='utf-8') as fh:"
    start = text.find(anchor)
    require(start >= 0, "ветка доведения оборванного сжатия не найдена по якорю")
    arm = text[start:text.find("except Exception as e:", start)]
    require("recompress = True" in arm, "ветка FileNotFoundError больше не ведёт к пересжатию")
    require("vanished" not in arm, "ветка FileNotFoundError снова считает «исчезло под руками»")


def scenario_18() -> None:
    """Исходник, пропавший до замера, не отменяет достигнутую цель."""
    text = COMPACT.read_text(encoding="utf-8")
    start = text.find("                except FileNotFoundError:\n                    before = None")
    require(start >= 0, "ветка «размер исходника неизвестен» не найдена")
    arm = text[start:start + 700]
    require("done += 1" in arm, "done больше не считается, когда исходник исчез до замера")
    require("src_gone += 1" in arm, "исчезнувший до замера исходник снова не имеет своего счётчика")
    require("vanished" not in arm.split("print(")[0], "ветка снова считает «исчезло под руками»")


def run_scenarios() -> int:
    outputs: list[dict[str, int]] = []
    module = import_patcher()
    cases: list[tuple[int, Callable[[], None]]] = [
        (1, lambda: scenario_1(outputs)),
        (2, lambda: scenario_2(outputs)),
        (3, lambda: scenario_3(outputs)),
        (4, lambda: scenario_4(outputs)),
        (5, lambda: scenario_5(outputs)),
        (6, lambda: scenario_6(outputs)),
        (7, lambda: scenario_7(outputs)),
        (8, lambda: scenario_8(outputs)),
        (9, lambda: scenario_9(outputs)),
        (10, lambda: scenario_10(outputs)),
        (11, lambda: scenario_11(module)),
        (12, lambda: scenario_12(module)),
        (13, lambda: scenario_13(module)),
        (14, lambda: scenario_14(module)),
        (15, lambda: scenario_15(module)),
        (16, lambda: scenario_16(outputs)),
        (17, scenario_17),
        (18, scenario_18),
    ]
    mismatches = 0
    for number, case in cases:
        try:
            case()
        except Exception as error:
            mismatches += 1
            print(f"judge-tools-bench: СЦЕНАРИЙ {number}: FAIL: {error}")
        else:
            print(f"judge-tools-bench: СЦЕНАРИЙ {number}: OK")
    print(f"judge-tools-bench: ИТОГ сценариев={len(cases)} расхождений={mismatches}")
    if len(cases) != EXPECTED_SCENARIOS:
        # Тот же класс, что и длина таблицы мутаций: объявленное число не
        # сходится с фактическим. Прежде уезжало кодом 1 -- «сценарий не
        # сошёлся», хотя ни один сценарий не при чём (раунд 19, A-8).
        print(f"judge-tools-bench: ОТКАЗ -- сценариев {len(cases)}, объявлено "
              f"{EXPECTED_SCENARIOS}")
        return 4
    return 0 if mismatches == 0 else 1


def replace_once(path: Path, old: str, new: str, mutation: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    require(count == 1, f"{mutation}: якорь встретился {count} раз в {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def mutation_m1(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "                done += 1\n                if before is None:\n",
        "                skipped += 1\n                if before is None:\n",
        "M1",
    )


def mutation_m2(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "                    print(f'удалил бы исходник (архив рядом целый): {os.path.basename(f)}')\n"
        "                    done += 1\n                    continue\n",
        "                    print(f'удалил бы исходник (архив рядом целый): {os.path.basename(f)}')\n"
        "                    skipped += 1\n                    continue\n",
        "M2",
    )


def mutation_m3(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "        if not tmp_form.search(t):\n            continue\n",
        "",
        "M3",
    )


def mutation_m4(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "        except (PermissionError, OverflowError, ValueError):\n",
        "        except PermissionError:\n",
        "M4",
    )


def mutation_m5(root: Path) -> None:
    replace_once(
        root / "claude_patch.py",
        "        if not form.match(stale.name):\n",
        "        if False:\n",
        "M5",
    )


def mutation_m6(root: Path) -> None:
    replace_once(
        root / "claude_patch.py",
        "        if (after.st_ino, after.st_mtime_ns) != (before.st_ino, before.st_mtime_ns):\n"
        "            continue                   # запись подменена после проверки\n",
        "",
        "M6",
    )


# M7-M10 добавлены контроллером: первые шесть мутаций (docnum:historical) не
# краснили ни одного из четырёх свойств ниже -- стенд их просто не покрывал. Каждая мутация здесь
# ВОСПРОИЗВОДИТ дефект, который волна 15 чинила, а не просто ломает код.
def mutation_m7(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "            except FileNotFoundError:\n                recompress = True",
        "            except FileNotFoundError:\n                vanished += 1; continue",
        "M7",
    )


def mutation_m8(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "                if before is None:\n                    src_gone += 1",
        "                if before is None:\n                    done -= 1; vanished += 1",
        "M8",
    )


def mutation_m9(root: Path) -> None:
    replace_once(
        root / "claude_patch.py",
        "        except PermissionError:\n            continue                   # жив, под другим пользователем",
        "        except PermissionError:\n            pass                       # жив, под другим пользователем",
        "M9",
    )


def mutation_m10(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "        except (PermissionError, OverflowError, ValueError):\n            continue",
        "        except (OverflowError, ValueError):\n            continue",
        "M10",
    )


# Каждая мутация обязана покраснить СВОЙ сценарий СВОЕЙ причиной. Голый
# `rc == 1` этого не доказывает: тот же код даёт необработанное исключение
# внутри копии стенда и мутация, свалившая ЧУЖУЮ дверь. Сценарий и причина
# ниже -- измеренные, а не назначенные: прогон каждой из них показывает
# именно эту строку (раунд 18, E-1).
MUTATIONS: list[tuple[str, Callable[[Path], None], int, str]] = [
    ("M1", mutation_m1, 3, "счётчик done: ожидалось 1, получено 0"),
    ("M2", mutation_m2, 5, "dry-run healthy-neighbor: сжато=0, боевой=1"),
    ("M3", mutation_m3, 9, "счётчик orphans: ожидалось 0, получено 1"),
    ("M4", mutation_m4, 9, "OverflowError"),
    ("M5", mutation_m5, 13, "прополка лаунчера сняла имя вне формы писателя"),
    ("M6", mutation_m6, 14, "новая ссылка снята после подмены"),
    ("M7", mutation_m7, 17, "ветка FileNotFoundError больше не ведёт к пересжатию"),
    ("M8", mutation_m8, 18, "исчезнувший до замера исходник снова не имеет своего счётчика"),
    ("M9", mutation_m9, 15, "снята запись живого процесса чужого пользователя"),
    ("M10", mutation_m10, 16, "PermissionError"),
]


def fail_segment(output: str, scenario: int) -> str | None:
    """Текст провала ИМЕННО этого сценария (сообщение бывает многострочным)."""
    head = f"judge-tools-bench: СЦЕНАРИЙ {scenario}: FAIL:"
    start = output.find(head)
    if start < 0:
        return None
    rest = output[start + len(head):]
    end = rest.find("judge-tools-bench: ")
    return rest if end < 0 else rest[:end]


def copy_tree(root: Path) -> None:
    (root / "judge").mkdir()
    (root / "tools").mkdir()
    shutil.copy2(COMPACT, root / "judge" / "compact.py")
    shutil.copy2(PATCHER, root / "claude_patch.py")
    shutil.copy2(BENCH, root / "tools" / "judge-tools-bench.py")


def run_copy(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(root / "tools" / "judge-tools-bench.py")],
        cwd=root,
        capture_output=True,
        text=True,
    )


def run_self_check() -> int:
    # Контроль: пристинная копия дерева обязана быть зелёной. Иначе краснеет
    # что угодно, и каждая мутация «подтвердится» чужим отказом.
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        copy_tree(root)
        control = run_copy(root)
        if control.returncode != 0:
            print(
                "judge-tools-bench: КОНТРОЛЬ ПРОВАЛЕН -- пристинная копия уже "
                f"красная (rc={control.returncode}); мутации ничего не докажут\n"
                f"{control.stdout}{control.stderr}"
            )
            # Класс 2 («ничего не измерено»), а не 3: тройка в таблице кита
            # значит «занят замок, повторить позже» (раунд 19, A-4).
            return 2
    print("judge-tools-bench: КОНТРОЛЬ без мутации: ЗЕЛЁНО")

    mutations = MUTATIONS
    reddened = 0
    for name, mutate, scenario, cause in mutations:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            copy_tree(root)
            try:
                mutate(root)
            except Exception as error:
                print(f"judge-tools-bench: МУТАЦИЯ {name}: FAIL: {error}")
                continue
            result = run_copy(root)
            output = result.stdout + result.stderr
            segment = fail_segment(output, scenario)
            if result.returncode != 1:
                print(
                    f"judge-tools-bench: МУТАЦИЯ {name}: FAIL: ожидался rc=1, "
                    f"получен rc={result.returncode}\n{output}"
                )
            elif segment is None:
                print(
                    f"judge-tools-bench: МУТАЦИЯ {name}: КРАСНАЯ НЕ ТОЙ ДВЕРЬЮ: "
                    f"сценарий {scenario} не упал\n{output}"
                )
            elif cause not in segment:
                print(
                    f"judge-tools-bench: МУТАЦИЯ {name}: КРАСНАЯ НЕ ПО ТОЙ ПРИЧИНЕ "
                    f"(нет «{cause}» в провале сценария {scenario}):\n{segment}"
                )
            else:
                reddened += 1
                print(f"judge-tools-bench: МУТАЦИЯ {name}: RED (сценарий {scenario})")
    print(
        f"judge-tools-bench: SELF-CHECK мутаций={len(mutations)} "
        f"покраснели={reddened}"
    )
    if len(mutations) != EXPECTED_MUTATIONS:
        print(
            f"judge-tools-bench: ОТКАЗ -- мутаций {len(mutations)}, "
            f"объявлено {EXPECTED_MUTATIONS}"
        )
        return 4
    return 0 if reddened == len(mutations) else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-check", action="store_true")
    args = parser.parse_args()
    return run_self_check() if args.self_check else run_scenarios()


if __name__ == "__main__":
    sys.exit(main())
