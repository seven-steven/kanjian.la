'use strict';

const DELIVERY_LABELS = Object.freeze({
  'navigation-request': Object.freeze({
    add: Object.freeze(['agent:completed']),
    remove: Object.freeze(['needs-owner-review']),
    preserved: Object.freeze(['agent:approved'])
  }),
  'url-removal': Object.freeze({
    add: Object.freeze(['agent:completed']),
    remove: Object.freeze(['needs-review']),
    preserved: Object.freeze(['agent:approved'])
  })
});

const FAILURE_MESSAGES = Object.freeze({
  beforeDelivery: 'Navigation automation stopped before pull-request delivery. Review this Actions run for the failed preflight, validation, scope audit, commit, push, or pull-request step.',
  afterDelivery: 'Navigation pull request was delivered, but the request status labels could not be updated. Review this Actions run and update the labels manually.'
});

/**
 * Returns the safe, label-specific delivery transition for a navigation path.
 * Labels are added before pending-review labels are removed so a failed removal
 * leaves the delivered state visible without discarding concurrent label edits.
 *
 * @param {'navigation-request'|'url-removal'} path Delivery workflow path.
 * @returns {{add: string[], remove: string[], preserved: string[]}} Label transition.
 */
function deliveryLabelTransition(path) {
  const transition = DELIVERY_LABELS[path];
  if (!transition) throw new Error(`unknown navigation delivery path: ${path}`);
  return {
    add: [...transition.add],
    remove: [...transition.remove],
    preserved: [...transition.preserved]
  };
}

/**
 * Returns the failure comment appropriate to the delivery stage.
 *
 * @param {boolean} prDelivered Whether pull-request delivery completed.
 * @returns {string} Failure comment body.
 */
function failureMessage(prDelivered) {
  return prDelivered ? FAILURE_MESSAGES.afterDelivery : FAILURE_MESSAGES.beforeDelivery;
}

if (require.main === module) {
  const [command, path, operation] = process.argv.slice(2);
  if (command !== 'labels' || !['add', 'remove'].includes(operation)) {
    throw new Error('usage: navigation_issue_labels.js labels PATH (add|remove)');
  }
  process.stdout.write(`${deliveryLabelTransition(path)[operation].join('\n')}\n`);
}

module.exports = {
  deliveryLabelTransition,
  failureMessage
};
