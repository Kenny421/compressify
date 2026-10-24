# frozen_string_literal: true

require "test_helper"

class PurgeOriginalJobTest < Minitest::Test
  class FakeBlob
    attr_reader :attachments, :deleted, :destroyed

    def initialize(referenced: false, deletion_error: nil)
      @attachments = Object.new
      @attachments.define_singleton_method(:exists?) { referenced }
      @deletion_error = deletion_error
      @deleted = false
      @destroyed = false
    end

    def with_lock
      yield
    end

    def delete
      raise @deletion_error if @deletion_error

      @deleted = true
    end

    def destroy!
      @destroyed = true
    end
  end

  def test_unreferenced_blob_is_deleted_before_database_record
    blob = FakeBlob.new
    with_blob(blob) { Compressify::PurgeOriginalJob.new.perform(blob_id: 10) }

    assert blob.deleted
    assert blob.destroyed
  end

  def test_referenced_blob_is_preserved
    blob = FakeBlob.new(referenced: true)
    with_blob(blob) { Compressify::PurgeOriginalJob.new.perform(blob_id: 10) }

    refute blob.deleted
    refute blob.destroyed
  end

  def test_storage_failure_does_not_destroy_record
    blob = FakeBlob.new(deletion_error: IOError.new("storage unavailable"))
    assert_raises(IOError) do
      with_blob(blob) { Compressify::PurgeOriginalJob.new.perform(blob_id: 10) }
    end

    refute blob.destroyed
  end

  private

  def with_blob(blob)
    singleton = class << ActiveStorage::Blob; self; end
    had_method = ActiveStorage::Blob.respond_to?(:find_by)
    original = ActiveStorage::Blob.method(:find_by) if had_method

    singleton.define_method(:find_by) { |id:| id == 10 ? blob : nil }
    yield
  ensure
    if had_method
      singleton.define_method(:find_by, original)
    else
      singleton.remove_method(:find_by)
    end
  end
end
