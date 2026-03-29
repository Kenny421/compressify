# frozen_string_literal: true

module Compressify
  module Controller
    extend ActiveSupport::Concern

    # Compress an Active Storage attachment in the background.
    #
    # Usage (controller):
    #   include Compressify::Controller
    #
    #   # Replace the original attachment (default)
    #   compress_attachment(@post.cover_image, format: :webp, quality: 80, resize_to_limit: [1600, 1600])
    #
    #   # Keep original + store compressed output somewhere else (has_one_attached or has_many_attached)
    #   compress_attachment(@post.cover_image, attach_to: :compressed_cover_image, format: :webp, quality: 80)
    #
    #   # For has_many_attached targets: keep only ONE compressed result (don't accumulate)
    #   compress_attachment(@post.photos, attach_to: { name: :compressed_photos, replace_existing: true }, format: :webp)
      #   compress_attachment(@post.photos, attach_to: { name: :compressed_photos, replace_existing: :per_source }, format: :webp)
#   compress_attachment(@post.photos, attach_to: { name: :compressed_photos, replace_existing: :per_record }, format: :webp)
    #
    # Works with:
    # - ActiveStorage::Attached::One (has_one_attached)
    # - ActiveStorage::Attached::Many (has_many_attached)
    #
    # attach_to:
    # - nil (default): replace the original attachment's blob
    # - Symbol: attach the compressed blob to that attachment name (keeps original)
    # - Hash: { name: :compressed_images, replace_existing: true } (handy for has_many_attached)
    #
    def compress_attachment(attached, attach_to: nil, **options)
      return unless Compressify.config.enabled
      return if attached.blank?

      attachments = Compressify::Processor.normalize_attachments(attached)

      attachments.each do |attachment|
        next if attachment.blank?

        Compressify::Job
          .set(queue: Compressify.queue_for_attachment(attachment))
          .perform_later(
            attachment_id: attachment.id,
            blob_id: attachment.blob_id,
            options: options.merge(attach_to: attach_to)
          )
      end
    end
  end
end
