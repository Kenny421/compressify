# frozen_string_literal: true

require "test_helper"

class ModelLoopGuardTest < Minitest::Test
  class DummyModel
    include Compressify::Model
  end

  def test_attachment_touched_requires_explicit_marker
    model = DummyModel.new

    refute model.send(:compressify_attachment_touched?, :image)
  end

  def test_attachment_touched_returns_true_when_marked
    model = DummyModel.new
    model.send(:compressify_mark_attachment_touched!, :image)

    assert model.send(:compressify_attachment_touched?, :image)
  end
end
