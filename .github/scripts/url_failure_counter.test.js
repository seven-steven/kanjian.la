'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  FAILURE_THRESHOLD,
  createEmptyDocument,
  loadDocument,
  matchesTarget,
  previousCacheCount,
  previousIssueCount,
  nextFailureCount,
  setFailure,
  removeFailure,
  pruneStale,
  serializeDocument
} = require('./url_failure_counter');

const item = {
  key: 'main-example',
  kind: 'main',
  normalized_url: 'https://example.com/'
};

const otherItem = {
  key: 'main-other',
  kind: 'main',
  normalized_url: 'https://other.example/'
};

const issueWithState = (state) => ({
  body: `Automated URL check\n<!-- url-check-state:${JSON.stringify(state)} -->`
});

const matchingState = (overrides = {}) => ({
  v: 1,
  key: item.key,
  kind: item.kind,
  normalized_url: item.normalized_url,
  consecutive_failures: 4,
  ...overrides
});

test('createEmptyDocument returns the versioned empty failure map', () => {
  assert.deepEqual(createEmptyDocument(), { v: 1, failures: {} });
});

test('loadDocument parses valid documents and rejects malformed documents', () => {
  const document = loadDocument(JSON.stringify({
    v: 1,
    failures: {
      valid: { kind: 'main', normalized_url: 'https://example.com/', consecutive_failures: 2 },
      invalid: { kind: 'main', normalized_url: 'https://invalid.example/', consecutive_failures: 0 }
    }
  }));

  assert.deepEqual(document, {
    v: 1,
    failures: {
      valid: { kind: 'main', normalized_url: 'https://example.com/', consecutive_failures: 2 }
    }
  });
  assert.throws(() => loadDocument('{'), /invalid cache document JSON:/);
  assert.throws(() => loadDocument(JSON.stringify({ v: 2, failures: {} })), /unsupported cache document version/);
  assert.throws(() => loadDocument(JSON.stringify({ v: 1, failures: [] })), /cache document failures must be an object/);
});

test('matchesTarget compares the kind and normalized URL', () => {
  const entry = { kind: item.kind, normalized_url: item.normalized_url };

  assert.equal(matchesTarget(entry, item), true);
  assert.equal(matchesTarget({ ...entry, kind: 'icon' }, item), false);
  assert.equal(matchesTarget({ ...entry, normalized_url: 'https://other.example/' }, item), false);
});

test('previousCacheCount returns only a valid matching cache count', () => {
  const document = {
    v: 1,
    failures: {
      [item.key]: { kind: item.kind, normalized_url: item.normalized_url, consecutive_failures: 4 }
    }
  };

  assert.equal(previousCacheCount(document, item.key, item), 4);
  assert.equal(previousCacheCount(document, item.key, { ...item, kind: 'icon' }), null);
  assert.equal(previousCacheCount(document, item.key, { ...item, normalized_url: 'https://other.example/' }), null);
  assert.equal(previousCacheCount(document, 'missing', item), null);
});

test('previousIssueCount accepts exactly one valid matching state marker', () => {
  assert.equal(previousIssueCount(issueWithState(matchingState()), item.key, item), 4);
  assert.equal(previousIssueCount(null, item.key, item), null);
  assert.equal(previousIssueCount({ body: 'No marker here' }, item.key, item), null);
  assert.equal(previousIssueCount({ body: `${issueWithState(matchingState()).body}\n${issueWithState(matchingState()).body}` }, item.key, item), null);
  assert.equal(previousIssueCount({ body: '<!-- url-check-state:{broken} -->' }, item.key, item), null);

  for (const state of [
    matchingState({ v: 2 }),
    matchingState({ key: otherItem.key }),
    matchingState({ kind: 'icon' }),
    matchingState({ normalized_url: otherItem.normalized_url }),
    matchingState({ consecutive_failures: 0 }),
    matchingState({ consecutive_failures: 1.5 })
  ]) {
    assert.equal(previousIssueCount(issueWithState(state), item.key, item), null);
  }
});

test('nextFailureCount prioritizes issue state, then cache state, then a fresh count', () => {
  const cache = {
    v: 1,
    failures: {
      [item.key]: { kind: item.kind, normalized_url: item.normalized_url, consecutive_failures: 4 }
    }
  };

  assert.deepEqual(nextFailureCount({ issue: null, doc: createEmptyDocument(), key: item.key, item }), {
    count: 1,
    source: 'fresh'
  });
  assert.deepEqual(nextFailureCount({ issue: { body: 'no state' }, doc: cache, key: item.key, item }), {
    count: 5,
    source: 'cache'
  });
  assert.deepEqual(nextFailureCount({ issue: issueWithState(matchingState({ consecutive_failures: 5 })), doc: cache, key: item.key, item }), {
    count: 6,
    source: 'issue'
  });
  assert.deepEqual(nextFailureCount({
    issue: issueWithState(matchingState({ normalized_url: otherItem.normalized_url, consecutive_failures: 9 })),
    doc: cache,
    key: item.key,
    item
  }), { count: 5, source: 'cache' });
});

test('setFailure, removeFailure, and pruneStale mutate the supplied document', () => {
  const document = createEmptyDocument();

  assert.equal(setFailure(document, item.key, item, 3), document);
  assert.deepEqual(document.failures[item.key], {
    kind: item.kind,
    normalized_url: item.normalized_url,
    consecutive_failures: 3
  });
  setFailure(document, otherItem.key, otherItem, 2);
  assert.equal(removeFailure(document, item.key), document);
  assert.equal(document.failures[item.key], undefined);
  setFailure(document, item.key, item, 3);
  assert.equal(pruneStale(document, new Set([item.key])), document);
  assert.deepEqual(Object.keys(document.failures), [item.key]);
});

test('serializeDocument round-trips through loadDocument', () => {
  const document = createEmptyDocument();
  setFailure(document, item.key, item, 3);

  assert.deepEqual(loadDocument(serializeDocument(document)), document);
});

test('FAILURE_THRESHOLD is five consecutive failures', () => {
  assert.equal(FAILURE_THRESHOLD, 5);
});
