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
     который не поймал нарушенный контракт вызова раннера
  2  прибор не может мерить: якорь пропал/слишком широк, замена длиннее якоря,
     либо КОНТРОЛЬ провален -- названный образ красен ещё до мутаций; сюда же
     относится нарушенный контракт вызова: --jobs < 1 (круг 26, K-14)
  4  длина таблицы разошлась с объявленной (EXPECTED_MUTATIONS)
     либо число зубов входа разошлось с EXPECTED_ENTRY_TEETH
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
EXPECTED_MUTATIONS = 32
# Зубы входа -- не мутации образа: EXPECTED_MUTATIONS не двигается.
EXPECTED_ENTRY_TEETH = 2
# Зубы третьего исхода шага 29 (docnum:other -- номер шага патча, не счёт стенда).
# Это мутации скрипта, декларации и патча, а не образа.
# EXPECTED_MUTATIONS держит только kind literal/derived, иначе живой счёт
# README/D37 разъедется с таблицей, а README этой волне править нельзя.
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


def read_table() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for line in io.open(TABLE, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 8:
            raise Refusal(f"строка таблицы не из восьми полей: {parts[:2]}")
        rows.append(dict(zip(("id", "check", "kind", "anchor", "repl", "also", "expect", "note"),
                             parts)))
    return rows


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


def edits_v4(base: bytes) -> list[tuple[int, bytes]]:
    """Опт-ин исключения верха линейки сломан в НАШЕЙ форме -- и только в ней.

    Литеральный зуб здесь невозможен: `()===void 0&&` встречается в собранном
    образе 12 раз при потолке прибора 8, и байтовая мутация выбила бы 11
    чужих сайтов вместе с нашим -- покраснело бы лишнее, а причина покраснения
    стала бы неназываемой. Поэтому мутация идёт ТОЙ ЖЕ цепочкой, что и сама
    проверка (связка констант -> опт-ин форма исключения), и правит один
    байт внутри найденной формы. Сравнение `===void 0` становится
    всегда-ложным: исключение верха перестаёт зависеть от таблицы и живёт
    всегда, то есть ровно та потеря, которую проверка обязана видеть.
    """
    bundle = re.search(
        rb'var (' + ID + rb')="claude-opus-4-8",(' + ID + rb')="claude-opus-5";'
        rb'function (' + ID + rb')\((' + ID + rb')\)\{return (' + ID + rb')\(\)&&(' + ID + rb')\(\4\)===\2\}',
        base)
    if not bundle:
        raise Refusal("V4: связка констант понижения и верха не найдена")
    optin = re.search(
        rb'!\((' + ID + rb')\(\)===void 0&&' + re.escape(bundle.group(3)) + rb'\((' + ID + rb')\)\)',
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
    """
    site = re.search(
        rb'if\((' + ID + rb')!==void 0&&\(!Number\.isInteger\(\1\)\|\|\1<1\|\|\1>(' + ID + rb')\)\)'
        rb'throw new ' + ID + rb'\(`\$\{' + ID + rb'\}: \$\.model\.complete: '
        rb'maxTokens must be an integer from 1 to \$\{\2\} \(got \$\{String\(\1\)\}\)`\)', base)
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
    if len(default) != len(lim):
        # Разная длина сдвинула бы весь хвост образа, и покраснело бы всё
        # подряд чужой причиной. Честный отказ прибора, а не тихая подгонка.
        raise Refusal(
            f"M2: имена разной длины (умолчание {len(default)}, предел {len(lim)}) -- "
            f"замена сдвинула бы хвост образа")
    return [(tail_at + use.start(1), lim)]


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


def _version_image(ver: str, *, orig: bool = False) -> Path:
    """273 собранный (наш след жив); 274 и пол -- пристинный. orig=True -- всегда .orig."""
    base = Path.home() / ".local" / "share" / "claude" / "versions"
    built = base / ver
    orig_p = base / f"{ver}.orig"
    if orig or ver == "2.1.274":
        if orig_p.is_file():
            return orig_p
        if built.is_file():
            return built
    else:
        if built.is_file():
            return built
        if orig_p.is_file():
            return orig_p
    raise Refusal(f"нет образа {ver} в {base}")


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
              runner_repl=None):
    """Снимок кита: скрипт + патч + дом декларации + раннер пола. Правка только снимка."""
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


def run_inapplicable_tooth(row: dict[str, str]) -> str | None:
    """None -- зуб поймал свою мутацию. Строка -- прошла молча / прибор."""
    mid = row["id"]
    td = None
    img_copy = None
    try:
        if mid == "I1":
            img = _version_image("2.1.274")
            td, script, patch = _temp_kit()
            ctrl = _run_checks(script, img, patch)
            if "[NOTE]" not in (ctrl.stdout or ""):
                return "контроль: на 2.1.274 с декларацией [NOTE] нет"
            tags = _step29_tags(ctrl.stdout or "")
            if any(tags[n] != "NOTE" for n in STEP29_BOTH):
                return f"контроль: шаг 29 не NOTE {tags}"
            shutil.rmtree(td, ignore_errors=True)
            td, script, patch = _temp_kit(script_repl=(I1_ANCHOR, I1_REPL))
            mut = _run_checks(script, img, patch)
            if "[NOTE]" in (mut.stdout or ""):
                return "печать убрана, а [NOTE] остался -- форматтер не единственный источник"
            return None

        if mid == "I2":
            img = _version_image("2.1.274")
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
            img = _version_image("2.1.273")
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
            img = _version_image("2.1.273")
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
            img = _version_image("2.1.273")
            td, script, patch = _temp_kit(patch_repl=(I5_ANCHOR, I5_REPL))
            mut = _run_checks(script, img, patch)
            mt = _step29_tags(mut.stdout or "")
            if all(mt[n] == "FAIL" for n in STEP29_BOTH):
                return None
            return f"WITNESSES в патче изменены, шаг 29 не FAIL {mt} -- список не из src"

        if mid == "I6":
            img = _version_image("2.1.274")
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
            img = _version_image("2.1.274")
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
            img = _version_image("2.1.273", orig=True)
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
        if img_copy is not None:
            try:
                os.unlink(img_copy)
            except FileNotFoundError:
                pass


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
                          capture_output=True, text=True, errors="replace")
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


def self_check() -> int:
    """Герметичная самопроверка ветвей edits_literal (#149): без образа и замка.

    Каждый сценарий обязан провалиться при удалении СВОЕЙ ветви -- иначе разводка
    двух отказов зелена вакуумно (в норме n==expect, ветвь дрейфа не срабатывает,
    и её удаление обычный прогон не заметит). База b"x MARK y MARK z" несёт ровно
    два вхождения MARK.
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
    print(f"checks-teeth self-check: ИТОГ сценариев={len(cases)} провалов={bad}", flush=True)
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
        return self_check()

    # Код 2 «контракт вызова» -- тот же, которым соседи validate/adjudicate
    # отвергают --jobs < 1 (круг 28, F-10). Прежний молчаливый подъём
    # max(1, opts.jobs) означал, что объявленный параллелизм и настоящий --
    # разные числа (круг 26, K-14). Проверка стоит ДО поисков раннера и
    # образа: нарушенный контракт вызова не зависит от того, есть ли на
    # машине образ, и не должен занимать замок.
    if opts.jobs < 1:
        print("checks-teeth: --jobs должен быть не меньше 1", file=sys.stderr)
        return 2

    # Контракт вызова раннера. Стоит ДО поисков раннера и образа: нарушенный
    # контракт вызова не зависит от того, есть ли на машине образ, и зуб не
    # имеет права пропадать вместе с ним.
    entry_teeth = (
        ("wrong-patch-src", _tooth_wrong_patch_src),
        ("real-patch-src", _tooth_real_patch_src),
    )
    if len(entry_teeth) != EXPECTED_ENTRY_TEETH:
        print(f"checks-teeth: ОТКАЗ -- зубов входа {len(entry_teeth)}, "
              f"объявлено {EXPECTED_ENTRY_TEETH}", file=sys.stderr)
        return 4
    entry_bad = 0
    for name, fn in entry_teeth:
        reason = fn()
        if reason:
            entry_bad += 1
            print(f"checks-teeth: ВХОД {name}: ПРОШЛА МОЛЧА -- {reason}", flush=True)
        else:
            print(f"checks-teeth: ВХОД {name}: OK", flush=True)
    if entry_bad:
        print(f"checks-teeth: ИТОГ вход={len(entry_teeth)} молча/неверно={entry_bad}",
              flush=True)
        return 1

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
    n_img = sum(1 for r in rows if r["kind"] in ("literal", "derived"))
    n_inapp = sum(1 for r in rows if r["kind"] == "inapplicable")
    n_other = len(rows) - n_img - n_inapp
    if n_other:
        print(f"checks-teeth: ОТКАЗ -- неизвестный kind у {n_other} строк",
              file=sys.stderr)
        return 4
    if n_img != EXPECTED_MUTATIONS:
        print(f"checks-teeth: ОТКАЗ -- мутаций {n_img}, объявлено {EXPECTED_MUTATIONS}",
              file=sys.stderr)
        return 4
    if n_inapp != EXPECTED_INAPPLICABLE_TEETH:
        print(f"checks-teeth: ОТКАЗ -- зубов неприменимости {n_inapp}, "
              f"объявлено {EXPECTED_INAPPLICABLE_TEETH}", file=sys.stderr)
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
    inapp_rows = []
    try:
        for row in rows:
            if picked is not None and row["id"] not in picked:
                continue
            if row["kind"] == "inapplicable":
                inapp_rows.append(row)
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
        # Воркер умер (SIGKILL/OOM): мутации НЕ ИЗМЕРЕНЫ. Класс 2, а не 1 --
        # по таблице инструмента 1 значит «мутация прошла молча», и свип
        # объявлял бы красным китом сломанный прибор.
        print("checks-teeth: НЕ МЕРИЛ -- воркер умер (SIGKILL/OOM), "
              "мутации не измерены", file=sys.stderr, flush=True)
        return 2

    for row in inapp_rows:
        try:
            reason = run_inapplicable_tooth(row)
        except Refusal as exc:
            print(f"checks-teeth: ОТКАЗ ПРИБОРА -- {exc}", file=sys.stderr)
            return 2
        want = [row["check"]]
        want += [x.strip() for x in row["also"].split(";") if x.strip()]
        if reason:
            bad += 1
            print(f"checks-teeth: МУТАЦИЯ {row['id']}: ПРОШЛА МОЛЧА -- {reason}",
                  flush=True)
        else:
            print(f"checks-teeth: МУТАЦИЯ {row['id']}: RED «{'» + «'.join(want)}»",
                  flush=True)

    print(f"checks-teeth: ИТОГ мутаций={len(jobs) + len(inapp_rows)} "
          f"прошло молча/чужой дверью={bad}", flush=True)
    lock.close()                       # замок снимается ПОСЛЕ последнего замера
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
