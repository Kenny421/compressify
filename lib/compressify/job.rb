# frozen_string_literal: true
require "digest"
require "json"
require "net/http"

module Compressify
  class Job < ActiveJob::Base
    queue_as { Compressify.config.queue_name }

    TRANSIENT_ERRORS = [
      Timeout::Error,
      Errno::ECONNRESET,
      Errno::ETIMEDOUT,
      Net::OpenTimeout,
      Net::ReadTimeout,
      IOError
    ].freeze

    retry_on(*TRANSIENT_ERRORS, wait: :exponentially_longer, attempts: 5)
    discard_on ActiveRecord::RecordNotFound if defined?(ActiveRecord::RecordNotFound)

    # attachment_id: ActiveStorage::Attachment id
    # blob_id: expected blob id at enqueue time (stale job guard)
    # options: hash for processor (format/quality/etc + attach_to)
    def perform(attachment_id:, blob_id: nil, options: {})
      attachment = ActiveStorage::Attachment.find_by(id: attachment_id)
      return unless attachment

      # Serialize concurrent jobs touching the same attachment row.
      attachment.with_lock do
        # If attachment changed since enqueue, this job is stale.
        if blob_id.present? && attachment.blob_id.to_i != blob_id.to_i
          log_info("Skip stale job attachment_id=#{attachment.id} expected_blob_id=#{blob_id} current_blob_id=#{attachment.blob_id}")
          next
        end

        lock_key = processing_lock_key(attachment: attachment, options: options)
        with_processing_lock(lock_key) do
          with_media_concurrency_slot(attachment, blob_id: blob_id, options: options) do
            # Re-check inside lock in case another worker swapped blob while we waited.
            if blob_id.present? && attachment.blob_id.to_i != blob_id.to_i
              log_info("Skip stale job inside lock attachment_id=#{attachment.id} expected_blob_id=#{blob_id} current_blob_id=#{attachment.blob_id}")
              next
            end

            run_processor(attachment, options)
          end
        end
      end
    end

    private

    def run_processor(attachment, options)
      Compressify::Processor.new(attachment: attachment, options: options).call
    end

    def processing_lock_key(attachment:, options:)
      digest = Digest::SHA256.hexdigest(JSON.generate(options || {}))
      "compressify:job-lock:attachment:#{attachment.id}:blob:#{attachment.blob_id}:opts:#{digest}"
    end

    def with_processing_lock(key)
      cache_store = rails_cache_store
      return yield unless cache_store

      ttl = Compressify.config.job_lock_ttl
      acquired = cache_store.write(key, true, unless_exist: true, expires_in: ttl)
      unless acquired
        log_info("Skip duplicate in-flight job lock_key=#{key}")
        return
      end

      yield
    ensure
      cache_store&.delete(key) if acquired
    end

    def rails_cache_store
      return nil unless defined?(Rails)
      return nil unless Rails.respond_to?(:cache)

      Rails.cache
    rescue StandardError
      nil
    end

    def with_media_concurrency_slot(attachment, blob_id:, options:)
      limit = concurrency_limit_for_attachment(attachment)
      return yield unless limit.to_i.positive?

      cache_store = rails_cache_store
      return yield unless cache_store

      slot_key = acquire_concurrency_slot(cache_store: cache_store, attachment: attachment, limit: limit)
      unless slot_key
        log_info("Requeue due to concurrency cap attachment_id=#{attachment.id} blob_id=#{attachment.blob_id} limit=#{limit}")
        requeue_with_backoff(attachment: attachment, blob_id: blob_id || attachment.blob_id, options: options)
        return
      end

      yield
    ensure
      cache_store&.delete(slot_key) if slot_key
    end

    def acquire_concurrency_slot(cache_store:, attachment:, limit:)
      scope = media_scope_for_attachment(attachment)
      ttl = Compressify.config.job_lock_ttl

      1.upto(limit.to_i) do |idx|
        key = "compressify:concurrency:#{scope}:slot:#{idx}"
        acquired = cache_store.write(key, true, unless_exist: true, expires_in: ttl)
        return key if acquired
      end

      nil
    end

    def requeue_with_backoff(attachment:, blob_id:, options:)
      self.class
        .set(queue: Compressify.queue_for_attachment(attachment), wait: Compressify.config.concurrency_retry_delay)
        .perform_later(attachment_id: attachment.id, blob_id: blob_id, options: options)
    end

    def concurrency_limit_for_attachment(attachment)
      case media_scope_for_attachment(attachment)
      when "image"
        Compressify.config.image_max_concurrency
      when "video"
        Compressify.config.video_max_concurrency
      else
        nil
      end
    end

    def media_scope_for_attachment(attachment)
      blob = attachment&.blob
      return "image" if Compressify.image_blob?(blob)
      return "video" if Compressify.video_blob?(blob)

      "other"
    rescue StandardError
      "other"
    end

    def log_info(msg)
      logger = if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger
      end
      logger&.info("[Compressify::Job] #{msg}")
    end
  end
end
