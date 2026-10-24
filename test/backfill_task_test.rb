# frozen_string_literal: true

require "test_helper"
require "rake"

Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
load File.expand_path("../lib/tasks/compressify.rake", __dir__)

class BackfillTaskTest < Minitest::Test
  class Demo; end
  class AsyncAdapter; end

  def setup
    @original_env = %w[MODEL ATTACHMENT DRY_RUN RUN_INLINE LIMIT].to_h { |key| [key, ENV[key]] }
    ENV["MODEL"] = "BackfillTaskTest::Demo"
    ENV["ATTACHMENT"] = "image"
    ENV["LIMIT"] = "2"
    ENV["DRY_RUN"] = "false"
    ENV.delete("RUN_INLINE")
    Rake::Task["compressify:backfill"].reenable
  end

  def teardown
    @original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rake::Task["compressify:backfill"].reenable
  end

  def test_non_durable_async_adapter_is_rejected_by_command
    with_job_async_adapter do
      error = assert_raises(RuntimeError) { Rake::Task["compressify:backfill"].invoke }
      assert_match("RUN_INLINE=true", error.message)
      assert_match("persistent Active Job backend", error.message)
    end
  end

  def test_async_adapter_still_permits_dry_run
    ENV["DRY_RUN"] = "true"
    with_job_async_adapter do
      with_fake_batch_report do
        out, = capture_io { Rake::Task["compressify:backfill"].invoke }
        assert_match('"execution_mode": "dry_run"', out)
      end
    end
  end

  def test_inline_mode_restores_job_adapters
    ENV["RUN_INLINE"] = "true"
    job_classes = [Compressify::Job, Compressify::PurgeOriginalJob]
    job_classes << ActiveStorage::PurgeJob if defined?(ActiveStorage::PurgeJob)
    old_adapters = job_classes.map(&:queue_adapter)

    with_fake_batch_report do
      out, = capture_io { Rake::Task["compressify:backfill"].invoke }
      assert_match('"execution_mode": "inline"', out)
    end

    assert_equal old_adapters, job_classes.map(&:queue_adapter)
  end

  private

  def with_fake_batch_report
    klass = class << Compressify::Batch; self; end
    original = Compressify::Batch.method(:enqueue)
    klass.define_method(:enqueue) do |**args|
      { dry_run: args[:dry_run], scanned: 1, eligible: 1, skipped: 0,
        enqueued: args[:dry_run] ? 0 : 1, last_id: 10, resume_after_id: 10, limit: 2 }
    end
    yield
  ensure
    klass.define_method(:enqueue, original)
  end

  def with_job_async_adapter
    klass = class << Compressify::Job; self; end
    original = Compressify::Job.method(:queue_adapter)
    adapter = AsyncAdapter.new
    klass.define_method(:queue_adapter) { adapter }
    yield
  ensure
    klass.define_method(:queue_adapter, original)
  end
end
