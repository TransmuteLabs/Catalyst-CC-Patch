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
  1  мутация прошла молча либо покрасила чужую дверь; сюда же зуб входа,
     который не поймал нарушенный контракт вызова раннера, и зуб фазы
     фикстуры (#407)
  2  прибор не может мерить: якорь пропал/слишком широк, замена длиннее якоря,
     либо КОНТРОЛЬ провален -- названный образ красен ещё до мутаций; сюда же
     относится нарушенный контракт вызова: --jobs < 1 (круг 26, K-14);
     сюда же НЕ ИЗМЕРЕНО фазы фикстуры (#407)
  4  длина таблицы разошлась с объявленной (EXPECTED_MUTATIONS)
     либо число зубов входа разошлось с EXPECTED_ENTRY_TEETH
     либо зубов фикстуры -- с EXPECTED_FIXTURE_TEETH (#407)
  3  замок конвейера держит живая сборка -- НЕ МЕРИЛИ, повтор поможет
  5  мерить нечего: на этой машине нет собранного образа
  6  сломано окружение либо машинерия замка: нет bash, нет
     tools/checks-on-image.sh, замок не открыть или flock не работает --
     повтор НЕ поможет
  9  отказ ПРИБОРА -- сломан предмет или строитель, а не проверяемый код.
     Производителей у девятки больше, чем потребитель способен перечислить
     (отказ строки, отказ строителя фикстуры, пустая причина зуба фазы), и
     сам код НЕ говорит, измерялись ли строки: отказ фазы фикстуры прохода
     не останавливает (ранний выход в main стоит только на коде 4). Факт
     измерения строк читается ПРЕДИКАТОМ -- наличием строки
     «checks-teeth: ИТОГ мутаций=» на stdout, -- и никогда из того, кто дал
     девятку. Это НЕ 2: код 2 свип читает как «этап не измеряли», а
     сломанный предмет не имеет права читаться как «не мерили».
     НЕ 7: 7 занят апстрим-смыслом «не краснить, ждать» с противоположным
     действием -- канон таблицы в шапке claude-patch-all.sh
"""

from __future__ import annotations

import argparse
import ast
import contextlib
import fcntl
import functools
import glob
import importlib.util
import io
import json
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
EXPECTED_MUTATIONS = 20
# Зубы входа -- не мутации образа: EXPECTED_MUTATIONS не двигается.
# 34 = 20 (#403, волна A и раньше) + 7 зубов карты шагов (docnum:other -- «шаг ->
# проверки» есть ИМЯ карты, не счёт проверок конвейера; #403B) + 6 зубов
# проекции базы корпусного стенда (docnum:other -- «шаг -> проверки» есть ИМЯ
# карты, не счёт проверок конвейера; #403C) + 2 зуба порядка фаз входа и
# мутаций (docnum:other -- «фазы» здесь порядок этапов прибора, не счёт
# шагов конвейера; #408) - 3 зуба, ушедшие в фазу фикстуры (#407: предмет
# СТРОИТСЯ, а не предполагается), + 2 зуба границы свёртки выходов фаз
# (docnum:other -- #407 и Р6 есть номер задачи и решение её брифа, не счёт
# зубов). Фикс-волна #407: + 2 = 36 -- зуб приоритета дефекта фикстуры над
# ранними «НЕ ИЗМЕРЕНО» (Р1) и зуб строки фазы при раннем отказе строк (Р9)
# (docnum:other -- Р1 и Р9 есть номера пунктов брифа fix-волны, не счёты
# стенда).
# Фикс-волна #407 раунд 2: + 1 = 37 -- зуб перечня ROOT-производных констант
# копии прибора (docnum:other -- Ф2 есть номер пункта брифа fix-волны 2, не
# счётчик стенда).
# Фикс-волна #407 раунд 2: + 1 = 38 -- зуб сохранения напечатанной находки
# при смерти воркера (docnum:other -- Ф1 есть номер пункта брифа fix-волны 2,
# не счётчик стенда).
# Фикс-волна #407 раунд 2: + 1 = 39 -- зуб строки «ФАЗА НЕ ЗАПУСКАЛАСЬ» у
# ранних пропусков (docnum:other -- Ф6 есть номер пункта брифа fix-волны 2,
# не счётчик стенда).
# Фикс-волна #407 раунд 3: + 1 = 40 -- зуб итога фазы на пути пина набора
# фикстур (docnum:other -- Х5 есть номер пункта брифа fix-волны 3, не
# счётчик стенда); + 1 = 41 -- зуб покрытия реестра прополки каждым mkdtemp
# (docnum:other -- Х6 есть номер пункта того же брифа, не счётчик стенда).
EXPECTED_ENTRY_TEETH = 41
# Зубы фазы фикстуры шага 26 (#407): идут ПОСЛЕ замка конвейера, предмет --
# ПОСТРОЕННЫЙ образ «2.1.278 + шаг 26». 4 = 3 переведённых со входа (Р4)
# + 1 зуб положительного контроля фикстуры (гейт #407); docnum:other --
# Р4 и гейт #407 есть решения брифа задачи, не счётчики стенда.
# Фикс-волна #407: + 7 = 11 -- уборка фазы в finally (Р2), прополка каталога
# фикстуры (Р2), ручка FORK одним домом (Р10), оба исхода строителя (Р6),
# причина Refusal зуба в итоге (Р8), пустая причина как отказ прибора (Р12)
# (docnum:other -- Р2/Р6/Р8/Р10/Р12 есть номера пунктов брифа fix-волны,
# не счётчики стенда).
# Фикс-волна #407 раунд 2: + 1 = 12 -- прополка каталога фикстуры требует
# возраст И мёртвого владельца (docnum:other -- Ф4 есть номер пункта брифа
# fix-волны 2, не счётчик стенда).
# Фикс-волна #407 раунд 3: + 1 = 13 -- переиспользованный pid не держит
# каталог вечно (docnum:other -- Х7 есть номер пункта брифа fix-волны 3, не
# счётчик стенда).
EXPECTED_FIXTURE_TEETH = 13
# Зубы третьего исхода шага 29 (docnum:other -- номер шага патча, не счёт стенда).
# Это мутации скрипта, декларации и патча, а не образа.
# EXPECTED_MUTATIONS держит только kind literal/derived, иначе живой счёт
# README/D37 разъедется с таблицей.
EXPECTED_INAPPLICABLE_TEETH = 8
ID = rb"[A-Za-z_$][A-Za-z0-9_$]*"
# Приманка кладётся ЗАВЕДОМО вне окна (оно +-20000 байт в обе стороны): так мутация
# отличает сужение по окну от поиска по всему образу.
DECOY_BACK = 2_000_000
# Потолок числа вхождений литерального якоря: больше -- якорь мутировал бы чужие
# сайты, и такому зубу место в derived (см. edits_literal, #149).
CEILING = 8


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


def read_table() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for ln, line in enumerate(io.open(TABLE, encoding="utf-8"), 1):
        if line.startswith("#") or not line.strip():
            continue
        parts = line.rstrip("\n").split("\t")
        # CONSTRAINT (#353): девятое поле (шаг-владелец) обязательно как СЛОТ --
        # ряд старой восьмиполевой формы отказывает с номером строки, а не
        # молча получает пустое поле шага.
        if len(parts) != 9:
            raise Refusal(f"строка {ln} таблицы не из девяти полей: {parts[:2]}")
        row: dict[str, object] = dict(zip(("id", "check", "kind", "anchor", "repl",
                                           "also", "expect", "note", "step"), parts))
        row["lineno"] = ln
        rows.append(row)
    return rows


@functools.lru_cache(maxsize=1)
def _pipeline_check_names() -> frozenset[str]:
    """Имена реестра checks конвейера: AST-разбором, не регуляркой.

    CONSTRAINT: тело heredoc достаётся ЕДИНСТВЕННЫМ домом правила
    tools/heredoc-anchor.py (загрузка importlib по образцу стадии сверки
    конвейера) -- местная копия правила уже расходилась с домом (волна 230).
    Ключи словаря читаются обходом ast.Dict; ключ-ast.Name резолвится
    присваиванием строковой константы в ТОМ ЖЕ теле, а при её отсутствии
    (с #403B литералы шага 26 удалены из тела) -- каналом карты
    «шаг -> проверки» (см. _map_channel_check_name). Регуляркой ключи не
    достаются: комментарий у EXPECTED_CHECKS фиксирует два неверных
    пересчёта регуляркой, ломавшейся на экранированном апострофе внутри
    `current turn is the judge\'s alone`. Неразрешённый ключ -- отказ
    прибора: имя-призрак проскочил бы дверь молча.
    """
    anchor_path = ROOT / "tools" / "heredoc-anchor.py"
    spec = importlib.util.spec_from_file_location(
        "checks_teeth_heredoc_anchor", str(anchor_path))
    if spec is None or spec.loader is None:
        raise Refusal(f"дом правила heredoc не загружается: {anchor_path}")
    anchor = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(anchor)
    except Exception as exc:
        raise Refusal(f"дом правила heredoc не исполняется: {exc}") from exc
    victim = ROOT / "claude-patch-all.sh"
    if not victim.is_file():
        raise Refusal(f"нет конвейера для реестра checks: {victim}")
    found: list[tuple[ast.Module, ast.Dict]] = []
    with tempfile.TemporaryDirectory(prefix="checks-teeth-registry.") as td:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            rc = anchor.bodies(str(victim), td)
        if rc != 0:
            raise Refusal(f"тела heredoc конвейера не извлекаются: rc={rc}")
        try:
            count = int(buffer.getvalue().strip())
        except ValueError as exc:
            raise Refusal(f"дом правила не назвал число тел: {buffer.getvalue()!r}") from exc
        for i in range(1, count + 1):
            body_path = Path(td) / ("body.%d.py" % i)
            try:
                tree = ast.parse(body_path.read_text(encoding="utf-8"))
            except SyntaxError as exc:
                raise Refusal(f"тело heredoc №{i} не разбирается как Python: {exc}") from exc
            for node in tree.body:
                if (isinstance(node, ast.Assign) and len(node.targets) == 1
                        and isinstance(node.targets[0], ast.Name)
                        and node.targets[0].id == "checks"
                        and isinstance(node.value, ast.Dict)):
                    found.append((tree, node.value))
    if len(found) != 1:
        raise Refusal(f"словарь checks в телах конвейера найден {len(found)} раз -- ждём ровно один")
    tree, dic = found[0]
    consts: dict[str, str] = {}
    for node in ast.walk(tree):
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and isinstance(node.value, ast.Constant)
                and isinstance(node.value.value, str)):
            consts[node.targets[0].id] = node.value.value
    # Ключи-имена без константы в теле (#403B): значение шага 26 пришло из
    # карты «шаг -> проверки» -- литерал в теле означал бы вторую копию
    # значения. Больше ОДНОГО такого ключа -- отказ: резолвер обязан расти
    # вместе с картой, а не молча ссыпать разные ключи в одно имя.
    unconst = [key for key in dic.keys
               if isinstance(key, ast.Name) and key.id not in consts]
    if len(unconst) > 1:
        raise Refusal(f"ключей checks без константы больше одного ({len(unconst)}) -- "
                      f"резолвер канала карты объявлен на один")
    map_name = _map_channel_check_name(tree) if unconst else None
    names: set[str] = set()
    for key in dic.keys:
        if key is None:
            raise Refusal("ключ checks -- распаковка **без имени: реестр не перечислим")
        if isinstance(key, ast.Constant) and isinstance(key.value, str):
            names.add(key.value)
        elif isinstance(key, ast.Name):
            if key.id in consts:
                names.add(consts[key.id])
            else:
                names.add(map_name)
        else:
            raise Refusal(f"ключ checks не строка и не имя: {ast.dump(key)}")
    if not names:
        raise Refusal("реестр checks конвейера извлечён пустым")
    return frozenset(names)


def _map_channel_check_name(tree: ast.Module) -> str:
    """Значение ключа checks из канала карты шагов (docnum:other -- «шаг -> проверки»
    есть ИМЯ карты, не счёт проверок конвейера; #403B).

    Признанная форма одна: переменная карты присвоена вызовом read_step_checks
    (единственный дом разбора tools/step-checks.py), а строка-результат
    выбирается генератором по <карта>.items() со сравнением обработчика
    h == '<id>'. Значение читается ИЗ КАРТЫ тем же единственным домом -- не
    из второй копии здесь. Иная форма или неоднозначность -- отказ прибора:
    имя-призрак не имеет права проскакивать дверь молча.
    """
    map_vars: set[str] = set()
    for node in ast.walk(tree):
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and isinstance(node.value, ast.Call)
                and isinstance(node.value.func, ast.Attribute)
                and node.value.func.attr == "read_step_checks"):
            map_vars.add(node.targets[0].id)
    if not map_vars:
        raise Refusal("канал карты не найден: тело не зовёт read_step_checks")
    handlers: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.ListComp):
            continue
        for gen in node.generators:
            # iter -- ВЫЗОВ <карта>.items(): в генераторе доступ-с-вызовом
            # парсится Call от Attribute, а не сам Attribute.
            if not (isinstance(gen.iter, ast.Call)
                    and isinstance(gen.iter.func, ast.Attribute)
                    and gen.iter.func.attr == "items"
                    and isinstance(gen.iter.func.value, ast.Name)
                    and gen.iter.func.value.id in map_vars):
                continue
            if not (isinstance(gen.target, ast.Tuple) and len(gen.target.elts) == 2
                    and isinstance(gen.target.elts[0], ast.Name)
                    and isinstance(gen.target.elts[1], ast.Tuple)
                    and len(gen.target.elts[1].elts) == 2
                    and all(isinstance(e, ast.Name) for e in gen.target.elts[1].elts)):
                continue
            handler_var = gen.target.elts[1].elts[0].id
            for cond in gen.ifs:
                if (isinstance(cond, ast.Compare) and len(cond.ops) == 1
                        and isinstance(cond.ops[0], ast.Eq)
                        and isinstance(cond.left, ast.Name)
                        and cond.left.id == handler_var
                        and len(cond.comparators) == 1
                        and isinstance(cond.comparators[0], ast.Constant)
                        and isinstance(cond.comparators[0].value, str)):
                    handlers.add(cond.comparators[0].value)
    if not handlers:
        raise Refusal("канал карты не назван обработчиком: нет сравнения "
                      "обработчика со строкой по итерации карты")
    tool = ROOT / "tools" / "step-checks.py"
    spec = importlib.util.spec_from_file_location("checks_teeth_step_checks",
                                                  str(tool))
    if spec is None or spec.loader is None:
        raise Refusal(f"модуль карты не загружается: {tool}")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        raise Refusal(f"модуль карты не исполняется: {exc}") from exc
    try:
        rows = module.read_step_checks(ROOT / "tools" / "our-step-checks.txt")
    except Exception as exc:
        raise Refusal(f"карта шагов не читается: {exc}") from exc
    values = sorted({check for handler, checks in rows.values()
                     if handler in handlers for check in checks})
    if len(values) != 1:
        raise Refusal(f"канал карты разрешается {len(values)} именами проверок "
                      f"для обработчиков {sorted(handlers)} -- ждали ровно одно: "
                      f"{values!r}")
    return values[0]


def check_row_names(rows: list[dict[str, object]], registry: set[str]) -> None:
    """Дверь реестра: имена полей 2 и 6 таблицы обязаны существовать в checks
    (docnum:other -- 2 и 6 суть номера КОЛОНОК таблицы, не счётчики кита).

    CONSTRAINT: поле 6 покрыто наравне с полем 2 -- «ещё одна ожидаемая
    красная», которой нет в реестре, тихо ослабляла бы зуб до одной двери.
    Отказы двух полей несут РАЗНЫЕ тексты: два отказа одной строкой
    неразличимы. Id обязан быть уникален: реестр без уникальности ключа
    читается не так, как правится.
    """
    problems: list[str] = []
    seen: dict[str, int] = {}
    for row in rows:
        rid = str(row["id"])
        ln = int(row["lineno"])
        if rid in seen:
            problems.append(f"строка {ln} ({rid}): id уже объявлен строкой {seen[rid]}")
        else:
            seen[rid] = ln
        check = str(row["check"])
        if check not in registry:
            problems.append(f"строка {ln} ({rid}): поле 2: имя проверки «{check}» "
                            f"вне реестра checks конвейера")
        for name in str(row.get("also", "")).split(";"):
            name = name.strip()
            if name and name not in registry:
                problems.append(f"строка {ln} ({rid}): поле 6: имя ещё-красной «{name}» "
                                f"вне реестра checks конвейера")
    if problems:
        raise Refusal("\n".join(problems))


def edits_literal(base: bytes, row: dict[str, str]) -> list[tuple[int, bytes]]:
    anchor = row["anchor"].encode()
    repl = row["repl"].encode()
    if len(repl) > len(anchor):
        raise Refusal(f"{row['id']}: замена длиннее якоря ({len(repl)} > {len(anchor)})")
    repl = repl.ljust(len(anchor))
    # Ожидаемое число вхождений -- ОБЯЗАТЕЛЬНОЕ поле: пустое/нецелое = отказ, а не
    # молчаливый пропуск (молчащее поле вернуло бы отказ, открывающийся молчанием).
    raw = row.get("expect", "")
    try:
        expect = int(raw)
    except (TypeError, ValueError):
        raise Refusal(f"{row['id']}: ожидаемое число вхождений не целое: {raw!r}")
    if expect < 1:
        raise Refusal(f"{row['id']}: ожидаемое число вхождений < 1: {expect}")
    if expect > CEILING:
        # Прежний отказ «якорь слишком широк», теперь по ОБЪЯВЛЕННОМУ числу:
        # литеральный зуб, ждущий больше потолка вхождений, мутировал бы чужие
        # сайты -- его место в derived (как V4 с 12 при потолке 8).
        raise Refusal(f"{row['id']}: якорь слишком широк -- ждёт {expect} вхождений "
                      f"при потолке {CEILING}; такому зубу место в derived")
    spots = [m.start() for m in re.finditer(re.escape(anchor), base)]
    n = len(spots)
    if not spots:
        raise Refusal(f"{row['id']}: якорь не найден в образе")
    if n != expect:
        # #149: два состояния больше не смешиваются в один текст. Живое число
        # разошлось с ожидаемым -- сдвинулась ПЛОЩАДКА (апстрим завёл или убрал
        # вхождения того же идиома), зуб цел; направление названо. Это НЕ «якорь
        # слишком широк» -- та ветка выше и судит по ОБЪЯВЛЕННОМУ числу.
        direction = "выросло" if n > expect else "убыло"
        raise Refusal(f"{row['id']}: число вхождений {direction} -- ждали {expect}, "
                      f"нашли {n}; сдвинулась площадка (апстрим завёл/убрал "
                      f"вхождения идиома), зуб цел -- перемерить и обновить "
                      f"ожидаемое поле")
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


def _find_downgrade_reader(base: bytes) -> tuple[bytes, bytes, bytes, bytes]:
    """Единственный читатель-понижатель `function <B>(<x>){return <A>(<x>)?<F>:<x>}`,
    чей <F> связан с "claude-opus-4-8".

    Совпадает по поведению с _find_downgrade_reader из claude-patch-all.sh:
    вход по ПОВЕДЕНИЮ читателя, а не по связке констант -- 2.1.276 разорвала
    прежнюю связку «две var-константы + предикат рядом» (между ними вставлена
    посторонняя функция, тело предиката выросло до .some()), предмет при этом
    не двигался. Уникальность требуется над всем текстом: константа
    неуникальна (десятки вхождений), читатель уникален; содержимое <F> затем
    опознаёт его как opus. Возвращает (B, x, A, F).
    """
    hits = list(re.finditer(
        rb'function (' + ID + rb')\((' + ID + rb')\)\{return (' + ID + rb')\(\2\)\?(' + ID + rb'):\2\}',
        base))
    if not hits:
        raise Refusal("V4: читатель-понижатель не найден")
    if len(hits) > 1:
        raise Refusal(f"V4: читатель-понижатель не уникален -- {len(hits)} вхождений")
    m = hits[0]
    if not re.search(rb'(?<![\w$.])' + re.escape(m.group(4)) + rb'="claude-opus-4-8"', base):
        raise Refusal("V4: читатель-понижатель не опознан как opus")
    return m.group(1), m.group(2), m.group(3), m.group(4)


def edits_v4(base: bytes) -> list[tuple[int, bytes]]:
    """Опт-ин исключения верха линейки сломан в НАШЕЙ форме -- и только в ней.

    Литеральный зуб здесь невозможен: `()===void 0&&` встречается в собранном
    образе 2.1.278 13 раз при потолке прибора 8, и байтовая мутация выбила бы
    12 чужих сайтов вместе с нашим -- покраснело бы лишнее, а причина
    покраснения стала бы неназываемой. Счёт версионно-зависим: при переезде
    версии пересчитывать по активному образу. Поэтому мутация идёт ТОЙ ЖЕ цепочкой, что и сама
    проверка в claude-patch-all.sh (читатель-понижатель по поведению ->
    опт-ин форма исключения с <A> из читателя), и правит один байт внутри
    найденной формы. Сравнение `===void 0` становится всегда-ложным:
    исключение верха перестаёт зависеть от таблицы и живёт всегда, то есть
    ровно та потеря, которую проверка обязана видеть.
    """
    _B, _x, A, _F = _find_downgrade_reader(base)
    optin = re.search(
        rb'!\((' + ID + rb')\(\)===void 0&&' + re.escape(A) + rb'\((' + ID + rb')\)\)',
        base)
    if not optin:
        raise Refusal("V4: опт-ин форма исключения верха не найдена")
    needle = b"===void 0&&"
    off = optin.group(0).find(needle)
    if off < 0:
        raise Refusal("V4: в найденной опт-ин форме нет сравнения с void 0")
    return [(optin.start() + off, b"===void 1&&")]


def edits_b2(base: bytes) -> list[tuple[int, bytes]]:
    """Порог предупреждения о бюджете мод-API записан СВОИМ числом.

    Литеральный зуб здесь невозможен по той же причине, по какой проверка
    ловит имя из сравнения: и потолок, и множитель минифицированы, а имена
    РАЗНЫЕ на darwin и linux одной версии (2.1.270: потолок `BSe` против
    `eke`). Якорь с любым из них был бы зубом одной платформы.

    Мутация идёт той же иглой, что проверка: имя потолка берётся из
    охраняемого сравнения отказа, затем произведение `<потолок>*<доля>`
    заменяется числовым литералом ТОЙ ЖЕ длины. Это и есть предмет: порог
    перестаёт выводиться из потолка, снятый потолок больше его не гасит, и
    образ снова печатает сообщение о пределе, которого нет.
    """
    site = re.search(
        rb'if\(\(' + ID + rb'\.get\((' + ID + rb')\)\?\?0\)\+' + ID + rb'>=(' + ID + rb')\)'
        rb'throw new ' + ID + rb'\(`\$\{\1\}: \$\.model\.complete: '
        rb"the session's model budget for this plugin is spent`\)", base)
    if not site:
        raise Refusal("B2: отказ бюджета мод-API не найден -- потолок назвать нечем")
    cap = site.group(2)
    derived = re.search(rb'var ' + ID + rb'=(' + re.escape(cap) + rb'\*' + ID + rb');', base)
    if not derived:
        raise Refusal("B2: порог предупреждения не выводится из потолка уже в ИСХОДНОМ образе")
    expr = derived.group(1)
    # Литерал той же длины: ведущая единица и нули. Короче -- сместились бы
    # все последующие байты образа, и покраснело бы всё подряд чужой причиной.
    return [(derived.start(1), b"1" + b"0" * (len(expr) - 1))]


def edits_m2(base: bytes) -> list[tuple[int, bytes]]:
    """Умолчание maxTokens сведено с ПРЕДЕЛОМ в одно имя.

    Литеральный зуб здесь невозможен по той же причине, что у B2: и предел, и
    умолчание минифицированы, а имена РАЗНЫЕ на darwin и linux одной версии
    (2.1.270: предел `sMt` и умолчание `H0s` против `cMt` и `fOs`). Якорь с
    любым из них был бы зубом одной платформы.

    Мутация идёт той же иглой, что проверка: имя предела берётся из сравнения
    внутри сторожа, затем в выражении `(<arg>??<DEF>)` имя умолчания
    заменяется именем ПРЕДЕЛА. Это и есть предмет: после снятия предела мод,
    не передавший maxTokens, просит не свои 256, а Infinity -- вред, которого
    на стоке нет и который создаёт именно шаг 30.

    CONSTRAINT (#353): игла несёт РАСЩЕПЛЁННУЮ форму сторожа 2.1.276+ -- ту
    же, что читают проверка кита (`_MOD_MAXTOKENS_REFUSAL`) и локатор патча
    (tweakcc-patch.js, шаг 30); цельная форма `!Number.isInteger(...)||<1`
    в этой сборке даёт 0 вхождений, и красность M2 была недоказуема.
    """
    site = re.search(
        rb'if\((' + ID + rb')!==void 0&&\1>(' + ID + rb')\)'
        rb'throw new ' + ID + rb'\(`\$\{' + ID + rb'\}: \$\.model\.complete: '
        rb'maxTokens \$\{\1\} is past what \$\{' + ID + rb'\} '
        rb'can produce in one reply \(\$\{\2\}\)`\)', base)
    if not site:
        raise Refusal("M2: отказ maxTokens мод-API не найден -- предел назвать нечем")
    arg, lim = site.group(1), site.group(2)
    tail_at = site.end()
    use = re.search(rb'\(' + re.escape(arg) + rb'\?\?(' + ID + rb')\)',
                    base[tail_at:tail_at + 900])
    if not use:
        raise Refusal("M2: выражение умолчания `(<arg>??<DEF>)` не найдено рядом со сторожем")
    default = use.group(1)
    if default == lim:
        raise Refusal("M2: умолчание УЖЕ равно пределу в исходном образе -- красить нечего")
    if len(lim) > len(default):
        # Замена ДЛИННЕЕ якоря сдвинула бы весь хвост образа, и покраснело бы
        # всё подряд чужой причиной. Честный отказ прибора, а не подгонка.
        raise Refusal(
            f"M2: имена разной длины (умолчание {len(default)}, предел {len(lim)}) -- "
            f"замена сдвинула бы хвост образа")
    # Канон literal-замен (edits_literal): замена КОРОЧЕ якоря добивается
    # пробелами до его длины -- `(s??M  )` синтаксически валиден, и длина
    # хвоста образа неизменна; проверка кита при этом теряет `(<arg>??<DEF>)`
    # и обязана покраснеть.
    return [(tail_at + use.start(1), lim.ljust(len(default)))]


def edits_s1(base: bytes) -> list[tuple[int, bytes]]:
    """Гвард предиката session memory вернулся в СОСТАВНОЙ форме (#341).

    Литеральный зуб невозможен: составная форма длиннее простой, а замена
    длиннее якоря -- отказ прибора. Мутация derived идёт той же иглой, что
    проверка: keep-хвост предиката, от него назад до головы функции, и всё
    между головой и хвостом (ранний возврат апстрима + нейтрализованный
    tweakcc-гвард `if(!!0)return!1;`) переписывается в живой составной гвард
    `if(<вызов из раннего возврата>||!<читатель keep>("tengu_m1",!1))return!1;`
    с дополнением пробелами до прежней длины. Первый терм берётся из самого
    образа, читатель флага -- из keep-хвоста, имя флага синтетическое:
    предмет зуба -- ФОРМА условия, а не имя. Старое постусловие знало гвард
    одним написанием `if(!ID("tengu_...",!1))return!1;` и составную форму
    пропускало молча -- проверка читала «уже снято» при живом гварде.
    """
    keep = re.search(rb'return!' + ID + rb'\(\)\|\|' + ID
                     + rb'\("tengu_[a-z0-9_]+",!1\)\}', base)
    if not keep:
        raise Refusal("S1: keep-хвост предиката session memory не найден")
    reader = re.search(rb'\|\|(' + ID + rb')\("tengu_', keep.group(0))
    if not reader:
        raise Refusal("S1: читатель флага в keep-хвосте не найден")
    at_keep = keep.start()
    back = base[max(0, at_keep - 400):at_keep]
    heads = list(re.finditer(rb'function ' + ID + rb'\(\)\{', back))
    if not heads:
        raise Refusal("S1: голова функции предиката не найдена")
    span_at = at_keep - len(back) + heads[-1].end()
    span = base[span_at:at_keep]
    term = re.search(rb'if\((' + ID + rb')\(\)', span)
    if not term:
        raise Refusal("S1: в теле предиката нет раннего возврата с вызовом -- "
                      "первый терм составного гварда не из чего взять")
    guard = (b'if(' + term.group(1) + b'()||!' + reader.group(1)
             + b'("tengu_m1",!1))return!1;')
    if len(guard) > len(span):
        raise Refusal(f"S1: составной гвард ({len(guard)} байт) не влезает "
                      f"в тело до keep-хвоста ({len(span)} байт)")
    return [(span_at, guard.ljust(len(span)))]


DERIVED = {"C10": edits_c10, "V4": edits_v4, "B2": edits_b2, "M2": edits_m2, "S1": edits_s1}


STEP29_CEILING = "the mod-API model budget ceiling is operator-set"
STEP29_WARNING = "the mod-API budget warning derives from that ceiling"
STEP29_BOTH = (STEP29_CEILING, STEP29_WARNING)

# Якоря мутаций -- НЕСУЩИЕ строки блока проверок / WITNESSES патча.
# Код под мутацию не подгоняется: пропавший якорь -- отказ прибора.
I1_ANCHOR = '_NOTE_FMT = "  [NOTE] {name}: {ver} step 29: {reason}"'
I1_REPL = '_NOTE_FMT = "  [NOTX] {name}: {ver} step 29: {reason}"'
I2_ANCHOR = (
    "    if _all_dead:\n"
    "        if declared:\n"
    "            return {'status': 'note', 'ver': ver, 'reason': declared[1]}"
)
I2_REPL = (
    "    if _all_dead:\n"
    "        return {'status': 'note', 'ver': ver, 'reason': 'unconditional'}\n"
    "        if declared:\n"
    "            return {'status': 'note', 'ver': ver, 'reason': declared[1]}"
)
I3_ANCHOR = "if declared:\n        return {'status': 'fail', 'fail_kind': 'stale'"
I3_REPL = "if False:\n        return {'status': 'fail', 'fail_kind': 'stale'"
I4_ANCHOR = "_all_dead = all(w.encode('utf-8') not in d for w in _witnesses)"
I4_REPL = "_all_dead = any(w.encode('utf-8') not in d for w in _witnesses)"
I5_ANCHOR = (
    "  const WITNESSES = [\n"
    '    "the session\'s model budget for this plugin is spent",\n'
    "    ' session tokens spent',\n"
    "    'budget for this plugin',\n"
    "    'new Map,n=new Map;return{reserve:',\n"
    "    'budgets.model',\n"
    "  ];"
)
I5_REPL = (
    "  const WITNESSES = [\n"
    '    "the session\'s model budget for this plugin is XXXXX",\n'
    "    ' session tokens XXXXX',\n"
    "    'budget for this XXXXXX',\n"
    "    'new Map,n=new Map;return{XXXXXXX:',\n"
    "    'budgets.XXXXX',\n"
    "  ];"
)
I4_WITNESS = b"budgets.model"
I4_WITNESS_REPL = b"budgets.modex"
I6_ANCHOR = (
    '_FLOOR_WITHDRAW_FMT = "ПОЛ: запись выведена из сверки: {name}: {ver} step {step}: {reason}"'
)
I6_REPL = (
    '_FLOOR_WITHDRAW_FMT = "ПОЛ: запись выведенx из сверки: {name}: {ver} step {step}: {reason}"'
)
I6_PHRASE = "ПОЛ: запись выведена из сверки"
I7_ANCHOR = "_WITHDRAW_UNDECLARED_RED = False"
I7_REPL = "_WITHDRAW_UNDECLARED_RED = True"
I8_ANCHOR = "if dver != _WITHDRAW_VERSION:\n        continue"
I8_REPL = "if False:\n        continue"


# Единственная оставшаяся адресация к дому образов: реальный пристин последней
# версии. База флоровых фикстур и якорь против вакуумности (#354); старые
# версии прибору зубов больше не нужны (#355).
PRISTINE_LATEST = Path.home() / ".local" / "share" / "claude" / "versions" / "2.1.278.orig"

# Предмет шага 29 (docnum:other -- номер шага патча, не счёт проверок)
# в формах игл блока проверок (claude-patch-all.sh):
# стоковый отказ бюджета (_MOD_BUDGET_REFUSAL) со стоковой производной порога
# и наша toPrimitive-форма (_mod_budget_ceiling_is_operator_set). Свидетель
# "the session's model budget for this plugin is spent" живёт В отказе: это
# хвост его иглы.
_STEP29_STOCK = (
    b"if((Qq.get(Ww)??0)+Ee>=Cc)throw new Zz(`${Ww}: $.model.complete: "
    b"the session's model budget for this plugin is spent`)\n"
    b"var Vv=Cc*Nn;\n"
)
_STEP29_OURS = (
    b"var Cc={[Symbol.toPrimitive](){let Tt=process.env.CLAUDE_CODE_MOD_MODEL_BUDGET;"
    b'if(Tt===void 0||Tt==="")return Infinity;let Rr=Number(Tt);'
    b"return Number.isFinite(Rr)&&Rr>0?Rr:Infinity}};\n"
)


def _step29_witnesses() -> list[str]:
    """Свидетели шага 29 из якоря WITNESSES в tweakcc-patch.js.

    CONSTRAINT: тот же якорь и тот же регексп, что у _step29_witnesses_from_src
    блока проверок (claude-patch-all.sh): своя копия списка без гвардии
    разошлась бы с патчем молча (#197). Пропажа якоря и пустой список --
    отказ прибора, а не тишина.
    """
    src = (ROOT / "tweakcc-patch.js").read_text(encoding="utf-8")
    m = re.search(
        r"step\('29 mod-API session model budget ceiling becomes operator-set'"
        r".*?const WITNESSES = \[(.*?)\];",
        src, re.S)
    if not m:
        raise Refusal("якорь WITNESSES шага 29 пропал из tweakcc-patch.js")
    witnesses = [a or b for a, b in re.findall(
        r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'', m.group(1))]
    if not witnesses:
        raise Refusal("WITNESSES шага 29 извлечён пустым")
    return witnesses


def _step29_subject(*, ours: bool) -> bytes:
    """Живой предмет шага 29: сток и свидетели вне стока; наша форма -- по требованию.

    CONSTRAINT: порог «предмета нет» -- ВСЕ свидетели мертвы, поэтому предмет
    обязан нести все пять; свидетель внутри стока не дублируется. Наша
    toPrimitive-форма включается только для нефлоровых зубов: пол мерит
    пристиноподобную базу, и зелёная НЕобъявленная запись (ceiling с нашим
    патчем) роняет его как extra.
    """
    data = _STEP29_STOCK
    if ours:
        data += _STEP29_OURS
    for w in _step29_witnesses():
        enc = w.encode("utf-8")
        if enc not in _STEP29_STOCK:
            data += enc + b"\n"
    return data


def _new_fixture() -> Path:
    handle, path = tempfile.mkstemp(prefix="checks-teeth.%d." % os.getpid(), suffix=".bin")
    os.close(handle)
    # Имя в формате копий воркера: обломки убитого воркера подбирает
    # weed_worker_leftovers, иначе пристинные копии копились бы без предела.
    return Path(path)


def _fixture_light(ver: str, *, live: bool) -> Path:
    fx = _new_fixture()
    try:
        data = b"var A=1;\n// Version: " + ver.encode() + b"\nvar B=2;\n"
        if live:
            data += _step29_subject(ours=True)
        fx.write_bytes(data)
    except BaseException:
        fx.unlink(missing_ok=True)
        raise
    return fx


def _fixture_floor(ver: str, *, live: bool) -> Path:
    """Пол сходится только там, где зелёны ВСЕ объявленные стоковые записи.

    Огрызок их не несёт (замер 2026-09-20: rc=1), поэтому база фикстуры пола --
    реальный пристин. Маркер версии переписывается РАВНОЙ ДЛИНОЙ во всех
    вхождениях: различное значение остаётся ровно одно, смещения не едут.
    """
    if not PRISTINE_LATEST.is_file():
        raise Refusal(f"нет реального пристина для базы фикстур пола: {PRISTINE_LATEST}")
    old = b"// Version: 2.1.278"
    new = b"// Version: " + ver.encode()
    if len(new) != len(old):
        raise Refusal(f"маркер {new!r} не равен длине пристинного -- копия сдвинулась бы")
    fx = _new_fixture()
    try:
        shutil.copyfile(PRISTINE_LATEST, fx)
        with open(fx, "r+b") as fh:
            raw = fh.read()
            if raw.count(old) < 1:
                raise Refusal("маркер версии пропал из пристина")
            fh.seek(0)
            fh.write(raw.replace(old, new))
        if live:
            with open(fx, "ab") as fh:
                fh.write(b"\n// step 29 live subject\n")
                fh.write(_step29_subject(ours=False))
    except BaseException:
        fx.unlink(missing_ok=True)
        raise
    return fx


def _version_image(ver: str, *, live: bool, floor: bool = False) -> Path:
    """Фикстура вместо живого образа старой версии (#354).

    Предмет зубов I1..I8 -- реакция прибора на пару «версия × наличие
    предмета», а версию прибор читает ОДНОЙ строкой (_image_version в
    checks-on-image.sh). live=False -- свидетелей шага 29 нет; live=True --
    все пять плюс формы, которые проверки шага 29 читают как живой предмет.
    """
    if floor:
        return _fixture_floor(ver, live=live)
    return _fixture_light(ver, live=live)


def _parse_registry(out: str) -> dict[str, str]:
    """Имя проверки -> OK|FAIL|NOTE. Прочие строки реестра игнорируются."""
    st: dict[str, str] = {}
    for line in out.splitlines():
        s = line.strip()
        m = re.match(r"\[(OK|FAIL|NOTE)\] (.*)$", s)
        if not m:
            continue
        tag, rest = m.group(1), m.group(2)
        name = rest.split(":", 1)[0] if tag == "NOTE" else rest
        st[name] = tag
    return st


def _step29_tags(out: str) -> dict[str, str]:
    st = _parse_registry(out)
    return {n: st.get(n, "") for n in STEP29_BOTH}


def _run_checks(script: Path, image: Path, patch: Path,
                runner: Path | None = None) -> subprocess.CompletedProcess:
    r = runner if runner is not None else RUNNER
    return subprocess.run(
        ["bash", str(r), "--script", str(script), str(image), str(patch)],
        capture_output=True,
        text=True,
        errors="replace",
    )


def _run_floor(script: Path, image: Path, patch: Path,
               runner: Path | None = None) -> subprocess.CompletedProcess:
    r = runner if runner is not None else RUNNER
    return subprocess.run(
        ["bash", str(r), "--floor", "--script", str(script), str(image), str(patch)],
        capture_output=True,
        text=True,
        errors="replace",
    )


def _once_replace(text: str, old: str, new: str, what: str) -> str:
    n = text.count(old)
    if n != 1:
        raise Refusal(f"{what}: якорь встречается {n} раз, ждали 1")
    return text.replace(old, new, 1)


def _temp_kit(*, decl_text: str | None = None, script_repl=None, patch_repl=None,
              runner_repl=None, carrier_text: str | None = None):
    """Снимок кита: скрипт + патч + дома реестров + раннер пола. Правка только снимка."""
    td = Path(tempfile.mkdtemp(prefix="checks-teeth-inapp."))
    script_dst = td / "claude-patch-all.sh"
    patch_dst = td / "tweakcc-patch.js"
    tools = td / "tools"
    tools.mkdir()
    shutil.copy2(ROOT / "claude-patch-all.sh", script_dst)
    shutil.copy2(ROOT / "tweakcc-patch.js", patch_dst)
    runner_dst = tools / "checks-on-image.sh"
    shutil.copy2(ROOT / "tools" / "checks-on-image.sh", runner_dst)
    runner_dst.chmod(0o755)
    # CONSTRAINT: реестр выключенных шагов ОБЯЗАН ехать в снимок кита.
    # _step26_verdict ищет его рядом со скриптом; в ките без реестра
    # выключенный шаг читается как включённый, его проверка даёт FAIL вместо
    # NOTE, и контроль объявляет ОБРАЗ красным -- ложная причина (#373).
    # Отсутствие файла в доме -- норма (все шаги включены), копия тогда не нужна.
    steps_off_src = ROOT / "tools" / "our-steps-off.txt"
    if steps_off_src.is_file():
        shutil.copy2(steps_off_src, tools / "our-steps-off.txt")
    # CONSTRAINT: карта «шаг -> проверки» и её единственный читатель ОБЯЗАНЫ
    # ехать в снимок: верификатор берёт имя и проверку шага 26 ИЗ МОДУЛЯ по
    # карте, и снимок без них отказал бы прибором, а не мерил. Отсутствие
    # этих файлов в доме -- НЕ норма (в отличие от реестра выключений): их
    # absence краснит гейт карты и верификатор; снимок наследует дом как есть.
    for _fname in ("step-checks.py", "our-step-checks.txt"):
        _src = ROOT / "tools" / _fname
        if _src.is_file():
            shutil.copy2(_src, tools / _fname)
    # CONSTRAINT: дом объявления отсутствия носителя ОБЯЗАН ехать в снимок
    # кита: гейт шага 26 ищет его рядом со скриптом, и снимок без дома молча
    # читал бы «ничего не объявлено» -- то же, что у our-steps-off.txt (#373).
    # Отсутствие файла в доме -- норма (ничего не объявлено), копия не нужна.
    carrier_src = ROOT / "tools" / "our-carrier-absent.txt"
    if carrier_text is not None:
        (tools / "our-carrier-absent.txt").write_text(carrier_text, encoding="utf-8")
    elif carrier_src.is_file():
        shutil.copy2(carrier_src, tools / "our-carrier-absent.txt")
    decl_path = tools / "our-patch-inapplicable.txt"
    if decl_text is None:
        src = ROOT / "tools" / "our-patch-inapplicable.txt"
        if not src.is_file():
            raise Refusal(f"нет дома декларации: {src}")
        decl_text = src.read_text(encoding="utf-8")
    decl_path.write_text(decl_text, encoding="utf-8")
    if script_repl:
        old, new = script_repl
        script_dst.write_text(
            _once_replace(script_dst.read_text(encoding="utf-8"), old, new, "скрипт"),
            encoding="utf-8",
        )
    if patch_repl:
        old, new = patch_repl
        patch_dst.write_text(
            _once_replace(patch_dst.read_text(encoding="utf-8"), old, new, "патч"),
            encoding="utf-8",
        )
    if runner_repl:
        old, new = runner_repl
        runner_dst.write_text(
            _once_replace(runner_dst.read_text(encoding="utf-8"), old, new, "раннер"),
            encoding="utf-8",
        )
    return td, script_dst, patch_dst


def _kit_decl_text() -> str:
    src = ROOT / "tools" / "our-patch-inapplicable.txt"
    if not src.is_file():
        raise Refusal(f"нет дома декларации: {src}")
    return src.read_text(encoding="utf-8")


def _decl_without_274(text: str) -> str:
    keep = [ln for ln in text.splitlines(True) if not ln.startswith("2.1.274\t29\t")]
    return "".join(keep)


def _decl_with_273(text: str) -> str:
    extra = "2.1.273\t29\tзуб I3: декларация на версии, где предмет жив\n"
    if not text.endswith("\n"):
        text += "\n"
    return text + extra


_KIT_FN_WANTED = ("_image_version", "_read_inapplicable", "_carrier_site")


@functools.lru_cache(maxsize=1)
def _kit_body_functions() -> dict[str, str]:
    """Исходники функций правил из питоньего тела блока проверок кита.

    CONSTRAINT (#353): правила «версия образа», «разбор дома декларации» и
    «площадка реестра объявлений» живут в ките (`_image_version`,
    `_read_inapplicable` и `_carrier_site` в claude-patch-all.sh); местная
    копия расходилась бы с проверяющей стороной молча. Тело достаётся
    ЕДИНСТВЕННЫМ домом правила heredoc (tools/heredoc-anchor.py) -- тем же
    путём, что и реестр checks у _pipeline_check_names; каждое имя обязано
    встретиться РОВНО один раз.
    """
    anchor_path = ROOT / "tools" / "heredoc-anchor.py"
    spec = importlib.util.spec_from_file_location(
        "checks_teeth_heredoc_anchor_kitfn", str(anchor_path))
    if spec is None or spec.loader is None:
        raise Refusal(f"дом правила heredoc не загружается: {anchor_path}")
    anchor = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(anchor)
    except Exception as exc:
        raise Refusal(f"дом правила heredoc не исполняется: {exc}") from exc
    victim = ROOT / "claude-patch-all.sh"
    if not victim.is_file():
        raise Refusal(f"нет конвейера для правил кита: {victim}")
    hits: dict[str, list[str]] = {n: [] for n in _KIT_FN_WANTED}
    with tempfile.TemporaryDirectory(prefix="checks-teeth-kitfn.") as td:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            rc = anchor.bodies(str(victim), td)
        if rc != 0:
            raise Refusal(f"тела heredoc конвейера не извлекаются: rc={rc}")
        try:
            count = int(buffer.getvalue().strip())
        except ValueError as exc:
            raise Refusal(f"дом правила не назвал число тел: {buffer.getvalue()!r}") from exc
        for i in range(1, count + 1):
            body_path = Path(td) / ("body.%d.py" % i)
            try:
                src = body_path.read_text(encoding="utf-8")
            except FileNotFoundError as exc:
                raise Refusal(f"тело heredoc №{i} не создано: {body_path}") from exc
            try:
                tree = ast.parse(src)
            except SyntaxError as exc:
                raise Refusal(f"тело heredoc №{i} не разбирается как Python: {exc}") from exc
            for node in tree.body:
                if isinstance(node, ast.FunctionDef) and node.name in hits:
                    seg = ast.get_source_segment(src, node)
                    if seg is None:
                        raise Refusal(f"исходник функции {node.name} не извлекается")
                    hits[node.name].append(seg)
    for name, segs in hits.items():
        if len(segs) != 1:
            raise Refusal(f"функция правила {name} встречена {len(segs)} раз "
                          f"в телах конвейера -- ждём ровно одну")
    return {name: segs[0] for name, segs in hits.items()}


def _kit_image_version(base: bytes) -> str:
    """Версия образа -- правилом кита `_image_version`, без местной копии (#353).

    Отказ правила (неоднозначная или отсутствующая версия) выходит из кита
    как SystemExit; здесь он становится Refusal, неся исходный текст отказа.
    """
    ns: dict[str, object] = {"re": re, "sys": sys}
    exec(compile(_kit_body_functions()["_image_version"],
                 "<kit:_image_version>", "exec"), ns)
    fn = ns["_image_version"]
    buf = io.StringIO()
    try:
        with contextlib.redirect_stderr(buf):
            return fn(base)
    except SystemExit as exc:
        raise Refusal(f"версия образа не читается правилом кита "
                      f"(код {exc.code}): {buf.getvalue().strip()}")


def _declared_pairs() -> dict[tuple[str, str], tuple[int, str]]:
    """Пары «версия × шаг» дома декларации -- парсером САМОГО кита (#353).

    CONSTRAINT: файл читает существующий _kit_decl_text(); разбор -- правило
    кита `_read_inapplicable` (неразобранная строка и дубль пары -- отказ),
    получающее текст через временный файл: домашняя сигнатура принимает путь.
    Свой разбор разошёлся бы с проверяющей стороной молча.
    """
    text = _kit_decl_text()
    ns: dict[str, object] = {"os": os, "sys": sys}
    exec(compile(_kit_body_functions()["_read_inapplicable"],
                 "<kit:_read_inapplicable>", "exec"), ns)
    fn = ns["_read_inapplicable"]
    fd, path = tempfile.mkstemp(prefix="checks-teeth-decl.", suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        buf = io.StringIO()
        try:
            with contextlib.redirect_stderr(buf):
                return fn(path)
        except SystemExit as exc:
            raise Refusal(f"дом декларации не разбирается правилом кита "
                          f"(код {exc.code}): {buf.getvalue().strip()}")
    finally:
        os.unlink(path)


def _kit_carrier_site() -> str:
    """Площадка -- правилом кита `_carrier_site`, без местной копии (#353, #389).

    Расхождение поймает зуб carrier-absent-declared-note: записи фикстуры
    перестанут подходить к площадке, NOTE не напечатается, зуб уйдёт в красный.
    """
    ns: dict[str, object] = {"os": os}
    exec(compile(_kit_body_functions()["_carrier_site"],
                 "<kit:_carrier_site>", "exec"), ns)
    return ns["_carrier_site"]()


@functools.lru_cache(maxsize=1)
def _patch_step_numbers() -> frozenset[str]:
    """Номера шагов, ОБЪЯВЛЕННЫЕ в tweakcc-patch.js строкой `step('NN ...`.

    CONSTRAINT (#353): поле 9 таблицы называет шаг-владельца ряда; номер,
    которого нет среди объявленных шагов патча, -- отказ прибора с номером,
    а не тихий пропуск: неверный номер молча подарил бы ряду чужую судьбу.
    """
    src = (ROOT / "tweakcc-patch.js").read_text(encoding="utf-8")
    nums = re.findall(r"step\('([0-9]+) ", src)
    if not nums:
        raise Refusal("в tweakcc-patch.js не найдено объявлений step('NN ...')")
    return frozenset(nums)


def run_inapplicable_tooth(row: dict[str, str]) -> str | None:
    """None -- зуб поймал свою мутацию. Строка -- прошла молча / прибор."""
    mid = row["id"]
    td = None
    img_copy = None
    fx = None
    try:
        if mid == "I1":
            fx = img = _version_image("2.1.274", live=False)
            td, script, patch = _temp_kit()
            ctrl = _run_checks(script, img, patch)
            tags = _step29_tags(ctrl.stdout or "")
            if any(tags[n] != "NOTE" for n in STEP29_BOTH):
                return f"контроль: шаг 29 не NOTE {tags}"
            shutil.rmtree(td, ignore_errors=True)
            td, script, patch = _temp_kit(script_repl=(I1_ANCHOR, I1_REPL))
            mut = _run_checks(script, img, patch)
            # CONSTRAINT: взгляд сужен до тегов шага 29 -- глобальное «нет [NOTE]»
            # ломается от постороннего NOTE (реестр our-steps-off.txt).
            mt = _step29_tags(mut.stdout or "")
            if any(mt[n] for n in STEP29_BOTH):
                return "печать убрана, а NOTE шага 29 остался -- форматтер не единственный источник"
            return None

        if mid == "I2":
            fx = img = _version_image("2.1.274", live=False)
            td, script, patch = _temp_kit(decl_text=_decl_without_274(_kit_decl_text()))
            ctrl = _run_checks(script, img, patch)
            tags = _step29_tags(ctrl.stdout or "")
            out = (ctrl.stdout or "") + (ctrl.stderr or "")
            if any(tags[n] != "FAIL" for n in STEP29_BOTH):
                return f"контроль: без декларации шаг 29 не FAIL {tags}"
            if "объявить неприменимость" not in out:
                return "контроль: нет готовой строки для вставки в дом"
            shutil.rmtree(td, ignore_errors=True)
            td, script, patch = _temp_kit(
                decl_text=_decl_without_274(_kit_decl_text()),
                script_repl=(I2_ANCHOR, I2_REPL),
            )
            mut = _run_checks(script, img, patch)
            mt = _step29_tags(mut.stdout or "")
            mout = (mut.stdout or "") + (mut.stderr or "")
            if all(mt[n] == "FAIL" for n in STEP29_BOTH) and "объявить неприменимость" in mout:
                return "декларация не читается, а отказ без строки остался -- ветка безусловного NOTE не сработала"
            if any(mt[n] == "NOTE" for n in STEP29_BOTH) and "объявить неприменимость" not in mout:
                return None
            return f"после мутации безусловного NOTE исход не тот {mt}"

        if mid == "I3":
            fx = img = _version_image("2.1.273", live=True)
            td, script, patch = _temp_kit(decl_text=_decl_with_273(_kit_decl_text()))
            ctrl = _run_checks(script, img, patch)
            tags = _step29_tags(ctrl.stdout or "")
            out = (ctrl.stdout or "") + (ctrl.stderr or "")
            if any(tags[n] != "FAIL" for n in STEP29_BOTH):
                return f"контроль: декларация на 2.1.273 не отказала {tags}"
            if "пережила причину" not in out:
                return "контроль: нет отказа «пережила причину»"
            shutil.rmtree(td, ignore_errors=True)
            td, script, patch = _temp_kit(
                decl_text=_decl_with_273(_kit_decl_text()),
                script_repl=(I3_ANCHOR, I3_REPL),
            )
            mut = _run_checks(script, img, patch)
            mt = _step29_tags(mut.stdout or "")
            mout = (mut.stdout or "") + (mut.stderr or "")
            if all(mt[n] == "OK" for n in STEP29_BOTH) and "пережила причину" not in mout:
                return None
            return f"после снятия отказа «пережила причину» исход не зелёный {mt}"

        if mid == "I4":
            fx = img = _version_image("2.1.273", live=True)
            handle, img_copy = tempfile.mkstemp(
                prefix="checks-teeth.%d." % os.getpid(), suffix=".bin")
            os.close(handle)
            shutil.copyfile(img, img_copy)
            raw = Path(img_copy).read_bytes()
            if raw.count(I4_WITNESS) < 1:
                raise Refusal("I4: якорь свидетеля budgets.model не найден в образе")
            if I4_WITNESS_REPL in raw:
                raise Refusal("I4: замена свидетеля уже есть в образе")
            Path(img_copy).write_bytes(raw.replace(I4_WITNESS, I4_WITNESS_REPL))
            td, script, patch = _temp_kit()
            ctrl = _run_checks(script, Path(img_copy), patch)
            tags = _step29_tags(ctrl.stdout or "")
            if any(tags[n] != "OK" for n in STEP29_BOTH):
                return f"контроль: один мёртвый свидетель уже роняет проверку {tags}"
            shutil.rmtree(td, ignore_errors=True)
            td, script, patch = _temp_kit(script_repl=(I4_ANCHOR, I4_REPL))
            mut = _run_checks(script, Path(img_copy), patch)
            mt = _step29_tags(mut.stdout or "")
            if all(mt[n] == "FAIL" for n in STEP29_BOTH):
                return None
            return f"порог any() не покраснил шаг 29 {mt}"

        if mid == "I5":
            fx = img = _version_image("2.1.273", live=True)
            td, script, patch = _temp_kit(patch_repl=(I5_ANCHOR, I5_REPL))
            mut = _run_checks(script, img, patch)
            mt = _step29_tags(mut.stdout or "")
            if all(mt[n] == "FAIL" for n in STEP29_BOTH):
                return None
            return f"WITNESSES в патче изменены, шаг 29 не FAIL {mt} -- список не из src"

        if mid == "I6":
            fx = img = _version_image("2.1.274", live=False, floor=True)
            td, script, patch = _temp_kit()
            runner = td / "tools" / "checks-on-image.sh"
            ctrl = _run_floor(script, img, patch, runner)
            cout = (ctrl.stdout or "") + (ctrl.stderr or "")
            if I6_PHRASE not in cout:
                return "контроль: пол на 2.1.274 не объявил вывод записи из сверки"
            if ctrl.returncode != 0:
                return f"контроль: пол на 2.1.274 с декларацией не сошёлся rc={ctrl.returncode}"
            shutil.rmtree(td, ignore_errors=True)
            td, script, patch = _temp_kit(runner_repl=(I6_ANCHOR, I6_REPL))
            runner = td / "tools" / "checks-on-image.sh"
            mut = _run_floor(script, img, patch, runner)
            mout = (mut.stdout or "") + (mut.stderr or "")
            if I6_PHRASE in mout:
                return "печать вывода из сверки убрана, а фраза осталась"
            return None

        if mid == "I7":
            fx = img = _version_image("2.1.274", live=False, floor=True)
            td, script, patch = _temp_kit(decl_text=_decl_without_274(_kit_decl_text()))
            runner = td / "tools" / "checks-on-image.sh"
            ctrl = _run_floor(script, img, patch, runner)
            if ctrl.returncode == 0:
                return "контроль: пол на 2.1.274 без декларации сошёлся -- красную DECLARED вывел молча"
            shutil.rmtree(td, ignore_errors=True)
            td, script, patch = _temp_kit(
                decl_text=_decl_without_274(_kit_decl_text()),
                runner_repl=(I7_ANCHOR, I7_REPL),
            )
            runner = td / "tools" / "checks-on-image.sh"
            mut = _run_floor(script, img, patch, runner)
            if mut.returncode == 0:
                return None
            return (f"пол выводит незелёную DECLARED без декларации, а мутация "
                    f"не сделала пол зелёным rc={mut.returncode}")

        if mid == "I8":
            fx = img = _version_image("2.1.273", live=True, floor=True)
            td, script, patch = _temp_kit()
            runner = td / "tools" / "checks-on-image.sh"
            ctrl = _run_floor(script, img, patch, runner)
            cout = (ctrl.stdout or "") + (ctrl.stderr or "")
            if ctrl.returncode != 0:
                return f"контроль: пол на 2.1.273.orig не сошёлся rc={ctrl.returncode}"
            if I6_PHRASE in cout:
                return "контроль: пол на 2.1.273 вывел запись по чужой декларации 274"
            shutil.rmtree(td, ignore_errors=True)
            td, script, patch = _temp_kit(runner_repl=(I8_ANCHOR, I8_REPL))
            runner = td / "tools" / "checks-on-image.sh"
            mut = _run_floor(script, img, patch, runner)
            mout = (mut.stdout or "") + (mut.stderr or "")
            if mut.returncode != 0 and I6_PHRASE in mout:
                return None
            return (f"игнор версии декларации не покраснил пол 273 "
                    f"rc={mut.returncode} phrase={I6_PHRASE in mout}")

        raise Refusal(f"{mid}: нет раннера для этого id")
    finally:
        if td is not None:
            shutil.rmtree(td, ignore_errors=True)
        if fx is not None:
            fx.unlink(missing_ok=True)
        if img_copy is not None:
            try:
                os.unlink(img_copy)
            except FileNotFoundError:
                pass


def _tooth_anchor_real_278() -> str | None:
    """Якорь против вакуумности фикстур: РЕАЛЬНЫЙ образ 2.1.278.

    Без якоря набор фикстур согласован сам с собой и ничего не доказывает о
    живом дереве: прибор обязан прочитать с реального образа версию и
    применить декларацию той же логикой, что и на фикстуре. Исход запинен:
    декларация 2.1.278 внесена в дом (#324 закрыт этой волной) -- значит
    NOTE/declared и БЕЗ готовой строки; обходить этот исход здесь нельзя.
    """
    if not PRISTINE_LATEST.is_file():
        raise Refusal(f"нет реального пристина 2.1.278: {PRISTINE_LATEST}")
    td, script, patch = _temp_kit()
    try:
        r = _run_checks(script, PRISTINE_LATEST, patch)
        tags = _step29_tags(r.stdout or "")
        out = (r.stdout or "") + (r.stderr or "")
        if any(tags[n] != "NOTE" for n in STEP29_BOTH):
            return f"якорь: шаг 29 на реальном 2.1.278 не NOTE/declared {tags}"
        if "объявить неприменимость:" in out:
            return "якорь: готовая строка осталась при ОБЪЯВЛЕННОЙ декларации"
        return None
    finally:
        shutil.rmtree(td, ignore_errors=True)


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
# CONSTRAINT (Ф4 fix-волны #407): файл владельца в каталоге фикстуры несёт pid
# создателя; удаление каталога требует ОБА условия -- возраст И мёртвый
# владелец. Возраст остаётся вторым условием именно из-за переиспользования
# pid: живой номер не значит живого создателя.
_FIXTURE_OWNER_NAME = ".owner.pid"
# CONSTRAINT (Х6 fix-волны #407, раунд 3): реестр префиксов прополки ОДИН и
# стоит рядом с ней. Прежде прополка знала ДВА имени из восьми живых, и всякий
# новый mkdtemp молча оставался без владельца уборки (намерено во временном
# доме: 84 каталога одного префикса, 23 другого, 11 третьего). Свой finally у
# потребителя реестр НЕ отменяет: прополка -- сетка для ОБОРВАННЫХ прогонов
# (SIGKILL/OOM/обрыв терминала), где finally не исполняется вовсе.
_WEED_DIR_PREFIXES = (
    "checks-teeth-inapp.",
    "checks-teeth-fixture407.",
    "checks-teeth-fxmut.",
    "checks-teeth-fxbuild.",
    "checks-teeth-fx2a.",
    "checks-teeth-z6.",
    "checks-teeth-crun.",
    "checks-teeth-phases408.",
)


def _proc_start_stamp(pid: int) -> str | None:
    """Метка старта процесса (на маке и Linux -- `ps -p <pid> -o lstart=`).

    CONSTRAINT (Х7 fix-волны #407, раунд 3): pid переиспользуется, и голый
    os.kill(pid, 0) на ЧУЖОМ живом номере объявляет владельца живым навсегда --
    каталог не убирается НИКОГДА (воспроизведено на pid 1). Метка старта
    отличает тот же НОМЕР от того же ПРОЦЕССА. Метка недоступна -- предикат
    падает на прежнюю пару «возраст И живой номер»; второго порога возраста не
    вводим: он был бы догадкой вместо признака.
    """
    try:
        done = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                              capture_output=True, text=True, errors="replace")
    except OSError:
        return None
    if done.returncode != 0:
        return None
    return (done.stdout or "").strip() or None


def _owner_file_text(pid: int) -> str:
    """Тело файла владельца: pid и метка старта его процесса (Х7)."""
    return "%d\n%s\n" % (pid, _proc_start_stamp(pid) or "")


@contextlib.contextmanager
def _weed_env_tmpdir(root: Path):
    """TMPDIR на временный дом прополки: glob читает os.environ["TMPDIR"]."""
    saved = os.environ.get("TMPDIR")
    os.environ["TMPDIR"] = str(root)
    try:
        yield
    finally:
        if saved is None:
            os.environ.pop("TMPDIR", None)
        else:
            os.environ["TMPDIR"] = saved


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
    # CONSTRAINT (Р2/Ф4 fix-волны #407): каталог фикстуры носит файл владельца
    # с pid создателя; удаление требует ОБА условия -- возраст больше порога И
    # мёртвый владелец. Каталог БЕЗ файла владельца -- остаток прежней формы:
    # удаляется по возрасту, как и до владельцев. Возраст остаётся вторым
    # условием из-за переиспользования pid: живой номер не значит живого
    # создателя. Х6: условия одни и те же для ВСЕХ префиксов реестра.
    for prefix in _WEED_DIR_PREFIXES:
        for dpath in glob.glob(os.path.join(tmp, prefix + "*")):
            try:
                dstat = os.stat(dpath)
            except FileNotFoundError:
                continue
            if (time.time() - dstat.st_mtime) < WORKER_TMP_HELD_SECONDS:
                continue
            pid = None
            want = ""
            try:
                with open(os.path.join(dpath, _FIXTURE_OWNER_NAME), "rb") as fh:
                    raw = fh.read(256).decode("utf-8", "replace").splitlines()
                pid = int(raw[0].strip())
                want = raw[1].strip() if len(raw) > 1 else ""
            except (OSError, ValueError, IndexError):
                pid = None
            if pid is not None:
                alive = True
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    alive = False
                except (PermissionError, OverflowError, ValueError):
                    alive = True
                # CONSTRAINT (Х7): тот же НОМЕР -- не тот же процесс. Метка
                # старта не совпала -- номер переиспользован, владелец мёртв.
                if alive and want:
                    got = _proc_start_stamp(pid)
                    if got is not None and got != want:
                        alive = False
                if alive:
                    continue
            try:
                dafter = os.stat(dpath)
            except FileNotFoundError:
                continue
            if ((dafter.st_ino, dafter.st_mtime_ns)
                    != (dstat.st_ino, dstat.st_mtime_ns)):
                continue           # подменён между замером и снятием -- не наш
            try:
                shutil.rmtree(dpath)
            except FileNotFoundError:
                continue
            removed += 1
    return removed


def reds(image: Path) -> tuple[list[str], str]:
    done = subprocess.run(["bash", str(RUNNER), str(image)],
                          capture_output=True, text=True, errors="replace")
    out = done.stdout
    red = [l.strip()[7:] for l in out.splitlines() if l.strip().startswith("[FAIL] ")]
    green = [l for l in out.splitlines() if l.strip().startswith("[OK] ")]
    if not red and not green:
        raise Refusal("реестр не назвал ни одной проверки: " + (out or done.stderr)[-500:])
    return red, out


def build_jobs(rows: list[dict[str, str]], picked: set[str] | None, image: Path,
               base: bytes, *, ver: str | None = None,
               decl_pairs: dict[tuple[str, str], tuple[int, str]] | None = None,
               ) -> tuple[list[tuple], list[dict[str, str]], list[tuple[str, str, str, str]],
                          list[tuple[str, str]]]:
    """Построение заданий; отказ строителя -- исход СТРОКИ, не прохода (#350).

    Прежний Refusal строителя завершал проход кодом 2 ДО построения остальных
    заданий: одна сместившаяся строка ослепляла прибор по всему реестру, а
    свип читал код 2 как «не измеряли». Отказ ловится на границе ЭТОЙ строки;
    остальные строки строятся и измеряются. Возвращает (jobs, inapp_rows,
    inapplicable_by_version, refused), где refused -- пары (id, сырой текст
    отказа), а inapplicable_by_version -- четвёрки (id, версия, шаг,
    основание).

    Третий исход рядов образа (#353): пара «версия образа × шаг-владелец»
    (поле 9), ОБЪЯВЛЕННАЯ неприменимой в доме декларации, уводит ряд из
    мутаций И из отказов -- постоянные жильцы ведра отказов делали прибор
    слепым к новому отказу того же ведра. Неприменимость даёт только
    ОБЪЯВЛЕНИЕ: без строки в декларации ряд строится как обычно, и мёртвый
    якорь остаётся отказом прибора. ver/decl_pairs -- точки внедрения зубов;
    живой прогон оставляет их None и читает правила кита.
    """
    jobs: list[tuple] = []
    inapp_rows: list[dict[str, str]] = []
    inapplicable_by_version: list[tuple[str, str, str, str]] = []
    refused: list[tuple[str, str]] = []
    steps: frozenset[str] = frozenset()
    setup_fail: str | None = None
    if any(str(r.get("step", "")) for r in rows
           if picked is None or r["id"] in picked):
        try:
            steps = _patch_step_numbers()
            if ver is None:
                ver = _kit_image_version(base)
            if decl_pairs is None:
                decl_pairs = _declared_pairs()
        except Refusal as exc:
            setup_fail = str(exc)
    for row in rows:
        if picked is not None and row["id"] not in picked:
            continue
        if row["kind"] == "inapplicable":
            inapp_rows.append(row)
            continue
        # Инвариант: поле шага непусто => шаги/версия/декларация прочитаны
        # (need_steps выше) либо их отказ уже записан в setup_fail.
        step_owner = str(row.get("step", ""))
        if step_owner:
            if setup_fail is not None:
                refused.append((row["id"], setup_fail))
                continue
            if step_owner not in steps:
                refused.append((row["id"],
                                f"поле 9: шаг {step_owner} не объявлен в tweakcc-patch.js"))
                continue
            hit = decl_pairs.get((ver, step_owner))
            if hit is not None:
                inapplicable_by_version.append((row["id"], ver, step_owner, hit[1]))
                continue
        try:
            if row["kind"] == "derived":
                edits = DERIVED[row["id"]](base)
            elif row["kind"] == "literal":
                edits = edits_literal(base, row)
            else:
                raise Refusal(f"{row['id']}: неизвестный вид мутации {row['kind']}")
        except Refusal as exc:
            refused.append((row["id"], str(exc)))
            continue
        want = {row["check"]}
        want |= {x.strip() for x in row["also"].split(";") if x.strip()}
        jobs.append((row["id"], row["check"], str(image), edits, sorted(want)))
    return jobs, inapp_rows, inapplicable_by_version, refused


def summary_line(measured: int, bad: int) -> str:
    """Итог измеренных: отказавшие строки сюда НЕ входят -- им свой счётчик."""
    return f"checks-teeth: ИТОГ мутаций={measured} прошло молча/чужой дверью={bad}"


def refusal_line(refused: list[tuple[str, str]]) -> str:
    ids = ", ".join(rid for rid, _ in refused)
    return f"checks-teeth: ИТОГ отказов прибора={len(refused)} id: {ids}"


def inapplicable_row_line(rid: str, ver: str, step: str, reason: str) -> str:
    """Строка третьего исхода: называет ВЕРСИЮ, ШАГ и ОСНОВАНИЕ декларации.

    CONSTRAINT (#353): два исхода одной строкой неразличимы -- текст обязан
    отличаться от строки отказа прибора и нести основание из декларации.
    """
    return (f"checks-teeth: МУТАЦИЯ {rid}: НЕПРИМЕНИМО ПО ВЕРСИИ -- "
            f"образ {ver}, шаг {step}: {reason}")


def inapplicable_line(inapplicable_by_version: list[tuple[str, str, str, str]]) -> str:
    ids = ", ".join(rid for rid, _ver, _step, _reason in inapplicable_by_version)
    return (f"checks-teeth: ИТОГ неприменимых по версии="
            f"{len(inapplicable_by_version)} id: {ids}")


def exit_code(bad: int, refused: int) -> int:
    """Код прохода при отказах строк. Оба класса выставляются ПОСЛЕ измерения
    всех строк; найденный дефект зубов (1) приоритетнее отказа строк (9).
    Отказ строк -- НЕ 2: свип читает 2 как «не измеряли», а проход, измеривший
    строки, не имеет права читаться как «не мерили»."""
    if bad:
        return 1
    if refused:
        return 9
    return 0


def _unmeasured_line(reason: str) -> str:
    """Итог фазы, которая не исполнилась.

    CONSTRAINT (#408): текст обязан отличаться от summary_line -- «ноль
    измеренных» и «не измерено» -- разные исходы, и одна строка на оба
    делала ПУСТО неотличимым от НОЛЯ (тот же класс, что у итога входа).
    """
    return f"checks-teeth: ИТОГ мутаций=НЕ ИЗМЕРЕНО -- {reason}"


def _phase_skipped(code: int, why: str, entry_bad: int) -> int:
    """«Мутационной фазе мерить нечем»: причина в stderr, итог фазы -- всегда.

    CONSTRAINT (#408): точка пропуска печатает причину прежним текстом и
    уходит к финальному коду, а не в возврат посреди прохода; итог фазы
    печатается и для неисполнившейся фазы. Найденный дефект входа
    приоритетнее кода «не измерено»: красный вход без раннера даёт 1, а не 6.
    """
    print(f"checks-teeth: {why}", file=sys.stderr)
    print(_unmeasured_line(why), flush=True)
    # CONSTRAINT (Ф6 fix-волны #407): «ФАЗА НЕ ЗАПУСКАЛАСЬ», а не «НЕ
    # ИЗМЕРЕНО»: здесь проход ушёл ДО фазы фикстуры, а «не измерено» --
    # исход САМОЙ фазы, которая запускалась и не смогла; одна строка на оба
    # делала «фазы не было» неотличимым от «фаза сломалась».
    print(_fixture_not_started_line(why), flush=True)
    return _phase_exit(code, entry_bad)


def _phase_exit(code: int, entry_bad: int, fx_code: int = 0) -> int:
    """Код точки выхода ПОСЛЕ итога входа: свёртка с объявленной границей (#407).

    ЕДИНСТВЕННЫЙ дом приоритета исходов (Р1 fix-волны #407): код 4 (расхождение
    набора с пином) доминирует; дальше найденный дефект (1) > отказ прибора (9)
    > «НЕ ИЗМЕРЕНО» фазы фикстуры (2) > прочий код точки. fx_code -- вердикт
    фазы фикстуры (0/1/2/4/9); пути ДО её запуска зовут функцию с умолчанием.
    CONSTRAINT (Р6 #407): коды «НЕ ИЗМЕРЕНО» (2, 3, 5, 6) при красном входе
    отдаются как 1 -- найденный дефект входа не имеет права уехать под код
    «не мерили» (тот же класс подмены, что чинила #408). CONSTRAINT: код 4
    НЕ сворачивается: расхождение набора с пином -- само найденный дефект
    (недоверенная опись обесценивает счёты) и доминирует над красным входом;
    асимметрия объявлена ЗДЕСЬ, а не побочным голым выходом. Причину точки
    печатает вызывающий ПРЕЖНИМ текстом в обоих случаях.
    CONSTRAINT (Ф12 fix-волны #407): дом покрывает пути, У КОТОРЫХ ЕСТЬ исход
    фазы; три возврата main() мимо него -- --self-check (другой режим), --jobs
    меньше 1 и расхождение пина зубов входа (уходят до вычисления entry_bad и
    любых исходов фаз -- сворачивать нечего) -- решение контроллера, не
    упущение.
    """
    if code == 4 or fx_code == 4:
        return 4
    if entry_bad or code == 1 or fx_code == 1:
        return 1
    if code == 9 or fx_code == 9:
        return 9
    if fx_code == 2:
        return 2
    return code


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


def _run_runner_floor(patch_src: Path) -> subprocess.CompletedProcess:
    """Настоящий раннер, крошечный файл вместо образа: дверь стоит выше работы с образом."""
    with tempfile.TemporaryDirectory(prefix="checks-teeth-entry.") as td:
        stub = Path(td) / "stub-image"
        stub.write_bytes(b"stub\n")
        return subprocess.run(
            ["bash", str(RUNNER), "--floor", str(stub), str(patch_src)],
            capture_output=True,
            text=True,
            errors="replace",
        )


def _tooth_wrong_patch_src() -> str | None:
    """Отказ двери на заведомо не том исходнике. None -- зуб зелёный."""
    kit = ROOT / "claude-patch-all.sh"
    done = _run_runner_floor(kit)
    err = done.stderr or ""
    if done.returncode != 2:
        return f"код {done.returncode}, ждали 2"
    if "ЯКОРЬ ПРОПАЛ" not in err:
        return "в stderr нет «ЯКОРЬ ПРОПАЛ»"
    if "вызван неверно" not in err:
        return "в stderr нет «вызван неверно»"
    if str(kit) not in err:
        return "в stderr нет пути исходника"
    return None


def _tooth_real_patch_src() -> str | None:
    """Дверь пропускает настоящий tweakcc-patch.js. None -- зуб зелёный."""
    src = ROOT / "tweakcc-patch.js"
    done = _run_runner_floor(src)
    err = done.stderr or ""
    if "вызван неверно" in err or "в исходнике патча нет" in err:
        return "дверь отказала настоящему tweakcc-patch.js"
    return None


# Якорь мутации зуба kit-steps-off-src: несущие строки копирования реестра
# выключенных шагов в _temp_kit. Мутация гасит условие -- копирование снимается.
KIT_STEPS_OFF_ANCHOR = (
    "    steps_off_src = ROOT / \"tools\" / \"our-steps-off.txt\"\n"
    "    if steps_off_src.is_file():\n"
    "        shutil.copy2(steps_off_src, tools / \"our-steps-off.txt\")\n"
)
KIT_STEPS_OFF_REPL = (
    "    steps_off_src = ROOT / \"tools\" / \"our-steps-off.txt\"\n"
    "    if False:\n"
    "        shutil.copy2(steps_off_src, tools / \"our-steps-off.txt\")\n"
)


# Маркеры текстов вердикта реестра выключенных шагов (#373): NOTE провенанса и
# отказ stale обязаны быть РАЗНЫМИ строками -- исходы с одним текстом
# неразличимы ни для оператора, ни для зуба.
_PREDATES_MARK = "собран до версии-пола"
_STALE_MARK = "запись пережила причину"
_STEP26_CHECK = "dispatch-cancellation rule reaches the main loop"
_STEP26_ROW = "26 dispatch-cancellation rule in the system prompt"


# --- фаза фикстуры шага 26 (#407) ---------------------------------------------
#
# Предмет трёх зубов СТРОИТСЯ, а не предполагается: в живом 2.1.278 текста
# правила нет (шаг выключен реестром ДО сборки, Ф1 #407), поэтому обе ветки
# пола вердикта на живом образе недостижимы. Фикстура -- копия пристина
# 2.1.278 с конвейерной нейтрализацией и ПРИМЕНЁННЫМ шагом 26 -- строится
# общим домом рецепта tools/fixture-build.sh (механизм K1 разбора #407).
FIXTURE_BUILDER = ROOT / "tools" / "fixture-build.sh"
_FIXTURE_STATE: dict[str, object] = {}


def _fixture_fork_path() -> Path:
    """Ручка форка -- ОДИН дом со строителем: fixture-build.sh читает ${FORK:-…}.

    CONSTRAINT (Р10 fix-волны #407): предпроверка наличия форка обязана
    смотреть туда же, куда пойдёт строитель, -- иначе заданный FORK доложен
    бы «нет форка», не попробовав настроенный.
    """
    env = os.environ.get("FORK")
    if env:
        return Path(env)
    return (Path.home() / "work" / "SIB" / "Transmutation" / "Nexus" /
            "Catalyst" / "Catalyst-tweakcc" / "dist" / "index.mjs")


def _fixture_unmeasured_line(reason: str) -> str:
    """Итог фазы фикстуры, которая не измерила свой предмет (#407).

    CONSTRAINT: форма отлична от измеренной -- «не измерено» и «ноль» одной
    строкой неразличимы (тот же класс, что у _unmeasured_line, #408).
    """
    return f"checks-teeth: ИТОГ фикстур=НЕ ИЗМЕРЕНО -- {reason}"


def _fixture_refusal_line(reason: str) -> str:
    """Итог фазы фикстуры, сломавшейся прибором (Р6 fix-волны #407).

    CONSTRAINT: отказ прибора -- отдельный исход, не сворачиваемый в
    неизмеренность: сломанный предмет и площадка без предмета обязаны быть
    различимы текстом итоговой строки.
    """
    return f"checks-teeth: ИТОГ фикстур=ОТКАЗ ПРИБОРА -- {reason}"


def _fixture_not_started_line(reason: str) -> str:
    """Итог фазы фикстуры, которая не запускалась (Р9 fix-волны #407).

    CONSTRAINT: молчание фазы читалось бы как её зелёный ноль (класс #396) --
    строка обязана присутствовать на КАЖДОМ пути main(), уходящем до фазы,
    и называть причину.
    """
    return f"checks-teeth: ИТОГ фикстур=ФАЗА НЕ ЗАПУСКАЛАСЬ -- {reason}"


def _fixture_missing_tool() -> str | None:
    """Инструментарий фазы до его запуска: отсутствие -- НЕ ИЗМЕРЕНО, не отказ."""
    if not FIXTURE_BUILDER.is_file():
        return f"нет общего дома рецепта: {FIXTURE_BUILDER}"
    if shutil.which("node") is None:
        return "нет node для сборки фикстуры"
    if not _fixture_fork_path().is_file():
        return f"нет форка для сборки фикстуры: {_fixture_fork_path()}"
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина для базы фикстуры: {PRISTINE_LATEST}"
    if not (ROOT / "tweakcc-patch.js").is_file():
        return f"нет патча для фикстуры: {ROOT / 'tweakcc-patch.js'}"
    return None


def _builder_outcome(stage: str, r: subprocess.CompletedProcess) -> tuple[Path | None, str | None]:
    """Исход строителя по его коду (Р6 fix-волны #407).

    Код 3 -- «инструментария/предмета нет»: (None, причина) -- фаза уходит в
    НЕ ИЗМЕРЕНО с причиной строителя. Любой иной ненулевой -- Refusal:
    сломанный предмет не имеет права читаться как неизмеренность площадки.
    """
    tail = ((r.stderr or "") + (r.stdout or ""))[-400:]
    if r.returncode == 3:
        return None, f"нет инструментария/предмета ({stage}, rc=3): {tail}"
    raise Refusal(f"строитель фикстуры отказал на {stage} "
                  f"(rc={r.returncode}): {tail}")


def _step26_fixture() -> tuple[Path | None, str | None]:
    """Фикстура «2.1.278 + применённый шаг 26» (#407); (None, причина) -- не построена.

    CONSTRAINT (Р2 #407): строится ОДИН раз за прогон, лениво -- только когда
    фаза фикстуры исполняется; живёт в одном месте и убирается в конце фазы
    (_fixture_cleanup). Две копии образа по ~218 МБ живут одновременно --
    принято (Р2 #407).
    """
    cached = _FIXTURE_STATE.get("path")
    if isinstance(cached, Path):
        return cached, None
    miss = _fixture_missing_tool()
    if miss is not None:
        return None, miss
    td = Path(tempfile.mkdtemp(prefix="checks-teeth-fixture407."))
    # CONSTRAINT (Ф4 fix-волны #407 + Х7 раунда 3): файл владельца несёт pid
    # создателя И метку старта его процесса -- прополка удаляет каталог при
    # возрасте И мёртвом владельце, а переиспользованный номер мёртв.
    (td / _FIXTURE_OWNER_NAME).write_text(
        _owner_file_text(os.getpid()), encoding="utf-8")
    subject = td / "subject"
    fixture = td / "fixture"
    _FIXTURE_STATE["dir"] = td
    r1 = subprocess.run(
        ["bash", str(FIXTURE_BUILDER), "neutralize", str(PRISTINE_LATEST),
         str(subject)], capture_output=True, text=True, errors="replace")
    if r1.returncode != 0:
        return _builder_outcome("нейтрализация", r1)
    r2 = subprocess.run(
        ["bash", str(FIXTURE_BUILDER), "apply", str(ROOT / "tweakcc-patch.js"),
         str(subject), str(fixture)],
        capture_output=True, text=True, errors="replace")
    if r2.returncode != 0:
        return _builder_outcome("применение шага 26", r2)
    _FIXTURE_STATE["path"] = fixture
    return fixture, None


def _fixture_cleanup() -> None:
    """Убрать предмет фазы (#407): каталог и состояние -- целиком."""
    d = _FIXTURE_STATE.pop("dir", None)
    _FIXTURE_STATE.pop("path", None)
    if d is not None:
        shutil.rmtree(d, ignore_errors=True)


def _step26_fixture_control(fixture: Path) -> str | None:
    """Положительный контроль фикстуры: вердикт шага 26 дошёл до ВЕТКИ ПОЛА.

    CONSTRAINT (Р3 #407): строка шага 26 в выводе обязана быть исходом ветки
    пола -- при боевом реестре (пол 2.1.278 = версия образа) это отказ
    stale, а при поле выше версии образа -- NOTE провенанса; NOTE выключения
    означает, что правила в образе НЕТ -- сборка отдала НЕ-предмет. Контроль
    не прошёл -- все зубы фазы уходят в НЕ ИЗМЕРЕНО с названной причиной:
    молча зеленеть запрещено (ровно тот дефект, который чинит волна).
    """
    td, script, patch = _temp_kit()
    try:
        r = _run_checks(script, fixture, patch)
    finally:
        shutil.rmtree(td, ignore_errors=True)
    out = (r.stdout or "") + (r.stderr or "")
    if f"[FAIL] {_STEP26_CHECK}" in out and _STALE_MARK in out:
        return None
    if _PREDATES_MARK in out:
        return None
    if "шаг выключен" in out:
        return ("вердикт шага 26 -- NOTE выключения: правила в образе нет, "
                "фикстура не построена")
    return "вердикт шага 26 не достиг ветки пола: " + (out or "вывод пуст")[-300:]


def _fixture_phase(entry_bad: int) -> int:
    """Фаза фикстуры шага 26 (#407): предмет СТРОИТСЯ, зубы идут по построенному.

    CONSTRAINT (Р5 #407): фаза стоит ПОСЛЕ взятия замка конвейера -- она
    строит и читает образ, а контрактом входной фазы («не зависеть от образа
    и не занимать замок») это запрещено. Итог печатается ВСЕГДА, включая
    «НЕ ИЗМЕРЕНО -- причина» и «ОТКАЗ ПРИБОРА -- причина» строителя.
    Возврат: 1 -- найденный дефект; 4 -- разошёлся пин набора (объявленная
    граница Р6: доминирует); 9 -- отказ прибора (строитель либо пустая
    причина зуба); 2 -- НЕ ИЗМЕРЕНО; 0 -- измерено и зелено.
    """
    if len(_FIXTURE_TEETH) != EXPECTED_FIXTURE_TEETH:
        print(f"checks-teeth: ОТКАЗ -- зубов фикстуры {len(_FIXTURE_TEETH)}, "
              f"объявлено {EXPECTED_FIXTURE_TEETH}", file=sys.stderr)
        # CONSTRAINT (Х5 fix-волны #407, раунд 3): итог фазы печатается и
        # здесь. Без него на stdout не остаётся НИ ОДНОЙ строки
        # «ИТОГ фикстур=», и потребитель, грепающий итог фазы, читает
        # молчание как её зелёный ноль (класс #396). Соседний путь -- пин
        # зубов входа -- печатает её с раунда 2; асимметрия и была дефектом.
        print(_fixture_not_started_line(
            f"зубов фикстуры {len(_FIXTURE_TEETH)}, объявлено "
            f"{EXPECTED_FIXTURE_TEETH}"), flush=True)
        return 4
    bad = 0
    unmeasured = 0
    refusals = 0
    try:
        try:
            fixture, why = _step26_fixture()
        except Refusal as exc:
            # CONSTRAINT (Р6 fix-волны #407): отказ строителя -- ОТКАЗ ПРИБОРА,
            # отдельный исход, не сворачиваемый в неизмеренность: сломанный
            # предмет и площадка без предмета неразличимы одним текстом.
            print(f"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}", file=sys.stderr,
                  flush=True)
            print(_fixture_refusal_line(str(exc)), flush=True)
            return _phase_exit(0, entry_bad, 9)
        ctrl = None
        if fixture is not None:
            try:
                ctrl = _step26_fixture_control(fixture)
            except Refusal as exc:
                ctrl = str(exc)
            if ctrl is not None:
                why = f"положительный контроль фикстуры: {ctrl}"
        for name, fn in _FIXTURE_TEETH:
            if fixture is None or ctrl is not None:
                unmeasured += 1
                print(f"checks-teeth: ФИКСТУРА {name}: НЕ ИЗМЕРЕНО -- {why}",
                      flush=True)
                continue
            try:
                reason = fn(fixture)
            except Refusal as exc:
                unmeasured += 1
                # CONSTRAINT (Р8 fix-волны #407): причина первого отказа зуба
                # доживает до итоговой строки -- «-- None» в итоге читался бы
                # как «причины нет».
                if why is None:
                    why = str(exc)
                print(f"checks-teeth: ФИКСТУРА {name}: НЕ ИЗМЕРЕНО -- {exc}",
                      flush=True)
                continue
            if reason is None:
                print(f"checks-teeth: ФИКСТУРА {name}: OK", flush=True)
                continue
            if reason == "":
                # CONSTRAINT (Р12 fix-волны #407): пустая причина -- отказ
                # прибора, отдельный исход от «ПРОШЛА МОЛЧА»: проверка «if
                # reason» пускала такой зуб в OK.
                refusals += 1
                print(f"checks-teeth: ФИКСТУРА {name}: ОТКАЗ ПРИБОРА -- "
                      f"зуб вернул пустую причину", flush=True)
                continue
            bad += 1
            print(f"checks-teeth: ФИКСТУРА {name}: ПРОШЛА МОЛЧА -- {reason}",
                  flush=True)
    finally:
        # CONSTRAINT (Р2 fix-волны #407): уборка в finally -- исключение фазы
        # (OSError/RuntimeError/KeyboardInterrupt) не имеет права уносить
        # каталог копии образа; finally не глушит исключение.
        _fixture_cleanup()
    if bad:
        print(f"checks-teeth: ИТОГ фикстур={len(_FIXTURE_TEETH)} "
              f"молча/неверно={bad} не измерено={unmeasured}", flush=True)
        return _phase_exit(1, entry_bad)
    if refusals:
        print(_fixture_refusal_line("зуб фазы вернул пустую причину"), flush=True)
        return _phase_exit(0, entry_bad, 9)
    if unmeasured:
        print(_fixture_unmeasured_line(why), flush=True)
        return _phase_exit(0, entry_bad, 2)
    print(f"checks-teeth: ИТОГ фикстур={len(_FIXTURE_TEETH)} "
          f"молча/неверно={bad} не измерено={unmeasured}", flush=True)
    return _phase_exit(0, entry_bad)


# CONSTRAINT (Ф2 fix-волны #407): перечень ROOT-производных модульных констант
# -- ЕДИНСТВЕННЫЙ дом перепривязки копий прибора; копия лежит вне дома кита,
# и неперепривязанная константа указывает в каталог копии -- зуб, читающий
# её, зеленеет по чужой причине (измерено на FIXTURE_BUILDER в зубе FORK).
# Новая ROOT-производная обязана попасть сюда и в зуб перечня
# (_tooth_mutant_rebinds_root_derived), иначе она уедет молча.
_ROOT_DERIVED = ("TABLE", "RUNNER", "FIXTURE_BUILDER",
                 "_STEP_CHECKS_TOOL", "_STEP_CHECKS_MAP", "_CORPUS_TOOL")


def _rebind_copy_home(mod) -> None:
    """Вернуть копии прибора ROOT и все ROOT-производные константы дома."""
    mod.ROOT = ROOT
    for name in _ROOT_DERIVED:
        setattr(mod, name, globals()[name])


def _fx_mutant(pairs: tuple[tuple[str, str, str], ...]):
    """Копия прибора с названными заменами текста; константы возвращены дому.

    Возвращает (модуль, каталог копии); каталог убирает вызывающий. Якоря
    замен собираются конкатенацией в зубах -- цельный литерал якоря в теле
    зуба дал бы второе вхождение, и замена отказала бы на самом зубе.
    """
    src = Path(__file__).read_text(encoding="utf-8")
    for old, new, what in pairs:
        src = _once_replace(src, old, new, what)
    raw = Path(tempfile.mkdtemp(prefix="checks-teeth-fxmut."))
    mod = raw / "checks-teeth-mutated.py"
    mod.write_text(src, encoding="utf-8")
    spec = importlib.util.spec_from_file_location("checks_teeth_fx_mutant", mod)
    mut = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mut)
    _rebind_copy_home(mut)
    return mut, raw


def _fixture_recursion_probe(mod) -> tuple[int, str]:
    """Рекурсивный прогон фазы модуля на пристине; (код, перехваченный вывод)."""
    saved = dict(mod._FIXTURE_STATE)
    mod._FIXTURE_STATE.clear()
    mod._FIXTURE_STATE["path"] = PRISTINE_LATEST
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = mod._fixture_phase(0)
        return code, buf.getvalue()
    finally:
        mod._FIXTURE_STATE.clear()
        mod._FIXTURE_STATE.update(saved)


class _ModuleHome:
    """Доступ к глобалям СВОЕГО или чужого модуля одной формой.

    Зубам, гоняющим и живой прибор, и его копию, нужен одинаковый доступ к
    FIXTURE_BUILDER/_FIXTURE_STATE; sys.modules[__name__] ломается при
    загрузке прибора importlib-ом без регистрации в sys.modules.
    """

    def __init__(self, mod=None):
        object.__setattr__(self, "_mod", mod)

    def __getattr__(self, name):
        mod = object.__getattribute__(self, "_mod")
        if mod is None:
            return globals()[name]
        return getattr(mod, name)

    def __setattr__(self, name, value):
        mod = object.__getattribute__(self, "_mod")
        if mod is None:
            globals()[name] = value
        else:
            setattr(mod, name, value)


def _fixture_recursion_verdict(code: int, out: str) -> str | None:
    """Вердикт по рекурсивной неизмеренной фазе; None -- исход честный."""
    if "ПРОШЛА МОЛЧА" in out:
        return f"фаза с образом без правила измерила зубы: rc={code}: {out!r}"
    # CONSTRAINT (Р3 fix-волны #407): рекурсия зовётся с entry_bad=0 --
    # объявленный код неизмеренной фазы есть 2; иное = красный зуб с печатью
    # полученного кода.
    if code != 2:
        return f"код неизмеренной фазы {code}, ждали 2: {out!r}"
    for name, _fn in _FIXTURE_TEETH:
        if f"ФИКСТУРА {name}: НЕ ИЗМЕРЕНО" not in out:
            return f"зуб {name} не назван в исходе НЕ ИЗМЕРЕНО: {out!r}"
    n_unmeasured = sum(1 for l in out.splitlines()
                       if l.startswith("checks-teeth: ФИКСТУРА ")
                       and ": НЕ ИЗМЕРЕНО -- " in l)
    if n_unmeasured != len(_FIXTURE_TEETH):
        return (f"строк НЕ ИЗМЕРЕНО {n_unmeasured}, ждали РОВНО "
                f"{len(_FIXTURE_TEETH)} (= EXPECTED_FIXTURE_TEETH): {out!r}")
    n_ok = sum(1 for l in out.splitlines()
               if l.startswith("checks-teeth: ФИКСТУРА ") and l.endswith(": OK"))
    if n_ok:
        return f"в неизмеренной фазе есть зелёные строки зубов ({n_ok}): {out!r}"
    if "положительный контроль фикстуры" not in out:
        return f"причина НЕ ИЗМЕРЕНО не названа: {out!r}"
    return None


def _tooth_fixture_control_is_load_bearing(_fixture: Path) -> str | None:
    """Положительный контроль фикстуры -- несущий, не декорация (гейт #407).

    Сборка, отдающая образ БЕЗ целого правила, обязана увести ВСЕ зубы фазы
    в НЕ ИЗМЕРЕНО с названной причиной -- а не зелёный и не «ПРОШЛА МОЛЧА».
    Контроль обязан падать на пристине (правила там нет -- Ф1 #407), а фаза
    с такой «сборкой» -- не мерить. Предмет фикстуры самому зубу не нужен:
    он мерит контроль, а не правило. Рекурсии нет: зуб фазы вызывается
    только после прошедшего контроля, а здесь контроль падает ДО зубов.
    Зуб пинит и КОД рекурсивной фазы, и ПОЛНОТУ множества исходов, и
    перечень имён из _FIXTURE_TEETH (Р3 fix-волны #407) -- проверка вхождения
    четырёх строк пропускала лишний OK и подмену кода молча.
    """
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина для плеча контроля: {PRISTINE_LATEST}"
    try:
        ctrl = _step26_fixture_control(PRISTINE_LATEST)
    except Refusal as exc:
        return f"контроль на пристине отказал прибором: {exc}"
    if ctrl is None:
        return "контроль зелёнет на образе БЕЗ целого правила -- вакуумный"
    code, out = _fixture_recursion_probe(_ModuleHome())
    reason = _fixture_recursion_verdict(code, out)
    if reason:
        return reason
    # Мутационные плечи (Р3 fix-волны #407): каждая приманка обязана менять
    # наблюдаемый исход -- иначе вердикт выше вакуумен.
    unmeasured_tail = ("    if unmeasured:\n"
                       "        print(_fixture_unmeasured_line(why), "
                       "flush=True)\n")
    mut_code0, raw1 = _fx_mutant(((
        unmeasured_tail + "        return _phase_exit(0, entry_bad, 2)\n",
        unmeasured_tail + "        return 0\n",
        "зуб Р3: неизмеренная фаза отвечает нулём"),))
    try:
        mcode, mout = _fixture_recursion_probe(mut_code0)
    finally:
        shutil.rmtree(raw1, ignore_errors=True)
    if _fixture_recursion_verdict(mcode, mout) is None:
        return (f"мутация «код 0» пережила зуб: вердикт зелён при коде "
                f"{mcode}: {mout!r}")
    mut_extrak, raw2 = _fx_mutant(((
        unmeasured_tail,
        '    if unmeasured:\n'
        '        print("checks-teeth: ФИКСТУРА bait-ок: OK", flush=True)\n'
        '        print(_fixture_unmeasured_line(why), flush=True)\n',
        "зуб Р3: лишняя зелёная строка в неизмеренной фазе"),))
    try:
        mcode, mout = _fixture_recursion_probe(mut_extrak)
    finally:
        shutil.rmtree(raw2, ignore_errors=True)
    if _fixture_recursion_verdict(mcode, mout) is None:
        return (f"мутация «лишний OK» пережила зуб: вердикт зелён при коде "
                f"{mcode}: {mout!r}")
    return None


# --- зубы карты шагов (docnum:other -- «шаг -> проверки» есть ИМЯ карты; #403B) -------------------------------------
# Гейт карты обязан отличать отказ СВОЙ (код 3: запись без строки карты) от
# отказа ПРИБОРА (код 2); маркеры ниже -- и «вне области отказа НЕТ».
_STEP_CHECKS_TOOL = ROOT / "tools" / "step-checks.py"
_STEP_CHECKS_MAP = ROOT / "tools" / "our-step-checks.txt"
_STEP_GATE_REFUSAL_MARK = "запись реестра не проведена в карту"
_STEP_GATE_SUMMARY_MARK = "все проведены"
# Объявление литералом имени/проверки шага 26 в конвейере -- возвращение второй
# копии значения (#403B, З5): значение обязано приходить из модуля карты.
_STEP26_DECL_RE = re.compile(r"(?m)^_STEP26_(?:NAME|CHECK)\s*=\s*['\"]")
# Вызывающий блок стенда шага 7: якорь строки вызова и рамки case-блока.
_STEP7_CALLER_ANCHOR = 'bash "$(dirname "$0")/tools/step7-window-teeth.sh" 9>&- || {'
_STEP7_OFF_MSG = ("step7-window-teeth: НЕ ИЗМЕРЕНО -- шаг выключен реестром "
                  "our-steps-off.txt")

# Якорь мутации зуба steps-off-floor-predates: сравнение версий в
# _step26_verdict. Мутация гасит условие -- ветвь predates недостижима, образ
# обязан покраснеть отказом stale.
FLOOR_PREDATES_ANCHOR = (
    "        if img < floor:\n"
    "            return {'status': 'note', 'note_kind': 'predates',\n"
)
FLOOR_PREDATES_REPL = (
    "        if False:\n"
    "            return {'status': 'note', 'note_kind': 'predates',\n"
)

# Двухполевая фикстура реестра: ряд шага 26 без версии-пола, ВТОРОЙ строкой
# файла -- номер строки входит в контракт отказа обоих парсеров.
_TWO_FIELD_REGISTRY = (
    "# fixture: старый двухполевой формат, версия-пол отсутствует\n"
    + _STEP26_ROW + "\tправило несёт мод catalyst-probes\n"
)
_TWO_FIELD_ROW_N = 2

# Реестр из одних комментариев (#403): ноль строк данных -- штатный остаток
# обратного включения удалением строки, все три стороны обязаны считать его
# нормой «выключенных нет».
_COMMENT_ONLY_REGISTRY = (
    "# fixture: обратное включение удалило строку данных\n"
    "\n"
    "# осталась одна шапка -- записей нет\n"
)

# Якорь нулевого исхода компоновки (#403): при нуле записей out НЕ пишется --
# непустой tmp для обвязки означает «подстановка была».
_ZERO_ROWS_ANCHOR = (
    "if not names:\n"
    "    # CONSTRAINT: ноль записей -- норма (обратное включение удаляет строку);\n"
    "    # out НЕ пишется: пустой tmp для обвязки ниже -- сигнал «подстановки нет».\n"
    "    print(f'Реестр выключенных шагов: {registry} не несёт ни одной '\n"
    "          f'выключенной записи -- все шаги включены, раннеру уходит '\n"
    "          f'файл как есть', file=sys.stderr)\n"
    "    sys.exit(0)\n"
)
# М1: возврат отказа прибора на нуле записей.
_ZERO_ROWS_EXIT2_REPL = (
    "if not names:\n"
    "    print(f'ОТКАЗ ПРИБОРА: реестр {registry} не пуст, а записей не найдено', file=sys.stderr)\n"
    "    sys.exit(2)\n"
)
# М3: подстановка пустого списка вместо пропуска -- out пишется и обвязка
# подставляет tmp, хотя менять было нечего.
_ZERO_ROWS_EMPTYSUB_REPL = (
    "if not names:\n"
    "    open(out, 'w', encoding='utf-8').write(\n"
    "        src.replace(ANCHOR, 'const STEPS_OFF = ' + json.dumps(names) + ';'))\n"
    "    sys.exit(0)\n"
)

# М2: снятие проверки трёх полей в модуле steps-off-registry.js.
_MODULE_ARITY_ANCHOR = (
    "    if (parts.length !== 3 || parts.some((part) => !part)) {\n"
)
_MODULE_ARITY_REPL = (
    "    if (false) {\n"
)


def _step26_registry_dispositioned(out: str) -> bool:
    """Вердикт реестра our-steps-off.txt по шагу 26 есть в выводе блока.

    Каждый исход записи несёт СВОЙ текст: NOTE выключения и NOTE провенанса
    (образ старше версии-пола) различаются формулировкой, отказы stale/carrier
    -- именем отказа. Путь БЕЗ реестра (proceed) не печатает ничего про него --
    его проверка выходит голым тегом включённого шага (#373).
    """
    return "шаг выключен" in out or _PREDATES_MARK in out


def _tooth_kit_steps_off_src() -> str | None:
    """Снимок кита несёт реестр выключенных шагов (#373). None -- зуб зелёный.

    _step26_verdict ищет our-steps-off.txt рядом со скриптом; кит без реестра
    читает выключенный шаг как включённый -- его проверка даёт FAIL вместо
    вердикта реестра, и контроль краснит ОБРАЗ ложной причиной. Копирование
    реестра пинится здесь: объявленный комментарием инвариант -- не инвариант.
    """
    src = ROOT / "tools" / "our-steps-off.txt"
    if not src.is_file():
        return "дома tools/our-steps-off.txt нет -- зубу нечего пинить"
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина для семантического плеча зуба: {PRISTINE_LATEST}"
    td, script, patch = _temp_kit()
    try:
        if not (td / "tools" / "our-steps-off.txt").is_file():
            return "снимок кита не несёт tools/our-steps-off.txt"
        r = _run_checks(script, PRISTINE_LATEST, patch)
        out = (r.stdout or "") + (r.stderr or "")
        if not _step26_registry_dispositioned(out):
            return ("реестр в снимке, а вердикта реестра в выводе нет -- "
                    "выключенный шаг читается как включённый")
    finally:
        shutil.rmtree(td, ignore_errors=True)
    own = Path(__file__).read_text(encoding="utf-8")
    mutated = _once_replace(own, KIT_STEPS_OFF_ANCHOR, KIT_STEPS_OFF_REPL,
                            "зуб: копирование реестра в _temp_kit")
    with tempfile.TemporaryDirectory(prefix="checks-teeth-kitso.") as raw:
        mod = Path(raw) / "checks-teeth-mutated.py"
        mod.write_text(mutated, encoding="utf-8")
        spec = importlib.util.spec_from_file_location("checks_teeth_mutated", mod)
        mut = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mut)
        # Копия модуля лежит вне дома: её константы указывают в пустоту.
        # Возвращаем дому ЕДИНЫМ механизмом перепривязки (_rebind_copy_home):
        # предмет мутации -- поведение _temp_kit, а не пути импорта копии.
        _rebind_copy_home(mut)
        mtd, mscript, mpatch = mut._temp_kit()
        try:
            if (mtd / "tools" / "our-steps-off.txt").is_file():
                return "мутация не сняла копирование реестра в снимок"
            mr = mut._run_checks(mscript, PRISTINE_LATEST, mpatch)
            mout = (mr.stdout or "") + (mr.stderr or "")
            if _step26_registry_dispositioned(mout):
                return ("реестра в снимке нет, а вердикт реестра есть -- "
                        "предикат зуба слеп")
        finally:
            shutil.rmtree(mtd, ignore_errors=True)
    return None


def _tooth_steps_off_floor_predates(fixture: Path) -> str | None:
    """Ветвь predates жива на ПОСТРОЕННОМ предмете (#373, #407).

    CONSTRAINT (#407): прежняя посылка «активный образ собран ДО решения
    выключить шаг -- правило в нём целое по праву» мертва: в живом 2.1.278
    правила НЕТ (шаг выключен реестром до сборки, Ф1), и обе ветки пола были
    недостижимы. Предмет СТРОИТСЯ: фикстура «пристин + шаг 26» с полом,
    перестеленным выше версии образа, -- вердикт обязан быть NOTE провенанса,
    а не отказом stale. Мутация гасит сравнение версий -- ветвь недостижима,
    прогон обязан покраснеть; мутация не покраснела -- зуб отдаёт причину.
    """
    mtd, mscript, mpatch = _temp_kit()
    try:
        _kit_registry_refloor(mtd, "2.1.999")
        r = _run_checks(mscript, fixture, mpatch)
        out = (r.stdout or "") + (r.stderr or "")
        if _PREDATES_MARK not in out:
            return f"на фикстуре с перестеленным полом нет NOTE провенанса «{_PREDATES_MARK}»"
        if f"[FAIL] {_STEP26_CHECK}" in out:
            return "NOTE провенанса напечатан ВМЕСТЕ с [FAIL] проверки шага 26"
    finally:
        shutil.rmtree(mtd, ignore_errors=True)
    mtd, mscript, mpatch = _temp_kit(
        script_repl=(FLOOR_PREDATES_ANCHOR, FLOOR_PREDATES_REPL))
    try:
        _kit_registry_refloor(mtd, "2.1.999")
        mr = _run_checks(mscript, fixture, mpatch)
        mout = (mr.stdout or "") + (mr.stderr or "")
        if f"[FAIL] {_STEP26_CHECK}" not in mout:
            return "мутация не сняла сравнение версий: [FAIL] шага 26 не вернулся"
        if _STALE_MARK not in mout:
            return "мутация покраснела, а текст не stale"
    finally:
        shutil.rmtree(mtd, ignore_errors=True)
    return None


def _kit_registry_refloor(td: Path, floor: str) -> None:
    """Переписать версию-пол шага 26 в реестре СНИМКА кита; дом не трогается."""
    p = td / "tools" / "our-steps-off.txt"
    text = p.read_text(encoding="utf-8")
    m = re.search(r"(?m)^" + re.escape(_STEP26_ROW) + r"\t([0-9][0-9.]*)\t", text)
    if not m:
        raise Refusal("строка шага 26 в реестре снимка не несёт версию-пол "
                      "вторым полем")
    p.write_text(text[:m.start(1)] + floor + text[m.end(1):], encoding="utf-8")


def _tooth_steps_off_floor_from_registry(fixture: Path) -> str | None:
    """Версия-пол читается ИЗ РЕЕСТРА, а не зашита литералом в коде (#373, #407).

    Класс «якорь, заморозивший чужое число»: зашитый в коде пол не видел бы
    правки реестра. CONSTRAINT (#407): оба плеча идут на ПОСТРОЕННОЙ фикстуре
    «пристин + шаг 26» -- на живом образе правила нет и плечам нечего мерить
    (Ф1). Низкий пол обязан покраснить прогон (пол больше не оправдывает
    образ), высокий -- вернуть NOTE провенанса; при зашитом поле схожи оба
    плеча -- зуб отдаёт причину, и текст «пол не читается из реестра»
    достижим ТОЛЬКО когда пол действительно не читается.
    """
    home = ROOT / "tools" / "our-steps-off.txt"
    if not re.search(r"(?m)^" + re.escape(_STEP26_ROW) + r"\t[0-9][0-9.]*\t",
                     home.read_text(encoding="utf-8")):
        return "дом реестра не несёт версию-пол вторым полем строки шага 26"
    for floor, want_fail in (("2.1.200", True), ("2.1.999", False)):
        td, script, patch = _temp_kit()
        try:
            _kit_registry_refloor(td, floor)
            r = _run_checks(script, fixture, patch)
            out = (r.stdout or "") + (r.stderr or "")
            failed = f"[FAIL] {_STEP26_CHECK}" in out
            if want_fail:
                if not failed:
                    return (f"пол {floor} в реестре не покраснил прогон -- "
                            f"пол не читается из реестра")
                if _STALE_MARK not in out:
                    return f"пол {floor}: [FAIL] есть, а текст не stale"
            else:
                if failed:
                    return f"пол {floor} в реестре не вернул NOTE провенанса"
                if _PREDATES_MARK not in out:
                    return f"пол {floor}: красного нет, а NOTE провенанса тоже нет"
        finally:
            shutil.rmtree(td, ignore_errors=True)
    return None


def _tooth_steps_off_arity_both_sides() -> str | None:
    """Три разборщика реестра требуют ТРИ поля, и отказы различимы (#373, #403).

    Один и тот же двухполевой реестр обязан отказать ВСЕМ ТРЁМ сторонам --
    проверяющей (блок проверок), компоновке (heredoc STEPSCOMP, исполняемый
    напрямую по его якорю) и модулю tools/steps-off-registry.js (его CLI) --
    с номером строки и именем СВОЕЙ стороны; совпавшие дословно отказы
    неразличимы -- это находка зуба.
    """
    if not PRISTINE_LATEST.is_file():
        # CONSTRAINT: модульное плечо идёт РАНЬШЕ пристин-гейта -- оно не
        # читает образ, и машина без пристина не имеет права пропускать его.
        mod_src = ROOT / "tools" / "steps-off-registry.js"
        if not mod_src.is_file():
            return f"нет модуля реестра -- третьей стороне нечего мерить: {mod_src}"
        td, script, patch = _temp_kit()
        try:
            reg = td / "tools" / "our-steps-off.txt"
            reg.write_text(_TWO_FIELD_REGISTRY, encoding="utf-8")
            reason, _mod_line = _module_arity_leg(mod_src, reg)
            if reason:
                return reason
        finally:
            shutil.rmtree(td, ignore_errors=True)
        return f"нет пристина для плеча проверяющей стороны: {PRISTINE_LATEST}"
    td, script, patch = _temp_kit()
    try:
        reg = td / "tools" / "our-steps-off.txt"
        reg.write_text(_TWO_FIELD_REGISTRY, encoding="utf-8")
        reason, mod_line = _module_arity_leg(ROOT / "tools" / "steps-off-registry.js", reg)
        if reason:
            return reason
        r = _run_checks(script, PRISTINE_LATEST, patch)
        combined = (r.stdout or "") + (r.stderr or "")
        if r.returncode == 0:
            return "проверяющая сторона приняла двухполевой реестр"
        ref_line = next((l for l in combined.splitlines()
                         if "неразобранная строка" in l), "")
        if f"строка {_TWO_FIELD_ROW_N}" not in ref_line:
            return f"отказ проверяющей стороны не назвал номер строки: {ref_line!r}"
        if "проверяющая сторона" not in ref_line:
            return f"отказ проверяющей стороны не назвал свою сторону: {ref_line!r}"
        if "три поля" not in ref_line:
            return f"отказ проверяющей стороны не требует три поля: {ref_line!r}"
        lines = script.read_text(encoding="utf-8").split("\n")
        marker = 'python3 - "$OUR_PATCH" "$STEPS_OFF_SRC" "$STEPS_OFF_TMP" <<'
        start = next((i for i, l in enumerate(lines)
                      if l.lstrip().startswith(marker)), -1)
        if start < 0:
            return "блок компоновки STEPSCOMP не найден в claude-patch-all.sh"
        end = next((i for i in range(start + 1, len(lines))
                    if lines[i] == "STEPSCOMP"), -1)
        if end < 0:
            return "блок компоновки STEPSCOMP не закрыт"
        comp_src = td / "stepscomp-extracted.py"
        comp_src.write_text("\n".join(lines[start + 1:end]), encoding="utf-8")
        c = subprocess.run(
            [sys.executable, str(comp_src), str(patch), str(reg), str(td / "out.js")],
            capture_output=True, text=True, errors="replace")
        ccombined = (c.stdout or "") + (c.stderr or "")
        if c.returncode == 0:
            return "компоновка приняла двухполевой реестр"
        comp_line = next((l for l in ccombined.splitlines()
                          if "неразобранная строка" in l), "")
        if f"строка {_TWO_FIELD_ROW_N}" not in comp_line:
            return f"отказ компоновки не назвал номер строки: {comp_line!r}"
        if "сторона компоновки" not in comp_line:
            return f"отказ компоновки не назвал свою сторону: {comp_line!r}"
        if "три поля" not in comp_line:
            return f"отказ компоновки не требует три поля: {comp_line!r}"
        if comp_line == ref_line:
            return "отказы двух сторон совпали дословно -- стороны неразличимы"
        if mod_line in (ref_line, comp_line):
            return "отказ модуля совпал дословно с другой стороной -- стороны неразличимы"
    finally:
        shutil.rmtree(td, ignore_errors=True)
    return None


def _module_arity_leg(mod_src: Path, reg: Path) -> tuple[str | None, str]:
    """Сторона модуля на двухполевом реестре + её мутация М2.

    Возвращает (причину или None, строку отказа модуля) -- сравнение с
    отказами других сторон держит сам зуб: у него все три строки.
    """
    m = subprocess.run(["node", str(mod_src), str(reg)],
                       capture_output=True, text=True, errors="replace")
    mcomb = (m.stdout or "") + (m.stderr or "")
    if m.returncode == 0:
        return "модуль принял двухполевой реестр", ""
    mod_line = next((l for l in mcomb.splitlines()
                     if "неразобранная строка" in l), "")
    if f"строка {_TWO_FIELD_ROW_N}" not in mod_line:
        return f"отказ модуля не назвал номер строки: {mod_line!r}", mod_line
    if "модуль" not in mod_line:
        return f"отказ модуля не назвал свою сторону: {mod_line!r}", mod_line
    if "три поля" not in mod_line:
        return f"отказ модуля не требует три поля: {mod_line!r}", mod_line
    with tempfile.TemporaryDirectory(prefix="checks-teeth-so-mod.") as raw:
        mut = Path(raw) / "steps-off-registry.js"
        mut.write_text(_once_replace(mod_src.read_text(encoding="utf-8"),
                                     _MODULE_ARITY_ANCHOR, _MODULE_ARITY_REPL,
                                     "модуль"), encoding="utf-8")
        mm = subprocess.run(["node", str(mut), str(reg)],
                            capture_output=True, text=True, errors="replace")
        if mm.returncode != 0:
            # Мутант, всё ещё отказывающий, не ломает плечо -- зуб на нём
            # остался бы зелёным, и проверка трёх полей не доказана.
            return ("мутация не сняла проверку трёх полей: мутант всё ещё "
                    "отказывает"), mod_line
    return None, mod_line


def _stepscomp_cut(script: Path, dst: Path) -> str | None:
    """Вырезать heredoc STEPSCOMP из скрипта в dst; причина -- если не вышло."""
    lines = script.read_text(encoding="utf-8").split("\n")
    marker = 'python3 - "$OUR_PATCH" "$STEPS_OFF_SRC" "$STEPS_OFF_TMP" <<'
    start = next((i for i, l in enumerate(lines)
                  if l.lstrip().startswith(marker)), -1)
    if start < 0:
        return "блок компоновки STEPSCOMP не найден в claude-patch-all.sh"
    end = next((i for i in range(start + 1, len(lines))
                if lines[i] == "STEPSCOMP"), -1)
    if end < 0:
        return "блок компоновки STEPSCOMP не закрыт"
    dst.write_text("\n".join(lines[start + 1:end]), encoding="utf-8")
    return None


def _compose_guard_run(script: Path, td: Path, patch: Path):
    """Исполнить вырезанную обвязку компоновки (без стадии tweakcc).

    Фрагмент -- от объявления STEPS_OFF_SRC до закрывающего fi: с HERE и
    OUR_PATCH, указанными через окружение. Возвращает (rc, stdout, stderr).
    """
    lines = script.read_text(encoding="utf-8").split("\n")
    start = next((i for i, l in enumerate(lines)
                  if l.startswith('STEPS_OFF_SRC="$HERE')), -1)
    if start < 0:
        return None, "", "обвязка компоновки не найдена в claude-patch-all.sh"
    end = next((i for i in range(start + 1, len(lines))
                if lines[i] == "STEPSCOMP"), -1)
    if end < 0:
        return None, "", "блок компоновки STEPSCOMP не закрыт"
    close = next((i for i in range(end + 1, len(lines))
                  if lines[i] == "fi"), -1)
    if close < 0:
        return None, "", "обвязка компоновки не закрыта (нет fi)"
    frag = "set -e;\n" + "\n".join(lines[start:close + 1]) + '\nprintf \'%s\\n\' "$OUR_PATCH_RUN"\n'
    r = subprocess.run(["bash", "-c", frag], capture_output=True, text=True,
                       errors="replace",
                       env={**os.environ, "HERE": str(td), "OUR_PATCH": str(patch)})
    return r.returncode, r.stdout or "", r.stderr or ""


def _tooth_steps_off_zero_rows_all_sides() -> str | None:
    """Ноль записей реестра -- норма всех ТРЁХ сторон, а не отказ (#403).

    Реестр из одних комментариев -- штатный остаток обратного включения
    удалением строки: компоновка обязана ответить кодом 0, назвав исход, и НЕ
    писать выходной файл (раннеру уходит $OUR_PATCH -- подстановки нет);
    проверяющая сторона и модуль дают ноль записей без отказа. Обвязка при
    записи в реестре подстановку ВОЗВРАЩАЕТ -- guard не имеет права стать
    вечным пропуском. Мутации: возврат sys.exit(2) на нуле (М1) и подстановка docnum:other
    пустого списка вместо пропуска (М3).
    """
    mod_src = ROOT / "tools" / "steps-off-registry.js"
    if not mod_src.is_file():
        return f"нет модуля реестра -- стороне модуля нечего мерить: {mod_src}"
    image = default_image()
    if image is None or not image.is_file():
        return "нет активного образа -- проверяющей стороне нечего мерить"
    td, script, patch = _temp_kit()
    try:
        reg = td / "tools" / "our-steps-off.txt"
        reg.write_text(_COMMENT_ONLY_REGISTRY, encoding="utf-8")
        r = _run_checks(script, image, patch)
        combined = (r.stdout or "") + (r.stderr or "")
        if "ОТКАЗ ПРИБОРА" in combined:
            return "проверяющая сторона отказала на реестре из одних комментариев"
        if _step26_registry_dispositioned(combined):
            return ("проверяющая сторона дала вердикт реестра при нуле записей -- "
                    "для неё реестра нет")
        if not _parse_registry(combined):
            return "проверяющая сторона не дошла до реестра проверок -- нечего сравнивать"
        m = subprocess.run(["node", str(mod_src), str(reg)],
                           capture_output=True, text=True, errors="replace")
        mout = (m.stdout or "") + (m.stderr or "")
        if m.returncode != 0 or "записей: 0" not in (m.stdout or ""):
            return f"модуль не дал ноль записей без отказа: rc={m.returncode} {mout!r}"
        reason = _zero_rows_comp_leg(td, script, patch, reg)
        if reason:
            return reason
        rc, gout, gerr = _compose_guard_run(script, td, patch)
        if rc != 0:
            return f"обвязка компоновки упала на нуле записей: rc={rc} {gout + gerr!r}"
        if gout.strip() != str(patch):
            return (f"обвязка подставила tmp при нуле записей -- раннеру ушёл не "
                    f"$OUR_PATCH: {gout.strip()!r}")
    finally:
        shutil.rmtree(td, ignore_errors=True)
    home_reg = ROOT / "tools" / "our-steps-off.txt"
    if not re.search(r"(?m)^" + re.escape(_STEP26_ROW) + r"\t",
                     home_reg.read_text(encoding="utf-8")):
        return "дом реестра не несёт строку данных -- контролю подстановки нечего мерить"
    td, script, patch = _temp_kit()
    try:
        rc, gout, gerr = _compose_guard_run(script, td, patch)
        if rc != 0:
            return f"обвязка компоновки упала на реестре с записью: rc={rc} {gout + gerr!r}"
        if gout.strip() == str(patch):
            return ("обвязка не подставила tmp при живой записи -- guard стал "
                    "вечным пропуском подстановки")
    finally:
        shutil.rmtree(td, ignore_errors=True)
    for name, repl in (("М1", _ZERO_ROWS_EXIT2_REPL), ("М3", _ZERO_ROWS_EMPTYSUB_REPL)):
        td, script, patch = _temp_kit(
            script_repl=(_ZERO_ROWS_ANCHOR, repl))
        try:
            reg = td / "tools" / "our-steps-off.txt"
            reg.write_text(_COMMENT_ONLY_REGISTRY, encoding="utf-8")
            reason = _zero_rows_comp_leg(td, script, patch, reg)
            if reason is None:
                return f"мутация {name} не покраснела стороной компоновки"
            rc, gout, gerr = _compose_guard_run(script, td, patch)
            if name == "М1" and rc == 0 and "ОТКАЗ ПРИБОРА" not in gout + gerr:
                return f"мутация {name} не остановила обвязку"
            if name == "М3" and rc == 0 and gout.strip() == str(patch):
                return f"мутация {name} не прошла подстановку в обвязку"
        finally:
            shutil.rmtree(td, ignore_errors=True)
    return None


def _zero_rows_comp_leg(td: Path, script: Path, patch: Path, reg: Path) -> str | None:
    """Сторона компоновки на реестре из одних комментариев; None -- зелёное."""
    comp_src = td / "stepscomp-zero.py"
    reason = _stepscomp_cut(script, comp_src)
    if reason:
        return reason
    out_path = td / "out-zero.js"
    c = subprocess.run([sys.executable, str(comp_src), str(patch), str(reg),
                        str(out_path)], capture_output=True, text=True,
                       errors="replace")
    combined = (c.stdout or "") + (c.stderr or "")
    if out_path.exists():
        return ("компоновка написала выходной файл при нуле записей -- подстановка "
                "пустого списка вместо пропуска")
    if c.returncode != 0:
        return f"компоновка отказала на нуле записей: rc={c.returncode} {combined!r}"
    if "все шаги включены" not in combined:
        return f"компоновка не назвала исход нуля записей: {combined!r}"
    return None


# --- зубы объявленного отсутствия носителя (#389) ---------------------------
#
# Фикстуры плеча: ручки носителя читаются из КОНТРОЛИРУЕМОГО CLAUDE_CONFIG_DIR
# (пустой каталог -- не закреплена ни одна; settings.json с env-картой --
# носитель работает), поэтому unmet определён конфигурацией зуба, а не живым
# домом юзера. Предмет всех плеч -- исход шага 26 на пристине 2.1.278,
# где прочие проверки красны ПО ПОСТРОЕНИЮ (патчей в пристине нет)
# (docnum:other -- 26 есть номер ШАГА, 2.1.278 -- версия образа).
_CARRIER_FAIL_MARK = "НОСИТЕЛЬ ОТСУТСТВУЕТ (carrier)"
_CARRIER_ABSENT_MARK = "без носителя судьи"
_NOTE_OFF_MARK = "шаг выключен реестром our-steps-off.txt"
_CARRIER_UNMET_HANDLES = ("CLAUDE_CODE_ENABLE_FUNCTION_HOOKS",
                          "CLAUDE_JUDGE_CARRIER", "CLAUDE_JUDGE")
_CARRIER_FIXTURE_BASIS = "#236-фикстура: носителей моделей на площадке нет по построению, судить некому"


@contextlib.contextmanager
def _carrier_pins(pins: dict[str, str]):
    """CLAUDE_CONFIG_DIR на время прогона: ручки носителя -- из контролируемого дома.

    Восстановление обязательно: соседние зуби и якорь 2.1.278 читают живой дом.
    """
    saved = os.environ.get("CLAUDE_CONFIG_DIR")
    with tempfile.TemporaryDirectory(prefix="checks-teeth-carriercfg.") as td:
        if pins:
            (Path(td) / "settings.json").write_text(
                json.dumps({"env": pins}), encoding="utf-8")
        os.environ["CLAUDE_CONFIG_DIR"] = td
        try:
            yield
        finally:
            if saved is None:
                os.environ.pop("CLAUDE_CONFIG_DIR", None)
            else:
                os.environ["CLAUDE_CONFIG_DIR"] = saved


def _carrier_registry_text(site: str, handles: list[str]) -> str:
    """Фикстура дома объявлений: записи ТОЛЬКО названных ручек площадки."""
    return ("# fixture: our-carrier-absent.txt (#389)\n"
            + "".join(f"{site}\t{h}\t{_CARRIER_FIXTURE_BASIS}\n" for h in handles))


def _step26_note_line(out: str) -> str:
    """Строка NOTE шага 26 целиком: субъект различимости текстов исходов."""
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("[NOTE] ") and _STEP26_CHECK in s:
            return s
    return ""


# Якорь мутации зуба carrier-absent-declared-note: чтение дома объявлений в
# гейте. Мутация подменяет чтение пустым словарём -- реестр не читается вовсе.
GATE_READ_ANCHOR = (
    "    for (row_site, handle), (_n, basis) in _read_carrier_absent(path).items():\n"
)
GATE_READ_REPL = (
    "    for (row_site, handle), (_n, basis) in {}.items():\n"
)

# Якорь мутации зуба carrier-absent-partial-stays-red: гашение расширяется до
# «любая объявленная ручка гасит всё» -- частичное объявление перестаёт
# оставлять необъявленные ручки в отказе.
GATE_ANY_ANCHOR = "    if unmet and not undeclared:\n"
GATE_ANY_REPL = "    if unmet and declared:\n"

# Якорь мутации зуба carrier-absent-foreign-site: поле площадки игнорируется.
GATE_SITE_ANCHOR = "        if row_site == site:\n"
GATE_SITE_REPL = "        if True:\n"

# Якорь мутации зуба carrier-absent-parse-refuses: ветвь отказа неразобранной
# строки глотает её молчаливым пропуском.
CARRIER_PARSE_ANCHOR = (
    "            if len(parts) != 3 or not all(parts):\n"
    "                print(f'ОТКАЗ ПРИБОРА: неразобранная строка {n} в реестре '\n"
    "                      f'our-carrier-absent.txt: {path}', file=sys.stderr)\n"
    "                sys.exit(2)\n"
)
CARRIER_PARSE_REPL = (
    "            if len(parts) != 3 or not all(parts):\n"
    "                continue\n"
)

# Якорь мутации зуба carrier-absent-missing-file-is-norm: гейт возвращает
# безусловный NOTE -- отсутствие файла больше не держит отказ carrier.
GATE_UNCONDITIONAL_ANCHOR = (
    "    note, undeclared = _carrier_absent_gate(\n"
    "        os.path.join(os.path.dirname(os.path.abspath(sys.argv[2])),\n"
    "                     'tools', 'our-carrier-absent.txt'), unmet)\n"
)
GATE_UNCONDITIONAL_REPL = (
    "    note, undeclared = {'status': 'note', 'note_kind': 'carrier-absent',\n"
    "                        'site': '', 'handles': [], 'reasons': []}, []\n"
)

# Якорь мутации зуба carrier-absent-texts-distinct: формат NOTE объявленного
# отсутствия сводится к формату NOTE выключения -- два исхода одной строкой.
CARRIER_FMT_ANCHOR = (
    '_NOTE_OFF_CARRIER_FMT = ("  [NOTE] {name}: площадка {site} без носителя судьи "\n'
    '                         "(объявлено our-carrier-absent.txt): ручки {handles}: "\n'
    '                         "{reasons}")\n'
)
CARRIER_FMT_REPL = (
    '_NOTE_OFF_CARRIER_FMT = ("  [NOTE] {name}: шаг выключен реестром "\n'
    '                         "our-steps-off.txt: {reasons}")\n'
)


def _tooth_carrier_absent_declared_note() -> str | None:
    """Объявленная площадка + ровно объявленные ручки -> NOTE шестого исхода (#389).

    Мутация снимает чтение дома объявлений -- NOTE обязан смениться отказом
    carrier с теми же ручками. Предмет -- исход шага 26: прочие проверки на
    пристине красны по построению (патчей там нет).
    """
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина 2.1.278: {PRISTINE_LATEST}"
    site = _kit_carrier_site()
    text = _carrier_registry_text(site, list(_CARRIER_UNMET_HANDLES))
    with _carrier_pins({}):
        td, script, patch = _temp_kit(carrier_text=text)
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if f"[FAIL] {_STEP26_CHECK}" in out:
                return "контроль: объявленная конфигурация покраснела шагом 26"
            if _CARRIER_FAIL_MARK in out:
                return "контроль: NOTE напечатан ВМЕСТЕ с отказом carrier"
            if _CARRIER_ABSENT_MARK not in out:
                return "контроль: NOTE объявленного отсутствия не напечатан"
        finally:
            shutil.rmtree(td, ignore_errors=True)
        td, script, patch = _temp_kit(
            carrier_text=text, script_repl=(GATE_READ_ANCHOR, GATE_READ_REPL))
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if _CARRIER_ABSENT_MARK in out:
                return "мутация сняла чтение реестра, а NOTE остался"
            if _CARRIER_FAIL_MARK not in out or f"[FAIL] {_STEP26_CHECK}" not in out:
                return "мутация сняла чтение реестра, а отказ carrier не вернулся"
        finally:
            shutil.rmtree(td, ignore_errors=True)
    return None


# CONSTRAINT полярности мутационной фазы зубов ниже: None возвращается ТОГДА
# И ТОЛЬКО ТОГДА, когда мутация произвела предсказанный ею эффект; строка --
# когда эффекта нет, то есть мутация прошла молча. Обратный порядок делает
# зуб зелёным на невредимой двери и красным на сломанной. Эталон --
# _tooth_carrier_absent_declared_note.
def _tooth_carrier_absent_partial_stays_red() -> str | None:
    """Вне области отказа НЕТ: объявлена одна ручка, не сошлись две (#389).

    Объявлены только CLAUDE_JUDGE_CARRIER и CLAUDE_JUDGE; HOOKS не закреплена
    и НЕ объявлена -- отказ carrier обязан остаться, текст называет именно
    необъявленную ручку, объявленные из текста погашены. Мутация расширяет
    гашение до «любая объявленная ручка гасит всё» -- частичное объявление
    уносит отказ в NOTE, зуб краснеет.
    """
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина 2.1.278: {PRISTINE_LATEST}"
    site = _kit_carrier_site()
    text = _carrier_registry_text(site, ["CLAUDE_JUDGE_CARRIER", "CLAUDE_JUDGE"])
    with _carrier_pins({}):
        td, script, patch = _temp_kit(carrier_text=text)
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if f"[FAIL] {_STEP26_CHECK}" not in out or _CARRIER_FAIL_MARK not in out:
                return "контроль: частичное объявление не оставило отказ carrier"
            if "не сошлось: CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=" not in out:
                return "контроль: текст отказа не назвал НЕОБЪЯВЛЕННУЮ ручку"
            for h in ("CLAUDE_JUDGE_CARRIER", "CLAUDE_JUDGE"):
                if f"не сошлось: {h}=" in out:
                    return f"контроль: текст отказа назвал ОБЪЯВЛЕННУЮ ручку {h}"
        finally:
            shutil.rmtree(td, ignore_errors=True)
        td, script, patch = _temp_kit(
            carrier_text=text, script_repl=(GATE_ANY_ANCHOR, GATE_ANY_REPL))
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if _CARRIER_FAIL_MARK in out or f"[FAIL] {_STEP26_CHECK}" in out:
                return "мутация «любая объявленная гасит всё» НЕ унесла отказ при частичном объявлении"
            return None
        finally:
            shutil.rmtree(td, ignore_errors=True)
    return None


def _tooth_carrier_absent_foreign_site() -> str | None:
    """Чужая площадка: записи есть, но на ДРУГОЙ хост -- отказ как прежде (#389).

    Мутация игнорирует поле площадки -- чужие записи применяются к этой
    машине и уносят отказ, зуб краснеет.
    """
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина 2.1.278: {PRISTINE_LATEST}"
    text = _carrier_registry_text("чужая-площадка-389", list(_CARRIER_UNMET_HANDLES))
    with _carrier_pins({}):
        td, script, patch = _temp_kit(carrier_text=text)
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if _CARRIER_FAIL_MARK not in out or f"[FAIL] {_STEP26_CHECK}" not in out:
                return "контроль: чужая площадка не дала отказа carrier"
            for h in _CARRIER_UNMET_HANDLES:
                if f"не сошлось: {h}=" not in out:
                    return f"контроль: чужая запись погасила ручку {h}"
        finally:
            shutil.rmtree(td, ignore_errors=True)
        td, script, patch = _temp_kit(
            carrier_text=text, script_repl=(GATE_SITE_ANCHOR, GATE_SITE_REPL))
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if _CARRIER_FAIL_MARK in out or f"[FAIL] {_STEP26_CHECK}" in out:
                return "мутация, игнорирующая поле площадки, НЕ унесла отказ"
            return None
        finally:
            shutil.rmtree(td, ignore_errors=True)
    return None


def _tooth_carrier_absent_parse_refuses() -> str | None:
    """Разбор дома объявлений: неразобранная строка и дубль -- ОТКАЗ с номером (#389).

    Мутация глотает неразобранную строку молчаливым пропуском -- отказ
    прибора исчезает, зуб краснеет.
    """
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина 2.1.278: {PRISTINE_LATEST}"
    with _carrier_pins({}):
        site = _kit_carrier_site()
        two_field = f"# fixture (#389)\n{site}\tCLAUDE_JUDGE\n"
        dup = (f"# fixture (#389)\n{site}\tCLAUDE_JUDGE\tосн-1\n"
               f"{site}\tCLAUDE_JUDGE\tосн-2\n")
        for label, text, marks in (
            ("двухполосная", two_field, ("неразобранная строка 2",)),
            ("дубль ключа", dup, ("две строки на пару", "(строки 2 и 3)")),
        ):
            td, script, patch = _temp_kit(carrier_text=text)
            try:
                r = _run_checks(script, PRISTINE_LATEST, patch)
                out = (r.stdout or "") + (r.stderr or "")
                if r.returncode != 2:
                    return f"контроль: {label} не отказала прибором (rc={r.returncode})"
                missing = [m for m in marks if m not in out]
                if missing:
                    return f"контроль: отказ {label} не назвал {missing}"
            finally:
                shutil.rmtree(td, ignore_errors=True)
        td, script, patch = _temp_kit(
            carrier_text=two_field, script_repl=(CARRIER_PARSE_ANCHOR, CARRIER_PARSE_REPL))
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if r.returncode == 2:
                if "неразобранная строка 2" in out:
                    return "мутация не погасила отказ неразобранной строки"
                return f"мутация отказала прибором чужим текстом: {out[-300:]!r}"
            return None
        finally:
            shutil.rmtree(td, ignore_errors=True)


def _tooth_carrier_absent_missing_file_is_norm() -> str | None:
    """Отсутствующий/пустой дом объявлений -- НОРМА: отказ carrier прежний (#389).

    Мутация возвращает из гейта безусловный NOTE -- отсутствие файла
    превращается в тихий NOTE, зуб краснеет.
    """
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина 2.1.278: {PRISTINE_LATEST}"
    with _carrier_pins({}):
        for label, drop in (("отсутствующий", True), ("пустой", False)):
            td, script, patch = _temp_kit()
            try:
                reg = td / "tools" / "our-carrier-absent.txt"
                if drop:
                    reg.unlink(missing_ok=True)
                else:
                    reg.write_text("", encoding="utf-8")
                r = _run_checks(script, PRISTINE_LATEST, patch)
                out = (r.stdout or "") + (r.stderr or "")
                if _CARRIER_ABSENT_MARK in out:
                    return f"контроль: {label} файл дал NOTE без объявления"
                if _CARRIER_FAIL_MARK not in out or f"[FAIL] {_STEP26_CHECK}" not in out:
                    return f"контроль: {label} файл унёс отказ carrier"
            finally:
                shutil.rmtree(td, ignore_errors=True)
        td, script, patch = _temp_kit(
            script_repl=(GATE_UNCONDITIONAL_ANCHOR, GATE_UNCONDITIONAL_REPL))
        try:
            (td / "tools" / "our-carrier-absent.txt").unlink(missing_ok=True)
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if _CARRIER_FAIL_MARK in out or f"[FAIL] {_STEP26_CHECK}" in out:
                return "мутация НЕ превратила отсутствие файла в тихий NOTE"
            return None
        finally:
            shutil.rmtree(td, ignore_errors=True)
    return None


def _tooth_carrier_absent_texts_distinct(fixture: Path) -> str | None:
    """Тексты трёх NOTE и отказа carrier -- РАЗЛИЧНЫ (#389, #407).

    Прогоны: выключение -- носитель работает в контролируемом доме;
    провенанс -- ПОСТРОЕННАЯ фикстура «пристин + шаг 26» с перестеленным
    полем (живой образ правила не несёт -- Ф1 #407); объявленное отсутствие
    -- пристин с полным объявлением. Мутация сводит формат нового NOTE к
    формату NOTE выключения -- исходы одной строкой, зуб краснеет.
    """
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина 2.1.278: {PRISTINE_LATEST}"
    site = _kit_carrier_site()
    with _carrier_pins({"CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1",
                        "CLAUDE_JUDGE_CARRIER": "mod", "CLAUDE_JUDGE": "1"}):
        td, script, patch = _temp_kit()
        try:
            ra = _run_checks(script, PRISTINE_LATEST, patch)
        finally:
            shutil.rmtree(td, ignore_errors=True)
    note_off = _step26_note_line(ra.stdout or "")
    text = _carrier_registry_text(site, list(_CARRIER_UNMET_HANDLES))
    with _carrier_pins({}):
        td, script, patch = _temp_kit(carrier_text=text)
        try:
            rb = _run_checks(script, PRISTINE_LATEST, patch)
        finally:
            shutil.rmtree(td, ignore_errors=True)
        td, script, patch = _temp_kit(
            carrier_text=text, script_repl=(CARRIER_FMT_ANCHOR, CARRIER_FMT_REPL))
        try:
            rm = _run_checks(script, PRISTINE_LATEST, patch)
        finally:
            shutil.rmtree(td, ignore_errors=True)
    note_absent = _step26_note_line(rb.stdout or "")
    note_mut = _step26_note_line(rm.stdout or "")
    td, script, patch = _temp_kit()
    try:
        _kit_registry_refloor(td, "2.1.999")
        rc_ = _run_checks(script, fixture, patch)
    finally:
        shutil.rmtree(td, ignore_errors=True)
    note_predates = _step26_note_line(rc_.stdout or "")
    if not note_off or not note_absent or not note_predates:
        return (f"контроль: какой-то NOTE не напечатан: off={note_off!r} "
                f"absent={note_absent!r} predates={note_predates!r}")
    if len({note_off, note_absent, note_predates}) != 3:
        return "контроль: два NOTE-исхода печатаются одной строкой"
    if _NOTE_OFF_MARK not in note_off:
        return "контроль: NOTE выключения без своего маркера"
    if _PREDATES_MARK not in note_predates:
        return "контроль: NOTE провенанса без своего маркера"
    if (_CARRIER_ABSENT_MARK not in note_absent
            or "our-carrier-absent.txt" not in note_absent):
        return "контроль: NOTE объявленного отсутствия без своего маркера"
    for label, note in (("off", note_off), ("predates", note_predates),
                        ("absent", note_absent)):
        if _CARRIER_FAIL_MARK in note:
            return f"контроль: NOTE {label} несёт текст отказа carrier"
    if _NOTE_OFF_MARK in note_mut:
        return None
    if _CARRIER_ABSENT_MARK in note_mut:
        return "мутация НЕ свела NOTE объявленного отсутствия к тексту NOTE выключения"
    return f"мутация не напечатала NOTE шага 26: {note_mut!r}"


# Подмена контроля фазы на управляемый исход -- фикстура зубов, мерящих цикл
# фазы без построения предмета (собирается конкатенацией: цельный литерал
# якоря в теле зуба дал бы второе вхождение при замене).
_FX_CTRL_NONE_PAIR = (
    "            ctrl = _step26_fixture_" + "control(fixture)\n",
    "            ctrl = None  # зуб фазы: управляемый исход контроля\n",
    "зуб фазы: контроль отключён")


def _fx_mutant_src(src: str):
    """Исполнить готовый текст копии прибора; (модуль, каталог копии)."""
    raw = Path(tempfile.mkdtemp(prefix="checks-teeth-fxmut."))
    mod = raw / "checks-teeth-mutated.py"
    mod.write_text(src, encoding="utf-8")
    spec = importlib.util.spec_from_file_location("checks_teeth_fx_mutant", mod)
    mut = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mut)
    _rebind_copy_home(mut)
    return mut, raw


def _fx_bait_teeth(src: str, bait_item: str) -> str:
    """Заменить блок _FIXTURE_TEETH на bait-набор ТОЙ ЖЕ ДЛИНЫ (Р8/Р12).

    Длина -- часть пина фазы: кортеж иного размера ронял бы фазу на проверке
    EXPECTED_FIXTURE_TEETH ДО цикла, и зуб не мерил бы свой путь.
    """
    m = re.search(r"(?ms)^_FIXTURE_TEETH: tuple = \(\n.*?^\)\n", src)
    if not m:
        raise Refusal("блок _FIXTURE_TEETH не найден в собственном тексте")
    n = len(re.findall(r"(?m)^    \(", m.group(0)))
    if n != EXPECTED_FIXTURE_TEETH:
        raise Refusal(f"блок _FIXTURE_TEETH несёт {n} зубов, объявлено "
                      f"{EXPECTED_FIXTURE_TEETH}")
    block = ("_FIXTURE_TEETH: tuple = (\n"
             + "".join('    ("bait-fx-%d", %s),\n' % (i, bait_item)
                       for i in range(n))
             + ")\n")
    return src.replace(m.group(0), block, 1)


def _probe_fixture_builder(rc: int, marker: str, mod=None) -> tuple[int, str]:
    """Фаза фикстуры на строителе-заглушке с названным кодом; (код, вывод).

    Заглушка печатает СВОЮ причину в stderr и выходит названным кодом:
    потребитель обязан различать код 3 (инструментария нет) и любой иной
    (отказ построения) текстом и кодом (Р6 fix-волны #407).
    """
    own = _ModuleHome(mod)
    stub_dir = tempfile.mkdtemp(prefix="checks-teeth-fxbuild.")
    stub = Path(stub_dir) / "fixture-build.sh"
    stub.write_text("#!/usr/bin/env bash\n"
                    "echo 'fixture-build: %s' >&2\n"
                    "exit %d\n" % (marker, rc), encoding="utf-8")
    saved_builder = own.FIXTURE_BUILDER
    saved_state = dict(own._FIXTURE_STATE)
    own.FIXTURE_BUILDER = stub
    own._FIXTURE_STATE.clear()
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            code = own._fixture_phase(0)
        return code, buf.getvalue()
    finally:
        own.FIXTURE_BUILDER = saved_builder
        own._FIXTURE_STATE.clear()
        own._FIXTURE_STATE.update(saved_state)
        shutil.rmtree(stub_dir, ignore_errors=True)


def _tooth_fixture_cleanup_on_exception(_fixture: Path) -> str | None:
    """Уборка фазы живёт в finally: исключение не уносит каталог (Р2 #407).

    Уборка после цикла ловила только штатный выход; OSError/RuntimeError/
    KeyboardInterrupt уносили каталог копии образа (сотни мегабайт).
    Управляемые исходы зуба: контроль погашен, первый зуб фазы падает
    исключением. Приманка возвращает уборку из finally -- каталог обязан
    пережить исключение, и зуб это ловит.
    """
    raiser = ("            try:\n"
              "                reason = fn(fixture)\n",
              "            try:\n"
              "                raise RuntimeError(\"мутация Р2: зуб фазы упал "
              "исключением\")\n"
              "                reason = fn(fixture)\n",
              "зуб Р2: зуб фазы падает исключением")
    marker = Path(tempfile.mkdtemp(prefix="checks-teeth-fx2a."))
    try:
        (marker / "fixture").write_bytes(b"x")
        mut, raw = _fx_mutant((_FX_CTRL_NONE_PAIR, raiser))
        try:
            mut._FIXTURE_STATE.clear()
            mut._FIXTURE_STATE["dir"] = marker
            mut._FIXTURE_STATE["path"] = marker / "fixture"
            try:
                mut._fixture_phase(0)
            except RuntimeError:
                pass
            else:
                return "подмена не подняла исключение в фазе -- зуб не мерил свой путь"
            if marker.exists():
                return "каталог фикстуры пережил исключение фазы -- уборка не в finally"
        finally:
            shutil.rmtree(raw, ignore_errors=True)
    finally:
        shutil.rmtree(marker, ignore_errors=True)
    bait = ("        _fixture_" + "cleanup()\n",
            "        pass  # мутация Р2: уборка выведена из finally\n",
            "зуб Р2: уборка после цикла")
    marker2 = Path(tempfile.mkdtemp(prefix="checks-teeth-fx2a."))
    try:
        (marker2 / "fixture").write_bytes(b"x")
        mut, raw = _fx_mutant((_FX_CTRL_NONE_PAIR, raiser, bait))
        try:
            mut._FIXTURE_STATE.clear()
            mut._FIXTURE_STATE["dir"] = marker2
            mut._FIXTURE_STATE["path"] = marker2 / "fixture"
            try:
                mut._fixture_phase(0)
            except RuntimeError:
                pass
            else:
                return "приманка не подняла исключение -- плечо мертво"
            if not marker2.exists():
                return ("мутация пережила зуб: уборка вне finally не оставила "
                        "каталога -- якорь приманки устарел")
        finally:
            shutil.rmtree(raw, ignore_errors=True)
    finally:
        shutil.rmtree(marker2, ignore_errors=True)
    return None


def _tooth_fixture_dir_weed_by_age(_fixture: Path) -> str | None:
    """Прополка знает каталог фикстуры: возраст -- единственный предикат (Р2).

    Каталог старше WORKER_TMP_HELD_SECONDS убирается, свежий -- нет: свежий
    может быть каталогом ИДУЩЕГО прогона. Приманка гасит ветку каталогов --
    старый каталог обязан пережить погашенную прополку. Каталоги БЕЗ файла
    владельца (остаток прежней формы, Ф4 fix-волны #407) удаляются по
    возрасту и здесь -- это объявленная норма, не дыра.
    """
    def _make_dirs(root: Path) -> tuple[Path, Path]:
        old_dir = root / "checks-teeth-fixture407.old"
        fresh_dir = root / "checks-teeth-fixture407.fresh"
        old_dir.mkdir()
        fresh_dir.mkdir()
        (old_dir / "subject").write_bytes(b"x")
        (fresh_dir / "subject").write_bytes(b"x")
        stamp = time.time() - WORKER_TMP_HELD_SECONDS - 600
        os.utime(old_dir, (stamp, stamp))
        return old_dir, fresh_dir

    with tempfile.TemporaryDirectory(prefix="checks-teeth-weed.") as raw:
        old_dir, fresh_dir = _make_dirs(Path(raw))
        with _weed_env_tmpdir(Path(raw)):
            weed_worker_leftovers()
        if old_dir.exists():
            return "старый каталог фикстуры пережил прополку"
        if not fresh_dir.exists():
            return "свежий каталог фикстуры снесён -- прополка бьёт по идущему прогону"
    # CONSTRAINT (Х6 раунда 3): ветка каталогов идёт по РЕЕСТРУ префиксов --
    # приманка гасит сам обход реестра, а не одно имя.
    weed_bait = ("    for prefix in _WEED_DIR_PREFIXES:\n",
                 "    for prefix in ():  # зуб Р2: обход реестра погашен\n",
                 "зуб Р2: ветка каталогов прополки погашена")
    with tempfile.TemporaryDirectory(prefix="checks-teeth-weed.") as raw2:
        old2, _fresh2 = _make_dirs(Path(raw2))
        with _weed_env_tmpdir(Path(raw2)):
            mut, mutraw = _fx_mutant((weed_bait,))
            try:
                mut.weed_worker_leftovers()
            finally:
                shutil.rmtree(mutraw, ignore_errors=True)
        if not old2.exists():
            return "мутация пережила зуб: погашенная ветка всё ещё убирает старый каталог"
    return None


def _tooth_weed_registry_covers_every_mkdtemp() -> str | None:
    """Каждый mkdtemp прибора стоит в реестре прополки (Х6 #407, раунд 3).

    Реестр знал ДВА префикса из восьми живых: новый временный каталог
    появлялся без владельца уборки и копился без предела. Перечень снимается
    с ИСХОДНИКА разбором (ast), а не текстовым поиском: перечень-проекция и
    был корнем класса. Направление проверяется в ОБЕ стороны -- префикс
    реестра без единого mkdtemp есть мёртвая запись, пережившая причину.
    """
    src = Path(__file__).read_text(encoding="utf-8")
    found: set[str] = set()
    for node in ast.walk(ast.parse(src)):
        if not isinstance(node, ast.Call):
            continue
        fn = node.func
        name = fn.attr if isinstance(fn, ast.Attribute) else getattr(fn, "id", "")
        if name != "mkdtemp":
            continue
        for kw in node.keywords:
            if (kw.arg == "prefix" and isinstance(kw.value, ast.Constant)
                    and isinstance(kw.value.value, str)):
                found.add(kw.value.value)
    if not found:
        return ("ни одного mkdtemp(prefix=...) не найдено разбором -- "
                "зуб мерит пустоту, а не реестр")
    missing = sorted(f for f in found if f not in _WEED_DIR_PREFIXES)
    if missing:
        return "префиксы mkdtemp без владельца прополки: " + ", ".join(missing)
    dead = sorted(x for x in _WEED_DIR_PREFIXES if x not in found)
    if dead:
        return ("записи реестра прополки без единого mkdtemp: "
                + ", ".join(dead))
    return None


def _tooth_fixture_dir_weed_owner_alive(_fixture: Path) -> str | None:
    """Прополка каталога фикстуры: возраст И владелец (Ф4 fix-волны #407).

    Живой процесс, держащий старый каталог (cwd), обязан его пережить;
    мёртвый владелец -- нет: предикат «только возраст» сносил каталог под
    ИДУЩИМ прогоном (воспроизведено дорожкой проб). Приманка снимает проверку
    живости -- каталог с живым владельцем обязан пасть, и зуб это ловит.
    """
    def _held_dir(root: Path, owner_pid: int) -> Path:
        held = root / "checks-teeth-fixture407.held"
        held.mkdir()
        (held / "subject").write_bytes(b"x")
        # Файл владельца пишется ДО уноса mtime в прошлое: запись в каталог
        # обновляет его возраст, и старый каталог стал бы «свежим».
        (held / _FIXTURE_OWNER_NAME).write_text(
            _owner_file_text(owner_pid), encoding="utf-8")
        stamp = time.time() - WORKER_TMP_HELD_SECONDS - 600
        os.utime(held, (stamp, stamp))
        return held

    with tempfile.TemporaryDirectory(prefix="checks-teeth-weed4.") as raw:
        (Path(raw) / "wee4-hold").mkdir()   # настоящий cwd держателя
        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import os, time; os.chdir(os.environ['WEED4_HELD']); "
             "time.sleep(120)"],
            env=dict(os.environ, WEED4_HELD=str(Path(raw) / "wee4-hold")),
            cwd=str(Path(raw)))
        try:
            held = _held_dir(Path(raw), holder.pid)
            with _weed_env_tmpdir(Path(raw)):
                weed_worker_leftovers()
            if not held.exists():
                return "живой владелец: старый каталог фикстуры снесён прополкой"
            holder.kill()
            holder.wait()
            with _weed_env_tmpdir(Path(raw)):
                weed_worker_leftovers()
            if held.exists():
                return "мёртвый владелец: старый каталог фикстуры пережил прополку"
        finally:
            holder.kill()
            holder.wait()
    liveness_bait = ("                if " + "alive:\n"
                     "                    continue\n",
                     "                if False:\n"
                     "                    continue\n",
                     "зуб Ф4: проверка живости владельца снята")
    with tempfile.TemporaryDirectory(prefix="checks-teeth-weed4.") as raw2:
        (Path(raw2) / "wee4-hold").mkdir()   # настоящий cwd держателя
        holder2 = subprocess.Popen(
            [sys.executable, "-c",
             "import os, time; os.chdir(os.environ['WEED4_HELD']); "
             "time.sleep(120)"],
            env=dict(os.environ, WEED4_HELD=str(Path(raw2) / "wee4-hold")),
            cwd=str(Path(raw2)))
        try:
            held2 = _held_dir(Path(raw2), holder2.pid)
            with _weed_env_tmpdir(Path(raw2)):
                mut, mutraw = _fx_mutant((liveness_bait,))
                try:
                    mut.weed_worker_leftovers()
                finally:
                    shutil.rmtree(mutraw, ignore_errors=True)
            if held2.exists():
                return ("мутация пережила зуб: погашенная живость владельца "
                        "всё ещё держит старый каталог")
        finally:
            holder2.kill()
            holder2.wait()
    return None


_X7_STAMP_BAIT = ("                    if got is not None and got != want:\n"
                  "                        alive = " + "False\n",
                  "                    if False:\n"
                  "                        alive = False\n",
                  "зуб Х7: сверка метки старта владельца снята")


def _tooth_fixture_dir_weed_pid_reuse(_fixture: Path) -> str | None:
    """Переиспользованный pid не держит каталог вечно (Х7 #407, раунд 3).

    Предикат живости был голым os.kill(pid, 0): каталог, чей владелец умер, а
    НОМЕР достался чужому живому процессу, не убирался НИКОГДА -- замерено на
    pid 1, который жив всегда. Файл владельца несёт метку старта, и её
    несовпадение означает мёртвого владельца при живом номере. Приманка
    снимает сверку метки -- каталог с чужим живым номером обязан снова
    пережить прополку, и зуб это ловит.
    """
    if _proc_start_stamp(os.getpid()) is None:
        return ("ПРИБОР: метка старта процесса недоступна (ps) -- предикат "
                "переиспользования pid не измерим на этой машине")

    def _aged(root: Path, name: str, body: str) -> Path:
        d = root / name
        d.mkdir()
        (d / "subject").write_bytes(b"x")
        # Файл владельца пишется ДО уноса mtime: запись в каталог обновляет
        # его возраст, и старый каталог стал бы «свежим».
        (d / _FIXTURE_OWNER_NAME).write_text(body, encoding="utf-8")
        stamp = time.time() - WORKER_TMP_HELD_SECONDS - 600
        os.utime(d, (stamp, stamp))
        return d

    foreign = "1\nМЕТКА-СТАРТА-КОТОРОЙ-НЕТ\n"
    with tempfile.TemporaryDirectory(prefix="checks-teeth-weedx7.") as raw:
        root = Path(raw)
        reused = _aged(root, "checks-teeth-fixture407.reused", foreign)
        mine = _aged(root, "checks-teeth-fixture407.mine",
                     _owner_file_text(os.getpid()))
        with _weed_env_tmpdir(root):
            weed_worker_leftovers()
        if reused.exists():
            return ("чужой живой номер (pid 1) держит каталог: прополка не "
                    "различила переиспользованный pid")
        if not mine.exists():
            return "свой живой владелец: каталог снесён прополкой"
    with tempfile.TemporaryDirectory(prefix="checks-teeth-weedx7.") as raw2:
        root2 = Path(raw2)
        reused2 = _aged(root2, "checks-teeth-fixture407.reused", foreign)
        with _weed_env_tmpdir(root2):
            mut, mutraw = _fx_mutant((_X7_STAMP_BAIT,))
            try:
                mut.weed_worker_leftovers()
            finally:
                shutil.rmtree(mutraw, ignore_errors=True)
        if not reused2.exists():
            return ("мутация пережила зуб: без сверки метки каталог с чужим "
                    "живым номером всё равно убран")
    return None


def _tooth_fixture_fork_one_home(_fixture: Path) -> str | None:
    """Предпроверка форка смотрит в FORK строителя (Р10 fix-волны #407).

    Питон пинил жёсткий путь, а строитель исполнял ${FORK:-…}: заданный
    FORK не пробовался вовсе. Примака возвращает жёсткий путь -- предпроверка
    перестаёт видеть настроенный FORK, зуб это ловит.
    """
    bait_path = "/нет/такого/форка-Р10"
    saved = os.environ.get("FORK")
    try:
        os.environ["FORK"] = bait_path
        miss = _fixture_missing_tool()
    finally:
        if saved is None:
            os.environ.pop("FORK", None)
        else:
            os.environ["FORK"] = saved
    if miss is None:
        return f"предпроверка не заметила несуществующий FORK={bait_path}"
    if bait_path not in miss:
        return f"причина не назвала настроенный FORK: {miss!r}"
    fork_bait = ("    env = os.environ.get(\"FORK\")\n"
                 "    if env:\n",
                 "    env = None  # мутация Р10: FORK игнорируется\n"
                 "    if env:\n",
                 "зуб Р10: жёсткий путь форка")
    mut, raw = _fx_mutant((fork_bait,))
    try:
        os.environ["FORK"] = bait_path
        try:
            mmiss = mut._fixture_missing_tool()
        finally:
            if saved is None:
                os.environ.pop("FORK", None)
            else:
                os.environ["FORK"] = saved
    finally:
        shutil.rmtree(raw, ignore_errors=True)
    if mmiss is None:
        # CONSTRAINT (Ф2 fix-волны #407): «нет предмета» здесь -- ЗЕЛЁНЫЙ
        # исход приманки: копия с погашенным чтением FORK обязана перестать
        # видеть несуществующий форк (все прочие дома есть). Прежний порядок
        # проверок падал на этом месте TypeError, а зелень за чужую причину
        # (каталог копии без FIXTURE_BUILDER до перепривязки констант) была
        # вакуумом -- приманка не мерила ветку FORK вовсе.
        return None
    if bait_path in mmiss:
        return (f"мутация пережила зуб: копия с жёстким путём всё ещё видит "
                f"FORK: {mmiss!r}")
    return (f"мутантное плечо отчиталось причиной вне FORK -- зелень была бы "
            f"чужой: {mmiss!r}")


def _tooth_fixture_builder_code3_is_unmeasured(_fixture: Path) -> str | None:
    """Код 3 строителя -- «НЕ ИЗМЕРЕНО» с причиной строителя (Р6 fix-волны #407).

    Потребитель сводил любой ненулевой код строителя в один исход; площадка
    без инструментария и сломанный предмет обязаны быть различимы.
    """
    marker = "НЕ ИЗМЕРЕНО -- зуб Р6: нет форка на этой площадке"
    code, out = _probe_fixture_builder(3, marker)
    if code != 2:
        return (f"код 3 строителя обязан отдавать фазе код 2 (НЕ ИЗМЕРЕНО), "
                f"получила {code}: {out!r}")
    if "ИТОГ фикстур=НЕ ИЗМЕРЕНО -- нет инструментария/предмета" not in out:
        return f"итог не назвал исход строителя кодом 3: {out!r}"
    if marker not in out:
        return f"причина строителя не доехала до вывода: {out!r}"
    rc3_bait = ("    if r.returncode == 3:\n",
                "    if False:\n",
                "зуб Р6: код 3 строителя не различается")
    mut, raw = _fx_mutant((rc3_bait,))
    try:
        mcode, mout = _probe_fixture_builder(3, marker, mod=mut)
    finally:
        shutil.rmtree(raw, ignore_errors=True)
    if mcode != 9 or "ОТКАЗ ПРИБОРА" not in mout:
        return (f"мутация «различение снято» пережила зуб: код 3 не ушёл в "
                f"отказ прибора: rc={mcode} {mout!r}")
    return None


def _tooth_fixture_builder_refusal_is_refusal(_fixture: Path) -> str | None:
    """Отказ построения (иной ненулевой код строителя) -- ОТКАЗ ПРИБОРА (Р6).

    Сломанный предмет не имеет права читаться как неизмеренность площадки:
    исходы обязаны различаться текстом итоговой строки и кодом фазы.
    """
    marker = "ОТКАЗ -- зуб Р6: нейтрализация легла не двумя заменами"
    code, out = _probe_fixture_builder(2, marker)
    if code != 9:
        return (f"отказ строителя обязан отдавать фазе код 9 (ОТКАЗ "
                f"ПРИБОРА), получила {code}: {out!r}")
    if "ИТОГ фикстур=ОТКАЗ ПРИБОРА -- строитель фикстуры отказал" not in out:
        return f"итог не назвал отказ строителя: {out!r}"
    if marker not in out:
        return f"причина строителя не доехала до вывода: {out!r}"
    if "ИТОГ фикстур=НЕ ИЗМЕРЕНО" in out:
        return f"отказ построения свёрнут в неизмеренность: {out!r}"
    raise_bait = ("    raise Refusal(f\"строитель фикстуры отказал на {stage} \"\n"
                  "                  f\"(rc={r.returncode}): {tail}\")\n",
                  "    return None, (\"предмет не построен (rc=%s): %s\" % "
                  "(r.returncode, tail))\n",
                  "зуб Р6: отказ строителя сведён в неизмеренность")
    mut, raw = _fx_mutant((raise_bait,))
    try:
        mcode, mout = _probe_fixture_builder(2, marker, mod=mut)
    finally:
        shutil.rmtree(raw, ignore_errors=True)
    if mcode != 2 or "ИТОГ фикстур=НЕ ИЗМЕРЕНО" not in mout:
        return (f"мутация пережила зуб: отказ строителя не свернулся в "
                f"неизмеренность: rc={mcode} {mout!r}")
    return None


def _tooth_fixture_refusal_reason_survives(_fixture: Path) -> str | None:
    """Причина Refusal зуба фазы доезжает до итоговой строки (Р8 fix-волны #407).

    Ветка except Refusal печатала причину построчно, но не клала её в why --
    итог фикстуры читался «НЕ ИЗМЕРЕНО -- None». Все зубы кортежа заменены
    бросками Refusal (длина кортежа -- пин фазы): почему обязан выжить.
    """
    own = Path(__file__).read_text(encoding="utf-8")
    bait_item = ("lambda _f: (_ for _ in ()).throw("
                 "Refusal(\"мутация Р8: причина отказа зуба\"))")
    mut, raw = _fx_mutant_src(_once_replace(
        _fx_bait_teeth(own, bait_item), *_FX_CTRL_NONE_PAIR))
    try:
        code, out = _fixture_recursion_probe(mut)
    finally:
        shutil.rmtree(raw, ignore_errors=True)
    if code != 2:
        return f"фаза на отказывающих зубах обязана дать код 2, получила {code}: {out!r}"
    if "мутация Р8: причина отказа зуба" not in out:
        return f"причина Refusal не напечатана: {out!r}"
    if "НЕ ИЗМЕРЕНО -- None" in out:
        return f"причина Refusal потеряна, итог называет None: {out!r}"
    whyfix_bait = ("                if why " + "is None:\n"
                   "                    why = str(exc)\n",
                   "                pass  # мутация Р8: причина не кладётся в why\n",
                   "зуб Р8: причина не кладётся в why")
    mut, raw = _fx_mutant_src(_once_replace(
        _once_replace(_fx_bait_teeth(own, bait_item), *_FX_CTRL_NONE_PAIR),
        *whyfix_bait))
    try:
        code, mout = _fixture_recursion_probe(mut)
    finally:
        shutil.rmtree(raw, ignore_errors=True)
    if "НЕ ИЗМЕРЕНО -- None" not in mout:
        return (f"мутация пережила зуб: причина дожила и без «why»: {mout!r}")
    return None


def _tooth_fixture_empty_reason_is_refusal(_fixture: Path) -> str | None:
    """Пустая причина зуба -- ОТКАЗ ПРИБОРА, а не зелёный исход (Р12 #407).

    Цикл фазы проверял «if reason» -- зуб, вернувший пустую строку, попадал
    в OK. Примака возвращает эту форму: пустая причина обязана снова стать
    зелёной, и зуб это ловит.
    """
    own = Path(__file__).read_text(encoding="utf-8")
    bait_src = _once_replace(
        _fx_bait_teeth(own, 'lambda _f: ""'), *_FX_CTRL_NONE_PAIR)
    mut, raw = _fx_mutant_src(bait_src)
    try:
        code, out = _fixture_recursion_probe(mut)
    finally:
        shutil.rmtree(raw, ignore_errors=True)
    if code != 9:
        return f"пустая причина обязана давать код 9, получила {code}: {out!r}"
    if "ОТКАЗ ПРИБОРА -- зуб вернул пустую причину" not in out:
        return f"строка отказа пустой причины не напечатана: {out!r}"
    if "ИТОГ фикстур=ОТКАЗ ПРИБОРА" not in out:
        return f"итог отказа не напечатан: {out!r}"
    empty_bait = ("            if reason " + "is None:\n"
                  "                print(f\"checks-teeth: ФИКСТУРА {name}: "
                  "OK\", flush=True)\n",
                  "            if reason is None or reason == \"\":\n"
                  "                print(f\"checks-teeth: ФИКСТУРА {name}: "
                  "OK\", flush=True)\n",
                  "зуб Р12: пустая причина снова зелёная")
    mut, raw = _fx_mutant_src(_once_replace(bait_src, *empty_bait))
    try:
        code, mout = _fixture_recursion_probe(mut)
    finally:
        shutil.rmtree(raw, ignore_errors=True)
    if code == 9 or "ОТКАЗ ПРИБОРА -- зуб вернул пустую причину" in mout:
        return (f"мутация пережила зуб: погашенная ветка всё ещё отказывает: "
                f"rc={code} {mout!r}")
    if ": OK" not in mout:
        return f"примака не вернула пустой причине зелёный исход: {mout!r}"
    return None


# CONSTRAINT (Р3 fix-волны #407): перечень зубов фазы живёт ЗДЕСЬ одним домом --
# фаза, пин и контрольный зуб читают этот кортеж; копия списка имён разошлась бы
# молча при добавлении зуба.
_FIXTURE_TEETH: tuple = (
    ("steps-off-floor-predates", _tooth_steps_off_floor_predates),
    ("steps-off-floor-from-registry", _tooth_steps_off_floor_from_registry),
    ("carrier-absent-texts-distinct", _tooth_carrier_absent_texts_distinct),
    ("fixture-control-is-load-bearing", _tooth_fixture_control_is_load_bearing),
    ("fixture-cleanup-on-exception", _tooth_fixture_cleanup_on_exception),
    ("fixture-dir-weed-by-age", _tooth_fixture_dir_weed_by_age),
    ("fixture-dir-weed-owner-alive", _tooth_fixture_dir_weed_owner_alive),
    ("fixture-dir-weed-pid-reuse", _tooth_fixture_dir_weed_pid_reuse),
    ("fixture-fork-one-home", _tooth_fixture_fork_one_home),
    ("fixture-builder-code3-is-unmeasured",
     _tooth_fixture_builder_code3_is_unmeasured),
    ("fixture-builder-refusal-is-refusal",
     _tooth_fixture_builder_refusal_is_refusal),
    ("fixture-refusal-reason-survives",
     _tooth_fixture_refusal_reason_survives),
    ("fixture-empty-reason-is-refusal",
     _tooth_fixture_empty_reason_is_refusal),
)


def _tooth_builder_refusal_is_row_scoped() -> str | None:
    """Отказ строителя одной строки не ослепляет остальные (#350).

    Фикстура -- две literal-строки на базе из самопроверки: R1 не находит свой
    якорь (Refusal строителя), O1 валидна. Ожидание: O1 построена в задания,
    R1 -- в перечне отказов с сырым текстом, итоговый код прохода ненулевой.
    Зуб краснеет, если отказ снова станет глобальным (код 2 до измерения).
    """
    B = b"x MARK y MARK z"
    rows = [
        {"id": "R1", "check": "c", "kind": "literal", "anchor": "ZZZZ",
         "repl": "ZZZ", "also": "", "expect": "1"},
        {"id": "O1", "check": "c", "kind": "literal", "anchor": "MARK",
         "repl": "MARX", "also": "", "expect": "2"},
    ]
    jobs, _inapp, _third, refused = build_jobs(rows, None, Path("/fixture-image"), B)
    if [j[0] for j in jobs] != ["O1"]:
        return f"валидная строка не построена: jobs={[j[0] for j in jobs]}"
    if [r[0] for r in refused] != ["R1"]:
        return f"отказ не привязан к строке: refused={refused}"
    if "не найден" not in refused[0][1]:
        return f"сырой текст отказа потерян: {refused[0][1]!r}"
    if exit_code(0, len(refused)) != 9:
        return (f"код прохода при отказе строки {exit_code(0, len(refused))}, ждали РОВНО 9 -- "
                f"2 запрещён: свип читает 2 как «не измеряли» и спрятал бы измеренные строки")
    return None


def _tooth_refusal_is_not_green() -> str | None:
    """Отказавшая строка -- третий исход: не «мутаций», не «прошло молча».

    Бухгалтерия итоговых строк -- тоже место вакуумной зелени: отказ, попавший
    в счётчик измеренных или молчавших, выглядел бы работой прибора.
    """
    B = b"x MARK y MARK z"
    rows = [
        {"id": "R1", "check": "c", "kind": "literal", "anchor": "ZZZZ",
         "repl": "ZZZ", "also": "", "expect": "1"},
        {"id": "O1", "check": "c", "kind": "literal", "anchor": "MARK",
         "repl": "MARX", "also": "", "expect": "2"},
    ]
    jobs, _inapp, third, refused = build_jobs(rows, None, Path("/fixture-image"), B)
    line = summary_line(len(jobs), 0)
    if "мутаций=1" not in line or "R1" in line:
        return f"отказавшая строка попала в счётчик мутаций: {line}"
    if "молча/чужой дверью=0" not in line:
        return f"отказавшая строка попала в счётчик молчаний: {line}"
    rline = refusal_line(refused)
    if "отказов прибора=1" not in rline or "R1" not in rline:
        return f"перечень отказов не назвал счётчик и строку: {rline}"
    tline = inapplicable_line(third)
    if "неприменимых по версии=0" not in tline:
        return f"третий исход попал в чужие счётчики: {tline}"
    return None


def _tooth_no_refusal_same_outcome() -> str | None:
    """Строка без отказа строится и кодируется ТОЧНО как до правки.

    Граница громкого отказа (#335): ветка отказа стреляет в области действия
    и не шире -- обёртка построения не имеет права менять исход строк, чьи
    строители не отказывают. Эталон кортежа -- формула, которой main строил
    задания ДО этой волны.
    """
    B = b"x MARK y MARK z"
    row = {"id": "O1", "check": "c", "kind": "literal", "anchor": "MARK",
           "repl": "MARX", "also": "c2; c3", "expect": "2"}
    image = Path("/fixture-image")
    jobs, inapp, third, refused = build_jobs([row], None, image, B)
    want = {"c"}
    want |= {x.strip() for x in "c2; c3".split(";") if x.strip()}
    expect_job = ("O1", "c", str(image), edits_literal(B, row), sorted(want))
    if jobs != [expect_job]:
        return f"исход строки изменился: {jobs!r}"
    if inapp or third or refused:
        return (f"без отказа нет иных исходов: inapp={[r['id'] for r in inapp]} "
                f"third={third} refused={refused}")
    if exit_code(0, 0) != 0:
        return "нулевых bad/refused хватило на ненулевой код"
    return None


def _tooth_seven_is_upstream() -> str | None:
    """Код 7 занят кит-таблицей с ПРОТИВОПЛОЖНЫМ действием -- ждать апстрим
    и НЕ краснить. Проход, измеривший строки, требует краснить и искать
    дефект; повторный захват кода молча перевернул бы реакцию свипа. Зуб
    границы: exit_code не имеет права отвечать 7 ни на каком входе."""
    for bad_n in range(6):
        for refused_n in range(6):
            if exit_code(bad_n, refused_n) == 7:
                return (f"exit_code({bad_n}, {refused_n}) = 7 -- "
                        f"код занят ожиданием апстрима")
    return None


# --- зубы третьего исхода рядов образа (#353) ---------------------------
#
# Фикстуры: расщеплённая форма сторожа maxTokens 2.1.276+ (та же игла, что у
# проверки кита и локатора патча) и ряд с мёртвым якорем -- без объявления
# он обязан отказывать, как отказывал до появления поля шага.
_M2_SPLIT_SITE = (
    b"// Version: 9.9.9\n"
    b"if(s!==void 0&&s>M)throw new Ne(`${g}: $.model.complete: "
    b"maxTokens ${s} is past what ${w} can produce in one reply (${M})`);"
    b"let U=Math.min((s??DEF)+B,M);\n"
)
_M2_LONGER_SITE = (
    b"// Version: 9.9.8\n"
    b"if(t!==void 0&&t>LIM)throw new Ne(`${g}: $.model.complete: "
    b"maxTokens ${t} is past what ${w} can produce in one reply (${LIM})`);"
    b"let U=Math.min((t??D)+B,LIM);\n"
)

_DECL_BRANCH_ANCHOR = (
    "            hit = decl_pairs.get((ver, step_owner))\n"
    "            if hit is not None:\n"
)
_DECL_BRANCH_REPL = (
    "            hit = decl_pairs.get((ver, step_owner))\n"
    "            if False:\n"
)
_DECL_LOOKUP_ANCHOR = "            hit = decl_pairs.get((ver, step_owner))\n"
_DECL_LOOKUP_REPL = (
    "            hit = (7, \"мутация: неприменимость без объявления\")\n"
)
_STEP_GATE_ANCHOR = "        if step_owner:\n"
_STEP_GATE_REPL = "        if True:\n"
_STEP_DOOR_ANCHOR = "            if step_owner not in steps:\n"
_STEP_DOOR_REPL = "            if False:\n"
_SETUP_DOOR_ANCHOR = "            if setup_fail is not None:\n"
_SETUP_DOOR_REPL = "            if False:\n"
_M2_PAD_ANCHOR = "    return [(tail_at + use.start(1), lim.ljust(len(default)))]\n"
_M2_PAD_REPL = "    return [(tail_at + use.start(1), lim)]\n"


def _version_row(rid: str, step: str) -> dict[str, str]:
    """Строка образа с мёртвым якорем и полем шага-владельца (поле 9)."""
    return {"id": rid, "check": "c", "kind": "literal", "anchor": "ZZZZ",
            "repl": "ZZZ", "also": "", "expect": "1", "note": "", "step": step,
            "lineno": 3}


def _mutated_self(anchor: str, repl: str, what: str):
    """Копия прибора с названной мутацией; константы возвращены дому."""
    own = Path(__file__).read_text(encoding="utf-8")
    mutated = _once_replace(own, anchor, repl, what)
    with tempfile.TemporaryDirectory(prefix="checks-teeth-third.") as raw:
        mod = Path(raw) / "checks-teeth-mutated.py"
        mod.write_text(mutated, encoding="utf-8")
        spec = importlib.util.spec_from_file_location("checks_teeth_mutated_third", mod)
        mut = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mut)
        # Копия модуля лежит вне дома: её константы указывают в пустоту.
        # Возвращаем дому ЕДИНЫМ механизмом перепривязки (_rebind_copy_home):
        # предмет мутации -- ветка третьего исхода, а не пути копии.
        _rebind_copy_home(mut)
        return mut


def _tooth_declared_row_is_third_outcome() -> str | None:
    """Объявленная неприменимость -- ТРЕТИЙ исход, не отказ прибора (#353).

    Ведро отказов -- сигнал, и два постоянных жильца (B1/B2 на образах без
    механизма бюджета мод-API) делали прибор слепым к новому отказу того же
    ведра. Пара «версия образа × шаг-владелец», ОБЪЯВЛЕННАЯ в доме декларации,
    уводит ряд в собственную корзину, строку ряда и итоговую строку. Мутация
    гасит ветку объявления: ряд обязан вернуться в отказ -- исход даёт
    ОБЪЯВЛЕНИЕ, а не ненахождение якоря.
    """
    row = _version_row("N1", "29")
    decl = {("2.1.276", "29"): (4, "тест-основание неприменимости")}
    jobs, _inapp, third, refused = build_jobs(
        [row], None, Path("/fixture-image"), b"x MARK y MARK z",
        ver="2.1.276", decl_pairs=decl)
    if jobs or refused:
        return f"объявленный ряд не в третьем исходе: jobs={jobs!r} refused={refused!r}"
    if [t[0] for t in third] != ["N1"]:
        return f"третий исход не назвал ряд: {third!r}"
    rid, ver, step, reason = third[0]
    if (ver, step, reason) != ("2.1.276", "29", "тест-основание неприменимости"):
        return f"третий исход потерял версию/шаг/основание: {third[0]!r}"
    rline = inapplicable_row_line(rid, ver, step, reason)
    for part in ("2.1.276", "29", "тест-основание неприменимости"):
        if part not in rline:
            return f"строка ряда не назвала версию/шаг/основание: {rline!r}"
    if "ОТКАЗ" in rline:
        return f"строка ряда неотличима от отказа прибора: {rline!r}"
    tline = inapplicable_line(third)
    if "неприменимых по версии=1" not in tline or "N1" not in tline:
        return f"итоговая строка не назвала счётчик и ряд: {tline!r}"
    if tline == refusal_line([("N1", "x")]):
        return "итоговая строка совпала со строкой отказов прибора"
    if exit_code(0, len(refused)) != 0:
        return "третий исход закодирован ненулевым кодом прохода"
    mut = _mutated_self(_DECL_BRANCH_ANCHOR, _DECL_BRANCH_REPL,
                        "зуб: ветка объявления")
    mjobs, _mi, mthird, mrefused = mut.build_jobs(
        [row], None, Path("/fixture-image"), b"x MARK y MARK z",
        ver="2.1.276", decl_pairs=decl)
    if mthird or not mrefused:
        return (f"мутация не вернула объявленный ряд в отказ прибора: "
                f"third={mthird!r} refused={mrefused!r}")
    return None


def _tooth_undeclared_pair_still_refuses() -> str | None:
    """Ряд БЕЗ строки в декларации -- ОТКАЗ прибора (#353).

    Неприменимость даёт только ОБЪЯВЛЕНИЕ: у пары «версия × шаг» без строки
    в доме мёртвый якорь обязан отказывать, как отказывал до появления поля
    шага. Мутация дарит третьей корзине ряд без объявления -- отказ исчезает
    молчанием, и третий исход становится глушилкой; зуб краснеет.
    """
    row = _version_row("N2", "29")
    decl = {("2.1.277", "29"): (2, "чужая пара -- не эта версия")}
    jobs, _inapp, third, refused = build_jobs(
        [row], None, Path("/fixture-image"), b"x MARK y MARK z",
        ver="2.1.276", decl_pairs=decl)
    if jobs or third:
        return f"ряд без объявления ушёл из отказов: third={third!r} jobs={jobs!r}"
    if [r[0] for r in refused] != ["N2"] or "не найден" not in refused[0][1]:
        return f"отказ не привязан к строке с мёртвым якорем: {refused!r}"
    if exit_code(0, len(refused)) != 9:
        return "отказ строки перестал кодироваться девяткой"
    mut = _mutated_self(_DECL_LOOKUP_ANCHOR, _DECL_LOOKUP_REPL,
                        "зуб: честность поиска пары")
    mjobs, _mi, mthird, mrefused = mut.build_jobs(
        [row], None, Path("/fixture-image"), b"x MARK y MARK z",
        ver="2.1.276", decl_pairs=decl)
    if mrefused or not mthird:
        return (f"мутация не подарила неприменимость ряду без объявления: "
                f"third={mthird!r} refused={mrefused!r}")
    return None


def _tooth_empty_step_field_still_refuses() -> str | None:
    """ПУСТОЕ поле шага + мёртвый якорь -- ОТКАЗ прибора (#353).

    Поле 9 -- провенанс для проверяющей стороны, а не глушилка: без названного
    шага-владельца ряд обязан строиться как раньше. Мутация гасит ТОЛЬКО
    дверь самого поля (`if step_owner:`): пустота просачивается в машинерию
    шага, и текст отказа уезжает со строителя на дверь реестра шагов --
    зуб краснеет дрейфом текста. Двери подготовки и реестра шагов пинят
    СВОИ зубы; пара декларации здесь -- sentinel: откройся обе двери,
    пустота получила бы третий исход, и это ловит контроль.
    """
    row = _version_row("N3", "")
    decl = {("2.1.276", ""): (5, "пара для пустого шага -- только мутации")}
    jobs, _inapp, third, refused = build_jobs(
        [row], None, Path("/fixture-image"), b"x MARK y MARK z",
        ver="2.1.276", decl_pairs=decl)
    if jobs or third:
        return f"пустое поле шага получило третий исход: third={third!r}"
    if [r[0] for r in refused] != ["N3"] or "не найден" not in refused[0][1]:
        return f"отказ не привязан к строке с мёртвым якорем: {refused!r}"
    mut = _mutated_self(_STEP_GATE_ANCHOR, _STEP_GATE_REPL,
                        "зуб: обязательность поля шага")
    mjobs, _mi, mthird, mrefused = mut.build_jobs(
        [row], None, Path("/fixture-image"), b"x MARK y MARK z",
        ver="2.1.276", decl_pairs=decl)
    if mjobs or mthird:
        return (f"пустое поле шага ушло в работу: third={mthird!r} "
                f"jobs={mjobs!r}")
    if not mrefused:
        return "пустое поле шага перестало отказывать"
    if "не найден" in mrefused[0][1]:
        return ("мутация двери поля шага не изменила текст отказа -- "
                "зуб не чувствует дверь")
    return None


def _tooth_undeclared_step_refuses() -> str | None:
    """Шаг поля 9, НЕ ОБЪЯВЛЕННЫЙ в патче, -- ОТКАЗ прибора с номером (#353).

    Дверь ловит опечатку в девятом поле: шаг, которого в tweakcc-patch.js
    нет, не имеет права ни на третий исход, ни на тихое измерение обычной
    мутацией -- неверный номер молча подарил бы ряду чужую судьбу. Ряд
    контроля несёт ЖИВОЙ якорь: снятая дверь обязана построить его в
    задания, и именно это краснит зуб.
    """
    row = {"id": "N4", "check": "c", "kind": "literal", "anchor": "MARK",
           "repl": "MARX", "also": "", "expect": "2", "note": "",
           "step": "99", "lineno": 3}
    decl = {("2.1.276", "29"): (4, "живая пара -- не этот шаг")}
    base = b"x MARK y MARK z"
    jobs, _inapp, third, refused = build_jobs(
        [row], None, Path("/fixture-image"), base,
        ver="2.1.276", decl_pairs=decl)
    if jobs or third:
        return f"шаг-призрак прошёл в работу: jobs={jobs!r} third={third!r}"
    if [r[0] for r in refused] != ["N4"]:
        return f"отказ не привязан к строке: {refused!r}"
    why = refused[0][1]
    if "99" not in why or "не объявлен" not in why:
        return f"отказ не назвал опечатанный шаг: {why!r}"
    mut = _mutated_self(_STEP_DOOR_ANCHOR, _STEP_DOOR_REPL,
                        "зуб: дверь реестра шагов")
    mjobs, _mi, mthird, mrefused = mut.build_jobs(
        [row], None, Path("/fixture-image"), base,
        ver="2.1.276", decl_pairs=decl)
    if mrefused or mthird or not mjobs:
        return (f"мутация не пустила ряд с опечатанным шагом в задания: "
                f"jobs={mjobs!r} third={mthird!r} refused={mrefused!r}")
    if [j[0] for j in mjobs] != ["N4"]:
        return f"мутация построила чужие задания: {mjobs!r}"
    return None


def _tooth_setup_failure_refuses() -> str | None:
    """Неудавшаяся подготовка -- ОТКАЗ ряда, а не молчаливый проход (#353).

    Дверь держит громкий отказ в области действия: сбой чтения правил
    (версия образа) не имеет права молча пускать ряды с полем шага в
    машинерию с недочитанным состоянием. Контроль ломает САМО чтение
    версии (база без маркера) -- отказ обязан нести причину подготовки.
    Мутация гасит ТОЛЬКО эту дверь: отказ проглатывается, и текст ряда
    уезжает на строителя -- зуб краснеет дрейфом.
    """
    row = {"id": "N5", "check": "c", "kind": "literal", "anchor": "ZZZZ",
           "repl": "ZZZ", "also": "", "expect": "1", "note": "",
           "step": "29", "lineno": 3}
    decl = {("2.1.276", "29"): (4, "пара недостижима: версия не читается")}
    base = b"x MARK y MARK z"
    jobs, _inapp, third, refused = build_jobs(
        [row], None, Path("/fixture-image"), base, decl_pairs=decl)
    if jobs or third:
        return f"сбой подготовки не отказал: jobs={jobs!r} third={third!r}"
    if [r[0] for r in refused] != ["N5"]:
        return f"отказ не привязан к строке: {refused!r}"
    if "версия образа" not in refused[0][1]:
        return f"отказ не понёс причину подготовки: {refused[0][1]!r}"
    mut = _mutated_self(_SETUP_DOOR_ANCHOR, _SETUP_DOOR_REPL,
                        "зуб: дверь отказа подготовки")
    mjobs, _mi, mthird, mrefused = mut.build_jobs(
        [row], None, Path("/fixture-image"), base, decl_pairs=decl)
    if mthird or mjobs:
        return (f"снятая дверь пустила ряд дальше: jobs={mjobs!r} "
                f"third={mthird!r}")
    if not mrefused:
        return "снятая дверь проглотила отказ молча"
    if "версия образа" in mrefused[0][1]:
        return "мутация не сняла дверь подготовки -- зуб не чувствует её"
    return None


def _tooth_m2_padding_keeps_tail() -> str | None:
    """Мутация M2 не сдвигает хвост образа (#353).

    Игла переведена на расщеплённую форму сторожа 2.1.276+ -- ту же, что
    читают проверка кита и локатор патча; цельная форма в этой сборке даёт
    0 вхождений, и красность M2 была недоказуема. Канон literal перенесён на
    derived: предел КОРОЧЕ умолчания записывается с добивкой пробелами до
    длины умолчания (`(s??M  )` -- валидный JS, длина хвоста неизменна),
    ДЛИННЕЕ -- отказ прибора. Мутация снимает добивку -- замена
    укорачивается, и хвост сдвинулся бы; зуб краснеет длиной.
    """
    base = _M2_SPLIT_SITE
    try:
        edits = edits_m2(base)
    except Refusal as exc:
        return f"расщеплённая форма сторожа не читается иглой: {exc}"
    if len(edits) != 1:
        return f"ждали одну правку, получили {len(edits)}"
    off, repl = edits[0]
    if base[off:off + len(repl)] != b"DEF":
        return f"правка стоит не на имени умолчания: {base[off:off + 8]!r}"
    if repl != b"M  ":
        return f"замена не добита пробелами до длины умолчания: {repl!r}"
    if len(base[:off] + repl + base[off + len(repl):]) != len(base):
        return "длина образа изменилась после мутации"
    try:
        edits_m2(_M2_LONGER_SITE)
    except Refusal as exc:
        if "замена сдвинула бы хвост образа" not in str(exc):
            return f"предел длиннее умолчания отказал чужим текстом: {exc}"
    else:
        return "предел длиннее умолчания не отказал -- хвост сдвинулся бы"
    mut = _mutated_self(_M2_PAD_ANCHOR, _M2_PAD_REPL, "зуб: добивка M2")
    try:
        medits = mut.edits_m2(base)
    except Refusal as exc:
        return f"мутация добивки отказала вместо укорачивания: {exc}"
    if not medits or medits[0][1] != b"M":
        return f"мутация не укоротила замену: {medits!r}"
    return None


def pick_ids(raw: str | None, known: set[str]) -> set[str] | None:
    """Разбор --id: None -- весь набор, иначе НЕПУСТОЕ подмножество known.

    CONSTRAINT: выбор, не назвавший ни одной строки (`--id ,`, `--id " "`,
    `--id ""`), ОТКАЗЫВАЕТ, а не мерит ноль строк: зелёный «ИТОГ мутаций=0»
    (docnum:example -- цитата печатаемой формы, не счёт стенда)
    неотличим от прохода, измерившего предмет, -- та же вакуумная зелень,
    что и неизмеренная мутация, только в бухгалтерии.
    """
    if raw is None:
        return None
    picked = {x.strip() for x in raw.split(",") if x.strip()}
    if not picked:
        raise Refusal(f"выбор пуст -- --id «{raw}» не назвал ни одной строки")
    unknown = picked - known
    if unknown:
        raise Refusal(f"нет таких строк: {sorted(unknown)}")
    return picked


def _tooth_empty_pick_refuses() -> str | None:
    """Вырожденный --id отказывает, а не мерит ноль строк.

    Область сторожа: пустой выбор не имеет потребителей образа, и контроль
    красноты пропускает его ПО ПОСТРОЕНИЮ -- единственный сторож здесь сам
    разбор. Без него `--id ,` печатал RC=0 «ИТОГ мутаций=0» (docnum:example --
    цитата печатаемой формы, не счёт стенда), неотличимый от
    измеренного прохода.
    """
    known = {"I1", "C1"}
    for raw in ("", ",", " ", ",,", " , "):
        try:
            got = pick_ids(raw, known)
        except Refusal as exc:
            if "выбор пуст" not in str(exc):
                return f"--id «{raw}»: отказ без слов «выбор пуст»: {exc}"
            continue
        return f"--id «{raw}» не отказал: {got!r}"
    try:
        got = pick_ids("I1", known)
    except Refusal as exc:
        return f"живой выбор отказал: {exc}"
    if got != {"I1"}:
        return f"живой выбор разобран как {got!r}"
    if pick_ids(None, known) is not None:
        return "отсутствие ключа перестало значить весь набор"
    try:
        pick_ids("I9", known)
    except Refusal as exc:
        if "нет таких строк" not in str(exc):
            return f"опечатка отказала без слов «нет таких строк»: {exc}"
    else:
        return "опечатка I9 не отказала"
    return None


_GHOST_CHECK = "a ghost check that exists nowhere"

# Якорь мутации зуба mutations-name-in-registry: ветвь поля 6 двери.
# Мутация гасит её безусловным continue -- копия прибора перестаёт видеть
# призрак в поле 6, и ловит это только плечо зуба, мерящее поле 6.
NAME_DOOR_FIELD6_ANCHOR = (
    "        for name in str(row.get(\"also\", \"\")).split(\";\"):\n"
    "            name = name.strip()\n"
    "            if name and name not in registry:\n"
)
NAME_DOOR_FIELD6_REPL = (
    "        for name in str(row.get(\"also\", \"\")).split(\";\"):\n"
    "            name = name.strip()\n"
    "            continue\n"
    "            if name and name not in registry:\n"
)


def _tooth_mutations_name_in_registry() -> str | None:
    """Дверь реестра имён пинит ОБА поля таблицы. None -- зуб зелёный.

    Ветвь поля 6 мерится и на мутации самой двери (docnum:other -- 6 есть
    номер КОЛОНКИ): копия прибора с погашенной
    ветвью поля 6 обязана перестать отказывать на призраке в поле 6 -- иначе
    зуб зелоне и на двери, знающей одно поле. Положительный контроль --
    живая таблица: дверь, краснеющая всегда, ничего не пинит.
    """
    try:
        registry = set(_pipeline_check_names())
    except Refusal as exc:
        return f"реестр checks конвейера не читается: {exc}"
    live = sorted(registry)[0]
    base = {"id": "G1", "kind": "literal", "anchor": "A", "repl": "B",
            "also": "", "expect": "1", "lineno": 7}
    row2 = dict(base, check=_GHOST_CHECK)
    try:
        check_row_names([row2], registry)
    except Refusal as exc:
        t2 = str(exc)
        if "строка 7" not in t2 or _GHOST_CHECK not in t2 or "поле 2" not in t2:
            return f"отказ поля 2 не назвал строку, поле и имя: {t2!r}"
    else:
        return "имя-призрак в поле 2 прошло дверь молча"
    row6 = dict(base, check=live, also=_GHOST_CHECK)
    try:
        check_row_names([row6], registry)
    except Refusal as exc:
        t6 = str(exc)
        if "строка 7" not in t6 or _GHOST_CHECK not in t6 or "поле 6" not in t6:
            return f"отказ поля 6 не назвал строку, поле и имя: {t6!r}"
        if t6 == t2:
            return "отказы поля 2 и поля 6 неразличимы"
    else:
        return "имя-призрак в поле 6 прошло дверь молча"
    dup = [dict(base, check=live, lineno=7), dict(base, check=live, lineno=8)]
    try:
        check_row_names(dup, registry)
    except Refusal as exc:
        if "строка 8" not in str(exc) or "G1" not in str(exc):
            return f"дубль id не назвал строку и id: {exc!r}"
    else:
        return "дубль id прошёл дверь молча"
    own = Path(__file__).read_text(encoding="utf-8")
    mutated = _once_replace(own, NAME_DOOR_FIELD6_ANCHOR, NAME_DOOR_FIELD6_REPL,
                            "зуб: ветвь поля 6 двери")
    with tempfile.TemporaryDirectory(prefix="checks-teeth-namedoor.") as raw:
        mod = Path(raw) / "checks-teeth-mutated.py"
        mod.write_text(mutated, encoding="utf-8")
        spec = importlib.util.spec_from_file_location(
            "checks_teeth_mutated_namedoor", mod)
        mut = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mut)
        try:
            mut.check_row_names([row6], registry)
        except Refusal:
            return "копия без ветви поля 6 всё ещё отказывает на призраке поля 6"
    try:
        rows = read_table()
    except Refusal as exc:
        return f"живая таблица не читается: {exc}"
    try:
        check_row_names(rows, registry)
    except Refusal as exc:
        return (f"дверь красна на живой таблице -- реестр без призраков "
                f"обязан молчать: {exc}")
    return None


# --- зубы карты «шаг -> проверки» и стены реестра стенда 7 (#403B) ------------


def _run_step_gate(tool: Path, registry: Path, map_path: Path):
    """Гейт карты шагов как предмет: CLI --gate, код возврата и вывод."""
    return subprocess.run(
        [sys.executable, str(tool), "--gate", str(registry), str(map_path)],
        capture_output=True, text=True, errors="replace")


def _tooth_step_checks_unmapped_step_refuses() -> str | None:
    """З1 (#403B): запись реестра без строки карты -- код 3 с именем шага.

    Дефект Д1: компоновка выключала шаг, а проверяющая сторона о нём не
    знала -- его проверки падали «предмета нет» без объяснения, мимо
    машинерии вердиктов реестра. Гейт обязан краснить ДО компоновки и
    называть шаг по имени. Мутации однопеременные: погашенный код 3 и
    инвертированное членство.
    """
    if not _STEP_CHECKS_TOOL.is_file():
        return f"нет инструмента карты шагов: {_STEP_CHECKS_TOOL}"
    if not _STEP_CHECKS_MAP.is_file():
        return f"нет карты шагов: {_STEP_CHECKS_MAP}"
    step = "З1 шаг вне карты"
    with tempfile.TemporaryDirectory(prefix="checks-teeth-z1.") as raw:
        reg = Path(raw) / "our-steps-off.txt"
        reg.write_text(f"{step}\t2.1.278\tзуб З1: шаг не проведён в карту\n",
                       encoding="utf-8")
        r = _run_step_gate(_STEP_CHECKS_TOOL, reg, _STEP_CHECKS_MAP)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 3:
            return f"гейт не краснит кодом 3: rc={r.returncode} {out!r}"
        if step not in out:
            return f"отказ гейта не называет шаг по имени: {out!r}"
        mut = Path(raw) / "step-checks-z1.py"
        # Мутированная копия обязана стоять в окружении инструмента: без
        # steps-off-registry.js рядом она умирает на чтении реестра ДО
        # мутированного кода -- и мутация «проверялась» бы чужой причиной.
        shutil.copy2(ROOT / "tools" / "steps-off-registry.js",
                     Path(raw) / "steps-off-registry.js")
        module_src = _STEP_CHECKS_TOOL.read_text(encoding="utf-8")
        for name, old, new in (
            ("погашенный код 3", "        return 3", "        return 0"),
            ("инвертированное членство", "name not in checks_map",
             "name in checks_map"),
        ):
            mut.write_text(_once_replace(module_src, old, new,
                                         f"зуб З1: {name}"),
                           encoding="utf-8")
            m = _run_step_gate(mut, reg, _STEP_CHECKS_MAP)
            mout = (m.stdout or "") + (m.stderr or "")
            if m.returncode == 3 and step in mout:
                return (f"мутация пережила зуб ({name}): отказ не отключился: "
                        f"rc={m.returncode} {mout!r}")
    return None


def _tooth_step_checks_mapped_step_passes() -> str | None:
    """З2 (#403B): проведённый шаг не краснит гейт; вне области отказа тихо.

    Зуб «вне области отказа НЕТ»: реестр с ровно шагом 26 и карта, несущая
    его, дают код 0 со сводкой, а текст отказа в зелёном исходе отсутствует.
    Мутация: инвертированное членство краснит проведённый шаг.
    """
    if not _STEP_CHECKS_TOOL.is_file():
        return f"нет инструмента карты шагов: {_STEP_CHECKS_TOOL}"
    if not _STEP_CHECKS_MAP.is_file():
        return f"нет карты шагов: {_STEP_CHECKS_MAP}"
    with tempfile.TemporaryDirectory(prefix="checks-teeth-z2.") as raw:
        reg = Path(raw) / "our-steps-off.txt"
        reg.write_text(_STEP26_ROW + "\t2.1.278\tзуб З2: проведённый шаг\n",
                       encoding="utf-8")
        r = _run_step_gate(_STEP_CHECKS_TOOL, reg, _STEP_CHECKS_MAP)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 0:
            return f"гейт краснит проведённый шаг: rc={r.returncode} {out!r}"
        if _STEP_GATE_SUMMARY_MARK not in out:
            return f"гейт не печатает сводку проведённости: {out!r}"
        if _STEP_GATE_REFUSAL_MARK in out:
            return f"вне области отказа не тихо: {out!r}"
        mut = Path(raw) / "step-checks-z2.py"
        # Окружение инструмента для мутированной копии -- см. зуб З1.
        shutil.copy2(ROOT / "tools" / "steps-off-registry.js",
                     Path(raw) / "steps-off-registry.js")
        mut.write_text(_once_replace(
            _STEP_CHECKS_TOOL.read_text(encoding="utf-8"),
            "name not in checks_map", "name in checks_map",
            "зуб З2: инвертированное членство"), encoding="utf-8")
        m = _run_step_gate(mut, reg, _STEP_CHECKS_MAP)
        mout = (m.stdout or "") + (m.stderr or "")
        if m.returncode == 0:
            return f"мутация пережила зуб: проведённый шаг не покраснел: {mout!r}"
    return None


def _tooth_step_checks_dash_is_declared_empty() -> str | None:
    """З3 (#403B): поле '-' -- ОБЪЯВЛЕННОЕ отсутствие проверок, не поломка.

    Дельта обязана быть объявляемой и отличимой от поломки: строка карты с
    '-' в поле проверок не краснит гейт, а строка, ОТСУТСТВУЮЩАЯ в карте,
    краснит. Тексты двух исходов попарно различны. Мутация: тире объявлено
    неразборчивым -- зелёный исход падает отказом.
    """
    if not _STEP_CHECKS_TOOL.is_file():
        return f"нет инструмента карты шагов: {_STEP_CHECKS_TOOL}"
    dash_step = "З3 шаг с объявленным отсутствием проверок"
    ghost_step = "З3 шаг без строки карты"
    with tempfile.TemporaryDirectory(prefix="checks-teeth-z3.") as raw:
        map_path = Path(raw) / "our-step-checks.txt"
        map_path.write_text(f"{dash_step} | s26 | -\n", encoding="utf-8")
        reg_one = Path(raw) / "one.txt"
        reg_one.write_text(f"{dash_step}\t2.1.278\tзуб З3: объявленное отсутствие\n",
                           encoding="utf-8")
        reg_two = Path(raw) / "two.txt"
        reg_two.write_text(f"{dash_step}\t2.1.278\tзуб З3: объявленное отсутствие\n"
                           f"{ghost_step}\t2.1.278\tзуб З3: строка не проведена\n",
                           encoding="utf-8")
        good = _run_step_gate(_STEP_CHECKS_TOOL, reg_one, map_path)
        good_out = (good.stdout or "") + (good.stderr or "")
        if good.returncode != 0:
            return f"объявленное отсутствие краснит гейт: rc={good.returncode} {good_out!r}"
        if _STEP_GATE_SUMMARY_MARK not in good_out:
            return f"гейт не печатает сводку проведённости: {good_out!r}"
        bad = _run_step_gate(_STEP_CHECKS_TOOL, reg_two, map_path)
        bad_out = (bad.stdout or "") + (bad.stderr or "")
        if bad.returncode != 3:
            return f"отсутствующая строка не краснит кодом 3: rc={bad.returncode} {bad_out!r}"
        if ghost_step not in bad_out:
            return f"отказ не называет непроведённый шаг: {bad_out!r}"
        good_line = next((ln for ln in good_out.splitlines()
                          if _STEP_GATE_SUMMARY_MARK in ln), "")
        bad_line = next((ln for ln in bad_out.splitlines()
                         if _STEP_GATE_REFUSAL_MARK in ln), "")
        if not good_line or not bad_line or good_line == bad_line:
            return (f"тексты исходов не попарно различны: {good_line!r} / "
                    f"{bad_line!r}")
        mut = Path(raw) / "step-checks-z3.py"
        # Окружение инструмента для мутированной копии -- см. зуб З1.
        shutil.copy2(ROOT / "tools" / "steps-off-registry.js",
                     Path(raw) / "steps-off-registry.js")
        mut.write_text(_once_replace(
            _STEP_CHECKS_TOOL.read_text(encoding="utf-8"),
            "if checks_field == '-':\n            checks = []",
            "if checks_field == '-':\n"
            "            raise StepChecksError('мутация З3: тире объявлено "
            "неразборчивым')",
            "зуб З3: тире объявлено неразборчивым"), encoding="utf-8")
        m = _run_step_gate(mut, reg_one, map_path)
        if m.returncode == 0:
            mout = (m.stdout or "") + (m.stderr or "")
            return f"мутация пережила зуб: тире всё ещё разбирается: {mout!r}"
    return None


def _tooth_step_checks_missing_map_refuses_as_instrument() -> str | None:
    """З4 (#403B): карты нет/пуста/из комментариев -- отказ прибора, код 2.

    Карта -- свойство КИТА (в отличие от реестра выключений): её пустота --
    потеря данных, а не решение оператора. Не код 3 и не молчание. Мутация:
    снятый отказ пустоты уводит исход в чужой класс 3.
    """
    if not _STEP_CHECKS_TOOL.is_file():
        return f"нет инструмента карты шагов: {_STEP_CHECKS_TOOL}"
    if not _STEP_CHECKS_MAP.is_file():
        return f"нет карты шагов: {_STEP_CHECKS_MAP}"
    with tempfile.TemporaryDirectory(prefix="checks-teeth-z4.") as raw:
        reg = Path(raw) / "our-steps-off.txt"
        reg.write_text(_STEP26_ROW + "\t2.1.278\tзуб З4: реестр при битой карте\n",
                       encoding="utf-8")
        cases = (
            ("карты нет", None),
            ("карта пуста", ""),
            ("карта из комментариев", "# только шапка\n\n# данных нет\n"),
        )
        for label, content in cases:
            map_path = Path(raw) / "our-step-checks.txt"
            if content is None:
                map_path.unlink(missing_ok=True)
            else:
                map_path.write_text(content, encoding="utf-8")
            r = _run_step_gate(_STEP_CHECKS_TOOL, reg, map_path)
            out = (r.stdout or "") + (r.stderr or "")
            if r.returncode != 2:
                return (f"{label}: ждали отказ прибора кодом 2, получили "
                        f"rc={r.returncode} {out!r}")
            if not out.strip():
                return f"{label}: отказ прибора молчит"
            if "ОТКАЗ ПРИБОРА" not in out:
                return f"{label}: отказ не назван приборным текстом: {out!r}"
        map_path = Path(raw) / "our-step-checks.txt"
        map_path.write_text("# только шапка\n", encoding="utf-8")
        mut = Path(raw) / "step-checks-z4.py"
        # Окружение инструмента для мутированной копии -- см. зуб З1.
        shutil.copy2(ROOT / "tools" / "steps-off-registry.js",
                     Path(raw) / "steps-off-registry.js")
        mut.write_text(_once_replace(
            _STEP_CHECKS_TOOL.read_text(encoding="utf-8"),
            "    if not rows:\n"
            "        raise StepChecksError(\n"
            "            f'карта шагов пуста или несёт только комментарии: {path} -- '\n"
            "            f'карта есть свойство кита, её пустота -- потеря данных')\n",
            "    if not rows:\n"
            "        pass  # мутация З4: пустая карта молча читается как ноль строк\n",
            "зуб З4: снятый отказ пустоты"), encoding="utf-8")
        m = _run_step_gate(mut, reg, map_path)
        if m.returncode == 2:
            mout = (m.stdout or "") + (m.stderr or "")
            return f"мутация пережила зуб: пустота всё ещё отказывает: {mout!r}"
    return None


def _tooth_step_checks_single_home() -> str | None:
    """З5 (#403B): имя и проверка шага 26 не объявляются литералами в конвейере.

    Значение приходит из модуля tools/step-checks.py по карте: вторая копия
    значения расходилась бы с картой молча. Зуб краснеет, если объявление
    вернулось; чувствительность детектора -- вживление объявления в копию
    текста; канал модуля -- отказ снимка кита без модуля (и отсутствие этого
    отказа, когда модуль на месте).
    """
    script = ROOT / "claude-patch-all.sh"
    if not script.is_file():
        return f"нет конвейера: {script}"
    if not _STEP_CHECKS_TOOL.is_file():
        return f"нет модуля карты: {_STEP_CHECKS_TOOL}"
    if not _STEP_CHECKS_MAP.is_file():
        return f"нет карты шагов: {_STEP_CHECKS_MAP}"
    text = script.read_text(encoding="utf-8")
    if _STEP26_DECL_RE.search(text):
        return ("в claude-patch-all.sh объявлен литерал _STEP26_NAME/"
                "_STEP26_CHECK -- значение обязано приходить из модуля карты")
    loader_anchor = "'tools', 'step-checks.py')"
    if loader_anchor not in text:
        return ("в claude-patch-all.sh нет загрузки модуля карты "
                "tools/step-checks.py -- значение не приходит из модуля")
    for probe in ("_STEP26_NAME = '26 зонд З5'\n",
                  "_STEP26_CHECK = 'зонд З5'\n"):
        if not _STEP26_DECL_RE.search(text + "\n" + probe):
            return f"детектор объявлений слеп к вживлению: {probe!r}"
    td, snap_script, snap_patch = _temp_kit()
    try:
        (td / "tools" / "step-checks.py").unlink()
        fake = td / "fake-image-z5.bin"
        fake.write_bytes(b"// Version: 2.1.278\n")
        r = _run_checks(snap_script, fake, snap_patch)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 2 or "step-checks.py" not in out:
            return (f"снимок без модуля карты не отказал его именем кодом 2: "
                    f"rc={r.returncode} {out!r}")
    finally:
        shutil.rmtree(td, ignore_errors=True)
    td, snap_script, snap_patch = _temp_kit()
    try:
        fake = td / "fake-image-z5.bin"
        fake.write_bytes(b"// Version: 2.1.278\n")
        r = _run_checks(snap_script, fake, snap_patch)
        out = (r.stdout or "") + (r.stderr or "")
        if "step-checks.py" in out:
            return (f"модуль на месте, а отказ с его именем есть: {out!r}")
    finally:
        shutil.rmtree(td, ignore_errors=True)
    return None


def _tooth_step7_teeth_off_by_registry_code5() -> str | None:
    """З6 (#403B): выключенный реестром шаг 7 -- код 5 стенда, ДО любой работы.

    Стенд шага 7 мерил СЫРОЙ патч и был слеп к реестру: выключив шаг 7,
    оператор получал зелёный стенд на шаге, которого в продукте нет --
    вакуумная зелень. Без записи реестра стенд кодом 5 НЕ выходит (идёт
    дальше и останавливается отсутствием патча в снимке -- код 2). Мутации:
    снятый выход кодом 5 и подменённый код.
    """
    stand_src = ROOT / "tools" / "step7-window-teeth.sh"
    module_src = ROOT / "tools" / "steps-off-registry.js"
    for path in (stand_src, module_src):
        if not path.is_file():
            return f"нет предмета зуба: {path}"
    step7 = "7 session memory"

    def _kit(registry_text: str) -> Path:
        raw = Path(tempfile.mkdtemp(prefix="checks-teeth-z6."))
        tools = raw / "tools"
        tools.mkdir()
        shutil.copy2(stand_src, tools / "step7-window-teeth.sh")
        shutil.copy2(module_src, tools / "steps-off-registry.js")
        (tools / "our-steps-off.txt").write_text(registry_text,
                                                 encoding="utf-8")
        return tools

    def _run(tools: Path):
        return subprocess.run(["bash", str(tools / "step7-window-teeth.sh")],
                              capture_output=True, text=True, errors="replace")

    off_text = f"{step7}\t2.1.278\tзуб З6: шаг выключен реестром\n"
    quiet_text = "# зуб З6: выключенных записей нет\n"
    tools = _kit(off_text)
    try:
        r = _run(tools)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 5 or _STEP7_OFF_MSG not in out:
            return (f"запись реестра не дала код 5 с его текстом: "
                    f"rc={r.returncode} {out!r}")
    finally:
        shutil.rmtree(tools.parent, ignore_errors=True)
    tools = _kit(quiet_text)
    try:
        r = _run(tools)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode == 5 or _STEP7_OFF_MSG in out:
            return (f"без записи реестра стенд вышел кодом 5: rc={r.returncode} "
                    f"{out!r}")
        if r.returncode != 2 or "tweakcc-patch.js" not in out:
            return (f"без записи реестра стенд не пошёл обычным путём "
                    f"(ждали отказ о патче, код 2): rc={r.returncode} {out!r}")
    finally:
        shutil.rmtree(tools.parent, ignore_errors=True)
    module_stand = stand_src.read_text(encoding="utf-8")
    for name, old, new in (
        ("снятый выход", "exit 5 ;;", ": ;;"),
        ("подменённый код", "exit 5 ;;", "exit 3 ;;"),
    ):
        tools = _kit(off_text)
        try:
            (tools / "step7-window-teeth.sh").write_text(
                _once_replace(module_stand, old, new, f"зуб З6: {name}"),
                encoding="utf-8")
            m = _run(tools)
            mout = (m.stdout or "") + (m.stderr or "")
            if m.returncode == 5 and _STEP7_OFF_MSG in mout:
                return f"мутация пережила зуб ({name}): {mout!r}"
        finally:
            shutil.rmtree(tools.parent, ignore_errors=True)
    return None


def _z7_caller_fragment(text: str) -> list:
    """case-блок вызывающего стенда 7; [] -- блок не найден."""
    lines = text.split("\n")
    start = next((i for i, ln in enumerate(lines)
                  if ln == _STEP7_CALLER_ANCHOR), -1)
    if start < 0:
        return []
    case = next((i for i in range(start, len(lines))
                 if lines[i] == "  case $__rc in"), -1)
    if case < 0:
        return []
    end = next((i for i in range(case + 1, len(lines))
                if lines[i] == "  esac"), -1)
    if end < 0:
        return []
    return lines[case:end + 1]


def _z7_run_fragment(fragment, rc_value: int):
    script = "__rc=%d\n%s\n" % (rc_value, "\n".join(fragment))
    return subprocess.run(["bash", "-c", script], capture_output=True,
                          text=True, errors="replace")


def _tooth_step7_caller_distinguishes_3_and_5() -> str | None:
    """З7 (#403B): ветки 3) и 5) вызывающего различны и не останавливают прогон.

    Код 3 -- дельта машины (окружение), код 5 -- решение реестра: владельцы
    разные, и слитые в один код или один текст исходы неразличимы. Обе ветки
    печатают и НЕ выходят. Мутации: снятая ветка 5) и слитый текст веток.
    """
    script = ROOT / "claude-patch-all.sh"
    if not script.is_file():
        return f"нет конвейера: {script}"
    frag = _z7_caller_fragment(script.read_text(encoding="utf-8"))
    if not frag:
        return "вызывающий блок step7-window-teeth не найден в claude-patch-all.sh"
    r3 = _z7_run_fragment(frag, 3)
    r5 = _z7_run_fragment(frag, 5)
    out3 = (r3.stdout or "") + (r3.stderr or "")
    out5 = (r5.stdout or "") + (r5.stderr or "")
    for label, proc, out in (("3", r3, out3), ("5", r5, out5)):
        if proc.returncode != 0:
            return (f"ветка {label}) останавливает прогон: "
                    f"rc={proc.returncode} {out!r}")
        if not out.strip():
            return f"ветка {label}) ничего не печатает"
    if out3 == out5:
        return f"ветки 3) и 5) печатают один текст: {out3!r}"
    if "предмета нет" not in out3 or "реестр" not in out5:
        return ("владельцы исходов не названы текстом: 3) обязан звать дельту "
                f"машины, 5) -- решение реестра: {out3!r} / {out5!r}")
    no5 = "\n".join(ln for ln in frag if not ln.lstrip().startswith("5)"))
    m = _z7_run_fragment(no5.split("\n"), 5)
    if m.returncode == 0:
        mout = (m.stdout or "") + (m.stderr or "")
        return f"мутация пережила зуб: снятая ветка 5) не остановила прогон: {mout!r}"
    merged = _once_replace("\n".join(frag),
                           "шаг 7 выключен реестром our-steps-off.txt (rc=5)",
                           "предмета нет на этой машине (rc=3)",
                           "зуб З7: слитый текст веток")
    a = _z7_run_fragment(merged.split("\n"), 3)
    b = _z7_run_fragment(merged.split("\n"), 5)
    a_out = (a.stdout or "") + (a.stderr or "")
    b_out = (b.stdout or "") + (b.stderr or "")
    if a_out != b_out:
        return (f"мутация пережила зуб: слитый текст не выровнял ветки: "
                f"{a_out!r} / {b_out!r}")
    return None


# --- зубы проекции базы корпусного стенда (#403C) ---------------------------

_CORPUS_TOOL = ROOT / "tools" / "checks-teeth-corpus.py"
_CORPUS_CONTROL_MARK = "КОНТРОЛЬ ПРОВАЛЕН"
# Фикстура карты: шаг 26 (его обработчик известен коду карты) проведён в
# проверку, ВХОДЯЩУЮ в двери корпусного стенда, -- проекции нужен именно
# такой шаг; живая пара «шаг 26 -> его проверка» в двери корпуса не входит.
_CORPUS_MAP_ROW = _STEP26_ROW + " | s26 | session memory forced on"
_CORPUS_OFF_REG = _STEP26_ROW + "\t2.1.278\tзуб 403C: проверка входит в двери корпуса\n"
_CORPUS_QUIET_REG = "# зуб 403C: выключенных записей нет\n"
_CORPUS_GHOST_STEP = "403C шаг без строки карты"
_CORPUS_DOOR = "session memory forced on"
# Маркеры констрейнта шапки corpus-прибора: конвейерное происхождение
# предмета и объявление команды сырого патча ручным воспроизведением.
_CORPUS_HEADER_MARKS = ("конвейером", "sweep.sh", "claude-patch-all.sh",
                        "ДРУГОЙ предмет")


def _load_corpus(mutator=None):
    """Модуль корпусного прибора: оригинал или копия с мутацией текста.

    ROOT/PATCH возвращаются дому кита: копия лежит вне дома, и её пути
    указывали бы в пустоту; предмет мутации -- поведение прибора, а не пути
    импорта копии. RUNNER остаётся за вызывающим (зубы подменяют его
    раннером-пустышкой).
    """
    src = _CORPUS_TOOL.read_text(encoding="utf-8")
    if mutator is not None:
        src = mutator(src)
    with tempfile.TemporaryDirectory(prefix="checks-teeth-corpus403c.") as raw:
        mod_path = Path(raw) / "checks-teeth-corpus-403c.py"
        mod_path.write_text(src, encoding="utf-8")
        spec = importlib.util.spec_from_file_location(
            "checks_teeth_corpus_403c", mod_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.ROOT = ROOT
        mod.PATCH = ROOT / "tweakcc-patch.js"
        return mod


def _fake_corpus_runner(lines) -> Path:
    """Раннер-пустышка: печатает названные строки -- управляемая база."""
    td = Path(tempfile.mkdtemp(prefix="checks-teeth-crun."))
    r = td / "runner.sh"
    body = "#!/bin/bash\n" + "".join(f"echo '  {ln}'\n" for ln in lines)
    r.write_text(body, encoding="utf-8")
    r.chmod(0o755)
    return r


def _corpus_fixtures(raw: Path, registry_text: str):
    reg = raw / "our-steps-off.txt"
    reg.write_text(registry_text, encoding="utf-8")
    map_path = raw / "our-step-checks.txt"
    map_path.write_text(_CORPUS_MAP_ROW + "\n", encoding="utf-8")
    return reg, map_path


def _corpus_probe(mod, registry_text: str, runner_lines) -> tuple:
    """(база проекции или текст отказа, rc run_one, вывод) на фикстурах."""
    with tempfile.TemporaryDirectory(prefix="checks-teeth-cprobe.") as raw:
        reg, map_path = _corpus_fixtures(Path(raw), registry_text)
        try:
            base = mod.base_projection(reg, map_path)
        except Exception as exc:                    # noqa: BLE001
            return f"::отказ:: {exc}", None, ""
        img = Path(raw) / "product.bin"
        img.write_bytes(b"// Version: 2.1.278\nstub\n")
        mod.RUNNER = _fake_corpus_runner(runner_lines)
        buf_out, buf_err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(buf_out), contextlib.redirect_stderr(buf_err):
            rc = mod.run_one(img, Path(raw), base)
        return base, rc, buf_out.getvalue() + buf_err.getvalue()


def _corpus_header_names_pipeline(doc) -> bool:
    """Констрейнт конвейерного происхождения в ШАПКЕ, структурно."""
    if not doc:
        return False
    return all(m in doc for m in _CORPUS_HEADER_MARKS)


def _tooth_corpus_base_is_projection() -> str | None:
    """З1 (#403C): выключенный шаг с проверкой в дверях корпуса -- база НЕ пуста.

    База корпусного прибора -- проекция реестра выключений, а не константа:
    боевой продукт собирается конвейером с подстановкой реестра, и база,
    совпавшая с проекцией, не имеет права читаться отказом «КОНТРОЛЬ
    ПРОВАЛЕН». Мутация возвращает константой пустое множество -- объявленная
    дельта снова отказала бы прибором (класс #382/#383, #400).
    """
    mod = _load_corpus()
    base, rc, out = _corpus_probe(mod, _CORPUS_OFF_REG, [f"[FAIL] {_CORPUS_DOOR}"])
    if isinstance(base, str):
        return f"проекция отказала на проведённом шаге: {base}"
    if base != {_CORPUS_DOOR}:
        return f"ожидаемая база не совпала с проекцией: {sorted(base)!r}"
    if _CORPUS_CONTROL_MARK in out:
        return "база совпала с проекцией, а прибор напечатал КОНТРОЛЬ ПРОВАЛЕН"
    if rc == 2:
        return f"база совпала, а прибор ответил кодом 2: rc={rc}"
    try:
        mut = _load_corpus(lambda t: _once_replace(
            t, "    return base\n", "    return set()\n", "зуб З1: проекция"))
    except Exception as exc:                        # noqa: BLE001
        return f"мутант не строится: {exc}"
    mbase, mrc, mout = _corpus_probe(mut, _CORPUS_OFF_REG,
                                     [f"[FAIL] {_CORPUS_DOOR}"])
    if isinstance(mbase, str):
        return f"мутант отказал вместо пустой базы: {mbase}"
    if mbase != set():
        return f"мутация не погасила проекцию: {sorted(mbase)!r}"
    if _CORPUS_CONTROL_MARK not in mout or mrc != 2:
        return (f"мутация не обратила исход: КОНТРОЛЬ ПРОВАЛЕН обязан "
                f"прозвучать на объявленной дельте: rc={mrc}")
    return None


def _tooth_corpus_base_empty_when_nothing_off() -> str | None:
    """З2 (#403C): пустой реестр -- база пуста, прибор зелен.

    Зуб «вне области отказа НЕТ»: без выключенных записей контроль не
    отказывает и не краснит. Мутация отказывает на нуле записей -- норма
    читалась бы поломкой прибора.
    """
    mod = _load_corpus()
    base, rc, out = _corpus_probe(mod, _CORPUS_QUIET_REG, ["[OK] anything"])
    if isinstance(base, str):
        return f"пустой реестр отказал: {base}"
    if base != set():
        return f"пустой реестр дал непустую базу: {sorted(base)!r}"
    if _CORPUS_CONTROL_MARK in out or rc == 2:
        return "пустая база без красных прочиталась отказом контроля"
    try:
        mut = _load_corpus(lambda t: _once_replace(
            t,
            "        names = module._read_registry_names(reg)\n",
            "        names = module._read_registry_names(reg)\n"
            "        if not names:\n"
            "            raise CorpusRefusal('мутация З2: пустой реестр -- отказ')\n",
            "зуб З2: отказ на нуле записей"))
    except Exception as exc:                        # noqa: BLE001
        return f"мутант не строится: {exc}"
    try:
        with tempfile.TemporaryDirectory(prefix="checks-teeth-z2m.") as raw:
            reg, map_path = _corpus_fixtures(Path(raw), _CORPUS_QUIET_REG)
            mut.base_projection(reg, map_path)
    except Exception:                               # noqa: BLE001
        return None
    return "мутация пережила зуб: пустой реестр не отказал"


def _tooth_corpus_unmapped_step_refuses() -> str | None:
    """З3 (#403C): выключенный шаг без строки карты -- ОТКАЗ ПРИБОРА.

    Отказ называет шаг по имени; НЕ пустая база и НЕ молчание. Мутация
    глотает непроведённый шаг молчаливым пропуском -- отказ исчезает, зуб
    краснеет.
    """
    ghost_reg = f"{_CORPUS_GHOST_STEP}\t2.1.278\tзуб З3: строка не проведена\n"
    mod = _load_corpus()
    with tempfile.TemporaryDirectory(prefix="checks-teeth-z3c.") as raw:
        reg, map_path = _corpus_fixtures(Path(raw), ghost_reg)
        try:
            base = mod.base_projection(reg, map_path)
        except Exception as exc:                    # noqa: BLE001
            text = str(exc)
            if _CORPUS_GHOST_STEP not in text:
                return f"отказ не назвал шаг по имени: {exc}"
            if "не проведён" not in text and "карту" not in text:
                return f"отказ не назвал требуемое действие: {exc}"
        else:
            return f"непроведённый шаг не отказал: база {sorted(base)!r}"
    try:
        mut = _load_corpus(_corpus_unmapped_mutator)
    except Exception as exc:                        # noqa: BLE001
        return f"мутант не строится: {exc}"
    with tempfile.TemporaryDirectory(prefix="checks-teeth-z3m.") as raw:
        reg, map_path = _corpus_fixtures(Path(raw), ghost_reg)
        try:
            base = mut.base_projection(reg, map_path)
        except Exception:                           # noqa: BLE001
            return "мутация не сняла отказ непроведённого шага"
        if base != set():
            return f"мутант построил базу из непроведённого шага: {sorted(base)!r}"
    return None


def _corpus_unmapped_mutator(text: str) -> str:
    """Мутация З3: непроведённый шаг глотается молчаливым пропуском."""
    return _once_replace(
        text,
        "        if name not in rows:\n"
        "            raise CorpusRefusal(\n"
        "                f'шаг {name!r} выключен реестром {reg}, но не проведён в '\n"
        "                f'карту {mpath} -- ожидаемая база не строится')\n",
        "        if name not in rows:\n"
        "            continue\n",
        "зуб З3: молчаливый пропуск")


def _tooth_corpus_header_names_pipeline_subject() -> str | None:
    """З4 (#403C): шапка corpus-прибора несёт констрейнт конвейерного предмета.

    Боевой предмет собирается конвейером (sweep.sh -> claude-patch-all.sh
    --target), а показанная команда сырого патча объявлена ручным
    воспроизведением ДРУГОГО предмета. Текст ищется в docstring --
    структурно, не по номеру строки. Мутация вырезает строки констрейнта --
    детектор обязан потерять их.
    """
    mod = _load_corpus()
    if not _corpus_header_names_pipeline(mod.__doc__):
        return "шапка corpus-прибора не несёт констрейнт о конвейерном предмете"
    src = _CORPUS_TOOL.read_text(encoding="utf-8")
    stripped = "\n".join(
        ln for ln in src.split("\n")
        if not any(m in ln for m in _CORPUS_HEADER_MARKS))
    try:
        mut = _load_corpus(lambda _t, _s=stripped: _s)
    except Exception as exc:                        # noqa: BLE001
        return f"мутант не строится: {exc}"
    if _corpus_header_names_pipeline(mut.__doc__):
        return "мутация вырезала констрейнт, а детектор его всё ещё видит"
    return None


# Якорь мутации З5: поиск пары «версия × шаг» в _step26_verdict (гашение
# второй причины -- исходный дефект Д4: причина неприменимости пропадала
# молча). Якорь мутации З6: прикрепление причины безусловно -- без пары.
_INAPP_PAIR_ANCHOR = "            (img_raw, step_no))"
_INAPP_PAIR_REPL = "            (img_raw, '403C-no-such-step'))"
_INAPP_ATTACH_ANCHOR = "    _inapp = (img_raw, _hit[1]) if _hit else None\n"
_INAPP_ATTACH_ALWAYS = (
    "    _inapp = (img_raw, 'мутация З6') if _hit else (img_raw, 'мутация З6')\n"
)
# Якорь мутации З5 (перевёрнутый порядок причин): литерал формата.
_BOTH_CAUSES_FMT_ANCHOR = (
    "_NOTE_BOTH_CAUSES_FMT = (\"шаг {name}: выключен реестром ({reason}); \"\n"
    "                         \"предмета нет в {ver} ({basis})\")\n"
)
_BOTH_CAUSES_ORDER_REPL = (
    "_NOTE_BOTH_CAUSES_FMT = (\"шаг {name}: предмета нет в {ver} ({basis}); \"\n"
    "                         \"выключен реестром ({reason})\")\n"
)
_S26_DECL_EXTRA = "2.1.278\t26\tзуб З5 403C: предмет шага 26 вырезан апстримом\n"
_BOTH_INAPP_MARK = "предмета нет в 2.1.278"
_BOTH_OFF_MARK = "выключен реестром"


def _decl_with_26(text: str) -> str:
    if not text.endswith("\n"):
        text += "\n"
    return text + _S26_DECL_EXTRA


def _both_causes_line(out: str) -> str:
    for line in out.splitlines():
        if _BOTH_INAPP_MARK in line:
            return line.strip()
    return ""


def _tooth_both_registries_name_both_causes() -> str | None:
    """З5 (#403C): шаг в ОБОИХ реестрах -- ОБЕ причины одной строкой.

    Порядок фиксирован: сперва выключение (решение наше), затем
    неприменимость (факт апстрима). Мутации: погашенный поиск пары (вторая
    причина пропадает молча -- дефект Д4) и перевёрнутый порядок.
    """
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина 2.1.278: {PRISTINE_LATEST}"
    decl = _decl_with_26(_kit_decl_text())
    with _carrier_pins({"CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1",
                        "CLAUDE_JUDGE_CARRIER": "mod", "CLAUDE_JUDGE": "1"}):
        td, script, patch = _temp_kit(decl_text=decl)
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if _NOTE_OFF_MARK not in out:
                return f"контроль: NOTE выключения не напечатан: {out[-300:]!r}"
            line = _both_causes_line(out)
            if not line:
                return "контроль: строка обеих причин отсутствует"
            if _STEP26_ROW not in line:
                return f"контроль: строка причин не назвала шаг: {line!r}"
            if "зуб З5 403C" not in line:
                return f"контроль: строка причин не несёт основание декларации: {line!r}"
            if line.index(_BOTH_OFF_MARK) > line.index(_BOTH_INAPP_MARK):
                return f"контроль: порядок причин перевёрнут: {line!r}"
        finally:
            shutil.rmtree(td, ignore_errors=True)
        try:
            td, script, patch = _temp_kit(
                decl_text=decl,
                script_repl=(_INAPP_PAIR_ANCHOR, _INAPP_PAIR_REPL))
        except Exception as exc:                    # noqa: BLE001
            return f"мутант пары не строится: {exc}"
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if _both_causes_line(out):
                return "мутация пережила зуб: пара погашена, а обе причины печатаются"
        finally:
            shutil.rmtree(td, ignore_errors=True)
        try:
            td, script, patch = _temp_kit(
                decl_text=decl,
                script_repl=(_BOTH_CAUSES_FMT_ANCHOR, _BOTH_CAUSES_ORDER_REPL))
        except Exception as exc:                    # noqa: BLE001
            return f"мутант порядка не строится: {exc}"
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            line = _both_causes_line(out)
            if not line:
                return "мутация переворота не напечатала строку причин"
            if line.index(_BOTH_OFF_MARK) < line.index(_BOTH_INAPP_MARK):
                return f"мутация пережила зуб: порядок не перевёрнут: {line!r}"
        finally:
            shutil.rmtree(td, ignore_errors=True)
    return None


def _tooth_single_registry_names_one_cause() -> str | None:
    """З6 (#403C): шаг только в реестре выключений -- ровно ОДНА причина.

    Тексты исходов «одна причина» и «обе причины» попарно различимы.
    Мутация прикрепляет вторую причину без пары декларации -- исход одной
    причины получает текст второй, зуб краснеет.
    """
    if not PRISTINE_LATEST.is_file():
        return f"нет пристина 2.1.278: {PRISTINE_LATEST}"
    pins = {"CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1",
            "CLAUDE_JUDGE_CARRIER": "mod", "CLAUDE_JUDGE": "1"}
    with _carrier_pins(pins):
        td, script, patch = _temp_kit()
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if _NOTE_OFF_MARK not in out:
                return "контроль: NOTE выключения не напечатан"
            if _both_causes_line(out):
                return "контроль: без пары в декларации напечатаны ОБЕ причины"
            one_line = _step26_note_line(out)
        finally:
            shutil.rmtree(td, ignore_errors=True)
        td, script, patch = _temp_kit(decl_text=_decl_with_26(_kit_decl_text()))
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            both_line = _both_causes_line(out)
            if not both_line:
                return "контроль: строка обеих причин не напечатана"
        finally:
            shutil.rmtree(td, ignore_errors=True)
        if not one_line:
            return "контроль: NOTE-строка одной причины не найдена"
        if one_line == both_line:
            return "тексты исходов «одна причина» и «обе причины» неразличимы"
        if _BOTH_INAPP_MARK in one_line:
            return "строка одной причины несёт текст второй"
        try:
            td, script, patch = _temp_kit(
                script_repl=(_INAPP_ATTACH_ANCHOR, _INAPP_ATTACH_ALWAYS))
        except Exception as exc:                    # noqa: BLE001
            return f"мутант прикрепления не строится: {exc}"
        try:
            r = _run_checks(script, PRISTINE_LATEST, patch)
            out = (r.stdout or "") + (r.stderr or "")
            if not _both_causes_line(out):
                return "мутация пережила зуб: причина не прикрепилась без пары"
        finally:
            shutil.rmtree(td, ignore_errors=True)
    return None


# --- зубы порядка фаз входа и мутаций (docnum:other -- #408 есть номер
# задачи, не счёт стенда) ----------------------------------------------------
#
# Предмет -- порядок фаз в main(): красный вход не имеет права отменять
# мутационную фазу, а «фаза не измерена» -- читаться как её нулевой итог.

# Якорь цикла входа ДВУХСТРОЧНЫЙ: одиночная строка «reason = fn()» есть и в
# self_check. Литерал якоря собирается конкатенацией: целиком в теле зуба он
# дал бы второе вхождение в снимок, и _once_replace отказал бы на снимке,
# а не на предмете зуба.
_PHASES_ENTRY_CALL = ("    for name, fn in entry_teeth:\n"
                      "        reason = " + "fn()")
_PHASES_SUMMARY_PREFIX = "checks-teeth: ИТОГ мутаций="
_PHASES_UNMEASURED_PREFIX = _PHASES_SUMMARY_PREFIX + "НЕ ИЗМЕРЕНО -- "
_PHASES_RUNNER_WHY = "нет tools/checks-on-image.sh -- мерить нечем"


def _phases_kit(entry_new: str,
                extra: tuple[tuple[str, str, str], ...] = ()):
    """Снимок кита для зубов порядка фаз: копия прибора в <td>/tools/.

    Мутация цикла входа подменяет ВЫЗОВ зуба управляемым исходом: прогон
    снимка не зависит от состояния машины (живой образ, пристин, реестры
    дома). Раннера в снимок НЕ кладём -- мутационной фазе снимка мерить
    нечем, и прогон обязан дойти до итога фазы, а не до мутаций. extra --
    дополнительные точечные мутации снимка (тройки old/new/что).
    """
    td = Path(tempfile.mkdtemp(prefix="checks-teeth-phases408."))
    tools = td / "tools"
    tools.mkdir()
    src = Path(__file__).read_text(encoding="utf-8")
    src = _once_replace(src, _PHASES_ENTRY_CALL, entry_new,
                        "зуб #408: исход цикла входа")
    for old, new, what in extra:
        src = _once_replace(src, old, new, what)
    copy = tools / "checks-teeth.py"
    copy.write_text(src, encoding="utf-8")
    return td, copy


def _phases_run(copy: Path) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(copy)],
                          capture_output=True, text=True, errors="replace")


def _tooth_phases_entry_red_keeps_mutation_summary() -> str | None:
    """Красный вход обязан оставить итогу мутационной фазы место (#408).

    Ранний возврат по entry_bad отменял мутационную фазу ЦЕЛИКОМ: при живых
    входных красных объявленные мутации не исполнялись ни разу, и ПУСТО в
    логе было неотличимо от НОЛЯ. Снимок делает РОВНО ОДИН входной зуб
    красным (мутация цикла входа снимка -- дом не трогается); прогон обязан
    напечатать итог мутационной фазы и вернуть 1: дефект входа приоритетнее
    «не измерено». Приманка возвращает ранний возврат -- итог фазы исчезает.
    """
    red_call = ("    for name, fn in entry_teeth:\n"
                '        reason = ("мутация снимка: единственный красный вход"\n'
                '                  if name == "single-registry-names-one-cause" '
                "else None)")
    td, copy = _phases_kit(red_call)
    try:
        r = _phases_run(copy)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 1:
            return (f"красный вход обязан давать код 1 -- дефект выше «не "
                    f"измерено»: rc={r.returncode} {out!r}")
        if "ИТОГ вход=" not in out or "молча/неверно=1" not in out:
            return f"входной итог не «ровно один красный»: {out!r}"
        if _PHASES_SUMMARY_PREFIX not in out:
            return f"итог мутационной фазы исчез при красном входе: {out!r}"
        if _PHASES_UNMEASURED_PREFIX not in out:
            return (f"фаза без раннера обязана зваться НЕ ИЗМЕРЕНО, а не "
                    f"нулём измеренных: {out!r}")
    finally:
        shutil.rmtree(td, ignore_errors=True)
    bait_old = "    if not RUN" + "NER.is_file():"
    bait_new = "    if entry_bad:\n        return 1\n" + bait_old
    td, copy = _phases_kit(red_call, ((bait_old, bait_new,
                                      "зуб #408: возвращённый ранний возврат"),))
    try:
        m = _phases_run(copy)
        mout = (m.stdout or "") + (m.stderr or "")
        if _PHASES_SUMMARY_PREFIX in mout:
            return (f"мутация пережила зуб: ранний возврат не снял итог "
                    f"фазы: {mout!r}")
    finally:
        shutil.rmtree(td, ignore_errors=True)
    return None


def _tooth_phases_unmeasured_mutation_is_not_zero() -> str | None:
    """«Не измерено» и «ноль измеренных» -- РАЗНЫЕ строки итога фазы (#408).

    Фазе без раннера мерить нечем: её итог обязан печататься строкой
    НЕ ИЗМЕРЕНО с той же причиной, что у отказа в stderr, и НЕ обязан
    печатать нулевую форму измеренной фазы. Приманка сливает исходы в
    нулевую форму -- зуб обязан это поймать.
    """
    green_call = ("    for name, fn in entry_teeth:\n"
                  "        reason = " + "None")
    td, copy = _phases_kit(green_call)
    try:
        r = _phases_run(copy)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 6:
            return (f"зелёный вход без раннера обязан давать код 6: "
                    f"rc={r.returncode} {out!r}")
        if "ИТОГ вход=" not in out or "молча/неверно=0" not in out:
            return f"входной итог не зелёный: {out!r}"
        want = _PHASES_UNMEASURED_PREFIX + _PHASES_RUNNER_WHY
        if want not in out:
            return f"нет строки «{want}»: {out!r}"
        if summary_line(0, 0) in out:
            return (f"нулевая форма измеренной фазы напечатана без "
                    f"измерения: {out!r}")
        if want == summary_line(0, 0):
            return "исходы «не измерено» и «ноль измеренных» текстуально слиты"
    finally:
        shutil.rmtree(td, ignore_errors=True)
    collapse_old = ('    return f"checks-teeth: ИТОГ мутаций=НЕ ИЗМЕРЕ'
                    'НО -- {reason}"')
    collapse_new = ('    return "checks-teeth: ИТОГ мутаций=0 прошло '
                    'молча/чужой дверью=0"')
    td, copy = _phases_kit(
        green_call, ((collapse_old, collapse_new,
                      "зуб #408: слитые исходы фазы"),))
    try:
        m = _phases_run(copy)
        mout = (m.stdout or "") + (m.stderr or "")
        # Приманка обязана ПОСТРОИТЬ слитую форму: такой вывод ловится
        # сценарием выше (нулевая форма без измерения), -- это и есть
        # доказательство не-вакуумности. НЕ ИЗМЕРЕНО в выводе приманки --
        # якорь приманки мёртв, зуб перестал мерить.
        if _PHASES_UNMEASURED_PREFIX in mout or summary_line(0, 0) not in mout:
            return (f"приманка не слила исходы -- якорь устарел, зуб мёртв: "
                    f"{mout!r}")
    finally:
        shutil.rmtree(td, ignore_errors=True)
    return None


# --- зубы границы свёртки выходов фаз (docnum:other -- #407 и Р6 есть номер
# задачи и решение её брифа, не счёт зубов) ------------------------------------
#
# Предмет -- приоритет кодов ПОСЛЕ итога входа: отказ прибора (2) не имеет
# права маскировать красный вход, а расхождение набора с пином (4) доминирует
# над обоими -- и это ОБЪЯВЛЕННАЯ граница _phase_exit, не побочный голый код.
_PHASE_EXIT_BOUNDARY = "    if code == 4 or fx_code == 4:\n        return 4\n"
_PHASES407_STUB_RUNNER = "# stub: достаточно существования двери раннера\n"
# Якорь пина мутаций собирается конкатенацией: цельный литерал в теле зуба
# дал бы третье вхождение в снимок (определение + два кита зуба), и
# _once_replace отказал бы на снимке, а не на предмете зуба.
# CONSTRAINT: якорь ВЫВОДИТСЯ из живого значения счётчика, а не пинит его
# копию литералом: пин чужого счётчика превращается в мину -- при законном
# росте таблицы якорь перестаёт находиться и зуб обезоруживается молча
# (класс #380, девятое попадание; найдено при адъюдикации 13 -> 20).
_PHASES407_PIN_OLD = "EXPECTED_MUTATIONS = " + str(EXPECTED_MUTATIONS)
_PHASES407_PIN_NEW = "EXPECTED_MUTATIONS = " + str(EXPECTED_MUTATIONS - 1)
_PHASES407_RED_CALL = (
    "    for name, fn in entry_teeth:\n"
    '        reason = ("мутация снимка: единственный красный вход"\n'
    '                  if name == "single-registry-names-one-cause" '
    "else None)")
# Якорь свёртки для приманки зуба refusal-does-not-mask-entry: код 2
# возвращается к голому выходу -- красный вход снова маскируется.
_PHASES407_BAIT_UNMASK_2 = ("    if code == 4 or fx_code == 4:\n        return 4\n",
                            "    if code in (2, 4):\n        return code\n")
# Якорь свёртки для приманки зуба pin-mismatch-outranks-entry: код 4
# сворачивается в приоритет входа -- недоверенная опись уехала бы под дефект.
_PHASES407_BAIT_COLLAPSE_4 = ("    if code == 4 or fx_code == 4:\n        return 4\n",
                              "    if False:\n        return 4\n")


def _phases407_kit(entry_new: str,
                   extra: tuple[tuple[str, str, str], ...] = (),
                   *, with_script: bool = False):
    """Снимок прибора для зубов Р6: копия в <td>/tools/ + заглушка раннера.

    Заглушка раннера проводит снимок до точек выхода мутационной фазы, не
    давая ей мерить; реальная таблица копируется целиком -- точки выхода
    стоят после её чтения. with_script добавляет конвейер и дом правила
    heredoc: двери реестра полей нужен AST исходника. CONSTRAINT: снимок не
    читает живой образ (--image указывает на заглушку) и не занимает замок
    конвейера (личный CLAUDE_PATCH_LOCK) -- контракт входной фазы цел.
    """
    td, copy = _phases_kit(entry_new, extra)
    tools = td / "tools"
    (tools / "checks-on-image.sh").write_text(_PHASES407_STUB_RUNNER,
                                              encoding="utf-8")
    shutil.copy2(TABLE, tools / "checks-mutations.tsv")
    if with_script:
        shutil.copy2(ROOT / "claude-patch-all.sh", td / "claude-patch-all.sh")
        shutil.copy2(ROOT / "tools" / "heredoc-anchor.py",
                     tools / "heredoc-anchor.py")
        # CONSTRAINT: дверь реестра полей резолвит ключ через канал карты --
        # модуль разбора и сама карта обязаны ехать в снимок, иначе дверь
        # отказывает прибором ДО точки выхода, которую меряет зуб.
        shutil.copy2(ROOT / "tools" / "step-checks.py", tools / "step-checks.py")
        shutil.copy2(ROOT / "tools" / "our-step-checks.txt",
                     tools / "our-step-checks.txt")
    return td, copy


def _phases407_run(copy: Path, td: Path,
                   *extra_args: str) -> subprocess.CompletedProcess:
    stub = Path(td) / "stub-image"
    stub.write_bytes(b"stub\n")
    env = dict(os.environ)
    env["CLAUDE_PATCH_LOCK"] = str(Path(td) / "private.lock")
    return subprocess.run(
        [sys.executable, str(copy), "--image", str(stub), *extra_args],
        capture_output=True, text=True, errors="replace", env=env)


def _tooth_phases_refusal_does_not_mask_entry() -> str | None:
    """Отказ прибора (2) после итога входа не маскирует красный вход (Р6 #407).

    Снимок с единственным красным входом и отказом разбора --id обязан дать
    rc=1 (найденный дефект важнее «не измерено»), а причина отказа --
    остаться напечатанной. Приманка возвращает коду 2 голый выход -- вход
    снова маскируется, зуб краснеет.
    """
    td, copy = _phases407_kit(_PHASES407_RED_CALL)
    try:
        r = _phases407_run(copy, td, "--id", "ZZZ")
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 1:
            return (f"красный вход + отказ прибора обязан давать rc=1: "
                    f"rc={r.returncode} {out!r}")
        if "ОТКАЗ ПРИБОРА" not in out or "нет таких строк" not in out:
            return f"причина отказа не напечатана: {out!r}"
        if "ИТОГ вход=" not in out or "молча/неверно=1" not in out:
            return f"входной итог не «ровно один красный»: {out!r}"
    finally:
        shutil.rmtree(td, ignore_errors=True)
    td, copy = _phases407_kit(
        _PHASES407_RED_CALL,
        ((_PHASES407_BAIT_UNMASK_2[0], _PHASES407_BAIT_UNMASK_2[1],
          "зуб Р6: код 2 снова не сворачивается"),))
    try:
        m = _phases407_run(copy, td, "--id", "ZZZ")
        mout = (m.stdout or "") + (m.stderr or "")
        # Приманка обязана ВОССТАНОВИТЬ маскирование (голый код 2) -- этот
        # исход ловится сценарием выше; иное значит, что якорь приманки мёртв.
        if m.returncode != 2:
            return (f"приманка не вернула голый код 2 -- якорь устарел, "
                    f"зуб мёртв: rc={m.returncode} {mout!r}")
    finally:
        shutil.rmtree(td, ignore_errors=True)
    return None


def _tooth_phases_pin_mismatch_outranks_entry() -> str | None:
    """Расхождение набора с пином (4) доминирует над красным входом (Р6 #407).

    Красный вход + разошедшийся пин мутаций даёт rc=4 (docnum:other -- код
    возврата прибора, не счёт стенда), а поведение
    -- быть ОБЪЯВЛЕННОЙ границей _phase_exit («код 4 не сворачивается»), не
    побочным голым выходом: зуб проверяет и поведение, и присутствие границы
    в коде прибора. Приманка сворачивает и код 4 -- rc падает до 1, зуб
    краснеет.
    """
    own = Path(__file__).read_text(encoding="utf-8")
    if own.count(_PHASE_EXIT_BOUNDARY) != 1:
        return ("граница «код 4 не сворачивается» не объявлена в коде "
                "прибора -- доминирование пина побочно")
    td, copy = _phases407_kit(
        _PHASES407_RED_CALL,
        ((_PHASES407_PIN_OLD, _PHASES407_PIN_NEW,
          "зуб Р6: пин мутаций разошёлся"),),
        with_script=True)
    try:
        r = _phases407_run(copy, td)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 4:
            return (f"красный вход + расхождение пина обязаны давать rc=4: "
                    f"rc={r.returncode} {out!r}")
        if "ОТКАЗ -- мутаций" not in out or "объявлено 12" not in out:
            return f"причина расхождения пина не напечатана: {out!r}"
        if "ИТОГ вход=" not in out or "молча/неверно=1" not in out:
            return f"входной итог не «ровно один красный»: {out!r}"
    finally:
        shutil.rmtree(td, ignore_errors=True)
    td, copy = _phases407_kit(
        _PHASES407_RED_CALL,
        ((_PHASES407_PIN_OLD, _PHASES407_PIN_NEW,
          "зуб Р6: пин мутаций разошёлся"),
         (_PHASES407_BAIT_COLLAPSE_4[0], _PHASES407_BAIT_COLLAPSE_4[1],
          "зуб Р6: код 4 свёрнут в приоритет входа")),
        with_script=True)
    try:
        m = _phases407_run(copy, td)
        mout = (m.stdout or "") + (m.stderr or "")
        if m.returncode != 1:
            return (f"приманка не свернула код 4 в приоритет входа -- якорь "
                    f"устарел, зуб мёртв: rc={m.returncode} {mout!r}")
    finally:
        shutil.rmtree(td, ignore_errors=True)
    return None


_FX407_GREEN_CALL = ("    for name, fn in entry_teeth:\n"
                     "        reason = None  # зуб Р1: зелёный вход")
_FX407_FX_ONE = ("    fx_code = _fixture_" + "phase(entry_bad)\n",
                 "    fx_code = 1  # мутация снимка: фаза фикстуры нашла дефект\n",
                 "зуб Р1: фаза фикстуры нашла дефект")


def _tooth_phases_fx_defect_outranks_early_unmeasured() -> str | None:
    """Дефект фазы фикстуры выше «НЕ ИЗМЕРЕНО» ранних выходов (Р1 fix-волны #407).

    Три ранних выхода мутационной фазы -- отказ реестра из reds, провал
    контроля красноты, смерть воркера -- возвращали _phase_exit(2, entry_bad)
    мимо fx_code, и потребитель печатал «НЕ ИЗМЕРЕНЫ» поверх НАЙДЕННОГО
    дефекта. Для КАЖДОГО пути: при fx_code=1 итог обязан быть 1. Приманка
    возвращает на пути прежнюю форму без fx_code -- код обязан упасть до 2:
    приманка, не меняющая код, означает, что путь живёт мимо правила.
    """
    def _run_kit(extra_pairs, runner_text=None):
        td, copy = _phases407_kit(_FX407_GREEN_CALL, tuple(extra_pairs),
                                  with_script=True)
        if runner_text is not None:
            (td / "tools" / "checks-on-image.sh").write_text(
                runner_text, encoding="utf-8")
        try:
            r = _phases407_run(copy, td)
            return r.returncode, (r.stdout or "") + (r.stderr or "")
        finally:
            shutil.rmtree(td, ignore_errors=True)

    c_setup = ("    jobs, inapp_rows, inapplicable_by_version, refused = "
               "build_jobs(rows, picked, image, base)\n",
               "    jobs, inapp_rows, inapplicable_by_version, refused = "
               "[(\"<probe>\", \"c\", str(image), [(0, b\"x\")], [\"c\"])], "
               "[], [], []\n",
               "зуб Р1: управляемое задание воркера")
    c_raise = ("        if jobs:\n",
               "        if jobs:\n"
               "            raise BrokenProcessPool(\"мутация снимка: "
               "воркер умер\")\n",
               "зуб Р1: смерть воркера")
    cases = (
        ("отказ-реестра", None, "реестр не назвал ни одной проверки",
         ("        except Refusal as exc:\n"
          "            print(f\"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}\", "
          "file=sys.stderr)\n"
          "            return _phase_exit(2, entry_bad, fx_code)\n",
          "        except Refusal as exc:\n"
          "            print(f\"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}\", "
          "file=sys.stderr)\n"
          "            return _phase_exit(2, entry_bad)\n",
          "зуб Р1: приманка на пути отказа реестра")),
        ("контроль-провален", "#!/bin/bash\necho '[FAIL] probe-red'\n",
         "КОНТРОЛЬ ПРОВАЛЕН",
         ("            for name in red:\n"
          "                print(\"    \" + name, file=sys.stderr)\n"
          "            return _phase_exit(2, entry_bad, fx_code)\n",
          "            for name in red:\n"
          "                print(\"    \" + name, file=sys.stderr)\n"
          "            return _phase_exit(2, entry_bad)\n",
          "зуб Р1: приманка на пути контроля красноты")),
        ("воркер-умер", "#!/bin/bash\necho '[OK] probe-green'\n",
         "воркер умер",
         # Якорь -- ТОЛЬКО строка возврата (собирается конкатенацией: цельный
         # литерал стал бы вторым вхождением для зуба Ф1 fix-волны #407,
         # приманивающего ту же строку): констрейнт-комментарий у пути смерти
         # не часть якоря -- приманка меняет одну переменную, свёртку.
         ("        return _phase_" + "exit(1 if bad else (9 if refused "
          "else 2), entry_bad, fx_code)\n",
          "        return _phase_" + "exit(2, entry_bad)\n",
          "зуб Р1: приманка на пути смерти воркера")),
    )
    for label, runner, marker, bait in cases:
        extra = [_FX407_FX_ONE]
        if label == "воркер-умер":
            extra += [c_setup, c_raise]
        rc, out = _run_kit(extra, runner)
        if rc != 1:
            return (f"путь {label}: при fx_code=1 итог обязан быть 1, "
                    f"получили rc={rc}: {out!r}")
        if marker not in out:
            return f"путь {label}: маркер пути не напечатан: {out!r}"
        rc2, out2 = _run_kit(extra + [bait], runner)
        if rc2 != 2:
            return (f"приманка на пути {label} обязана вернуть голую двойку "
                    f"(мутация пережила зуб): rc={rc2} {out2!r}")
    return None


def _tooth_phases_fixture_line_on_early_refusal() -> str | None:
    """Ранний отказ строк печатает строку фазы фикстуры (Р9 fix-волны #407).

    Ранние отказы выбора строк возвращали _phase_exit без строки фазы --
    молчание фазы читалось бы как её зелёный ноль (класс #396). Зуб гоняет
    снимок с несуществующим --id: строка «ФАЗА НЕ ЗАПУСКАЛАСЬ» с причиной
    обязана присутствовать. Приманка снимает печать -- зуб обязан это ловить.
    """
    td, copy = _phases407_kit(_FX407_GREEN_CALL)
    try:
        r = _phases407_run(copy, td, "--id", "ZZZ")
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 2:
            return (f"несуществующий --id обязан давать rc=2: "
                    f"rc={r.returncode} {out!r}")
        if "ИТОГ фикстур=ФАЗА НЕ ЗАПУСКАЛАСЬ" not in out:
            return f"строка фазы не напечатана при раннем отказе строк: {out!r}"
        if "нет таких строк" not in out:
            return f"причина раннего отказа не названа: {out!r}"
    finally:
        shutil.rmtree(td, ignore_errors=True)
    bait = ("        picked = pick_ids(opts.id, {r[\"id\"] for r in rows})\n"
            "    except Refusal as exc:\n"
            "        print(f\"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}\", "
            "file=sys.stderr)\n"
            "        print(_fixture_not_started_line(str(exc)), flush=True)\n",
            "        picked = pick_ids(opts.id, {r[\"id\"] for r in rows})\n"
            "    except Refusal as exc:\n"
            "        print(f\"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}\", "
            "file=sys.stderr)\n",
            "зуб Р9: строка фазы снята с раннего отказа")
    td, copy = _phases407_kit(_FX407_GREEN_CALL, (bait,))
    try:
        m = _phases407_run(copy, td, "--id", "ZZZ")
        mout = (m.stdout or "") + (m.stderr or "")
        if "ИТОГ фикстур=ФАЗА НЕ ЗАПУСКАЛАСЬ" in mout:
            return f"мутация пережила зуб: строка фазы осталась: {mout!r}"
    finally:
        shutil.rmtree(td, ignore_errors=True)
    return None


# Якорь блока смерти пула и управляемые замены зуба Ф1 (fix-волна #407, раунд 2):
# якоря собираются конкатенацией, чтобы цельный литерал в теле зуба не стал
# вторым вхождением при замене на тексте прибора.
_FX1_DEATH_ANCHOR = ("    bad = " + "0\n"
                     "    try:\n"
                     "        if " + "jobs:\n")
_FX1_JOBS_ANCHOR = ("    jobs, inapp_rows, inapplicable_by_version, refused = "
                    "build_" + "jobs(rows, picked, image, base)\n")
_FX1_JOBS_STUB = (_FX1_JOBS_ANCHOR,
                  "    jobs, inapp_rows, inapplicable_by_version, refused = "
                  "[(\"probe-death\", \"c\", str(image), [(0, b\"x\")], "
                  "[\"c\"])], [], [], []\n",
                  "зуб Ф1: управляемое задание воркера")
_FX1_DEATH_BAD = (_FX1_DEATH_ANCHOR,
                  _FX1_DEATH_ANCHOR +
                  "            bad += 1\n"
                  "            print(\"checks-teeth: МУТАЦИЯ probe-death: "
                  "ПРОШЛА МОЛЧА -- мутация снимка\", flush=True)\n"
                  "            raise BrokenProcessPool(\"мутация снимка: "
                  "воркер умер\")\n",
                  "зуб Ф1: смерть воркера после напечатанной находки")
_FX1_DEATH_REFUSED = (_FX1_DEATH_ANCHOR,
                      _FX1_DEATH_ANCHOR +
                      "            refused.append((\"probe-ref\", \"мутация "
                      "снимка: отказ строки\"))\n"
                      "            print(\"checks-teeth: МУТАЦИЯ probe-ref: "
                      "ОТКАЗ ПРИБОРА -- мутация снимка\",\n"
                      "                  file=sys.stderr, flush=True)\n"
                      "            raise BrokenProcessPool(\"мутация снимка: "
                      "воркер умер\")\n",
                      "зуб Ф1: смерть воркера после отказа строки")
_FX1_RUNNER_GREEN = "#!/bin/bash\necho '[OK] probe-green'\n"


def _tooth_phases_worker_death_keeps_printed_findings() -> str | None:
    """Смерть воркера не съедает уже напечатанную находку (Ф1 fix-волны #407).

    Снимок печатает одну молчавшую мутацию (или один отказ строки) и умирает
    BrokenProcessPool'ом: путь смерти обязан отдавать _phase_exit тот же
    первый аргумент, что и финальная свёртка, -- 1 (дефект) либо 9 (отказ
    строк), а не безусловную 2: свип читает 2 как «не измеряли», и
    НАПЕЧАТАННАЯ находка сворачивалась бы в «не мерили». Приманка возвращает
    на пути смерти безусловную 2 -- код обязан упасть до 2.
    """
    def _run_kit(extra_pairs):
        td, copy = _phases407_kit(_FX407_GREEN_CALL, tuple(extra_pairs),
                                  with_script=True)
        (td / "tools" / "checks-on-image.sh").write_text(
            _FX1_RUNNER_GREEN, encoding="utf-8")
        try:
            r = _phases407_run(copy, td)
            return r.returncode, (r.stdout or "") + (r.stderr or "")
        finally:
            shutil.rmtree(td, ignore_errors=True)

    rc, out = _run_kit((_FX1_JOBS_STUB, _FX1_DEATH_BAD))
    if rc != 1:
        return (f"смерть воркера после «ПРОШЛА МОЛЧА» обязана давать rc=1 "
                f"(найденный дефект выше «не измерено»): rc={rc} {out!r}")
    if "ПРОШЛА МОЛЧА" not in out:
        return f"напечатанная находка не доехала до вывода: {out!r}"
    if "воркер умер" not in out:
        return f"причина смерти воркера не напечатана: {out!r}"
    rc, out = _run_kit((_FX1_JOBS_STUB, _FX1_DEATH_REFUSED))
    if rc != 9:
        return (f"смерть воркера после отказа строки обязана давать rc=9 "
                f"(отказ прибора выше «не измерено»): rc={rc} {out!r}")
    if "ОТКАЗ ПРИБОРА" not in out:
        return f"напечатанный отказ строки не доехал до вывода: {out!r}"
    bait = ("        return _phase_" + "exit(1 if bad else (9 if refused "
            "else 2), entry_bad, fx_code)\n",
            "        return _phase_" + "exit(2, entry_bad, fx_code)\n",
            "зуб Ф1: безусловная двойка на пути смерти")
    rc, out = _run_kit((_FX1_JOBS_STUB, _FX1_DEATH_BAD, bait))
    if rc != 2:
        return (f"приманка не вернула безусловную 2 -- якорь устарел, зуб "
                f"мёртв: rc={rc} {out!r}")
    return None


# CONSTRAINT: якорь ВЫВОДИТСЯ из живого значения (тот же класс мины, что у
# _PHASES407_PIN_OLD): литерал чужого счётчика отваливается при его законном
# росте и обезоруживает зуб молча. Значение замены берётся заведомо иным.
_X5_FIXTURE_PIN_OLD = "EXPECTED_FIXTURE_TEETH = " + str(EXPECTED_FIXTURE_TEETH)
_X5_FIXTURE_PIN_NEW = "EXPECTED_FIXTURE_TEETH = " + str(EXPECTED_FIXTURE_TEETH + 86)
_X5_PHASE_PRINT = ('        print(_fixture_not_started_line(\n'
                   '            f"зубов фикстуры {len(_FIXTURE_TEETH)}, '
                   'объявлено "\n'
                   '            f"{EXPECTED_FIXTURE_TEETH}"), flush=True)\n')


def _tooth_phases_fixture_pin_prints_phase_line() -> str | None:
    """Путь пина набора фикстур печатает итог фазы (Х5 #407, раунд 3).

    Расхождение len(_FIXTURE_TEETH) с пином возвращало 4, напечатав причину
    ТОЛЬКО в stderr: на stdout не оставалось ни одной строки «ИТОГ фикстур=»,
    и потребитель, грепающий итог фазы, читал молчание как её зелёный ноль
    (класс #396). Снимок расходит пин; прогон обязан вернуть 4 и назвать оба
    числа. Приманка снимает печать -- зуб обязан это ловить.
    """
    pin = (_X5_FIXTURE_PIN_OLD, _X5_FIXTURE_PIN_NEW,
           "зуб Х5: пин набора фикстур расхожден")
    td, copy = _phases407_kit(_FX407_GREEN_CALL, (pin,), with_script=True)
    try:
        r = _phases407_run(copy, td)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 4:
            return (f"расхождение пина набора фикстур обязано давать rc=4: "
                    f"rc={r.returncode} {out!r}")
        if "ИТОГ фикстур=ФАЗА НЕ ЗАПУСКАЛАСЬ" not in out:
            return f"итог фазы не напечатан на пути пина набора: {out!r}"
        if "зубов фикстуры" not in out or "99" not in out:
            return f"причина не назвала оба числа пина: {out!r}"
    finally:
        shutil.rmtree(td, ignore_errors=True)
    bait = (_X5_PHASE_PRINT, "", "зуб Х5: печать итога снята с пути пина")
    td, copy = _phases407_kit(_FX407_GREEN_CALL, (pin, bait), with_script=True)
    try:
        m = _phases407_run(copy, td)
        mout = (m.stdout or "") + (m.stderr or "")
        if "ИТОГ фикстур=ФАЗА НЕ ЗАПУСКАЛАСЬ" in mout:
            return f"мутация пережила зуб: итог фазы остался: {mout!r}"
    finally:
        shutil.rmtree(td, ignore_errors=True)
    return None


def _tooth_phases_fixture_not_started_line() -> str | None:
    """Ранний пропуск печатает «ФАЗА НЕ ЗАПУСКАЛАСЬ», не «НЕ ИЗМЕРЕНО» (Ф6).

    Прогон с несуществующим --image уходит ДО фазы фикстуры: строка фазы
    обязана называть отсутствие запуска; «ИТОГ фикстур=НЕ ИЗМЕРЕНО» печатает
    САМА фаза, которая шла и не смогла, -- одной строкой на оба исхода
    оператор не отличил бы «фазы не было» от «фаза сломалась». Приманка
    возвращает пропускам прежнюю форму -- зуб обязан это ловить.
    """
    def _run(extra=()):
        td, copy = _phases407_kit(_FX407_GREEN_CALL, tuple(extra))
        try:
            r = _phases407_run(copy, td, "--image", "/нет/такого/образа-Ф6")
            return (r.returncode, (r.stdout or "") + (r.stderr or ""))
        finally:
            shutil.rmtree(td, ignore_errors=True)

    rc, out = _run()
    if rc != 5:
        return (f"несуществующий образ обязан давать rc=5: rc={rc} {out!r}")
    if "ИТОГ фикстур=ФАЗА НЕ ЗАПУСКАЛАСЬ" not in out:
        return f"строка «ФАЗА НЕ ЗАПУСКАЛАСЬ» не напечатана: {out!r}"
    if "ИТОГ фикстур=НЕ ИЗМЕРЕНО" in out:
        return f"ранний пропуск напечатан строкой «НЕ ИЗМЕРЕНО»: {out!r}"
    bait = ("    print(_fixture_" + "not_started_line(why), flush=True)\n"
            "    return _phase_" + "exit(code, entry_bad)\n",
            "    print(_fixture_" + "unmeasured_line(why), flush=True)\n"
            "    return _phase_" + "exit(code, entry_bad)\n",
            "зуб Ф6: пропуск снова печатает «НЕ ИЗМЕРЕНО»")
    rc, out = _run((bait,))
    if "ИТОГ фикстур=НЕ ИЗМЕРЕНО" not in out or "ФАЗА НЕ ЗАПУСКАЛАСЬ" in out:
        return (f"приманка не вернула прежнюю форму -- якорь устарел, зуб "
                f"мёртв: rc={rc} {out!r}")
    return None


def _tooth_mutant_rebinds_root_derived() -> str | None:
    """Копии прибора перепривязывают ВСЕ ROOT-производные константы (Ф2 #407).

    Перечень собирается ИЗ ТЕКСТА прибора (ast, присвоения модульного уровня,
    чьё значение ссылается на ROOT): копия лежит вне дома кита, и
    неперепривязанная константа указывает в каталог копии -- зуб FORK был
    зелен по чужой причине (нет FIXTURE_BUILDER в каталоге копии), измерено
    дорожками ревью. Новая ROOT-производная константа не имеет права уехать
    молча: зуб краснеет на имени, которого нет в перечне. Приманка возвращает
    конструктору перепривязку только ROOT -- хотя бы одна константа обязана
    разойтись с домом, иначе якорь приманки мёртв.

    ГРАНИЦА (Х10 раунда 3): квантор «ВСЕ копии» относится к копиям, идущим
    через _fx_mutant. Копия двери имён (prefix "checks-teeth-namedoor.") не
    перепривязывает НИЧЕГО и делает это законно: она зовёт одну чистую
    функцию разбора имён, у которой потребителей путей нет вовсе. Появится у
    неё путь -- она обязана уехать на общий конструктор.
    """
    live = set()
    for node in ast.parse(Path(__file__).read_text(encoding="utf-8")).body:
        if not isinstance(node, ast.Assign):
            continue
        names = [t.id for t in node.targets if isinstance(t, ast.Name)]
        if names and any(isinstance(n, ast.Name) and n.id == "ROOT"
                         for n in ast.walk(node.value)):
            live.update(names)
    not_bound = live - set(_ROOT_DERIVED)
    if not_bound:
        return (f"ROOT-производные константы вне перечня перепривязки: "
                f"{sorted(not_bound)}")
    mut, raw = _fx_mutant(())
    try:
        for name in sorted(live):
            if getattr(mut, name) != globals()[name]:
                return (f"копия не перепривязала {name}: "
                        f"{getattr(mut, name)!r} != {globals()[name]!r}")
    finally:
        shutil.rmtree(raw, ignore_errors=True)
    # Приманка исполняет КОНСТРУКТОР КОПИИ (по образцу зубов, зовущих функцию
    # копии): конструктор, чинящий только ROOT, обязан оставить константы
    # копии в её каталоге -- именно это состояние ловит проверка выше.
    bait_src = _once_replace(
        Path(__file__).read_text(encoding="utf-8"),
        "    for name in _ROOT_" + "DERIVED:\n"
        "        setattr(mod, name, globals()[name])\n",
        "    pass  # мутация Ф2: перепривязывается только ROOT\n",
        "зуб Ф2: конструктор чинит только ROOT")
    raw2 = Path(tempfile.mkdtemp(prefix="checks-teeth-fxmut."))
    mod2 = raw2 / "checks-teeth-mutated.py"
    mod2.write_text(bait_src, encoding="utf-8")
    spec2 = importlib.util.spec_from_file_location("checks_teeth_fx_mutant2", mod2)
    mut2 = importlib.util.module_from_spec(spec2)
    spec2.loader.exec_module(mut2)
    try:
        mut2._rebind_copy_home(mut2)
        stray = [name for name in sorted(live)
                 if getattr(mut2, name) != globals()[name]]
        if not stray:
            return ("мутация пережила зуб: конструктор «только ROOT» держит "
                    "все константы дома -- якорь приманки мёртв")
    finally:
        shutil.rmtree(raw2, ignore_errors=True)
    return None


def self_check() -> int:
    """Герметичная самопроверка: без образа и замка.

    Ветви edits_literal (#149): каждый сценарий обязан провалиться при
    удалении СВОЕЙ ветви -- иначе разводка двух отказов зелена вакуумно
    (в норме n==expect, ветвь дрейфа не срабатывает, и её удаление обычный
    прогон не заметит). База b"x MARK y MARK z" несёт ровно два вхождения
    MARK. Зубы #350 ниже держат третий исход строки (отказ прибора) в
    границе этой строки -- и в бухгалтерии итоговых строк.
    """
    B = b"x MARK y MARK z"

    def r(anchor: str, repl: str, expect) -> dict[str, str]:
        return {"id": "T", "anchor": anchor, "repl": repl, "expect": expect}

    # (имя, база, строка, ожидание): ("edits", N) -- вернуть N правок;
    # ("refuse", [подстроки]) -- отказ, несущий все подстроки.
    cases = [
        ("совпало",        B, r("MARK", "MARX", 2),           ("edits", 2)),
        ("дрейф-вверх",    B, r("MARK", "MARX", 1),           ("refuse", ["выросло", "ждали 1", "нашли 2", "площадка"])),
        ("дрейф-вниз",     B, r("MARK", "MARX", 3),           ("refuse", ["убыло", "ждали 3", "нашли 2", "площадка"])),
        ("выше-потолка",   B, r("MARK", "MARX", CEILING + 1), ("refuse", ["слишком широк", "derived"])),
        ("нецелое",        B, r("MARK", "MARX", "-"),         ("refuse", ["не целое"])),
        ("меньше-1",       B, r("MARK", "MARX", "0"),         ("refuse", ["< 1"])),
        ("якорь-пропал",   B, r("ZZZZ", "ZZZ", 1),            ("refuse", ["не найден"])),
        ("замена-длиннее", B, r("MARK", "MARKX", 2),          ("refuse", ["замена длиннее якоря"])),
    ]
    bad = 0
    for name, base, row, exp in cases:
        kind = exp[0]
        try:
            res = edits_literal(base, row)
        except Refusal as exc:
            if kind != "refuse":
                bad += 1
                print(f"checks-teeth self-check: {name}: ЖДАЛИ РЕЗУЛЬТАТ, отказ «{exc}»", flush=True)
                continue
            miss = [s for s in exp[1] if s not in str(exc)]
            if miss:
                bad += 1
                print(f"checks-teeth self-check: {name}: отказ без слов {miss}: «{exc}»", flush=True)
            else:
                print(f"checks-teeth self-check: {name}: OK", flush=True)
            continue
        if kind == "refuse":
            bad += 1
            print(f"checks-teeth self-check: {name}: ЖДАЛИ ОТКАЗ, получили {len(res)} правок", flush=True)
        elif len(res) != exp[1]:
            bad += 1
            print(f"checks-teeth self-check: {name}: ждали {exp[1]} правок, получили {len(res)}", flush=True)
        else:
            print(f"checks-teeth self-check: {name}: OK", flush=True)
    teeth = (
        ("строитель-отказ-не-роняет-проход", _tooth_builder_refusal_is_row_scoped),
        ("отказ-не-зелёный", _tooth_refusal_is_not_green),
        ("вне-области-отказа-нет", _tooth_no_refusal_same_outcome),
        ("код-7-занят-апстримом", _tooth_seven_is_upstream),
        ("пустой-выбор-отказывает", _tooth_empty_pick_refuses),
        ("имена-обоих-полей-в-реестре", _tooth_mutations_name_in_registry),
    )
    for name, fn in teeth:
        reason = fn()
        if reason:
            bad += 1
            print(f"checks-teeth self-check: {name}: ПРОШЛА МОЛЧА -- {reason}", flush=True)
        else:
            print(f"checks-teeth self-check: {name}: OK", flush=True)
    total = len(cases) + len(teeth)
    print(f"checks-teeth self-check: ИТОГ сценариев={total} провалов={bad}", flush=True)
    return 0 if bad == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="зубы реестра проверок")
    ap.add_argument("--image", help="собранный образ (по умолчанию -- цель ~/.local/bin/claude)")
    ap.add_argument("--jobs", type=int, default=3, help="сколько мутаций мерить разом")
    ap.add_argument("--id", help="прогнать только названные строки таблицы (через запятую)")
    ap.add_argument("--self-check", action="store_true",
                    help="герметичная самопроверка ветвей edits_literal (#149), без образа и замка")
    opts = ap.parse_args()

    if opts.self_check:
        # CONSTRAINT (Ф6 fix-волны #407): --self-check -- другой РЕЖИМ: фазы
        # фикстуры у него нет вовсе, итоговой строки фазы он не печатает
        # и печатать не обязан.
        return self_check()

    # Код 2 «контракт вызова» -- тот же, которым соседи validate/adjudicate
    # отвергают --jobs < 1 (круг 28, F-10). Прежний молчаливый подъём
    # max(1, opts.jobs) означал, что объявленный параллелизм и настоящий --
    # разные числа (круг 26, K-14). Проверка стоит ДО поисков раннера и
    # образа: нарушенный контракт вызова не зависит от того, есть ли на
    # машине образ, и не должен занимать замок.
    if opts.jobs < 1:
        print("checks-teeth: --jobs должен быть не меньше 1", file=sys.stderr)
        print(_fixture_not_started_line(
            "нарушен контракт вызова: --jobs меньше 1"), flush=True)
        return 2

    # Контракт вызова раннера. Стоит ДО поисков раннера и образа: нарушенный
    # контракт вызова не зависит от того, есть ли на машине образ, и зуб не
    # имеет права пропадать вместе с ним.
    entry_teeth = (
        ("wrong-patch-src", _tooth_wrong_patch_src),
        ("real-patch-src", _tooth_real_patch_src),
        ("kit-steps-off-src", _tooth_kit_steps_off_src),
        ("steps-off-arity-both-sides", _tooth_steps_off_arity_both_sides),
        ("steps-off-zero-rows-all-sides", _tooth_steps_off_zero_rows_all_sides),
        ("mutations-name-in-registry", _tooth_mutations_name_in_registry),
        ("declared-row-third-outcome", _tooth_declared_row_is_third_outcome),
        ("undeclared-pair-refuses", _tooth_undeclared_pair_still_refuses),
        ("empty-step-refuses", _tooth_empty_step_field_still_refuses),
        ("undeclared-step-refuses", _tooth_undeclared_step_refuses),
        ("setup-failure-refuses", _tooth_setup_failure_refuses),
        ("m2-padding-keeps-tail", _tooth_m2_padding_keeps_tail),
        ("carrier-absent-declared-note", _tooth_carrier_absent_declared_note),
        ("carrier-absent-partial-stays-red", _tooth_carrier_absent_partial_stays_red),
        ("carrier-absent-foreign-site", _tooth_carrier_absent_foreign_site),
        ("carrier-absent-parse-refuses", _tooth_carrier_absent_parse_refuses),
        ("carrier-absent-missing-file-is-norm", _tooth_carrier_absent_missing_file_is_norm),
        ("step-checks-unmapped-step-refuses", _tooth_step_checks_unmapped_step_refuses),
        ("step-checks-mapped-step-passes", _tooth_step_checks_mapped_step_passes),
        ("step-checks-dash-is-declared-empty", _tooth_step_checks_dash_is_declared_empty),
        ("step-checks-missing-map-refuses-as-instrument", _tooth_step_checks_missing_map_refuses_as_instrument),
        ("step-checks-single-home", _tooth_step_checks_single_home),
        ("step7-teeth-off-by-registry-code5", _tooth_step7_teeth_off_by_registry_code5),
        ("step7-caller-distinguishes-3-and-5", _tooth_step7_caller_distinguishes_3_and_5),
        ("corpus-base-is-projection", _tooth_corpus_base_is_projection),
        ("corpus-base-empty-when-nothing-off", _tooth_corpus_base_empty_when_nothing_off),
        ("corpus-unmapped-step-refuses", _tooth_corpus_unmapped_step_refuses),
        ("corpus-header-names-pipeline-subject", _tooth_corpus_header_names_pipeline_subject),
        ("both-registries-name-both-causes", _tooth_both_registries_name_both_causes),
        ("single-registry-names-one-cause", _tooth_single_registry_names_one_cause),
        ("phases-entry-red-keeps-mutation-summary",
         _tooth_phases_entry_red_keeps_mutation_summary),
        ("phases-unmeasured-mutation-is-not-zero",
         _tooth_phases_unmeasured_mutation_is_not_zero),
        ("phases-refusal-does-not-mask-entry",
         _tooth_phases_refusal_does_not_mask_entry),
        ("phases-pin-mismatch-outranks-entry",
         _tooth_phases_pin_mismatch_outranks_entry),
        ("phases-fx-defect-outranks-early-unmeasured",
         _tooth_phases_fx_defect_outranks_early_unmeasured),
        ("phases-fixture-line-on-early-refusal",
         _tooth_phases_fixture_line_on_early_refusal),
        ("mutant-rebind-pins-root-derived",
         _tooth_mutant_rebinds_root_derived),
        ("phases-worker-death-keeps-printed-findings",
         _tooth_phases_worker_death_keeps_printed_findings),
        ("phases-fixture-not-started-line",
         _tooth_phases_fixture_not_started_line),
        ("phases-fixture-pin-prints-phase-line",
         _tooth_phases_fixture_pin_prints_phase_line),
        ("weed-registry-covers-every-mkdtemp",
         _tooth_weed_registry_covers_every_mkdtemp),
    )
    if len(entry_teeth) != EXPECTED_ENTRY_TEETH:
        print(f"checks-teeth: ОТКАЗ -- зубов входа {len(entry_teeth)}, "
              f"объявлено {EXPECTED_ENTRY_TEETH}", file=sys.stderr)
        print(_fixture_not_started_line(
            f"зубов входа {len(entry_teeth)}, объявлено "
            f"{EXPECTED_ENTRY_TEETH}"), flush=True)
        return 4
    entry_bad = 0
    for name, fn in entry_teeth:
        reason = fn()
        if reason:
            entry_bad += 1
            print(f"checks-teeth: ВХОД {name}: ПРОШЛА МОЛЧА -- {reason}", flush=True)
        else:
            print(f"checks-teeth: ВХОД {name}: OK", flush=True)
    # CONSTRAINT: итог входной фазы печатается ВСЕГДА, как итог мутационной:
    # под условием entry_bad нулевой итог был неотличим от фазы, которая не
    # исполнилась вовсе (пусто != ноль), и число измеренных зубов оператор не
    # видел ни в одном зелёном прогоне.
    print(f"checks-teeth: ИТОГ вход={len(entry_teeth)} молча/неверно={entry_bad}",
          flush=True)
    # CONSTRAINT (#408): красный вход НЕ отменяет мутационную фазу. Ранний
    # возврат по entry_bad оставлял объявленные мутации неисполненными, и
    # ПУСТО в логе было неотличимо от НОЛЯ; дефект входа доживает до
    # финального кода и приоритетнее «не измерено».
    if not RUNNER.is_file():
        return _phase_skipped(6, "нет tools/checks-on-image.sh -- мерить нечем",
                              entry_bad)
    if shutil.which("bash") is None:
        return _phase_skipped(6, "нет bash", entry_bad)

    image = Path(opts.image) if opts.image else default_image()
    if image is None or not image.is_file():
        return _phase_skipped(5, "собранного образа на этой машине нет -- пропуск",
                              entry_bad)

    # Замок берётся ДО первого чтения образа и держится до конца замера.
    # Круг 28, F-1: занятость (3) и поломку машинерии (6) нельзя отвечать
    # одним кодом -- свип на 3 ждёт держателя, которого при поломке нет.
    try:
        lock = hold_read_lock()
    except LockMachineryBroken as exc:
        return _phase_skipped(
            6, "НЕ МЕРИЛИ -- машинерия замка сломана, повтор НЕ поможет "
            f"({exc})", entry_bad)
    if lock is None:
        return _phase_skipped(
            3, "НЕ МЕРИЛИ -- замок конвейера держит живая сборка "
            f"({pipeline_lock_path()}); образ меняется под руками, повтор поможет",
            entry_bad)
    freed = weed_worker_leftovers()
    if freed:
        print(f"checks-teeth: убрано копий образа от убитых воркеров: {freed}", flush=True)

    try:
        rows = read_table()
    except Refusal as exc:
        return _phase_skipped(2, f"ОТКАЗ ПРИБОРА -- {exc}", entry_bad)
    try:
        picked = pick_ids(opts.id, {r["id"] for r in rows})
    except Refusal as exc:
        print(f"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}", file=sys.stderr)
        print(_fixture_not_started_line(str(exc)), flush=True)
        return _phase_exit(2, entry_bad)
    # Дверь реестра: имена полей 2 и 6 обязаны существовать в checks
    # конвейера (docnum:other -- номера КОЛОНОК таблицы, не счётчики кита).
    # Стоит ДО мутационной фазы и не зависит от --id: таблица -- цельный
    # документ, а не набор выбранных строк.
    try:
        check_row_names(rows, set(_pipeline_check_names()))
    except Refusal as exc:
        print(f"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}", file=sys.stderr)
        print(_fixture_not_started_line(str(exc)), flush=True)
        return _phase_exit(2, entry_bad)
    n_img = sum(1 for r in rows if r["kind"] in ("literal", "derived"))
    n_inapp = sum(1 for r in rows if r["kind"] == "inapplicable")
    n_other = len(rows) - n_img - n_inapp
    if n_other:
        print(f"checks-teeth: ОТКАЗ -- неизвестный kind у {n_other} строк",
              file=sys.stderr)
        print(_fixture_not_started_line(
            f"неизвестный kind у {n_other} строк"), flush=True)
        return _phase_exit(4, entry_bad)
    if n_img != EXPECTED_MUTATIONS:
        print(f"checks-teeth: ОТКАЗ -- мутаций {n_img}, объявлено {EXPECTED_MUTATIONS}",
              file=sys.stderr)
        print(_fixture_not_started_line(
            f"мутаций {n_img}, объявлено {EXPECTED_MUTATIONS}"), flush=True)
        return _phase_exit(4, entry_bad)
    if n_inapp != EXPECTED_INAPPLICABLE_TEETH:
        print(f"checks-teeth: ОТКАЗ -- зубов неприменимости {n_inapp}, "
              f"объявлено {EXPECTED_INAPPLICABLE_TEETH}", file=sys.stderr)
        print(_fixture_not_started_line(
            f"зубов неприменимости {n_inapp}, объявлено "
            f"{EXPECTED_INAPPLICABLE_TEETH}"), flush=True)
        return _phase_exit(4, entry_bad)

    # CONSTRAINT (#407, Р5): зубы фикстуры идут ПОСЛЕ замка конвейера: они
    # строят и читают образ, а контрактом входной фазы («не зависеть от
    # образа и не занимать замок») это запрещено. Код 4 пина фазы --
    # объявленная граница (Р6): доминирует и не сворачивается.
    fx_code = _fixture_phase(entry_bad)
    if fx_code == 4:
        return _phase_exit(4, entry_bad, fx_code)

    # CONSTRAINT (#335): громкий отказ стреляет в области действия и не шире.
    # Контроль красноты защищает мутационные зубы -- им нужен зелёный базис
    # активного образа, иначе краснота ничего не докажет (она была и без нас).
    # Зубы неприменимости работают на фикстурах и активный образ не читают:
    # в наборе без мутационных строк контроль не гоняется вовсе, иначе точечная
    # краснота образа отказывала бы в обслуживании зубов, которых образ не
    # касается.
    n_img_picked = sum(1 for r in rows
                       if r["kind"] in ("literal", "derived")
                       and (picked is None or r["id"] in picked))
    n_inapp_picked = sum(1 for r in rows
                         if r["kind"] == "inapplicable"
                         and (picked is None or r["id"] in picked))
    # CONSTRAINT: прогон читает ДВА образа -- названный ключом (мутации и
    # контроль красноты) и пристин 2.1.278 (база фикстур неприменимости и
    # якоря). Назван обязан быть КАЖДЫЙ: свип зовёт прибор с образом СВОЕЙ
    # волны, и умолчание о второй базе заставляет читателя лога отнести к
    # названному образу вывод зубов, говоривших о другой версии.
    if n_img_picked:
        print(f"checks-teeth: ОБРАЗ мутаций и контроля: {image}", flush=True)
    if n_inapp_picked:
        print(f"checks-teeth: БАЗА фикстур неприменимости и якоря: "
              f"{PRISTINE_LATEST}", flush=True)
    if n_img_picked:
        try:
            red, _ = reds(image)
        except Refusal as exc:
            print(f"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}", file=sys.stderr)
            return _phase_exit(2, entry_bad, fx_code)
        if red:
            print("checks-teeth: КОНТРОЛЬ ПРОВАЛЕН -- образ красен ещё до мутаций:",
                  file=sys.stderr)
            for name in red:
                print("    " + name, file=sys.stderr)
            return _phase_exit(2, entry_bad, fx_code)
        print(f"checks-teeth: КОНТРОЛЬ без мутации: ЗЕЛЁНО ({image})", flush=True)
        base = image.read_bytes()
    else:
        print("checks-teeth: КОНТРОЛЬ красноты пропущен -- в наборе нет строк, "
              "читающих активный образ", flush=True)
        base = b""
    jobs, inapp_rows, inapplicable_by_version, refused = build_jobs(rows, picked, image, base)
    del base
    # Построчный исход отказа печатается сразу с id и сырым текстом; счётчик
    # и перечень -- в итоговых строках, после измерения остальных строк.
    for rid, why in refused:
        print(f"checks-teeth: МУТАЦИЯ {rid}: ОТКАЗ ПРИБОРА -- {why}",
              file=sys.stderr, flush=True)
    # Третий исход печатается СВОЕЙ строкой (версия/шаг/основание), в stdout
    # рядом с RED-строками измеренных мутаций, а не в stderr отказов.
    for rid, iver, istep, ireason in inapplicable_by_version:
        print(inapplicable_row_line(rid, iver, istep, ireason), flush=True)

    bad = 0
    try:
        if jobs:
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
        # Воркер умер (SIGKILL/OOM): ненапечатанные мутации НЕ ИЗМЕРЕНЫ, но
        # уже напечатанные находки (bad/refused) не имеют права сворачиваться
        # в «не измерено»: находка, названная вслух, старше неизмеренности.
        print("checks-teeth: НЕ МЕРИЛ -- воркер умер (SIGKILL/OOM), "
              "мутации не измерены", file=sys.stderr, flush=True)
        # CONSTRAINT (Ф1 fix-волны #407): 2 здесь НЕ безусловна -- свёртка
        # принимает найденный дефект/отказ строк, накопленные ДО смерти
        # воркера (тот же приоритет, что у финальной свёртки ниже); «не
        # измерено» остаётся только когда не накоплено ни того, ни другого.
        return _phase_exit(1 if bad else (9 if refused else 2), entry_bad, fx_code)

    measured_inapp = 0
    for row in inapp_rows:
        try:
            reason = run_inapplicable_tooth(row)
        except Refusal as exc:
            # Тот же третий исход, что у строителей literal/derived: отказ
            # зуба неприменимости -- свойство строки, остальные идут дальше.
            refused.append((row["id"], str(exc)))
            print(f"checks-teeth: МУТАЦИЯ {row['id']}: ОТКАЗ ПРИБОРА -- {exc}",
                  file=sys.stderr, flush=True)
            continue
        measured_inapp += 1
        want = [row["check"]]
        want += [x.strip() for x in row["also"].split(";") if x.strip()]
        if reason:
            bad += 1
            print(f"checks-teeth: МУТАЦИЯ {row['id']}: ПРОШЛА МОЛЧА -- {reason}",
                  flush=True)
        else:
            print(f"checks-teeth: МУТАЦИЯ {row['id']}: RED «{'» + «'.join(want)}»",
                  flush=True)

    # Якорь против вакуумности см. в docstring функции: положительный контроль
    # фикстур на реальном образе; не входит в EXPECTED_INAPPLICABLE_TEETH --
    # он не строка таблицы и не мутация.
    try:
        reason = _tooth_anchor_real_278()
    except Refusal as exc:
        refused.append(("anchor-278", str(exc)))
        print(f"checks-teeth: ЯКОРЬ 2.1.278: ОТКАЗ ПРИБОРА -- {exc}",
              file=sys.stderr, flush=True)
    else:
        if reason:
            bad += 1
            print(f"checks-teeth: ЯКОРЬ 2.1.278: ПРОШЛА МОЛЧА -- {reason}", flush=True)
        else:
            print("checks-teeth: ЯКОРЬ 2.1.278: ПОДТВЕРЖДЁН "
                  "(шаг 29 NOTE/declared, готовой строки нет)", flush=True)

    print(summary_line(len(jobs) + measured_inapp, bad), flush=True)
    if inapplicable_by_version:
        print(inapplicable_line(inapplicable_by_version), flush=True)
    if refused:
        print(refusal_line(refused), flush=True)
    lock.close()                       # замок снимается ПОСЛЕ последнего замера
    # CONSTRAINT (Р1 fix-волны #407): приоритет исходов -- найденный дефект (1)
    # > отказ прибора (9) > «не измерено» фазы фикстуры (2) > чистый ноль --
    # живёт ТОЛЬКО в _phase_exit; вторая копия правила здесь расходилась бы
    # с ранними выходами молча.
    return _phase_exit(1 if bad else (9 if refused else 0), entry_bad, fx_code)


if __name__ == "__main__":
    sys.exit(main())
