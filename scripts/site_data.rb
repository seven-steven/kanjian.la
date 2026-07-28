# frozen_string_literal: true

require "yaml"
require "uri"

module SiteData
  Site = Struct.new(:category, :title, :url, :description, :logo, :icons, :source, keyword_init: true)

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
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTP) && !uri.host.nil? && !uri.host.empty?
  rescue URI::InvalidURIError
    false
  end

  def safe_logo_name?(value)
    value.is_a?(String) && !value.empty? &&
      value !~ %r{[\\/]} && value != "." && value != ".."
  end
end
