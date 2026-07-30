#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"
require_relative "check_urls"

# Defines the machine-readable state embedded in URL check issues.
module UrlIssueState
  VERSION = 1
  KEY_PATTERN = /\A[a-f0-9]{20}\z/
  MARKER_PATTERN = /<!-- url-check:([a-f0-9]{20}) -->/
  STATE_PATTERN = /<!-- url-check-state:(.*?) -->/m
  FIELDS = %w[
    v key kind normalized_url consecutive_failures checked_at run_id category status error
  ].freeze

  class InvalidState < StandardError; end

  module_function

  def render_marker(key)
    raise InvalidState, "invalid URL check key" unless key.is_a?(String) && key.match?(KEY_PATTERN)

    "<!-- url-check:#{key} -->"
  end

  def render_state(state)
    validated = validate_state(state)
    ordered = FIELDS.each_with_object({}) { |field, result| result[field] = validated.fetch(field) }
    "<!-- url-check-state:#{JSON.generate(ordered)} -->"
  end

  def parse_issue(body)
    raise InvalidState, "issue body must be a string" unless body.is_a?(String)

    markers = body.scan(MARKER_PATTERN).flatten
    states = body.scan(STATE_PATTERN).flatten
    raise InvalidState, "expected exactly one URL check marker" unless markers.length == 1
    raise InvalidState, "expected exactly one URL check state" unless states.length == 1

    state = JSON.parse(states.first)
    state = validate_state(state)
    raise InvalidState, "marker key does not match state key" unless markers.first == state.fetch("key")

    state
  rescue JSON::ParserError => error
    raise InvalidState, "invalid URL check state JSON: #{error.message}"
  end

  def next_failure_state(previous:, current:)
    current = validate_current(current)
    previous = validate_state(previous) unless previous.nil?
    count = if previous && same_target?(previous, current)
              previous.fetch("consecutive_failures") + 1
            else
              1
            end

    {
      "v" => VERSION,
      "key" => current.fetch("key"),
      "kind" => current.fetch("kind"),
      "normalized_url" => current.fetch("normalized_url"),
      "consecutive_failures" => count,
      "checked_at" => current.fetch("checked_at"),
      "run_id" => current.fetch("run_id"),
      "category" => current.fetch("category"),
      "status" => current.fetch("status"),
      "error" => current.fetch("error")
    }
  end

  def validate_state(state)
    raise InvalidState, "state must be an object" unless state.is_a?(Hash)
    raise InvalidState, "state fields do not match protocol" unless state.keys.sort == FIELDS.sort
    raise InvalidState, "unsupported URL check state version" unless state["v"] == VERSION
    validate_target(state)

    count = state["consecutive_failures"]
    raise InvalidState, "consecutive failures must be a positive integer" unless count.is_a?(Integer) && count.positive?
    validate_metadata(state)
    state
  end

  def validate_current(current)
    raise InvalidState, "current result must be an object" unless current.is_a?(Hash)

    state = current.slice("key", "kind", "normalized_url", "checked_at", "run_id", "category", "status", "error")
    raise InvalidState, "current result fields do not match protocol" unless state.length == 8

    state["v"] = VERSION
    state["consecutive_failures"] = 1
    validate_state(state)
  end

  def validate_target(state)
    key = state["key"]
    kind = state["kind"]
    url = state["normalized_url"]
    raise InvalidState, "invalid URL check key" unless key.is_a?(String) && key.match?(KEY_PATTERN)
    raise InvalidState, "invalid URL check kind" unless %w[main icon].include?(kind)
    raise InvalidState, "normalized URL must be canonical" unless url.is_a?(String) && UrlCheck.normalize(url) == url
    raise InvalidState, "URL check key does not match target" unless UrlCheck.key_for(kind, url) == key
  rescue URI::InvalidURIError => error
    raise InvalidState, "invalid normalized URL: #{error.message}"
  end
  private_class_method :validate_target

  def validate_metadata(state)
    Time.iso8601(state["checked_at"])
    raise InvalidState, "run ID must be a non-empty string" unless state["run_id"].is_a?(String) && !state["run_id"].empty?
    raise InvalidState, "category must be a non-empty string" unless state["category"].is_a?(String) && !state["category"].empty?
    raise InvalidState, "status must be an integer or null" unless state["status"].nil? || state["status"].is_a?(Integer)
    raise InvalidState, "error must be a string or null" unless state["error"].nil? || state["error"].is_a?(String)
  rescue ArgumentError
    raise InvalidState, "checked_at must be ISO 8601"
  end
  private_class_method :validate_metadata

  def same_target?(left, right)
    %w[key kind normalized_url].all? { |field| left.fetch(field) == right.fetch(field) }
  end
  private_class_method :same_target?
end
