# frozen_string_literal: true

require "test_helper"

class ProcessorKeywordForwardingTest < Minitest::Test
  DummyBlob = Struct.new(:content_type, :filename)
  DummyFilename = Struct.new(:extension_without_delimiter)

  class KeywordContext
    attr_reader :received

    def needs_keywords(source_blob:, outfile:, filename:, content_type:, fingerprint:, mode:, options_snapshot:)
      @received = {
        source_blob: source_blob,
        outfile: outfile,
        filename: filename,
        content_type: content_type,
        fingerprint: fingerprint,
        mode: mode,
        options_snapshot: options_snapshot
      }
    end

    private

    def private_keywords(source_blob:, outfile:, filename:, content_type:, fingerprint:, mode:, options_snapshot:)
      needs_keywords(
        source_blob: source_blob,
        outfile: outfile,
        filename: filename,
        content_type: content_type,
        fingerprint: fingerprint,
        mode: mode,
        options_snapshot: options_snapshot
      )
    end
  end

  def test_image_processor_context_send_forwards_keywords
    ctx = KeywordContext.new
    blob = DummyBlob.new("image/png", DummyFilename.new("png"))
    processor = Compressify::ImageProcessor.new(context: ctx, blob: blob)

    processor.send(
      :context_send,
      :needs_keywords,
      source_blob: :blob,
      outfile: :out,
      filename: "x.webp",
      content_type: "image/webp",
      fingerprint: "abc",
      mode: :image,
      options_snapshot: { quality: 80 }
    )

    assert_equal :blob, ctx.received[:source_blob]
    assert_equal :out, ctx.received[:outfile]
  end

  def test_video_processor_context_send_forwards_keywords
    ctx = KeywordContext.new
    blob = DummyBlob.new("video/mp4", DummyFilename.new("mp4"))
    processor = Compressify::VideoProcessor.new(context: ctx, blob: blob)

    processor.send(
      :context_send,
      :needs_keywords,
      source_blob: :blob,
      outfile: :out,
      filename: "x.mp4",
      content_type: "video/mp4",
      fingerprint: "abc",
      mode: :video,
      options_snapshot: { crf: 28 }
    )

    assert_equal :video, ctx.received[:mode]
    assert_equal "video/mp4", ctx.received[:content_type]
  end

  def test_image_processor_context_send_reaches_private_keyword_method
    ctx = KeywordContext.new
    blob = DummyBlob.new("image/png", DummyFilename.new("png"))
    processor = Compressify::ImageProcessor.new(context: ctx, blob: blob)

    processor.send(
      :context_send,
      :private_keywords,
      source_blob: :blob,
      outfile: :out,
      filename: "x.webp",
      content_type: "image/webp",
      fingerprint: "abc",
      mode: :image,
      options_snapshot: { quality: 80 }
    )

    assert_equal :image, ctx.received[:mode]
    assert_equal "image/webp", ctx.received[:content_type]
  end
end
