#!/usr/bin/env python3
"""Герметичный стенд инструментов кита: compact.py и прополка временных
лаунчеров, сверка раскатки, загрузка образа, бэкап конфига цен, форма отчёта
стенда проб.

Коды выхода (подмножество общей таблицы кита -- см. шапку claude-patch-all.sh):
  0  всё сошлось: каждая дверь на месте, каждая мутация покраснела свою
  1  дверь не сошлась, либо мутация прошла молча / покрасила чужую
  2  прибор не может мерить: контракт вызова (argparse), ПРИСТИННАЯ копия
     дерева уже красная (контроль провален), замена СЛОМАЛА РАЗБОР жертвы
     (круг 25, E-3) -- покраснение разбором ничего не доказывает, и такой
     прогон останавливается ДО счёта покраснений -- либо правило
     единственного дома (tools/heredoc-anchor.py) не загрузилось либо
     не держит свои зубы
  3  замок объекта держит другой живой прогон -- повторить позже; счёт
     расхождений при этом НЕ ведётся, «занято» вердиктом не является
  4  объявленное число не сходится с фактическим (EXPECTED_SCENARIOS,
     EXPECTED_MUTATIONS), либо сверка покрытия нашла дверь без своего зуба
     (круг 25, E-4: непокрытая дверь не доказывает ничего)
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import gzip
import io
import importlib.util
import json
import os
import py_compile
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
# КОНСТРЕЙНТ: правило «строка открывает питоновский heredoc» берётся из
# ЕДИНСТВЕННОГО дома кита tools/heredoc-anchor.py (волна 229): прежняя
# местная копия была грубее и молча недосчитывала тела, а тело, которого
# страж не увидел, не компилируется и выглядит ровно как проверенное.
# Ни один сценарий этот файл не читает -- его читает сам стенд, поэтому в
# перечне копирования он лежит как зависимость, а не как жертва.
ANCHOR = ROOT / "tools" / "heredoc-anchor.py"
# Волна 205 добавила judge-tools-bench сценарии 51-56 (docnum:subset --
# диапазон номеров новых сценариев, не счёт набора; горизонт архива
# compact.py), волна 227b -- сценарии 58-61 (docnum:subset -- тот же класс:
# список проб за один прогон, худший код из проб, пустой элемент списка, ценз
# покрытия агента), доработка 227b -- сценарии 62-63 (docnum:subset -- тот же
# класс: изоляция OSError-отказа пробы, валидация имени пробы); счётчик
# растёт вместе с ними по тому же правилу, что и раньше (круг 25, E-4).
EXPECTED_SCENARIOS = 63
# Круг 25, E-4: счётчик вырос вместе с новыми зубами -- до этой волны часть
# сценариев не краснила ни одна мутация, и сверка покрытия ниже теперь
# отказывает на любом новом пробеле, а не молчит.
EXPECTED_MUTATIONS = 73
# CONSTRAINT (волна 227b): каждая итоговая строка compact.py несёт имя пробы
# префиксом [<probe>] -- ВСЕГДА, включая одиночную пробу (урок #207: рядом с
# числом стоит имя владельца; условный «префикс только при списке» делает разбор
# вывода зависимым от аргументов). Регулярки ниже требуют префикс и НАЗЫВАЮТ
# пробу: итог без префикса или с чужим именем -- не распознан.
SUMMARY_RE = re.compile(
    r"\[(?P<probe>[^\]]+)\] сжато: (?P<done>\d+), пропущено: (?P<skipped>\d+), "
    r"исчезли под руками: (?P<vanished>\d+), "
    r"архив исчез после сжатия: (?P<gz_gone>\d+), "
    r"исходник исчез до замера: (?P<src_gone>\d+), "
    r"сирот tmp убрано: (?P<orphans>\d+), "
    r"tmp при живом pid: (?P<tmp_held>\d+), "
    r"освобождено: [-0-9.]+ МБ"
)
HORIZON_RE = re.compile(
    r"\[(?P<probe>[^\]]+)\] горизонт архива: унесено (?P<arch_taken>\d+), "
    r"исчезли (?P<arch_vanished>\d+), байт (?P<arch_bytes>\d+), рубеж \S+"
)

# Форма загрузки -- как у стадии PYCOMPILE конвейера: отказ загрузки это
# отказ стенда кодом 2 («прибор не может мерить»), а не откат к местной
# редакции правила и не «тел нет».
_anchor_spec = importlib.util.spec_from_file_location("heredoc_anchor", str(ANCHOR))
if _anchor_spec is None or _anchor_spec.loader is None:
    print("judge-tools-bench: ЯКОРЬ HEREDOC'ОВ НЕ ЗАГРУЖАЕТСЯ: нет tools/heredoc-anchor.py")
    sys.exit(2)
_anchor = importlib.util.module_from_spec(_anchor_spec)
try:
    _anchor_spec.loader.exec_module(_anchor)
except Exception as _error:    # отказ загрузки -- не откат к своей копии правила
    print(f"judge-tools-bench: ЯКОРЬ HEREDOC'ОВ НЕ ЗАГРУЖАЕТСЯ: {_error}")
    sys.exit(2)
opener_match = _anchor.opener_match

# КОНСТРЕЙНТ (волна 230): импортируемый-но-негодный прибор обязан отказывать
# стенду так же, как незагружающийся: с полностью ослеплённым opener_match
# оба стенда проходили самопроверку целиком -- зелёный вердикт над прибором,
# не видящим открытий, «измерен» только по имени. Решают ПУБЛИЧНЫЕ зубы
# прибора; их отпечаток успеха ПОГЛОЩАЕТСЯ, а не печатается: вывод стендов
# сравнивается побайтно, лишняя строка сломала бы их собственный контракт.
ANCHOR_TEETH_RAN = False


def _anchor_teeth_hold() -> None:
    """Прогнать публичные зубы якоря; отказ прибора -- отказ стенду."""
    global ANCHOR_TEETH_RAN
    buffer = io.StringIO()
    try:
        with contextlib.redirect_stdout(buffer):
            rc = _anchor.self_check()
    except SystemExit as error:
        rc = error.code if isinstance(error.code, int) else 1
    except Exception as error:    # любой отказ прибора -- «не могу мерить»
        rc = 1
        buffer.write(f"{type(error).__name__}: {error}")
    if rc != 0:
        print(f"judge-tools-bench: ЯКОРЬ HEREDOC'ОВ НЕ ДЕРЖИТ ФОРМУ: "
              f"{buffer.getvalue().strip()}")
        sys.exit(2)
    ANCHOR_TEETH_RAN = True


_anchor_teeth_hold()


class BenchFailure(AssertionError):
    pass


class CannotMeasureNow(Exception):
    """Сценарий не смог мерить: замок объекта держит другой живой прогон.

    Круг 25, замер контроллера. Сценарий 28 раскатывает в игрушечный дом; пока
    замок синхронизации брался от БОЕВОГО дома, чужая раскатка отказывала ему
    кодом 3, а стенд печатал FAIL и считал расхождение -- то есть «свойство не
    держится» вместо «померить сейчас нельзя». Ключ замка починен в
    scripts/probes-sync.sh, но различать классы обязан и стенд: два его
    собственных прогона рядом всё ещё законно встречаются на одном доме.
    """


class UnparsableVictim(Exception):
    """Замена сломала РАЗБОР жертвы -- прибор не может мерить (код выхода 2).

    Круг 25, E-3: покраснение СЦЕНАРИЯ синтаксической ошибкой ничего не
    доказывает -- тот же код возврата даёт и отключённый механизм. Страж
    разбираемости ловит такую замену ДО прогона сценариев, и класс возврата
    здесь свой, отдельный от «мутация не применилась» (анкер не найден) и от
    «мутация прошла молча»: причины разные и чинятся по-разному.
    """


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


def age_to(path: Path, days: float) -> None:
    """Метка времени файла на N суток в прошлое: возраст -- ось горизонта."""
    stamp = time.time() - days * 86400
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
    home: Path | None = None,
    extra_env: dict[str, str] | None = None,
    probe: str = "judge",
) -> tuple[dict[str, int], str]:
    """Прогон compact.py в ИЗОЛИРОВАННОМ доме проб.

    Лестница дома у compact.py (main, строки 323-324): CLAUDE_PROBES_DIR, затем
    CLAUDE_CONFIG_DIR/probes, затем ~/.claude/probes. `--dir` задаёт только
    каталог ЗАПИСЕЙ и на путь журнала не влияет вовсе. Стенд передавал лишь
    `--dir`, поэтому journal_path КАЖДОГО прогона указывал в ЖИВОЙ
    ~/.claude/probes/judge/journal.jsonl.

    Замер 2026-09-14: обе свёртки на этом пути уходили в ранний возврат
    («нечего вкладывать») -- mod-фикстур у стенда нет, шардов рядом с живым
    журналом в тот момент не лежало. Вред был отложенный, а не нулевой: шард
    пишет боевой носитель в любой момент, и тогда прогон стенда вложил бы его в
    живой журнал и УДАЛИЛ шард (fold_journal_shards дописывает open(..., 'a') и
    сносит шард после обратного чтения). Счёт порванных строк при этом
    описывал бы огрызки ЖИВОГО журнала, а не фикстуру сценария.

    Изоляция задаётся и флагом `--home`, и переменной CLAUDE_PROBES_DIR --
    дублирование НАМЕРЕННОЕ, оба ведут в один и тот же временный каталог.
    Снятие любого одного не выпускает прогон в живой дом, поэтому мутация этой
    пары ненаблюдаема по построению: зуб есть у СЛЕДСТВИЯ (сценарий 50 читает
    журнал по названному дому), а не у самого дублирования. Менять защиту
    чужих данных на наблюдаемость мутации здесь нельзя -- цена промаха -- запись
    в живой журнал пользователя.
    """
    if home is not None:
        return _compact_once(home, directory, older_than_hours, dry_run, extra_env, probe)
    # Дом без предмета: свой каталог на прогон, чтобы состояние не перетекало
    # между сценариями и не оставалось после стенда.
    with tempfile.TemporaryDirectory() as raw:
        return _compact_once(Path(raw), directory, older_than_hours, dry_run, extra_env, probe)


def _compact_once(
    home: Path,
    directory: Path,
    older_than_hours: float,
    dry_run: bool,
    extra_env: dict[str, str] | None = None,
    probe: str = "judge",
) -> tuple[dict[str, int], str]:
    command = [
        sys.executable,
        str(COMPACT),
        "--home",
        str(home),
        "--dir",
        str(directory),
        "--older-than-hours",
        str(older_than_hours),
        "--probe",
        probe,
    ]
    if dry_run:
        command.append("--dry-run")
    env = dict(os.environ)
    # Ручка горизонта снимается всегда: постороннее значение в окружении
    # подменяло бы умолчание 180 (docnum:other -- сутки рубежа, не счётчик
    # кита) и делало сценарии judge-tools-bench зависимыми от машины.
    env.pop("CLAUDE_JUDGE_ARCHIVE_DAYS", None)
    env["CLAUDE_PROBES_DIR"] = str(home)
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        command, capture_output=True, text=True, errors="replace", env=env,
    )
    output = result.stdout + result.stderr
    require(result.returncode == 0, f"compact.py rc={result.returncode}\n{output}")
    # «Ровно одна итоговая строка НА ПРОБУ» (волна 227b): матч с ЧУЖИМ именем
    # пробы не засчитывается, второй итог той же пробы -- отказ разбора.
    matches = [m for m in SUMMARY_RE.finditer(result.stdout)
               if m.group("probe") == probe]
    require(len(matches) == 1,
            f"итоговая строка compact.py пробы {probe} не распознана ровно один раз\n{output}")
    counters = {name: int(value) for name, value in matches[0].groupdict().items()
                if name != "probe"}
    hmatches = [m for m in HORIZON_RE.finditer(result.stdout)
                if m.group("probe") == probe]
    require(len(hmatches) == 1,
            f"строка горизонта compact.py пробы {probe} не распознана ровно один раз\n{output}")
    counters.update(
        {name: int(value) for name, value in hmatches[0].groupdict().items()
         if name not in ("arch_edge", "probe")})
    return counters, output


def run_compact_raw(
    home: Path,
    directory: Path,
    *,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Прогон compact.py БЕЗ требования кода 0: путь отказа -- предмет сценария."""
    command = [
        sys.executable,
        str(COMPACT),
        "--home",
        str(home),
        "--dir",
        str(directory),
        "--older-than-hours",
        "0",
    ]
    env = dict(os.environ)
    env.pop("CLAUDE_JUDGE_ARCHIVE_DAYS", None)
    env["CLAUDE_PROBES_DIR"] = str(home)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        command, capture_output=True, text=True, errors="replace", env=env,
    )


def _run_compact_probes(
    home: Path,
    probes: list[str],
    older_than_hours: float,
    dry_run: bool,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Прогон compact.py по СПИСКУ проб в изолированном доме (общая команда).

    `--dir` не передаётся НАМЕРЕННО: каталог записей один, а проб в списке
    может быть несколько, и контракт compact.py (волна 227b) отвергает такую
    пару кодом 2 -- у каждой пробы свой <дом>/<проба>/records.
    """
    command = [
        sys.executable,
        str(COMPACT),
        "--home",
        str(home),
        "--probe",
        ",".join(probes),
        "--older-than-hours",
        str(older_than_hours),
    ]
    if dry_run:
        command.append("--dry-run")
    env = dict(os.environ)
    env.pop("CLAUDE_JUDGE_ARCHIVE_DAYS", None)
    env["CLAUDE_PROBES_DIR"] = str(home)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        command, capture_output=True, text=True, errors="replace", env=env,
    )


def run_compact_probes(
    home: Path,
    probes: list[str],
    *,
    older_than_hours: float = 0,
    dry_run: bool = False,
    extra_env: dict[str, str] | None = None,
) -> tuple[dict[str, dict[str, int]], str]:
    """Прогон по списку проб с требованием rc=0 и разбором «НА ПРОБУ».

    Итоговые строки разбираются поимённо: ровно один «сжато» и ровно один
    горизонт НА КАЖДУЮ пробу списка. Ослабление до «хотя бы одной» сняло бы
    зуб: потерянная проба стала бы невидимой (волна 227b).
    """
    result = _run_compact_probes(home, probes, older_than_hours, dry_run, extra_env)
    output = result.stdout + result.stderr
    require(result.returncode == 0, f"compact.py rc={result.returncode}\n{output}")
    counters: dict[str, dict[str, int]] = {}
    for probe in probes:
        summary = [m for m in SUMMARY_RE.finditer(result.stdout)
                   if m.group("probe") == probe]
        require(len(summary) == 1,
                f"итоговая строка пробы {probe} не распознана ровно один раз\n{output}")
        row = {name: int(value) for name, value in summary[0].groupdict().items()
               if name != "probe"}
        horizon = [m for m in HORIZON_RE.finditer(result.stdout)
                   if m.group("probe") == probe]
        require(len(horizon) == 1,
                f"строка горизонта пробы {probe} не распознана ровно один раз\n{output}")
        row.update({name: int(value) for name, value in horizon[0].groupdict().items()
                    if name not in ("arch_edge", "probe")})
        counters[probe] = row
    return counters, output


def run_compact_probes_raw(
    home: Path,
    probes: list[str],
    *,
    older_than_hours: float = 0,
    dry_run: bool = False,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Прогон по списку проб БЕЗ требования кода: путь отказа -- предмет сценария."""
    return _run_compact_probes(home, probes, older_than_hours, dry_run, extra_env)


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
        capture_output=True, text=True, errors="replace", env=env,
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
            capture_output=True, text=True, errors="replace", env=env,
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
    """replay с ПОДСТАВЛЕННЫМ словарём: стенд герметичен и байтов не читает.

    Ключ кэша -- тройка (дом, образ, проба) с волны 40b: дом берётся у самого
    модуля, а не пишется здесь второй копией -- в мутантной копии дерева он
    другой, и посев мимо ключа молча вернул бы стенд к чтению настоящих
    файлов.
    """
    module = import_tool("replay")
    # Дом разрешается ДО mkstemp: отказ ниже уронил бы уже созданный файл
    # образа, и стенд копил бы мусор ровно на тех мутациях, которые он ловит.
    src = module.default_source()
    require(src is not None,
            "дом словарей не найден ни в одной раскладке: посев ушёл бы мимо ключа")
    home = os.path.realpath(os.path.expanduser(src))
    handle, path = tempfile.mkstemp(prefix="judge-bench-image.")
    os.close(handle)
    real = os.path.realpath(path)
    for probe, values in vocab.items():
        module._VOCAB_CACHE[(home, real, probe)] = values
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
                                capture_output=True, text=True, errors="replace")
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
                          cwd=str(ROOT / "judge"), capture_output=True, text=True, errors="replace", env=env)
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

    Копируется ИЗ ROOT -- то есть из дерева, которое правит мутация. Иначе зуб
    применился бы к копии, а сценарий мерил бы живой кит (круг 18, §6).

    CONSTRAINT: каталоги канона копируются ЦЕЛИКОМ -- перечня имён здесь нет и
    быть не должно. Перечень, живущий рядом со своим домом, обязан либо
    читаться из дома, либо не существовать; здесь выбрано второе, потому что
    judge/ и probes/ целиком дешевле любого перечня. Следствие, на которое
    опираются сценарии набора: опечатка в TOOL_FILES краснит стенд (в ките
    такого файла нет), тогда как своя копия перечня её скрывала бы.
    """
    kit = base / "kit"
    (kit / "scripts").mkdir(parents=True)
    shutil.copy2(ROOT / "scripts" / "probes-sync.sh", kit / "scripts" / "probes-sync.sh")
    # Дом словарей вердиктов лежит в КОРНЕ кита, а не в judge/, и раскатка
    # везёт его отдельной парой: без него сторона канона отсутствует и
    # probes-sync отказывает названно, роняя сценарий на своей же полноте.
    shutil.copy2(ROOT / "tweakcc-patch.js", kit / "tweakcc-patch.js")
    # records/labelled -- записи прогонов живого дома, а не канон; __pycache__
    # -- продукт машины. В каноне их быть не должно, но prune дешевле веры.
    skip = shutil.ignore_patterns("__pycache__", "records", "labelled", "*.pyc")
    shutil.copytree(ROOT / "judge", kit / "judge", ignore=skip)
    shutil.copytree(ROOT / "probes", kit / "probes", ignore=skip)
    return kit


def run_sync(kit: Path, mode: str, home: Path, tools: Path, agents: Path,
             fake_home: Path | None = None,
             lock_path: Path | None = None) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env.update(CLAUDE_PROBES_DIR=str(home), CLAUDE_JUDGE_TOOLS_DIR=str(tools),
               CLAUDE_LAUNCH_AGENTS_DIR=str(agents))
    # Замок называется явно только там, где сценарию нужно СДЕЛАТЬ его
    # занятым: держать боевой замок стенд не вправе.
    if lock_path is not None:
        env["PROBES_SYNC_LOCK"] = str(lock_path)
    else:
        env.pop("PROBES_SYNC_LOCK", None)
    if fake_home is not None:
        env["HOME"] = str(fake_home)
    return subprocess.run(["bash", str(kit / "scripts" / "probes-sync.sh"), mode],
                          capture_output=True, text=True, errors="replace", env=env)


def home_bytes(home: Path, tools: Path) -> dict[Path, bytes]:
    out: dict[Path, bytes] = {}
    for base in (home, tools):
        for item in sorted(base.rglob("*")):
            if item.is_file():
                out[item] = item.read_bytes()
    return out


def canon_set(kit: Path, home: Path, tools: Path, agents: Path) -> list[str]:
    """Набор раскатки -- со слов САМОГО инструмента (`--list`).

    CONSTRAINT: ожидаемое число файлов не пишется здесь числом. Прежняя
    редакция держала `11` с комментарием «10, а не 11, с волны 40b» -- то
    есть счёт набора переезжал в стенд руками при каждом пополнении и
    разошёлся на первом же, которого никто не сопроводил (#193). Число живёт
    там же, где набор: в scripts/probes-sync.sh.
    """
    done = run_sync(kit, "--list", home, tools, agents)
    require(done.returncode == 0,
            f"--list отказал rc={done.returncode}: {done.stderr}")
    names = [line for line in done.stdout.splitlines() if line.strip()]
    require(bool(names), "--list назвал ПУСТОЙ набор")
    return names


def scenario_28() -> None:
    """Раскатка ставится НАБОРОМ и не сталкивается со стадией чужого прогона."""
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        kit = toy_kit(base)
        home, tools, agents = base / "p", base / "t", base / "la"
        agents.mkdir()

        # Перечень снимается ДО раскатки: --list обязан работать на пустых
        # домах -- он называет канон, а не то, что уже разложено.
        named = canon_set(kit, home, tools, agents)
        require(not home.exists() and not tools.exists(),
                "--list создал дома -- режим перечисления обязан не трогать ничего")
        # plist едет в ТРЕТИЙ каталог (агентов), которого home_bytes не мерит;
        # в каноне он образец с плейсхолдерами и в набор не входит вовсе --
        # исключение оставлено на случай машины с заполненным образцом.
        expected = len([n for n in named if not n.endswith(".plist")])

        done = run_sync(kit, "--to-home", home, tools, agents)
        if done.returncode == 3:
            raise CannotMeasureNow(
                f"замок дома держит другой писатель: {done.stderr.strip()}")
        require(done.returncode == 0, f"раскатка в игрушечный дом провалилась: {done.stderr}")
        before = home_bytes(home, tools)
        require(len(before) == expected,
                f"в доме {len(before)} файлов, а инструмент назвал набором {expected}")

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


# Форма ЖИВОГО дескриптора пробы в образе: между `dirName:"<проба>"` и её
# словарём стоят поля arm/turn/selfId/turnLost -- ~236 знаков. Прежний
# извлекатель стоял на окне {0,160} и молча перестал находить словарь, когда
# поля добавили; сценариев на извлечение ИЗ ОБРАЗА не было вовсе (все звали
# seeded_replay, подставляющий словарь в кэш), поэтому отказ вылез только на
# живой разметке. Фикстура повторяет форму образа, а не её сокращение.
IMAGE_JUDGE_DESC = (
    'dirName:"judge",arm:!0,turn:()=>{let __x=globalThis.__ccJudgeTurn?.get(E.toolUseId);'
    'globalThis.__ccJudgeTurn?.delete(E.toolUseId);return __x||[]},selfId:()=>E.toolUseId,'
    'turnLost:()=>globalThis.__ccJudgeTurnLost?.has(E.toolUseId)||!1,'
    'rx:"OK|BLOCK|STOP|DENY|WARN",act:"BLOCK|STOP|DENY",fb:"You judge one dispatch."'
)
# Проба БЕЗ своего словаря стоит перед пробой, у которой словарь есть: скан без
# запрета на пересечение границы `dirName:"` вернёт ей ЧУЖОЙ словарь.
IMAGE_MUTE_DESC = 'dirName:"mute-probe",arm:!1,label:"MUTE",fb:"no dictionary here"'
IMAGE_IDLE_DESC = (
    'dirName:"idle-watch",arm:!1,label:"FLEET",rx:"SILENT|NUDGE",act:"NUDGE",'
    'fb:"You watch the subagent fleet."'
)


def synthetic_image(path: Path) -> None:
    """Образ ОДНОЙ строкой -- как настоящий бандл: `[^\n]` в скане не спасёт."""
    body = ("var A=1;" + IMAGE_JUDGE_DESC + "};var B=2;" + IMAGE_MUTE_DESC
            + "};var C=3;" + IMAGE_IDLE_DESC + "};")
    path.write_bytes(body.encode("utf-8"))


def scenario_35() -> None:
    """Читатель ОБРАЗА берёт словарь живой формы и не крадёт чужой.

    С волны 40b образ -- перекрёстная сверка, а не источник, поэтому предмет
    здесь vocabulary_from_image: запрет на пересечение границы соседней пробы
    -- свойство ИМЕННО этого скана (в образе пробы стоят подряд одной
    строкой), и проверять его через verdict_vocabulary больше нечем -- тот
    отказал бы раньше, по отсутствию пробы в доме.
    """
    module = import_tool("replay")
    with tempfile.TemporaryDirectory() as tmp:
        image = Path(tmp) / "claude-image"
        synthetic_image(image)

        # Положительный контроль фикстуры: если её сократить, сценарий перестанет
        # воспроизводить дефект и «пройдёт» на любом окне (круг 18, §6).
        text = image.read_text(encoding="utf-8")
        gap = text.index('rx:"OK') - (text.index('dirName:"judge"') + len('dirName:"judge"'))
        require(gap > 160,
                f"фикстура короче прежнего окна ({gap} знаков) -- дефект не воспроизводится")

        # «Словаря нет» читатель образа отдаёт значением None, а не отказом:
        # решение -- пропустить сверку или объявить расхождение -- принимает
        # вызывающий, и здесь оно ещё не принято.
        got = module.vocabulary_from_image(str(image), "judge")
        rx, act = got if got else (None, None)
        require(rx == ["OK", "BLOCK", "STOP", "DENY", "WARN"] and act == ["BLOCK", "STOP", "DENY"],
                f"словарь пробы живой формы не извлечён из образа: {rx!r}/{act!r}")

        stolen = module.vocabulary_from_image(str(image), "mute-probe")
        require(stolen is None,
                f"скан пересёк границу чужой пробы и вернул ей ЧУЖОЙ словарь: {stolen!r}")

        got2 = module.vocabulary_from_image(str(image), "idle-watch")
        rx2, act2 = got2 if got2 else (None, None)
        require(rx2 == ["SILENT", "NUDGE"] and act2 == ["NUDGE"],
                f"словарь соседней пробы разобран неверно: {rx2!r}/{act2!r}")


def scenario_36() -> None:
    """Метка из будущего -- испорченная метка, а не живой писатель.

    tmp с ЖИВЫМ pid и mtime на сутки вперёд обязан сниматься: возраст по
    времени старта писателя его не покрывает, а «pid жив» не доказывает
    ничьё -- файл остаётся навсегда. Порог и правило общие с tools/sweep.sh.
    """
    with tempfile.TemporaryDirectory() as raw:
        records = Path(raw)
        live = os.getpid()               # заведомо живой номер
        future = records / f"a.json.gz.tmp.{live}"
        fresh = records / f"b.json.gz.tmp.{live}"
        for item in (future, fresh):
            item.write_text("x", encoding="utf-8")
        ahead = time.time() + 24 * 3600
        os.utime(future, (ahead, ahead))

        counters, _ = run_compact(records)
        require(future.exists() is False,
                "сирота с меткой из БУДУЩЕГО снова неприкосновенна навсегда")
        require(fresh.is_file(), "снят СВЕЖИЙ tmp живого писателя")
        require_counters(counters, orphans=1, tmp_held=1)


def scenario_37() -> None:
    """Занятый замок дома -- «повторить позже» (3), а не отказ по существу.

    Круг 25, замер контроллера: инструмент брал замок от CLAUDE_HOME_DIR, а
    писал в дом из CLAUDE_PROBES_DIR -- игрушечная раскатка стенда и настоящая
    раскатка отказывали друг другу, и стенд читал это как непрошедшее
    свойство. Ключ замка привязан к дому проб (scripts/probes-sync.sh); здесь
    пинится ВТОРАЯ половина: когда замок занят по-настоящему, инструмент
    обязан ответить классом 3 и НАЗВАТЬ держателя, а не свалиться в 1.
    """
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        kit = toy_kit(base)
        home, tools, agents = base / "p", base / "t", base / "la"
        agents.mkdir()
        lock = base / "held.lock"
        with open(lock, "w", encoding="utf-8") as holder:
            fcntl.flock(holder, fcntl.LOCK_EX)
            done = run_sync(kit, "--to-home", home, tools, agents,
                            lock_path=lock)
            require(done.returncode == 3,
                    f"занятый замок дал {done.returncode}, ожидался класс 3: "
                    f"{done.stderr.strip()}")
            out = done.stdout + done.stderr
            require("держит" in out,
                    f"отказ по занятому замку не назвал держателя: {out.strip()}")
            require(not home.exists() and not tools.exists(),
                    "дом ТРОНУТ, хотя замок держал другой писатель")


# Сценарии 38-44 -- зубы волны 31, бриф 3 (круг 26): числовые ручки инструментов
# судьи (K-5/K-7/K-13/K-14), собственный ключ подрезки реплик (K-6),
# доказательная база меток (L-4) и граница строки в labels.jsonl (L-5).
def toy_judge_records(directory: Path, count: int = 5) -> None:
    """Записи минимальной формы, которую читают replay.load и compose_body."""
    for i in range(count):
        record = {
            "request": {"model": "bench-model",
                        "messages": [{"role": "user", "content": f"запись {i}"}]},
            "verdict": "ok: запись",
        }
        (directory / f"rec-{i}.json").write_text(json.dumps(record), encoding="utf-8")


def run_validate_run(records: Path, image: Path, out: Path,
                     *extra: str) -> subprocess.CompletedProcess[str]:
    """Прогон validate.py run в герметичном окружении.

    Адрес -- заведомо закрытый порт: единственный ожидаемый исход канала --
    отказ соединения, пойманный в error-строку прогона. Образ -- синтетическая
    фикстура (словарь из synthetic_image), дом проб не перенаправляется:
    --url и --models перекрывают все, что validate мог бы прочитать из
    боевого probes.toml.
    """
    command = [
        sys.executable, str(ROOT / "judge" / "validate.py"), "run",
        "--records", str(records),
        "--models", "bench-model",
        "--channel", "http",
        "--url", "http://127.0.0.1:1",
        "--image", str(image),
        "--out", str(out),
        *extra,
    ]
    env = dict(os.environ)
    env.pop("ANTHROPIC_BASE_URL", None)
    return subprocess.run(command, capture_output=True, text=True, errors="replace", env=env)


def scenario_38() -> None:
    """--limit отвергает минус кодом 2 у всех трёх читателей; ноль -- без потолка.

    Прежний type=int пропускал минус, и files[-limit:] молча выкидывал самые
    старые записи: --limit=-1 терял ОДНУ, --limit=-5 давал пустой список и код 5
    «записи не найдены» при записях на диске.
    """
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        records = base / "records"
        records.mkdir()
        toy_judge_records(records, 5)
        image = base / "image"
        synthetic_image(image)
        out = base / "out.jsonl"

        for tool, args, env_extra in (
            # validate: полный прогон нужен потому, что отказ обязан прийти ОТ
            # argparse, а не от отсутствия образа -- иначе на машине без образа
            # неотремонтированное дерево отвечало бы кодом 2 впустую.
            ("validate.py",
             ["run", "--records", str(records), "--models", "bench-model",
              "--channel", "http", "--url", "http://127.0.0.1:1",
              "--image", str(image), "--out", str(out), "--limit=-1"], None),
            ("adjudicate.py",
             [str(records), "--model", "bench-model", "--channel", "http",
              "--image", str(image), "--dry-run", "--limit=-1"],
             {"ANTHROPIC_BASE_URL": "http://127.0.0.1:1"}),
            ("replay.py",
             [str(records), "--model", "bench-model", "--channel", "http",
              "--url", "http://127.0.0.1:1", "--limit=-1"],
             {"CLAUDE_JUDGE_IMAGE": str(image),
              "ANTHROPIC_BASE_URL": "http://127.0.0.1:1"}),
        ):
            env = dict(os.environ)
            env.pop("ANTHROPIC_BASE_URL", None)
            if env_extra:
                env.update(env_extra)
            done = subprocess.run(
                [sys.executable, str(ROOT / "judge" / tool), *args],
                capture_output=True, text=True, errors="replace", env=env)
            combined = done.stdout + done.stderr
            require(done.returncode == 2,
                    f"{tool}: --limit=-1 не отвергнут кодом 2 (rc={done.returncode})")
            require("--limit" in combined, f"{tool}: отказ не назвал ручку --limit")

        # Ноль сохраняет действующий смысл «без потолка»: пять записей -- пять
        # строк прогона.
        done = run_validate_run(records, image, out, "--limit=0")
        require(done.returncode == 0,
                f"--limit=0 не прошёл прогон: rc={done.returncode}\n"
                f"{done.stdout}{done.stderr}")
        rows = [line for line in out.read_text(encoding="utf-8").splitlines()
                if line.strip()]
        require(len(rows) == 5, f"--limit=0 взял {len(rows)} записей, а не все 5")


def scenario_39() -> None:
    """--timeout конечен и в отрезке; отказ при 240000 называет единицы.

    Верхняя граница -- сутки: timeout_ms=240000 из соседнего toml,
    скопированный в --timeout, -- это 240000 СЕКУНД (~67 часов), и потолок
    превращает описку в громкий отказ вместо прогона, который не кончится.
    """
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        records = base / "records"
        records.mkdir()
        toy_judge_records(records, 1)
        image = base / "image"
        synthetic_image(image)
        for value in ("0", "-1", "nan", "240000"):
            done = run_validate_run(records, image, base / "out.jsonl",
                                    f"--timeout={value}")
            combined = done.stdout + done.stderr
            require(done.returncode == 2,
                    f"--timeout {value} не отвергнут кодом 2 (rc={done.returncode})")
            require("--timeout" in combined,
                    f"--timeout {value}: отказ не назвал ручку")
            if value == "240000":
                require("СЕКУНД" in combined.upper(),
                        "отказ при 240000 не назвал единицы: --timeout в СЕКУНДАХ, "
                        "timeout_ms соседнего toml -- в миллисекундах")
        # Здоровое значение по-прежнему принимается: затянуть гайки до «не
        # работает никогда» -- не чинка.
        done = run_validate_run(records, image, base / "out.jsonl", "--timeout=30")
        require(done.returncode == 0,
                f"--timeout=30 отвергнут здоровым значением: rc={done.returncode}\n"
                f"{done.stdout}{done.stderr}")


def scenario_40() -> None:
    """--older-than-hours конечен и неотрицателен; 24 на свежих -- прежнее поведение.

    Прежний type=float пропускал минус и nan: минус кладывал cutoff в будущее и
    сжимал ВСЁ живое, nan делал сравнение всегда ложным с тем же исходом -- при
    коде выхода 0 и счётчике «сжато: N», выглядящем как штатный проход.
    """
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        source = directory / "fresh.json"
        write_record(source, "fresh")
        for value in ("-1", "nan"):
            done = subprocess.run(
                [sys.executable, str(COMPACT), "--dir", str(directory),
                 "--older-than-hours", value],
                capture_output=True, text=True, errors="replace")
            require(done.returncode == 2,
                    f"--older-than-hours {value} не отвергнут кодом 2 "
                    f"(rc={done.returncode})")
            require("--older-than-hours" in done.stdout + done.stderr,
                    f"--older-than-hours {value}: отказ не назвал ручку")
        # Прежнее поведение цело: сутки на свежей записи -- пропуск, не сжатие.
        counters, _ = run_compact(directory, older_than_hours=24)
        require_counters(counters, skipped=1, done=0)


def scenario_41() -> None:
    """checks-teeth отвергает --jobs < 1 кодом 2, как соседи validate/adjudicate.

    Прежний молчаливый подъём max(1, opts.jobs) означал, что объявленный
    параллелизм и настоящий -- разные числа. Образ называется заведомо
    несуществующим: контракт вызова обязан проверяться ДО поиска образа, и на
    неотремонтированном дереве прогон должен отличаться от пропуска (rc=5), а
    не совпадать с отказом по другой причине.
    """
    with tempfile.TemporaryDirectory() as raw:
        missing = Path(raw) / "нет-такого-образа"
        done = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "checks-teeth.py"),
             "--jobs", "0", "--image", str(missing)],
            capture_output=True, text=True, errors="replace")
        require(done.returncode == 2,
                f"--jobs=0 не отвергнут кодом 2 (rc={done.returncode})")
        require("--jobs" in done.stderr, "отказ не назвал ручку --jobs")


def scenario_42() -> None:
    """Подрезку реплик ведёт recompose_message_tail_chars, а не context_chars.

    Ключ context_chars принадлежит ядру (бюджет JSON-длины ВСЕЙ ленты), а слой
    recompose прежде читал его как хвост КАЖДОГО user-сообщения: одно значение
    рулило двумя разными операциями, и владелец, выставивший его ядру, получал
    незаметную подрезку реплик. Молчать о чужом ключе нельзя -- молчание и был
    дефект.
    """
    module = import_tool("validate")
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)
        prompt = base / "prompt.md"
        prompt.write_text("судейский промт стенда\n", encoding="utf-8")
        long_reply = "д" * 100000
        record = {"request": {"model": "bench-model", "messages": [
            {"role": "user", "content": long_reply}]},
            "cfg": None}

        def compose(config):
            args = SimpleNamespace(prompt=str(prompt), project_layer="recompose")
            buffer = io.StringIO()
            stderr = sys.stderr
            sys.stderr = buffer
            try:
                body, _ = module.compose_body(record, "bench-model", "high",
                                              args, config)
            finally:
                sys.stderr = stderr
            return body, buffer.getvalue()

        def user_content(body):
            return next(message["content"] for message in body["messages"]
                        if message.get("role") == "user")

        # Чужой ключ объявляется одной строкой и НЕ применяется.
        body, warnings = compose({"context_chars": 60000})
        require(len(user_content(body)) == len(long_reply),
                f"реплики подрезаны чужим ключом context_chars: "
                f"{len(user_content(body))} из {len(long_reply)}")
        require("context_chars" in warnings
                and "recompose_message_tail_chars" in warnings,
                f"молчание о чужом ключе context_chars: {warnings.strip()!r}")
        require(warnings.count("\n") == 1,
                "предупреждение о чужом ключе не одна строка")

        # Свой ключ подрезает хвост реплики.
        body, warnings = compose({"recompose_message_tail_chars": 5})
        require(user_content(body) == long_reply[-5:],
                "recompose_message_tail_chars не подрезает хвост реплики")
        require(warnings == "",
                "предупреждение появилось там, где чужого ключа нет")

        # Ноль -- явное «без подрезки», а не совпадение s[-0:].
        body, _ = compose({"recompose_message_tail_chars": 0})
        require(len(user_content(body)) == len(long_reply),
                "recompose_message_tail_chars = 0 подрезает реплики")

        # Отрицательный предел отвергается и после смены ключа.
        try:
            module.apply_context_limit({"messages": []}, -5)
        except ValueError:
            pass
        else:
            require(False, "отрицательный предел подрезки больше не отвергается")


def scenario_43() -> None:
    """Дом доказательной базы принимает существующий target только побайтово равным.

    Прежняя копия shutil.copy2 прямо под конечным именем и признак готовности
    os.path.exists означали: смерть посреди копии оставляла УСЕЧЁННЫЙ файл, а
    повторный label его не переписывал -- CLI возвращал 0, а база хранила обрезок.
    """
    module = import_tool("validate")
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)
        home = base / "probes-home"
        labelled = base / "labelled"
        records = home / "judge" / "records"
        records.mkdir(parents=True)
        source = records / "rec.json"
        payload = ("доказательная база " + "x" * 5000).encode("utf-8")
        source.write_bytes(payload)
        labelled.mkdir()
        target = labelled / "rec.json"
        target.write_bytes(payload[:100])

        saved = os.environ.get("CLAUDE_JUDGE_LABELLED_DIR")
        os.environ["CLAUDE_JUDGE_LABELLED_DIR"] = str(labelled)
        try:
            module.configure_paths(str(home), "judge")
            kept = module.keep_labelled("rec.json")
            require(kept == str(target),
                    f"keep_labelled вернул {kept}, а не {target}")
            require(target.read_bytes() == payload,
                    "усечённый target не переписан побайтово равным источнику")
            require(not list(labelled.glob("*.new.*")),
                    "временное имя копии осталось в доме доказательной базы")
            # Идемпотентность по содержимому: повтор не трогает целое.
            before = target.stat().st_mtime_ns
            module.keep_labelled("rec.json")
            require(target.stat().st_mtime_ns == before,
                    "повторная разметка переписывает байтово равный target")
        finally:
            if saved is None:
                os.environ.pop("CLAUDE_JUDGE_LABELLED_DIR", None)
            else:
                os.environ["CLAUDE_JUDGE_LABELLED_DIR"] = saved


def scenario_44() -> None:
    """Писатель меток восстанавливает границу строки в labels.jsonl.

    Оборванный предыдущий писатель оставлял хвост без перевода строки, и
    следующая полноценная метка приклеивалась к обломку -- читатель терял ОБЕ,
    а второй label возвращал 0 и печатал свой JSON. Контракт общий с ядром
    (tweakcc-patch.js, journal.jsonl, волна 31 бриф 1): границу восстанавливает
    писатель, читатель остаётся толерантным.
    """
    module = import_tool("validate")
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)
        home = base / "probes-home"
        labelled = base / "labelled"
        records = home / "judge" / "records"
        records.mkdir(parents=True)
        (records / "rec.json").write_text(
            '{"verdict": "ok: запись"}', encoding="utf-8")
        labels = home / "judge" / "labels.jsonl"
        labels.write_text('{"rec": "stale", "truth": "OK"', encoding="utf-8")

        saved = os.environ.get("CLAUDE_JUDGE_LABELLED_DIR")
        os.environ["CLAUDE_JUDGE_LABELLED_DIR"] = str(labelled)
        try:
            module.configure_paths(str(home), "judge")
            module.command_label(
                SimpleNamespace(record="rec.json", truth="OK", note=""))
            text = labels.read_text(encoding="utf-8")
            require(text.count("\n") == 2,
                    "граница строки не восстановлена: переводов "
                    f"{text.count(chr(10))}, ожидалось 2 (обломок и новая метка)")
            lines = text.split("\n")
            require(json.loads(lines[1]).get("rec") == "rec.json",
                    "новая метка не разбирается как JSON")
            seen = module.labels_by_record()
            require(seen.get("rec.json", {}).get("human", {}).get("truth") == "OK",
                    "новая метка не видна читателю меток")
            # Второй писатель (адъюдикатор) пользуется той же функцией границы.
            # Его штатный прогон -- сеть и живые модели, поэтому вызов пинится
            # формой и это объявлено: тот же приём, что у сценариев 17-18, 20, 27.
            adj = (ROOT / "judge" / "adjudicate.py").read_text(encoding="utf-8")
            require("replay.append_jsonl(LABELS_PATH, batch)" in adj,
                    "адъюдикатор дописывает метки мимо общей функции границы")
        finally:
            if saved is None:
                os.environ.pop("CLAUDE_JUDGE_LABELLED_DIR", None)
            else:
                os.environ["CLAUDE_JUDGE_LABELLED_DIR"] = saved


# --- волна 40b: дом словарей вердиктов и перекрёстная сверка с образом --------
#
# Форма ЖИВОГО дома -- многострочная склейка JS-литералов с комментариями между
# полями (tweakcc-patch.js): от `dirName:"judge"` до его словаря там тринадцать
# строк. Фикстура повторяет ИМЕННО эту форму, а не её сокращение: скан по классу
# `[^\n]` (форма образа) на ней не сходится, и это её положительный контроль.
SOURCE_JUDGE_DESC = (
    "    'tag:\"[Judge]\",dirName:\"judge\",arm:!0,' +\n"
    "      // Между дескриптором и словарём стоят поля и комментарии -- ровно\n"
    "      // то, из-за чего однострочный класс здесь не годится.\n"
    "      'turn:()=>{let __x=globalThis.__ccJudgeTurn?.get($5);return __x||[]},' +\n"
    "      'selfId:()=>$5,turnLost:()=>!1,' +\n"
    "      'rx:\"OK|BLOCK|STOP|DENY|WARN\",act:\"BLOCK|STOP|DENY\",' +\n"
    "      'fb:\"You judge one dispatch.\",' +\n"
)
SOURCE_IDLE_DESC = (
    "    'tag:\"[Watch]\",dirName:\"idle-watch\",arm:!1,label:\"FLEET\",' +\n"
    "      'rx:\"SILENT|NUDGE\",act:\"NUDGE\",' +\n"
)


def synthetic_source(path: Path, judge_rx: str = "OK|BLOCK|STOP|DENY|WARN") -> None:
    """Дом словарей игрушечной формы: та же многострочность, что у живого."""
    body = ("// синтетический дом стенда\n"
            + SOURCE_JUDGE_DESC.replace("OK|BLOCK|STOP|DENY|WARN", judge_rx)
            + SOURCE_IDLE_DESC)
    path.write_text(body, encoding="utf-8")


def carrier_image(path: Path, body: str) -> None:
    """Образ-НОСИТЕЛЬ: одна строка плюс метка ядра проб.

    Без метки образ читается как «не наша сборка», и сверка пропускается --
    тогда сценарий о расхождении не воспроизводил бы расхождение вовсе.
    """
    path.write_bytes(("var A=1;globalThis.__ccProbe??=async function(__o){};" + body).encode())


def run_vocabulary(probe: str, image: Path | str | None = None,
                   source: Path | str | None = None) -> subprocess.CompletedProcess[str]:
    """verdict_vocabulary отдельным процессом: нужен ИМЕННО код выхода и stderr.

    Обе ручки передаются переменными окружения, а не аргументами: так заодно
    проверяется лестница «аргумент -> переменная -> умолчание», которой
    пользуются validate.py и adjudicate.py.
    """
    code = ("import json, sys, replay\n"
            "print(json.dumps(replay.verdict_vocabulary(None, sys.argv[1])))\n")
    env = dict(os.environ)
    env.pop("CLAUDE_JUDGE_PATCH_SRC", None)
    env.pop("CLAUDE_JUDGE_IMAGE", None)
    if source is not None:
        env["CLAUDE_JUDGE_PATCH_SRC"] = str(source)
    if image is not None:
        env["CLAUDE_JUDGE_IMAGE"] = str(image)
    return subprocess.run([sys.executable, "-c", code, probe], cwd=str(ROOT / "judge"),
                          capture_output=True, text=True, errors="replace", env=env)


def scenario_45() -> None:
    """Дом словарей -- ИСХОДНИК патча: машина БЕЗ образа мерит, а не отказывает.

    Прибор вычитывал словарь регекспом из ПРОПАТЧЕННОГО образа, и на машине без
    установленного пропатченного claude отказывал кодом 2: 2026-09-07 стенд
    падал так на сценариях 38 и 39 И на маке, И на воркере. Образ -- производное
    от tweakcc-patch.js; дом -- файл, который пишет байты.
    """
    patch = (ROOT / "tweakcc-patch.js").read_text(encoding="utf-8")
    # Положительный контроль фикстуры: сократится дом -- сценарий перестанет
    # воспроизводить предмет и «пройдёт» на чём угодно.
    for declared in ('rx:"OK|BLOCK|STOP|DENY|WARN",act:"BLOCK|STOP|DENY",',
                     'rx:"PASS|WARN|REFUSE",act:"REFUSE|WARN",',
                     'rx:"SILENT|NUDGE",act:"NUDGE",'):
        require(patch.count(declared) == 1,
                f"дом не объявляет словарь ровно один раз: {declared}")
    head = patch.index('dirName:"judge"')
    gap = patch[head:patch.index('rx:"OK|BLOCK', head)]
    require(gap.count("\n") > 1,
            f"дом стал однострочным на этом участке ({gap.count(chr(10))} переводов) -- "
            "многострочный класс скана больше ничего не доказывает")

    for probe, rx, act in (("judge", ["OK", "BLOCK", "STOP", "DENY", "WARN"], ["BLOCK", "STOP", "DENY"]),
                           ("form", ["PASS", "WARN", "REFUSE"], ["REFUSE", "WARN"]),
                           ("idle-watch", ["SILENT", "NUDGE"], ["NUDGE"])):
        done = run_vocabulary(probe, image="/nonexistent/claude-image")
        require(done.returncode == 0,
                f"прибор отказал без образа на пробе {probe} (rc={done.returncode}): "
                f"{(done.stderr or '').strip()[:300]}")
        require(json.loads(done.stdout) == [rx, act],
                f"словарь пробы {probe} прочитан не из дома: {done.stdout.strip()}")


def scenario_46() -> None:
    """Пропуск сверки с образом ОБЪЯВЛЕН: молчание неотличимо от сверки.

    Два разных «сверять нечем» -- образа нет по пути и образ есть, но наших
    проб не несёт (сток либо чужая сборка). У каждого своя строка с причиной.
    """
    done = run_vocabulary("judge", image="/nonexistent/claude-image")
    require(done.returncode == 0, f"rc={done.returncode}: {(done.stderr or '').strip()[:300]}")
    require("сверка с образом ПРОПУЩЕНА" in done.stderr
            and "/nonexistent/claude-image" in done.stderr,
            f"пропуск сверки не объявлен при отсутствии образа: {done.stderr.strip()[:300]!r}")

    with tempfile.TemporaryDirectory() as tmp:
        stock = Path(tmp) / "stock-image"
        # Ни метки ядра проб, ни дескрипторов: ровно то, что лежит в
        # ~/.local/bin/claude на машине без нашей установки.
        stock.write_bytes(b"var A=1;function nothingOfOurs(){}")
        done = run_vocabulary("judge", image=stock)
        require(done.returncode == 0,
                f"стоковый образ принят за расхождение (rc={done.returncode}): "
                f"{(done.stderr or '').strip()[:300]}")
        require("не несёт наших проб" in done.stderr,
                f"пропуск сверки со стоковым образом не объявлен: {done.stderr.strip()[:300]!r}")
        require(json.loads(done.stdout) == [["OK", "BLOCK", "STOP", "DENY", "WARN"],
                                            ["BLOCK", "STOP", "DENY"]],
                f"словарь при пропущенной сверке взят не из дома: {done.stdout.strip()}")


def scenario_47() -> None:
    """Дом и образ РАСХОДЯТСЯ -- отказ кодом 2, и названы ОБА словаря.

    Расхождение значит, что поставленный образ собран не из этого дерева.
    Молча предпочесть любую из сторон -- дать неверную разметку корпуса.
    """
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        source = base / "tweakcc-patch.js"
        synthetic_source(source, judge_rx="OK|BLOCK")
        image = base / "carrier-image"
        carrier_image(image, 'dirName:"judge",arm:!0,rx:"OK|BLOCK|STOP|DENY|WARN",'
                             'act:"BLOCK|STOP|DENY",fb:"x"};')

        done = run_vocabulary("judge", image=image, source=source)
        require(done.returncode == 2,
                f"расхождение дома и образа не отвергнуто кодом 2 (rc={done.returncode}): "
                f"{done.stdout.strip()[:200]}")
        require("OK|BLOCK\"" in done.stderr and "OK|BLOCK|STOP|DENY|WARN" in done.stderr,
                f"отказ назвал не оба словаря: {done.stderr.strip()[:400]!r}")

        # Носитель БЕЗ словаря пробы -- то же расхождение, а не «нечего сверять»:
        # метка говорит, что пробы в образе есть, значит эта пропала.
        gone = base / "carrier-without-judge"
        carrier_image(gone, 'dirName:"idle-watch",arm:!1,rx:"SILENT|NUDGE",act:"NUDGE"};')
        done = run_vocabulary("judge", image=gone, source=source)
        require(done.returncode == 2,
                f"носитель без словаря пробы принят за сверку (rc={done.returncode})")
        require("словаря этой пробы в нём нет" in done.stderr,
                f"отказ не назвал причину пропажи: {done.stderr.strip()[:400]!r}")


def scenario_48() -> None:
    """Пробы, которой нет в ДОМЕ, не существует: словарь не крадётся у образа.

    Дверь волны 22 (проба «mute-probe» и чужой соседний словарь) переехала на
    верхний вход вместе с домом: раньше кражу мог совершить только скан образа,
    теперь -- ещё и подстановка зашитого словаря на месте отказа.
    """
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        source = base / "tweakcc-patch.js"
        synthetic_source(source)
        image = base / "carrier-image"
        # В образе у чужой пробы словарь ЕСТЬ -- красть есть что.
        carrier_image(image, 'dirName:"judge",arm:!0,rx:"OK|BLOCK|STOP|DENY|WARN",'
                             'act:"BLOCK|STOP|DENY",fb:"x"};var B=2;'
                             'dirName:"mute-probe",arm:!1,rx:"MUTE|LOUD",act:"MUTE",fb:"y"};')

        control = run_vocabulary("judge", image=image, source=source)
        require(control.returncode == 0,
                f"положительный контроль не прошёл: judge не прочитан (rc={control.returncode}): "
                f"{(control.stderr or '').strip()[:300]}")

        # Сперва БЕЗ образа: сверка тогда пропущена, и единственное, что стоит
        # между «пробы нет» и выдуманным ответом, -- сам отказ дома. С образом
        # отказ приходил бы и от сверки, то есть дверь дома проверялась бы
        # чужим часовым.
        done = run_vocabulary("mute-probe", image="/nonexistent/claude-image", source=source)
        require(done.returncode == 2,
                f"проба вне дома не отвергнута кодом 2 (rc={done.returncode}): "
                f"{done.stdout.strip()[:200]}")
        require("не объявлен в доме" in done.stderr,
                f"отказ не назвал дом причиной: {done.stderr.strip()[:300]!r}")

        # И с носителем, у которого своя проба со СВОИМ словарём: отказ обязан
        # остаться -- образ не источник ни при каких условиях.
        done = run_vocabulary("mute-probe", image=image, source=source)
        require(done.returncode == 2,
                f"проба вне дома взяла словарь у образа (rc={done.returncode}): "
                f"{done.stdout.strip()[:200]}")


def scenario_49() -> None:
    """Раскатанный дом инструментов резолвится САМ: исходник лежит СОСЕДОМ.

    Раскатка (scripts/probes-sync.sh) кладёт judge/*.py и tweakcc-patch.js в
    ОДИН каталог, а резолвер знал только раскладку дерева кита -- 2026-09-07
    любой вызов словаря в раскатанном доме отказывал кодом 2 (волна 42).
    Половина Б -- положительный контроль половины А: без отказа, называющего
    ОБА кандидата, «словарь нашёлся» неотличимо от «резолвер вернул что
    попало».
    """
    saved = {name: os.environ.get(name)
             for name in ("CLAUDE_JUDGE_PATCH_SRC", "CLAUDE_JUDGE_IMAGE")}
    spec_name = "judge_tools_bench_deployed_replay"
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        tools = base / "judge"
        tools.mkdir()
        shutil.copy2(ROOT / "judge" / "replay.py", tools / "replay.py")
        neighbour = tools / "tweakcc-patch.js"
        shutil.copy2(ROOT / "tweakcc-patch.js", neighbour)
        # Фикстура обязана быть ИМЕННО раскатанной раскладкой: исходник на
        # уровне кита вернул бы сценарий к СТАРОЙ ступени, и соседняя не
        # измерялась бы вовсе.
        require(not (base / "tweakcc-patch.js").exists(),
                "фикстура несёт исходник на уровне кита -- измеряется старая ступень")

        for name in saved:
            os.environ.pop(name, None)
        try:
            # Копия грузится ПО СВОЕМУ ПУТИ: import_tool берёт replay из дерева
            # кита, а предмет здесь -- раскладка, которую модуль считает от
            # собственного __file__.
            spec = importlib.util.spec_from_file_location(
                spec_name, tools / "replay.py")
            require(spec is not None and spec.loader is not None,
                    f"не удалось создать spec для {tools / 'replay.py'}")
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec_name] = module
            spec.loader.exec_module(module)

            # Образа нет по пути -- это ОБЪЯВЛЕННЫЙ пропуск сверки (волна 40b),
            # а не отказ: предмет сценария -- дом, а не сверка.
            image = str(base / "nonexistent-claude-image")

            def vocabulary(probe="judge"):
                """Словарь В ПРОЦЕССЕ с перехватом stderr: отказ разбирается текстом.

                Кэш чистится перед каждым вызовом: половины меряют РАЗНЫЕ
                состояния одного дома, и ответ первой не должен отвечать за
                вторую.
                """
                noise = io.StringIO()
                keep = sys.stderr
                sys.stderr = noise
                module._VOCAB_CACHE.clear()
                try:
                    return module.verdict_vocabulary(image_path=image,
                                                     probe=probe), None, noise.getvalue()
                except SystemExit as error:
                    return None, error.code, noise.getvalue()
                finally:
                    sys.stderr = keep

            home, code, said = vocabulary()
            require(code is None,
                    "раскатанная раскладка не резолвится: соседний исходник не взят "
                    f"(код {code}): {said.strip()[:300]}")
            require(bool(home) and all(home),
                    f"словарь раскатанного дома пуст: {home}")

            neighbour.unlink()
            home, code, said = vocabulary()
            require(code == 2,
                    f"дом без единой раскладки не отвергнут кодом 2 (код {code}): {home}")
            require(all(cand in said for cand in module.DEFAULT_SOURCES),
                    f"отказ назвал не оба кандидата раскладки: {said.strip()[:300]!r}")
        finally:
            sys.modules.pop(spec_name, None)
            for name, value in saved.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value


def build_journal_home(base: Path, *, torn: bool) -> tuple[Path, Path]:
    """Игрушечный дом проб с журналом, шардом и записью мода.

    Обе свёртки журнала уходят в ранний возврат, если им нечего вкладывать:
    fold_mod_records -- когда в каталоге записей нет mod-*.json,
    fold_journal_shards -- когда рядом с журналом нет journal.jsonl.shard.*.
    Не прочитав журнал, они и порванную строку назвать не могут, поэтому
    фикстура обязана нести ОБА повода, иначе сценарий зелен по причине
    «читатель не читал», а не «читатель назвал».

    Порванная строка стоит ВТОРОЙ намеренно: координата обязана приводить к
    строке, а строка первая совпала бы с номером при любой ошибке отсчёта.
    Подпись взята с измеренного случая (журнал судьи, строка 346): данные
    плюс NUL -- «файл вырос, данные до диска не дошли».
    """
    home = base / "home"
    records = home / "judge" / "records"
    records.mkdir(parents=True)
    journal = home / "judge" / "journal.jsonl"

    torn_line = '{"rec": "mod-torn.json", "t": "2026-09-14T00:00:00' + "\x00" * 11 + '"}'
    lines = ['{"rec": "mod-a.json", "carrier": "mod"}']
    if torn:
        lines.append(torn_line)
    else:
        lines.append('{"rec": "mod-c.json", "carrier": "mod"}')
    lines.append('{"rec": "mod-b.json", "carrier": "mod"}')
    journal.write_text("\n".join(lines) + "\n", encoding="utf-8")

    (journal.parent / (journal.name + ".shard.mod-shard.json")).write_text(
        '{"rec": "mod-shard.json", "carrier": "mod"}\n', encoding="utf-8",
    )
    (records / "mod-fold.json").write_text(
        json.dumps({"kind": "OK", "tool": "Agent", "agent": "probe",
                    "dtMs": 5, "used": True, "cls": "an-cause",
                    "t0": 1757000000000}),
        encoding="utf-8",
    )
    return home, records


def scenario_50() -> None:
    """Порванная строка журнала НАЗВАНА и СОЧТЕНА обеими свёртками.

    Журнал во всём наборе инструментов читает только judge/compact.py, и оба
    его цикла делали `except json.JSONDecodeError: continue` -- молча, без
    счёта. Счётчик «не прочитано» в их итогах считает СОВСЕМ ДРУГОЕ: нечитаемые
    файлы записей (fold mod) и нечитаемый шард со своими строками (fold
    shards). На журнале с порванной строкой оба итога печатали «не прочитано
    0» -- не умолчание, а ЛОЖНОЕ ЧИСЛО: инструмент утверждал, что
    непрочитанного нет, глядя при этом на непрочитанную строку. Строка шарда,
    порвавшаяся точно так же, считалась. Образец поведения уже жил рядом --
    adjudicate.py на файле меток называет непарсящуюся строку и считает
    пропуск; журнал был единственным отстающим читателем набора.

    Сценарий заодно держит изоляцию прогона (см. run_compact): он утверждает,
    что ВНИМАНИЕ называет журнал ИГРУШЕЧНОГО дома. Прогон, ушедший в живой дом
    проб, назвал бы другой путь и упал бы здесь же.

    Половина Б -- положительный контроль: та же фикстура без порванной строки
    обязана дать ноль и НИ ОДНОГО ВНИМАНИЯ. Без неё «назвал 1» неотличимо от
    «называет всегда».
    """
    with tempfile.TemporaryDirectory() as raw:
        home, records = build_journal_home(Path(raw), torn=True)
        journal = home / "judge" / "journal.jsonl"
        counters, output = run_compact(records, older_than_hours=24, home=home)

        require(
            f"{journal}:2 не разбирается" in output,
            f"порванная строка не названа координатой {journal}:2\n{output}",
        )
        require("NUL: да" in output,
                f"подпись оборванной записи (NUL) не названа\n{output}")
        named = output.count("не разбирается")
        require(named == 2,
                f"порванную строку назвали {named} раз вместо 2 (по разу на "
                f"свёртку: проходы независимы)\n{output}")
        counted = output.count("строк журнала не разобрано 1")
        require(counted == 2,
                f"итог со счётом порванных строк напечатан {counted} раз "
                f"вместо 2\n{output}")
        require_counters(counters, done=0, skipped=1)

    with tempfile.TemporaryDirectory() as raw:
        home, records = build_journal_home(Path(raw), torn=False)
        counters, output = run_compact(records, older_than_hours=24, home=home)
        require("ВНИМАНИЕ" not in output,
                f"целый журнал вызвал ВНИМАНИЕ\n{output}")
        zeroed = output.count("строк журнала не разобрано 0")
        require(zeroed == 2,
                f"на целом журнале ноль напечатан {zeroed} раз вместо 2: "
                f"молчащее число ничем не лучше молчащего разбора\n{output}")
        require_counters(counters, done=0, skipped=1)


# --- волна 205: горизонт архива compact.py -----------------------------------
#
# Граница роста архива назначена авторами ядра ВЛАДЕЛЬЦУ архива (tweakcc-patch.js,
# блок о records_keep: «если когда-нибудь понадобится граница, её место у
# compact.py, где живут правила возраста»). Зубы ниже держат эту границу:
# возраст, а не количество; ручка окружения; надгробие; отказ прибора; гонки.


def scenario_51() -> None:
    """Возраст решает, ручка задаёт рубеж: старше унесено, моложе остаётся.

    Граница ПО ВОЗРАСТУ, а не «последние N штук»: архив -- доказательная база
    замеров, количество выкашивает историю неравномерно. Рубеж -- ручка
    окружения $CLAUDE_JUDGE_ARCHIVE_DAYS с умолчанием 180 суток.
    """
    for days_env, expect_old, expect_young in (
        (None, False, True),      # умолчание 180: 200 суток унесено, 100 остаётся
        ("90", False, False),     # ручка сужает рубеж: унесены ОБЕ
        ("300", True, True),      # ручка расширяет рубеж: остаются ОБЕ
    ):
        with tempfile.TemporaryDirectory() as raw:
            base = Path(raw)
            records = base / "records"
            records.mkdir()
            old = records / "old.json.gz"
            young = records / "young.json.gz"
            write_archive(old, {"marker": "old"})
            write_archive(young, {"marker": "young"})
            age_to(old, 200)
            age_to(young, 100)
            extra = None if days_env is None else {"CLAUDE_JUDGE_ARCHIVE_DAYS": days_env}
            counters, _ = run_compact(records, home=base, extra_env=extra)
            label = days_env or "умолчание 180"
            require(old.exists() is expect_old,
                    f"рубеж {label}: архив старше горизонта не унесён: {old.name}")
            require(young.exists() is expect_young,
                    f"рубеж {label}: архив моложе горизонта не остался: {young.name}")
            taken = (0 if expect_old else 1) + (0 if expect_young else 1)
            require_counters(counters, arch_taken=taken, arch_vanished=0)
            if taken:
                require(counters["arch_bytes"] > 0,
                        "унесённые архивы не дали ни одного байта")


def scenario_52() -> None:
    """Горячие .json горизонтом не трогаются вовсе: их владелец -- ядро.

    Окно ядра (records_keep) держит несжатые записи по своему счётчику; второй
    владелец на том же файле -- дефект. Сухой прогон выбирает его потому, что
    боевой прогон успевает СЖАТЬ старый .json раньше горизонта, и у горизонта
    тот уже не .json.
    """
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)
        records = base / "records"
        records.mkdir()
        hot = records / "hot.json"
        write_record(hot, "hot")
        age_to(hot, 400)
        counters, output = run_compact(records, home=base, older_than_hours=24,
                                       dry_run=True)
        require(hot.exists(), "dry-run удалил горячий .json")
        require("сжал бы: hot.json" in output,
                "фикстура не дошла до сжатия: dry-run её не назвал")
        require("унёс бы архив: hot.json" not in output,
                f"горизонт тронул горячий .json: {hot.name} -- его владелец ядро")
        require_counters(counters, arch_taken=0)


def scenario_53() -> None:
    """Обломок <имя>.json.gz.tmp.<pid> не считается архивом горизонта.

    У обломка свой владелец -- прополка tmp выше по этому же проходу; положить
    его в кандидаты горизонта значило бы снять чужое имя. Обломок состарен
    ЗАВЕДОМО больше рубежа: иначе его защищал бы сам возраст, а не форма имени.
    """
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)
        records = base / "records"
        records.mkdir()
        frag = records / f"frag.json.gz.tmp.{dead_pid()}"
        frag.write_text("tmp", encoding="utf-8")
        age_to(frag, 400)
        old = records / "old.json.gz"
        write_archive(old, {"marker": "old"})
        age_to(old, 400)
        counters, output = run_compact(records, home=base, dry_run=True)
        require(f"снёс бы сироту tmp: {frag.name}" in output,
                "прополка tmp не назвала обломок -- фикстура вне её поля зрения")
        require(f"унёс бы архив: {old.name}" in output,
                "горизонт не назвал настоящий архив кандидатом")
        require(f"унёс бы архив: {frag.name}" not in output,
                f"обломок tmp назван архивом горизонта: {frag.name}")
        require_counters(counters, arch_taken=1, orphans=1)
        require(frag.exists() and old.exists(), "dry-run что-то удалил")
        counters, _ = run_compact(records, home=base)
        require(not frag.exists(), "боевой прогон не снял обломок tmp")
        require(not old.exists(), "боевой прогон не унёс настоящий архив")
        require_counters(counters, orphans=1, arch_taken=1)


def scenario_54() -> None:
    """Надгробие пишется и несёт метку, до которой пропалывали.

    Указатель улики в журнале уже умеет отличать «улики нет» от «улика на
    месте» (#172); без отметки «улику законно унёс горизонт» стал бы третьим,
    неразличимым значением того же указателя. Отметка -- не журнал: рост
    ограничен числом прогонов HORIZON_KEEP_RUNS, голова -- последний прогон.
    """
    module = import_tool("compact")
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)
        records = base / "records"
        records.mkdir()
        old = records / "old.json.gz"
        young = records / "young.json.gz"
        write_archive(old, {"marker": "old"})
        write_archive(young, {"marker": "young"})
        age_to(old, 200)
        age_to(young, 10)
        started = time.time()
        counters, _ = run_compact(records, home=base)
        require_counters(counters, arch_taken=1)
        require(not old.exists() and young.exists(), "фикстура прогона не сошлась")
        mark = base / "horizon.json"
        require(mark.is_file(), "отметка горизонта не написана")
        data = json.loads(mark.read_text(encoding="utf-8"))
        runs = data.get("runs")
        require(isinstance(runs, list) and len(runs) == 1,
                f"отметка не несёт записи прогона: {data!r}")
        entry = runs[0]
        require(entry.get("removed") == 1,
                f"отметка не несёт число унесённых: {entry!r}")
        require(abs(entry.get("horizon_epoch", 0) - (started - 180 * 86400)) < 300,
                f"метка рубежа не сходится с умолчанием 180 суток: {entry!r}")
        require(started - 300 <= entry.get("run_epoch", 0) <= time.time() + 300,
                f"время прогона вне окна прогона: {entry!r}")
        # Рост ограничен: хвост истории обрезан до HORIZON_KEEP_RUNS записей,
        # голова -- текущий прогон.
        fabricated = [{"horizon_epoch": float(i), "removed": 0, "run_epoch": float(i)}
                      for i in range(80)]
        fresh = {"horizon_epoch": 1.0, "removed": 2, "run_epoch": 2.0}
        merged = module._horizon_merged(fabricated, fresh, module.HORIZON_KEEP_RUNS)
        require(len(merged) == module.HORIZON_KEEP_RUNS,
                f"история отметки не обрезана до {module.HORIZON_KEEP_RUNS}: {len(merged)}")
        require(merged[0] is fresh, "голова истории -- не текущий прогон")
        # Повторный прогон ДОПИСЫВАЕТ запись, а не перезаписывает историю.
        write_archive(old, {"marker": "old2"})
        age_to(old, 200)
        run_compact(records, home=base)
        runs2 = json.loads(mark.read_text(encoding="utf-8"))["runs"]
        require(len(runs2) == 2, f"повторный прогон не дописал запись: {runs2!r}")
        require(runs2[0].get("removed") == 1 and runs2[1].get("removed") == 1,
                f"записи истории не несут свои числа: {runs2!r}")
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)
        records = base / "records"
        records.mkdir()
        aged = records / "aged.json.gz"
        write_archive(aged, {"marker": "aged"})
        age_to(aged, 200)
        run_compact(records, home=base, dry_run=True)
        require(not (base / "horizon.json").exists(),
                "dry-run написал отметку горизонта: сухой прогон не пишет ничего")


def scenario_55() -> None:
    """Отказ прибора отличим: ненулевой код с причиной, а не «нечего уносить».

    ПУСТО != НОЛЬ: пустой список кандидатов -- штатный прогон, нечитаемый
    каталог, непишущаяся отметка и мусор в ручке -- отказ по существу (код 1),
    причём отказ обязан случиться ДО первого снятия.
    """
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)
        records = base / "records"
        records.mkdir()
        aged = records / "aged.json.gz"
        write_archive(aged, {"marker": "aged"})
        age_to(aged, 200)
        os.chmod(records, 0)
        try:
            done = run_compact_raw(base, records)
        finally:
            os.chmod(records, 0o755)
        require(done.returncode == 1,
                f"нечитаемый каталог дал rc={done.returncode}, ожидался 1")
        require("ОТКАЗ" in done.stderr and "не читается" in done.stderr,
                f"отказ не назвал причину словами: {done.stderr.strip()!r}")
        require(aged.exists(), "нечитаемый каталог всё же что-то унёс")
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)
        records = base / "records"
        records.mkdir()
        aged = records / "aged.json.gz"
        write_archive(aged, {"marker": "aged"})
        age_to(aged, 200)
        os.chmod(base, 0o555)
        try:
            done = run_compact_raw(base, records)
        finally:
            os.chmod(base, 0o755)
        require(done.returncode == 1,
                f"непишущаяся отметка дала rc={done.returncode}, ожидался 1")
        require("ОТКАЗ" in done.stderr and "не пишется" in done.stderr,
                f"отказ не назвал причину словами: {done.stderr.strip()!r}")
        require(aged.exists(),
                "прогон унёс архив, не сумев отметиться: удаление без объяснения")
    with tempfile.TemporaryDirectory() as raw:
        base = Path(raw)
        records = base / "records"
        records.mkdir()
        done = run_compact_raw(base, records,
                               extra_env={"CLAUDE_JUDGE_ARCHIVE_DAYS": "месяц"})
        require(done.returncode == 1,
                f"мусор в ручке дал rc={done.returncode}, ожидался 1")
        require("CLAUDE_JUDGE_ARCHIVE_DAYS" in done.stderr,
                f"отказ не назвал ручку: {done.stderr.strip()!r}")


def scenario_56() -> None:
    """Исчезнувший под руками архив -- ожидаемый исход, а не отказ.

    Свойство пинится ФОРМОЙ и это объявлено (тот же приём, что у сценариев
    17-18 и 27): подменить или убрать файл между stat и unlink ВНУТРИ чужого
    процесса стенду нечем. Пинится ветка снятия: гонка с прополкой ядра и со
    вторым своим проходом -- тот же класс, что у цикла сжатия (см. комментарий
    у него в compact.py), исчезнувшее -- цель прогона, а не его поломка.
    """
    text = COMPACT.read_text(encoding="utf-8")
    start = text.find("os.unlink(path)")
    require(start >= 0, "ветка снятия архива горизонта не найдена по якорю")
    arm = text[start:start + 400]
    require("except FileNotFoundError:" in arm,
            "снятие архива горизонта не ловит исчезновение файла")
    require("HorizonRefusal" not in arm and "ОТКАЗ" not in arm,
            "исчезнувший под руками архив снова становится отказом")
    require("vanished'] += 1" in arm,
            "исчезнувший под руками архив не считается своим счётчиком")


def scenario_57() -> None:
    """Прибор на месте -- ещё не доказательство, что он видит открытия.

    Волна 230: с полностью ослеплённым opener_match оба стенда проходили
    самопроверку целиком -- зелёный вердикт над слепым прибором. Негодный
    прибор обязан отказывать стенду кодом «не могу мерить» с названной
    причиной, а вызов зубов -- выполняться при старте.
    """
    require(ANCHOR_TEETH_RAN, "вызов зубов якоря при старте не выполнялся")
    def _broken_teeth() -> None:
        print("ЯКОРЬ HEREDOC ПОТЕРЯЛ ФОРМУ: синтетика сценария 57")
        sys.exit(1)
    saved = _anchor.self_check
    _anchor.self_check = _broken_teeth
    try:
        with contextlib.redirect_stdout(io.StringIO()) as captured:
            try:
                _anchor_teeth_hold()
            except SystemExit as error:
                require(error.code == 2, f"код отказа {error.code}, а не 2")
            else:
                raise BenchFailure("ослеплённый якорь принят: стенд мерил бы дальше")
    finally:
        _anchor.self_check = saved
    out = captured.getvalue()
    require("НЕ ДЕРЖИТ ФОРМУ" in out and "синтетика сценария 57" in out,
            f"отказ без названной причины: {out!r}")


# --- волна 227b: список проб за один прогон владельца прополки ---------------
#
# Журнал лестницы failover пишется ШАРДОМ НА КАЖДУЮ ЗАПИСЬ (у хоста нет глагола
# дописывания: моду доступны ровно $.fs.read/$.fs.write) -- 1664 файла/ч, и
# владельцем его прополки назначен тот же compact.py: второй агент, обёртка и
# вторая копия расписания НЕ заводятся. Зубы ниже держат список проб, худший
# код, контракт списка и ценз покрытия агента.


def build_probe_shard(base: Path, probe: str) -> Path:
    """Проба с журналом, СВОИМ шардом и пустым records; путь журнала.

    Форма шарда -- боевого носителя: одна строка JSON рядом с journal.jsonl
    пробы; fold_journal_shards сворачивает такие и сносит после обратного
    чтения. records обязан существовать: горизонт на отсутствующем каталоге
    уходит в тихий ранний возврат, а разбору нужна итоговая строка КАЖДОЙ
    пробы.
    """
    probe_dir = base / probe
    (probe_dir / "records").mkdir(parents=True)
    journal = probe_dir / "journal.jsonl"
    journal.write_text("", encoding="utf-8")
    shard = probe_dir / (journal.name + f".shard.mod-{probe}.json")
    shard.write_text(
        f'{{"rec": "mod-{probe}.json", "carrier": "mod"}}\n', encoding="utf-8")
    return journal


def scenario_58() -> None:
    """Две пробы за один прогон: обе свёрнуты, у каждой строки свой префикс.

    До волны 227b --probe принимал ОДНУ пробу, и агент на умолчании judge не
    пропалывал failover вовсе. Разбор прогона -- «ровно одна итоговая строка
    НА ПРОБУ» (run_compact_probes); здесь держится ЭФФЕКТ обеих свёрток и
    СВОЙ префикс у каждой строки вывода.
    """
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        journals = {probe: build_probe_shard(home, probe)
                    for probe in ("judge", "failover")}
        counters, output = run_compact_probes(home, ["judge", "failover"])

        require("[judge] fold shards: добавлено 1" in output,
                f"строки пробы judge не несут свой префикс\n{output}")
        require("[failover] fold shards: добавлено 1" in output,
                f"строки пробы failover не несут свой префикс\n{output}")
        for probe, journal in journals.items():
            leftovers = [p.name for p in journal.parent.iterdir()
                         if p.name.startswith(journal.name + ".shard.")]
            require(not leftovers,
                    f"проба {probe}: шард не снесён после свёртки: {leftovers}")
            require(f'"rec": "mod-{probe}.json"'
                    in journal.read_text(encoding="utf-8"),
                    f"проба {probe}: строка шарда не вложена в её журнал")
        require_counters(counters["judge"], done=0, skipped=0)
        require_counters(counters["failover"], done=0, skipped=0)


def scenario_59() -> None:
    """Худший код побеждает: отказ одной пробы не спрятан успехом соседней.

    Итоговый код прогона -- ХУДШИЙ из проб (2 бьёт 1, 1 бьёт 0): тихий успех
    одной пробы не имеет права спрятать отказ другой. Отказ по существу -- у
    пробы judge (каталог пробы читаем, но отметка горизонта в него не
    пишется), failover в том же прогоне проходит штатно. Успех соседней пробы
    держится ЭФФЕКТОМ на диске, а не строкой вывода.
    """
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        failover = build_probe_shard(home, "failover")
        # records у judge обязан СУЩЕСТВОВАТЬ: горизонт на отсутствующем
        # каталоге уходит в тихий ранний возврат, а отказ нужен по существу.
        (home / "judge" / "records").mkdir(parents=True)
        os.chmod(home / "judge", 0o555)
        try:
            done = run_compact_probes_raw(home, ["judge", "failover"])
        finally:
            os.chmod(home / "judge", 0o755)
        output = done.stdout + done.stderr
        require(done.returncode == 1,
                f"отказ по существу не победил: rc={done.returncode}, ожидался 1\n{output}")
        require("[judge] ОТКАЗ ГОРИЗОНТА" in output,
                f"отказ пробы judge не назван её именем\n{output}")
        leftovers = [p.name for p in failover.parent.iterdir()
                     if p.name.startswith(failover.name + ".shard.")]
        require(not leftovers,
                f"успех второй пробы проглочен: шард failover не снесён: {leftovers}")
        require('"rec": "mod-failover.json"' in failover.read_text(encoding="utf-8"),
                "успех второй пробы проглочен: строка шарда failover не в её журнале")


def scenario_60() -> None:
    """Пустой элемент списка проб -- отказ контракта кодом 2, а не пропуск.

    «judge,» и «--probe ""» -- опечатка владельца; молчаливый пропуск элемента
    превращал бы её в прогон неизвестно чего. Отказ обязан назвать причину и
    не тронуть НИ ОДНОГО файла дома: проход не начался.
    """
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        build_probe_shard(home, "judge")

        def snapshot() -> dict[str, bytes]:
            return {str(p.relative_to(home)): p.read_bytes()
                    for p in sorted(home.rglob("*")) if p.is_file()}

        before = snapshot()
        done = run_compact_probes_raw(home, ["judge", ""])
        output = done.stdout + done.stderr
        require(done.returncode == 2,
                f"пустой элемент списка проб не отвергнут кодом 2 (rc={done.returncode})\n{output}")
        require("пустой элемент" in output and "--probe" in output,
                f"отказ не назвал причину: пустой элемент списка --probe\n{output}")
        require(snapshot() == before,
                "отказ контракта тронул файлы дома -- проход не должен был начаться")


def scenario_61() -> None:
    """Ценз покрытия: агент без failover в аргументах -- красная строка.

    Проверка цели агента (сценарий 19) сверяет, ЧТО запускает агент, и не
    видит, КАКИЕ ПРОБЫ: машина, где агент остался на умолчании judge,
    выглядела зелёной, а журнал лестницы failover не пропалывал никто (волна
    227b). Образец plist -- из кита, пути подставлены на игрушечные дома, как
    у сценария 29: канон -- плейсхолдеры, живой агент -- заполненный файл.
    """
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        kit = toy_kit(base)
        home, tools, agents = base / "p", base / "t", base / "la"
        agents.mkdir()

        done = run_sync(kit, "--to-home", home, tools, agents)
        if done.returncode == 3:
            raise CannotMeasureNow(
                f"замок дома держит другой писатель: {done.stderr.strip()}")
        require(done.returncode == 0, f"раскатка в игрушечный дом провалилась: {done.stderr}")

        sample = (kit / "judge" / "com.transmutelabs.judge-compact.plist").read_text(
            encoding="utf-8")
        filled = sample.replace("/Users/YOUR-USER/.claude/judge", str(tools))
        agent = agents / "com.toy.judge-compact.plist"

        agent.write_text(filled, encoding="utf-8")
        done = run_sync(kit, "--diff", home, tools, agents)
        out = done.stdout + done.stderr
        require(done.returncode == 0,
                f"агент с --probe judge,failover не должен краснить: {out}")

        agent.write_text(
            filled.replace("<string>judge,failover</string>", "<string>judge</string>"),
            encoding="utf-8")
        done = run_sync(kit, "--diff", home, tools, agents)
        out = done.stdout + done.stderr
        require(done.returncode == 1,
                f"агент без failover не краснит (rc={done.returncode})\n{out}")
        require("агент com.toy.judge-compact.plist не покрывает пробу failover" in out,
                f"класс непокрытия не назван\n{out}")


def scenario_62() -> None:
    """Отказ I/O одной пробы изолирован: соседняя выполняется, код -- 1.

    Доработка волны: цикл ловил только HorizonRefusal, а запись журнала в
    fold_journal_shards идёт open(..., 'a') без охраны -- непишущийся журнал
    пробы judge (права, ENOSPC) ронял весь прогон ТРЕЙСБЕКОМ, и failover не
    выполнялся вовсе при обещании обратного. Изолируется ровно OSError:
    ошибки программиста (TypeError и прочие) обязаны падать громко.
    """
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        judge = build_probe_shard(home, "judge")
        failover = build_probe_shard(home, "failover")
        os.chmod(judge, 0o444)
        try:
            done = run_compact_probes_raw(home, ["judge", "failover"])
        finally:
            os.chmod(judge, 0o644)
        output = done.stdout + done.stderr
        require(done.returncode == 1,
                f"отказ пробы не изолирован: rc={done.returncode}, ожидался 1\n{output}")
        require("[judge] ОТКАЗ ПРОХОДА" in output,
                f"отказ I/O пробы не назван её именем\n{output}")
        require("Traceback" not in output,
                f"изоляция отдаёт трейсбек вместо причины\n{output}")
        leftovers = [p.name for p in failover.parent.iterdir()
                     if p.name.startswith(failover.name + ".shard.")]
        require(not leftovers,
                f"соседняя проба не выполнена после отказа judge: {leftovers}")
        require('"rec": "mod-failover.json"' in failover.read_text(encoding="utf-8"),
                "соседняя проба не выполнена после отказа judge: строка не в журнале")


def scenario_63() -> None:
    """Имя пробы -- ПРОСТОЙ СЕГМЕНТ: опечатка не уводит проход за дом.

    Замер контроллера на первой редакции: --probe "judge, failover" шёл в
    каталог с ВЕДУЩИМ ПРОБЕЛОМ в имени, --probe "../escaped" -- за пределы
    дома проб. Проход УДАЛЯЕТ файлы (шарды, архивы горизонта), поэтому имя с
    пробельными символами, разделителем пути, точка-имя и пустое после
    обрезки -- отказ контракта кодом 2 с показом негодного имени, ДО начала
    прохода.
    """
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        build_probe_shard(home, "judge")

        def snapshot() -> dict[str, bytes]:
            return {str(p.relative_to(home)): p.read_bytes()
                    for p in sorted(home.rglob("*")) if p.is_file()}

        for bad, cls in ((" failover", "пробельные символы"),
                         ("../escaped", "разделитель пути"),
                         ("..", "имя-точка"),
                         (" ", "пустой элемент")):
            before = snapshot()
            done = run_compact_probes_raw(home, ["judge", bad])
            output = done.stdout + done.stderr
            require(done.returncode == 2,
                    f"имя пробы не отвергнуто кодом 2 (rc={done.returncode}): {bad!r}\n{output}")
            require(repr(bad) in output and cls in output,
                    f"отказ не назвал имя и класс негодности: {bad!r} / {cls}\n{output}")
            require(snapshot() == before,
                    f"отказ имени тронул дом: {bad!r}")


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
        (35, scenario_35),
        (36, scenario_36),
        (37, scenario_37),
        (38, scenario_38),
        (39, scenario_39),
        (40, scenario_40),
        (41, scenario_41),
        (42, scenario_42),
        (43, scenario_43),
        (44, scenario_44),
        (45, scenario_45),
        (46, scenario_46),
        (47, scenario_47),
        (48, scenario_48),
        (49, scenario_49),
        (50, scenario_50),
        (51, scenario_51),
        (52, scenario_52),
        (53, scenario_53),
        (54, scenario_54),
        (55, scenario_55),
        (56, scenario_56),
        (57, scenario_57),
        (58, scenario_58),
        (59, scenario_59),
        (60, scenario_60),
        (61, scenario_61),
        (62, scenario_62),
        (63, scenario_63),
    ]
    mismatches = 0
    for number, case in cases:
        try:
            case()
        except CannotMeasureNow as error:
            # Класс 3 общей таблицы кита: не вердикт о продукте, а «сейчас
            # нельзя». Счёт расхождений НЕ трогается -- иначе занятый замок
            # читался бы как непрошедшее свойство.
            print(f"judge-tools-bench: СЦЕНАРИЙ {number}: НЕ МЕРИЛ -- {error}")
            return 3
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


def shell_python_heredocs(text: str) -> list[str]:
    """Тела heredoc'ов .sh-жертвы, поданные питону.

    Правило открытия живёт в единственном доме tools/heredoc-anchor.py
    (загружен в голове файла); здесь только прогулка по строкам: тело --
    всё между открытием и строкой, равной тегу дословно. Незакрытый heredoc --
    отказ разбора (UnparsableVictim), а не молчаливый хвост до конца файла:
    тело, которого страж не видел, неотличимо от проверенного.
    """
    bodies: list[str] = []
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        match = opener_match(lines[i])
        if match is None:
            i += 1
            continue
        tag = match.group(1)
        end = next((j for j in range(i + 1, len(lines)) if lines[j] == tag), -1)
        if end < 0:
            raise UnparsableVictim(f"heredoc {tag} не закрыт в {lines[i]!r}")
        bodies.append("\n".join(lines[i + 1:end]))
        i = end + 1
    return bodies


def victim_parses(path: Path) -> None:
    """Разбор жертвы её СОБСТВЕННЫМ разборщиком; иначе -- UnparsableVictim.

    Круг 25, E-3: до этого стража замена влетала в жертву свободным текстом,
    и сломанный разбор эксплуатировался только СЛУЧАЙНО -- следи мутации за
    маркером состояния, а не за кодом возврата, и любая синтаксическая
    поломка на строке со своим следом читалась бы как зуб. У .py-жертв
    вложенных тел под другим интерпретатором нет (внешние вызовы идут
    файлами-скриптами), у .sh-жертв питоньи heredoc-тела разбираются тем же
    правилом, что и в corpus-tools-bench (круг 25, E-1). Для .js отдельного
    разборщика у кита нет (bun/node не обязаны стоять на машине стенда) --
    жертва tools/probe-bench.js остаётся без этого стража, и это объявлено:
    первая же мутация со следом-маркером состояния по .js-жертве обязана
    завести его, а не полагаться на случайность.
    """
    if path.suffix == ".py":
        try:
            py_compile.compile(str(path), doraise=True)
        except py_compile.PyCompileError as error:
            raise UnparsableVictim(f"py_compile {path}: {error}") from error
    elif path.suffix == ".sh":
        done = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True, errors="replace")
        if done.returncode != 0:
            raise UnparsableVictim(f"bash -n {path}: {(done.stderr or '').strip()}")
        for body in shell_python_heredocs(path.read_text(encoding="utf-8")):
            try:
                compile(body, f"heredoc@{path}", "exec")
            except SyntaxError as error:
                raise UnparsableVictim(
                    f"heredoc-тело в {path}: строка {error.lineno}: {error.msg}") from error


BUSY_LOCK_ARM = (
    '        echo "ОТКАЗ: другой писатель синхронизации держит $SYNC_LOCK '
    '(узнать держателя: lsof $SYNC_LOCK)" >&2\n'
    "        exit 3\n      fi\n"
)


def replace_once(path: Path, old: str, new: str, mutation: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    require(count == 1, f"{mutation}: якорь встретился {count} раз в {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    victim_parses(path)


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
        "                    _say(probe, f'удалил бы исходник (архив рядом целый): {os.path.basename(f)}')\n"
        "                    done += 1\n                    continue\n",
        "                    _say(probe, f'удалил бы исходник (архив рядом целый): {os.path.basename(f)}')\n"
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
        "        if a.dry_run:\n            _say(probe, f'снёс бы сироту tmp: ",
        "        if a.dry_run:\n            os.unlink(t)\n            _say(probe, f'снёс бы сироту tmp: ",
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
    # Якорь -- условие хранения tmp ЖИВОГО pid целиком (с аркой метки из
    # будущего, волна 25B): мутация снимает только АРМ ВОЗРАСТА.
    replace_once(
        root / "judge" / "compact.py",
        "            if age < TMP_HELD_SECONDS and before.st_mtime <= time.time() + 60:\n",
        "            if before.st_mtime <= time.time() + 60:\n",
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
def mutation_m31(root: Path) -> None:
    # Возврат к прежнему окну: словарь живой формы снова не находится.
    replace_once(
        root / "judge" / "replay.py",
        '(?:(?!dirName:")[^\\n]){0,4000}?',
        '(?:(?!dirName:")[^\\n]){0,160}?',
        "M31",
    )


def mutation_m33(root: Path) -> None:
    replace_once(
        root / "judge" / "compact.py",
        "            if age < TMP_HELD_SECONDS and before.st_mtime <= time.time() + 60:\n",
        "            if age < TMP_HELD_SECONDS:\n",
        "M33",
    )


def mutation_m32(root: Path) -> None:
    # Снятие запрета на пересечение границы: проба без словаря крадёт соседний.
    replace_once(
        root / "judge" / "replay.py",
        '(?:(?!dirName:")[^\\n]){0,4000}?',
        '[^\\n]{0,4000}?',
        "M32",
    )


# M34-M43 -- зубы круга 25, E-4: часть дверей стенда жила без своей мутации,
# и сверка покрытия (введена той же волной) отказывала бы на них. Каждая
# мутация ниже ломает МЕХАНИЗМ, который утверждает её сценарий, а не синтаксис
# -- страж разбираемости (E-3) любую синтаксическую поломку остановил бы
# кодом «прибор не может мерить». Двери, разделяющие один механизм (снятие
# сироты, удержание живого писателя, исходник-после-сжатия), краснеют от
# мутации вместе со своей -- сверка проверяет названную дверь и её причину.
def mutation_m34(root: Path) -> None:
    # Возрастная калитка снята: свежая запись уходит в сжатие вместо пропуска.
    replace_once(
        root / "judge" / "compact.py",
        "        if mtime > cutoff:",
        "        if False:",
        "M34",
    )


def mutation_m35(root: Path) -> None:
    # Исходник не снимается после успешного сжатия: рядом с архивом остаётся
    # дубль. Дверь оборванного сжатия разделяет этот механизм и краснеет
    # вместе со своей -- у неё есть собственный зуб M36 на решение о пересжатии.
    replace_once(
        root / "judge" / "compact.py",
        "        try:\n            os.unlink(f)\n        except FileNotFoundError:\n            pass",
        "        try:\n            pass  # M35: источник не снимается после сжатия\n"
        "        except FileNotFoundError:\n            pass",
        "M35",
    )


def mutation_m36(root: Path) -> None:
    # Нечитаемый сосед-архив объявляется целым: пересжатие не запускается,
    # битый архив остаётся лежать рядом с неснятым исходником.
    replace_once(
        root / "judge" / "compact.py",
        "                try:\n                    os.unlink(gz)\n"
        "                except FileNotFoundError:\n"
        "                    pass          # архив уже убран — пересжимаем всё равно\n"
        "                _say(probe, f'ОБОРВАННОЕ СЖАТИЕ, архив не читается -- пересжимаю: {os.path.basename(f)}: {e}')\n"
        "                recompress = True",
        "                done += 1\n                continue",
        "M36",
    )


def mutation_m37(root: Path) -> None:
    # Обратное чтение архива вырвано: битый json сжимается и снимается,
    # сжатие превращается в потерю материала -- ровно то, что запрещает
    # комментарий у этой ветки в compact.py.
    replace_once(
        root / "judge" / "compact.py",
        "        try:\n            with gzip.open(tmp, 'rt', encoding='utf-8') as fh:\n"
        "                json.load(fh)\n        except Exception as e:",
        "        try:\n            with gzip.open(tmp, 'rt', encoding='utf-8') as fh:\n"
        "                pass  # M37: обратное чтение вырвано\n        except Exception as e:",
        "M37",
    )


def mutation_m38(root: Path) -> None:
    # Мёртвый pid считается живым: осиротевший tmp не снимается никогда.
    # Двери dry-run-сироты и переиспользованного номера разделяют механизм
    # снятия и краснеют вместе со своей.
    replace_once(
        root / "judge" / "compact.py",
        "        except ProcessLookupError:\n            pass                       # pid мёртв -- файл ничей",
        "        except ProcessLookupError:\n            continue                  # M38: мёртвый pid держится как живой",
        "M38",
    )


def mutation_m39(root: Path) -> None:
    # Удержание свежего tmp живого писателя вырвано: файл падает сквозь
    # проверку в снятие. Двери возрастного порога и метки из будущего имеют
    # собственные зубы M29/M33 на свои армы условия.
    replace_once(
        root / "judge" / "compact.py",
        "                tmp_held += 1\n                continue               # живой писатель, файл свежий",
        "                pass                   # M39: свежий tmp живого писателя проваливается в снятие",
        "M39",
    )


def mutation_m40(root: Path) -> None:
    # Пропуск свежей записи заодно считается «исчезновением под руками»:
    # ложные исчезновения появляются в нормальном прогоне, и надсценарная
    # дверь, собирающая счётчики всех прогонов, обязана это назвать.
    replace_once(
        root / "judge" / "compact.py",
        "        if mtime > cutoff:\n            skipped += 1\n            continue",
        "        if mtime > cutoff:\n            skipped += 1\n            vanished += 1\n            continue",
        "M40",
    )


def mutation_m41(root: Path) -> None:
    # Мёртвый pid лаунчера считается живым: осиротевшая ссылка не снимается.
    # Дверь подмены после проверки разделяет механизм снятия и краснеет
    # вместе со своей (у неё собственный зуб M6 на сверку inode).
    replace_once(
        root / "claude_patch.py",
        "        except ProcessLookupError:\n            pass                       # pid мёртв — свап уже не случится",
        "        except ProcessLookupError:\n            continue                  # M41: мёртвый pid держится как живой",
        "M41",
    )


def mutation_m42(root: Path) -> None:
    # Удержание живого pid вырвано: чужая рабочая ссылка снимается, и её
    # собственный os.replace падает после подмены образа -- ровно то, чему
    # посвящён абзац сдержанности в docstring прополки.
    replace_once(
        root / "claude_patch.py",
        "        else:\n            continue                   # жив",
        "        else:\n            pass                       # M42: живой pid проваливается в снятие",
        "M42",
    )


def mutation_m43(root: Path) -> None:
    # Импорт снова требует НАЛИЧИЯ образа: одна проверка файла на импорте --
    # и adjudicate не импортируется на машине без образа, дефект, который
    # закрывала ленивость чтения. Проверяется именно существование, а не
    # чтение словаря: соседняя дверь сеет словарь ПУСТЫМ файлом-образом
    # (кэшем, не байтами), и чтение роняло её вместо своей.
    replace_once(
        root / "judge" / "adjudicate.py",
        "if __name__ == '__main__':\n    main()",
        "if os.environ.get('CLAUDE_JUDGE_IMAGE'):\n"
        "    os.stat(os.environ['CLAUDE_JUDGE_IMAGE'])\n"
        "\n"
        "\n"
        "if __name__ == '__main__':\n    main()",
        "M43",
    )


def mutation_m44(root: Path) -> None:
    """Занятый замок отвечает классом 1 вместо 3.

    Зуб сценария 37. Ронять «занято» в отказ по существу -- ровно тот дефект,
    что круг 25 и вскрыл: вызывающий перестаёт отличать «повторить позже» от
    «свойство не держится». Обе ступени лестницы замка правятся: какая из них
    сработает, зависит от машины (flock(1) есть не везде), и мутация, задевшая
    только одну, молча прошла бы там, где живёт другая.
    """
    for tail in ("      echo \"NOTE: flock(1) не сработал",
                 "      echo \"NOTE: perl flock(2) не сработал"):
        replace_once(
            root / "scripts" / "probes-sync.sh",
            BUSY_LOCK_ARM + tail,
            BUSY_LOCK_ARM.replace("exit 3", "exit 1                    # M44") + tail,
            "M44",
        )


# M45-M52 -- зубы волны 31, бриф 3 (круг 26: K-5/K-6/K-7/K-13/K-14 + L-4/L-5).
def mutation_m45(root: Path) -> None:
    # --limit снова пропускает минус: files[-limit:] молча теряет записи.
    replace_once(
        root / "judge" / "validate.py",
        "    run.add_argument('--limit', type=replay.nonneg_int, default=0)",
        "    run.add_argument('--limit', type=int, default=0)",
        "M45",
    )


def mutation_m46(root: Path) -> None:
    # --timeout снова принимает всё подряд: миллисекундная описка из соседнего
    # toml превращается в прогон на ~67 часов вместо громкого отказа.
    replace_once(
        root / "judge" / "validate.py",
        "type=replay.bounded_float('--timeout', 0.001, 86400,\n"
        "                                               NOTE_TIMEOUT_UNITS))",
        "type=float)",
        "M46",
    )


def mutation_m47(root: Path) -> None:
    # --older-than-hours снова пропускает минус и nan: cutoff уезжает в
    # будущее, сжимается всё живое, код 0 выглядит штатным проходом.
    replace_once(
        root / "judge" / "compact.py",
        "    p.add_argument('--older-than-hours', type=replay.bounded_float(\n"
        "        '--older-than-hours', 0, 876000), default=24)\n",
        "    p.add_argument('--older-than-hours', type=float, default=24)\n",
        "M47",
    )


def mutation_m48(root: Path) -> None:
    # Молчаливый подъём параллелизма возвращается: объявленный и настоящий
    # --jobs снова разные числа.
    replace_once(
        root / "tools" / "checks-teeth.py",
        "    if opts.jobs < 1:\n",
        "    if False:\n",
        "M48",
    )


def mutation_m49(root: Path) -> None:
    # Подрезку реплик снова ведёт чужой ключ ядра: одно имя -- две операции,
    # владелец context_chars молча получает вторую.
    replace_once(
        root / "judge" / "validate.py",
        "        tail_chars = global_config.get('recompose_message_tail_chars')",
        "        tail_chars = global_config.get('context_chars')",
        "M49",
    )


def mutation_m50(root: Path) -> None:
    # Молчание о чужом ключе: прежний дефект K-6 -- тихое двойное толкование
    # настройки -- возвращается без единого сообщения.
    replace_once(
        root / "judge" / "validate.py",
        "        if 'context_chars' in global_config or 'context_chars' in project_config:\n",
        "        if False:\n",
        "M50",
    )


def mutation_m51(root: Path) -> None:
    # Существующий target снова принимается по имени: усечённая прежняя
    # копия остаётся в доказательной базе, повторный label её не чинит.
    # CONSTRAINT: якорь запинен на ОТСТУП, и отступ уехал -- строка вышла из
    # вложенного блока на уровень функции, а якорь остался восьмипробельным и
    # перестал встречаться (корень #75, «локатор пинит форму записи»). Дефект
    # прожил невидимо: контроль самопроверки падал ДО мутаций (пристинная копия
    # была красной, #195), и M51 не исполнялась вовсе. Правится на текущую
    # форму; устойчивее было бы искать по структуре, но у replace_once контракт
    # -- ровно одно текстовое вхождение, и «0 раз» он называет вслух.
    replace_once(
        root / "judge" / "validate.py",
        "    if os.path.exists(target) and _same_bytes(candidate, target):\n"
        "        return target",
        "    if os.path.exists(target):\n"
        "        return target",
        "M51",
    )


def mutation_m52(root: Path) -> None:
    # Писатель снова не восстанавливает границу строки: новая метка
    # приклеивается к обломку, читатель теряет ОБЕ.
    replace_once(
        root / "judge" / "replay.py",
        "                if fh.read(1) != b'\\n':\n"
        "                    prefix = '\\n'",
        "                if False:\n"
        "                    prefix = '\\n'",
        "M52",
    )


def mutation_m53(root: Path) -> None:
    # Ступень КОРНЯ кита снята: в дереве кита исходник лежит в корне, и без
    # неё прибор отказывает там, где предмет замера лежит рядом.
    replace_once(
        root / "judge" / "replay.py",
        "    os.path.join(KIT_ROOT, 'tweakcc-patch.js'),\n"
        "    os.path.join(TOOLS_DIR, 'tweakcc-patch.js'),\n",
        "    os.path.join(TOOLS_DIR, 'tweakcc-patch.js'),\n",
        "M53",
    )


def mutation_m54(root: Path) -> None:
    # Пропуск сверки снова МОЛЧАЛИВЫЙ: след пропадает, и «сверять было нечем»
    # становится неотличимо от «сверка прошла».
    replace_once(
        root / "judge" / "replay.py",
        "        print(f'сверка с образом ПРОПУЩЕНА: образа нет по пути {image} '\n"
        "              f'({err.__class__.__name__})', file=sys.stderr)\n"
        "        return\n",
        "        return\n",
        "M54",
    )


def mutation_m55(root: Path) -> None:
    # Сверка с образом снята: дом и поставленный образ расходятся молча.
    replace_once(
        root / "judge" / "replay.py",
        "    if shipped != home:\n",
        "    if False:\n",
        "M55",
    )


def mutation_m56(root: Path) -> None:
    # На месте отказа снова подставляется ЗАШИТЫЙ словарь -- ровно то, что
    # запрещает собственный комментарий функции.
    replace_once(
        root / "judge" / "replay.py",
        "    if home is None:\n"
        "        # Код 2, а не строка-в-SystemExit (она даёт 1) -- круг 28, F-10.\n",
        "    if home is None:\n"
        "        home = (['OK'], ['BLOCK'])\n"
        "    if False:\n"
        "        # Код 2, а не строка-в-SystemExit (она даёт 1) -- круг 28, F-10.\n",
        "M56",
    )


def mutation_m57(root: Path) -> None:
    # Ступень СОСЕДА снята (обратная к M53): раскатанный дом инструментов
    # снова не резолвится, хотя исходник лежит в нём рядом с judge/*.py.
    replace_once(
        root / "judge" / "replay.py",
        "    os.path.join(KIT_ROOT, 'tweakcc-patch.js'),\n"
        "    os.path.join(TOOLS_DIR, 'tweakcc-patch.js'),\n",
        "    os.path.join(KIT_ROOT, 'tweakcc-patch.js'),\n",
        "M57",
    )


def mutation_m58(root: Path) -> None:
    # Отказ называет ОДНУ раскладку из двух: починка снова выглядит как «не
    # тот путь» вместо «файла нет ни в одной раскладке».
    replace_once(
        root / "judge" / "replay.py",
        "', '.join(DEFAULT_SOURCES)",
        "DEFAULT_SOURCES[0]",
        "M58",
    )


def mutation_m59(root: Path) -> None:
    """Вернуть молчаливый пропуск непарсящейся строки журнала."""
    replace_once(
        root / "judge" / "compact.py",
        "        except ValueError as exc:\n"
        "            torn += 1\n"
        "            body = raw.encode('utf-8', 'surrogateescape')\n"
        "            has_nul = 'да' if b'\\x00' in body else 'нет'\n"
        "            _warn(probe,\n"
        "                  f'ВНИМАНИЕ: {journal_path}:{lineno} не разбирается ({exc}); '\n"
        "                  f'длина {len(body)} байт, NUL: {has_nul}; строка пропущена')\n"
        "            continue\n",
        "        except ValueError:\n"
        "            continue\n",
        "M59",
    )


def mutation_m60(root: Path) -> None:
    """Снять счёт порванных строк с итога fold mod, оставив сам счётчик."""
    replace_once(
        root / "judge" / "compact.py",
        "    _say(probe, f'fold mod: добавлено {added}, уже в индексе {skipped},"
        " не прочитано {unread}'\n"
        "         f', строк журнала не разобрано {torn}'\n",
        "    _say(probe, f'fold mod: добавлено {added}, уже в индексе {skipped},"
        " не прочитано {unread}'\n",
        "M60",
    )


# M61-M66 -- зубы волны 205: горизонт архива compact.py (возрастная граница
# роста, надгробие, отказ прибора, гонки).
def mutation_m61(root: Path) -> None:
    # Сравнение с рубежом вырвано: возраст перестаёт решать, старший архив
    # остаётся на диске -- рост ничем не ограничен снова.
    replace_once(
        root / "judge" / "compact.py",
        "        if st.st_mtime > edge:\n            continue\n",
        "        if True:\n            continue\n",
        "M61",
    )


def mutation_m62(root: Path) -> None:
    # Горизонт распространён на горячие .json: у них уже есть владелец --
    # окно ядра (records_keep), два владельца на одном файле -- дефект.
    replace_once(
        root / "judge" / "compact.py",
        "        if not name.endswith('.json.gz'):\n            continue\n",
        "        if not (name.endswith('.json') or name.endswith('.json.gz')):\n"
        "            continue\n",
        "M62",
    )


def mutation_m63(root: Path) -> None:
    # Подстрока вместо суффикса: обломок <имя>.json.gz.tmp.<pid> попадает в
    # кандидаты горизонта, хотя у него другой владелец (прополка tmp).
    replace_once(
        root / "judge" / "compact.py",
        "        if not name.endswith('.json.gz'):\n            continue\n",
        "        if '.json.gz' not in name:\n            continue\n",
        "M63",
    )


def mutation_m64(root: Path) -> None:
    # Отметка горизонта не пишется: удаление уходит без объяснения, указатель
    # улики в журнале снова двусмысленен.
    replace_once(
        root / "judge" / "compact.py",
        "        runs = _horizon_mark_read(mark_path)\n"
        "        _horizon_write_mark(mark_path, _horizon_merged(runs, entry))\n",
        "        runs = []\n        pass  # M64: отметка не пишется\n",
        "M64",
    )


def mutation_m65(root: Path) -> None:
    # Отказ прибора проглатывается: худший код заменён молчаливым нулём --
    # ровно fail-open, который запрещает шапка compact.py.
    replace_once(
        root / "judge" / "compact.py",
        # Якорь -- ровно несущая строка (выход худшим из проб, волна 227b), а
        # не окружающий её текст: якорь по форме сообщения ломался бы от правки
        # слов в нём, и мутация молча переставала бы мерить (#75, круг 26).
        "    return worst\n",
        "    return 0  # M65: отказ прибора проглатывается\n",
        "M65",
    )


def mutation_m66(root: Path) -> None:
    # Исчезнувший под руками архив становится отказом: гонка с прополкой ядра
    # снова роняет ночной проход.
    replace_once(
        root / "judge" / "compact.py",
        # Якорь -- снятие архива и заголовок его ветки гонки (os.unlink(path)
        # в файле ровно один). Тело ветки в якорь не входит: комментарий и
        # счётчик внутри неё -- форма, а мутация мерит поведение.
        "            os.unlink(path)\n"
        "        except FileNotFoundError:\n",
        "            os.unlink(path)\n"
        "        except FileNotFoundError:\n"
        "            raise HorizonRefusal('архив исчез под руками')\n",
        "M66",
    )


def mutation_m67(root: Path) -> None:
    # Волна 230: вызов зубов при старте снят -- сценарий 57 обязан поймать
    # стенд, который мерил бы поверх негодного прибора. Якорь -- последняя
    # строка функции зубов плюс вызов на уровне модуля (каждый встречается
    # только там); присваивание флага остаётся, красит именно проверка
    # сценария.
    replace_once(
        root / "tools" / "judge-tools-bench.py",
        "    ANCHOR_TEETH_RAN = True\n\n\n_anchor_teeth_hold()",
        "    ANCHOR_TEETH_RAN = True",
        "M67",
    )


# M68-M71 -- зубы волны 227b: список проб за один прогон владельца прополки,
# худший код из проб, контракт списка и ценз покрытия агента.
def mutation_m68(root: Path) -> None:
    # Разбор «ровно одна итоговая строка НА ПРОБУ» ослеп: матч любой пробы
    # засчитывается каждой -- потерянная или задублированная проба стала бы
    # невидимой (класс «прибор ослеп»). Сценарии 59-61 этим разбором не
    # пользуются, красит ровно зуб 58.
    replace_once(
        root / "tools" / "judge-tools-bench.py",
        "        summary = [m for m in SUMMARY_RE.finditer(result.stdout)\n"
        "                   if m.group(\"probe\") == probe]\n"
        "        require(len(summary) == 1,\n"
        "                f\"итоговая строка пробы {probe} не распознана ровно один раз\\n{output}\")\n",
        "        summary = list(SUMMARY_RE.finditer(result.stdout))  # M68: разбор ослеп\n"
        "        require(len(summary) == 1,\n"
        "                f\"итоговая строка пробы {probe} не распознана ровно один раз\\n{output}\")\n",
        "M68",
    )


def mutation_m69(root: Path) -> None:
    # Проход останавливается на первом отказе: успешная проба не исполняется,
    # её эффект на диске пропадает. Одиночные пробы (сценарии 1-56) и прогон
    # без отказов (58) не задеты -- красит ровно зуб 59. Якорь -- блок целиком:
    # после доработки 227b строка `worst = 1` встречается в файле дважды
    # (горизонт и OSError-изоляция), и якорь по одной строке не уникален.
    replace_once(
        root / "judge" / "compact.py",
        "            _warn(probe, f'ОТКАЗ ГОРИЗОНТА: {exc}')\n"
        "            worst = 1\n",
        "            _warn(probe, f'ОТКАЗ ГОРИЗОНТА: {exc}')\n"
        "            worst = 1\n"
        "            break  # M69: проход остановлен на первом отказе\n",
        "M69",
    )


def mutation_m70(root: Path) -> None:
    # Пустой элемент списка проб пропускается молча: опечатка владельца
    # превращается в прогон неизвестно чего с кодом 0 -- красит ровно зуб 60.
    # Якорь -- ветка целиком (со строкой печати): sys.exit(2) после доработки
    # 227b встречается в файле дважды (пустой элемент и негодное имя), и
    # якорь по одной несущей строке перестал бы быть уникальным.
    replace_once(
        root / "judge" / "compact.py",
        "        if item.strip() == '':\n"
        "            print(f'ОТКАЗ: пустой элемент в списке проб ({item!r} в '\n"
        "                  f'--probe {raw!r}); проба обязана быть названа', file=sys.stderr)\n"
        "            sys.exit(2)\n",
        "        if item.strip() == '':\n"
        "            continue  # M70: пустой элемент пропущен молча\n",
        "M70",
    )


def mutation_m71(root: Path) -> None:
    # Ценз покрытия агента снят: агент на умолчании judge снова выглядит
    # зелёным, а журнал лестницы failover не пропалывает никто -- красит
    # ровно зуб 61. Проверка цели агента (строка выше) не тронута.
    replace_once(
        root / "scripts" / "probes-sync.sh",
        "    if grep -q -- '--probe' <<<\"$__args\" && grep -qF 'failover' <<<\"$__args\"; then\n",
        "    if true; then\n",
        "M71",
    )


# M72-M73 -- зубы доработки 227b: изоляция OSError-отказа пробы и валидация
# имени пробы (находки контроллера на первой редакции волны).
def mutation_m72(root: Path) -> None:
    # Изоляция OSError-отказа пробы проглатывает его: worst не поднят и
    # причина не названа, непишущийся журнал снова даёт код 0 -- красит
    # ровно зуб 62. Ошибка программиста остаётся громкой: глотается только
    # OSError.
    replace_once(
        root / "judge" / "compact.py",
        "            _warn(probe, f'ОТКАЗ ПРОХОДА: {exc}')\n"
        "            worst = 1\n",
        "            pass  # M72: отказ пробы проглочен молча\n",
        "M72",
    )


def mutation_m73(root: Path) -> None:
    # Валидация имени пробы ослеплена: опечатка снова уводит проход за дом
    # проб или в каталог с пробелом -- красит ровно зуб 63.
    replace_once(
        root / "judge" / "compact.py",
        "        if _bad_probe_name(item):\n",
        "        if False:  # M73: валидация имени ослеплена\n",
        "M73",
    )


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
    # Причина M10 -- именованный отказ ПРОГОНА (доработка 227b): PermissionError
    # от os.kill(чужой pid, 0) больше не роняет прогон трейсбеком -- его ловит
    # изоляция OSError и называет по имени пробы; прежняя причина ждала слово
    # «PermissionError» из трейсбека, которого больше не существует.
    ("M10", mutation_m10, 16, "ОТКАЗ ПРОХОДА"),
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
    ("M31", mutation_m31, 35, "словарь пробы живой формы не извлечён из образа"),
    ("M32", mutation_m32, 35, "скан пересёк границу чужой пробы"),
    ("M33", mutation_m33, 36, "из БУДУЩЕГО"),
    ("M34", mutation_m34, 1, "счётчик skipped: ожидалось 1"),
    ("M35", mutation_m35, 2, "после сжатия остался неверный состав"),
    ("M36", mutation_m36, 4, "пересжатие оставило лишние файлы"),
    ("M37", mutation_m37, 6, "счётчик skipped: ожидалось 1"),
    ("M38", mutation_m38, 7, "счётчик orphans: ожидалось 1"),
    ("M39", mutation_m39, 8, "счётчик orphans: ожидалось 0"),
    ("M40", mutation_m40, 10, "ложные исчезновения в сценариях compact.py"),
    ("M41", mutation_m41, 11, "лаунчер tmp мёртвого pid не снят"),
    ("M42", mutation_m42, 12, "лаунчер tmp живого процесса снят"),
    ("M43", mutation_m43, 23, "импорт adjudicate требует образа"),
    ("M44", mutation_m44, 37, "ожидался класс 3"),
    ("M45", mutation_m45, 38, "--limit=-1 не отвергнут кодом 2"),
    ("M46", mutation_m46, 39, "--timeout 0 не отвергнут кодом 2"),
    ("M47", mutation_m47, 40, "--older-than-hours -1 не отвергнут кодом 2"),
    ("M48", mutation_m48, 41, "--jobs=0 не отвергнут кодом 2"),
    ("M49", mutation_m49, 42, "реплики подрезаны чужим ключом"),
    ("M50", mutation_m50, 42, "молчание о чужом ключе"),
    ("M51", mutation_m51, 43, "усечённый target не переписан"),
    ("M52", mutation_m52, 44, "граница строки не восстановлена"),
    ("M53", mutation_m53, 45, "прибор отказал без образа"),
    ("M54", mutation_m54, 46, "пропуск сверки не объявлен при отсутствии образа"),
    ("M55", mutation_m55, 47, "расхождение дома и образа не отвергнуто кодом 2"),
    ("M56", mutation_m56, 48, "проба вне дома не отвергнута кодом 2"),
    ("M57", mutation_m57, 49, "раскатанная раскладка не резолвится"),
    ("M58", mutation_m58, 49, "отказ назвал не оба кандидата раскладки"),
    ("M59", mutation_m59, 50, "порванная строка не названа координатой"),
    ("M60", mutation_m60, 50, "итог со счётом порванных строк напечатан"),
    ("M61", mutation_m61, 51, "архив старше горизонта не унесён"),
    ("M62", mutation_m62, 52, "горизонт тронул горячий .json"),
    ("M63", mutation_m63, 53, "обломок tmp назван архивом горизонта"),
    ("M64", mutation_m64, 54, "отметка горизонта не написана"),
    ("M65", mutation_m65, 55, "нечитаемый каталог дал rc=0"),
    ("M66", mutation_m66, 56, "исчезнувший под руками архив снова становится отказом"),
    ("M67", mutation_m67, 57, "вызов зубов якоря при старте не выполнялся"),
    ("M68", mutation_m68, 58, "не распознана ровно один раз"),
    ("M69", mutation_m69, 59, "успех второй пробы проглочен"),
    ("M70", mutation_m70, 60, "не отвергнут кодом 2"),
    ("M71", mutation_m71, 61, "агент без failover не краснит"),
    ("M72", mutation_m72, 62, "отказ пробы не изолирован"),
    ("M73", mutation_m73, 63, "имя пробы не отвергнуто кодом 2"),
]

# Круг 25, E-4: сценарий без своей мутации не доказывает ничего -- его можно
# сломать, и стенд останется зелёным. corpus-tools-bench исполняет это правило
# сверкой таблиц; здесь и у соседних стендов её не было вовсе, проверки были
# только про длину. Сверка идёт по третьему полю таблицы ДО любого прогона и в
# ОБЕИХ режимах. Исключения -- только поимённо, с написанной причиной (как
# UNMUTATED_OK у corpus-tools-bench: позитивный контроль вердикта, краснеющий
# от любой всегда-красной мутации). На сегодня исключений нет: покрытие полное.
UNMUTATED_OK: tuple[int, ...] = ()


def check_tables() -> int:
    covered = {scenario for _, _, scenario, _ in MUTATIONS}
    missing = [n for n in range(1, EXPECTED_SCENARIOS + 1)
               if n not in covered and n not in UNMUTATED_OK]
    if missing or len(MUTATIONS) != EXPECTED_MUTATIONS:
        print(f"judge-tools-bench: ОТКАЗ -- мутаций {len(MUTATIONS)}/{EXPECTED_MUTATIONS},"
              f" без своей мутации сценарии: {missing or 'нет'}")
        return 4
    return 0


def fail_segment(output: str, scenario: int) -> str | None:
    """Текст провала ИМЕННО этого сценария (сообщение бывает многострочным)."""
    head = f"judge-tools-bench: СЦЕНАРИЙ {scenario}: FAIL:"
    start = output.find(head)
    if start < 0:
        return None
    rest = output[start + len(head):]
    end = rest.find("judge-tools-bench: ")
    return rest if end < 0 else rest[:end]


# Копия несёт РОВНО то, что читают сценарии: мутации правят её, а не живое
# дерево. Со сценариями 19-20 в неё вошли сверка раскатки и конвейер --
# мутация, которой не во что примениться, «проходит» молча (круг 18, §6).
# CONSTRAINT: каталоги канона копируются ЦЕЛИКОМ -- перечня имён внутри них
# здесь нет по той же причине, что и в toy_kit. Прежняя редакция держала шесть
# имён judge/ и четыре файла probes/; пополнение набора (#193) обошло её
# стороной, и ПРИСТИННАЯ копия вышла красной -- контроль самопроверки отказал
# целиком («мутации ничего не докажут»), то есть зубы стенда перестали мерить
# вовсе, а причина выглядела дефектом инструментов. Остальные файлы лежат в
# каталогах, которые целиком копировать нельзя (корень несёт образы и сборки),
# поэтому они названы поимённо -- и ровно поэтому рядом стоит check_copy_list:
# перечень, живущий рядом со своим домом, обязан читаться из дома. Дом здесь --
# текст сценариев и мутаций, где путь внутри копии пишется формой ниже.
COPIED_FILES: tuple[str, ...] = (
    "claude_patch.py",
    "set-model-costs.py",
    "claude-patch-all.sh",
    # Дом словарей вердиктов (волна 40b): без него копия отказывает кодом 2 на
    # первом же чтении словаря, и контроль без мутации красен -- мутации тогда
    # не доказывают ничего.
    "tweakcc-patch.js",
    "tools/judge-tools-bench.py",
    "tools/probe-bench.js",
    # Сценарий 41 гоняет checks-teeth.py сабпроцессом: без копии мутация по
    # нему применялась бы к живому дереву, а сценарий мерил бы нетронутый файл.
    "tools/checks-teeth.py",
    # Зависимость самого стенда (волна 229): правило открытия питоньих
    # heredoc'ов -- ни один сценарий его не читает, его читает стенд.
    "tools/heredoc-anchor.py",
    "scripts/probes-sync.sh",
)
COPIED_DIRS: tuple[str, ...] = ("judge", "probes")
COPY_SKIP = ("__pycache__", "records", "labelled", "*.pyc")

_COPY_SITE = re.compile(
    r'root\s*/\s*"([^"]+)"(?:\s*/\s*"([^"]+)")?(?:\s*/\s*"([^"]+)")?')


def check_copy_list() -> int:
    bad: list[str] = []
    for rel in COPIED_FILES + COPIED_DIRS:
        if not (ROOT / rel).exists():
            bad.append(f"объявлен к копированию «{rel}», а в дереве его нет "
                       f"-- устаревшее объявление")
    dirs = {str(Path(rel).parent) for rel in COPIED_FILES} | set(COPIED_DIRS)
    for parts in _COPY_SITE.findall(BENCH.read_text(encoding="utf-8")):
        rel = "/".join(part for part in parts if part)
        if rel in COPIED_FILES or rel in dirs:
            continue
        if rel.split("/", 1)[0] in COPIED_DIRS:
            continue
        bad.append(f"сценарии обращаются к «{rel}» внутри копии, "
                   f"а перечень копирования его не несёт")
    if bad:
        for line in sorted(set(bad)):
            print(f"judge-tools-bench: ОТКАЗ -- {line}")
        return 4
    return 0


def copy_tree(root: Path) -> None:
    for rel in COPIED_FILES:
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, target)
    skip = shutil.ignore_patterns(*COPY_SKIP)
    for rel in COPIED_DIRS:
        shutil.copytree(ROOT / rel, root / rel, ignore=skip, dirs_exist_ok=True)


def run_copy(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(root / "tools" / "judge-tools-bench.py")],
        cwd=root,
        capture_output=True,
        text=True, errors="replace",
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
            except UnparsableVictim as error:
                # Круг 25, E-3: замена, сломавшая разбор жертвы, -- поломка
                # САМОГО ПРИБОРА, а не вердикт о продукте. Прогон
                # останавливается ДО счёта покраснений: пока прибор чинят,
                # остальным числам этого прогона веры нет.
                print(f"judge-tools-bench: МУТАЦИЯ {name}: СЛОМАЛА РАЗБОР ЖЕРТВЫ -- {error}")
                return 2
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
    # Сверка таблиц -- ДО любого прогона и в обеих режимах (как check_mut_tables
    # у corpus-tools-bench): рассинхрон таблиц сдвигает причины мутаций молча,
    # а непокрытый сценарий стенд доказывать не может в принципе.
    if check_tables():
        return 4
    # Там же и по той же причине: перечень копирования, потерявший жертву,
    # превращает мутацию по ней в дефект стенда, а не в вердикт о продукте.
    if check_copy_list():
        return 4
    return run_self_check() if args.self_check else run_scenarios()


if __name__ == "__main__":
    sys.exit(main())
