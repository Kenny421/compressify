# frozen_string_literal: true

module Compressify
  # Retryable, attachment-aware deletion of replaced originals.
  #
  # Deleting the storage object before the DB record keeps the blob available
  # for retries if R2/S3 deletion fails. Locking prevents an attachment from
  # appearing between the reference check and deletion on FK-backed databases.
  class PurgeOriginalJob < ActiveJob::Base
    queue_as { Compressify.config.queue_name }

    retry_on StandardError, wait: 30.seconds, attempts: 5

    def perform(blob_id:)
      blob = ActiveStorage::Blob.find_by(id: blob_id)
      return unless blob

      blob.with_lock do
        next if blob.attachments.exists?

        blob.delete
        blob.destroy!
      end
    end
  end
end
