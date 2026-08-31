#!/usr/bin/env python3
"""Реплика разметки вердиктов живого судьи по записям проб.

Коды выхода (подмножество общей таблицы кита -- шапка claude-patch-all.sh):
  0  разметка завершена
  2  прибор не может мерить: образ не прочитан либо словарь вердиктов не
     извлечён из него (зашитый словарь не подставляется: расхождение с
     образом даёт неверную разметку). Круг 28, F-10: прежде эти выходы
     отдавались кодом 1 через sys.exit('строка') -- «отказ по существу»,
     хотя по существу здесь отказываться не о чем, чинить надо вход.
"""
import argparse
import glob
import gzip
import json
import math
import os
import re
import sys

# The home of the verdict dictionary is the image: that is where it is applied.
# A literal copy drifts from the image silently, and a wrong dictionary gives a
# wrong corpus annotation, which model selection then relies on.
DEFAULT_IMAGE = '~/.local/bin/claude'
_VOCAB_CACHE = {}


# Общие argparse-типы числовых ручек судейских инструментов. Дом -- replay.py:
# его уже импортируют и validate.py, и adjudicate.py, поэтому второй копии типа
# быть не должно -- три читателя --limit с тремя своими недосмотрами и были
# находкой круга 26 (K-5/K-7/K-13/K-14). ArgumentTypeError argparse сам
# превращает в код 2 «контракт вызова», назвав ручку, -- тот же код, которым
# соседи уже отвергают --jobs/--repeat (круг 28, F-10). Прежние type=int /
# type=float пропускали значение дальше, и потребитель толковал его молча:
# files[-limit:] при --limit=-1 МОЛЧА выкидывал самую старую запись, а
# --limit=-5 давал пустой список и код 5 «записи не найдены» при записях на диске.
def nonneg_int(value):
    """Целое >= 0; ноль сохраняет свой действующий смысл «без потолка»."""
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f'ожидалось целое число, получено {value!r}')
    if number < 0:
        raise argparse.ArgumentTypeError(
            f'значение не может быть отрицательным: {value!r}')
    return number


def bounded_float(name, lo, hi, note=''):
    """Конечное число (не nan, не inf) в отрезке [lo, hi]; возвращает тип.

    note дописывается к отказу «вне отрезка»: у --timeout в нём единицы --
    самая дорогая описка там миллисекунды из соседнего toml, скопированные
    в секундную ручку (240000 секунд -- это ~67 часов прогона, который не
    кончится), и отказ обязан назвать это словами, а не только числом.
    """

    def parse(value):
        try:
            number = float(value)
        except ValueError:
            raise argparse.ArgumentTypeError(
                f'{name}: ожидалось число, получено {value!r}')
        if not math.isfinite(number):
            raise argparse.ArgumentTypeError(
                f'{name}: ожидалось конечное число, получено {value!r}')
        if not lo <= number <= hi:
            raise argparse.ArgumentTypeError(
                f'{name}: {value!r} вне отрезка [{lo}, {hi}]'
                + (f'; {note}' if note else ''))
        return number

    return parse


def append_jsonl(path, payload):
    """Дописывает payload в jsonl-файл, ВОССТАНАВЛИВАЯ границу строки.

    Оборванный предыдущий писатель оставляет хвост без перевода строки, и
    следующая ПОЛНОЦЕННАЯ метка приклеивается к обломку -- толерантный читатель
    теряет ОБЕ (круг 26, L-5): повторный label возвращал 0 и печатал свой JSON,
    а перечень показывал для той же записи «нет метки». Увидев непустой файл,
    чей последний байт не \\n, писатель предваряет полезную нагрузку переводом
    строки -- обломок теряет ровно ОДНУ метку, свою. Контракт общий с ядром
    кита (tweakcc-patch.js, дозапись journal.jsonl, волна 31 бриф 1):
    границу ВОССТАНАВЛИВАЕТ писатель, читатель остаётся толерантным.
    Проверка и дозапись -- один вызов write на весь payload: строка не делится
    между write(2), замер этой механики -- в adjudicate.py.
    """
    prefix = ''
    try:
        with open(path, 'rb') as fh:
            fh.seek(0, os.SEEK_END)
            if fh.tell():
                fh.seek(-1, os.SEEK_END)
                if fh.read(1) != b'\n':
                    prefix = '\n'
    except FileNotFoundError:
        pass
    with open(path, 'a', encoding='utf-8') as fh:
        fh.write(prefix + payload)


def verdict_vocabulary(image_path=None, probe='judge'):
    path = os.path.realpath(os.path.expanduser(
        image_path or os.environ.get('CLAUDE_JUDGE_IMAGE') or DEFAULT_IMAGE))
    key = (path, probe)
    if key in _VOCAB_CACHE:
        return _VOCAB_CACHE[key]
    try:
        with open(path, 'rb') as fh:
            data = fh.read()
    except OSError as err:
        # Код 2, а не строка-в-SystemExit (она даёт 1): прибор не может
        # мерить -- круг 28, F-10.
        print(f'образ не прочитан: {path} ({err.__class__.__name__})', file=sys.stderr)
        raise SystemExit(2)
    # От дескриптора пробы до её словаря — сколько угодно полей, но НЕ через
    # соседнюю пробу: `(?!dirName:")` запрещает пересечь границу, поэтому окно
    # не приходится подгонять числом. Прежняя форма стояла на `{0,160}` и
    # молча перестала находить словарь, когда в дескриптор добавили turn/
    # selfId/turnLost (2026-08-29: расстояние стало ~250 знаков, инструмент
    # отказал на ЖИВОМ образе — «прибор не может мерить» вместо разметки).
    pattern = (rb'dirName:"' + re.escape(probe.encode()) +
               rb'"(?:(?!dirName:")[^\n]){0,4000}?rx:"([^"]+)",act:"([^"]+)"')
    found = re.search(pattern, data)
    if not found:
        # Код 2, а не строка-в-SystemExit (она даёт 1) -- круг 28, F-10.
        print(f'словарь вердиктов не извлечён из образа {path} для пробы "{probe}"; '
              'зашитый словарь не подставляется — расхождение с образом даёт неверную разметку',
              file=sys.stderr)
        raise SystemExit(2)
    result = (found.group(1).decode().split('|'), found.group(2).decode().split('|'))
    _VOCAB_CACHE[key] = result
    return result


class _VerdictPattern:
    # Lazy construction: the dictionary is taken from the image on the very
    # first lookup, not at import time — otherwise any import of replay would
    # require the image to be present.
    def findall(self, text):
        return verdict_pattern().findall(text)


VERDICT = _VerdictPattern()


def verdict_pattern(probe='judge'):
    rx, _ = verdict_vocabulary(probe=probe)
    # re.I -- потому что образ компилирует свой словарь с "gmi" (act -- с "mi").
    # Без флага живой судья принимал `ok: причина`, а реплика той же записи
    # объявляла «вердикта нет»: метрика расхождения показывала разницу, которой
    # в образе не было (круг 20, D-4).
    return re.compile(r'^\s*(?:' + '|'.join(re.escape(v) for v in rx) + r'):.*$',
                      re.M | re.I)


def load(path):
    op = gzip.open if path.endswith('.gz') else open
    with op(path, 'rt', encoding='utf-8') as fh:
        return json.load(fh)


def _verdict_in_text(text, probe='judge'):
    # Нет строки вердикта -- НЕТ вердикта, как и в образе (`return ""`). Прежде
    # возвращался весь текст, и потребитель, сравнивающий вердикт записи с
    # вердиктом реплики, сравнивал несравнимое (круг 20, D-4).
    matches = verdict_pattern(probe).findall(str(text or ''))
    return (matches[0] if matches else '').strip()


def verdict_of(raw, probe='judge'):
    """The first line of content/result is the decision; without content the
    last verdict line from reasoning is taken, so an intermediate variant does
    not override the conclusion."""
    try:
        data = json.loads(raw)
    except Exception:
        return _verdict_in_text(raw, probe)
    if isinstance(data, dict) and 'result' in data:
        return _verdict_in_text(data.get('result'), probe)
    message = ((data.get('choices') or [{}])[0].get('message') or {}) \
        if isinstance(data, dict) else {}
    content = message.get('content')
    if isinstance(content, list):
        content = ''.join(
            item.get('text', '') for item in content
            if isinstance(item, dict) and isinstance(item.get('text'), str))
    pattern = verdict_pattern(probe)
    matches = pattern.findall(str(content or ''))
    if matches:
        return matches[0].strip()
    reasoning = '\n'.join(
        value for value in (message.get('reasoning'), message.get('reasoning_content')) if value)
    matches = pattern.findall(reasoning)
    # Ни в содержимом, ни в рассуждении строки вердикта нет -- вердикта нет.
    # Возврат сырого содержимого расходился с образом (круг 20, D-4).
    return (matches[-1] if matches else '').strip()


# The channel rejects the urllib User-Agent with a perimeter stub; an external
# replay must identify itself with the same recognizable agent as the client.
UA = 'claude-cli/2.1.237 (external, cli)'

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import channel

DEFAULT_BASE_URL = 'http://127.0.0.1:8317'


def _message_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return ''.join(
            item.get('text', '') for item in value
            if isinstance(item, dict) and isinstance(item.get('text'), str))
    return str(value or '')


def request_texts(request):
    systems = []
    users = []
    for message in request.get('messages') or []:
        role = message.get('role')
        if role == 'system':
            systems.append(_message_text(message.get('content')))
        elif role == 'user':
            users.append(_message_text(message.get('content')))
    return '\n\n'.join(systems), '\n\n'.join(users)


def normalize_url(value):
    value = value.rstrip('/')
    if value.endswith('/v1/chat/completions'):
        return value
    if value.endswith('/v1'):
        return value + '/chat/completions'
    return value + '/v1/chat/completions'


def resolve_url(cli_url, record):
    if cli_url:
        return normalize_url(cli_url)
    recorded = str(record.get('url') or '')
    if recorded.startswith(('http://', 'https://')):
        return normalize_url(recorded)
    configured = os.environ.get('ANTHROPIC_BASE_URL') or DEFAULT_BASE_URL
    return normalize_url(configured)


def replay(rec, args):
    body = dict(rec['request'])
    model = args.model or str(body.get('model') or rec.get('model') or '')
    effort = args.effort or body.get('effort') or body.get('reasoning_effort')
    system, user = request_texts(body)
    if args.prompt:
        with open(args.prompt, encoding='utf-8') as fh:
            system = fh.read()
    sent = channel.send(
        system, user, model,
        effort=effort,
        max_tokens=body.get('max_tokens'),
        channel=args.channel,
        url=resolve_url(args.url, rec),
        timeout=args.timeout,
        body_template=body,
    )
    return sent, verdict_of(sent['raw'], args.probe) if not sent['error'] else ''


def klass(verdict, probe='judge'):
    rx, _ = verdict_vocabulary(probe=probe)
    # Двоеточие ОБЯЗАТЕЛЬНО и регистр не важен -- ровно как в образе. Без
    # двоеточия «OKAY, данных не хватает» классифицировалось как OK; без
    # регистра `ok:` не классифицировалось вовсе (круг 20, D-4). Возвращается
    # КАНОНИЧЕСКОЕ написание словаря: потребители сравнивают с ним литералами.
    match = re.match(r'\s*(' + '|'.join(re.escape(v) for v in rx) + r')\s*:',
                     verdict or '', re.I)
    if not match:
        return 'EMPTY'
    seen = match.group(1).lower()
    return next((v for v in rx if v.lower() == seen), match.group(1))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('target')
    parser.add_argument('--model')
    parser.add_argument('--prompt')
    parser.add_argument('--url')
    parser.add_argument('--effort', default='high')
    parser.add_argument('--channel', choices=('pool', 'http', 'auto'), default='auto')
    parser.add_argument('--limit', type=nonneg_int, default=0)
    parser.add_argument('--timeout', type=float, default=120)
    # Идентичность пробы протянута до конца: словарь вердиктов у каждой пробы
    # СВОЙ, а разбор шёл судейским независимо от того, чьи это записи -- записи
    # наблюдателя размечались чужим словарём (круг 20, D-5).
    parser.add_argument('--probe', default='judge', help='идентификатор пробы')
    args = parser.parse_args()

    # Два ЯВНЫХ глоба, а не *.json*: соседний compact.py пишет архивы под
    # временным именем <rec>.json.gz.tmp.<pid>, глоб *.json* совпадает с ним,
    # а load() выбирает gzip-поток по endswith('.gz') — путь с pid-суффиксом
    # кончается не на .gz, gzip-байты читаются текстом, и весь прогон падает
    # на первом же файле (sorted ставит tmp-имя в начало). Так же уже делают
    # adjudicate.py и validate.py.
    files = sorted(glob.glob(os.path.join(args.target, '*.json')) +
                   glob.glob(os.path.join(args.target, '*.json.gz'))) \
        if os.path.isdir(args.target) else [args.target]
    if args.limit:
        files = files[-args.limit:]

    same = diff = failed = 0
    for path in files:
        record = load(path)
        was = record.get('verdict') or ''
        sent, now = replay(record, args)
        if sent['error']:
            failed += 1
            print(f'{os.path.basename(path)}  ОШИБКА ПОВТОРА: {sent["error"]}  via={sent["via"]}')
            continue
        changed = klass(was, args.probe) != klass(now, args.probe)
        same, diff = (same, diff + 1) if changed else (same + 1, diff)
        print(f'{os.path.basename(path)}  {klass(was, args.probe)} -> '
              f'{klass(now, args.probe)}  via={sent["via"]}'
              f'{"  ИЗМЕНИЛОСЬ" if changed else ""}')
        if changed or len(files) == 1:
            print(f'   было:  {was[:300]}')
            print(f'   стало: {now[:300]}')
    if len(files) > 1:
        print(f'\nитого: {len(files)} записей, класс совпал {same}, '
              f'изменился {diff}, не прогналось {failed}')


if __name__ == '__main__':
    main()
