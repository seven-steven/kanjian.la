#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "tempfile"
require "yaml"
require_relative "check_urls"
require_relative "url_issue_state"

# Removes one persistently failing main URL after an atomic local preflight.
class UrlRemovalProcessor
  def initialize(issue_body:, sites_path:, checker: UrlCheck.new)
    @issue_body = issue_body
    @sites_path = sites_path
    @checker = checker
  end

  def call
    state = UrlIssueState.parse_issue(@issue_body)
    return no_op("URL is not a main navigation entry") unless state.fetch("kind") == "main"
    return no_op("URL has fewer than #{UrlIssueState::FAILURE_THRESHOLD} consecutive failures") unless state.fetch("consecutive_failures") >= UrlIssueState::FAILURE_THRESHOLD

    source = File.binread(@sites_path)
    data = YAML.safe_load(source, permitted_classes: [], aliases: false)
    matches = matching_entries(data, state)
    return no_op("current navigation entry is missing or ambiguous") unless matches.length == 1

    entry = matches.first
    result = @checker.check(entry)
    return no_op("URL recovered or could not be confirmed unhealthy") unless confirmed_failure?(result)

    updated = remove_record(source, entry.fetch("path"))
    verify_removal!(updated, state)
    atomic_write(updated)
    { "result" => "removed", "message" => "removed persistently failing URL", "path" => entry.fetch("path") }
  rescue UrlIssueState::InvalidState => error
    raise error
  rescue Psych::Exception, Errno::ENOENT, ArgumentError => error
    raise RuntimeError, "cannot process URL removal: #{error.message}"
  rescue StandardError
    no_op("URL could not be confirmed unhealthy")
  end

  private

  def matching_entries(data, state)
    UrlCheck.entries(data).select do |entry|
      next false unless entry["kind"] == "main"

      normalized = UrlCheck.normalize(entry.fetch("url"))
      normalized == state.fetch("normalized_url") &&
        UrlCheck.key_for(entry.fetch("kind"), normalized) == state.fetch("key")
    rescue URI::InvalidURIError
      false
    end
  end

  def confirmed_failure?(result)
    return false if UrlCheck.healthy?(result)
    return false unless result["status"].is_a?(Integer)

    %w[client_error server_error].include?(result["category"])
  end

  def remove_record(source, url_path)
    record, following = record_nodes(Psych.parse(source), url_path)
    lines = source.lines
    start_line = record.start_line
    end_line = following ? following.start_line - 1 : record.end_line
    raise ArgumentError, "invalid record line range" unless start_line && end_line && start_line <= end_line

    lines[0...start_line].join + lines[(end_line + 1)..].to_a.join
  end

  def record_nodes(document, url_path)
    segments = url_path.split(".")
    raise ArgumentError, "invalid entry path" unless segments.pop == "url"

    record_index = Integer(segments.pop)
    links_key = segments.pop
    raise ArgumentError, "invalid entry path" unless links_key == "links"

    node = document.children.first
    segments.each do |segment|
      node = if node.is_a?(Psych::Nodes::Sequence)
               node.children.fetch(Integer(segment))
             else
               mapping_value(node, segment)
             end
    end
    node = mapping_value(node, links_key)
    raise ArgumentError, "links must be a sequence" unless node.is_a?(Psych::Nodes::Sequence)

    record = node.children.fetch(record_index)
    raise ArgumentError, "navigation record must be a mapping" unless record.is_a?(Psych::Nodes::Mapping)

    [record, node.children[record_index + 1]]
  rescue IndexError, KeyError
    raise ArgumentError, "entry changed during removal"
  end

  def mapping_value(mapping, key)
    raise ArgumentError, "expected YAML mapping" unless mapping.is_a?(Psych::Nodes::Mapping)

    pair = mapping.children.each_slice(2).find { |name, _value| name.value == key }
    raise KeyError, key unless pair

    pair.last
  end

  def verify_removal!(source, state)
    data = YAML.safe_load(source, permitted_classes: [], aliases: false)
    remaining = matching_entries(data, state)
    raise ArgumentError, "target remains after removal" unless remaining.empty?
  end

  def atomic_write(content)
    directory = File.dirname(File.expand_path(@sites_path))
    Tempfile.create([".sites", ".yml"], directory) do |file|
      file.write(content)
      file.flush
      file.fsync
      File.rename(file.path, @sites_path)
    end
  end

  def no_op(message)
    { "result" => "not_removed", "message" => message }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = { sites: "_data/sites.yml", timeout: UrlCheck::DEFAULT_TIMEOUT, retries: UrlCheck::DEFAULT_RETRIES }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/remove_failed_url.rb --input ISSUE_BODY [options]"
    parser.on("--input PATH", "Issue body file") { |value| options[:input] = value }
    parser.on("--sites PATH", "YAML site data (default: _data/sites.yml)") { |value| options[:sites] = value }
    parser.on("--timeout SECONDS", Integer, "Per-request timeout") { |value| options[:timeout] = value }
    parser.on("--retries COUNT", Integer, "Retries after first transient failure") { |value| options[:retries] = value }
  end.parse!

  raise OptionParser::MissingArgument, "--input" unless options[:input]

  body = File.read(options[:input])
  output = UrlRemovalProcessor.new(
    issue_body: body,
    sites_path: options[:sites],
    checker: UrlCheck.new(timeout: options[:timeout], retries: options[:retries])
  ).call
  $stdout.write(JSON.generate(output) + "\n")
  rescue UrlIssueState::InvalidState => error
  $stdout.write(JSON.generate("result" => "not_removed", "message" => error.message) + "\n")
  exit 0
  rescue OptionParser::ParseError, RuntimeError, Errno::ENOENT => error
  $stdout.write(JSON.generate("result" => "error", "message" => error.message) + "\n")
  exit 1
  end
end
