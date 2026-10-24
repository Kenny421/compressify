# frozen_string_literal: true

require "test_helper"

class ConfigDefaultsTest < Minitest::Test
  def test_efficiency_defaults
    cfg = Compressify::Config.new

    assert_equal 8, cfg.image_max_concurrency
    assert_equal 2, cfg.video_max_concurrency
    assert_equal 100.megabytes, cfg.max_download_bytes
    assert_equal 50.kilobytes, cfg.image_min_bytes_for_compression
    assert_equal true, cfg.adaptive_quality_enabled
    assert_equal 60, cfg.adaptive_quality_min
    assert_equal 4_000_000, cfg.adaptive_quality_large_image_pixels
    assert_equal 3.megabytes, cfg.adaptive_quality_large_file_bytes
    assert_equal true, cfg.reuse_existing_derivatives
    assert_equal 80, cfg.default_image_options[:quality]
    assert_equal false, cfg.skip_if_no_resize_needed
    assert_equal true, cfg.skip_larger_output
    assert_equal false, cfg.postgres_fingerprint_lookup
  end
end
