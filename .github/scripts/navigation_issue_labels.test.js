'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  deliveredLabels,
  failureMessage
} = require('./navigation_issue_labels');

test('manual navigation delivery preserves unrelated labels and marks the request completed', () => {
  assert.deepEqual(deliveredLabels('navigation-request', [
    'navigation-request',
    'needs-owner-review',
    'agent:approved',
    'custom'
  ]), [
    'navigation-request',
    'agent:approved',
    'custom',
    'agent:completed'
  ]);
});

test('approved URL removal delivery preserves automation and marks the request completed', () => {
  assert.deepEqual(deliveredLabels('url-removal', [
    'url-check',
    'automated',
    'needs-review',
    'agent:approved'
  ]), [
    'url-check',
    'automated',
    'agent:approved',
    'agent:completed'
  ]);
});

test('delivery label transitions are idempotent and reject invalid input', () => {
  assert.deepEqual(deliveredLabels('navigation-request', [
    'navigation-request',
    'agent:completed'
  ]), [
    'navigation-request',
    'agent:completed'
  ]);
  assert.throws(() => deliveredLabels('unknown', []), /unknown navigation delivery path/);
  assert.throws(() => deliveredLabels('navigation-request', 'not an array'), /current labels must be an array/);
});

test('delivery failure text distinguishes an undelivered PR from a post-delivery label update', () => {
  assert.equal(
    failureMessage(false),
    'Navigation automation stopped before pull-request delivery. Review this Actions run for the failed preflight, validation, scope audit, commit, push, or pull-request step.'
  );
  assert.equal(
    failureMessage(true),
    'Navigation pull request was delivered, but the request status labels could not be updated. Review this Actions run and update the labels manually.'
  );
});
