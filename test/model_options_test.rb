# frozen_string_literal: true

require "test_helper"

class ModelOptionsTest < Minitest::Test
  class DummyModel
    include Compressify::Model
  end

  def setup
    @model = DummyModel.new
  end

  def test_size_width_only_keeps_two_slot_resize_array
    opts = { size: "600x" }
    normalized = @model.send(:compressify_normalize_options, opts)

    assert_equal [600, nil], normalized[:resize_to_limit]
  end

  def test_size_height_only_keeps_two_slot_resize_array
    opts = { size: "x600" }
    normalized = @model.send(:compressify_normalize_options, opts)

    assert_equal [nil, 600], normalized[:resize_to_limit]
  end

  def test_size_bang_enables_resize_to_fill_for_exact_dimensions
    opts = { size: "600x600!" }
    normalized = @model.send(:compressify_normalize_options, opts)

    assert_equal [600, 600], normalized[:resize_to_fill]
    assert_nil normalized[:resize_to_limit]
  end

  def test_size_bang_with_single_dimension_falls_back_to_resize_to_limit
    opts = { size: "600x!" }
    normalized = @model.send(:compressify_normalize_options, opts)

    assert_equal [600, nil], normalized[:resize_to_limit]
    assert_nil normalized[:resize_to_fill]
  end
end
