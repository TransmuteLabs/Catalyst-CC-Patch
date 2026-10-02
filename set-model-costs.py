#!/usr/bin/env python3
r"""Sync `customModelCosts` and `customModelContextWindows` in ~/.claude.json from
models.dev — per-model prices and context limits for the models the local proxy
serves, which Claude Code otherwise misprices and pins to a 200K window.

Why this exists
---------------
Claude Code bills every request through one shared path, so subagent usage is
already in the session total and a proxy model already gets its own row in
`/cost`. The PRICE is what is wrong: a model missing from the built-in table
falls back to the default main-loop model's tier and, when that misses too, to
$5/$25 per Mtok — Anthropic Opus rates applied to every proxy model.

Claude Code's own override key, `additionalModelCostsCache`, is server-owned:
the bootstrap response overwrites it wholesale, so anything written there by
hand is erased on the next fetch. Patch #8 in tweakcc-patch.js therefore merges
a user-owned key, `customModelCosts`, on top of it — that is the key this
script writes.

Why models.dev rather than a table in this file
-----------------------------------------------
Prices are data, and hand-typed data goes stale and is wrong on the details:
the first cut of this script guessed gpt-5.6-terra cache-read at $0.25 (real:
$0.20) and gpt-5.6-luna at $0.10 (real: $0.02). models.dev is the maintained
catalogue that ccusage, splitrail and opencode all already build on, so this
script syncs from it instead of asserting prices of its own. Re-run it whenever
a vendor changes rates or the proxy gains models.

The provider tie-break mirrors ccusage's (nix/tools/models-dev-gen/compact.ts):
several catalogues publish the same model id at different prices, so prefer the
first-party vendor, then entries carrying explicit cache fields, then the
lexicographically smaller provider id for determinism.

    python3 set-model-costs.py               # sync and write
    python3 set-model-costs.py --dry-run     # show what would be written
    python3 set-model-costs.py --show        # print what is currently stored
    python3 set-model-costs.py --check-drift # read-only: live proxy list vs stored rows

Exit codes (a subset of the kit-wide table, see the claude-patch-all.sh header):
  0  sync done (or --dry-run/--show answered, or --check-drift found no red)
  1  a refusal on the merits: the registry is unreachable/unparsable, the
     stored config is unreadable, or --check-drift found a served model
     without a row the source could have written (stale sync — red)
  2  --check-drift could not measure: the proxy listing or the price source
     is unreachable. An unmeasured predicate must not answer green, and a
     "no drift" over an unreachable source is exactly that.
The script itself CAN exit non-zero (круг 28, F-11): what makes a failed cost
sync a WARNING is the CONVEYOR, which swallows this script's non-zero code as
one (claude-patch-all.sh, the set-model-costs step) -- the image is already
built and correct by then. The claim used to live here as "never exits
fatally", which was true of the caller and false of this file.
"""

import ctypes
import errno
import hashlib
import json
import os
import re
import secrets
import shutil
import socket
import stat as stat_module
import sys
import threading
import time
import urllib.request

MODELS_DEV_URL = "https://models.dev/api.json"
PROXY_MODELS_URL = "http://localhost:8317/v1/models"

# The proxy's own model catalogue: every model it knows how to route, switched
# on or not, with the real upstream id behind each published alias and — where
# the provider reports one — the window that ROUTE allows.
#
# That last part is why this file beats models.dev for windows: models.dev
# describes a model, the catalogue describes a deployment of it. The same
# gpt-5.5 is 272000 through the Codex route and 200000 through CommandCode;
# Kimi-K2.7-Code is 256000 here against the catalogue's 262144. One global
# number per model cannot express that, and guessing high is the failure mode
# that returns `400 input exceeds the context window`.
PROXY_CATALOGUE_PATH = os.path.expanduser(
    "~/Library/Application Support/VibeProxy/models.json")

# First-party catalogues win over resellers, which publish the same ids at
# their own markups (e.g. greenpt lists kimi-k3 at $3.762 vs Moonshot's $3.00).
FIRST_PARTY = (
    "openai",
    "xai",
    "moonshotai",
    "moonshot",
    "zhipuai",
    "zai",
    "z-ai",
    "anthropic",
    "google",
    "deepseek",
    "meta",
    "alibaba",
)

# Ids the proxy serves that models.dev does not list under that exact name.
# Value = the models.dev id to price them from.
ALIASES = {
    # Only CAPPED DEPLOYMENTS belong here — a different serving of the same
    # model, which no naming rule can infer. Vendor-path ids like
    # `cc/deepseek/deepseek-v4-pro` or `cc/Qwen/Qwen3.8-Max` used to be listed
    # too; id_matches() now resolves those by lowercased suffix, so spelling
    # them out by hand (and re-adding a line every time the proxy renames a
    # route) is no longer needed.
    "kimi-k3-256k": "kimi-k3",  # same model, smaller window
    "deepseek-v4-flash-200k": "deepseek-v4-flash",  # same model, smaller window
}

# Model ids to leave alone even if the proxy serves them: image, video and
# speech models bill per image/second/character, not per token, so a token
# price would be nonsense and a context window meaningless.
SKIP_SUBSTRINGS = ("imagine", "gpt-image", "-video", "-image", "-audio-")

# Context windows the catalogue cannot express, because the proxy serves a
# capped deployment of a model whose upstream entry advertises the full window.
# Priced from the base model via ALIASES, but metered at the smaller window.
# TOTAL (input+output) budgets the catalogue cannot express, because the proxy
# serves a capped deployment of a model whose upstream entry advertises the full
# window. Priced from the base model via ALIASES, metered at the smaller budget.
# These go through the reply carve-out like any other `limit.context` figure.
CONTEXT_OVERRIDES = {
    "kimi-k3-256k": 262144,  # 256K deployment of kimi-k3 (catalogue: 1M)
    "deepseek-v4-flash-200k": 200000,  # 200K deployment of deepseek-v4-flash (catalogue: 1M)
}

# INPUT-ONLY caps — the reply does not count against these, so no carve-out.
# The proxy serves the gpt-5.x family through a Codex (ChatGPT-subscription)
# route whose bundled catalogue reports context_window: 272000 whatever the
# model card advertises. It is a billing guard, not a model limit: past 272K
# input OpenAI charges 2x input / 1.5x output for the WHOLE session, so the
# catalogue's 922K/1.05M is unreachable here. 258000 rather than the raw 272000
# because Codex itself budgets 95% of the cap — a client's token estimate never
# matches the server's exactly, and without that margin a prompt counted at 271K
# comes back as `400 Your input exceeds the context window of this model`, which
# is how both gpt-5.6-luna probe runs died on 2026-08-08.
INPUT_CAP_OVERRIDES = {
    "gpt-5.6-sol": 258000,
    "gpt-5.6-terra": 258000,
    "gpt-5.6-luna": 258000,
    "gpt-5.5": 258000,
}


# Claude Code subtracts exactly this much from the declared window before
# checking a prompt against it (MAX_OUTPUT_TOKENS_FOR_SUMMARY in autoCompact.ts).
SUMMARY_RESERVE = 20_000

# `MiniMax-M3[1m]`, `qwen3.8-max[1m]`: the proxy publishes a long-context
# serving of a model under the base id plus a size tag. Same weights and same
# rates as the base — only the window differs — so the tag is stripped for the
# price lookup and read as the window. Handled by rule rather than by two
# ALIASES lines, because the next such id appears the moment a route is added.
DEPLOYMENT_TAG = re.compile(r"\[(\d+)([km])\]$", re.IGNORECASE)


def deployment_tag_window(model_id):
    """Total window a `[1m]`-style tag declares, or None. 1m reads as 1_000_000
    rather than 1_048_576: of the two readings that is the smaller, and an
    under-declared window wastes context where an over-declared one 400s."""
    tag = DEPLOYMENT_TAG.search(model_id)
    if not tag:
        return None
    size, unit = int(tag.group(1)), tag.group(2).lower()
    return size * (1_000_000 if unit == "m" else 1_000)


def config_path():
    if "CLAUDE_CONFIG_DIR" in os.environ and not os.environ["CLAUDE_CONFIG_DIR"]:
        raise ValueError("CLAUDE_CONFIG_DIR is set but empty; nothing written")
    directory = os.environ.get("CLAUDE_CONFIG_DIR")
    if directory is None and not os.environ.get("HOME"):
        # python's expanduser would fall back to the pwd database while bash
        # reads an empty $HOME as "/" -- two different paths for one setting.
        raise ValueError("HOME is empty or not set; nothing written")
    settings_dir = directory or os.path.expanduser("~/.claude")
    legacy = os.path.join(settings_dir, ".config.json")
    if os.path.exists(legacy):
        return legacy
    suffix = "-custom-oauth" if os.environ.get("CLAUDE_CODE_CUSTOM_OAUTH_URL") else ""
    return os.path.join(directory or os.path.expanduser("~"), f".claude{suffix}.json")


def settings_path():
    return os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                        "settings.json")


class SettingsUnreadable(ValueError):
    pass


# CONSTRAINT: match proper-lockfile stale:1e4 in the 2.1.286 image;
# wait at most 30 s before refusing a fresh foreign lock.
CONFIG_LOCK_STALE_SECONDS = 10
CONFIG_LOCK_TIMEOUT_SECONDS = 30
# CONSTRAINT: under half of the product's stale window (proper-lockfile
# refreshes at stale/2): the heartbeat must touch the lock more often than
# the product can declare it abandoned.
CONFIG_LOCK_HEARTBEAT_SECONDS = 2
# Old temp-name forms (released before the tag/pid-namespace scheme) carry no
# namespace identity, so age is the only available boundary; a sync run lasts
# seconds, and one hour is far outside any honest run.
TEMP_OLD_FORM_AGE_SECONDS = 3600


class ConfigLockHeld(Exception):
    pass


class ConfigLockLost(Exception):
    pass


class ConfigLockNotADirectory(Exception):
    pass


class ConfigLockUnavailable(Exception):
    pass


class BackupNameExhausted(Exception):
    pass


class ConfigWriteFailed(Exception):
    pass


def temp_space_tag():
    """First 8 hex of sha1('<hostname>:<pid-ns>') — the identity of THIS
    writer's pid space. A pid is only meaningful inside its namespace: a
    foreign namespace's live pid can collide with our dead one, so a temp of
    the new form is only ours when the tag matches too."""
    global _TEMP_SPACE_TAG
    if _TEMP_SPACE_TAG is None:
        try:
            namespace = os.stat("/proc/self/ns/pid").st_ino
        except OSError:
            namespace = 0
        seed = f"{socket.gethostname()}:{namespace}".encode()
        _TEMP_SPACE_TAG = hashlib.sha1(seed).hexdigest()[:8]
    return _TEMP_SPACE_TAG


_TEMP_SPACE_TAG = None


class ConfigLock:
    """Ownership of the directory lock: (st_dev, st_ino, st_mtime_ns) taken
    from stat AFTER our own utime, never the value we asked utime to store —
    a coarse filesystem may not keep the given nanoseconds, and comparing
    against the requested value would report a false loss.

    CONSTRAINT: the verify→syscall window is inherent to a directory lock;
    the product has the same window, and proper-lockfile detects compromise
    the same way (mtime re-check)."""

    def __init__(self, path):
        self.path = path + ".lock"
        self.identity = None
        self.lost = False
        self._identity_guard = threading.Lock()
        self._fd = None
        self.created = None
        self.staging = None
        self.published = False
        self._stop = threading.Event()
        self._thread = None

    def current_identity(self):
        info = os.stat(self.path)
        return (info.st_dev, info.st_ino, info.st_mtime_ns)

    def _adopt(self):
        # CONSTRAINT: the directory descriptor, opened once on the creation
        # path, is held for the whole ownership and closed only by
        # release()/abandon() -- while it is open the inode cannot be freed,
        # so its number cannot be reused by a rival's directory. Every
        # ownership decision below compares the path against the HELD
        # descriptor, never against remembered numbers alone. Any OSError
        # inside is a lost lock (named rc-5 refusal), never a traceback.
        with self._identity_guard:
            owned = self.identity
            moment = time.time_ns()
            try:
                if self._fd is None:
                    self._fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                held = os.fstat(self._fd)
                if owned is not None:
                    path_now = os.stat(self.path)
                    if (path_now.st_dev, path_now.st_ino) != (held.st_dev, held.st_ino):
                        self.lost = True
                        raise ConfigLockLost(
                            f"config lock {self.path} lost to another writer; nothing written")
                    os.utime(self._fd, ns=(moment, moment))
                    path_now = os.stat(self.path)
                    if (path_now.st_dev, path_now.st_ino) != (held.st_dev, held.st_ino):
                        self.lost = True
                        raise ConfigLockLost(
                            f"config lock {self.path} lost to another writer; nothing written")
                else:
                    os.utime(self._fd, ns=(moment, moment))
                after = os.fstat(self._fd)
                path_now = os.stat(self.path)
                if (path_now.st_dev, path_now.st_ino) != (after.st_dev, after.st_ino):
                    self.lost = True
                    raise ConfigLockLost(
                        f"config lock {self.path} lost to another writer; nothing written")
                self.identity = (after.st_dev, after.st_ino, after.st_mtime_ns)
            except OSError as exc:
                self.lost = True
                raise ConfigLockLost(
                    f"config lock {self.path} lost: [Errno {exc.errno}] {exc.strerror}; nothing written")

    def touch(self):
        # CONSTRAINT: never adopt a changed identity. An unconditional
        # refresh would claim a rival's lock taken over after ours went
        # stale, every later verify would pass, and release() would remove
        # the rival's directory.
        with self._identity_guard:
            try:
                current = self.current_identity()
            except OSError:
                self.lost = True
                raise ConfigLockLost(
                    f"config lock {self.path} lost to another writer; nothing written")
            if current != self.identity:
                self.lost = True
                raise ConfigLockLost(
                    f"config lock {self.path} lost to another writer; nothing written")
        self._adopt()

    def _heartbeat(self):
        while not self._stop.wait(CONFIG_LOCK_HEARTBEAT_SECONDS):
            try:
                self.touch()
            except (ConfigLockLost, OSError):
                # The thread never throws outward: a lock it cannot prove its
                # own is a lock it must stop refreshing.
                with self._identity_guard:
                    self.lost = True
                return

    def start(self):
        # acquire() created this directory a moment ago in this process:
        # there is no identity to lose yet, only one to record.
        # CONSTRAINT: the stop flag is created ONCE, in __init__, and abandon()
        # sets it on every contended iteration while the SAME lock object is
        # retried -- a heartbeat started afterwards would see the flag already
        # set and return without ever refreshing. A fresh flag per start is
        # what makes a lock won on a retry stay alive.
        self._stop = threading.Event()
        self._adopt()
        self._thread = threading.Thread(target=self._heartbeat, daemon=True)
        self._thread.start()

    def verify_owned(self):
        # CONSTRAINT: the lost check shares the guard with every write of the
        # flag (no publish may slip past a raised lost), and ownership is
        # decided by comparing the path against the HELD descriptor, never
        # against remembered numbers alone.
        with self._identity_guard:
            if self.lost:
                raise ConfigLockLost(
                    f"config lock {self.path} lost to another writer; nothing written")
            try:
                held = os.fstat(self._fd)
                now = os.stat(self.path)
                if (now.st_dev, now.st_ino, now.st_mtime_ns) != (
                        held.st_dev, held.st_ino, held.st_mtime_ns):
                    self.lost = True
                    raise ConfigLockLost(
                        f"config lock {self.path} lost to another writer; nothing written")
            except OSError as exc:
                self.lost = True
                raise ConfigLockLost(
                    f"config lock {self.path} lost: [Errno {exc.errno}] {exc.strerror}; nothing written")

    def stop(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join()

    def abandon(self):
        # CONSTRAINT (protocol v2): before publication the staging name is
        # PRIVATE, so its cleanup removes it BY NAME and cannot touch
        # another writer; after publication the directory is removed only
        # while the path still resolves to the HELD descriptor, and its
        # owner file is removed THROUGH that descriptor, never by path --
        # a rival's replacement at the path must survive every failure of
        # ours. Never raises: the caller re-raises the named refusal.
        self._stop.set()
        if self._thread is not None and self._thread.is_alive():
            self._thread.join()
        with self._identity_guard:
            try:
                if not self.published:
                    # Pre-publication the owner file exists only once the
                    # directory descriptor is held; a failure before that
                    # leaves a bare directory, removed BY ITS PRIVATE NAME.
                    if self._fd is not None:
                        try:
                            os.unlink("owner", dir_fd=self._fd)
                        except OSError:
                            pass
                    if self.staging is not None:
                        os.rmdir(self.staging)
                elif self._fd is not None:
                    held = os.fstat(self._fd)
                    now = os.stat(self.path)
                    if (now.st_dev, now.st_ino) == (held.st_dev, held.st_ino):
                        try:
                            os.unlink("owner", dir_fd=self._fd)
                        except OSError:
                            pass
                        os.rmdir(self.path)
            except OSError:
                pass
            finally:
                if self._fd is not None:
                    try:
                        os.close(self._fd)
                    except OSError:
                        pass
                    self._fd = None

    def release(self):
        # CONSTRAINT: release runs in main's finally over an already computed
        # rc -- it must never raise and never change that rc; every failure
        # is a stderr line carrying errno or naming the foreign owner.
        # "owned by another writer" is said only when the path exists and is
        # not ours, or when our directory is not empty after the owner file
        # was removed (v2: anything else inside is not ours to release).
        with self._identity_guard:
            try:
                held = os.fstat(self._fd)
                now = os.stat(self.path)
                foreign = (now.st_dev, now.st_ino) != (held.st_dev, held.st_ino)
                if not foreign:
                    try:
                        os.unlink("owner", dir_fd=self._fd)
                    except FileNotFoundError:
                        pass
                    try:
                        os.rmdir(self.path)
                    except OSError as exc:
                        if exc.errno != errno.ENOTEMPTY:
                            raise
                        foreign = True
                if foreign:
                    print(f"lock not released: owned by another writer ({self.path})",
                          file=sys.stderr)
            except OSError as exc:
                print(f"lock not released: [Errno {exc.errno}] {exc.strerror} ({self.path})",
                      file=sys.stderr)
            finally:
                if self._fd is not None:
                    try:
                        os.close(self._fd)
                    except OSError:
                        pass
                    self._fd = None


def rename_noreplace(src, dst):
    """Atomically move `src` onto `dst` ONLY if `dst` does not exist.

    CONSTRAINT: publishing the lock directory by plain os.rename would
    silently REPLACE whatever another writer placed at `dst` in the window
    between our staging mkdir and this call -- the single no-replace
    syscall is the whole publication guarantee of protocol v2.
    """
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        try:
            renamex_np = libc.renamex_np
        except AttributeError:
            raise ConfigLockUnavailable(
                "no atomic no-replace rename on this platform") from None
        renamex_np.restype = ctypes.c_int
        renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = renamex_np(os.fsencode(src), os.fsencode(dst), 0x4)  # RENAME_EXCL
        code = ctypes.get_errno()
    else:
        try:
            renameat2 = libc.renameat2
        except AttributeError:
            raise ConfigLockUnavailable(
                "no atomic no-replace rename on this platform") from None
        renameat2.restype = ctypes.c_int
        renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p,
                              ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = renameat2(-100, os.fsencode(src), -100, os.fsencode(dst), 1)  # AT_FDCWD, RENAME_NOREPLACE
        code = ctypes.get_errno()
    if result != 0:
        raise OSError(code, os.strerror(code), src, None, dst)


def reap_stale_staging(lock):
    """Remove staging directories left by writers that died between mkdir and
    rename: `<lock path>.new.*` of the same parent, older than the staleness
    bound. The protocol is the reap's: open by descriptor, appraise, unlink
    owner through the descriptor, re-check the path, rmdir.

    CONSTRAINT: this sweep must never fail the acquisition it serves -- a
    staging directory it cannot appraise (open/stat refused, contents beyond
    owner, identity changed under it) is skipped, and the writer's OWN staging
    name (`lock.staging`, mid-publication) is never a candidate. Own is matched
    by entry name, not by path spelling: staging is built from `lock.path`, so
    it lives in this same parent under its basename."""
    parent = os.path.dirname(lock.path) or "."
    prefix = os.path.basename(lock.path) + ".new."
    own = os.path.basename(lock.staging) if lock.staging else None
    try:
        names = os.listdir(parent)
    except OSError:
        return
    for name in names:
        if not name.startswith(prefix):
            continue
        if name == own:
            continue
        candidate = os.path.join(parent, name)
        try:
            fd_s = os.open(candidate, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except FileNotFoundError:
            continue
        except OSError:
            continue
        try:
            try:
                st = os.fstat(fd_s)
            except OSError:
                continue
            if time.time() - st.st_mtime <= CONFIG_LOCK_STALE_SECONDS:
                continue
            try:
                entries = os.listdir(fd_s)
            except OSError:
                continue
            # CONSTRAINT: same rule as the reap -- anything beyond `owner` is
            # foreign and is left untouched; an empty directory is the form a
            # writer killed before its owner file existed.
            if any(entry != "owner" for entry in entries):
                continue
            try:
                os.unlink("owner", dir_fd=fd_s)
            except FileNotFoundError:
                pass
            except OSError:
                continue
            try:
                info = os.stat(candidate)
            except FileNotFoundError:
                continue
            if (info.st_dev, info.st_ino) != (st.st_dev, st.st_ino):
                continue
            try:
                os.rmdir(candidate)
            except OSError:
                continue
        finally:
            os.close(fd_s)


def acquire_config_lock(path):
    lock = ConfigLock(path)
    deadline = time.monotonic() + CONFIG_LOCK_TIMEOUT_SECONDS
    delay = 0.1
    waited = False
    while True:
        # CONSTRAINT: the deadline and the backoff live at the TOP of the
        # loop so that every re-entry passes through them, including the bare
        # `continue` paths below -- a lock path that keeps defeating
        # description (a dangling symlink fails publication with EEXIST and
        # open with ELOOP) must end in a named refusal, never in a sleepless
        # spin. The first attempt alone is immediate.
        remaining = deadline - time.monotonic()
        if waited and remaining <= 0:
            raise ConfigLockHeld(f"config lock {lock.path} held by another writer; nothing written")
        if waited:
            time.sleep(min(delay, remaining))
            delay = min(delay * 2, 1.0)
        waited = True
        # CONSTRAINT: any other OSError on the lock path is a named rc-5
        # refusal, never a traceback; the recognizable subclasses are handled
        # inside first.
        try:
            # Protocol v2, step 1: create on a PRIVATE staging name. The
            # creation witness is taken on our own directory before any
            # other writer can see it, so a rival's directory can never be
            # mistaken for ours.
            token = secrets.token_hex(8)
            staging = f"{lock.path}.new.{os.getpid()}.{token}"
            owner = f"{os.getpid()} {token}\n"
            lock.staging = staging
            try:
                # CONSTRAINT: the directory mode must not inherit the
                # caller's umask (0o777 would make our own next open fail).
                os.mkdir(staging)
                os.chmod(staging, 0o700)
                lock._fd = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                lock.created = os.fstat(lock._fd)
                owner_fd = os.open("owner", os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                                   0o600, dir_fd=lock._fd)
                try:
                    os.write(owner_fd, owner.encode())
                finally:
                    os.close(owner_fd)
                # Fresh mtime BEFORE publication: the staleness window
                # starts when the directory becomes visible, not when we
                # built it.
                os.utime(lock._fd)
            except OSError as error:
                lock.abandon()
                raise ConfigLockUnavailable(
                    f"config lock {lock.path} unusable: [Errno {error.errno}] {error.strerror}; nothing written") from None
            # Step 2: publish WITHOUT replacement.
            try:
                rename_noreplace(staging, lock.path)
            except ConfigLockUnavailable:
                lock.abandon()
                raise
            except OSError as exc:
                lock.abandon()
                if exc.errno not in (errno.EEXIST, errno.ENOTEMPTY):
                    if exc.errno in (errno.ENOSYS, errno.EINVAL, errno.ENOTSUP):
                        raise ConfigLockUnavailable(
                            "no atomic no-replace rename on this filesystem") from None
                    raise ConfigLockUnavailable(
                        f"config lock {lock.path} unusable: [Errno {exc.errno}] {exc.strerror}; nothing written") from None
                # The path is held: wait out a fresh holder, reap a stale one.
                try:
                    fd_r = os.open(lock.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                except FileNotFoundError:
                    reap_stale_staging(lock)
                    continue
                except OSError as exc_r:
                    if exc_r.errno in (errno.ELOOP, errno.ENOTDIR):
                        raise ConfigLockNotADirectory(
                            f"config lock path {lock.path} is not a directory; "
                            "nothing written") from None
                    raise
                try:
                    st = os.fstat(fd_r)
                    if time.time() - st.st_mtime <= CONFIG_LOCK_STALE_SECONDS:
                        reap_stale_staging(lock)  # fresh holder: wait
                        continue
                    entries = os.listdir(fd_r)
                    # CONSTRAINT: an empty directory is the pre-v2 format, or
                    # a v2 lock whose staging `owner` the sweep removed while
                    # its writer stalled past the staleness bound; both are
                    # reaped only past that bound. Anything beyond owner is
                    # foreign and is never removed here.
                    if any(entry != "owner" for entry in entries):
                        raise ConfigLockUnavailable(
                            f"config lock {lock.path} unusable: lock directory holds foreign entries; nothing written")
                    try:
                        os.unlink("owner", dir_fd=fd_r)
                    except FileNotFoundError:
                        pass
                    try:
                        info = os.stat(lock.path)
                    except FileNotFoundError:
                        # CONSTRAINT (protocol v2 reap): the appraised directory
                        # can vanish between the owner unlink and this re-check
                        # -- a rival reaper removed it. The inode is already
                        # gone, so there is nothing of ours left to remove;
                        # close and keep waiting.
                        reap_stale_staging(lock)  # path vanished: keep waiting
                        continue
                    if (info.st_dev, info.st_ino) != (st.st_dev, st.st_ino):
                        reap_stale_staging(lock)  # identity moved: keep waiting
                        continue
                    # CONSTRAINT: the fall-through reaches the reap, so it sweeps
                    # stale staging on the way there too.
                    reap_stale_staging(lock)  # identity held: reap it
                    try:
                        os.rmdir(lock.path)
                    except OSError as exc_r:
                        if exc_r.errno in (errno.ENOTEMPTY, errno.ENOENT, errno.ENOTDIR):
                            # A rival's fresh non-empty directory is not
                            # removed by construction: only the reap of the
                            # appraised inode reaches this rmdir.
                            reap_stale_staging(lock)  # rmdir lost the race
                            continue
                        raise
                finally:
                    os.close(fd_r)
                reap_stale_staging(lock)  # reaped: retry the publication
                continue
            # Step 3: prove the published path is the directory we built.
            lock.published = True
            info = os.stat(lock.path)
            if (info.st_dev, info.st_ino) != (lock.created.st_dev, lock.created.st_ino):
                lock.abandon()
                raise ConfigLockLost(
                    f"config lock {lock.path} lost to another writer; nothing written")
            try:
                lock.start()
            except ConfigLockLost:
                lock.abandon()
                raise
            except Exception as error:
                lock.abandon()
                raise ConfigLockUnavailable(
                    f"config lock {lock.path} unusable: {error}; nothing written") from None
            return lock
        except OSError as exc:
            lock.abandon()
            raise ConfigLockUnavailable(
                f"config lock {lock.path} unusable: [Errno {exc.errno}] {exc.strerror}; nothing written") from None
        except BaseException:
            # CONSTRAINT: publication is the rename, and the `published` flag is
            # set a statement LATER -- a non-OSError raised in that gap (an
            # interrupt) would otherwise make abandon treat the directory as
            # still private and remove it by its staging name, which no longer
            # exists, leaving the published directory behind with no owner of
            # record. The flag is set here only when the path still resolves to
            # the directory we built; the stat failure is swallowed, the
            # original exception is always re-raised.
            try:
                now = os.stat(lock.path)
                if (lock.created is not None
                        and (now.st_dev, now.st_ino) == (lock.created.st_dev, lock.created.st_ino)):
                    lock.published = True
            except OSError:
                pass
            lock.abandon()
            raise


def usable_temp_pid(raw):
    try:
        pid = int(raw)
    except ValueError:
        return None
    # os.kill on Linux overflows past the C int range; a pid outside it says
    # nothing about liveness, and a temp we cannot appraise stays untouched.
    if not 1 <= pid <= 2**31 - 1:
        return None
    return pid


def temp_pid_state(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return "dead"
    except PermissionError:
        # Exists and belongs to another user: live for our purposes.
        return "alive"
    except (OverflowError, ValueError):
        return "unusable"
    return "alive"


def remove_temp(directory, name):
    temp = os.path.join(directory, name)
    try:
        if not stat_module.S_ISREG(os.lstat(temp).st_mode):
            print(f"Skipped non-file temp {temp}")
            return
        os.unlink(temp)
    except FileNotFoundError:
        # A rival sweeper took it between our decision and the unlink: its
        # removal line belongs to that run, not to this one.
        return
    except OSError as error:
        print(f"Could not sweep {temp}: {error}")
        return
    print(f"Swept stale temp {temp}")


def sweep_stale_temps(path):
    directory = os.path.dirname(path) or "."
    base = re.escape(os.path.basename(path))
    tag = temp_space_tag()
    hex8 = "[0-9a-f]{8}"
    pid_group = r"(?P<pid>[0-9]{1,10})"
    new_forms = (
        re.compile(rf"\.tmp-copy-cms-(?P<tag>{hex8})-{pid_group}-{base}\.backup\..+"),
        re.compile(rf"{base}\.tmp\.cms-(?P<tag>{hex8})-{pid_group}"),
    )
    old_forms = (
        re.compile(rf"\.tmp-copy-{pid_group}-{base}\.backup\..+"),
        re.compile(rf"{base}\.tmp\.{pid_group}"),
    )
    now = time.time()
    # CONSTRAINT: the sweep is advisory -- a directory it cannot list is a
    # named note, not a reason to fail the sync it serves.
    try:
        names = sorted(os.listdir(directory))
    except OSError as exc:
        print(f"Could not sweep {directory}: [Errno {exc.errno}] {exc.strerror}")
        return
    for name in names:
        new_match = next((m for pattern in new_forms if (m := pattern.fullmatch(name))), None)
        if new_match is not None:
            temp = os.path.join(directory, name)
            if new_match.group("tag") != tag:
                print(f"Skipped foreign temp {temp}")
                continue
            pid = usable_temp_pid(new_match.group("pid"))
            if pid is None:
                print(f"Skipped temp with unusable pid {temp}")
                continue
            state = temp_pid_state(pid)
            if state == "unusable":
                print(f"Skipped temp with unusable pid {temp}")
            elif state == "dead":
                remove_temp(directory, name)
            continue
        old_match = next((m for pattern in old_forms if (m := pattern.fullmatch(name))), None)
        if old_match is None:
            continue
        pid = usable_temp_pid(old_match.group("pid"))
        if pid is None:
            print(f"Skipped temp with unusable pid {os.path.join(directory, name)}")
            continue
        state = temp_pid_state(pid)
        if state == "unusable":
            print(f"Skipped temp with unusable pid {os.path.join(directory, name)}")
        elif state == "dead":
            temp = os.path.join(directory, name)
            # Old forms have no namespace identity; age is their only boundary,
            # and a future mtime reads as "not older than the bound" and stays.
            try:
                age = now - os.lstat(temp).st_mtime
            except FileNotFoundError:
                # A rival sweeper removed the temp between our listdir and
                # this lstat: its removal line belongs to that run, not this.
                continue
            if age >= TEMP_OLD_FORM_AGE_SECONDS:
                remove_temp(directory, name)


def reply_headroom():
    """Tokens a reply can add on top of what Claude Code already reserves.

    The declared window is not a prompt budget — Claude Code lets the prompt
    reach `window - 20_000` and then puts a reply of up to
    CLAUDE_CODE_MAX_OUTPUT_TOKENS on top. With that set to 96_000 the request
    can total `window + 76_000`, so declaring the model's full budget overshoots
    it by that much. Invisible at 1M, fatal at 200K where it is a 38% overrun.
    """
    path = settings_path()
    try:
        with open(path, encoding="utf-8") as fh:
            configured = int((json.load(fh).get("env") or {}).get(
                "CLAUDE_CODE_MAX_OUTPUT_TOKENS", 0) or 0)
    except FileNotFoundError:
        configured = 0
    except Exception as error:
        raise SettingsUnreadable(f"{path} unreadable ({error}); nothing written") from error
    return max(0, configured - SUMMARY_RESERVE)


def context_window(model_id, model, catalogued=None):
    """Window to declare so that prompt + reply stays inside the real budget.

    Two kinds of number get conflated here and must not be:

    `limit.context` is the COMBINED input+output budget, so the reply has to be
    carved out of it — that is what reply_headroom() does.

    `limit.input` (and INPUT_CAP_OVERRIDES) is already an input-only cap that
    the reply does not count against, so no carve-out applies. The gpt-5.x
    family is the visible case: context 1,050,000 but input only 922,000, the
    other 128,000 belonging to the reply by construction.

    Source order is narrowest-first: a hand-set input cap, then the window the
    proxy records for THIS route, then models.dev for the model in general.

    Every fallback is cut from above by `routed` when the route is known: the
    ladder only reaches a fallback when `routed - headroom` is already
    nonpositive, and an uncapped `limit.input` there declared 116000 to a
    route that carries 32000 (wave 26). The declared window may not exceed the
    route's capacity on any fallback branch; the hand-set INPUT_CAP_OVERRIDES
    return is a deliberate override, not a fallback.
    """
    cap = INPUT_CAP_OVERRIDES.get(model_id)
    if cap:
        return cap
    limit = (model or {}).get("limit") or {}
    routed = (catalogued or {}).get("context") or deployment_tag_window(model_id)
    if routed:
        adjusted = routed - reply_headroom()
        if adjusted > 0:
            return adjusted
    explicit_input = limit.get("input")
    if explicit_input:
        if not routed or explicit_input <= routed:
            return explicit_input
        return routed
    total = CONTEXT_OVERRIDES.get(model_id) or limit.get("context")
    if total:
        adjusted = total - reply_headroom()
        if adjusted > 0:
            if not routed or adjusted <= routed:
                return adjusted
            return routed
    return None


CACHE_PATH = os.path.expanduser("~/.cache/claude-model-costs/models-dev.json")
CACHE_FUTURE_TOLERANCE_SECONDS = 60
CACHE_MAX_AGE_SECONDS = 168 * 3600

# Every model id ever seen on the proxy. The proxy's listing shows only what is
# switched on at that instant, so this file is what makes the roster survive a
# model being toggled off — see the roster comment in main().
SEEN_PATH = os.path.expanduser("~/.cache/claude-model-costs/seen-models.json")


def write_json_atomically(path, payload, lock=None, **dump_kw):
    """Запись json через временное имя рядом, fsync и переименование.

    Три места писали этот же приём вручную и БЕЗ fsync: переименование
    гарантирует, что читатель не увидит половину, но не гарантирует, что после
    внезапной перезагрузки в файле окажутся байты, а не нули. Дом приёма один
    на всех писателей (круг 21, E-6).
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.cms-{temp_space_tag()}-{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, **dump_kw)
            fh.flush()
            os.fsync(fh.fileno())
        # Ownership check is the LAST action before the rename: staging may
        # outlive the moment the lock was last proven ours.
        if lock is not None:
            lock.verify_owned()
        os.replace(tmp, path)
    except OSError as exc:
        # CONSTRAINT: a destination that could not be reached is a named
        # rc-6 refusal with the errno and the path; the staging name is
        # always removed. Nothing here is a lock loss -- ConfigLockLost is
        # not an OSError and passes to its own handler.
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise ConfigWriteFailed(
            f"could not write {path}: [Errno {exc.errno}] {exc.strerror}; nothing written") from None
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def publish_backup(src, lock=None):
    stamp = time.strftime('%Y%m%d-%H%M%S', time.gmtime())
    dst = f"{src}.backup.u{stamp}"
    # Имя стадии НАМЕРЕННО не из семьи назначения: конвейер прополаывает бэкапы
    # глобом `~/.claude.json.backup.*` и оставляет три свежих. Стадия с именем
    # `<бэкап>.part.<pid>` попала бы в этот глоб -- и обломок убитого прогона
    # вытеснил бы из тройки НАСТОЯЩИЙ бэкап (claude-patch-all.sh,
    # prune_config_backups).
    directory = os.path.dirname(src) or "."
    part = os.path.join(
        directory, f".tmp-copy-cms-{temp_space_tag()}-{os.getpid()}-{os.path.basename(dst)}")
    linked = None
    try:
        with open(src, "rb") as rfh, open(part, "wb") as wfh:
            shutil.copyfileobj(rfh, wfh)
            wfh.flush()
            shutil.copystat(src, part)
            os.fsync(wfh.fileno())
        for number in range(100):
            candidate = dst if number == 0 else f"{dst}.{number:02d}"
            # Verified before EVERY link attempt, not once before the loop:
            # each retry is another chance for a takeover to slip in.
            if lock is not None:
                lock.verify_owned()
            try:
                os.link(part, candidate)
            except FileExistsError:
                continue
            linked = candidate
            fd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
            return candidate
        raise BackupNameExhausted(f"backup name space exhausted for {stamp}; nothing written")
    except OSError as exc:
        # CONSTRAINT: an I/O failure anywhere in the publish path is a named
        # rc-6 refusal, never a traceback; the "nothing written" tail is
        # claimed only while the destination name is still untouched
        # (linked is None). Lock losses and name exhaustion are not OSError
        # and pass through to their own handlers.
        raise ConfigWriteFailed(
            f"could not publish backup {src}: [Errno {exc.errno}] {exc.strerror}"
            + ("; nothing written" if linked is None else "")) from None
    finally:
        try:
            os.unlink(part)
        except OSError:
            pass


def load_seen():
    try:
        with open(SEEN_PATH, encoding="utf-8") as fh:
            return set(json.load(fh))
    except Exception:
        return set()


def save_seen(ids, lock=None):
    write_json_atomically(SEEN_PATH, sorted(ids), lock=lock, indent=2)


def fetch_json(url, timeout=30):
    # models.dev answers 403 to urllib's default User-Agent.
    request = urllib.request.Request(url, headers={"User-Agent": "claude-model-costs/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def fetch_catalogue():
    """Return (catalogue, origin) without writing, including in read-only modes."""
    try:
        catalogue = fetch_json(MODELS_DEV_URL)
    except Exception as error:
        # An unreadable cache means NO cache: two concurrent syncs used to
        # tear the file apart with a direct open("w") on the final name,
        # and the "network down -> fall back to cache" degradation turned
        # into a traceback instead. Warn and let the original network
        # error surface, exactly as when no cache file exists at all.
        # getmtime lives INSIDE this guard: the same concurrent sync that
        # can tear the cache can remove it between os.path.exists below
        # and getmtime, and that FileNotFoundError must land here — in the
        # "no cache" branch that re-raises the ORIGINAL network error —
        # not fly past it as a raw traceback.
        if os.path.exists(CACHE_PATH):
            try:
                age_seconds = time.time() - os.path.getmtime(CACHE_PATH)
                age_h = age_seconds / 3600
                if (age_seconds < -CACHE_FUTURE_TOLERANCE_SECONDS
                        or age_seconds > CACHE_MAX_AGE_SECONDS):
                    print(f"  cache is outside its valid age window ({age_h:.0f}h); "
                          "no fallback")
                else:
                    with open(CACHE_PATH, encoding="utf-8") as fh:
                        catalogue = json.load(fh)
                    if catalogue:
                        print(f"  models.dev unreachable ({error}); using cache, {age_h:.0f}h old")
                        return catalogue, "cache"
            except (OSError, ValueError) as cache_error:
                print(f"  cache is unreadable too ({cache_error}); no fallback")
                # Re-raise the ORIGINAL network error, exactly as when no
                # cache file exists at all: a bare `raise` here would surface
                # the cache's JSONDecodeError instead and misreport the cause.
                raise error from cache_error
        raise
    return catalogue, "network"


def proxy_model_ids():
    """Model ids the local proxy currently serves, minus the non-token ones."""
    data = fetch_json(PROXY_MODELS_URL, timeout=10)
    ids = [m["id"] for m in data.get("data", [])]
    return sorted(i for i in ids if not any(s in i for s in SKIP_SUBSTRINGS))


def load_proxy_catalogue():
    """Published id -> {"name": upstream id, "context": int|None, "providers": [...]}.

    Keyed by `alias`, which is what the proxy publishes and therefore what
    Claude Code will look up; `name` is the upstream id behind it, kept because
    it is the better key for a price lookup (`muse-spark-1.2-contributor` is
    published bare but catalogued as `meta/muse-spark-1.2-contributor`).

    ADDITIVE, never a replacement for the live listing: this file is written
    when the app discovers a provider's models, so it lags reality in both
    directions — on 2026-08-13 four served models (gpt-5.6-sol, gpt-5.6-terra,
    grok-4.6, codex-auto-review) were absent from it while three marked
    `enabled` were not being served.

    One alias can appear under several providers (deepseek-v4-flash is routed
    by three). Entries that are switched on describe the route in force, so
    they win; among equals the SMALLEST declared window wins, because
    under-declaring wastes context while over-declaring makes requests fail.

    The parse also counts the file's raw denominators into last_stats
    (providers / records / enabled): records counts EVERY model row across
    providers of both
    shapes, before the skip filter and the dedup — it is the file's size;
    unique published names (len of the return value) is what the sync keys
    on. The two counts answer different questions (#53 measured 682 raw
    records against 626 published names) and both are named in the output,
    because a bare "(N models)" let them pass for the same number.
    """
    try:
        with open(PROXY_CATALOGUE_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        # No catalogue AND no stats: an explicit empty state, so a stale
        # attribute from an earlier call can never answer for this one.
        load_proxy_catalogue.last_stats = None
        return {}
    out = {}
    records = 0
    for provider_id, rows in data.items():
        # The proxy publishes a provider entry in two shapes: a bare list of
        # models and a wrapper {"models": [...], "priority": N}. Iterating the
        # dict yields STRING keys, not entries, and a reader that knows only one
        # shape crashes on the very first wrapper — taking down the entire price
        # and window sync step, not just one provider. The "priority" field is
        # deliberately unused here: provider seniority is set by its own list
        # below, and substituting a number of unknown polarity for it is guessing.
        if isinstance(rows, dict):
            rows = rows.get("models")
        for row in rows or []:
            records += 1
            if not isinstance(row, dict):
                continue
            published = row.get("alias") or row.get("name")
            if not published or any(s in published for s in SKIP_SUBSTRINGS):
                continue
            entry = out.setdefault(
                published, {"name": row.get("name"), "context": None, "providers": [],
                            "enabled": False})
            entry["providers"].append(provider_id)
            live_route = bool(row.get("enabled"))
            window = row.get("context-length")
            # A switched-on route replaces whatever a switched-off one claimed.
            if live_route and not entry["enabled"]:
                entry["enabled"] = True
                entry["context"] = window
                entry["name"] = row.get("name") or entry["name"]
            elif live_route == entry["enabled"] and window:
                entry["context"] = min(entry["context"] or window, window)
    load_proxy_catalogue.last_stats = {
        # providers — ключи файла ОБЕИХ форм, включая пустые; records — все
        # строки моделей до фильтра и дедупа; enabled — уникальные имена, у
        # которых хоть один маршрут включён (уровень имени, не строки: замер
        # 17.09 считал именно так).
        "providers": len(data),
        "records": records,
        "enabled": sum(1 for entry in out.values() if entry["enabled"]),
    }
    return out


def id_matches(proxy_id, catalogue_id):
    """Do these two ids name the same model?

    Ids differ in case and in how many vendor segments they carry, and which
    side is longer varies: the proxy says `cc/Qwen/Qwen3.8-Max` where the
    catalogue says `qwen3.8-max`, but says `muse-spark-1.2-contributor` where
    the catalogue says `meta/muse-spark-1.2-contributor`. So: compare lowercased,
    and accept a suffix in either direction. The `/` in the test keeps the match
    on a segment boundary — without it `deepseek-v4-pro` would swallow anything
    merely ending in those characters.
    """
    a, b = proxy_id.lower(), catalogue_id.lower()
    return a == b or a.endswith("/" + b) or b.endswith("/" + a)


def candidates(catalogue, model_id):
    """Every (provider_id, model, catalogue_id) in models.dev naming this model."""
    out = []
    for provider_id, provider in catalogue.items():
        for catalogue_id, model in (provider.get("models") or {}).items():
            if not id_matches(model_id, catalogue_id):
                continue
            cost = model.get("cost") or {}
            # Subscription catalogues publish all-zero costs (e.g.
            # zai-coding-plan). They are true for a flat-rate plan but make
            # per-token accounting useless, so they only win when nothing else
            # lists the model.
            if not cost.get("input") and not cost.get("output"):
                continue
            out.append((provider_id, model, catalogue_id))
    return out


def rank(entry, model_id):
    """ccusage's tie-break, but ordered by FIRST_PARTY position, not alphabet.

    Membership alone is not enough once the list holds several vendors: with an
    alphabetical final key `alibaba` outranked `zai` for glm-5.2 and priced a
    Z.ai model off Alibaba's sheet (cache read 0.28 against the real 0.26).
    Position makes the list an explicit preference order, so each model lands on
    the vendor that actually builds it. An id that matches exactly beats one
    matched only by suffix.
    """
    provider_id, model, catalogue_id = entry
    cost = model.get("cost") or {}
    try:
        first_party_rank = FIRST_PARTY.index(provider_id)
    except ValueError:
        first_party_rank = len(FIRST_PARTY)
    return (
        # Vendor identity outranks string exactness: the sheet that prices a
        # model correctly is its maker's, whether or not the maker happens to
        # spell the id without a vendor path. Exactness only breaks ties inside
        # one provider tier.
        first_party_rank,
        0 if catalogue_id.lower() == model_id.lower() else 1,
        0 if "cache_read" in cost else 1,
        0 if "cache_write" in cost else 1,
        provider_id,
    )


def lookup_keys(model_id, routed):
    """Lookup keys for one proxy id: the published id first, then the upstream
    id behind it, then the deployment-tag-stripped id.

    One home for the key order: the sync and the drift check must ask the
    source the same question, or their answers are about different models.
    """
    keys = [ALIASES.get(model_id, model_id)]
    for extra in (routed.get("name"), DEPLOYMENT_TAG.sub("", model_id)):
        if extra and extra.lower() not in (k.lower() for k in keys):
            keys.append(extra)
    return keys


def price_match(catalogue, keys):
    """Ranked candidates for the first key that names the model, else [].

    The sync prices a model iff this is non-empty, so the drift check asking
    the same question of the same source is what makes "the source could
    have priced it" mean exactly what the sync does — not an approximation
    that could drift from it.
    """
    for key in keys:
        found = sorted(candidates(catalogue, key), key=lambda e: rank(e, key))
        if found:
            return found
    return []


def to_model_costs(cost):
    """models.dev cost record -> Claude Code's ModelCosts (USD per 1M tokens).

    Only the standard tier is taken. models.dev also carries `tiers` /
    `context_over_200k` for the long-context meters (grok-4.5 doubles at 200K,
    gpt-5.6 at 272K), but Claude Code's ModelCosts has no tier concept — one
    flat rate per model — so long-context requests are under-counted. That is
    a far smaller error than the $5/$25 fallback it replaces.
    """
    inp = float(cost["input"])
    out = float(cost["output"])
    cache_write = cost.get("cache_write")
    cache_read = cost.get("cache_read")
    return {
        "inputTokens": inp,
        "outputTokens": out,
        # Most non-Anthropic providers do not bill cache creation separately;
        # where they do (OpenAI charges 1.25x input) models.dev carries it.
        "promptCacheWriteTokens": float(cache_write) if cache_write else inp,
        "promptCacheReadTokens": float(cache_read) if cache_read is not None else inp,
        # Server-side web search is not billed per request on these providers,
        # and Claude Code's $0.01 default would silently inflate the total.
        "webSearchRequests": 0.0,
    }


def proxy_catalog_line(catalogued):
    """The catalogue denominators line — one home for sync and drift output.

    Every quantity names itself: raw records (every model row the file
    carries, both provider shapes, before the skip filter and the dedup) is
    the file's size, unique published names is what the sync keys on, and
    neither may hide behind a bare "(N models)" again — the two counts
    measured 682 against 626 on the same file (#53) and looked like one
    number that disagreed with itself.
    """
    stats = getattr(load_proxy_catalogue, "last_stats", None)
    if catalogued:
        return (f"Proxy catalog <- {PROXY_CATALOGUE_PATH} "
                f"(records {stats['records']}, providers {stats['providers']}, "
                f"enabled {stats['enabled']}, "
                f"unique published names {len(catalogued)})")
    return f"Proxy catalog <- absent, skipped ({PROXY_CATALOGUE_PATH})"


def check_drift(config):
    """Read-only drift predicate (#53): the LIVE proxy listing vs stored rows.

    RED is a name the proxy serves right now that lacks a price or a window
    row the sync COULD have written — the source knows the model, so the
    stored rows are stale, and every session through that model bills at the
    $5/$25 fallback and compacts at a 200K default. A name the source cannot
    price (or window) is YELLOW: counted, never red, because an invented
    price is worse than a missing one — the sync leaves those rows out on
    purpose, and a tooth that painted them red would be a tooth on a
    decision, not on drift. The proxy's catalogue file and its live listing
    are DIFFERENT sources (measured 17.09: of 10 served names only 3 were
    enabled catalogue entries), so their disagreement is printed as a fact
    about the configuration and never colours the verdict. Nothing here
    writes: not the config, not the seen-roster, not the fetch cache.
    """
    try:
        live_ids = proxy_model_ids()
    except Exception as error:
        print(f"ERROR: cannot reach the proxy: {error}", file=sys.stderr)
        return 2
    catalogued = load_proxy_catalogue()
    print(proxy_catalog_line(catalogued))
    # The source catalogue decides red vs yellow; without it the two are
    # indistinguishable, and an unmeasured predicate must not answer green.
    try:
        catalogue, _ = fetch_catalogue()
    except Exception as error:
        print(f"ERROR: cannot reach {MODELS_DEV_URL} ({error}); red vs yellow "
              "is unmeasurable, refusing to answer", file=sys.stderr)
        return 2
    if not isinstance(config, dict):
        print("ERROR: ~/.claude.json does not hold a JSON object; nothing to "
              "compare the live list against", file=sys.stderr)
        return 1
    prices = config.get("customModelCosts") or {}
    windows = config.get("customModelContextWindows") or {}
    red_price, red_window = [], []
    yellow = {}
    for model_id in live_ids:
        routed = catalogued.get(model_id) or {}
        found = price_match(catalogue, lookup_keys(model_id, routed))
        window = context_window(model_id, found[0][1] if found else None, routed)
        price_gap = model_id not in prices
        window_gap = model_id not in windows
        priceable = bool(found)
        windowable = window is not None and window > 0
        if price_gap and priceable:
            red_price.append(model_id)
        if price_gap and not priceable:
            yellow.setdefault(model_id, []).append("price")
        if window_gap and windowable:
            red_window.append(model_id)
        if window_gap and not windowable:
            yellow.setdefault(model_id, []).append("window")
    missing_price = [m for m in live_ids if m not in prices]
    missing_window = [m for m in live_ids if m not in windows]
    print(f"Live list <- {PROXY_MODELS_URL}: {len(live_ids)} served names, "
          f"without price row: {len(missing_price)}, "
          f"without window row: {len(missing_window)}, "
          f"not in source: {len(yellow)}")
    for model_id in red_price:
        print(f"  RED {model_id}: served live, no price row (the source prices it)")
    for model_id in red_window:
        print(f"  RED {model_id}: served live, no window row (a window is derivable)")
    for model_id, kinds in sorted(yellow.items()):
        print(f"  YELLOW {model_id}: not in source for {' and '.join(sorted(kinds))}; "
              "left without a row on purpose")
    enabled_catalogue = {name for name, entry in catalogued.items()
                         if entry.get("enabled")}
    only_catalogue = sorted(enabled_catalogue - set(live_ids))
    only_live = sorted(set(live_ids) - enabled_catalogue)
    print(f"Catalogue/live discrepancy (a fact about the configuration, not a "
          f"verdict): enabled in the catalogue but not served: "
          f"{len(only_catalogue)} ({', '.join(only_catalogue)}); "
          f"served but not enabled in the catalogue: {len(only_live)} "
          f"({', '.join(only_live)})")
    red = sorted(set(red_price) | set(red_window))
    print(f"Drift verdict: red {len(red)}, not in source {len(yellow)}")
    if red:
        print("ERROR: stored rows are stale for models the proxy serves right "
              "now; re-run the sync", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    try:
        path = config_path()
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    # Read-only modes go first and touch nothing: no sweep, no lock, no files
    # (--show keeps priority because it is the older, narrower reader).
    try:
        with open(path, encoding="utf-8") as fh:
            config = json.load(fh)
    except FileNotFoundError:
        print(f"ERROR: {path} not found; nothing written", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"ERROR: {path} unreadable ({error}); nothing written", file=sys.stderr)
        return 1
    if not isinstance(config, dict):
        print(f"ERROR: {path} no longer holds a JSON object; nothing written", file=sys.stderr)
        return 1

    if "--show" in sys.argv:
        print(json.dumps({
            "customModelCosts": config.get("customModelCosts", {}),
            "customModelContextWindows": config.get("customModelContextWindows", {}),
        }, indent=2))
        return 0

    if "--check-drift" in sys.argv:
        try:
            return check_drift(config)
        except SettingsUnreadable as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2

    print(f"Proxy models  <- {PROXY_MODELS_URL}")
    try:
        live_ids = proxy_model_ids()
    except Exception as error:
        print(f"ERROR: cannot reach the proxy: {error}", file=sys.stderr)
        return 1

    # Models get toggled on and off at the proxy, so its current listing is a
    # snapshot, not the roster. Pricing only what is live would drop a model's
    # entry the moment it is switched off and silently return it to the $5/$25
    # fallback when it comes back. Instead the roster only ever grows: every id
    # seen here, everything the proxy's own catalogue knows how to route, and
    # everything already priced in the config. The catalogue is what makes this
    # work AHEAD of first use — a model switched on for the first time is
    # already priced and already metered, instead of billing at the fallback
    # until someone re-runs this. `--prune` is the explicit way to drop what is
    # really gone.
    catalogued = load_proxy_catalogue()
    print(proxy_catalog_line(catalogued))

    print(f"Price catalog <- {MODELS_DEV_URL}")
    try:
        catalogue, catalogue_source = fetch_catalogue()
    except Exception as error:
        print(f"ERROR: catalogue unavailable ({error}); nothing written", file=sys.stderr)
        return 1

    if "--dry-run" in sys.argv:
        # Read-only like --show/--check-drift: computes its answer under a
        # foreign fresh lock instead of refusing with rc 5. Read-only legs
        # never write, so the seen roster needs no lock here.
        try:
            return sync_config(path, live_ids, catalogued, load_seen(),
                               catalogue, catalogue_source, None)
        except SettingsUnreadable as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2

    lock = None
    try:
        # CONSTRAINT (Н3): the seen roster is read UNDER the lock, right
        # after it is held -- reading it before acquisition made this run's
        # save erase a parallel sync's ids.
        lock = acquire_config_lock(path)
        remembered = load_seen()
        return sync_config(path, live_ids, catalogued, remembered,
                           catalogue, catalogue_source, lock)
    except ConfigLockHeld as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 5
    except ConfigLockNotADirectory as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 5
    except ConfigLockLost as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 5
    except ConfigLockUnavailable as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 5
    except ConfigWriteFailed as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 6
    except SettingsUnreadable as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except BackupNameExhausted as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 3
    finally:
        if lock is not None:
            lock.stop()
            lock.release()


def sync_config(path, live_ids, catalogued, remembered, catalogue, catalogue_source,
                lock=None):
    # Lost update: the config was read IN FULL before the network phase
    # (proxy + models.dev, tens of seconds), while a live Claude Code session
    # writes to ~/.claude.json more often than that — flushing the stale
    # object below erased its writes silently and completely. The kit knows
    # about the second writer (claude-patch-all.sh:96). So the file is re-read
    # after the LAST network fetch, and ONLY the two keys this tool owns are
    # applied to the FRESH object; everything else comes from that fresh read.
    # If the re-read fails (file gone, unparseable), refuse with the reason
    # and write nothing.
    # The roster's owned-keys part is likewise derived from THIS object, not
    # from the pre-network read: a model added to customModelCosts while the
    # network phase ran was priced by nobody here, and the wholesale replace
    # below would erase it silently — the roster moves with the re-read, so
    # such a model is priced and rewritten instead of dropped.
    # CONSTRAINT: hold the product's config lock across this read and publication.
    try:
        with open(path, encoding="utf-8") as fh:
            config = json.load(fh)
    except FileNotFoundError:
        print(f"ERROR: {path} disappeared while this tool was syncing; "
              "nothing written", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"ERROR: {path} no longer parses ({error}); nothing written",
              file=sys.stderr)
        return 1
    if not isinstance(config, dict):
        print(f"ERROR: {path} no longer holds a JSON object; nothing written",
              file=sys.stderr)
        return 1

    reply_headroom()
    if "--prune" in sys.argv:
        roster = sorted(live_ids)
    else:
        roster = sorted(set(live_ids) | remembered | set(catalogued)
                        | set(config.get("customModelCosts") or {}))

    costs, windows, unpriced = {}, {}, []
    rows = []
    for model_id in roster:
        routed = catalogued.get(model_id) or {}
        found = price_match(catalogue, lookup_keys(model_id, routed))

        # A window is worth writing even with no price: an unpriced model still
        # has to compact at the right point, and that is the defect that breaks
        # a session rather than the bill.
        window = context_window(model_id, found[0][1] if found else None, routed)
        if window is not None and window <= 0:
            print(f"  refusing nonpositive context window for {model_id}: "
                  f"window={window}, reply_headroom={reply_headroom()}")
        elif window:
            windows[model_id] = int(window)
        if not found:
            unpriced.append(model_id)
            continue
        provider_id, model, catalogue_id = found[0]
        costs[model_id] = to_model_costs(model.get("cost") or {})
        note = f"via {catalogue_id}" if catalogue_id.lower() != model_id.lower() else ""
        rows.append((model_id, provider_id, costs[model_id], windows.get(model_id), note,
                     model_id in live_ids))

    for model_id, provider_id, c, window, note, live in rows:
        ctx = f"{window // 1000}K ctx" if window else "no ctx"
        mark = " " if live else "·"  # "·" = priced but not currently served
        print(
            f" {mark}{model_id:<24} {c['inputTokens']:>6}/in {c['outputTokens']:>6}/out "
            f"{c['promptCacheReadTokens']:>6}/cache-read {ctx:>9}  [{provider_id}] {note}"
        )
    offline = [r[0] for r in rows if not r[5]]
    if offline:
        print(f"\n  · = priced and metered, not served right now ({len(offline)})")
    if unpriced:
        print(f"\n  not in models.dev, left on Claude Code's fallback price ({len(unpriced)}):")
        for model_id in unpriced:
            window = windows.get(model_id)
            metered = f"{window // 1000}K ctx from the proxy catalogue" if window else \
                "no window either — full fallback"
            print(f"    {model_id:<32} {metered}")
        print("  (`/cost` flags any session that used them as possibly inaccurate)")

    if "--dry-run" in sys.argv:
        print("\n--dry-run: nothing written")
        return 0

    def empty_replacement_refused(key, replacement, found_name):
        previous = config.get(key) or {}
        if previous and not replacement:
            print(f"ERROR: refusing empty {key} replacement: roster={len(roster)}, "
                  f"{found_name}={len(replacement)}, catalogue={catalogue_source}; "
                  "nothing written and no backup taken", file=sys.stderr)
            return True
        return False

    if empty_replacement_refused("customModelCosts", costs, "prices"):
        return 1
    if empty_replacement_refused("customModelContextWindows", windows, "windows"):
        return 1

    # The .NN name space is checked BEFORE the staging part exists: a refused
    # sync leaves nothing behind but the lock lifecycle. The check is advisory
    # for the same second only — publication itself still walks the suffixes,
    # because a lockless rival can occupy names between here and the link.
    stamp = time.strftime('%Y%m%d-%H%M%S', time.gmtime())
    second_dst = f"{path}.backup.u{stamp}"
    for number in range(100):
        candidate = second_dst if number == 0 else f"{second_dst}.{number:02d}"
        if not os.path.exists(candidate):
            break
    else:
        raise BackupNameExhausted(f"backup name space exhausted for {stamp}; nothing written")

    def still_owned():
        # CONSTRAINT: every publication write happens only while the lock is
        # verifiably ours; lock=None is the standalone caller (no sync, no
        # lock protocol), and the sync itself never passes None here.
        if lock is not None:
            lock.verify_owned()

    # Sweep only after every refusal: a refused sync must not even touch the
    # directory listing.
    still_owned()
    sweep_stale_temps(path)
    still_owned()

    # Replace wholesale rather than merge: a model that lost its models.dev
    # entry should fall back rather than keep a price nobody can trace.
    # (Wholesale applies to the two OWNED keys above, not to the rest of the
    # config — that now arrives from the fresh re-read.)
    config["customModelCosts"] = costs
    config["customModelContextWindows"] = windows

    # The backup is taken from the FRESH state: what is on disk right now is
    # what a rollback would need to restore, not the snapshot from before
    # the network phase.
    if lock is not None:
        lock.touch()
    backup = publish_backup(path, lock=lock)
    still_owned()

    # Write via a temp file in the same directory so a crash cannot truncate the
    # live config, and rename over it.
    write_json_atomically(path, config, lock=lock, indent=2, ensure_ascii=False)

    print(f"\nBacked up -> {backup}")
    print(f"Wrote customModelCosts ({len(costs)} models) -> {path}")
    print(f"Wrote customModelContextWindows ({len(windows)} models) -> {path}")
    side_files = []
    if catalogue_source == "network" and catalogue:
        side_files.append((CACHE_PATH, lambda: write_json_atomically(
            CACHE_PATH, catalogue, lock=lock)))
    side_files.append((SEEN_PATH, lambda: save_seen(
        remembered | set(live_ids), lock=lock)))
    result = 0
    for side_path, write in side_files:
        still_owned()
        try:
            write()
        except ConfigLockLost:
            # CONSTRAINT: a side file refused because the LOCK was lost is a
            # named rc-5 refusal, not a side-file warning (rc 4); the generic
            # handler below must not swallow it.
            raise
        except Exception as error:
            print(f"WARNING: config written; side file {side_path} not written: {error}",
                  file=sys.stderr)
            result = 4
    return result


if __name__ == "__main__":
    sys.exit(main())
