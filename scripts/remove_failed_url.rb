#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "tempfile"
require "yaml"
require_relative "check_urls"
require_relative "site_data"
require_relative "url_issue_state"

# Removes one persistently failing navigation entry — either a main URL (the
# whole link record) or a single icon entry (one item of a site's `icons`
# collection) — after an atomic local preflight.
class UrlRemovalProcessor
  # Resolved from the script location so the default does not depend on the
  # caller's working directory. Overridable via `logo_dir:` / `--logo-dir` for
  # tests and the scope-check workflow, which must run against an isolated
  # directory rather than the live checkout.
  DEFAULT_LOGO_DIR = File.expand_path("../assets/image/logo", __dir__)

  # Raised when a site record was removed but its now-orphaned logo file could
  # not be deleted. Distinct from the generic `rescue StandardError` so the
  # post-write failure is not swallowed into a misleading "not_removed".
  LogoRemovalError = Class.new(StandardError)

  def initialize(issue_body:, sites_path:, logo_dir: DEFAULT_LOGO_DIR, checker: UrlCheck.new)
    @issue_body = issue_body
    @sites_path = sites_path
    @logo_dir = File.expand_path(logo_dir)
    @checker = checker
  end

  def call
    state = UrlIssueState.parse_issue(@issue_body)
    return no_op("URL is not a main or icon navigation entry") unless %w[main icon].include?(state.fetch("kind"))
    return no_op("URL has fewer than #{UrlIssueState::FAILURE_THRESHOLD} consecutive failures") unless state.fetch("consecutive_failures") >= UrlIssueState::FAILURE_THRESHOLD

    source = File.binread(@sites_path)
    data = YAML.safe_load(source, permitted_classes: [], aliases: false)
    matches = matching_entries(data, state)
    return no_op("current navigation entry is missing or ambiguous") unless matches.length == 1

    entry = matches.first
    result = @checker.check(entry)
    return no_op("URL recovered or could not be confirmed unhealthy") unless confirmed_failure?(result)

    updated, promotion = if state.fetch("kind") == "main"
      promote_or_remove(source, data, entry)
    else
      [remove_record(source, entry.fetch("path")), nil]
    end
    verify_removal!(updated, state)
    atomic_write(updated)
    removed_logo = remove_orphaned_logo(entry["logo"])
    if promotion
      promotion.merge("removed_logo" => removed_logo)
    else
      { "result" => "removed", "message" => "removed persistently failing URL",
        "path" => entry.fetch("path"), "removed_logo" => removed_logo }
    end
  rescue LogoRemovalError => error
    # sites.yml was already written; a post-write logo failure must surface as an
    # error rather than degrading to a misleading "not_removed".
    raise RuntimeError, error.message
  rescue UrlIssueState::InvalidState => error
    raise error
  rescue Psych::Exception, Errno::ENOENT, ArgumentError => error
    raise RuntimeError, "cannot process URL removal: #{error.message}"
  rescue StandardError
    no_op("URL could not be confirmed unhealthy")
  end

  private

  def matching_entries(data, state)
    kind = state.fetch("kind")
    UrlCheck.entries(data).select do |entry|
      next false unless entry["kind"] == kind

      normalized = UrlCheck.normalize(entry.fetch("url"))
      normalized == state.fetch("normalized_url") &&
        UrlCheck.key_for(entry.fetch("kind"), normalized) == state.fetch("key")
    rescue URI::InvalidURIError
      false
    end
  end

  # A URL is a confirmed failure only when it is both unhealthy and in a known
  # failure category. `healthy?` already excludes ok/redirect and the
  # access-restricted 401/403/429 (a paywall or rate limit is not a dead site).
  # The allowlist then admits every category the checker can emit for a genuine
  # failure — including timeout, network_error and invalid_url, whose status is
  # nil — so a persistently failing URL is removable regardless of how it
  # failed. The list is explicit on purpose: an unrecognized category stays
  # fail-closed (not removed) rather than being silently treated as removable.
  def confirmed_failure?(result)
    return false if UrlCheck.healthy?(result)

    %w[client_error server_error timeout network_error invalid_url].include?(result["category"])
  end

  def promote_or_remove(source, data, entry)
    candidates = replacement_candidates(data, entry)
    return [remove_record(source, entry.fetch("path")), nil] unless candidates.length == 1

    candidate = candidates.first
    result = @checker.check(candidate.fetch("entry"))
    return [remove_record(source, entry.fetch("path")), nil] unless UrlCheck.healthy?(result)

    [replace_record(source, entry.fetch("path"), promoted_record(candidate)), promotion_result(entry, candidate)]
  end

  def replacement_candidates(data, entry)
    site = site_at_path(data, entry.fetch("path"))
    return [] unless site.is_a?(Hash) && site["icons"].is_a?(Hash)

    Array(site["icons"]["info"]).filter_map.with_index do |icon, index|
      next unless SiteData.valid_replacement_profile?(icon, old_url: entry.fetch("url"), logos: @logo_dir)

      { "icon" => icon, "index" => index,
        "entry" => { "url" => icon["url"], "kind" => "main", "title" => icon["title"], "logo" => icon["logo"] } }
    end
  end

  def site_at_path(data, url_path)
    segments = url_path.split(".")
    return nil unless segments.pop == "url"

    record_index = Integer(segments.pop)
    container = segments.reduce(data) { |current, segment| current.is_a?(Array) ? current[Integer(segment)] : current[segment] }
    container.is_a?(Array) ? container[record_index] : nil
  rescue TypeError, ArgumentError
    nil
  end

  def promoted_record(candidate)
    icon = candidate.fetch("icon")
    record = icon.slice("title", "url", "description", "logo")
    record["icons"] = icon["icons"] if icon.key?("icons")
    YAML.dump(record).lines.drop(1).join
  end

  def promotion_result(entry, candidate)
    icon = candidate.fetch("icon")
    { "result" => "promoted", "message" => "promoted replacement URL",
      "path" => entry.fetch("path"), "old_url" => entry.fetch("url"), "new_url" => icon.fetch("url"),
      "old_title" => entry["title"], "new_title" => icon.fetch("title"),
      "old_logo" => entry["logo"], "new_logo" => icon.fetch("logo") }
  end

  def replace_record(source, url_path, replacement)
    record, following = record_nodes(Psych.parse(source), url_path)
    lines = source.lines
    start_line = record.start_line
    end_line = following ? following.start_line - 1 : record.end_line - 1
    raise ArgumentError, "invalid record line range" unless start_line && end_line && start_line <= end_line

    indentation = lines[start_line][/\A\s*/]
    replacement_lines = replacement.lines.each_with_index.map do |line, index|
      indentation + (index.zero? ? "- " : "  ") + line
    end
    lines[0...start_line].join + replacement_lines.join + lines[(end_line + 1)..].to_a.join
  end

  def remove_record(source, url_path)
    record, following = record_nodes(Psych.parse(source), url_path)
    lines = source.lines
    start_line = record.start_line
    end_line = following ? following.start_line - 1 : record.end_line - 1
    raise ArgumentError, "invalid record line range" unless start_line && end_line && start_line <= end_line

    lines[0...start_line].join + lines[(end_line + 1)..].to_a.join
  end

  # Walks the parsed YAML document to the sequence that contains the target
  # record, then returns `[record, following]` where `record` is the mapping at
  # `record_index` and `following` is its immediate successor (or nil). The
  # entry path is the dotted form produced by `UrlCheck.entries`, always ending
  # in `.url`; peeling `url` and the integer `record_index` leaves the container
  # path that names the enclosing sequence — e.g. `0.links` for a main link,
  # `2.sub.6.links.15.icons.info` for a status/info icon, or
  # `0.links.14.icons` for a legacy icons array.
  def record_nodes(document, url_path)
    segments = url_path.split(".")
    raise ArgumentError, "invalid entry path" unless segments.pop == "url"

    record_index = Integer(segments.pop)
    container_path = segments

    sequence = container_path.empty? ? document.root : walk(document.root, container_path)
    raise ArgumentError, "navigation container must be a sequence" unless sequence.is_a?(Psych::Nodes::Sequence)

    record = sequence.children.fetch(record_index)
    raise ArgumentError, "navigation record must be a mapping" unless record.is_a?(Psych::Nodes::Mapping)

    [record, sequence.children[record_index + 1]]
  rescue IndexError, KeyError
    raise ArgumentError, "entry changed during removal"
  end

  # Descends one segment at a time. Integer segments index into a sequence's
  # children; string segments select a mapping value by key. This mirrors how
  # `UrlCheck.entries` builds paths, so the same path round-trips through the
  # AST regardless of whether it crosses arrays (`links`, `icons`) or mappings
  # (`sub`, `info`, `status`).
  def walk(node, segments)
    segments.reduce(node) do |current, segment|
      raise ArgumentError, "expected a YAML node to descend into" if current.nil?

      if current.is_a?(Psych::Nodes::Sequence)
        current.children.fetch(Integer(segment))
      else
        mapping_value(current, segment)
      end
    end
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

  # Deletes the removed entry's logo file iff it is no longer referenced by any
  # other entry in the (already rewritten) sites.yml. Re-reads the file from
  # disk so the judgment reflects the post-removal state. A shared logo (e.g.
  # github.com.svg) is always preserved; only a true orphan is deleted.
  #
  # Returns the logo filename when a file was deleted, nil otherwise (shared,
  # missing, unsafe name, or no logo). A missing file is idempotent (nil); a
  # file that exists but cannot be deleted raises so the workflow fails loudly.
  def remove_orphaned_logo(logo)
    return nil unless SiteData.safe_logo_name?(logo)

    data = YAML.safe_load_file(@sites_path, permitted_classes: [], aliases: false)
    return nil if referenced_logos(data).include?(logo)

    File.delete(File.join(@logo_dir, logo))
    logo
  rescue Errno::ENOENT
    nil
  rescue SystemCallError => error
    raise LogoRemovalError, "entry removed, but logo #{logo.inspect} could not be deleted: #{error.message}"
  end

  # Every logo still referenced anywhere in sites.yml — main links and icon
  # entries alike — so the orphan check is correct whether the removed entry
  # was a main link (its `logo`) or an icon (an icon mapping may also carry its
  # own `logo`). Re-read from disk after the rewrite so the judgment reflects
  # post-removal state.
  def referenced_logos(data)
    UrlCheck.entries(data).filter_map { |entry| entry["logo"] }
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
    options = {
      sites: "_data/sites.yml",
      logo_dir: UrlRemovalProcessor::DEFAULT_LOGO_DIR,
      timeout: UrlCheck::DEFAULT_TIMEOUT,
      retries: UrlCheck::DEFAULT_RETRIES
    }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/remove_failed_url.rb --input ISSUE_BODY [options]"
    parser.on("--input PATH", "Issue body file") { |value| options[:input] = value }
    parser.on("--sites PATH", "YAML site data (default: _data/sites.yml)") { |value| options[:sites] = value }
    parser.on("--logo-dir PATH", "Logo directory to prune orphans from (default: assets/image/logo)") do |value|
      options[:logo_dir] = value
    end
    parser.on("--timeout SECONDS", Integer, "Per-request timeout") { |value| options[:timeout] = value }
    parser.on("--retries COUNT", Integer, "Retries after first transient failure") { |value| options[:retries] = value }
  end.parse!

  raise OptionParser::MissingArgument, "--input" unless options[:input]

  body = File.read(options[:input])
  output = UrlRemovalProcessor.new(
    issue_body: body,
    sites_path: options[:sites],
    logo_dir: options[:logo_dir],
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
