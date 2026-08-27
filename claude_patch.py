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
"""
from __future__ import annotations

import io
import json
import os
import platform
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


def die(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


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
    return tags["latest"]


def download_binary(version: str, dest: Path) -> None:
    """Fetch the per-platform package (the main npm pkg is only a downloader)."""
    pkg = npm_platform_pkg()
    info(f"Fetching {pkg}@{version} ...")
    meta = http_json(f"https://registry.npmjs.org/{pkg}/{version}")
    tarball = meta["dist"]["tarball"]
    with urllib.request.urlopen(tarball, timeout=600) as r:
        blob = r.read()
    member_name = f"package/{binary_name()}"
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
        try:
            src = tf.extractfile(member_name)
        except KeyError:
            src = None
        if src is None:
            die(f"{member_name} not found in {pkg}@{version}")
        dest.parent.mkdir(parents=True, exist_ok=True)
        with open(dest, "wb") as out:
            shutil.copyfileobj(src, out)
    os.chmod(dest, 0o755)


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
        cands = [p for p in vdir.iterdir()
                 if p.is_file() and not p.name.endswith(".orig")]
        if cands:
            # newest by mtime — matches what the launcher points at after an update
            return max(cands, key=lambda p: p.stat().st_mtime)
    die("could not locate a Claude Code binary; pass its path explicitly "
        "or run with --update")


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
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(target)
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
    tmp = backup.with_name(backup.name + ".new")
    shutil.copy2(src, tmp)
    os.replace(tmp, backup)


def _is_pristine(path: Path) -> bool:
    """True when the file carries neither our patches nor tweakcc's stage.

    Used to decide whether an EXISTING `.orig` may keep its place. A backup that
    fails this is worse than no backup: it is the file a human is told to
    restore from, so restoring returns a patch while reporting a removal.
    """
    return not has_marker(path, ROUTING_MARKER) and not has_marker(path, TWEAKCC_MARKER)


def patch_binary(target: Path) -> None:
    if has_marker(target, ROUTING_MARKER):
        info("Already patched — nothing to do.")
        return

    backup = target.with_name(target.name + ".orig")
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
        die(f"patch_claude_routing.py not found next to this script ({PATCHER})")

    target: Path
    repoint_after_patch = False
    if argv and argv[0] == "--download-only":
        # Install a PRISTINE build and stop: used by the combined tweakcc
        # pipeline, which applies the patches itself (and would conflict with
        # the byte-neutral ones this script normally applies).
        version = argv[1] if len(argv) > 1 else latest_version()
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
            staging = target.with_name(target.name + ".staging")
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
        version = argv[1] if len(argv) > 1 else latest_version()
        target = versions_dir() / version
        if target.is_file() and has_marker(target, ROUTING_MARKER):
            info(f"{version} is already installed and patched -> {target}")
            repoint_launcher(target)
            return
        download_binary(version, target)
        info(f"Installed pristine {version} -> {target}")
        # Repointed only after patch_binary() below succeeds — an unpatched
        # binary on the launcher path sends subscription traffic to the proxy.
        repoint_after_patch = True
    elif argv:
        target = Path(argv[0]).expanduser().resolve()
        if not target.is_file():
            die(f"binary not found: {target}")
    else:
        target = resolve_active_binary()

    info(f"Target binary: {target}")
    patch_binary(target)
    if repoint_after_patch:
        repoint_launcher(target)


if __name__ == "__main__":
    main(sys.argv[1:])
