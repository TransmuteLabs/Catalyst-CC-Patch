#!/usr/bin/env python3
"""Gate for step 19 on one pristine/patched pair.

Reads _stream_recoverable_cond, _stream_finalize_ok and ID from
claude-patch-all.sh by the heredoc anchor (tools/heredoc-anchor.py). Does not
keep a second copy of those regexes. Exit 0 only when pristine is not
finalized, patched is, the cap shape for this image is OK, the recoverable
names are the site module's locals, and every guarded yield sits within the
240-byte window the verifier pins. Exit 2 when the instrument cannot measure.
Scope: the output of tools/raw-image-step-run.js with MARKERS=1 (module
boundary markers present), images from 2.1.246 on (the guarded yield exists).
An image without boundary markers exits 2.
Cap forms (single/split and the pristine shapes they are matched against) are
measured on 2.1.278 / 2.1.280 / 2.1.281 / 2.1.282 (brief KIT-FIX6 п.7).
"""
import ast
import importlib.util
import io
import os
import re
import sys
import tempfile
import textwrap

# CONSTRAINT: loading heredoc-anchor.py must not leave __pycache__ in the kit.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
# CONSTRAINT: STEP19_KIT names the kit when this file runs from a copy outside it.
KIT = os.environ.get("STEP19_KIT") or os.path.dirname(HERE)


def die(msg, code=2):
    sys.stderr.write("step19-image-check: %s\n" % msg)
    sys.exit(code)


def load_finalize(script_path):
    anchor_path = os.path.join(KIT, "tools", "heredoc-anchor.py")
    spec = importlib.util.spec_from_file_location("step19_heredoc_anchor", anchor_path)
    if spec is None or spec.loader is None:
        die("heredoc anchor does not load: %s" % anchor_path)
    anchor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(anchor)
    with tempfile.TemporaryDirectory(prefix="step19-heredoc.") as td:
        buf = io.StringIO()
        old = sys.stdout
        sys.stdout = buf
        try:
            rc = anchor.bodies(script_path, td)
        finally:
            sys.stdout = old
        if rc != 0:
            die("heredoc bodies rc=%s" % rc)
        try:
            count = int(buf.getvalue().strip())
        except ValueError:
            die("heredoc anchor did not name a count: %r" % buf.getvalue())
        chosen = None
        for i in range(1, count + 1):
            body_path = os.path.join(td, "body.%d.py" % i)
            src = open(body_path, encoding="utf-8").read()
            if "def _stream_finalize_ok" in src and "\nID = " in ("\n" + src):
                chosen = src
                break
        if chosen is None:
            die("_stream_finalize_ok not found in a heredoc body")
    tree = ast.parse(chosen)
    pieces = []
    for node in tree.body:
        if isinstance(node, ast.Assign):
            if any(isinstance(t, ast.Name) and t.id == "ID" for t in node.targets):
                pieces.append(ast.get_source_segment(chosen, node))
        elif isinstance(node, ast.FunctionDef) and node.name in (
                "_stream_recoverable_cond", "_stream_finalize_ok"):
            pieces.append(ast.get_source_segment(chosen, node))
    if len(pieces) != 3:
        die("expected ID, _stream_recoverable_cond and _stream_finalize_ok, got %d" % len(pieces))
    expr = None
    for node in ast.walk(tree):
        if isinstance(node, ast.Dict):
            for key, val in zip(node.keys, node.values):
                if isinstance(key, ast.Constant) and key.value == "broken stream retried, not halved":
                    expr = ast.get_source_segment(chosen, val)
    if not expr:
        die("broken-stream check expression not found")
    wrapped = "def _broken_stream(d):\n    return (\n" + textwrap.indent(expr, "    ") + "\n    )\n"
    ns = {}
    exec("import re\n" + "\n".join(pieces) + "\n" + wrapped, ns)
    return ns["_broken_stream"], ns["_stream_recoverable_cond"]()


ID = r"[A-Za-z_$][\w$]*"
SPLIT_CAP = re.compile(
    rb"" + ID.encode() + rb"=" + ID.encode()
    + rb"\?Math\.max\(" + ID.encode() + rb",300\):Math\.max\("
    + ID.encode() + rb"\(\),300\);if\(" + ID.encode()
    + rb"&&" + ID.encode() + rb"===null&&\(" + ID.encode()
    + rb"\?" + ID.encode() + rb":" + ID.encode() + rb"\)<"
    + ID.encode() + rb"\)\{"
)
# CONSTRAINT: pinned to step 19's single-cap rewrite (`if($3&&$4===null&&$5<Math.max($1,300)){`,
# tweakcc-patch.js rxCapSingle branch): a bare `<Math.max(ID,300)` outside that context is
# not the cap site (KIT-282-v4-FIX5 opus F4; brief KIT-FIX6 п.4).
SINGLE_CAP = re.compile(
    rb"" + ID.encode() + rb"&&" + ID.encode() + rb"===null&&" + ID.encode() + rb"<Math\.max\(" + ID.encode() + rb",300\)\)\{"
)
PRISTINE_SINGLE = re.compile(
    rb"let " + ID.encode() + rb"=" + ID.encode()
    + rb"\(\);if\(" + ID.encode() + rb"&&" + ID.encode()
    + rb"===null&&" + ID.encode() + rb"<" + ID.encode() + rb"\)\{"
)
PRISTINE_SPLIT = re.compile(
    rb"let " + ID.encode() + rb"=" + ID.encode()
    + rb"\?\.code===\"StreamTruncated\"," + ID.encode()
    + rb"=" + ID.encode() + rb"\?" + ID.encode() + rb":"
    + ID.encode() + rb"\(\);"
)
BUDGET_PAIR = re.compile(
    ID.encode() + rb"=300," + ID.encode() + rb"=0,"
    + ID.encode() + rb"=0," + ID.encode() + rb"=1,"
    + ID.encode() + rb"=0," + ID.encode() + rb"=!1,"
    + ID.encode() + rb"=300," + ID.encode() + rb"=0,"
)
BUDGET_BARE = re.compile(
    ID.encode() + rb"=300," + ID.encode() + rb"=0,"
    + ID.encode() + rb"=0," + ID.encode() + rb"=!1,"
    + ID.encode() + rb"=300," + ID.encode() + rb"=0,"
)
READER = re.compile(
    rb"function " + ID.encode() + rb"\((" + ID.encode() + rb"),("
    + ID.encode() + rb"),(" + ID.encode()
    + rb")\)\{return \1\?\.type===\"assistant\"&&\1\.isApiErrorMessage===!0&&\1\.truncatedAfterOutput===!0&&\(("
    + ID.encode() + rb")\(\3\)===\"subagent\"\|\|\4\(\3\)===\"main\"&&\2\.options\.isNonInteractiveSession\)&&("
    + ID.encode() + rb")\(\"tengu_truncated_response_recovery\",!0\)\}"
)
BOUNDARY = re.compile(rb"\n/\*__tweakcc_module_boundary_\d+__\*/\n")
IMPORT_RE = re.compile(
    rb'import\s*(?:([A-Za-z_$][\w$]*)\s*,\s*)?\{([^}]*)\}\s*from\s*"([^"]+)"\s*;'
)


def py_code_spans(blob):
    """Top-level code spans of a JS module: everything outside strings,
    templates, and comments.

    CONSTRAINT: this minimal lexer does not tell a regex literal from
    division; module headers do not carry regex around their imports.
    A nested ${...} counts as part of the template, matching the gate's
    own reading of the header; inside it strings, templates and comments
    are lexed like code, so a quoted brace or backtick does not end it.
    """
    spans = []
    i, n = 0, len(blob)
    code_start = 0
    mode = "code"
    # One brace counter per open ${ level; spans are written only when empty.
    interp = []
    while i < n:
        c = blob[i:i + 1]
        top = not interp
        if mode == "code":
            if c == b"/" and blob[i + 1:i + 2] == b"/":
                if top:
                    spans.append((code_start, i))
                mode = "line"
                i += 2
            elif c == b"/" and blob[i + 1:i + 2] == b"*":
                if top:
                    spans.append((code_start, i))
                mode = "block"
                i += 2
            elif c in (b"'", b'"'):
                if top:
                    spans.append((code_start, i))
                mode = "sq" if c == b"'" else "dq"
                i += 1
            elif c == b"`":
                if top:
                    spans.append((code_start, i))
                mode = "tmpl"
                i += 1
            elif not top and c == b"{":
                interp[-1] += 1
                i += 1
            elif not top and c == b"}":
                if interp[-1] == 0:
                    interp.pop()
                    mode = "tmpl"
                else:
                    interp[-1] -= 1
                i += 1
            else:
                i += 1
        elif mode == "line":
            if c == b"\n":
                mode = "code"
                if top:
                    code_start = i + 1
            i += 1
        elif mode == "block":
            if c == b"*" and blob[i + 1:i + 2] == b"/":
                mode = "code"
                if top:
                    code_start = i + 2
                i += 2
            else:
                i += 1
        elif mode in ("sq", "dq"):
            if c == b"\\":
                i += 2
            elif (mode == "sq" and c == b"'") or (mode == "dq" and c == b'"'):
                mode = "code"
                if top:
                    code_start = i + 1
                i += 1
            else:
                i += 1
        else:  # tmpl
            if c == b"\\":
                i += 2
            elif c == b"`":
                mode = "code"
                if top:
                    code_start = i + 1
                i += 1
            elif c == b"$" and blob[i + 1:i + 2] == b"{":
                interp.append(0)
                mode = "code"
                i += 2
            else:
                i += 1
    if mode == "code" and not interp:
        spans.append((code_start, n))
    return spans


def module_slice(blob, pos):
    start = 0
    end = len(blob)
    for m in BOUNDARY.finditer(blob):
        if m.start() < pos:
            start = m.end()
        else:
            end = m.start()
            break
    return blob[start:end]


def parse_imports(mod):
    specs = []
    code = py_code_spans(mod)
    for m in IMPORT_RE.finditer(mod):
        if not any(a <= m.start() < b for a, b in code):
            continue
        path = m.group(3).decode("latin1")
        for raw in m.group(2).decode("latin1").split(","):
            part = raw.strip()
            if not part:
                continue
            as_m = re.match(r"^([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)$", part)
            if as_m:
                specs.append((as_m.group(1), as_m.group(2), path))
            elif re.match(r"^[A-Za-z_$][\w$]*$", part):
                specs.append((part, part, path))
    return specs


def cap_ok(pristine, patched):
    n_split = len(SPLIT_CAP.findall(patched))
    n_single = len(SINGLE_CAP.findall(patched))
    n_pr_single = len(PRISTINE_SINGLE.findall(patched))
    n_pr_split = len(PRISTINE_SPLIT.findall(patched))
    n_pair = len(BUDGET_PAIR.findall(patched))
    n_bare = len(BUDGET_BARE.findall(patched))
    p_single = len(PRISTINE_SINGLE.findall(pristine))
    p_split = len(PRISTINE_SPLIT.findall(pristine))
    # CONSTRAINT: the pristine names the image's own cap form: zero or two pristine
    # sites mean the instrument cannot tell which form it is gating, which is a
    # refusal (ValueError -> exit 2), never a verdict (KIT-282-v4-FIX5 opus F1 AR;
    # brief KIT-FIX6 п.3).
    if p_single + p_split != 1:
        raise ValueError("pristine cap form %s: single=%d split=%d"
                         % ("none" if p_single + p_split == 0 else "mixed", p_single, p_split))
    pform = "single" if p_single == 1 else "split"
    # CONSTRAINT: the form is the image's own, as tweakcc-patch.js decides it
    # (nCapSingle + nCapSplit === 1), and its budgets are raised in that
    # form's own shape (single: bare, split: pair) -- never a list of version
    # names.
    if n_split == 0 and n_single == 0:
        good = False
        form = "none"
    elif n_split == 0:
        good = n_single == 1 and n_bare == 1 and n_pair == 0 and n_pr_single == 0 and n_pr_split == 0
        form = "single"
    else:
        good = n_split == 1 and n_single == 0 and n_pair == 1 and n_bare == 0 and n_pr_single == 0 and n_pr_split == 0
        form = "split"
    if form != pform:
        good = False
    return form, good, "split=%d single=%d pristine_single=%d pristine_split=%d pair=%d bare=%d pristine_form=%s" % (
        n_split, n_single, n_pr_single, n_pr_split, n_pair, n_bare, pform)


def names_ok(blob, cond):
    if re.compile(cond).groups != 3:
        raise ValueError("recoverable cond has %d groups, expected 3" % re.compile(cond).groups)
    recs = list(re.finditer(cond, blob))
    if not recs or any(r.group(0) != recs[0].group(0) for r in recs):
        return None, None, False, "recoverable=%d" % len(recs)
    rec = recs[0]
    # CONSTRAINT: groups 1 and 3 feed the .decode() and the name comparison
    # below; a cond whose static count is 3 while one of them stops
    # participating must refuse as a layout error, not crash as
    # AttributeError/TypeError (KIT-282-v4-FIX5 opus F2; brief KIT-FIX6 п.2).
    if (rec.group(1) is None or rec.group(3) is None
            or not re.fullmatch(ID.encode(), rec.group(1))
            or not re.fullmatch(ID.encode(), rec.group(3))):
        raise ValueError("recoverable cond layout: groups 1 and 3 must be identifiers")
    cls_s = rec.group(1).decode("latin1")
    gate_s = rec.group(3).decode("latin1")
    expr = rec.group(0).decode("latin1")
    readers = list(READER.finditer(blob))
    if len(readers) != 1:
        return cls_s, gate_s, False, "reader=%d expr=%s" % (len(readers), expr)
    rd = readers[0]
    cls_r = rd.group(4).decode("latin1")
    gate_r = rd.group(5).decode("latin1")
    rmod = module_slice(blob, rd.start())
    smod = module_slice(blob, rec.start())
    rspecs = parse_imports(rmod)
    sspecs = parse_imports(smod)

    def one_local(specs, local):
        found = [s for s in specs if s[1] == local]
        return found

    cls_imp = one_local(rspecs, cls_r)
    gate_imp = one_local(rspecs, gate_r)
    if len(cls_imp) != 1 or len(gate_imp) != 1:
        return cls_s, gate_s, False, "reader imports cls=%d gate=%d expr=%s" % (len(cls_imp), len(gate_imp), expr)

    def site_local(exp_name, path):
        return [s for s in sspecs if s[0] == exp_name and s[2] == path]

    cls_site = site_local(cls_imp[0][0], cls_imp[0][2])
    gate_site = site_local(gate_imp[0][0], gate_imp[0][2])
    if len(cls_site) != 1 or len(gate_site) != 1:
        return cls_s, gate_s, False, "site imports cls=%d gate=%d expr=%s" % (len(cls_site), len(gate_site), expr)
    ok = cls_s == cls_site[0][1] and gate_s == gate_site[0][1]
    return cls_s, gate_s, ok, expr


def occurrence_form(data, start, end):
    # CONSTRAINT: a string-pool entry is u32 length|0x80000000, u32 hash with
    # a zero top byte, the bytes, NUL padding to 4 (measured on 2.1.282); for
    # this 33-byte constant (33 = 1 mod 4) both neighbours are NUL. A code
    # site never has a NUL neighbour, so NUL on both sides reads as pool and
    # anything else (any quote, a template, the file edge) as code.
    if start > 0 and end < len(data) and data[start - 1] == 0 and data[end] == 0:
        return "pool"
    return "code"


def window_verdict(patched, cond):
    lines = []
    bad = False
    occs = list(re.finditer(rb"tengu_streaming_partial_finalized", patched))
    yields = list(re.finditer(rb"," + cond + rb"\?yield ", patched, re.S))
    # CONSTRAINT: пара = та, что матчит регэксп верификатора
    # (claude-patch-all.sh:7526-7529): константа непосредственно перед
    # guarded yield. Forward-поиск от вхождения мерил бы копию в пуле строк.
    paired = set()
    for m in yields:
        prev = None
        prev_i = None
        for i, occ in enumerate(occs):
            if occ.end() <= m.start():
                prev = occ
                prev_i = i
            else:
                break
        if prev is None:
            continue
        paired.add(prev_i)
        dist = m.start() - prev.end()
        far = dist > 240
        lines.append("WINDOW %d%s" % (dist, " BAD" if far else ""))
        if far:
            bad = True
    for i, occ in enumerate(occs):
        if i in paired:
            continue
        if occurrence_form(patched, occ.start(), occ.end()) == "code":
            lines.append("WINDOW unpaired-code %d BAD" % occ.start())
            bad = True
        else:
            lines.append("WINDOW unpaired %d" % occ.start())
    return lines, bad


def self_test():
    failed = 0

    def run(name, call, pred):
        # CONSTRAINT: an exception inside one fixture is that fixture's failure, never
        # a crash of the whole self-test; the label carries the class so a mutation
        # that removes a guard reads differently from an unrelated breakage
        # (brief KIT-FIX6 п.5).
        nonlocal failed
        try:
            res = call()
            exc = None
        except Exception as e:
            res = None
            exc = e
        if not pred(res, exc):
            if exc is None:
                print("SELFTEST FAIL %s" % name)
            else:
                print("SELFTEST FAIL %s %s" % (name, type(exc).__name__))
            failed += 1

    f_ok = (b"\x00tengu_streaming_partial_finalized\x00"
            + b'i("tengu_streaming_partial_finalized",{}),G?yield ')
    f_code = f_ok + b'j("tengu_streaming_partial_finalized",{})'
    f_far = (b'i("tengu_streaming_partial_finalized",{})'
             + b"x" * 300 + b",G?yield ")
    f_sq = f_ok + b"k('tengu_streaming_partial_finalized')"
    f_tpl = f_ok + b"l(`tengu_streaming_partial_finalized${v}`)"
    f_edge = b"tengu_streaming_partial_finalized\x00" + f_ok + b"\x00"
    f_half = f_ok + b"\x00tengu_streaming_partial_finalized)"
    f_end = f_ok + b"\x00tengu_streaming_partial_finalized"

    def ok_clean(lines, bad):
        return (not bad
                and sum(1 for l in lines if l.startswith("WINDOW unpaired ")) == 1
                and not any("BAD" in l for l in lines))

    def ok_unpaired_code(lines, bad):
        return bad and any(l.startswith("WINDOW unpaired-code ") for l in lines)

    def ok_far(lines, bad):
        return bad and any(re.match(r"WINDOW \d+ BAD", l) for l in lines)

    for name, data, pred in (
            ("F_OK", f_ok, ok_clean),
            ("F_CODE", f_code, ok_unpaired_code),
            ("F_FAR", f_far, ok_far),
            ("F_SQ", f_sq, ok_unpaired_code),
            ("F_TPL", f_tpl, ok_unpaired_code),
            ("F_EDGE", f_edge, ok_unpaired_code),
            ("F_HALF", f_half, ok_unpaired_code),
            ("F_END", f_end, ok_unpaired_code)):
        run(name, (lambda d=data: window_verdict(d, rb"G")),
            lambda res, exc, p=pred: exc is None and p(*res))
    split = b"a=b?Math.max(c,300):Math.max(d(),300);if(e&&f===null&&(g?h:i)<j){"
    single = b"a&&b===null&&c<Math.max(d,300)){"
    pair = b"a=300,b=0,c=0,d=1,e=0,f=!1,g=300,h=0,"
    bare = b"a=300,b=0,c=0,d=!1,e=300,f=0,"
    p_single = b"let cap=mr();if(conn&&stop===null&&tries<cap){"
    p_split = b'let isTr=er?.code==="StreamTruncated",cap=isTr?tm:mr();'
    for name, pristine, blob, want_form, want_good in (
            ("C_SPLIT", p_split, split + pair, "split", True),
            ("C_SINGLE", p_single, single + bare, "single", True),
            ("C_NONE", p_split, b"", "none", False),
            ("C_SPLIT_STRAY", p_split, split + pair + single, "split", False),
            ("C_SINGLE_NOBUDGET", p_single, single, "single", False),
            ("C_SPLIT_NOPAIR", p_split, split, "split", False),
            ("C_BAIT", p_single, single + bare + b"a<Math.max(b,300)", "single", True)):
        run(name, (lambda p=pristine, b=blob: cap_ok(p, b)),
            lambda res, exc, wf=want_form, wg=want_good:
            exc is None and (res[0], res[1]) == (wf, wg))

    def raises_cap_form(which):
        def pred(res, exc):
            return (isinstance(exc, ValueError)
                    and "pristine cap form " + which in str(exc))
        return pred

    run("P_MIXED", lambda: cap_ok(p_single + p_split, split + pair),
        raises_cap_form("mixed"))
    run("P_NONE", lambda: cap_ok(b"", split + pair), raises_cap_form("none"))
    cond_t = rb"([A-Za-z_$][\w$]*)\(e\)(\|\|)([A-Za-z_$][\w$]*)\(e\)"
    reader_mod = (b'import{a as K,b as H}from"./m.js";'
                  b'function r(e,t,n){return e?.type==="assistant"&&e.isApiErrorMessage===!0'
                  b'&&e.truncatedAfterOutput===!0&&(K(n)==="subagent"||K(n)==="main"'
                  b'&&t.options.isNonInteractiveSession)&&H("tengu_truncated_response_recovery",!0)}')
    sep = b"\n/*__tweakcc_module_boundary_1__*/\n"
    n_ok_blob = b'import{a as C,b as G}from"./m.js";x=C(e)||G(e);' + sep + reader_mod
    run("N_OK", lambda: names_ok(n_ok_blob, cond_t),
        lambda res, exc: exc is None and res[2] is True)
    n_swap_blob = b'import{a as C,b as G}from"./m.js";x=G(e)||C(e);' + sep + reader_mod
    run("N_SWAP", lambda: names_ok(n_swap_blob, cond_t),
        lambda res, exc: exc is None and res[2] is False)
    run("N_LAYOUT", lambda: names_ok(n_ok_blob, rb"([A-Za-z_$][\w$]*)\(e\)"),
        lambda res, exc: isinstance(exc, ValueError))
    # CONSTRAINT fixtures: a cond may keep exactly 3 static groups while group 1
    # stops participating (optional prefix) -- the layout check must refuse, the
    # decode in names_ok would otherwise crash (KIT-282-v4-FIX5 opus F2; brief
    # KIT-FIX6 п.2/п.6).
    run("N_OPT", lambda: names_ok(
            b"x=G(e)||H(e);",
            rb'(?:(C)\|\|)?([A-Za-z_$][\w$]*)\(e\)\|\|([A-Za-z_$][\w$]*)\(e\)'),
        lambda res, exc: (isinstance(exc, ValueError)
                          and "recoverable cond layout" in str(exc)))
    # CONSTRAINT: an uncompilable cond is an instrument refusal that must reach
    # main's catch-all as re.error, not as a traceback (brief KIT-FIX6 п.6).
    run("E_RE", lambda: names_ok(n_ok_blob, rb"("),
        lambda res, exc: isinstance(exc, re.error))
    if failed:
        return 1
    print("SELFTEST ok 22")
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 4:
        die("usage: step19-image-check.py <pristine> <patched> <name>", 2)
    pristine_path, patched_path, name = argv[1], argv[2], argv[3]
    print("IMAGE %s" % name)
    script = os.path.join(KIT, "claude-patch-all.sh")
    if not os.path.isfile(script):
        die("no pipeline: %s" % script)
    if not os.path.isfile(pristine_path) or not os.path.isfile(patched_path):
        die("image missing")
    try:
        finalize, cond = load_finalize(script)
    except SystemExit:
        raise
    except Exception as exc:
        die("could not load _stream_finalize_ok: %s" % exc)
    pristine = open(pristine_path, "rb").read()
    patched = open(patched_path, "rb").read()
    if not BOUNDARY.search(patched):
        die("no module boundary markers in %s: the instrument reads raw-image-step-run.js output with MARKERS=1 only" % patched_path)
    # CONSTRAINT: an analysis refusal -- inside finalize or inside any measuring
    # step -- is the instrument exiting 2 (any exception class), never a verdict
    # of 1; a SystemExit already raised by die() must pass through untouched
    # (KIT-282-v4-FIX5 opus F1; brief KIT-FIX6 п.1).
    try:
        p_ok = bool(finalize(pristine))
        a_ok = bool(finalize(patched))
        print("FINALIZE pristine=%s patched=%s" % (p_ok, a_ok))
        form, cap_good, cap_detail = cap_ok(pristine, patched)
        print("CAP %s %s %s" % (form, "OK" if cap_good else "BAD", cap_detail))
        cls_s, gate_s, n_ok, detail = names_ok(patched, cond)
        print("NAMES CLS=%s GATE=%s %s" % (cls_s, gate_s, "OK" if n_ok else "BAD"))
        print("EXPR %s" % detail)
        wl, window_bad = window_verdict(patched, cond)
        for line in wl: print(line)
    except SystemExit:
        raise
    except Exception as exc:
        die("analysis failed: %s: %s" % (type(exc).__name__, exc), 2)
    if (not p_ok) and a_ok and cap_good and n_ok and not window_bad:
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
