# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/check_urls"

class UrlCheckTest < Minitest::Test
  Resolver = Struct.new(:addresses) do
    attr_reader :resolved_hosts

    def getaddresses(host)
      (@resolved_hosts ||= []) << host
      addresses
    end
  end

  Http = Struct.new(:responses, :methods, :starts) do
    def start(*args)
      starts << args
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

  def test_entries_carry_site_metadata_for_top_level_category
    data = [{ "name" => "开源应用", "links" => [{ "title" => "Alist", "url" => "https://alist.nn.ci/", "logo" => "alist.nn.ci.svg", "icons" => { "info" => [{ "title" => "Demo", "url" => "https://al.nn.ci/" }] } }] }]
    main, icon = UrlCheck.entries(data)

    assert_equal "main", main["kind"]
    assert_equal "Alist", main["site_title"]
    assert_equal "https://alist.nn.ci/", main["site_url"]
    assert_equal "开源应用", main["site_category"]
    assert_equal "alist.nn.ci.svg", main["logo"]
    assert_equal "0.links.0.url", main["path"]

    assert_equal "icon", icon["kind"]
    assert_equal "Demo", icon["title"]
    assert_equal "Alist", icon["site_title"]
    assert_equal "https://alist.nn.ci/", icon["site_url"]
    assert_equal "开源应用", icon["site_category"]
    assert_equal "0.links.0.icons.info.0.url", icon["path"]
  end

  def test_entries_accumulate_category_path_across_sub_sections
    data = [{ "name" => "开发资源", "sub" => [{ "name" => "在线工具", "links" => [{ "title" => "Bento", "url" => "https://bento.me/", "icons" => { "info" => [{ "title" => "文档", "url" => "https://docs.bento.me/" }] } }] }] }]
    main, icon = UrlCheck.entries(data)

    assert_equal "开发资源 / 在线工具", main["site_category"]
    assert_equal "开发资源 / 在线工具", icon["site_category"]
    assert_equal "Bento", icon["site_title"]
    assert_equal "https://bento.me/", icon["site_url"]
    assert_equal "文档", icon["title"]
    assert_equal "0.sub.0.links.0.url", main["path"]
    assert_equal "0.sub.0.links.0.icons.info.0.url", icon["path"]
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
    assert_equal "unsafe_destination", result["category"]
    assert_match(/non-public/, result["error"])
  end

  def test_classifies_unresolvable_hosts_as_dns_errors
    result = UrlCheck.new(resolver: Resolver.new([])).check(entry("https://example.test"))

    assert_equal "dns_error", result["category"]
    assert_match(/did not resolve/, result["error"])
    refute UrlCheck.deletion_eligible_failure?(result)
  end

  def test_classifies_tls_failures_separately
    http = Object.new
    def http.start(*)
      raise OpenSSL::SSL::SSLError, "certificate verify failed"
    end

    result = UrlCheck.new(http: http, resolver: Resolver.new(["93.184.216.34"]), retries: 0).check(entry("https://example.com"))

    assert_equal "tls_error", result["category"]
    assert_match(/certificate verify failed/, result["error"])
  end

  def test_check_preserves_site_metadata_in_result
    http = Http.new([Net::HTTPOK.new("1.1", "200", "OK")], [], [])
    rich = entry("https://example.com").merge("site_title" => "Site", "site_url" => "https://example.com", "site_category" => "Tools")
    result = UrlCheck.new(http: http, resolver: Resolver.new(["93.184.216.34"])).check(rich)

    assert_equal "Site", result["site_title"]
    assert_equal "https://example.com", result["site_url"]
    assert_equal "Tools", result["site_category"]
    assert_equal ["example.com", 443], http.starts.first.first(2)
    assert_equal true, http.starts.first.last.fetch(:use_ssl)
    assert_equal "93.184.216.34", http.starts.first.last.fetch(:ipaddr)
  end

  def test_uses_plain_http_with_resolved_address
    http = Http.new([Net::HTTPOK.new("1.1", "200", "OK")], [], [])
    result = UrlCheck.new(http: http, resolver: Resolver.new(["93.184.216.34"])).check(entry("http://example.com/path"))

    assert_equal "ok", result["category"]
    assert_equal ["example.com", 80], http.starts.first.first(2)
    assert_equal false, http.starts.first.last.fetch(:use_ssl)
    assert_equal "93.184.216.34", http.starts.first.last.fetch(:ipaddr)
  end

  def test_falls_back_to_get_when_head_returns_not_found
    http = Http.new([Net::HTTPNotFound.new("1.1", "404", "Not Found"), Net::HTTPOK.new("1.1", "200", "OK")], [], [])
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
      http = Http.new([response_class.new("1.1", status.to_s, "Restricted")], [], [])
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

  def test_normalizes_internationalized_domain_name_to_punycode
    assert_equal "https://xn--rhqp87dfoiv9a830g.com/", UrlCheck.normalize("https://楚门的世界.com")
    assert_equal "https://xn--wcv59z.com/", UrlCheck.normalize("https://教父.com")
  end

  def test_normalize_is_idempotent_for_internationalized_domain
    normalized = UrlCheck.normalize("https://楚门的世界.com")
    assert_equal normalized, UrlCheck.normalize(normalized)
  end

  def test_normalizes_mixed_ascii_and_unicode_label
    assert_equal "https://xn--mnchen-3ya.de/", UrlCheck.normalize("https://münchen.de")
    assert_equal "https://xn--caf-dma.example/", UrlCheck.normalize("https://café.example")
  end

  def test_normalize_preserves_port_and_userinfo_for_idn_host
    assert_equal(
      "https://xn--rhqp87dfoiv9a830g.com:8080/path",
      UrlCheck.normalize("https://楚门的世界.com:8080/path")
    )
    assert_equal(
      "https://user:pass@xn--rhqp87dfoiv9a830g.com/",
      UrlCheck.normalize("https://user:pass@楚门的世界.com/")
    )
  end

  def test_normalize_preserves_plain_ascii_authority
    assert_equal "http://example.com/", UrlCheck.normalize("HTTP://EXAMPLE.COM:80")
    assert_equal "https://example.com/path?x=1", UrlCheck.normalize("HTTPS://EXAMPLE.COM:443/path?x=1#section")
  end

  def test_check_reaches_real_request_for_internationalized_domain
    http = Http.new([Net::HTTPOK.new("1.1", "200", "OK")], [], [])
    resolver = Resolver.new(["93.184.216.34"])
    result = UrlCheck.new(http: http, resolver: resolver).check(entry("https://楚门的世界.com"))

    assert_equal "ok", result["category"]
    assert_equal 200, result["status"]
    assert_equal "https://xn--rhqp87dfoiv9a830g.com/", result["normalized_url"]
    assert_equal %w[HEAD], http.methods
    assert_equal ["xn--rhqp87dfoiv9a830g.com"], resolver.resolved_hosts
  end

  def test_key_for_collapses_unicode_and_punycode_forms
    assert_equal(
      UrlCheck.key_for("icon", "https://楚门的世界.com"),
      UrlCheck.key_for("icon", "https://xn--rhqp87dfoiv9a830g.com/")
    )
  end
end
