# frozen_string_literal: true

require "test_helper"

class BatchTest < Minitest::Test
  class Record < ActiveRecord::Base
    self.abstract_class = true

    def self.polymorphic_name = "BatchTest::Record"
    def self.reflect_on_attachment(name) = name.to_s == "image" ? true : nil
  end

  Blob = Struct.new(:id, :byte_size, :content_type, :filename)
  Attachment = Struct.new(:id, :blob)
  Filename = Struct.new(:extension_without_delimiter)

  class Relation
    def initialize(attachments)
      @attachments = attachments
      @cursor = 0
      @limit = 1000
    end

    def where(*args)
      @cursor = args.last if args.first.is_a?(String) && args.first.include?("id >")
      self
    end

    def limit(n)
      @limit = n
      self
    end

    def includes(*_args) = self

    def find_each(batch_size:)
      raise ArgumentError unless batch_size.positive?
      @attachments.select { |att| att.id > @cursor }.first(@limit).each { |att| yield att }
    end
  end

  def setup
    @images = [
      Attachment.new(1, Blob.new(11, 1000, "image/jpeg", Filename.new("jpg"))),
      Attachment.new(2, Blob.new(12, 2000, "image/png", Filename.new("png"))),
      Attachment.new(3, Blob.new(13, 1000, "text/plain", Filename.new("txt"))),
      Attachment.new(4, Blob.new(14, 1000, "image/webp", Filename.new("webp")))
    ]
  end

  def test_dry_run_reports_work_without_enqueuing_jobs
    with_attachments(@images) do
      report = Compressify::Batch.enqueue(model: Record, attachment_name: :image, limit: 3)
      assert_equal true, report[:dry_run]
      assert_equal 3, report[:scanned]
      assert_equal 2, report[:eligible]
      assert_equal 1, report[:skipped]
      assert_equal 0, report[:enqueued]
      assert_equal 3, report[:resume_after_id]
    end
  end

  def test_scan_resumes_strictly_after_cursor
    with_attachments(@images) do
      report = Compressify::Batch.enqueue(
        model: Record, attachment_name: :image, after_id: 2,
        limit: 2, batch_size: 1
      )
      assert_equal 2, report[:scanned]
      assert_equal 1, report[:eligible]
      assert_equal 4, report[:resume_after_id]
    end
  end

  def test_enqueues_with_expected_blob_id_and_selected_queue
    enqueued = []
    runner = Object.new
    runner.define_singleton_method(:perform_later) do |**args|
      enqueued << args
      Object.new
    end
    with_attachments(@images) do
      patch_method(Compressify::Job, :set, ->(**_args) { runner }) do
        report = Compressify::Batch.enqueue(
          model: Record, attachment_name: :image,
          limit: 2, dry_run: false, options: { quality: 72 }
        )
        assert_equal 2, report[:enqueued]
      end
    end
    assert_equal [11, 12], enqueued.map { |args| args[:blob_id] }
    assert_equal [1, 2], enqueued.map { |args| args[:attachment_id] }
    assert_equal({ quality: 72 }, enqueued.first[:options])
  end

  def test_rejects_unbounded_or_invalid_requests
    assert_raises(ArgumentError) do
      Compressify::Batch.enqueue(model: Record, attachment_name: :image, limit: 10001)
    end
    assert_raises(ArgumentError) do
      Compressify::Batch.enqueue(model: Record, attachment_name: :video)
    end
    assert_raises(ArgumentError) do
      Compressify::Batch.enqueue(model: Object, attachment_name: :image)
    end
  end

  private

  def with_attachments(items)
    patch_method(ActiveStorage::Attachment, :where, ->(*_args) { Relation.new(items) }) { yield }
  end

  def patch_method(klass, method_name, new_method)
    singleton = class << klass; self; end
    prior = klass.method(method_name) if klass.respond_to?(method_name)
    singleton.define_method(method_name, new_method)
    yield
  ensure
    if prior
      singleton.define_method(method_name, prior)
    else
      singleton.remove_method(method_name)
    end
  end
end
