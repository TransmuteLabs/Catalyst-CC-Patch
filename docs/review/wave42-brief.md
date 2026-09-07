# Волна 42 — раскатанный дом словарей не резолвится (класс 1b)

## Что измерено (не гипотеза)

После `bash scripts/probes-sync.sh --to-home` на маке 2026-09-07:

    $ cd ~/.claude/judge && python3 -c "import sys;sys.path.insert(0,'.');import replay;print(replay.verdict_vocabulary())"
    дом словарей вердиктов не прочитан: /Users/maratkarimov/.claude/tweakcc-patch.js
    (FileNotFoundError); положите tweakcc-patch.js рядом с китом либо назовите
    его путь в CLAUDE_JUDGE_PATCH_SRC
    rc=2

При этом файл РАСКАТАН — но соседом инструментов, а не на уровень выше:

    -rw-r--r-- 1 maratkarimov staff 315137 Sep 7 16:12 /Users/maratkarimov/.claude/judge/tweakcc-patch.js
    ls: /Users/maratkarimov/.claude/tweakcc-patch.js: No such file or directory

Причина — расхождение двух мест, введённое в хвостах волны 40b:

* `scripts/probes-sync.sh:192` кладёт исходник в `$TOOLS_HOME` (`:51` —
  `${CLAUDE_JUDGE_TOOLS_DIR:-$CLAUDE_HOME_DIR/judge}`), то есть `~/.claude/judge/`;
* `judge/replay.py:29-30` ищет его на `dirname(dirname(__file__))`, то есть
  `~/.claude/`.

Радиус: импорт ленив (замерено — `import replay` даёт rc=0), ночной
`compact.py --older-than-hours 24 --dry-run` тоже rc=0 (он берёт из replay
только `bounded_float`). Отказывает ЛЮБОЙ вызов словаря — то есть
`channel.py`, `adjudicate.py`, `validate.py` в раскатанном доме.
Отказ fail-closed с названной причиной, не тихий.

Зуба нет ни одного: у бенча есть мутация M53, пиняющая ровно ОБРАТНОЕ
(«дом НЕ в `judge/`»), а раскатанной раскладки не касается ни один сценарий.

## Решение (принято, не обсуждается)

Раскатанный контур обязан быть САМОДОСТАТОЧНЫМ: инструменты раскатывают, чтобы
они работали без дерева кита. Класть исходник в `~/.claude/` (корень стокового
каталога пользователя) запрещено — наши данные туда не пишутся. Значит
резолвер учит ВТОРУЮ раскладку, а раскладка ИЗМЕРЯЕТСЯ по наличию файла, а не
выводится из имени дома.

## Правки

### 1. `judge/replay.py` — лестница из двух кандидатов

Заменить `:29-32` (дословный текущий вид):

    KIT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    DEFAULT_SOURCE = os.path.join(KIT_ROOT, 'tweakcc-patch.js')
    # Раскатка (scripts/probes-sync.sh) кладёт judge/*.py в ~/.claude/judge, а
    # исходник патча рядом НЕ кладёт: в таком доме путь называется этой ручкой.
    SOURCE_ENV = 'CLAUDE_JUDGE_PATCH_SRC'

на:

    TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
    KIT_ROOT = os.path.dirname(TOOLS_DIR)
    # Один файл живёт в ДВУХ раскладках: в дереве кита он лежит в корне
    # (judge/ -- подкаталог), а раскатанный дом инструментов несёт его СОСЕДОМ
    # (scripts/probes-sync.sh кладёт его в $TOOLS_HOME). Раскладка измеряется
    # по наличию файла, а не выводится из имени дома: раскатанный контур обязан
    # работать без дерева кита. В ~/.claude (стоковый каталог пользователя)
    # исходник не кладётся.
    DEFAULT_SOURCES = (
        os.path.join(KIT_ROOT, 'tweakcc-patch.js'),
        os.path.join(TOOLS_DIR, 'tweakcc-patch.js'),
    )
    SOURCE_ENV = 'CLAUDE_JUDGE_PATCH_SRC'

Добавить рядом функцию (публичное имя — её зовёт стенд):

    def default_source():
        """Первый СУЩЕСТВУЮЩИЙ кандидат раскладки; None, когда нет ни одного.

        None, а не первый кандидат: звонящий обязан назвать в отказе ВСЕ
        кандидаты -- иначе починка выглядит как «не тот путь» вместо «файла
        нет ни в одной раскладке».
        """
        for cand in DEFAULT_SOURCES:
            if os.path.exists(os.path.expanduser(cand)):
                return cand
        return None

В `verdict_vocabulary` (`:204-231`) заменить строку разрешения источника

    source = os.path.realpath(os.path.expanduser(
        source_path or os.environ.get(SOURCE_ENV) or DEFAULT_SOURCE))

на разрешение с отдельной дверью «ни одной раскладки»:

    chosen = source_path or os.environ.get(SOURCE_ENV) or default_source()
    if chosen is None:
        # Код 2 -- прибор не может мерить. Названы ВСЕ кандидаты: раскладок
        # две, и «не тот путь» -- неверный диагноз.
        print('дом словарей вердиктов не найден ни в одной раскладке: '
              + ', '.join(DEFAULT_SOURCES)
              + f'; положите tweakcc-patch.js рядом с китом или в дом '
                f'инструментов либо назовите его путь в {SOURCE_ENV}',
              file=sys.stderr)
        raise SystemExit(2)
    source = os.path.realpath(os.path.expanduser(chosen))

Ветку `except OSError` НЕ трогать: явно названный (аргументом или ручкой) и
нечитаемый путь остаётся отдельным диагнозом с именем файла.

Заголовочный комментарий `:6` про код 2 проверить и, если он называет ОДИН
дом, привести к двум раскладкам.

### 2. `tools/judge-tools-bench.py:569` — посев кэша через тот же резолвер

Сейчас:

    home = os.path.realpath(os.path.expanduser(module.DEFAULT_SOURCE))

Константы больше нет; ключ кэша обязан совпадать с тем, что вычислит
`verdict_vocabulary`, иначе посев уходит мимо ключа и стенд молча читает
настоящие файлы (об этом прямо сказано в докстроке `:560-564`). Заменить на:

    src = module.default_source()
    require(src is not None,
            "дом словарей не найден ни в одной раскладке: посев ушёл бы мимо ключа")
    home = os.path.realpath(os.path.expanduser(src))

### 3. `tools/judge-tools-bench.py` — мутация M53 пере-авторизуется

Её якорь (`:2419-2420`) — удалённая строка. Новый вид: убрать ступень корня
кита, оставив только соседнюю.

    replace_once(
        root / "judge" / "replay.py",
        "    os.path.join(KIT_ROOT, 'tweakcc-patch.js'),\n"
        "    os.path.join(TOOLS_DIR, 'tweakcc-patch.js'),\n",
        "    os.path.join(TOOLS_DIR, 'tweakcc-patch.js'),\n",
        "M53",
    )

Причина покраснения прежняя и её надо оставить комментарием: в дереве кита
исходник лежит в корне, и без этой ступени прибор отказывает там, где предмет
замера лежит рядом. Сценарий, к которому M53 привязана, НЕ менять — он обязан
покраснеть по своей причине.

### 4. Новый сценарий 49 — раскатанная раскладка (ДВЕ половины)

Имя и место — по образцу соседних сценариев файла.

* **Половина А (раскладка резолвится).** Построить временный дом ВИДА
  РАСКАТКИ: каталог `<tmp>/judge/` c копией настоящего `judge/replay.py` и
  копией настоящего `tweakcc-patch.js` СОСЕДОМ; на уровне `<tmp>/`
  `tweakcc-patch.js` НЕ класть (иначе измеряется старая ступень).
  Загрузить копию как модуль по её пути (`importlib.util.spec_from_file_location`
  — `import_tool` берёт из дерева кита и здесь не годится).
  Требовать: `verdict_vocabulary(image_path=<заведомо несуществующий путь>,
  probe='judge')` возвращает непустой словарь. Образа нет — это объявленный
  пропуск сверки волны 40b, а не отказ.
* **Половина Б (ни одной раскладки — отказ называет ОБА кандидата).** Тот же
  дом без `tweakcc-patch.js` вовсе, ручка `CLAUDE_JUDGE_PATCH_SRC` снята из
  окружения. Требовать `SystemExit` с кодом 2, и чтобы в stderr стояли ОБА
  пути-кандидата дословно. Половина Б — положительный контроль половины А:
  без неё «словарь нашёлся» не отличается от «резолвер вернул что попало».

Кэш `_VOCAB_CACHE` в загруженной копии — свой, но если сценарий зовёт словарь
дважды, чистить его явно.

### 5. Две новые мутации

* **M57** — убрать соседнюю ступень (обратная к M53):

      "    os.path.join(KIT_ROOT, 'tweakcc-patch.js'),\n"
      "    os.path.join(TOOLS_DIR, 'tweakcc-patch.js'),\n"
      →
      "    os.path.join(KIT_ROOT, 'tweakcc-patch.js'),\n"

  Краснит половину А сценария 49.
* **M58** — отказ называет только ОДИН кандидат: заменить
  `', '.join(DEFAULT_SOURCES)` на `DEFAULT_SOURCES[0]`.
  Краснит половину Б сценария 49.

### 6. Ценз читателей размеров множеств

`EXPECTED_SCENARIOS = 48 → 49`, `EXPECTED_MUTATIONS = 56 → 58`
(`tools/judge-tools-bench.py:49,53`).

Ценз внешних объявлений СНЯТ МНОЙ и он пуст: числа judge-бенча не объявлены
ни в `README.md`, ни в `tools/docnum-mutations.tsv`. Положительный контроль
той же иглы: числа corpus-tools-bench (157/186) находятся в
`README.md:141`, `docnum-mutations.tsv:25,26,71`. Гейт чисел
(`claude-patch-all.sh:2587-2588`) знает judge-бенч как владельца, но сверяет
только прозу, а прозы с этими числами нет. Значит правок в доках по числам НЕ
требуется. Если гейт чисел всё же покраснеет — это находка, доложить, не
подгонять.

### 7. Дока

`docs/judge-architecture.md:231` («The dictionary's home is `tweakcc-patch.js`,
the authored patch source») — добавить ОДНО предложение: у дома две раскладки
(корень дерева кита и дом раскатанных инструментов), выбирается по наличию
файла, отсутствие обеих — отказ кодом 2 с обоими путями.

## `paths:` — писать только сюда

`judge/replay.py`, `tools/judge-tools-bench.py`, `docs/judge-architecture.md`,
`docs/review/wave42-report.md` (создать). Всё остальное — только чтение;
замеченное вне скоупа — флагом в отчёт, не правкой.

`scripts/probes-sync.sh` НЕ трогать: его строка `:192` теперь верна.

## Гейты (гонять на linux, usbox — не на маке)

Кит на маке канонический; на usbox копия. Синхронизация и прогон:

    rsync -a --delete --exclude .git \
      ~/work/SIB/Transmutation/Nexus/Catalyst/Catalyst-CC-Patch/ \
      usbox:~/ccpatch/kit42/
    ssh usbox 'cd ~/ccpatch/kit42 && <гейт>'

Зелёными обязаны быть, с ДОСЛОВНЫМИ числами в отчёте:

1. `python3 tools/judge-tools-bench.py` — сценариев 49, расхождений 0, rc=0
2. `python3 tools/judge-tools-bench.py --self-check` — 58/58 покраснели,
   контроль зелёный, rc=0
3. `bash tools/probes-sync-bench.sh` и `--self-check` (7/8) — регрессия
   раскатки
4. `python3 tools/docnum-bench.py --anchors` и `python3 tools/docnum-bench.py`
5. `python3 -m py_compile judge/*.py tools/judge-tools-bench.py`

Exit-код снимать БЕЗ пайпа либо под `set -o pipefail` (в zsh `PIPESTATUS`
пуст — там `$pipestatus`). Полный конвейер-263 гоняю я сам, в твою приёмку он
не входит.

## Контракт

* Коммитов НЕ делать: изменения остаются в рабочем дереве, коммичу я после
  личной верификации.
* Стоп-правило: неожиданное падение или расхождение с брифом → одна честная
  попытка → BLOCKED с СЫРЫМ выводом, без глубокой диагностики.
* Задача уже сделана / посылка ложная → доказательство (grep/diff/прогон) и
  стоп; фабрикация диффа запрещена.
* Комментарий в коде = констрейнт (граница, инвариант, «почему не иначе»).
  Нарратив — в `docs/review/wave42-report.md`.
* Отчёт: изменённые файлы с +/−, дословные счётчики всех пяти гейтов,
  причина покраснения для каждой из трёх мутаций (M53 пере-авторизованной,
  M57, M58), и отдельным списком — всё, где ты принял решение или спорную
  оценку.

<!-- BRIEF COMPLETE -->
