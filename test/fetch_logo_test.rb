# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/fetch_logo"

class FetchLogoTest < Minitest::Test
  def test_requires_https
    error = assert_raises(ArgumentError) { FetchLogo.fetch("http://example.com/logo.png", "logo.png") }
    assert_equal "URL must use https", error.message
  end

  def test_rejects_unsafe_output_basename
    %w[../logo.png /tmp/logo.png nested/logo.png . ..].each do |name|
      assert_raises(ArgumentError) { FetchLogo.safe_basename!(name) }
    end
  end

  def test_accepts_safe_output_basename
    assert_equal "example-logo_2.png", FetchLogo.safe_basename!("example-logo_2.png")
  end

  def test_recognizes_only_allowed_image_magic_bytes
    assert FetchLogo.valid_magic?("image/png", "\x89PNG\r\n\x1A\nbody".b)
    assert FetchLogo.valid_magic?("image/jpeg", "\xFF\xD8\xFFbody".b)
    assert FetchLogo.valid_magic?("image/webp", "RIFFxxxxWEBPbody".b)
    refute FetchLogo.valid_magic?("image/png", "<svg".b)
    refute FetchLogo.valid_magic?("image/png", "GIF89a".b)
    refute FetchLogo.valid_magic?("image/png", "\x00\x00\x01\x00".b)
  end
end
