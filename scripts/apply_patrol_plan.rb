#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "tempfile"
require "yaml"
require_relative "check_urls"
require_relative "site_data"
require_relative "remove_failed_url"

# Applies a URL patrol disposition plan to _data/sites.yml with line-level,
# byte-conservative edits. This is the execution layer of the URL patrol
# pipeline: check tooling emits entry keys, a human or agent curates them
# into a plan, and this script applies the plan. Promotion of replacement
# profiles is intentionally out of scope here — it stays with the
# remove_failed_url.rb pipeline.
#
# Plan format contract (JSON):
#
#   {
#     "actions": [
#       { "key": "<20-char hex>", "action": "remove" },
#       { "key": "<20-char hex>", "action": "replace_url",
#         "suggested_url": "https://replacement.example.com/" },
#       { "key": "<20-char hex>", "action": "defer" }
#     ]
#   }
#
# - `key` is `UrlCheck.key_for(kind, url)` — the first 20 hex chars of the
#   SHA-256 digest over "<kind>:<normalized url>", exactly as emitted by the
#   check/patrol tooling. Every action's key must resolve to exactly one
#   navigation entry; unknown or ambiguous keys fail that action only.
# - `remove` deletes the whole link record (main) or a single icon element
#   (icon). When the link's `icons.info` holds a unique complete
#   ri-exchange-line replacement profile the removal still happens, with a
#   warn in the result detail — promotion belongs to remove_failed_url.rb.
# - `replace_url` rewrites only the url value on its line (indentation,
#   quoting style and inline comments preserved) after normalizing
#   suggested_url the same way SiteData does (Punycode + lowercasing).
# - `defer` records the decision and touches nothing.
# - Actions apply serially: each one re-reads sites.yml, so line numbers are
#   never cached across actions.
# - Every applied change is verified by re-parsing the rewritten file, and an
#   entry whose logo is no longer referenced anywhere is pruned from the logo
#   directory (shared or missing logos are skipped), mirroring
#   remove_failed_url.rb.
class ApplyPatrolPlan
  # Resolved from the script location so the default does not depend on the
  # caller's working directory. Overridable via `logo_dir:` / `--logo-dir`
  # for tests, which must run against an isolated directory.
  DEFAULT_LOGO_DIR = File.expand_path("../assets/image/logo", __dir__)

  ACTIONS = %w[remove replace_url defer].freeze

  # Raised when an entry was removed but its now-orphaned logo file could not
  # be deleted. sites.yml was already written, so this surfaces as an error
  # outcome for the action instead of being swallowed.
  LogoRemovalError = Class.new(StandardError)

  def initialize(plan_path:, sites_path:, logo_dir: DEFAULT_LOGO_DIR, dry_run: false)
    @plan_path = plan_path
    @sites_path = sites_path
    @logo_dir = File.expand_path(logo_dir)
    @dry_run = dry_run
  end

  def call
    seen_keys = {}
    results = parse_plan.map { |action| apply_action(action, seen_keys) }
    { "results" => results, "summary" => summarize(results) }
  end

  private

  def parse_plan
    plan = JSON.parse(File.read(@plan_path))
    actions = plan.is_a?(Hash) ? plan["actions"] : nil
    raise ArgumentError, "plan must be a JSON object with an actions array" unless actions.is_a?(Array)

    actions
  end

  def apply_action(action, seen_keys)
    name = action["action"]
    key = action["key"]
    return error_result(action, "unknown action #{name.inspect}") unless ACTIONS.include?(name)
    return error_result(action, "missing plan key") unless key.is_a?(String) && !key.empty?
    return error_result(action, "duplicate key in plan") if seen_keys.key?(key)

    seen_keys[key] = true
    # Every action re-reads sites.yml, so earlier actions in the same plan are
    # reflected and no line number is cached across actions.
    source = decoded_source
    data = YAML.safe_load(source, permitted_classes: [], aliases: false)
    entry = single_entry(data, key)

    return apply_replace_url(action, key, entry, source) if name == "replace_url"
    return apply_remove(action, key, entry, source, data) if name == "remove"

    build_result(action, "deferred", "deferred: entry located, no changes made")
  rescue LogoRemovalError => error
    error_result(action, "entry removed, but cleanup failed: #{error.message}")
  rescue Psych::Exception, ArgumentError, IndexError, TypeError, SystemCallError => error
    error_result(action, "#{error.class}: #{error.message}")
  end

  def apply_replace_url(action, key, entry, source)
    suggested = action["suggested_url"]
    unless suggested.is_a?(String) && SiteData.valid_http_url?(suggested)
      raise ArgumentError, "suggested_url is missing or not a valid http(s) URL"
    end

    target = SiteData.normalize_http_url(suggested)
    old_url = entry.fetch("url")
    label = entry_label(entry)
    if @dry_run
      detail = "dry run: would replace #{entry["kind"]} url for #{label}: #{old_url} -> #{target}"
      return build_result(action, "dry_run", detail)
    end

    updated = replace_url_line(source, entry.fetch("path"), target)
    verify_replacement!(updated, entry.fetch("path"), target)
    atomic_write(updated)
    build_result(action, "success", "replaced #{entry["kind"]} url for #{label}: #{old_url} -> #{target}")
  end

  def apply_remove(action, key, entry, source, data)
    warn_note = entry["kind"] == "main" ? replacement_profile_warn(data, entry) : nil
    label = entry_label(entry)
    if @dry_run
      detail = "dry run: would remove #{entry["kind"]} entry #{label} (#{entry.fetch("url")})"
      detail = "#{warn_note} #{detail}" if warn_note
      return build_result(action, "dry_run", detail)
    end

    updated = remove_record(source, entry.fetch("path"))
    verify_removal!(updated, key)
    atomic_write(updated)
    removed_logo = remove_orphaned_logo(entry["logo"])
    detail = "removed #{entry["kind"]} entry #{label} (#{entry.fetch("url")})"
    detail = "#{warn_note} #{detail}" if warn_note
    build_result(action, "success", detail, logo_removed: removed_logo)
  end

  # A unique complete ri-exchange-line profile in icons.info would have been
  # promoted by the remove_failed_url.rb pipeline; this plan-driven script
  # only warns about the missed promotion and removes as instructed.
  def replacement_profile_warn(data, entry)
    record_path = entry.fetch("path").split(".")[0...-1].join(".")
    site = value_at_path(data, record_path)
    info = site.is_a?(Hash) ? site.dig("icons", "info") : nil
    profiles = Array(info).count { |icon| SiteData.replacement_profile?(icon) }
    return nil unless profiles == 1

    "warn: unique complete ri-exchange-line replacement profile in icons.info was not promoted " \
      "(promotion belongs to the remove_failed_url.rb pipeline);"
  end

  def single_entry(data, key)
    matches = entry_index(data)[key] || []
    raise ArgumentError, "key not found in sites.yml" if matches.empty?
    raise ArgumentError, "key matches #{matches.length} navigation entries; duplicate entries sharing kind+url require manual splitting in sites.yml" if matches.length > 1

    matches.first
  end

  # Indexes every navigation entry by the patrol key emitted by the check
  # tooling, so a plan key maps back to the entry it was generated from.
  def entry_index(data)
    UrlCheck.entries(data).each_with_object({}) do |entry, index|
      (index[UrlCheck.key_for(entry.fetch("kind"), entry.fetch("url"))] ||= []) << entry
    end
  end

  # Column-level URL rewriting needs character offsets: libyaml counts columns
  # in characters, so the source must be decoded as UTF-8 before slicing
  # lines. Jekyll data files are UTF-8 by definition.
  def decoded_source
    text = File.binread(@sites_path).force_encoding(Encoding::UTF_8)
    raise ArgumentError, "sites file is not valid UTF-8" unless text.valid_encoding?

    text
  end

  # Rewrites only the url value on its own line: everything before the value
  # (indentation, `url:`) and after it (inline comments) is kept verbatim, and
  # the quoting style follows the original line. libyaml reports scalar
  # columns inclusive of surrounding quotes, so the whole quoted span is
  # replaced with a re-quoted value of the same style.
  def replace_url_line(source, url_path, new_url)
    record, = record_nodes(Psych.parse(source), url_path)
    scalar = mapping_value(record, "url")
    unless scalar.is_a?(Psych::Nodes::Scalar)
      raise ArgumentError, "entry url must be a scalar"
    end
    if scalar.start_line != scalar.end_line
      raise ArgumentError, "url value spans multiple lines"
    end

    supported = [Psych::Nodes::Scalar::PLAIN, Psych::Nodes::Scalar::SINGLE_QUOTED, Psych::Nodes::Scalar::DOUBLE_QUOTED]
    raise ArgumentError, "unsupported url scalar style" unless supported.include?(scalar.style)

    quote = quote_char(scalar.style)
    lines = source.lines
    line = lines.fetch(scalar.start_line)
    unless line[scalar.start_column...scalar.end_column] == quote + scalar.value + quote
      raise ArgumentError, "sites.yml drifted from its parsed url value"
    end
    if quote.empty? && new_url.match?(/[\s#]/)
      raise ArgumentError, "replacement url would break a plain scalar"
    end

    rewritten = line[0...scalar.start_column] + quote + new_url + quote + line[scalar.end_column..]
    lines[0...scalar.start_line].join + rewritten + lines[(scalar.start_line + 1)..].to_a.join
  end

  def quote_char(style)
    if style == Psych::Nodes::Scalar::SINGLE_QUOTED
      "'"
    elsif style == Psych::Nodes::Scalar::DOUBLE_QUOTED
      "\""
    else
      ""
    end
  end

  def verify_replacement!(source, url_path, expected_url)
    data = YAML.safe_load(source, permitted_classes: [], aliases: false)
    actual = value_at_path(data, url_path)
    return if actual == expected_url

    raise ArgumentError, "replacement did not persist (found #{actual.inspect})"
  end

  def verify_removal!(source, key)
    data = YAML.safe_load(source, permitted_classes: [], aliases: false)
    return if (entry_index(data)[key] || []).empty?

    raise ArgumentError, "target remains after removal"
  end

  # Resolves a dotted entry path (e.g. `0.links.2.icons.info.1.url`) through
  # the loaded data, mirroring how UrlCheck.entries builds paths.
  def value_at_path(data, path)
    path.split(".").reduce(data) do |current, segment|
      if current.is_a?(Array)
        current.fetch(Integer(segment, 10))
      elsif current.is_a?(Hash)
        current.fetch(segment)
      else
        raise KeyError, "cannot descend into #{current.inspect} at #{segment.inspect}"
      end
    end
  end

  # Line-level record removal, mirroring scripts/remove_failed_url.rb: the
  # record spans from its start line to the line before its successor (or its
  # own end line), so only the target's lines are dropped and every other
  # byte — comments, blank lines, quoting — survives untouched.
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

    record_index = Integer(segments.pop, 10)
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
        current.children.fetch(Integer(segment, 10))
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

  # Deletes the removed entry's logo file iff it is no longer referenced by any
  # other entry in the (already rewritten) sites.yml, mirroring
  # scripts/remove_failed_url.rb. Re-reads the file from disk so the judgment
  # reflects the post-removal state. A shared logo is always preserved; only a
  # true orphan is deleted. A missing file is idempotent (nil); a file that
  # exists but cannot be deleted raises LogoRemovalError so the failure is loud.
  def remove_orphaned_logo(logo)
    return nil unless SiteData.safe_logo_name?(logo)

    data = YAML.safe_load(File.binread(@sites_path), permitted_classes: [], aliases: false)
    return nil if referenced_logos(data).include?(logo)

    File.delete(File.join(@logo_dir, logo))
    logo
  rescue Errno::ENOENT
    nil
  rescue SystemCallError => error
    raise LogoRemovalError, "logo #{logo.inspect} could not be deleted: #{error.message}"
  end

  # Every logo still referenced anywhere in sites.yml — main links and icon
  # entries alike — so the orphan check is correct whether the removed entry
  # was a main link or an icon carrying its own logo. Re-read from disk after
  # the rewrite so the judgment reflects post-removal state.
  def referenced_logos(data)
    UrlCheck.entries(data).map { |entry| entry["logo"] }.compact
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

  def entry_label(entry)
    entry["title"] ? "\"#{entry["title"]}\"" : "(untitled #{entry["kind"]} entry)"
  end

  def build_result(action, outcome, detail, logo_removed: nil)
    { "key" => action["key"], "action" => action["action"], "outcome" => outcome,
      "detail" => detail, "logo_removed" => logo_removed }
  end

  def error_result(action, detail)
    build_result(action, "error", detail)
  end

  def summarize(results)
    counts = { "success" => 0, "deferred" => 0, "error" => 0, "dry_run" => 0 }
    results.each { |result| counts[result.fetch("outcome")] += 1 }
    counts
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {
      sites: "_data/sites.yml",
      logo_dir: ApplyPatrolPlan::DEFAULT_LOGO_DIR,
      dry_run: false
    }
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby scripts/apply_patrol_plan.rb --plan PLAN_JSON [options]"
      parser.on("--plan PATH", "Patrol disposition plan (JSON)") { |value| options[:plan] = value }
      parser.on("--sites PATH", "YAML site data (default: _data/sites.yml)") { |value| options[:sites] = value }
      parser.on("--logo-dir PATH", "Logo directory to prune orphans from (default: assets/image/logo)") do |value|
        options[:logo_dir] = value
      end
      parser.on("--dry-run", "Report the changes that would be made without writing anything") do
        options[:dry_run] = true
      end
    end.parse!

    raise OptionParser::MissingArgument, "--plan" unless options[:plan]

    output = ApplyPatrolPlan.new(
      plan_path: options[:plan],
      sites_path: options[:sites],
      logo_dir: options[:logo_dir],
      dry_run: options[:dry_run]
    ).call
    $stdout.write(JSON.generate(output) + "\n")
    exit(output.dig("summary", "error").to_i.positive? ? 1 : 0)
  rescue OptionParser::ParseError, RuntimeError, Errno::ENOENT, JSON::ParserError => error
    $stdout.write(JSON.generate("result" => "error", "message" => error.message) + "\n")
    exit 1
  end
end
