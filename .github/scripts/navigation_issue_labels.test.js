'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
  deliveryLabelTransition,
  failureMessage
} = require('./navigation_issue_labels');
const { execFileSync } = require('node:child_process');
const path = require('node:path');

const helper = path.join(__dirname, 'navigation_issue_labels.js');

test('manual navigation delivery adds completed before removing owner review and preserves approval', () => {
  assert.deepEqual(deliveryLabelTransition('navigation-request'), {
    add: ['agent:completed'],
    remove: ['needs-owner-review'],
    preserved: ['agent:approved']
  });
});

test('approved URL removal delivery adds completed before removing review and preserves approval', () => {
  assert.deepEqual(deliveryLabelTransition('url-removal'), {
    add: ['agent:completed'],
    remove: ['needs-review'],
    preserved: ['agent:approved']
  });
});

test('delivery label transitions return fresh arrays and reject unknown paths', () => {
  const transition = deliveryLabelTransition('navigation-request');
  transition.add.push('unrelated');

  assert.deepEqual(deliveryLabelTransition('navigation-request').add, ['agent:completed']);
  assert.throws(() => deliveryLabelTransition('unknown'), /unknown navigation delivery path/);
});

test('helper CLI emits label-specific operations without a full label replacement', () => {
  assert.equal(
    execFileSync(process.execPath, [helper, 'labels', 'navigation-request', 'add'], { encoding: 'utf8' }),
    'agent:completed\n'
  );
  assert.equal(
    execFileSync(process.execPath, [helper, 'labels', 'url-removal', 'remove'], { encoding: 'utf8' }),
    'needs-review\n'
  );
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
