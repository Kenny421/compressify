# frozen_string_literal: true

require "test_helper"

unless defined?(ActiveStorage::Attachment)
  module ActiveStorage
    class Attachment
    end
  end
end

class JobIdempotencyTest < Minitest::Test
  FakeFilename = Struct.new(:extension_without_delimiter)
  FakeBlob = Struct.new(:content_type, :filename)
  FakeAttachment = Struct.new(:id, :blob_id, :blob) do
    def with_lock
      yield
    end
  end

  class FakeCache
    attr_accessor :acquired

    def initialize(acquired:)
      @acquired = acquired
    end

    def write(*)
      acquired
    end

    def delete(*)
      true
    end
  end

  def test_job_skips_when_enqueued_blob_id_is_stale
    attachment = FakeAttachment.new(42, 200, FakeBlob.new("image/png", FakeFilename.new("png")))
    processor_called = false
    job = Compressify::Job.new
    job.define_singleton_method(:run_processor) { |_attachment, _options| processor_called = true }

    patch_singleton_method(ActiveStorage::Attachment, :find_by, ->(id:) { id == 42 ? attachment : nil }) do
      job.perform(attachment_id: 42, blob_id: 999, options: {})
    end

    refute processor_called
  end

  def test_job_runs_when_blob_id_matches
    attachment = FakeAttachment.new(42, 200, FakeBlob.new("image/png", FakeFilename.new("png")))
    processor_called = false
    job = Compressify::Job.new
    job.define_singleton_method(:run_processor) { |_attachment, _options| processor_called = true }

    patch_singleton_method(ActiveStorage::Attachment, :find_by, ->(id:) { id == 42 ? attachment : nil }) do
      job.perform(attachment_id: 42, blob_id: 200, options: {})
    end

    assert processor_called
  end

  def test_with_processing_lock_skips_when_cache_lock_not_acquired
    cache = FakeCache.new(acquired: false)
    job = Compressify::Job.new
    job.define_singleton_method(:rails_cache_store) { cache }

    yielded = false
    job.send(:with_processing_lock, "compressify:test-lock") { yielded = true }

    refute yielded
  end

  def test_with_media_concurrency_slot_yields_when_slot_available
    original_limit = Compressify.config.image_max_concurrency
    Compressify.config.image_max_concurrency = 1

    cache = FakeCache.new(acquired: true)
    job = Compressify::Job.new
    job.define_singleton_method(:rails_cache_store) { cache }

    attachment = FakeAttachment.new(7, 22, FakeBlob.new("image/png", FakeFilename.new("png")))
    yielded = false

    job.send(:with_media_concurrency_slot, attachment, blob_id: 22, options: {}) { yielded = true }

    assert yielded
  ensure
    Compressify.config.image_max_concurrency = original_limit
  end

  def test_with_media_concurrency_slot_requeues_when_full
    original_limit = Compressify.config.video_max_concurrency
    Compressify.config.video_max_concurrency = 1

    cache = FakeCache.new(acquired: false)
    job = Compressify::Job.new
    job.define_singleton_method(:rails_cache_store) { cache }

    requeued = false
    job.define_singleton_method(:requeue_with_backoff) { |**_kwargs| requeued = true }

    attachment = FakeAttachment.new(8, 33, FakeBlob.new("video/mp4", FakeFilename.new("mp4")))
    yielded = false

    job.send(:with_media_concurrency_slot, attachment, blob_id: 33, options: {}) { yielded = true }

    assert requeued
    refute yielded
  ensure
    Compressify.config.video_max_concurrency = original_limit
  end

  private

  def patch_singleton_method(klass, method_name, callable)
    singleton = class << klass; self; end
    had_method = klass.respond_to?(method_name)
    original_method = klass.method(method_name) if had_method

    singleton.define_method(method_name, callable)
    yield
  ensure
    if had_method
      singleton.define_method(method_name, original_method)
    else
      singleton.remove_method(method_name)
    end
  end
end
