// CONSTRAINT: on("event") literal; $.noun.verb only. CLAUDE_IDLE empty = OFF.
// CLAUDE_IDLE_CARRIER=mod stands the splice down. Consultation detached.
// NUDGE: $.ui.toast (measured). Never {deny}.

const LAST_KEY = "catalyst-idle:last"
const CWD_KEY = "catalyst-idle:cwd"

function envOn(v: any): boolean {
  const s = String(v ?? "").trim().toLowerCase()
  return !(s === "" || s === "0" || s === "false" || s === "off" || s === "no")
}

function parseVerdict(raw: string): { kind: string; rest: string } | null {
  const text = String(raw ?? "")
  const lines = text.split("\n")
  for (let i = 0; i < lines.length; i++) {
    const m = /^(SILENT|NUDGE):\s*(.*)$/.exec(lines[i].trim())
    if (m) return { kind: m[1], rest: m[2] }
  }
  return null
}

async function readText($: any, path: string): Promise<string | null> {
  try {
    const v = await $.fs.read(path)
    if (v == null) return null
    return String(v)
  } catch (x) { return null }
}

async function appendJournal($: any, jpath: string, obj: any) {
  const line = JSON.stringify(obj)
  let prev = ""
  try { prev = String(await $.fs.read(jpath) || "") } catch (x) { prev = "" }
  let pfx = ""
  if (prev.length > 0 && prev.charCodeAt(prev.length - 1) !== 10) pfx = "\n"
  try { await $.fs.write(jpath, prev + pfx + line + "\n") } catch (x) {}
}

export function register(on: any) {
  on("session.start", async ($: any, e: any, next: any) => {
    try { if (e && e.cwd) await $.store.set(CWD_KEY, String(e.cwd)) } catch (x) {}
    return next(e)
  })

  on("tool.call", async ($: any, e: any, next: any) => {
    if ("agentId" in e) return next(e)
    let carrier: any = ""
    try { carrier = await $.env.get("CLAUDE_IDLE_CARRIER") } catch (x) { carrier = "" }
    if (String(carrier).trim().toLowerCase() !== "mod") return next(e)
    let sw: any = ""
    try { sw = await $.env.get("CLAUDE_IDLE") } catch (x) { sw = "" }
    if (!envOn(sw)) return next(e)

    const tool = String((e && e.tool) || "")
    if (tool === "Agent" || tool === "Task") return next(e)

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

    let live = 0
    try {
      const lst = await $.agent.list()
      if (Array.isArray(lst)) live = lst.length
    } catch (x) {}
    if (live > 0) return next(e)

    const t0 = $.clock.now()
    let last: any = 0
    try { last = Number(await $.store.get(LAST_KEY) || 0) } catch (x) { last = 0 }
    const cooldownMs = 30 * 60 * 1000
    const toml = await readText($, globalHome + "/probes.toml")
    let cd = cooldownMs
    if (toml) {
      const m = /cooldown_min\s*=\s*(\d+)/.exec(toml)
      if (m) cd = parseInt(m[1], 10) * 60 * 1000
    }
    if (last && t0 - last < cd) return next(e)
    try { await $.store.set(LAST_KEY, t0) } catch (x) {}

    ;(async () => {
      const rec: any = { t0, tool, live, carrier: "mod" }
      try {
        let sys = await readText($, globalHome + "/idle-watch/prompt.md")
        if (!sys) sys = "Answer with ONE line: SILENT:<why> or NUDGE:<what the fleet should be doing>."
        let msgs: any[] = []
        try { msgs = await $.session.messages() } catch (x) { msgs = [] }
        const ctx: string[] = []
        if (Array.isArray(msgs)) {
          for (let i = 0; i < msgs.length; i++) {
            const m = msgs[i]
            ctx.push(String((m && m.role) || "") + ": " + String((m && m.text) || "").slice(0, 1500))
          }
        }
        const raw = await $.model.complete({
          model: "deepseek-flash",
          prompt: sys + "\n\n=== SESSION ===\n" + ctx.join("\n").slice(-20000),
        })
        rec.raw = String(raw).slice(0, 400)
        const v = parseVerdict(String(raw))
        rec.kind = v ? v.kind : "NONE"
        rec.rest = v ? v.rest : ""
        if (v && v.kind === "NUDGE") {
          try { await $.ui.toast("fleet: " + v.rest.slice(0, 200)) } catch (x) { rec.toastErr = String(x).slice(0, 160) }
        }
      } catch (x) {
        rec.threw = String(x).slice(0, 300)
        rec.kind = "NONE"
      }
      rec.dtMs = $.clock.now() - t0
      try {
        await appendJournal($, globalHome + "/idle-watch/journal.jsonl", {
          t: new Date(t0).toISOString(), tool, outcome: rec.kind, ms: rec.dtMs,
          verdict: String(rec.kind) + ": " + String(rec.rest || ""), carrier: "mod",
        })
      } catch (x) {}
      try { $.ui.log("catalyst-idle " + rec.kind + " dt=" + rec.dtMs) } catch (x) {}
    })()
    return next(e)
  })
}
