# frozen_string_literal: true

require "test_helper"

class QueueRoutingTest < Minitest::Test
  Blob = Struct.new(:content_type, :filename)
  Filename = Struct.new(:extension_without_delimiter)
  Attachment = Struct.new(:blob)

  def setup
    @original_queue = Compressify.config.queue_name
    @original_image_queue = Compressify.config.image_queue_name
    @original_video_queue = Compressify.config.video_queue_name

    Compressify.config.queue_name = :default
    Compressify.config.image_queue_name = :compressify_images
    Compressify.config.video_queue_name = :compressify_videos
  end

  def teardown
    Compressify.config.queue_name = @original_queue
    Compressify.config.image_queue_name = @original_image_queue
    Compressify.config.video_queue_name = @original_video_queue
  end

  def test_routes_image_to_image_queue
    attachment = Attachment.new(Blob.new("image/png", Filename.new("png")))

    assert_equal :compressify_images, Compressify.queue_for_attachment(attachment)
  end

  def test_routes_video_to_video_queue
    attachment = Attachment.new(Blob.new("video/mp4", Filename.new("mp4")))

    assert_equal :compressify_videos, Compressify.queue_for_attachment(attachment)
  end

  def test_routes_unknown_type_to_default_queue
    attachment = Attachment.new(Blob.new("application/pdf", Filename.new("pdf")))

    assert_equal :default, Compressify.queue_for_attachment(attachment)
  end
end
