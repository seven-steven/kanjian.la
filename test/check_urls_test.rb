# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/check_urls"

class UrlCheckTest < Minitest::Test
  Resolver = Struct.new(:addresses) do
    def getaddresses(_host)
      addresses
    end
  end

  def entry(url, kind: "main")
    { "url" => url, "kind" => kind, "title" => "Example", "path" => "links.0.url" }
  end

  def test_normalizes_scheme_host_default_port_and_fragment
    assert_equal "https://example.com/path?x=1", UrlCheck.normalize("HTTPS://EXAMPLE.COM:443/path?x=1#section")
  end

  def test_extracts_main_and_icon_http_urls_only
    data = [{ "links" => [{ "title" => "Site", "url" => "https://example.com", "icons" => { "info" => [{ "url" => "http://example.org/docs" }] } }] }]
    entries = UrlCheck.entries(data)
    assert_equal %w[main icon], entries.map { |item| item["kind"] }
    assert_equal ["https://example.com", "http://example.org/docs"], entries.map { |item| item["url"] }
  end

  def test_invalid_url_has_deterministic_key
    first = UrlCheck.new.check(entry("ftp://example.com"))
    second = UrlCheck.new.check(entry("ftp://example.com"))
    assert_equal "invalid_url", first["category"]
    assert_equal first["key"], second["key"]
  end

  def test_rejects_non_public_destination_before_request
    result = UrlCheck.new(resolver: Resolver.new(["127.0.0.1"])).check(entry("http://example.test"))
    assert_equal "invalid_url", result["category"]
    assert_match(/non-public/, result["error"])
  end

  def test_validates_timeout_and_retries
    assert_raises(ArgumentError) { UrlCheck.new(timeout: 0) }
    assert_raises(ArgumentError) { UrlCheck.new(retries: -1) }
    UrlCheck.new(timeout: 0.1, retries: 0)
  end
end
