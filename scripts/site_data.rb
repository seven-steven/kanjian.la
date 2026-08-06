# frozen_string_literal: true

require "yaml"
require "uri"
require_relative "punycode"

module SiteData
  Site = Struct.new(:category, :title, :url, :description, :logo, :icons, :source, keyword_init: true)
  REPLACEMENT_ICON = "ri-exchange-line"
  ICON_KINDS = %w[status info].freeze

  module_function

  def load_file(path)
    data = YAML.safe_load_file(path, aliases: true)
    raise ArgumentError, "sites data must be an array" unless data.is_a?(Array)

    data
  rescue Psych::Exception => error
    raise ArgumentError, "cannot parse #{path}: #{error.message}"
  end

  def sites(data, category = [], result = [])
    data.each do |section|
      raise ArgumentError, "section must be a mapping" unless section.is_a?(Hash)

      current_category = category + [section["name"]].compact
      links = section["links"]
      if links
        raise ArgumentError, "links must be an array" unless links.is_a?(Array)

        links.each do |link|
          raise ArgumentError, "link must be a mapping" unless link.is_a?(Hash)

          result << Site.new(
            category: current_category,
            title: link["title"],
            url: link["url"],
            description: link["description"],
            logo: link["logo"],
            icons: link["icons"],
            source: link
          )
        end
      end

      children = section["sub"]
      if children
        raise ArgumentError, "sub must be an array" unless children.is_a?(Array)

        sites(children, current_category, result)
      end
    end
    result
  end

  def read(path)
    sites(load_file(path))
  end

  def valid_http_url?(value)
    ascii_url = Punycode.ascii_host_url(value.to_s)
    uri = URI.parse(ascii_url)
    uri.is_a?(URI::HTTP) && !uri.host.nil? && !uri.host.empty?
  rescue URI::InvalidURIError
    false
  end

  def safe_logo_name?(value)
    value.is_a?(String) && !value.empty? &&
      value !~ %r{[\\/]} && value != "." && value != ".."
  end

  def replacement_icon?(icon)
    icon.is_a?(Hash) && icon["icon"] == REPLACEMENT_ICON
  end

  # Complete exchange icons are replacement candidates. Partial profiles remain
  # ordinary icons for backward compatibility.
  def replacement_profile?(icon)
    replacement_icon?(icon) && %w[title url description logo].all? { |key| nonempty_string?(icon[key]) }
  end

  def valid_replacement_profile?(icon, old_url:, logos:)
    return false unless replacement_profile?(icon)

    valid_http_url?(icon["url"]) && distinct_http_urls?(icon["url"], old_url) &&
      safe_logo_name?(icon["logo"]) && File.file?(File.join(logos, icon["logo"])) &&
      valid_icons?(icon["icons"])
  end

  def distinct_http_urls?(first, second)
    normalize_http_url(first) != normalize_http_url(second)
  rescue URI::InvalidURIError
    false
  end

  def normalize_http_url(value)
    ascii_url = Punycode.ascii_host_url(value.to_s.strip)
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

  def valid_icons?(icons)
    return true if icons.nil?
    return false unless icons.is_a?(Hash) && (icons.keys - ICON_KINDS).empty?

    icons.all? do |_kind, entries|
      entries.nil? || (entries.is_a?(Array) && entries.all? do |entry|
        entry.is_a?(Hash) && nonempty_string?(entry["icon"]) &&
          (!entry.key?("url") || valid_http_url?(entry["url"]))
      end)
    end
  end

  def nonempty_string?(value)
    value.is_a?(String) && !value.strip.empty?
  end
  private_class_method :nonempty_string?
end
