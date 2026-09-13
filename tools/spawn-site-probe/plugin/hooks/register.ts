// Прибор площадки agent.spawn. Мерит контракт хоста, продуктом не является.
// CONSTRAINT: on(event) — строковый литерал; $ только как $.noun.verb;
// имена env — строковые литералы (загрузчик их сканирует); process/Bun нет.
// CONSTRAINT: $.fs.write ПЕРЕЗАПИСЫВАЕТ — каждое срабатывание пишет свой файл.
// CONSTRAINT: ни один случай не называет haiku/sonnet — запрет юзера действует
// и в приборе: замер не имеет права породить запрещённый диспатч.
// CONSTRAINT: дом вывода приходит через CLAUDE_SPAWNPROBE_OUT. Путь не зашивать:
// прибор с зашитым домом мерит только ту машину, где его писали.

let seq = 0

function shallow(v: any): any {
  const t = typeof v
  if (v === null || t === "string" || t === "number" || t === "boolean") return v
  if (t === "undefined") return "<undefined>"
  if (t === "function") return "<function>"
  if (Array.isArray(v)) return "<array:" + v.length + ">"
  return "<object:" + Object.keys(v).join("|") + ">"
}

export function register(on: any) {
  on("agent.spawn", async ($: any, e: any, next: any) => {
    seq = seq + 1
    const n = seq

    let kase = ""
    let out = ""
    try { kase = String(await $.env.get("CLAUDE_SPAWNPROBE") || "") } catch (x) { kase = "" }
    try { out = String(await $.env.get("CLAUDE_SPAWNPROBE_OUT") || "") } catch (x) { out = "" }

    const payload: any = {}
    for (const k in e) payload[k] = shallow((e as any)[k])
    const rec: any = { seq: n, case: kase, keys: Object.keys(e).sort(), payload: payload }
    // Отрицательный контроль поверхности: resolveModel есть на месте вызова,
    // но модулю не выдаётся. Пишем факт, а не предположение.
    rec.resolveModel_exposed = typeof (e as any).resolveModel === "function"
    if (out) { try { await $.fs.write(out + "/ev-" + kase + "-" + n + ".json", JSON.stringify(rec, null, 1)) } catch (x) {} }

    // Ответы площадки.
    if (kase === "deny") return { deny: "SPAWNPROBE-DENY" }
    if (kase === "neither") return {}
    if (kase === "modelopus") return { model: "opus" }
    if (kase === "modelbogus") return { model: "SPAWNPROBE-NO-SUCH-MODEL" }

    // Переписи аргумента.
    if (kase === "rewrite") {
      return next(Object.assign({}, e, {
        prompt: String(e.prompt || "") + "\n\nSPAWNPROBE-REWRITE",
        description: "SPAWNPROBE-DESC",
      }))
    }
    if (kase === "pinned") {
      return next(Object.assign({}, e, { tool_use_id: "SPAWNPROBE-PIN" }))
    }
    if (kase === "retype") {
      return next(Object.assign({}, e, { subagentType: "probe-beta" }))
    }
    if (kase === "retypeghost") {
      return next(Object.assign({}, e, { subagentType: "SPAWNPROBE-NO-SUCH-AGENT" }))
    }

    // Бюджет и примитивы консультации.
    if (kase === "slow") {
      const t0 = $.clock.now()
      await new Promise((r: any) => setTimeout(r, 12000))
      if (out) { try { await $.fs.write(out + "/slow-" + n + ".json", JSON.stringify({ seq: n, spentMs: $.clock.now() - t0 })) } catch (x) {} }
      return next(e)
    }
    if (kase === "complete") {
      const t0 = $.clock.now()
      const r: any = { seq: n }
      try {
        r.raw = String(await $.model.complete({
          model: "glm-5.3-flash", prompt: "Answer with exactly one word: OK",
          max_tokens: 16, timeoutMs: 8000,
        })).slice(0, 200)
      } catch (x) { r.err = String(x).slice(0, 500) }
      r.spentMs = $.clock.now() - t0
      if (out) { try { await $.fs.write(out + "/complete-" + n + ".json", JSON.stringify(r, null, 1)) } catch (x) {} }
      return next(e)
    }
    if (kase === "consult") {
      // Хост сам стережёт повторный вход; собственная защита — второй слой.
      if (String(e.description || "").indexOf("SPAWNPROBE-CONSULT") === 0) return next(e)
      const t0 = $.clock.now()
      const r: any = { seq: n }
      try {
        // CONSTRAINT: $.agent.spawn принимает subagentType (camelCase).
        // Инструментальная форма subagent_type одна не доходит.
        const a = await $.agent.spawn({
          prompt: "Answer with exactly one word: OK",
          description: "SPAWNPROBE-CONSULT", subagentType: "worker",
        })
        r.answer = String((a && (a.text || a.result)) || JSON.stringify(a)).slice(0, 300)
      } catch (x) { r.err = String(x).slice(0, 400) }
      r.spentMs = $.clock.now() - t0
      if (out) { try { await $.fs.write(out + "/consult-" + n + ".json", JSON.stringify(r, null, 1)) } catch (x) {} }
      return next(e)
    }

    return next(e)
  })
}
