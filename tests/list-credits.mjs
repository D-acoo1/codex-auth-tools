import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const temp = fs.mkdtempSync(path.join(process.env.CODEX_AUTH_TEST_TMPDIR || os.tmpdir(), 'ca-credits-'));
try {
  const cases = [
    ['string', 'prolite', 'Pro 100', { balance: '12345.67890000' }, '12,345.68'],
    ['number', 'PRO', 'Pro 200', { balance: 4321.5 }, '4,321.5'],
    ['zero', ' promax ', 'Pro 500', { balance: '0', has_credits: false }, '0'],
    ['unlimited', 'plus', 'Plus', { unlimited: true }, '∞'],
    ['small', 'team', 'Team', { balance: '0.004' }, '<0.01'],
    ['rounding', 'self_serve_business_prolite', 'Self_serve_business_prolite', { balance: '1.005' }, '1.01'],
    ['missing', undefined, '-', undefined, '?'],
    ['null', null, '-', { balance: null }, '?'],
    ['empty', ' ', '-', { balance: '' }, '?'],
    ['invalid', 200, '-', { balance: 'unknown' }, '?'],
    ['boolean', 'free', 'Free', { balance: false }, '?'],
    ['negative', 'unknown', 'Unknown', { balance: -1 }, '?'],
    ['relay', 'promax', 'API', { balance: '999' }, '-'],
  ];
  const accounts = Object.fromEntries(cases.map(([alias, plan, , credits]) => [alias, {
    kind: alias === 'relay' ? 'api' : 'chatgpt',
    email: `${alias}@example.com`,
    plan,
    base_url: alias === 'relay' ? 'https://relay.example.com/v1' : undefined,
    last_usage_at: Math.floor(Date.now() / 1000),
    last_usage: {
      primary: null,
      secondary: { used_percent: 25, window_minutes: 10080, resets_at: 2_000_000_000 },
      credits,
      reset_credits_available: 2,
    },
  }]));
  const registry = path.join(temp, 'registry.json');
  fs.writeFileSync(registry, JSON.stringify({ accounts, active_alias: 'string' }));
  const before = fs.readFileSync(registry);
  const env = { ...process.env, CODEX_AC_HOME: temp, CODEX_HOME: path.join(temp, 'codex') };
  const python = process.env.PYTHON_BIN || 'python3';
  const commands = [
    [process.execPath, [path.join(root, 'codex-auth/lib/list.mjs'), '--cached', '--alias', '--no-color']],
    [python, [path.join(root, 'codex-auth/lib/codex-ac.py'), 'list', '--cached']],
  ];
  for (const [executable, args] of commands) {
    const result = spawnSync(executable, args, { env, encoding: 'utf8', timeout: 10000 });
    assert.equal(result.status, 0, result.stderr || result.error?.message);
    const lines = result.stdout.replace(/\n$/, '').split('\n');
    const planStart = lines[0].indexOf('PLAN');
    const planEnd = lines[0].indexOf('5H USAGE');
    const start = lines[0].indexOf('CREDITS');
    const end = lines[0].indexOf('RESET');
    assert(start >= 0 && end > start, 'CREDITS column precedes RESET');
    assert(planStart >= 0 && planEnd > planStart, 'PLAN precedes quota columns');
    for (const [alias, , expectedPlan, , expectedCredits] of cases) {
      const row = lines.slice(2).find(line => {
        const text = line.trim().replace(/^\*\s+/, '');
        return text.startsWith(alias + ' ') || text.endsWith(' ' + alias);
      });
      assert(row, `missing ${alias} row`);
      assert.equal(row.slice(planStart, planEnd).trim(), expectedPlan, `${path.basename(args[0])}: ${alias} PLAN`);
      assert.equal(row.slice(start, end).trim(), expectedCredits, `${path.basename(args[0])}: ${alias} CREDITS`);
      assert.equal(row.length, lines[0].length, 'columns remain aligned');
    }
    assert.deepEqual(fs.readFileSync(registry), before, 'cached list remains read-only');
  }
  const merge = spawnSync(python, ['-c', `
import runpy, sys
merge = runpy.run_path(sys.argv[1])["merge_usage_snapshots"]
old = {"credits": {"balance": "123.5"}, "reset_credits_available": 2}
assert merge(old, {"primary": None})["credits"] == old["credits"]
assert merge(old, {"credits": {"balance": "0"}})["credits"]["balance"] == "0"
assert merge(old, {"credits": None})["credits"] is None
`, path.join(root, 'codex-auth/lib/codex-ac.py')], { env, encoding: 'utf8', timeout: 10000 });
  assert.equal(merge.status, 0, merge.stderr || merge.error?.message);
  console.log('list plan and credits regression passed (Node and Python)');
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
