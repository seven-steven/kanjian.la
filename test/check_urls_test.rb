# frozen_string_literal: true

require "minitest/autorun"
require "webrick"
require_relative "../scripts/check_urls"

class UrlCheckTest < Minitest::Test
  def setup
    @server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    @server.mount_proc("/ok") { |_req, res| res.status = 200; res.body = "ok" }
    @server.mount_proc("/redirect") { |_req, res| res.status = 302; res["Location"] = "/ok" }
    @server.mount_proc("/head-rejected") { |req, res| res.status = req.request_method == "HEAD" ? 405 : 200; res.body = "ok" }
    @thread = Thread.new { @server.start }
    @base_url = "http://127.0.0.1:#{@server.config[:Port]}"
  end

  def teardown
    @server.shutdown
    @thread.join
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

  def test_marks_redirect_and_records_final_url
    result = UrlCheck.new.check(entry("#{@base_url}/redirect"))
    assert_equal "redirect", result["category"]
    assert_equal "#{@base_url}/ok", result["final_url"]
    assert_equal ["#{@base_url}/ok"], result["redirects"]
  end

  def test_falls_back_to_get_when_head_is_not_supported
    result = UrlCheck.new.check(entry("#{@base_url}/head-rejected"))
    assert_equal "ok", result["category"]
    assert_equal "GET", result["method"]
    assert_equal 200, result["status"]
  end

  def test_invalid_url_has_deterministic_key
    first = UrlCheck.new.check(entry("ftp://example.com"))
    second = UrlCheck.new.check(entry("ftp://example.com"))
    assert_equal "invalid_url", first["category"]
    assert_equal first["key"], second["key"]
  end
end
