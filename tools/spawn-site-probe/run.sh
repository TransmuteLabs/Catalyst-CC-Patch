#!/bin/bash
# Прибор площадки agent.spawn: перемеряет контракт хоста на живом образе.
#
# ЧТО ЭТО НЕ: не продуктовый мод, не часть конвейера патча, не стенд судьи.
# Один прогон = один `claude -p` в ИЗОЛИРОВАННОМ доме конфига. Живая
# установка не трогается: плагин подаётся через --plugin-dir, маркетплейс
# не регистрируется, ~/.claude не пишется.
#
# КОНСТРЕЙНТ ПОЛОЖИТЕЛЬНОГО КОНТРОЛЯ: отсутствие строки — это НЕ зелёный.
# В каждом прогоне обязана быть строка приёмки загрузки модуля; без неё
# прогон красный по причине «модуль не загружен», а не «случай не сошёлся».
# Пустой результат без положительного контроля недействителен.
#
# КОНСТРЕЙНТ ЗАПРЕТА: ни один случай не называет haiku/sonnet. Прибор не
# имеет права породить диспатч, запрещённый директивой.
#
# Дом вывода передаётся модулю через CLAUDE_SPAWNPROBE_OUT (имя — литерал
# в модуле). Зашивать путь в модуль нельзя: тогда он мерит одну машину.
#
# Ручки:
#   CLAUDE_SPAWNPROBE_IMAGE   образ (по умолчанию `command -v claude`)
#   CLAUDE_CODE_OAUTH_TOKEN   токен; на маке иначе берётся из связки ключей
#   CLAUDE_SPAWNPROBE_WORK    рабочий каталог (по умолчанию mktemp -d)
#   CLAUDE_SPAWNPROBE_CASES   подсписок случаев через пробел
#
# Коды: 0 сошлось; 1 случай(и) разошлись; 2 прибор не готов (нет образа,
# нет токена, модуль не загрузился ни разу).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$HERE/plugin"

die() { echo "spawn-site-probe: $*" >&2; exit 2; }

IMG="${CLAUDE_SPAWNPROBE_IMAGE:-$(command -v claude || true)}"
[[ -n "$IMG" && -x "$IMG" ]] || die "нет исполняемого образа (CLAUDE_SPAWNPROBE_IMAGE)"
[[ -f "$PLUGIN/hooks/register.ts" ]] || die "модуль прибора не найден: $PLUGIN"

TOK="${CLAUDE_CODE_OAUTH_TOKEN:-}"
if [[ -z "$TOK" && "$(uname -s)" == "Darwin" ]]; then
  # Ключ привязан к каталогу конфига (`Claude Code-credentials-<хеш>`), поэтому
  # изолированный дом не залогинен: токен подаётся безголовой ручкой.
  TOK="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null || true)"
fi
[[ -n "$TOK" ]] || die "нет токена: задай CLAUDE_CODE_OAUTH_TOKEN"

WORK="${CLAUDE_SPAWNPROBE_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/spawn-site-probe.XXXXXX")}"
CFG="$WORK/cfg"; OUT="$WORK/out"; LOG="$WORK/log"
mkdir -p "$CFG/agents" "$OUT" "$LOG" || die "не создать $WORK"
echo "spawn-site-probe: образ $IMG"
echo "spawn-site-probe: работа $WORK"

cat > "$CFG/settings.json" <<'EOF'
{ "model": "opus", "includeCoAuthoredBy": false }
EOF
# Две различимые цели: перетипизация наблюдается только если ответ агента
# называет, КТО из них исполнился.
cat > "$CFG/agents/probe-alpha.md" <<'EOF'
---
name: probe-alpha
description: Measurement target alpha.
model: opus
tools: Read
---
You are measurement target ALPHA. Answer with exactly: ALPHA
EOF
cat > "$CFG/agents/probe-beta.md" <<'EOF'
---
name: probe-beta
description: Measurement target beta.
model: opus
tools: Read
---
You are measurement target BETA. Answer with exactly: BETA
EOF

PROMPT='Call the Agent tool EXACTLY ONCE with subagent_type=probe-alpha, asking it to name itself. Do nothing else. Quote VERBATIM what the subagent returned.'

# случай|что обязано быть в отладке хоста|что обязано быть в ответе прогона
CASES=(
  "pass|agent.spawn settled in|ALPHA"
  "deny|denied by a hook (SPAWNPROBE-DENY)|Subagent spawn denied by a plugin"
  "neither|hook skipped: returned the wrong shape (neither { model } nor { deny })|ALPHA"
  "modelopus|model (inherit) -> opus by a hook|ALPHA"
  "modelbogus|-> SPAWNPROBE-NO-SUCH-MODEL by a hook (resolves to SPAWNPROBE-NO-SUCH-MODEL)|SPAWNPROBE-NO-SUCH-MODEL"
  "rewrite|prompt, description rewritten by a hook|ALPHA"
  "pinned|hook skipped: threw|ALPHA"
  "retype|subagentType rewritten by a hook|BETA"
  "retypeghost|subagentType rewritten by a hook|names no agent this call can dispatch"
  "slow|hook skipped: ran past its 10s budget|ALPHA"
  "complete|agent.spawn settled in|ALPHA"
  "consult|agent.spawn settled in|ALPHA"
)

WANT="${CLAUDE_SPAWNPROBE_CASES:-}"
LOADED=0; RED=0; RAN=0
ACCEPT='hooks module spawnprobe loaded'

for row in "${CASES[@]}"; do
  K="${row%%|*}"; rest="${row#*|}"
  DBG_WANT="${rest%%|*}"; ANS_WANT="${rest#*|}"
  if [[ -n "$WANT" ]] && [[ " $WANT " != *" $K "* ]]; then continue; fi
  RAN=$((RAN+1))

  rm -rf "$CFG/debug"; mkdir -p "$CFG/debug"
  env CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_OAUTH_TOKEN="$TOK" \
      CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 \
      CLAUDE_SPAWNPROBE="$K" CLAUDE_SPAWNPROBE_OUT="$OUT" \
      "$IMG" -p "$PROMPT" --plugin-dir "$PLUGIN" --debug \
      > "$LOG/$K.out" 2> "$LOG/$K.err"
  rc=$?
  cat "$CFG/debug/"*.txt > "$LOG/$K.dbg" 2>/dev/null

  # Положительный контроль ПЕРВЫМ: без него «строки нет» неотличимо от
  # «модуль не грузился», и весь прогон был бы вакуумно зелёным.
  if grep -qF "$ACCEPT" "$LOG/$K.dbg"; then
    LOADED=$((LOADED+1)); load="загружен"
  else
    load="НЕ ЗАГРУЖЕН"
  fi

  # CONSTRAINT: образец может начинаться с "-" (например "-> модель"):
  # без -- grep принимает его за ключ и отказывает, а отказ здесь
  # неотличим от "не нашлось".
  dbg_ok=0; grep -qF -- "${DBG_WANT}" "$LOG/$K.dbg" && dbg_ok=1
  ans_ok=0; grep -qF -- "${ANS_WANT}" "$LOG/$K.out" && ans_ok=1

  if [[ "$load" == "загружен" && $dbg_ok -eq 1 && $ans_ok -eq 1 ]]; then
    echo "  ЗЕЛЁНЫЙ  $K (rc=$rc)"
  else
    RED=$((RED+1))
    echo "  КРАСНЫЙ  $K (rc=$rc): модуль $load; отладка=$dbg_ok «${DBG_WANT}»; ответ=$ans_ok «${ANS_WANT}»"
  fi
done

echo "spawn-site-probe: случаев $RAN, красных $RED, модуль загружался в $LOADED из $RAN"
if [[ $RAN -gt 0 && $LOADED -eq 0 ]]; then
  echo "spawn-site-probe: модуль не загрузился НИ РАЗУ — мерить было нечем, вердикта нет" >&2
  exit 2
fi
[[ $RED -eq 0 ]] || exit 1
exit 0
