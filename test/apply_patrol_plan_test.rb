# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"
require_relative "../scripts/apply_patrol_plan"

class ApplyPatrolPlanTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/apply_patrol_plan.rb", __dir__)

  # Alpha carries an icon sub-entry, Beta has no icons, Gamma's icons.info
  # holds a complete ri-exchange-line replacement profile. Deliberately mixes
  # quoting styles (quoted main url, plain icon url) and a trailing comment,
  # matching the real _data/sites.yml idioms.
  FIXTURE = <<~YAML
    - name: "Category"
      links:
        - title: "Alpha"
          url: "https://alpha.example.com/"
          description: "Alpha site" # 中文注释
          logo: "alpha.svg"
          icons:
            info:
              - icon: ri-book-2-line
                title: "Alpha docs"
                url: https://docs.alpha.example.com/ # docs
        - title: "Beta"
          url: https://beta.example.com/
          logo: "beta.svg"
        - title: "Gamma"
          url: https://gamma.example.com/
          logo: "gamma.svg"
          icons:
            info:
              - icon: ri-exchange-line
                title: "Gamma new"
                url: https://gamma-new.example.com/
                description: "New home"
                logo: "gamma-new.svg"
  YAML

  DEFAULT_LOGOS = %w[alpha.svg beta.svg gamma.svg gamma-new.svg].freeze

  ALPHA_MAIN = UrlCheck.key_for("main", "https://alpha.example.com/")
  ALPHA_DOCS_ICON = UrlCheck.key_for("icon", "https://docs.alpha.example.com/")
  BETA_MAIN = UrlCheck.key_for("main", "https://beta.example.com/")
  GAMMA_MAIN = UrlCheck.key_for("main", "https://gamma.example.com/")

  def with_sites(logos: DEFAULT_LOGOS, content: FIXTURE)
    Dir.mktmpdir do |directory|
      sites = File.join(directory, "sites.yml")
      logo_dir = File.join(directory, "logos")
      Dir.mkdir(logo_dir)
      File.binwrite(sites, content)
      logos.each { |name| File.binwrite(File.join(logo_dir, name), "<svg>#{name}</svg>") }
      yield sites, logo_dir, directory
    end
  end

  def run_plan(sites, logo_dir, directory, actions, dry_run: false)
    plan_path = File.join(directory, "plan.json")
    File.binwrite(plan_path, JSON.generate("actions" => actions))
    ApplyPatrolPlan.new(
      plan_path: plan_path, sites_path: sites, logo_dir: logo_dir, dry_run: dry_run
    ).call
  end

  def outcome_for(output, key)
    output.fetch("results").find { |result| result.fetch("key") == key }
  end

  def assert_logos(logo_dir, present, absent)
    present.each { |name| assert File.file?(File.join(logo_dir, name)), "expected #{name} to survive" }
    absent.each { |name| refute File.exist?(File.join(logo_dir, name)), "expected #{name} to be gone" }
  end

  def test_replaces_a_main_url_preserving_format_and_quoting
    with_sites do |sites, logo_dir, directory|
      output = run_plan(sites, logo_dir, directory,
                        [{ "key" => ALPHA_MAIN, "action" => "replace_url",
                           "suggested_url" => "https://Alpha-New.Example.com:443/" }])

      result = output.fetch("results").first
      assert_equal "success", result.fetch("outcome"), result.fetch("detail")
      assert_equal 1, output.fetch("summary").fetch("success")
      assert_equal 0, output.fetch("summary").fetch("error")

      link = YAML.safe_load(File.binread(sites), permitted_classes: [], aliases: false).first.fetch("links").first
      assert_equal "https://alpha-new.example.com/", link.fetch("url")
      # The quoted style and every other byte of the file are preserved.
      expected = FIXTURE.sub('url: "https://alpha.example.com/"', 'url: "https://alpha-new.example.com/"')
      assert_equal expected.b, File.binread(sites)
    end
  end

  def test_replaces_only_the_icon_url
    with_sites do |sites, logo_dir, directory|
      output = run_plan(sites, logo_dir, directory,
                        [{ "key" => ALPHA_DOCS_ICON, "action" => "replace_url",
                           "suggested_url" => "https://docs2.alpha.example.com/" }])

      result = output.fetch("results").first
      assert_equal "success", result.fetch("outcome"), result.fetch("detail")

      data = YAML.safe_load(File.binread(sites), permitted_classes: [], aliases: false)
      link = data.first.fetch("links").first
      assert_equal "https://alpha.example.com/", link.fetch("url")
      icon = link.fetch("icons").fetch("info").first
      assert_equal "https://docs2.alpha.example.com/", icon.fetch("url")
      assert_equal "Alpha docs", icon.fetch("title")
      # The trailing comment on the icon url line survives untouched.
      expected = FIXTURE.sub("url: https://docs.alpha.example.com/", "url: https://docs2.alpha.example.com/")
      assert_equal expected.b, File.binread(sites)
    end
  end

  def test_rejects_invalid_suggested_urls_without_touching_the_file
    ["ftp://alpha.example.com/", "https://has space.example.com/", "javascript:alert(1)"].each do |suggested|
      with_sites do |sites, logo_dir, directory|
        output = run_plan(sites, logo_dir, directory,
                          [{ "key" => ALPHA_MAIN, "action" => "replace_url", "suggested_url" => suggested }])

        result = output.fetch("results").first
        assert_equal "error", result.fetch("outcome"), suggested
        assert_includes result.fetch("detail"), "suggested_url"
        assert_equal 1, output.fetch("summary").fetch("error")
        assert_equal FIXTURE.b, File.binread(sites)
        assert_logos(logo_dir, DEFAULT_LOGOS, [])
      end
    end
  end

  def test_removes_a_main_entry_and_orphans_its_logo
    with_sites do |sites, logo_dir, directory|
      output = run_plan(sites, logo_dir, directory, [{ "key" => BETA_MAIN, "action" => "remove" }])

      result = output.fetch("results").first
      assert_equal "success", result.fetch("outcome"), result.fetch("detail")
      assert_equal "beta.svg", result.fetch("logo_removed")
      refute_includes result.fetch("detail"), "warn"
      titles = YAML.safe_load(File.binread(sites), permitted_classes: [], aliases: false)
                    .first.fetch("links").map { |link| link.fetch("title") }
      assert_equal ["Alpha", "Gamma"], titles
      assert_logos(logo_dir, %w[alpha.svg gamma.svg gamma-new.svg], %w[beta.svg])
    end
  end

  def test_removing_a_main_with_a_replacement_profile_warns_but_still_removes
    with_sites do |sites, logo_dir, directory|
      output = run_plan(sites, logo_dir, directory, [{ "key" => GAMMA_MAIN, "action" => "remove" }])

      result = output.fetch("results").first
      assert_equal "success", result.fetch("outcome"), result.fetch("detail")
      assert_includes result.fetch("detail"), "warn"
      assert_includes result.fetch("detail"), "replacement"
      titles = YAML.safe_load(File.binread(sites), permitted_classes: [], aliases: false)
                    .first.fetch("links").map { |link| link.fetch("title") }
      assert_equal ["Alpha", "Beta"], titles
      # The promoted profile's own logo is not this script's concern.
      assert_logos(logo_dir, %w[alpha.svg beta.svg gamma-new.svg], %w[gamma.svg])
    end
  end

  def test_removing_a_main_keeps_a_logo_shared_by_another_entry
    content = <<~YAML
      - name: "Category"
        links:
          - title: "Shared"
            url: "https://shared.example.com/"
            logo: "shared.svg"
          - title: "Other"
            url: https://other.example.com/
            logo: "shared.svg"
    YAML
    with_sites(logos: %w[shared.svg], content: content) do |sites, logo_dir, directory|
      shared_key = UrlCheck.key_for("main", "https://shared.example.com/")
      output = run_plan(sites, logo_dir, directory, [{ "key" => shared_key, "action" => "remove" }])

      result = output.fetch("results").first
      assert_equal "success", result.fetch("outcome"), result.fetch("detail")
      assert_nil result.fetch("logo_removed")
      titles = YAML.safe_load(File.binread(sites), permitted_classes: [], aliases: false)
                    .first.fetch("links").map { |link| link.fetch("title") }
      assert_equal ["Other"], titles
      assert_logos(logo_dir, %w[shared.svg], [])
    end
  end

  def test_removes_only_the_icon_element
    with_sites do |sites, logo_dir, directory|
      output = run_plan(sites, logo_dir, directory, [{ "key" => ALPHA_DOCS_ICON, "action" => "remove" }])

      result = output.fetch("results").first
      assert_equal "success", result.fetch("outcome"), result.fetch("detail")
      assert_nil result.fetch("logo_removed")

      data = YAML.safe_load(File.binread(sites), permitted_classes: [], aliases: false)
      link = data.first.fetch("links").first
      assert_equal "Alpha", link.fetch("title")
      assert_equal "https://alpha.example.com/", link.fetch("url")
      assert_nil link.fetch("icons").fetch("info")
    end
  end

  def test_defer_touches_nothing
    with_sites do |sites, logo_dir, directory|
      output = run_plan(sites, logo_dir, directory, [{ "key" => BETA_MAIN, "action" => "defer" }])

      result = output.fetch("results").first
      assert_equal "deferred", result.fetch("outcome")
      assert_equal 1, output.fetch("summary").fetch("deferred")
      assert_equal FIXTURE.b, File.binread(sites)
      assert_logos(logo_dir, DEFAULT_LOGOS, [])
    end
  end

  def test_applies_serial_removes_after_lines_shift
    with_sites do |sites, logo_dir, directory|
      output = run_plan(sites, logo_dir, directory,
                        [{ "key" => BETA_MAIN, "action" => "remove" }, { "key" => GAMMA_MAIN, "action" => "remove" }])

      assert_equal %w[success success], output.fetch("results").map { |result| result.fetch("outcome") }
      titles = YAML.safe_load(File.binread(sites), permitted_classes: [], aliases: false)
                    .first.fetch("links").map { |link| link.fetch("title") }
      assert_equal ["Alpha"], titles
      assert_logos(logo_dir, %w[alpha.svg gamma-new.svg], %w[beta.svg gamma.svg])
    end
  end

  def test_unknown_and_duplicate_keys_error_without_blocking_other_actions
    with_sites do |sites, logo_dir, directory|
      output = run_plan(sites, logo_dir, directory, [
                          { "key" => "0123456789abcdef0123", "action" => "remove" },
                          { "key" => BETA_MAIN, "action" => "remove" },
                          { "key" => BETA_MAIN, "action" => "remove" }
                        ])

      assert_equal "error", output.fetch("results")[0].fetch("outcome")
      assert_equal "success", output.fetch("results")[1].fetch("outcome")
      assert_equal "error", output.fetch("results")[2].fetch("outcome")
      assert_equal 2, output.fetch("summary").fetch("error")
      assert_equal 1, output.fetch("summary").fetch("success")
      titles = YAML.safe_load(File.binread(sites), permitted_classes: [], aliases: false)
                    .first.fetch("links").map { |link| link.fetch("title") }
      assert_equal ["Alpha", "Gamma"], titles
      assert_logos(logo_dir, %w[alpha.svg gamma.svg gamma-new.svg], %w[beta.svg])
    end
  end

  def test_ambiguous_key_errors_without_modifying_the_file
    content = FIXTURE + <<~YAML
      - name: "Category"
        links:
          - title: "Alpha twin"
            url: "https://alpha.example.com/"
            logo: "alpha.svg"
    YAML
    with_sites(content: content) do |sites, logo_dir, directory|
      output = run_plan(sites, logo_dir, directory, [{ "key" => ALPHA_MAIN, "action" => "remove" }])

      result = output.fetch("results").first
      assert_equal "error", result.fetch("outcome")
      assert_includes result.fetch("detail"), "navigation entries"
      assert_includes result.fetch("detail"), "manual splitting in sites.yml"
      assert_equal content.b, File.binread(sites)
    end
  end

  def test_dry_run_reports_changes_without_modifying_anything
    with_sites do |sites, logo_dir, directory|
      output = run_plan(sites, logo_dir, directory, [
                          { "key" => ALPHA_MAIN, "action" => "replace_url",
                            "suggested_url" => "https://alpha-new.example.com/" },
                          { "key" => BETA_MAIN, "action" => "remove" },
                          { "key" => GAMMA_MAIN, "action" => "defer" }
                        ], dry_run: true)

      outcomes = output.fetch("results").map { |result| result.fetch("outcome") }
      assert_equal %w[dry_run dry_run deferred], outcomes
      assert_equal 2, output.fetch("summary").fetch("dry_run")
      replaced = output.fetch("results").first
      assert_includes replaced.fetch("detail"), "https://alpha-new.example.com/"
      assert_includes replaced.fetch("detail"), "https://alpha.example.com/"
      assert_equal 0, output.fetch("summary").fetch("error")
      assert_equal FIXTURE.b, File.binread(sites)
      assert_logos(logo_dir, DEFAULT_LOGOS, [])
    end
  end

  def test_cli_dry_run_smoke
    with_sites do |sites, logo_dir, directory|
      plan_path = File.join(directory, "plan.json")
      File.binwrite(plan_path, JSON.generate("actions" => [
        { "key" => ALPHA_MAIN, "action" => "replace_url", "suggested_url" => "https://alpha-new.example.com/" },
        { "key" => BETA_MAIN, "action" => "remove" }
      ]))

      stdout, _stderr, status = Open3.capture3("ruby", SCRIPT, "--plan", plan_path, "--sites", sites,
                                               "--logo-dir", logo_dir, "--dry-run")

      assert status.success?, "expected exit 0, got #{status.exitstatus}: #{stdout}"
      parsed = JSON.parse(stdout)
      assert_equal 2, parsed.fetch("results").length
      assert_equal 2, parsed.fetch("summary").fetch("dry_run")
      assert_equal FIXTURE.b, File.binread(sites)
      assert_logos(logo_dir, DEFAULT_LOGOS, [])
    end
  end

  def test_cli_exits_nonzero_when_any_action_errors
    with_sites do |sites, logo_dir, directory|
      plan_path = File.join(directory, "plan.json")
      File.binwrite(plan_path, JSON.generate("actions" => [{ "key" => "deadbeefdeadbeefdead", "action" => "remove" }]))

      stdout, _stderr, status = Open3.capture3("ruby", SCRIPT, "--plan", plan_path, "--sites", sites,
                                               "--logo-dir", logo_dir)

      refute status.success?, "expected non-zero exit, got success: #{stdout}"
      parsed = JSON.parse(stdout)
      assert_equal "error", parsed.fetch("results").first.fetch("outcome")
      assert_equal 1, parsed.fetch("summary").fetch("error")
      assert_equal FIXTURE.b, File.binread(sites)
    end
  end

  def test_cli_reports_an_error_for_a_missing_or_malformed_plan
    Dir.mktmpdir do |directory|
      sites = File.join(directory, "sites.yml")
      logo_dir = File.join(directory, "logos")
      Dir.mkdir(logo_dir)
      File.binwrite(sites, FIXTURE)
      malformed = File.join(directory, "plan.json")
      File.binwrite(malformed, "{not json")

      stdout, _stderr, status = Open3.capture3("ruby", SCRIPT, "--plan", malformed, "--sites", sites,
                                               "--logo-dir", logo_dir)

      refute status.success?
      assert_equal "error", JSON.parse(stdout).fetch("result")
    end
  end
end
