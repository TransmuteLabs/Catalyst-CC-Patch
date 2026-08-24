#!/usr/bin/env python3
"""Суточное сжатие записей судейств.

Записи пишутся несжатыми: свежую запись надо читать и грепать. Ценность они
теряют не сразу, а объём растут заметный — около сотни килобайт на судейство,
почти всё это лента. Поэтому сжимаются они отдельным проходом, по возрасту.

  compact.py [--dir D] [--older-than-hours N] [--dry-run]

Идемпотентен: уже сжатые пропускаются, исходник удаляется только после того,
как архив записан и прочитан обратно.
"""
import argparse, glob, gzip, json, os, shutil, time


def main():
    p = argparse.ArgumentParser()
    home = os.environ.get('CLAUDE_PROBES_DIR') or '~/.claude/probes'
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
    done = saved = skipped = 0
    for f in sorted(glob.glob(os.path.join(a.dir, '*.json'))):
        if os.path.getmtime(f) > cutoff:
            skipped += 1
            continue
        gz = f + '.gz'
        if os.path.exists(gz):
            skipped += 1
            continue
        before = os.path.getsize(f)
        if a.dry_run:
            print(f'сжал бы: {os.path.basename(f)}  {before} байт')
            done += 1
            continue
        with open(f, 'rb') as src, gzip.open(gz, 'wb', compresslevel=9) as dst:
            shutil.copyfileobj(src, dst)
        # запись удаляется только если архив читается и разбирается обратно —
        # иначе сжатие превратилось бы в потерю материала
        try:
            with gzip.open(gz, 'rt', encoding='utf-8') as fh:
                json.load(fh)
        except Exception as e:
            os.unlink(gz)
            print(f'ПРОПУЩЕНО (архив не читается): {os.path.basename(f)}: {e}')
            skipped += 1
            continue
        os.unlink(f)
        saved += before - os.path.getsize(gz)
        done += 1

    print(f'сжато: {done}, пропущено: {skipped}, освобождено: {saved/1048576:.2f} МБ')


if __name__ == '__main__':
    main()
