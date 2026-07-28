#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "optparse"

options = { base: "origin/jekyll" }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/check_agent_diff.rb [--base REF]"
  parser.on("--base REF", "Compare working tree and index against REF (default: origin/jekyll)") { |ref| options[:base] = ref }
end.parse!

root = File.expand_path("..", __dir__)
Dir.chdir(root)

changed, status = Open3.capture2e("git", "diff", "--name-only", options[:base])
abort "error: cannot compare against #{options[:base]}" unless status.success?

paths = changed.lines.map(&:strip).reject(&:empty?).sort
abort "error: no changes against #{options[:base]}" if paths.empty?

allowed = lambda do |path|
  path == "_data/sites.yml" || path.match?(%r{\Aassets/image/logo/[A-Za-z0-9][A-Za-z0-9._-]*\z})
end
rejected = paths.reject(&allowed)
unless rejected.empty?
  warn "error: changes outside the allowed paths:"
  rejected.each { |path| warn "  #{path}" }
  exit 1
end

whitespace, whitespace_status = Open3.capture2e("git", "diff", "--check", options[:base])
unless whitespace_status.success?
  warn whitespace
  exit 1
end

paths.each { |path| puts path }
