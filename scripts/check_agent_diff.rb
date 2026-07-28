#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "optparse"

options = { base: "HEAD" }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/check_agent_diff.rb [--base REF]"
  parser.on("--base REF", "Compare against REF (default: HEAD)") { |ref| options[:base] = ref }
end.parse!

root = File.expand_path("..", __dir__)
Dir.chdir(root)

changed, status = Open3.capture2("git", "diff", "--name-only", "#{options[:base]}...HEAD")
abort "error: cannot compare against #{options[:base]}" unless status.success?

paths = changed.lines.map(&:strip).reject(&:empty?).sort
if paths.empty?
  puts "No committed changes since #{options[:base]}."
  exit 0
end

paths.each { |path| puts path }

whitespace, whitespace_status = Open3.capture2e("git", "diff", "--check", "#{options[:base]}...HEAD")
if whitespace_status.success?
  exit 0
else
  warn whitespace
  exit 1
end
