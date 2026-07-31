# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/check_urls"

class UrlCheckTest < Minitest::Test
  Resolver = Struct.new(:addresses) do
    def getaddresses(_host)
      addresses
    end
  end

  Http = Struct.new(:responses, :methods) do
    def start(*)
      yield self
    end

    def request(request)
      methods << request.method
      responses.shift
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

  def test_exposes_shared_key_and_healthy_helpers
    assert_equal UrlCheck.key_for("main", "https://example.com/"), UrlCheck.key_for("main", "HTTPS://EXAMPLE.COM:443/#fragment")
    refute_equal UrlCheck.key_for("main", "https://example.com/"), UrlCheck.key_for("icon", "https://example.com/")
    assert UrlCheck.healthy?("category" => "ok")
    assert UrlCheck.healthy?("category" => "client_error", "status" => 401)
    refute UrlCheck.healthy?("category" => "client_error", "status" => 404)
  end

  def test_rejects_non_public_destination_before_request
    result = UrlCheck.new(resolver: Resolver.new(["127.0.0.1"])).check(entry("http://example.test"))
    assert_equal "invalid_url", result["category"]
    assert_match(/non-public/, result["error"])
  end

  def test_falls_back_to_get_when_head_returns_not_found
    http = Http.new([Net::HTTPNotFound.new("1.1", "404", "Not Found"), Net::HTTPOK.new("1.1", "200", "OK")], [])
    result = UrlCheck.new(http: http, resolver: Resolver.new(["93.184.216.34"])).check(entry("https://example.com"))

    assert_equal %w[HEAD GET], http.methods
    assert_equal "ok", result["category"]
    assert_equal 200, result["status"]
    assert_equal "GET", result["method"]
    assert_equal [], result["redirects"]
    assert_equal 1, result["attempts"]
  end

  def test_does_not_fallback_for_access_restricted_healthy_statuses
    { 401 => Net::HTTPUnauthorized, 403 => Net::HTTPForbidden, 429 => Net::HTTPTooManyRequests }.each do |status, response_class|
      http = Http.new([response_class.new("1.1", status.to_s, "Restricted")], [])
      result = UrlCheck.new(http: http, resolver: Resolver.new(["93.184.216.34"]), retries: 0).check(entry("https://example.com"))

      assert_equal ["HEAD"], http.methods
      assert_equal status, result["status"]
      assert_equal "HEAD", result["method"]
      assert UrlCheck.healthy?(result)
    end
  end

  def test_validates_timeout_and_retries
    assert_raises(ArgumentError) { UrlCheck.new(timeout: 0) }
    assert_raises(ArgumentError) { UrlCheck.new(retries: -1) }
    UrlCheck.new(timeout: 0.1, retries: 0)
  end
end
