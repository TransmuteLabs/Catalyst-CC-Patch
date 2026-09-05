#!/usr/bin/env python3
"""Hermetic checks for model-cost synchronization and its installer guards.

Exit codes (subset of the kit-wide table in claude-patch-all.sh):
  0  every scenario passed; in --self-check every mutation reddened its owner
  1  a scenario failed, or a mutation did not redden its owning scenario
  2  the bench cannot measure: invocation is invalid, the pristine copy is red,
     or a replacement BROKE THE VICTIM'S PARSE (circle 25, E-3) -- a scenario
     reddened by a parse error proves nothing, and the run stops BEFORE the
     reddening count
  4  the declared scenario or mutation count differs from the tables below,
     or some scenario has NO mutation of its own (circle 25, E-4: an uncovered
     scenario is a door without teeth)
"""

from __future__ import annotations

import argparse
import base64
import contextlib
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
import time
from pathlib import Path
from types import ModuleType
from typing import Callable
from unittest.mock import patch

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
BENCH = Path(__file__).resolve()
COSTS = ROOT / "set-model-costs.py"
PATCHER = ROOT / "claude_patch.py"
CORPUS = ROOT / "tools" / "corpus-list.py"
PIPELINE = ROOT / "claude-patch-all.sh"
EXPECTED_SCENARIOS = 13
EXPECTED_MUTATIONS = 20


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


def run_costs_main(config: dict[str, object], *, catalogue: dict[str, object]) -> tuple[int, bytes, bytes, str, list[Path]]:
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        path = home / ".claude.json"
        path.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")
        before = path.read_bytes()
        old_home = os.environ.get("HOME")
        old_argv = sys.argv[:]
        os.environ["HOME"] = str(home)
        try:
            module = import_file(COSTS, "costs")
            module.proxy_model_ids = lambda: []
            module.load_proxy_catalogue = lambda: {}
            module.load_seen = lambda: set()
            module.save_seen = lambda ids: None

            def fake_fetch(persist: bool = True) -> dict[str, object]:
                return catalogue

            fake_fetch.last_source = "network"  # type: ignore[attr-defined]
            module.fetch_catalogue = fake_fetch
            sys.argv = [str(COSTS)]
            output = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                rc = module.main()
            after = path.read_bytes()
            backups = sorted(home.glob(".claude.json.backup.*"))
            backup_bytes = [p.read_bytes() for p in backups]
            return rc, before, after, output.getvalue(), [Path(str(len(b))) for b in backup_bytes]
        finally:
            sys.argv = old_argv
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home


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
        old_home, old_argv = os.environ.get("HOME"), sys.argv[:]
        os.environ["HOME"] = str(home)
        try:
            guarded = import_file(COSTS, "guard")
            guarded.proxy_model_ids = lambda: ["small"]
            guarded.load_proxy_catalogue = lambda: {"small": {"context": 32000}}
            guarded.load_seen = lambda: set()
            guarded.save_seen = lambda ids: None
            guarded.candidates = lambda catalogue, model_id: []
            guarded.context_window = lambda *args: -44000
            guarded.reply_headroom = lambda: 76000

            def fake_fetch(persist: bool = True) -> dict[str, object]:
                return {}

            fake_fetch.last_source = "network"  # type: ignore[attr-defined]
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
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home


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
                require(loaded == payload, f"cache payload changed: {loaded!r}")
                require(getattr(module.fetch_catalogue, "last_source", None) == "cache",
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
        path.write_text(f"# platform: {patcher.npm_platform_pkg()}\n"
                        "foo:bar 2.1.1 -\n", encoding="utf-8")
        result = subprocess.run([sys.executable, str(CORPUS), str(path)], cwd=ROOT,
                                capture_output=True, text=True, errors="replace")
        require(result.returncode == 1,
                f"colon label returned rc={result.returncode}\n{result.stdout}{result.stderr}")
        require("строка 2" in result.stderr and ":" in result.stderr,
                f"colon refusal did not name line and delimiter\n{result.stderr}")


def shell_function(source: str, name: str) -> str:
    match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}\n", source)
    require(match is not None, f"shell function {name} not found")
    return match.group(0)


def scenario_c10() -> None:
    source = PIPELINE.read_text(encoding="utf-8")
    function = shell_function(source, "prune_config_backups")
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
        result = subprocess.run(["bash"], input=script, env={**os.environ, "HOME": str(home)},
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
                 + shell_function(source, "sign_macos_binary"))
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
        script = (f"set -euo pipefail\n{functions}\n"
                  "uname() { printf 'Darwin\\n'; }\n" + stage.group(1)
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


SCENARIOS: list[tuple[str, Callable[[], None]]] = [
    ("C1", scenario_c1), ("C2", scenario_c2), ("C3", scenario_c3),
    ("C4", scenario_c4), ("C5", scenario_c5), ("C6", scenario_c6),
    ("C7", scenario_c7), ("C8", scenario_c8), ("C9", scenario_c9),
    ("C10", scenario_c10), ("C11", scenario_c11), ("C12", scenario_c12),
    ("C13", scenario_c13),
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

    Same rule as the pipeline's PYCOMPILE gate (claude-patch-all.sh): the part
    of the line before the first '#' contains python3 on a word boundary, no
    '|' ';' '&' between python3 and the opening, and the line ENDS with the
    <<'TAG' opening; the body runs to the line equal to TAG verbatim. The
    end-of-line requirement keeps comment mentions out -- otherwise an example
    line would swallow the rest of the file as a "body" and the guard would
    redden a healthy victim.
    """
    bodies: list[str] = []
    opener = re.compile(r"^[^#]*\bpython3\b[^|;&]*<<'([A-Za-z_][A-Za-z0-9_]*)'\s*$")
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        match = opener.match(lines[i])
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
    replace_once(root / "claude-patch-all.sh", "[[ \"$base\" =~ ^\\.claude\\.json\\.backup\\.[0-9]{8}-[0-9]{6}$ ]] || continue",
                 ": # M10 accepts foreign backup names", "M10")


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


def copy_tree(root: Path) -> None:
    (root / "tools").mkdir(parents=True)
    shutil.copy2(COSTS, root / "set-model-costs.py")
    shutil.copy2(PATCHER, root / "claude_patch.py")
    shutil.copy2(CORPUS, root / "tools" / "corpus-list.py")
    shutil.copy2(PIPELINE, root / "claude-patch-all.sh")
    shutil.copy2(BENCH, root / "tools" / "costs-bench.py")
    shutil.copy2(ROOT / "patch_claude_routing.py", root / "patch_claude_routing.py")


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
    args = parser.parse_args()
    # Table check BEFORE any run and in both modes (as check_mut_tables in
    # corpus-tools-bench): a silent table drift re-aims the mutations at
    # other people's rules, and an uncovered scenario cannot be proven at all.
    if check_tables():
        return 4
    return run_self_check() if args.self_check else run_scenarios()


if __name__ == "__main__":
    sys.exit(main())
