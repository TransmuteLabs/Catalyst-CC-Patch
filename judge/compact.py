#!/usr/bin/env python3
"""Daily compaction of judgment records.

Records are written uncompressed: a fresh record must be readable and greppable.
They lose value gradually, while the volume grows noticeably — about a hundred
kilobytes per judgment, almost all of it the transcript. So they are compacted
by a separate pass, by age.

  compact.py [--dir D] [--older-than-hours N] [--dry-run]

Idempotent: already-compacted ones are skipped, the source is deleted only
after the archive has been written and read back.

Коды выхода (подмножество общей таблицы кита -- шапка claude-patch-all.sh):
  0  проход завершён (что считать «записью» и что «мусором», решают правила
     ниже; пропуск пустого каталога -- тоже 0: нечего уплотнять -- не отказ)
  2  контракт вызова нарушен: argparse отверг аргументы (питон отдаёт 2 сам)
Круг 28, F-10: шапка заведена, чтобы объявленный код был виден вызывающему.
"""
import argparse, glob, gzip, json, os, re, shutil, sys, time

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


def _clip(v, n=400):
    if isinstance(v, str) and len(v) > n:
        return v[:n]
    return v


def _outcome_of(kind):
    if kind in ('OK', 'WARN'):
        return 'ok'
    if kind in ('BLOCK', 'STOP', 'DENY'):
        return 'block'
    if kind == 'NONE':
        return 'block_no_verdict'
    if kind == 'SKIP':
        return 'skip'
    return 'skip'


def _line_from_mod(rec, filename):
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
        'ms': rec.get('dtMs') if rec.get('dtMs') is not None else 0,
        'outcome': _outcome_of(kind),
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


def fold_mod_records(journal_path, records_dir, dry_run=False):
    """Insert missing journal index lines for records/mod-*.json{,.gz}.

    The function-hooks carrier has no append verb ($.fs.write overwrites).
    The hook does a read-modify-write of journal.jsonl; two concurrent
    hooks can lose a line. Unique record files are the source of truth.
    Idempotent: a line whose rec field already names the file is left
    alone. Does not rewrite existing splice lines.
    """
    added = skipped = unread = 0
    if not os.path.isdir(records_dir):
        print(f'fold mod: записей нет ({records_dir})')
        return
    names = []
    for pat in ('mod-*.json', 'mod-*.json.gz'):
        names.extend(os.path.basename(x) for x in glob.glob(os.path.join(records_dir, pat)))
    if not names:
        print('fold mod: нечего вкладывать')
        return
    seen = set()
    existing = ''
    try:
        with open(journal_path, encoding='utf-8') as fh:
            existing = fh.read()
    except FileNotFoundError:
        existing = ''
    if existing:
        for raw in existing.splitlines():
            if not raw.strip():
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
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
        line = _line_from_mod(loaded, rec_field)
        new_lines.append(json.dumps(line, ensure_ascii=False))
        added += 1
    if new_lines and not dry_run:
        pfx = ''
        if existing and not existing.endswith('\n'):
            pfx = '\n'
        os.makedirs(os.path.dirname(journal_path) or '.', exist_ok=True)
        with open(journal_path, 'a', encoding='utf-8') as fh:
            fh.write(pfx + '\n'.join(new_lines) + '\n')
    print(f'fold mod: добавлено {added}, уже в индексе {skipped}, не прочитано {unread}'
          f'{" (dry-run)" if dry_run else ""}')


def fold_journal_shards(journal_path, dry_run=False):
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
        print('fold shards: каталога нет')
        return
    for name in names:
        if name.startswith(prefix):
            shards.append(os.path.join(d, name))
    if not shards:
        print('fold shards: нечего вкладывать')
        return
    seen_rec = set()
    seen_line = set()
    existing = ''
    try:
        with open(journal_path, encoding='utf-8') as fh:
            existing = fh.read()
    except FileNotFoundError:
        existing = ''
    for raw in existing.splitlines():
        s = raw.strip()
        if not s:
            continue
        seen_line.add(s)
        try:
            obj = json.loads(s)
        except json.JSONDecodeError:
            continue
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
            print('fold shards: read-back missed lines; shards kept')
            consumed = []
    if not dry_run:
        for path in consumed:
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
    print(f'fold shards: добавлено {added}, уже в индексе {skipped}, не прочитано {unread}'
          f'{" (dry-run)" if dry_run else ""}')



def main():
    p = argparse.ArgumentParser()
    # Лестница дома -- та же, что у ядра (круг 21, F-8).
    home = (os.environ.get('CLAUDE_PROBES_DIR')
            or os.path.join(os.environ.get('CLAUDE_CONFIG_DIR') or '~/.claude', 'probes'))
    p.add_argument('--home', default=home, help='дом проб')
    p.add_argument('--probe', default='judge', help='идентификатор пробы')
    p.add_argument('--dir', default=None,
                   help='каталог записей (умолчание: <дом>/<проба>/records)')
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
    if a.dir is None:
        a.dir = os.path.join(os.path.expanduser(a.home), a.probe, 'records')

    journal_path = os.path.join(os.path.expanduser(a.home), a.probe, 'journal.jsonl')
    fold_mod_records(journal_path, a.dir, dry_run=a.dry_run)
    fold_journal_shards(journal_path, dry_run=a.dry_run)


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
    for t in glob.glob(os.path.join(a.dir, '*.json.gz.tmp.*')):
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
            print(f'снёс бы сироту tmp: {os.path.basename(t)}')
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
    for f in sorted(glob.glob(os.path.join(a.dir, '*.json'))):
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
                    print(f'пересжал бы (архив рядом не читается): {os.path.basename(f)}: {e}')
                    done += 1
                    continue
                try:
                    os.unlink(gz)
                except FileNotFoundError:
                    pass          # архив уже убран — пересжимаем всё равно
                print(f'ОБОРВАННОЕ СЖАТИЕ, архив не читается -- пересжимаю: {os.path.basename(f)}: {e}')
                recompress = True
            else:
                if a.dry_run:
                    print(f'удалил бы исходник (архив рядом целый): {os.path.basename(f)}')
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
                print(f'ОБОРВАННОЕ СЖАТИЕ ДОВЕДЕНО: {os.path.basename(f)}')
                continue
            del recompress          # сюда попадают только записи на пересжатие
        try:
            before = os.path.getsize(f)
        except FileNotFoundError:
            vanished += 1
            continue
        if a.dry_run:
            print(f'сжал бы: {os.path.basename(f)}  {before} байт')
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
            print(f'ПРОПУЩЕНО (архив не читается): {os.path.basename(f)}: {e}')
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

    print(f'сжато: {done}, пропущено: {skipped}, исчезли под руками: {vanished}, '
          f'архив исчез после сжатия: {gz_gone}, исходник исчез до замера: {src_gone}, '
          f'сирот tmp убрано: {orphans}, tmp при живом pid: {tmp_held}, '
          f'освобождено: {saved/1048576:.2f} МБ')


if __name__ == '__main__':
    main()
