#!/usr/bin/env python3
import copy
import json
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def _text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, dict) and isinstance(item.get('text'), str):
                parts.append(item['text'])
        return ''.join(parts)
    return ''


def _openai_text(data):
    choice = (data.get('choices') or [{}])[0]
    message = choice.get('message') or {}
    return _text_content(message.get('content'))


def _http_usage(data):
    usage = data.get('usage') or {}
    tokens_in = usage.get('prompt_tokens', usage.get('input_tokens'))
    tokens_out = usage.get('completion_tokens', usage.get('output_tokens'))
    return tokens_in, tokens_out


def _pool_usage(data):
    usage = data.get('modelUsage') or {}
    entries = usage.values() if isinstance(usage, dict) else []
    entries = [item for item in entries if isinstance(item, dict)]
    tokens_in = sum(item.get('inputTokens') or 0 for item in entries) if entries else None
    tokens_out = sum(item.get('outputTokens') or 0 for item in entries) if entries else None
    return tokens_in, tokens_out


def _result(via, started, *, text='', http=None, raw='', error=None,
            tokens_in=None, tokens_out=None, cost_usd=None, notes=()):
    return {
        'text': text,
        'via': via,
        'ms': round((time.perf_counter() - started) * 1000),
        'http': http,
        'raw': raw,
        'error': error,
        'tokens_in': tokens_in,
        'tokens_out': tokens_out,
        'cost_usd': cost_usd,
        # Всё, чего полоса не смогла выполнить из запрошенного. Молча ронять
        # часть запроса нельзя: расхождение реплики с живым прогоном потом
        # списывают на модель или промт (круг 20, D-10).
        'notes': list(notes),
    }


def _send_http(system, user, model, effort, max_tokens, url, timeout, body_template):
    started = time.perf_counter()
    if not url:
        return _result('http', started, error='для канала http не задан url')
    body = copy.deepcopy(body_template) if isinstance(body_template, dict) else {}
    body['model'] = model
    body['messages'] = [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
    ]
    if max_tokens is None:
        body.pop('max_tokens', None)
    else:
        body['max_tokens'] = max_tokens
    if effort is None:
        body.pop('reasoning_effort', None)
        body.pop('effort', None)
    else:
        body['reasoning_effort'] = effort
        body.pop('effort', None)
    try:
        import replay
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode(),
            headers={'content-type': 'application/json', 'user-agent': replay.UA},
            method='POST',
        )
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode('utf-8', 'replace')
            http = response.status
        data = json.loads(raw)
        text = _openai_text(data)
        tokens_in, tokens_out = _http_usage(data)
        return _result('http', started, text=text, http=http, raw=raw,
                       tokens_in=tokens_in, tokens_out=tokens_out)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode('utf-8', 'replace')
        return _result('http', started, http=exc.code, raw=raw, error=str(exc))
    except Exception as exc:
        return _result('http', started, error=str(exc))


def _send_pool(system, user, model, effort, timeout, max_tokens=None):
    started = time.perf_counter()
    # У клиента нет ручки потолка вывода (в его `--help` только `--max-budget-usd`
    # и `--autocompact`), поэтому записанный бюджет на этой полосе НЕ
    # применяется. Это объявляется, а не замалчивается: реплика без потолка
    # отвечает полностью там, где живой прогон был обрезан.
    notes = ([] if max_tokens in (None, '') else
             [f'бюджет max_tokens={max_tokens} не применён: полоса pool не несёт потолок вывода'])
    workdir = tempfile.mkdtemp()
    command = [
        'claude', '-p', user, '--model', model,
        '--system-prompt', system, '--tools', '',
        '--no-session-persistence', '--output-format', 'json',
    ]
    if effort:
        command.extend(['--effort', effort])
    try:
        completed = subprocess.run(
            command, cwd=workdir, capture_output=True, text=True, timeout=timeout)
        raw = completed.stdout
        if completed.returncode:
            detail = completed.stderr.strip() or raw.strip() or f'exit {completed.returncode}'
            return _result('pool', started, raw=raw, error=detail, notes=notes)
        try:
            data = json.loads(raw)
        except Exception as exc:
            return _result('pool', started, raw=raw, error=f'не разобран JSON: {exc}', notes=notes)
        text = str(data.get('result') or '')
        if data.get('is_error'):
            return _result('pool', started, raw=raw, error=text or 'клиент вернул is_error', notes=notes)
        tokens_in, tokens_out = _pool_usage(data)
        cost = data.get('total_cost_usd')
        return _result('pool', started, text=text, raw=raw,
                       tokens_in=tokens_in, tokens_out=tokens_out, cost_usd=cost,
                       notes=notes)
    except subprocess.TimeoutExpired as exc:
        raw = exc.stdout or ''
        if isinstance(raw, bytes):
            raw = raw.decode('utf-8', 'replace')
        return _result('pool', started, raw=raw, error=f'таймаут через {timeout} с', notes=notes)
    except Exception as exc:
        return _result('pool', started, error=str(exc), notes=notes)
    finally:
        shutil.rmtree(workdir)


def send(system: str, user: str, model: str, *, effort: str | None,
         max_tokens: int | None, channel: str, url: str | None,
         timeout: float, body_template: dict | None) -> dict:
    chosen = channel.lower()
    if chosen == 'auto':
        chosen = 'pool' if model.lower().startswith('claude') else 'http'
    if chosen == 'pool':
        return _send_pool(system, user, model, effort, timeout, max_tokens)
    if chosen == 'http':
        return _send_http(system, user, model, effort, max_tokens, url, timeout, body_template)
    started = time.perf_counter()
    return _result(chosen, started, error=f'неизвестный канал: {channel}')
