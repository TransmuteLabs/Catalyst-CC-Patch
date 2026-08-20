#!/usr/bin/env python3
"""
Version-independent, byte-neutral in-binary patch for Claude Code
(bun-compiled Mach-O; JS is plaintext-minified inside — strings readable,
identifiers minified and DRIFTING between releases).

Rather than hard-coded literal anchors (which break every release when the
minifier renames variables), every site is located by a STRUCTURAL REGEX that
keys on stable tokens (property names, string literals, keywords) and captures
the volatile minified identifiers. The reclaim that restores the original file
size is computed DYNAMICALLY, so the patch stays byte-neutral no matter how long
the captured identifiers are.

Four edits (net file-size delta forced to 0 so every bun offset and Mach-O
section boundary stays valid; only re-signing is needed afterwards):

  1. ROUTING  — inject `baseURL:/^claude/i.test(<model>)?"https://api.anthropic.com":void 0,`
     into the final firstParty client-options object of getAnthropicClient, so
     claude-* models hit the subscription endpoint and everything else falls
     back to process.env.ANTHROPIC_BASE_URL (the proxy). GROWS the file.
  2. RECLAIM  — shorten a rarely-hit gateway error string by exactly the number
     of bytes edits 1+3 added, so the net delta is 0.
  3. DISCOVERY — flip the ANTHROPIC_AUTH_TOKEN requirement in
     fetchGatewayModelOptions so the /model list populates from the proxy
     without a token. Nearly length-neutral (folded into the reclaim budget).
  4. ENUM     — relax the Agent tool's `model` zod enum (sonnet|opus|haiku|
     fable) to a free string so subagents accept external/proxy model IDs.
     Self-neutral (padded with spaces to the original length).

Idempotent: refuses to double-patch (routing marker is a constant literal).
"""
import re
import sys
import os

# Constant injected literal — identical across versions, so it doubles as the
# idempotency sentinel. Only <model> (the captured model identifier) varies.
BASEURL_TMPL = 'baseURL:/^claude/i.test(%s)?"https://api.anthropic.com":void 0,'
ROUTING_MARKER = b'baseURL:/^claude/i.test('

# Reclaim source: the gateway "token expired" error string. Stable English text.
# Stored as it appears in the bundle (literal backslash-u escape).
REC_OLD = b'Cloud gateway token expired \\u2014 refresh ANTHROPIC_AUTH_TOKEN and restart.'
REC_BASE = b'Cloud gateway.'   # readable stub; padded/truncated to hit exact length

# --- structural regexes (bytes) ---------------------------------------------

# 1. Routing injection site: the firstParty client-options object literal, keyed
#    on `authToken:<g>?<m>?.accessToken??null:null,...!1,...<spread>,`. The two
#    spreads (`...!1` = empty-ish, `...<spread>` = shared defaults) are stable in
#    shape; only <spread> is a volatile identifier we preserve verbatim.
RE_INJECT = re.compile(
    rb'(accessToken\?\?null:null,)(\.\.\.!1,\.\.\.)([A-Za-z_$][\w$]*)(,)'
)

# Model identifier: captured from the vertex-branch `region:<fn>(<model>)` call
# that sits just above the firstParty object in the SAME getAnthropicClient
# function (region is derived from the model name in every version).
RE_REGION = re.compile(rb'region:[A-Za-z_$][\w$]*\(([A-Za-z_$][\w$]*)\)')

# 3. Discovery token guard in fetchGatewayModelOptions:
#    `let <t>=<env>.ANTHROPIC_AUTH_TOKEN,<r>=<fn>();if(!<t>&&!<r>)return`
#    <env> is the minified env-object identifier and IS RENAMED between releases
#    (2.1.220: `Z`, 2.1.221+: `te`), so it must be matched generically — pinning
#    it silently broke this locator on 2.1.221. `process.env` is accepted too,
#    in case the bundler ever stops aliasing it. The non-capturing group keeps
#    the numbering of groups 1..5 (used for the replacement) intact.
RE_DISCOVERY = re.compile(
    rb'(let ([A-Za-z_$][\w$]*)=(?:[A-Za-z_$][\w$]*|process\.env)\.ANTHROPIC_AUTH_TOKEN,'
    rb'([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*\(\);if\(!)(\2)(&&!\3\)return)'
)

# 4. Agent-tool model enum. TWO SHAPES — 2.1.224 moved this schema to zod v4,
#    whose builders are standalone helpers instead of methods on a namespace:
#      <= 2.1.222   model:<zod>.enum(["sonnet","opus","haiku","fable"])
#      >= 2.1.224   model:<enumFn>(["sonnet","opus","haiku","fable"])
#    The v4 form has no namespace to hang `.string()` off, so the replacement
#    borrows the STRING builder from a sibling field of the same object literal
#    (`subagent_type:` is a plain string there, as are `description` and
#    `prompt`) — which makes the captured helper a string schema by
#    construction and keeps it valid in that module's scope.
RE_ENUM_V3 = re.compile(
    rb'([A-Za-z_$][\w$]*)\.enum\(\["sonnet","opus","haiku","fable"\]\)'
)
RE_ENUM_V4 = re.compile(
    rb'model:([A-Za-z_$][\w$]*)\(\["sonnet","opus","haiku","fable"\]\)'
)
RE_STRING_SIBLING = re.compile(rb'subagent_type:([A-Za-z_$][\w$]*)\(\)')


def die(msg):
    print("ERROR:", msg)
    sys.exit(1)


def find_unique(rx, data, name):
    ms = list(rx.finditer(data))
    if len(ms) != 1:
        die(f"{name}: expected 1 match, found {len(ms)}")
    return ms[0]


def main():
    if len(sys.argv) != 3:
        die("usage: patch_claude_routing.py <src-binary> <out-binary>")
    src, out = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    orig_len = len(data)

    if ROUTING_MARKER in data:
        die("already patched (routing marker present) — refusing to double-patch")

    # --- locate all four sites -------------------------------------------------
    inj = find_unique(RE_INJECT, data, "ROUTING injection site")
    disc = find_unique(RE_DISCOVERY, data, "DISCOVERY guard")
    enum_v3 = list(RE_ENUM_V3.finditer(data))
    if len(enum_v3) == 1:
        enum, enum_shape = enum_v3[0], "v3"
    elif enum_v3:
        die(f"ENUM site (v3 form): expected 1 match, found {len(enum_v3)}")
    else:
        enum, enum_shape = find_unique(RE_ENUM_V4, data, "ENUM site (v4 form)"), "v4"

    if data.count(REC_OLD) != 1:
        die(f"RECLAIM string not unique: {data.count(REC_OLD)} occurrences")

    # model identifier = last region:<fn>(<model>) in the 2500 bytes preceding
    # the injection site (i.e. inside the same getAnthropicClient function).
    win_start = max(0, inj.start() - 2500)
    regions = list(RE_REGION.finditer(data, win_start, inj.start()))
    if not regions:
        die("could not capture model identifier (no region:<fn>(<model>) before injection site)")
    model_id = regions[-1].group(1)
    if not (1 <= len(model_id) <= 4):
        die(f"suspicious model identifier {model_id!r}")

    # --- build replacements ----------------------------------------------------
    inj_add = (BASEURL_TMPL % model_id.decode()).encode()
    inj_new = inj.group(1) + inj_add + inj.group(2) + inj.group(3) + inj.group(4)
    growth_inject = len(inj_new) - (inj.end() - inj.start())

    # discovery: replace the first guard var `!<t>` with `!1`
    t_var = disc.group(2)
    disc_new = disc.group(1) + b'1' + disc.group(5)
    growth_disc = len(disc_new) - (disc.end() - disc.start())  # 1 - len(t_var)

    # enum -> a string schema + padding spaces (self-neutral by construction).
    # v3: <zod>.enum([...]) -> <zod>.string()
    # v4: model:<enumFn>([...]) -> model:<strFn>(), with <strFn> taken from the
    #     sibling `subagent_type:` field just above in the same object literal.
    zod = enum.group(1)
    enum_orig = enum.group(0)
    if enum_shape == "v3":
        enum_core = zod + b'.string()'
    else:
        sib_start = max(0, enum.start() - 800)
        siblings = list(RE_STRING_SIBLING.finditer(data, sib_start, enum.start()))
        if not siblings:
            die("could not capture the string schema builder (no subagent_type sibling)")
        str_fn = siblings[-1].group(1)
        enum_core = b'model:' + str_fn + b'()'
    pad = len(enum_orig) - len(enum_core)
    if pad < 10:
        die(f"enum padding too small ({pad}); cannot form unique marker")
    enum_new = enum_core + b' ' * pad
    growth_enum = 0  # by construction

    # reclaim: shrink REC_OLD by exactly (growth_inject + growth_disc)
    total_growth = growth_inject + growth_disc + growth_enum
    target = len(REC_OLD) - total_growth
    if target < len(b'Cloud'):
        die(f"reclaim target too small ({target}); growth={total_growth}")
    if target <= len(REC_BASE):
        rec_new = REC_BASE[:target]
    else:
        rec_new = REC_BASE + b' ' * (target - len(REC_BASE))
    assert len(REC_OLD) - len(rec_new) == total_growth

    print(f"model identifier : {model_id.decode()!r}")
    print(f"spread var       : {inj.group(3).decode()!r}")
    print(f"enum site        : {enum_shape} form, fn {zod.decode()!r}  (pad = {pad} spaces)")
    print(f"discovery guard  : flipped !{t_var.decode()} -> !1")
    print(f"inject growth    : +{growth_inject}")
    print(f"discovery growth : {growth_disc:+d}")
    print(f"reclaim delta    : {len(rec_new) - len(REC_OLD):+d}  (target len {target})")
    print(f"net delta        : {total_growth + (len(rec_new) - len(REC_OLD))}")

    # --- apply (each site is unique, so a single replace is safe) --------------
    data = data.replace(inj.group(0), inj_new, 1)
    data = data.replace(disc.group(0), disc_new, 1)
    data = data.replace(enum_orig, enum_new, 1)
    data = data.replace(REC_OLD, rec_new, 1)

    if len(data) != orig_len:
        die(f"size changed: {orig_len} -> {len(data)} (aborting, would corrupt offsets)")

    # --- post-checks -----------------------------------------------------------
    if ROUTING_MARKER not in data:
        die("post-check: routing marker missing")
    if RE_ENUM_V3.search(data) or RE_ENUM_V4.search(data):
        die("post-check: enum still present after patch")
    enum_marker = enum_core + b' ' * 10
    if enum_marker not in data:
        die("post-check: enum string marker missing")
    if b'if(!1' + disc.group(5) not in data:
        die("post-check: discovery guard not flipped")

    open(out, "wb").write(data)
    os.chmod(out, 0o755)
    print(f"OK: wrote {out} ({len(data)} bytes, size unchanged)")
    print("NEXT: codesign -f -i com.anthropic.claude-code -s <identity> <out>")


if __name__ == "__main__":
    main()
