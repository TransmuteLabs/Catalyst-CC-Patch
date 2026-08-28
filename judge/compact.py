#!/usr/bin/env python3
"""Daily compaction of judgment records.

Records are written uncompressed: a fresh record must be readable and greppable.
They lose value gradually, while the volume grows noticeably — about a hundred
kilobytes per judgment, almost all of it the transcript. So they are compacted
by a separate pass, by age.

  compact.py [--dir D] [--older-than-hours N] [--dry-run]

Idempotent: already-compacted ones are skipped, the source is deleted only
after the archive has been written and read back.
"""
import argparse, glob, gzip, json, os, re, shutil, time

# Возраст, после которого tmp не может принадлежать здоровому писателю: он
# создаёт временный файл и переименовывает его в те же секунды. Порог служит
# ВТОРЫМ признаком рядом с проверкой pid -- номера переиспользуются, и одна
# проверка pid оставляла сироту с чужим живым номером навсегда (круг 21, F-10).
TMP_HELD_SECONDS = 24 * 3600


def main():
    p = argparse.ArgumentParser()
    # Лестница дома -- та же, что у ядра (круг 21, F-8).
    home = (os.environ.get('CLAUDE_PROBES_DIR')
            or os.path.join(os.environ.get('CLAUDE_CONFIG_DIR') or '~/.claude', 'probes'))
    p.add_argument('--home', default=home, help='дом проб')
    p.add_argument('--probe', default='judge', help='идентификатор пробы')
    p.add_argument('--dir', default=None,
                   help='каталог записей (умолчание: <дом>/<проба>/records)')
    p.add_argument('--older-than-hours', type=float, default=24)
    p.add_argument('--dry-run', action='store_true')
    a = p.parse_args()
    if a.dir is None:
        a.dir = os.path.join(os.path.expanduser(a.home), a.probe, 'records')

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
            if age < TMP_HELD_SECONDS:
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
