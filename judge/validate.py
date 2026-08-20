#!/usr/bin/env python3
import argparse
import concurrent.futures
import copy
import datetime
import glob
import json
import math
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import channel
import replay

DEFAULT_RECORDS = os.path.join(HERE, 'records')
CONFIG_PATH = os.path.join(HERE, 'config.json')
PROMPT_PATH = os.path.join(HERE, 'prompt.md')
LABELS_PATH = os.path.join(HERE, 'labels.jsonl')
COSTS_PATH = os.path.expanduser('~/.claude.json')
DEFAULT_BASE_URL = 'http://127.0.0.1:8317'


def read_json(path, default=None):
    try:
        with open(path, encoding='utf-8') as fh:
            return json.load(fh)
    except FileNotFoundError:
        return default


def read_text(path):
    with open(path, encoding='utf-8') as fh:
        return fh.read()


def record_files(directory, limit=0):
    files = sorted(glob.glob(os.path.join(os.path.expanduser(directory), '*.json')) +
                   glob.glob(os.path.join(os.path.expanduser(directory), '*.json.gz')))
    return files[-limit:] if limit else files


def labels_by_record():
    labels = {}
    try:
        with open(LABELS_PATH, encoding='utf-8') as fh:
            for line in fh:
                if not line.strip():
                    continue
                item = json.loads(line)
                rec = item.get('rec')
                if not rec:
                    continue
                source = item.get('source') or 'human'
                kind = 'human' if source == 'human' else 'model'
                labels.setdefault(rec, {})[kind] = item
    except FileNotFoundError:
        pass
    return labels


def parse_model(value, default_effort='high'):
    value = value.strip()
    if not value:
        raise ValueError('пустая модель')
    model, sep, effort = value.rpartition(':')
    return (model, effort) if sep and model and effort else (value, default_effort)


def configured_models(config):
    result = []
    for item in config.get('models') or []:
        if isinstance(item, str):
            result.append(parse_model(item))
        elif isinstance(item, dict) and item.get('model'):
            result.append((str(item['model']), str(item.get('effort') or 'high')))
    if not result:
        raise ValueError('модели не заданы ни в --models, ни в config.json')
    return result


def models_from_args(value, config):
    if value:
        return [parse_model(item) for item in value.split(',') if item.strip()]
    return configured_models(config)


def normalize_url(value):
    value = value.rstrip('/')
    if value.endswith('/v1/chat/completions'):
        return value
    if value.endswith('/v1'):
        return value + '/chat/completions'
    return value + '/v1/chat/completions'


def resolve_url(cli_url, record, config):
    candidates = (
        ('cli', cli_url),
        ('record', record.get('url')),
        ('config', config.get('url')),
        ('env', os.environ.get('ANTHROPIC_BASE_URL')),
        ('default', DEFAULT_BASE_URL),
    )
    for source, value in candidates:
        if value and str(value).startswith(('http://', 'https://')):
            return normalize_url(str(value)), source
    raise RuntimeError('адрес канала не найден')


def replace_system_message(body, prompt):
    messages = []
    found = False
    for message in body.get('messages') or []:
        if message.get('role') == 'system':
            messages.append(dict(message, content=prompt))
            found = True
        else:
            messages.append(message)
    if not found:
        messages.insert(0, {'role': 'system', 'content': prompt})
    body['messages'] = messages


def apply_context_limit(body, context_chars):
    if context_chars is None:
        return
    limit = int(context_chars)
    if limit < 0:
        raise ValueError('context_chars не может быть отрицательным')
    body['messages'] = [
        dict(message, content=str(message.get('content') or '')[-limit:])
        if message.get('role') == 'user' and len(str(message.get('content') or '')) > limit
        else message
        for message in body.get('messages') or []
    ]


def compose_body(record, model, effort, args, global_config):
    body = copy.deepcopy(record['request'])
    body['model'] = model
    body['reasoning_effort'] = effort
    layer_missing = False

    if args.project_layer == 'off':
        replace_system_message(body, read_text(os.path.expanduser(args.prompt)))
    elif args.project_layer == 'recompose':
        prompt = read_text(os.path.expanduser(args.prompt)) if args.prompt else read_text(PROMPT_PATH)
        max_tokens = global_config.get('max_tokens')
        context_chars = global_config.get('context_chars')
        cfg = record.get('cfg')
        if cfg:
            cfg = os.path.expanduser(cfg)
            if not os.path.isdir(cfg):
                layer_missing = True
            else:
                project_prompt = os.path.join(cfg, 'prompt.md')
                if os.path.isfile(project_prompt):
                    prompt = read_text(project_prompt)
                extra_prompt = os.path.join(cfg, 'prompt.extra.md')
                if os.path.isfile(extra_prompt):
                    extra = read_text(extra_prompt)
                    if extra.strip():
                        prompt += '\n\n=== ПРАВИЛА ЭТОГО ПРОЕКТА ===\n' + extra
                project_config = read_json(os.path.join(cfg, 'config.json'), {}) or {}
                if 'max_tokens' in project_config:
                    max_tokens = project_config['max_tokens']
                if 'context_chars' in project_config:
                    context_chars = project_config['context_chars']
        replace_system_message(body, prompt)
        if max_tokens is not None:
            body['max_tokens'] = max_tokens
        apply_context_limit(body, context_chars)

    return body, layer_missing


def run_one(task):
    index, path, record, model, effort, rep, args, config, truths = task
    url, url_from = resolve_url(args.url, record, config)
    layer_missing = False
    try:
        body, layer_missing = compose_body(record, model, effort, args, config)
        system, user = replay.request_texts(body)
        sent = channel.send(
            system, user, model,
            effort=effort,
            max_tokens=body.get('max_tokens'),
            channel=args.channel,
            url=url,
            timeout=args.timeout,
            body_template=body,
        )
        verdict = replay.verdict_of(sent['raw']) if not sent['error'] else ''
        result_class = replay.klass(verdict) if not sent['error'] else 'ERROR'
    except Exception as exc:
        sent = {
            'via': args.channel, 'ms': 0, 'http': None, 'error': str(exc),
            'tokens_in': None, 'tokens_out': None, 'cost_usd': None,
        }
        verdict = ''
        result_class = 'ERROR'
    result = {
        'rec': os.path.basename(path),
        'model': model,
        'effort': effort,
        'rep': rep,
        'klass': result_class,
        'verdict': verdict,
        'via': sent['via'],
        'ms': sent['ms'],
        'http': sent['http'],
        'cost_usd': sent['cost_usd'],
        'error': sent['error'],
        'truth': truths.get('human'),
        'truth_human': truths.get('human'),
        'truth_model': truths.get('model'),
        'layer': args.project_layer,
        'cfg': record.get('cfg'),
        'tokens_in': sent['tokens_in'],
        'tokens_out': sent['tokens_out'],
        'layer_missing': layer_missing,
        'url_from': url_from,
    }
    return index, result


def effective_class(value):
    return 'BLOCK' if value in ('BLOCK', 'STOP', 'DENY') else value


def percentile_90(values):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.9) - 1)]


def model_costs():
    data = read_json(COSTS_PATH, {}) or {}
    costs = data.get('customModelCosts')
    return costs if isinstance(costs, dict) else {}


def price_100(rows, model, costs):
    direct = [row.get('cost_usd') for row in rows if isinstance(row.get('cost_usd'), (int, float))]
    if direct:
        return 100 * sum(direct) / len(direct)
    pricing = costs.get(model)
    pairs = [(row.get('tokens_in'), row.get('tokens_out')) for row in rows]
    pairs = [(i, o) for i, o in pairs if isinstance(i, (int, float)) and isinstance(o, (int, float))]
    if not isinstance(pricing, dict) or not pairs:
        return None
    input_rate = pricing.get('inputTokens')
    output_rate = pricing.get('outputTokens')
    if not isinstance(input_rate, (int, float)) or not isinstance(output_rate, (int, float)):
        return None
    average_in = sum(item[0] for item in pairs) / len(pairs)
    average_out = sum(item[1] for item in pairs) / len(pairs)
    return 100 * (average_in * input_rate + average_out * output_rate) / 1_000_000


def recorded_classes_for(rows):
    wanted = {row['rec'] for row in rows}
    result = {}
    for path in record_files(DEFAULT_RECORDS):
        name = os.path.basename(path)
        if name in wanted:
            result[name] = replay.klass((replay.load(path).get('verdict') or ''))
    return result


def row_truth(row, kind):
    if kind == 'human':
        return row.get('truth_human', row.get('truth'))
    return row.get('truth_model')


def accuracy_text(rows, kind):
    labelled = [row for row in rows if row_truth(row, kind)]
    matched = sum(effective_class(row.get('klass')) == row_truth(row, kind) for row in labelled)
    return f'{matched}/{len(labelled)}' if labelled else '—'


def print_summary(rows, model_order=None, recorded_classes=None):
    if not rows:
        print('нет результатов')
        return
    recorded_classes = recorded_classes or recorded_classes_for(rows)
    order = model_order or []
    seen = []
    for row in rows:
        if row['model'] not in seen:
            seen.append(row['model'])
    models = [model for model in order if model in seen] + [model for model in seen if model not in order]
    costs = model_costs()
    human_records = {row['rec'] for row in rows if row_truth(row, 'human')}
    model_records = {row['rec'] for row in rows if row_truth(row, 'model')}
    heading = ('модель\tканал\tпрогонов\tошибок\tEMPTY\tмедиана_мс\tp90_мс\tток_вх/вых\t'
               'пропусков\tложных_отмен\tпо_человеческим\tпо_предложенным_моделью\t'
               'с_записанным\tнестабильных\tцена_100')
    print(heading)
    stats = {}
    for model in models:
        selected = [row for row in rows if row['model'] == model]
        latencies = [row['ms'] for row in selected if isinstance(row.get('ms'), (int, float))]
        errors = sum(row.get('klass') == 'ERROR' for row in selected)
        empty = sum(row.get('klass') == 'EMPTY' for row in selected)
        misses = sum(row_truth(row, 'human') == 'BLOCK' and effective_class(row.get('klass')) != 'BLOCK'
                     for row in selected)
        false_blocks = sum(row_truth(row, 'human') == 'OK' and effective_class(row.get('klass')) == 'BLOCK'
                           for row in selected)
        comparable = [row for row in selected if row['rec'] in recorded_classes]
        recorded_match = sum(row.get('klass') == recorded_classes[row['rec']] for row in comparable)
        repeats = {}
        for row in selected:
            repeats.setdefault(row['rec'], set()).add(row.get('klass'))
        unstable = sum(len(classes) > 1 for classes in repeats.values())
        known_in = [row.get('tokens_in') for row in selected if isinstance(row.get('tokens_in'), (int, float))]
        known_out = [row.get('tokens_out') for row in selected if isinstance(row.get('tokens_out'), (int, float))]
        token_text = f'{sum(known_in)}/{sum(known_out)}' if known_in or known_out else '—'
        price = price_100(selected, model, costs)
        price_text = f'${price:.6f}' if price is not None else '—'
        median = statistics.median(latencies) if latencies else None
        p90 = percentile_90(latencies)
        via_counts = {}
        for row in selected:
            via_counts[row.get('via') or '—'] = via_counts.get(row.get('via') or '—', 0) + 1
        via_text = ','.join(f'{name}:{count}' for name, count in sorted(via_counts.items()))
        print(f'{model}\t{via_text}\t{len(selected)}\t{errors}\t{empty}\t'
              f'{median if median is not None else "—"}\t{p90 if p90 is not None else "—"}\t'
              f'{token_text}\t{misses}\t{false_blocks}\t{accuracy_text(selected, "human")}\t'
              f'{accuracy_text(selected, "model")}\t{recorded_match}/{len(comparable)}*\t'
              f'{unstable}\t{price_text}')
        stats[model] = {'misses': misses, 'unstable': unstable, 'median': median}
    print(f'меток: человеческих {len(human_records)}, предложенных моделью {len(model_records)}')
    print('* согласие с записанным вердиктом; записанный вердикт истиной не является')
    pool_runs = sum(row.get('via') == 'pool' for row in rows)
    print(f'канал pool: {pool_runs} прогонов; вход не совпадает с исходным из-за контекста старта сессии')

    distinct = {}
    for row in rows:
        distinct.setdefault(row['rec'], row.get('url_from'))
    foreign = {rec: source for rec, source in distinct.items() if source != 'record'}
    sources = {}
    for source in foreign.values():
        sources[source] = sources.get(source, 0) + 1
    source_text = ', '.join(f'{source} {count}' for source, count in sources.items()) or '—'
    print(f'адрес не из записи: {len(foreign)} из {len(distinct)} ({source_text})')

    criterion = 'критерий: 0 пропусков и 0 нестабильных; порядок кандидатов из --models'
    if not human_records:
        print(f'минимальная годная не определена: нет человеческих меток ({criterion})')
        return
    passing = [model for model in models if stats[model]['misses'] == 0 and stats[model]['unstable'] == 0]
    if not passing:
        rejected = ', '.join(
            f'{model} — пропусков {stats[model]["misses"]}, нестабильных {stats[model]["unstable"]}'
            for model in models)
        print(f'минимальная годная: нет ({criterion}); отвергнуты: {rejected}')
        return
    chosen = passing[0]
    median_seconds = stats[chosen]['median'] / 1000 if stats[chosen]['median'] is not None else 0
    rejected = []
    for model in models:
        if model == chosen:
            continue
        if model in passing:
            rejected.append(f'{model} — также проходит, но позже в порядке кандидатов')
        else:
            rejected.append(f'{model} — пропусков {stats[model]["misses"]}, '
                            f'нестабильных {stats[model]["unstable"]}')
    suffix = f'; остальные: {", ".join(rejected)}' if rejected else ''
    print(f'минимальная годная: {chosen} (пропусков 0, нестабильных 0, '
          f'медиана {median_seconds:.1f} с; {criterion}){suffix}')


def command_list(args):
    labels = labels_by_record()
    print('запись\tзаписанный\tчеловеческая\tпредложенная_моделью')
    for path in record_files(args.records):
        name = os.path.basename(path)
        pair = labels.get(name) or {}
        if args.unlabelled and pair:
            continue
        recorded = replay.klass(replay.load(path).get('verdict') or '')
        human = (pair.get('human') or {}).get('truth') or 'нет метки'
        model = (pair.get('model') or {}).get('truth') or 'нет метки'
        print(f'{name}\t{recorded}\t{human}\t{model}')


def resolve_record_name(value):
    expanded = os.path.expanduser(value)
    if os.path.isfile(expanded):
        return os.path.basename(expanded)
    names = [os.path.basename(path) for path in record_files(DEFAULT_RECORDS)]
    if value in names:
        return value
    matches = [name for name in names if name.removesuffix('.gz').removesuffix('.json') == value]
    if len(matches) == 1:
        return matches[0]
    raise FileNotFoundError(f'запись не найдена: {value}')


def command_label(args):
    name = resolve_record_name(args.record)
    item = {
        'rec': name,
        'truth': args.truth,
        'note': args.note or '',
        't': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
    }
    with open(LABELS_PATH, 'a', encoding='utf-8') as fh:
        fh.write(json.dumps(item, ensure_ascii=False, separators=(',', ':')) + '\n')
    print(json.dumps(item, ensure_ascii=False))


def command_run(args):
    config = read_json(CONFIG_PATH, {}) or {}
    models = models_from_args(args.models, config)
    if args.project_layer == 'off' and not args.prompt:
        raise SystemExit('--prompt обязателен при --project-layer off')
    paths = record_files(args.records, args.limit)
    labels = labels_by_record()
    tasks = []
    index = 0
    recorded = {}
    for path in paths:
        record = replay.load(path)
        name = os.path.basename(path)
        recorded[name] = replay.klass(record.get('verdict') or '')
        pair = labels.get(name) or {}
        truths = {
            'human': (pair.get('human') or {}).get('truth'),
            'model': (pair.get('model') or {}).get('truth'),
        }
        for model, effort in models:
            for rep in range(1, args.repeat + 1):
                tasks.append((index, path, record, model, effort, rep, args, config, truths))
                index += 1
    if not tasks:
        raise SystemExit('записи для прогона не найдены')
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        completed = [future.result() for future in [executor.submit(run_one, task) for task in tasks]]
    rows = [result for _, result in sorted(completed)]
    out = os.path.expanduser(args.out) if args.out else default_output_path()
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as fh:
        for row in rows:
            line = json.dumps(row, ensure_ascii=False, separators=(',', ':'))
            fh.write(line + '\n')
            print(line)
    print(f'файл прогона: {out}')
    print_summary(rows, [model for model, _ in models], recorded)


def default_output_path():
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H-%M-%S-%fZ')
    return os.path.join(HERE, 'bench', stamp + '-run.jsonl')


def command_report(args):
    rows = []
    for path in args.files:
        with open(os.path.expanduser(path), encoding='utf-8') as fh:
            for line in fh:
                if line.strip():
                    rows.append(json.loads(line))
    print_summary(rows)


def build_parser():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)

    run = sub.add_parser('run')
    run.add_argument('--records', default=DEFAULT_RECORDS)
    run.add_argument('--models')
    run.add_argument('--repeat', type=int, default=1)
    run.add_argument('--limit', type=int, default=0)
    run.add_argument('--jobs', type=int, default=4)
    run.add_argument('--timeout', type=float, default=180)
    run.add_argument('--prompt')
    run.add_argument('--project-layer', choices=('record', 'recompose', 'off'), default='record')
    run.add_argument('--url')
    run.add_argument('--channel', choices=('pool', 'http', 'auto'), default='auto')
    run.add_argument('--out')
    run.set_defaults(func=command_run)

    label = sub.add_parser('label')
    label.add_argument('record')
    label.add_argument('--truth', choices=('OK', 'WARN', 'BLOCK'), required=True)
    label.add_argument('--note')
    label.set_defaults(func=command_label)

    listing = sub.add_parser('list')
    listing.add_argument('--records', default=DEFAULT_RECORDS)
    listing.add_argument('--unlabelled', action='store_true')
    listing.set_defaults(func=command_list)

    report = sub.add_parser('report')
    report.add_argument('files', nargs='+')
    report.set_defaults(func=command_report)
    return parser


def main():
    args = build_parser().parse_args()
    if getattr(args, 'repeat', 1) < 1:
        raise SystemExit('--repeat должен быть не меньше 1')
    if getattr(args, 'jobs', 1) < 1:
        raise SystemExit('--jobs должен быть не меньше 1')
    args.func(args)


if __name__ == '__main__':
    main()
