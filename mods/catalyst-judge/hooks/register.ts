// CONSTRAINT: loader form — on("event") is a string literal; $ only as
// $.noun.verb(...) call sites. A green `plugin validate` is not acceptance.
// CONSTRAINT: awaited tool.call must return well under 10 000 ms. Consultation
// is detached. CLAUDE_JUDGE_CARRIER=mod stands the splice down.
// CONSTRAINT: process and Bun are undefined in the module (measured). Cwd is
// session.start's e.cwd, stashed in $.store; fallback is relative $.fs.read
// against the host cwd. $.fs.ancestors rejects non-.md names.
// CONSTRAINT: $.fs.write overwrites. Unique records/mod-*.json are durable;
// journal.jsonl is never RMW'd (short read replaced 6302 lines, 2026-09-12).
// Index line → journal.jsonl.shard.<rec>; compact.py fold_journal_shards.

const PENDING_MSG =
  "Adjudication is in progress for this dispatch. Wait a moment and repeat the SAME Agent/Task call unchanged. An unchanged retry is how the review completes. Do not switch to Bash or another tool."

const COACHING =
  "A subagent dispatch may be reviewed before it runs. " +
  "If the tool error says adjudication is in progress: wait briefly and repeat the SAME dispatch unchanged; an unchanged retry is how the review completes. " +
  "If the tool error names a correction: treat that reason as a correction to apply. Reissue the dispatch only with the change it names, and never repeat the identical call — an unchanged retry cannot succeed. " +
  "This review is separate from the permission system and from any routing gate, so do not attribute a cancellation to either."

const CWD_KEY = "catalyst-judge:cwd"

function envOn(v: any): boolean {
  const s = String(v ?? "").trim().toLowerCase()
  return !(s === "" || s === "0" || s === "false" || s === "off" || s === "no")
}

function bl3(v: any, defaultTrue: boolean): boolean {
  if (v === undefined || v === null) return defaultTrue
  if (v === false || v === 0) return false
  const s = String(v).trim().toLowerCase()
  if (s === "" || s === "0" || s === "false" || s === "off" || s === "no") return false
  return true
}

function num(v: any, fallback: number, floor: number): number {
  const n = typeof v === "number" ? v : parseInt(String(v ?? ""), 10)
  if (!(n >= floor)) return fallback
  return n
}

function parseVerdict(raw: string): { kind: string; rest: string } | null {
  const text = String(raw ?? "")
  const first = text.split("\n")[0].trim()
  const m = /^(OK|BLOCK|STOP|DENY|WARN):\s*(.*)$/.exec(first)
  if (m) return { kind: m[1], rest: m[2] }
  const lines = text.split("\n")
  for (let i = lines.length - 1; i >= 0; i--) {
    const mm = /^(OK|BLOCK|STOP|DENY|WARN):\s*(.*)$/.exec(lines[i].trim())
    if (mm) return { kind: mm[1], rest: mm[2] }
  }
  return null
}

function fnv1a(s: string): string {
  let h = 2166136261
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return (h >>> 0).toString(16)
}

function classesOf(prompt: string): string[] {
  const found = String(prompt).match(/\[dispatch-class:[\w-]+\]/g) || []
  const set: string[] = []
  for (let i = 0; i < found.length; i++) {
    const c = found[i].slice(16, -1)
    if (set.indexOf(c) < 0) set.push(c)
  }
  return set
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

function outcomeOf(kind: string): string {
  if (kind === "OK" || kind === "WARN") return "ok"
  if (kind === "BLOCK" || kind === "STOP" || kind === "DENY") return "block"
  if (kind === "NONE") return "block_no_verdict"
  if (kind === "SKIP") return "skip"
  return "skip"
}

function parseVal(raw: string): any {
  let s = String(raw || "").trim()
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
  if (/^-?\d+\.\d+$/.test(s)) return parseFloat(s)
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

function flattenJudge(parsed: any): any {
  const defaults = (parsed && parsed.defaults) || {}
  const judge = (parsed && parsed.probe && parsed.probe.judge) || {}
  const out: any = {}
  const dk = Object.keys(defaults)
  for (let i = 0; i < dk.length; i++) out[dk[i]] = defaults[dk[i]]
  const jk = Object.keys(judge)
  for (let i = 0; i < jk.length; i++) out[jk[i]] = judge[jk[i]]
  return out
}

function listOf(cfg: any, key: string): string[] {
  const f = cfg && cfg.filter
  const v = f && f[key]
  if (!Array.isArray(v)) return []
  const out: string[] = []
  for (let i = 0; i < v.length; i++) out.push(String(v[i]))
  return out
}

function rungsOf(cfg: any, modelEnv: string): { model: string; effort?: string; max_tokens?: number; timeout_ms?: number; context_chars?: number }[] {
  if (modelEnv) return [{ model: modelEnv }]
  const raw = cfg && cfg.models
  const out: { model: string; effort?: string; max_tokens?: number; timeout_ms?: number; context_chars?: number }[] = []
  if (Array.isArray(raw) && raw.length) {
    for (let i = 0; i < raw.length; i++) {
      const x = raw[i]
      if (typeof x === "string" && x) out.push({ model: x })
      else if (x && typeof x === "object" && x.model) {
        const r: any = { model: String(x.model) }
        if (x.effort) r.effort = String(x.effort)
        if (x.max_tokens != null) r.max_tokens = num(x.max_tokens, 0, 1)
        if (x.timeout_ms != null) r.timeout_ms = num(x.timeout_ms, 0, 1)
        if (x.context_chars != null) r.context_chars = num(x.context_chars, 0, 1)
        out.push(r)
      }
    }
  }
  if (!out.length && cfg && cfg.model) out.push({ model: String(cfg.model) })
  if (!out.length) out.push({ model: "glm-5.3" })
  return out
}

async function readText($: any, path: string): Promise<{ text: string | null; unreadable: string }> {
  try {
    const v = await $.fs.read(path)
    if (v === null || v === undefined) return { text: null, unreadable: "" }
    return { text: String(v), unreadable: "" }
  } catch (x) {
    const m = String(x)
    if (m.indexOf("ENOENT") >= 0) return { text: null, unreadable: "" }
    return { text: null, unreadable: m.slice(0, 160) }
  }
}

async function appendJournal($: any, jpath: string, obj: any) {
  // CONSTRAINT: $.fs.write overwrites the whole path. RMW of journal.jsonl
  // is fail-open on a short/failed read: a 5.7 MB index was replaced with
  // one line (2026-09-12). Unique sibling; compact.py folds it in.
  const line = JSON.stringify(obj) + "\n"
  const rec = String((obj && obj.rec) || ("t" + String($.clock.now())))
  let safe = ""
  for (let i = 0; i < rec.length; i++) {
    const c = rec.charAt(i)
    safe += /[A-Za-z0-9._-]/.test(c) ? c : "_"
  }
  const shard = jpath + ".shard." + safe
  try { await $.fs.write(shard, line) } catch (x) {
    try { $.ui.log("catalyst-judge journal: " + String(x).slice(0, 160)) } catch (y) {}
  }
}

async function layerHit($: any, ch: string): Promise<boolean> {
  // One existence probe per level: host logs ERROR on ENOENT from $.fs.read
  // (no access() in the module). probes.toml is the layer's discriminator;
  // prompt-only project dirs without toml are not this port's contract.
  const r = await readText($, ch + "/probes.toml")
  return !!(r.unreadable || r.text !== null)
}

async function findProjectHome($: any, cwd: string, globalHome: string): Promise<string> {
  if (cwd) {
    let p = cwd
    for (let i = 0; i < 24; i++) {
      if (!p) break
      const ch = p + "/.claude/probes"
      if (normTmp(ch) !== normTmp(globalHome) && await layerHit($, ch)) return ch
      const up = parentDir(p)
      if (!up || up === p) break
      p = up
    }
    return ""
  }
  let dots = ""
  for (let i = 0; i < 24; i++) {
    const rel = dots + ".claude/probes"
    if (await layerHit($, rel)) return rel
    dots = dots + "../"
  }
  return ""
}

export function register(on: any) {
  on("session.start", async ($: any, e: any, next: any) => {
    try {
      const cwd = e && e.cwd
      if (cwd) await $.store.set(CWD_KEY, String(cwd))
    } catch (x) {}
    return next(e)
  })

  on("prompt.section", async ($: any, e: any, next: any) => {
    let carrier: any = ""
    try { carrier = await $.env.get("CLAUDE_JUDGE_CARRIER") } catch (x) { carrier = "" }
    if (String(carrier).trim().toLowerCase() !== "mod") return next(e)
    let sw: any = ""
    try { sw = await $.env.get("CLAUDE_JUDGE") } catch (x) { sw = "" }
    if (!envOn(sw)) return next(e)
    const name = String((e && e.name) || "")
    if (name !== "communication:L") return next(e)
    const text = String((e && e.text) || "") + "\n\n" + COACHING
    return next(Object.assign({}, e, { text }))
  })

  on("tool.call", async ($: any, e: any, next: any) => {
    const tool = String((e && e.tool) || "")
    if (tool !== "Agent" && tool !== "Task") return next(e)
    if ("agentId" in e) return next(e)

    let carrier: any = ""
    try { carrier = await $.env.get("CLAUDE_JUDGE_CARRIER") } catch (x) { carrier = "" }
    if (String(carrier).trim().toLowerCase() !== "mod") return next(e)
    let sw: any = ""
    try { sw = await $.env.get("CLAUDE_JUDGE") } catch (x) { sw = "" }
    if (!envOn(sw)) return next(e)

    const id = String((e && e.tool_use_id) || "")
    const prompt = String((e && e.prompt) || "")
    const agent = String((e && e.subagent_type) || "")
    // CONSTRAINT: $.store keys max 256 chars (measured: 302-char dispatch
    // digest of head+tail threw; PENDING never landed and retries re-ran
    // the ladder). Hash the prompt; keep tool/agent/len as plaintext.
    const key = "v:" + tool + "|" + agent + "|" + String(prompt.length) + "|" + fnv1a(prompt)
    let stored: any
    try { stored = await $.store.get(key) } catch (x) { stored = undefined }

    let probesDir: any = ""
    try { probesDir = await $.env.get("CLAUDE_PROBES_DIR") } catch (x) { probesDir = "" }
    let configDir: any = ""
    try { configDir = await $.env.get("CLAUDE_CONFIG_DIR") } catch (x) { configDir = "" }
    let home: any = ""
    try { home = await $.env.get("HOME") } catch (x) { home = "" }
    let pwd: any = ""
    try { pwd = await $.env.get("PWD") } catch (x) { pwd = "" }
    let modelEnv: any = ""
    try { modelEnv = await $.env.get("CLAUDE_JUDGE_MODEL") } catch (x) { modelEnv = "" }
    let promptEnv: any = ""
    try { promptEnv = await $.env.get("CLAUDE_JUDGE_PROMPT") } catch (x) { promptEnv = "" }
    let tmoEnv: any = ""
    try { tmoEnv = await $.env.get("CLAUDE_JUDGE_TIMEOUT_MS") } catch (x) { tmoEnv = "" }

    const probesDirS = String(probesDir || "").trim()
    const configDirS = String(configDir || "").trim()
    const homeS = String(home || "")
    let globalHome = ""
    if (probesDirS) globalHome = probesDirS
    else if (configDirS) globalHome = configDirS + "/probes"
    else globalHome = homeS + "/.claude/probes"

    const globalTomlR = await readText($, globalHome + "/probes.toml")
    const globalCfg = flattenJudge(parseToml(globalTomlR.text || ""))

    // CONSTRAINT: $.store is per-plugin across sessions. Another session's
    // session.start overwrites CWD_KEY. PWD first; store only if PWD is empty.
    let cwd = String(pwd || "").trim()
    if (!cwd) {
      try { cwd = String(await $.store.get(CWD_KEY) || "") } catch (x) { cwd = "" }
    }

    let projectHome = ""
    let projectCfg: any = {}
    if (!probesDirS) {
      projectHome = await findProjectHome($, cwd, globalHome)
      if (projectHome) {
        const pt = await readText($, projectHome + "/probes.toml")
        if (pt.text) projectCfg = flattenJudge(parseToml(pt.text))
      }
    }
    const cfg: any = {}
    const gk = Object.keys(globalCfg)
    for (let i = 0; i < gk.length; i++) cfg[gk[i]] = globalCfg[gk[i]]
    const pk = Object.keys(projectCfg)
    for (let i = 0; i < pk.length; i++) cfg[pk[i]] = projectCfg[pk[i]]

    const recName = "mod-" + (id || "noid") + ".json"
    const recPath = globalHome + "/judge/records/" + recName
    const jpath = globalHome + "/judge/journal.jsonl"
    const t0 = $.clock.now()
    const doRecord = cfg.record !== false
    const swS = String(sw || "")
    const enforce = swS === "enforce" || bl3(cfg.enforce, true)
    const failClosed = bl3(cfg.fail_closed, true)

    if (stored && typeof stored === "object" && stored.kind) {
      if (stored.kind === "OK" || stored.kind === "WARN") return next(e)
      if (stored.kind === "PENDING") return { deny: PENDING_MSG }
      if (stored.kind === "BLOCK" || stored.kind === "STOP" || stored.kind === "DENY") {
        if (!enforce) return next(e)
        return { deny: "Subagent dispatch cancelled by the dispatch judge (this is NOT the routing-table.toml gate). Reason: " + String(stored.rest || stored.kind) }
      }
      if (stored.kind === "NONE") {
        if (!failClosed) return next(e)
        return { deny: "Subagent dispatch cancelled: the judge obtained no verdict on any rung. This is NOT the routing-table.toml gate. Tell the human and do the work without a subagent, or retry later." }
      }
    }

    if (cfg.enabled === false) {
      try { $.ui.log("catalyst-judge skip_disabled") } catch (x) {}
      ;(async () => {
        try {
          await appendJournal($, jpath, {
            t: new Date(t0).toISOString(), tool, agent, outcome: "skip_disabled",
            rec: recName, carrier: "mod", sw: swS, ms: 0,
          })
        } catch (x) {}
      })()
      return next(e)
    }

    const cls = classesOf(prompt)
    const amb = cls.length > 1
    const cl = cls.length === 1 ? cls[0] : ""
    const skipC = listOf(cfg, "classes_skip")
    const skipA = listOf(cfg, "agents_skip")
    const judgeC = listOf(cfg, "classes_judge")
    const judgeA = listOf(cfg, "agents_judge")
    let by: string | null = null
    if (!amb) {
      for (let i = 0; i < skipC.length; i++) {
        try { if (cl && new RegExp(skipC[i]).test(cl)) { by = "classes_skip"; break } } catch (x) {}
      }
    }
    if (!by) {
      for (let i = 0; i < skipA.length; i++) {
        try { if (agent && new RegExp(skipA[i]).test(agent)) { by = "agents_skip"; break } } catch (x) {}
      }
    }
    if (!by && (judgeC.length > 0 || judgeA.length > 0) && !amb) {
      let hit = false
      for (let i = 0; i < judgeC.length; i++) {
        try { if (cl && new RegExp(judgeC[i]).test(cl)) hit = true } catch (x) {}
      }
      for (let i = 0; i < judgeA.length; i++) {
        try { if (agent && new RegExp(judgeA[i]).test(agent)) hit = true } catch (x) {}
      }
      if (!hit) by = cl ? "not_in_judge_list" : "no_class_marker"
    }

    if (by) {
      try { $.ui.log("catalyst-judge filtered " + by + " cls=" + cl + " project=" + projectHome) } catch (x) {}
      const rec: any = { id, tool, agent, cls, by, kind: "SKIP", t0, projectHome, globalHome, carrier: "mod" }
      if (doRecord) { try { $.fs.write(recPath, JSON.stringify(rec)) } catch (x) {} }
      ;(async () => {
        try {
          await appendJournal($, jpath, {
            t: new Date(t0).toISOString(), tool, agent, outcome: "skip",
            rec: recName, carrier: "mod", reason: by, cls, ms: 0, sw: swS,
          })
        } catch (x) {}
      })()
      return next(e)
    }

    try { await $.store.set(key, { kind: "PENDING" }) } catch (x) {}

    ;(async () => {
      const rec: any = { id, tool, agent, cls, t0, projectHome, globalHome, carrier: "mod", en: enforce ? "config" : "off", fcl: failClosed, promptHead: prompt.slice(0, 240) }
      try {
        let sys = ""
        const promptPath = String(promptEnv || "").trim()
        if (promptPath) {
          const pr = await readText($, promptPath)
          if (pr.text) sys = pr.text
        } else {
          const gPrompt = await readText($, globalHome + "/judge/prompt.md")
          if (gPrompt.text) sys = gPrompt.text
          if (projectHome) {
            const pPrompt = await readText($, projectHome + "/judge/prompt.md")
            if (pPrompt.text) sys = pPrompt.text
            const extra = await readText($, projectHome + "/judge/prompt.extra.md")
            if (extra.text) sys = sys + "\n\nПРАВИЛА ЭТОГО ПРОЕКТА\n" + extra.text
          }
        }

        const atn = num(cfg.attach_files, 0, 0)
        const atc = num(cfg.attach_chars, 40000, 0)
        const atb = num(cfg.attach_total, 90000, 0)
        const att: { path: string; n: number }[] = []
        if (atn > 0 && atc > 0 && atb > 0) {
          const rx = /(~|\/)[A-Za-z0-9._~\/-]*\.(?:md|txt)(?![A-Za-z0-9])/g
          const seen: any = {}
          let sp = 0
          let mm: RegExpExecArray | null
          while ((mm = rx.exec(prompt)) && att.length < atn) {
            let f = mm[0]
            if (f.charAt(0) === "~") f = homeS + f.slice(1)
            if (seen[f]) continue
            seen[f] = 1
            const body = await readText($, f)
            if (body.text == null) continue
            let chunk = body.text
            if (chunk.length > atc) chunk = chunk.slice(0, atc)
            if (sp + chunk.length > atb) chunk = chunk.slice(0, Math.max(0, atb - sp))
            if (!chunk) break
            att.push({ path: f, n: chunk.length })
            sys = sys + "\n\n=== ATTACHED " + f + " ===\n" + chunk
            sp += chunk.length
          }
        }
        rec.att = att

        let msgs: any[] = []
        try { msgs = await $.session.messages() } catch (x) { msgs = [] }
        const ctxN = num(cfg.context_chars, 24000, 0) || 24000
        const ctx: string[] = []
        if (Array.isArray(msgs)) {
          for (let i = 0; i < msgs.length; i++) {
            const m = msgs[i]
            const role = String((m && m.role) || "")
            const text = String((m && m.text) || "")
            const kind = m && typeof m === "object" && "toolResults" in m ? "tool" : role
            ctx.push(kind + ": " + text.slice(0, 2000))
          }
        }
        const context = ctx.join("\n").slice(-ctxN)
        const dchars = num(cfg.dispatch_chars, 16000, 0) || 16000
        const dispatch = JSON.stringify({
          tool,
          subagent_type: agent,
          model: e && e.model,
          prompt: prompt.slice(0, dchars),
        })
        const user = "=== SESSION SO FAR ===\n" + context + "\n\n=== DISPATCH ===\n" + dispatch
        const full = (sys ? sys + "\n\n" : "") + user
        const ladder = rungsOf(cfg, String(modelEnv || "").trim())
        rec.ladder = ladder.map((r) => r.model)
        let verdict: { kind: string; rest: string } | null = null
        let used = ""
        const floorTok = num(cfg.max_tokens, 8000, 1)
        const floorTmo = num(tmoEnv, num(cfg.timeout_ms, 0, 1), 1)
        for (let i = 0; i < ladder.length; i++) {
          const rung = ladder[i]
          used = rung.model
          try {
            const arg: any = { model: rung.model, prompt: full }
            if (rung.effort) arg.effort = rung.effort
            const mt = rung.max_tokens || floorTok
            if (mt) arg.max_tokens = mt
            const tmo = rung.timeout_ms || floorTmo
            if (tmo) arg.timeoutMs = tmo
            const raw = await $.model.complete(arg)
            rec["raw_" + used] = String(raw).slice(0, 500)
            verdict = parseVerdict(String(raw))
            if (verdict) break
          } catch (x) {
            rec["err_" + used] = String(x).slice(0, 240)
          }
        }
        rec.dtMs = $.clock.now() - t0
        rec.used = used
        if (verdict) {
          rec.kind = verdict.kind
          rec.rest = verdict.rest
          await $.store.set(key, { kind: verdict.kind, rest: verdict.rest, used, dtMs: rec.dtMs, enforce, failClosed })
        } else {
          rec.kind = "NONE"
          await $.store.set(key, { kind: "NONE", used, dtMs: rec.dtMs, enforce, failClosed })
        }
      } catch (x) {
        rec.threw = String(x).slice(0, 400)
        rec.dtMs = $.clock.now() - t0
        try { await $.store.set(key, { kind: "NONE", threw: rec.threw, dtMs: rec.dtMs, enforce, failClosed }) } catch (y) {}
      }
      if (doRecord) {
        try { $.fs.write(recPath, JSON.stringify(rec)) } catch (x) {
          try { $.ui.log("catalyst-judge journal write: " + String(x).slice(0, 160)) } catch (y) {}
        }
      }
      try {
        const kind = String(rec.kind || "NONE")
        const rest = String(rec.rest || "")
        let oc = outcomeOf(kind)
        if ((kind === "BLOCK" || kind === "STOP" || kind === "DENY") && !enforce) oc = "block_not_enforced"
        await appendJournal($, jpath, {
          t: new Date(t0).toISOString(),
          tool, agent, ms: rec.dtMs, sw: swS,
          outcome: oc,
          verdict: (kind + ": " + rest).slice(0, 400),
          jm: rec.used, rec: recName, carrier: "mod", cls,
          en: enforce ? "config" : "off",
        })
      } catch (x) {}
      try { $.ui.log("catalyst-judge done kind=" + rec.kind + " dt=" + rec.dtMs + " jm=" + rec.used) } catch (x) {}
    })()

    return { deny: PENDING_MSG }
  })
}
