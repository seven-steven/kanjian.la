# frozen_string_literal: true

# Pure-Ruby RFC 3492 Punycode encoding plus IDN authority normalization. Shared
# by the URL checker (scripts/check_urls.rb) and the site-data validator
# (scripts/site_data.rb) so both treat Internationalized Domain Names
# consistently. Has no gem dependencies and no network requires, keeping the
# validator lightweight.
module Punycode
  BASE = 36
  TMIN = 1
  TMAX = 26
  SKEW = 38
  DAMP = 700
  INITIAL_BIAS = 72
  INITIAL_N = 128
  # Whitespace, C0 control characters, DEL, and URL-delimiter characters that
  # must never appear inside a single host label. Matching these rejects a
  # malformed authority before it can be encoded into a parseable Punycode host.
  UNSAFE_LABEL_CHARS = /[\s\x00-\x1f\x7f\/?:#@&=+%]/

  module_function

  # Encodes a single Unicode domain label to its ASCII Punycode payload (without
  # the "xn--" prefix). Returns nil when the label is empty or contains
  # whitespace, control characters, or URL-delimiter characters, so a malformed
  # authority cannot be silently turned into a syntactically parseable host.
  def encode_label(input)
    text = input.to_s
    return nil if text.empty?
    return nil if UNSAFE_LABEL_CHARS.match?(text)

    output = +""
    basic_chars = text.each_char.select { |char| char.ord < INITIAL_N }
    basic = basic_chars.length
    output << basic_chars.join
    output << "-" if basic.positive?
    n = INITIAL_N
    delta = 0
    bias = INITIAL_BIAS
    handled = basic
    input_len = text.length
    while handled < input_len
      next_codepoint = text.each_char.map(&:ord).select { |codepoint| codepoint >= n }.min
      delta += (next_codepoint - n) * (handled + 1)
      n = next_codepoint
      text.each_char do |char|
        codepoint = char.ord
        next delta += 1 if codepoint < n
        next unless codepoint == n

        q = delta
        k = BASE
        loop do
          t = k <= bias ? TMIN : (k >= bias + TMAX ? TMAX : k - bias)
          break if q < t

          output << digit(t + (q - t) % (BASE - t))
          q = (q - t) / (BASE - t)
          k += BASE
        end
        output << digit(q)
        bias = adapt(delta, handled + 1, handled == basic)
        delta = 0
        handled += 1
      end
      delta += 1
      n += 1
    end
    output
  end

  def digit(digit)
    (digit + (digit < 26 ? 97 : 22)).chr
  end
  private_class_method :digit

  def adapt(delta, num_points, first_time)
    delta = first_time ? delta / DAMP : delta / 2
    delta += delta / num_points
    k = 0
    while delta > ((BASE - TMIN) * TMAX) / 2
      delta /= BASE - TMIN
      k += BASE
    end
    k + (BASE - TMIN + 1) * delta / (delta + SKEW)
  end
  private_class_method :adapt

  # Encodes an Internationalized Domain Name host to ASCII (Punycode). Each
  # dot-separated label is encoded only if it contains non-ASCII characters,
  # producing "xn--<payload>"; pure-ASCII labels and bracketed IPv6 hosts are
  # returned unchanged so the method is a no-op for ordinary hosts. A label
  # that fails the encode_label safety check is returned unchanged so the
  # caller's parser can reject the original input.
  def encode_host(host)
    return host if host.nil? || host.empty?
    return host if host.start_with?("[") # IPv6 literal

    host.split(".").map do |label|
      next label if label.ascii_only?

      encoded = encode_label(label)
      encoded ? "xn--#{encoded}" : label
    end.join(".")
  end

  # Replaces the host portion of a raw URL with its ASCII (Punycode) form so
  # that URI.parse can accept Internationalized Domain Names. Only the authority
  # host is touched; userinfo, port, path, query and fragment are preserved. If
  # the URL has no scheme the input is returned unchanged and left to URI.parse
  # to reject.
  def ascii_host_url(raw_url)
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

    ascii_host = encode_host(host)
    encoded_authority = [userinfo && "#{userinfo}@", ascii_host, port].compact.join
    "#{scheme}://#{encoded_authority}#{suffix}"
  end
end
