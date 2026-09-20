#!/usr/bin/env python3
"""Реплика разметки вердиктов живого судьи по записям проб.

Коды выхода (подмножество общей таблицы кита -- шапка claude-patch-all.sh):
  0  разметка завершена
  2  прибор не может мерить: ДОМ словарей (hooks/register.ts мода
     catalyst-probes) не найден ни в одной из ДВУХ раскладок -- раскатка,
     названная реестром исполняемого, и соседний register.ts в доме
     инструментов (см. default_source) -- либо найден и не прочитан,
     словарь пробы в нём не объявлен, либо дом РАЗОШЁЛСЯ с каноном мода в
     дереве семьи (зашитый словарь не подставляется: расхождение с тем, что
     исполняется, даёт неверную разметку). Круг 28, F-10: прежде эти выходы
     отдавались кодом 1 через sys.exit('строка') -- «отказ по существу»,
     хотя по существу здесь отказываться не о чем, чинить надо вход.
     Волна 40b: ОТСУТСТВИЕ канона кодом 2 больше не является -- сверка с
     ним объявляется пропущенной в stderr, а словарь берётся из дома.
"""
import argparse
import glob
import gzip
import json
import math
import os
import re
import sys

# Дом словаря вердиктов -- РАСКАТАННЫЙ экземпляр мода catalyst-probes:
# реестр исполняемого называет запись "catalyst-probes@catalyst", словарь --
# hooks/register.ts внутри её installPath. КАНОН мода живёт в дереве семьи
# (тот же способ хода к нему, что у scripts/claude-mods.sh: $KIT/../Catalyst)
# и дом сверяется с ним. Путь считается от __file__, а не от cwd:
# инструменты зовут из любого каталога.
TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
KIT_ROOT = os.path.dirname(TOOLS_DIR)
FAMILY_ROOT = os.path.dirname(KIT_ROOT)
# Запасная раскладка -- соседний register.ts в доме инструментов
# (scripts/probes-sync.sh кладёт его в $TOOLS_HOME): раскатанный контур
# обязан работать без дерева семьи. Глоб по каталогам кэша плагинов
# ЗАПРЕЩЁН: версий там десятки, и лексикографический максимум не есть
# исполняемая (#334) -- реестр единственный называет работающее.
NEIGHBOUR_SOURCE = os.path.join(TOOLS_DIR, 'register.ts')
# Ручка источника переименована по новому дому; прежнее имя читается как
# запасное -- рабочий обход живого контура не должен умирать молча.
SOURCE_ENV = 'CLAUDE_JUDGE_VOCAB_SRC'
SOURCE_ENV_LEGACY = 'CLAUDE_JUDGE_PATCH_SRC'
# Единственный дом умолчания образа на весь контур: adjudicate.py берёт его
# здесь (своей копии у него быть не должно -- три копии одной константы
# расходятся молча). Сверка с образом снята вместе с предметом, но константа
# остаётся контрактом CLI соседа.
DEFAULT_IMAGE = '~/.local/bin/claude'
# Реестр и канон вынесены в ручки для герметичности стенда: копия дерева
# кита не должна мерить живую установку мода.
REGISTRY_ENV = 'CLAUDE_JUDGE_MOD_REGISTRY'
DEFAULT_REGISTRY = '~/.claude/plugins/installed_plugins.json'
PROBES_PLUGIN_KEY = 'catalyst-probes@catalyst'
MOD_CANON_ENV = 'CLAUDE_JUDGE_MOD_CANON'
MOD_CANON = os.path.join(FAMILY_ROOT, 'Catalyst', 'plugins',
                         'catalyst-probes', 'hooks', 'register.ts')
# Признак НОСИТЕЛЯ МОДА -- замена CARRIER_MARK в роли часового сверки
# (метка образа globalThis.__ccProbe умерла вместе с образом: на 2.1.278
# бинарь проб не несёт). Файл без признака -- не наш мод (чужой либо
# оборванный), и сверять его с домом нечем; НАШ мод без дома словаря --
# расхождение, а не «нечего сверять». Признак обязан стоять в ЛЮБОЙ версии
# мода, не только после появления самого дома, -- иначе мод до волны
# читался бы «чужим файлом».
MOD_CARRIER_MARK = b'export const MOD_VERSION'
# Ключ кэша -- ПАРА (дом, проба): под ключом без дома два разных дома
# отдавали бы один словарь.
_VOCAB_CACHE = {}


def _registry_paths():
    """installPath-ы записей мода из реестра исполняемого либо (None, причина)."""
    path = os.path.realpath(os.path.expanduser(
        os.environ.get(REGISTRY_ENV) or DEFAULT_REGISTRY))
    try:
        with open(path, encoding='utf-8') as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return None, f'реестра исполняемого нет по пути {path}'
    except (OSError, ValueError) as err:
        return None, (f'реестр исполняемого не прочитан: {path} '
                      f'({err.__class__.__name__})')
    plugins = data.get('plugins') if isinstance(data, dict) else None
    records = plugins.get(PROBES_PLUGIN_KEY) if isinstance(plugins, dict) else None
    if not isinstance(records, list) or not records:
        return None, (f'в реестре исполняемого {path} нет записей '
                      f'"{PROBES_PLUGIN_KEY}"')
    paths = [rec.get('installPath') for rec in records
             if isinstance(rec, dict) and rec.get('installPath')]
    if not paths:
        return None, (f'записи "{PROBES_PLUGIN_KEY}" в {path} не несут installPath')
    return paths, None


def deployed_source():
    """(раскатка|None, отказ|None, причина_реестра|None) по реестру исполняемого.

    Берётся ПЕРВАЯ запись, чей installPath существует на диске: записей
    может быть несколько (разный scope). Отказ непуст только когда реестр
    НАЗВАЛ раскладки, которых на диске нет, -- это отказ прибора с названной
    причиной, а не повод молча мерить соседнюю раскладку.
    """
    paths, why = _registry_paths()
    if paths is None:
        return None, None, why
    named = [os.path.join(os.path.expanduser(p), 'hooks', 'register.ts')
             for p in paths]
    for cand in named:
        if os.path.exists(cand):
            return cand, None, why
    return None, ('реестр исполняемого называет раскатки мода, которых нет '
                  'на диске: ' + ', '.join(named)), why


def default_source():
    """(Первый СУЩЕСТВУЮЩИЙ кандидат раскладки, отказ реестра|None).

    Кандидаты: раскатка, названная реестром исполняемого, затем соседний
    register.ts в доме инструментов. None, а не первый кандидат: звонящий
    обязан назвать в отказе ВСЕ кандидаты -- иначе починка выглядит как
    «не тот путь» вместо «файла нет ни в одной раскладке». Отказ реестра
    (раскладки названы, но их нет на диске) поднимается звонящим кодом 2 и
    откатом к соседу НЕ гасится.
    """
    deployed, refusal, _why = deployed_source()
    if deployed is not None:
        return deployed, refusal
    if refusal is not None:
        return None, refusal
    if os.path.exists(NEIGHBOUR_SOURCE):
        return NEIGHBOUR_SOURCE, None
    return None, None


def default_source_candidates():
    """Обе раскладки словами -- для отказа «ни в одной раскладке»."""
    deployed, refusal, why = deployed_source()
    first = deployed if deployed is not None else (
        'раскатка мода по реестру (' + (refusal or why) + ')')
    return [first, 'соседний ' + NEIGHBOUR_SOURCE]


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


def _scan_image(data, probe):
    """(rx, act) из БАЙТОВ собранного образа либо None, если словаря там нет.

    От дескриптора пробы до её словаря -- сколько угодно полей, но НЕ через
    соседнюю пробу: `(?!dirName:")` запрещает пересечь границу, поэтому окно
    не приходится подгонять числом. Прежняя форма стояла на `{0,160}` и
    молча перестала находить словарь, когда в дескриптор добавили turn/
    selfId/turnLost (2026-08-29: расстояние стало ~250 знаков, инструмент
    отказал на ЖИВОМ образе -- «прибор не может мерить» вместо разметки).
    Запрет границы -- свойство ИМЕННО этого скана: в образе пробы стоят
    подряд одной строкой, и проба без своего словаря взяла бы соседний.
    `[^\n]` тоже свойство образа: он одна строка. У авторского исходника
    класс другой -- см. _scan_source.
    """
    pattern = (rb'dirName:"' + re.escape(probe.encode()) +
               rb'"(?:(?!dirName:")[^\n]){0,4000}?rx:"([^"]+)",act:"([^"]+)"')
    found = re.search(pattern, data)
    if not found:
        return None
    return (found.group(1).decode().split('|'), found.group(2).decode().split('|'))


def vocabulary_from_image(image_path, probe='judge'):
    """Словарь пробы из ПРОПАТЧЕННОГО образа либо None. OSError не ловится:
    решение о пропуске сверки принимает вызывающий, а не читатель байтов."""
    with open(image_path, 'rb') as fh:
        return _scan_image(fh.read(), probe)


def _scan_source(data, probe):
    """(emits, folds) из ИСХОДНИКА мода (hooks/register.ts) либо None.

    Форма дома -- записи { probe, emits, folds }: emits описывает поле
    `verdict` улики (ПРОПИСНЫЕ виды), folds -- класс свёртки для метрик
    прибора. Класс [\\s\\S]: TS-исходник многострочный. Запрет на
    пересечение границы соседней пробы сохранён и перепривязан на `probe:`
    -- записи дома идут подряд, и проба без своего словаря взяла бы
    соседний.
    """
    pattern = (rb'probe:\s*"' + re.escape(probe.encode()) +
               rb'"(?:(?!probe:\s*")[\s\S]){0,4000}?emits:\s*"([^"]+)",\s*folds:\s*"([^"]+)"')
    found = re.search(pattern, data)
    if not found:
        return None
    return (found.group(1).decode().split('|'), found.group(2).decode().split('|'))


def _cross_check_canon(home, source, probe):
    """Сверка дома с КАНОНОМ мода. Расхождение -- код 2; пропуск -- ОБЪЯВЛЕН.

    Пропуск без следа неотличим от сверки, которая прошла, поэтому у каждого
    исхода «сверять нечем» есть своя строка в stderr с названной причиной.
    """
    canon = os.path.realpath(os.path.expanduser(
        os.environ.get(MOD_CANON_ENV) or MOD_CANON))
    try:
        with open(canon, 'rb') as fh:
            data = fh.read()
    except OSError as err:
        print(f'сверка с каноном ПРОПУЩЕНА: канона нет по пути {canon} '
              f'({err.__class__.__name__})', file=sys.stderr)
        return
    if MOD_CARRIER_MARK not in data:
        print(f'сверка с каноном ПРОПУЩЕНА: {canon} не несёт признака мода '
              f'({MOD_CARRIER_MARK.decode()}) -- чужой файл либо оборванная '
              'копия', file=sys.stderr)
        return
    canon_home = _scan_source(data, probe)
    if canon_home is None:
        # Наш мод БЕЗ словаря пробы -- расхождение, а не «нечего сверять»:
        # признак мода говорит, что носитель наш, значит дом словаря в нём
        # обязан быть.
        print(f'дом и канон РАСХОДЯТСЯ по пробе "{probe}": дом {source} '
              f'объявляет emits="{"|".join(home[0])}",'
              f'folds="{"|".join(home[1])}"; канон {canon} -- наш мод, но '
              'словаря этой пробы в нём нет -- раскатка либо источник '
              'собраны не из этого дерева', file=sys.stderr)
        raise SystemExit(2)
    if canon_home != home:
        print(f'дом и канон РАСХОДЯТСЯ по пробе "{probe}": дом {source} -- '
              f'emits="{"|".join(home[0])}",folds="{"|".join(home[1])}"; '
              f'канон {canon} -- '
              f'emits="{"|".join(canon_home[0])}",'
              f'folds="{"|".join(canon_home[1])}" -- '
              'раскатка либо источник собраны не из этого дерева', file=sys.stderr)
        raise SystemExit(2)


def verdict_vocabulary(image_path=None, probe='judge', source_path=None):
    """Словарь пробы из ДОМА, сверенный с каноном, когда канон есть.

    Зашитый словарь не подставляется ни при каком исходе: расхождение с тем,
    что исполняется, даёт неверную разметку корпуса, на которую потом
    опирается выбор модели. image_path сохранён контрактом validate.py и
    adjudicate.py; сверка с образом снята вместе с предметом: на 2.1.278
    бинарь проб не несёт вовсе.
    """
    chosen = (source_path or os.environ.get(SOURCE_ENV)
              or os.environ.get(SOURCE_ENV_LEGACY))
    if chosen is None:
        chosen, registry_refusal = default_source()
        if registry_refusal is not None:
            # Реестр НАЗВАЛ раскатку, которой на диске нет: код 2 с названной
            # причиной, а не молчаливый откат к соседней раскладке.
            print('дом словарей вердиктов не найден: ' + registry_refusal,
                  file=sys.stderr)
            raise SystemExit(2)
    if chosen is None:
        # Код 2 -- прибор не может мерить. Названы ВСЕ кандидаты: раскладок
        # две, и «не тот путь» -- неверный диагноз.
        candidates = default_source_candidates()
        print('дом словарей вердиктов не найден ни в одной раскладке: '
              + ', '.join(candidates)
              + f'; раскатайте мод ({PROBES_PLUGIN_KEY}) либо положите '
                'hooks/register.ts рядом с judge-инструментами либо назовите '
                f'его путь в {SOURCE_ENV}', file=sys.stderr)
        raise SystemExit(2)
    source = os.path.realpath(os.path.expanduser(chosen))
    key = (source, probe)
    if key in _VOCAB_CACHE:
        return _VOCAB_CACHE[key]
    try:
        with open(source, 'rb') as fh:
            body = fh.read()
    except OSError as err:
        # Код 2, а не строка-в-SystemExit (она даёт 1): прибор не может
        # мерить -- круг 28, F-10. Ветка достижима ДВУМЯ путями: путь назван
        # явно (аргументом или ручкой) и нечитаем, ЛИБО кандидат раскладки
        # существовал на замере default_source() и исчез до открытия. В обоих
        # случаях дом НАЗВАН, поэтому совет «положите рядом» здесь неверен --
        # называть надо сам путь. Отсутствие обеих раскладок -- другая дверь,
        # выше по функции.
        print(f'дом словарей вердиктов не прочитан: {source} '
              f'({err.__class__.__name__}); проверьте этот путь либо назовите '
              f'другой в {SOURCE_ENV}', file=sys.stderr)
        raise SystemExit(2)
    home = _scan_source(body, probe)
    if home is None:
        # Код 2, а не строка-в-SystemExit (она даёт 1) -- круг 28, F-10.
        print(f'словарь вердиктов не объявлен в доме {source} для пробы "{probe}"; '
              'зашитый словарь не подставляется — расхождение с тем, что '
              'исполняется, даёт неверную разметку', file=sys.stderr)
        raise SystemExit(2)
    _cross_check_canon(home, source, probe)
    _VOCAB_CACHE[key] = home
    return home


class _VerdictPattern:
    # Lazy construction: the dictionary is taken from its home on the very
    # first lookup, not at import time — otherwise any import of replay would
    # require the home (and, with it, the cross-check) to be reachable.
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
