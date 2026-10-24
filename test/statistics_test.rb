# frozen_string_literal: true

require "test_helper"

class StatisticsTest < Minitest::Test
  FakeBlob = Struct.new(:metadata)
  class FakeRelation
    attr_reader :conditions

    def initialize(blobs)
      @blobs = blobs
      @conditions = []
    end

    def where(*arguments)
      @conditions << arguments
      self
    end

    def find_each(batch_size:)
      raise ArgumentError unless batch_size.positive?
      @blobs.each { |blob| yield blob }
    end
  end

  def test_summary_reports_bytes_savings_from_retained_metadata
    key = Compressify.config.metadata_key
    blobs = [
      FakeBlob.new({ key => {
        "mode" => "image", "source_byte_size" => 1000,
        "compressed_byte_size" => 250, "processing_ms" => 12.5
      } }),
      FakeBlob.new(key => {
        "mode" => "video", "source_byte_size" => 10_000,
        "compressed_byte_size" => 5000, "processing_ms" => 37.5
      } }),
      FakeBlob.new({ key => { "mode" => "image", "source_byte_size" => "bad" } }),
      FakeBlob.new({ "other" => "unrelated" })
    ]
    relation = FakeRelation.new(blobs)
    report = Compressify::Statistics.summary(scope: relation, since: Time.utc(2026, 1, 1))

    assert_equal 2, report[:count]
    assert_equal 11_000, report[:source_bytes]
    assert_equal 5250, report[:compressed_bytes]
    assert_equal 5750, report[:bytes_saved]
    assert_equal 52.27, report[:percent_saved]
    assert_equal 25.0, report[:average_processing_ms]
    assert_equal 1, report[:by_mode]["image"][:count]
    assert_equal 1, report[:by_mode]["video"][:count]
    assert_equal 2, relation.conditions.size
  end

  def test_empty_statistics_have_safe_defaults
    report = Compressify::Statistics.summary(scope: FakeRelation.new([]))
    assert_equal 0, report[:count]
    assert_equal 0, report[:bytes_saved]
    assert_equal 0.0, report[:percent_saved]
    assert_nil report[:average_processing_ms]
  end
end
