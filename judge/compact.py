#!/usr/bin/env python3
"""Compaction pass over probe journals and records.

Records are written uncompressed: a fresh record must be readable and greppable.
They lose value gradually, while the volume grows noticeably — about a hundred
kilobytes per judgment, almost all of it the transcript. So they are compacted
by a separate pass, by age.

  compact.py [--dir D] [--probe P1,P2] [--older-than-hours N] [--dry-run]

Архив (сжатые <имя>.json.gz) растёт неограниченно; его горизонт -- возрастная
граница с обязательной машиночитаемой отметкой horizon.json рядом с каталогом
записей (подробности -- у prune_archive_horizon). Рубеж задаёт ручка окружения
$CLAUDE_JUDGE_ARCHIVE_DAYS (сутки, умолчание 180).

Проб в одном прогоне может быть НЕСКОЛЬКО: --probe judge,failover (волна
227b). Владелец прополки один на все журналы -- этот проход; второй агент,
обёртка и вторая копия расписания не заводятся. Весь проход (fold mod ->
fold shards -> сжатие -> горизонт) выполняется ПО КАЖДОЙ пробе отдельно;
каждая строка вывода несёт имя пробы префиксом [<probe>] ВСЕГДА, включая
одиночную пробу -- разбор вывода не должен зависеть от того, список это или
одно имя (урок #207: рядом с числом стоит имя владельца). Итоговый код
прогона: 1, если хотя бы одна проба отказала по существу (горизонт либо
изолированный OSError); тихий успех одной пробы не имеет права спрятать
отказ другой, и наоборот -- отказ одной не отнимает проход у остальных.
Двойка в «худший из проб» НЕ входит: код 2 -- контракт вызова по таблице
кита, он про АРГУМЕНТЫ, а не про выполнение, и весь проверяется ДО начала
прохода проб.

Idempotent: already-compacted ones are skipped, the source is deleted only
after the archive has been written and read back.

Коды выхода (подмножество общей таблицы кита -- шапка claude-patch-all.sh):
  0  проход завершён (что считать «записью» и что «мусором», решают правила
     ниже; пропуск пустого каталога -- тоже 0: нечего уплотнять -- не отказ;
     пустой список кандидатов горизонта -- тоже 0: ПУСТО не есть НОЛЬ)
  1  отказ по существу: горизонт архива не может ни унести, ни отметиться --
     не читается каталог или метка времени архива, не читается либо не пишется
     отметка горизонта, мусор в ручке окружения; либо изолированная ошибка
     внешней среды пробы (OSError: права, ENOSPC, битый путь); причина --
     словами в stderr; отказ ОДНОЙ пробы не останавливает остальные, но
     делает итоговый код 1
  2  контракт вызова нарушен (весь -- ДО начала прохода проб): argparse
     отверг аргументы (питон отдаёт 2 сам), элемент списка --probe пуст
     после обрезки пробелов, имя пробы -- не простой сегмент (пробельные
     символы, разделитель пути, «.»/«..»), либо --dir при более чем одной
     пробе (каталог записей один, а пробы разные: у каждой свой
     <дом>/<проба>/records)
Круг 28, F-10: шапка заведена, чтобы объявленный код был виден вызывающему.
"""
import argparse, glob, gzip, json, math, os, re, shutil, sys, time

# argparse-типы общих числовых ручек живут в replay.py: его уже импортируют
# validate.py и adjudicate.py, и второй копии типа не должно быть (круг 26,
# K-13/K-14 -- три читателя одной ручки с тремя своими недосмотрами). Каталог
# судьи кладётся в sys.path по той же причине, что и у соседей: раскатка
# (scripts/probes-sync.sh) держит judge/*.py в одном каталоге.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import replay

# Возраст, после которого tmp не может принадлежать здоровому писателю: он
# создаёт временный файл и переименовывает его в те же секунды. Порог служит
# ВТОРЫМ признаком рядом с проверкой pid -- номера переиспользуются, и одна
# проверка pid оставляла сироту с чужим живым номером навсегда (круг 21, F-10).
TMP_HELD_SECONDS = 24 * 3600

# Горизонт архива: возрастная граница его роста. Дом решения назначен авторами
# ядра (tweakcc-patch.js, блок о records_keep): «если когда-нибудь понадобится
# граница, её место у владельца архива -- compact.py, где живут правила
# возраста». Граница ПО ВОЗРАСТУ, а не по количеству: архив -- доказательная
# база замеров, «последние N штук» выкашивает историю неравномерно -- густо
# там, где прогонов было много, пусто там, где их было мало.
HORIZON_DAYS_ENV = 'CLAUDE_JUDGE_ARCHIVE_DAYS'
# Умолчание щедрое намеренно: цена хранения дешевле исчезнувшей улики замера,
# который уже никто не повторит. Оценка ядра («около 7 КБ на сжатую запись --
# порядок сотен мегабайт за годы») ЗАМЕРОМ НЕ ПОДТВЕРЖДЕНА и здесь не
# наследуется: 16.09.2026 боевой дом держал 6940 архивов на 176 МБ за 17.3
# суток -- 26 КБ на запись и ~10 МБ в сутки. При этом умолчании архив
# стабилизируется около 73 тыс. файлов и ~1.9 ГБ; это ПОТОЛОК взамен прежней
# бесконечности, и менять его следует пересчитав от свежего замера, а не от
# унаследованного числа.
HORIZON_DAYS_DEFAULT = 180.0
# Потолок -- век: конечность той же природы, что у --older-than-hours (876000 ч).
HORIZON_DAYS_MAX = 36500.0
# Отметка горизонта -- не журнал: рост ограничен этим числом записей прогона
# (голова -- последнее состояние, хвост -- история до этого предела).
HORIZON_KEEP_RUNS = 32
HORIZON_MARK_NAME = 'horizon.json'


def _clip(v, n=400):
    if isinstance(v, str) and len(v) > n:
        return v[:n]
    return v


def _say(probe, text):
    # CONSTRAINT (волна 227b): каждая строка вывода несёт имя пробы префиксом
    # ВСЕГДА, включая одиночную пробу -- разбор вывода не зависит от того,
    # список проб назван или одно имя, а рядом с каждым числом стоит владелец.
    print(f'[{probe}] {text}')


def _warn(probe, text):
    # Тот же префикс для stderr: отказ и предупреждение принадлежат пробе.
    print(f'[{probe}] {text}', file=sys.stderr)


# CONSTRAINT (#374): служебные исходы прибора -- НЕ виды вердикта и в доме
# словаря не объявлены; их места остаются литеральными по обе стороны (тот же
# набор в моде, outcomeOf). Это решение, а не недосмотр: «вердикта нет» и
# причина, по которой его нет, не могут зависеть от словаря пробы.
_SERVICE_OUTCOME = {
    'NONE': 'block_no_verdict',
    'TIMEOUT': 'skip',
    'TRUNCATED': 'skip',
    'SKIP': 'skip',
    'STALE_EPOCH': 'skip',
}


def _outcome_by_home(kind, probe, filename):
    """Класс свёртки вида ПО ДОМУ пробы; неопределимость -- отказ прибора.

    CONSTRAINT: литеральной таблицы видов здесь больше нет. Она была ВТОРЫМ
    домом правила, не знала пробы и расходилась с модом на пяти видах
    (PASS/WARN/REFUSE формы, SILENT/NUDGE бездействия), а расхождение было
    видно только сличением двух домов.
    """
    if not kind:
        # CONSTRAINT: улика без вида -- ПОВРЕЖДЁННАЯ улика, а не пропуск.
        # Молчаливый 'skip' положил бы её в метриках рядом с честными
        # пропусками, и потеря вердикта стала бы неотличима от его отсутствия.
        print(f'улика без вида вердикта: {filename} (проба "{probe}") -- '
              'класс свёртки неопределим', file=sys.stderr)
        raise SystemExit(2)
    if kind in _SERVICE_OUTCOME:
        return _SERVICE_OUTCOME[kind]
    emits, folds = replay.verdict_vocabulary(probe=probe)
    if kind in emits:
        return 'block' if kind in folds else 'ok'
    return 'skip'


def _line_from_mod(rec, filename, probe):
    kind = rec.get('kind')
    rest = rec.get('rest') or rec.get('by') or ''
    t0 = rec.get('t0')
    t = None
    if isinstance(t0, (int, float)) and t0 > 0:
        t = time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime(t0 / 1000.0))
    verdict = None
    if kind:
        verdict = _clip(f'{kind}: {rest}')
    line = {
        't': t,
        'tool': rec.get('tool'),
        'agent': rec.get('agent'),
        'sid': rec.get('sid'),
        'ms': rec.get('dtMs') if rec.get('dtMs') is not None else 0,
        # CONSTRAINT: готовое поле улики -- ПЕРВИЧНО: мод посчитал класс один
        # раз и положил ТО ЖЕ значение в свою журнальную строку. Пересчёт
        # здесь вернул бы второй дом правила через чёрный ход.
        'outcome': rec.get('outcome') or _outcome_by_home(kind, probe, filename),
        'verdict': verdict,
        'jm': rec.get('used'),
        'rec': filename,
        'carrier': 'mod',
        'cls': rec.get('cls'),
    }
    if rec.get('by'):
        line['reason'] = rec.get('by')
    return {k: v for k, v in line.items() if v is not None}


def _load_mod_record(path):
    try:
        if path.endswith('.gz'):
            with gzip.open(path, 'rt', encoding='utf-8') as fh:
                return json.load(fh)
        with open(path, encoding='utf-8') as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError, UnicodeError):
        return False


def read_journal_lines(journal_path, existing, probe):
    """Разбор строк журнала с ИМЕНОВАНИЕМ непарсящихся.

    Возвращает (rows, torn): rows -- список пар (строка, объект) по тем
    строкам, что разобрались; torn -- сколько НЕ разобралось.

    Образец поведения взят у соседа по этому же дереву: adjudicate.py на файле
    меток печатает «ВНИМАНИЕ: <путь>:<номер> не разбирается (<exc>); строка
    пропущена» и считает пропуск. Журнал был единственным читаемым файлом
    набора, где этого не было: оба цикла ниже делали
    `except json.JSONDecodeError: continue`, а счётчик `не прочитано` в их
    итогах считает СОВСЕМ ДРУГОЕ -- нечитаемые файлы записей (fold mod) и
    нечитаемый шард со своими строками (fold shards). На журнале с порванной
    строкой итог печатал «не прочитано 0»: это не умолчание, а ЛОЖНОЕ ЧИСЛО о
    журнале -- инструмент утверждал, что непрочитанного нет, глядя при этом на
    непрочитанную строку. Строка шарда, порвавшаяся точно так же, считалась.

    Почему счётчик отдельный, а не тот же `unread`: сущности разные (файл
    записи против строки журнала), и сложение спрятало бы, ЧТО именно не
    прочитано.

    Номер строки -- от начала файла, ВКЛЮЧАЯ пустые: координата обязана
    приводить к строке, иначе она хуже отсутствующей.

    Одна порванная строка при полном проходе называется ДВАЖДЫ -- по разу от
    каждой свёртки. Это не дубль под склейку: проходы независимы, и число в
    итоге каждого описывает ЕГО чтение. Свести их в один голос значило бы
    сделать одно из двух чисел ложным.

    Длина и наличие NUL названы не для красоты: измеренный случай (журнал
    судьи, строка 346) -- 271 байт данных плюс 11 NUL, подпись «файл вырос,
    данные до диска не дошли». Она отличает оборванную запись от гонки
    чтения-записи, которая теряет строку целиком и NUL не оставляет.
    """
    rows = []
    torn = 0
    for lineno, raw in enumerate(existing.splitlines(), 1):
        s = raw.strip()
        if not s:
            continue
        try:
            obj = json.loads(s)
        except ValueError as exc:
            torn += 1
            body = raw.encode('utf-8', 'surrogateescape')
            has_nul = 'да' if b'\x00' in body else 'нет'
            _warn(probe,
                  f'ВНИМАНИЕ: {journal_path}:{lineno} не разбирается ({exc}); '
                  f'длина {len(body)} байт, NUL: {has_nul}; строка пропущена')
            continue
        rows.append((s, obj))
    return rows, torn


def fold_mod_records(journal_path, records_dir, probe, dry_run=False):
    """Insert missing journal index lines for records/mod-*.json{,.gz}.

    The function-hooks carrier has no append verb ($.fs.write overwrites).
    The hook does a read-modify-write of journal.jsonl; two concurrent
    hooks can lose a line. Unique record files are the source of truth.
    Idempotent: a line whose rec field already names the file is left
    alone. Does not rewrite existing splice lines.
    """
    added = skipped = unread = torn = 0
    if not os.path.isdir(records_dir):
        _say(probe, f'fold mod: записей нет ({records_dir})')
        return
    names = []
    for pat in ('mod-*.json', 'mod-*.json.gz'):
        names.extend(os.path.basename(x) for x in glob.glob(os.path.join(records_dir, pat)))
    if not names:
        _say(probe, 'fold mod: нечего вкладывать')
        return
    seen = set()
    existing = ''
    try:
        with open(journal_path, encoding='utf-8') as fh:
            existing = fh.read()
    except FileNotFoundError:
        existing = ''
    if existing:
        rows, torn = read_journal_lines(journal_path, existing, probe)
        for _s, obj in rows:
            rec = obj.get('rec')
            if isinstance(rec, str):
                seen.add(rec)
                if rec.endswith('.json'):
                    seen.add(rec + '.gz')
                if rec.endswith('.json.gz'):
                    seen.add(rec[:-3])
    new_lines = []
    for name in sorted(names):
        rec_field = name[:-3] if name.endswith('.gz') else name
        if name in seen or rec_field in seen:
            skipped += 1
            continue
        loaded = _load_mod_record(os.path.join(records_dir, name))
        if loaded is None:
            continue
        if loaded is False:
            unread += 1
            continue
        if not isinstance(loaded, dict):
            unread += 1
            continue
        line = _line_from_mod(loaded, rec_field, loaded.get('probe') or probe)
        new_lines.append(json.dumps(line, ensure_ascii=False))
        added += 1
    if new_lines and not dry_run:
        pfx = ''
        if existing and not existing.endswith('\n'):
            pfx = '\n'
        os.makedirs(os.path.dirname(journal_path) or '.', exist_ok=True)
        with open(journal_path, 'a', encoding='utf-8') as fh:
            fh.write(pfx + '\n'.join(new_lines) + '\n')
    # Ноль печатается тоже: отсутствие слова читатель принимает за отсутствие
    # проблемы, и молчащее число ничем не лучше молчащего разбора.
    _say(probe, f'fold mod: добавлено {added}, уже в индексе {skipped}, не прочитано {unread}'
         f', строк журнала не разобрано {torn}'
         f'{" (dry-run)" if dry_run else ""}')


def fold_journal_shards(journal_path, probe, dry_run=False):
    """Append unique sibling shards written by the function-hooks carrier.

    The hook cannot append: $.fs.write overwrites. It writes
    ``<journal.jsonl>.shard.<rec>`` (one line). This pass copies those
    lines into journal.jsonl with open(..., 'a') and deletes the shard
    after a read-back. Idempotent on rec-field / exact line.
    """
    added = skipped = unread = 0
    d = os.path.dirname(os.path.abspath(journal_path)) or '.'
    base = os.path.basename(journal_path)
    prefix = base + '.shard.'
    shards = []
    try:
        names = os.listdir(d)
    except FileNotFoundError:
        _say(probe, 'fold shards: каталога нет')
        return
    for name in names:
        if name.startswith(prefix):
            shards.append(os.path.join(d, name))
    if not shards:
        _say(probe, 'fold shards: нечего вкладывать')
        return
    seen_rec = set()
    seen_line = set()
    existing = ''
    try:
        with open(journal_path, encoding='utf-8') as fh:
            existing = fh.read()
    except FileNotFoundError:
        existing = ''
    rows, torn = read_journal_lines(journal_path, existing, probe)
    for s, obj in rows:
        seen_line.add(s)
        rec = obj.get('rec')
        if isinstance(rec, str):
            seen_rec.add(rec)
    new_lines = []
    consumed = []
    for path in sorted(shards):
        try:
            text = open(path, encoding='utf-8').read()
        except FileNotFoundError:
            continue
        except (OSError, UnicodeError):
            unread += 1
            continue
        local = []
        dup = True
        for raw in text.splitlines():
            s = raw.strip()
            if not s:
                continue
            try:
                obj = json.loads(s)
            except json.JSONDecodeError:
                unread += 1
                dup = False
                continue
            rec = obj.get('rec')
            if s in seen_line or (isinstance(rec, str) and rec in seen_rec):
                skipped += 1
                continue
            dup = False
            local.append(s)
            seen_line.add(s)
            if isinstance(rec, str):
                seen_rec.add(rec)
            added += 1
        if local:
            new_lines.extend(local)
        if not dup or local:
            consumed.append(path)
        elif dup:
            consumed.append(path)
    if new_lines and not dry_run:
        pfx = ''
        if existing and not existing.endswith('\n'):
            pfx = '\n'
        os.makedirs(os.path.dirname(journal_path) or '.', exist_ok=True)
        with open(journal_path, 'a', encoding='utf-8') as fh:
            fh.write(pfx + '\n'.join(new_lines) + '\n')
        # read-back: the just-appended tail must contain every new line
        with open(journal_path, encoding='utf-8') as fh:
            got = set(x.strip() for x in fh.read().splitlines() if x.strip())
        if not set(new_lines) <= got:
            _say(probe, 'fold shards: read-back missed lines; shards kept')
            consumed = []
    if not dry_run:
        for path in consumed:
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
    # Тот же договор, что у fold mod: число называется всегда, включая ноль.
    _say(probe, f'fold shards: добавлено {added}, уже в индексе {skipped}, не прочитано {unread}'
         f', строк журнала не разобрано {torn}'
         f'{" (dry-run)" if dry_run else ""}')



class HorizonRefusal(Exception):
    """Отказ прибора горизонта: унести нельзя или нельзя отметиться (код 1)."""


def _horizon_days():
    """Сутки горизонта из ручки окружения.

    Мусор в ручке -- отказ, а не молчаливое умолчание: откат к 180 суткам
    превращал бы опечатку владельца в тихое «всё в порядке». Разбор -- тот же
    bounded_float, что у --older-than-hours: вторая копия парсера числовой
    ручки -- путь к трём читателям с тремя недосмотрами (круг 26, K-13/K-14).
    """
    raw = os.environ.get(HORIZON_DAYS_ENV)
    if raw is None:
        return HORIZON_DAYS_DEFAULT
    parse = replay.bounded_float(HORIZON_DAYS_ENV, 0, HORIZON_DAYS_MAX)
    try:
        return parse(raw)
    except argparse.ArgumentTypeError as exc:
        raise HorizonRefusal(str(exc))


def _horizon_mark_entries(data):
    """Записи отметки с проверкой формы: чужая структура -- отказ, не догадка.

    Отметку пишет только этот проход, но лежит она в общем доме: молча
    перезаписать непонятное -- стереть единственное объяснение чужих пропаж.
    """
    if not isinstance(data, dict) or not isinstance(data.get('runs'), list):
        raise HorizonRefusal('отметка горизонта: верхний уровень не {"runs": [...]}')
    for entry in data['runs']:
        if not isinstance(entry, dict):
            raise HorizonRefusal('отметка горизонта: запись не объект')
        for field in ('horizon_epoch', 'run_epoch'):
            value = entry.get(field)
            if isinstance(value, bool) or not isinstance(value, (int, float)) \
                    or not math.isfinite(value):
                raise HorizonRefusal(
                    f'отметка горизонта: поле {field} не конечное число')
        removed = entry.get('removed')
        if isinstance(removed, bool) or not isinstance(removed, int):
            raise HorizonRefusal('отметка горизонта: поле removed не целое')
    return data['runs']


def _horizon_mark_read(mark_path):
    """Отметка горизонта: отсутствующая -- пустая история, битая -- отказ."""
    try:
        with open(mark_path, encoding='utf-8') as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return []
    except (OSError, ValueError) as exc:
        raise HorizonRefusal(f'отметка горизонта не читается: {mark_path}: {exc}')
    return _horizon_mark_entries(data)


def _horizon_merged(previous, entry, keep=HORIZON_KEEP_RUNS):
    """Голова -- текущий прогон, хвост обрезан: рост отметки ограничен keep."""
    return [entry] + list(previous)[: keep - 1]


def _horizon_write_mark(mark_path, runs):
    """Атомарная запись отметки: tmp + replace, как у архива (та же гонка двух
    своих проходов -- последний replace оставляет валидный JSON всегда)."""
    tmp = f'{mark_path}.tmp.{os.getpid()}'
    try:
        with open(tmp, 'w', encoding='utf-8') as fh:
            json.dump({'runs': runs}, fh, ensure_ascii=False)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, mark_path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise HorizonRefusal(f'отметка горизонта не пишется: {mark_path}: {exc}')


def prune_archive_horizon(records_dir, probe, dry_run=False):
    """Прополка архива по возрасту с обязательной отметкой горизонта.

    Архив -- имена, КОТОРЫМИ кончающиеся на .json.gz. Положительный список
    здесь не «допустимость», а разграничение владельцев: горячие .json держит
    окно ядра (records_keep), обломки <имя>.json.gz.tmp.<pid> -- прополка tmp
    этого же прохода; подстрока '.json.gz' вместо суффикса отдала бы горизонту
    чужое имя. Отметка пишется ДО снятия: отказ отметиться обязан случиться
    раньше, чем унесена первая запись, иначе появится удаление без объяснения.
    Исчезнувший под руками файл -- ожидаемый исход (гонка с прополкой ядра и со
    вторым своим проходом), а не отказ: тот же договор, что у цикла сжатия.
    """
    counters = {'taken': 0, 'vanished': 0, 'bytes': 0}
    days = _horizon_days()
    now = time.time()
    edge = now - days * 86400.0
    mark_path = os.path.join(
        os.path.dirname(os.path.abspath(records_dir)), HORIZON_MARK_NAME)
    try:
        names = sorted(os.listdir(records_dir))
    except FileNotFoundError:
        # Тот же договор, что у сжатия (шапка): отсутствующий каталог -- не отказ.
        _say(probe, 'горизонт архива: каталога нет -- нечего пропалывать')
        return counters
    except OSError as exc:
        raise HorizonRefusal(f'каталог архива не читается: {records_dir}: {exc}')
    candidates = []
    for name in names:
        if not name.endswith('.json.gz'):
            continue
        path = os.path.join(records_dir, name)
        try:
            st = os.stat(path)
        except FileNotFoundError:
            # Снял соперничающий уборщик -- уже достигнутая цель, не потеря.
            counters['vanished'] += 1
            continue
        except OSError as exc:
            raise HorizonRefusal(f'метка времени архива не читается: {path}: {exc}')
        if st.st_mtime > edge:
            continue
        candidates.append((path, name, st.st_size))
    entry = {'horizon_epoch': edge, 'removed': len(candidates), 'run_epoch': now}
    if not dry_run:
        runs = _horizon_mark_read(mark_path)
        _horizon_write_mark(mark_path, _horizon_merged(runs, entry))
    for path, name, size in candidates:
        if dry_run:
            _say(probe, f'унёс бы архив: {name}  {size} байт')
            counters['taken'] += 1
            counters['bytes'] += size
            continue
        try:
            os.unlink(path)
        except FileNotFoundError:
            # Соперничающий уборщик успел раньше -- не отказ и не потеря.
            counters['vanished'] += 1
            continue
        counters['taken'] += 1
        counters['bytes'] += size
    if not dry_run and counters['vanished']:
        # Унесено меньше запланированного (часть унесла чужая рука): финальная
        # отметка обязана нести фактическое число, а не план.
        entry['removed'] = counters['taken']
        _horizon_write_mark(mark_path, _horizon_merged(runs, entry))
    # Ноль печатается тоже: молчащее число ничем не лучше молчащего разбора.
    _say(probe, f"горизонт архива: унесено {counters['taken']}, "
         f"исчезли {counters['vanished']}, байт {counters['bytes']}, рубеж "
         f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(edge))}")
    return counters


def _bad_probe_name(name):
    """Причина негодности имени пробы словами, либо None.

    Имя пробы -- ПРОСТОЙ СЕГМЕНТ пути: оно становится именем каталога внутри
    дома проб, и всё, что выходит за сегмент (пробельные символы,
    разделитель пути, точка-имя), уводит проход в каталог с пробелом или за
    пределы дома, а проход УДАЛЯЕТ файлы (шарды, архивы горизонта). Опечатка
    владельца не имеет права превращаться в прогон неизвестно чего; имя с
    пробельными символами отвергается ЦЕЛИКОМ, без молчаливой обрезки:
    прощённая опечатка невидима, названная -- исправима (замер контроллера:
    «judge, failover» молча шёл в каталог « failover», «../escaped» -- за
    пределы дома).
    """
    if any(ch.isspace() for ch in name):
        return 'пробельные символы'
    if '/' in name or os.sep in name:
        return 'разделитель пути'
    if name in ('.', '..'):
        return 'имя-точка'
    return None


def _probe_list(raw):
    """Разбор --probe: список через запятую (волна 227b).

    Порядок сохраняется, повтор схлопывается с названной строкой. Элемент,
    пустой после обрезки пробелов («judge,», «--probe ""»), -- отказ
    контракта кодом 2, а не молчаливый пропуск; имя пробы обязано быть
    ПРОСТЫМ СЕГМЕНТОМ пути (см. _bad_probe_name) -- тоже кодом 2, с
    показом негодного имени. Обе проверки -- ДО начала прохода: опечатка
    владельца не имеет права превращаться в прогон неизвестно чего, а
    проход удаляет файлы. Владелец прополки журналов один на все пробы --
    второй агент не заводится, список расширяет этот же проход.
    """
    probes = []
    seen = set()
    for item in raw.split(','):
        if item.strip() == '':
            print(f'ОТКАЗ: пустой элемент в списке проб ({item!r} в '
                  f'--probe {raw!r}); проба обязана быть названа', file=sys.stderr)
            sys.exit(2)
        if _bad_probe_name(item):
            print(f'ОТКАЗ: негодное имя пробы {item!r} в --probe {raw!r}: '
                  f'{_bad_probe_name(item)}; имя обязано быть простым сегментом '
                  '(без пробельных символов, без разделителей пути, не . и не ..)',
                  file=sys.stderr)
            sys.exit(2)
        if item in seen:
            _say(item, 'проба названа повторно -- схлопнуто')
            continue
        seen.add(item)
        probes.append(item)
    return probes


def run_probe(probe, a):
    """Один полный проход по пробе: свёртки, сжатие, горизонт.

    Отказ HorizonRefusal ловит вызывающий цикл: отказ одной пробы не
    останавливает остальные и не отменяет их вывод.
    """
    records_dir = a.dir if a.dir is not None else os.path.join(
        os.path.expanduser(a.home), probe, 'records')
    journal_path = os.path.join(os.path.expanduser(a.home), probe, 'journal.jsonl')
    fold_mod_records(journal_path, records_dir, probe, dry_run=a.dry_run)
    fold_journal_shards(journal_path, probe, dry_run=a.dry_run)


    cutoff = time.time() - a.older_than_hours * 3600
    done = saved = skipped = vanished = gz_gone = orphans = src_gone = 0
    tmp_held = 0
    # Гонка с прополкой ядра (tweakcc-patch.js, records_keep, дефолт 500):
    # ядро удаляет старейшие записи ЭТОГО же каталога в любой момент, и файл,
    # уже попавший в наш глоб, исчезает до getmtime, между getmtime и open,
    # между open и unlink. Первый же выигранный ядром unlink ронял весь
    # ночной проход (launchd повторил бы его только через сутки).
    # Исчезнувший под руками файл — НЕ ошибка прохода, а его цель: запись уже
    # убрана. Поэтому каждая операция с записью ловит FileNotFoundError,
    # считает её отдельным счётчиком «исчезли под руками» и идёт дальше по
    # списку; прочие исключения по-прежнему падают наружу.
    # Свои осиротевшие tmp сносим ДО основного цикла: прогон, убитый между
    # созданием tmp и replace, оставляет <имя>.json.gz.tmp.<pid> навсегда —
    # наш глоб *.json его не видит, ветка доведения смотрит на конечный gz,
    # а прополка ядра убирает такой файл только на общих основаниях, как
    # старейшее имя каталога. Убираем только доказанно ничьи: суффикс-число,
    # чей pid мёртв. Живой pid — наш или чужого работающего прохода — не
    # трогаем (PermissionError от os.kill(pid, 0) = процесс жив, но
    # принадлежит другому пользователю); нечисловой суффикс оставляем:
    # происхождение такого файла неизвестно.
    tmp_form = re.compile(r'\.json\.gz\.tmp\.[0-9]+\Z')
    for t in glob.glob(os.path.join(records_dir, '*.json.gz.tmp.*')):
        # Глоб шире формы писателя: `.tmp.*` ловит и `.tmp.12.34`, и
        # `.tmp.pid-7`, и `.tmp.²`. Имя сверяется с ТОЙ ЖЕ формой, которую
        # пишет строка создания ниже (`gz + f'.tmp.{os.getpid()}'`), иначе
        # прополка снимает файлы чужого происхождения.
        if not tmp_form.search(t):
            continue
        suffix = t.rsplit('.', 1)[-1]
        # `str.isdigit()` истинно и для '²' (int его отвергает), а
        # 20-значное число os.kill не принимает вовсе (OverflowError).
        # Форма выше уже отсекла и то и другое; int() и kill() всё равно
        # обёрнуты -- прополка не имеет права падать на имени файла.
        try:
            pid = int(suffix)
        except ValueError:
            continue
        # Снимок до проверки: между «pid мёртв» и unlink номер может быть
        # переиспользован новым прогоном, который создаст СВОЙ файл с тем же
        # именем. Сверка inode+mtime после проверки сужает окно до нуля
        # полезных случаев: изменившийся файл -- уже не тот, что признан ничьим.
        try:
            before = os.stat(t)
        except FileNotFoundError:
            continue
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass                       # pid мёртв -- файл ничей
        except (PermissionError, OverflowError, ValueError):
            tmp_held += 1
            continue                   # живой чужой процесс либо неномер pid
        else:
            # Живой pid НЕ ДОКАЗЫВАЕТ, что файл чей-то: номера переиспользуются,
            # и сирота, чей номер достался долгоживущему процессу, не снимался
            # НИКОГДА -- прополка обходила его каждый проход, вечно (круг 21,
            # F-10). Возраст файла -- признак, не зависящий от номера: писатель
            # создаёт tmp и переименовывает его в те же секунды, поэтому tmp
            # старше суток не принадлежит здоровому писателю ни при каком pid.
            # Зависший на сутки писатель и так сломан, а его rename после снятия
            # tmp падает FileNotFoundError -- запись останется несжатой и будет
            # сжата следующим проходом.
            try:
                age = time.time() - os.stat(t).st_mtime
            except FileNotFoundError:
                continue
            # Граница: mtime в будущем (дальше +60 c) -- не живой писатель, а
            # испорченная метка (шаг часов, копия с машины вперёд); такой
            # обломок протухает наравне со старым. Порог общий с tools/sweep.sh.
            if age < TMP_HELD_SECONDS and before.st_mtime <= time.time() + 60:
                tmp_held += 1
                continue               # живой писатель, файл свежий
        if a.dry_run:
            _say(probe, f'снёс бы сироту tmp: {os.path.basename(t)}')
        else:
            try:
                after = os.stat(t)
            except FileNotFoundError:
                continue               # соперничающий уборщик успел раньше
            if (after.st_ino, after.st_mtime_ns) != (before.st_ino, before.st_mtime_ns):
                continue               # файл подменён после проверки -- не наш
            try:
                os.unlink(t)
            except FileNotFoundError:
                continue
        orphans += 1
    for f in sorted(glob.glob(os.path.join(records_dir, '*.json'))):
        try:
            mtime = os.path.getmtime(f)
        except FileNotFoundError:
            vanished += 1
            continue
        if mtime > cutoff:
            skipped += 1
            continue
        gz = f + '.gz'
        if os.path.exists(gz):
            # Запись И её архив рядом -- это не «уже сжато», а ОБОРВАННОЕ
            # сжатие: прогон, убитый между записью архива и удалением
            # исходника. Прежняя ветка считала это «пропущено» -- тем же
            # словом, что и «слишком свежая», -- и состояние не имело
            # собственного вывода. Оно не рассасывалось: каждый следующий
            # проход снова пропускал пару, диск не освобождался, а горизонт
            # ядра (records_keep считает .json и .json.gz одинаково) тратил
            # на неё два места вместо одного.
            #
            # Доделываем начатое, а не обходим: архив либо читается -- тогда
            # исходник удаляется, как и должен был, -- либо не читается и
            # удаляется сам, чтобы запись сжалась заново на этом же проходе.
            # Верификация читает КОНЕЧНЫЙ файл (gz), а не промежуточное имя:
            # эта ветка доводит оборванное сжатие, и целостность проверяется
            # у того, что уже лежит на диске под конечным именем.
            # Архив, исчезнувший между exists и чтением, НЕ делает запись
            # исчезнувшей: исходник на месте и всё ещё не сжат. Две прежние
            # ветки считали такой случай «исчез под руками» и уходили по
            # continue — запись оставалась несжатой, а счётчик винил в этом
            # чужую прополку. Исход тот же, что и у нечитаемого архива:
            # сжать заново ЗДЕСЬ ЖЕ, на этом проходе.
            recompress = False
            try:
                with gzip.open(gz, 'rt', encoding='utf-8') as fh:
                    json.load(fh)
            except FileNotFoundError:
                recompress = True
            except Exception as e:
                if a.dry_run:
                    # Паритет: сухой прогон обязан назвать тот ИСХОД, к
                    # которому пришёл бы боевой (запись будет сжата -> done),
                    # иначе «сжал бы N» расходится с реальным N.
                    _say(probe, f'пересжал бы (архив рядом не читается): {os.path.basename(f)}: {e}')
                    done += 1
                    continue
                try:
                    os.unlink(gz)
                except FileNotFoundError:
                    pass          # архив уже убран — пересжимаем всё равно
                _say(probe, f'ОБОРВАННОЕ СЖАТИЕ, архив не читается -- пересжимаю: {os.path.basename(f)}: {e}')
                recompress = True
            else:
                if a.dry_run:
                    _say(probe, f'удалил бы исходник (архив рядом целый): {os.path.basename(f)}')
                    done += 1
                    continue
                # Та же асимметрия, что была ниже у основного пути: архив уже
                # проверен и лежит под конечным именем, поэтому исчезнувший
                # исходник — достигнутая цель, а не потеря. Размер исходника
                # при этом неизвестен, и экономия по нему не считается: свой
                # счётчик честнее, чем ноль, подмешанный в saved.
                try:
                    before = os.path.getsize(f)
                except FileNotFoundError:
                    before = None
                try:
                    os.unlink(f)
                except FileNotFoundError:
                    pass
                done += 1
                if before is None:
                    src_gone += 1
                else:
                    try:
                        saved += before - os.path.getsize(gz)
                    except FileNotFoundError:
                        gz_gone += 1
                _say(probe, f'ОБОРВАННОЕ СЖАТИЕ ДОВЕДЕНО: {os.path.basename(f)}')
                continue
            del recompress          # сюда попадают только записи на пересжатие
        try:
            before = os.path.getsize(f)
        except FileNotFoundError:
            vanished += 1
            continue
        if a.dry_run:
            _say(probe, f'сжал бы: {os.path.basename(f)}  {before} байт')
            done += 1
            continue
        # Архив пишется под временным именем и становится конечным только
        # через os.replace после верификации: раньше gzip.open бил прямо в
        # конечное имя, и второй инстанс прохода (launchd + ручной) видел
        # недописанный .gz как «архив уже есть» — ветка доведения выше при
        # неудачном чтении удаляла бы И архив, И исходник. Суффикс .tmp.<pid>
        # действительно не подпадает под НАШ глоб *.json, поэтому записью
        # сам проход его не считает — но в горизонт ядра он попадает:
        # прополка (tweakcc-patch.js, records_keep) читает каталог БЕЗ
        # фильтра расширений, tmp занимает место, вытесняя настоящую запись,
        # и может быть убран в любой момент, включая миг между верификацией
        # и replace ниже.
        tmp = gz + f'.tmp.{os.getpid()}'
        try:
            with open(f, 'rb') as src, gzip.open(tmp, 'wb', compresslevel=9) as dst:
                shutil.copyfileobj(src, dst)
        except FileNotFoundError:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
            vanished += 1
            continue
        # the record is deleted only if the archive reads and parses back —
        # otherwise compaction would turn into loss of material
        try:
            with gzip.open(tmp, 'rt', encoding='utf-8') as fh:
                json.load(fh)
        except Exception as e:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
            _say(probe, f'ПРОПУЩЕНО (архив не читается): {os.path.basename(f)}: {e}')
            skipped += 1
            continue
        # Прополка ядра не смотрит на расширения: и tmp может не дожить до
        # replace (см. комментарий у его создания выше).
        try:
            os.replace(tmp, gz)
        except FileNotFoundError:
            vanished += 1
            continue
        # Исходник, пропавший ПОСЛЕ replace, — не «исчез под руками»: архив
        # уже лежит под конечным именем, исходника нет, то есть конечное
        # состояние ровно то, ради которого проход и затевался. Кто снял
        # исходник, мы или прополка ядра, на результат не влияет, поэтому
        # обе ветки считаются одинаково (иначе done занижался бы ровно на
        # проигранных гонках, а vanished завышался).
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass
        # Как в ветке доведения выше: запись сжата; пропажа архива при
        # подсчёте статистики — отдельный счётчик, а не «исчезла под руками».
        done += 1
        try:
            saved += before - os.path.getsize(gz)
        except FileNotFoundError:
            gz_gone += 1

    # Ноль печатается тоже (тот же договор, что у свёрток): молчащее число
    # ничем не лучше молчащего разбора.
    _say(probe, f'сжато: {done}, пропущено: {skipped}, исчезли под руками: {vanished}, '
         f'архив исчез после сжатия: {gz_gone}, исходник исчез до замера: {src_gone}, '
         f'сирот tmp убрано: {orphans}, tmp при живом pid: {tmp_held}, '
         f'освобождено: {saved/1048576:.2f} МБ')

    # Горизонт идёт ПОСЛЕ цикла сжатия, и порядок здесь несущий: сжатие
    # создаёт архивы, горизонт их уносит. В обратном порядке запись, сжатая
    # этим же проходом, успевала бы попасть в кандидаты того же прогона.
    prune_archive_horizon(records_dir, probe, dry_run=a.dry_run)


def main():
    p = argparse.ArgumentParser()
    # Лестница дома -- та же, что у ядра (круг 21, F-8).
    home = (os.environ.get('CLAUDE_PROBES_DIR')
            or os.path.join(os.environ.get('CLAUDE_CONFIG_DIR') or '~/.claude', 'probes'))
    p.add_argument('--home', default=home, help='дом проб')
    p.add_argument('--probe', default='judge',
                   help='пробы через запятую (judge,failover)')
    p.add_argument('--dir', default=None,
                   help='каталог записей; только для одиночной пробы '
                        '(умолчание: <дом>/<проба>/records)')
    # Отрезок [0, 876000]: ноль -- буквальное «старше нуля часов» (решение
    # контроллера, не менять), верхняя граница -- сто лет: конечность и
    # неотрицательность -- часть контракта. Прежний type=float пропускал минус
    # и nan молча: минус клал cutoff в БУДУЩЕЕ и сжимал всё живое, nan делал
    # `mtime > nan` всегда ложным с тем же исходом -- при коде 0 и счётчике
    # «сжато: N», выглядящем как штатный проход (круг 26, K-14).
    p.add_argument('--older-than-hours', type=replay.bounded_float(
        '--older-than-hours', 0, 876000), default=24)
    p.add_argument('--dry-run', action='store_true')
    a = p.parse_args()
    probes = _probe_list(a.probe)
    if a.dir is not None and len(probes) > 1:
        print('ОТКАЗ: --dir задаёт ОДИН каталог записей, а проб в списке '
              f'{len(probes)}; у каждой пробы свой <дом>/<проба>/records',
              file=sys.stderr)
        sys.exit(2)

    worst = 0
    for probe in probes:
        try:
            run_probe(probe, a)
        except HorizonRefusal as exc:
            # Отказ прибора отделён от работы (шапка файла): «унести нельзя» и
            # «уносить нечего» -- разные исходы, и второй никогда не маскирует
            # первый. Причина словами в stderr, код 1, без трейсбека: адресат
            # этой строки -- журнал launchd, а не отладчик. Отказ ОДНОЙ пробы
            # не останавливает остальные: тихий успех одной пробы не имеет
            # права спрятать отказ другой, и наоборот.
            _warn(probe, f'ОТКАЗ ГОРИЗОНТА: {exc}')
            worst = 1
        except OSError as exc:
            # Изоляция пробы от ошибок ВНЕШНЕЙ среды (права, ENOSPC, битый
            # путь): запись журнала в свёртках идёт open(..., 'a') без охраны,
            # и непишущийся журнал ОДНОЙ пробы ронял весь прогон трейсбеком,
            # отнимая проход у остальных (доработка 227b). Ловится ровно
            # OSError: ошибки программиста (TypeError и прочие) обязаны
            # падать громко -- глухой except Exception здесь запрещён.
            _warn(probe, f'ОТКАЗ ПРОХОДА: {exc}')
            worst = 1
    return worst


if __name__ == '__main__':
    sys.exit(main())
