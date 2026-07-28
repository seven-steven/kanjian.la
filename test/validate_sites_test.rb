# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"

class ValidateSitesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FIXTURES = File.join(__dir__, "fixtures")

  def test_accepts_valid_data_and_warns_for_legacy_icons
    Dir.mktmpdir do |logos|
      File.write(File.join(logos, "example.svg"), "svg")
      File.write(File.join(logos, "example.png"), "png")
      output, status = run_validator("sites.yml", logos)

      assert status.success?, output
      assert_includes output, "warning: 测试分类 / 旧式图标: legacy icons array"
    end
  end

  def test_rejects_invalid_data
    Dir.mktmpdir do |logos|
      output, status = run_validator("invalid_sites.yml", logos)

      refute status.success?
      assert_includes output, "missing title"
      assert_includes output, "invalid url"
      assert_includes output, "invalid logo"
      assert_includes output, "unsupported icons keys extra"
      assert_includes output, "icons.status must be an array"
    end
  end

  private

  def run_validator(fixture, logos)
    Open3.capture2e(
      "ruby", File.join(ROOT, "scripts/validate_sites.rb"),
      "--data", File.join(FIXTURES, fixture), "--logos", logos
    )
  end
end
