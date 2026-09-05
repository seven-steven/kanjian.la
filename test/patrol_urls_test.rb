# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tempfile"
require_relative "../scripts/patrol_urls"

class UrlPatrolTest < Minitest::Test
  Resolver = Struct.new(:addresses) do
    def getaddresses(_host)
      addresses
    end
  end

  # Returns a different address list per resolution attempt, so tests can make
  # a redirect hop land on a private address.
  SequenceResolver = Struct.new(:sequence) do
    def getaddresses(_host)
      sequence.length > 1 ? sequence.shift : sequence.first
    end
  end

  Http = Struct.new(:responses, :methods, :starts) do
    def start(*args)
      starts << args
      yield self
    end

    # Mirrors Net::HTTP#request block mode: when a block is given the response
    # is handed to it instead of being returned.
    def request(request, &block)
      methods << request.method
      response = responses.shift
      block ? block.call(response) : response
    end
  end

  # Fails every verified TLS handshake but serves queued responses once the
  # caller reconnects without verification (cert_expired_live probing path).
  TlsOnlyHttp = Struct.new(:responses, :methods, :starts) do
    def start(*args)
      starts << args
      options = args.last.is_a?(Hash) ? args.last : {}
      raise OpenSSL::SSL::SSLError, "certificate has expired" unless options[:verify_mode] == OpenSSL::SSL::VERIFY_NONE

      yield self
    end

    def request(request, &block)
      methods << request.method
      response = responses.shift
      block ? block.call(response) : response
    end
  end

  # Serves the first verified handshake, then fails every later verified one;
  # unverified reconnects succeed. Emulates a certificate that breaks between
  # the base HEAD check and the content GET (tls_expired content path).
  CertFlakyHttp = Struct.new(:responses, :methods, :starts) do
    def start(*args)
      starts << args
      options = args.last.is_a?(Hash) ? args.last : {}
      @verified_starts ||= 0
      if options[:verify_mode] != OpenSSL::SSL::VERIFY_NONE
        @verified_starts += 1
        raise OpenSSL::SSL::SSLError, "certificate verify failed" if @verified_starts > 1
      end

      yield self
    end

    def request(request, &block)
      methods << request.method
      response = responses.shift
      block ? block.call(response) : response
    end
  end

  FIXTURE = <<~YAML
    ---
    - name: 巡检
      links:
        - title: Parked
          url: https://parked.example.com/
        - title: Fine
          url: https://fine.example.com/
        - title: Dead
          url: https://dead.example.com/
  YAML

  LONG_BODY = ("All work and no play makes the fine site a dull place. " * 8).freeze

  def entry(url, kind: "main")
    { "url" => url, "kind" => kind, "title" => "Example", "path" => "links.0.url" }
  end

  # Hand-built responses carry no socket, so reading #body on Ruby 2.6 goes
  # through stream_check and dies on nil; marking them as already read makes
  # #body return the assigned value on every supported Ruby.
  def ok(body = "ok")
    Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
      response.body = body
      response.instance_variable_set(:@read, true)
    end
  end

  def not_found
    Net::HTTPNotFound.new("1.1", "404", "Not Found")
  end

  def forbidden
    Net::HTTPForbidden.new("1.1", "403", "Forbidden")
  end

  def server_error
    Net::HTTPInternalServerError.new("1.1", "500", "Internal Server Error")
  end

  def found(location)
    Net::HTTPFound.new("1.1", "302", "Found").tap { |response| response["location"] = location }
  end

  def patrol(http: Http.new([], [], []), resolver: Resolver.new(["93.184.216.34"]))
    UrlPatrol.new(http: http, resolver: resolver, retries: 0)
  end

  def test_classify_maps_network_categories_to_death_and_unreachable_verdicts
    {
      "dns_error" => "dead_dns",
      "tls_error" => "dead_tls",
      "invalid_url" => "dead_http",
      "timeout" => "unreachable_net",
      "network_error" => "unreachable_net",
      "unsafe_destination" => "unreachable_net",
      "server_error" => "unreachable_5xx",
    }.each do |category, verdict|
      assert_equal verdict, UrlPatrol.classify({ "category" => category, "status" => 500 }, nil, nil), category
    end
  end

  def test_classify_splits_client_errors_into_dead_and_blocked
    { 404 => "dead_http", 410 => "dead_http", 403 => "blocked", 429 => "blocked",
      401 => "blocked", 412 => "blocked", 400 => "blocked" }.each do |status, verdict|
      assert_equal verdict, UrlPatrol.classify({ "category" => "client_error", "status" => status }, nil, nil), status
    end
  end

  def test_classify_detects_unlisted_store_slug
    result = { "category" => "ok", "normalized_url" => "https://example.com/suspender" }
    assert_equal "unlisted", UrlPatrol.classify(result, LONG_BODY, "https://chromewebstore.google.com/detail/empty-title/abcdefghijk")
  end

  def test_classify_detects_parking_by_redirect_target_including_subdomains
    result = { "category" => "redirect", "normalized_url" => "https://gone.example.com/" }
    assert_equal "parked", UrlPatrol.classify(result, LONG_BODY, "https://park.afternic.com/gone.example.com")
    assert_equal "parked", UrlPatrol.classify(result, LONG_BODY, "https://sedoparking.com/gone.example.com")
  end

  def test_classify_detects_parking_by_body_signature_case_insensitively
    result = { "category" => "ok", "normalized_url" => "https://gone.example.com/" }
    assert_equal "parked", UrlPatrol.classify(result, "<h1>This Domain May Be For Sale</h1>", "https://gone.example.com/")
    assert_equal "parked", UrlPatrol.classify(result, "Domain Registration Has Expired. Renew now.", "https://gone.example.com/")
  end

  def test_classify_detects_parking_by_script_host
    result = { "category" => "ok", "normalized_url" => "https://gone.example.com/" }
    body = "<html><head><script src=\"https://parklogic.com/park.js\"></script></head><body></body></html>"
    assert_equal "parked", UrlPatrol.classify(result, body, "https://gone.example.com/")
  end

  def test_classify_ignores_host_substrings_inside_other_words
    result = { "category" => "ok", "normalized_url" => "https://shop.example.com/" }
    body = "<p>Readers compare us with jordan.com and sudan.com reviews.</p>#{LONG_BODY}"
    assert_equal "ok", UrlPatrol.classify(result, body, "https://shop.example.com/")
  end

  def test_classify_matches_generic_phrases_only_inside_the_title
    result = { "category" => "ok", "normalized_url" => "https://blog.example.com/" }
    prose = "<p>Our related searches roundup covers account suspended cases.</p>#{LONG_BODY}"
    assert_equal "ok", UrlPatrol.classify(result, prose, "https://blog.example.com/")

    bodis = "<html><title>Related Searches</title><body><script src=\"/b.js\"></script></body></html>"
    assert_equal "parked", UrlPatrol.classify(result, bodis, "https://blog.example.com/")

    suspended = "<html><title>Account Suspended</title><body></body></html>"
    assert_equal "hosting_suspended", UrlPatrol.classify(result, suspended, "https://blog.example.com/")
  end

  def test_classify_detects_hosting_suspension
    result = { "category" => "ok", "normalized_url" => "https://hosted.example.com/" }
    assert_equal "hosting_suspended", UrlPatrol.classify(result, "站点已被管理员停止运行", "https://hosted.example.com/")
    assert_equal "hosting_suspended", UrlPatrol.classify(result, "<title>Account Suspended</title>", "https://hosted.example.com/")
  end

  def test_classify_flags_foreign_registrable_domain_with_etld_boundaries
    result = { "category" => "ok", "normalized_url" => "https://x.co.uk/" }
    assert_equal "ok", UrlPatrol.classify(result, LONG_BODY, "https://sub.x.co.uk/page")
    assert_equal "redirect_foreign", UrlPatrol.classify(result, LONG_BODY, "https://y.uk/")

    plain = { "category" => "ok", "normalized_url" => "https://example.com/" }
    assert_equal "ok", UrlPatrol.classify(plain, LONG_BODY, "https://www.example.com/page")
    assert_equal "redirect_foreign", UrlPatrol.classify(plain, LONG_BODY, "https://other.example.net/")
  end

  def test_classify_detects_bot_challenge_bodies
    result = { "category" => "ok", "normalized_url" => "https://guarded.example.com/" }
    assert_equal "blocked", UrlPatrol.classify(result, "<title>Just a moment...</title>", "https://guarded.example.com/")
    assert_equal "blocked", UrlPatrol.classify(result, "Checking your browser before accessing", "https://guarded.example.com/")
  end

  def test_classify_treats_login_wall_redirects_as_blocked_but_not_own_domain
    result = { "category" => "redirect", "normalized_url" => "https://docs.example.com/" }
    assert_equal "blocked", UrlPatrol.classify(result, LONG_BODY, "https://accounts.feishu.cn/share/auth")

    github = { "category" => "ok", "normalized_url" => "https://github.com/foo/bar" }
    assert_equal "ok", UrlPatrol.classify(github, LONG_BODY, "https://github.com/foo/bar")
  end

  def test_classify_limits_github_login_wall_to_login_paths
    docs = { "category" => "redirect", "normalized_url" => "https://docs.example.com/" }
    assert_equal "blocked", UrlPatrol.classify(docs, LONG_BODY, "https://github.com/login")
    assert_equal "blocked", UrlPatrol.classify(docs, LONG_BODY, "https://github.com/session/new")
    assert_equal "blocked", UrlPatrol.classify(docs, LONG_BODY, "https://github.com/password_reset")
    # A project migrating to GitHub must stay visible for model review.
    assert_equal "redirect_foreign", UrlPatrol.classify(docs, LONG_BODY, "https://github.com/owner/repo")
  end

  def test_classify_separates_spa_shells_from_real_content
    result = { "category" => "ok", "normalized_url" => "https://spa.example.com/" }
    shell = "<html><head><script src=\"/bundle.js\"></script></head><body><div id=\"app\"></div></body></html>"
    assert_equal "spa_shell", UrlPatrol.classify(result, shell, "https://spa.example.com/")
    assert_equal "spa_shell", UrlPatrol.classify(result, "", "https://spa.example.com/")

    long_with_script = "<html><body><script>var x = 1;</script><p>#{LONG_BODY}</p></body></html>"
    assert_equal "ok", UrlPatrol.classify(result, long_with_script, "https://spa.example.com/")
    assert_equal "ok", UrlPatrol.classify(result, LONG_BODY, "https://spa.example.com/")
  end

  def test_registrable_domain_handles_two_level_suffixes
    assert_equal "x.co.uk", UrlPatrol.registrable_domain("a.b.x.co.uk")
    assert_equal "example.com.cn", UrlPatrol.registrable_domain("sub.example.com.cn")
    assert_equal "y.uk", UrlPatrol.registrable_domain("y.uk")
    assert_equal "example.com", UrlPatrol.registrable_domain("www.example.com")
  end

  def test_variant_urls_prefer_www_then_scheme_then_combined
    assert_equal(
      ["https://www.example.com/", "http://example.com/", "http://www.example.com/"],
      UrlPatrol.variant_urls("https://example.com/")
    )
    assert_equal(
      ["http://example.com/", "https://www.example.com/", "https://example.com/"],
      UrlPatrol.variant_urls("http://www.example.com/")
    )
    assert_equal(
      ["https://example.com/", "http://www.example.com/", "http://example.com/"],
      UrlPatrol.variant_urls("https://www.example.com/")
    )
  end

  def test_fetch_body_uses_get_and_truncates_to_body_read_limit
    http = Http.new([ok("a" * 100_000)], [], [])
    fetched = patrol(http: http).send(:fetch_body, "https://example.com/docs")

    assert_equal 200, fetched["status"]
    assert_equal "https://example.com/docs", fetched["final_url"]
    assert_equal UrlPatrol::BODY_READ_LIMIT, fetched["body"].bytesize
    assert_equal false, fetched["tls_expired"]
    assert_equal false, fetched["oversized"]
    assert_equal ["GET"], http.methods
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.starts.first.last.fetch(:verify_mode)
  end

  def test_fetch_body_caps_streamed_bodies_at_read_limit
    response = Net::HTTPOK.new("1.1", "200", "OK")
    def response.read_body(&block)
      block.call("x" * 50_000)
      block.call("x" * 50_000)
      nil
    end

    http = Http.new([response], [], [])
    fetched = patrol(http: http).send(:fetch_body, "https://big.example.com/")

    assert_equal UrlPatrol::BODY_READ_LIMIT, fetched["body"].bytesize
    assert_equal false, fetched["oversized"]
  end

  def test_fetch_body_skips_oversized_content_length_without_reading
    response = ok("tiny").tap { |r| r["content-length"] = (3 * 1024 * 1024).to_s }
    http = Http.new([response], [], [])
    fetched = patrol(http: http).send(:fetch_body, "https://huge.example.com/")

    assert_equal "", fetched["body"]
    assert_equal true, fetched["oversized"]
  end

  def test_fetch_body_follows_redirect_chain
    http = Http.new([found("https://final.example.com/landing"), ok("redirected body")], [], [])
    fetched = patrol(http: http).send(:fetch_body, "https://start.example.com/")

    assert_equal 200, fetched["status"]
    assert_equal "https://final.example.com/landing", fetched["final_url"]
    assert_equal "redirected body", fetched["body"]
    assert_equal %w[GET GET], http.methods
  end

  def test_fetch_body_aborts_when_first_hop_is_private
    http = Http.new([], [], [])
    error = assert_raises(SafeNetwork::UnsafeDestinationError) do
      patrol(http: http, resolver: Resolver.new(["10.0.0.5"])).send(:fetch_body, "https://example.test/")
    end

    assert_match(/non-public/, error.message)
    assert_empty http.starts
  end

  def test_fetch_body_aborts_when_redirect_hop_is_private
    resolver = SequenceResolver.new([["93.184.216.34"], ["10.0.0.5"]])
    http = Http.new([found("https://internal.example.com/")], [], [])
    error = assert_raises(SafeNetwork::UnsafeDestinationError) do
      patrol(http: http, resolver: resolver).send(:fetch_body, "https://start.example.com/")
    end

    assert_match(/non-public/, error.message)
  end

  def test_fetch_body_reconnects_without_verification_on_tls_errors
    http = TlsOnlyHttp.new([ok("clean body")], [], [])
    fetched = UrlPatrol.new(http: http, resolver: Resolver.new(["93.184.216.34"]), retries: 0)
                         .send(:fetch_body, "https://expired.example.com/")

    assert_equal true, fetched["tls_expired"]
    assert_equal "clean body", fetched["body"]
    assert_equal [OpenSSL::SSL::VERIFY_PEER, OpenSSL::SSL::VERIFY_NONE], http.starts.map { |start| start.last.fetch(:verify_mode) }
  end

  def test_patrol_entry_defers_when_content_check_fails_on_private_redirect
    resolver = SequenceResolver.new([["93.184.216.34"], ["93.184.216.34"], ["10.0.0.5"]])
    http = Http.new([ok, found("https://internal.example.com/")], [], [])
    result = patrol(http: http, resolver: resolver).send(:patrol_entry, entry("https://start.example.com/"))

    assert_equal "content_check_failed", result["verdict"]
    assert_equal "defer", result["suggested_action"]
    assert_match(/non-public/, result["evidence"])
  end

  def test_patrol_entry_defers_on_pure_tls_failure_without_content_evidence
    http = TlsOnlyHttp.new([], [], [])
    result = UrlPatrol.new(http: http, resolver: Resolver.new(["93.184.216.34"]), retries: 0)
                      .send(:patrol_entry, entry("https://expired.example.com/"))

    assert_equal "unreachable_tls", result["verdict"]
    assert_equal "defer", result["suggested_action"]
    assert_match(/certificate has expired/, result["evidence"])
  end

  def test_patrol_entry_defers_on_server_error_with_unhealthy_variants
    http = Http.new([server_error, server_error, server_error, server_error], [], [])
    result = patrol(http: http).send(:patrol_entry, entry("https://broken.example.com/"))

    assert_equal "unreachable_5xx", result["verdict"]
    assert_equal "defer", result["suggested_action"]
    assert_equal %w[HEAD HEAD HEAD HEAD], http.methods
  end

  def test_patrol_entry_flags_cert_expired_live_when_content_served_after_tls_break
    http = CertFlakyHttp.new([ok(LONG_BODY), ok(LONG_BODY)], [], [])
    result = UrlPatrol.new(http: http, resolver: Resolver.new(["93.184.216.34"]), retries: 0)
                      .send(:patrol_entry, entry("https://flaky.example.com/"))

    assert_equal "cert_expired_live", result["verdict"]
    assert_equal "defer", result["suggested_action"]
    assert_match(/certificate rejected during content fetch/, result["evidence"])
  end

  def test_patrol_entry_notes_oversized_body_in_evidence
    response = ok("tiny").tap { |r| r["content-length"] = (3 * 1024 * 1024).to_s }
    http = Http.new([ok, response], [], [])
    result = patrol(http: http).send(:patrol_entry, entry("https://huge.example.com/"))

    assert_equal "spa_shell", result["verdict"]
    assert_equal "model_review", result["suggested_action"]
    assert_match(/oversized/, result["evidence"])
  end

  def test_patrol_entry_reports_cert_expired_live_for_clean_unverified_content
    http = TlsOnlyHttp.new([ok(LONG_BODY)], [], [])
    result = UrlPatrol.new(http: http, resolver: Resolver.new(["93.184.216.34"]), retries: 0)
                      .send(:patrol_entry, entry("https://expired.example.com/"))

    assert_equal "cert_expired_live", result["verdict"]
    assert_equal "defer", result["suggested_action"]
    assert_match(/unverified fetch serves live content/, result["evidence"])
  end

  def test_patrol_entry_reports_dead_tls_when_expired_cert_serves_parked_body
    http = TlsOnlyHttp.new([ok("buy this domain now")], [], [])
    result = UrlPatrol.new(http: http, resolver: Resolver.new(["93.184.216.34"]), retries: 0)
                      .send(:patrol_entry, entry("https://expired.example.com/"))

    assert_equal "dead_tls", result["verdict"]
    assert_equal "remove", result["suggested_action"]
    assert_match(/parked body signature/, result["evidence"])
  end

  def test_patrol_entry_probes_variants_and_suggests_misconfigured_url
    http = Http.new([not_found, not_found, ok], [], [])
    result = patrol(http: http).send(:patrol_entry, entry("https://dead.example.com/"))

    assert_equal "misconfigured", result["verdict"]
    assert_equal "replace_url", result["suggested_action"]
    assert_equal "https://www.dead.example.com/", result["suggested_url"]
    assert_match(/variant https:\/\/www\.dead\.example\.com\/ is healthy \(status 200\)/, result["evidence"])
    assert_equal %w[HEAD GET HEAD], http.methods
  end

  def test_patrol_entry_keeps_access_restricted_statuses_as_blocked
    http = Http.new([forbidden], [], [])
    result = patrol(http: http).send(:patrol_entry, entry("https://walled.example.com/"))

    assert_equal "blocked", result["verdict"]
    assert_equal "none", result["suggested_action"]
    assert_equal 403, result["status"]
    assert_equal ["HEAD"], http.methods
  end

  def test_run_reports_verdicts_actions_and_summary
    http = Http.new(
      [ok, ok("This Domain May Be For Sale — submit an offer"),
       ok, ok(LONG_BODY),
       not_found, not_found, not_found, not_found, not_found, not_found, not_found, not_found],
      [], []
    )
    payload = nil
    with_sites_fixture do |path|
      payload = patrol(http: http).run(path)
    end

    assert_equal "1", payload["version"]
    assert payload["checked_at"]
    assert_equal 3, payload["results"].length
    assert_equal %w[parked ok dead_http], payload["results"].map { |row| row["verdict"] }
    assert_equal %w[remove none remove], payload["results"].map { |row| row["suggested_action"] }
    assert_equal(
      %w[https://parked.example.com/ https://fine.example.com/ https://dead.example.com/],
      payload["results"].map { |row| row["url"] }
    )
    assert_equal({ "parked" => 1, "ok" => 1, "dead_http" => 1 }, payload["summary"]["counts"])
    assert_empty payload["summary"]["model_review_queue"]
    assert_match(/parked body signature/, payload["results"][0]["evidence"])
    assert_match(/status 404/, payload["results"][2]["evidence"])
    assert_equal UrlCheck.key_for("main", "https://parked.example.com/"), payload["results"][0]["key"]
    assert payload["results"].all? { |row| row["evidence"].length <= 200 }
    assert(payload["results"].all? { |row| %w[key url kind title path site_title verdict status final_url evidence suggested_action suggested_url].all? { |field| row.key?(field) } })
  end

  def test_run_supports_only_and_limit_filters
    with_sites_fixture do |path|
      parked_key = UrlCheck.key_for("main", "https://parked.example.com/")
      http = Http.new([ok, ok("This domain may be for sale")], [], [])
      only_payload = patrol(http: http).run(path, only: [parked_key, "nonexistent-key"])

      assert_equal [parked_key], only_payload["results"].map { |row| row["key"] }

      http = Http.new([ok, ok("This domain may be for sale"), ok, ok(LONG_BODY)], [], [])
      limit_payload = patrol(http: http).run(path, limit: 2)

      assert_equal %w[parked ok], limit_payload["results"].map { |row| row["verdict"] }
    end
  end

  def test_cli_help_smoke
    script = File.expand_path("../scripts/patrol_urls.rb", __dir__)
    stdout, stderr, status = Open3.capture3("ruby", script, "--help")

    assert_predicate status, :success?
    assert_includes stdout, "Usage: ruby scripts/patrol_urls.rb"
    assert_empty stderr
  end

  private

  def with_sites_fixture
    file = Tempfile.new(["sites", ".yml"])
    file.write(FIXTURE)
    file.close
    yield file.path
  ensure
    file&.unlink
  end
end
