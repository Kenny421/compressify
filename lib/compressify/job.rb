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
    retry_on ActiveRecord::StaleObjectError, wait: 2.seconds, attempts: 3
    discard_on ActiveRecord::RecordNotFound if defined?(ActiveRecord::RecordNotFound)

    # attachment_id: ActiveStorage::Attachment id
    # blob_id: expected blob id at enqueue time (stale job guard)
    # options: hash for processor (format/quality/etc + attach_to)
    def perform(attachment_id:, blob_id: nil, options: {})
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      metric_error = nil
      @processor = nil
      attachment = ActiveStorage::Attachment.find_by(id: attachment_id)
      return unless attachment

      # Serialize jobs per attachment row so two workers do not "help" at the same time.
      begin
        attachment.with_lock do
          # If the blob changed since enqueue, this job missed its moment.
          if blob_id.present? && attachment.blob_id.to_i != blob_id.to_i
            log_info("Skip stale job attachment_id=#{attachment.id} expected_blob_id=#{blob_id} current_blob_id=#{attachment.blob_id}")
            next
          end

          lock_key = processing_lock_key(attachment: attachment, options: options)
          with_processing_lock(lock_key) do
            with_media_concurrency_slot(attachment, blob_id: blob_id, options: options) do
              # Re-check inside the lock. Queues are fast, but not psychic.
              if blob_id.present? && attachment.blob_id.to_i != blob_id.to_i
                log_info("Skip stale job inside lock attachment_id=#{attachment.id} expected_blob_id=#{blob_id} current_blob_id=#{attachment.blob_id}")
                next
              end

              run_processor(attachment, options)
            end
          end
        end
      rescue StandardError
        # The DB transaction has rolled back; clean up new media that was
        # uploaded to a nontransactional storage service before the error.
        @processor&.cleanup_failed_outputs!
        raise
      end

      # Never enqueue the purge before the replacement transaction commits.
      @processor&.enqueue_pending_purges!
    rescue StandardError => error
      metric_error = error
      raise
    ensure
      publish_job_metric(started_at: started_at, attachment_id: attachment_id,
                         blob_id: blob_id, error: metric_error) if started_at
    end

    private

    def publish_job_metric(started_at:, attachment_id:, blob_id:, error:)
      result = @processor&.result || {}
      payload = {
        attachment_id: attachment_id, blob_id: blob_id, job_id: job_id,
        status: error ? "failed" : result.fetch(:status, "skipped"),
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000).round(2),
        mode: result[:mode], source_bytes: result[:source_bytes],
        output_bytes: result[:output_bytes], bytes_saved: result[:bytes_saved],
        skip_reason: result[:reason], error_class: error&.class&.name
      }
      ActiveSupport::Notifications.instrument("compressify.job", payload)
    rescue StandardError => metric_error
      log_info("Unable to publish compression metric: #{metric_error.class}")
    end

    def run_processor(attachment, options)
      @processor = Compressify::Processor.new(attachment: attachment, options: options)
      @processor.call
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

      if postgres_semaphore_enabled?
        acquired = false
        ActiveStorage::Attachment.connection_pool.with_connection do |connection|
          acquired = Compressify::PostgresSemaphore.with_slot(
            scope: media_scope_for_attachment(attachment),
            limit: limit, connection: connection,
            namespace: Compressify.config.concurrency_namespace
          ) { yield }
        end
        unless acquired
          log_info("Requeue due to distributed concurrency cap attachment_id=#{attachment.id} limit=#{limit}")
          requeue_with_backoff(attachment: attachment, blob_id: blob_id || attachment.blob_id, options: options)
        end
        return
      end

      with_cache_concurrency_slot(attachment, limit: limit, blob_id: blob_id, options: options) { yield }
    end

    def postgres_semaphore_enabled?
      backend = Compressify.config.concurrency_backend.to_sym
      raise ArgumentError, "Unsupported Compressify concurrency backend: #{backend}" unless
        %i[auto cache postgres].include?(backend)
      return false if backend == :cache

      config = ActiveStorage::Attachment.connection_db_config
      is_postgres = config && config.adapter.to_s.downcase.include?("postgres")
      raise Compressify::Error, "concurrency_backend=:postgres requires PostgreSQL" if
        backend == :postgres && !is_postgres
      !!is_postgres
    end

    def with_cache_concurrency_slot(attachment, limit:, blob_id:, options:)
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
