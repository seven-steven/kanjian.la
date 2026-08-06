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

  def with_sites(content: YAML.dump(@data), logos: {})
    Dir.mktmpdir do |directory|
      path = File.join(directory, "sites.yml")
      logo_dir = File.join(directory, "logos")
      Dir.mkdir(logo_dir)
      File.write(path, content)
      logos.each { |name, body| File.binwrite(File.join(logo_dir, name), body) }
      yield path, logo_dir
    end
  end

  def processor(path, logo_dir:, value: state, result: { "category" => "server_error", "status" => 503 })
    UrlRemovalProcessor.new(issue_body: issue_body(value), sites_path: path, logo_dir: logo_dir, checker: Checker.new(result))
  end

  def test_removes_the_single_persistently_unhealthy_main_entry
    with_sites do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir).call

      assert_equal "removed", output.fetch("result")
      # The default fixture creates no logo file, so the orphan deletion is a
      # no-op; removed_logo stays nil rather than failing the removal.
      assert_nil output.fetch("removed_logo")
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
      with_sites do |path, logo_dir|
        output = processor(path, logo_dir: logo_dir, result: result).call

        assert_equal "removed", output.fetch("result"), "expected #{result["category"]} to be removed"
        links = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links")
        assert_equal ["Keep"], links.map { |link| link.fetch("title") }
      end
    end
  end

  def test_removes_a_single_failing_info_icon_leaving_the_site_intact
    @data = [
      { "name" => "Category", "links" => [
        { "title" => "Site", "url" => "https://example.org/", "logo" => "keep.svg",
          "icons" => { "info" => [
            { "icon" => "ri-exchange-line", "title" => "Dead", "url" => "https://dead.example.com/" },
            { "icon" => "ri-book-2-line", "title" => "Docs", "url" => "https://docs.example.org/" }
          ] } }
      ] }
    ]
    icon_state = state(kind: "icon", url: "https://dead.example.com/")
    with_sites do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir, value: icon_state).call

      assert_equal "removed", output.fetch("result")
      assert_nil output.fetch("removed_logo")
      link = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links").first
      # The site itself survives; only the dead icon entry is removed.
      assert_equal "Site", link.fetch("title")
      assert_equal "https://example.org/", link.fetch("url")
      remaining = link.fetch("icons").fetch("info")
      assert_equal ["Docs"], remaining.map { |icon| icon.fetch("title") }
    end
  end

  def test_removes_a_failing_status_icon_entry
    @data = [
      { "name" => "Category", "links" => [
        { "title" => "Site", "url" => "https://example.org/",
          "icons" => { "status" => [{ "icon" => "ri-money-circle-line", "title" => "Dead", "url" => "https://dead.example.com/" }] } }
      ] }
    ]
    icon_state = state(kind: "icon", url: "https://dead.example.com/")
    with_sites do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir, value: icon_state).call

      assert_equal "removed", output.fetch("result")
      link = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links").first
      # Removing the only status icon leaves the `status:` key with no entries,
      # which YAML parses back as nil — the site itself is untouched.
      assert_nil link.fetch("icons").fetch("status")
    end
  end

  def test_removes_a_failing_icon_in_a_legacy_icons_array
    @data = [
      { "name" => "Category", "links" => [
        { "title" => "Site", "url" => "https://example.org/",
          "icons" => [{ "icon" => "ri-exchange-line", "title" => "Dead", "url" => "https://dead.example.com/" }] }
      ] }
    ]
    icon_state = state(kind: "icon", url: "https://dead.example.com/")
    with_sites do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir, value: icon_state).call

      assert_equal "removed", output.fetch("result")
      link = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links").first
      # The legacy `icons:` array is now empty, which parses back as nil.
      assert_nil link.fetch("icons")
    end
  end

  def test_removing_an_icon_preserves_all_surrounding_bytes
    source = <<~YAML
      - name: "Category"
        links:
          - title: "Site"
            url: https://example.org/
            icons:
              info:
                - icon: ri-exchange-line
                  title: "Dead"
                  url: https://dead.example.com/
                - icon: ri-book-2-line # keep this comment
                  title: Docs
                  url: https://docs.example.org/
    YAML
    icon_state = state(kind: "icon", url: "https://dead.example.com/")
    with_sites(content: source) do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir, value: icon_state).call

      assert_equal "removed", output.fetch("result")
      target = "          - icon: ri-exchange-line\n" \
        "            title: \"Dead\"\n" \
        "            url: https://dead.example.com/\n"
      expected = source.sub(target, "").b
      assert_equal expected, File.binread(path)
    end
  end

  def test_removing_an_icon_does_not_delete_a_logo_still_used_by_its_site
    # The icon shares the site's logo; removing the icon must not orphan it.
    @data = [
      { "name" => "Category", "links" => [
        { "title" => "Site", "url" => "https://example.org/", "logo" => "shared.svg",
          "icons" => { "info" => [{ "icon" => "ri-exchange-line", "title" => "Dead", "url" => "https://dead.example.com/" }] } }
      ] }
    ]
    icon_state = state(kind: "icon", url: "https://dead.example.com/")
    with_sites(logos: { "shared.svg" => "svg" }) do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir, value: icon_state).call

      assert_equal "removed", output.fetch("result")
      assert_nil output.fetch("removed_logo")
      assert File.file?(File.join(logo_dir, "shared.svg"))
    end
  end

  def test_removing_an_icon_orphans_its_own_unique_logo
    @data = [
      { "name" => "Category", "links" => [
        { "title" => "Site", "url" => "https://example.org/", "logo" => "site.svg",
          "icons" => { "info" => [{ "icon" => "ri-exchange-line", "title" => "Dead", "url" => "https://dead.example.com/", "logo" => "icon-only.svg" }] } }
      ] }
    ]
    icon_state = state(kind: "icon", url: "https://dead.example.com/")
    with_sites(logos: { "site.svg" => "svg", "icon-only.svg" => "svg" }) do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir, value: icon_state).call

      assert_equal "removed", output.fetch("result")
      assert_equal "icon-only.svg", output.fetch("removed_logo")
      refute File.exist?(File.join(logo_dir, "icon-only.svg"))
      assert File.file?(File.join(logo_dir, "site.svg"))
    end
  end

  def test_icon_failure_below_threshold_is_not_removed
    @data = [
      { "name" => "Category", "links" => [
        { "title" => "Site", "url" => "https://example.org/",
          "icons" => { "info" => [{ "icon" => "ri-exchange-line", "title" => "Dead", "url" => "https://dead.example.com/" }] } }
      ] }
    ]
    icon_state = state(kind: "icon", url: "https://dead.example.com/", count: UrlIssueState::FAILURE_THRESHOLD - 1)
    with_sites do |path, logo_dir|
      before = File.binread(path)
      output = processor(path, logo_dir: logo_dir, value: icon_state).call

      assert_equal "not_removed", output.fetch("result")
      assert_equal before, File.binread(path)
    end
  end

  def test_ambiguous_icon_entries_do_not_modify_the_file
    @data = [
      { "name" => "Category", "links" => [
        { "title" => "Site", "url" => "https://example.org/",
          "icons" => { "info" => [
            { "icon" => "ri-exchange-line", "title" => "First", "url" => "https://dead.example.com/" },
            { "icon" => "ri-exchange-line", "title" => "Duplicate", "url" => "https://dead.example.com/" }
          ] } }
      ] }
    ]
    icon_state = state(kind: "icon", url: "https://dead.example.com/")
    with_sites do |path, logo_dir|
      before = File.binread(path)
      output = processor(path, logo_dir: logo_dir, value: icon_state).call

      assert_equal "not_removed", output.fetch("result")
      assert_equal before, File.binread(path)
    end
  end

  def test_removing_an_icon_under_a_sub_section
    @data = [
      { "name" => "Top", "sub" => [
        { "name" => "Inner", "links" => [
          { "title" => "Site", "url" => "https://example.org/",
            "icons" => { "info" => [{ "icon" => "ri-exchange-line", "title" => "Dead", "url" => "https://dead.example.com/" }] } }
        ] }
      ] }
    ]
    icon_state = state(kind: "icon", url: "https://dead.example.com/")
    with_sites do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir, value: icon_state).call

      assert_equal "removed", output.fetch("result")
      link = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("sub").first.fetch("links").first
      assert_nil link.fetch("icons").fetch("info")
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

    with_sites(content: source) do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir).call

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
      [state, { "category" => "ok", "status" => 200 }],
      [state, { "category" => "client_error", "status" => 401 }],
      [state, RuntimeError.new("network unavailable")]
    ]

    cases.each do |value, result|
      with_sites do |path, logo_dir|
        before = File.binread(path)
        output = processor(path, logo_dir: logo_dir, value: value, result: result).call

        assert_equal "not_removed", output.fetch("result")
        assert_equal before, File.binread(path)
      end
    end
  end

  def test_sub_threshold_failure_message_mentions_the_threshold
    with_sites do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir, value: state(count: UrlIssueState::FAILURE_THRESHOLD - 1)).call

      assert_equal "not_removed", output.fetch("result")
      assert_includes output.fetch("message"), UrlIssueState::FAILURE_THRESHOLD.to_s
    end
  end

  def test_ambiguous_current_entries_do_not_modify_the_file
    @data.first.fetch("links") << { "title" => "Duplicate", "url" => "https://example.com/", "logo" => "duplicate.svg" }
    with_sites do |path, logo_dir|
      before = File.binread(path)
      output = processor(path, logo_dir: logo_dir).call

      assert_equal "not_removed", output.fetch("result")
      assert_equal before, File.binread(path)
    end
  end

  def test_invalid_protocol_raises_without_modifying_the_file
    with_sites do |path, logo_dir|
      before = File.binread(path)
      assert_raises(UrlIssueState::InvalidState) do
        UrlRemovalProcessor.new(issue_body: "not a protocol", sites_path: path, logo_dir: logo_dir, checker: Checker.new({})).call
      end
      assert_equal before, File.binread(path)
    end
  end

  def test_removes_an_unreferenced_logo_after_removing_its_only_entry
    with_sites(logos: { "remove.svg" => "svg", "keep.svg" => "keep" }) do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir).call

      assert_equal "removed", output.fetch("result")
      assert_equal "remove.svg", output.fetch("removed_logo")
      refute File.exist?(File.join(logo_dir, "remove.svg"))
      assert File.exist?(File.join(logo_dir, "keep.svg"))
      links = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links")
      assert_equal ["Keep"], links.map { |link| link.fetch("title") }
    end
  end

  def test_preserves_a_logo_still_referenced_by_another_entry
    # The surviving entry also points at remove.svg, so it is shared and must
    # not be deleted even though the removed entry was its first referencer.
    @data.first.fetch("links").last["logo"] = "remove.svg"
    with_sites(logos: { "remove.svg" => "svg" }) do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir).call

      assert_equal "removed", output.fetch("result")
      assert_nil output.fetch("removed_logo")
      assert File.file?(File.join(logo_dir, "remove.svg"))
      remaining = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links")
      assert_equal ["Keep"], remaining.map { |link| link.fetch("title") }
      assert_equal "remove.svg", remaining.first.fetch("logo")
    end
  end

  def test_removes_entry_when_its_unreferenced_logo_file_is_already_missing
    with_sites(logos: { "keep.svg" => "keep" }) do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir).call

      assert_equal "removed", output.fetch("result")
      assert_nil output.fetch("removed_logo")
      refute File.exist?(File.join(logo_dir, "remove.svg"))
      assert File.file?(File.join(logo_dir, "keep.svg"))
      links = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links")
      assert_equal ["Keep"], links.map { |link| link.fetch("title") }
    end
  end

  def test_raises_when_an_existing_unreferenced_logo_cannot_be_deleted
    with_sites do |path, logo_dir|
      # Make the logo path a non-empty directory: File.delete on a non-empty
      # directory raises Errno::ENOTEMPTY (a SystemCallError, not ENOENT), so
      # the post-write failure surfaces as an error instead of being swallowed
      # into a misleading "not_removed". No mocking — real filesystem behavior.
      logo_path = File.join(logo_dir, "remove.svg")
      Dir.mkdir(logo_path)
      File.write(File.join(logo_path, "occupant"), "blocks deletion")

      error = assert_raises(RuntimeError) { processor(path, logo_dir: logo_dir).call }
      assert_includes error.message, "remove.svg"

      # The site record is still removed (sites.yml was written before the logo step).
      links = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links")
      assert_equal ["Keep"], links.map { |link| link.fetch("title") }
      assert File.directory?(logo_path)
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
