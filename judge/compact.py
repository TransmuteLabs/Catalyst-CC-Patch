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
        # the record is deleted only if the archive reads and parses back —
        # otherwise compaction would turn into loss of material
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
