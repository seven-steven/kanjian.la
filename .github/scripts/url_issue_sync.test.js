'use strict';

const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');

const {
  REQUIRED_LABELS,
  isHealthy,
  legacyKeyFor,
  failureBody,
  reconcileRequiredLabels,
  synchronizeIssues
} = require('./url_issue_sync');

const item = (overrides = {}) => ({
  key: 'a'.repeat(20), kind: 'main', url: 'https://example.com', normalized_url: 'https://example.com/',
  title: 'Example', path: '_data/sites.yml', category: 'timeout', status: null, error: 'timeout',
  site_title: 'Example', site_category: 'Tools', ...overrides
});

function mockGithub({ issues = [], labels = REQUIRED_LABELS.map(([name]) => name) } = {}) {
  const calls = [];
  const github = {
    paginate: async () => issues,
    rest: { issues: {
      getLabel: async ({ name }) => {
        calls.push(['getLabel', name]);
        if (!labels.includes(name)) { const error = new Error('not found'); error.status = 404; throw error; }
      },
      createLabel: async (args) => { calls.push(['createLabel', args]); labels.push(args.name); },
      addLabels: async (args) => calls.push(['addLabels', args]),
      update: async (args) => calls.push(['update', args]),
      createComment: async (args) => calls.push(['createComment', args]),
      create: async (args) => { calls.push(['create', args]); return { data: { number: 999, state: 'open', labels: args.labels.map((name) => ({ name })), ...args } }; },
      listForRepo: async () => []
    } }
  };
  return { github, calls };
}

const context = { repo: { owner: 'owner', repo: 'repo' }, runId: 42 };
const core = { info() {}, warning() {} };

test('health handling retains accessible authentication and rate-limit URLs', () => {
  assert.equal(isHealthy(item({ category: 'ok', status: 200 })), true);
  assert.equal(isHealthy(item({ category: 'redirect', status: 301 })), true);
  for (const status of [401, 403, 429]) assert.equal(isHealthy(item({ category: 'http_error', status })), true);
  assert.equal(isHealthy(item({ category: 'timeout', status: null })), false);
});

test('legacy key matches the raw Unicode URL fallback', () => {
  assert.equal(legacyKeyFor('main', 'https://例子.测试/'), 'b3c4ec163f90fbb4b248');
});

test('failure body preserves references, state, threshold and action URL', () => {
  const body = failureBody({ key: 'a'.repeat(20), items: [item()], consecutiveFailures: 5, checkedAt: '2026-01-01T00:00:00Z', runId: 42, runUrl: 'https://github.test/run/42' });
  assert.match(body, /<!-- url-check:aaaaaaaaaaaaaaaaaaaa -->/);
  assert.match(body, /"consecutive_failures":5/);
  assert.match(body, /Eligible for owner approval/);
  assert.match(body, /_data\/sites.yml/);
  assert.match(body, /https:\/\/github.test\/run\/42/);
});

test('reconcileRequiredLabels always restores base labels and conditionally adds needs-review', async () => {
  const { github, calls } = mockGithub();
  await reconcileRequiredLabels(github, 'owner', 'repo', { number: 7, labels: [{ name: 'agent:approved' }] }, { actionable: true });
  assert.deepEqual(calls, [['addLabels', { owner: 'owner', repo: 'repo', issue_number: 7, labels: ['url-check', 'automated'] }]]);

  calls.length = 0;
  await reconcileRequiredLabels(github, 'owner', 'repo', { number: 8, labels: [{ name: 'url-check' }] }, { actionable: true });
  assert.deepEqual(calls, [['addLabels', { owner: 'owner', repo: 'repo', issue_number: 8, labels: ['automated', 'needs-review'] }]]);

  calls.length = 0;
  await reconcileRequiredLabels(github, 'owner', 'repo', { number: 9, labels: [{ name: 'agent:completed' }] }, { actionable: true });
  assert.deepEqual(calls, [['addLabels', { owner: 'owner', repo: 'repo', issue_number: 9, labels: ['url-check', 'automated'] }]]);

  calls.length = 0;
  await reconcileRequiredLabels(github, 'owner', 'repo', { number: 10, labels: [{ name: 'url-check' }] });
  assert.deepEqual(calls, [['addLabels', { owner: 'owner', repo: 'repo', issue_number: 10, labels: ['automated'] }]]);
});

test('synchronization creates an issue at threshold with required labels', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'url-issue-sync-'));
  try {
    const resultsFile = path.join(directory, 'results.json');
    const stateFile = path.join(directory, 'state', 'failure-counts.json');
    fs.writeFileSync(resultsFile, JSON.stringify({ checked_at: '2026-01-01T00:00:00Z', results: [item()] }));
    fs.mkdirSync(path.dirname(stateFile), { recursive: true });
    fs.writeFileSync(stateFile, JSON.stringify({ v: 1, failures: { ['a'.repeat(20)]: { kind: 'main', normalized_url: 'https://example.com/', consecutive_failures: 4 } } }));
    const { github, calls } = mockGithub();
    await synchronizeIssues({ github, core, context, resultsFile, failureStateFile: stateFile, serverUrl: 'https://github.test' });
    const create = calls.find(([method]) => method === 'create');
    assert.deepEqual(create[1].labels, ['url-check', 'automated', 'needs-review']);
    assert.match(create[1].body, /"consecutive_failures":5/);
    assert.equal(JSON.parse(fs.readFileSync(stateFile)).failures['a'.repeat(20)].consecutive_failures, 5);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('synchronization reconciles labels on an existing open issue without losing approved label', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'url-issue-sync-'));
  try {
    const current = item();
    const issue = { number: 7, state: 'open', user: { login: 'github-actions[bot]' }, labels: [{ name: 'url-check' }, { name: 'agent:approved' }], body: `<!-- url-check:${current.key} -->\n<!-- url-check-state:${JSON.stringify({ v: 1, key: current.key, kind: 'main', normalized_url: current.normalized_url, consecutive_failures: 5 })} -->` };
    const resultsFile = path.join(directory, 'results.json');
    const stateFile = path.join(directory, 'failure-counts.json');
    fs.writeFileSync(resultsFile, JSON.stringify({ checked_at: '2026-01-01T00:00:00Z', results: [current] }));
    const { github, calls } = mockGithub({ issues: [issue] });
    await synchronizeIssues({ github, core, context, resultsFile, failureStateFile: stateFile, serverUrl: 'https://github.test' });
    assert.deepEqual(calls.find(([method]) => method === 'addLabels')[1].labels, ['automated']);
    const update = calls.find(([method, args]) => method === 'update' && args.state === 'open');
    assert.match(update[1].body, /"consecutive_failures":6/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
