# frozen_string_literal: true

require "minitest/autorun"
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

  def state(count: 3, kind: "main", url: "https://example.com/")
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
      [state(count: 2), { "category" => "server_error", "status" => 503 }],
      [state(kind: "icon"), { "category" => "server_error", "status" => 503 }],
      [state, { "category" => "ok", "status" => 200 }],
      [state, { "category" => "client_error", "status" => 401 }],
      [state, { "category" => "network_error", "status" => nil, "error" => "host did not resolve" }],
      [state, { "category" => "timeout", "status" => nil, "error" => "execution expired" }],
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
