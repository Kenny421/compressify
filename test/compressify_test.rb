# frozen_string_literal: true

require "test_helper"

class CompressifyTest < Minitest::Test
  def test_version_present
    refute_nil Compressify::VERSION
  end
end
