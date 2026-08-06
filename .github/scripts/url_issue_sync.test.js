'use strict';

const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');

const {
  REQUIRED_LABELS,
  isHealthy,
  isDeletionEligibleFailure,
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
      removeLabel: async (args) => calls.push(['removeLabel', args]),
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

test('deletion eligibility accepts only explicit failures', () => {
  assert.equal(isDeletionEligibleFailure(item({ category: 'invalid_url', status: null })), true);
  assert.equal(isDeletionEligibleFailure(item({ category: 'client_error', status: 404 })), true);
  assert.equal(isDeletionEligibleFailure(item({ category: 'server_error', status: 503 })), true);
  for (const category of ['timeout', 'network_error', 'dns_error', 'tls_error', 'unsafe_destination']) {
    assert.equal(isDeletionEligibleFailure(item({ category, status: null })), false);
  }
  for (const status of [401, 403, 429]) {
    assert.equal(isDeletionEligibleFailure(item({ category: 'client_error', status })), false);
  }
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

test('icon failure at threshold is eligible for owner-approved removal', () => {
  const body = failureBody({
    key: 'b'.repeat(20),
    items: [item({ key: 'b'.repeat(20), kind: 'icon', url: 'https://example.com/icon', normalized_url: 'https://example.com/icon', site_url: 'https://example.com/' })],
    consecutiveFailures: 5,
    checkedAt: '2026-01-01T00:00:00Z',
    runId: 42,
    runUrl: 'https://github.test/run/42'
  });
  assert.match(body, /Eligible for owner approval/);
  assert.doesNotMatch(body, /Automatic removal requires a main URL/);
});

test('sub-threshold failure is not yet eligible regardless of kind', () => {
  for (const kind of ['main', 'icon']) {
    const body = failureBody({
      key: 'c'.repeat(20),
      items: [item({ key: 'c'.repeat(20), kind, url: `https://example.com/${kind}`, normalized_url: `https://example.com/${kind}/` })],
      consecutiveFailures: 4,
      checkedAt: '2026-01-01T00:00:00Z',
      runId: 42,
      runUrl: 'https://github.test/run/42'
    });
    assert.match(body, /Automatic removal requires a URL to fail 5 consecutive checks/);
    assert.doesNotMatch(body, /Eligible for owner approval/);
  }
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
    fs.writeFileSync(resultsFile, JSON.stringify({ checked_at: '2026-01-01T00:00:00Z', results: [item({ category: 'server_error', status: 503, error: null })] }));
    fs.mkdirSync(path.dirname(stateFile), { recursive: true });
    fs.writeFileSync(stateFile, JSON.stringify({ v: 2, failures: { ['a'.repeat(20)]: { kind: 'main', normalized_url: 'https://example.com/', consecutive_failures: 4 } } }));
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
    const current = item({ category: 'server_error', status: 503, error: null });
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

test('an unverifiable result resets evidence, closes its issue, and removes actionable labels', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'url-issue-sync-'));
  try {
    const current = item({ category: 'timeout', status: null });
    const issue = {
      number: 7, state: 'open', user: { login: 'github-actions[bot]' },
      labels: [{ name: 'url-check' }, { name: 'needs-review' }, { name: 'agent:approved' }, { name: 'owner-label' }],
      body: `<!-- url-check:${current.key} -->\n<!-- url-check-state:${JSON.stringify({ v: 1, key: current.key, kind: 'main', normalized_url: current.normalized_url, consecutive_failures: 5 })} -->\nDetails`
    };
    const resultsFile = path.join(directory, 'results.json');
    const stateFile = path.join(directory, 'failure-counts.json');
    fs.writeFileSync(resultsFile, JSON.stringify({ checked_at: '2026-01-01T00:00:00Z', results: [current] }));
    fs.writeFileSync(stateFile, JSON.stringify({ v: 2, failures: { [current.key]: { kind: current.kind, normalized_url: current.normalized_url, consecutive_failures: 5 } } }));
    const { github, calls } = mockGithub({ issues: [issue] });
    await synchronizeIssues({ github, core, context, resultsFile, failureStateFile: stateFile, serverUrl: 'https://github.test' });
    assert.equal(JSON.parse(fs.readFileSync(stateFile)).failures[current.key], undefined);
    assert.deepEqual(calls.filter(([method]) => method === 'removeLabel').map(([, args]) => args.name), ['needs-review', 'agent:approved']);
    const bodyUpdate = calls.find(([method, args]) => method === 'update' && typeof args.body === 'string');
    assert.doesNotMatch(bodyUpdate[1].body, /url-check-state/);
    assert.match(calls.find(([method]) => method === 'createComment')[1].body, /could not verify/);
    assert.equal(calls.find(([method, args]) => method === 'update' && args.state === 'closed')[1].issue_number, issue.number);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('an unverifiable result restarts a subsequent explicit failure at one', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'url-issue-sync-'));
  try {
    const resultsFile = path.join(directory, 'results.json');
    const stateFile = path.join(directory, 'failure-counts.json');
    const explicit = item({ category: 'server_error', status: 503, error: null });
    fs.writeFileSync(stateFile, JSON.stringify({ v: 2, failures: { [explicit.key]: { kind: explicit.kind, normalized_url: explicit.normalized_url, consecutive_failures: 4 } } }));
    fs.writeFileSync(resultsFile, JSON.stringify({ checked_at: '2026-01-01T00:00:00Z', results: [explicit] }));
    let mock = mockGithub();
    await synchronizeIssues({ github: mock.github, core, context, resultsFile, failureStateFile: stateFile, serverUrl: 'https://github.test' });
    assert.match(mock.calls.find(([method]) => method === 'create')[1].body, /"consecutive_failures":5/);

    fs.writeFileSync(resultsFile, JSON.stringify({ checked_at: '2026-01-02T00:00:00Z', results: [item({ category: 'timeout', status: null })] }));
    mock = mockGithub();
    await synchronizeIssues({ github: mock.github, core, context, resultsFile, failureStateFile: stateFile, serverUrl: 'https://github.test' });
    assert.equal(JSON.parse(fs.readFileSync(stateFile)).failures[explicit.key], undefined);
    assert.equal(mock.calls.some(([method]) => method === 'create'), false);

    fs.writeFileSync(resultsFile, JSON.stringify({ checked_at: '2026-01-03T00:00:00Z', results: [explicit] }));
    mock = mockGithub();
    await synchronizeIssues({ github: mock.github, core, context, resultsFile, failureStateFile: stateFile, serverUrl: 'https://github.test' });
    assert.equal(JSON.parse(fs.readFileSync(stateFile)).failures[explicit.key].consecutive_failures, 1);
    assert.equal(mock.calls.some(([method]) => method === 'create'), false);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
