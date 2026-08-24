#!/usr/bin/env python3

import argparse
import json
import math
import re
import sys
import tomllib
from pathlib import Path
from typing import Any


BARE_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+$")
MISSING = object()


class RussianArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        self.exit(2, f"{self.prog}: ошибка аргументов: {message}\n")


def parse_args() -> argparse.Namespace:
    parser = RussianArgumentParser(
        description="Свести настройки judge и idle-watch в единый probes.toml."
    )
    parser.add_argument(
        "--judge",
        default="~/.claude/judge/config.json",
        help="путь к config.json пробы judge",
    )
    parser.add_argument(
        "--idle",
        default="~/.claude/idle-watch/config.json",
        help="путь к config.json пробы idle-watch",
    )
    parser.add_argument(
        "--out",
        default="~/.claude/probes/probes.toml",
        help="путь к выходному probes.toml",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="перезаписать существующий выходной файл",
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="напечатать TOML вместо записи файла",
    )
    return parser.parse_args()


def load_json(path: Path, probe_id: str) -> dict[str, Any]:
    def reject_constant(value: str) -> None:
        raise ValueError(f"недопустимое JSON-число {value}")

    try:
        with path.open("r", encoding="utf-8") as source:
            value = json.load(source, parse_constant=reject_constant)
    except (OSError, json.JSONDecodeError, UnicodeError, ValueError) as error:
        raise ValueError(f"не удалось прочитать {probe_id} из {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"конфигурация {probe_id} в {path} должна быть JSON-объектом")
    return value


def exact_equal(left: Any, right: Any) -> bool:
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(
            exact_equal(left[key], right[key]) for key in left
        )
    if isinstance(left, list):
        return len(left) == len(right) and all(
            exact_equal(left_item, right_item)
            for left_item, right_item in zip(left, right)
        )
    return left == right


def split_settings(
    judge: dict[str, Any], idle: dict[str, Any]
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    shared_keys = {
        key for key, value in judge.items() if key in idle and exact_equal(value, idle[key])
    }
    defaults = {key: value for key, value in judge.items() if key in shared_keys}
    judge_only = {key: value for key, value in judge.items() if key not in shared_keys}
    idle_only = {key: value for key, value in idle.items() if key not in shared_keys}
    return defaults, judge_only, idle_only


def format_key(key: str) -> str:
    if BARE_KEY_RE.fullmatch(key):
        return key
    return json.dumps(key, ensure_ascii=False)


def format_path(path: tuple[str, ...]) -> str:
    return ".".join(format_key(part) for part in path)


def format_inline_table(value: dict[str, Any]) -> str:
    parts = [f"{format_key(key)} = {format_value(item)}" for key, item in value.items()]
    return "{ " + ", ".join(parts) + " }"


def format_value(value: Any) -> str:
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("нечисловые и бесконечные значения JSON не поддерживаются")
        return repr(value)
    if value is None:
        raise ValueError("значение null нельзя представить в TOML без потери ключа")
    if isinstance(value, list):
        return "[" + ", ".join(format_value(item) for item in value) + "]"
    if isinstance(value, dict):
        return format_inline_table(value)
    raise ValueError(f"неподдерживаемый тип значения: {type(value).__name__}")


def is_array_of_tables(value: Any) -> bool:
    return isinstance(value, list) and bool(value) and all(
        isinstance(item, dict) for item in value
    )


def emit_table(lines: list[str], path: tuple[str, ...], table: dict[str, Any]) -> None:
    lines.append(f"[{format_path(path)}]")
    children: list[tuple[str, Any]] = []
    for key, value in table.items():
        if isinstance(value, dict) or is_array_of_tables(value):
            children.append((key, value))
        else:
            lines.append(f"{format_key(key)} = {format_value(value)}")
    lines.append("")
    emit_children(lines, path, children)


def emit_array_table(
    lines: list[str], path: tuple[str, ...], items: list[dict[str, Any]]
) -> None:
    for item in items:
        lines.append(f"[[{format_path(path)}]]")
        children: list[tuple[str, Any]] = []
        for key, value in item.items():
            if isinstance(value, dict) or is_array_of_tables(value):
                children.append((key, value))
            else:
                lines.append(f"{format_key(key)} = {format_value(value)}")
        lines.append("")
        emit_children(lines, path, children)


def emit_children(
    lines: list[str], parent: tuple[str, ...], children: list[tuple[str, Any]]
) -> None:
    for key, value in children:
        path = parent + (key,)
        if isinstance(value, dict):
            emit_table(lines, path, value)
        else:
            emit_array_table(lines, path, value)


def render_toml(
    defaults: dict[str, Any], judge: dict[str, Any], idle: dict[str, Any]
) -> str:
    lines: list[str] = []
    emit_table(lines, ("defaults",), defaults)
    emit_table(lines, ("probe", "judge"), judge)
    emit_table(lines, ("probe", "idle-watch"), idle)
    return "\n".join(lines).rstrip() + "\n"


def display_value(value: Any) -> str:
    if value is MISSING:
        return "<ключ отсутствует>"
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def differences(expected: Any, actual: Any, path: str = "$") -> list[str]:
    if type(expected) is not type(actual):
        return [
            f"{path}: ожидалось {display_value(expected)}, получено {display_value(actual)}"
        ]
    if isinstance(expected, dict):
        result: list[str] = []
        for key in expected:
            child = f"{path}.{key}"
            if key not in actual:
                result.append(
                    f"{child}: ожидалось {display_value(expected[key])}, "
                    f"получено {display_value(MISSING)}"
                )
            else:
                result.extend(differences(expected[key], actual[key], child))
        for key in actual:
            if key not in expected:
                result.append(
                    f"{path}.{key}: ожидалось {display_value(MISSING)}, "
                    f"получено {display_value(actual[key])}"
                )
        return result
    if isinstance(expected, list):
        result = []
        common_length = min(len(expected), len(actual))
        for index in range(common_length):
            result.extend(differences(expected[index], actual[index], f"{path}[{index}]"))
        for index in range(common_length, len(expected)):
            result.append(
                f"{path}[{index}]: ожидалось {display_value(expected[index])}, "
                f"получено {display_value(MISSING)}"
            )
        for index in range(common_length, len(actual)):
            result.append(
                f"{path}[{index}]: ожидалось {display_value(MISSING)}, "
                f"получено {display_value(actual[index])}"
            )
        return result
    if expected != actual:
        return [
            f"{path}: ожидалось {display_value(expected)}, получено {display_value(actual)}"
        ]
    return []


def verify(
    text: str,
    expected: dict[str, dict[str, Any]],
) -> tuple[bool, list[str]]:
    try:
        parsed = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        return False, [f"TOML не разобран: {error}"]

    defaults = parsed.get("defaults", MISSING)
    probes = parsed.get("probe", MISSING)
    if not isinstance(defaults, dict):
        return False, ["таблица [defaults] отсутствует или имеет неверный тип"]
    if not isinstance(probes, dict):
        return False, ["таблица [probe] отсутствует или имеет неверный тип"]

    success = True
    messages: list[str] = []
    for probe_id, source in expected.items():
        probe_settings = probes.get(probe_id, MISSING)
        if not isinstance(probe_settings, dict):
            probe_differences = [f"$.probe.{probe_id}: таблица отсутствует"]
        else:
            effective = dict(defaults)
            effective.update(probe_settings)
            probe_differences = differences(source, effective)
        if probe_differences:
            success = False
            messages.append(f"{probe_id}: найдены расхождения")
            messages.extend(f"  {item}" for item in probe_differences)
        else:
            messages.append(f"{probe_id}: {len(source)} ключей, совпало ТОЧНО")
    return success, messages


def main() -> int:
    args = parse_args()
    judge_path = Path(args.judge).expanduser()
    idle_path = Path(args.idle).expanduser()
    out_path = Path(args.out).expanduser()

    try:
        judge = load_json(judge_path, "judge")
        idle = load_json(idle_path, "idle-watch")
        defaults, judge_only, idle_only = split_settings(judge, idle)
        text = render_toml(defaults, judge_only, idle_only)
    except ValueError as error:
        print(f"Ошибка: {error}", file=sys.stderr)
        return 1

    verified, messages = verify(text, {"judge": judge, "idle-watch": idle})
    for message in messages:
        print(message, file=sys.stderr)
    if not verified:
        return 1

    if args.stdout:
        sys.stdout.write(text)
        return 0

    mode = "w" if args.force else "x"
    try:
        with out_path.open(mode, encoding="utf-8", newline="\n") as output:
            output.write(text)
    except FileExistsError:
        print(
            f"Ошибка: выходной файл уже существует: {out_path}; "
            "используйте --force для перезаписи",
            file=sys.stderr,
        )
        return 1
    except (OSError, UnicodeError) as error:
        print(f"Ошибка: не удалось записать {out_path}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
