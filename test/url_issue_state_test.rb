# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/url_issue_state"

class UrlIssueStateTest < Minitest::Test
  def current(overrides = {})
    {
      "key" => UrlCheck.key_for("main", "https://example.com/"),
      "kind" => "main",
      "normalized_url" => "https://example.com/",
      "checked_at" => "2026-07-30T12:00:00Z",
      "run_id" => "123",
      "category" => "server_error",
      "status" => 503,
      "error" => nil
    }.merge(overrides)
  end

  def test_renders_and_parses_strict_canonical_state
    state = UrlIssueState.next_failure_state(previous: nil, current: current)
    body = "#{UrlIssueState.render_marker(state.fetch("key"))}\n#{UrlIssueState.render_state(state)}"

    assert_equal state, UrlIssueState.parse_issue(body)
  end

  def test_rejects_missing_or_duplicate_protocol_elements
    state = UrlIssueState.next_failure_state(previous: nil, current: current)
    marker = UrlIssueState.render_marker(state.fetch("key"))
    rendered = UrlIssueState.render_state(state)

    assert_raises(UrlIssueState::InvalidState) { UrlIssueState.parse_issue(rendered) }
    assert_raises(UrlIssueState::InvalidState) { UrlIssueState.parse_issue(marker) }
    assert_raises(UrlIssueState::InvalidState) { UrlIssueState.parse_issue("#{marker}\n#{marker}\n#{rendered}") }
    assert_raises(UrlIssueState::InvalidState) { UrlIssueState.parse_issue("#{marker}\n#{rendered}\n#{rendered}") }
  end

  def test_rejects_noncanonical_url_and_mismatched_key
    state = UrlIssueState.next_failure_state(previous: nil, current: current)
    state["normalized_url"] = "HTTPS://EXAMPLE.COM:443/"
    assert_raises(UrlIssueState::InvalidState) { UrlIssueState.render_state(state) }

    state = current("key" => "0" * 20)
    assert_raises(UrlIssueState::InvalidState) { UrlIssueState.next_failure_state(previous: nil, current: state) }
  end

  def test_increments_only_for_the_same_target
    previous = UrlIssueState.next_failure_state(previous: nil, current: current)
    assert_equal 2, UrlIssueState.next_failure_state(previous: previous, current: current).fetch("consecutive_failures")

    changed = current("normalized_url" => "https://example.org/", "key" => UrlCheck.key_for("main", "https://example.org/"))
    assert_equal 1, UrlIssueState.next_failure_state(previous: previous, current: changed).fetch("consecutive_failures")
  end

  def test_main_and_icon_have_different_keys
    refute_equal UrlCheck.key_for("main", "https://example.com/"), UrlCheck.key_for("icon", "https://example.com/")
  end
end
