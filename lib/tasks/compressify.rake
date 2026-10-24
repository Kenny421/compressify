# frozen_string_literal: true

require "json"

namespace :compressify do
  desc "Dry-run-first, bounded backfill of existing Active Storage attachments"
  task backfill: :environment do
    model_name = ENV.fetch("MODEL")
    attachment_name = ENV.fetch("ATTACHMENT")
    unless model_name.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
      raise ArgumentError, "MODEL must be an existing model constant"
    end
    model = model_name.safe_constantize
    raise ArgumentError, "Unknown model #{model_name}" unless model

    options = JSON.parse(ENV.fetch("OPTIONS_JSON", "{}"))
    raise ArgumentError, "OPTIONS_JSON must contain an object" unless options.is_a?(Hash)

    dry_run = ENV.fetch("DRY_RUN", "true") != "false"
    run_inline = ENV.fetch("RUN_INLINE", "false") == "true"

    # Active Job's AsyncAdapter is process-local. Tasks exit immediately after
    # enqueueing, so work is not durably recorded and can be silently dropped.
    if !dry_run && !run_inline && Compressify::Job.queue_adapter.class.name.to_s.end_with?("AsyncAdapter")
      raise "Cannot safely enqueue backfill to an in-process AsyncAdapter from a one-off command. " \
        "Use RUN_INLINE=true for a small local batch or configure a persistent Active Job backend."
    end

    adapters = []
    begin
      if run_inline && !dry_run
        # Process in this CLI process, including original purge and its
        # Active Storage purge callbacks. Do not change persistent job config.
        classes = [Compressify::Job, Compressify::PurgeOriginalJob]
        classes << ActiveStorage::PurgeJob if defined?(ActiveStorage::PurgeJob)
        classes.each do |job_class|
          adapters << [job_class, job_class.queue_adapter]
          job_class.queue_adapter = :inline
        end
      end

      report = Compressify::Batch.enqueue(
        model: model,
        attachment_name: attachment_name,
        options: options,
        dry_run: dry_run,
        limit: Integer(ENV.fetch("LIMIT", "500")),
        batch_size: Integer(ENV.fetch("BATCH_SIZE", "100")),
        after_id: Integer(ENV.fetch("AFTER_ID", "0"))
      )
      report[:execution_mode] = run_inline && !dry_run ? "inline" : (dry_run ? "dry_run" : "queued")
      puts JSON.pretty_generate(report)
      puts "Resume with AFTER_ID=#{report[:resume_after_id]} (if scanned == limit)" if report[:scanned] == report[:limit]
    ensure
      adapters.reverse_each { |job_class, adapter| job_class.queue_adapter = adapter }
    end
  end

  desc "Summarize storage savings for retained compressed blobs (read-only)"
  task stats: :environment do
    since = ENV["SINCE"] && Time.iso8601(ENV["SINCE"])
    until_at = ENV["UNTIL"] && Time.iso8601(ENV["UNTIL"])
    puts JSON.pretty_generate(Compressify::Statistics.summary(since: since, until_at: until_at))
  end
end
