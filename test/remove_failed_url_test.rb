# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"
require_relative "../scripts/remove_failed_url"

class UrlRemovalProcessorTest < Minitest::Test
  Checker = Struct.new(:result) do
    def check(entry)
      return result.call(entry) if result.respond_to?(:call)

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

  def test_promotes_a_single_healthy_complete_info_replacement
    @data = [
      { "name" => "Category", "links" => [
        { "title" => "Old", "url" => "https://example.com/", "description" => "Old site", "logo" => "old.svg",
          "icons" => { "status" => [{ "icon" => "ri-book-3-line", "title" => "Old status" }], "info" => [
            { "icon" => "ri-exchange-line", "title" => "New", "url" => "https://new.example.com/",
              "description" => "New site", "logo" => "new.svg", "icons" => { "info" => [{ "icon" => "ri-book-2-line", "title" => "Docs", "url" => "https://docs.new.example.com/" }] } }
          ] } }
      ] }
    ]
    healthy_replacement = lambda { |entry| entry["url"] == "https://new.example.com/" ? { "category" => "ok", "status" => 200 } : { "category" => "server_error", "status" => 503 } }
    with_sites(logos: { "old.svg" => "old", "new.svg" => "new" }) do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir, result: healthy_replacement).call

      assert_equal "promoted", output.fetch("result")
      assert_equal "https://example.com/", output.fetch("old_url")
      assert_equal "https://new.example.com/", output.fetch("new_url")
      assert_equal "Old", output.fetch("old_title")
      assert_equal "New", output.fetch("new_title")
      assert_equal "old.svg", output.fetch("old_logo")
      assert_equal "new.svg", output.fetch("new_logo")
      assert_equal "old.svg", output.fetch("removed_logo")
      link = YAML.safe_load_file(path, permitted_classes: [], aliases: false).first.fetch("links").first
      assert_equal({ "title" => "New", "url" => "https://new.example.com/", "description" => "New site", "logo" => "new.svg", "icons" => { "info" => [{ "icon" => "ri-book-2-line", "title" => "Docs", "url" => "https://docs.new.example.com/" }] } }, link)
      refute File.exist?(File.join(logo_dir, "old.svg"))
      assert File.file?(File.join(logo_dir, "new.svg"))
    end
  end

  def test_removes_main_entry_when_replacement_is_incomplete_ambiguous_or_unhealthy
    cases = [
      [{ "icon" => "ri-exchange-line", "title" => "New", "url" => "https://new.example.com/" }],
      [{ "icon" => "ri-exchange-line", "title" => "New", "url" => "https://new.example.com/", "description" => "New", "logo" => "new.svg" },
       { "icon" => "ri-exchange-line", "title" => "Other", "url" => "https://other.example.com/", "description" => "Other", "logo" => "other.svg" }],
      [{ "icon" => "ri-exchange-line", "title" => "New", "url" => "https://new.example.com/", "description" => "New", "logo" => "new.svg" }]
    ]
    cases.each_with_index do |icons, index|
      @data.first.fetch("links").first["icons"] = { "info" => icons }
      result = if index == 2
        lambda { |entry| entry["url"] == "https://example.com/" ? { "category" => "server_error", "status" => 503 } : { "category" => "server_error", "status" => 503 } }
      else
        lambda { |entry| entry["url"] == "https://example.com/" ? { "category" => "server_error", "status" => 503 } : { "category" => "ok", "status" => 200 } }
      end
      with_sites(logos: { "new.svg" => "new", "other.svg" => "other" }) do |path, logo_dir|
        output = processor(path, logo_dir: logo_dir, result: result).call

        assert_equal "removed", output.fetch("result")
      end
    end
  end

  def test_removes_main_entry_when_replacement_url_normalizes_to_the_old_url
    equivalent_urls = [
      "HTTPS://EXAMPLE.com:443#fragment",
      "https://EXAMPLE.com:443#fragment",
      "https://example.com:443/#fragment",
      "https://example.com/#fragment"
    ]
    equivalent_urls.each do |url|
      @data.first.fetch("links").first["icons"] = { "info" => [
        { "icon" => "ri-exchange-line", "title" => "Same", "url" => url,
          "description" => "Same site", "logo" => "new.svg" }
      ] }
      with_sites(logos: { "new.svg" => "new" }) do |path, logo_dir|
        output = processor(path, logo_dir: logo_dir).call

        assert_equal "removed", output.fetch("result"), url
      end
    end
  end

  def test_ignores_exchange_icons_outside_direct_info_candidates
    @data.first.fetch("links").first["icons"] = {
      "status" => [{ "icon" => "ri-exchange-line", "title" => "Status", "url" => "https://new.example.com/", "description" => "New", "logo" => "new.svg" }],
      "info" => [{ "icon" => "ri-book-2-line", "title" => "Info", "url" => "https://new.example.com/", "description" => "New", "logo" => "new.svg" }]
    }
    with_sites(logos: { "new.svg" => "new" }) do |path, logo_dir|
      output = processor(path, logo_dir: logo_dir).call

      assert_equal "removed", output.fetch("result")
    end
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

  # Only static invalid URLs and received unhealthy HTTP responses are eligible
  # for deletion. DNS, TLS and transport errors may be environmental/transient.
  def test_does_not_remove_environmental_failures
    %w[dns_error unsafe_destination tls_error timeout network_error].each do |category|
      with_sites do |path, logo_dir|
        before = File.binread(path)
        output = processor(path, logo_dir: logo_dir, result: { "category" => category, "status" => nil }).call

        assert_equal "not_removed", output.fetch("result"), "expected #{category} not to be removed"
        assert_equal before, File.binread(path)
      end
    end
  end

  def test_removes_static_invalid_url_and_received_unhealthy_http_errors
    [
      { "category" => "invalid_url", "status" => nil },
      { "category" => "client_error", "status" => 404 },
      { "category" => "server_error", "status" => 503 }
    ].each do |result|
      with_sites do |path, logo_dir|
        output = processor(path, logo_dir: logo_dir, result: result).call

        assert_equal "removed", output.fetch("result"), "expected #{result["category"]} to be removed"
      end
    end
  end

  def test_does_not_remove_healthy_access_restrictions
    [401, 403, 429].each do |status|
      with_sites do |path, logo_dir|
        before = File.binread(path)
        output = processor(path, logo_dir: logo_dir, result: { "category" => "client_error", "status" => status }).call

        assert_equal "not_removed", output.fetch("result")
        assert_equal before, File.binread(path)
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
