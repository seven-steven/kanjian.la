#!/usr/bin/env ruby
# frozen_string_literal: true

require "ipaddr"
require "resolv"
require "uri"

# Shared SSRF protections for scripts that make external HTTP requests.
module SafeNetwork
  IPV4_DENYLIST = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24
    192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
    224.0.0.0/4 240.0.0.0/4
  ].map { |range| IPAddr.new(range) }.freeze
  IPV6_DENYLIST = %w[
    ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 2001:db8::/32
    2001:10::/28 2002::/16
  ].map { |range| IPAddr.new(range) }.freeze

  DnsError = Class.new(ArgumentError)
  UnsafeDestinationError = Class.new(ArgumentError)

  module_function

  def https_uri!(value)
    uri = URI.parse(value.to_s)
    raise ArgumentError, "URL must use https" unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty?

    uri
  end

  def public_ip?(address)
    ip = IPAddr.new(address.to_s)
    return public_ip?(ip.native.to_s) if ip.ipv4_mapped?

    ranges = ip.ipv4? ? IPV4_DENYLIST : IPV6_DENYLIST
    !ranges.any? { |range| range.include?(ip) }
  rescue IPAddr::InvalidAddressError
    false
  end

  def resolve_public!(host, resolver: Resolv)
    addresses = resolver.getaddresses(host)
    raise DnsError, "host did not resolve" if addresses.empty?

    rejected = addresses.reject { |address| public_ip?(address) }
    unless rejected.empty?
      raise UnsafeDestinationError, "host resolves to a non-public address"
    end

    addresses
  rescue Resolv::ResolvError, SocketError => error
    raise DnsError, "cannot resolve host: #{error.message}"
  end

  def validate_uri!(uri, resolver: Resolv)
    https_uri!(uri.to_s)
    resolve_public!(uri.host, resolver: resolver)
    uri
  end
end
