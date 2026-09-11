// CONSTRAINT: on("event") string literal; $.noun.verb call sites only.
// CLAUDE_FORM empty = ON. CLAUDE_FORM_CARRIER=mod stands the splice down.
// process/Bun undefined. cwd = session.start e.cwd in $.store.
// Awaited body must stay under 10 s; this probe is deterministic file I/O.

const CWD_KEY = "catalyst-form:cwd"
const REQ = [
  "brief_path","brief_ref","brief_head","brief_tail","report_path","fence",
  "arm_line","arm_ellipsis","arm_cmd","arm_remote","arm_log","witness_remote",
  "witness_worker","open_door","negation","rule_line","path_line",
  "decision_head","decision_basis","decision_referent","legalize",
  "git_commit","git_commit_ok","git_msg","git_push","git_push_ok","git_force",
  "trailer_a","trailer_b","write_redirect","heredoc",
]

function formOn(v: any): boolean {
  const s = String(v ?? "").trim().toLowerCase()
  return !(s === "0" || s === "false" || s === "off" || s === "no")
}

function clip(q: string, n: number): string {
  const s = String(q ?? "")
  return s.length > n ? s.slice(0, n) : s
}

function parseVal(raw: string): any {
  let s = String(raw || "").trim()
  if (s.slice(0, 3) === "'''" || s.slice(0, 3) === '"""') {
    const q = s.slice(0, 3)
    const end = s.indexOf(q, 3)
    if (end >= 0) return s.slice(3, end)
  }
  if (s.charAt(0) === '"') {
    const m = /^"([\s\S]*)"\s*(?:#.*)?$/.exec(s)
    if (m) return m[1].replace(/\\n/g, "\n").replace(/\\"/g, '"')
  }
  if (s.charAt(0) === "'") {
    const m = /^'([\s\S]*)'\s*(?:#.*)?$/.exec(s)
    if (m) return m[1]
  }
  if (s.charAt(0) === "[") {
    const m = /^\[([\s\S]*)\]\s*(?:#.*)?$/.exec(s)
    if (m) {
      const out: string[] = []
      const reQ = /"([^"]*)"/g
      let q: RegExpExecArray | null
      while ((q = reQ.exec(m[1]))) out.push(q[1])
      return out
    }
  }
  const hash = s.indexOf("#")
  if (hash >= 0) s = s.slice(0, hash).trim()
  if (s === "true") return true
  if (s === "false") return false
  if (/^-?\d+$/.test(s)) return parseInt(s, 10)
  return s
}

function parseToml(src: string): any {
  const root: any = {}
  let current: any = root
  function nav(keys: string[], asArray: boolean): any {
    let d: any = root
    for (let i = 0; i < keys.length - 1; i++) {
      const k = keys[i]
      if (!d[k] || typeof d[k] !== "object" || Array.isArray(d[k])) d[k] = {}
      d = d[k]
    }
    const last = keys[keys.length - 1]
    if (asArray) {
      if (!Array.isArray(d[last])) d[last] = []
      const obj: any = {}
      d[last].push(obj)
      return obj
    }
    if (!d[last] || typeof d[last] !== "object" || Array.isArray(d[last])) d[last] = {}
    return d[last]
  }
  const lines = String(src || "").split("\n")
  for (let i = 0; i < lines.length; i++) {
    const s = lines[i].trim()
    if (!s || s.charAt(0) === "#") continue
    const aa = /^\[\[(.+)\]\]$/.exec(s)
    if (aa) { current = nav(aa[1].split("."), true); continue }
    const sec = /^\[(.+)\]$/.exec(s)
    if (sec) { current = nav(sec[1].split("."), false); continue }
    const kv = /^([A-Za-z0-9_]+)\s*=\s*(.*)$/.exec(s)
    if (kv) current[kv[1]] = parseVal(kv[2])
  }
  return root
}

function flattenForm(parsed: any): any {
  const defaults = (parsed && parsed.defaults) || {}
  const form = (parsed && parsed.probe && parsed.probe.form) || {}
  const out: any = {}
  const dk = Object.keys(defaults)
  for (let i = 0; i < dk.length; i++) out[dk[i]] = defaults[dk[i]]
  const fk = Object.keys(form)
  for (let i = 0; i < fk.length; i++) out[fk[i]] = form[fk[i]]
  return out
}

const rxCache: any = {}
function K(s: string, f: string): RegExp {
  const key = f + "|" + s
  if (rxCache[key]) return rxCache[key]
  const r = new RegExp(s, f)
  rxCache[key] = r
  return r
}

function formKind(p: string, t: string, c: any): string | null {
  const path = String(p ?? "")
  const text = String(t ?? "")
  if (K(c.brief_path, "u").test(path)) {
    // CONSTRAINT: a `>` redirect without a heredoc body has empty post-state
    // (same as the splice). Measured: after Write A1 deny, grok did
    // `printf ... > docs/review/zq-brief.md` and the file landed. Path
    // matching brief_path is enough: empty text fails brief_head and was
    // skipped. Fail-closed: treat as brief so A1 fires.
    if (!text || K(c.brief_head, "iu").test(text.split("\n")[0])) return "brief"
  }
  if (K(c.report_path, "u").test(path)) return "report"
  return null
}

function formEval(ev: any, c: any): { refuse: any[]; warn: any[] } {
  const W: any = { A4: 1, C2: 1 }
  const Rf: any[] = []
  const Wr: any[] = []
  const F = (cl: string, n: number, q: string) => (W[cl] ? Wr : Rf).push({ c: cl, n, q: clip(q, 160) })
  const t = String(ev.text ?? "")
  const ls = t.split("\n")
  let inn = false
  const op = ls.map((l: string) => {
    if (K(c.fence, "u").test(l)) { inn = !inn; return false }
    return !inn
  })
  if (ev.kind === "brief") {
    let ln = -1, ll = ""
    for (let i = 0; i < ls.length; i++) {
      const e = ls[i].trimEnd()
      if (e) { ln = i + 1; ll = e }
    }
    if (ln < 0) F("A1", 0, "")
    else if (ll !== c.brief_tail) F("A1", ln, ll)
    let ac = 0
    for (let i = 0; i < ls.length; i++) {
      let cs2: string[] = []
      if (!op[i]) cs2 = [ls[i]]
      else if (K(c.arm_line, "u").test(ls[i]))
        cs2 = [...ls[i].matchAll(/`([^`]*)`/g)].map((m) => m[1])
      for (let j = 0; j < cs2.length; j++) {
        let b = cs2[j], el = false
        if (K(c.arm_ellipsis, "u").test(b)) {
          el = true
          b = b.replace(K(c.arm_ellipsis, "u"), "")
        }
        if (!K(c.arm_cmd, "u").test(b)) continue
        ac++
        if (el || !K(c.arm_remote, "u").test(b) || !K(c.arm_log, "u").test(b))
          F("A2", i + 1, cs2[j])
      }
    }
    if (ac && !K(c.witness_remote, "iu").test(t))
      F("A2", 0, "арма есть, свидетель [RCH] remote не назван")
    if (K(c.witness_worker, "u").test(t)) {
      for (let i = 0; i < ls.length; i++)
        if (K(c.witness_worker, "u").test(ls[i])) { F("A2", i + 1, ls[i]); break }
    }
    const a3 = new RegExp("(?<!(?:" + c.negation + ")\\s{0,16})(?:" + c.open_door + ")", "iu")
    for (let i = 0; i < ls.length; i++) {
      if (op[i] && a3.test(ls[i])) F("A3", i + 1, ls[i])
    }
    let pc = 0, rl = false
    for (let i = 0; i < ls.length; i++) {
      if (K(c.path_line, "u").test(ls[i])) pc++
      if (K(c.rule_line, "iu").test(ls[i])) rl = true
    }
    if (pc >= c.path_lines_min && !rl)
      F("A4", 0, "строк-путей " + pc + ", строчки правила нет")
  }
  if (ev.kind === "report" || ev.kind === "message") {
    for (let i = 0; i < ls.length; i++) {
      if (op[i] && K(c.legalize, "iu").test(ls[i])) { F("C1", i + 1, ls[i]); break }
    }
    if (K(c.witness_worker, "u").test(t) && !K(c.witness_remote, "iu").test(t)) {
      for (let i = 0; i < ls.length; i++)
        if (K(c.witness_worker, "u").test(ls[i])) { F("C2", i + 1, ls[i]); break }
    }
  }
  if (ev.kind === "message") {
    let h = -1
    for (let i = 0; i < ls.length; i++) if (ls[i].trim()) { h = i; break }
    if (h >= 0 && K(c.decision_head, "u").test(ls[h]) &&
        (!K(c.decision_basis, "iu").test(t) || !K(c.decision_referent, "iu").test(t)))
      F("B", h + 1, ls[h])
  }
  if (ev.kind === "command") {
    if (K(c.git_commit, "u").test(t)) {
      if (!K(c.git_commit_ok, "u").test(t))
        F("F", 1, "git commit: нет " + c.git_commit_ok)
      const ms = [...t.matchAll(K(c.git_msg, "gu"))].map((m) => m[1] ?? m[2] ?? m[3] ?? "")
      const hd = K(c.heredoc, "u").exec(t)
      const ct = hd ? hd[2] : ms.join("\n\n")
      if (ct) {
        const cm = ct.split("\n")
        let ia = -1, ib = -1
        for (let i = 0; i < cm.length; i++) {
          if (ia < 0 && K(c.trailer_a, "mu").test(cm[i])) ia = i
          if (ib < 0 && K(c.trailer_b, "mu").test(cm[i])) ib = i
        }
        if (ia >= 0 && ib >= 0 && Math.abs(ia - ib) !== 1)
          F("F", ia + 1, "трейлеры Session: и Co-Authored-By: не соседние")
      }
    }
    if (K(c.git_push, "u").test(t)) {
      if (!K(c.git_push_ok, "u").test(t)) F("F", 1, "git push: нет " + c.git_push_ok)
      if (K(c.git_force, "u").test(t)) F("F", 1, t)
    }
  }
  return { refuse: Rf, warn: Wr }
}

async function readText($: any, path: string): Promise<string | null> {
  try {
    const v = await $.fs.read(path)
    if (v === null || v === undefined) return null
    return String(v)
  } catch (x) {
    return null
  }
}

function parentDir(p: string): string {
  const trimmed = String(p || "").replace(/\/+$/, "")
  const i = trimmed.lastIndexOf("/")
  if (i <= 0) return ""
  return trimmed.slice(0, i)
}

function normTmp(p: string): string {
  return String(p || "").replace(/^\/private\/tmp\b/, "/tmp")
}

function resolvePath(p: string, home: string, cwd: string): string {
  let s = String(p)
  if (s.charAt(0) === "~") s = home + s.slice(1)
  if (s.charAt(0) === "/") return s
  return (cwd || ".") + "/" + s
}

async function appendJournal($: any, jpath: string, obj: any) {
  const line = JSON.stringify(obj)
  let prev = ""
  try { prev = String(await $.fs.read(jpath) || "") } catch (x) { prev = "" }
  let pfx = ""
  if (prev.length > 0 && prev.charCodeAt(prev.length - 1) !== 10) pfx = "\n"
  try { await $.fs.write(jpath, prev + pfx + line + "\n") } catch (x) {}
}

function actOf(cfg: any, cls: string): string {
  const a = cfg && cfg.act
  const v = a && a[cls]
  return String(v || "log_only")
}

function textOf(cfg: any, cls: string): string {
  const a = cfg && cfg.text
  return String((a && a[cls]) || cls)
}

export function register(on: any) {
  on("session.start", async ($: any, e: any, next: any) => {
    try { if (e && e.cwd) await $.store.set(CWD_KEY, String(e.cwd)) } catch (x) {}
    return next(e)
  })

  on("tool.call", async ($: any, e: any, next: any) => {
    const tool = String((e && e.tool) || "")
    if (tool !== "Agent" && tool !== "Task" && tool !== "SendMessage" &&
        tool !== "Write" && tool !== "Edit" && tool !== "Bash") return next(e)
    if ("agentId" in e) return next(e)

    let carrier: any = ""
    try { carrier = await $.env.get("CLAUDE_FORM_CARRIER") } catch (x) { carrier = "" }
    if (String(carrier).trim().toLowerCase() !== "mod") return next(e)
    let sw: any = ""
    try { sw = await $.env.get("CLAUDE_FORM") } catch (x) { sw = "" }
    if (!formOn(sw)) return next(e)

    let probesDir: any = ""
    try { probesDir = await $.env.get("CLAUDE_PROBES_DIR") } catch (x) { probesDir = "" }
    let configDir: any = ""
    try { configDir = await $.env.get("CLAUDE_CONFIG_DIR") } catch (x) { configDir = "" }
    let home: any = ""
    try { home = await $.env.get("HOME") } catch (x) { home = "" }
    const probesDirS = String(probesDir || "").trim()
    const configDirS = String(configDir || "").trim()
    const homeS = String(home || "")
    let globalHome = ""
    if (probesDirS) globalHome = probesDirS
    else if (configDirS) globalHome = configDirS + "/probes"
    else globalHome = homeS + "/.claude/probes"

    const gTxt = await readText($, globalHome + "/probes.toml")
    const cfg = flattenForm(parseToml(gTxt || ""))
    if (!probesDirS) {
      let cwd = ""
      try { cwd = String(await $.store.get(CWD_KEY) || "") } catch (x) { cwd = "" }
      if (cwd) {
        let p = cwd
        for (let i = 0; i < 24; i++) {
          if (!p) break
          const ch = p + "/.claude/probes"
          if (normTmp(ch) !== normTmp(globalHome)) {
            const pt = await readText($, ch + "/probes.toml")
            if (pt) {
              const pc = flattenForm(parseToml(pt))
              const keys = Object.keys(pc)
              for (let k = 0; k < keys.length; k++) cfg[keys[k]] = pc[keys[k]]
              break
            }
          }
          const up = parentDir(p)
          if (!up || up === p) break
          p = up
        }
      }
    }

    for (let i = 0; i < REQ.length; i++) {
      if (typeof cfg[REQ[i]] !== "string" || !cfg[REQ[i]]) {
        try { $.ui.log("catalyst-form broken form-rule-missing:" + REQ[i]) } catch (x) {}
        return next(e)
      }
    }
    if (typeof cfg.path_lines_min !== "number") {
      try { $.ui.log("catalyst-form broken form-rule-missing:path_lines_min") } catch (x) {}
      return next(e)
    }

    let cwd = ""
    try { cwd = String(await $.store.get(CWD_KEY) || "") } catch (x) { cwd = "" }

    const evs: any[] = []
    const sk: string[] = []
    const byPath = async (p: string) => {
      const t = await readText($, p)
      if (t === null) return
      const k = formKind(p, t, cfg)
      if (k) evs.push({ kind: k, text: t, label: tool + ":" + p })
      else sk.push(p)
    }

    if (tool === "Agent" || tool === "Task" || tool === "SendMessage") {
      const tx = String((e && (e.prompt || e.message || e.text)) || "")
      const pu: string[] = []
      const re = K(cfg.brief_ref, "gu")
      let m: RegExpExecArray | null
      while ((m = re.exec(tx)) && pu.length < 4) {
        const rp = resolvePath(m[0], homeS, cwd)
        if (pu.indexOf(rp) < 0) pu.push(rp)
      }
      for (let i = 0; i < pu.length; i++) await byPath(pu[i])
      if (tool === "SendMessage") evs.push({ kind: "message", text: tx, label: "SendMessage:message" })
    } else if (tool === "Write") {
      const fp = String((e && e.file_path) || "")
      const ct = String((e && e.content) || "")
      const k = formKind(fp, ct, cfg)
      if (k) evs.push({ kind: k, text: ct, label: "Write:" + fp })
      else sk.push(fp)
    } else if (tool === "Edit") {
      const fp = String((e && e.file_path) || "")
      const cur = await readText($, fp)
      if (cur !== null) {
        const oldS = String((e && e.old_string) || "")
        const newS = String((e && e.new_string) || "")
        const post = e && e.replace_all ? cur.split(oldS).join(newS) : cur.replace(oldS, newS)
        const k = formKind(fp, post, cfg)
        if (k) evs.push({ kind: k, text: post, label: "Edit:" + fp })
        else sk.push(fp)
      }
    } else {
      const cmd = String((e && e.command) || "")
      const wr = K(cfg.write_redirect, "u").exec(cmd)
      if (wr) {
        const fp = resolvePath(wr[1], homeS, cwd)
        const hd = K(cfg.heredoc, "u").exec(cmd)
        let body = hd ? hd[2] : ""
        let post = body
        if (/>>|tee/.test(wr[0])) {
          const cur = await readText($, fp)
          post = (cur === null ? "" : cur) + ((cur && cur.length && !cur.endsWith("\n")) ? "\n" : "") + body
        }
        const k = formKind(fp, post, cfg)
        if (k) evs.push({ kind: k, text: post, label: "Bash:" + fp })
        else sk.push(fp)
      }
      if (/git\s+(?:commit|push)\b/.test(cmd))
        evs.push({ kind: "command", text: cmd, label: "Bash:command" })
      if (!evs.length) return next(e)
    }

    if (!evs.length) return next(e)

    const rf: any[] = []
    const wn: any[] = []
    const cls: string[] = []
    for (let i = 0; i < evs.length; i++) {
      const r2 = formEval(evs[i], cfg)
      for (let j = 0; j < r2.refuse.length; j++) rf.push({ ...r2.refuse[j], src: evs[i].label })
      for (let j = 0; j < r2.warn.length; j++) wn.push({ ...r2.warn[j], src: evs[i].label })
    }
    for (let i = 0; i < rf.length; i++) if (cls.indexOf(rf[i].c) < 0) cls.push(rf[i].c)
    for (let i = 0; i < wn.length; i++) if (cls.indexOf(wn[i].c) < 0) cls.push(wn[i].c)
    const vk = rf.length ? "refuse" : (wn.length ? "warn" : "pass")
    const src3 = rf[0] || wn[0]
    const lbl = src3 ? src3.src : (evs[0] ? evs[0].label : tool)
    const cnts = cls.map((c3) => c3 + "×" + rf.concat(wn).filter((x) => x.c === c3).length).join(", ")
    const vd = (vk === "pass" ? "PASS" : vk === "warn" ? "WARN" : "REFUSE") + ": " +
      (vk === "pass" ? lbl : cnts + " — " + lbl + " — " + (src3 ? src3.c : "") + " :" + (src3 ? src3.n : "") + " " + (src3 ? src3.q : ""))

    const t0 = $.clock.now()
    const recName = "mod-" + String((e && e.tool_use_id) || "noid") + ".json"
    const jpath = globalHome + "/form/journal.jsonl"
    const recPath = globalHome + "/form/records/" + recName
    try {
      await appendJournal($, jpath, {
        t: new Date(t0).toISOString(), tool, outcome: vk, verdict: clip(vd, 400),
        cls, jm: "rules", tries: 0, rec: recName, carrier: "mod", sw: String(sw || ""),
        skipped: sk.slice(0, 8),
      })
    } catch (x) {}
    if (vk !== "pass") {
      try { $.fs.write(recPath, JSON.stringify({ ev: tool, cls, refuse: rf, warn: wn, vd })) } catch (x) {}
    }
    try { $.ui.log("catalyst-form " + vk + " " + cls.join(",")) } catch (x) {}

    if (vk === "refuse") {
      let cancel = false
      for (let i = 0; i < rf.length; i++) {
        if (actOf(cfg, rf[i].c) === "cancel") cancel = true
      }
      if (cancel) {
        const reason = cls.map((c) => textOf(cfg, c)).join("; ")
        return { deny: "Form probe refused the call (not the routing gate). " + reason }
      }
    }
    return next(e)
  })
}
