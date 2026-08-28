# Round 22, lens H — fresh-eyes audit

- **Repo:** `/Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch`
- **HEAD:** `ef50972` (`волна 24: атомарность записи и одновременность инструментов`)
- **Lens:** H1 external input; H2 time. Bodies of the 117 checks, write atomicity, and concurrent-tool races are out of scope (R20/R21).
- **Mode:** read-only. No kit build, no writes under `~/.tweakcc` / `~/.claude` / `~/.local/share/claude`. Small probes only: pathlib join, `corpus-list` regexes, `find -mtime +0` on a future stamp, `seq 1 0` on Darwin, `context_window` arithmetic.
- **Method:** every claim below is from the named file:line, not from another document that describes it.

---

## Answers to the six attacking questions

### Q1. `dist.integrity` — skip path or comparison of the wrong object?

`download_binary` always calls `_verify_tarball` after `r.read()`:

```195:203:/Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch/claude_patch.py
def download_binary(version: str, dest: Path) -> None:
    ...
    with urllib.request.urlopen(tarball, timeout=600) as r:
        blob = r.read()
    _verify_tarball(blob, meta.get("dist", {}), f"{pkg}@{version}")
```

No skip inside that function for `--update`, a re-fetch, or an already-present dest: the dest is written only after the digest check. `--download-only` (the pipeline's install path) always goes through this. `tools/fetch-corpus.sh` also goes through this for a network fetch.

**Three doors do not call `download_binary` and therefore do not check `dist.integrity`:**

1. **`--update` when the named file already carries `ROUTING_MARKER`** (`claude_patch.py:641-644`): no download, no digest, launcher is repointed. The check is "our patch bytes are present", not "these are the registry bytes of this version". A file that still has the marker after a swap, a truncate-after-marker, or a copy of some other patched build, is accepted.
2. **`tools/fetch-corpus.sh:221-227` when the on-disk image is non-empty and the pin is not `-`:** skip fetch if `sha256_of(dst) == pin`. This compares the *extracted binary* to the *recorded pin of that binary*, not the tarball to `dist.integrity`. That is the right object for a pin, provided the pin was born from registry bytes (the filler's own rule).
3. **`resolve_active_binary` / default `claude_patch.py` with no args:** pick a file under `versions_dir()` by max `st_mtime`. No digest at all.

Inside `_verify_tarball` itself: if `integrity` is present it is the only check (no fall-through to `shasum`); if it is absent, `shasum` (sha1); if neither, refuse. Algorithm is `integrity.partition("-")` then `hashlib.new(alg, blob)` — no allow-list (finding H-7). Digest is over the tarball bytes against the digest in the *same* registry JSON (TOFU; see adjudications).

### Q2. `tools/corpus-list.py` — every accepted form, and one that should have been a refusal

The parser is the whole of `main()` (`corpus-list.py:42-102`). Line loop: `io.open(..., encoding='utf-8')`; `\r` stripped; `\n` rstripped; then either a platform line or a data line.

**Accepted (complete list, by recount of the loop, not a sample):**

| Form | Rule |
|---|---|
| Platform line | `^#\s*platform:\s*(\S+)\s*$`. May appear any number of times; **the last one wins**. Compared to `claude_patch.npm_platform_pkg()`. |
| Blank | after `re.sub(r'#.*', '', line).strip()`, empty → skip |
| Comment | `#...` that is not a platform line → empty after strip → skip |
| Data | exactly 3 fields after `#`-tail strip, split on any whitespace |
| label | **no form check** (any non-whitespace token) |
| version | `^[0-9][0-9.]*$` (`match`, not `fullmatch`; safe only because the line was rstripped) |
| pin | `-` or `^[0-9a-fA-F]{64}$`; then `.lower()` |

**Refused:** argc ≠ 1 (code 2); missing file (2); `claude_patch` import/platform failure (2); field count ≠ 3; version not in `VERSION`; pin neither `-` nor 64 hex; duplicate label; duplicate version; no platform line; platform ≠ this machine; zero data rows. Partial stdout is not produced (`rows` are written only after the loop).

**Version tokens that pass `VERSION` and should not (probe, Python 3 `re.match`):** `2.`, `2..1`, `2.1.250.`, `09.1`, `0`, `1`. Letters, `-beta`, leading `v` are refused. Downstream `corpus_file_name` becomes `<token>.pristine`; npm `/{version}` typically 404s, so this is a late refusal with a confusing name, not a green lie.

**Form that parses and is then interpreted wrongly (not a refusal at the format door):**

A label containing `:` — e.g. `250:extra 2.1.250 <64 hex>`.

`corpus-list.py` emits `250:extra\t2.1.250\t<pin>` (tab-separated, internally correct). `tools/fetch-corpus.sh` reads TSV and is fine. `tools/sweep.sh:368-370` re-encodes as `label:version:pin` and later splits on `:`:

```437:439:/Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch/tools/sweep.sh
src_of() { printf '%s/%s' "$CORPUS" "$(corpus_file_name "$1")"; }
ver_of() { local rest="${1#*:}"; printf '%s' "${rest%%:*}"; }
pin_of() { printf '%s' "${1##*:}"; }
```

Probe of that join: label `250:foo`, version `2.1.250` → sweep's `ver_of` is `foo`, `src_of` looks for `foo.pristine`, `entry%%:*` (the "label" used in logs and CLI matching) is `250`. That is a wrong pairing. On the current `tools/corpus-versions.txt` every label is digits-only, so this is latent. A green measurement of the wrong bytes is unlikely (missing file / pin mismatch / `Version: foo` smoke all refuse), but the format home promised that a parsed line *is* (label, version, pin), and the sweep — the other of the two declared consumers — does not preserve that triple. The refusal, when it happens, names the wrong file.

No other accepted form was found that silently substitutes one version's bytes for another's. See finding H-4.

### Q3. Age weeding vs a future stamp, vs a live pid that is not ours

Wall clock everywhere (`time.time()` / `st_mtime` / `find -mtime`). Watcher cadence in the image is monotonic (`__ccMono`); these weeders are not.

**`judge/compact.py` — records (`--older-than-hours`, default 24) and tmp (`TMP_HELD_SECONDS = 24 * 3600`):**

- Record `*.json` with **future mtime**: `mtime > cutoff` (`cutoff = now - N*3600`) is true → `skipped`. Never compacted. Disk leak of uncompressed records.
- Record with live/dead pid: json names carry no pid; not applicable.
- Tmp `*.json.gz.tmp.<pid>` with **dead pid**: unlinked after inode+mtime_ns check, **including future mtime** (age is not consulted on the dead-pid arm).
- Tmp with **live pid** (ours or someone else's; `PermissionError` counts as live): `age = now - mtime`; future → negative age → `age < TMP_HELD_SECONDS` → held. **Held forever** until the pid dies or the clock catches up.
- Tmp with **live pid and age ≥ 24 h**: deleted even though the process is alive. Documented as "a writer hung for a day is already broken". A live compact of another user is `PermissionError` → held. Same-user stranger with a reused number past 24 h: deleted.

**`tools/checks-teeth.py` — `WORKER_TMP_HELD_SECONDS = 6 * 3600`, glob `checks-teeth.[0-9]*.*.bin`:**

- `alive and (now - mtime) < 6h` → keep. Future + live pid → negative age → **keep forever**.
- Dead pid → delete regardless of future stamp (same as compact's dead-pid arm).
- Live stranger + age ≥ 6 h → **delete**. Shorter than compact's 24 h. Two teeth runs share the lock (`LOCK_SH`), so a second run may reap the first's worker file once it is 6 h old.

**Sweep debris (`tools/sweep.sh:286-290`) — `find ... -maxdepth 0 -mtime +0` then `rm -rf`:**

- Probe on this Darwin: a file with mtime **7 days in the future** is **not** selected by `-mtime +0`; a file 2 days in the past is. Future kit / `sweep.self.*` debris is **never** reaped.
- **No pid check at all.** Comment: a live sweep holds the lock, so anything older than a day belongs to a run that is gone. That is false for descendants of a SIGKILL'd sweep (the reason the kit snapshot exists): they do not hold `sweep.lock`. After 24 h the next sweep `rm -rf`s the snapshot from under them.
- `find` failure (`2>/dev/null` empty) → skip delete. Fail-safe.

Benches (`tools/judge-tools-bench.py`, `tools/corpus-tools-bench.sh`) stamp files *into the past* (`time.time() - 3600`, `- 48*3600`). Grep of those two files plus `checks-teeth.py` for `future` / clock-ahead: no case. The future arm is untested.

### Q4. Line-oriented parsing of someone else's program

Recount of parsers that assume a column layout (not "the tool exists"):

| Site | Command | Assumption | Empty / space / newline |
|---|---|---|---|
| `claude-patch-all.sh:5297-5298` | `lsof -p "$p" \| awk '$4=="txt"{print $NF}'` | FD is field 4, NAME is last field and has no spaces | Empty IN_USE ≡ "nothing in use" → `rm`. Path with a space: `$NF` is the last word (probe: `/Users/John Doe/.../2.1.226` → `Doe/.../2.1.226`). `grep -qxF "$old"` misses, **unlinks a binary a live session is executing**. `2>/dev/null` on lsof: a failing lsof is the same empty. Tools-missing is refused (`:5293-5295`); tools-present-but-silent is not. Finding H-1. |
| `tools/sweep.sh:97-99`, `:310-315` | `ps -eo pid,args` then awk `$1` / `index($0, here)` | pid is field 1; kit path appears in the displayed args | Header line does not contain `here` → skip. Truncated `args` (false negative) → kit snapshot removed while still in use. Path is short (`$STATE/kit.XXXXXX`), so truncation is unlikely; not raised. |
| `tools/sweep.sh:468-472`, `fetch-corpus.sh:110-114`, `claude-patch-all.sh:649` | `shasum -a 256` / `sha256sum` \| `awk '{print $1}'` | first field is the hex digest | Empty stdout → explicit refusal ("не прочитать"). Standard BSD/GNU format puts the hash first. Not raised. |
| `tools/sweep.sh:504-506` | `git status --porcelain` | any output ⇒ dirty | Failure is `2>/dev/null` and treated as clean. Does not parse columns; newline-in-filename is quoted by git and still non-empty. Weak; see "not raised". |
| `claude-patch-all.sh:414` | `ls -t ~/.claude.json.backup.* \| while read -r f` | one name per line, mtime order | Newline in a name splits into two names (they already closed this class for `prune_tweakcc_cache` by globbing 40-hex dirs). Future mtime sorts first and is kept; real older backups are deleted. Finding H-8. |
| `claude_patch.py:384-388` | `security find-identity` `line.split()`, `len(parts[1])==40` | hash is field 2 | Empty → ad-hoc sign with a warning. Fail-noisy. Not raised. |

### Q5. Reverse hole of gate 0d (a number in *code* that drifted from prose)

Gate 0d (`claude-patch-all.sh` `PYDOCS`, `OWNERS` at `:1145-1167`, `NOUNS` at `:1171-1180`) binds prose to three quantities only: **checks, scenarios, mutations**, and only when the owner is named. It does not watch seconds, hours, milliseconds, pin lengths, or fallback constants.

**Concrete drift it will never see:**

`judge/README.md:183` — «The shared default timeout is 60 seconds».

Shipped config is `probes/probes.toml:3` `timeout_ms = 240000` (240 s). Code fallback with no config is `tweakcc-patch.js:3066` `__num("timeout_ms", ..., 8000, 1)` (8 s). `docs/judge-architecture.md:289` states 240 s shipped / 8 s fallback and matches the code. `judge/README.md` is scanned by 0d (`.md`, not in `JOURNALS` / `docs/review/`) but «60 seconds» is not a checks/scenarios/mutations noun, so the gate is green.

That is the reverse hole: 0d is a census of *counter nouns*, not of *numbers that are promises*. Finding H-5.

### Q6. `set-model-costs.py` cache / wrong shape / no network

| Condition | What happens |
|---|---|
| Partial write of the cache | `write_json_atomically` (tmp + fsync + `os.replace`). A reader never sees a half document. Leftover `*.tmp.<pid>` is not the cache path. |
| Cache present but not JSON / unreadable | `fetch_catalogue` (`:298-309`): print «cache is unreadable too», **re-raise the original network error**. Refusal. No write of costs. |
| No network, no cache | Re-raise. Refusal. |
| No network, cache readable | Print age in hours, **return cached object**. Old data, not an empty set. **No maximum age.** Future mtime → negative hours printed, still used. Finding H-6. |
| HTTP 200, JSON object of the wrong shape (`{}`, `{provider: {}}`, providers with no `models`) | `candidates()` returns `[]` for every id (`:399-414`). All models go to `unpriced`. Then wholesale `config["customModelCosts"] = costs` with `costs={}` (`:624`). **Wipe of live prices.** Empty-but-valid is not distinguished from «models.dev has nothing». Finding H-2. |
| HTTP 200, non-object / HTML | `json.load` fails → cache or raise. Refusal. |
| `save_seen` | Runs **before** `fetch_catalogue` (`:511-516`). A later crash in the catalogue walk still persists the seen-roster. Costs are not written (write is at the end). |

---

## Findings

### H-1. высшая — live-session binary deleted when `lsof` is empty or NAME has a space

**Where:** `claude-patch-all.sh:5293-5315` (cleanup of previous versions after `--update`).

**What the comment promises:** do not unlink a binary a live session is executing; without `pgrep` and `lsof` refuse to delete on a guess (`:5285-5295`). That refuse arm is only `command -v`.

**What actually holds:**

```5297:5315:/Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch/claude-patch-all.sh
    IN_USE="$(for p in $(pgrep -x claude 2>/dev/null); do
        lsof -p "$p" 2>/dev/null | awk '$4=="txt"{print $NF}'
      done | sort -u)"
    for old in "$VERSIONS_DIR"/2.1.*; do
      ...
      if grep -qxF "$old" <<<"$IN_USE"; then
        echo "  kept (a running session is executing it): $base"
        continue
      fi
      ...
      rm -v "$old"
```

**Concrete inputs that delete the running image:**

1. `lsof -p` fails or prints nothing (`2>/dev/null`): `IN_USE` empty. Empty ≡ not in use. `rm` runs. This is the same «cannot be answered» the missing-tool arm claims to refuse, reached through a different door.
2. Install path contains a space. Probe of awk's field split on a typical `lsof -p` line: NAME `/Users/John Doe/.local/share/claude/versions/2.1.226` → `$NF` = `Doe/.local/share/claude/versions/2.1.226`. `grep -qxF "$old"` against the real path misses. `rm -v` of `2.1.226` proceeds. The comment at `:5282-5284` is the previous payment for this class (`lsof -c claude` was empty on Darwin; they switched to `lsof -p` and left `$NF`).

**Why existing benches do not catch it:** `tools/build-path-probe.sh` covers `--update` staging and CLI doors, not the post-success cleanup's `IN_USE` parser. `tools/corpus-tools-bench.sh` drives the sweep, which uses `--target` and never enters this block (`DO_UPDATE` is 0). No mutation of an `lsof` line with a space in NAME.

### H-2. высокая — models.dev HTTP 200 with an empty-shaped object wipes `customModelCosts`

**Where:** `set-model-costs.py:399-414` (`candidates`), `:558-625` (roster walk + wholesale replace).

**What is promised:** on network failure, use cache or refuse; a model that *lost its models.dev entry* should fall back rather than keep an untraceable price (`:620-623`).

**What actually holds:** `candidates()` does `for provider_id, provider in catalogue.items()` then `(provider.get("models") or {}).items()`. A 200 body `{}`, or `{ "openai": {} }`, or any object whose values have no `models` / no non-zero costs, yields `found=[]` for every roster id. `costs` stays `{}`. Then:

```624:625:/Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch/set-model-costs.py
    config["customModelCosts"] = costs
    config["customModelContextWindows"] = windows
```

That is a wipe of the live billing table — the exact `$5/$25` fallback this tool exists to prevent. «Unpriced» is printed, then the empty dict is still written. There is no «catalogue had at least one priced model» gate and no merge-with-previous-on-empty.

**Concrete input:** HTTP 200, `Content-Type: application/json`, body `{}` (CDN/WAF empty JSON, a shape change that wraps the catalogue, a truncated-but-parseable object). Cache is *not* used: the `except` arm of `fetch_catalogue` is only for transport/`json.load` failure.

**Why benches do not catch it:** no test of `fetch_catalogue` / `candidates` against a fixture body. The pipeline's model sync is skipped under `CLAUDE_PATCH_SKIP_MODELS=1` on the sweep (`sweep.sh:827`), so a wipe would not even show up as a red version.

### H-3. высокая — `routed - reply_headroom()` can be negative and is written

**Where:** `set-model-costs.py:189-191`, consumed at `:580-581`.

```189:191:/Users/maratkarimov/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch/set-model-costs.py
    if routed:
        return routed - reply_headroom()
```

`reply_headroom()` is `max(0, CLAUDE_CODE_MAX_OUTPUT_TOKENS - 20_000)` from `~/.claude/settings.json`. The comment at `:156-158` names 96_000 as a real setting (headroom 76_000).

**Probe** (same function, `reply_headroom` stubbed to 76000): `context=32000` → **`-44000`**, `bool(window)` is True, `int(window)` is `-44000`. Then `if window: windows[model_id] = int(window)` writes it.

`if window` is the only gate; it rejects `0`/`None` and **accepts every negative**. External inputs in the subtraction: proxy catalogue `context-length`, `[N k/m]` deployment tags, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`. A 32K/64K model plus the documented 96K output cap is enough.

**Why benches do not catch it:** no unit of `context_window`. Gate 0d does not watch these constants.

### H-4. средняя — version and label from outside become paths / join keys without a form check

**(a) Version as a filesystem path — `claude_patch.py:148-150`, `:571-572`, `:639-640`.**

`latest_version()` returns `tags["latest"]` from the registry with no `VERSION` check. `--update` / `--download-only` do `target = versions_dir() / version`. Probe:

- `version='/tmp/evil'` → dest is `/tmp/evil` (`Path / abs` replaces the base on POSIX).
- `version='../bin/claude'` → `.../versions/../bin/claude`.

The write still needs `download_binary` to obtain a tarball (npm 404s on most garbage), so a confused operator `--update /tmp/foo` usually dies on HTTP. A registry (or a MITM that already forges `dist.integrity`) that sets `latest` to an absolute path gets a write *outside* `versions_dir`. That is more than «they can already give you a bad binary»: it is a dest the rest of the kit does not expect to be an image.

`tools/corpus-list.py` *does* restrict version to `[0-9][0-9.]*` for the corpus list. The installer CLI and `latest` tag do not reuse that rule.

**(b) Label with `:` — see Q2.** `corpus-list.py:70-74` accepts it; `sweep.sh:368-439` cannot round-trip it. Current `tools/corpus-versions.txt` labels are `233`/`240`/… so latent.

**Why benches do not catch it:** `tools/corpus-tools-bench.sh` builds lists with numeric labels and `0.0.900`-style versions. No case with `:` in the label, no case of `--update` with a non-semver `latest`.

### H-5. средняя — default judge timeout in `judge/README.md` is not the shipped value; 0d cannot see it

**Where:** `judge/README.md:183` «The shared default timeout is 60 seconds» (example JSON at `:175` has `"timeout_ms": 60000`).

**What holds:** `probes/probes.toml:3` `timeout_ms = 240000`. Fallback in the image: `tweakcc-patch.js:3066` `8000` ms. `docs/judge-architecture.md:289` matches the code.

Gate 0d's `NOUNS` are only checks/scenarios/mutations (`claude-patch-all.sh:1171-1180`). A drifted *second count* in a scanned `.md` is green. This is the reverse hole Q5 asked for: a number in prose that is a real promise, diverged from the constant that implements it, and the number gate is structurally unable to notice.

**Why the teeth of 0d do not catch it:** `tools/docnum-mutations.tsv` mutates owner constants and counter nouns, not `timeout_ms` / «seconds».

Related H2 (not a separate finding): `__num("timeout_ms", ..., 8000, 1)` (`tweakcc-patch.js:2303-2308`, min=1) treats `0` and `""` as «use 8 s», not «no timeout» and not «use the 240 s from toml». Empty `CLAUDE_JUDGE_TIMEOUT_MS` is falsy in the `||` at `:3066` and falls through to config; `"0"` is truthy, then rejected as `< min`, then 8000. Documented for missing config (8 s); not documented that an explicit 0 is 8 s.

### H-6. средняя — models.dev cache has no expiry; future mtime is still trusted

**Where:** `set-model-costs.py:298-303`.

On network failure a readable cache is used whatever its age. Age is printed (`{age_h:.0f}h old`) and not gated. Probe-equivalent: `age_h = (now - mtime) / 3600`; future mtime → negative hours, `json.load` still returns. A cache copied from another machine with a clock ahead, or left for months, is «models.dev» as far as the write is concerned.

**Why benches do not catch it:** no fixture of an old/future cache file.

### H-7. средняя — age weeders never reap a future stamp (live-pid arm); sweep debris has no pid check

Covered in Q3. The divergence is: comments say «older than a day belongs to a run that is gone» (`sweep.sh:284-285`), «tmp older than a day is not a healthy writer» (`compact.py:96-97`). Both are false when `mtime` is in the future: the live-pid / `find -mtime +0` arms keep the file forever. Clock step-back, a copy with `-p` from a machine ahead, or `touch` into next week, is enough.

Sweep's `find -mtime +0` + `rm -rf` without pid ( `:286-290` ) is the other half: a hung child of a killed sweep, 25 h later, loses its snapshot from under it. That is F-9 with a 24 h delay; the drain on *our* exit (`__drop_kit_when_idle`) does not protect *their* leftover.

**Why benches do not catch it:** past-mtime fixtures only (`judge-tools-bench.py:81`, `:941`).

### H-8. низкая — `prune_config_backups` still parses `ls -t`

**Where:** `claude-patch-all.sh:400-415`.

`prune_tweakcc_cache` (`:427-432`) documents why `ls` must not be the iterator (newline in a name deletes two *other* entries) and iterates a glob of 40-hex dirs. `prune_config_backups` counts with a glob then deletes with `ls -t ... | tail -n +4 | while read -r f`. Names are `~/.claude.json.backup.%Y%m%d-%H%M%S` from `set-model-costs.py:617` (no newline in the writer), so the newline split is latent. **Future mtime** on a backup makes `ls -t` keep it as «most recent» and drop a real older backup.

### H-9. низкая — `_verify_tarball` accepts any `hashlib.new` algorithm

**Where:** `claude_patch.py:168-179`.

`alg, _, b64 = integrity.partition("-")` then `hashlib.new(alg, blob)`. Probe: `hashlib.new("md5", ...)` works. A registry document that carries only `md5-<b64>` (or another algorithm Python ships) is accepted. npm today publishes `sha512-`; this is the door if that stops being true, or if a forged document omits sha512 and leaves a weak `integrity`. Unknown alg → `ValueError` → refuse. No comparison of the wrong object; comparison of a digest that is too cheap.

### H-10. низкая — Darwin `seq 1 0` is not an empty sequence

**Where:** `claude-patch-all.sh:5020` `for _ in $(seq 1 "$GATE_BUDGET"); do sleep 1`.

`GATE_BUDGET="${CLAUDE_PATCH_GATE_BUDGET:-150}"` (`:4995`). Empty env uses 150 (`:-`). **`GATE_BUDGET=0`:** probe on this Darwin, `seq 1 0` prints `1\n0\n` (BSD seq counts down). The loop runs **twice**, not zero times. README (`:348`) says the budget is «seconds the interface gate waits». 0 does not mean 0. Non-numeric (`abc`): `seq` rc=2, `set -euo pipefail` kills the run (noisy refuse). `SWEEP_LAST_N` is validated as a number (`sweep.sh:409-410`); `SWEEP_LOCK_BUDGET` / `GATE_BUDGET` / `SWEEP_KIT_DRAIN` are not.

`SWEEP_LOCK_BUDGET=0` is intentional (corpus-tools-bench uses it as «do not wait»). `SWEEP_LOCK_BUDGET=abc` under `set -u`: `(( waited >= LOCK_BUDGET ))` treats `abc` as a variable name → unbound → abort of the wait loop. Not a silent wrong wait; a crash at a door that `SWEEP_LAST_N` already learned to refuse with code 2.

---

## Adjudication requests

1. **TOFU on npm.** `_verify_tarball` checks the tarball against `dist.integrity` from the same JSON. A party that serves both the metadata and the bytes will always pass. I did not raise this as a finding: the kit's threat model for the registry is «detect a swap between registry and disk», not «the registry is hostile». `dist.tarball` is likewise not pinned to `https://registry.npmjs.org/` (any URL `urlopen` will fetch); same TOFU envelope.
2. **Fetch-corpus pin match without re-contacting npm.** Once a pin exists, on-disk bytes that match it are not re-hashed against a fresh `dist.integrity`. I treat this as the pin's job, not a skip of Q1's check.
3. **Live-pid + age ≥ threshold → delete** in `compact.py` / `checks-teeth.py`. Documented as the pid-reuse arm. I did not raise it; I did raise the future-mtime half of the same `if`, which those comments do not describe.
4. **Operator env as a path** (`CLAUDE_PROBES_DIR`, `CLAUDE_CONFIG_DIR`, `CORPUS_DIR`, `XDG_DATA_HOME`, `TMPDIR`, `CLAUDE_PATCH_LOCK`). No form check. I treat these as the operator's dest, not as untrusted input of the same class as npm JSON / `lsof` lines / `probes.toml` in a project tree.
5. **Project-layer `probes.toml` `filter.*` compiled with `new RegExp(__r)`** (`tweakcc-patch.js:2688`) with only try/catch around `.test`. The subject strings (`dispatch-class` token, `subagent_type`) are short, so a cheap-regex blow-up is bounded. I did not raise it; a project that can write that file can already set `enforce=false`. Flagged here because the lens asked about «into a regexp without a form check» and that is exactly this line.
6. **`__num` has no maximum.** `timeout_ms=1e15` would stall a consultation. Shipped default is 240 s; a project overlay can raise it. Same envelope as (5).
7. **`SWEEP_LOCK_BUDGET=0` means try once.** Tested (`corpus-tools-bench.sh:601`). Matches «seconds to wait» with wait=0. Not a finding.
8. **`SWEEP_KIT_DRAIN=0` still looks once.** Explicitly fixed (`sweep.sh:93-95`). Not a finding.
9. **`retry_context_chars: 0` disables the salvage rung.** `__num(..., 8000, 0)` (`tweakcc-patch.js:3263`); min=0, so 0 is kept. Matches `docs/judge-architecture.md:286`. Not a finding.
10. **Watcher cadence is monotonic** (`tweakcc-patch.js:2227`, `pre`/`gate` use `__ccMono`). Wall-clock jumps do not extend or skip `cooldown_min` / `window_min`. Not a finding under H2.

---

## Noticed and not raised (with why)

- **`download_binary` always verifies.** No in-function skip. The skips are callers that never call it (Q1). Raised only those callers (H-1 is a different door; `--update` already-patched is under Q1 and is weaker than H-1, folded into Q1 rather than a second high finding: the pipeline's `--update` uses `--download-only`, so the skip is the standalone installer).
- **`git status --porcelain 2>/dev/null` as clean-on-failure.** Marks a corrupt git as clean. The stamp is informational (`SWEPT_STATE`), not a gate. Weak.
- **`ps -eo pid,args` for kit drain / pipeline-alive.** `$1` as pid holds on Darwin for the header and for numeric pids. False negative on truncated args not demonstrated for this short path.
- **`sha256_of` / `sha_of` `awk '{print $1}'`.** Empty → refuse. Format on this Darwin is hash-first.
- **`EXPECTED_CHECKS = 117` vs README «117 checks».** 0d's actual subject; out of this lens if they match, and 0d would catch them if they don't. Not re-counted here (that is 0d's job; I did not re-run the gate).
- **`TMP_HELD_SECONDS` hardcoded 24 h vs `--older-than-hours`.** Tmp weeding does not follow the CLI flag. A run with `--older-than-hours 1` still holds tmp 24 h. Pedantic; the two clocks measure different objects (records vs writer debris).
- **`os.kill(0, 0)` if a tmp suffix is `0`.** Glob could match a crafted name. Not a writer-produced name (`os.getpid()` is never 0).
- **`record_pins` in `fetch-corpus.sh` is a second parser** (`split()`, `len >= 2`). It only *rewrites pins* of versions it already fetched after a `corpus-list.py` pass. Extra fields would be dropped on rewrite; `corpus-list` would have refused extras before the fetch. Residual lost-update of pins across two fillers is documented in the script itself (`:162-165`).

---

## Scope actually checked (zeros included)

| Address | What was opened / grepped | Result for this lens |
|---|---|---|
| `claude_patch.py` | full file (698 lines): download, integrity, version path, mtime picker, launcher tmp pid | Q1, H-4a, H-9 |
| `tools/corpus-list.py` | full file (107) | Q2, H-4b |
| `tools/corpus-versions.txt` | full file | labels are digits; no `:` in current list |
| `tools/corpus-file-name.sh` | full file | `'%s.pristine' "$1"` — no extra check |
| `tools/fetch-corpus.sh` | full file: lock, sha256_of, pin skip, record_pins, corpus-list consumer | Q1 pin-skip, Q2 TSV consumer |
| `tools/sweep.sh` | header, drain, stale `find -mtime +0`, ps-alive, corpus-list join, pin check, `kit_state` porcelain, `SWEEP_LOCK_BUDGET` wait | Q2 consumer, Q3, Q4, H-7, H-10 |
| `judge/compact.py` | full file (280) | Q3 |
| `tools/checks-teeth.py` | weeding + glob + pid (`:157-200`) | Q3 |
| `set-model-costs.py` | cache, candidates, context_window, wholesale write | Q6, H-2, H-3, H-6 |
| `claude-patch-all.sh` | lock, prune_config_backups, prune_tweakcc_cache, sha_of, EXPECT_SHA, GATE_BUDGET/seq, IN_USE lsof, PYDOCS owners/nouns | H-1, H-5, H-8, H-10 |
| `tweakcc-patch.js` | `__num` (`:2303`), timeout (`:3066`), retry half-clock (`:3280-3282`), filter RegExp (`:2688`), watcher minutes*`60000` (`:3448-3453`), `__ccMono` | Q5/H-5, adj. 5–10 |
| `probes/probes.toml` | `timeout_ms`, `cooldown_min`, `window_min`, `live_recheck_ms` | Q5, H2 units |
| `docs/judge-architecture.md:265-294` | timeout / retry claims vs code | README drift is H-5; architecture doc matches |
| `judge/README.md:170-190` | «60 seconds» | H-5 |
| `judge/channel.py` | timeouts via `urllib`/`subprocess.run(..., timeout=)` | pool/http refuse on timeout; no silent OK |
| `judge/adjudicate.py:110-120` | first-line parse of model text | `CORRECT:` / `WRONG:` / `UNSURE:`; unknown first line → None (not raised: fail-closed to «no decision», not «yes») |
| `tools/image-check.py` | header only (magic/product/completeness) | not a digest of registry bytes |
| `tools/docnum-bench.py` + PYDOCS OWNERS/NOUNS | what 0d can see | Q5 |
| `tools/judge-tools-bench.py`, `tools/corpus-tools-bench.sh` | grep for future-mtime / `lsof` NAME-with-space | **0 hits** for a future stamp; no lsof-space case |
| `docs/review/` | `findings-ledger.md` present; this file is new | — |

**Stopped at:** image-side `__ccProbe` TOML walk past the `__num`/filter/timeout sites (the rest of the 3.6k-line consumer is R20/R21 material). Did not re-run 0d, did not re-count `EXPECTED_CHECKS`, did not fetch models.dev or npm.

