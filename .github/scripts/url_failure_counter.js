'use strict';

/** Number of consecutive failures required before an issue is actionable. */
const FAILURE_THRESHOLD = 5;
const DOCUMENT_VERSION = 1;
const STATE_PATTERN = /<!-- url-check-state:(\{.*?\}) -->/g;

/**
 * Returns whether a value is a non-array object.
 *
 * @param {unknown} value Value to inspect.
 * @returns {boolean} Whether the value is an object suitable for a document.
 */
function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * Returns whether a count represents one or more consecutive failures.
 *
 * @param {unknown} count Failure count to validate.
 * @returns {boolean} Whether the count is a positive integer.
 */
function isPositiveInteger(count) {
  return Number.isInteger(count) && count > 0;
}

/**
 * Creates an empty, versioned failure-cache document.
 *
 * @returns {{v: number, failures: Object<string, object>}} Empty cache document.
 */
function createEmptyDocument() {
  return { v: DOCUMENT_VERSION, failures: {} };
}

/**
 * Parses and validates the persisted failure-cache document. Invalid individual
 * entries are omitted so one damaged record does not discard the whole cache.
 *
 * @param {string} rawJsonString Serialized cache document.
 * @returns {{v: number, failures: Object<string, object>}} Normalized document.
 * @throws {Error} When the JSON or document-level schema is invalid.
 */
function loadDocument(rawJsonString) {
  let document;
  try {
    document = JSON.parse(rawJsonString);
  } catch (error) {
    throw new Error(`invalid cache document JSON: ${error.message}`);
  }

  if (!isObject(document)) throw new Error('cache document must be an object');
  if (document.v !== DOCUMENT_VERSION) throw new Error('unsupported cache document version');
  if (!isObject(document.failures)) throw new Error('cache document failures must be an object');

  const failures = {};
  for (const [key, entry] of Object.entries(document.failures)) {
    if (!isObject(entry) || typeof entry.kind !== 'string' ||
      typeof entry.normalized_url !== 'string' || !isPositiveInteger(entry.consecutive_failures)) {
      continue;
    }
    failures[key] = {
      kind: entry.kind,
      normalized_url: entry.normalized_url,
      consecutive_failures: entry.consecutive_failures
    };
  }

  return { v: DOCUMENT_VERSION, failures };
}

/**
 * Determines whether a cache entry belongs to the checked canonical target.
 * The cache map key has already selected the candidate entry.
 *
 * @param {{kind: string, normalized_url: string}} entry Cached failure entry.
 * @param {{kind: string, normalized_url: string}} item Current check result.
 * @returns {boolean} Whether both target properties match.
 */
function matchesTarget(entry, item) {
  return entry?.kind === item?.kind && entry?.normalized_url === item?.normalized_url;
}

/**
 * Gets the count from a matching valid cache entry.
 *
 * @param {{failures: Object<string, object>}} doc Cache document.
 * @param {string} key Cache key.
 * @param {{kind: string, normalized_url: string}} item Current check result.
 * @returns {number|null} Previous count, if it belongs to this target.
 */
function previousCacheCount(doc, key, item) {
  const entry = doc?.failures?.[key];
  if (!matchesTarget(entry, item) || !isPositiveInteger(entry?.consecutive_failures)) return null;

  return entry.consecutive_failures;
}

/**
 * Gets the count from exactly one valid URL-check issue state marker.
 *
 * @param {{body?: string}|null} issue Existing GitHub issue.
 * @param {string} key Canonical failure key.
 * @param {{kind: string, normalized_url: string}} item Current check result.
 * @returns {number|null} Previous issue count, if its state matches this target.
 */
function previousIssueCount(issue, key, item) {
  if (!issue || typeof issue.body !== 'string') return null;

  const markers = [...issue.body.matchAll(STATE_PATTERN)];
  if (markers.length !== 1) return null;

  try {
    const state = JSON.parse(markers[0][1]);
    const matches = isObject(state) && state.v === DOCUMENT_VERSION && state.key === key &&
      state.kind === item?.kind && state.normalized_url === item?.normalized_url &&
      isPositiveInteger(state.consecutive_failures);
    return matches ? state.consecutive_failures : null;
  } catch (_error) {
    return null;
  }
}

/**
 * Advances a failure count using issue state first, then durable cache state.
 *
 * @param {{issue: object|null, doc: object, key: string, item: object}} input Failure context.
 * @returns {{count: number, source: 'issue'|'cache'|'fresh'}} Next count and its source.
 */
function nextFailureCount({ issue, doc, key, item }) {
  const issueCount = previousIssueCount(issue, key, item);
  if (issueCount !== null) return { count: issueCount + 1, source: 'issue' };

  const cacheCount = previousCacheCount(doc, key, item);
  if (cacheCount !== null) return { count: cacheCount + 1, source: 'cache' };

  return { count: 1, source: 'fresh' };
}

/**
 * Records a target's current failure count in the supplied cache document.
 *
 * @param {{failures: Object<string, object>}} doc Cache document to update.
 * @param {string} key Cache key.
 * @param {{kind: string, normalized_url: string}} item Current check result.
 * @param {number} count Current consecutive failure count.
 * @returns {object} The same mutated document.
 */
function setFailure(doc, key, item, count) {
  doc.failures[key] = {
    kind: item.kind,
    normalized_url: item.normalized_url,
    consecutive_failures: count
  };
  return doc;
}

/**
 * Removes one target's failure state from the supplied cache document.
 *
 * @param {{failures: Object<string, object>}} doc Cache document to update.
 * @param {string} key Cache key to remove.
 * @returns {object} The same mutated document.
 */
function removeFailure(doc, key) {
  delete doc.failures[key];
  return doc;
}

/**
 * Drops records for targets no longer present in the current check result.
 *
 * @param {{failures: Object<string, object>}} doc Cache document to update.
 * @param {Set<string>|string[]} activeKeys Current target keys.
 * @returns {object} The same mutated document.
 */
function pruneStale(doc, activeKeys) {
  const keys = activeKeys instanceof Set ? activeKeys : new Set(activeKeys);
  for (const key of Object.keys(doc.failures)) {
    if (!keys.has(key)) delete doc.failures[key];
  }
  return doc;
}

/**
 * Serializes a cache document for its caller to persist.
 *
 * @param {object} doc Cache document.
 * @returns {string} JSON cache document.
 */
function serializeDocument(doc) {
  return JSON.stringify(doc);
}

module.exports = {
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
};
