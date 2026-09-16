#!/usr/bin/env bash
# Зубы уборки гейта интерфейса: доставка TERM различает три исхода, и
# «проигнорировал TERM» печатается только если сигнал был доставлен.
#
# Предмет -- настоящие процессы и настоящий kill. Логика вырезается из
# claude-patch-all.sh по якорю; пропавший якорь -- отказ прибора (код 2),
# не зелёный прогон. Пустая вырезка -- тоже отказ: пусто не ноль.
#
# Коды (подмножество таблицы кита, шапка claude-patch-all.sh):
#   0  4 зуба зелёные, 4 мутации покраснили названный зуб (docnum:other --
#      смысл кода возврата, а не объявление счёта стенда: сам счёт живёт
#      ниже в EXPECTED_TEETH / EXPECTED_MUTATIONS, второго дома у него нет)
#   1  зуб не держится, либо мутация прошла молча / покраснела не своей причиной
#   2  прибор не может мерить: нет python3, якорь не ровно один, вырезка пуста
#      или не содержит обеих функций, не собрать фиктивный процесс нужной формы,
#      снимок не сошёлся после восстановления
#   4  (docnum:other -- это КОД ВОЗВРАТА, не счёт) объявленное число зубов или
#      мутаций не равно фактическому
set -euo pipefail

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PIPE="${KIT}/claude-patch-all.sh"
EXPECTED_TEETH=4
EXPECTED_MUTATIONS=4
BEGIN='# GATE_TERM_HELPERS_BEGIN'
END='# GATE_TERM_HELPERS_END'

# Часовой завершения обязателен для КАЖДОГО EXIT-трапа: bash 3.2 отдаёт код 0,
# когда скрипт с трапом умирает на фатальной ошибке подстановки (unbound
# variable под `set -u`, `${x:?}`, bad substitution) -- трап исполняется, `$?` внутри
# него ноль, и вызывающий видит успех вместо оборванного прогона. Штатный
# конец объявляет себя сам (__DONE=1), трап без объявления краснит.
# Уборка pids и временного каталога живёт ЗДЕСЬ: `trap` в bash глобален, и
# трап функции затёр бы часового. Сигнальные трапы переводят сигнал в КОД
# (130/143) и стоят отдельными строками -- войдя в общий гвард, точечный TERM
# пришёлся бы на последнюю УДАВШУЮСЯ команду и был бы объявлен «ошибкой оболочки».
# CONSTRAINT: rm -rf только при непустом WORKDIR -- пустая строка это не путь.
# CONSTRAINT: `if [[ -n ]]; then rm; fi`, не `[[ -n ]] && rm` -- под set -e
# падение проверки на пустом WORKDIR оборвало бы гвард до часового.
__DONE=0
WORKDIR=''
PIDS=''
cleanup() {
  local p
  if [[ -f "${PIDS}" ]]; then
    while IFS= read -r p; do
      [[ -n "${p}" ]] || continue
      kill -KILL "${p}" || true
      wait "${p}" || true
    done < "${PIDS}"
  fi
  if [[ -n "${WORKDIR:-}" ]]; then
    rm -rf "${WORKDIR}"
  fi
}
__gate_kill_teeth_guard() {
  __rc=$?
  cleanup
  if [[ "${__DONE:-0}" != 1 && "$__rc" == 0 ]]; then
    echo "ОТКАЗ: gate-kill-teeth оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 2
  fi
  exit "$__rc"
}
trap '__gate_kill_teeth_guard' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -f "${PIPE}" ]]; then
  echo "gate-kill-teeth: ОТКАЗ -- нет ${PIPE}" >&2
  __DONE=1
  exit 2
fi

_py=$(command -v python3 || true)
if [[ -z "${_py}" ]]; then
  echo "gate-kill-teeth: ОТКАЗ -- нет python3 (прибор)" >&2
  __DONE=1
  exit 2
fi
_py_probe=$("${_py}" -c 'print("ok")')
if [[ "${_py_probe}" != "ok" ]]; then
  echo "gate-kill-teeth: ОТКАЗ -- python3 не печатает положительный контроль" >&2
  __DONE=1
  exit 2
fi

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/gate-kill-teeth.XXXXXX")
PIDS="${WORKDIR}/pids"
HELPERS="${WORKDIR}/helpers.sh"
: > "${PIDS}"

note_pid() {
  echo "$1" >> "${PIDS}"
}

sha256_of() {
  "${_py}" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

extract_helpers() {
  "${_py}" - "${PIPE}" "${BEGIN}" "${END}" "${HELPERS}" <<'PY'
import sys
path, begin, end, dest = sys.argv[1:5]
text = open(path, "r").read()
nb, ne = text.count(begin), text.count(end)
if nb != 1 or ne != 1:
    sys.stderr.write(
        "gate-kill-teeth: ОТКАЗ -- якорь BEGIN %d раз, END %d раз, нужно ровно 1\n"
        % (nb, ne)
    )
    sys.exit(2)
i = text.index(begin) + len(begin)
j = text.index(end, i)
if j < i:
    sys.stderr.write("gate-kill-teeth: ОТКАЗ -- END стоит раньше BEGIN\n")
    sys.exit(2)
body = text[i:j].lstrip("\n")
if not body.strip():
    sys.stderr.write("gate-kill-teeth: ОТКАЗ -- вырезка пуста\n")
    sys.exit(2)
if "__interface_gate_deliver_term" not in body:
    sys.stderr.write(
        "gate-kill-teeth: ОТКАЗ -- вырезка не содержит __interface_gate_deliver_term\n"
    )
    sys.exit(2)
if "__interface_gate_term_still_alive_msg" not in body:
    sys.stderr.write(
        "gate-kill-teeth: ОТКАЗ -- вырезка не содержит __interface_gate_term_still_alive_msg\n"
    )
    sys.exit(2)
open(dest, "w").write(body)
PY
  if ! bash -n "${HELPERS}"; then
    echo "gate-kill-teeth: ОТКАЗ -- вырезка не разбирается" >&2
    __DONE=1
    exit 2
  fi
}

wait_ready() {
  local f="$1" n=0
  while [[ ! -s "${f}" ]]; do
    n=$((n + 1))
    if [[ "${n}" -gt 50 ]]; then
      echo "gate-kill-teeth: ОТКАЗ -- процесс не отметился за 5 с (${f})" >&2
      __DONE=1
      exit 2
    fi
    sleep 0.1
  done
}

# Лидер группы: kill -TERM -PID обязан пройти.
# CONSTRAINT: не звать через $(...) -- подстановка это подshell, и фиктивный
# процесс умрёт вместе с ней (SIGHUP) до доставки.
SPAWNED_PID=
spawn_leader() {
  local ready="$1" rpid rpgid
  rm -f "${ready}"
  "${_py}" -c '
import os, sys, time
try:
    os.setsid()
except OSError:
    pass
fd = open(sys.argv[1], "w")
fd.write("%d %d\n" % (os.getpid(), os.getpgid(0)))
fd.flush()
os.fsync(fd.fileno())
fd.close()
time.sleep(60)
' "${ready}" &
  SPAWNED_PID=$!
  note_pid "${SPAWNED_PID}"
  wait_ready "${ready}"
  read rpid rpgid < "${ready}"
  if [[ "${rpid}" != "${SPAWNED_PID}" ]]; then
    echo "gate-kill-teeth: ОТКАЗ -- \$ ! (${SPAWNED_PID}) не совпал с os.getpid (${rpid})" >&2
    __DONE=1
    exit 2
  fi
  if [[ "${rpid}" != "${rpgid}" ]]; then
    echo "gate-kill-teeth: ОТКАЗ -- процесс ${rpid} не лидер группы (pgid ${rpgid})" >&2
    __DONE=1
    exit 2
  fi
  if ! kill -0 -"${SPAWNED_PID}"; then
    echo "gate-kill-teeth: ОТКАЗ -- групповой kill -0 на лидере ${SPAWNED_PID} не прошёл" >&2
    __DONE=1
    exit 2
  fi
}

# Не лидер: групповая форма обязана отказать, одиночная -- пройти.
spawn_nongroup() {
  local ready="$1" rpid rpgid
  rm -f "${ready}"
  "${_py}" -c '
import os, sys, time
fd = open(sys.argv[1], "w")
fd.write("%d %d\n" % (os.getpid(), os.getpgid(0)))
fd.flush()
os.fsync(fd.fileno())
fd.close()
time.sleep(60)
' "${ready}" &
  SPAWNED_PID=$!
  note_pid "${SPAWNED_PID}"
  wait_ready "${ready}"
  read rpid rpgid < "${ready}"
  if [[ "${rpid}" != "${SPAWNED_PID}" ]]; then
    echo "gate-kill-teeth: ОТКАЗ -- \$ ! (${SPAWNED_PID}) не совпал с os.getpid (${rpid})" >&2
    __DONE=1
    exit 2
  fi
  if [[ "${rpid}" == "${rpgid}" ]]; then
    echo "gate-kill-teeth: ОТКАЗ -- процесс без setsid оказался лидером группы; зуб 2 нечем мерить" >&2
    __DONE=1
    exit 2
  fi
  if kill -0 -"${SPAWNED_PID}"; then
    echo "gate-kill-teeth: ОТКАЗ -- групповая форма прошла на не-лидере ${SPAWNED_PID} (pgid ${rpgid})" >&2
    __DONE=1
    exit 2
  fi
  if ! kill -0 "${SPAWNED_PID}"; then
    echo "gate-kill-teeth: ОТКАЗ -- процесс ${SPAWNED_PID} уже мёртв до доставки" >&2
    __DONE=1
    exit 2
  fi
}

make_dead_pid() {
  "${_py}" -c 'import time; time.sleep(60)' &
  SPAWNED_PID=$!
  note_pid "${SPAWNED_PID}"
  kill -KILL "${SPAWNED_PID}" || true
  wait "${SPAWNED_PID}" || true
  if kill -0 "${SPAWNED_PID}"; then
    echo "gate-kill-teeth: ОТКАЗ -- не смогли снять фиктивный процесс ${SPAWNED_PID}" >&2
    __DONE=1
    exit 2
  fi
}

reap() {
  local p="$1"
  kill -KILL "${p}" || true
  wait "${p}" || true
}

load_helpers() {
  GATE_TERM_OUTCOME=
  GATE_TERM_GROUP_ERR=
  GATE_TERM_PROC_ERR=
  GATE_TERM_GROUP_RC=
  GATE_TERM_PROC_RC=
  # shellcheck disable=SC1090
  source "${HELPERS}"
}

t1() {
  load_helpers
  local pid
  spawn_leader "${WORKDIR}/ready.t1"
  pid="${SPAWNED_PID}"
  __interface_gate_deliver_term "${pid}"
  local got="${GATE_TERM_OUTCOME}"
  reap "${pid}"
  if [[ "${got}" != group ]]; then
    echo "T1 FAIL: expected group, got ${got}"
    return 1
  fi
  echo "T1 green: delivered to group"
  return 0
}

t2() {
  load_helpers
  local pid
  spawn_nongroup "${WORKDIR}/ready.t2"
  pid="${SPAWNED_PID}"
  __interface_gate_deliver_term "${pid}"
  local got="${GATE_TERM_OUTCOME}"
  reap "${pid}"
  if [[ "${got}" != process ]]; then
    echo "T2 FAIL: expected process, got ${got}"
    return 1
  fi
  echo "T2 green: delivered to process"
  return 0
}

t3() {
  load_helpers
  local pid msg
  make_dead_pid
  pid="${SPAWNED_PID}"
  __interface_gate_deliver_term "${pid}"
  if [[ "${GATE_TERM_OUTCOME}" != undelivered ]]; then
    echo "T3 FAIL: expected undelivered, got ${GATE_TERM_OUTCOME}"
    return 1
  fi
  msg=$({ __interface_gate_term_still_alive_msg; } 2>&1)
  if printf '%s' "${msg}" | grep -F -q 'ignored TERM'; then
    echo "T3 FAIL: message still claims ignored TERM"
    echo "T3 message: ${msg}"
    return 1
  fi
  if ! printf '%s' "${msg}" | grep -F -q 'could not deliver TERM'; then
    echo "T3 FAIL: message does not say delivery failed"
    echo "T3 message: ${msg}"
    return 1
  fi
  if [[ -z "${GATE_TERM_GROUP_ERR}" && -z "${GATE_TERM_PROC_ERR}" ]]; then
    echo "T3 FAIL: reason not named (both stderr empty)"
    echo "T3 message: ${msg}"
    return 1
  fi
  if [[ -n "${GATE_TERM_GROUP_ERR}" ]] && ! printf '%s' "${msg}" | grep -F -q "${GATE_TERM_GROUP_ERR}"; then
    echo "T3 FAIL: reason not named"
    echo "T3 message: ${msg}"
    echo "T3 group err: ${GATE_TERM_GROUP_ERR}"
    return 1
  fi
  if [[ -n "${GATE_TERM_PROC_ERR}" ]] && ! printf '%s' "${msg}" | grep -F -q "${GATE_TERM_PROC_ERR}"; then
    echo "T3 FAIL: reason not named"
    echo "T3 message: ${msg}"
    echo "T3 process err: ${GATE_TERM_PROC_ERR}"
    return 1
  fi
  echo "T3 green: undelivered, reason named, not ignored TERM"
  echo "T3 message: ${msg}"
  return 0
}

write_t4() {
  local q_helpers q_py q_wd
  q_helpers=$(printf '%q' "${HELPERS}")
  q_py=$(printf '%q' "${_py}")
  q_wd=$(printf '%q' "${WORKDIR}")
  cat > "${WORKDIR}/t4.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
HELPERS=${q_helpers}
PY=${q_py}
WORKDIR=${q_wd}
# shellcheck disable=SC1090
source "\${HELPERS}"
note() { echo "\$1" >> "\${WORKDIR}/t4.pids"; }
cleanup_t4() {
  local p
  if [[ -f "\${WORKDIR}/t4.pids" ]]; then
    while IFS= read -r p; do
      [[ -n "\${p}" ]] || continue
      kill -KILL "\${p}" || true
      wait "\${p}" || true
    done < "\${WORKDIR}/t4.pids"
  fi
}
# CONSTRAINT: часовой t4 экранирован (EOF без кавычек): иначе родитель
# подставит свои значения в момент генерации.
__DONE=0
__t4_guard() {
  __rc=\$?
  cleanup_t4
  if [[ "\${__DONE:-0}" != 1 && "\$__rc" == 0 ]]; then
    echo "ОТКАЗ: t4 оборвался, не дойдя до конца (ошибка оболочки выше)" >&2
    exit 2
  fi
  exit "\$__rc"
}
trap '__t4_guard' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
: > "\${WORKDIR}/t4.pids"

# Живые -- до мёртвого: обрыв на мёртвом не оставляет их без трапа.
"\${PY}" -c '
import os, sys, time
os.setsid()
fd = open(sys.argv[1], "w")
fd.write("%d %d\\n" % (os.getpid(), os.getpgid(0)))
fd.flush(); os.fsync(fd.fileno()); fd.close()
time.sleep(60)
' "\${WORKDIR}/ready.t4.g" &
gpid=\$!
note "\${gpid}"
"\${PY}" -c '
import os, sys, time
fd = open(sys.argv[1], "w")
fd.write("%d %d\\n" % (os.getpid(), os.getpgid(0)))
fd.flush(); os.fsync(fd.fileno()); fd.close()
time.sleep(60)
' "\${WORKDIR}/ready.t4.p" &
ppid=\$!
note "\${ppid}"

n=0
while [[ ! -s "\${WORKDIR}/ready.t4.g" || ! -s "\${WORKDIR}/ready.t4.p" ]]; do
  n=\$((n + 1))
  if [[ "\${n}" -gt 50 ]]; then
    echo "T4 FAIL: processes did not become ready" >&2
    __DONE=1
    exit 2
  fi
  sleep 0.1
done

"\${PY}" -c 'import time; time.sleep(60)' &
dpid=\$!
note "\${dpid}"
kill -KILL "\${dpid}" || true
wait "\${dpid}" || true

__interface_gate_deliver_term "\${dpid}"
__interface_gate_deliver_term "\${gpid}"
__interface_gate_deliver_term "\${ppid}"
echo CONTINUED
__DONE=1
EOF
}

t4() {
  write_t4
  if ! bash -n "${WORKDIR}/t4.sh"; then
    echo "gate-kill-teeth: ОТКАЗ -- t4.sh не разбирается" >&2
    __DONE=1
    exit 2
  fi
  local rc=0
  bash "${WORKDIR}/t4.sh" > "${WORKDIR}/t4.out" 2> "${WORKDIR}/t4.err" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "T4 FAIL: aborted under set -e (rc=${rc})"
    echo "T4 stdout: $(cat "${WORKDIR}/t4.out")"
    echo "T4 stderr: $(cat "${WORKDIR}/t4.err")"
    return 1
  fi
  if ! grep -F -q 'CONTINUED' "${WORKDIR}/t4.out"; then
    echo "T4 FAIL: CONTINUED not printed"
    echo "T4 stdout: $(cat "${WORKDIR}/t4.out")"
    echo "T4 stderr: $(cat "${WORKDIR}/t4.err")"
    return 1
  fi
  echo "T4 green: all three outcomes continued"
  return 0
}

replace_once() {
  local file="$1" oldf="$2" newf="$3"
  "${_py}" - "${file}" "${oldf}" "${newf}" <<'PY'
import sys
path, oldp, newp = sys.argv[1:4]
text = open(path).read()
old, new = open(oldp).read(), open(newp).read()
n = text.count(old)
if n != 1:
    sys.stderr.write(
        "gate-kill-teeth: ОТКАЗ -- якорь мутации встречается %d раз, нужно ровно 1\n" % n
    )
    sys.exit(2)
open(path, "w").write(text.replace(old, new, 1))
PY
}

run_mutation() {
  local mid="$1" tooth="$2" needle="$3"
  local oldf="${WORKDIR}/mut.${mid}.old"
  local newf="${WORKDIR}/mut.${mid}.new"
  cp "${HELPERS}" "${WORKDIR}/helpers.snap"
  local snap now
  snap=$(sha256_of "${WORKDIR}/helpers.snap")
  replace_once "${HELPERS}" "${oldf}" "${newf}"
  local rc=0
  local out="${WORKDIR}/mut.${mid}.out"
  set +e
  "${tooth}" > "${out}" 2>&1
  rc=$?
  set -e
  cp "${WORKDIR}/helpers.snap" "${HELPERS}"
  now=$(sha256_of "${HELPERS}")
  if [[ "${now}" != "${snap}" ]]; then
    echo "gate-kill-teeth: ОТКАЗ -- снимок не сошёлся после ${mid}: snap=${snap} now=${now}" >&2
    __DONE=1
    exit 2
  fi
  load_helpers
  echo "  ${mid} snapshot ${snap}"
  echo "  ${mid} restored ${now}"
  if [[ "${rc}" -eq 0 ]]; then
    echo "M${mid} FAIL: mutation silent (tooth still green)"
    echo "  output: $(cat "${out}")"
    return 1
  fi
  if [[ "${rc}" -eq 2 ]]; then
    echo "M${mid} FAIL: mutation broke the instrument (rc=2), not the named tooth"
    echo "  output: $(cat "${out}")"
    return 1
  fi
  if ! grep -F -q "${needle}" "${out}"; then
    echo "M${mid} FAIL: tooth reddened, but not with named reason «${needle}»"
    echo "  output: $(cat "${out}")"
    return 1
  fi
  echo "M${mid} green: ${tooth} reddened (${needle})"
  echo "  output: $(cat "${out}")"
  return 0
}

# --- extract, teeth, mutations ------------------------------------------------

extract_helpers
load_helpers
bash -n "${HELPERS}"

n_teeth=0
n_green=0
n_mut=0
n_mut_held=0
fail=0

echo "gate-kill-teeth: running ${EXPECTED_TEETH} teeth"

n_teeth=$((n_teeth + 1))
if t1; then n_green=$((n_green + 1)); else fail=1; fi
n_teeth=$((n_teeth + 1))
if t2; then n_green=$((n_green + 1)); else fail=1; fi
n_teeth=$((n_teeth + 1))
if t3; then n_green=$((n_green + 1)); else fail=1; fi
n_teeth=$((n_teeth + 1))
if t4; then n_green=$((n_green + 1)); else fail=1; fi

if [[ "${n_teeth}" -ne "${EXPECTED_TEETH}" ]]; then
  echo "gate-kill-teeth: объявлено ${EXPECTED_TEETH} зубов, фактически ${n_teeth}" >&2
  __DONE=1
  exit 4
fi

echo "gate-kill-teeth: teeth=${n_teeth} green=${n_green}"

if [[ "${fail}" -ne 0 ]]; then
  echo "gate-kill-teeth: teeth red; skipping mutations until teeth are green"
  __DONE=1
  exit 1
fi

# Мутации -- по копии вырезки, не по живому киту. Восстановление снимком + sha256.
mkdir -p "${WORKDIR}"
printf '%s' '      GATE_TERM_OUTCOME=group' > "${WORKDIR}/mut.1.old"
printf '%s' '      GATE_TERM_OUTCOME=process' > "${WORKDIR}/mut.1.new"
printf '%s' '      GATE_TERM_OUTCOME=process' > "${WORKDIR}/mut.2.old"
printf '%s' '      GATE_TERM_OUTCOME=group' > "${WORKDIR}/mut.2.new"
cat > "${WORKDIR}/mut.3.old" <<'OLD3'
    case "${GATE_TERM_OUTCOME}" in
      group|process)
        echo "  the interface gate ignored TERM; killing it" >&2
        ;;
      *)
        echo "  the interface gate could not deliver TERM (group rc=${GATE_TERM_GROUP_RC:-?} ${GATE_TERM_GROUP_ERR}; process rc=${GATE_TERM_PROC_RC:-?} ${GATE_TERM_PROC_ERR}); killing it" >&2
        ;;
    esac
OLD3
cat > "${WORKDIR}/mut.3.new" <<'NEW3'
    echo "  the interface gate ignored TERM; killing it" >&2
NEW3
printf '%s' 'group_err="$(kill -TERM -"${pid}" 2>&1)" || group_rc=$?' > "${WORKDIR}/mut.4.old"
printf '%s' 'group_err="$(kill -TERM -"${pid}" 2>&1)"' > "${WORKDIR}/mut.4.new"

echo "gate-kill-teeth: running ${EXPECTED_MUTATIONS} mutation controls"

n_mut=$((n_mut + 1))
if run_mutation 1 t1 'T1 FAIL: expected group, got'; then n_mut_held=$((n_mut_held + 1)); else fail=1; fi
n_mut=$((n_mut + 1))
if run_mutation 2 t2 'T2 FAIL: expected process, got'; then n_mut_held=$((n_mut_held + 1)); else fail=1; fi
n_mut=$((n_mut + 1))
if run_mutation 3 t3 'T3 FAIL: message still claims ignored TERM'; then n_mut_held=$((n_mut_held + 1)); else fail=1; fi
n_mut=$((n_mut + 1))
if run_mutation 4 t4 'T4 FAIL: aborted under set -e'; then n_mut_held=$((n_mut_held + 1)); else fail=1; fi

if [[ "${n_mut}" -ne "${EXPECTED_MUTATIONS}" ]]; then
  echo "gate-kill-teeth: объявлено ${EXPECTED_MUTATIONS} мутаций, фактически ${n_mut}" >&2
  __DONE=1
  exit 4
fi

echo "gate-kill-teeth: teeth=${n_teeth} green=${n_green} mutations=${n_mut} held=${n_mut_held}"

if [[ "${fail}" -ne 0 ]]; then
  __DONE=1
  exit 1
fi
__DONE=1
exit 0
