#!/usr/bin/env python3
# The docstring is raw: it shows a Windows path (`.\patch-claude-routing.ps1`),
# and `\p` is not a valid escape — Python 3.14 warns about it.
r"""
Cross-platform, version-independent installer for the Claude Code multi-provider
patch (macOS / Linux / Windows, x64 + arm64, glibc + musl).

What the patch does (see patch_claude_routing.py for the byte-level details):
  * claude-* models  -> https://api.anthropic.com   (subscription / OAuth)
  * every other model -> process.env.ANTHROPIC_BASE_URL (your proxy)
  * /model discovery works against the proxy without ANTHROPIC_AUTH_TOKEN
  * the Agent tool's `model` param accepts external/proxy IDs (subagents too)

Usage:
  python3 claude_patch.py                    # patch the active installation
  python3 claude_patch.py /path/to/binary    # patch a specific binary
  python3 claude_patch.py --update           # download latest from npm, install,
                                             #   repoint launcher, patch
  python3 claude_patch.py --update 2.1.220   # ... a specific version

Convenience wrappers (same arguments):
  macOS / Linux : bash patch-claude-routing.sh --update
  Windows       : .\patch-claude-routing.ps1 --update   (finds a working Python;
                  a bare `python3` there is often the inert Store stub)

Platform notes:
  * The patched JS bundle is IDENTICAL across platforms; only the container
    differs (Mach-O / ELF / PE). patch_claude_routing.py locates every site by
    structural regex, so all 8 official builds patch byte-neutrally.
  * macOS: the binary MUST be re-signed with a stable identity and the original
    bundle id, or the login-keychain OAuth item denies access ("Not logged in").
  * Linux: no signing exists; nothing to do.
  * Windows: the Authenticode signature is invalidated by any byte edit. Normal
    Windows still runs the binary; under WDAC/AppLocker enforcement you must
    re-sign yourself (set CLAUDE_PATCH_SIGNTOOL_SHA1, optionally
    CLAUDE_PATCH_SIGNTOOL, to have this script call signtool for you).

Exit codes (a subset of the kit-wide table, see the claude-patch-all.sh header;
круг 28, F-11):
  0  installed/verified
  1  a refusal on the merits: unsupported platform or architecture, integrity
     mismatch, the target is in use, a post-check failed
  2  the call contract is broken, or the instrument itself is incomplete:
     no Claude Code binary found where the invocation promises one (pass its
     path explicitly or run --update), a malformed --update version, or the
     kit's own patch_claude_routing.py missing next to this script.
     Retrying as-is cannot help -- fix the call or the deployment.
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

NPM_MAIN = "@anthropic-ai/claude-code"
BUNDLE_ID = "com.anthropic.claude-code"
ROUTING_MARKER = b"baseURL:/^claude/i.test("      # constant across versions
# tweakcc leaves its own name in the image it patches (11 occurrences on 2.1.247 --
# `grep -c` says 8 because it counts LINES, not matches; the presence test is what
# matters, but a number in a comment has to be the number the tool returned,
# 0 in stock). Used only to refuse making a "pristine" backup out of a binary
# that plainly is not one -- never to decide whether OUR patches are present.
TWEAKCC_MARKER = b"tweakcc"
ENUM_MARKER = b".string()" + b" " * 10            # padding run is unique to our edit

HERE = Path(__file__).resolve().parent
PATCHER = HERE / "patch_claude_routing.py"


def die(msg: str, code: int = 1) -> "NoReturn":  # type: ignore[name-defined]
    # Круг 28, F-11: код стал параметром с умолчанием 1. Прежде die() всегда
    # отдавал единицу -- в том числе на нарушении контракта вызова (нет файла),
    # где класс по общей таблице кита -- 2 «прибор не может мерить»: чинить
    # надо ВЫЗОВ, а не продукт. Прочие отказа (архитектура, платформа,
    # целостность) остаются классом 1.
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def info(msg: str) -> None:
    print(msg, flush=True)


# --------------------------------------------------------------------------- #
# platform / path resolution (mirrors the binary's own logic)
# --------------------------------------------------------------------------- #

def is_windows() -> bool:
    return sys.platform.startswith("win")


def is_musl() -> bool:
    """Alpine & co ship musl; the npm package name gets a -musl suffix."""
    if not sys.platform.startswith("linux"):
        return False
    if any(Path("/lib").glob("ld-musl-*.so.1")):
        return True
    try:
        out = subprocess.run(["ldd", "--version"], capture_output=True, text=True)
        return "musl" in (out.stdout + out.stderr).lower()
    except Exception:
        return False


def npm_platform_pkg() -> str:
    """Same mapping the binary uses to pick its own platform package."""
    machine = platform.machine().lower()
    if machine in ("arm64", "aarch64"):
        arch = "arm64"
    elif machine in ("x86_64", "amd64"):
        arch = "x64"
    else:
        die(f"unsupported architecture: {machine}")

    if sys.platform == "darwin":
        plat = "darwin"
    elif sys.platform.startswith("linux"):
        plat = "linux"
    elif is_windows():
        plat = "win32"
    else:
        die(f"unsupported platform: {sys.platform}")

    suffix = "-musl" if (plat == "linux" and is_musl()) else ""
    return f"{NPM_MAIN}-{plat}-{arch}{suffix}"


def binary_name() -> str:
    return "claude.exe" if is_windows() else "claude"


VERSION = re.compile(r"^[0-9][0-9.]*$")


def validate_version(version: str) -> str:
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        die(f"invalid version {version!r}: expected digits and dots, starting with a digit",
            code=2)
    return version


def versions_dir() -> Path:
    """$XDG_DATA_HOME || ~/.local/share, then /claude/versions (all platforms)."""
    xdg = os.environ.get("XDG_DATA_HOME")
    base = Path(xdg) if xdg else Path.home() / ".local" / "share"
    return base / "claude" / "versions"


def launcher_path() -> Path:
    """~/.local/bin/claude — a symlink on posix, a plain copy on Windows."""
    return Path.home() / ".local" / "bin" / binary_name()


# --------------------------------------------------------------------------- #
# npm download
# --------------------------------------------------------------------------- #

def http_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def latest_version() -> str:
    tags = http_json(f"https://registry.npmjs.org/-/package/{NPM_MAIN}/dist-tags")
    return validate_version(tags["latest"])


INTEGRITY_ALGORITHMS = {"sha512", "sha256"}


def _verify_tarball(blob: bytes, dist: dict, what: str) -> None:
    """Check the downloaded archive against the digest the registry published.

    Without this the only integrity the download had was structural: gzip and
    tar had to decode and the member had to exist. A truncated-but-valid
    archive, or a body swapped anywhere between the registry and here, passed
    that test -- and the bytes went on to become an installed binary and, for
    the sweep, the pinned reference the whole measurement base rests on.

    npm publishes `dist.integrity` (`<alg>-<base64>`, sha512 for anything
    recent) and the legacy `dist.shasum` (sha1). Whichever is present is
    checked; a package that carries NEITHER is refused rather than trusted,
    because "no digest" and "digest matches" must not read the same.
    """
    integrity = dist.get("integrity")
    if integrity:
        alg, _, b64 = integrity.partition("-")
        if alg not in INTEGRITY_ALGORITHMS:
            die(f"{what}: dist.integrity algorithm {alg!r} is not allowed")
        if not b64:
            die(f"{what}: unreadable dist.integrity ({integrity!r})")
        try:
            want = base64.b64decode(b64, validate=True)
        except Exception as exc:                       # noqa: BLE001
            die(f"{what}: unreadable dist.integrity ({integrity!r}): {exc}")
        try:
            got = hashlib.new(alg, blob).digest()
        except ValueError:
            die(f"{what}: dist.integrity names an unknown algorithm {alg!r}")
        if got != want:
            die(f"{what}: archive does not match dist.integrity "
                f"({alg}: got {base64.b64encode(got).decode()}, want {b64})")
        return
    shasum = dist.get("shasum")
    if shasum:
        got = hashlib.sha1(blob).hexdigest()
        if got != shasum:
            die(f"{what}: archive does not match dist.shasum "
                f"(got {got}, want {shasum})")
        return
    die(f"{what}: the registry published no integrity or shasum for this "
        f"archive -- refusing to trust it")


def download_binary(version: str, dest: Path) -> None:
    """Fetch the per-platform package (the main npm pkg is only a downloader)."""
    pkg = npm_platform_pkg()
    info(f"Fetching {pkg}@{version} ...")
    meta = http_json(f"https://registry.npmjs.org/{pkg}/{version}")
    tarball = meta["dist"]["tarball"]
    with urllib.request.urlopen(tarball, timeout=600) as r:
        blob = r.read()
    _verify_tarball(blob, meta.get("dist", {}), f"{pkg}@{version}")
    member_name = f"package/{binary_name()}"
    tmp = dest.with_name(f"{dest.name}.{os.getpid()}.download")
    try:
        _download_into(blob, member_name, pkg, version, tmp, dest)
    except BaseException:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise


def _download_into(blob: bytes, member_name: str, pkg: str, version: str,
                   tmp: Path, dest: Path) -> None:
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
        try:
            src = tf.extractfile(member_name)
        except KeyError:
            src = None
        if src is None:
            die(f"{member_name} not found in {pkg}@{version}")
        dest.parent.mkdir(parents=True, exist_ok=True)
        # Распаковка НИКОГДА не идёт через конечное имя. Оборванная (kill,
        # кончилось место, обрыв сети посреди copyfileobj) оставляла усечённый
        # файл под именем версии, а следующий прогон читает существование как
        # «уже установлено»: `--update` уходит в ветку target.exists() и строит
        # рядом, оставляя огрызок на месте установки (круг 21, E-3). Два из трёх
        # вызывающих уже качали в staging -- дыра была у ПЕРВОЙ установки, где
        # конечное имя и есть цель. Лечится здесь, а не у вызывающих: свойство
        # принадлежит загрузке.
        #
        # Имя несёт pid: две одновременные загрузки одной версии (свип + ручной
        # прогон) не должны писать в один временный файл.
        with open(tmp, "wb") as out:
            shutil.copyfileobj(src, out)
            out.flush()
            os.fsync(out.fileno())
    os.chmod(tmp, 0o755)
    os.replace(tmp, dest)


# --------------------------------------------------------------------------- #
# install-site discovery
# --------------------------------------------------------------------------- #

def resolve_active_binary() -> Path:
    """Find the binary the `claude` command actually runs."""
    which = shutil.which("claude")
    if which:
        real = Path(os.path.realpath(which))
        # On Windows the launcher is a COPY, and `which` may find a .cmd shim;
        # only trust it when it looks like the native executable.
        if real.is_file() and real.stat().st_size > 50_000_000:
            return real
    vdir = versions_dir()
    if vdir.is_dir():
        # Кандидат задаётся ПОЛОЖИТЕЛЬНОЙ формой имени версии. Отрицательный
        # список нельзя дописать до полноты: прежняя правка добавила .download,
        # следующая должна была бы знать про .claude-patched-, а следующий
        # писатель придумал бы ещё одно промежуточное имя. Обломок оборванного
        # прогона целью не бывает, даже если он самый свежий по mtime.
        version_name = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:\.exe)?$" if is_windows()
                                  else r"^[0-9]+\.[0-9]+\.[0-9]+$")
        cands = [p for p in vdir.iterdir()
                 if p.is_file() and version_name.fullmatch(p.name)]
        if cands:
            # newest by mtime — matches what the launcher points at after an update
            return max(cands, key=lambda p: p.stat().st_mtime)
    die("could not locate a Claude Code binary: the versions directory has no file "
        "whose name is a version; interrupted-run leftovers are never patch targets. "
        "Pass the binary path explicitly or run with --update", code=2)


def _sweep_stale_launcher_tmps(link: Path) -> None:
    """Remove OTHER processes' orphaned launcher tmp symlinks from link's
    directory before creating our own.

    A repoint killed between symlink_to and os.replace leaves a
    <name>.tmp.<pid> symlink sitting in a directory that is on PATH — it
    outlives its own pid and every later repoint. Exactly one thing licenses
    removal: the entry is attributable to a pid that is DEAD, so its swap
    will never happen. A live pid is never touched (PermissionError from
    os.kill(pid, 0) means the process is alive under another user), and a
    non-numeric suffix is left alone — the origin of such a name is unknown,
    and unlinking by pattern alone would sweep a file we cannot attribute.

    A dangling target is deliberately NOT a licence of its own. It says
    nothing about ownership: an entry whose pid is dead is already covered by
    the check above, while a LIVE process is dangling for the instant between
    its target being replaced and its own os.replace — sweeping it there
    makes that replace raise FileNotFoundError, and it would raise AFTER the
    image has been swapped, i.e. exactly where the pipeline can no longer
    unwind. The price of this restraint is one inert symlink in the rare case
    where a dead pid was reused by a live process."""
    # Глоб шире формы писателя: `.tmp.*` ловит `.tmp.12.34`, `.tmp.pid-7`,
    # `.tmp.²`. Имя сверяется с той же формой, что пишет repoint_launcher
    # (`f"{link.name}.tmp.{os.getpid()}"`), иначе прополка берёт на себя файлы
    # чужого происхождения. `str.isdigit()` для этого не годится: оно истинно
    # для '²', а int() его отвергает — прополка падала бы на имени файла,
    # причём ПОСЛЕ подмены образа, где конвейеру уже нечем размотать шаг.
    form = re.compile(re.escape(link.name) + r"\.tmp\.[0-9]+\Z")
    for stale in link.parent.glob(f"{link.name}.tmp.*"):
        if not form.match(stale.name):
            continue                   # происхождение имени неизвестно
        try:
            pid = int(stale.name.rsplit(".", 1)[-1])
        except ValueError:
            continue
        # Снимок до проверки: между «pid мёртв» и unlink номер может быть
        # переиспользован новым прогоном, который создаст СВОЙ tmp с тем же
        # именем. Сверка inode+mtime после проверки не даёт снять чужой новый.
        try:
            before = stale.lstat()
        except FileNotFoundError:
            continue
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass                       # pid мёртв — свап уже не случится
        except PermissionError:
            continue                   # жив, под другим пользователем
        except OverflowError:
            continue                   # число не может быть pid этой системы
        else:
            continue                   # жив
        try:
            after = stale.lstat()
        except FileNotFoundError:
            continue                   # соперничающий уборщик успел раньше
        if (after.st_ino, after.st_mtime_ns) != (before.st_ino, before.st_mtime_ns):
            continue                   # запись подменена после проверки
        try:
            stale.unlink()
        except FileNotFoundError:
            pass  # a competing sweeper won the race; the goal is met


def repoint_launcher(target: Path) -> None:
    """Symlink on posix; copy on Windows (which is what the installer does)."""
    link = launcher_path()
    link.parent.mkdir(parents=True, exist_ok=True)
    if is_windows():
        try:
            shutil.copyfile(target, link)
            info(f"Copied launcher {link} <- {target}")
        except PermissionError:
            info(f"WARNING: {link} is in use (close all Claude Code sessions, "
                 f"including VS Code) — versioned binary is patched, launcher not updated")
    else:
        # Atomic repoint. unlink-then-symlink leaves a window where the
        # launcher does NOT exist (starting `claude` at that instant is a
        # plain ENOENT), and a concurrent second repoint hits an uncaught
        # FileExistsError from symlink_to — under `set -e` the pipeline then
        # dies AFTER the image has already been swapped. A symlink created
        # under a temporary name in the same directory plus os.replace is
        # atomic: replace over a symlink (or a file) never exposes a missing
        # path and never fails with "already exists".
        _sweep_stale_launcher_tmps(link)
        tmp = link.with_name(f"{link.name}.tmp.{os.getpid()}")
        if tmp.is_symlink() or tmp.exists():
            tmp.unlink()
        tmp.symlink_to(target)
        os.replace(tmp, link)
        info(f"Repointed {link} -> {target}")


# --------------------------------------------------------------------------- #
# signing
# --------------------------------------------------------------------------- #

def sign_macos(path: Path) -> None:
    """Stable identity + pinned bundle id, or the keychain OAuth grant breaks."""
    sign_id = os.environ.get("CLAUDE_PATCH_SIGN_ID")
    if not sign_id:
        out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2 and len(parts[1]) == 40:
                sign_id = parts[1]
                break
    if sign_id:
        subprocess.run(["codesign", "-f", "-i", BUNDLE_ID, "-s", sign_id, str(path)],
                       check=True)
        info(f"Re-signed with identity {sign_id} (bundle id {BUNDLE_ID})")
    else:
        subprocess.run(["codesign", "-f", "-i", BUNDLE_ID, "-s", "-", str(path)],
                       check=True)
        info("WARNING: no code-signing identity found -> ad-hoc signed; "
             "keychain OAuth (subscription login) will NOT work")


def sign_windows(path: Path) -> None:
    """Optional: the byte edit invalidates Authenticode. Windows still runs the
    binary; re-sign only if a policy (WDAC/AppLocker) requires it."""
    sha1 = os.environ.get("CLAUDE_PATCH_SIGNTOOL_SHA1")
    if not sha1:
        info("NOTE: Authenticode signature is now invalid (expected). Windows runs "
             "the binary anyway; set CLAUDE_PATCH_SIGNTOOL_SHA1 to re-sign.")
        return
    tool = os.environ.get("CLAUDE_PATCH_SIGNTOOL", "signtool")
    subprocess.run([tool, "sign", "/sha1", sha1, "/fd", "sha256", str(path)], check=True)
    info(f"Re-signed with certificate {sha1}")


def sign(path: Path) -> None:
    if sys.platform == "darwin":
        sign_macos(path)
    elif is_windows():
        sign_windows(path)
    else:
        info("Linux: no code signature to restore.")


# --------------------------------------------------------------------------- #
# main flow
# --------------------------------------------------------------------------- #

def has_marker(path: Path, marker: bytes) -> bool:
    """Chunked scan — these binaries are ~250 MB; never slurp them whole."""
    overlap = len(marker) - 1
    tail = b""
    with open(path, "rb") as f:
        while chunk := f.read(8 << 20):
            if marker in tail + chunk:
                return True
            tail = chunk[-overlap:] if overlap else b""
    return False


def _replace_backup(src: Path, backup: Path) -> None:
    """Write `backup` from `src` atomically.

    Never a plain copy onto the destination: a copy killed halfway leaves a
    TRUNCATED backup, and truncated bytes carry no marker -- so `_is_pristine`
    calls it pristine, every later run keeps it, and a restore writes a broken
    binary while reporting success. Same staging-and-rename the rest of the kit
    uses for live files, for the same reason.
    """
    # The staging name belongs to this writer. Two direct invocations are a
    # supported surface; a fixed <backup>.new let one process rename the inode
    # while the other was still writing it, publishing bytes from both sources.
    tmp = backup.with_name(backup.name + f".new.{os.getpid()}")
    shutil.copy2(src, tmp)
    os.replace(tmp, backup)


def _is_pristine(path: Path) -> bool:
    """True when the file carries neither our patches nor tweakcc's stage.

    Used to decide whether an EXISTING `.orig` may keep its place. A backup that
    fails this is worse than no backup: it is the file a human is told to
    restore from, so restoring returns a patch while reporting a removal.
    """
    return not has_marker(path, ROUTING_MARKER) and not has_marker(path, TWEAKCC_MARKER)


def patch_binary(target: Path, backup: Path | None = None) -> None:
    """Patch `target` in place (staged internally), reading stock bytes from `backup`.

    `backup` is named explicitly by callers that build into a staging file: the
    default `<name>.orig` would then be `<version>.staging.orig`, a second
    backup under a name nothing else knows -- while the real one, the one the
    pipeline restores from and step 0b stages from, is `<version>.orig`.
    """
    if has_marker(target, ROUTING_MARKER):
        info("Already patched — nothing to do.")
        return

    backup = backup or target.with_name(target.name + ".orig")
    if not backup.exists():
        # `.orig` is what a human restores from, so it must not quietly become a
        # snapshot of somebody else's patch. The guard above only knows OUR
        # marker: a binary that has been through tweakcc's stage carries none of
        # it and used to be copied straight into `.orig`, after which "restore
        # the pristine binary" put tweakcc's patches back.
        #
        # A copy taken from a file on disk is a PRE-PATCH SNAPSHOT, not a
        # guaranteed-stock image -- only --download-only can promise that,
        # because it took the bytes from the registry. Say which one this is.
        if has_marker(target, TWEAKCC_MARKER):
            die(f"{target} has already been through tweakcc's stage, so a copy of it "
                f"would not be a pristine backup. Fetch stock bytes first: "
                f"python3 claude_patch.py --download-only <version>")
        _replace_backup(target, backup)
        info(f"Backed up original -> {backup}")
        info("  (a snapshot of the file on disk; --download-only is what guarantees stock bytes)")
    elif _is_pristine(backup):
        info(f"Backup already exists -> {backup} (keeping it)")
    else:
        # Keeping it would preserve exactly the file a human is told to restore
        # from, in exactly the state that makes restoring return a patch. This
        # tool cannot heal it -- it has no stock bytes -- so it says which one
        # can, instead of building on top of a backup it knows is wrong.
        die(f"{backup} is not a pristine copy (it carries our patches or tweakcc's). "
            f"Restoring from it would return a patch. Replace it with stock bytes: "
            f"python3 claude_patch.py --download-only <version>")

    # Stage the temp file in the TARGET's directory, not the system temp dir:
    # os.replace() cannot cross filesystems (Linux /tmp is often tmpfs, Windows
    # %TEMP% may sit on another drive), and same-dir staging makes the swap atomic.
    # ".exe" matters on Windows: we exec the staged file for the --version check
    # (and signtool expects it), and an extensionless PE is not reliably runnable.
    tmp_fd, tmp_name = tempfile.mkstemp(prefix=".claude-patched-", dir=target.parent,
                                        suffix=".exe" if is_windows() else "")
    os.close(tmp_fd)
    tmp = Path(tmp_name)
    try:
        subprocess.run([sys.executable, str(PATCHER), str(backup), str(tmp)], check=True)

        # byte-neutrality is a property of the PATCH; signing afterwards may
        # legitimately resize the signature blob.
        if tmp.stat().st_size != backup.stat().st_size:
            die("patch not byte-neutral (pre-sign)")

        if not has_marker(tmp, ROUTING_MARKER):
            die("post-check: routing marker missing")
        if not has_marker(tmp, ENUM_MARKER):
            die("post-check: enum marker missing")

        sign(tmp)
        os.chmod(tmp, 0o755)   # mkstemp creates 0600; needed before we exec it

        try:
            out = subprocess.run([str(tmp), "--version"], capture_output=True,
                                 text=True, timeout=120)
            info(f"Patched --version: {(out.stdout or out.stderr).strip().splitlines()[0]}")
        except Exception as e:
            info(f"NOTE: could not run --version on the patched binary ({e})")

        try:
            os.replace(tmp, target)
        except PermissionError:
            die(f"{target} is in use — close all Claude Code sessions "
                f"(including VS Code) and re-run")
        info(f"Installed patched binary over {target}")
        # Staged and renamed, never a copy onto the live file: a bun executable
        # reads its embedded assets back out of its own file, and the two images
        # differ in size, so an in-place rewrite moves every offset under a session
        # that is still running.
        info(f"Restore anytime with:  cp -p \"{backup}\" \"{target}.restore\" && "
             f"mv \"{target}.restore\" \"{target}\"")
    finally:
        if tmp.exists():
            tmp.unlink()


def main(argv: list[str]) -> None:
    if not PATCHER.is_file():
        # Класс 2, а не 1 (адъюдикация круга 25, запрос F-4): пропал
        # компонент САМОГО кита, а не что-то в цели. Код 1 отправляет
        # читателя разбираться с образом ("не сошёлся гейт"), тогда как
        # чинить надо неполную раскатку кита -- ровно то различие,
        # ради которого класс 2 и заведён. Не 6: 6 -- про окружение и
        # машинерию замка, а здесь недостаёт нашего же файла.
        die(f"patch_claude_routing.py not found next to this script ({PATCHER})",
            code=2)

    target: Path
    # Set only on the --update path: the name the staging build is renamed onto,
    # and the pristine backup that path already wrote (so patch_binary does not
    # snapshot a second one under the staging name).
    #
    # This name is ALSO the condition for the swap-and-repoint tail below. A
    # separate `repoint_after_patch` flag lived here and had to be kept in step
    # with it by hand: any future branch setting the flag without the name would
    # rename onto None. One name, one meaning -- the pair cannot drift apart.
    update_final: Path | None = None
    update_backup: Path | None = None
    if argv and argv[0] == "--download-only":
        # Install a PRISTINE build and stop: used by the combined tweakcc
        # pipeline, which applies the patches itself (and would conflict with
        # the byte-neutral ones this script normally applies).
        version = validate_version(argv[1]) if len(argv) > 1 else latest_version()
        target = versions_dir() / version
        backup = target.with_name(target.name + ".orig")
        # When the requested version is ALREADY installed, `target` is the file
        # the launcher resolves to -- and download_binary opens its destination
        # with "wb", truncating it in place. Writing pristine bytes there puts
        # the live installation on an unpatched image for the whole run (every
        # new session then sends claude-* to the proxy under the subscription
        # bearer and dies on "unknown provider"), and an interrupted run leaves
        # it that way for good. Deferring the launcher repoint cannot help: the
        # launcher already points AT the file being clobbered.
        #
        # This is not a rare mistake to make. `--update` without a version
        # resolves to npm's latest, which equals the installed version whenever
        # nothing new was published, and a version-matrix sweep passes explicit
        # versions that may include the live one.
        #
        # So when the target exists, download beside it and hand the caller the
        # staging file. The pipeline patches THAT and renames it over the target
        # once every gate has passed.
        if target.exists():
            staging = target.with_name(target.name + f".staging.{os.getpid()}")
            download_binary(version, staging)
            info(f"{version} is already installed; built pristine beside it -> {staging}")
            if not backup.exists() or not _is_pristine(backup):
                # The installed file may already carry our patches, so it cannot
                # serve as the pristine backup. The bytes just downloaded can.
                #
                # And an EXISTING backup is replaced when it is not pristine.
                # Keeping it was a closed loop: a `.orig` that had been
                # snapshotted from a patched or tweakcc-staged binary made the
                # pipeline refuse to build (it will not stage from a poisoned
                # copy) and send the human here -- where the one place holding
                # guaranteed-stock bytes declined to use them, so the next run
                # refused again with the same advice.
                _replace_backup(staging, backup)
                info(f"Backed up pristine -> {backup}")
            print(staging)
            return
        download_binary(version, target)
        info(f"Installed pristine {version} -> {target}")
        if not backup.exists() or not _is_pristine(backup):
            _replace_backup(target, backup)
            info(f"Backed up pristine -> {backup}")
        # The launcher is deliberately NOT repointed here. This mode installs a
        # PRISTINE image and hands it to the combined pipeline, which needs a
        # minute to unpack, patch, verify and sign it. Repointing first opens a
        # window in which every newly started session runs UNPATCHED: with
        # ANTHROPIC_BASE_URL set, its claude-* traffic goes to the local proxy
        # carrying the subscription OAuth bearer, and the session dies on
        # "unknown provider for model claude-opus-5". That window cost a live
        # session on 2026-08-18. The caller repoints with --repoint once its
        # checks pass.
        print(target)          # last line = path, for the caller to consume
        return

    if argv and argv[0] == "--repoint":
        if len(argv) < 2:
            die("--repoint needs the binary to point the launcher at")
        target = Path(argv[1]).expanduser().resolve()
        if not target.is_file():
            die(f"binary not found: {target}")
        if not has_marker(target, ROUTING_MARKER):
            die(f"refusing to repoint the launcher at an unpatched binary: {target}")
        repoint_launcher(target)
        return

    if argv and argv[0] == "--update":
        version = validate_version(argv[1]) if len(argv) > 1 else latest_version()
        target = versions_dir() / version
        if target.is_file() and has_marker(target, ROUTING_MARKER):
            info(f"{version} is already installed and patched -> {target}")
            repoint_launcher(target)
            return
        # Download BESIDE the target, never into it -- the same rule, and for
        # the same reason, as --download-only above.
        #
        # `download_binary` opens its destination with "wb". When the requested
        # version is the installed one and it is merely UNPATCHED (a restore, an
        # interrupted run, a fresh image the pipeline has not been over yet),
        # the old branch truncated the file the launcher resolves to and refilled
        # it over the network. Every session started in that window ran an
        # unpatched image, and a download that failed halfway left the live
        # installation truncated for good. patch_binary() has staged its own
        # write since the beginning; the DOWNLOAD was the one step that still
        # wrote through the live name.
        #
        # So: fetch into `<version>.staging`, take the pristine backup from
        # those bytes (registry bytes, integrity-checked -- a strictly better
        # source than a snapshot of whatever is on disk), patch the staging file,
        # and only then rename it over the target. A run that dies anywhere
        # before that rename leaves the installation exactly as it was.
        staging = target.with_name(target.name + f".staging.{os.getpid()}")
        download_binary(version, staging)
        backup = target.with_name(target.name + ".orig")
        if not backup.exists() or not _is_pristine(backup):
            _replace_backup(staging, backup)
            info(f"Backed up pristine -> {backup}")
        info(f"Built pristine {version} beside the target -> {staging}")
        update_final = target
        update_backup = backup
        target = staging
        # Swapped in and repointed only after patch_binary() below succeeds --
        # an unpatched binary on the launcher path sends subscription traffic to
        # the proxy.
    elif argv:
        target = Path(argv[0]).expanduser().resolve()
        if not target.is_file():
            die(f"binary not found: {target}")
    else:
        target = resolve_active_binary()

    info(f"Target binary: {target}")
    patch_binary(target, update_backup)
    if update_final is not None:
        # The swap is the last thing that happens: up to here the live file
        # still holds the previous build, so any failure above -- a locator that
        # missed, a post-check, a signature -- leaves a working installation
        # rather than a half-built one.
        os.replace(target, update_final)
        info(f"Swapped the patched build over the target: {update_final}")
        target = update_final
        repoint_launcher(target)


if __name__ == "__main__":
    main(sys.argv[1:])
