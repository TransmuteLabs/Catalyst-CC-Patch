#!/usr/bin/env python3
"""Hermetic checks for model-cost synchronization and its installer guards.

Exit codes (subset of the kit-wide table in claude-patch-all.sh):
  0  every scenario passed; in --self-check every mutation reddened its owner
  1  a scenario failed, or a mutation did not redden its owning scenario
  2  the bench cannot measure: invocation is invalid, the pristine copy is red,
     a replacement BROKE THE VICTIM'S PARSE (circle 25, E-3) -- a scenario
     reddened by a parse error proves nothing, and the run stops BEFORE the
     reddening count -- or the kit's single-home heredoc rule
     (tools/heredoc-anchor.py) refused to load or failed its own teeth
  4  the declared scenario or mutation count differs from the tables below,
     or some scenario has NO mutation of its own (circle 25, E-4: an uncovered
     scenario is a door without teeth)
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import errno
import hashlib
import importlib.util
import io
import json
import os
import py_compile
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import ModuleType
from typing import Callable
from unittest.mock import patch

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
BENCH = Path(__file__).resolve()
COSTS = ROOT / "set-model-costs.py"
VALIDATE = ROOT / "judge" / "validate.py"
PATCHER = ROOT / "claude_patch.py"
CORPUS = ROOT / "tools" / "corpus-list.py"
PIPELINE = ROOT / "claude-patch-all.sh"
# CONSTRAINT: no scenario reads this file -- it is a dependency of the product
# under test (claude_patch.py refuses when its byte-level half is not beside
# it), and it has a name here so that the copy list stays derived from the
# path constants instead of repeating them.
ROUTING = ROOT / "patch_claude_routing.py"
# CONSTRAINT: the "this line opens a python heredoc" rule is loaded from the
# kit's SINGLE home, tools/heredoc-anchor.py (wave 229): the local copy of
# the rule was rougher and silently undercounted bodies, and a body the guard
# never saw compiled exactly like a checked one. No scenario reads the file;
# the bench itself does -- the copy list carries it as a dependency, for the
# same one-way-census reason as ROUTING above.
ANCHOR = ROOT / "tools" / "heredoc-anchor.py"
EXPECTED_SCENARIOS = 62
EXPECTED_MUTATIONS = 113

# Load form mirrors the pipeline's PYCOMPILE stage: a load failure is a named
# bench refusal (code 2, "cannot measure"), not a fallback to a local edition
# of the rule and not an empty "no bodies" verdict.
_anchor_spec = importlib.util.spec_from_file_location("heredoc_anchor", str(ANCHOR))
if _anchor_spec is None or _anchor_spec.loader is None:
    print("costs-bench: ЯКОРЬ HEREDOC'ОВ НЕ ЗАГРУЖАЕТСЯ: нет tools/heredoc-anchor.py")
    sys.exit(2)
_anchor = importlib.util.module_from_spec(_anchor_spec)
try:
    _anchor_spec.loader.exec_module(_anchor)
except Exception as _error:    # load refusal -- no fallback to a local rule copy
    print(f"costs-bench: ЯКОРЬ HEREDOC'ОВ НЕ ЗАГРУЖАЕТСЯ: {_error}")
    sys.exit(2)
opener_match = _anchor.opener_match

# CONSTRAINT (wave 230): an importable-but-broken instrument must refuse the
# bench too. Both benches passed their whole self-check with a fully blinded
# opener_match: a green verdict over an instrument that cannot see openings
# is "measured" only in name. The instrument's PUBLIC teeth decide; its
# success print is captured, not shown -- bench output is compared
# byte-for-byte, and an extra line would break the stands' own contract.
ANCHOR_TEETH_RAN = False


def _anchor_teeth_hold() -> None:
    """Run the anchor's public self-check; refuse the bench if it fails."""
    global ANCHOR_TEETH_RAN
    buffer = io.StringIO()
    try:
        with contextlib.redirect_stdout(buffer):
            rc = _anchor.self_check()
    except SystemExit as error:
        rc = error.code if isinstance(error.code, int) else 1
    except Exception as error:    # any instrument refusal is a refusal to measure
        rc = 1
        buffer.write(f"{type(error).__name__}: {error}")
    if rc != 0:
        print(f"costs-bench: ЯКОРЬ HEREDOC'ОВ НЕ ДЕРЖИТ ФОРМУ: "
              f"{buffer.getvalue().strip()}")
        sys.exit(2)
    ANCHOR_TEETH_RAN = True


_anchor_teeth_hold()


class BenchFailure(AssertionError):
    pass


class UnparsableVictim(Exception):
    """The replacement broke the victim's PARSE -- the bench cannot measure.

    Circle 25, E-3: a scenario reddened by a syntax error looks exactly like
    one reddened by a disabled mechanism, and only parse-ability separates
    the two on state-marker traces. Caught BEFORE any scenario runs; the
    class is separate from "anchor not found" and from "passed silently"
    because the causes and the fixes differ.
    """


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BenchFailure(message)


def import_file(path: Path, stem: str) -> ModuleType:
    name = f"costs_bench_{stem}_{os.getpid()}_{time.time_ns()}"
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def bench_env(home: Path, *, ccd: str | None = None, oauth: str | None = None) -> dict[str, str]:
    """The bench's ONE door into the product's environment: whatever the bench
    process itself inherited (an ambient CLAUDE_CONFIG_DIR or OAuth URL) never
    reaches a fixture — a fixture decides explicitly what the product sees."""
    env = {key: value for key, value in os.environ.items()
           if key not in ("CLAUDE_CONFIG_DIR", "CLAUDE_CODE_CUSTOM_OAUTH_URL")}
    env["HOME"] = str(home)
    if ccd is not None:
        env["CLAUDE_CONFIG_DIR"] = ccd
    if oauth is not None:
        env["CLAUDE_CODE_CUSTOM_OAUTH_URL"] = oauth
    return env


def run_costs_main(config: dict[str, object], *, catalogue: dict[str, object],
                   live_ids: list[str] | None = None,
                   proxy_catalogue: dict[str, object] | None = None,
                   proxy_stats: dict[str, int] | None = None,
                   proxy_unreachable: bool = False,
                   argv: list[str] | None = None
                   ) -> tuple[int, bytes, bytes, str, list[Path]]:
    """Run set-model-costs.py's main() against a substituted HOME.

    Every network side is a fixture: the live proxy listing (live_ids, or a
    raised OSError with proxy_unreachable), the proxy's own catalogue file
    (proxy_catalogue + the raw denominators the parse counts into
    load_proxy_catalogue.last_stats), the seen-roster (empty, inert) and the
    models.dev price catalogue. argv extends the plain invocation, so a mode
    like --check-drift is exercised through the same door a caller uses.
    """
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        path = home / ".claude.json"
        path.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")
        before = path.read_bytes()
        old_argv = sys.argv[:]
        output = io.StringIO()
        try:
            # CONSTRAINT: the product module is imported INSIDE the patched
            # environment — CACHE_PATH/SEEN_PATH are resolved from the HOME the
            # fixture chose, at import time.
            with patch.dict(os.environ, bench_env(home), clear=True), \
                    contextlib.redirect_stdout(output), \
                    contextlib.redirect_stderr(output):
                module = import_file(COSTS, "costs")

                def fixture_proxy_ids() -> list[str]:
                    if proxy_unreachable:
                        raise OSError("fixture: proxy is down")
                    return [] if live_ids is None else list(live_ids)

                module.proxy_model_ids = fixture_proxy_ids

                def fixture_proxy_catalogue() -> dict[str, object]:
                    fixture_proxy_catalogue.last_stats = proxy_stats  # type: ignore[attr-defined]
                    return {} if proxy_catalogue is None else dict(proxy_catalogue)

                module.load_proxy_catalogue = fixture_proxy_catalogue
                module.load_seen = lambda: set()
                module.save_seen = lambda ids, lock=None: None

                def fake_fetch() -> tuple[dict[str, object], str]:
                    return catalogue, "network"

                module.fetch_catalogue = fake_fetch
                sys.argv = [str(COSTS)] if argv is None else [str(COSTS), *argv]
                rc = module.main()
        finally:
            sys.argv = old_argv
        after = path.read_bytes()
        backups = sorted(home.glob(".claude.json.backup.*"))
        backup_bytes = [p.read_bytes() for p in backups]
        return rc, before, after, output.getvalue(), [Path(str(len(b))) for b in backup_bytes]


def scenario_c1() -> None:
    cases = [
        ({"other": {"kept": True},
          "customModelCosts": {"missing-model": {"inputTokens": 1}},
          "customModelContextWindows": {}},
         "customModelCosts", "roster=1", "prices=0"),
        ({"other": {"kept": True},
          "customModelCosts": {},
          "customModelContextWindows": {"missing-model": 200000}},
         "customModelContextWindows", "roster=0", "windows=0"),
    ]
    for original, key, roster_count, found_count in cases:
        rc, before, after, output, backups = run_costs_main(original, catalogue={})
        require(rc == 1, f"empty replacement over live {key} returned rc={rc}\n{output}")
        require(after == before, f"empty replacement changed the config for {key}")
        require(not backups, f"empty replacement took a backup before refusing {key}")
        require(key in output and roster_count in output and found_count in output
                and "network" in output,
                f"refusal did not name key/roster/found/source for {key}\n{output}")


def scenario_c2() -> None:
    original = {"other": {"kept": True}, "customModelCosts": {},
                "customModelContextWindows": {}}
    rc, _, after, output, backups = run_costs_main(original, catalogue={})
    require(rc == 0, f"empty replacement over empty tables returned rc={rc}\n{output}")
    data = json.loads(after)
    require(data["customModelCosts"] == {} and data["customModelContextWindows"] == {},
            f"empty tables were not written as empty: {data}")
    require(len(backups) == 1, f"allowed write took {len(backups)} backups, expected one")


def scenario_c3() -> None:
    module = import_file(COSTS, "context")
    module.reply_headroom = lambda: 76000
    value = module.context_window("small", {"limit": {"input": 12000,
                                                             "context": 32000}},
                                  {"context": 32000})
    require(value == 12000,
            f"invalid routed window did not continue to limit.input: {value}")
    no_value = module.context_window("small", {"limit": {"context": 32000}}, {})
    require(no_value is None, f"nonpositive total context window escaped: {no_value}")

    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        path = home / ".claude.json"
        path.write_text(json.dumps({"customModelCosts": {},
                                    "customModelContextWindows": {}}), encoding="utf-8")
        old_argv = sys.argv[:]
        try:
            with patch.dict(os.environ, bench_env(home), clear=True):
                guarded = import_file(COSTS, "guard")
                guarded.proxy_model_ids = lambda: ["small"]

                def guard_catalogue() -> dict[str, object]:
                    # Каталожная строка вывода теперь требует сырые знаменатели
                    # (last_stats), и стаб обязан нести полный контракт прибора.
                    guard_catalogue.last_stats = {"records": 1, "providers": 1,  # type: ignore[attr-defined]
                                                  "enabled": 0}
                    return {"small": {"context": 32000}}

                guarded.load_proxy_catalogue = guard_catalogue
                guarded.load_seen = lambda: set()
                guarded.save_seen = lambda ids, lock=None: None
                guarded.candidates = lambda catalogue, model_id: []
                guarded.context_window = lambda *args: -44000
                guarded.reply_headroom = lambda: 76000

                def fake_fetch() -> tuple[dict[str, object], str]:
                    return {}, "network"

                guarded.fetch_catalogue = fake_fetch
                sys.argv = [str(COSTS)]
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    rc = guarded.main()
                data = json.loads(path.read_text(encoding="utf-8"))
                require(rc == 0, f"write guard run returned rc={rc}\n{output.getvalue()}")
                require("small" not in data["customModelContextWindows"],
                        f"write guard stored a negative window: {data}")
                require("small" in output.getvalue() and "-44000" in output.getvalue()
                        and "76000" in output.getvalue(),
                        f"write guard did not name model/window/headroom\n{output.getvalue()}")
        finally:
            sys.argv = old_argv


def cache_case(age_seconds: float, *, should_load: bool) -> None:
    module = import_file(COSTS, "cache")
    with tempfile.TemporaryDirectory() as raw:
        cache = Path(raw) / "models-dev.json"
        payload = {"provider": {"models": {}}}
        cache.write_text(json.dumps(payload), encoding="utf-8")
        stamp = time.time() - age_seconds
        os.utime(cache, (stamp, stamp))
        module.CACHE_PATH = str(cache)
        original = OSError("network-down-original")
        module.fetch_json = lambda url: (_ for _ in ()).throw(original)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            try:
                loaded = module.fetch_catalogue()
            except Exception as error:
                require(not should_load, f"valid cache raised {error!r}\n{output.getvalue()}")
                require(error is original, f"invalid cache raised {error!r}, not original network error")
            else:
                require(should_load, f"invalid cache was accepted: age={age_seconds}\n{output.getvalue()}")
                require(loaded[0] == payload, f"cache payload changed: {loaded!r}")
                require(loaded[1] == "cache",
                        "cache source was not recorded")


def scenario_c4() -> None:
    cache_case(200 * 3600, should_load=False)


def scenario_c5() -> None:
    cache_case(-24 * 3600, should_load=False)


def scenario_c6() -> None:
    cache_case(2 * 3600, should_load=True)


def scenario_c7() -> None:
    module = import_file(PATCHER, "integrity")
    blob = b"costs-bench-tarball"
    md5 = base64.b64encode(hashlib.md5(blob).digest()).decode()
    try:
        module._verify_tarball(blob, {"integrity": f"md5-{md5}"}, "fixture")
    except SystemExit as error:
        require(error.code == 1, f"md5 refusal returned {error.code}")
    else:
        raise BenchFailure("md5 dist.integrity was accepted")
    sha512 = base64.b64encode(hashlib.sha512(blob).digest()).decode()
    module._verify_tarball(blob, {"integrity": f"sha512-{sha512}"}, "fixture")
    sha256 = base64.b64encode(hashlib.sha256(blob).digest()).decode()
    module._verify_tarball(blob, {"integrity": f"sha256-{sha256}"}, "fixture")


def scenario_c8() -> None:
    for bad, argv in (("/tmp/evil", ["--download-only", "/tmp/evil"]),
                      ("../bin/claude", ["--download-only", "../bin/claude"]),
                      ("/tmp/evil", ["--download-only"])):
        module = import_file(PATCHER, "version")
        module.versions_dir = lambda: (_ for _ in ()).throw(
            BenchFailure(f"path constructed before rejecting {bad!r}"))
        if len(argv) == 1:
            module.http_json = lambda url: {"latest": bad}
        try:
            module.main(argv)
        except SystemExit as error:
            # Круг 28, F-11: неверная версия -- нарушение КОНТРАКТА вызова
            # (класс 2), а не отказ по существу; полоса E пинила единицу,
            # потому что тогда die() не умел ничего другого.
            require(error.code == 2, f"invalid version {bad!r} returned {error.code}")
        except BenchFailure:
            raise
        else:
            raise BenchFailure(f"invalid version {bad!r} was accepted")


def scenario_c9() -> None:
    patcher = import_file(PATCHER, "platform")
    with tempfile.TemporaryDirectory() as raw:
        path = Path(raw) / "corpus.txt"
        pkg = patcher.npm_platform_pkg()
        path.write_text(f"# platform: {pkg}\n"
                        "foo:bar 2.1.1 -\n", encoding="utf-8")
        # Платформа-цель -- обязательный второй аргумент: без него разборщик
        # отвечает кодом 2 (контракт вызова), и сценарий мерил бы ту дверь, а
        # не свою (метка с двоеточием).
        result = subprocess.run([sys.executable, str(CORPUS), str(path), pkg], cwd=ROOT,
                                capture_output=True, text=True, errors="replace")
        require(result.returncode == 1,
                f"colon label returned rc={result.returncode}\n{result.stdout}{result.stderr}")
        require("строка 2" in result.stderr and ":" in result.stderr,
                f"colon refusal did not name line and delimiter\n{result.stderr}")


def shell_function(source: str, name: str) -> str:
    # У ГОЛОВЫ функции бывает ХВОСТ -- комментарий с её контрактом, и в ките это
    # обычная форма (`__image_run_note() {   # <путь> -> диагноз`). Якорь,
    # требующий перевода строки сразу за `{`, такую функцию просто НЕ НАХОДИТ:
    # отказ честный и громкий, но он про прибор, а не про предмет. Измерено
    # волной 48 на подписанте, который начал звать диагност платформы.
    match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{[^\n]*\n.*?^\}}\n", source)
    require(match is not None, f"shell function {name} not found")
    return match.group(0)


def scenario_c10() -> None:
    source = PIPELINE.read_text(encoding="utf-8")
    function = (shell_function(source, "__config_json_path")
                + shell_function(source, "prune_config_backups"))
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        own = [
            home / ".claude.json.backup.20260101-000000",
            home / ".claude.json.backup.20260201-000000",
            home / ".claude.json.backup.20260301-000000",
            home / ".claude.json.backup.20260401-000000",
        ]
        for path in own:
            path.write_text(path.name, encoding="utf-8")
        future = time.time() + 24 * 3600
        os.utime(own[0], (future, future))
        foreign = home / ".claude.json.backup.foreign"
        foreign.write_text("foreign", encoding="utf-8")
        script = f"set -euo pipefail\n{function}\nprune_config_backups\n"
        env = {**os.environ, "HOME": str(home)}
        env.pop("CLAUDE_CONFIG_DIR", None)
        env.pop("CLAUDE_CODE_CUSTOM_OAUTH_URL", None)
        result = subprocess.run(["bash"], input=script, env=env,
                                capture_output=True, text=True, errors="replace")
        require(result.returncode == 0, f"backup pruning rc={result.returncode}\n{result.stdout}{result.stderr}")
        remaining = {p.name for p in home.iterdir()}
        expected = {p.name for p in own[1:]} | {foreign.name}
        require(remaining == expected,
                f"backup pruning kept/deleted wrong names: {sorted(remaining)} != {sorted(expected)}")


def scenario_c11() -> None:
    source = PIPELINE.read_text(encoding="utf-8")
    function = shell_function(source, "validated_nonnegative_integer")
    # Волна 26, D-8: величина сверяется по ЗНАЧЕНИЮ, а не по длине строки.
    # «0000000000000000000005» -- это 5, а не 22-значное число; 20-значное
    # значение выше потолка bash-арифметики обязано отказать с названной
    # границей -- `$((10#...))` выше 9223372036854775807 заворачивается.
    for raw, expected_rc, expected_out in (
            ("0", 0, "0"), ("7", 0, "7"),
            ("0000000000000000000005", 0, "5"),
            ("-1", 2, ""), ("abc", 2, ""),
            ("99999999999999999999", 2, "")):
        script = f"set -u\n{function}\nvalidated_nonnegative_integer CLAUDE_PATCH_GATE_BUDGET {raw!r}\n"
        result = subprocess.run(["bash"], input=script, capture_output=True, text=True, errors="replace")
        require(result.returncode == expected_rc,
                f"budget {raw!r}: rc={result.returncode}, expected {expected_rc}\n"
                f"{result.stdout}{result.stderr}")
        if expected_rc:
            require(raw in result.stderr and "CLAUDE_PATCH_GATE_BUDGET" in result.stderr,
                    f"budget refusal omitted name/value\n{result.stderr}")
            if len(raw) > 19:
                require("9223372036854775807" in result.stderr,
                        f"budget refusal omitted the arithmetic bound\n{result.stderr}")
        else:
            require(result.stdout.strip() == expected_out,
                    f"budget {raw!r}: printed {result.stdout.strip()!r}, "
                    f"expected {expected_out!r}")
    require('while (( i < GATE_BUDGET ))' in source,
            "interface gate is not bounded by arithmetic while")
    require('seq 1 "$GATE_BUDGET"' not in source,
            "interface gate still uses seq for the configurable budget")


def scenario_c12() -> None:
    module = import_file(COSTS, "cap")
    module.reply_headroom = lambda: 76000
    # Волна 26, D-9: фолбэк не вправе объявить больше, чем везёт сам маршрут.
    # routed=32000, headroom=76000 -- лестница проваливается к фолбэкам, и
    # наивный limit.input объявлял бы 116000 маршруту с 32000.
    by_input = module.context_window("small", {"limit": {"input": 116000,
                                                          "context": 192000}},
                                     {"context": 32000})
    require(by_input == 32000,
            f"limit.input fallback declared {by_input} over the route's 32000")
    by_total = module.context_window("small", {"limit": {"context": 192000}},
                                     {"context": 32000})
    require(by_total == 32000,
            f"limit.context fallback declared {by_total} over the route's 32000")
    # Контроль в обе стороны: без известной ёмкости маршрута фолбэк работает
    # как прежде (отсечение не режет неизвестное), а фолбэк МЕНЬШЕ маршрута
    # не поднимается до него.
    uncapped = module.context_window("small", {"limit": {"input": 116000}}, {})
    require(uncapped == 116000,
            f"fallback without a known route was cut to {uncapped}")
    smaller = module.context_window("small", {"limit": {"input": 8000}},
                                    {"context": 32000})
    require(smaller == 8000,
            f"input below the route was cut to {smaller}")


def signing_call(action: Callable[[], None], label: str, expected_rc: int,
                 reason: str = "") -> None:
    output = io.StringIO()
    rc = 0
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        try:
            action()
        except SystemExit as error:
            rc = error.code
    require(rc == expected_rc,
            f"{label}: returned rc={rc}, expected {expected_rc}\n{output.getvalue()}")
    if expected_rc:
        require("ERROR:" in output.getvalue() and reason in output.getvalue(),
                f"{label}: refusal omitted its reason\n{output.getvalue()}")


def signing_shell_cases(identity: str, valid: str) -> None:
    source = PIPELINE.read_text(encoding="utf-8")
    functions = (shell_function(source, "resolve_signing_identity")
                 + shell_function(source, "sign_macos_binary")
                 # Пара ХОЗЯИНА берётся ВЫРЕЗАННОЙ из конвейера: копия правила
                 # здесь стала бы его вторым домом и разошлась бы молча.
                 + shell_function(source, "__host_os_arch")
                 # Диагност платформы (волна 48) зовётся подписантом на ветке
                 # «подписанный образ не назвался»: вырезанный без него
                 # подписант умирал бы кодом 127 «команда не найдена», и случай
                 # «launch failure» краснел бы ПРИБОРОМ вместо предмета.
                 + shell_function(source, "__image_run_note"))
    stage = re.search(r"(?ms)^# --- 4\. signature[^\n]*\n(.*?)^# --- 5\. verify", source)
    require(stage is not None, "signature stage not found")
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        trace = home / "calls"
        binary = home / "signed image"
        stubs = {
            "security": 'printf "%s\\n" "$C13_IDENTITIES"\nexit "$C13_SECURITY_RC"\n',
            "codesign": 'if [[ "$1" == "-v" ]]; then exit "$C13_VERIFY_RC"; fi\n'
                        'exit "$C13_SIGN_RC"\n',
            binary.name: 'printf "%s\\n" "fixture-version"\nexit "$C13_LAUNCH_RC"\n',
        }
        for name, body in stubs.items():
            path = home / name
            label = "binary" if path == binary else name
            path.write_text('#!/bin/bash\n'
                            f'printf "%s\\t" {label} "$@" >> "$C13_TRACE"\n'
                            'printf "\\n" >> "$C13_TRACE"\n' + body, encoding="utf-8")
            path.chmod(0o755)
        env = {"HOME": str(home), "PATH": f"{home}:/usr/bin:/bin", "LC_ALL": "C",
               "TMPDIR": str(home),
               "BUNDLE_ID": "com.anthropic.claude-code", "BIN": str(binary),
               "CLAUDE_PATCH_SIGN_ID": "", "C13_TRACE": str(trace),
               "C13_IDENTITIES": valid, "C13_SECURITY_RC": "0", "C13_SIGN_RC": "0",
               "C13_VERIFY_RC": "0", "C13_LAUNCH_RC": "0"}
        security = ["security", "find-identity", "-v", "-p", "codesigning"]
        sign = ["codesign", "-f", "-i", "com.anthropic.claude-code", "-s", identity, str(binary)]
        strict = ["codesign", "-v", "--strict", str(binary)]
        launch = ["binary", "--version"]
        published = ["publish"]
        cases = [
            ("missing identity", {"C13_IDENTITIES": "0 valid identities found"}, 1, [security]),
            ("security failure", {"C13_SECURITY_RC": "9"}, 1, [security]),
            ("invalid hash", {"C13_IDENTITIES": f'1) {"Z" * 40} "Identity"'}, 1, [security]),
            ("short hash", {"C13_IDENTITIES": f'1) {identity[:-1]} "Identity"'}, 1, [security]),
            ("unnumbered identity", {"C13_IDENTITIES": f'{identity} "Identity"'}, 1, [security]),
            ("unquoted identity", {"C13_IDENTITIES": f'1) {identity} Identity'}, 1, [security]),
            ("valid identity", {}, 0, [security, sign, strict, launch, published]),
            ("explicit identity", {"CLAUDE_PATCH_SIGN_ID": identity, "C13_SECURITY_RC": "9"},
             0, [sign, strict, launch, published]),
            ("explicit dash", {"CLAUDE_PATCH_SIGN_ID": "-"}, 1, []),
            ("sign failure", {"C13_SIGN_RC": "7"}, 1, [security, sign]),
            ("strict failure", {"C13_VERIFY_RC": "7"}, 1, [security, sign, strict]),
            ("launch failure", {"C13_LAUNCH_RC": "7"}, 1, [security, sign, strict, launch]),
        ]
        # Execute the shipping stage, including its refusal before the next stage.
        # Платформа ОБРАЗА -- ФИКСТУРА этого случая, а не измеряемое правило:
        # C13 меряет разрешение личности и вызовы codesign на СВОЁМ образе.
        # Детектор образа проверяется своими зубами (corpus-tools-bench 158/159).
        script = (f"set -euo pipefail\n{functions}\n"
                  "uname() { printf 'Darwin\\n'; }\n"
                  "__image_os_arch() { printf 'darwin-arm64\\n'; }\n" + stage.group(1)
                  + 'printf "publish\\t\\n" >> "$C13_TRACE"\n')
        for label, overrides, expected_rc, expected_calls in cases:
            trace.write_text("", encoding="utf-8")
            result = subprocess.run(["bash"], input=script, env={**env, **overrides},
                                    capture_output=True, text=True, timeout=10)
            require(result.returncode == expected_rc,
                    f"shell {label}: rc={result.returncode}, expected {expected_rc}\n"
                    f"{result.stdout}{result.stderr}")
            calls = [line.split("\t")[:-1] for line in trace.read_text().splitlines()]
            require(calls == expected_calls,
                    f"shell {label}: calls {calls!r} != {expected_calls!r}")
            if expected_rc:
                require("FATAL:" in result.stderr,
                        f"shell {label}: refusal omitted FATAL\n{result.stderr}")


def signing_python_cases(identity: str, valid: str) -> None:
    module = import_file(PATCHER, "signing")
    path = Path("signed image")
    security = ["security", "find-identity", "-v", "-p", "codesigning"]
    sign = ["codesign", "-f", "-i", "com.anthropic.claude-code", "-s", identity, str(path)]
    strict = ["codesign", "-v", "--strict", str(path)]
    cases = [
        ("missing identity", {"identities": "0 valid identities found"}, 1, [security], "no code-signing identity"),
        ("security failure", {"security_rc": 9}, 1, [security], "security find-identity failed"),
        ("invalid hash", {"identities": f'1) {"Z" * 40} "Identity"'}, 1, [security], "no code-signing identity"),
        ("short hash", {"identities": f'1) {identity[:-1]} "Identity"'}, 1, [security], "no code-signing identity"),
        ("unnumbered identity", {"identities": f'{identity} "Identity"'}, 1, [security], "no code-signing identity"),
        ("unquoted identity", {"identities": f'1) {identity} Identity'}, 1, [security], "no code-signing identity"),
        ("valid identity", {}, 0, [security, sign, strict], ""),
        ("explicit identity", {"override": identity, "security_rc": 9}, 0, [sign, strict], ""),
        ("explicit dash", {"override": "-"}, 1, [], "must name a stable signing identity"),
        ("sign failure", {"sign_rc": 7}, 1, [security, sign], "code signing failed"),
        ("strict failure", {"verify_rc": 7}, 1, [security, sign, strict], "strict signature verification failed"),
        ("security unavailable", {"raises": "security"}, 1, [security], "security find-identity could not run"),
        ("sign unavailable", {"raises": "sign"}, 1, [security, sign], "code signing could not run"),
        ("verify unavailable", {"raises": "verify"}, 1, [security, sign, strict], "strict signature verification could not run"),
    ]
    for label, settings, expected_rc, expected_calls, reason in cases:
        calls = []

        def fake_run(command, **options):
            calls.append(command)
            require(options.get("capture_output") and options.get("text"),
                    f"python {label}: signing output is not captured as text")
            step = "security" if command[0] == "security" else "verify" if command[1] == "-v" else "sign"
            if settings.get("raises") == step:
                raise OSError("fixture tool unavailable")
            stdout = settings.get("identities", valid) if step == "security" else ""
            return subprocess.CompletedProcess(command, settings.get(f"{step}_rc", 0),
                                               stdout=stdout, stderr="fixture diagnostic")

        with patch.dict(os.environ, {"CLAUDE_PATCH_SIGN_ID": settings.get("override", "")}), \
                patch.object(module.subprocess, "run", side_effect=fake_run):
            signing_call(lambda: module.sign_macos(path), f"python {label}", expected_rc, reason)
        require(calls == expected_calls,
                f"python {label}: calls {calls!r} != {expected_calls!r}")


def signing_launch_cases() -> None:
    module = import_file(PATCHER, "launch")
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        binary = home / "signed image"
        cases = [
            ("success", "printf 'fixture-version\\n'\n", 0, ""),
            ("stderr success", "printf 'fixture-version\\n' >&2\n", 0, ""),
            ("nonzero", "printf 'fixture-version\\n'\nexit 7\n", 1, "--version failed"),
            ("empty", "exit 0\n", 1, "--version produced no output"),
            ("whitespace", "printf ' \\n\\t'\n", 1, "--version produced no output"),
        ]
        for label, body, expected_rc, reason in cases:
            binary.write_text('#!/bin/sh\n[ "$#" = 1 ] && [ "$1" = "--version" ] || exit 9\n'
                              + body, encoding="utf-8")
            binary.chmod(0o755)
            signing_call(lambda: module.verify_binary_launch(binary),
                         f"python launch {label}", expected_rc, reason)
        binary.chmod(0o600)
        signing_call(lambda: module.verify_binary_launch(binary),
                     "python launch permission error", 1, "--version could not run")
        signing_call(lambda: module.verify_binary_launch(home / "absent"),
                     "python launch missing executable", 1, "--version could not run")
        with patch.object(module.subprocess, "run",
                          side_effect=subprocess.TimeoutExpired([str(binary), "--version"], 120)) as run:
            signing_call(lambda: module.verify_binary_launch(binary),
                         "python launch timeout", 1, "--version could not run")
            run.assert_called_once_with([str(binary), "--version"], capture_output=True,
                                        text=True, errors="replace", timeout=120)

        # Only the byte patcher and signer are substituted; chmod, exec and publication are real.
        original_run = subprocess.run
        target, backup = home / "installed", home / "installed.orig"
        for exit_code in (7, 0):
            image = (b"#!/bin/sh\n# " + module.ROUTING_MARKER + b"\n# " + module.ENUM_MARKER
                     + b"\nprintf 'fixture-version\\n'\nexit " + str(exit_code).encode() + b"\n")
            target.write_bytes(b"live installation")
            backup.write_bytes(b" " * len(image))

            def patch_or_run(command, **options):
                if command[:2] == [sys.executable, str(module.PATCHER)]:
                    Path(command[3]).write_bytes(image)
                    return subprocess.CompletedProcess(command, 0)
                return original_run(command, **options)

            with patch.object(module, "sign"), \
                    patch.object(module.subprocess, "run", side_effect=patch_or_run):
                signing_call(lambda: module.patch_binary(target, backup),
                             f"python staged launch exit {exit_code}", 1 if exit_code else 0,
                             "--version failed")
            require(target.read_bytes() == (b"live installation" if exit_code else image),
                    f"python staged launch exit {exit_code}: wrong bytes published")
            require(backup.read_bytes() == b" " * len(image), "launch check changed the pristine backup")
            require(not list(home.glob(".claude-patched-*")), "launch check left staging files behind")


def scenario_c13() -> None:
    identity = "a1B2" * 10
    valid = f'  1) {identity} "Apple Development: Fixture"\n     1 valid identities found\n'
    signing_shell_cases(identity, valid)
    signing_python_cases(identity, valid)
    signing_launch_cases()


def scenario_c14() -> None:
    # Wave 230: an instrument that sits in place and imports is not proven
    # able to see openings -- with opener_match fully blinded this bench
    # passed its whole self-check, a verdict in name only. The bench must
    # refuse to measure (code 2, named reason) when the anchor's own teeth
    # fail, and the teeth must have RUN at startup.
    require(ANCHOR_TEETH_RAN, "anchor teeth never ran at startup")
    def _broken_teeth() -> None:
        print("ЯКОРЬ HEREDOC ПОТЕРЯЛ ФОРМУ: синтетика сценария C14")
        sys.exit(1)
    saved = _anchor.self_check
    _anchor.self_check = _broken_teeth
    try:
        with contextlib.redirect_stdout(io.StringIO()) as captured:
            try:
                _anchor_teeth_hold()
            except SystemExit as error:
                require(error.code == 2, f"refusal code is {error.code}, not 2")
            else:
                raise BenchFailure("blinded anchor accepted: bench would measure on")
    finally:
        _anchor.self_check = saved
    out = captured.getvalue()
    require("НЕ ДЕРЖИТ ФОРМУ" in out and "синтетика сценария C14" in out,
            f"refusal is not named: {out!r}")


def scenario_c15() -> None:
    # #53, §0.1/§0.4 герметично: предмет дрейфа -- ЖИВОЙ список прокси против
    # строк конфига. Имя из живого ответа без строки цены ИЛИ окна, которую
    # источник мог бы написать, -- КРАСНЫЙ (конфиг протух); имя, которого
    # источник не знает, -- ЖЁЛТЫЙ (счётчик, никогда не красный: выдуманная
    # цена хуже отсутствующей); недоступный прокси -- отказ мерить (код 2),
    # не ноль. Каталог и живой список -- РАЗНЫЕ источники (замер 17.09:
    # пересечение 3 из 10), их расхождение печатается фактом и вердикт не
    # красит. Проверка чисто читающая: подменённый конфиг обязан вернуться
    # байт-в-байт и без бэкапа.
    source = {"vendor": {"models": {
        "drift-model": {"cost": {"input": 1.25, "output": 5},
                         "limit": {"input": 120000, "context": 160000}},
        "synced-model": {"cost": {"input": 2, "output": 8},
                          "limit": {"context": 200000}},
    }}}
    routes = {
        "drift-model": {"name": None, "context": None,
                        "providers": ["fixture"], "enabled": False},
        "ghost-model": {"name": None, "context": 32000,
                        "providers": ["fixture"], "enabled": True},
    }
    stats = {"records": 2, "providers": 1, "enabled": 1}

    rc, before, after, output, backups = run_costs_main(
        {"customModelCosts": {}, "customModelContextWindows": {}},
        catalogue=source, live_ids=["drift-model"],
        proxy_catalogue=routes, proxy_stats=stats, argv=["--check-drift"])
    require(rc == 1, f"live gap did not redden the drift check: rc={rc}\n{output}")
    require(after == before, "drift check is not read-only: config changed")
    require(not backups, f"drift check took a backup: {backups}")
    require("RED drift-model" in output and "no price row" in output
            and "no window row" in output,
            f"red case did not name the model and both missing rows\n{output}")
    require("records 2" in output and "providers 1" in output
            and "enabled 1" in output and "unique published names 2" in output,
            f"catalogue denominators not named in the drift output\n{output}")

    synced = {"customModelCosts": {"synced-model": {"inputTokens": 2}},
              "customModelContextWindows": {"synced-model": 200000}}
    rc, before, after, output, backups = run_costs_main(
        synced, catalogue=source, live_ids=["synced-model"],
        proxy_catalogue=routes, proxy_stats=stats, argv=["--check-drift"])
    require(rc == 0,
            f"green case (every row present) returned rc={rc} -- a discrepancy "
            f"fact line must not paint the check red\n{output}")
    require(after == before and not backups,
            "green drift check wrote to the config")
    require("enabled in the catalogue but not served: 1" in output
            and "ghost-model" in output
            and "served but not enabled in the catalogue: 1" in output,
            f"catalogue/live discrepancy not named as a fact line\n{output}")

    rc, _, after, output, _ = run_costs_main(
        {"customModelCosts": {}, "customModelContextWindows": {}},
        catalogue={"vendor": {"models": {}}}, live_ids=["unknown-model"],
        argv=["--check-drift"])
    require(rc == 0,
            f"a not-in-source gap painted the check red: rc={rc}\n{output}")
    require("not in source: 1" in output and "YELLOW unknown-model" in output,
            f"yellow case not named with its counter\n{output}")
    require("absent, skipped" in output,
            f"absent catalogue line changed form\n{output}")

    rc, _, _, output, _ = run_costs_main(
        {"customModelCosts": {}, "customModelContextWindows": {}},
        catalogue=source, proxy_unreachable=True, argv=["--check-drift"])
    require(rc == 2,
            f"unreachable proxy answered instead of refusing to measure: rc={rc}\n{output}")
    require("cannot reach the proxy" in output,
            f"refusal did not name the proxy\n{output}")


def scenario_c16() -> None:
    # #53, §0.2 (замер §2): прокси публикует провайдера ДВУМЯ формами --
    # голый список моделей и обёртка {"models": [...], "priority": N}. Разбор
    # одной формы занижает МОЛЧА (первый счёт контроллера: 77 вместо 682).
    # Синтетический каталог несёт ОБЕ формы; уникальные имена и сырые записи
    # обязаны быть суммой по обеим формам, «включённые» -- считаться с обеих.
    module = import_file(COSTS, "forms")
    with tempfile.TemporaryDirectory() as raw:
        catalogue_path = Path(raw) / "models.json"
        catalogue_path.write_text(json.dumps({
            "bare": [
                {"alias": "bare-one", "name": "bare-one",
                 "context-length": 111, "enabled": True},
                {"alias": "bare-two", "name": "bare-two",
                 "context-length": 222, "enabled": False},
            ],
            "wrapped": {
                "priority": 3,
                "models": [
                    {"alias": "wrapped-one", "name": "wrapped-one",
                     "context-length": 333, "enabled": True},
                ],
            },
        }), encoding="utf-8")
        module.PROXY_CATALOGUE_PATH = str(catalogue_path)
        loaded = module.load_proxy_catalogue()
        require(sorted(loaded) == ["bare-one", "bare-two", "wrapped-one"],
                f"both provider shapes must yield their names: {sorted(loaded)}")
        require(loaded["wrapped-one"]["context"] == 333
                and loaded["wrapped-one"]["providers"] == ["wrapped"]
                and loaded["wrapped-one"]["enabled"] is True,
                f"wrapper-form entry lost its route facts: {loaded['wrapped-one']}")
        stats = module.load_proxy_catalogue.last_stats
        require(stats == {"providers": 2, "records": 3, "enabled": 2},
                f"raw denominators must count BOTH provider shapes: {stats!r}")


@contextlib.contextmanager
def sync_fixture(*, ccd: bool = False):
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        directory = home / "ccd" if ccd else home
        directory.mkdir(exist_ok=True)
        env = bench_env(home, ccd=str(directory) if ccd else None)
        with patch.dict(os.environ, env, clear=True):
            module = import_file(COSTS, "sync_fixture")
            path = directory / ".claude.json"
            path.write_text('{"other": "original"}', encoding="utf-8")
            module.proxy_model_ids = lambda: ["fixture-model"]
            module.load_proxy_catalogue = lambda: {}
            source = {"vendor": {"models": {
                "fixture-model": {"cost": {"input": 1, "output": 2},
                                  "limit": {"context": 200000}}}}}
            module.fetch_json = lambda url: source
            module.CONFIG_LOCK_TIMEOUT_SECONDS = 1
            yield module, path, home


def invoke_sync(module, argv=()):
    output = io.StringIO()
    with patch.object(sys, "argv", [str(COSTS), *argv]), \
            contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        rc = module.main()
    return rc, output.getvalue()


def invoke_sync_split(module, argv=()):
    """Streams captured SEPARATELY: a tooth that pins a line to stderr must
    also prove it does not leak to stdout (V2)."""
    out, err = io.StringIO(), io.StringIO()
    with patch.object(sys, "argv", [str(COSTS), *argv]), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = module.main()
    return rc, out.getvalue(), err.getvalue()


def teardown_owned_lock(lock: str) -> None:
    """Remove OUR published lock directory the way a rival takeover does:
    the owner file first, then the directory. A pre-v2 directory (no owner)
    goes the same way -- the guarded unlink covers both formats."""
    try:
        os.unlink(os.path.join(lock, "owner"))
    except OSError:
        pass
    os.rmdir(lock)


def sync_trace(module, path):
    """Full refusal-purity snapshot: every name in the config directory and in
    the cache/seen directories, with bytes — not just the four paths the sync
    owns. The only allowed difference across a refusal is the lock lifecycle,
    and after a completed run no lock may remain."""
    trace = {}

    def record(directory: Path, prefix: str) -> None:
        if not directory.is_dir():
            trace[prefix] = None
            return
        for entry in sorted(directory.iterdir()):
            key = f"{prefix}{entry.name}"
            trace[key] = entry.read_bytes() if entry.is_file() else "<dir>"

    files = [path, Path(module.CACHE_PATH), Path(module.SEEN_PATH)]
    files.extend(sorted(path.parent.glob(path.name + ".backup.*")))
    trace.update({str(p): p.read_bytes() if p.exists() else None for p in files})
    record(path.parent, "configdir:")
    record(Path(module.CACHE_PATH).parent, "cachedir:")
    record(Path(module.SEEN_PATH).parent, "seendir:")
    return trace


def fixed_second(module):
    return patch.object(module.time, "strftime", return_value="20261001-120000")


def scenario_c17() -> None:
    with sync_fixture() as (module, path, _):
        first = path.read_bytes()
        with fixed_second(module):
            rc, output = invoke_sync(module)
            require(rc == 0, f"same-second first rc={rc}\n{output}")
            second = path.read_bytes()
            rc, output = invoke_sync(module)
        require(rc == 0, f"same-second second rc={rc}\n{output}")
        backups = sorted(path.parent.glob(path.name + ".backup.*"))
        # Bytes first: a publisher that overwrites an existing name instead of
        # taking the next suffix keeps the name count plausible only until the
        # FIRST backup's own bytes are checked.
        require([p.read_bytes() for p in backups] == [first, second],
                "same-second backups lost their own run's bytes")
        require([p.name for p in backups] == [path.name + ".backup.u20261001-120000",
                                             path.name + ".backup.u20261001-120000.01"],
                f"same-second backup names: {[p.name for p in backups]}")


def scenario_c18() -> None:
    failures = []
    # family routes the fixture; phrase says the exit names itself with the
    # "nothing written" form (drift verdicts and the proxy-listing refusal
    # have their own named forms).
    cases = [("initial missing", 1, "initial", True),
             ("initial not JSON", 1, "initial", True),
             ("initial not object", 1, "initial", True),
             ("initial unreadable", 1, "initial", True),
             ("proxy listing unreachable", 1, "proxy", False),
             ("catalogue unavailable", 1, "catalogue", True),
             ("empty replacement costs", 1, "empty-costs", True),
             ("empty replacement windows", 1, "empty-windows", True),
             ("nn exhausted", 3, "nn", True),
             ("re-read missing", 1, "re-read", True),
             ("re-read not JSON", 1, "re-read", True),
             ("re-read not object", 1, "re-read", True),
             ("settings unreadable", 2, "settings", True),
             ("empty CCD", 2, "ccd", True),
             ("empty HOME", 2, "home", True),
             ("lock held", 5, "lock-held", True),
             ("lock not directory", 5, "lock-file", True),
             ("drift proxy unreachable", 2, "drift-proxy", False),
             ("drift catalogue unreachable", 2, "drift-catalogue", False),
             ("drift settings unreadable", 2, "drift-settings", True),
             ("drift red", 1, "drift-red", False),
             ("drift clean", 0, "drift-clean", False)]
    cost_only = {"vendor": {"models": {
        "fixture-model": {"cost": {"input": 1, "output": 2}}}}}

    def unreadable_open(config_path):
        # Д5: сам ЧИТАТЕЛЬ отказывает -- байты на диске целы, трасса остаётся
        # читаемой, и на отказе проверяется только путь продукта (Permission
        # OSError, а не битые байты: у того случая свои строки выше).
        product_open = open

        def refused(name, *args, **kwargs):
            if str(name) == str(config_path):
                raise PermissionError(13, "fixture: config unreadable")
            return product_open(name, *args, **kwargs)

        return patch("builtins.open", refused)

    for label, expected_rc, family, phrase in cases:
        with sync_fixture() as (module, path, home):
            for side, payload in ((module.CACHE_PATH, {"cached": {"models": {}}}),
                                  (module.SEEN_PATH, ["remembered"])):
                target = Path(side)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(json.dumps(payload), encoding="utf-8")
            # The temp is of the OLD released form, bound to the config base:
            # a refusal must leave even a sweepable-looking temp alone.
            dead_temp = path.parent / f".tmp-copy-{reaped_pid()}-{path.name}.backup.u1-000000"
            dead_temp.write_text("refusal must not sweep")
            if family == "initial":
                if label == "initial missing":
                    path.unlink()
                elif label == "initial not JSON":
                    path.write_text("not JSON")
                elif label == "initial unreadable":
                    pass  # the reader is blinded at open() below, not on disk
                else:
                    path.write_text("[]")
            elif family == "proxy":
                module.proxy_model_ids = lambda: (_ for _ in ()).throw(
                    OSError("fixture proxy down"))
            elif family == "catalogue":
                module.fetch_catalogue = lambda *args, **kwargs: (_ for _ in ()).throw(
                    OSError("fixture catalogue unavailable"))
            elif family == "empty-costs":
                path.write_text('{"customModelCosts":{"missing":{"inputTokens":1}},'
                                '"customModelContextWindows":{"missing":200000}}')
                module.fetch_json = lambda url: {}
            elif family == "empty-windows":
                path.write_text('{"customModelCosts":{"missing":{"inputTokens":1}},'
                                '"customModelContextWindows":{"missing":200000}}')
                module.fetch_json = lambda url: cost_only
            elif family == "lock-held":
                Path(str(path) + ".lock").mkdir()
            elif family == "lock-file":
                Path(str(path) + ".lock").write_text("not a directory")
            elif family == "settings":
                (home / ".claude").mkdir()
                (home / ".claude" / "settings.json").write_text("not JSON")
            elif family == "ccd":
                os.environ["CLAUDE_CONFIG_DIR"] = ""
            elif family == "home":
                os.environ["HOME"] = ""
            elif family == "drift-proxy":
                module.proxy_model_ids = lambda: (_ for _ in ()).throw(
                    OSError("fixture proxy down"))
            elif family == "drift-catalogue":
                module.fetch_catalogue = lambda *args, **kwargs: (_ for _ in ()).throw(
                    OSError("fixture catalogue unavailable"))
            elif family == "drift-settings":
                (home / ".claude").mkdir()
                (home / ".claude" / "settings.json").write_text("not JSON")
            elif family == "drift-clean":
                path.write_text('{"customModelCosts":{"fixture-model":'
                                '{"inputTokens":1,"outputTokens":2,"promptCacheWriteTokens":1,'
                                '"promptCacheReadTokens":1,"webSearchRequests":0.0}},'
                                '"customModelContextWindows":{"fixture-model":200000}}')
            expected = sync_trace(module, path)
            if family == "re-read":
                def changed_proxy():
                    if label == "re-read missing":
                        path.unlink()
                    else:
                        path.write_text("not JSON" if label == "re-read not JSON" else "[]")
                    # Снимок пересобирается ЦЕЛИКОМ: побайтовое обновление
                    # оставило бы исчезнувшие имена каталога как устаревшие
                    # ключи, и отказ казался бы оставившим следы.
                    expected.clear()
                    expected.update(sync_trace(module, path))
                    return ["fixture-model"]
                module.proxy_model_ids = changed_proxy
            argv = ["--check-drift"] if family.startswith("drift") else []
            try:
                with unreadable_open(path) if label == "initial unreadable" \
                        else contextlib.nullcontext(), \
                        fixed_second(module) if family == "nn" else contextlib.nullcontext():
                    if family == "nn":
                        for number in range(100):
                            suffix = "" if number == 0 else f".{number:02d}"
                            (path.parent / f"{path.name}.backup.u20261001-120000{suffix}"
                             ).write_text("occupied")
                        expected = sync_trace(module, path)
                    rc, output = invoke_sync(module, argv)
                if rc != expected_rc:
                    failures.append(f"{label}: rc={rc}, expected {expected_rc}\n{output}")
                if phrase and "nothing written" not in output:
                    failures.append(f"{label}: named refusal missing\n{output}")
            except Exception as error:
                failures.append(f"{label}: uncaught {error!r}")
            if sync_trace(module, path) != expected:
                failures.append(f"{label}: refusal left traces")
    # A refusal with no pre-existing side files must not create them either;
    # the finding joins the shared list so one branch's red cannot mask
    # another's in the reported cause.
    with sync_fixture() as (module, path, home):
        path.write_text("not JSON")
        expected = sync_trace(module, path)
        rc, output = invoke_sync(module)
        if rc != 1:
            failures.append(f"no-side-files: rc={rc}, expected 1\n{output}")
        elif sync_trace(module, path) != expected:
            failures.append("no-side-files: refusal created side files")
    require(not failures, "refusal-no-trace: " + "\n".join(failures))


def reaped_pid() -> int:
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    pid = child.pid
    child.wait()
    return pid


def validate_costs_path():
    import ast
    tree = ast.parse(VALIDATE.read_text(encoding="utf-8"))
    selected = [node for node in tree.body
                if isinstance(node, ast.FunctionDef) and node.name == "config_path"]
    namespace = {"os": os}
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(VALIDATE), "exec"), namespace)
    # CONSTRAINT: the judge resolves the path lazily (Д10), so the mirror is
    # the function itself, never a value captured at import.
    return namespace["config_path"]()


def scenario_c19() -> None:
    source = PIPELINE.read_text(encoding="utf-8")
    helper = shell_function(source, "__config_json_path")

    def bash_resolve(env):
        return subprocess.run(["bash"], input=helper + "\n__config_json_path\n",
                              capture_output=True, text=True, env=env)

    def resolver_states(module):
        """(python, judge) as ('refused', message) or ('path', value)."""
        states = []
        for action in (module.config_path, validate_costs_path):
            try:
                states.append(("path", action()))
            except Exception as error:
                states.append(("refused", str(error)))
        return states

    def compare(label, module, env):
        (kind_a, first), (kind_b, second) = resolver_states(module)
        result = bash_resolve(env)
        if kind_a == "refused" or kind_b == "refused":
            require(kind_a == kind_b == "refused",
                    f"{label}: resolvers disagree on refusal: {kind_a}/{kind_b}")
            require("nothing written" in first and "nothing written" in second,
                    f"{label}: python/judge refusal not named: {first!r}/{second!r}")
            require(result.returncode == 2 and "nothing written" in result.stderr,
                    f"{label}: bash did not refuse: rc={result.returncode} {result.stderr!r}")
            return
        require(result.returncode == 0, f"{label}: bash rc={result.returncode}\n{result.stderr}")
        require(first == second == result.stdout.strip(),
                f"{label}: paths disagree: {first!r} / {second!r} / {result.stdout!r}")

    for ccd in (False, True):
        for oauth in (False, True):
            for legacy in (False, True):
                with sync_fixture(ccd=ccd) as (module, path, home):
                    if oauth:
                        os.environ["CLAUDE_CODE_CUSTOM_OAUTH_URL"] = "fixture-oauth"
                    settings = path.parent if ccd else home / ".claude"
                    if legacy:
                        settings.mkdir(exist_ok=True)
                        (settings / ".config.json").write_text("{}")
                    compare(f"path-parity CCD={ccd} oauth={oauth} legacy={legacy}",
                            module, dict(os.environ))

    # Д9: значения CCD, на которых склейка расходится с os.path.join, и пустой
    # (установленный, но незаданный) OAuth; каждый случай × legacy.
    ccd_values = {"relative": "rel-ccd", "trailing slash": None, "double slash": None}
    for name in ccd_values:
        for legacy in (False, True):
            with sync_fixture() as (module, path, home):
                directory = home / "ccd"
                directory.mkdir(exist_ok=True)
                value = {"relative": "rel-ccd",
                         "trailing slash": str(directory) + "/",
                         "double slash": str(directory) + "//"}[name]
                if name == "relative":
                    os.chdir(home)
                os.environ["CLAUDE_CONFIG_DIR"] = value
                if legacy:
                    (directory if name != "relative" else home / "rel-ccd").mkdir(
                        parents=True, exist_ok=True)
                    ((directory if name != "relative" else home / "rel-ccd")
                     / ".config.json").write_text("{}")
                try:
                    compare(f"ccd-value {name} legacy={legacy}", module, dict(os.environ))
                finally:
                    if name == "relative":
                        os.chdir(ROOT)

    # Д9: литеральная `~` в явном CCD не раскрывается -- expanduser
    # принадлежит только HOME-ветке. Легаси-проба сознательно стоит на
    # РАСКРЫТОМ месте: только она различает резолвер, который раскрыл `~`,
    # от резолвера, который честно держит литеральный путь.
    for legacy in (False, True):
        with sync_fixture() as (module, path, home):
            expanded = home / "ccd-literal"
            if legacy:
                expanded.mkdir(parents=True, exist_ok=True)
                (expanded / ".config.json").write_text("{}")
            os.environ["CLAUDE_CONFIG_DIR"] = "~/ccd-literal"
            compare(f"ccd literal-tilde legacy={legacy}", module, dict(os.environ))
    for legacy in (False, True):
        for ccd in (False, True):
            with sync_fixture(ccd=ccd) as (module, path, home):
                os.environ["CLAUDE_CODE_CUSTOM_OAUTH_URL"] = ""
                settings = path.parent if ccd else home / ".claude"
                if legacy:
                    settings.mkdir(exist_ok=True)
                    (settings / ".config.json").write_text("{}")
                compare(f"empty-set oauth ccd={ccd} legacy={legacy}", module, dict(os.environ))

    # Д16: пустой/неустановленный HOME -- все три резолвера отказывают тем же
    # именованным отказом, что при пустом CCD; при заданном CCD HOME не нужен.
    for home_state in ("unset", "empty"):
        for ccd in (False, True):
            for legacy in (False, True):
                with sync_fixture(ccd=ccd) as (module, path, home):
                    settings = path.parent if ccd else home / ".claude"
                    if legacy:
                        settings.mkdir(exist_ok=True)
                        (settings / ".config.json").write_text("{}")
                    if home_state == "empty":
                        os.environ["HOME"] = ""
                    else:
                        os.environ.pop("HOME", None)
                    compare(f"home {home_state} ccd={ccd} legacy={legacy}",
                            module, dict(os.environ))

    with sync_fixture() as (module, _, _):
        os.environ["CLAUDE_CONFIG_DIR"] = ""
        for label, action in (("python", module.config_path), ("validate", validate_costs_path)):
            try:
                action()
            except Exception as error:
                require("CLAUDE_CONFIG_DIR is set but empty" in str(error),
                        f"empty CCD {label}: wrong reason {error}")
            else:
                raise BenchFailure(f"empty CCD {label} accepted")
        result = bash_resolve(dict(os.environ))
        require(result.returncode == 2, f"empty CCD bash rc={result.returncode}")


def scenario_c20() -> None:
    with sync_fixture(ccd=True) as (module, path, home):
        frozen = home / ".claude.json"
        frozen.write_text('{"frozen":true}')
        before = frozen.read_bytes()
        rc, output = invoke_sync(module)
        require(rc == 0, f"ccd-write rc={rc}\n{output}")
        require("fixture-model" in json.loads(path.read_bytes()).get("customModelCosts", {}),
                "ccd-write did not write CCD config")
        require(len(list(path.parent.glob(path.name + ".backup.*"))) == 1,
                "ccd-write backup is not next to CCD config")
        require(frozen.read_bytes() == before, "ccd-write touched HOME config")


def scenario_c21() -> None:
    with sync_fixture() as (module, path, _):
        lock = Path(str(path) + ".lock")
        lock.mkdir()
        before, mtime = sync_trace(module, path), lock.stat().st_mtime_ns
        rc, output = invoke_sync(module)
        require(rc == 5, f"fresh lock rc={rc}\n{output}")
        require(sync_trace(module, path) == before, "fresh lock refusal left traces")
        require(lock.exists() and lock.stat().st_mtime_ns == mtime,
                "foreign fresh lock removed or refreshed")
    with sync_fixture() as (module, path, _):
        lock = Path(str(path) + ".lock")
        lock.mkdir()
        stamp = time.time() - 20
        os.utime(lock, (stamp, stamp))
        rc, output = invoke_sync(module)
        require(rc == 0 and not lock.exists(), f"stale lock not reclaimed/released rc={rc}\n{output}")
    with sync_fixture() as (module, path, _):
        path.write_text('{"customModelCosts":{"missing":{"inputTokens":1}}}')
        module.fetch_json = lambda url: {}
        acquired = []
        mkdir = module.os.mkdir
        def witness_mkdir(name, *args, **kwargs):
            # Свидетель захвата по ОБЕИМ формам: путь замка (до v2) или
            # личный staging-каталог .lock.new.* (v2 -- захвата по пути нет).
            if (str(name) == str(path) + ".lock"
                    or str(name).startswith(str(path) + ".lock.new.")):
                acquired.append(str(name))
            return mkdir(name, *args, **kwargs)
        with patch.object(module.os, "mkdir", side_effect=witness_mkdir):
            rc, output = invoke_sync(module)
        require(rc == 1 and acquired and not Path(str(path) + ".lock").exists(),
                f"own lock not acquired/released on refusal rc={rc}\n{output}")
    with sync_fixture() as (module, path, _):
        # Stale-takeover ДО первой записи: синк обязан отказаться rc 5, а
        # release -- не снести чужой замок, который ему уже не принадлежит.
        # Свидетель -- выживание и mtime ЧУЖОГО замка, не трассы синка.
        real_sweep = module.sweep_stale_temps
        fresh = []

        def takeover_sweep(p):
            lock = str(path) + ".lock"
            abandoned = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
            os.utime(lock, (abandoned, abandoned))
            teardown_owned_lock(lock)
            os.mkdir(lock)
            moment = time.time_ns()
            os.utime(lock, ns=(moment, moment))
            fresh.append(os.stat(lock).st_mtime_ns)
            return real_sweep(p)

        config_before = path.read_bytes()
        with patch.object(module, "sweep_stale_temps", takeover_sweep):
            rc, output = invoke_sync(module)
        lock = Path(str(path) + ".lock")
        require(rc == 5, f"stale-takeover rc={rc}\n{output}")
        require("lost to another writer" in output,
                f"stale-takeover not named\n{output}")
        require(path.read_bytes() == config_before
                and not list(path.parent.glob(path.name + ".backup.*"))
                and not os.path.exists(module.CACHE_PATH)
                and not os.path.exists(module.SEEN_PATH),
                "stale-takeover refusal left traces")
        require(lock.is_dir() and lock.stat().st_mtime_ns == fresh[0],
                "stale-takeover released the foreign lock")


def scenario_c22() -> None:
    with sync_fixture() as (module, path, _):
        module.fetch_json = lambda url: {}
        rc, output = invoke_sync(module)
        require(rc == 0 and not Path(module.CACHE_PATH).exists(),
                f"empty network catalogue poisoned cache rc={rc}\n{output}")
        cache = Path(module.CACHE_PATH)
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text("{}")
        original = OSError("fixture network down")
        module.fetch_json = lambda url: (_ for _ in ()).throw(original)
        try:
            module.fetch_catalogue()
        except Exception as error:
            require(error is original, f"empty cache wrong error: {error}")
        else:
            raise BenchFailure("empty cached catalogue accepted")


def scenario_c23() -> None:
    source = PIPELINE.read_text(encoding="utf-8")
    function = shell_function(source, "prune_config_backups")
    helper = (shell_function(source, "__config_json_path")
              if "__config_json_path()" in source else "")
    with sync_fixture(ccd=True) as (_, path, home):
        names = [f".claude.json.backup.20260{i}01-000000" for i in range(1, 5)]
        names += [".claude.json.backup.u20261001-000000",
                  ".claude.json.backup.u20261001-000000.01",
                  ".claude.json.backup.u20261002-000000"]
        for name in names + [".claude.json.backup.foreign"]:
            (home / name).write_text(name)
        ccd_names = [f".claude.json.backup.u2026100{i}-000000" for i in range(1, 6)]
        for name in ccd_names:
            (path.parent / name).write_text(name)
        result = subprocess.run(["bash"], input="set -euo pipefail\n" + helper + function
                                + "\nprune_config_backups\n", env=dict(os.environ),
                                capture_output=True, text=True)
        require(result.returncode == 0, f"prune-forms rc={result.returncode}\n{result.stderr}")
        require({p.name for p in home.glob(".claude.json.backup.*")}
                == set(names[-3:]) | {".claude.json.backup.foreign"},
                "prune-forms HOME did not keep newest three new forms")
        require({p.name for p in path.parent.glob(".claude.json.backup.*")} == set(ccd_names[-3:]),
                "prune-forms CCD did not keep newest three")


def scenario_c24() -> None:
    with sync_fixture() as (module, path, _):
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        dead = child.pid
        child.wait()
        live = os.getpid()
        past = time.time() - 2 * 3600
        names = [path.name + f".tmp.{dead}", f".tmp-copy-{dead}-{path.name}.backup.u1-1",
                 path.name + f".tmp.{live}", f".tmp-copy-{live}-{path.name}.backup.u1-2",
                 "x.tmp.123"]
        for name in names:
            (path.parent / name).write_text(name)
        # Возраст у всех форм-темпов за час: живой pid -- ЕДИНСТВЕННАЯ защита
        # живого писателя, и мутация живости обязана краснить именно её.
        for name in names[:4]:
            os.utime(path.parent / name, (past, past))
        rc, output = invoke_sync(module)
        require(rc == 0, f"sweep rc={rc}\n{output}")
        require(not any((path.parent / name).exists() for name in names[:2]),
                "sweep did not remove dead-pid temps")
        require(all((path.parent / name).exists() for name in names[2:]),
                "sweep touched live or foreign temps")
        require(output.count("Swept stale temp ") == 2, "sweep did not name both removals")


def scenario_c25() -> None:
    with sync_fixture() as (module, path, _):
        before = path.read_bytes()
        module.save_seen = lambda ids, lock=None: (_ for _ in ()).throw(OSError("fixture seen failure"))
        rc, output = invoke_sync(module)
        require(rc == 4, f"side-file-warning rc={rc}\n{output}")
        require(path.read_bytes() != before and "fixture-model" in json.loads(
            path.read_bytes())["customModelCosts"], "side-file-warning config not published")
        require("WARNING: config written; side file " + module.SEEN_PATH
                + " not written: fixture seen failure" in output, "side-file-warning missing reason/path")
        require(not Path(str(path) + ".lock").exists(), "side-file-warning own lock remained")
    with sync_fixture() as (module, path, home):
        # Захват перед записью seen (последняя публикация): потеря владения на
        # ней -- именованный отказ rc 5, а не предупреждение бокового файла
        # rc 4; следующей проверки после seen больше нет.
        real_dump = module.json.dump

        def takeover_after_seen_dump(payload, fh, **dump_kw):
            real_dump(payload, fh, **dump_kw)
            if isinstance(payload, list):
                lock = str(path) + ".lock"
                abandoned = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
                os.utime(lock, (abandoned, abandoned))
                teardown_owned_lock(lock)
                os.mkdir(lock)
                moment = time.time_ns()
                os.utime(lock, ns=(moment, moment))

        with patch.object(module.json, "dump", takeover_after_seen_dump):
            rc, output = invoke_sync(module)
        require(rc == 5, f"seen-takeover rc={rc}\n{output}")
        require("lost to another writer" in output,
                f"seen-takeover not named\n{output}")


def scenario_c26() -> None:
    with sync_fixture() as (module, path, home):
        (home / ".claude").mkdir()
        settings = home / ".claude" / "settings.json"
        settings.write_text("not JSON")
        before = sync_trace(module, path)
        rc, output = invoke_sync(module)
        require(rc == 2, f"headroom-unreadable rc={rc}\n{output}")
        require(sync_trace(module, path) == before, "headroom-unreadable left traces")
        require(f"ERROR: {settings} unreadable (" in output and "nothing written" in output,
                "headroom-unreadable missing named refusal")
        require(not Path(str(path) + ".lock").exists(), "headroom-unreadable own lock remained")
        rc, output = invoke_sync(module, ["--check-drift"])
        require(rc == 2 and f"ERROR: {settings} unreadable (" in output
                and "nothing written" in output,
                f"headroom-unreadable drift missing named rc2 refusal rc={rc}\n{output}")
        require(sync_trace(module, path) == before, "headroom-unreadable drift left traces")


def scenario_c27() -> None:
    # Д1(а): внешний писатель забирает замок по протоколу продукта. Синк
    # обязан отказаться rc 5, не тронув ни конфиг продукта, ни его замок.
    with sync_fixture() as (module, path, home):
        # Захват ДО явного touch перед публикацией: touch обязан проверить
        # владение и отказаться, а не усыновить чужую идентичность -- иначе
        # публикация идёт под чужим замком, а release сносит ЕГО каталог.
        module.CONFIG_LOCK_STALE_SECONDS = 1
        module.CONFIG_LOCK_TIMEOUT_SECONDS = 5
        real_touch = module.ConfigLock.touch
        taken = []

        def takeover_touch(self):
            # start() зовёт _adopt() напрямую, не touch(); явный вызов перед
            # публикацией приходит с уже записанной идентичностью. Захват один,
            # перед первым явным вызовом; повторные вызовы heartbeat гасит `taken`.
            if self.identity is None or taken:
                return real_touch(self)
            taken.append(True)
            lock = str(path) + ".lock"
            abandoned = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
            os.utime(lock, (abandoned, abandoned))
            teardown_owned_lock(lock)
            os.mkdir(lock)
            moment = time.time_ns()
            os.utime(lock, ns=(moment, moment))
            path.write_text('{"other": "product"}', encoding="utf-8")
            return real_touch(self)

        with patch.object(module.ConfigLock, "touch", takeover_touch):
            rc, output = invoke_sync(module)
        require(Path(str(path) + ".lock").is_dir(),
                "takeover-refusal released the product's lock")
        require(rc == 5, f"takeover-refusal rc={rc}\n{output}")
        require("lost to another writer" in output,
                f"takeover-refusal not named\n{output}")
        require(json.loads(path.read_bytes()) == {"other": "product"},
                "takeover-refusal overwrote the product's config")
        require("lock not released: owned by another writer" in output,
                "takeover-refusal release did not name the foreign owner")
    with sync_fixture() as (module, path, home):
        # Захват ПОСЕРЕДИНЕ публикации (между touch и link): отказ обязан
        # прийти от проверки непосредственно перед сисколлом.
        module.CONFIG_LOCK_STALE_SECONDS = 1
        module.CONFIG_LOCK_TIMEOUT_SECONDS = 5
        real_publish = module.publish_backup

        def product_takeover():
            time.sleep(1.2)
            lock = str(path) + ".lock"
            info = os.stat(lock)
            if time.time() - info.st_mtime >= 1:
                teardown_owned_lock(lock)
                os.mkdir(lock)
                moment = time.time_ns()
                os.utime(lock, ns=(moment, moment))
                path.write_text('{"other": "product"}', encoding="utf-8")

        def pausing_publish(src, lock=None):
            threading.Thread(target=product_takeover).start()
            time.sleep(1.6)
            return real_publish(src, lock=lock)

        with patch.object(module, "publish_backup", pausing_publish):
            rc, output = invoke_sync(module)
        require(rc == 5, f"takeover-refusal rc={rc}\n{output}")
        require("lost to another writer" in output,
                f"takeover-refusal not named\n{output}")
        require(json.loads(path.read_bytes()) == {"other": "product"},
                "takeover-refusal overwrote the product's config")
        require(Path(str(path) + ".lock").is_dir(),
                "takeover-refusal released the product's lock")
        require("lock not released: owned by another writer" in output,
                "takeover-refusal release did not name the foreign owner")
    with sync_fixture() as (module, path, home):
        # F1-окно: чужой rmdir+mkdir МЕЖДУ проверкой touch и utime внутри
        # _adopt. Refresh-путь обязан отказать по смене inode, а не усыновить
        # чужой каталог -- иначе публикация идёт под чужим замком, а release
        # сносит ЕГО каталог как «свой».
        module.CONFIG_LOCK_STALE_SECONDS = 1
        module.CONFIG_LOCK_TIMEOUT_SECONDS = 5
        real_lock_class = module.ConfigLock
        owned_locks = []
        lock_fd = []

        class WitnessLock(real_lock_class):
            def __init__(self, lock_path):
                super().__init__(lock_path)
                owned_locks.append(self)

        real_open = module.os.open
        real_utime = module.os.utime
        taken = []

        # G10: дверцы только в главной нити -- иначе сердцебиение срабатывает
        # раньше главной и вердикт зависит от расписания, а не от кода.
        # Совпадение двойное: по пути (fd-форма FIX5 зовёт utime по fd,
        # открытому один раз) и по пути-строке (форма до FIX5).
        def takeover_open(name, *args, **kwargs):
            if (str(name) == str(path) + ".lock" and owned_locks
                    and owned_locks[0].identity is not None and not taken
                    and threading.current_thread() is threading.main_thread()):
                taken.append("open")
                abandoned = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
                real_utime(name, (abandoned, abandoned))
                teardown_owned_lock(name)
                os.mkdir(name)
                moment = time.time_ns()
                real_utime(name, ns=(moment, moment))
            value = real_open(name, *args, **kwargs)
            # Запись fd -- по обеим формам создания (путь замка до v2,
            # личный staging-каталог v2): refresh касается УДЕРЖИВАЕМОГО
            # дескриптора, и предикат utime ниже ловит его по записи.
            if str(name) == str(path) + ".lock" or str(name).startswith(
                    str(path) + ".lock.new."):
                lock_fd.append(value)
            return value

        def takeover_utime(name, *args, **kwargs):
            if (not taken and owned_locks
                    and owned_locks[0].identity is not None
                    and threading.current_thread() is threading.main_thread()
                    and (str(name) == str(path) + ".lock"
                         or (lock_fd and name == lock_fd[-1]))):
                taken.append("utime")
                abandoned = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
                real_utime(str(path) + ".lock", (abandoned, abandoned))
                teardown_owned_lock(str(path) + ".lock")
                os.mkdir(str(path) + ".lock")
                moment = time.time_ns()
                real_utime(str(path) + ".lock", ns=(moment, moment))
            return real_utime(name, *args, **kwargs)

        config_before = path.read_bytes()
        with patch.object(module, "ConfigLock", WitnessLock), \
                patch.object(module.os, "open", side_effect=takeover_open), \
                patch.object(module.os, "utime", side_effect=takeover_utime):
            rc, output = invoke_sync(module)
        require(Path(str(path) + ".lock").is_dir(),
                "adopt-window released the foreign lock")
        require(rc == 5, f"adopt-window rc={rc}\n{output}")
        require("lost to another writer" in output,
                f"adopt-window not named\n{output}")
        require(path.read_bytes() == config_before,
                "adopt-window overwrote the product's config")
        require(not list(path.parent.glob(path.name + ".backup.*")),
                "adopt-window published a backup")


def scenario_c28() -> None:
    # Д1(б): два писателя в нитях. Пока победитель держит замок дольше чужого
    # окта-таймаута и дольше устаревания, второй обязан отказаться rc 5, а не
    # отбирать замок; публикующий ровно один.
    with sync_fixture() as (module, path, home):
        module.CONFIG_LOCK_STALE_SECONDS = 3.5
        module.CONFIG_LOCK_TIMEOUT_SECONDS = 5.0
        real_publish = module.publish_backup
        winner_holding = []

        def holding_publish(src, lock=None):
            if not winner_holding:
                winner_holding.append(True)
                time.sleep(5.5)
            return real_publish(src, lock=lock)

        acquired = []
        # Свидетель захвата по форме протокола: до v2 -- успешный mkdir по
        # пути замка; v2 -- успешная публикация без замены (rename_noreplace).
        if hasattr(module, "rename_noreplace"):
            real_publish_rename = module.rename_noreplace

            def witness_rename(src, dst):
                result = real_publish_rename(src, dst)
                if str(dst) == str(path) + ".lock":
                    acquired.append("A" if len(acquired) == 0 else "B")
                return result

            publisher_patch = patch.object(module, "rename_noreplace",
                                           witness_rename)
        else:
            mkdir = module.os.mkdir

            def witness_mkdir(name, *args, **kwargs):
                try:
                    value = mkdir(name, *args, **kwargs)
                except FileExistsError:
                    raise
                if str(name) == str(path) + ".lock":
                    acquired.append("A" if len(acquired) == 0 else "B")
                return value

            publisher_patch = patch.object(module.os, "mkdir",
                                           side_effect=witness_mkdir)

        outcomes = []

        def runner():
            try:
                rc_value, _ = invoke_sync(module)
                outcomes.append(str(rc_value))
            except BaseException as error:
                outcomes.append(f"raised {type(error).__name__}")

        # redirect_stdout глобален: при наложении выходов нитей восстановление
        # может прийтись на чужой буфер. Сценарий читает только rc/состояние
        # ФС, взаимный вывод нитей не важен -- stdout/err лечатся насильно.
        real_stdout, real_stderr = sys.stdout, sys.stderr
        try:
            with patch.object(module, "publish_backup", holding_publish), \
                    publisher_patch:
                threads = [threading.Thread(target=runner) for _ in range(2)]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join()
        finally:
            sys.stdout, sys.stderr = real_stdout, real_stderr
        require(sorted(outcomes) == ["0", "5"],
                f"single-publisher outcomes: {outcomes}")
        require(acquired == ["A"], f"single-publisher acquired: {acquired}")
        require(len(list(path.parent.glob(path.name + ".backup.*"))) == 1,
                "single-publisher left more than one backup")


def scenario_c29() -> None:
    # Д1(в): сердцебиение держит замок свежим внутри долгой публикации; нить
    # останавливается и на исключении внутри публикации. Свидетель паузы
    # пересекает границу устаревания: мёртвое сердцебиение за эту паузу
    # ДОПУСТИЛО бы захват -- свежесть доказывает сердцебиение, не пауза.
    with sync_fixture() as (module, path, home):
        real_publish = module.publish_backup
        ages = []
        pause_started = []

        def pausing_publish(src, lock=None):
            pause_started.append(time.monotonic())
            time.sleep(12.0)
            info = os.stat(str(path) + ".lock")
            ages.append(time.time() - info.st_mtime)
            return real_publish(src, lock=lock)

        with patch.object(module, "publish_backup", pausing_publish):
            rc, output = invoke_sync(module)
        require(rc == 0, f"heartbeat-freshness rc={rc}\n{output}")
        require(ages and ages[0] <= 2.5,
                f"heartbeat let the lock age to {ages} inside the sync")
        pause = time.monotonic() - pause_started[0]
        require(pause >= module.CONFIG_LOCK_STALE_SECONDS,
                f"heartbeat witness pause {pause:.1f}s never crossed the "
                f"staleness bound {module.CONFIG_LOCK_STALE_SECONDS}s")

        def failing_publish(src, lock=None):
            raise RuntimeError("fixture: publication torn")

        before_threads = threading.active_count()
        with patch.object(module, "publish_backup", failing_publish):
            try:
                invoke_sync(module)
            except RuntimeError:
                pass
            else:
                raise BenchFailure("torn publication did not raise")
        require(not Path(str(path) + ".lock").exists(),
                "torn publication left the lock behind")
        require(threading.active_count() == before_threads,
                "heartbeat thread survived a torn publication")
    with sync_fixture() as (module, path, home):
        # F2: между utime и записью идентичности в _adopt читатель обязан
        # видеть согласованную пару (диск, идентичность): mtime диска не
        # может обогнать self.identity -- иначе ложная потеря СВОЕГО замка.
        real_lock_class = module.ConfigLock
        owned_locks = []
        interleave = []

        class WitnessLock(real_lock_class):
            def __init__(self, lock_path):
                super().__init__(lock_path)
                owned_locks.append(self)

        real_open = module.os.open
        real_utime = module.os.utime
        lock_fd = []

        def recording_open(name, *args, **kwargs):
            value = real_open(name, *args, **kwargs)
            # Запись fd по ОБЕИМ формам создания: путь замка (до v2) и
            # личный staging-каталог v2 -- refresh касается удерживаемого
            # дескриптора, и предикаты utime ниже ловят его по записи.
            if str(name) == str(path) + ".lock" or str(name).startswith(
                    str(path) + ".lock.new."):
                lock_fd.append(value)
            return value

        def interleaving_utime(name, *args, **kwargs):
            value = real_utime(name, *args, **kwargs)
            if (not interleave and owned_locks
                    and owned_locks[0].identity is not None
                    and (str(name) == str(path) + ".lock"
                         or (lock_fd and name == lock_fd[-1]))):
                probe = {"done": False}

                def checker():
                    try:
                        # Читатель здесь -- touch(), не verify_owned():
                        # после G1 verify сравнивает путь с ЖИВЫМ дескриптором
                        # и окно «mtime диска впереди self.identity» больше не
                        # видит; touch сравнивает stat(путь) с ЗАПОМНЕННОЙ
                        # идентичностью -- ровно та ложная потеря, которую
                        # обязан закрывать мьютекс _adopt.
                        owned_locks[0].touch()
                    except BaseException as error:
                        probe["error"] = f"{type(error).__name__}"
                    finally:
                        probe["done"] = True

                thread = threading.Thread(target=checker, daemon=True)
                thread.start()
                # Окно держит открытым сам враппер: пока он не вернулся, _adopt
                # не дойдёт до записи идентичности -- читатель без мьютекса
                # (дефект/мутант) успевает прочитать ГАРАНТИРОВАННО, не по
                # выигрышу гонки планировщика. С мьютексом чекер стоит на
                # guard, и враппер уходит по таймауту, НЕ дожидаясь: это и
                # есть наблюдаемое разделение исправного и дефектного кода.
                # Совпадение двойное -- по пути (utime-по-пути) и по fd
                # (fd-форма _adopt): зуб держит обе формы.
                probe_deadline = time.monotonic() + 1.0
                while not probe["done"] and time.monotonic() < probe_deadline:
                    time.sleep(0.005)
                interleave.append((probe, thread))
            return value

        with patch.object(module, "ConfigLock", WitnessLock), \
                patch.object(module.os, "open", side_effect=recording_open), \
                patch.object(module.os, "utime", side_effect=interleaving_utime):
            rc, output = invoke_sync(module)
        probe, checker = interleave[0]
        checker.join(5.0)
        require(probe["done"], "interleave probe never finished")
        require(not checker.is_alive(), "interleave probe stuck on the guard")
        require("error" not in probe,
                f"interleave false loss on our own lock: {probe.get('error')}")
        require(rc == 0, f"interleave sync rc={rc}\n{output}")


def scenario_c31() -> None:
    # Д2: --show / --dry-run / --check-drift только читают: ни свипа, ни
    # замка, ни файлов; dry-run при чужом свежем замке отвечает своим кодом.
    with sync_fixture() as (module, path, home):
        Path(str(path) + ".lock").mkdir()
        dead = reaped_pid()
        temp = path.parent / f".tmp-copy-{dead}-{path.name}.backup.u1-1"
        temp.write_text("read-only modes must not sweep")
        past = time.time() - 7200
        os.utime(temp, (past, past))
        before = sync_trace(module, path)
        rc, output = invoke_sync(module, ["--show"])
        require(rc == 0, f"mode-read-only show rc={rc}\n{output}")
        rc, output = invoke_sync(module, ["--dry-run"])
        require(rc == 0, f"mode-read-only dry-run rc={rc}\n{output}")
        require("--dry-run: nothing written" in output,
                f"mode-read-only dry-run not named\n{output}")
        rc, output = invoke_sync(module, ["--check-drift"])
        require(rc == 1, f"mode-read-only drift rc={rc}\n{output}")
        require(sync_trace(module, path) == before, "mode-read-only left traces")
        require(Path(str(path) + ".lock").is_dir(),
                "mode-read-only touched the foreign lock")


def scenario_c32() -> None:
    # Д6: унаследованный CLAUDE_CONFIG_DIR не доходит до продукта ни в одной
    # фикстуре стенда: сторожевой каталог побайтно цел.
    with tempfile.TemporaryDirectory() as raw:
        sentinel = Path(raw)
        (sentinel / ".claude.json").write_text(
            '{"customModelCosts": {}, "customModelContextWindows": {}}', encoding="utf-8")
        (sentinel / "guard").write_text("sentinel", encoding="utf-8")
        before = {p.name: p.read_bytes() for p in sentinel.iterdir()}
        os.environ["CLAUDE_CONFIG_DIR"] = str(sentinel)
        try:
            rc, _, _, output, _ = run_costs_main(
                {"customModelCosts": {}, "customModelContextWindows": {}}, catalogue={})
        finally:
            os.environ.pop("CLAUDE_CONFIG_DIR", None)
        require(rc == 0, f"env-builder rc={rc}\n{output}")
        after = {p.name: p.read_bytes() for p in sentinel.iterdir()}
        require(after == before,
                f"env-builder let an inherited CCD reach the product: {sorted(after)}")


def scenario_c33() -> None:
    # Д7: соседний свип уже убрал файл между нашим решением и unlink —
    # строки Swept нет, синк продолжается.
    with sync_fixture() as (module, path, home):
        dead = reaped_pid()
        temp = path.parent / f".tmp-copy-{dead}-{path.name}.backup.u1-1"
        temp.write_text("rival sweeper", encoding="utf-8")
        past = time.time() - 7200
        os.utime(temp, (past, past))
        real_unlink = module.os.unlink

        def rival_unlink(name, *args, **kwargs):
            if str(name) == str(temp):
                real_unlink(name, *args, **kwargs)
                raise FileNotFoundError(name)
            return real_unlink(name, *args, **kwargs)

        try:
            with patch.object(module.os, "unlink", side_effect=rival_unlink):
                rc, output = invoke_sync(module)
        except FileNotFoundError as error:
            raise BenchFailure(f"rival-sweep unlink intolerance: {error}") from error
        require(rc == 0, f"rival-sweep rc={rc}\n{output}")
        require(not temp.exists(), "rival-sweep temp survived")
        require(f"Swept stale temp {temp}" not in output,
                "rival-sweep claimed the rival's removal")
    with sync_fixture() as (module, path, home):
        # F4: соперник убирает temp МЕЖДУ listdir и пред-remove lstat --
        # возраст уже не спросить, но и падать синк не обязан: строка
        # удаления принадлежит тому прогону.
        dead = reaped_pid()
        temp = path.parent / f".tmp-copy-{dead}-{path.name}.backup.u1-2"
        temp.write_text("rival sweeper", encoding="utf-8")
        past = time.time() - 7200
        os.utime(temp, (past, past))
        real_unlink = module.os.unlink
        real_lstat = module.os.lstat

        def rival_lstat(name, *args, **kwargs):
            if str(name) == str(temp):
                real_unlink(name)
                raise FileNotFoundError(name)
            return real_lstat(name, *args, **kwargs)

        try:
            with patch.object(module.os, "lstat", side_effect=rival_lstat):
                rc, output = invoke_sync(module)
        except FileNotFoundError as error:
            raise BenchFailure(f"rival-sweep lstat intolerance: {error}") from error
        require(rc == 0, f"rival-sweep lstat rc={rc}\n{output}")
        require(not temp.exists(), "rival-sweep lstat temp survived")
        require(f"Swept stale temp {temp}" not in output,
                "rival-sweep lstat claimed the rival's removal")


def scenario_c34() -> None:
    # Д8/Д13/Д14: пространства pid в свипе. Свой tag с мёртвым pid удалён;
    # чужой tag цел; старые формы — только мёртвый pid И старше часа (будущее
    # mtime не «старше»); непригодный pid и не-файл пропущены поимённо;
    # отказ unlink не роняет синк.
    with sync_fixture() as (module, path, home):
        tag = module.temp_space_tag()
        foreign = "00000000" if tag != "00000000" else "ffffffff"
        dead = reaped_pid()
        base = path.name
        own_copy = f".tmp-copy-cms-{tag}-{dead}-{base}.backup.u2-1"
        own_json = f"{base}.tmp.cms-{tag}-{dead}"
        foreign_copy = f".tmp-copy-cms-{foreign}-{dead}-{base}.backup.u2-2"
        old_young = f".tmp-copy-{dead}-{base}.backup.u2-3"
        old_old = f".tmp-copy-{dead}-{base}.backup.u2-4"
        old_json_old = f"{base}.tmp.{dead}"
        old_future = f".tmp-copy-{dead}-{base}.backup.u2-6"
        unusable = f"{base}.tmp.cms-{tag}-9999999999"
        denied = f".tmp-copy-{dead}-{base}.backup.u2-7"
        for name in (own_copy, own_json, foreign_copy, old_young, old_old,
                     old_json_old, old_future, unusable, denied):
            (path.parent / name).write_text(name, encoding="utf-8")
        nonfile = path.parent / f".tmp-copy-cms-{tag}-{dead}-{base}.backup.u2-5"
        nonfile.mkdir()
        past = time.time() - 7200
        future = time.time() + 3600
        for name in (old_old, old_json_old, denied):
            os.utime(path.parent / name, (past, past))
        os.utime(path.parent / old_future, (future, future))
        real_unlink = module.os.unlink

        def denying_unlink(name, *args, **kwargs):
            if str(name) == str(path.parent / denied):
                raise PermissionError(13, "Permission denied")
            return real_unlink(name, *args, **kwargs)

        with patch.object(module.os, "unlink", side_effect=denying_unlink):
            rc, output = invoke_sync(module)
        require(rc == 0, f"sweep-spaces rc={rc}\n{output}")
        for name in (own_copy, own_json, old_old, old_json_old):
            require(not (path.parent / name).exists(),
                    f"own-tag dead temp not swept: {name}")
        for name in (foreign_copy, old_young, old_future, unusable, denied):
            require((path.parent / name).exists(), f"temp must stay: {name}")
        require(nonfile.exists(), "temp must stay: non-file")
        require(f"Skipped foreign temp {path.parent / foreign_copy}" in output,
                "foreign-tag temp not named")
        require(f"Skipped temp with unusable pid {path.parent / unusable}" in output,
                "unusable pid not named")
        require(f"Skipped non-file temp {nonfile}" in output,
                "non-file temp not named")
        require(f"Could not sweep {path.parent / denied}: " in output,
                "unlink refusal not named")
        require(output.count("Swept stale temp ") == 4,
                f"sweep-spaces removal count: {output.count('Swept stale temp ')}")


def scenario_c35() -> None:
    # Д15: путь замка существует, но это не каталог. Это не протокол продукта:
    # файл не удаляем, именованный отказ rc 5 в любом возрасте.
    with sync_fixture() as (module, path, home):
        lock = Path(str(path) + ".lock")
        lock.write_text("not a directory", encoding="utf-8")
        fresh = lock.read_bytes()
        rc, output = invoke_sync(module)
        require(rc == 5, f"lock-not-directory rc={rc}\n{output}")
        require("is not a directory" in output and "nothing written" in output,
                f"lock-not-directory refusal not named\n{output}")
        require(lock.read_bytes() == fresh,
                "lock-not-directory touched the foreign file")
        stamp = time.time() - 20
        os.utime(lock, (stamp, stamp))
        rc, output = invoke_sync(module)
        require(rc == 5 and "is not a directory" in output,
                f"lock-not-directory aged rc={rc}\n{output}")
        require(lock.read_bytes() == fresh,
                "lock-not-directory aged touched the foreign file")
    with sync_fixture() as (module, path, home):
        # F5: висячий симлинк на месте замка. Протокол v2 опознаёт его сразу
        # (публикация EEXIST, открытие с O_NOFOLLOW -- ELOOP) и отказывает
        # именованным «is not a directory» rc 5; форма до v2 доходила до
        # дедлайна «held by another writer» -- на входе нож красен именно
        # этой причиной. Свидетель -- завершение прогона в пределах окна.
        lock = Path(str(path) + ".lock")
        lock.symlink_to(home / "gone")
        outcome = {}

        def runner():
            try:
                value_rc, value_out = invoke_sync(module)
                outcome["rc"] = value_rc
                outcome["out"] = value_out
            except BaseException as error:
                outcome["raise"] = f"{type(error).__name__}: {error}"

        # redirect_stdout глобален: как и в C28, выходы нитей не важны --
        # сценарий читает только rc/состояние ФС.
        real_stdout, real_stderr = sys.stdout, sys.stderr
        thread = threading.Thread(target=runner, daemon=True)
        started = time.monotonic()
        try:
            thread.start()
            thread.join(6.0)
            waited = time.monotonic() - started
            if thread.is_alive():

                def refusing_mkdir(name, *args, **kwargs):
                    raise OSError(f"fixture: spin stopped at {name}")

                with patch.object(module.os, "mkdir", side_effect=refusing_mkdir):
                    thread.join(3.0)
                require(False,
                        f"symlink-lock deadline ignored: still spinning "
                        f"after {waited:.1f}s")
        finally:
            sys.stdout, sys.stderr = real_stdout, real_stderr
        require(outcome.get("rc") == 5,
                f"symlink-lock rc={outcome}\n{outcome.get('out', '')}")
        require("is not a directory" in outcome.get("out", ""),
                f"symlink-lock not named\n{outcome.get('out', '')}")
        require(lock.is_symlink(),
                "symlink-lock replaced the foreign symlink")


def scenario_c36() -> None:
    # Д10: судья вычисляет путь конфига цен лениво; пустой CCD/HOME на входе
    # CLI — тот же именованный отказ rc 2, без трассировки. Публичный вход
    # CLI, не AST-фрагмент.
    for overrides, label in (({"CLAUDE_CONFIG_DIR": ""}, "empty-ccd"),
                             ({"HOME": ""}, "empty-home")):
        env = bench_env(Path(tempfile.mkdtemp()))
        env.update(overrides)
        result = subprocess.run(
            [sys.executable, str(ROOT / "judge" / "validate.py"),
             "list", "--records", "/nonexistent"],
            capture_output=True, text=True, env=env)
        require(result.returncode == 2,
                f"judge-cli {label} rc={result.returncode}\n{result.stderr}")
        require("ERROR:" in result.stderr and "nothing written" in result.stderr,
                f"judge-cli {label} refusal not named\n{result.stderr}")
        require("Traceback" not in result.stderr,
                f"judge-cli {label} answered with a traceback\n{result.stderr}")


def scenario_c37() -> None:
    # Д1-окно: проверка владения обязана стоять НЕПОСРЕДСТВЕННО перед
    # сисколлом публикации. Захват между call-site проверкой и link/replace --
    # именованный отказ rc 5, а не ближайшая проверка снаружи. Оба свидетеля
    # отличаются от соседей: бэкап-файл (link) и байты конфига (replace).
    with sync_fixture() as (module, path, home):
        real_copy = module.shutil.copyfileobj

        def takeover_after_copy(rfh, wfh):
            real_copy(rfh, wfh)
            lock = str(path) + ".lock"
            abandoned = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
            os.utime(lock, (abandoned, abandoned))
            teardown_owned_lock(lock)
            os.mkdir(lock)
            moment = time.time_ns()
            os.utime(lock, ns=(moment, moment))

        config_before = path.read_bytes()
        with patch.object(module.shutil, "copyfileobj", takeover_after_copy):
            rc, output = invoke_sync(module)
        require(rc == 5, f"link-site takeover rc={rc}\n{output}")
        require("lost to another writer" in output,
                f"link-site takeover not named\n{output}")
        require(not list(path.parent.glob(path.name + ".backup.*")),
                "takeover before backup link linked anyway")
        require(path.read_bytes() == config_before,
                "link-site takeover wrote the config")
    with sync_fixture() as (module, path, home):
        real_dump = module.json.dump

        def takeover_after_dump(payload, fh, **dump_kw):
            real_dump(payload, fh, **dump_kw)
            lock = str(path) + ".lock"
            abandoned = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
            os.utime(lock, (abandoned, abandoned))
            teardown_owned_lock(lock)
            os.mkdir(lock)
            moment = time.time_ns()
            os.utime(lock, ns=(moment, moment))

        config_before = path.read_bytes()
        with patch.object(module.json, "dump", takeover_after_dump):
            rc, output = invoke_sync(module)
        require(rc == 5, f"replace-site takeover rc={rc}\n{output}")
        require("lost to another writer" in output,
                f"replace-site takeover not named\n{output}")
        require(list(path.parent.glob(path.name + ".backup.*")),
                "replace-site lost the legitimate pre-takeover backup")
        require(path.read_bytes() == config_before,
                "takeover between staging and rename published anyway")
    with sync_fixture() as (module, path, home):
        # Q1: коллизия ПЕРВОГО имени бэкапа + захват МЕЖДУ суффиксными
        # попытками. Проверка владения обязана стоять перед КАЖДЫМ link, а
        # не только перед первым: захват после первой неудачи обязан
        # остановить публикацию, а не ссылаться на суффикс .01 под чужим
        # замком.
        first = path.parent / (path.name + ".backup.u20261001-120000")
        first.write_text("occupied", encoding="utf-8")
        real_link = module.os.link
        taken = []

        def colliding_link(src, dst, *args, **kwargs):
            try:
                return real_link(src, dst, *args, **kwargs)
            except FileExistsError:
                if str(dst) == str(first) and not taken:
                    taken.append(True)
                    lock = str(path) + ".lock"
                    abandoned = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
                    os.utime(lock, (abandoned, abandoned))
                    teardown_owned_lock(lock)
                    os.mkdir(lock)
                    moment = time.time_ns()
                    os.utime(lock, ns=(moment, moment))
                raise

        config_before = path.read_bytes()
        with fixed_second(module), \
                patch.object(module.os, "link", side_effect=colliding_link):
            rc, output = invoke_sync(module)
        require(rc == 5, f"retry-suffix takeover rc={rc}\n{output}")
        require(not (path.parent / (path.name + ".backup.u20261001-120000.01")).exists(),
                "takeover at the retry suffix published anyway")
        require(Path(str(path) + ".lock").is_dir(),
                "retry-suffix takeover released the foreign lock")
        require(path.read_bytes() == config_before,
                "retry-suffix takeover wrote the config")


def scenario_c38() -> None:
    # F6: любое OSError внутри _adopt (open/utime/fstat/stat) на ОБЕИХ путях --
    # именованный отказ rc 5, не трейсбек: каталог замка может уйти между
    # проверкой touch и сисколлом (refresh) или между mkdir и utime (start).
    with sync_fixture() as (module, path, home):
        real_open = module.os.open
        real_utime = module.os.utime
        real_lock_class = module.ConfigLock
        owned_locks = []
        lock_fd = []
        fired = []

        class WitnessLock(real_lock_class):
            def __init__(self, lock_path):
                super().__init__(lock_path)
                owned_locks.append(self)

        # G10: дверцы срабатывают только в главной нити -- иначе нить
        # сердцебиения снимает каталог раньше главной, её потеря глотается,
        # и вердикт сценария зависит от расписания. Совпадение utime двойное:
        # fd-форма (FIX5 зовёт utime по удерживаемому дескриптору) и
        # путь-строка (форма до FIX5).
        def removing_open(name, *args, **kwargs):
            if (str(name) == str(path) + ".lock" and owned_locks
                    and owned_locks[0].identity is not None and not fired
                    and threading.current_thread() is threading.main_thread()):
                fired.append("open")
                teardown_owned_lock(str(path) + ".lock")
            value = real_open(name, *args, **kwargs)
            if str(name) == str(path) + ".lock" or str(name).startswith(
                    str(path) + ".lock.new."):
                lock_fd.append(value)
            return value

        def removing_utime(name, *args, **kwargs):
            if (not fired and owned_locks
                    and owned_locks[0].identity is not None
                    and threading.current_thread() is threading.main_thread()
                    and (str(name) == str(path) + ".lock"
                         or (lock_fd and name == lock_fd[-1]))):
                fired.append("utime")
                teardown_owned_lock(str(path) + ".lock")
            return real_utime(name, *args, **kwargs)

        config_before = path.read_bytes()
        try:
            with patch.object(module, "ConfigLock", WitnessLock), \
                    patch.object(module.os, "open", side_effect=removing_open), \
                    patch.object(module.os, "utime", side_effect=removing_utime):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(
                f"adopt-removal refresh traceback: {error!r}") from error
        require(rc == 5, f"adopt-removal refresh rc={rc}\n{output}")
        error_lines = [line for line in output.splitlines()
                       if line.startswith("ERROR: config lock")]
        require(error_lines and all("lost: [Errno" in line for line in error_lines),
                f"adopt-removal refresh wrong loss reason\n{output}")
        require(not any("another writer" in line for line in error_lines),
                f"adopt-removal refresh misnames an OSError loss\n{output}")
        require(not Path(str(path) + ".lock").exists(),
                "adopt-removal refresh left a lock behind")
        require(path.read_bytes() == config_before,
                "adopt-removal refresh wrote the config")
    with sync_fixture() as (module, path, home):
        # Путь start: каталог снят ПОСЛЕ создания, ДО utime в стартовой ветке
        # (_adopt). В форме v2 стартовый utime идёт по дескриптору УЖЕ
        # опубликованного каталога (published), а utime шага строительства
        # (до публикации) дверцей не трогается.
        real_open = module.os.open
        real_utime = module.os.utime
        real_lock_class = module.ConfigLock
        owned_locks = []
        lock_fd = []
        fired = []

        class WitnessLock(real_lock_class):
            def __init__(self, lock_path):
                super().__init__(lock_path)
                owned_locks.append(self)

        def removing_open(name, *args, **kwargs):
            if (str(name) == str(path) + ".lock" and owned_locks
                    and owned_locks[0].identity is None and not fired
                    and threading.current_thread() is threading.main_thread()):
                fired.append("open")
                teardown_owned_lock(str(path) + ".lock")
            value = real_open(name, *args, **kwargs)
            if str(name) == str(path) + ".lock" or str(name).startswith(
                    str(path) + ".lock.new."):
                lock_fd.append(value)
            return value

        def removing_utime(name, *args, **kwargs):
            if (not fired and owned_locks
                    and getattr(owned_locks[0], "published", True)
                    and owned_locks[0].identity is None
                    and threading.current_thread() is threading.main_thread()
                    and (str(name) == str(path) + ".lock"
                         or (lock_fd and name == lock_fd[-1]))):
                fired.append("utime")
                teardown_owned_lock(str(path) + ".lock")
            return real_utime(name, *args, **kwargs)

        config_before = path.read_bytes()
        try:
            with patch.object(module, "ConfigLock", WitnessLock), \
                    patch.object(module.os, "open", side_effect=removing_open), \
                    patch.object(module.os, "utime", side_effect=removing_utime):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(
                f"adopt-removal start traceback: {error!r}") from error
        require(rc == 5, f"adopt-removal start rc={rc}\n{output}")
        error_lines = [line for line in output.splitlines()
                       if line.startswith("ERROR: config lock")]
        require(error_lines and all("lost: [Errno" in line for line in error_lines),
                f"adopt-removal start wrong loss reason\n{output}")
        require(not any("another writer" in line for line in error_lines),
                f"adopt-removal start misnames an OSError loss\n{output}")
        require(path.read_bytes() == config_before,
                "adopt-removal start wrote the config")


def scenario_c39() -> None:
    # F7: захват в окне проверка→utime. Наш процесс обязан отказаться, НЕ
    # изменив (dev, ino, mtime_ns) каталога соперника: касание по дескриптору
    # касается нашего (возможно уже снятого) inode, а не чужого пути.
    with sync_fixture() as (module, path, home):
        real_open = module.os.open
        real_utime = module.os.utime
        real_lock_class = module.ConfigLock
        owned_locks = []
        lock_fd = []
        rival = []

        class WitnessLock(real_lock_class):
            def __init__(self, lock_path):
                super().__init__(lock_path)
                owned_locks.append(self)

        def recording_open(name, *args, **kwargs):
            value = real_open(name, *args, **kwargs)
            # Запись fd по ОБЕИМ формам создания: путь замка (до v2) и
            # личный staging-каталог v2 -- refresh касается удерживаемого
            # дескриптора, и предикаты utime ниже ловят его по записи.
            if str(name) == str(path) + ".lock" or str(name).startswith(
                    str(path) + ".lock.new."):
                lock_fd.append(value)
            return value

        def takeover_utime(name, *args, **kwargs):
            if (not rival and owned_locks
                    and owned_locks[0].identity is not None
                    and (str(name) == str(path) + ".lock"
                         or (lock_fd and name == lock_fd[-1]))):
                rival.append(True)
                lock = str(path) + ".lock"
                teardown_owned_lock(lock)
                os.mkdir(lock)
                moment = time.time_ns()
                real_utime(lock, ns=(moment, moment))
                info = real_open(lock, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    st = os.fstat(info)
                    rival[0] = (st.st_dev, st.st_ino, st.st_mtime_ns)
                finally:
                    os.close(info)
            return real_utime(name, *args, **kwargs)

        config_before = path.read_bytes()
        with patch.object(module, "ConfigLock", WitnessLock), \
                patch.object(module.os, "open", side_effect=recording_open), \
                patch.object(module.os, "utime", side_effect=takeover_utime):
            rc, output = invoke_sync(module)
        lock = Path(str(path) + ".lock")
        require(lock.is_dir(), f"takeover-window rival lock gone rc={rc}\n{output}")
        info = lock.stat()
        require((info.st_dev, info.st_ino, info.st_mtime_ns) == rival[0],
                "takeover-window touched the rival lock")
        require(rc == 5, f"takeover-window rc={rc}\n{output}")
        require("lost to another writer" in output,
                f"takeover-window not named\n{output}")
        require(path.read_bytes() == config_before,
                "takeover-window wrote the config")


def scenario_c40() -> None:
    # F4b/AR-2: иной OSError по пути замка в acquire (mkdir каталога
    # строительства / открытие занятого пути / чужой файл в просроченном
    # каталоге) -- именованный отказ rc 5 «unusable», не трейсбек; узнаваемые
    # подклассы по-прежнему обрабатываются внутри попытки.
    with sync_fixture() as (module, path, home):
        real_mkdir = module.os.mkdir

        def denying_mkdir(name, *args, **kwargs):
            # mkdir каталога строительства -- по пути замка (форма до v2)
            # или по личному staging-имени (v2); дверца бьёт по обеим.
            if (str(name) == str(path) + ".lock"
                    or str(name).startswith(str(path) + ".lock.new.")):
                raise PermissionError(13, "Permission denied")
            return real_mkdir(name, *args, **kwargs)

        config_before = path.read_bytes()
        try:
            with patch.object(module.os, "mkdir", side_effect=denying_mkdir):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(
                f"lock-unusable mkdir traceback: {error!r}") from error
        require(rc == 5, f"lock-unusable mkdir rc={rc}\n{output}")
        require("unusable:" in output and "nothing written" in output,
                f"lock-unusable mkdir not named\n{output}")
        require("Traceback" not in output,
                f"lock-unusable mkdir traceback printed\n{output}")
        require(not list(path.parent.glob(path.name + ".lock*")),
                "lock-unusable mkdir left a lock behind")
        require(path.read_bytes() == config_before,
                "lock-unusable mkdir wrote the config")
    with sync_fixture() as (module, path, home):
        # Открытие занятого пути в ветке ожидания отказано -- именованный
        # unusable rc 5 (в v2 ветка ждёт через open+fstat, не через stat).
        lock_dir = Path(str(path) + ".lock")
        lock_dir.mkdir()
        real_open = module.os.open

        def denying_open(name, *args, **kwargs):
            if (str(name) == str(path) + ".lock"
                    and threading.current_thread() is threading.main_thread()):
                raise PermissionError(13, "Permission denied")
            return real_open(name, *args, **kwargs)

        config_before = path.read_bytes()
        try:
            with patch.object(module.os, "open", side_effect=denying_open):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(
                f"lock-unusable open traceback: {error!r}") from error
        require(rc == 5, f"lock-unusable open rc={rc}\n{output}")
        require("unusable:" in output and "nothing written" in output,
                f"lock-unusable open not named\n{output}")
        require("Traceback" not in output,
                f"lock-unusable open traceback printed\n{output}")
        require(lock_dir.is_dir(),
                "lock-unusable open removed the foreign lock directory")
        require(path.read_bytes() == config_before,
                "lock-unusable open wrote the config")
    with sync_fixture() as (module, path, home):
        # Без дверцы: стейл-каталог замка НЕ пуст -- rmdir даёт ENOTEMPTY.
        lock_dir = Path(str(path) + ".lock")
        lock_dir.mkdir()
        (lock_dir / "payload").write_text("rival", encoding="utf-8")
        stamp = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
        os.utime(lock_dir, (stamp, stamp))
        config_before = path.read_bytes()
        try:
            rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(
                f"lock-unusable rmdir traceback: {error!r}") from error
        require(rc == 5, f"lock-unusable rmdir rc={rc}\n{output}")
        require("unusable:" in output and "nothing written" in output,
                f"lock-unusable rmdir not named\n{output}")
        require("Traceback" not in output,
                f"lock-unusable rmdir traceback printed\n{output}")
        require((lock_dir / "payload").read_text(encoding="utf-8") == "rival",
                "lock-unusable rmdir touched the rival's directory")
        require(path.read_bytes() == config_before,
                "lock-unusable rmdir wrote the config")


def scenario_c41() -> None:
    # G1: соперник снимает наш каталог и создаёт свой в цикле до совпадения
    # НОМЕРА inode с нашим прежним (и подделывает mtime_ns нашей идентичности,
    # чтобы сверка тройки не спасала). Пока дескриптор держится всё владение,
    # номер не может быть переиспользован: refresh обязан отказать rc 5, не
    # усыновив чужой каталог и не тронув его. Дверца висит на ПЕРВОМ stat пути
    # замка в главной нити с уже записанной идентичностью -- это verify_owned
    # ДО touch, точка, общая обеим формам _adopt.
    with sync_fixture() as (module, path, home):
        module.CONFIG_LOCK_STALE_SECONDS = 1
        module.CONFIG_LOCK_TIMEOUT_SECONDS = 5
        real_lock_class = module.ConfigLock
        real_stat = module.os.stat
        owned_locks = []
        fired = []

        class WitnessLock(real_lock_class):
            def __init__(self, lock_path):
                super().__init__(lock_path)
                owned_locks.append(self)

        def reusing_stat(name, *args, **kwargs):
            if (fired or not owned_locks
                    or threading.current_thread() is not threading.main_thread()
                    or owned_locks[0].identity is None
                    or str(name) != str(path) + ".lock"):
                return real_stat(name, *args, **kwargs)
            fired.append(True)
            ours = owned_locks[0].identity
            lock = str(path) + ".lock"
            # Наш каталог разбирается как это сделал бы соперник: owner
            # первым, потом каталог (форма до v2 -- просто пустой каталог).
            teardown_owned_lock(lock)
            attempts = 0
            while True:
                attempts += 1
                if attempts > 4096:
                    break
                os.mkdir(lock)
                info = real_stat(lock)
                if (info.st_dev, info.st_ino) == (ours[0], ours[1]):
                    break
                os.rmdir(lock)
            if not os.path.isdir(lock):
                os.mkdir(lock)
            os.utime(lock, ns=(ours[2], ours[2]))
            path.write_text('{"other": "product"}', encoding="utf-8")
            return real_stat(name, *args, **kwargs)

        try:
            with patch.object(module, "ConfigLock", WitnessLock), \
                    patch.object(module.os, "stat", side_effect=reusing_stat):
                rc, output = invoke_sync(module)
        except Exception as error:
            raise BenchFailure(
                f"inode-reuse reverted form crashed instead of refusing: {error!r}")
        require(Path(str(path) + ".lock").is_dir(),
                "inode-reuse rival lock gone")
        require(rc == 5, f"inode-reuse rc={rc}\n{output}")
        require("lost to another writer" in output,
                f"inode-reuse not named\n{output}")
        require(json.loads(path.read_bytes()) == {"other": "product"},
                "inode-reuse adopted the rival lock and wrote the config")
        require(not list(path.parent.glob(path.name + ".backup.*")),
                "inode-reuse published a backup")


def scenario_c42() -> None:
    # G2: release никогда не выпускает OSError -- вычисленный rc синка
    # сохраняется, отказ уборки именован строкой с errno.
    with sync_fixture() as (module, path, home):
        # Каталог снят соперником между stat и rmdir внутри release.
        real_rmdir = module.os.rmdir
        fired = []

        def removing_rmdir(name, *args, **kwargs):
            if (not fired and str(name) == str(path) + ".lock"
                    and threading.current_thread() is threading.main_thread()):
                fired.append(True)
                real_rmdir(name, *args, **kwargs)
            return real_rmdir(name, *args, **kwargs)

        try:
            with patch.object(module.os, "rmdir", side_effect=removing_rmdir):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(f"release-removal traceback: {error!r}") from error
        require(rc == 0, f"release-removal rc={rc}\n{output}")
        require("lock not released: [Errno" in output,
                f"release-removal errno line missing\n{output}")
        require("Traceback" not in output, f"release-removal traceback\n{output}")
    with sync_fixture() as (module, path, home):
        # Посторонний файл оказался внутри каталога к моменту rmdir.
        real_rmdir = module.os.rmdir
        fired = []

        def cluttering_rmdir(name, *args, **kwargs):
            if (not fired and str(name) == str(path) + ".lock"
                    and threading.current_thread() is threading.main_thread()):
                fired.append(True)
                (Path(str(path) + ".lock") / "payload").write_text(
                    "x", encoding="utf-8")
            return real_rmdir(name, *args, **kwargs)

        try:
            with patch.object(module.os, "rmdir", side_effect=cluttering_rmdir):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(f"release-clutter traceback: {error!r}") from error
        require(rc == 0, f"release-clutter rc={rc}\n{output}")
        # v2: непустой после снятия owner каталог -- чужой владелец
        # (протокол п.5); форма до v2 отвечала errno-строкой ENOTEMPTY --
        # на входе нож красен именно этой причиной.
        require("lock not released: owned by another writer" in output,
                f"release-clutter owner line missing\n{output}")
        require("Traceback" not in output, f"release-clutter traceback\n{output}")


def scenario_c43() -> None:
    # G3: провал start() после создания каталога не оставляет каталог замка
    # и уходит именованным отказом rc 5, не трейсбеком.
    with sync_fixture() as (module, path, home):
        # OSError внутри стартового _adopt -- ветка ConfigLockLost. До v2
        # дверца отказывала первый open каталога замка; в v2 дескриптор уже
        # открыт на опубликованном каталоге, и дверца отказывает его первый
        # utime (published, идентичность ещё не записана).
        real_open = module.os.open
        real_utime = module.os.utime
        real_lock_class = module.ConfigLock
        owned_locks = []

        class WitnessLock(real_lock_class):
            def __init__(self, lock_path):
                super().__init__(lock_path)
                owned_locks.append(self)

        def denying_open(name, *args, **kwargs):
            if (str(name) == str(path) + ".lock" and owned_locks
                    and owned_locks[0].identity is None
                    and threading.current_thread() is threading.main_thread()):
                raise PermissionError(13, "Permission denied")
            return real_open(name, *args, **kwargs)

        def denying_utime(name, *args, **kwargs):
            if (owned_locks
                    and getattr(owned_locks[0], "published", True)
                    and owned_locks[0].identity is None
                    and threading.current_thread() is threading.main_thread()):
                raise PermissionError(13, "Permission denied")
            return real_utime(name, *args, **kwargs)

        config_before = path.read_bytes()
        try:
            with patch.object(module, "ConfigLock", WitnessLock), \
                    patch.object(module.os, "open", side_effect=denying_open), \
                    patch.object(module.os, "utime", side_effect=denying_utime):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(f"start-failure traceback: {error!r}") from error
        require(rc == 5, f"start-failure rc={rc}\n{output}")
        require(not Path(str(path) + ".lock").exists(),
                "start-failure left the lock behind")
        error_lines = [line for line in output.splitlines()
                       if line.startswith("ERROR: config lock")]
        require(error_lines and all("lost: [Errno" in line for line in error_lines),
                f"start-failure wrong loss reason\n{output}")
        require("Traceback" not in output, f"start-failure traceback\n{output}")
        require(path.read_bytes() == config_before,
                "start-failure wrote the config")
    with sync_fixture() as (module, path, home):
        # Thread.start отказан (лимит нитей) -- ветка ConfigLockUnavailable.
        def failing_start(self):
            raise RuntimeError("fixture: thread limit")

        try:
            with patch.object(module.threading.Thread, "start", failing_start):
                rc, output = invoke_sync(module)
        except RuntimeError as error:
            raise BenchFailure(
                f"start-failure thread traceback: {error!r}") from error
        require(rc == 5, f"start-failure thread rc={rc}\n{output}")
        require(not Path(str(path) + ".lock").exists(),
                "start-failure thread left the lock behind")
        require("unusable:" in output and "nothing written" in output,
                f"start-failure thread not named\n{output}")
        require("Traceback" not in output,
                f"start-failure thread traceback\n{output}")


def scenario_c44() -> None:
    # G5: каталог замка не наследует umask вызывающего -- при 0o777 наш
    # следующий open обязан пройти, синк доходит до конца. Каталоги боковых
    # файлов создаются ДО враждебного umask: предмет зуба -- режим КАТАЛОГА
    # ЗАМКА, а не режим каталогов боковых файлов (их отказ -- отдельный
    # контракт предупреждения rc 4).
    with sync_fixture() as (module, path, home):
        Path(module.CACHE_PATH).parent.mkdir(parents=True, exist_ok=True)
        Path(module.SEEN_PATH).parent.mkdir(parents=True, exist_ok=True)
        old_umask = os.umask(0o777)
        try:
            rc, output = invoke_sync(module)
        finally:
            os.umask(old_umask)
        require(rc == 0, f"umask-start rc={rc}\n{output}")
        require("Traceback" not in output, f"umask-start traceback\n{output}")
        require(not Path(str(path) + ".lock").exists(),
                "umask-start left the lock behind")


def scenario_c45() -> None:
    # G7: непричитаемый каталог при свипе -- именованная заметка с errno,
    # свип пропускается, синк продолжается.
    with sync_fixture() as (module, path, home):
        real_listdir = module.os.listdir
        fired = []

        def denying_listdir(name, *args, **kwargs):
            if (not fired and str(name) == str(path.parent)
                    and threading.current_thread() is threading.main_thread()):
                fired.append(True)
                raise PermissionError(13, "Permission denied")
            return real_listdir(name, *args, **kwargs)

        try:
            with patch.object(module.os, "listdir", side_effect=denying_listdir):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(f"sweep-listdir traceback: {error!r}") from error
        require(rc == 0, f"sweep-listdir rc={rc}\n{output}")
        require("Could not sweep" in output,
                f"sweep-listdir note missing\n{output}")
        require("[Errno" in output, f"sweep-listdir errno missing\n{output}")
        require("Traceback" not in output, f"sweep-listdir traceback\n{output}")


def scenario_c46() -> None:
    # G8: I/O-отказ публикующего пути -- именованный rc 6 «nothing written»,
    # не трейсбек; отказ уборки стадии не затеняет успешную публикацию.
    with sync_fixture() as (module, path, home):
        # os.replace конфига отказан на записи tmp -> rc 6.
        real_replace = module.os.replace
        fired = []

        def failing_replace(src, dst, *args, **kwargs):
            if (not fired and str(dst) == str(path)
                    and threading.current_thread() is threading.main_thread()):
                fired.append(True)
                raise OSError(5, "Input/output error")
            return real_replace(src, dst, *args, **kwargs)

        config_before = path.read_bytes()
        try:
            with patch.object(module.os, "replace", side_effect=failing_replace):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(f"write-failure traceback: {error!r}") from error
        require(rc == 6, f"write-failure rc={rc}\n{output}")
        require("could not write" in output,
                f"write-failure not named\n{output}")
        require("[Errno 5]" in output, f"write-failure errno missing\n{output}")
        require("nothing written" in output,
                f"write-failure tail missing\n{output}")
        require(path.read_bytes() == config_before,
                "write-failure wrote the config")
        require("Traceback" not in output, f"write-failure traceback\n{output}")
    with sync_fixture() as (module, path, home):
        # os.link бэкапа отказан -- rc 6, конфиг не тронут.
        real_link = module.os.link
        fired = []

        def failing_link(src, dst, *args, **kwargs):
            if (not fired and str(dst).startswith(str(path) + ".backup")
                    and threading.current_thread() is threading.main_thread()):
                fired.append(True)
                raise OSError(1, "Operation not permitted")
            return real_link(src, dst, *args, **kwargs)

        config_before = path.read_bytes()
        try:
            with patch.object(module.os, "link", side_effect=failing_link):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(f"publish-failure traceback: {error!r}") from error
        require(rc == 6, f"publish-failure rc={rc}\n{output}")
        require("could not publish backup" in output,
                f"publish-failure not named\n{output}")
        require("nothing written" in output,
                f"publish-failure tail missing\n{output}")
        require(path.read_bytes() == config_before,
                "publish-failure wrote the config")
        require("Traceback" not in output, f"publish-failure traceback\n{output}")
    with sync_fixture() as (module, path, home):
        # unlink стадии отказан ПОСЛЕ успешного link -- публикация уже
        # состоялась, rc 0 сохранён, отказ уборки проглочен без затенения.
        real_unlink = module.os.unlink
        fired = []

        def denying_unlink(name, *args, **kwargs):
            if (not fired and ".tmp-copy-cms-" in str(name)
                    and threading.current_thread() is threading.main_thread()):
                fired.append(True)
                raise PermissionError(1, "Operation not permitted")
            return real_unlink(name, *args, **kwargs)

        try:
            with patch.object(module.os, "unlink", side_effect=denying_unlink):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(f"unlink-part traceback: {error!r}") from error
        require(rc == 0, f"unlink-part rc={rc}\n{output}")
        require("Traceback" not in output, f"unlink-part traceback\n{output}")
        require(len(list(path.parent.glob(path.name + ".backup.*"))) == 1,
                "unlink-part lost the backup")


def scenario_c47() -> None:
    # V1: отказ chmod каталога строительства -- отказ именованный rc 5,
    # после отказа нет НИ каталога замка, НИ staging-остатка.
    with sync_fixture() as (module, path, home):
        real_chmod = module.os.chmod
        fired = []

        def denying_chmod(name, *args, **kwargs):
            # chmod каталога строительства зовётся ТОЛЬКО из ветки
            # строительства замка -- по пути замка (форма до v2) или по
            # личному staging-имени (v2); дверца бьёт ровно по ней.
            if ((str(name) == str(path) + ".lock"
                 or str(name).startswith(str(path) + ".lock.new."))
                    and threading.current_thread() is threading.main_thread()):
                fired.append(True)
                raise PermissionError(1, "Operation not permitted")
            return real_chmod(name, *args, **kwargs)

        config_before = path.read_bytes()
        try:
            with patch.object(module.os, "chmod", side_effect=denying_chmod):
                rc, output = invoke_sync(module)
        except OSError as error:
            raise BenchFailure(f"chmod-failure traceback: {error!r}") from error
        require(rc == 5, f"chmod-failure rc={rc}\n{output}")
        require(not list(path.parent.glob(path.name + ".lock*")),
                "chmod-failure left the lock behind")
        require("unusable:" in output and "nothing written" in output,
                f"chmod-failure not named\n{output}")
        require("Traceback" not in output, f"chmod-failure traceback\n{output}")
        require(path.read_bytes() == config_before,
                "chmod-failure wrote the config")


def scenario_c48() -> None:
    # V2: строка «lock not released: owned by another writer» обязана идти в
    # stderr (как её errno-соседка) и не пачкать stdout. Оба потока захвата,
    # на которых строка жила до раздельного пина: захват в ConfigLock.touch
    # до публикации и захват посреди publish_backup (форма FIX5).
    line = "lock not released: owned by another writer"
    with sync_fixture() as (module, path, home):
        # Захват ДО явного touch перед публикацией.
        module.CONFIG_LOCK_STALE_SECONDS = 1
        module.CONFIG_LOCK_TIMEOUT_SECONDS = 5
        real_touch = module.ConfigLock.touch
        taken = []

        def takeover_touch(self):
            if self.identity is None or taken:
                return real_touch(self)
            taken.append(True)
            lock = str(path) + ".lock"
            abandoned = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
            os.utime(lock, (abandoned, abandoned))
            teardown_owned_lock(lock)
            os.mkdir(lock)
            moment = time.time_ns()
            os.utime(lock, ns=(moment, moment))
            path.write_text('{"other": "product"}', encoding="utf-8")
            return real_touch(self)

        with patch.object(module.ConfigLock, "touch", takeover_touch):
            rc, out_text, err_text = invoke_sync_split(module)
        require(rc == 5, f"release-stream rc={rc}\n{out_text}{err_text}")
        require(line in err_text,
                f"release-stream line not on stderr\n{err_text}")
        require(line not in out_text,
                f"release-stream line leaked to stdout\n{out_text}")
    with sync_fixture() as (module, path, home):
        # Захват ПОСЕРЕДИНЕ публикации (между touch и link).
        module.CONFIG_LOCK_STALE_SECONDS = 1
        module.CONFIG_LOCK_TIMEOUT_SECONDS = 5
        real_publish = module.publish_backup

        def product_takeover():
            time.sleep(1.2)
            lock = str(path) + ".lock"
            info = os.stat(lock)
            if time.time() - info.st_mtime >= 1:
                teardown_owned_lock(lock)
                os.mkdir(lock)
                moment = time.time_ns()
                os.utime(lock, ns=(moment, moment))
                path.write_text('{"other": "product"}', encoding="utf-8")

        def pausing_publish(src, lock=None):
            threading.Thread(target=product_takeover).start()
            time.sleep(1.6)
            return real_publish(src, lock=lock)

        with patch.object(module, "publish_backup", pausing_publish):
            rc, out_text, err_text = invoke_sync_split(module)
        require(rc == 5, f"release-stream midpublish rc={rc}\n{out_text}{err_text}")
        require(line in err_text,
                f"release-stream midpublish line not on stderr\n{err_text}")
        require(line not in out_text,
                f"release-stream midpublish line leaked to stdout\n{out_text}")
    with sync_fixture() as (module, path, home):
        # Подслучай errno-соседки: отказ уборки в release -- строка
        # «lock not released: [Errno …]» тоже только в stderr.
        real_rmdir = module.os.rmdir
        fired = []

        def removing_rmdir(name, *args, **kwargs):
            if (not fired and str(name) == str(path) + ".lock"
                    and threading.current_thread() is threading.main_thread()):
                fired.append(True)
                real_rmdir(name, *args, **kwargs)
            return real_rmdir(name, *args, **kwargs)

        with patch.object(module.os, "rmdir", side_effect=removing_rmdir):
            rc, out_text, err_text = invoke_sync_split(module)
        require(rc == 0, f"release-stream errno rc={rc}\n{out_text}{err_text}")
        require("lock not released: [Errno" in err_text,
                f"release-stream errno line not on stderr\n{err_text}")
        require("lock not released: [Errno" not in out_text,
                f"release-stream errno line leaked to stdout\n{out_text}")


def scenario_c49() -> None:
    # G11: при пустом и при неустановленном HOME с заданным непустым CCD
    # семья "/.claude.json" не строится. Наблюдаемое без доступа к корню ФС:
    # трасса set -x не содержит НИ ОДНОГО дополнения families+= (счётчик
    # команд не зависит от кавычек xtrace), set -u не роняет, CCD-семья
    # реально пропалывается (зуб не вакуумен).
    source = PIPELINE.read_text(encoding="utf-8")
    function = shell_function(source, "prune_config_backups")
    helper = (shell_function(source, "__config_json_path")
              if "__config_json_path()" in source else "")
    for label in ("empty", "unset"):
        with sync_fixture(ccd=True) as (_, path, home):
            for i in range(1, 5):
                (path.parent / f".claude.json.backup.u2026100{i}-000000").write_text("x")
            if label == "empty":
                env = dict(os.environ, HOME="")
            else:
                env = {k: v for k, v in os.environ.items() if k != "HOME"}
            result = subprocess.run(
                ["bash"], input="set -euo pipefail\nset -x\n" + helper + function
                + "\nprune_config_backups\n",
                env=env, capture_output=True, text=True)
            require(result.returncode == 0,
                    f"prune-empty-home {label} rc={result.returncode}\n{result.stderr}")
            require(result.stderr.count("families+=") == 0,
                    f"prune-empty-home {label} built the root family\n{result.stderr}")
            require({p.name for p in path.parent.glob(".claude.json.backup.*")}
                    == {f".claude.json.backup.u2026100{i}-000000" for i in range(2, 5)},
                    f"prune-empty-home {label} did not prune the CCD family")


def scenario_c50() -> None:
    # Протокол v2: соперник публикует живой каталог v2 (с owner) в окне
    # между созданием staging и публикацией. Публикация без замены обязана
    # отказаться, цикл -- ждать до таймаута (rc 5 held), каталог соперника
    # и его owner побайтно целы, staging убран.
    with sync_fixture() as (module, path, home):
        require(hasattr(module, "rename_noreplace"),
                "no-replace publication missing: rival window unguarded")
        real_publish = module.rename_noreplace
        rival_owner = b"4242 rival-token\n"
        rival = []

        def rival_publishing_rename(src, dst):
            if str(dst) == str(path) + ".lock" and not rival:
                lock = str(path) + ".lock"
                os.mkdir(lock)
                os.chmod(lock, 0o700)
                with open(os.path.join(lock, "owner"), "wb") as fh:
                    fh.write(rival_owner)
                moment = time.time_ns()
                os.utime(lock, ns=(moment, moment))
                rival.append(os.stat(lock).st_ino)
            return real_publish(src, dst)

        config_before = path.read_bytes()
        with patch.object(module, "rename_noreplace", rival_publishing_rename):
            rc, output = invoke_sync(module)
        lock = Path(str(path) + ".lock")
        require(rc == 5 and "held by another writer" in output,
                f"rival-publish deadline refusal missing "
                f"(held by another writer)\n{output}")
        require(lock.is_dir() and lock.stat().st_ino == rival[0],
                "rival-publish replaced the rival's lock")
        require((lock / "owner").read_bytes() == rival_owner,
                "rival-publish touched the rival's owner")
        require(not list(path.parent.glob(path.name + ".lock.new.*")),
                "rival-publish left staging behind")
        require(path.read_bytes() == config_before,
                "rival-publish wrote the config")


def scenario_c50b() -> None:
    # Протокол v2: та же дверца публикации, но соперник положил по пути
    # живой ПУСТОЙ каталог свежего mtime -- класс замены, который держит
    # только атомарная публикация без замены (мутация M104 заменяет его
    # через os.rename). Красен на входе отсутствием no-replace публикации.
    with sync_fixture() as (module, path, home):
        require(hasattr(module, "rename_noreplace"),
                "no-replace publication missing: empty-lock window unguarded")
        real_publish = module.rename_noreplace
        rival = []

        def empty_rival_rename(src, dst):
            if str(dst) == str(path) + ".lock" and not rival:
                lock = str(path) + ".lock"
                os.mkdir(lock)
                moment = time.time_ns()
                os.utime(lock, ns=(moment, moment))
                rival.append(os.stat(lock).st_ino)
            return real_publish(src, dst)

        config_before = path.read_bytes()
        with patch.object(module, "rename_noreplace", empty_rival_rename):
            rc, output = invoke_sync(module)
        lock = Path(str(path) + ".lock")
        require(rc == 5 and "held by another writer" in output,
                f"empty-rival deadline refusal missing "
                f"(held by another writer)\n{output}")
        require(lock.is_dir() and lock.stat().st_ino == rival[0],
                "empty-rival replaced the rival's lock")
        require(not list(path.parent.glob(path.name + ".lock.new.*")),
                "empty-rival left staging behind")
        require(path.read_bytes() == config_before,
                "empty-rival wrote the config")


def scenario_c51() -> None:
    # Протокол v2: соперник заменил наш каталог ПОСЛЕ публикации (дверца в
    # start: снять наш owner и каталог, опубликовать каталог соперника с
    # owner), start отказал -- abandon обязан оставить каталог соперника и
    # уйти именованным rc 5. На входе зелёный и у формы до v2 (непустой
    # каталог соперника не снимался и раньше) -- помечен покрытием; RED
    # даёт мутация M85 (owner убирается по пути, а не по дескриптору).
    with sync_fixture() as (module, path, home):
        real_start = module.ConfigLock.start
        rival_owner = b"777 rival-owner\n"
        rival = []

        def takeover_start(self):
            if not rival:
                lock = str(path) + ".lock"
                teardown_owned_lock(lock)
                os.mkdir(lock)
                os.chmod(lock, 0o700)
                with open(os.path.join(lock, "owner"), "wb") as fh:
                    fh.write(rival_owner)
                moment = time.time_ns()
                os.utime(lock, ns=(moment, moment))
                rival.append(os.stat(lock).st_ino)
                raise RuntimeError("fixture: thread limit")
            return real_start(self)

        config_before = path.read_bytes()
        with patch.object(module.ConfigLock, "start", takeover_start):
            rc, output = invoke_sync(module)
        lock = Path(str(path) + ".lock")
        require(rc == 5, f"post-publish takeover rc={rc}\n{output}")
        require(lock.is_dir() and lock.stat().st_ino == rival[0],
                "post-publish takeover removed the rival's lock")
        require((lock / "owner").read_bytes() == rival_owner,
                "post-publish takeover touched the rival's owner")
        require(not list(path.parent.glob(path.name + ".lock.new.*")),
                "post-publish takeover left staging behind")
        require(path.read_bytes() == config_before,
                "post-publish takeover wrote the config")
    with sync_fixture() as (module, path, home):
        # Подслучай Б: каталог соперника ПУСТОЙ (без owner) -- его держит
        # только сверка идентичности в abandon; каталог с owner держит
        # ENOTEMPTY по построению (мутация M85 снимает сверку).
        real_start = module.ConfigLock.start
        rival = []

        def takeover_start(self):
            if not rival:
                lock = str(path) + ".lock"
                teardown_owned_lock(lock)
                os.mkdir(lock)
                moment = time.time_ns()
                os.utime(lock, ns=(moment, moment))
                rival.append(os.stat(lock).st_ino)
                raise RuntimeError("fixture: thread limit")
            return real_start(self)

        config_before = path.read_bytes()
        with patch.object(module.ConfigLock, "start", takeover_start):
            rc, output = invoke_sync(module)
        lock = Path(str(path) + ".lock")
        require(rc == 5, f"post-publish empty takeover rc={rc}\n{output}")
        require(lock.is_dir() and lock.stat().st_ino == rival[0],
                "post-publish takeover removed the empty rival lock")
        require(path.read_bytes() == config_before,
                "post-publish empty takeover wrote the config")


def scenario_c52() -> None:
    # Протокол v2, гонка просрочки: дверца между unlink owner и rmdir
    # подменяет путь свежим каталогом соперника -- цикл продолжает ожидание
    # (rc 5 по таймауту), каталог соперника цел. Подслучай А: соперник с
    # owner (не снимается по построению); подслучай Б: ПУСТОЙ свежий
    # каталог -- его держит только сверка (dev, ino) перед rmdir (мутация
    # M106 снимает сверку и сносит подмену).
    with sync_fixture() as (module, path, home):
        require(hasattr(module, "rename_noreplace"),
                "no owner-bearing reap protocol: expiry race unguarded")
        lock = Path(str(path) + ".lock")
        lock.mkdir()
        stamp = time.time() - 20
        os.utime(lock, (stamp, stamp))
        stale_ino = lock.stat().st_ino
        rival_owner = b"31337 rival-token\n"
        real_unlink = module.os.unlink
        fired = []
        rival = []

        def substituting_unlink(name, *args, **kwargs):
            # Дверца стоит на unlink owner просроченного каталога ПО
            # ДЕСКРИПТОРУ (имя 'owner' + dir_fd с inode просроченного
            # каталога); уборка staging в abandon идёт по другому inode.
            # У просроченного каталога старого формата owner НЕТ -- сам
            # unlink падает FileNotFoundError ПОСЛЕ дверцы, подмена идёт
            # дальше.
            dir_fd = kwargs.get("dir_fd")
            if (name == "owner" and isinstance(dir_fd, int) and not rival
                    and threading.current_thread() is threading.main_thread()
                    and os.fstat(dir_fd).st_ino == stale_ino):
                try:
                    result = real_unlink(name, *args, **kwargs)
                except FileNotFoundError:
                    result = None
                os.rmdir(lock)
                os.mkdir(lock)
                with open(os.path.join(lock, "owner"), "wb") as fh:
                    fh.write(rival_owner)
                moment = time.time_ns()
                os.utime(lock, ns=(moment, moment))
                rival.append(os.stat(lock).st_ino)
                return result
            return real_unlink(name, *args, **kwargs)

        config_before = path.read_bytes()
        with patch.object(module.os, "unlink", side_effect=substituting_unlink):
            rc, output = invoke_sync(module)
        require(rc == 5 and "held by another writer" in output,
                f"expiry-race rival wait missing "
                f"(held by another writer)\n{output}")
        require(lock.is_dir() and lock.stat().st_ino == rival[0],
                "expiry-race removed the rival's lock")
        require((lock / "owner").read_bytes() == rival_owner,
                "expiry-race touched the rival's owner")
        require(path.read_bytes() == config_before,
                "expiry-race wrote the config")
    with sync_fixture() as (module, path, home):
        # Подслучай Б: подмена ПУСТЫМ свежим каталогом.
        require(hasattr(module, "rename_noreplace"),
                "no owner-bearing reap protocol: empty expiry race unguarded")
        lock = Path(str(path) + ".lock")
        lock.mkdir()
        stamp = time.time() - 20
        os.utime(lock, (stamp, stamp))
        stale_ino = lock.stat().st_ino
        real_unlink = module.os.unlink
        fired = []
        rival = []

        def substituting_unlink(name, *args, **kwargs):
            dir_fd = kwargs.get("dir_fd")
            if (name == "owner" and isinstance(dir_fd, int) and not rival
                    and threading.current_thread() is threading.main_thread()
                    and os.fstat(dir_fd).st_ino == stale_ino):
                try:
                    result = real_unlink(name, *args, **kwargs)
                except FileNotFoundError:
                    result = None
                os.rmdir(lock)
                os.mkdir(lock)
                moment = time.time_ns()
                os.utime(lock, ns=(moment, moment))
                rival.append(os.stat(lock).st_ino)
                return result
            return real_unlink(name, *args, **kwargs)

        config_before = path.read_bytes()
        with patch.object(module.os, "unlink", side_effect=substituting_unlink):
            rc, output = invoke_sync(module)
        require(rc == 5 and "held by another writer" in output,
                f"expiry-empty-rival wait missing "
                f"(held by another writer)\n{output}")
        require(lock.is_dir() and lock.stat().st_ino == rival[0],
                "expiry-race removed the empty rival lock")


def scenario_c53() -> None:
    # Протокол v2: ФС отказала в no-replace публикации (дверца:
    # rename_noreplace поднимает EINVAL) -- именованный отказ rc 5, ни
    # каталога замка, ни staging.
    with sync_fixture() as (module, path, home):
        require(hasattr(module, "rename_noreplace"),
                "no-replace publication missing: filesystem refusal unguarded")

        def einval_rename(src, dst):
            raise OSError(errno.EINVAL, "Invalid argument", src, None, dst)

        config_before = path.read_bytes()
        with patch.object(module, "rename_noreplace", einval_rename):
            rc, output = invoke_sync(module)
        require(rc == 5 and
                "no atomic no-replace rename on this filesystem" in output,
                f"no-replace filesystem refusal not named\n{output}")
        require(not Path(str(path) + ".lock").exists(),
                "no-replace refusal left the lock behind")
        require(not list(path.parent.glob(path.name + ".lock.new.*")),
                "no-replace refusal left staging behind")
        require(path.read_bytes() == config_before,
                "no-replace refusal wrote the config")


def scenario_c54() -> None:
    # Протокол v2: чистый цикл захват->release -- путь замка снят,
    # staging-остатков .lock.new.* нет. На входе зелёный и у формы до v2
    # (staging не было) -- помечен покрытием; RED даёт мутация M109
    # (release не убирает owner -- rmdir встречает ENOTEMPTY).
    with sync_fixture() as (module, path, home):
        rc, output = invoke_sync(module)
        require(rc == 0, f"clean-cycle rc={rc}\n{output}")
        require(not Path(str(path) + ".lock").exists(),
                "clean-cycle lock left behind")
        require(not list(path.parent.glob(path.name + ".lock.new.*")),
                "clean-cycle staging left behind")


def scenario_c55() -> None:
    # Протокол v2: в просроченном каталоге чужой файл -- именованный отказ
    # rc 5 «lock directory holds foreign entries», содержимое не тронуто.
    with sync_fixture() as (module, path, home):
        require(hasattr(module, "rename_noreplace"),
                "no foreign-entry reap guard before v2")
        lock = Path(str(path) + ".lock")
        lock.mkdir()
        (lock / "payload").write_text("rival", encoding="utf-8")
        stamp = time.time() - 20
        os.utime(lock, (stamp, stamp))
        config_before = path.read_bytes()
        rc, output = invoke_sync(module)
        require(rc == 5 and "lock directory holds foreign entries" in output,
                f"foreign-entries refusal not named\n{output}")
        require((lock / "payload").read_text(encoding="utf-8") == "rival",
                "foreign-entries touched the rival's file")
        require(path.read_bytes() == config_before,
                "foreign-entries wrote the config")


def scenario_c56() -> None:
    # Протокол v2 (покрытие): просроченный ПУСТОЙ каталог старого формата
    # (без owner) снимается той же веткой, захват успешен. На входе зелёный
    # и у формы до v2; RED даёт мутация M110 (пустой каталог больше не
    # считается старым форматом).
    with sync_fixture() as (module, path, home):
        lock = Path(str(path) + ".lock")
        lock.mkdir()
        stamp = time.time() - 20
        os.utime(lock, (stamp, stamp))
        rc, output = invoke_sync(module)
        require(rc == 0 and not lock.exists(),
                f"old-format empty stale not reclaimed rc={rc}\n{output}")
        require(not list(path.parent.glob(path.name + ".lock.new.*")),
                "old-format reclaim left staging behind")


def scenario_c57() -> None:
    # Н3: seen читается ПОД замком (сразу после acquire в main). Два
    # параллельных синка с разными id: победитель держит замок до тех пор,
    # пока второй поток не прочтёт seen (форма до v2 читает до замка --
    # на входе нож красен потерей id); в seen обязаны остаться ОБА id.
    with sync_fixture() as (module, path, home):
        module.CONFIG_LOCK_STALE_SECONDS = 30
        module.CONFIG_LOCK_TIMEOUT_SECONDS = 30
        real_publish = module.publish_backup
        real_load_seen = module.load_seen
        early_read = threading.Event()
        winner_holding = []
        readers = []
        ids_by_thread = {}

        def holding_publish(src, lock=None):
            if not winner_holding:
                winner_holding.append(True)
                early_read.wait(3.0)
            return real_publish(src, lock=lock)

        def counting_load_seen():
            thread = threading.current_thread()
            if thread not in readers:
                readers.append(thread)
            # Событие держит победителя до тех пор, пока ВТОРОЙ поток не
            # прочёл seen: у мутанта/старой формы это происходит до его
            # захвата (чтение ДО замка), у исправной формы -- только после
            # освобождения победителя.
            if len(readers) > 1:
                early_read.set()
            return real_load_seen()

        def thread_ids():
            return ids_by_thread.get(threading.current_thread(), ["fixture-model"])

        module.proxy_model_ids = thread_ids
        module.load_seen = counting_load_seen
        outcomes = []

        def runner(ids):
            ids_by_thread[threading.current_thread()] = ids
            try:
                rc_value, _ = invoke_sync(module)
                outcomes.append(str(rc_value))
            except BaseException as error:
                outcomes.append(f"raised {type(error).__name__}")

        # redirect_stdout глобален: выходы нитей не важны (как C28) --
        # сценарий читает rc/состояние seen-файла.
        real_stdout, real_stderr = sys.stdout, sys.stderr
        threads = [threading.Thread(target=runner, args=(ids,))
                   for ids in (["parallel-a"], ["parallel-b"])]
        try:
            with patch.object(module, "publish_backup", holding_publish):
                threads[0].start()
                time.sleep(0.3)
                threads[1].start()
                for thread in threads:
                    thread.join()
        finally:
            sys.stdout, sys.stderr = real_stdout, real_stderr
        require(sorted(outcomes) == ["0", "0"],
                f"parallel-sync outcomes: {outcomes}")
        require(Path(module.SEEN_PATH).exists(),
                "parallel-sync seen not written")
        require(set(json.loads(Path(module.SEEN_PATH).read_text(
            encoding="utf-8"))) == {"parallel-a", "parallel-b"},
            "parallel-sync seen lost an id")


def scenario_c58() -> None:
    # Р1: соперник держит замок ровно одну нашу итерацию (EEXIST), затем
    # отпускает -- захват происходит на ретрае. За время удержания дольше
    # сжатого срока устаревания mtime замка обязан остаться свежим: мёртвое
    # сердцебиение (флаг остановки взведён abandon'ом первой итерации и не
    # сброшен) состарило бы его, и ждущий писатель снял бы замок.
    with sync_fixture() as (module, path, home):
        module.CONFIG_LOCK_STALE_SECONDS = 1.5
        module.CONFIG_LOCK_HEARTBEAT_SECONDS = 0.4
        module.CONFIG_LOCK_TIMEOUT_SECONDS = 30
        real_rename = module.rename_noreplace
        real_backup = module.publish_backup
        contested = []

        def hold_then_release(dst):
            # Соперник держит путь ДОЛЬШЕ первой попытки публикации и
            # отпускает сам: снять его до вызова rename нельзя -- продукт
            # между отказом и повтором успевает убрать каталог своей уборкой.
            time.sleep(0.4)
            try:
                os.unlink(os.path.join(dst, "owner"))
                os.rmdir(dst)
            except OSError:
                pass

        def once_held_rename(src, dst):
            if str(dst) == str(path) + ".lock" and not contested:
                os.mkdir(dst)
                os.chmod(dst, 0o700)
                with open(os.path.join(dst, "owner"), "wb") as fh:
                    fh.write(b"5151 rival-token\n")
                moment = time.time_ns()
                os.utime(dst, ns=(moment, moment))
                contested.append(True)
                threading.Thread(target=hold_then_release, args=(dst,)).start()
            return real_rename(src, dst)

        ages = []
        # Свежесть читает ОТДЕЛЬНАЯ нить, пока держатель ещё внутри publish:
        # замок в этот момент обязан быть жив и свеж. На форме без
        # сердцебиения он за эти 2.5с успевает состариться ниже порога -- и
        # тогда ждущий писатель имел бы право его снять.
        def measure_later():
            time.sleep(2.5)
            try:
                info = os.stat(str(path) + ".lock")
            except FileNotFoundError:
                ages.append(None)
            else:
                ages.append(time.time() - info.st_mtime)

        measured = []

        def holding_publish(src, lock=None):
            # Замер свежести -- один раз, на первом удержании. Следующие
            # проходы (их порождает форма без сердцебиения: замок устарел и
            # его тут же перезахватили) идут без паузы, иначе прогон не
            # кончается.
            if not measured:
                measured.append(True)
                watcher = threading.Thread(target=measure_later)
                watcher.start()
                watcher.join()
            return real_backup(src, lock=lock)

        with patch.object(module, "rename_noreplace", once_held_rename), \
                patch.object(module, "publish_backup", holding_publish):
            rc, output = invoke_sync(module)
        require(rc == 0, f"retry-heartbeat rc={rc}\n{output}")
        require(ages and ages[0] is not None,
                f"retry-heartbeat let the lock age: the lock was gone when "
                f"measured ({ages}) -- a waiting writer would have reaped it")
        require(ages[0] <= module.CONFIG_LOCK_HEARTBEAT_SECONDS + 0.6,
                f"retry-heartbeat let the lock age to {ages[0]}s after the retry")


def scenario_c59() -> None:
    # Р2: путь просроченного замка исчезает между unlink owner и сверкой
    # (соперник-жнец снял каталог). Дверца -- подмена os.unlink: после
    # настоящего unlink владельца просроченного каталога делает
    # os.rmdir(lock.path). Ожидание: захват rc 0. Красен на входе:
    # FileNotFoundError сверки не пойман.
    with sync_fixture() as (module, path, home):
        lock = Path(str(path) + ".lock")
        lock.mkdir()
        (lock / "owner").write_bytes(b"stale-owner\n")
        stamp = time.time() - 20
        os.utime(lock, (stamp, stamp))
        stale_ino = lock.stat().st_ino
        real_unlink = module.os.unlink

        def reap_then_remove(name, *args, **kwargs):
            dir_fd = kwargs.get("dir_fd")
            if (name == "owner" and isinstance(dir_fd, int)
                    and threading.current_thread() is threading.main_thread()
                    and os.fstat(dir_fd).st_ino == stale_ino):
                result = real_unlink(name, *args, **kwargs)
                os.rmdir(lock)
                return result
            return real_unlink(name, *args, **kwargs)

        with patch.object(module.os, "unlink", side_effect=reap_then_remove):
            rc, output = invoke_sync(module)
        require(rc == 0, f"reap-vanished-path rc={rc}\n{output}")
        require(not lock.exists(),
                "reap-vanished-path left the lock behind")


def scenario_c60() -> None:
    # Р3: рядом с путём замка лежат два staging-остатка: просроченный с
    # owner и свежий соседский. Соперник держит путь одну итерацию, так что
    # захват проходит через ветку ожидания, где живёт уборка. После захвата
    # просроченного нет, свежий цел, свой staging убран публикацией. Красен
    # на входе: уборщика просроченных staging нет.
    with sync_fixture() as (module, path, home):
        require(hasattr(module, "reap_stale_staging"),
                "no stale-staging sweep")
        # CONSTRAINT: the rival holds 0.4 s; the fixture's 1 s acquisition
        # bound leaves no margin on a loaded host.
        module.CONFIG_LOCK_TIMEOUT_SECONDS = 5
        parent = path.parent
        stale = parent / (path.name + ".lock.new.111.deadbeefdeadbeef")
        fresh = parent / (path.name + ".lock.new.222.freshbeefbeefbeef")
        stale.mkdir()
        (stale / "owner").write_bytes(b"111 deadbeefdeadbeef\n")
        # Возраст привязан к порогу модуля, а не к абсолютным 20с: фикстура
        # сжимает таймаут захвата до 1с, и фиксированные 20с при пороге 10с
        # оказываются на грани -- прогон переходит её и каталог уже не просрочен.
        stamp = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
        os.utime(stale / "owner", (stamp, stamp))
        os.utime(stale, (stamp, stamp))
        fresh.mkdir()
        (fresh / "owner").write_bytes(b"222 freshbeefbeefbeef\n")
        moment = time.time_ns()
        os.utime(fresh, ns=(moment, moment))
        real_publish = module.rename_noreplace
        held_once = []

        def release_rival(dst):
            # Соперник держит путь дольше первой попытки и отпускает сам:
            # снятие до вызова rename не даёт отказу публикации случиться.
            time.sleep(0.4)
            try:
                os.unlink(os.path.join(dst, "owner"))
                os.rmdir(dst)
            except OSError:
                pass

        def once_held_rename(src, dst):
            if str(dst) == str(path) + ".lock" and not held_once:
                os.mkdir(dst)
                os.chmod(dst, 0o700)
                with open(os.path.join(dst, "owner"), "wb") as fh:
                    fh.write(b"3333 rival-token\n")
                now_ns = time.time_ns()
                os.utime(dst, ns=(now_ns, now_ns))
                held_once.append(True)
                threading.Thread(target=release_rival, args=(dst,)).start()
            return real_publish(src, dst)

        with patch.object(module, "rename_noreplace", once_held_rename):
            rc, output = invoke_sync(module)
        require(rc == 0, f"stale-staging-sweep rc={rc}\n{output}")
        require(not stale.exists(),
                "stale-staging-sweep left the expired staging")
        require(fresh.is_dir() and (fresh / "owner").read_bytes()
                == b"222 freshbeefbeefbeef\n",
                "stale-staging-sweep touched the fresh neighbour staging")
        require(not list(parent.glob(path.name + ".lock.new." + str(os.getpid()) + ".*")),
                "stale-staging-sweep removed the writer's own staging")


def scenario_c62() -> None:
    # Свой staging узнаётся по имени записи, не по написанию пути: путь
    # замка написан с двойным разделителем, свой staging старше срока
    # просрочки (писатель замер посреди публикации) уборкой не снимается,
    # чужой просроченный рядом снимается. Красен на входе: сравнение
    # путей строкой не узнаёт свой staging в другом написании.
    with sync_fixture() as (module, path, home):
        spelled = str(path.parent) + "//" + path.name
        lock = module.ConfigLock(spelled)
        stamp = time.time() - module.CONFIG_LOCK_STALE_SECONDS - 5
        own = path.parent / (path.name + ".lock.new.333.0123456789abcdef")
        foreign = path.parent / (path.name + ".lock.new.444.fedcba9876543210")
        for entry, token in ((own, b"333 0123456789abcdef\n"),
                             (foreign, b"444 fedcba9876543210\n")):
            entry.mkdir()
            (entry / "owner").write_bytes(token)
            os.utime(entry / "owner", (stamp, stamp))
            os.utime(entry, (stamp, stamp))
        lock.staging = lock.path + ".new.333.0123456789abcdef"
        module.reap_stale_staging(lock)
        require(own.is_dir() and (own / "owner").is_file(),
                "own-staging-spelling swept the writer's own staging")
        require(not foreign.exists(),
                "own-staging-spelling left the foreign stale staging")


def scenario_c61() -> None:
    # Р4: lock.start подменён на KeyboardInterrupt -- прерывание обязано
    # всплыть, а каталог на lock.path не остаться (публикация уже
    # состоялась, abandon снимает её по сверке идентичности). Красен на
    # входе: обработчика BaseException в acquire нет, каталог остаётся.
    with sync_fixture() as (module, path, home):

        def interrupted_start(self):
            raise KeyboardInterrupt

        with patch.object(module.ConfigLock, "start", interrupted_start):
            try:
                invoke_sync(module)
            except KeyboardInterrupt:
                pass
            else:
                raise BenchFailure(
                    "interrupt-after-publish did not raise KeyboardInterrupt")
        require(not Path(str(path) + ".lock").exists(),
                "interrupt-after-publish left the lock directory behind")


SCENARIOS: list[tuple[str, Callable[[], None]]] = [
    ("C1", scenario_c1), ("C2", scenario_c2), ("C3", scenario_c3),
    ("C4", scenario_c4), ("C5", scenario_c5), ("C6", scenario_c6),
    ("C7", scenario_c7), ("C8", scenario_c8), ("C9", scenario_c9),
    ("C10", scenario_c10), ("C11", scenario_c11), ("C12", scenario_c12),
    ("C13", scenario_c13), ("C14", scenario_c14),
    ("C15", scenario_c15), ("C16", scenario_c16),
    ("C17", scenario_c17), ("C18", scenario_c18),
    ("C19", scenario_c19), ("C20", scenario_c20),
    ("C21", scenario_c21), ("C22", scenario_c22),
    ("C23", scenario_c23), ("C24", scenario_c24),
    ("C25", scenario_c25), ("C26", scenario_c26),
    ("C27", scenario_c27), ("C28", scenario_c28),
    ("C29", scenario_c29), ("C31", scenario_c31),
    ("C32", scenario_c32), ("C33", scenario_c33),
    ("C34", scenario_c34), ("C35", scenario_c35),
    ("C36", scenario_c36), ("C37", scenario_c37),
    ("C38", scenario_c38), ("C39", scenario_c39),
    ("C40", scenario_c40), ("C41", scenario_c41),
    ("C42", scenario_c42), ("C43", scenario_c43),
    ("C44", scenario_c44), ("C45", scenario_c45),
    ("C46", scenario_c46), ("C47", scenario_c47),
    ("C48", scenario_c48), ("C49", scenario_c49),
    ("C50", scenario_c50), ("C50b", scenario_c50b),
    ("C51", scenario_c51), ("C52", scenario_c52),
    ("C53", scenario_c53), ("C54", scenario_c54),
    ("C55", scenario_c55), ("C56", scenario_c56),
    ("C57", scenario_c57), ("C58", scenario_c58),
    ("C59", scenario_c59), ("C60", scenario_c60),
    ("C61", scenario_c61), ("C62", scenario_c62),
]


def run_scenarios() -> int:
    mismatches = 0
    for name, scenario in SCENARIOS:
        try:
            scenario()
        except Exception as error:
            mismatches += 1
            print(f"costs-bench: СЦЕНАРИЙ {name}: FAIL: {error}")
        else:
            print(f"costs-bench: СЦЕНАРИЙ {name}: OK")
    print(f"costs-bench: ИТОГ сценариев={len(SCENARIOS)} расхождений={mismatches}")
    if len(SCENARIOS) != EXPECTED_SCENARIOS:
        print(f"costs-bench: ОТКАЗ -- сценариев {len(SCENARIOS)}, объявлено {EXPECTED_SCENARIOS}")
        return 4
    return 0 if mismatches == 0 else 1


def shell_python_heredocs(text: str) -> list[str]:
    """Bodies of .sh-victim heredocs fed to python.

    The opening rule lives in its single home, tools/heredoc-anchor.py
    (loaded at the top of this file); this wrapper only walks the lines and
    collects each body between an opener line and the verbatim tag line. An
    unclosed heredoc is a parse refusal (UnparsableVictim), not a silent
    tail-to-EOF swallow: a body the guard never saw is indistinguishable
    from a body it checked.
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
            raise UnparsableVictim(f"heredoc {tag} is not closed at {lines[i]!r}")
        bodies.append("\n".join(lines[i + 1:end]))
        i = end + 1
    return bodies


def victim_parses(path: Path) -> None:
    """Parse the victim with its OWN parser; otherwise raise UnparsableVictim.

    Circle 25, E-3: until this guard a replacement flew into the victim as
    free text, and a broken parse was exploited only BY CHANCE -- traces tied
    to a return code hid it today, and the first state-marker trace would
    have opened the same hole the corpus bench closed in circle 24. The kit's
    rule is the CHECK, not the absence of an exploit. For .py victims there
    are no embedded foreign-interpreter bodies (external calls go through
    script files, not inline text); .sh victims get their python heredoc
    bodies parsed by the same rule as corpus-tools-bench (circle 25, E-1).
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
                    f"heredoc body in {path}: line {error.lineno}: {error.msg}") from error


def replace_once(path: Path, old: str, new: str, name: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    require(count == 1, f"{name}: anchor occurs {count} times in {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    victim_parses(path)


def m1(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "if previous and not replacement:",
                 "if False and previous and not replacement:", "M1")


def m2(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "if previous and not replacement:",
                 "if not previous and not replacement:", "M2")


def m3a(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 "if routed:\n        adjusted = routed - reply_headroom()\n        if adjusted > 0:\n            return adjusted",
                 "if routed:\n        adjusted = routed - reply_headroom()\n        return adjusted", "M3a")


def m3b(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "if window is not None and window <= 0:",
                 "if False and window is not None and window <= 0:", "M3b")


def m4(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "age_seconds > CACHE_MAX_AGE_SECONDS",
                 "False", "M4")


def m5(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "age_seconds < -CACHE_FUTURE_TOLERANCE_SECONDS",
                 "False", "M5")


def m6(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "catalogue = json.load(fh)",
                 "raise error", "M6")


def m7(root: Path) -> None:
    replace_once(root / "claude_patch.py", "if alg not in INTEGRITY_ALGORITHMS:",
                 "if False and alg not in INTEGRITY_ALGORITHMS:", "M7")


def m8(root: Path) -> None:
    replace_once(root / "claude_patch.py",
                 "if not isinstance(version, str) or not VERSION.fullmatch(version):",
                 "if False and (not isinstance(version, str) or not VERSION.fullmatch(version)):",
                 "M8")


def m9(root: Path) -> None:
    replace_once(root / "tools" / "corpus-list.py", "if ':' in label:",
                 "if False and ':' in label:", "M9")


def m10(root: Path) -> None:
    replace_once(root / "claude-patch-all.sh",
                 '[[ "$name" =~ ^${base_re}\\.backup\\.[0-9]{8}-[0-9]{6}$ ]]',
                 'true', "M10")


def m11(root: Path) -> None:
    replace_once(root / "claude-patch-all.sh", "case \"$value\" in",
                 "case 0 in", "M11")


def m12(root: Path) -> None:
    replace_once(root / "claude-patch-all.sh", "while (( i < GATE_BUDGET )); do",
                 "for _ in $(seq 1 \"$GATE_BUDGET\"); do", "M12")


def m13(root: Path) -> None:
    # Волна 26, D-9: снять отсечение фолбэк-ветки limit.input сверху ёмкостью
    # маршрута -- ветка снова объявляет больше, чем везёт сам маршрут.
    replace_once(root / "set-model-costs.py",
                 "if not routed or explicit_input <= routed:",
                 "if True:", "M13")


def m14(root: Path) -> None:
    # Волна 26, D-9: то же для ветки limit.context минус headroom.
    replace_once(root / "set-model-costs.py",
                 "if not routed or adjusted <= routed:",
                 "if True:", "M14")


def m15(root: Path) -> None:
    # Волна 26, D-8: снять проверку величины -- 20-значное значение снова
    # уходит в bash-арифметику и заворачивается.
    replace_once(root / "claude-patch-all.sh",
                 "if (( ${#digits} > 19 )) \\\n     || { [[ \"${#digits}\" == 19 ]] "
                 "&& [[ \"$digits\" > \"9223372036854775807\" ]]; }; then",
                 "if false; then", "M15")


def m16(root: Path) -> None:
    replace_once(root / "claude-patch-all.sh",
                 'id="$(resolve_signing_identity)" || return 1',
                 'id="$(resolve_signing_identity)" || return 0', "M16")


def m17(root: Path) -> None:
    replace_once(root / "claude-patch-all.sh",
                 'if ! codesign -v --strict "$bin"; then',
                 'if false; then', "M17")


def m18(root: Path) -> None:
    replace_once(root / "claude_patch.py",
                 'die("no code-signing identity found; a stable identity is required for Keychain OAuth",\n'
                 '                code=1)',
                 'return', "M18")


def m19(root: Path) -> None:
    replace_once(root / "claude_patch.py",
                 'if out.returncode != 0:\n        die(f"post-check: --version failed',
                 'if False and out.returncode != 0:\n        die(f"post-check: --version failed', "M19")


def m20(root: Path) -> None:
    # Wave 230: the startup teeth call removed -- scenario C14 must catch a
    # bench that would measure on a broken instrument. The anchor is the
    # function's last line plus the module-level call (each occurs only
    # there); the flag assignment stays, so the scenario's check is what
    # reddens.
    replace_once(root / "tools" / "costs-bench.py",
                 "    ANCHOR_TEETH_RAN = True\n\n\n_anchor_teeth_hold()",
                 "    ANCHOR_TEETH_RAN = True", "M20")


def m21(root: Path) -> None:
    # #53: предикат дрейфа ослеплён в «всегда красный» (равная длина:
    # and -> or с паддингом) -- зелёный контроль C15 обязан упасть: без
    # пробела в строках вердикта быть не может.
    replace_once(root / "set-model-costs.py",
                 "if price_gap and priceable:",
                 "if price_gap or  priceable:", "M21")


def m22(root: Path) -> None:
    # #53: разбор каталога теряет объект-форму провайдера -- счёт уникальных
    # имён и сырых записей занижается МОЛЧА (первый счёт контроллера: 77
    # вместо 682). Равная длина: models -> modelz.
    replace_once(root / "set-model-costs.py",
                 'rows = rows.get("models")',
                 'rows = rows.get("modelz")', "M22")


def m23(root: Path) -> None:
    # Д4: мутант ДОХОДИТ до коллизии той же секунды и затирает ПЕРВЫЙ бэкап
    # вместо следующего суффикса. Ловит утверждение C17 о байтах первого
    # бэкапа; игла перезапинена на хвост continue после переноса unlink
    # стадии в finally (G8).
    replace_once(root / "set-model-costs.py",
                 "            except FileExistsError:\n"
                 "                continue\n"
                 "            linked = candidate",
                 "            except FileExistsError:\n"
                 "                os.replace(part, candidate)\n"
                 "                return candidate\n"
                 "            linked = candidate", "M23")


def m24(root: Path) -> None:
    replace_once(root / "set-model-costs.py", '    return catalogue, "network"',
                 '    write_json_atomically(CACHE_PATH, catalogue)\n    return catalogue, "network"', "M24")


def m25(root: Path) -> None:
    replace_once(root / "claude-patch-all.sh", 'if [[ -e "$legacy" ]]; then',
                 'if false; then', "M25")


def m26(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "def config_path():\n",
                 'def config_path():\n    return os.path.expanduser("~/.claude.json")\n', "M26")


def m27(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "        lock = acquire_config_lock(path)",
                 "        lock = None", "M27")


def m28(root: Path) -> None:
    replace_once(root / "set-model-costs.py", 'if catalogue_source == "network" and catalogue:',
                 'if catalogue_source == "network":', "M28")


def m29(root: Path) -> None:
    replace_once(root / "claude-patch-all.sh",
                 '|| [[ "$name" =~ ^${base_re}\\.backup\\.u[0-9]{8}-[0-9]{6}(\\.[0-9]{2})?$ ]] || continue',
                 '|| continue', "M29")


def m30(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "        os.kill(pid, 0)",
                 "        raise ProcessLookupError", "M30")


def m31(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "            result = 4",
                 "            result = 0", "M31")


def m32(root: Path) -> None:
    replace_once(root / "set-model-costs.py", "    except FileNotFoundError:\n        configured = 0",
                 "    except Exception:\n        configured = 0", "M32")


def m33(root: Path) -> None:
    # Д1: rmdir без сверки идентичности -- чужой замок сносится в finally.
    # Игла перезапинена на форму v2: foreign-флаг release присвоен константой,
    # release всегда снимает путь (owner уже убран -- пустой чужой каталог
    # сносится, чужой с owner остаётся цел только ENOTEMPTY).
    replace_once(root / "set-model-costs.py",
                 "                foreign = (now.st_dev, now.st_ino) != (held.st_dev, held.st_ino)\n",
                 "                foreign = False\n", "M33")


def m34(root: Path) -> None:
    # Д1: нить сердцебиения запускается, но ничего не делает (пустой target),
    # иначе join в finally роняет синк чужой ошибкой.
    replace_once(root / "set-model-costs.py",
                 "        self._thread = threading.Thread(target=self._heartbeat, daemon=True)\n"
                 "        self._thread.start()",
                 "        self._thread = threading.Thread(target=lambda: None, daemon=True)\n"
                 "        self._thread.start()", "M34")


def m35(root: Path) -> None:
    # Д1: проверка владения перед публикацией отключена целиком. Игла
    # перезапинена на критсекцию verify_owned (G4) -- до FIX5 проверка
    # начиналась с if self.lost на 8 пробелах.
    replace_once(root / "set-model-costs.py",
                 "        with self._identity_guard:\n"
                 "            if self.lost:",
                 "        with self._identity_guard:\n"
                 "            return\n"
                 "            if self.lost:", "M35")


def m38(root: Path) -> None:
    # Д1(б): чужой СВЕЖИЙ замок удаляется как устаревший. Игла перезапинена
    # на свежесть-порог ветки ожидания v2 (fstat удерживаемого fd).
    replace_once(root / "set-model-costs.py",
                 "                    if time.time() - st.st_mtime <= CONFIG_LOCK_STALE_SECONDS:\n",
                 "                    if False:\n", "M38")


def seen_write_mutation(root: Path, name: str, needle: str) -> None:
    # Вставка ПЕРЕД хвостовой строкой якоря: запись после return/raise --
    # мёртвый код, и мутация ничего не доказывает.
    head, _, tail = needle.rstrip("\n").rpartition("\n")
    replacement = f"{head}\n        save_seen(set())\n{tail}\n"
    replace_once(root / "set-model-costs.py", needle, replacement, name)


def m40(root: Path) -> None:
    seen_write_mutation(root, "M40",
        '        print(f"ERROR: {path} not found; nothing written", file=sys.stderr)\n        return 1\n')


def m41(root: Path) -> None:
    # Одна ветка кода на два случая фикстуры: нечитаем и битый JSON.
    seen_write_mutation(root, "M41",
        '        print(f"ERROR: {path} unreadable ({error}); nothing written", file=sys.stderr)\n        return 1\n')


def m43(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '        return 1\n    if not isinstance(config, dict):\n'
                 '        print(f"ERROR: {path} no longer holds a JSON object; nothing written", file=sys.stderr)\n'
                 '        return 1\n',
                 '        return 1\n    if not isinstance(config, dict):\n'
                 '        print(f"ERROR: {path} no longer holds a JSON object; nothing written", file=sys.stderr)\n'
                 '        save_seen(set())\n'
                 '        return 1\n', "M43")


def m44(root: Path) -> None:
    seen_write_mutation(root, "M44",
        '        print(f"ERROR: cannot reach the proxy: {error}", file=sys.stderr)\n        return 1\n')


def m45(root: Path) -> None:
    seen_write_mutation(root, "M45",
        '        print(f"ERROR: catalogue unavailable ({error}); nothing written", file=sys.stderr)\n        return 1\n')


def m46(root: Path) -> None:
    seen_write_mutation(root, "M46",
        '        print(f"ERROR: {path} disappeared while this tool was syncing; "\n'
        '              "nothing written", file=sys.stderr)\n        return 1\n')


def m47(root: Path) -> None:
    seen_write_mutation(root, "M47",
        '        print(f"ERROR: {path} no longer parses ({error}); nothing written",\n'
        '              file=sys.stderr)\n        return 1\n')


def m48(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '        return 1\n\n    reply_headroom()',
                 '        save_seen(set())\n        return 1\n\n    reply_headroom()', "M48")


def m49(root: Path) -> None:
    seen_write_mutation(root, "M49",
        '    if empty_replacement_refused("customModelCosts", costs, "prices"):\n        return 1\n')


def m50(root: Path) -> None:
    seen_write_mutation(root, "M50",
        '    if empty_replacement_refused("customModelContextWindows", windows, "windows"):\n        return 1\n')


def m51(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '    else:\n'
                 '        raise BackupNameExhausted(f"backup name space exhausted for {stamp}; nothing written")',
                 '    else:\n'
                 '        save_seen(set())\n'
                 '        raise BackupNameExhausted(f"backup name space exhausted for {stamp}; nothing written")',
                 "M51")


def m52(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '    except Exception as error:\n'
                 '        raise SettingsUnreadable(f"{path} unreadable ({error}); nothing written") from error',
                 '    except Exception as error:\n'
                 '        save_seen(set())\n'
                 '        raise SettingsUnreadable(f"{path} unreadable ({error}); nothing written") from error',
                 "M52")


def m53(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '        raise ValueError("CLAUDE_CONFIG_DIR is set but empty; nothing written")\n',
                 '        save_seen(set())\n'
                 '        raise ValueError("CLAUDE_CONFIG_DIR is set but empty; nothing written")\n',
                 "M53")


def m54(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '        raise ValueError("HOME is empty or not set; nothing written")\n',
                 '        save_seen(set())\n'
                 '        raise ValueError("HOME is empty or not set; nothing written")\n',
                 "M54")


def m55(root: Path) -> None:
    # Игла перезапинена на классификацию ELOOP/ENOTDIR протокола v2
    # (открытие занятого пути с O_NOFOLLOW): отказ пишет seen.
    replace_once(root / "set-model-costs.py",
                 '                except OSError as exc_r:\n'
                 '                    if exc_r.errno in (errno.ELOOP, errno.ENOTDIR):\n'
                 '                        raise ConfigLockNotADirectory(\n',
                 '                except OSError as exc_r:\n'
                 '                    if exc_r.errno in (errno.ELOOP, errno.ENOTDIR):\n'
                 '                        save_seen(set())\n'
                 '                        raise ConfigLockNotADirectory(\n',
                 "M55")


def m56(root: Path) -> None:
    seen_write_mutation(root, "M56",
        '        print(f"ERROR: cannot reach the proxy: {error}", file=sys.stderr)\n        return 2\n')


def m57(root: Path) -> None:
    seen_write_mutation(root, "M57",
        '              "is unmeasurable, refusing to answer", file=sys.stderr)\n        return 2\n')


def m59(root: Path) -> None:
    seen_write_mutation(root, "M59",
        '        print("ERROR: stored rows are stale for models the proxy serves right "\n'
        '              "now; re-run the sync", file=sys.stderr)\n        return 1\n')


def m60(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '        return 1\n    return 0\n',
                 '        return 1\n    save_seen(set())\n    return 0\n', "M60")


def m61(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '            raise ConfigLockHeld(f"config lock {lock.path} held by another writer; nothing written")\n',
                 '            save_seen(set())\n'
                 '            raise ConfigLockHeld(f"config lock {lock.path} held by another writer; nothing written")\n',
                 "M61")


def m62(root: Path) -> None:
    seen_write_mutation(root, "M62",
        '        print("\\n--dry-run: nothing written")\n        return 0\n')


def m63(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '    if "--show" in sys.argv:\n        print(json.dumps({\n',
                 '    if "--show" in sys.argv:\n        sweep_stale_temps(path)\n        print(json.dumps({\n',
                 "M63")


def m64(root: Path) -> None:
    replace_once(root / "tools" / "costs-bench.py",
                 '    env = {key: value for key, value in os.environ.items()\n'
                 '           if key not in ("CLAUDE_CONFIG_DIR", "CLAUDE_CODE_CUSTOM_OAUTH_URL")}',
                 '    env = dict(os.environ)', "M64")


def m65(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '    except FileNotFoundError:\n'
                 '        # A rival sweeper took it between our decision and the unlink: its\n',
                 '    except FileNotFoundError:\n'
                 '        raise\n'
                 '        # A rival sweeper took it between our decision and the unlink: its\n',
                 "M65")


def m66(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '            if new_match.group("tag") != tag:\n'
                 '                print(f"Skipped foreign temp {temp}")\n                continue\n',
                 '            if False:\n'
                 '                print(f"Skipped foreign temp {temp}")\n                continue\n',
                 "M66")


def m67(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '            elif state == "dead":\n'
                 '                remove_temp(directory, name)\n            continue\n',
                 '            elif state == "dead":\n'
                 '                pass\n            continue\n', "M67")


def m68(root: Path) -> None:
    # Игла перезапинена на форму с age (F4): «всегда сносить» -- мутант
    # отличим от m72 («никогда не сносить» тем же якорем).
    replace_once(root / "set-model-costs.py",
                 '            if age >= TEMP_OLD_FORM_AGE_SECONDS:\n'
                 '                remove_temp(directory, name)\n',
                 '            if True:\n'
                 '                remove_temp(directory, name)\n', "M68")


def m69(root: Path) -> None:
    replace_once(root / "claude-patch-all.sh",
                 '  if [[ "$base" == */ ]]; then\n'
                 '    out="${base}.claude${suffix}.json"\n',
                 '  if false; then\n'
                 '    out="${base}.claude${suffix}.json"\n', "M69")


def m70(root: Path) -> None:
    replace_once(root / "judge" / "validate.py",
                 "    except ValueError as error:\n"
                 "        print(f'ERROR: {error}', file=sys.stderr)\n"
                 "        raise SystemExit(2)\n",
                 "    except KeyError as error:\n"
                 "        print(f'ERROR: {error}', file=sys.stderr)\n"
                 "        raise SystemExit(2)\n", "M70")


def m71(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '                    if catalogue:\n',
                 '                    if True:\n', "M71")


def m72(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '            if age >= TEMP_OLD_FORM_AGE_SECONDS:\n'
                 '                remove_temp(directory, name)\n',
                 '            if age >= TEMP_OLD_FORM_AGE_SECONDS:\n'
                 '                pass\n', "M72")


def m73(root: Path) -> None:
    # Д1: просроченный замок больше не снимается (свежесть-порог всегда
    # срабатывает). Игла перезапинена на ветку ожидания v2.
    replace_once(root / "set-model-costs.py",
                 "                    if time.time() - st.st_mtime <= CONFIG_LOCK_STALE_SECONDS:\n",
                 "                    if True:\n", "M73")


def m74(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '            if pid is None:\n'
                 '                print(f"Skipped temp with unusable pid {temp}")\n                continue\n',
                 '            if pid is None:\n'
                 '                remove_temp(directory, name)\n                continue\n', "M74")


def m75(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '        if not stat_module.S_ISREG(os.lstat(temp).st_mode):\n'
                 '            print(f"Skipped non-file temp {temp}")\n            return\n',
                 '        if False:\n'
                 '            print(f"Skipped non-file temp {temp}")\n            return\n', "M75")


def m76(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '    except OSError as error:\n'
                 '        print(f"Could not sweep {temp}: {error}")\n        return\n',
                 '    except OSError as error:\n        raise\n', "M76")


def m77(root: Path) -> None:
    # Д15: файл на месте замка больше не классифицируется (ENOTDIR выпал
    # из пары ELOOP/ENOTDIR) -- именованный «is not a directory» теряется.
    replace_once(root / "set-model-costs.py",
                 "                    if exc_r.errno in (errno.ELOOP, errno.ENOTDIR):\n",
                 "                    if exc_r.errno == errno.ELOOP:\n", "M77")


def m78(root: Path) -> None:
    replace_once(root / "set-model-costs.py",
                 '    if directory is None and not os.environ.get("HOME"):\n',
                 '    if False:\n', "M78")


def m79(root: Path) -> None:
    # G1 (R3): дескриптор снова закрывается по хвосту каждого _adopt --
    # возврат к форме «открыть-на-каждый-refresh», в которой номер inode
    # свободен МЕЖДУ _adopt и переиспользуется соперником. Двухточечная
    # игла FIX3 мертва структурно: обе её точки ушли с переписыванием _adopt.
    replace_once(root / "set-model-costs.py",
                 "                self.identity = (after.st_dev, after.st_ino, after.st_mtime_ns)\n",
                 "                self.identity = (after.st_dev, after.st_ino, after.st_mtime_ns)\n"
                 "                os.close(self._fd)\n"
                 "                self._fd = None\n", "M79")


def m80(root: Path) -> None:
    # Д1: проверка перед КАЖДОЙ попыткой link снята.
    replace_once(root / "set-model-costs.py",
                 "            if lock is not None:\n"
                 "                lock.verify_owned()\n"
                 "            try:\n"
                 "                os.link(part, candidate)\n",
                 "            try:\n"
                 "                os.link(part, candidate)\n", "M80")


def m81(root: Path) -> None:
    # Д1: проверка непосредственно перед переименованием конфига снята.
    replace_once(root / "set-model-costs.py",
                 "        if lock is not None:\n"
                 "            lock.verify_owned()\n"
                 "        os.replace(tmp, path)\n",
                 "        os.replace(tmp, path)\n", "M81")


def m82(root: Path) -> None:
    # Q1: verify остался только перед ПЕРВОЙ попыткой link; захват после
    # коллизии первого имени публикует суффикс под чужим замком.
    replace_once(root / "set-model-costs.py",
                 "            # Verified before EVERY link attempt, not once before the loop:\n"
                 "            # each retry is another chance for a takeover to slip in.\n"
                 "            if lock is not None:\n"
                 "                lock.verify_owned()\n",
                 "            # Verified before EVERY link attempt, not once before the loop:\n"
                 "            # each retry is another chance for a takeover to slip in.\n"
                 "            if number == 0 and lock is not None:\n"
                 "                lock.verify_owned()\n", "M82")


def m83(root: Path) -> None:
    # Q2: expanduser добрался до явного CCD -- литеральная `~` раскрылась,
    # и легаси-проба на раскрытом месте увела резолвер от паритета.
    replace_once(root / "set-model-costs.py",
                 '    settings_dir = directory or os.path.expanduser("~/.claude")\n',
                 '    settings_dir = os.path.expanduser(directory or "~/.claude")\n', "M83")


def m84(root: Path) -> None:
    # Q3: из начального обработчика ушёл OSError -- нечитаемый конфиг
    # летит наружу трассировкой вместо именованного отказа.
    replace_once(root / "set-model-costs.py",
                 '    except FileNotFoundError:\n'
                 '        print(f"ERROR: {path} not found; nothing written", file=sys.stderr)\n'
                 '        return 1\n'
                 '    except (OSError, ValueError) as error:\n',
                 '    except FileNotFoundError:\n'
                 '        print(f"ERROR: {path} not found; nothing written", file=sys.stderr)\n'
                 '        return 1\n'
                 '    except ValueError as error:\n', "M84")


def m85(root: Path) -> None:
    # Протокол v2: сверка идентичности в abandon снята -- после подмены
    # нашего каталога отказ start сносит ПУСТОЙ каталог соперника (каталог
    # с owner держит ENOTEMPTY -- защита по построению). Прежняя игла
    # (ветка elif created) мертва: ветка удалена протоколом v2 (свидетель
    # всегда fd).
    replace_once(root / "set-model-costs.py",
                 "                    if (now.st_dev, now.st_ino) == (held.st_dev, held.st_ino):\n",
                 "                    if True:\n", "M85")


def m86(root: Path) -> None:
    # F2: критсекция снята с _adopt (utime и запись идентичности разнесены) --
    # читатель видит mtime диска впереди self.identity.
    replace_once(root / "set-model-costs.py",
                 "        with self._identity_guard:\n"
                 "            owned = self.identity\n"
                 "            moment = time.time_ns()\n",
                 "        owned = self.identity\n"
                 "        moment = time.time_ns()\n"
                 "        if True:\n", "M86")


def m87(root: Path) -> None:
    # F3: ConfigLockLost снова глотается общим обработчиком бокового файла --
    # потеря владения на записи seen даёт rc 4 вместо rc 5.
    replace_once(root / "set-model-costs.py",
                 "        except ConfigLockLost:\n"
                 "            # CONSTRAINT: a side file refused because the LOCK was lost is a\n"
                 "            # named rc-5 refusal, not a side-file warning (rc 4); the generic\n"
                 "            # handler below must not swallow it.\n"
                 "            raise\n",
                 "", "M87")


def m88(root: Path) -> None:
    # F4: пред-remove lstat снова нетерпим -- исчезнувший между listdir и
    # lstat temp роняет синк трассировкой.
    replace_once(root / "set-model-costs.py",
                 "            try:\n"
                 "                age = now - os.lstat(temp).st_mtime\n"
                 "            except FileNotFoundError:\n"
                 "                # A rival sweeper removed the temp between our listdir and\n"
                 "                # this lstat: its removal line belongs to that run, not this.\n"
                 "                continue\n",
                 "            age = now - os.lstat(temp).st_mtime\n", "M88")


def m89(root: Path) -> None:
    # F5: классификация неописуемого пути (ELOOP/ENOTDIR -> именованный
    # отказ) снята -- отказ уходит в общий errno-отказ. Игла перезапинена
    # на пару errno протокола v2.
    replace_once(root / "set-model-costs.py",
                 "                    if exc_r.errno in (errno.ELOOP, errno.ENOTDIR):\n",
                 "                    if False:\n", "M89")


def m90(root: Path) -> None:
    # F6: отображение OSError -> ConfigLockLost снято -- пропажа каталога
    # замка под _adopt снова уходит трейсбеком вместо именованного отказа.
    # Игла перезапинена на хвост _adopt без finally (G1 убрал его).
    replace_once(root / "set-model-costs.py",
                 "                self.identity = (after.st_dev, after.st_ino, after.st_mtime_ns)\n"
                 "            except OSError as exc:\n"
                 "                self.lost = True\n"
                 "                raise ConfigLockLost(\n"
                 "                    f\"config lock {self.path} lost: [Errno {exc.errno}] {exc.strerror}; nothing written\")\n",
                 "                self.identity = (after.st_dev, after.st_ino, after.st_mtime_ns)\n"
                 "            except OSError as exc:\n"
                 "                raise\n", "M90")


def m91(root: Path) -> None:
    # F7: utime возвращён к ПУТИ -- в окне захвата процесс трогает mtime
    # чужого каталога вместо своего дескриптора. Игла перезапинена на
    # РЕФРЕШ-точку (за ней следует path_now-сверка; стартовая ветка
    # отличается следующей строкой) -- до FIX5 utime по fd был один.
    replace_once(root / "set-model-costs.py",
                 "                    os.utime(self._fd, ns=(moment, moment))\n"
                 "                    path_now = os.stat(self.path)\n",
                 "                    os.utime(self.path, ns=(moment, moment))\n"
                 "                    path_now = os.stat(self.path)\n", "M91")


def m92(root: Path) -> None:
    # F4b: внешний except OSError снят (внутренние остаются) -- иной OSError
    # по пути замка снова уходит трейсбеком мимо rc 5. Игла перезапинена на
    # обработчик acquire протокола v2 (с уборкой abandon).
    replace_once(root / "set-model-costs.py",
                 "        except OSError as exc:\n"
                 "            lock.abandon()\n"
                 "            raise ConfigLockUnavailable(\n"
                 "                f\"config lock {lock.path} unusable: [Errno {exc.errno}] {exc.strerror}; nothing written\") from None\n",
                 "        except OSError:\n"
                 "            raise\n", "M92")


def m93(root: Path) -> None:
    # F4b: сообщение OSError-потери снова зовёт чужого писателя -- отказ
    # ложно именует причину. Игла перезапинена на хвост _adopt без finally;
    # строка identity отличает её от того же обработчика в verify_owned.
    replace_once(root / "set-model-costs.py",
                 "                self.identity = (after.st_dev, after.st_ino, after.st_mtime_ns)\n"
                 "            except OSError as exc:\n"
                 "                self.lost = True\n"
                 "                raise ConfigLockLost(\n"
                 "                    f\"config lock {self.path} lost: [Errno {exc.errno}] {exc.strerror}; nothing written\")\n",
                 "                self.identity = (after.st_dev, after.st_ino, after.st_mtime_ns)\n"
                 "            except OSError as exc:\n"
                 "                self.lost = True\n"
                 "                raise ConfigLockLost(\n"
                 "                    f\"config lock {self.path} lost to another writer; nothing written\")\n", "M93")


def m94(root: Path) -> None:
    # G2: обработчик OSError в release снят -- отказ rmdir снова уходит
    # голым исключением из finally main поверх вычисленного rc.
    replace_once(root / "set-model-costs.py",
                 "            except OSError as exc:\n"
                 "                print(f\"lock not released: [Errno {exc.errno}] {exc.strerror} ({self.path})\",\n"
                 "                      file=sys.stderr)\n",
                 "", "M94")


def m95(root: Path) -> None:
    # G3: уборка abandon из обеих веток провала start() снята -- наш
    # каталог снова остаётся после именованного отказа. Игла перезапинена
    # на обработчики провала start протокола v2 (публикация уже прошла).
    replace_once(root / "set-model-costs.py",
                 "            try:\n"
                 "                lock.start()\n"
                 "            except ConfigLockLost:\n"
                 "                lock.abandon()\n"
                 "                raise\n"
                 "            except Exception as error:\n"
                 "                lock.abandon()\n"
                 "                raise ConfigLockUnavailable(\n"
                 "                    f\"config lock {lock.path} unusable: {error}; nothing written\") from None\n",
                 "            try:\n"
                 "                lock.start()\n"
                 "            except ConfigLockLost:\n"
                 "                raise\n"
                 "            except Exception as error:\n"
                 "                raise ConfigLockUnavailable(\n"
                 "                    f\"config lock {lock.path} unusable: {error}; nothing written\") from None\n",
                 "M95")
    # Внешний обработчик тоже снимает каталог на этом пути: провал start()
    # всплывает к нему. Без снятия и его уборки мутация остаётся зелёной.
    replace_once(root / "set-model-costs.py",
                 "            except OSError:\n"
                 "                pass\n"
                 "            lock.abandon()\n"
                 "            raise\n",
                 "            except OSError:\n"
                 "                pass\n"
                 "            raise\n", "M95")


def m96(root: Path) -> None:
    # G5: chmod каталога строительства снят -- каталог снова наследует
    # umask вызывающего. Игла перезапинена на staging-каталог протокола v2.
    replace_once(root / "set-model-costs.py",
                 "                os.chmod(staging, 0o700)\n",
                 "", "M96")


def m97(root: Path) -> None:
    # G7: обёртка listdir свипа снята -- непричитаемый каталог снова роняет
    # синк трейсбеком.
    replace_once(root / "set-model-costs.py",
                 "    try:\n"
                 "        names = sorted(os.listdir(directory))\n"
                 "    except OSError as exc:\n"
                 "        print(f\"Could not sweep {directory}: [Errno {exc.errno}] {exc.strerror}\")\n"
                 "        return\n"
                 "    for name in names:\n",
                 "    names = sorted(os.listdir(directory))\n"
                 "    for name in names:\n", "M97")


def m98(root: Path) -> None:
    # G8: карта OSError в write_json_atomically снята -- отказ записи снова
    # уходит голым исключением вместо именованного rc 6.
    replace_once(root / "set-model-costs.py",
                 "    except OSError as exc:\n"
                 "        # CONSTRAINT: a destination that could not be reached is a named\n"
                 "        # rc-6 refusal with the errno and the path; the staging name is\n"
                 "        # always removed. Nothing here is a lock loss -- ConfigLockLost is\n"
                 "        # not an OSError and passes to its own handler.\n"
                 "        try:\n"
                 "            os.unlink(tmp)\n"
                 "        except OSError:\n"
                 "            pass\n"
                 "        raise ConfigWriteFailed(\n"
                 "            f\"could not write {path}: [Errno {exc.errno}] {exc.strerror}; nothing written\") from None\n",
                 "", "M98")


def m99(root: Path) -> None:
    # G8: карта OSError в publish_backup снята -- отказ публикации снова
    # уходит голым исключением.
    replace_once(root / "set-model-costs.py",
                 "    except OSError as exc:\n"
                 "        # CONSTRAINT: an I/O failure anywhere in the publish path is a named\n"
                 "        # rc-6 refusal, never a traceback; the \"nothing written\" tail is\n"
                 "        # claimed only while the destination name is still untouched\n"
                 "        # (linked is None). Lock losses and name exhaustion are not OSError\n"
                 "        # and pass through to their own handlers.\n"
                 "        raise ConfigWriteFailed(\n"
                 "            f\"could not publish backup {src}: [Errno {exc.errno}] {exc.strerror}\"\n"
                 "            + (\"; nothing written\" if linked is None else \"\")) from None\n",
                 "", "M99")


def m100(root: Path) -> None:
    # G8: unlink стадии в finally снова ловит только FileNotFoundError --
    # иной отказ уборки затеняет успешную публикацию.
    replace_once(root / "set-model-costs.py",
                 "        try:\n"
                 "            os.unlink(part)\n"
                 "        except OSError:\n"
                 "            pass\n",
                 "        try:\n"
                 "            os.unlink(part)\n"
                 "        except FileNotFoundError:\n"
                 "            pass\n", "M100")


def m101(root: Path) -> None:
    # V1: отказ шага строительства снова оставляет наш каталог -- уборка
    # staging из обработчика снята. Игла перезапинена на обработчик шага 1
    # протокола v2 (порядок chmod/свидетель структурно исчез: свидетель
    # всегда fstat удерживаемого дескриптора).
    replace_once(root / "set-model-costs.py",
                 "            except OSError as error:\n"
                 "                lock.abandon()\n"
                 "                raise ConfigLockUnavailable(\n"
                 "                    f\"config lock {lock.path} unusable: [Errno {error.errno}] {error.strerror}; nothing written\") from None\n",
                 "            except OSError as error:\n"
                 "                raise ConfigLockUnavailable(\n"
                 "                    f\"config lock {lock.path} unusable: [Errno {error.errno}] {error.strerror}; nothing written\") from None\n",
                 "M101")
    # Отказ шага строительства всплывает к внешнему обработчику, который
    # снимает staging сам. Без снятия и его уборки мутация остаётся зелёной.
    replace_once(root / "set-model-costs.py",
                 "            except OSError:\n"
                 "                pass\n"
                 "            lock.abandon()\n"
                 "            raise\n",
                 "            except OSError:\n"
                 "                pass\n"
                 "            raise\n", "M101")


def m102(root: Path) -> None:
    # V2: строка чужого владельца снова уходит в stdout -- поток не пинится.
    replace_once(root / "set-model-costs.py",
                 "                    print(f\"lock not released: owned by another writer ({self.path})\",\n"
                 "                          file=sys.stderr)\n",
                 "                    print(f\"lock not released: owned by another writer ({self.path})\")\n",
                 "M102")


def m103(root: Path) -> None:
    # G11: старая :662 возвращена -- семья "/.claude.json" снова строится из
    # пустого HOME (трасса) и роняет функцию при неустановленном HOME (set -u).
    replace_once(root / "claude-patch-all.sh",
                 '  if [[ -n "${HOME-}" && "$resolved" != "$HOME/.claude.json" ]]; then families+=("$HOME/.claude.json"); fi\n',
                 '  [[ "$resolved" == "$HOME/.claude.json" ]] || families+=("$HOME/.claude.json")\n',
                 "M103")


def m104(root: Path) -> None:
    # Протокол v2: публикация через os.rename (замена) -- живой ПУСТОЙ
    # каталог соперника по пути молча заменяется нашим.
    replace_once(root / "set-model-costs.py",
                 "                rename_noreplace(staging, lock.path)\n",
                 "                os.rename(staging, lock.path)\n", "M104")


def m105(root: Path) -> None:
    # Протокол v2: проверка listdir снята -- чужой файл в просроченном
    # каталоге больше не именуется отказом foreign entries.
    replace_once(root / "set-model-costs.py",
                 "                    if any(entry != \"owner\" for entry in entries):\n",
                 "                    if False:\n", "M105")


def m106(root: Path) -> None:
    # Протокол v2: rmdir без предварительной сверки пути -- подменённый
    # пустой свежий каталог соперника снимается нашим циклом просрочки.
    replace_once(root / "set-model-costs.py",
                 "                    if (info.st_dev, info.st_ino) != (st.st_dev, st.st_ino):\n"
                 "                        reap_stale_staging(lock)  # identity moved: keep waiting\n"
                 "                        continue\n",
                 "", "M106")


def m107(root: Path) -> None:
    # Н3: чтение seen возвращено ДО захвата замка -- параллельный синк
    # теряет чужие id.
    replace_once(root / "set-model-costs.py",
                 "        lock = acquire_config_lock(path)\n"
                 "        remembered = load_seen()\n",
                 "        remembered = load_seen()\n"
                 "        lock = acquire_config_lock(path)\n", "M107")


def m108(root: Path) -> None:
    # Н2: errno-строка release снова уходит в stdout.
    replace_once(root / "set-model-costs.py",
                 "                print(f\"lock not released: [Errno {exc.errno}] {exc.strerror} ({self.path})\",\n"
                 "                      file=sys.stderr)\n",
                 "                print(f\"lock not released: [Errno {exc.errno}] {exc.strerror} ({self.path})\")\n",
                 "M108")


def m109(root: Path) -> None:
    # Протокол v2: release не убирает owner -- rmdir встречает ENOTEMPTY,
    # замок остаётся.
    replace_once(root / "set-model-costs.py",
                 "                if not foreign:\n"
                 "                    try:\n"
                 "                        os.unlink(\"owner\", dir_fd=self._fd)\n",
                 "                if not foreign:\n"
                 "                    try:\n"
                 "                        pass\n", "M109")


def m110(root: Path) -> None:
    # Протокол v2: пустой каталог больше не считается форматом до v2 --
    # снятие просроченного пустого каталога превращается в отказ.
    replace_once(root / "set-model-costs.py",
                 "                    if any(entry != \"owner\" for entry in entries):\n",
                 "                    if entries != [\"owner\"]:\n", "M110")


def m111(root: Path) -> None:
    # Протокол v2: занятый путь (EEXIST/ENOTEMPTY) больше не ждёт --
    # немедленный именованный отказ вместо ветки ожидания/просрочки.
    replace_once(root / "set-model-costs.py",
                 "                if exc.errno not in (errno.EEXIST, errno.ENOTEMPTY):\n",
                 "                if True:\n", "M111")


def m112(root: Path) -> None:
    # Протокол v2: отказ ФС в no-replace (ENOSYS/EINVAL/ENOTSUP) уходит в
    # общий errno-отказ -- именование filesystem-причины снято.
    replace_once(root / "set-model-costs.py",
                 "                    if exc.errno in (errno.ENOSYS, errno.EINVAL, errno.ENOTSUP):\n"
                 "                        raise ConfigLockUnavailable(\n"
                 "                            \"no atomic no-replace rename on this filesystem\") from None\n",
                 "", "M112")


def m113(root: Path) -> None:
    # Р1: свежий флаг остановки в start() снят -- сердцебиение захвата с
    # ретрая видит флаг, взведённый abandon'ом первой итерации, и не
    # обновляет замок.
    replace_once(root / "set-model-costs.py",
                 "        # what makes a lock won on a retry stay alive.\n"
                 "        self._stop = threading.Event()\n"
                 "        self._adopt()\n",
                 "        # what makes a lock won on a retry stay alive.\n"
                 "        self._adopt()\n", "M113")


def m114(root: Path) -> None:
    # Р2: сверка пути в жатве снова без терпимости к исчезновению каталога
    # между unlink owner и stat.
    replace_once(root / "set-model-costs.py",
                 "                    try:\n"
                 "                        info = os.stat(lock.path)\n"
                 "                    except FileNotFoundError:\n",
                 "                    try:\n"
                 "                        info = os.stat(lock.path)\n"
                 "                    except SystemExit:\n", "M114")


def m115(root: Path) -> None:
    # Р3: вызов уборки в ветке ожидания (свежий держатель, до continue)
    # снят -- остаток чужого просроченного staging переживает захват.
    replace_once(root / "set-model-costs.py",
                 "reap_stale_staging(lock)  # fresh holder: wait\n",
                 "None  # fresh holder: wait\n", "M115")


def m116(root: Path) -> None:
    # Р4: обработчик BaseException в acquire снят -- прерывание после
    # публикации оставляет каталог замка без владельца.
    replace_once(root / "set-model-costs.py",
                 "                f\"config lock {lock.path} unusable: [Errno {exc.errno}] {exc.strerror}; nothing written\") from None\n"
                 "        except BaseException:\n",
                 "                f\"config lock {lock.path} unusable: [Errno {exc.errno}] {exc.strerror}; nothing written\") from None\n"
                 "        except BaseException:\n"
                 "            raise\n", "M116")


def m117(root: Path) -> None:
    # Свой staging перестаёт узнаваться по имени -- уборка снимает
    # staging замершего писателя.
    replace_once(root / "set-model-costs.py",
                 "        if name == own:\n            continue\n",
                 "        if False:\n            continue\n", "M117")


MUTATIONS: list[tuple[str, Callable[[Path], None], str, str]] = [
    ("M1", m1, "C1", "empty replacement"),
    ("M2", m2, "C2", "empty replacement"),
    ("M3a", m3a, "C3", "invalid routed window did not continue"),
    ("M3b", m3b, "C3", "write guard stored a negative window"),
    ("M4", m4, "C4", "invalid cache was accepted"),
    ("M5", m5, "C5", "invalid cache was accepted"),
    ("M6", m6, "C6", "valid cache raised"),
    ("M7", m7, "C7", "md5 dist.integrity was accepted"),
    ("M8", m8, "C8", "path constructed before rejecting"),
    ("M9", m9, "C9", "colon label returned"),
    ("M10", m10, "C10", "backup pruning kept/deleted wrong names"),
    ("M11", m11, "C11", "budget '-1'"),
    ("M12", m12, "C11", "interface gate is not bounded"),
    ("M13", m13, "C12", "limit.input fallback declared"),
    ("M14", m14, "C12", "limit.context fallback declared"),
    ("M15", m15, "C11", "budget '99999999999999999999': rc=0"),
    ("M16", m16, "C13", "shell missing identity: rc=0"),
    ("M17", m17, "C13", "shell valid identity: calls"),
    ("M18", m18, "C13", "python missing identity: returned rc=0"),
    ("M19", m19, "C13", "python launch nonzero: returned rc=0"),
    ("M20", m20, "C14", "anchor teeth never ran at startup"),
    ("M21", m21, "C15", "must not paint the check red"),
    ("M22", m22, "C16", "both provider shapes must yield"),
    ("M23", m23, "C17", "same-second backups lost their own run's bytes"),
    ("M24", m24, "C18", "refusal left traces"),
    ("M25", m25, "C19", "paths disagree"),
    ("M26", m26, "C20", "ccd-write did not write CCD config"),
    ("M27", m27, "C21", "fresh lock rc=0"),
    ("M28", m28, "C22", "empty network catalogue poisoned cache"),
    ("M29", m29, "C23", "prune-forms HOME"),
    ("M30", m30, "C24", "sweep touched live or foreign temps"),
    ("M31", m31, "C25", "side-file-warning rc=0"),
    ("M32", m32, "C26", "headroom-unreadable rc=0"),
    ("M33", m33, "C21", "stale-takeover released the foreign lock"),
    ("M34", m34, "C29", "heartbeat let the lock age"),
    ("M35", m35, "C27", "takeover-refusal rc="),
    ("M38", m38, "C28", "single-publisher acquired"),
    ("M40", m40, "C18", "initial missing: refusal left traces"),
    ("M41", m41, "C18", "initial not JSON: refusal left traces"),
    ("M43", m43, "C18", "initial not object: refusal left traces"),
    ("M44", m44, "C18", "proxy listing unreachable: refusal left traces"),
    ("M45", m45, "C18", "catalogue unavailable: refusal left traces"),
    ("M46", m46, "C18", "re-read missing: refusal left traces"),
    ("M47", m47, "C18", "re-read not JSON: refusal left traces"),
    ("M48", m48, "C18", "re-read not object: refusal left traces"),
    ("M49", m49, "C18", "empty replacement costs: refusal left traces"),
    ("M50", m50, "C18", "empty replacement windows: refusal left traces"),
    ("M51", m51, "C18", "nn exhausted: refusal left traces"),
    ("M52", m52, "C18", "settings unreadable: refusal left traces"),
    ("M53", m53, "C18", "empty CCD: refusal left traces"),
    ("M54", m54, "C18", "empty HOME: refusal left traces"),
    ("M55", m55, "C18", "lock not directory: refusal left traces"),
    ("M56", m56, "C18", "drift proxy unreachable: refusal left traces"),
    ("M57", m57, "C18", "drift catalogue unreachable: refusal left traces"),
    ("M59", m59, "C18", "drift red: refusal left traces"),
    ("M60", m60, "C18", "drift clean: refusal left traces"),
    ("M61", m61, "C18", "lock held: refusal left traces"),
    ("M62", m62, "C31", "mode-read-only left traces"),
    ("M63", m63, "C31", "mode-read-only left traces"),
    ("M64", m64, "C32", "env-builder let an inherited CCD"),
    ("M65", m65, "C33", "rival-sweep unlink intolerance"),
    ("M66", m66, "C34", "temp must stay"),
    ("M67", m67, "C34", "own-tag dead temp not swept"),
    ("M68", m68, "C34", "temp must stay"),
    ("M69", m69, "C19", "paths disagree"),
    ("M70", m70, "C36", "judge-cli empty-ccd rc="),
    ("M71", m71, "C22", "empty cached catalogue accepted"),
    ("M72", m72, "C24", "sweep did not remove dead-pid temps"),
    ("M73", m73, "C21", "stale lock not reclaimed"),
    ("M74", m74, "C34", "temp must stay"),
    ("M75", m75, "C34", "non-file temp not named"),
    ("M76", m76, "C34", "Permission denied"),
    ("M77", m77, "C35", "lock-not-directory refusal not named"),
    ("M78", m78, "C19", "resolvers disagree on refusal"),
    ("M79", m79, "C41", "inode-reuse"),
    ("M80", m80, "C37", "takeover before backup link linked anyway"),
    ("M81", m81, "C37", "takeover between staging and rename published anyway"),
    ("M82", m82, "C37", "takeover at the retry suffix published anyway"),
    ("M83", m83, "C19", "paths disagree"),
    ("M84", m84, "C18", "initial unreadable: uncaught"),
    ("M85", m85, "C51", "post-publish takeover removed the empty rival lock"),
    ("M86", m86, "C29", "interleave false loss"),
    ("M87", m87, "C25", "seen-takeover rc=4"),
    ("M88", m88, "C33", "lstat intolerance"),
    ("M89", m89, "C35", "lock-not-directory refusal not named"),
    ("M90", m90, "C38", "adopt-removal refresh traceback"),
    ("M91", m91, "C39", "takeover-window touched the rival lock"),
    ("M92", m92, "C40", "lock-unusable open traceback"),
    ("M93", m93, "C38", "adopt-removal refresh wrong loss reason"),
    ("M94", m94, "C42", "release-removal"),
    ("M95", m95, "C43", "start-failure"),
    ("M96", m96, "C44", "umask-start"),
    ("M97", m97, "C45", "sweep-listdir"),
    ("M98", m98, "C46", "write-failure"),
    ("M99", m99, "C46", "publish-failure"),
    ("M100", m100, "C46", "unlink-part"),
    ("M101", m101, "C47", "chmod-failure"),
    ("M102", m102, "C48", "release-stream"),
    ("M103", m103, "C49", "prune-empty-home"),
    ("M104", m104, "C50b", "empty-rival"),
    ("M105", m105, "C55", "foreign-entries"),
    ("M106", m106, "C52", "expiry-empty-rival"),
    ("M107", m107, "C57", "parallel-sync seen"),
    ("M108", m108, "C48", "release-stream"),
    ("M109", m109, "C54", "clean-cycle"),
    ("M110", m110, "C56", "old-format empty stale not reclaimed"),
    ("M111", m111, "C50", "rival-publish"),
    ("M112", m112, "C53", "no-replace"),
    ("M113", m113, "C58", "retry-heartbeat let the lock age to"),
    ("M114", m114, "C59", "reap-vanished-path rc="),
    ("M115", m115, "C60", "stale-staging-sweep left the expired staging"),
    ("M116", m116, "C61", "interrupt-after-publish left the lock directory behind"),
    ("M117", m117, "C62", "own-staging-spelling swept the writer's own staging"),
]

# Circle 25, E-4: a scenario with no mutation of its own proves nothing --
# break it, and the bench stays green. corpus-tools-bench enforces this rule
# by a table check; here and in the neighbouring benches the check did not
# exist at all -- only lengths were compared, and the hole stayed latent
# while coverage was accidentally full. The check runs BEFORE any scenario in
# BOTH modes. Exceptions are named HERE with a written reason (as
# UNMUTATED_OK in corpus-tools-bench); today there are none.
UNMUTATED_OK: tuple[str, ...] = ()


def check_tables() -> int:
    covered = {scenario for _, _, scenario, _ in MUTATIONS}
    missing = [name for name, _ in SCENARIOS
               if name not in covered and name not in UNMUTATED_OK]
    if (missing or len(MUTATIONS) != EXPECTED_MUTATIONS
            or len(SCENARIOS) != EXPECTED_SCENARIOS):
        print(f"costs-bench: ОТКАЗ -- мутаций {len(MUTATIONS)}/{EXPECTED_MUTATIONS},"
              f" сценариев {len(SCENARIOS)}/{EXPECTED_SCENARIOS},"
              f" без своей мутации: {missing or 'нет'}")
        return 4
    return 0


# CONSTRAINT: the pristine copy is a SUBSET of the tree (the repository root
# also holds image corpora and build output, which no scenario reads), so the
# whole-directory remedy used by judge-tools-bench does not apply here. What
# must not exist is a SECOND spelling of these paths: the copy list is derived
# from the same constants the scenarios read, and the roster of VICTIMS --
# which lives in the mutation bodies, spelled against the copy root -- is read
# back from the bench source by check_copy_list. A hand-kept list would drift
# the moment a mutation aimed at a file nobody copied: the copy would be
# missing it, and the mutation would count as a bench failure instead of a
# product verdict. Entries with no mutation are dependencies of the product
# under test, so the census is one-way by design.
COPIED: tuple[str, ...] = tuple(
    str(path.relative_to(ROOT)) for path in
    (COSTS, PATCHER, CORPUS, PIPELINE, BENCH, ROUTING, ANCHOR, VALIDATE))
# CONSTRAINT: C36 запускает судью ПУБЛИЧНЫМ входом CLI; validate.py импортирует
# соседей по judge/ при загрузке, так что копируется весь каталог.
COPIED_DIRS: tuple[str, ...] = ("judge",)

_COPY_SITE = re.compile(r'root\s*/\s*"([^"]+)"(?:\s*/\s*"([^"]+)")?')


def check_copy_list() -> int:
    bad: list[str] = []
    for rel in COPIED:
        if not (ROOT / rel).exists():
            bad.append(f"объявлен к копированию «{rel}», а в дереве его нет "
                       f"-- устаревшее объявление")
    dirs = {str(Path(rel).parent) for rel in COPIED} | set(COPIED_DIRS)
    for head, tail in _COPY_SITE.findall(BENCH.read_text(encoding="utf-8")):
        rel = f"{head}/{tail}" if tail else head
        if rel not in COPIED and rel not in dirs:
            bad.append(f"сценарии обращаются к «{rel}» внутри копии, "
                       f"а перечень копирования его не несёт")
    if bad:
        for line in sorted(set(bad)):
            print(f"costs-bench: ОТКАЗ -- {line}")
        return 4
    return 0


def copy_tree(root: Path) -> None:
    for rel in COPIED:
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, target)
    for rel in COPIED_DIRS:
        shutil.copytree(ROOT / rel, root / rel, dirs_exist_ok=True)


def run_copy(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(root / "tools" / "costs-bench.py")],
                          cwd=root, capture_output=True, text=True, errors="replace")


def fail_segment(output: str, scenario: str) -> str | None:
    head = f"costs-bench: СЦЕНАРИЙ {scenario}: FAIL:"
    start = output.find(head)
    if start < 0:
        return None
    rest = output[start + len(head):]
    end = rest.find("costs-bench: ")
    return rest if end < 0 else rest[:end]


def tree_snapshot(root: Path) -> dict:
    # CONSTRAINT: только исходники -- replace_once валидирует жертву
    # компиляцией, и её байткод-кэш не должен ни создавать «изменение»,
    # ни маскировать инертную мутацию.
    return {str(p.relative_to(root)): p.read_bytes()
            for p in sorted(root.rglob("*"))
            if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc"}


def needle_census() -> int:
    # G9 (R3): статический ценз игл БЕЗ запуска мутаций -- каждая игла
    # обязана совпадать ровно один раз (replace_once сам отказывает на 0/>1,
    # отказ ловится здесь), и ни одна мутация не может быть инертной
    # (дерево-байты до/после обязаны различаться). Мёртвая игла = отказ
    # прибора, не зелёный прогон.
    bad = 0
    for name, mutate, scenario, cause in MUTATIONS:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            copy_tree(root)
            before = tree_snapshot(root)
            try:
                mutate(root)
            except Exception as error:
                print(f"costs-bench: ЦЕНЗ {name}: ОТКАЗ -- {error}")
                bad += 1
                continue
            after = tree_snapshot(root)
            changed = sorted(rel for rel in after
                             if before.get(rel) != after[rel])
            if not changed:
                print(f"costs-bench: ЦЕНЗ {name}: ИНЕРТНА -- дерево не изменилось")
                bad += 1
            else:
                print(f"costs-bench: ЦЕНЗ {name}: OK ({', '.join(changed)})")
    print(f"costs-bench: ЦЕНЗ игл={len(MUTATIONS)} отказов={bad}")
    return 0 if bad == 0 else 4


def run_self_check() -> int:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        copy_tree(root)
        control = run_copy(root)
        if control.returncode != 0:
            print("costs-bench: КОНТРОЛЬ ПРОВАЛЕН -- пристинная копия уже красная "
                  f"(rc={control.returncode}); мутации ничего не докажут\n"
                  f"{control.stdout}{control.stderr}")
            return 2
    print("costs-bench: КОНТРОЛЬ без мутации: ЗЕЛЁНО")

    reddened = 0
    for name, mutate, scenario, cause in MUTATIONS:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            copy_tree(root)
            try:
                mutate(root)
            except UnparsableVictim as error:
                # Circle 25, E-3: a replacement that broke the victim's parse
                # is a broken INSTRUMENT, not a verdict about the product.
                # The run stops BEFORE the reddening count: while the
                # instrument is being fixed, no number of this run is to be
                # trusted.
                print(f"costs-bench: МУТАЦИЯ {name}: СЛОМАЛА РАЗБОР ЖЕРТВЫ -- {error}")
                return 2
            except Exception as error:
                print(f"costs-bench: МУТАЦИЯ {name}: FAIL: {error}")
                continue
            result = run_copy(root)
            output = result.stdout + result.stderr
            segment = fail_segment(output, scenario)
            if result.returncode != 1:
                print(f"costs-bench: МУТАЦИЯ {name}: FAIL: ожидался rc=1, "
                      f"получен rc={result.returncode}\n{output}")
            elif segment is None:
                print(f"costs-bench: МУТАЦИЯ {name}: КРАСНАЯ НЕ ТОЙ ДВЕРЬЮ: "
                      f"сценарий {scenario} не упал\n{output}")
            elif cause not in segment:
                print(f"costs-bench: МУТАЦИЯ {name}: КРАСНАЯ НЕ ПО ТОЙ ПРИЧИНЕ "
                      f"(нет «{cause}»):\n{segment}")
            else:
                reddened += 1
                print(f"costs-bench: МУТАЦИЯ {name}: RED (сценарий {scenario})")
    print(f"costs-bench: SELF-CHECK мутаций={len(MUTATIONS)} покраснели={reddened}")
    if len(SCENARIOS) != EXPECTED_SCENARIOS or len(MUTATIONS) != EXPECTED_MUTATIONS:
        print(f"costs-bench: ОТКАЗ -- сценариев {len(SCENARIOS)}/{EXPECTED_SCENARIOS}, "
              f"мутаций {len(MUTATIONS)}/{EXPECTED_MUTATIONS}")
        return 4
    return 0 if reddened == len(MUTATIONS) else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--needle-census", action="store_true")
    args = parser.parse_args()
    # Table check BEFORE any run and in both modes (as check_mut_tables in
    # corpus-tools-bench): a silent table drift re-aims the mutations at
    # other people's rules, and an uncovered scenario cannot be proven at all.
    if check_tables():
        return 4
    # Same placement as the table check, and for the same reason: a copy list
    # that lost a victim makes every mutation aimed at it a bench artefact.
    if check_copy_list():
        return 4
    if args.needle_census:
        return needle_census()
    return run_self_check() if args.self_check else run_scenarios()


if __name__ == "__main__":
    sys.exit(main())
