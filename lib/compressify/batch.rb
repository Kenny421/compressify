# frozen_string_literal: true

module Compressify
  # Safely enqueue existing Active Storage attachments without loading every
  # record into memory or changing attachment state in the calling process.
  #
  # By default this is a dry run. Real runs are bounded and resumable by the
  # last scanned attachment ID. Existing job stale-blob and dedupe checks apply.
  class Batch
    MAX_LIMIT = 10_000
    DEFAULT_LIMIT = 500
    DEFAULT_BATCH_SIZE = 100

    def self.enqueue(model:, attachment_name:, options: {}, dry_run: true,
                     limit: DEFAULT_LIMIT, batch_size: DEFAULT_BATCH_SIZE, after_id: 0)
      unless model.is_a?(Class) && model < ActiveRecord::Base
        raise ArgumentError, "model must be an Active Record model class"
      end

      name = attachment_name.to_s
      unless model.respond_to?(:reflect_on_attachment) && model.reflect_on_attachment(name)
        raise ArgumentError, "#{model.name} has no Active Storage attachment named #{name}"
      end

      limit = Integer(limit)
      batch_size = Integer(batch_size)
      after_id = Integer(after_id)
      raise ArgumentError, "limit must be between 1 and #{MAX_LIMIT}" unless (1..MAX_LIMIT).cover?(limit)
      raise ArgumentError, "batch_size must be between 1 and #{MAX_LIMIT}" unless (1..MAX_LIMIT).cover?(batch_size)
      raise ArgumentError, "after_id must not be negative" if after_id.negative?
      raise ArgumentError, "options must be a Hash" unless options.is_a?(Hash)

      enqueued = 0
      eligible = 0
      skipped = 0
      scanned = 0
      last_id = after_id

      relation = ActiveStorage::Attachment.where(
        record_type: model.polymorphic_name, name: name
      ).where("id > ?", after_id).limit(limit).includes(:blob)

      relation.find_each(batch_size: batch_size) do |attachment|
        last_id = attachment.id
        scanned += 1
        blob = attachment.blob

        unless blob && (Compressify.image_blob?(blob) || Compressify.video_blob?(blob)) &&
            blob.byte_size.to_i <= Compressify.config.max_download_bytes.to_i
          skipped += 1
          next
        end

        declared_options = model_options(attachment, model: model, name: name)
        if declared_options.nil?
          skipped += 1
          next
        end

        resolved_options = declared_options.deep_merge(options.deep_symbolize_keys)
        eligible += 1
        next if dry_run

        job = Compressify::Job.set(queue: Compressify.queue_for_attachment(attachment))
          .perform_later(attachment_id: attachment.id, blob_id: blob.id, options: resolved_options)
        enqueued += 1 if job
      end

      { dry_run: !!dry_run, scanned: scanned, eligible: eligible,
        skipped: skipped, enqueued: enqueued, last_id: last_id,
        resume_after_id: last_id, limit: limit }
    end

    def self.model_options(attachment, model:, name:)
      return {} unless model.respond_to?(:compressify_attachment_rules)

      rule = model.compressify_attachment_rules[name]
      return {} unless rule

      record = attachment.record
      configured = rule.fetch(:options)
      if_condition = configured[:if]
      unless_condition = configured[:unless]
      return nil if if_condition && !if_condition.call(record)
      return nil if unless_condition && unless_condition.call(record)

      opts = record.send(:compressify_normalize_options, configured.except(:if, :unless).deep_dup)
      dynamic_opts = rule[:dynamic_opts]
      if dynamic_opts
        evaluated = dynamic_opts.call(record)
        opts = opts.deep_merge(evaluated.deep_symbolize_keys) if evaluated.is_a?(Hash)
      end
      opts
    end
    private_class_method :model_options
  end
end
