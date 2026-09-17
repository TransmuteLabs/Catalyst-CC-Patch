# Дом пары хозяина для выбора списка корпуса.
#
# Файл ПОДКЛЮЧАЕТСЯ (`source`), а не запускается: своих кодов выхода у него нет.
#
# host_os_arch печатает <ос>-<дуга> и есть КОПИЯ __host_os_arch из
# claude-patch-all.sh. Копия в конвейере остаётся: стадия гейта ВЫРЕЗАЕТСЯ
# стендом и исполняется без кита рядом, импортировать ей нечем. Поведение
# обязано совпадать на всех разобранных парах, включая unknown.
#
# host_corpus_for отображает пару в имя файла списка и пакет реестра.
# Имена файлов объявлены здесь и только здесь: darwin-arm64 держит прежнее
# имя (его пинит гейт свипа и называет README), linux-x64 -- своё.
# Пустое имя файла -- пары нет в объявленном наборе.
#
# Пол поддержки сюда не входит: он живёт в tools/support-floor.txt, один
# на все платформы.

host_os_arch() {
  local os arch __un_s __un_m
  # «unknown» в ветке * -- ОБЪЯВЛЕННЫЙ ответ на неответивший uname (rc 1,
  # пустой вывод): пара хозяина обязана существовать на любом хозяине.
  # Отказ прибора -- код выше единицы.
  __un_s="$(uname -s)" || __unos_rc=$?
  [ "${__unos_rc:-0}" -le 1 ] || { printf 'ПРИБОР НЕДОСТУПЕН: ОС хозяина не опознана (uname, код %s)\n' "$__unos_rc" >&2; exit 2; }
  __unos_rc=0
  case "$__un_s" in
    Darwin)               os=darwin ;;
    Linux)                os=linux ;;
    MINGW*|MSYS*|CYGWIN*) os=win32 ;;
    *)                    os=unknown ;;
  esac
  __un_m="$(uname -m)" || __unm_rc=$?
  [ "${__unm_rc:-0}" -le 1 ] || { printf 'ПРИБОР НЕДОСТУПЕН: дуга хозяина не опознана (uname, код %s)\n' "$__unm_rc" >&2; exit 2; }
  __unm_rc=0
  case "$__un_m" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=x64 ;;
    *)             arch=unknown ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}

host_corpus_for() {   # пара -> «имя-файла<TAB>пакет». пустое имя -- не объявлена
  local pair="$1" name pkg
  case "$pair" in
    darwin-arm64)
      name=corpus-versions.txt
      pkg=@anthropic-ai/claude-code-darwin-arm64
      ;;
    linux-x64)
      name=corpus-versions-linux-x64.txt
      pkg=@anthropic-ai/claude-code-linux-x64
      ;;
    *)
      name=
      pkg=@anthropic-ai/claude-code-$pair
      ;;
  esac
  printf '%s\t%s\n' "$name" "$pkg"  # HOST_LIST_NAME
}
