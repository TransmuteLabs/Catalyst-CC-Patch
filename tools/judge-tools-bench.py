#!/usr/bin/env python3
"""Герметичный стенд инструментов кита: compact.py и прополка временных
лаунчеров, сверка раскатки, загрузка образа, бэкап конфига цен, форма отчёта
стенда проб.

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
import io
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Callable


# Импорт проверяемого модуля не должен оставлять артефакты в проверяемом дереве.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
COMPACT = ROOT / "judge" / "compact.py"
PATCHER = ROOT / "claude_patch.py"
BENCH = Path(__file__).resolve()
EXPECTED_SCENARIOS = 34
EXPECTED_MUTATIONS = 30
SUMMARY_RE = re.compile(
    r"сжато: (?P<done>\d+), пропущено: (?P<skipped>\d+), "
    r"исчезли под руками: (?P<vanished>\d+), "
    r"архив исчез после сжатия: (?P<gz_gone>\d+), "
    r"исходник исчез до замера: (?P<src_gone>\d+), "
    r"сирот tmp убрано: (?P<orphans>\d+), "
    r"tmp при живом pid: (?P<tmp_held>\d+), "
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
        # Хвост имени -- ЗАВЕДОМО мёртвый pid. Со случайным хвостом покраснение
        # мутации, снимающей проверку формы, зависело от того, жив ли процесс с
        # таким номером на чужой машине -- ровно та гонка, которую стенд себе
        # запретил (круг 20, D-7).
        names = (
            f"a.json.gz.tmp.12.{dead_pid()}",
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
        names = ("claude.tmp.²", f"claude.tmp.12.{dead_pid()}",
                 "claude.tmp.99999999999999999999")
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


def sync_diff(root: Path, home: Path, tools: Path, agents: Path) -> tuple[int, str]:
    """Прогон scripts/probes-sync.sh --diff на игрушечных домах."""
    env = dict(os.environ)
    env["CLAUDE_PROBES_DIR"] = str(home)
    env["CLAUDE_JUDGE_TOOLS_DIR"] = str(tools)
    env["CLAUDE_LAUNCH_AGENTS_DIR"] = str(agents)
    done = subprocess.run(
        ["bash", str(root / "scripts" / "probes-sync.sh"), "--diff"],
        capture_output=True, text=True, env=env,
    )
    return done.returncode, done.stdout + done.stderr


def scenario_19() -> None:
    """Сверка раскатки отвечает КЛАССОМ: нет дома, дрейф, неполнота, чужой агент."""
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        home, tools, agents = base / "p", base / "t", base / "la"
        agents.mkdir()

        rc, out = sync_diff(ROOT, home, tools, agents)
        require(rc == 5, f"пустая машина обязана давать «мерить нечего» (5), а дала {rc}")
        require("не раскатан" in out, "пустая машина не названа классом «не раскатан»")

        env = dict(os.environ)
        env.update(CLAUDE_PROBES_DIR=str(home), CLAUDE_JUDGE_TOOLS_DIR=str(tools),
                   CLAUDE_LAUNCH_AGENTS_DIR=str(agents))
        done = subprocess.run(
            ["bash", str(ROOT / "scripts" / "probes-sync.sh"), "--to-home"],
            capture_output=True, text=True, env=env,
        )
        require(done.returncode == 0, f"раскатка в игрушечный дом провалилась: {done.stderr}")

        rc, out = sync_diff(ROOT, home, tools, agents)
        require(rc == 0, f"сошедшийся дом обязан давать 0, а дал {rc}: {out}")

        # дрейф: файл есть, байты другие
        drifted = tools / "compact.py"
        drifted.write_text(drifted.read_text(encoding="utf-8") + "# дрейф\n", encoding="utf-8")
        rc, out = sync_diff(ROOT, home, tools, agents)
        require(rc == 1, f"дрейф обязан краснить (1), а дал {rc}")
        require("расходится: judge/compact.py" in out, "дрейф не назван по имени файла")
        shutil.copy2(ROOT / "judge" / "compact.py", drifted)

        # неполнота: файла нет вовсе, но дом заведён
        (tools / "replay.py").unlink()
        rc, out = sync_diff(ROOT, home, tools, agents)
        require(rc == 1, f"неполная раскатка обязана краснить (1), а дала {rc}")
        require("раскатка неполная" in out, "неполнота не названа своим классом")
        shutil.copy2(ROOT / "judge" / "replay.py", tools / "replay.py")

        # заведённый агент показывает НЕ на раскатанный инструмент
        sample = (ROOT / "judge" / "com.transmutelabs.judge-compact.plist").read_text(
            encoding="utf-8")
        stray = agents / "com.stray.judge-compact.plist"
        stray.write_text(
            sample.replace("/Users/YOUR-USER/.claude/judge", "/gone/elsewhere"),
            encoding="utf-8")
        rc, out = sync_diff(ROOT, home, tools, agents)
        require(rc == 1, f"агент мимо раскатки обязан краснить (1), а дал {rc}")
        require("агент com.stray.judge-compact.plist запускает НЕ" in out,
                "чужая цель агента не названа")

        stray.write_text(sample.replace("/Users/YOUR-USER/.claude/judge", str(tools)),
                         encoding="utf-8")
        rc, out = sync_diff(ROOT, home, tools, agents)
        require(rc == 0, f"агент, показывающий на раскатку, не должен краснить, а дал {rc}: {out}")


def scenario_20() -> None:
    """Гейт конвейера зовёт сверку и снимает тест-ручки домов.

    Свойство ФОРМЫ: сам стенд исполняет копию кита, а гейт живёт в конвейере,
    который стенд не запускает. Пин по тексту -- объявленная замена прогону.
    """
    text = (ROOT / "claude-patch-all.sh").read_text(encoding="utf-8")
    call = text.find("scripts/probes-sync.sh\" --diff")
    require(call >= 0, "конвейер не зовёт probes-sync.sh --diff")
    head = text[max(0, call - 400):call]
    require("env -u CLAUDE_JUDGE" + "_TOOLS_DIR" in head,
            "гейт не снимает тест-ручку дома инструментов")
    require("env -u CLAUDE_JUDGE_TOOLS_DIR -u CLAUDE_LAUNCH" + "_AGENTS_DIR" in head,
            "гейт не снимает тест-ручку каталога агентов")
    tail = text[call:call + 700]
    require("5)" in tail and "пропуск" in tail,
            "гейт не отличает «раскатки нет» от расхождения")



def import_tool(name: str) -> ModuleType:
    """Импорт одного из judge/*.py из ТОГО ЖЕ дерева, что меряет стенд."""
    path = ROOT / "judge" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"judge_tools_bench_{name}", path)
    require(spec is not None and spec.loader is not None, f"не удалось создать spec для {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def seeded_replay(vocab: dict[str, tuple[list[str], list[str]]]) -> tuple[ModuleType, str]:
    """replay с ПОДСТАВЛЕННЫМ словарём: стенд герметичен и образа не читает."""
    module = import_tool("replay")
    handle, path = tempfile.mkstemp(prefix="judge-bench-image.")
    os.close(handle)
    real = os.path.realpath(path)
    for probe, values in vocab.items():
        module._VOCAB_CACHE[(real, probe)] = values
    os.environ["CLAUDE_JUDGE_IMAGE"] = real
    return module, path


def scenario_21() -> None:
    """Разметка вердикта повторяет ОБРАЗ: двоеточие обязательно, регистр не важен."""
    module, image = seeded_replay({"judge": (["OK", "BLOCK", "WARN"], ["BLOCK"])})
    try:
        require(module.klass("OKAY, данных не хватает") == "EMPTY",
                "слово без двоеточия снова классифицируется как вердикт")
        require(module.klass("ok: причина") == "OK",
                "строчный вердикт не разобран либо возвращён не в каноне словаря")
        require(module.verdict_of("свободный текст модели") == "",
                "текст без строки вердикта снова выдаётся за вердикт")
        raw = '{"choices":[{"message":{"content":"ok: всё в порядке"}}]}'
        require(module.verdict_of(raw) == "ok: всё в порядке", "вердикт из содержимого потерян")
    finally:
        os.unlink(image)
        os.environ.pop("CLAUDE_JUDGE_IMAGE", None)


def scenario_22() -> None:
    """Идентичность пробы протянута: словарь чужой пробы не размечает записи."""
    module, image = seeded_replay({
        "judge": (["OK", "BLOCK"], ["BLOCK"]),
        "idle-watch": (["ASK", "SKIP"], ["ASK"]),
    })
    try:
        require(module.klass("ask: пора спросить", "idle-watch") == "ASK",
                "словарь пробы не применён")
        require(module.klass("ask: пора спросить") == "EMPTY",
                "судейский словарь принял чужой класс")
        helped = subprocess.run([sys.executable, str(ROOT / "judge" / "replay.py"), "--help"],
                                capture_output=True, text=True)
        require("--probe" in helped.stdout, "у replay.py нет аргумента --probe")

        adj = import_tool("adjudicate")
        adj.replay._VOCAB_CACHE.update(module._VOCAB_CACHE)
        prompt = adj.load_vocabulary(image, "idle-watch")
        require("ASK" in prompt and "BLOCK" not in prompt,
                "промт адъюдикатора не перерисован под словарь пробы")

        text = (ROOT / "judge" / "validate.py").read_text(encoding="utf-8")
        # Свойство ФОРМЫ: путь метрик тянет за собой сеть и записи, поэтому
        # проба здесь пинится текстом вызова, и это объявлено.
        require("replay.verdict_of(sent['raw'], PROBE_ID)" in text
                and "replay.klass(verdict, PROBE_ID)" in text,
                "validate размечает записи судейским словарём независимо от --probe")
    finally:
        os.unlink(image)
        os.environ.pop("CLAUDE_JUDGE_IMAGE", None)


def scenario_23() -> None:
    """adjudicate импортируется на машине БЕЗ образа: словарь читается в main."""
    env = dict(os.environ, CLAUDE_JUDGE_IMAGE="/nonexistent/claude-image")
    done = subprocess.run([sys.executable, "-c", "import adjudicate"],
                          cwd=str(ROOT / "judge"), capture_output=True, text=True, env=env)
    require(done.returncode == 0,
            f"импорт adjudicate требует образа: {(done.stderr or '').strip()[:200]}")


def scenario_24() -> None:
    """Полоса pool ОБЪЯВЛЯЕТ бюджет, который не умеет применить."""
    module = import_tool("channel")
    payload = json.dumps({"result": "ok: да", "total_cost_usd": 0.01})

    class Fake:
        returncode = 0
        stdout = payload
        stderr = ""

    original = module.subprocess.run
    module.subprocess.run = lambda *a, **k: Fake()
    try:
        got = module.send("s", "u", "claude-x", effort=None, max_tokens=1234,
                          channel="pool", url=None, timeout=5, body_template=None)
        require(any("max_tokens=1234" in n for n in got.get("notes", [])),
                "потолок вывода уронен молча")
        bare = module.send("s", "u", "claude-x", effort=None, max_tokens=None,
                           channel="pool", url=None, timeout=5, body_template=None)
        require(bare.get("notes") == [], "объявление появилось там, где ронять было нечего")
    finally:
        module.subprocess.run = original


def scenario_25() -> None:
    """Метка истины нормализуется так же, как класс ответа (BLOCK/STOP/DENY)."""
    module = import_tool("validate")
    module.ACT_VALUES = ["BLOCK", "STOP", "DENY"]
    rows = [{
        "rec": "r1", "model": "m", "effort": None, "rep": 1, "klass": "OK",
        "verdict": "ok: да", "via": "http", "ms": 10, "http": 200, "cost_usd": None,
        "error": None, "truth": "STOP", "truth_human": "STOP", "truth_model": None,
        "layer": None, "cfg": None, "tokens_in": None, "tokens_out": None,
        "layer_missing": False, "url_from": "record", "notes": [],
    }]
    buffer = io.StringIO()
    stdout = sys.stdout
    sys.stdout = buffer
    try:
        module.print_summary(rows)
    finally:
        sys.stdout = stdout
    out = buffer.getvalue()
    require("пропусков 1" in out,
            "метка STOP не засчитана как отмена -- точность завышается молча:\n" + out[-400:])


def scenario_26() -> None:
    """--dry-run не снимает сироту tmp -- он вообще ничего не пишет."""
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        orphan = directory / f"a.json.gz.tmp.{dead_pid()}"
        orphan.write_text("tmp", encoding="utf-8")
        counters, _ = run_compact(directory, dry_run=True)
        require(orphan.exists(), "dry-run СНЁС сироту tmp")
        require(counters["orphans"] == 1, "dry-run не назвал сироту, которую снял бы")
        counters, _ = run_compact(directory)
        require(not orphan.exists(), "боевой прогон сироту не снял")


def scenario_27() -> None:
    """Ветки гонок прополки пинятся ФОРМОЙ: стенд гоняет compact.py сабпроцессом.

    Подменить файл между `os.stat` и `os.unlink` внутри чужого процесса стенду
    нечем -- приём с monkeypatch достаёт только до claude_patch.py. Поэтому
    свойство пинится текстом, и это объявлено (тот же приём, что у сценариев
    17-18): исчезнувшее свойство краснит стенд, даже если исполнить его нельзя.
    """
    text = (ROOT / "judge" / "compact.py").read_text(encoding="utf-8")
    require("if (after.st_ino, after.st_mtime_ns) != (before.st_ino, before.st_mtime_ns):"
            in text, "сверка подмены сироты между замером и снятием пропала")
    require(text.count("except FileNotFoundError:") >= 4,
            "ветки исчезновения файла под руками схлопнулись")
    require("исходник исчез" in text or "src_gone" in text,
            "счётчик исчезнувшего до замера исходника пропал")


def toy_kit(base: Path) -> Path:
    """Игрушечная копия кита: раскатку надо ЛОМАТЬ, а живой кит трогать нельзя.

    Копируется ровно то, что читает scripts/probes-sync.sh, и копируется ИЗ
    ROOT -- то есть из дерева, которое правит мутация. Иначе зуб применился бы
    к копии, а сценарий мерил бы живой кит (круг 18, §6).
    """
    kit = base / "kit"
    (kit / "scripts").mkdir(parents=True)
    (kit / "judge").mkdir()
    shutil.copy2(ROOT / "scripts" / "probes-sync.sh", kit / "scripts" / "probes-sync.sh")
    for name in ("replay.py", "compact.py", "validate.py", "channel.py",
                 "adjudicate.py", "README.md", "com.transmutelabs.judge-compact.plist"):
        shutil.copy2(ROOT / "judge" / name, kit / "judge" / name)
    for rel in ("probes.toml", "judge/prompt.md", "judge/body.json",
                "idle-watch/prompt.md"):
        dst = kit / "probes" / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "probes" / rel, dst)
    return kit


def run_sync(kit: Path, mode: str, home: Path, tools: Path, agents: Path,
             fake_home: Path | None = None) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env.update(CLAUDE_PROBES_DIR=str(home), CLAUDE_JUDGE_TOOLS_DIR=str(tools),
               CLAUDE_LAUNCH_AGENTS_DIR=str(agents))
    if fake_home is not None:
        env["HOME"] = str(fake_home)
    return subprocess.run(["bash", str(kit / "scripts" / "probes-sync.sh"), mode],
                          capture_output=True, text=True, env=env)


def home_bytes(home: Path, tools: Path) -> dict[Path, bytes]:
    out: dict[Path, bytes] = {}
    for base in (home, tools):
        for item in sorted(base.rglob("*")):
            if item.is_file():
                out[item] = item.read_bytes()
    return out


def scenario_28() -> None:
    """Раскатка ставится НАБОРОМ и не сталкивается со стадией чужого прогона."""
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        kit = toy_kit(base)
        home, tools, agents = base / "p", base / "t", base / "la"
        agents.mkdir()

        done = run_sync(kit, "--to-home", home, tools, agents)
        require(done.returncode == 0, f"раскатка в игрушечный дом провалилась: {done.stderr}")
        before = home_bytes(home, tools)
        require(len(before) == 10, f"в доме {len(before)} файлов, ожидалось 10")

        # Пропал ОДИН исходник -- дом не трогается ВООБЩЕ. Правка prompt.md
        # делает «тронут» наблюдаемым: без неё дом совпал бы с собой и на
        # пофайловой раскатке.
        (kit / "judge" / "replay.py").unlink()
        (kit / "probes" / "judge" / "prompt.md").write_text(
            "раскатка следующей волны\n", encoding="utf-8")
        done = run_sync(kit, "--to-home", home, tools, agents)
        out = done.stdout + done.stderr
        require(done.returncode == 1,
                f"неполный набор обязан краснить (1), а дал {done.returncode}: {out}")
        require(home_bytes(home, tools) == before,
                "дом ТРОНУТ на неполном наборе -- раскатка идёт не всё-или-ничего")
        require("не перенесено НИЧЕГО" in out, "отказ по неполному набору не назван своим текстом")

        # Стадия чужого прогона под фиксированным именем обязана уцелеть.
        shutil.copy2(ROOT / "judge" / "replay.py", kit / "judge" / "replay.py")
        stray = tools / "compact.py.sync-new"
        stray.write_bytes(b"stage of another run\n")
        done = run_sync(kit, "--to-home", home, tools, agents)
        require(done.returncode == 0, f"раскатка провалилась: {done.stderr}")
        require(stray.is_file() and stray.read_bytes() == b"stage of another run\n",
                "стадия чужого прогона снесена -- временное имя не несёт pid")
        require((home / "judge" / "prompt.md").read_text(encoding="utf-8")
                == "раскатка следующей волны\n", "полный набор так и не доехал до дома")


def scenario_29() -> None:
    """plist едет в ОБЪЯВЛЕННЫЙ каталог агентов, а не в $HOME живой машины."""
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        kit = toy_kit(base)
        home, tools, agents = base / "p", base / "t", base / "la"
        agents.mkdir()
        fake = base / "fakehome"
        (fake / "Library" / "LaunchAgents").mkdir(parents=True)

        # В каноне plist -- ОБРАЗЕЦ с плейсхолдерами и не раскатывается вовсе;
        # ручку видно только на заполненном.
        pl = kit / "judge" / "com.transmutelabs.judge-compact.plist"
        pl.write_text(pl.read_text(encoding="utf-8").replace("/Users/YOUR-USER", str(fake)),
                      encoding="utf-8")
        done = run_sync(kit, "--to-home", home, tools, agents, fake_home=fake)
        require(done.returncode == 0, f"раскатка с заполненным plist провалилась: {done.stderr}")
        require(not (fake / "Library" / "LaunchAgents"
                     / "com.transmutelabs.judge-compact.plist").exists(),
                "plist ушёл мимо объявленной ручки -- в $HOME")
        require((agents / "com.transmutelabs.judge-compact.plist").is_file(),
                "plist не лёг в объявленный каталог агентов")
        require("launchctl" in done.stdout,
                "раскатанный plist не объявил, что нужен bootout+bootstrap")


class FakeResponse:
    """Ответ реестра без сети: стенд герметичен."""

    def __init__(self, blob: bytes) -> None:
        self.blob = blob

    def read(self) -> bytes:
        return self.blob

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_: object) -> bool:
        return False


def fake_tarball(member: str, payload: bytes) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        entry = tarfile.TarInfo(member)
        entry.size = len(payload)
        tf.addfile(entry, io.BytesIO(payload))
    return buf.getvalue()


def scenario_30(module: ModuleType) -> None:
    """Загрузка не идёт через конечное имя и не оставляет обломков."""
    payload = b"PRISTINE IMAGE" * 64
    blob = fake_tarball("package/claude", payload)
    saved = (module.npm_platform_pkg, module.binary_name, module.http_json,
             module._verify_tarball, module.urllib, module.shutil)
    try:
        module.npm_platform_pkg = lambda: "pkg"
        module.binary_name = lambda: "claude"
        module.http_json = lambda url: {"dist": {"tarball": "http://example.invalid/t"}}
        module._verify_tarball = lambda _b, _d, _w: None
        module.urllib = SimpleNamespace(
            request=SimpleNamespace(urlopen=lambda *_a, **_k: FakeResponse(blob)))

        with tempfile.TemporaryDirectory() as raw:
            vdir = Path(raw)
            dest = vdir / "2.1.250"
            module.download_binary("2.1.250", dest)
            require(dest.read_bytes() == payload, "образ лёг не теми байтами")
            require(not list(vdir.glob("*.download")), "обломок загрузки остался после успеха")

            # Оборванная распаковка: установка не тронута, обломок убран.
            dest.write_bytes(b"OLD INSTALL")

            def torn(_src: object, _dst: object) -> None:
                raise RuntimeError("обрыв посреди распаковки")

            module.shutil = SimpleNamespace(copyfileobj=torn)
            try:
                module.download_binary("2.1.250", dest)
            except RuntimeError:
                pass
            else:
                require(False, "оборванная загрузка не подняла ошибку")
            # Читается защищённо: когда временное имя СОВПАДАЕТ с конечным,
            # уборка обломка сносит саму установку, и голый read_bytes() упал бы
            # сырым OSError -- стенд покраснел бы, но НЕ назвал бы свойство.
            after = dest.read_bytes() if dest.exists() else b"<install deleted>"
            require(after == b"OLD INSTALL",
                    "оборванная загрузка перезаписала установку")
            require(not list(vdir.glob("*.download")),
                    "обломок оборванной загрузки не убран")
    finally:
        (module.npm_platform_pkg, module.binary_name, module.http_json,
         module._verify_tarball, module.urllib, module.shutil) = saved


def import_costs() -> ModuleType:
    """set-model-costs.py из ТОГО ЖЕ дерева, что меряет стенд."""
    path = ROOT / "set-model-costs.py"
    spec = importlib.util.spec_from_file_location("judge_tools_bench_costs", path)
    require(spec is not None and spec.loader is not None, f"не удалось создать spec для {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def scenario_31() -> None:
    """Бэкап конфига есть либо целиком, либо никак, и стадия не в семье бэкапов."""
    module = import_costs()
    real_shutil = module.shutil
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        cfg = home / "cfg.json"
        module.write_json_atomically(str(cfg), {"customModelCosts": {"a": 1}}, indent=2)
        require(json.loads(cfg.read_text(encoding="utf-8"))["customModelCosts"] == {"a": 1},
                "атомарная запись легла не теми байтами")
        require([q.name for q in home.iterdir()] == ["cfg.json"],
                "атомарная запись оставила обломок")

        # Оборванная копия: под именем бэкапа не должно появиться НИЧЕГО.
        torn_dst = home / "cfg.json.backup.20260829"

        # Замер идёт ВНУТРИ копии: обработчик исключения снимает стадию, и после
        # возврата состояние «писали прямо в конечное имя» неотличимо от
        # честного. Видно только в полёте.
        mid: list[bool] = []

        def torn(_src: object, _dst: object) -> None:
            mid.append(torn_dst.exists())
            raise RuntimeError("обрыв посреди копии")

        module.shutil = SimpleNamespace(copyfileobj=torn, copystat=real_shutil.copystat)
        try:
            module.copy_atomically(str(cfg), str(torn_dst))
        except RuntimeError:
            pass
        else:
            require(False, "оборванная копия не подняла ошибку")
        require(mid == [False] and not torn_dst.exists(),
                "оборванная копия оставила огрызок бэкапа (имя бэкапа занято уже в полёте)")
        require(sorted(q.name for q in home.iterdir()) == ["cfg.json"],
                "оборванная копия оставила обломок стадии")

        # Успешная копия: пока она идёт, глоб прополки бэкапов обязан быть ПУСТ.
        during: list[list[str]] = []

        def spy(src: object, dst: object) -> None:
            during.append(sorted(q.name for q in home.glob("cfg.json.backup.*")))
            real_shutil.copyfileobj(src, dst)

        module.shutil = SimpleNamespace(copyfileobj=spy, copystat=real_shutil.copystat)
        good = home / "cfg.json.backup.20260828"
        module.copy_atomically(str(cfg), str(good))
        require(during == [[]],
                f"имя стадии попало в семью бэкапов: во время копии глоб дал {during}")
        require(good.read_bytes() == cfg.read_bytes(), "бэкап лёг не теми байтами")
    module.shutil = real_shutil


def scenario_32() -> None:
    """Отчёт стенда проб кладётся переименованием.

    Свойство пинится ФОРМОЙ, и это объявлено: исполнить ветку `--json` можно
    только полным прогоном probe-bench под bun по СОБРАННОМУ образу, которого у
    этого стенда нет. Тот же приём, что у сценариев 17-18, 20 и 27.
    """
    text = (ROOT / "tools" / "probe-bench.js").read_text(encoding="utf-8")
    require("const jsonTmp = `${options.json}.tmp.${process.pid}`;" in text,
            "отчёт --json снова пишется через конечное имя")
    start = text.find("const jsonTmp =")
    arm = text[start:start + 600]
    require("fs.fsyncSync(fd);" in arm, "стадия отчёта не доводится до диска")
    require("fs.renameSync(jsonTmp, options.json);" in arm, "стадия отчёта не вводится переименованием")
    require("fs.unlinkSync(jsonTmp)" in arm, "обломок стадии отчёта не убирается")


def scenario_33() -> None:
    """Живой pid не даёт сироте вечной неприкосновенности: возраст -- второй признак."""
    with tempfile.TemporaryDirectory() as raw:
        records = Path(raw)
        live = os.getpid()               # заведомо живой номер
        fresh = records / f"a.json.gz.tmp.{live}"
        aged = records / f"b.json.gz.tmp.{live}"
        dead = records / "c.json.gz.tmp.999999"
        for item in (fresh, aged, dead):
            item.write_text("x", encoding="utf-8")
        past = time.time() - 48 * 3600
        os.utime(aged, (past, past))

        counters, _ = run_compact(records)
        require(aged.exists() is False,
                "сирота с ПЕРЕИСПОЛЬЗОВАННЫМ живым pid снова неприкосновенна навсегда")
        require(dead.exists() is False, "сирота мёртвого pid не снята")
        require(fresh.is_file(), "снят СВЕЖИЙ tmp живого писателя")
        require_counters(counters, orphans=2, tmp_held=1)


def scenario_34() -> None:
    """Уничтоженная точка восстановления tweakcc чинится ПОСЛЕ стадии.

    Свойство пинится ФОРМОЙ и это объявлено: чтобы исполнить ветку, нужен
    настоящий прогон конвейера со стадией распаковщика (минуты, сеть, живой
    дом). Тот же приём, что у сценария 20.
    """
    text = (ROOT / "claude-patch-all.sh").read_text(encoding="utf-8")
    stage = text.find('TWEAKCC_RC=${PIPESTATUS[0]}')
    require(stage >= 0, "в конвейере не найден код возврата стадии распаковщика")
    arm = text[stage:stage + 4000]
    require('if [[ ! -f "$TWEAKCC_BACKUP" ]]; then' in arm,
            "после стадии не проверяется, уцелела ли точка восстановления")
    require('cp -p "$PRISTINE_SRC" "$TWEAKCC_BACKUP.repair"' in arm,
            "точка восстановления не пересоздаётся из пристинных байтов")
    require(arm.index('if [[ ! -f "$TWEAKCC_BACKUP" ]]; then') < arm.index("__tw_saved="),
            "починка стоит ПОСЛЕ сверки дома -- прогон, отказавший на сверке, "
            "оставит дом без точки восстановления")


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
        (19, scenario_19),
        (20, scenario_20),
        (21, scenario_21),
        (22, scenario_22),
        (23, scenario_23),
        (24, scenario_24),
        (25, scenario_25),
        (26, scenario_26),
        (27, scenario_27),
        (28, scenario_28),
        (29, scenario_29),
        (30, lambda: scenario_30(module)),
        (31, scenario_31),
        (32, scenario_32),
        (33, scenario_33),
        (34, scenario_34),
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
        "        except (PermissionError, OverflowError, ValueError):\n            tmp_held += 1\n",
        "        except (OverflowError, ValueError):\n            tmp_held += 1\n",
        "M10",
    )


# M11-M13 -- зубы сверки раскатки (круг 20, D-1). До них у scripts/probes-sync.sh
# не было НИ ОДНОГО стенда, и его нога plist молчала всегда: она сравнивала дом
# с каноническим ИМЕНЕМ файла, которого в доме не бывает.
def mutation_m11(root: Path) -> None:
    replace_once(
        root / "scripts" / "probes-sync.sh",
        'if [[ ! -f "$2" ]]; then\n',
        'if false; then\n',
        "M11",
    )


def mutation_m12(root: Path) -> None:
    replace_once(
        root / "scripts" / "probes-sync.sh",
        '    if grep -qF "$TOOLS_HOME/compact.py" "$__pl"; then\n',
        '    if true; then\n',
        "M12",
    )


def mutation_m13(root: Path) -> None:
    replace_once(
        root / "claude-patch-all.sh",
        'env -u CLAUDE_JUDGE_TOOLS_DIR -u CLAUDE_LAUNCH_AGENTS_DIR \\\n  bash',
        'bash',
        "M13",
    )


# M14-M20 -- зубы волны 23: у replay/validate/adjudicate/channel не было ни
# одного сценария, и все двери, чинившиеся в этой волне, не краснили ничего
# (круг 20, D-6).
def mutation_m14(root: Path) -> None:
    replace_once(
        root / "judge" / "replay.py",
        "'|'.join(re.escape(v) for v in rx) + r')\\s*:',\n                     verdict or '', re.I)",
        "'|'.join(re.escape(v) for v in rx) + r')',\n                     verdict or '', re.I)",
        "M14",
    )


def mutation_m15(root: Path) -> None:
    replace_once(
        root / "judge" / "replay.py",
        "    return (matches[0] if matches else '').strip()",
        "    return (matches[0] if matches else str(text or '')).strip()",
        "M15",
    )


def mutation_m16(root: Path) -> None:
    replace_once(
        root / "judge" / "adjudicate.py",
        "    REVIEW_PROMPT = REVIEW_TEMPLATE.replace('{RX}', '|'.join(RX_VALUES))",
        "    REVIEW_PROMPT = REVIEW_TEMPLATE.replace('{RX}', 'OK|BLOCK')",
        "M16",
    )


def mutation_m17(root: Path) -> None:
    replace_once(
        root / "judge" / "channel.py",
        "    notes = ([] if max_tokens in (None, '') else",
        "    notes = ([] if max_tokens in (None, '') or True else",
        "M17",
    )


def mutation_m18(root: Path) -> None:
    replace_once(
        root / "judge" / "validate.py",
        "        misses = sum(effective_class(row_truth(row, 'human')) == cancel",
        "        misses = sum(row_truth(row, 'human') == 'BLOCK'",
        "M18",
    )


def mutation_m19(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "        if a.dry_run:\n            print(f'снёс бы сироту tmp: ",
        "        if a.dry_run:\n            os.unlink(t)\n            print(f'снёс бы сироту tmp: ",
        "M19",
    )


def mutation_m20(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "            if (after.st_ino, after.st_mtime_ns) != (before.st_ino, before.st_mtime_ns):\n"
        "                continue               # файл подменён после проверки -- не наш\n",
        "",
        "M20",
    )


# M21-M23 -- зубы волны 24: раскатка набором, имя стадии с pid, каталог агентов
# из объявленной ручки (круг 21, E-4/F-5/F-4).
def mutation_m21(root: Path) -> None:
    replace_once(
        root / "scripts" / "probes-sync.sh",
        '  if [[ "$FAILED" -ne 0 ]]; then\n    cleanup_staged\n',
        '  if false; then\n    cleanup_staged\n',
        "M21",
    )


def mutation_m22(root: Path) -> None:
    replace_once(
        root / "scripts" / "probes-sync.sh",
        '  tmp="$dst.sync-new.$$"\n',
        '  tmp="$dst.sync-new"\n',
        "M22",
    )


def mutation_m23(root: Path) -> None:
    replace_once(
        root / "scripts" / "probes-sync.sh",
        'PLIST_HOME="$LAUNCH_AGENTS_DIR/$PLIST_NAME"\n',
        'PLIST_HOME="$HOME/Library/LaunchAgents/$PLIST_NAME"\n',
        "M23",
    )


# M24-M25 -- зубы загрузки образа (круг 21, E-3): распаковка через конечное имя
# и неубранный обломок.
def mutation_m24(root: Path) -> None:
    replace_once(
        root / "claude_patch.py",
        '    tmp = dest.with_name(f"{dest.name}.{os.getpid()}.download")\n',
        '    tmp = dest\n',
        "M24",
    )


def mutation_m25(root: Path) -> None:
    replace_once(
        root / "claude_patch.py",
        "    except BaseException:\n        try:\n            tmp.unlink()\n",
        "    except BaseException:\n        try:\n            pass\n",
        "M25",
    )


# M26-M27 -- зубы бэкапа конфига цен (круг 21, E-6): копия через конечное имя и
# имя стадии, попадающее в глоб прополки бэкапов.
def mutation_m26(root: Path) -> None:
    replace_once(
        root / "set-model-costs.py",
        '    part = os.path.join(os.path.dirname(dst) or ".",\n'
        '                        f".tmp-copy-{os.getpid()}-{os.path.basename(dst)}")\n',
        '    part = dst\n',
        "M26",
    )


def mutation_m27(root: Path) -> None:
    replace_once(
        root / "set-model-costs.py",
        '    part = os.path.join(os.path.dirname(dst) or ".",\n'
        '                        f".tmp-copy-{os.getpid()}-{os.path.basename(dst)}")\n',
        '    part = f"{dst}.part.{os.getpid()}"\n',
        "M27",
    )


# M28 -- зуб отчёта стенда проб (круг 21, E-10).
def mutation_m28(root: Path) -> None:
    replace_once(
        root / "tools" / "probe-bench.js",
        "      const jsonTmp = `${options.json}.tmp.${process.pid}`;\n",
        "      const jsonTmp = options.json;\n",
        "M28",
    )


# M29 -- зуб возрастного признака прополки tmp (круг 21, F-10).
def mutation_m29(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "            if age < TMP_HELD_SECONDS:\n",
        "            if True:\n",
        "M29",
    )


# M30 -- зуб починки точки восстановления tweakcc (круг 21, E-2).
def mutation_m30(root: Path) -> None:
    replace_once(
        root / "claude-patch-all.sh",
        '    if [[ ! -f "$TWEAKCC_BACKUP" ]]; then\n',
        '    if false; then\n',
        "M30",
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
    ("M11", mutation_m11, 19, "пустая машина обязана давать «мерить нечего» (5)"),
    ("M12", mutation_m12, 19, "агент мимо раскатки обязан краснить"),
    ("M13", mutation_m13, 20, "гейт не снимает тест-ручку дома инструментов"),
    ("M14", mutation_m14, 21, "слово без двоеточия снова классифицируется как вердикт"),
    ("M15", mutation_m15, 21, "текст без строки вердикта снова выдаётся за вердикт"),
    ("M16", mutation_m16, 22, "промт адъюдикатора не перерисован под словарь пробы"),
    ("M17", mutation_m17, 24, "потолок вывода уронен молча"),
    ("M18", mutation_m18, 25, "метка STOP не засчитана как отмена"),
    ("M19", mutation_m19, 26, "dry-run СНЁС сироту tmp"),
    ("M20", mutation_m20, 27, "сверка подмены сироты между замером и снятием пропала"),
    ("M21", mutation_m21, 28, "дом ТРОНУТ на неполном наборе"),
    ("M22", mutation_m22, 28, "стадия чужого прогона снесена"),
    ("M23", mutation_m23, 29, "plist ушёл мимо объявленной ручки"),
    ("M24", mutation_m24, 30, "оборванная загрузка перезаписала установку"),
    ("M25", mutation_m25, 30, "обломок оборванной загрузки не убран"),
    ("M26", mutation_m26, 31, "оборванная копия оставила огрызок бэкапа"),
    ("M27", mutation_m27, 31, "имя стадии попало в семью бэкапов"),
    ("M28", mutation_m28, 32, "отчёт --json снова пишется через конечное имя"),
    ("M29", mutation_m29, 33, "сирота с ПЕРЕИСПОЛЬЗОВАННЫМ живым pid снова неприкосновенна"),
    ("M30", mutation_m30, 34, "после стадии не проверяется, уцелела ли точка восстановления"),
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
    # Копия несёт РОВНО то, что читают сценарии: мутации правят её, а не живое
    # дерево. Со сценариями 19-20 в неё вошли сверка раскатки и конвейер --
    # мутация, которой не во что примениться, «проходит» молча (круг 18, §6).
    (root / "judge").mkdir()
    (root / "tools").mkdir()
    (root / "scripts").mkdir()
    shutil.copy2(COMPACT, root / "judge" / "compact.py")
    shutil.copy2(PATCHER, root / "claude_patch.py")
    shutil.copy2(ROOT / "set-model-costs.py", root / "set-model-costs.py")
    shutil.copy2(BENCH, root / "tools" / "judge-tools-bench.py")
    shutil.copy2(ROOT / "tools" / "probe-bench.js", root / "tools" / "probe-bench.js")
    shutil.copy2(ROOT / "claude-patch-all.sh", root / "claude-patch-all.sh")
    shutil.copy2(ROOT / "scripts" / "probes-sync.sh", root / "scripts" / "probes-sync.sh")
    for name in ("replay.py", "validate.py", "channel.py", "adjudicate.py",
                 "README.md", "com.transmutelabs.judge-compact.plist"):
        shutil.copy2(ROOT / "judge" / name, root / "judge" / name)
    for rel in ("probes.toml", "judge/prompt.md", "judge/body.json",
                "idle-watch/prompt.md"):
        dst = root / "probes" / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "probes" / rel, dst)


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
