# frozen_string_literal: true

module Compressify
  # A read-only snapshot of currently retained compressed Active Storage blobs.
  # Metrics are based on blob metadata; purged or replaced outputs are no longer
  # counted. For lifetime reporting subscribe to "compressify.job" events.
  class Statistics
    def self.summary(scope: ActiveStorage::Blob.all, since: nil, until_at: nil, batch_size: 1_000)
      batch_size = Integer(batch_size)
      raise ArgumentError, "batch_size must be positive" unless batch_size.positive?

      relation = scope
      relation = relation.where("created_at >= ?", since) if since
      relation = relation.where("created_at < ?", until_at) if until_at
      metadata_key = Compressify.config.metadata_key.to_s
      # Prefilter across SQLite/PostgreSQL without requiring an optional index.
      relation = relation.where("metadata LIKE ?", "%\\\"#{metadata_key}\\\"%")

      totals = { count: 0, source_bytes: 0, compressed_bytes: 0,
                 bytes_saved: 0, processing_ms: 0, timed_count: 0,
                 by_mode: {} }

      relation.find_each(batch_size: batch_size) do |blob|
        meta = blob.metadata.is_a?(Hash) ? blob.metadata[metadata_key] : nil
        next unless meta.is_a?(Hash) && meta["source_byte_size"].is_a?(Numeric) &&
                    meta["compressed_byte_size"].is_a?(Numeric)

        source = meta["source_byte_size"].to_i
        compressed = meta["compressed_byte_size"].to_i
        next if source.negative? || compressed.negative?

        mode = meta["mode"].to_s
        mode = "other" unless %w[image video].include?(mode)

        totals[:count] += 1
        totals[:source_bytes] += source
        totals[:compressed_bytes] += compressed
        totals[:bytes_saved] += source - compressed

        mode_stats = (totals[:by_mode][mode] ||= { count: 0, source_bytes: 0, compressed_bytes: 0, bytes_saved: 0 })
        mode_stats[:count] += 1
        mode_stats[:source_bytes] += source
        mode_stats[:compressed_bytes] += compressed
        mode_stats[:bytes_saved] += source - compressed

        if meta["processing_ms"].is_a?(Numeric) && meta["processing_ms"] >= 0
          totals[:processing_ms] += meta["processing_ms"]
          totals[:timed_count] += 1
        end
      end

      totals[:percent_saved] = totals[:source_bytes].positive? ?
        (100.0 * totals[:bytes_saved] / totals[:source_bytes]).round(2) : 0.0
      totals[:average_processing_ms] = totals[:timed_count].positive? ?
        (totals[:processing_ms].to_f / totals[:timed_count]).round(2) : nil
      totals
    end
  end
end
