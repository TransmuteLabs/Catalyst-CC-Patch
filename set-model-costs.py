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
"""

import json
import os
import re
import shutil
import sys
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


def reply_headroom():
    """Tokens a reply can add on top of what Claude Code already reserves.

    The declared window is not a prompt budget — Claude Code lets the prompt
    reach `window - 20_000` and then puts a reply of up to
    CLAUDE_CODE_MAX_OUTPUT_TOKENS on top. With that set to 96_000 the request
    can total `window + 76_000`, so declaring the model's full budget overshoots
    it by that much. Invisible at 1M, fatal at 200K where it is a 38% overrun.
    """
    try:
        with open(os.path.expanduser("~/.claude/settings.json"), encoding="utf-8") as fh:
            configured = int((json.load(fh).get("env") or {}).get(
                "CLAUDE_CODE_MAX_OUTPUT_TOKENS", 0) or 0)
    except Exception:
        configured = 0
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
    """
    cap = INPUT_CAP_OVERRIDES.get(model_id)
    if cap:
        return cap
    limit = (model or {}).get("limit") or {}
    routed = (catalogued or {}).get("context") or deployment_tag_window(model_id)
    if routed:
        return routed - reply_headroom()
    explicit_input = limit.get("input")
    if explicit_input:
        return explicit_input
    total = CONTEXT_OVERRIDES.get(model_id) or limit.get("context")
    return total - reply_headroom() if total else None


CACHE_PATH = os.path.expanduser("~/.cache/claude-model-costs/models-dev.json")

# Every model id ever seen on the proxy. The proxy's listing shows only what is
# switched on at that instant, so this file is what makes the roster survive a
# model being toggled off — see the roster comment in main().
SEEN_PATH = os.path.expanduser("~/.cache/claude-model-costs/seen-models.json")


def load_seen():
    try:
        with open(SEEN_PATH, encoding="utf-8") as fh:
            return set(json.load(fh))
    except Exception:
        return set()


def save_seen(ids):
    os.makedirs(os.path.dirname(SEEN_PATH), exist_ok=True)
    tmp = f"{SEEN_PATH}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(sorted(ids), fh, indent=2)
    os.replace(tmp, SEEN_PATH)


def fetch_json(url, timeout=30):
    # models.dev answers 403 to urllib's default User-Agent.
    request = urllib.request.Request(url, headers={"User-Agent": "claude-model-costs/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def fetch_catalogue():
    """models.dev, cached on disk so a network hiccup does not block a re-run."""
    try:
        catalogue = fetch_json(MODELS_DEV_URL)
    except Exception as error:
        if os.path.exists(CACHE_PATH):
            age_h = (time.time() - os.path.getmtime(CACHE_PATH)) / 3600
            print(f"  models.dev unreachable ({error}); using cache, {age_h:.0f}h old")
            with open(CACHE_PATH, encoding="utf-8") as fh:
                return json.load(fh)
        raise
    os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
    with open(CACHE_PATH, "w", encoding="utf-8") as fh:
        json.dump(catalogue, fh)
    return catalogue


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
    """
    try:
        with open(PROXY_CATALOGUE_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return {}
    out = {}
    for provider_id, rows in data.items():
        for row in rows or []:
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


def main() -> int:
    path = os.path.expanduser("~/.claude.json")
    if not os.path.exists(path):
        print(f"ERROR: {path} not found", file=sys.stderr)
        return 1

    with open(path, encoding="utf-8") as fh:
        config = json.load(fh)

    if "--show" in sys.argv:
        print(json.dumps({
            "customModelCosts": config.get("customModelCosts", {}),
            "customModelContextWindows": config.get("customModelContextWindows", {}),
        }, indent=2))
        return 0

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
    if catalogued:
        print(f"Proxy catalog <- {PROXY_CATALOGUE_PATH} ({len(catalogued)} models)")
    else:
        print(f"Proxy catalog <- absent, skipped ({PROXY_CATALOGUE_PATH})")

    remembered = load_seen()
    save_seen(remembered | set(live_ids))
    if "--prune" in sys.argv:
        roster = sorted(live_ids)
    else:
        roster = sorted(set(live_ids) | remembered | set(catalogued)
                        | set(config.get("customModelCosts") or {}))

    print(f"Price catalog <- {MODELS_DEV_URL}")
    catalogue = fetch_catalogue()

    costs, windows, unpriced = {}, {}, []
    rows = []
    for model_id in roster:
        routed = catalogued.get(model_id) or {}
        # Published id first, then the upstream id behind it: the proxy renames
        # freely, and the upstream id is the one models.dev is keyed on.
        keys = [ALIASES.get(model_id, model_id)]
        for extra in (routed.get("name"), DEPLOYMENT_TAG.sub("", model_id)):
            if extra and extra.lower() not in (k.lower() for k in keys):
                keys.append(extra)

        found, lookup = [], keys[0]
        for key in keys:
            found = sorted(candidates(catalogue, key), key=lambda e: rank(e, key))
            if found:
                lookup = key
                break

        # A window is worth writing even with no price: an unpriced model still
        # has to compact at the right point, and that is the defect that breaks
        # a session rather than the bill.
        window = context_window(model_id, found[0][1] if found else None, routed)
        if window:
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

    backup = f"{path}.backup.{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)

    # Replace wholesale rather than merge: a model that lost its models.dev
    # entry should fall back rather than keep a price nobody can trace.
    config["customModelCosts"] = costs
    config["customModelContextWindows"] = windows

    # Write via a temp file in the same directory so a crash cannot truncate the
    # live config, and rename over it.
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, path)

    print(f"\nBacked up -> {backup}")
    print(f"Wrote customModelCosts ({len(costs)} models) -> {path}")
    print(f"Wrote customModelContextWindows ({len(windows)} models) -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
