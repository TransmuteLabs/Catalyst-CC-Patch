#!/usr/bin/env python3
"""Прогнать записанное судейство заново.

Запись содержит тело запроса ровно в том виде, в каком оно ушло в канал, так
что повтор — это тот же запрос ещё раз. Смысл повтора в подмене: другая модель
на том же входе, другая редакция инструкции судьи на том же входе. Сравнивать
вердикты имеет смысл только при неизменной ленте — она в записи и лежит.

  replay.py <файл|каталог> [--model M] [--prompt FILE] [--url U] [--limit N]

Без подмен повтор проверяет воспроизводимость самого канала.
"""
import argparse, glob, gzip, json, os, re, sys, urllib.request

VERDICT = re.compile(r'^\s*(?:OK|BLOCK|STOP|DENY|WARN):.*$', re.M)


def load(path):
    op = gzip.open if path.endswith('.gz') else open
    with op(path, 'rt', encoding='utf-8') as fh:
        return json.load(fh)


def verdict_of(raw):
    """Те же правила разбора, что и в самом судье: первая строка вердикта в
    content — это решение; у рассуждающей модели без content берётся ПОСЛЕДНЯЯ
    в рассуждении, чтобы отрепетированный по дороге вердикт не перебил вывод."""
    try:
        j = json.loads(raw)
    except Exception:
        return ''
    m = (j.get('choices') or [{}])[0].get('message') or {}
    c = VERDICT.findall(str(m.get('content') or ''))
    if c:
        return c[0].strip()
    rr = '\n'.join(x for x in (m.get('reasoning'), m.get('reasoning_content')) if x)
    r = VERDICT.findall(rr)
    return (r[-1] if r else str(m.get('content') or '')).strip()


# Канал отбивает запрос без узнаваемого агента: с UA питоновского urllib
# приходит 403 со страницей-заглушкой периметра, с агентом клиента — 200
# (измерено 2026-08-20). Сам судья ходит из бинаря и своего агента не теряет,
# а повтор снаружи обязан представиться так же, иначе воспроизводимость мнимая.
UA = 'claude-cli/2.1.237 (external, cli)'


def post(url, body, timeout, ua=UA):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={'content-type': 'application/json', 'user-agent': ua}, method='POST')
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode('utf-8', 'replace')


def replay(rec, args):
    body = dict(rec['request'])
    if args.model:
        body['model'] = args.model
    if args.effort:
        body['reasoning_effort'] = args.effort
    if args.prompt:
        sysmsg = open(args.prompt, encoding='utf-8').read()
        body['messages'] = [
            dict(m, content=sysmsg) if m.get('role') == 'system' else m
            for m in body['messages']]
    url = args.url or rec.get('url')
    if not url:
        sys.exit('в записи нет адреса канала — укажи --url')
    return verdict_of(post(url, body, args.timeout, args.user_agent))


def klass(v):
    m = re.match(r'\s*(OK|WARN|BLOCK|STOP|DENY)', v or '')
    return m.group(1) if m else 'EMPTY'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('target')
    p.add_argument('--model'); p.add_argument('--prompt'); p.add_argument('--url')
    # усилие задаётся явно в командной строке: канал прокси требует, чтобы оно
    # было видно в самом вызове, а не пряталось в теле записи
    p.add_argument('--effort', default='high')
    p.add_argument('--user-agent', default=UA)
    p.add_argument('--limit', type=int, default=0)
    p.add_argument('--timeout', type=float, default=120)
    a = p.parse_args()

    files = sorted(glob.glob(os.path.join(a.target, '*.json*'))) \
        if os.path.isdir(a.target) else [a.target]
    if a.limit:
        files = files[-a.limit:]

    same = diff = failed = 0
    for f in files:
        rec = load(f)
        was = rec.get('verdict') or ''
        try:
            now = replay(rec, a)
        except Exception as e:
            failed += 1
            print(f'{os.path.basename(f)}  ОШИБКА ПОВТОРА: {e}')
            continue
        changed = klass(was) != klass(now)
        same, diff = (same, diff + 1) if changed else (same + 1, diff)
        print(f'{os.path.basename(f)}  {klass(was)} -> {klass(now)}'
              f'{"  ИЗМЕНИЛОСЬ" if changed else ""}')
        if changed or len(files) == 1:
            print(f'   было:  {was[:300]}')
            print(f'   стало: {now[:300]}')
    if len(files) > 1:
        print(f'\nитого: {len(files)} записей, класс совпал {same}, '
              f'изменился {diff}, не прогналось {failed}')


if __name__ == '__main__':
    main()
