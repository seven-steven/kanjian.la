# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/safe_network"

class SafeNetworkTest < Minitest::Test
  Resolver = Struct.new(:addresses) do
    def getaddresses(_host)
      addresses
    end
  end

  def test_rejects_non_public_ipv4_and_ipv6_addresses
    %w[127.0.0.1 10.0.0.1 169.254.169.254 224.0.0.1 ::1 fc00::1 fe80::1 ff02::1].each do |address|
      refute SafeNetwork.public_ip?(address), address
    end
  end

  def test_accepts_public_addresses
    assert SafeNetwork.public_ip?("1.1.1.1")
    assert SafeNetwork.public_ip?("2606:4700:4700::1111")
  end

  def test_rejects_host_when_any_resolved_address_is_non_public
    error = assert_raises(SafeNetwork::UnsafeDestinationError) do
      SafeNetwork.resolve_public!("example.test", resolver: Resolver.new(["1.1.1.1", "127.0.0.1"]))
    end
    assert_equal "host resolves to a non-public address", error.message
  end

  def test_distinguishes_empty_and_failed_dns_resolution
    empty_error = assert_raises(SafeNetwork::DnsError) do
      SafeNetwork.resolve_public!("example.test", resolver: Resolver.new([]))
    end
    assert_equal "host did not resolve", empty_error.message

    failed_resolver = Object.new
    def failed_resolver.getaddresses(_host)
      raise Resolv::ResolvError, "temporary DNS failure"
    end

    error = assert_raises(SafeNetwork::DnsError) do
      SafeNetwork.resolve_public!("example.test", resolver: failed_resolver)
    end
    assert_match(/cannot resolve host/, error.message)
  end
end
