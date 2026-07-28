#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "net/http"
require "optparse"
require "tempfile"
require "uri"

module FetchLogo
  EXTENSIONS = {
    "image/avif" => ".avif", "image/gif" => ".gif", "image/jpeg" => ".jpg",
    "image/png" => ".png", "image/svg+xml" => ".svg", "image/webp" => ".webp",
    "image/x-icon" => ".ico"
  }.freeze
  REDIRECT_LIMIT = 5

  module_function

  def fetch(url, output, redirects: REDIRECT_LIMIT)
    uri = URI.parse(url)
    raise ArgumentError, "URL must use http or https" unless uri.is_a?(URI::HTTP) && uri.host

    response = request(uri)
    if response.is_a?(Net::HTTPRedirection)
      raise ArgumentError, "too many redirects" if redirects.zero?

      location = response["location"]
      raise ArgumentError, "redirect without location" unless location

      return fetch(uri.merge(location).to_s, output, redirects: redirects - 1)
    end
    raise ArgumentError, "request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    content_type = response["content-type"].to_s.split(";", 2).first
    raise ArgumentError, "response is not an image" unless EXTENSIONS.key?(content_type)

    FileUtils.mkdir_p(File.dirname(output))
    Tempfile.create(["logo", EXTENSIONS.fetch(content_type)], File.dirname(output)) do |file|
      file.binmode
      file.write(response.body)
      file.flush
      FileUtils.mv(file.path, output)
    end
    output
  end

  def request(uri)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 20) do |http|
      http.request(Net::HTTP::Get.new(uri.request_uri, { "User-Agent" => "kanjian.la logo fetcher" }))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { output: nil }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/fetch_logo.rb URL --output PATH"
    parser.on("-o", "--output PATH", "Destination logo path") { |path| options[:output] = path }
  end.parse!
  url = ARGV.shift
  abort "error: URL is required" unless url
  abort "error: --output is required" unless options[:output]

  begin
    FetchLogo.fetch(url, options[:output])
  rescue ArgumentError, URI::InvalidURIError, Net::OpenTimeout, Net::ReadTimeout, SocketError => error
    warn "error: #{error.message}"
    exit 1
  end
end
