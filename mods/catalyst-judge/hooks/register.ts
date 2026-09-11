// CONSTRAINT: loader form — on("event") is a string literal; $ only as
// $.noun.verb(...) call sites; next.to(e, "<tier>") if used. A green
// `plugin validate` is not acceptance; read `hooks module … loaded`.
// CONSTRAINT: the awaited body of tool.call must return in well under
// 10 000 ms (host fail-open). Model consultation is detached.
// CONSTRAINT: CLAUDE_JUDGE_CARRIER=mod is what stands the splice down
// and arms this module; loading the plugin alone does nothing.
// CONSTRAINT: $.fs.ancestors accepts only relative .md names (measured
// host check). Project probes.toml is a 24-level walk of PWD with
// $.fs.read, matching the splice. process is not defined in the module;
// cwd is $.env.get("PWD").
// CONSTRAINT: $.fs.write overwrites and there is no append verb. The
// journal index line is a read-modify-write of journal.jsonl, detached.
// Unique records/mod-*.json are the durable source; compact.py folds
// any line the rmw lost.

const PENDING_MSG =
  "Adjudication is in progress for this dispatch. Wait a moment and repeat the SAME Agent/Task call unchanged. An unchanged retry is how the review completes. Do not switch to Bash or another tool."

const COACHING =
  "A subagent dispatch may be reviewed before it runs. " +
  "If the tool error says adjudication is in progress: wait briefly and repeat the SAME dispatch unchanged; an unchanged retry is how the review completes. " +
  "If the tool error names a correction: treat that reason as a correction to apply. Reissue the dispatch only with the change it names, and never repeat the identical call — an unchanged retry cannot succeed. " +
  "This review is separate from the permission system and from any routing gate, so do not attribute a cancellation to either."

function envOn(v: any): boolean {
  const s = String(v ?? "").trim().toLowerCase()
  return !(s === "" || s === "0" || s === "false" || s === "off" || s === "no")
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

function listField(src: string, key: string): string[] {
  const re = new RegExp(key + "\\s*=\\s*\\[([^\\]]*)\\]")
  const m = re.exec(src)
  if (!m) return []
  const out: string[] = []
  const inner = m[1]
  const reQ = /"([^"]*)"/g
  let q: RegExpExecArray | null
  while ((q = reQ.exec(inner))) out.push(q[1])
  return out
}

function hasField(src: string, key: string): boolean {
  return new RegExp(key + "\\s*=\\s*\\[").test(src)
}

function pickList(globalSrc: string, projectSrc: string, key: string): string[] {
  if (projectSrc && hasField(projectSrc, key)) return listField(projectSrc, key)
  return listField(globalSrc, key)
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

async function resolveRel($: any, rel: string): Promise<string> {
  const marker = String(rel).replace(/\/+$/, "") + "/.__catalyst_abs__"
  try {
    await $.fs.read(marker)
    return ""
  } catch (x) {
    const m = String(x)
    const key = "$.fs.read("
    const a = m.indexOf(key)
    const b = m.indexOf(") failed:")
    if (a >= 0 && b > a) {
      const path = m.slice(a + key.length, b)
      const suf = "/.__catalyst_abs__"
      if (path.endsWith(suf)) return path.slice(0, -suf.length)
    }
    return ""
  }
}

function outcomeOf(kind: string): string {
  if (kind === "OK" || kind === "WARN") return "ok"
  if (kind === "BLOCK" || kind === "STOP" || kind === "DENY") return "block"
  if (kind === "NONE") return "block_no_verdict"
  if (kind === "SKIP") return "skip"
  return "skip"
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
  const line = JSON.stringify(obj)
  let prev = ""
  try { prev = String(await $.fs.read(jpath) || "") } catch (x) { prev = "" }
  let pfx = ""
  if (prev.length > 0 && prev.charCodeAt(prev.length - 1) !== 10) pfx = "\n"
  try { await $.fs.write(jpath, prev + pfx + line + "\n") } catch (x) {
    try { $.ui.log("catalyst-judge journal: " + String(x).slice(0, 160)) } catch (y) {}
  }
}

export function register(on: any) {
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
    // CONSTRAINT: a retry mints a new tool_use_id. PENDING/OK must key on the
    // dispatch (tool+agent+prompt), or each retry starts a new ladder (measured:
    // 64 denies / 63 records on one Agent ping when keyed by tool_use_id).
    const key = "verdict:" + tool + "|" + agent + "|" + String(prompt.length) + "|" + prompt.slice(0, 160) + "|" + prompt.slice(-160)
    let stored: any
    try { stored = await $.store.get(key) } catch (x) { stored = undefined }

    if (stored && typeof stored === "object" && stored.kind) {
      if (stored.kind === "OK" || stored.kind === "WARN") return next(e)
      if (stored.kind === "PENDING") return { deny: PENDING_MSG }
      if (stored.kind === "BLOCK" || stored.kind === "STOP" || stored.kind === "DENY") {
        return { deny: "Subagent dispatch cancelled by the dispatch judge (this is NOT the routing-table.toml gate). Reason: " + String(stored.rest || stored.kind) }
      }
      if (stored.kind === "NONE") {
        return { deny: "Subagent dispatch cancelled: the judge obtained no verdict on any rung. This is NOT the routing-table.toml gate. Tell the human and do the work without a subagent, or retry later." }
      }
    }

    const cls = classesOf(prompt)
    const amb = cls.length > 1
    const cl = cls.length === 1 ? cls[0] : ""

    let probesDir: any = ""
    try { probesDir = await $.env.get("CLAUDE_PROBES_DIR") } catch (x) { probesDir = "" }
    let configDir: any = ""
    try { configDir = await $.env.get("CLAUDE_CONFIG_DIR") } catch (x) { configDir = "" }
    let home: any = ""
    try { home = await $.env.get("HOME") } catch (x) { home = "" }
    let pwd: any = ""
    try { pwd = await $.env.get("PWD") } catch (x) { pwd = "" }

    let globalHome = ""
    const probesDirS = String(probesDir || "").trim()
    const configDirS = String(configDir || "").trim()
    const homeS = String(home || "")
    if (probesDirS) globalHome = probesDirS
    else if (configDirS) globalHome = configDirS + "/probes"
    else globalHome = homeS + "/.claude/probes"

    const globalTomlR = await readText($, globalHome + "/probes.toml")
    const globalToml = globalTomlR.text || ""

    let projectHome = ""
    let projectToml = ""
    if (!probesDirS) {
      // CONSTRAINT: process is not defined here. PWD can be absent (env -i)
      // or stale. $.fs.read of a relative path is resolved against the host
      // cwd (measured). Walk "../".repeat(i)+".claude/probes". Skip the
      // candidate whose resolved path is the global home (same as splice).
      let dots = ""
      for (let i = 0; i < 24; i++) {
        const rel = dots + ".claude/probes"
        const files = [
          rel + "/probes.toml",
          rel + "/judge/prompt.md",
          rel + "/judge/prompt.extra.md",
          rel + "/judge/body.json",
        ]
        let hit = false
        for (let j = 0; j < files.length; j++) {
          const r = await readText($, files[j])
          if (r.unreadable) { hit = true; break }
          if (r.text !== null) { hit = true; break }
        }
        if (hit) {
          let abs = await resolveRel($, rel)
          if (!abs && pwd) {
            let q = String(pwd)
            for (let k = 0; k < i; k++) q = parentDir(q)
            if (q) abs = q + "/.claude/probes"
          }
          if (!(abs && normTmp(abs) === normTmp(globalHome))) {
            projectHome = abs || rel
            const pt = await readText($, rel + "/probes.toml")
            projectToml = pt.text || ""
            break
          }
        }
        dots = dots + "../"
      }
    }

    const skipC = pickList(globalToml, projectToml, "classes_skip")
    const skipA = pickList(globalToml, projectToml, "agents_skip")
    const judgeC = pickList(globalToml, projectToml, "classes_judge")
    const judgeA = pickList(globalToml, projectToml, "agents_judge")
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

    const recName = "mod-" + (id || "noid") + ".json"
    const recPath = globalHome + "/judge/records/" + recName
    const jpath = globalHome + "/judge/journal.jsonl"
    const t0 = $.clock.now()

    if (by) {
      try { $.ui.log("catalyst-judge filtered " + by + " cls=" + cl + " project=" + projectHome) } catch (x) {}
      const rec: any = {
        id, tool, agent, cls, by, kind: "SKIP", t0,
        projectHome, globalHome, carrier: "mod",
      }
      try { $.fs.write(recPath, JSON.stringify(rec)) } catch (x) {}
      ;(async () => {
        try {
          await appendJournal($, jpath, {
            t: new Date(t0).toISOString(),
            tool, agent, outcome: "skip",
            rec: recName, carrier: "mod",
            reason: by, cls, ms: 0, sw: String(sw || ""),
          })
        } catch (x) {}
      })()
      return next(e)
    }

    try { await $.store.set(key, { kind: "PENDING" }) } catch (x) {}

    ;(async () => {
      const rec: any = { id, tool, agent, cls, t0, projectHome, globalHome, carrier: "mod" }
      try {
        let sys = ""
        const gPrompt = await readText($, globalHome + "/judge/prompt.md")
        if (gPrompt.text) sys = gPrompt.text
        if (projectHome) {
          const pPrompt = await readText($, projectHome + "/judge/prompt.md")
          if (pPrompt.text) sys = pPrompt.text
          const extra = await readText($, projectHome + "/judge/prompt.extra.md")
          if (extra.text) sys = sys + "\n\nПРАВИЛА ЭТОГО ПРОЕКТА\n" + extra.text
        }
        let msgs: any[] = []
        try { msgs = await $.session.messages() } catch (x) { msgs = [] }
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
        const context = ctx.join("\n").slice(-24000)
        const dispatch = JSON.stringify({
          tool,
          subagent_type: agent,
          model: e && e.model,
          prompt: prompt.slice(0, 16000),
        })
        const user = "=== SESSION SO FAR ===\n" + context + "\n\n=== DISPATCH ===\n" + dispatch
        const full = (sys ? sys + "\n\n" : "") + user
        const models = ["deepseek-flash", "glm-5.3", "gpt-5.6-terra"]
        let verdict: { kind: string; rest: string } | null = null
        let used = ""
        for (let i = 0; i < models.length; i++) {
          used = models[i]
          try {
            const raw = await $.model.complete({ model: models[i], prompt: full })
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
          await $.store.set(key, { kind: verdict.kind, rest: verdict.rest, used, dtMs: rec.dtMs })
        } else {
          rec.kind = "NONE"
          await $.store.set(key, { kind: "NONE", used, dtMs: rec.dtMs })
        }
      } catch (x) {
        rec.threw = String(x).slice(0, 400)
        rec.dtMs = $.clock.now() - t0
        try { await $.store.set(key, { kind: "NONE", threw: rec.threw, dtMs: rec.dtMs }) } catch (y) {}
      }
      try { $.fs.write(recPath, JSON.stringify(rec)) } catch (x) {
        try { $.ui.log("catalyst-judge journal write: " + String(x).slice(0, 160)) } catch (y) {}
      }
      try {
        const kind = String(rec.kind || "NONE")
        const rest = String(rec.rest || "")
        await appendJournal($, jpath, {
          t: new Date(t0).toISOString(),
          tool, agent,
          ms: rec.dtMs,
          sw: String(sw || ""),
          outcome: outcomeOf(kind),
          verdict: (kind + ": " + rest).slice(0, 400),
          jm: rec.used,
          rec: recName,
          carrier: "mod",
          cls,
        })
      } catch (x) {}
      try { $.ui.log("catalyst-judge done kind=" + rec.kind + " dt=" + rec.dtMs) } catch (x) {}
    })()

    return { deny: PENDING_MSG }
  })
}
