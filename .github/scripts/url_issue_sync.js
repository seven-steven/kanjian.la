'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const counter = require('./url_failure_counter');

const REQUIRED_LABELS = [
  ['url-check', 'd73a4a'],
  ['automated', '1d76db'],
  ['needs-review', 'fbca04']
];
const ACCESSIBLE_STATUSES = new Set([401, 403, 429]);
const STATE_PATTERN = /<!-- url-check-state:(\{[^\n]*\}) -->/g;
const STATE_CAPTURE_PATTERN = /<!-- url-check-state:(\{[^\n]*\}) -->/;

const markerFor = (key) => `<!-- url-check:${key} -->`;
const legacyKeyFor = (kind, rawUrl) =>
  crypto.createHash('sha256').update(`${kind}:${rawUrl}`).digest('hex').slice(0, 20);
const isHealthy = (item) => ['ok', 'redirect'].includes(item.category) || ACCESSIBLE_STATUSES.has(item.status);
const isDeletionEligibleFailure = counter.isDeletionEligibleFailure;

function referenceFor(item) {
  const head = `- \`${item.path || 'unknown path'}\` — ${item.title || '(untitled)'} (${item.kind}): ${item.url}`;
  const category = item.site_category || '(unknown category)';
  if (item.kind === 'icon') {
    const site = item.site_title || '(unknown site)';
    const main = item.site_url ? `（主链接：${item.site_url}）` : '';
    return `${head}\n  - 属于站点：${site}${main}\n  - 分类：${category}`;
  }
  return `${head}\n  - 站点：${item.site_title || item.title || '(untitled)'}\n  - 分类：${category}`;
}

function failureBody({ key, items, consecutiveFailures, checkedAt, runId, runUrl }) {
  const primary = items.find((item) => !isHealthy(item)) || items[0];
  const approval = consecutiveFailures >= counter.FAILURE_THRESHOLD
    ? 'Eligible for owner approval: add the `agent:approved` label to create a removal PR.'
    : `Automatic removal requires a URL to fail ${counter.FAILURE_THRESHOLD} consecutive checks.`;
  const state = JSON.stringify({
    v: counter.ISSUE_STATE_VERSION, key, kind: primary.kind, normalized_url: primary.normalized_url,
    consecutive_failures: consecutiveFailures, checked_at: checkedAt, run_id: String(runId),
    category: primary.category, status: primary.status ?? null, error: primary.error ?? null
  });
  return [
    markerFor(key), `<!-- url-check-state:${state} -->`, 'Automated URL check detected a failure.', '',
    '## References', items.map(referenceFor).join('\n'), '', '## Latest result',
    `- Consecutive failures: ${consecutiveFailures}/${counter.FAILURE_THRESHOLD}`,
    `- Category: ${primary.category}`, `- Status: ${primary.status ?? 'n/a'}`,
    `- Error: ${primary.error ?? 'n/a'}`, `- Normalized URL: ${primary.normalized_url}`,
    `- Final URL: ${primary.final_url ?? 'n/a'}`, '', approval, '', `[View this Actions run](${runUrl})`
  ].join('\n');
}

function loadFailureCache(file, core) {
  if (!fs.existsSync(file)) return counter.createEmptyDocument();
  try {
    return counter.loadDocument(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    core.warning(`failure counter cache ignored (${error.message}); sub-threshold counts restart at 1`);
    return counter.createEmptyDocument();
  }
}

function writeFailureCache(file, doc) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, counter.serializeDocument(doc));
}

async function ensureRequiredLabels(github, owner, repo) {
  for (const [name, color] of REQUIRED_LABELS) {
    try {
      await github.rest.issues.getLabel({ owner, repo, name });
    } catch (error) {
      if (error.status !== 404) throw error;
      await github.rest.issues.createLabel({ owner, repo, name, color });
    }
  }
}

/**
 * Reconciles labels on a bot-owned URL issue without removing owner-managed
 * labels. needs-review signals actionable work, so never restore it after an
 * approved or completed delivery state.
 */
async function reconcileRequiredLabels(github, owner, repo, issue, { actionable = false } = {}) {
  const existing = new Set((issue.labels || []).map((label) => typeof label === 'string' ? label : label.name));
  const required = ['url-check', 'automated'];
  if (actionable && !existing.has('agent:approved') && !existing.has('agent:completed')) {
    required.push('needs-review');
  }
  const missing = required.filter((name) => !existing.has(name));
  if (missing.length) await github.rest.issues.addLabels({ owner, repo, issue_number: issue.number, labels: missing });
}

async function synchronizeIssues({ github, core, context, resultsFile, failureStateFile, serverUrl }) {
  const payload = JSON.parse(fs.readFileSync(resultsFile, 'utf8'));
  const { results } = payload;
  const checkedAt = payload.checked_at;
  const { owner, repo } = context.repo;
  const runUrl = `${serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;
  const failureCache = loadFailureCache(failureStateFile, core);
  const resetFailureState = async (issue) => {
    if (!issue?.body?.match(STATE_CAPTURE_PATTERN)) return;
    const body = issue.body.replace(STATE_PATTERN, '').replace(/\n{3,}/g, '\n\n').trim();
    await github.rest.issues.update({ owner, repo, issue_number: issue.number, body });
  };
  const removeActionableLabels = async (issue) => {
    const labels = new Set((issue?.labels || []).map((label) => typeof label === 'string' ? label : label.name));
    for (const name of ['needs-review', 'agent:approved']) {
      if (labels.has(name)) await github.rest.issues.removeLabel({ owner, repo, issue_number: issue.number, name });
    }
  };
  const commentAndClose = async (issue, comment, alwaysComment = false) => {
    if (!issue) return;
    if (alwaysComment || issue.state === 'open') {
      await github.rest.issues.createComment({ owner, repo, issue_number: issue.number, body: comment });
    }
    if (issue.state === 'open') await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'closed' });
  };

  await ensureRequiredLabels(github, owner, repo);
  const issues = (await github.paginate(github.rest.issues.listForRepo, {
    owner, repo, state: 'all', per_page: 100, labels: 'url-check'
  })).filter((issue) => !issue.pull_request && issue.user?.login === 'github-actions[bot]');
  const currentByKey = new Map();
  for (const item of results) {
    const grouped = currentByKey.get(item.key) || [];
    grouped.push(item);
    currentByKey.set(item.key, grouped);
  }
  const issuesByKey = new Map();
  for (const issue of issues) {
    const markers = [...(issue.body || '').matchAll(/<!-- url-check:([a-f0-9]{20}) -->/g)];
    const states = [...(issue.body || '').matchAll(STATE_PATTERN)];
    if (markers.length !== 1 || states.length > 1) continue;
    const key = markers[0][1];
    if (states.length === 1) {
      try {
        const state = JSON.parse(states[0][1]);
        if (state.v !== counter.ISSUE_STATE_VERSION || state.key !== key || !['main', 'icon'].includes(state.kind) || typeof state.normalized_url !== 'string') continue;
      } catch (_error) { continue; }
    }
    const grouped = issuesByKey.get(key) || [];
    grouped.push(issue);
    issuesByKey.set(key, grouped);
  }
  const issueMap = new Map();
  for (const [key, duplicates] of issuesByKey) {
    duplicates.sort((left, right) => left.number - right.number);
    const [earliest, ...later] = duplicates;
    issueMap.set(key, earliest);
    await reconcileRequiredLabels(github, owner, repo, earliest);
    for (const duplicate of later) {
      await reconcileRequiredLabels(github, owner, repo, duplicate);
      await commentAndClose(duplicate, `Duplicate of #${earliest.number}; retaining the earliest URL check issue for this key.\n\n[View this Actions run](${runUrl})`, true);
    }
  }
  const migratedIssueNumbers = new Set();
  for (const [canonicalKey, items] of currentByKey) {
    if (issueMap.has(canonicalKey)) continue;
    const legacyKeys = new Set(items.map((item) => legacyKeyFor(item.kind, item.url)));
    legacyKeys.delete(canonicalKey);
    const claim = [...legacyKeys].map((key) => issueMap.get(key)).find((candidate) => candidate && !migratedIssueNumbers.has(candidate.number));
    if (!claim) continue;
    issueMap.set(canonicalKey, claim);
    for (const key of legacyKeys) issueMap.delete(key);
    migratedIssueNumbers.add(claim.number);
  }
  for (const [key, issue] of issueMap) {
    if (!currentByKey.has(key)) {
      counter.removeFailure(failureCache, key);
      await commentAndClose(issue, `This URL has been removed from navigation and is no longer checked.\n\n[View this Actions run](${runUrl})`);
    }
  }
  for (const [key, items] of currentByKey) {
    const issue = issueMap.get(key);
    const wasMigrated = issue && migratedIssueNumbers.has(issue.number);
    if (items.every(isHealthy)) {
      counter.removeFailure(failureCache, key);
      await resetFailureState(issue);
      const note = wasMigrated
        ? `URL check recovered; the URL is reachable again. This issue was matched via its legacy Unicode-URL key after IDN (Punycode) canonicalization.\n\n[View this Actions run](${runUrl})`
        : `URL check recovered; the URL is reachable again.\n\n[View this Actions run](${runUrl})`;
      await commentAndClose(issue, note);
      continue;
    }
    const primary = items.find(isDeletionEligibleFailure);
    if (!primary) {
      counter.removeFailure(failureCache, key);
      await resetFailureState(issue);
      await removeActionableLabels(issue);
      await commentAndClose(issue, `URL check could not verify this URL's availability. Its failure count has been reset and no removal action will be taken until a subsequent explicit failure is observed.\n\n[View this Actions run](${runUrl})`, true);
      continue;
    }
    const { count: consecutiveFailures, source } = counter.nextFailureCount({ issue, doc: failureCache, key, item: primary });
    counter.setFailure(failureCache, key, primary, consecutiveFailures);
    core.info(`URL key ${key}: consecutive failures=${consecutiveFailures}/${counter.FAILURE_THRESHOLD} (source=${source})`);
    if (consecutiveFailures < counter.FAILURE_THRESHOLD) {
      if (issue && issue.state === 'open') {
        await github.rest.issues.update({ owner, repo, issue_number: issue.number, body: failureBody({ key, items, consecutiveFailures, checkedAt, runId: context.runId, runUrl }) });
      }
      continue;
    }
    const body = failureBody({ key, items, consecutiveFailures, checkedAt, runId: context.runId, runUrl });
    if (issue) {
      await github.rest.issues.update({ owner, repo, issue_number: issue.number, state: 'open', body });
      await reconcileRequiredLabels(github, owner, repo, issue, { actionable: true });
    } else {
      const created = await github.rest.issues.create({ owner, repo, title: `[URL Check] ${items[0].title || items[0].url}`, body, labels: REQUIRED_LABELS.map(([name]) => name) });
      issueMap.set(key, created.data);
    }
  }
  counter.pruneStale(failureCache, new Set(currentByKey.keys()));
  writeFailureCache(failureStateFile, failureCache);
}

module.exports = { REQUIRED_LABELS, isHealthy, isDeletionEligibleFailure, legacyKeyFor, referenceFor, failureBody, loadFailureCache, writeFailureCache, ensureRequiredLabels, reconcileRequiredLabels, synchronizeIssues };
