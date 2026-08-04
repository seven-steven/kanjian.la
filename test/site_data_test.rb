# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/site_data"

class SiteDataTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)

  def test_reads_nested_sites
    sites = SiteData.read(File.join(FIXTURES, "sites.yml"))

    assert_equal 2, sites.length
    assert_equal ["测试分类"], sites.first.category
    assert_equal "标准站点", sites.first.title
    assert_equal "https://example.com/", sites.first.url
  end

  def test_validates_http_urls
    assert SiteData.valid_http_url?("https://example.com/path")
    refute SiteData.valid_http_url?("example.com")
    refute SiteData.valid_http_url?("ftp://example.com")
  end

  def test_validates_internationalized_domain_names
    # Unicode IDN and its Punycode form must both be accepted.
    assert SiteData.valid_http_url?("https://教父.com")
    assert SiteData.valid_http_url?("https://xn--wcv59z.com")

    # A bare filename is not a URL, regardless of IDN support.
    refute SiteData.valid_http_url?("midjourney.com.svg")
    refute SiteData.valid_http_url?("")
  end

  def test_rejects_unsafe_logo_names
    assert SiteData.safe_logo_name?("example.svg")
    refute SiteData.safe_logo_name?("../example.svg")
    refute SiteData.safe_logo_name?("folder/example.svg")
  end
end
