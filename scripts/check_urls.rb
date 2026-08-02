#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "optparse"
require "openssl"
require "socket"
require "timeout"
require "time"
require "uri"
require "yaml"
require "digest"
require_relative "safe_network"

# Checks external URLs declared in _data/sites.yml. It deliberately has no gem
# dependencies so it can run in GitHub Actions' stock Ruby installation.
class UrlCheck
  DEFAULT_TIMEOUT = 10
  DEFAULT_RETRIES = 2
  MAX_REDIRECTS = 5
  TRANSIENT_STATUSES = (500..599).to_a + [408, 425, 429]
  HEAD_FALLBACK_STATUSES = ((400..499).to_a - TRANSIENT_STATUSES - [401, 403]) + [501]

  def initialize(timeout: DEFAULT_TIMEOUT, retries: DEFAULT_RETRIES, http: Net::HTTP, resolver: Resolv)
    raise ArgumentError, "timeout must be greater than zero" unless timeout.is_a?(Numeric) && timeout.positive?
    raise ArgumentError, "retries must be zero or greater" unless retries.is_a?(Integer) && retries >= 0

    @timeout = timeout
    @retries = retries
    @http = http
    @resolver = resolver
  end

  # RFC 3492 Bootstring parameters for Punycode encoding.
  PUNYCODE_BASE = 36
  PUNYCODE_TMIN = 1
  PUNYCODE_TMAX = 26
  PUNYCODE_SKEW = 38
  PUNYCODE_DAMP = 700
  PUNYCODE_INITIAL_BIAS = 72
  PUNYCODE_INITIAL_N = 128

  # Encodes a single Unicode domain label to its ASCII Punycode payload (without
  # the "xn--" prefix). Pure-Ruby RFC 3492 so the checker stays gem-free.
  def self.punycode_encode_label(input)
    input = input.to_s
    output = +""
    basic_chars = input.each_char.select { |char| char.ord < PUNYCODE_INITIAL_N }
    basic = basic_chars.length
    output << basic_chars.join
    output << "-" if basic.positive?
    n = PUNYCODE_INITIAL_N
    delta = 0
    bias = PUNYCODE_INITIAL_BIAS
    handled = basic
    input_len = input.length
    while handled < input_len
      next_codepoint = input.each_char.map(&:ord).select { |codepoint| codepoint >= n }.min
      delta += (next_codepoint - n) * (handled + 1)
      n = next_codepoint
      input.each_char do |char|
        codepoint = char.ord
        next delta += 1 if codepoint < n
        next unless codepoint == n

        q = delta
        k = PUNYCODE_BASE
        loop do
          t = k <= bias ? PUNYCODE_TMIN : (k >= bias + PUNYCODE_TMAX ? PUNYCODE_TMAX : k - bias)
          break if q < t

          output << punycode_digit(t + (q - t) % (PUNYCODE_BASE - t))
          q = (q - t) / (PUNYCODE_BASE - t)
          k += PUNYCODE_BASE
        end
        output << punycode_digit(q)
        bias = punycode_adapt(delta, handled + 1, handled == basic)
        delta = 0
        handled += 1
      end
      delta += 1
      n += 1
    end
    output
  end

  def self.punycode_digit(digit)
    (digit + (digit < 26 ? 97 : 22)).chr
  end
  private_class_method :punycode_digit

  def self.punycode_adapt(delta, num_points, first_time)
    delta = first_time ? delta / PUNYCODE_DAMP : delta / 2
    delta += delta / num_points
    k = 0
    while delta > ((PUNYCODE_BASE - PUNYCODE_TMIN) * PUNYCODE_TMAX) / 2
      delta /= PUNYCODE_BASE - PUNYCODE_TMIN
      k += PUNYCODE_BASE
    end
    k + (PUNYCODE_BASE - PUNYCODE_TMIN + 1) * delta / (delta + PUNYCODE_SKEW)
  end
  private_class_method :punycode_adapt

  # Encodes an Internationalized Domain Name host to ASCII (Punycode). Each
  # dot-separated label is encoded only if it contains non-ASCII characters,
  # producing "xn--<payload>"; pure-ASCII labels and bracketed IPv6 hosts are
  # returned unchanged so the method is a no-op for ordinary hosts.
  def self.punycode_encode_host(host)
    return host if host.nil? || host.empty?
    return host if host.start_with?("[") # IPv6 literal
    host.split(".").map do |label|
      label.ascii_only? ? label : "xn--#{punycode_encode_label(label)}"
    end.join(".")
  end

  def self.normalize(raw_url)
    ascii_url = ascii_host_url(raw_url.to_s.strip)
    uri = URI.parse(ascii_url)
    raise URI::InvalidURIError, "URL must use http or https" unless %w[http https].include?(uri.scheme&.downcase)
    raise URI::InvalidURIError, "URL must include a host" if uri.host.nil? || uri.host.empty?

    uri.scheme = uri.scheme.downcase
    uri.host = uri.host.downcase
    uri.fragment = nil
    uri.path = "/" if uri.path.nil? || uri.path.empty?
    uri.port = nil if (uri.scheme == "http" && uri.port == 80) || (uri.scheme == "https" && uri.port == 443)
    uri.to_s
  end

  # Replaces the host portion of a raw URL with its ASCII (Punycode) form so
  # that URI.parse can accept Internationalized Domain Names. Only the authority
  # host is touched; userinfo, port, path, query and fragment are preserved. If
  # the URL has no scheme the input is returned unchanged and left to URI.parse
  # to reject.
  def self.ascii_host_url(raw_url)
    scheme_match = raw_url.match(/\A([a-zA-Z][a-zA-Z0-9+.\-]*):\/\/(.*)\z/m)
    return raw_url unless scheme_match

    scheme = scheme_match[1]
    rest = scheme_match[2]
    authority_boundary = rest.index(/[\/?#]/)
    authority = authority_boundary ? rest[0...authority_boundary] : rest
    suffix = authority_boundary ? rest[authority_boundary..] : ""

    userinfo, host_and_port = authority.split("@", 2)
    if host_and_port.nil?
      host_and_port = userinfo
      userinfo = nil
    end

    # Separate the host from an optional port, taking care not to split on dots
    # inside an IPv6 literal like [::1]:8080.
    if host_and_port.start_with?("[")
      close = host_and_port.index("]")
      host = close ? host_and_port[0..close] : host_and_port
      remainder = close ? host_and_port[(close + 1)..] : ""
      port = remainder.start_with?(":") ? remainder : nil
    else
      host, port_part = host_and_port.split(":", 2)
      port = port_part && !port_part.empty? ? ":#{port_part}" : nil
    end

    ascii_host = punycode_encode_host(host)
    encoded_authority = [userinfo && "#{userinfo}@", ascii_host, port].compact.join
    "#{scheme}://#{encoded_authority}#{suffix}"
  end

  def self.key_for(kind, url)
    normalized = normalize(url)
    Digest::SHA256.hexdigest("#{kind}:#{normalized}")[0, 20]
  rescue URI::InvalidURIError
    Digest::SHA256.hexdigest("#{kind}:#{url}")[0, 20]
  end

  def self.healthy?(result)
    %w[ok redirect].include?(result["category"]) || [401, 403, 429].include?(result["status"].to_i)
  end

  def self.entries(data, path = [])
    collect_entries(data, path, "category_path" => [], "site_title" => nil, "site_url" => nil)
  end

  def self.collect_entries(data, path, context)
    case data
    when Array
      data.flat_map.with_index { |item, index| collect_entries(item, path + [index], context) }
    when Hash
      result = []
      derived = context.dup
      if data["name"].is_a?(String) && (data.key?("links") || data.key?("sub"))
        derived["category_path"] = derived["category_path"] + [data["name"]]
      end
      derived["site_title"] = data["title"] if path[-2] == "links"
      derived["site_url"] = data["url"] if path[-2] == "links" && data["url"].is_a?(String)
      if data["url"].is_a?(String) && data["url"].match?(%r{\Ahttps?://}i)
        kind = path.include?("icons") ? "icon" : "main"
        result << {
          "url" => data["url"], "kind" => kind, "title" => data["title"],
          "path" => (path + ["url"]).join("."),
          "site_title" => derived["site_title"],
          "site_url" => derived["site_url"],
          "site_category" => derived["category_path"].join(" / ")
        }
      end
      data.each do |key, value|
        result.concat(collect_entries(value, path + [key], derived)) if value.is_a?(Array) || value.is_a?(Hash)
      end
      result
    else
      []
    end
  end
  private_class_method :collect_entries

  def check(entry)
    normalized = self.class.normalize(entry.fetch("url"))
    response, final_url, redirects, method, attempts = request_with_retries(normalized)
    status = response.code.to_i
    category = category_for(status, redirects)
    result(entry, normalized, final_url, category, status: status, method: method,
                                                    redirects: redirects, attempts: attempts)
  rescue URI::InvalidURIError, ArgumentError => error
    result(entry, entry["url"], entry["url"], "invalid_url", error: error.message)
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => error
    result(entry, normalized || entry["url"], normalized || entry["url"], "timeout", error: error.message)
  rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse => error
    result(entry, normalized || entry["url"], normalized || entry["url"], "network_error", error: error.message)
  rescue StandardError => error
    result(entry, normalized || entry["url"], normalized || entry["url"], "network_error", error: "#{error.class}: #{error.message}")
  end

  private

  def request_with_retries(url)
    attempts = 0
    loop do
      attempts += 1
      response, final_url, redirects, method = request(url)
      return [response, final_url, redirects, method, attempts] unless TRANSIENT_STATUSES.include?(response.code.to_i) && attempts <= @retries

      sleep(2**(attempts - 1))
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, OpenSSL::SSL::SSLError
      raise if attempts > @retries

      sleep(2**(attempts - 1))
    end
  end

  def request(url)
    current = url
    redirects = []
    method = "HEAD"
    loop do
      response = perform(current, method)
      if HEAD_FALLBACK_STATUSES.include?(response.code.to_i) && method == "HEAD"
        method = "GET"
        response = perform(current, method)
      end
      unless response.is_a?(Net::HTTPRedirection)
        return [response, current, redirects, method]
      end

      raise Net::HTTPBadResponse, "too many redirects" if redirects.length >= MAX_REDIRECTS
      location = response["location"]
      raise Net::HTTPBadResponse, "redirect missing Location" if location.nil? || location.empty?

      current = self.class.normalize(URI.join(current, location).to_s)
      redirects << current
      method = "HEAD"
    end
  end

  def perform(url, method)
    uri = URI.parse(url)
    addresses = SafeNetwork.resolve_public!(uri.host, resolver: @resolver)
    @http.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      ipaddr: addresses.first,
      open_timeout: @timeout,
      read_timeout: @timeout
    ) do |http|
      request = method == "HEAD" ? Net::HTTP::Head.new(uri) : Net::HTTP::Get.new(uri)
      request["User-Agent"] = "kanjian-la-url-check/1.0"
      http.request(request)
    end
  end

  def category_for(status, redirects)
    return "redirect" if status.between?(200, 399) && !redirects.empty?
    return "ok" if status.between?(200, 399)
    return "client_error" if status.between?(400, 499)
    return "server_error" if status.between?(500, 599)

    "network_error"
  end

  def result(entry, normalized, final_url, category, details = {})
    key = self.class.key_for(entry.fetch("kind"), normalized)
    entry.merge(
      "key" => key,
      "normalized_url" => normalized,
      "final_url" => final_url,
      "category" => category
    ).merge(details.transform_keys(&:to_s))
  end
end

if $PROGRAM_NAME == __FILE__
  options = { input: "_data/sites.yml", output: nil, timeout: UrlCheck::DEFAULT_TIMEOUT, retries: UrlCheck::DEFAULT_RETRIES }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/check_urls.rb [options]"
    parser.on("--input PATH", "YAML site data (default: _data/sites.yml)") { |value| options[:input] = value }
    parser.on("--output PATH", "Write JSON to PATH (default: stdout)") { |value| options[:output] = value }
    parser.on("--timeout SECONDS", Integer, "Per-request timeout") { |value| options[:timeout] = value }
    parser.on("--retries COUNT", Integer, "Retries after first transient failure") { |value| options[:retries] = value }
  end.parse!

  data = YAML.safe_load_file(options[:input], permitted_classes: [], aliases: false)
  entries = UrlCheck.entries(data)
  checks = UrlCheck.new(timeout: options[:timeout], retries: options[:retries])
  results = entries.map { |entry| checks.check(entry) }
  payload = { "checked_at" => Time.now.utc.iso8601, "results" => results }
  json = JSON.pretty_generate(payload) + "\n"
  options[:output] ? File.write(options[:output], json) : $stdout.write(json)
end
