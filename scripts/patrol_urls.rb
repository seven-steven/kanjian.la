#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "optparse"
require "openssl"
require "time"
require "timeout"
require "uri"
require "yaml"
require_relative "check_urls"
require_relative "site_data"

# Content-level patrol for external URLs declared in _data/sites.yml. Where
# UrlCheck only sees HTTP status codes (and is blind to redirects that end on a
# parked or takeover page), this script fetches bodies and fingerprints them
# against a signature library to detect domain parking, store unlistings,
# hosting suspensions, and similar content-level deaths. Like check_urls.rb it
# deliberately has no gem dependencies so it can run in GitHub Actions' stock
# Ruby installation. The constants below are the single source of truth for
# every verdict rule; downstream consumers (skill, apply_patrol_plan.rb) read
# the emitted JSON instead of duplicating them.
class UrlPatrol
  VERSION = "1"
  DEFAULT_TIMEOUT = 15
  DEFAULT_RETRIES = 1
  MAX_REDIRECTS = 5
  BODY_READ_LIMIT = 64 * 1024        # fingerprint matching only reads the first 64KB
  OVERSIZED_BODY_LIMIT = 2 * 1024 * 1024 # bodies larger than this are skipped entirely
  SPA_MIN_TEXT_LENGTH = 200          # visible chars below which a scripted page counts as a shell
  EVIDENCE_LIMIT = 200
  USER_AGENT = "kanjian-la-patrol/1.0"

  # Raised internally when a streamed body reaches BODY_READ_LIMIT; the
  # accumulated buffer becomes the fingerprinted body.
  ReadLimitReached = Class.new(StandardError)

  # Domain parking / sale: substrings of the response body (case-insensitive).
  # Generic English phrases live in the *-TITLE lists instead: they only count
  # inside <title> to keep ordinary articles from tripping the patrol.
  PARKED_BODY_SIGNATURES = [
    "this domain may be for sale",
    "domain registration has expired",
    "buy this domain",
    "domain is for sale",
    "this website is for sale",
    "parked free",
    "sedoparking",
  ].freeze
  PARKED_TITLE_SIGNATURES = ["related searches"].freeze # Bodis parking page
  # Parking-provider script/resource hosts: any standalone occurrence in the
  # body decides (see matched_script_host).
  PARKED_SCRIPT_HOSTS = %w[parklogic.com abovedomains.com bodis.com afternic.com dan.com parkingcrew.net].freeze
  # Redirecting to one of these targets means parked.
  PARKED_REDIRECT_TARGETS = %w[expireddomains.com afternic.com sedoparking.com].freeze
  # Hosting-provider suspension pages. The English phrases are title-scoped:
  # "account suspended" in running text is ordinary prose, in a <title> it is
  # the provider's suspension page.
  SUSPENDED_BODY_SIGNATURES = [
    "站点已被管理员停止运行",
    "该站点已经被管理员停止",
  ].freeze
  SUSPENDED_TITLE_SIGNATURES = ["account suspended", "site has been suspended"].freeze
  # Chrome Web Store unlisting: the final URL slug is rewritten to empty-title.
  STORE_UNLISTED_SLUG = %r{chromewebstore\.google\.com/detail/empty-title/}
  # Anti-bot / human verification: not an anomaly, skip.
  BLOCKED_BODY_SIGNATURES = ["just a moment", "checking your browser", "attention required", "challenge-platform", "cf-chl-"].freeze
  # Login-wall redirect targets, two shapes: whole hosts that only exist for
  # authentication, and GitHub paths that gate a normally public site. Other
  # GitHub redirects stay visible as redirect_foreign so migrations to GitHub
  # are re-checked instead of silently swallowed.
  LOGIN_HOSTS = %w[accounts.feishu.cn accounts.google.com login.microsoftonline.com].freeze
  LOGIN_PATH_PATTERN = %r{github\.com/(login|session|password_reset|enter)}.freeze
  # eTLD+1 approximation: hosts ending in one of these use the last three
  # labels as the registrable domain, everything else the last two.
  COMMON_TWO_LEVEL_SUFFIX = %w[co.uk com.cn org.cn net.cn gov.cn co.jp com.au co.nz com.br com.mx].freeze

  # Verdict philosophy: remove only on strong evidence (DNS death, content
  # fingerprints, hard 404/410, invalid URL). Everything that merely *looks*
  # unreachable — 5xx, network errors, bare TLS failures, content checks that
  # crashed — defers to the status-code pipeline or the model queue instead.
  SUGGESTED_ACTIONS = {
    "ok" => "none",
    "parked" => "remove",
    "unlisted" => "remove",
    "hosting_suspended" => "remove",
    "dead_dns" => "remove",
    "dead_tls" => "remove",
    "dead_http" => "remove",
    "cert_expired_live" => "defer",
    "misconfigured" => "replace_url",
    "redirect_foreign" => "model_review",
    "spa_shell" => "model_review",
    "blocked" => "none",
    "unreachable_5xx" => "defer",
    "unreachable_net" => "defer",
    "unreachable_tls" => "defer",
    "content_check_failed" => "defer",
  }.freeze
  # Verdicts that are worth probing scheme/www variants for a misconfigured
  # original: DNS and hard protocol deaths, plus the new unreachable-* bucket
  # where a healthy variant means the entry URL itself is just wrong.
  DEAD_VERDICTS = %w[dead_dns dead_tls dead_http unreachable_5xx unreachable_net unreachable_tls].freeze
  # Body fingerprints that count as "parking or suspension" when a certificate
  # error still serves content: these turn a cert failure into dead_tls rather
  # than cert_expired_live.
  SUSPENDED_VERDICTS = %w[parked hosting_suspended].freeze
  TRANSIENT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError].freeze

  def initialize(timeout: DEFAULT_TIMEOUT, retries: DEFAULT_RETRIES, http: Net::HTTP, resolver: Resolv, checker: nil)
    raise ArgumentError, "timeout must be greater than zero" unless timeout.is_a?(Numeric) && timeout.positive?
    raise ArgumentError, "retries must be zero or greater" unless retries.is_a?(Integer) && retries >= 0

    @timeout = timeout
    @retries = retries
    @http = http
    @resolver = resolver
    @checker = checker || UrlCheck.new(timeout: timeout, retries: retries, http: http, resolver: resolver)
  end

  # Stable verdict enum consumed downstream. check_result is the hash emitted by
  # UrlCheck#check (category/status/error/normalized_url). Steps that need a
  # body or a probe (content rules, cert probing, variant probing) are produced
  # by the instance flow, not here.
  def self.classify(check_result, body, final_url)
    case check_result["category"]
    when "dns_error" then "dead_dns"
    when "tls_error" then "dead_tls"
    when "timeout", "network_error", "unsafe_destination" then "unreachable_net"
    when "invalid_url" then "dead_http"
    when "server_error" then "unreachable_5xx"
    when "client_error"
      [404, 410].include?(check_result["status"].to_i) ? "dead_http" : "blocked"
    else
      content_verdict(body, final_url, origin_domain(check_result))[0]
    end
  end

  # Registrable domain (eTLD+1 approximation): last two labels, or the last
  # three when the host ends in a known two-level public suffix.
  def self.registrable_domain(host)
    labels = host.to_s.downcase.split(".").reject(&:empty?)
    return labels.join(".") if labels.length <= 2

    two_level = labels[-2..].join(".")
    COMMON_TWO_LEVEL_SUFFIX.include?(two_level) ? labels[-3..].join(".") : two_level
  end

  def self.host_of(url)
    URI.parse(url.to_s).host&.downcase
  rescue URI::InvalidURIError
    nil
  end

  def self.subdomain_or_self?(host, domain)
    return false if host.nil? || host.empty?

    host == domain || host.end_with?(".#{domain}")
  end

  def self.origin_domain(check_result)
    registrable_domain(host_of(check_result["normalized_url"] || check_result["url"].to_s).to_s)
  end

  # Content rules for a reachable URL. Returns [verdict, evidence] so the
  # verdict and its report evidence always stay in lockstep.
  def self.content_verdict(body, final_url, origin_domain)
    target = final_url.to_s
    host = host_of(target)
    title = title_text(body)

    if STORE_UNLISTED_SLUG.match?(target)
      return ["unlisted", "final URL slug was rewritten to empty-title (Chrome Web Store unlisted the item)"]
    end
    if (service = PARKED_REDIRECT_TARGETS.find { |name| subdomain_or_self?(host, name) })
      return ["parked", "redirects to parking service #{service}"]
    end
    if (login_host = LOGIN_HOSTS.find { |name| subdomain_or_self?(host, name) }) &&
       !host.to_s.empty? && registrable_domain(host) != origin_domain
      return ["blocked", "redirects to login host #{login_host}"]
    end
    if !host.to_s.empty? && registrable_domain(host) == "github.com" && (login_path = target[LOGIN_PATH_PATTERN])
      return ["blocked", "redirects to GitHub login wall (#{login_path})"]
    end
    if !origin_domain.empty? && !host.to_s.empty? && registrable_domain(host) != origin_domain
      return ["redirect_foreign", "redirects to foreign registrable domain #{registrable_domain(host)} (origin #{origin_domain})"]
    end
    if (signature = matched_signature(body, SUSPENDED_BODY_SIGNATURES))
      return ["hosting_suspended", "hosting suspension body signature #{signature.inspect}"]
    end
    if (signature = matched_signature(title, SUSPENDED_TITLE_SIGNATURES))
      return ["hosting_suspended", "hosting suspension title signature #{signature.inspect}"]
    end
    if (signature = matched_signature(body, PARKED_BODY_SIGNATURES))
      return ["parked", "parked body signature #{signature.inspect}"]
    end
    if (signature = matched_signature(title, PARKED_TITLE_SIGNATURES))
      return ["parked", "parked title signature #{signature.inspect}"]
    end
    if (script_host = matched_script_host(body))
      return ["parked", "parking provider script host #{script_host}"]
    end
    if (signature = matched_signature(body, BLOCKED_BODY_SIGNATURES))
      return ["blocked", "bot-challenge signature #{signature.inspect}"]
    end
    if spa_shell?(body)
      return ["spa_shell", "script-only shell page (#{visible_text_length(body)} visible text chars after stripping scripts)"]
    end

    ["ok", "live content with no parked/suspended/blocked signature in the first #{BODY_READ_LIMIT} bytes"]
  end

  def self.matched_signature(body, signatures)
    haystack = body.to_s.downcase
    signatures.find { |signature| haystack.include?(signature.to_s.downcase) }
  end

  # Shared mapping for content that was only obtainable by skipping
  # certificate verification: a parking or suspension fingerprint still proves
  # the site is dead (dead_tls, remove), anything else means the site is
  # alive behind a broken certificate (cert_expired_live, defer).
  def self.cert_content_outcome(content_verdict, detail, tls_error)
    if SUSPENDED_VERDICTS.include?(content_verdict)
      ["dead_tls", "TLS failure (#{tls_error}) and served content shows #{detail}"]
    else
      ["cert_expired_live", "TLS failure (#{tls_error}) but an unverified fetch serves live content; #{detail}"]
    end
  end

  # Parking-provider hosts must appear as a standalone host reference. A bare
  # include? would match "dan.com" inside "jordan.com"; the lookbehind rejects
  # matches preceded by a word character or hyphen while still accepting
  # "www.dan.com" (preceded by a dot) and a match at the very start.
  def self.matched_script_host(body)
    haystack = body.to_s
    PARKED_SCRIPT_HOSTS.find do |host|
      haystack.match?(/(?<![\w-])#{Regexp.escape(host)}/i)
    end
  end

  def self.title_text(body)
    match = body.to_s.match(%r{<title[^>]*>(.*?)</title>}im)
    match ? match[1].to_s : ""
  end

  def self.spa_shell?(body)
    return true if body.nil? || body.strip.empty?
    return false unless body.include?("<script")

    visible_text_length(body) < SPA_MIN_TEXT_LENGTH
  end

  def self.visible_text_length(body)
    body.to_s
        .gsub(/<script[^>]*>.*?<\/script>/im, " ")
        .gsub(/<style[^>]*>.*?<\/style>/im, " ")
        .gsub(/<[^>]+>/, " ")
        .gsub(/\s+/, " ")
        .strip
        .length
  end

  # Variant URLs tried when a URL is dead, in order: bare-domain <-> www swap
  # first (the canonical https://www.apex form wins for https origins), then
  # the scheme swap, then the combined swap. Purely syntactic; healthiness is
  # decided by the caller.
  def self.variant_urls(url)
    uri = URI.parse(url)
    has_www = uri.host.start_with?("www.")
    swapped_host = has_www ? uri.host.delete_prefix("www.") : "www.#{uri.host}"
    swapped_scheme = uri.scheme == "https" ? "http" : "https"
    www_swap = uri.dup.tap { |variant| variant.host = swapped_host }
    scheme_swap = uri.dup.tap { |variant| variant.scheme = swapped_scheme }
    combined = uri.dup.tap { |variant| variant.host = swapped_host; variant.scheme = swapped_scheme }
    [www_swap.to_s, scheme_swap.to_s, combined.to_s].reject { |candidate| candidate == url }.uniq
  rescue URI::InvalidURIError
    []
  end

  # Returns the parsed sites.yml as a raw data tree, ready for
  # UrlCheck.entries. SiteData.load_file needs psych >= 3.3 (YAML.safe_load_file,
  # bundled since Ruby 3.0); the fallback keeps the script usable on stock
  # system rubies. The raw tree is used instead of SiteData.read because
  # UrlCheck.entries walks Array/Hash structures, not Site structs.
  def self.load_sites(path)
    SiteData.load_file(path)
  rescue NoMethodError
    YAML.safe_load(File.read(path), permitted_classes: [], aliases: true)
  end

  # Serial patrol over every navigation entry. Results are collected single
  # threaded, matching check_urls.rb.
  def run(sites_path, only: nil, limit: nil)
    entries = UrlCheck.entries(self.class.load_sites(sites_path))
    keys = only ? only.map(&:strip).reject(&:empty?) : nil
    selected = entries.select { |entry| keys.nil? || keys.include?(UrlCheck.key_for(entry["kind"], entry["url"])) }
    selected = selected.first(limit) if limit

    results = selected.map { |entry| patrol_entry(entry) }
    counts = results.each_with_object(Hash.new(0)) { |row, memo| memo[row["verdict"]] += 1 }
    {
      "checked_at" => Time.now.utc.iso8601,
      "version" => VERSION,
      "results" => results,
      "summary" => {
        "counts" => counts,
        "model_review_queue" => results
          .select { |row| row["suggested_action"] == "model_review" }
          .map { |row| row["key"] },
      },
    }
  end

  private

  def patrol_entry(entry)
    check_result = @checker.check(entry)
    verdict, evidence, suggested_url, final_url = evaluate(check_result)
    record(entry, check_result, verdict, evidence, suggested_url, final_url)
  end

  def evaluate(check_result)
    verdict, evidence, suggested_url, final_url =
      if %w[ok redirect].include?(check_result["category"])
        evaluate_content(check_result)
      else
        evaluate_unreachable(check_result)
      end

    if DEAD_VERDICTS.include?(verdict)
      probe = probe_variants(check_result)
      if probe
        verdict = "misconfigured"
        suggested_url = probe["url"]
        evidence = "variant #{probe["url"]} is healthy (status #{probe["status"]}); original URL failed"
      end
    end
    [verdict, evidence, suggested_url, final_url]
  end

  def evaluate_unreachable(check_result)
    verdict = self.class.classify(check_result, nil, nil)
    evidence = check_result["error"] || "status #{check_result["status"]} (#{check_result["category"]})"

    if verdict == "dead_tls"
      # Cert probing: an expired/invalid certificate may still front the
      # original site, so fingerprint one unverified fetch before giving up.
      cert = certificate_probe(check_result)
      return cert if cert

      # A bare TLS failure is not proof of death — defer.
      return ["unreachable_tls", evidence, nil, check_result["final_url"]]
    end

    [verdict, evidence, nil, check_result["final_url"]]
  end

  def evaluate_content(check_result)
    fetched = fetch_body(check_result["final_url"] || check_result["normalized_url"])
    verdict, detail = self.class.content_verdict(fetched["body"], fetched["final_url"], self.class.origin_domain(check_result))
    if fetched["tls_expired"]
      verdict, detail = self.class.cert_content_outcome(verdict, detail, "certificate rejected during content fetch")
    end
    detail = "#{detail}; oversized body not fingerprinted (Content-Length exceeds #{OVERSIZED_BODY_LIMIT} bytes)" if fetched["oversized"]
    [verdict, detail, nil, fetched["final_url"]]
  rescue OpenSSL::SSL::SSLError => error
    cert = certificate_probe(check_result.merge("error" => error.message))
    return cert if cert

    ["unreachable_tls", "content fetch TLS failure: #{error.message}", nil, check_result["final_url"]]
  rescue StandardError => error
    # A crash here (redirect loop, non-http deep link, patrol bug) is not
    # evidence the site died — defer with the failure recorded.
    ["content_check_failed", "content check could not complete: #{error.class}: #{error.message}", nil, check_result["final_url"]]
  end

  def certificate_probe(check_result)
    url = (check_result["final_url"] || check_result["normalized_url"] || check_result["url"]).to_s
    fetched = unverified_body(url)
    return nil unless fetched

    content_verdict, detail = self.class.content_verdict(
      fetched["body"], fetched["final_url"], self.class.registrable_domain(self.class.host_of(url).to_s)
    )
    verdict, evidence = self.class.cert_content_outcome(content_verdict, detail, check_result["error"])
    [verdict, evidence, nil, check_result["final_url"]]
  end

  def probe_variants(check_result)
    base_url = (check_result["normalized_url"] || check_result["url"]).to_s
    base_domain = self.class.registrable_domain(self.class.host_of(base_url).to_s)
    self.class.variant_urls(base_url).each do |variant|
      result = @checker.check("url" => variant, "kind" => check_result["kind"])
      next unless UrlCheck.healthy?(result)
      next unless self.class.registrable_domain(self.class.host_of(result["final_url"] || variant).to_s) == base_domain

      return { "url" => variant, "status" => result["status"], "final_url" => result["final_url"] }
    end
    nil
  end

  # GET with at most MAX_REDIRECTS hops. Every hop's target must pass the
  # shared SSRF guard before any socket is opened.
  def fetch_body(url)
    get_with_retries(url, verify: true)
  rescue OpenSSL::SSL::SSLError => error
    unverified_body(url) || raise(error)
  end

  # One verification-free reconnect used to fingerprint content behind an
  # expired or otherwise invalid certificate. Returns nil when that also fails.
  def unverified_body(url)
    get_with_retries(url, verify: false).merge("tls_expired" => true)
  rescue StandardError
    nil
  end

  def get_with_retries(url, verify: true)
    attempts = 0
    begin
      attempts += 1
      return get_following_redirects(url, verify: verify)
    rescue *TRANSIENT_ERRORS
      raise if attempts > @retries

      sleep(2**(attempts - 1))
      retry
    end
  end

  def get_following_redirects(url, verify: true)
    current = url
    hops = 0
    loop do
      result = get_once(current, verify: verify)
      if result["location"]
        raise Net::HTTPBadResponse, "too many redirects" if hops >= MAX_REDIRECTS
        raise Net::HTTPBadResponse, "redirect missing Location" if result["location"].to_s.empty?

        current = UrlCheck.normalize(URI.join(current, result["location"]).to_s)
        hops += 1
      else
        return {
          "status" => result["status"],
          "final_url" => current,
          "body" => truncate_body(result["body"]),
          "oversized" => result["oversized"],
          "tls_expired" => false,
        }
      end
    end
  end

  def get_once(url, verify: true)
    uri = URI.parse(url)
    addresses = SafeNetwork.resolve_public!(uri.host, resolver: @resolver)
    @http.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      ipaddr: addresses.first,
      open_timeout: @timeout,
      read_timeout: @timeout,
      verify_mode: verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    ) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      # Block-mode request: bodies are streamed in chunks and capped, so a
      # pathological site cannot OOM the patrol runner.
      payload = nil
      http.request(request) { |response| payload = read_limited(response) }
      payload
    end
  end

  # Flattens a response into {status, location?, body, oversized} so redirect
  # hops never read a body and terminal responses never read past the cap.
  def read_limited(response)
    if response.is_a?(Net::HTTPRedirection)
      { "status" => response.code.to_i, "location" => response["location"], "body" => nil, "oversized" => false }
    elsif response["content-length"].to_i > OVERSIZED_BODY_LIMIT
      { "status" => response.code.to_i, "body" => "", "oversized" => true }
    else
      { "status" => response.code.to_i, "body" => capped_body(response), "oversized" => false }
    end
  end

  def capped_body(response)
    # Hand-constructed responses (tests) carry their body already read and
    # cannot be re-streamed; real responses in block mode are always unread.
    return response.body.to_s if response.instance_variable_get(:@read)

    buffer = +""
    response.read_body do |chunk|
      buffer << chunk.to_s
      raise ReadLimitReached if buffer.bytesize >= BODY_READ_LIMIT
    end
    buffer
  rescue ReadLimitReached
    buffer
  end

  def truncate_body(raw)
    raw.to_s.byteslice(0, BODY_READ_LIMIT).force_encoding(Encoding::UTF_8).scrub
  end

  def record(entry, check_result, verdict, evidence, suggested_url, final_url)
    {
      "key" => check_result["key"],
      "url" => entry["url"],
      "kind" => entry["kind"],
      "title" => entry["title"],
      "path" => entry["path"],
      "site_title" => entry["site_title"],
      "verdict" => verdict,
      "status" => check_result["status"],
      "final_url" => final_url,
      "evidence" => evidence.to_s[0, EVIDENCE_LIMIT],
      "suggested_action" => SUGGESTED_ACTIONS.fetch(verdict, "model_review"),
      "suggested_url" => suggested_url,
    }
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    input: "_data/sites.yml",
    output: nil,
    timeout: UrlPatrol::DEFAULT_TIMEOUT,
    retries: UrlPatrol::DEFAULT_RETRIES,
    only: nil,
    limit: nil,
  }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/patrol_urls.rb --output PATH [options]"
    parser.on("--input PATH", "YAML site data (default: _data/sites.yml)") { |value| options[:input] = value }
    parser.on("--output PATH", "Write JSON report to PATH (required)") { |value| options[:output] = value }
    parser.on("--timeout SECONDS", Integer, "Per-request timeout") { |value| options[:timeout] = value }
    parser.on("--retries COUNT", Integer, "Retries after first transient failure") { |value| options[:retries] = value }
    parser.on("--only KEY1,KEY2", Array, "Comma-separated entry keys to patrol") { |value| options[:only] = value }
    parser.on("--limit COUNT", Integer, "Patrol at most COUNT entries") { |value| options[:limit] = value }
  end.parse!

  abort "--output is required" unless options[:output]
  patrol = UrlPatrol.new(timeout: options[:timeout], retries: options[:retries])
  payload = patrol.run(options[:input], only: options[:only], limit: options[:limit])
  File.write(options[:output], JSON.pretty_generate(payload) + "\n")
end
