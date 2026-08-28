#!/usr/bin/env bash
# Наполнение корпуса пристинных образов, на котором работает tools/sweep.sh.
#
# Повод (2026-08-28). Корпус лежал в ~/.local/share/claude/versions как
# <версия>.orig, а фаза «Cleaning up previous versions» самого конвейера удаляет
# оттуда ВСЁ, кроме текущей версии и той, что исполняет живая сессия. Установка
# 2.1.248 честно отработала эту фазу и вместе со старыми сборками унесла образы
# 233/240/243/245/246 -- измерительную базу, на которой меряется каждая волна
# правок. Теперь у корпуса свой каталог, куда очистка не заглядывает.
#
# Источник -- РЕЕСТР npm, а не локальная копия: локальный образ может быть уже
# пропатченным (нашими правками или tweakcc), и корпус из него бесполезен --
# свип мерил бы патч поверх патча.
#
# Качается ПРЯМО в корпус, вызовом download_binary из claude_patch.py, а не
# через `--download-only`. Тот режим кладёт образ в каталог УСТАНОВОК и там же
# заменяет <версия>.orig, а для уже установленной версии оставляет ещё и
# <версия>.staging. Наполнителю корпуса нечего делать в каталоге установок:
# первая редакция этого скрипта подчищала за собой `rm -f $VDIR/$version`, то
# есть отвязала бы образ, который в этот момент исполняет живая сессия.
#
# Идемпотентно для ЗАПИНЕННЫХ версий: лежащий образ с сошедшимся пином не
# перекачивается. Лежащий образ БЕЗ пина -- качается: пин обязан родиться из
# байт реестра, а не из того, что кто-то положил в каталог. Список версий --
# общий со свипом, tools/corpus-versions.txt.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$HERE/.." && pwd)
# Те же ручки, что у свипа, и с той же целью -- стенд (см. комментарий там).
CORPUS="${CORPUS_DIR:-$HOME/.local/share/claude-patch/corpus}"
LIST="${CORPUS_LIST:-$HERE/corpus-versions.txt}"
[[ -f "$LIST" ]] || { echo "ОТКАЗ: нет списка версий $LIST" >&2; exit 1; }
mkdir -p "$CORPUS"

# Инструмент хеша выбирается ОДИН раз, на старте.
#
# Прежняя редакция держала отказ «нет ни shasum, ни sha256sum» ВНУТРИ функции,
# которую зовут только как `got=$(sha256_of ...)`. `exit 1` там убивает подшелл,
# а не скрипт: дальше шёл пустой хеш, который не совпадал с пином, и отказ
# случался по другой причине. Дверь, срабатывающая по касательной, перестаёт
# работать на первом же вызове, где результат не сверяют с пином.
if command -v shasum >/dev/null 2>&1; then HASH=(shasum -a 256)
elif command -v sha256sum >/dev/null 2>&1; then HASH=(sha256sum)
else echo "ОТКАЗ: нет ни shasum, ни sha256sum -- пин корпуса не проверить" >&2; exit 1
fi
sha256_of() { "${HASH[@]}" "$1" | awk '{print $1}'; }

# Пины записываются ПОСЛЕ обхода, одной перезаписью.
#
# Прежняя редакция писала пин прямо в цикле, а цикл читал ЭТОТ ЖЕ файл через
# `done < "$LIST"`. Запись делает truncate по тому же иноду, дескриптор чтения
# остаётся за концом файла -- и первая же записанная строка обрывала обход:
# остальные версии молча не качались, а код возврата оставался нулевым. Список
# читается в память до цикла, пины копятся и применяются в конце.
record_pins() {   # пары: версия цифры версия цифры ...
  (( $# )) || return 0
  python3 - "$LIST" "$@" <<'PIN_PY'
import sys
path, rest = sys.argv[1], sys.argv[2:]
pins = dict(zip(rest[0::2], rest[1::2]))
lines = open(path).read().splitlines()
seen = set()
for i, ln in enumerate(lines):
    parts = ln.split()
    if len(parts) >= 2 and not parts[0].startswith('#') and parts[1] in pins:
        lines[i] = '%s %s %s' % (parts[0], parts[1], pins[parts[1]])
        seen.add(parts[1])
missing = sorted(set(pins) - seen)
if missing:
    sys.exit('в списке нет версий: %s' % ', '.join(missing))
open(path, 'w').write('\n'.join(lines) + '\n')
PIN_PY
}

# Закачка из реестра во ВРЕМЕННЫЙ файл, имя которого уникально для процесса:
# два наполнителя, стартовавших разом, писали в один и тот же `<образ>.part` и
# обрезали друг друга (download_binary открывает цель на "wb").
fetch_to() {   # версия, путь назначения
  KIT="$KIT" DST="$2" VER="$1" python3 - <<'FETCH_PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ['KIT'])
import claude_patch
claude_patch.download_binary(os.environ['VER'], Path(os.environ['DST']))
FETCH_PY
}

# Список -- в память целиком, комментарии и пустые строки отсеиваются здесь.
ENTRIES=$(sed 's/#.*//' "$LIST" | awk 'NF')

rc=0
declare -a NEW_PINS=()
while read -r label version pin _rest; do
  [[ -n "${label:-}" ]] || continue
  pin="${pin:--}"
  dst="$CORPUS/$version.pristine"
  tmp=$(mktemp "$dst.part.XXXXXX") || { echo "ОТКАЗ: не создать временный файл для $version" >&2; rc=1; continue; }

  if [[ -s "$dst" ]]; then
    got=$(sha256_of "$dst")
    if [[ "$pin" != "-" ]]; then
      rm -f "$tmp"
      if [[ "$got" == "$pin" ]]; then
        echo "уже есть: $version ($(wc -c < "$dst" | tr -d ' ') байт, пин сходится)"
      else
        echo "ОТКАЗ: $version на диске не сходится с пином (пин $pin, файл $got)" >&2; rc=1
      fi
      continue
    fi
    # Пин ещё не записан, а файл уже лежит. Записать хеш диска -- значит
    # объявить эталоном то, что никто не проверял: в корпус мог попасть
    # пропатченный образ или обрубок, и дальше «сток против патча поверх патча»
    # уже не отличить. Пин ставится только по байтам РЕЕСТРА, поэтому версия
    # качается и сверяется с тем, что лежит.
    echo "== $version лежит без пина -- качаю из реестра для сверки"
    if ! fetch_to "$version" "$tmp"; then
      rm -f "$tmp"; echo "ОТКАЗ: не скачать $version для сверки" >&2; rc=1; continue
    fi
    fresh=$(sha256_of "$tmp")
    rm -f "$tmp"
    if [[ "$fresh" == "$got" ]]; then
      NEW_PINS+=("$version" "$fresh")
      echo "ok $version: файл совпал с реестром, пин будет записан: $fresh"
    else
      echo "ОТКАЗ: $version в корпусе НЕ равен реестру (файл $got, реестр $fresh)." >&2
      echo "       Пин не записан. Удалите $dst и перезапустите." >&2
      rc=1
    fi
    continue
  fi

  echo "== качаю $version"
  if ! fetch_to "$version" "$tmp"; then
    rm -f "$tmp"; echo "ОТКАЗ на $version" >&2; rc=1; continue
  fi
  got=$(sha256_of "$tmp")
  if [[ "$pin" != "-" && "$got" != "$pin" ]]; then
    # Реестр отдал не то, что записано. Это не повод молча заменить пин: файл
    # выбрасывается, прогон краснеет, разбирается человек.
    rm -f "$tmp"
    echo "ОТКАЗ: $version из реестра не сходится с пином (пин $pin, скачано $got)" >&2
    rc=1; continue
  fi
  chmod 755 "$tmp"
  mv "$tmp" "$dst" || { rm -f "$tmp"; echo "ОТКАЗ: не перенести $version" >&2; rc=1; continue; }
  if [[ "$pin" == "-" ]]; then
    NEW_PINS+=("$version" "$got")
    echo "ok $version -> $dst ($(wc -c < "$dst" | tr -d ' ') байт), пин будет записан: $got"
  else
    echo "ok $version -> $dst ($(wc -c < "$dst" | tr -d ' ') байт, пин сходится)"
  fi
done <<< "$ENTRIES"

if (( ${#NEW_PINS[@]} )); then
  if record_pins "${NEW_PINS[@]}"; then
    echo "пины записаны: $(( ${#NEW_PINS[@]} / 2 ))"
  else
    echo "ОТКАЗ: не записать пины" >&2; rc=1
  fi
fi

echo "КОРПУС ($CORPUS):"
ls -l "$CORPUS" | sed 's/^/  /'
exit $rc
