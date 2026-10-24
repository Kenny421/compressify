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

    report = Compressify::Batch.enqueue(
      model: model,
      attachment_name: attachment_name,
      options: options,
      dry_run: ENV.fetch("DRY_RUN", "true") != "false",
      limit: Integer(ENV.fetch("LIMIT", "500")),
      batch_size: Integer(ENV.fetch("BATCH_SIZE", "100")),
      after_id: Integer(ENV.fetch("AFTER_ID", "0"))
    )
    puts JSON.pretty_generate(report)
    puts "Resume with AFTER_ID=#{report[:resume_after_id]} (if scanned == limit)" if report[:scanned] == report[:limit]
  end

  desc "Summarize storage savings for retained compressed blobs (read-only)"
  task stats: :environment do
    since = ENV["SINCE"] && Time.iso8601(ENV["SINCE"])
    until_at = ENV["UNTIL"] && Time.iso8601(ENV["UNTIL"])
    puts JSON.pretty_generate(Compressify::Statistics.summary(since: since, until_at: until_at))
  end
end
