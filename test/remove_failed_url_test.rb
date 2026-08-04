# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"
require_relative "../scripts/remove_failed_url"

class UrlRemovalProcessorTest < Minitest::Test
  Checker = Struct.new(:result) do
    def check(_entry)
      raise result if result.is_a?(Exception)

      result
    end
  end

  def setup
    @data = [
      { "name" => "Category", "links" => [
        { "title" => "Remove", "url" => "https://example.com/", "logo" => "remove.svg" },
        { "title" => "Keep", "url" => "https://example.org/", "logo" => "keep.svg" }
      ] }
    ]
  end

  def state(count: UrlIssueState::FAILURE_THRESHOLD, kind: "main", url: "https://example.com/")
    current = {
      "key" => UrlCheck.key_for(kind, url), "kind" => kind, "normalized_url" => url,
      "checked_at" => "2026-07-30T12:00:00Z", "run_id" => "123",
      "category" => "server_error", "status" => 503, "error" => nil
    }
    state = UrlIssueState.next_failure_state(previous: nil, current: current)
    state["consecutive_failures"] = count
    state
  end

  def issue_body(value)
    "#{UrlIssueState.render_marker(value.fetch("key"))}\n#{UrlIssueState.render_state(value)}"
  end

  def with_sites(content: YAML.dump(@data))
    Dir.mktmpdir do |directory|
      path = File.join(directory, "sites.yml")
      File.write(path, content)
      yield path
    end
  end

  def processor(path, value: state, result: { "category" => "server_error", "status" => 503 })
    UrlRemovalProcessor.new(issue_body: issue_body(value), sites_path: path, checker: Checker.new(result))
  end

  def test_removes_the_single_persistently_unhealthy_main_entry
    with_sites do |path|
      output = processor(path).call

      assert_equal "removed", output.fetch("result")
      links = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links")
      assert_equal ["Keep"], links.map { |link| link.fetch("title") }
    end
  end

  # Failures whose status is nil (timeout, network_error, invalid_url) must be
  # removable too: the URL checker emits them without an HTTP status, and they
  # are exactly the persistent-failure categories that url-check.yml files
  # removal issues for. Reproduces issue #71 (a URL timing out for 8 checks).
  def test_removes_persistently_failing_url_without_an_http_status
    failure_results = [
      { "category" => "timeout", "status" => nil, "error" => "execution expired" },
      { "category" => "network_error", "status" => nil, "error" => "host did not resolve" },
      { "category" => "invalid_url", "status" => nil, "error" => "bad URI" }
    ]

    failure_results.each do |result|
      with_sites do |path|
        output = processor(path, result: result).call

        assert_equal "removed", output.fetch("result"), "expected #{result["category"]} to be removed"
        links = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links")
        assert_equal ["Keep"], links.map { |link| link.fetch("title") }
      end
    end
  end

  def test_preserves_all_non_target_bytes_when_removing_a_record
    source = <<~YAML
      - name: "Category"
        links:
          - title: "Remove"
            url: "https://example.com/"
            logo: 'remove.svg'

          - title: Keep # unchanged comment
            url: https://example.org/
            logo: keep.svg
    YAML

    with_sites(content: source) do |path|
      output = processor(path).call

      assert_equal "removed", output.fetch("result")
      target = "    - title: \"Remove\"\n" \
        "      url: \"https://example.com/\"\n" \
        "      logo: 'remove.svg'\n\n"
      expected = source.sub(target, "").b
      assert_equal expected, File.binread(path)
    end
  end

  def test_no_op_conditions_do_not_modify_the_file
    cases = [
      [state(count: UrlIssueState::FAILURE_THRESHOLD - 1), { "category" => "server_error", "status" => 503 }],
      [state(kind: "icon"), { "category" => "server_error", "status" => 503 }],
      [state, { "category" => "ok", "status" => 200 }],
      [state, { "category" => "client_error", "status" => 401 }],
      [state, RuntimeError.new("network unavailable")]
    ]

    cases.each do |value, result|
      with_sites do |path|
        before = File.binread(path)
        output = processor(path, value: value, result: result).call

        assert_equal "not_removed", output.fetch("result")
        assert_equal before, File.binread(path)
      end
    end
  end

  def test_sub_threshold_failure_message_mentions_the_threshold
    with_sites do |path|
      output = processor(path, value: state(count: UrlIssueState::FAILURE_THRESHOLD - 1)).call

      assert_equal "not_removed", output.fetch("result")
      assert_includes output.fetch("message"), UrlIssueState::FAILURE_THRESHOLD.to_s
    end
  end

  def test_ambiguous_current_entries_do_not_modify_the_file
    @data.first.fetch("links") << { "title" => "Duplicate", "url" => "https://example.com/", "logo" => "duplicate.svg" }
    with_sites do |path|
      before = File.binread(path)
      output = processor(path).call

      assert_equal "not_removed", output.fetch("result")
      assert_equal before, File.binread(path)
    end
  end

  def test_invalid_protocol_raises_without_modifying_the_file
    with_sites do |path|
      before = File.binread(path)
      assert_raises(UrlIssueState::InvalidState) do
        UrlRemovalProcessor.new(issue_body: "not a protocol", sites_path: path, checker: Checker.new({})).call
      end
      assert_equal before, File.binread(path)
    end
  end
end

class UrlRemovalCliExitCodeTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/remove_failed_url.rb", __dir__)

  def setup
    @data = [{ "name" => "Category", "links" => [
      { "title" => "Keep", "url" => "https://example.org/", "logo" => "keep.svg" }
    ] }]
  end

  def test_invalid_state_is_not_removed_and_exits_zero
    # Reproduces a legacy issue body: a single URL marker but no url-check-state marker.
    body = "<!-- url-check:22ba0cb0d5340770cdf1 -->\nAutomated URL check detected a failure."

    Dir.mktmpdir do |directory|
      sites = File.join(directory, "sites.yml")
      input = File.join(directory, "issue-body")
      File.write(sites, YAML.dump(@data))
      File.write(input, body)

      output, status = run_cli("--input", input, "--sites", sites)

      assert status.success?, "expected exit 0, got #{status.exitstatus}: #{output}"
      parsed = JSON.parse(output)
      assert_equal "not_removed", parsed.fetch("result")
      assert_equal "expected exactly one URL check state", parsed.fetch("message")
      assert_equal YAML.dump(@data), File.binread(sites)
    end
  end

  def test_missing_input_argument_exits_one
    output, status = run_cli("--sites", "/dev/null")

    refute status.success?, "expected non-zero exit, got success: #{output}"
    assert_equal "error", JSON.parse(output).fetch("result")
  end

  def run_cli(*args)
    stdout, _stderr, status = Open3.capture3("ruby", SCRIPT, *args)
    [stdout, status]
  end
end
