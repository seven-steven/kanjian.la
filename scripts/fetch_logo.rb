#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "net/http"
require "optparse"
require "tempfile"
require "uri"
require_relative "safe_network"

module FetchLogo
  LOGO_DIR = File.expand_path("../assets/image/logo", __dir__)
  MAX_BYTES = 1 * 1024 * 1024
  REDIRECT_LIMIT = 5
  TYPES = {
    "image/png" => "png", "image/jpeg" => "jpeg", "image/webp" => "webp", "image/avif" => "avif"
  }.freeze

  module_function

  def safe_basename!(name)
    value = name.to_s
    unless value.match?(%r{\A[A-Za-z0-9][A-Za-z0-9._-]*\z}) && File.basename(value) == value && !value.include?("..")
      raise ArgumentError, "output must be a safe basename"
    end
    value
  end

  def fetch(url, basename, redirects: REDIRECT_LIMIT, resolver: Resolv, http: Net::HTTP)
    output = File.join(LOGO_DIR, safe_basename!(basename))
    uri = SafeNetwork.https_uri!(url)
    download(uri, output, redirects: redirects, resolver: resolver, http: http)
  end

  def download(uri, output, redirects:, resolver:, http:)
    addresses = SafeNetwork.resolve_public!(uri.host, resolver: resolver)
    response = nil
    http.start(
      uri.host,
      uri.port,
      use_ssl: true,
      ipaddr: addresses.first,
      open_timeout: 10,
      read_timeout: 20
    ) do |client|
      client.request(Net::HTTP::Get.new(uri.request_uri, { "User-Agent" => "kanjian.la logo fetcher" })) do |result|
        response = result
        break unless result.is_a?(Net::HTTPSuccess)

        content_type = result["content-type"].to_s.split(";", 2).first.downcase
        raise ArgumentError, "response is not an accepted image" unless TYPES.key?(content_type)

        FileUtils.mkdir_p(LOGO_DIR)
        Tempfile.create(["logo", ".download"], LOGO_DIR) do |file|
          file.binmode
          bytes = 0
          result.read_body do |chunk|
            bytes += chunk.bytesize
            raise ArgumentError, "response exceeds 1 MiB" if bytes > MAX_BYTES
            file.write(chunk)
          end
          file.flush
          file.rewind
          magic = file.read(16)
          raise ArgumentError, "image magic bytes do not match content type" unless valid_magic?(content_type, magic)

          raise ArgumentError, "output extension does not match content type" unless File.extname(output).downcase == ".#{TYPES.fetch(content_type).sub("jpeg", "jpg")}"
          FileUtils.mv(file.path, output)
        end
      end
    end

    if response.is_a?(Net::HTTPRedirection)
      raise ArgumentError, "too many redirects" if redirects.zero?
      location = response["location"]
      raise ArgumentError, "redirect without location" if location.nil? || location.empty?

      return download(URI.join(uri.to_s, location), output, redirects: redirects - 1, resolver: resolver, http: http)
    end
    raise ArgumentError, "request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    output
  end

  def valid_magic?(content_type, data)
    case content_type
    when "image/png" then data.start_with?("\x89PNG\r\n\x1A\n".b)
    when "image/jpeg" then data.start_with?("\xFF\xD8\xFF".b)
    when "image/webp" then data.start_with?("RIFF".b) && data.byteslice(8, 4) == "WEBP"
    when "image/avif" then data.byteslice(4, 8)&.include?("ftyp") && data.byteslice(8, 8)&.match?(/avif|avis/)
    else false
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { name: nil }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/fetch_logo.rb URL --name BASENAME"
    parser.on("-n", "--name BASENAME", "Safe basename under assets/image/logo") { |name| options[:name] = name }
  end.parse!
  url = ARGV.shift
  abort "error: URL is required" unless url
  abort "error: unexpected arguments" unless ARGV.empty?
  abort "error: --name is required" unless options[:name]

  begin
    puts FetchLogo.fetch(url, options[:name])
  rescue ArgumentError, URI::InvalidURIError, Net::OpenTimeout, Net::ReadTimeout, SocketError => error
    warn "error: #{error.message}"
    exit 1
  end
end
