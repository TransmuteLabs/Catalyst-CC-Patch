// CONSTRAINT: loader form — on("event") is a string literal; $ only as
// $.noun.verb(...) call sites; next.to(e, "<tier>") if used. A green
// `plugin validate` is not acceptance; read `hooks module … loaded`.
// CONSTRAINT: the awaited body of tool.call must return in well under
// 10 000 ms (host fail-open). Model consultation is detached.
// CONSTRAINT: CLAUDE_JUDGE_CARRIER=mod is what stands the splice down
// and arms this module; loading the plugin alone does nothing.

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

function classesOf(prompt: string): string[] {
  const found = String(prompt).match(/\[dispatch-class:[\w-]+\]/g) || []
  const set: string[] = []
  for (let i = 0; i < found.length; i++) {
    const c = found[i].slice(16, -1)
    if (set.indexOf(c) < 0) set.push(c)
  }
  return set
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

    let home: any = ""
    try { home = await $.env.get("HOME") } catch (x) { home = "" }
    const tomlPath = String(home) + "/.claude/probes/probes.toml"
    let toml = ""
    try { toml = String(await $.fs.read(tomlPath) || "") } catch (x) { toml = "" }
    try {
      const local = String(await $.fs.read(".claude/probes/probes.toml") || "")
      if (local) toml = toml + "\n" + local
    } catch (x) {}

    const skipC = listField(toml, "classes_skip")
    const skipA = listField(toml, "agents_skip")
    const judgeC = listField(toml, "classes_judge")
    const judgeA = listField(toml, "agents_judge")
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
      try { $.ui.log("catalyst-judge filtered " + by + " cls=" + cl) } catch (x) {}
      return next(e)
    }

    try { await $.store.set(key, { kind: "PENDING" }) } catch (x) {}

    const t0 = $.clock.now()
    ;(async () => {
      const rec: any = { id, tool, agent, cls, t0 }
      try {
        let sys = ""
        try { sys = String(await $.fs.read(String(home) + "/.claude/probes/judge/prompt.md") || "") } catch (x) { sys = "" }
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
      try {
        $.fs.write(
          String(home) + "/.claude/probes/judge/records/mod-" + id + ".json",
          JSON.stringify(rec),
        )
      } catch (x) {
        try { $.ui.log("catalyst-judge journal write: " + String(x).slice(0, 160)) } catch (y) {}
      }
      try { $.ui.log("catalyst-judge done kind=" + rec.kind + " dt=" + rec.dtMs) } catch (x) {}
    })()

    return { deny: PENDING_MSG }
  })
}
