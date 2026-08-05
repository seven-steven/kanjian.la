'use strict';

const DELIVERY_LABELS = Object.freeze({
  'navigation-request': Object.freeze({
    remove: Object.freeze(['needs-owner-review']),
    add: Object.freeze(['agent:completed'])
  }),
  'url-removal': Object.freeze({
    remove: Object.freeze(['needs-review']),
    add: Object.freeze(['agent:completed'])
  })
});

const FAILURE_MESSAGES = Object.freeze({
  beforeDelivery: 'Navigation automation stopped before pull-request delivery. Review this Actions run for the failed preflight, validation, scope audit, commit, push, or pull-request step.',
  afterDelivery: 'Navigation pull request was delivered, but the request status labels could not be updated. Review this Actions run and update the labels manually.'
});

/**
 * Returns the complete final label set for a delivered navigation request.
 *
 * @param {'navigation-request'|'url-removal'} path Delivery workflow path.
 * @param {string[]} currentLabels Current issue label names.
 * @returns {string[]} Final issue labels.
 */
function deliveredLabels(path, currentLabels) {
  const transition = DELIVERY_LABELS[path];
  if (!transition) throw new Error(`unknown navigation delivery path: ${path}`);
  if (!Array.isArray(currentLabels) || currentLabels.some((label) => typeof label !== 'string')) {
    throw new Error('current labels must be an array of strings');
  }

  const remove = new Set(transition.remove);
  return [...new Set([...currentLabels.filter((label) => !remove.has(label)), ...transition.add])];
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
  const [command, argument] = process.argv.slice(2);
  if (command === 'delivered-labels') {
    let currentLabels;
    try {
      currentLabels = JSON.parse(argument);
    } catch (error) {
      throw new Error(`invalid current label JSON: ${error.message}`);
    }
    process.stdout.write(JSON.stringify({ labels: deliveredLabels(process.argv[4], currentLabels) }));
  } else if (command === 'failure-message') {
    if (argument !== 'before-delivery' && argument !== 'after-delivery') {
      throw new Error(`unknown navigation failure stage: ${argument}`);
    }
    process.stdout.write(failureMessage(argument === 'after-delivery'));
  } else {
    throw new Error(`unknown navigation label helper command: ${command}`);
  }
}

module.exports = {
  deliveredLabels,
  failureMessage
};
