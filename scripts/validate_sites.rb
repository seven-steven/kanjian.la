#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "pathname"
require_relative "site_data"

options = {
  data: File.expand_path("../_data/sites.yml", __dir__),
  logos: File.expand_path("../assets/image/logo", __dir__)
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/validate_sites.rb [options]"
  parser.on("--data PATH", "Path to sites.yml") { |path| options[:data] = path }
  parser.on("--logos PATH", "Path to logo directory") { |path| options[:logos] = path }
end.parse!

errors = []
warnings = []

begin
  sites = SiteData.read(options[:data])
rescue ArgumentError => error
  warn "error: #{error.message}"
  exit 1
end

sites.each do |site|
  label = ([site.category.join(" / "), site.title].reject(&:nil?).join(" / "))
  errors << "#{label}: missing title" unless site.title.is_a?(String) && !site.title.strip.empty?
  errors << "#{label}: invalid url #{site.url.inspect}" unless SiteData.valid_http_url?(site.url)
  unless SiteData.safe_logo_name?(site.logo)
    errors << "#{label}: invalid logo #{site.logo.inspect}"
  else
    logo_path = File.join(options[:logos], site.logo)
    errors << "#{label}: logo not found #{site.logo}" unless File.file?(logo_path)
  end

  case site.icons
  when nil
    next
  when Array
    warnings << "#{label}: legacy icons array; use status/info mapping"
  when Hash
    unknown = site.icons.keys - ["status", "info"]
    errors << "#{label}: unsupported icons keys #{unknown.join(", ")}" unless unknown.empty?
    site.icons.each do |kind, icons|
      next if icons.nil?
      unless icons.is_a?(Array)
        errors << "#{label}: icons.#{kind} must be an array"
        next
      end
      icons.each_with_index do |icon, index|
        unless icon.is_a?(Hash) && icon["icon"].is_a?(String) && !icon["icon"].empty?
          errors << "#{label}: icons.#{kind}[#{index}] missing icon"
        end
        if icon.is_a?(Hash) && icon.key?("url") && !SiteData.valid_http_url?(icon["url"])
          errors << "#{label}: icons.#{kind}[#{index}] invalid url #{icon["url"].inspect}"
        end
      end
    end
  else
    errors << "#{label}: icons must be a mapping"
  end
end

warnings.sort.each { |message| warn "warning: #{message}" }
errors.sort.each { |message| warn "error: #{message}" }
exit(errors.empty? ? 0 : 1)
