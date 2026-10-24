# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "stringio"

unless defined?(ActiveStorage::Blob)
  module ActiveStorage
    class Blob
    end
  end
end

class ProcessorSecurityTest < Minitest::Test
  FakeBlob = Struct.new(:key, :metadata, :content_type, :attachments, :byte_size)
  FakeFilename = Struct.new(:extension_without_delimiter)
  OpenableBlob = Struct.new(:content_type, :filename) do
    def open
      io = StringIO.new("\x89PNG\r\n\x1a\n")
      yield io
    end
  end

  class FakeAttachedMany < ActiveStorage::Attached::Many
    attr_reader :attachments, :attached_blob

    def initialize(attachments)
      @attachments = attachments
      @attached_blob = nil
    end

    def attach(blob)
      @attached_blob = blob
    end
  end

  class FakeExistingAttachment
    attr_reader :blob

    def initialize(blob)
      @blob = blob
      @purged = false
    end

    def purge_later
      @purged = true
    end

    def purged?
      @purged
    end
  end

  class FakeAttachment
    attr_reader :blob, :record, :record_id, :record_type, :name, :updated_attrs

    def initialize(blob:, record:, record_id:, record_type:, name:)
      @blob = blob
      @record = record
      @record_id = record_id
      @record_type = record_type
      @name = name
      @updated_attrs = nil
    end

    def update!(attrs)
      @updated_attrs = attrs
    end
  end

  def setup
    @original_purge_original = Compressify.config.purge_original
    Compressify.config.purge_original = false
    @original_image_min_bytes = Compressify.config.image_min_bytes_for_compression
    @original_adaptive_enabled = Compressify.config.adaptive_quality_enabled
    @original_adaptive_min = Compressify.config.adaptive_quality_min
    @original_adaptive_pixels = Compressify.config.adaptive_quality_large_image_pixels
    @original_adaptive_bytes = Compressify.config.adaptive_quality_large_file_bytes
    @original_reuse = Compressify.config.reuse_existing_derivatives
    @original_skip_resize = Compressify.config.skip_if_no_resize_needed
    @original_skip_larger = Compressify.config.skip_larger_output
    @original_pg_lookup = Compressify.config.postgres_fingerprint_lookup
  end

  def teardown
    Compressify.config.purge_original = @original_purge_original
    Compressify.config.image_min_bytes_for_compression = @original_image_min_bytes
    Compressify.config.adaptive_quality_enabled = @original_adaptive_enabled
    Compressify.config.adaptive_quality_min = @original_adaptive_min
    Compressify.config.adaptive_quality_large_image_pixels = @original_adaptive_pixels
    Compressify.config.adaptive_quality_large_file_bytes = @original_adaptive_bytes
    Compressify.config.reuse_existing_derivatives = @original_reuse
    Compressify.config.skip_if_no_resize_needed = @original_skip_resize
    Compressify.config.skip_larger_output = @original_skip_larger
    Compressify.config.postgres_fingerprint_lookup = @original_pg_lookup
  end

  def test_active_storage_target_for_rejects_non_attachment_target
    record = Object.new
    def record.compressed_image = Object.new

    attachment = FakeAttachment.new(
      blob: FakeBlob.new("source-key", {}, "image/jpeg", nil),
      record: record,
      record_id: 7,
      record_type: "Photo",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})
    processor.instance_variable_set(:@target_name, :compressed_image)

    error = assert_raises(Compressify::Error) do
      processor.send(:active_storage_target_for, record)
    end
    assert_match("is not an Active Storage attachment", error.message)
  end

  def test_active_storage_target_for_accepts_attached_one
    record = Object.new
    target = ActiveStorage::Attached::One.new("compressed_image", record)
    record.define_singleton_method(:compressed_image) { target }

    attachment = FakeAttachment.new(
      blob: FakeBlob.new("source-key", {}, "image/jpeg", nil),
      record: record,
      record_id: 8,
      record_type: "Photo",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})
    processor.instance_variable_set(:@target_name, :compressed_image)

    assert_same target, processor.send(:active_storage_target_for, record)
  end

  def test_attach_output_writes_security_metadata_for_per_record_matching
    source_blob = FakeBlob.new("source-key", { "existing" => "meta" }, "image/jpeg", nil, 15)
    record = Object.new
    attachment = FakeAttachment.new(
      blob: source_blob,
      record: record,
      record_id: 42,
      record_type: "Photo",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})
    processor.instance_variable_set(:@target_name, :image)
    processor.instance_variable_set(:@replace_mode, true)

    captured_upload = nil
    created_blob = Object.new

    Tempfile.create(["processor-security-", ".jpg"]) do |outfile|
      outfile.write("bytes")
      outfile.flush

      blob_singleton = class << ActiveStorage::Blob; self; end
      had_original = ActiveStorage::Blob.respond_to?(:create_and_upload!)
      original_method = ActiveStorage::Blob.method(:create_and_upload!) if had_original

      blob_singleton.define_method(:create_and_upload!) do |**kwargs|
        captured_upload = kwargs
        created_blob
      end

      begin
        processor.send(
          :attach_output!,
          source_blob: source_blob,
          outfile: outfile,
          filename: "compressed.jpg",
          content_type: "image/jpeg",
          fingerprint: "fp-123",
          mode: :image,
          options_snapshot: { quality: 80 }
        )
      ensure
        if had_original
          blob_singleton.define_method(:create_and_upload!, original_method)
        else
          blob_singleton.remove_method(:create_and_upload!)
        end
      end
    end

    refute_nil captured_upload
    assert_equal "meta", captured_upload[:metadata]["existing"]

    compressify_meta = captured_upload[:metadata][Compressify.config.metadata_key]
    assert_equal "fp-123", compressify_meta["fingerprint"]
    assert_equal "image", compressify_meta["mode"]
    assert_equal "image", compressify_meta["target"]
    assert_equal "source-key", compressify_meta["source_blob_key"]
    assert_equal 42, compressify_meta["record_id"]
    assert_equal "Photo", compressify_meta["record_type"]
    assert_equal 15, compressify_meta["source_byte_size"]
    assert_equal 5, compressify_meta["compressed_byte_size"]
    assert_equal 10, compressify_meta["bytes_saved"]
    assert_equal 66.67, compressify_meta["percent_saved"]
    refute_nil compressify_meta["processed_at"]

    assert_equal({ blob: created_blob }, attachment.updated_attrs)
  end

  def test_ffmpeg_custom_args_ignores_non_array_extra_args
    record = Object.new
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("source-key", {}, "video/mp4", nil),
      record: record,
      record_id: 9,
      record_type: "Video",
      name: "clip"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    args = processor.send(
      :ffmpeg_custom_args,
      { preset: "slow", crf: 24, max_width: 1280, extra_args: "--bad-raw-string" }
    )

    assert_equal ["-preset", "slow", "-crf", "24", "-vf", "scale='min(1280,iw)':-2"], args
  end

  def test_ffmpeg_custom_args_limits_video_threads_when_configured
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("source-key", {}, "video/mp4", nil),
      record: Object.new, record_id: 10, record_type: "Video", name: "clip"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    args = processor.send(:ffmpeg_custom_args, { crf: 28, threads: 2 })
    assert_equal ["-crf", "28", "-threads", "2"], args
  end

  def test_ffmpeg_custom_args_stringifies_array_values_safely
    record = Object.new
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("source-key", {}, "video/mp4", nil),
      record: record,
      record_id: 10,
      record_type: "Video",
      name: "clip"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    extra = [:"-movflags", :faststart, 123]
    args = processor.send(:ffmpeg_custom_args, { extra_args: extra })

    assert_equal ["-movflags", "faststart", "123"], args
  end

  def test_attach_output_per_record_purges_only_matching_existing_attachments
    source_blob = FakeBlob.new("source-key", {}, "image/jpeg", nil)
    matching_blob = FakeBlob.new(
      "old-1",
      {
        Compressify.config.metadata_key => {
          "record_id" => "123",
          "record_type" => "Photo",
          "target" => "compressed_images"
        }
      },
      "image/webp",
      nil
    )
    wrong_record_blob = FakeBlob.new(
      "old-2",
      {
        Compressify.config.metadata_key => {
          "record_id" => "999",
          "record_type" => "Photo",
          "target" => "compressed_images"
        }
      },
      "image/webp",
      nil
    )
    wrong_target_blob = FakeBlob.new(
      "old-3",
      {
        Compressify.config.metadata_key => {
          "record_id" => "123",
          "record_type" => "Photo",
          "target" => "other_target"
        }
      },
      "image/webp",
      nil
    )

    matching_attachment = FakeExistingAttachment.new(matching_blob)
    wrong_record_attachment = FakeExistingAttachment.new(wrong_record_blob)
    wrong_target_attachment = FakeExistingAttachment.new(wrong_target_blob)
    many_target = FakeAttachedMany.new([matching_attachment, wrong_record_attachment, wrong_target_attachment])

    record = Object.new
    record.define_singleton_method(:compressed_images) { many_target }

    attachment = FakeAttachment.new(
      blob: source_blob,
      record: record,
      record_id: 123,
      record_type: "Photo",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})
    processor.instance_variable_set(:@target_name, :compressed_images)
    processor.instance_variable_set(:@replace_mode, false)
    processor.instance_variable_set(:@target_replace_existing, :per_record)

    created_blob = Object.new

    Tempfile.create(["processor-security-per-record-", ".webp"]) do |outfile|
      outfile.write("bytes")
      outfile.flush

      blob_singleton = class << ActiveStorage::Blob; self; end
      had_original = ActiveStorage::Blob.respond_to?(:create_and_upload!)
      original_method = ActiveStorage::Blob.method(:create_and_upload!) if had_original

      blob_singleton.define_method(:create_and_upload!) do |**_kwargs|
        created_blob
      end

      begin
        processor.send(
          :attach_output!,
          source_blob: source_blob,
          outfile: outfile,
          filename: "compressed.webp",
          content_type: "image/webp",
          fingerprint: "fp-456",
          mode: :image,
          options_snapshot: { quality: 80 }
        )
      ensure
        if had_original
          blob_singleton.define_method(:create_and_upload!, original_method)
        else
          blob_singleton.remove_method(:create_and_upload!)
        end
      end
    end

    assert matching_attachment.purged?
    refute wrong_record_attachment.purged?
    refute wrong_target_attachment.purged?
    assert_same created_blob, many_target.attached_blob
  end

  def test_already_compressed_for_target_matches_same_options_even_with_symbol_string_differences
    compressify_meta = {
      "target" => "image",
      "mode" => "image",
      "options" => {
        "format" => "webp",
        "quality" => 80,
        "resize_to_limit" => [600, 600],
        "strip" => true,
        "saver" => {}
      }
    }
    blob = FakeBlob.new("k1", { Compressify.config.metadata_key => compressify_meta }, "image/jpeg", nil)
    record = Object.new
    attachment = FakeAttachment.new(blob: blob, record: record, record_id: 1, record_type: "Blog", name: "image")
    processor = Compressify::Processor.new(
      attachment: attachment,
      options: { format: :webp, quality: 80, resize_to_limit: [600, 600], strip: true, saver: {} }
    )
    processor.instance_variable_set(:@target_name, :image)

    assert processor.send(:already_compressed_for_target?, blob)
  end

  def test_already_compressed_for_target_rejects_when_options_differ
    compressify_meta = {
      "target" => "image",
      "mode" => "image",
      "options" => { "format" => "webp", "quality" => 75, "resize_to_limit" => [600, 600], "strip" => true, "saver" => {} }
    }
    blob = FakeBlob.new("k2", { Compressify.config.metadata_key => compressify_meta }, "image/jpeg", nil)
    record = Object.new
    attachment = FakeAttachment.new(blob: blob, record: record, record_id: 1, record_type: "Blog", name: "image")
    processor = Compressify::Processor.new(
      attachment: attachment,
      options: { format: :webp, quality: 80, resize_to_limit: [600, 600], strip: true, saver: {} }
    )
    processor.instance_variable_set(:@target_name, :image)

    refute processor.send(:already_compressed_for_target?, blob)
  end

  def test_image_detection_falls_back_to_filename_extension
    blob = Struct.new(:content_type, :filename).new("application/octet-stream", FakeFilename.new("png"))
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k3", {}, "image/jpeg", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    assert processor.send(:image?, blob)
  end

  def test_video_detection_falls_back_to_filename_extension
    blob = Struct.new(:content_type, :filename).new("application/octet-stream", FakeFilename.new("mp4"))
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k4", {}, "video/mp4", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "video"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    assert processor.send(:video?, blob)
  end

  def test_image_detection_falls_back_to_mime_sniff_when_extension_missing
    blob = OpenableBlob.new("application/octet-stream", "Untitled design")
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k5", {}, "image/jpeg", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    assert processor.send(:image?, blob)
  end

  def test_preserve_image_result_keeps_original_when_operation_returns_nil
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k6", {}, "image/png", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    original = Object.new
    result = processor.send(:preserve_image_result, original) { |_img| nil }

    assert_same original, result
  end

  def test_preserve_image_result_uses_operation_result_when_present
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k7", {}, "image/png", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    original = Object.new
    transformed = Object.new
    result = processor.send(:preserve_image_result, original) { |_img| transformed }

    assert_same transformed, result
  end

  def test_merged_image_options_accepts_resize_to_fill
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k8", {}, "image/png", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(
      attachment: attachment,
      options: { resize_to_fill: [600, 600], format: :webp, quality: 80 }
    )

    merged = processor.send(:merged_image_options)

    assert_equal [600, 600], merged[:resize_to_fill]
    assert_equal "webp", merged[:format].to_s
    assert_equal 80, merged[:quality]
  end

  def test_tiny_image_detection_respects_threshold
    Compressify.config.image_min_bytes_for_compression = 100

    blob = Struct.new(:byte_size).new(99)
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k9", {}, "image/png", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    assert processor.send(:tiny_image?, blob)
    refute processor.send(:tiny_image?, Struct.new(:byte_size).new(100))
  end

  def test_tiny_image_check_does_not_skip_when_format_conversion_requested
    Compressify.config.image_min_bytes_for_compression = 100

    blob = Struct.new(:byte_size, :content_type, :filename).new(
      99,
      "image/avif",
      FakeFilename.new("avif")
    )
    opts = { format: :webp }

    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k15", {}, "image/avif", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    refute processor.send(:tiny_image?, blob, opts)
  end

  def test_tiny_image_check_does_not_skip_when_resize_requested
    Compressify.config.image_min_bytes_for_compression = 100

    blob = Struct.new(:byte_size, :content_type, :filename).new(
      99,
      "image/avif",
      FakeFilename.new("avif")
    )
    opts = { resize_to_limit: [600, 600] }

    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k16", {}, "image/avif", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    refute processor.send(:tiny_image?, blob, opts)
  end

  def test_adaptive_quality_reduces_for_large_images_and_large_files
    Compressify.config.adaptive_quality_enabled = true
    Compressify.config.adaptive_quality_min = 60
    Compressify.config.adaptive_quality_large_image_pixels = 1_000_000
    Compressify.config.adaptive_quality_large_file_bytes = 1_000_000

    image = Struct.new(:width, :height).new(2000, 1000) # 2MP
    blob = Struct.new(:byte_size).new(2_000_000)
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k10", {}, "image/png", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    assert_equal 62, processor.send(:adaptive_quality_for, base_quality: 80, image: image, blob: blob)
  end

  def test_adaptive_quality_returns_base_when_disabled
    Compressify.config.adaptive_quality_enabled = false

    image = Struct.new(:width, :height).new(4000, 4000)
    blob = Struct.new(:byte_size).new(10_000_000)
    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k11", {}, "image/png", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    assert_equal 80, processor.send(:adaptive_quality_for, base_quality: 80, image: image, blob: blob)
  end

  def test_reusable_blob_for_finds_matching_fingerprint_and_mode
    fp = "fp-123"
    good = Struct.new(:id, :metadata).new(2, { Compressify.config.metadata_key => { "fingerprint" => fp, "mode" => "image" } })
    bad_mode = Struct.new(:id, :metadata).new(3, { Compressify.config.metadata_key => { "fingerprint" => fp, "mode" => "video" } })
    candidates = [bad_mode, good]

    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k12", {}, "image/png", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    patch_class_method(ActiveStorage::Blob, :where, ->(*_args) { candidates }) do
      found = processor.send(:reusable_blob_for, fingerprint: fp, mode: :image, exclude_blob_id: nil)
      assert_same good, found
    end
  end

  def test_try_reuse_derivative_attaches_existing_blob
    Compressify.config.reuse_existing_derivatives = true
    source_blob = Struct.new(:id, :key, :byte_size, :content_type, :filename, :metadata).new(
      10, "source-k", 500_000, "image/png", Struct.new(:extension_without_delimiter).new("png"), {}
    )
    attachment = FakeAttachment.new(
      blob: source_blob,
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    attachment.define_singleton_method(:id) { 123 }
    processor = Compressify::Processor.new(attachment: attachment, options: {})
    processor.instance_variable_set(:@target_name, :image)
    processor.instance_variable_set(:@replace_mode, true)

    reusable = Struct.new(:id).new(99)
    attached = false

    processor.define_singleton_method(:fingerprint_for) { |_blob| "fp-reuse" }
    processor.define_singleton_method(:reusable_blob_for) { |**_kwargs| reusable }
    processor.define_singleton_method(:attach_existing_blob!) do |**kwargs|
      attached = (kwargs[:existing_blob] == reusable)
    end

    reused = processor.send(:try_reuse_derivative!, source_blob: source_blob, mode: :image, options_snapshot: { quality: 80 })
    assert reused
    assert attached
  end

  def test_skip_if_no_resize_needed_true_when_within_bounds
    Compressify.config.skip_if_no_resize_needed = true
    blob = Struct.new(:metadata).new({ "width" => 500, "height" => 400 })
    opts = { resize_to_limit: [600, 600] }

    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k13", {}, "image/png", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    assert processor.send(:skip_if_no_resize_needed?, blob, opts)
  end

  def test_skip_if_no_resize_needed_false_when_resize_required
    Compressify.config.skip_if_no_resize_needed = true
    blob = Struct.new(:metadata).new({ "width" => 1400, "height" => 900 })
    opts = { resize_to_limit: [600, 600] }

    attachment = FakeAttachment.new(
      blob: FakeBlob.new("k14", {}, "image/png", nil),
      record: Object.new,
      record_id: 1,
      record_type: "Blog",
      name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    refute processor.send(:skip_if_no_resize_needed?, blob, opts)
  end

  def test_attach_output_skips_larger_in_place_replacement
    Compressify.config.skip_larger_output = true
    source_blob = FakeBlob.new("small-source", {}, "image/jpeg", nil, 4)
    attachment = FakeAttachment.new(
      blob: source_blob, record: Object.new, record_id: 88,
      record_type: "Photo", name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})
    processor.instance_variable_set(:@target_name, :image)
    processor.instance_variable_set(:@replace_mode, true)

    Tempfile.create(["larger-output-", ".jpg"]) do |outfile|
      outfile.write("123456789")
      outfile.flush

      patch_class_method(ActiveStorage::Blob, :create_and_upload!, ->(**_kwargs) { flunk "should not upload larger file" }) do
        result = processor.send(
          :attach_output!, source_blob: source_blob, outfile: outfile,
          filename: "output.jpg", content_type: "image/jpeg",
          fingerprint: "fp-large", mode: :image, options_snapshot: { quality: 80 }
        )
        assert_equal false, result
      end
    end

    assert_nil attachment.updated_attrs
  end

  def test_larger_output_is_allowed_when_guard_disabled
    Compressify.config.skip_larger_output = false
    source_blob = FakeBlob.new("small-source", {}, "image/jpeg", nil, 4)
    attachment = FakeAttachment.new(
      blob: source_blob, record: Object.new, record_id: 88,
      record_type: "Photo", name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})
    processor.instance_variable_set(:@target_name, :image)
    processor.instance_variable_set(:@replace_mode, true)

    replacement = Object.new
    Tempfile.create(["larger-allowed-", ".jpg"]) do |outfile|
      outfile.write("123456789")
      outfile.flush

      patch_class_method(ActiveStorage::Blob, :create_and_upload!, ->(**_kwargs) { replacement }) do
        processor.send(
          :attach_output!, source_blob: source_blob, outfile: outfile,
          filename: "output.jpg", content_type: "image/jpeg",
          fingerprint: "fp-large", mode: :image, options_snapshot: { quality: 80 }
        )
      end
    end

    assert_equal({ blob: replacement }, attachment.updated_attrs)
  end

  def test_reusable_blob_uses_indexed_postgres_query_when_enabled
    Compressify.config.postgres_fingerprint_lookup = true
    fp = "abc123"
    matching = Struct.new(:id, :metadata).new(
      72, { Compressify.config.metadata_key => { "fingerprint" => fp, "mode" => "image" } }
    )
    connection = Object.new
    connection.define_singleton_method(:adapter_name) { "PostgreSQL" }
    connection.define_singleton_method(:quote) { |val| "'#{val}'" }

    attachment = FakeAttachment.new(
      blob: FakeBlob.new("source", {}, "image/png", nil),
      record: Object.new, record_id: 6, record_type: "Photo", name: "image"
    )
    processor = Compressify::Processor.new(attachment: attachment, options: {})

    queried = nil
    patch_class_method(ActiveStorage::Blob, :connection, -> { connection }) do
      patch_class_method(ActiveStorage::Blob, :where, ->(*args) { queried = args; [matching] }) do
        assert_same matching, processor.send(:reusable_blob_for, fingerprint: fp, mode: :image)
      end
    end

    assert_includes queried.first, "metadata::jsonb"
    assert_includes queried.first, "'compressify'"
    assert_equal fp, queried.last
  end

  def test_replacement_refreshes_stale_owner_before_attachment_touch
    source_blob = FakeBlob.new("stale-source", {}, "image/jpeg", nil, 100)
    record = Object.new
    record.define_singleton_method(:persisted?) { true }
    record.define_singleton_method(:reload) { @was_reloaded = true; self }
    record.define_singleton_method(:reloaded?) { @was_reloaded }

    attachment = FakeAttachment.new(
      blob: source_blob, record: record, record_id: 65,
      record_type: "Book", name: "cover_image"
    )
    attachment.define_singleton_method(:update!) do |attrs|
      raise ActiveRecord::StaleObjectError.new(record, "touch") unless record.reloaded?
      @updated_attrs = attrs
    end

    processor = Compressify::Processor.new(attachment: attachment, options: {})
    processor.instance_variable_set(:@target_name, :cover_image)
    processor.instance_variable_set(:@replace_mode, true)
    replacement = Object.new

    Tempfile.create(["compressify-reload-", ".webp"]) do |outfile|
      outfile.write("short")
      outfile.flush

      patch_class_method(ActiveStorage::Blob, :create_and_upload!, ->(**_kwargs) { replacement }) do
        processor.send(
          :attach_output!, source_blob: source_blob, outfile: outfile,
          filename: "cover.webp", content_type: "image/webp",
          fingerprint: "fp-lock", mode: :image, options_snapshot: { quality: 82 }
        )
      end
    end

    assert record.reloaded?
    assert_equal({ blob: replacement }, attachment.updated_attrs)
  end

  def test_failed_transaction_cleanup_deletes_uncommitted_storage_file
    source_blob = FakeBlob.new("source", {}, "image/jpeg", nil, 100)
    attachment = FakeAttachment.new(
      blob: source_blob, record: Object.new, record_id: 65,
      record_type: "Book", name: "cover_image"
    )
    attachment.define_singleton_method(:update!) do |_attrs|
      raise ActiveRecord::StaleObjectError.new(record, "touch")
    end

    processor = Compressify::Processor.new(attachment: attachment, options: {})
    processor.instance_variable_set(:@target_name, :cover_image)
    processor.instance_variable_set(:@replace_mode, true)

    deleted_keys = []
    storage = Object.new
    storage.define_singleton_method(:delete) { |key| deleted_keys << key }
    replacement = Object.new
    replacement.define_singleton_method(:key) { "rolled-back-key" }
    replacement.define_singleton_method(:service) { storage }

    Tempfile.create(["compressify-rollback-", ".webp"]) do |outfile|
      outfile.write("short")
      outfile.flush

      patch_class_method(ActiveStorage::Blob, :create_and_upload!, ->(**_kwargs) { replacement }) do
        assert_raises(ActiveRecord::StaleObjectError) do
          processor.send(
            :attach_output!, source_blob: source_blob, outfile: outfile,
            filename: "cover.webp", content_type: "image/webp",
            fingerprint: "fp-lock", mode: :image, options_snapshot: {}
          )
        end
      end
    end

    assert_equal [], deleted_keys
    processor.cleanup_failed_outputs!
    assert_equal ["rolled-back-key"], deleted_keys
    assert_equal [], processor.pending_purge_blob_ids
  end

  private

  def patch_class_method(klass, method_name, callable)
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
