#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const START_MARKER = '/*__ccProbe0*/';
const END_MARKER = '/*__ccProbe1*/';
const ENV_KEYS = [
  'CLAUDE_JUDGE_DIR',
  'CLAUDE_JUDGE',
  'CLAUDE_JUDGE_URL',
  'CLAUDE_JUDGE_MODEL',
  'CLAUDE_JUDGE_PROMPT',
  'CLAUDE_JUDGE_DEBUG',
  'CLAUDE_IDLE',
  'CLAUDE_IDLE_DIR',
  'CLAUDE_IDLE_URL',
  'CLAUDE_IDLE_MODEL',
  'CLAUDE_IDLE_PROMPT',
  'CLAUDE_IDLE_TIMEOUT_MS',
  'CLAUDE_IDLE_DEBUG',
];

function failSetup(message) {
  console.error(`probe-bench: ${message}`);
  process.exitCode = 2;
}

function parseArgs(argv) {
  let binary = null;
  let json = null;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--binary' || argument === '--json') {
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) {
        throw new Error(`${argument} requires a path`);
      }
      if (argument === '--binary') binary = value;
      else json = value;
      index += 1;
    } else {
      throw new Error(`unknown argument: ${argument}`);
    }
  }

  if (!binary) throw new Error('usage: node tools/probe-bench.js --binary <path> [--json <file>]');
  return { binary, json };
}

function carveBlock(binaryPath) {
  const source = fs.readFileSync(binaryPath, 'latin1');
  const start = source.indexOf(START_MARKER);
  const end = start < 0 ? -1 : source.indexOf(END_MARKER, start + START_MARKER.length);

  if (start < 0) throw new Error(`marker not found: ${START_MARKER}`);
  if (end < 0) throw new Error(`marker not found: ${END_MARKER}`);
  return source.slice(start + START_MARKER.length, end);
}

function locateNames(carved) {
  const slots = /tool:([A-Za-z_$][\w$]*),input:([A-Za-z_$][\w$]*),ctx:([A-Za-z_$][\w$]*),key:([A-Za-z_$][\w$]*)/.exec(carved);
  if (!slots) throw new Error('free names not found: tool, input, context, key');
  const pool = /let __pool=typeof ([A-Za-z_$][\w$]*)==="function"/.exec(carved);
  if (!pool) throw new Error('free name not found: pool');
  // Форма реакции менялась (стала асинхронной) — локатор не должен падать на
  // том, что для него несущественно.
  const notify = /onAct:(?:async)?\(__r\)=>\{try\{([A-Za-z_$][\w$]*)\(\{value:"\[fleet-idle\] "/.exec(carved);
  if (!notify) throw new Error('free name not found: notify');
  const agent = /mode:"task-notification",agentId:([A-Za-z_$][\w$]*)\(\)/.exec(carved);
  if (!agent) throw new Error('free name not found: agentId');
  return [slots[1], slots[2], slots[3], slots[4], pool[1], notify[1], agent[1]];
}

function compileProbe(carved, names) {
  try {
    return new Function(
      ...names,
      '"use strict";return (async()=>{' + carved + '})()',
    );
  } catch (error) {
    throw new Error(`cannot compile carved block: ${error.message}`);
  }
}

function baseConfig(scenario) {
  if (scenario.probe === 'watch') {
    return {
      enforce: true,
      fail_closed: false,
      models: [{ model: 'stub-model' }],
      max_tokens: 8000,
      window_min: 30,
      threshold: 1,
      cooldown_min: 30,
    };
  }
  return { enforce: true, fail_closed: true, models: [{ model: 'stub-model' }], max_tokens: 8000 };
}

const OLD = () => ({ last: 0, start: Date.now() - 3600000 });

const scenarios = [
  {
    name: 'ok',
    response: 'OK: бриф полон',
    expected: { passed: true, outcome: 'ok' },
  },
  {
    name: 'warn',
    response: 'WARN: моделька дороговата',
    expected: { passed: true, outcome: 'warn' },
  },
  {
    name: 'block',
    response: 'BLOCK: бриф не готов, добавь пути',
    expected: { passed: false, outcome: 'block', errorIncludes: 'бриф не готов' },
  },
  {
    name: 'no-verdict-failclosed',
    response: 'просто рассуждение без вердикта',
    expected: { passed: false, outcome: 'block_no_verdict' },
  },
  {
    name: 'no-verdict-failopen',
    response: 'просто рассуждение без вердикта',
    config: { fail_closed: false },
    expected: { passed: true },
  },
  {
    name: 'broken-config',
    configText: '{',
    response: 'OK: бриф полон',
    expected: null,
  },
  {
    name: 'missing-prompt',
    omitPrompt: true,
    response: 'OK: бриф полон',
    expected: null,
  },
  {
    name: 'pool-throws',
    poolError: new Error('boom'),
    expected: null,
  },
  {
    name: 'filtered',
    config: { filter: { classes_skip: ['1e'] } },
    response: 'OK: бриф полон',
    expected: { passed: true, outcome: 'filtered', poolCalls: 0 },
  },
  {
    name: 'block-not-enforced',
    config: { enforce: false },
    response: 'BLOCK: нет',
    expected: { passed: true, outcome: 'block_not_enforced' },
  },
  { name: 'watch-silent', probe: 'watch', toolName: 'Read', watchState: OLD,
    response: 'SILENT: человек велел не звать субагентов',
    expected: { passed: true, outcome: 'silent', poolCalls: 1, nudges: 0 } },
  { name: 'watch-nudge', probe: 'watch', toolName: 'Read', watchState: OLD,
    response: 'NUDGE: отправь scout на перечисление файлов',
    expected: { passed: true, outcome: 'nudge', poolCalls: 1, nudges: 1,
                nudgeIncludes: 'отправь scout' } },
  { name: 'watch-nudge-not-enforced', probe: 'watch', toolName: 'Read', watchState: OLD,
    config: { enforce: false },
    response: 'NUDGE: отправь scout на перечисление файлов',
    expected: { passed: true, outcome: 'nudge_not_enforced', poolCalls: 1, nudges: 0 } },
  { name: 'watch-fleet-busy', probe: 'watch', toolName: 'Read', watchState: OLD,
    fleet: () => [Date.now()],
    response: 'NUDGE: не должно дойти',
    expected: { passed: true, outcome: 'filtered', poolCalls: 0, nudges: 0,
                by: 'fleet-busy:1' } },
  { name: 'watch-window-not-filled', probe: 'watch', toolName: 'Read',
    response: 'NUDGE: не должно дойти',
    expected: { passed: true, outcome: 'filtered', poolCalls: 0, nudges: 0,
                by: 'window-not-filled' } },
  { name: 'watch-cooldown', probe: 'watch', toolName: 'Read',
    watchState: () => ({ last: Date.now(), start: Date.now() - 3600000 }),
    response: 'NUDGE: не должно дойти',
    expected: { passed: true, outcome: 'filtered', poolCalls: 0, nudges: 0,
                by: 'cooldown' } },
  // Отсев по памяти: ни канала, ни СТРОКИ В ЖУРНАЛЕ — пропущенный проход это
  // отсутствие консультации, а не её исход.
  { name: 'watch-not-yet', probe: 'watch', toolName: 'Read',
    watchState: () => ({ last: 0, start: Date.now() - 3600000, nextAt: Date.now() + 600000 }),
    response: 'NUDGE: не должно дойти',
    expected: { passed: true, outcome: null, poolCalls: 0, nudges: 0 } },
  { name: 'watch-broken-config', probe: 'watch', toolName: 'Read', watchState: OLD,
    configText: '{',
    response: 'NUDGE: не должно дойти',
    expected: { passed: true, outcome: 'skip_degraded', poolCalls: 0, nudges: 0 } },
];

function saveEnvironment() {
  return new Map(ENV_KEYS.map((key) => [
    key,
    Object.prototype.hasOwnProperty.call(process.env, key)
      ? { present: true, value: process.env[key] }
      : { present: false, value: undefined },
  ]));
}

function restoreEnvironment(saved) {
  for (const [key, state] of saved) {
    if (state.present) process.env[key] = state.value;
    else delete process.env[key];
  }
}

function setScenarioEnvironment(tempDir, scenario) {
  for (const key of ENV_KEYS) delete process.env[key];
  if (scenario.probe === 'watch') {
    process.env.CLAUDE_IDLE = '1';
    process.env.CLAUDE_IDLE_DIR = tempDir;
  } else {
    process.env.CLAUDE_JUDGE = '1';
    process.env.CLAUDE_JUDGE_DIR = tempDir;
  }
}

function sanitizeText(value, tempDir) {
  if (value === null || value === undefined) return '';
  return String(value)
    .split(tempDir).join('<temp>')
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function sanitizeValue(value, tempDir) {
  if (typeof value === 'string') return sanitizeText(value, tempDir);
  if (Array.isArray(value)) return value.map((item) => sanitizeValue(item, tempDir));
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, sanitizeValue(item, tempDir)]),
    );
  }
  return value;
}

function readLastJournal(tempDir) {
  const journalPath = path.join(tempDir, 'journal.jsonl');
  if (!fs.existsSync(journalPath)) return { entry: null, error: '' };

  const lines = fs.readFileSync(journalPath, 'utf8').split(/\r?\n/).filter(Boolean);
  if (lines.length === 0) return { entry: null, error: '' };

  try {
    return { entry: JSON.parse(lines[lines.length - 1]), error: '' };
  } catch (error) {
    return { entry: null, error: `invalid journal line: ${error.message}` };
  }
}

function expectationText(expected) {
  if (!expected) return '—';
  const parts = [expected.passed ? 'прошёл' : 'отменён'];
  if (expected.outcome !== undefined) parts.push(`outcome=${expected.outcome}`);
  if (expected.poolCalls !== undefined) parts.push(`канал=${expected.poolCalls}`);
  if (expected.by !== undefined) parts.push(`причина=${expected.by}`);
  if (expected.nudges !== undefined) parts.push(`напоминаний=${expected.nudges}`);
  if (expected.nudgeIncludes !== undefined) parts.push(`напоминание содержит «${expected.nudgeIncludes}»`);
  if (expected.errorIncludes !== undefined) parts.push(`исключение содержит «${expected.errorIncludes}»`);
  return parts.join(', ');
}

function checkMismatch(result, expected) {
  if (!expected) return false;
  if (result.passed !== expected.passed) return true;
  if (expected.outcome !== undefined && result.outcome !== expected.outcome) return true;
  if (expected.poolCalls !== undefined && result.poolCalls !== expected.poolCalls) return true;
  // Три отказа дешёвого счёта дают ОДИН И ТОТ ЖЕ outcome; различает их только
  // причина, и без неё перепутанная ветка прошла бы зелёной.
  if (expected.by !== undefined && result.by !== expected.by) return true;
  if (expected.nudges !== undefined && result.nudges !== expected.nudges) return true;
  if (expected.nudgeIncludes !== undefined && !result.nudgeText.includes(expected.nudgeIncludes)) return true;
  if (expected.errorIncludes !== undefined && !result.error.includes(expected.errorIncludes)) return true;
  return false;
}

async function runScenario(probe, scenario) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-'));
  const savedEnvironment = saveEnvironment();
  const savedProbe = Object.getOwnPropertyDescriptor(globalThis, '__ccProbe');
  const savedFleet = Object.getOwnPropertyDescriptor(globalThis, '__ccFleet');
  const savedWatch = Object.getOwnPropertyDescriptor(globalThis, '__ccWatch');
  delete globalThis.__ccProbe;
  delete globalThis.__ccFleet;
  delete globalThis.__ccWatch;
  let poolCalls = 0;
  let passed = true;
  let errorText = '';

  try {
    setScenarioEnvironment(tempDir, scenario);

    const config = { ...baseConfig(scenario), ...(scenario.config || {}) };
    fs.writeFileSync(
      path.join(tempDir, 'config.json'),
      scenario.configText === undefined ? JSON.stringify(config) : scenario.configText,
    );
    if (!scenario.omitPrompt) {
      const prompt = scenario.probe === 'watch'
        ? 'Rules must contain NUDGE.\n'
        : 'Rules must contain BLOCK.\n';
      fs.writeFileSync(path.join(tempDir, 'prompt.md'), prompt);
    }

    if (scenario.fleet) globalThis.__ccFleet = scenario.fleet();
    if (scenario.watchState) globalThis.__ccWatch = scenario.watchState();

    const stubPrompt = '[' + 'dispatch-class' + ':1e]' + ' сделай X';
    const tool = { name: scenario.toolName || 'Agent' };
    const input = {
      subagent_type: 'glm-executor',
      model: 'glm-5.3',
      prompt: stubPrompt,
    };
    const context = {
      messages: [{ type: 'user', message: { role: 'user', content: 'сделай X' } }],
      agentId: 'a1',
      agentContext: { agentType: 'main' },
      getAppState: () => ({ toolPermissionContext: {} }),
    };
    const pool = async () => {
      poolCalls += 1;
      if (scenario.poolError) throw scenario.poolError;
      return {
        message: {
          content: [{ type: 'text', text: scenario.response }],
        },
      };
    };
    const nudges = [];
    const notify = (payload) => { nudges.push(payload); };
    const agentId = () => 'a1';

    try {
      await probe(tool, input, context, 'tool-use-1', pool, notify, agentId);
    } catch (error) {
      passed = false;
      errorText = sanitizeText(error?.message ?? error, tempDir);
    }

    const journal = readLastJournal(tempDir);
    const entry = journal.entry ? sanitizeValue(journal.entry, tempDir) : null;
    if (!errorText && journal.error) errorText = sanitizeText(journal.error, tempDir);

    const result = {
      scenario: scenario.name,
      passed,
      result: passed ? 'прошёл' : 'отменён',
      outcome: entry?.outcome ?? null,
      by: entry?.by ?? null,
      deg: entry?.deg ?? null,
      poolCalls,
      nudges: nudges.length,
      nudgeText: sanitizeText(nudges.map((n) => n && n.value).join(' | '), tempDir),
      error: errorText,
      expected: expectationText(scenario.expected),
      mismatch: false,
    };
    result.mismatch = checkMismatch(result, scenario.expected);
    return result;
  } finally {
    restoreEnvironment(savedEnvironment);
    if (savedProbe) Object.defineProperty(globalThis, '__ccProbe', savedProbe);
    else delete globalThis.__ccProbe;
    if (savedFleet) Object.defineProperty(globalThis, '__ccFleet', savedFleet);
    else delete globalThis.__ccFleet;
    if (savedWatch) Object.defineProperty(globalThis, '__ccWatch', savedWatch);
    else delete globalThis.__ccWatch;
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function formatCell(value) {
  if (value === null || value === undefined || value === '') return '—';
  if (Array.isArray(value) || typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

function printTable(results) {
  const headers = ['сценарий', 'факт', 'outcome', 'deg', 'канал', 'напоминаний', 'исключение', 'ожидалось', 'статус'];
  const rows = results.map((result) => [
    result.scenario,
    result.result,
    formatCell(result.outcome),
    formatCell(result.deg),
    String(result.poolCalls),
    String(result.nudges),
    formatCell(result.error),
    result.expected,
    result.mismatch ? 'MISMATCH' : '—',
  ]);
  const widths = headers.map((header, index) => Math.max(
    header.length,
    ...rows.map((row) => row[index].length),
  ));
  const render = (row) => row.map((cell, index) => cell.padEnd(widths[index])).join(' | ');

  console.log(render(headers));
  console.log(widths.map((width) => '-'.repeat(width)).join('-+-'));
  for (const row of rows) console.log(render(row));
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
    const carved = carveBlock(options.binary);
    const names = locateNames(carved);
    const probe = compileProbe(carved, names);
    const results = [];

    for (const scenario of scenarios) {
      results.push(await runScenario(probe, scenario));
    }

    printTable(results);
    if (options.json) fs.writeFileSync(options.json, `${JSON.stringify(results, null, 2)}\n`);
    if (results.some((result) => result.mismatch)) process.exitCode = 1;
  } catch (error) {
    failSetup(error?.message ?? error);
  }
}

main();
