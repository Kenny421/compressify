# Compressify

Compressify is a Rails gem that automatically optimizes Active Storage uploads in background jobs.

Its focus is simple: shrink what you store, not just what you render.

If your app accepts uploads and your storage bill keeps quietly getting bolder, Compressify gives you a repeatable post-upload pipeline without making every Rails app invent one from scratch.

Compressify can:

- Compress uploaded images with `libvips`
- Optionally transcode videos with `ffmpeg`
- Replace the original blob to maximize storage savings
- Keep the original and attach an optimized copy instead
- Route image and video work to separate queues
- Skip stale, duplicate, or already-compressed work
- Reuse matching derivatives instead of regenerating them
- Record byte savings in blob metadata

## Why Use Compressify

Rails variants are useful for rendering alternate versions on demand. They do not reduce the storage footprint of the original upload.

Compressify is for teams that want to optimize the stored upload itself, or persist a compressed companion attachment, with background-job safety and repeatable behavior.

Use Compressify when you want:

- Lower Active Storage costs
- Smaller images by default across the app
- Automatic post-upload optimization
- A repeatable model-level API instead of controller glue

## Variants vs Compressify

| Concern | Rails variants | Compressify |
| --- | --- | --- |
| Optimizes original stored upload | No | Yes |
| Runs automatically after upload | Usually app-specific | Yes |
| Replaces original blob safely | No | Yes |
| Keeps source and writes optimized copy | Manual | Yes |
| Skips stale or duplicate jobs | Manual | Yes |
| Tracks byte savings in metadata | No | Yes |

## Installation

Add the gem:

```ruby
gem "compressify"
```

Then install dependencies:

```bash
bundle install
bundle exec rails generate compressify:install
```

## Requirements

Compressify is intended for:

- Ruby `3.1+`
- Rails / Active Storage `6.1+`

Native dependencies:

- `libvips` for image processing
- `ffmpeg` for video processing
- `streamio-ffmpeg` in your app Gemfile if you enable video compression

Ubuntu example:

```bash
sudo apt install libvips ffmpeg
```

Video support in your app:

```ruby
gem "streamio-ffmpeg"
```

## Quick Start

If Active Storage is not installed yet:

```bash
bundle exec rails active_storage:install
bundle exec rails db:migrate
```

Compress and replace the original image:

```ruby
class Photo < ApplicationRecord
  has_one_attached :image

  include Compressify::Model

  auto_compress :image, format: :webp, quality: 80, size: "1600x1600"
end
```

What happens next:

1. The user uploads the original file.
2. Compressify enqueues a background job after commit.
3. The job downloads and processes the blob.
4. The attachment is swapped to the optimized blob.
5. The replaced blob is purged later if no other attachment still references it.

## Why Teams Usually Like It

- The API stays close to the model instead of leaking attachment logic into controllers and custom jobs.
- It is conservative around race conditions, stale jobs, and duplicate work.
- It works for both "replace the original" and "keep the original" workflows.
- The metadata shows whether the gem is actually saving storage instead of just feeling productive.

## Common Model Setups

Replace the original upload to maximize storage savings:

```ruby
class Photo < ApplicationRecord
  has_one_attached :image

  include Compressify::Model

  auto_compress :image,
    format: :webp,
    quality: 80,
    size: "1600x1600"
end
```

Keep the original and attach a compressed copy:

```ruby
class Photo < ApplicationRecord
  has_one_attached :image
  has_one_attached :compressed_image

  include Compressify::Model

  auto_compress :image,
    attach_to: :compressed_image,
    format: :webp,
    quality: 80
end
```

Generate exact dimensions with center-crop:

```ruby
auto_compress :image, format: :webp, quality: 80, size: "600x600!"
```

Process `has_many_attached` uploads:

```ruby
class Gallery < ApplicationRecord
  has_many_attached :photos

  include Compressify::Model

  auto_compress :photos, format: :webp, quality: 78, size: "2000x2000"
end
```

## Video Compression

Enable video compression explicitly:

```ruby
class Clip < ApplicationRecord
  has_one_attached :video

  include Compressify::Model

  auto_compress :video,
    video: {
      enabled: true,
      format: "mp4",
      video_codec: "libx264",
      audio_codec: "aac",
      crf: 28,
      preset: "medium",
      max_width: 1280,
      max_height: 720
    }
end
```

Keep the source video and store the optimized result separately:

```ruby
class Clip < ApplicationRecord
  has_one_attached :video
  has_one_attached :compressed_video

  include Compressify::Model

  auto_compress :video,
    attach_to: :compressed_video,
    video: {
      enabled: true,
      format: "mp4",
      crf: 28,
      preset: "medium"
    }
end
```

## API Overview

Primary API:

```ruby
auto_compress :attachment_name, **options
```

Common options:

- `format:` output format for images such as `:webp`, `:jpg`, `:png`, `:avif`
- `quality:` image quality target
- `size:` shorthand resize syntax such as `"1600x1600"` or `"600x600!"`
- `resize_to_limit:` direct resize option
- `resize_to_fill:` direct exact-size resize option
- `attach_to:` keep original and store compressed output elsewhere
- `only:` `:create`, `:update`, or both
- `if:` conditional lambda
- `unless:` conditional lambda
- `video:` nested video options

`size:` examples:

```ruby
size: "1200x1200"  # fit within bounds
size: "1200x"      # width only
size: "x1200"      # height only
size: "600x600!"   # exact size with center-crop
size: [1200, 1200]
```

## Initializer and Queueing

The installer generates `config/initializers/compressify.rb`.

Important production settings:

- `config.queue_name`
- `config.image_queue_name`
- `config.video_queue_name`
- `config.job_lock_ttl`
- `config.image_max_concurrency`
- `config.video_max_concurrency`
- `config.max_download_bytes`
- `config.tempfile_dir`
- `config.reuse_existing_derivatives`
- `config.skip_larger_output`
- `config.postgres_fingerprint_lookup` (opt-in, PostgreSQL only)

Recommended production pattern:

- Route image and video jobs to separate queues
- Keep video concurrency lower than image concurrency
- Point `tempfile_dir` at fast local storage if large uploads are common
- Leave dedupe and stale-job protections enabled
- Set conservative worker counts to fit your CPU/RAM budget (for example, start at 1 FFmpeg job on a small VPS)
- Optionally set `video: { threads: 2 }` (or `config.default_video_options[:threads] = 2`) to cap FFmpeg encoder threads per job
- Benchmark different FFmpeg presets/CRF values rather than expecting faster encoding solely from Ruby changes

## Storage safeguards and faster PostgreSQL reuse lookups

Compressify now uses the verified tempfile yielded by `ActiveStorage::Blob#open`
rather than copying the downloaded source into another tempfile. The optimized
output still goes to a separate temporary file before upload.

By default, `config.skip_larger_output = true` prevents in-place replacement
when the optimized output would be the same size or larger than the original.
This applies only to replacement mode: companion attachments created using
`attach_to:` are still saved, even if larger. For one attachment that **must**
produce a specific format or exact dimensions, set `allow_larger_output: true`
in its `auto_compress` options. For example:

```ruby
auto_compress :avatar, format: :webp, quality: 82, size: "512x512!",
  allow_larger_output: true
```

Without this opt-in, a tiny source image can be retained instead of the
larger 512x512 WebP. Alternatively, to disable the safeguard everywhere,
set `config.skip_larger_output = false` (not recommended for storage-first apps).

For very large PostgreSQL Active Storage tables, you can opt into an indexed
fingerprint lookup for derivative reuse. Run this SQL in a **nontransactional**
database migration (or a supervised maintenance session):

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS
  index_active_storage_blobs_on_compressify_fingerprint
ON active_storage_blobs
  (((metadata::jsonb -> 'compressify' ->> 'fingerprint')));
```

After the index exists, set `config.postgres_fingerprint_lookup = true`.
This fast path requires PostgreSQL and the default `metadata_key: "compressify"`.
If your metadata key differs, use the same key in your index expression.
Other databases and installs without this setting retain the legacy
`metadata LIKE` lookup. Do not enable the fast path until the index has
finished building. The existing metadata must contain valid JSON.

## Active Storage optimistic locking

When replacing a Book/User image, Rails may automatically touch the parent
record. An attachment job can hold a stale in-memory parent `lock_version`
after another request updates that record. Compressify refreshes the parent
before the swap, and retries `ActiveRecord::StaleObjectError` up to three
times if a concurrent update still occurs. A failed transaction does **not**
schedule deletion of the original. New files uploaded to storage by the failed
attempt are cleaned up after rollback when possible.

Original-file purge jobs are enqueued **after** the attachment transaction
commits, so an asynchronous worker does not incorrectly see the source as
still attached before the update becomes visible.

## Retryable original cleanup

Replaced original blobs are scheduled for `Compressify::PurgeOriginalJob`.
The job checks that no attachments reference the blob, then deletes the
underlying storage object **before** destroying its database record.
If storage deletion fails, the record remains and the job retries (up to
five attempts, 30 seconds apart). Shared originals are deliberately preserved.
Keep your Active Job worker running and monitor exhausted retries. Already
orphaned objects from older gem versions require a separate storage audit;
this update cannot retroactively locate all of them.


## Batch optimization for existing uploads

Compressify can now enqueue **existing** attachments in bounded, resumable batches
instead of only handling newly uploaded files. The default is a **dry run**.
No original blobs are changed directly by the batch scanner: it schedules
the same idempotent `Compressify::Job` used for regular uploads. By default,
the batch uses the model's own `auto_compress` declarations, including its
format, resize settings, conditions and dynamic option block. Explicit
`options:` / `OPTIONS_JSON` settings override those declared options.

Preview the first 500 book covers:

```sh
bundle exec rails compressify:backfill MODEL=Book ATTACHMENT=cover_image
```

Explicitly enqueue a smaller batch, then resume at the `resume_after_id`
from the JSON report:

```sh
bundle exec rails compressify:backfill MODEL=Book ATTACHMENT=cover_image DRY_RUN=false LIMIT=100
bundle exec rails compressify:backfill MODEL=Book ATTACHMENT=cover_image DRY_RUN=false LIMIT=100 AFTER_ID=12345
```

Pass custom processor options, e.g. for a legacy image attachment:

```sh
bundle exec rails compressify:backfill MODEL=Photo ATTACHMENT=image DRY_RUN=false LIMIT=100 OPTIONS_JSON='{"format":"webp","quality":78}'
```

Or call the API:

```ruby
Compressify::Batch.enqueue(model: Book, attachment_name: :cover_image, dry_run: true)
Compressify::Batch.enqueue(model: Book, attachment_name: :cover_image,
  dry_run: false, limit: 100, after_id: 0, options: { format: :webp, quality: 82 })
```

The scanner validates the model attachment, skips unsupported/oversized blobs,
caps each invocation to 10,000 attachment rows, and enqueues an expected
`blob_id` so replaced attachments cannot be overwritten by stale jobs. The
`eligible` count is a *candidate* count; the job may still skip an already
optimized image, or an output that would exceed its original size. For sustained
backfills, use a durable Active Job backend and monitor queue depth. Scheduling
many batches concurrently can create excess queue load. Run a dry run and
test on a few uploads before applying it to production.

## Compression statistics and instrumentation

A read-only snapshot reports savings from **currently retained** compressed
blobs (those whose Active Storage blob metadata includes Compressify data):

```sh
bundle exec rails compressify:stats
bundle exec rails compressify:stats SINCE=2026-10-01T00:00:00Z
```

```ruby
Compressify::Statistics.summary
Compressify::Statistics.summary(since: 7.days.ago)
```

The result includes `count`, `source_bytes`, `compressed_bytes`,
`bytes_saved`, `percent_saved`, `by_mode`, and `average_processing_ms`
(for outputs produced by the new pipeline). Older outputs without timings
still count toward byte savings. This scans blob metadata and can be expensive
on large databases; use during off-peak periods. Deleted/replaced derivatives
are no longer included, so it is **not** a lifetime accounting ledger.

Each compression job also publishes an `ActiveSupport::Notifications`
event named `compressify.job`, with status (`compressed`, `reused`,
`skipped`, or `failed`), duration, byte counts, skip reason and error class.
Attach your own monitoring/analytics subscriber to build cumulative metrics:

```ruby
ActiveSupport::Notifications.subscribe("compressify.job") do |_name, _start, _finish, _id, payload|
  Rails.logger.info("Compressify metric: #{payload.slice(:status, :duration_ms, :bytes_saved).inspect}")
end
```

No uploaded image bytes or filenames are included in the event payload.

## Cross-worker concurrency control

Compressify now supports PostgreSQL **session advisory-lock slots**, which
coordinate the image/video concurrency caps across independent Rails
processes sharing the same PostgreSQL database. They do not require Redis,
migrations or an additional service:

```ruby
Compressify.configure do |config|
  config.concurrency_backend = :auto # default: PostgreSQL advisory slots when PostgreSQL is configured
  config.concurrency_namespace = "my-rails-app"
  config.image_max_concurrency = 4
  config.video_max_concurrency = 1
end
```

Use `:postgres` to require a PostgreSQL adapter or `:cache` to always use
the existing cache-backed slots. On SQLite/other databases, `:auto` falls
back to the cache backend; a **process-local** cache cannot enforce limits
across multiple workers. Use a shared atomic cache or PostgreSQL if you
need cross-process limits. PostgreSQL slots release when a job exits or
its connection closes, so stale TTL keys cannot permanently block work.
Excess work is re-enqueued after `concurrency_retry_delay`.

Note: advisory locks prevent more than the configured *number of concurrent
processors* only if every worker uses the same database/namespace and
matching limits. They do not substitute for durable queues or stale-blob
checks. For production, validate with real PostgreSQL and concurrent workers
before scaling traffic.

## Failure Behavior and Safety

Compressify is designed to be conservative:

- Jobs run after commit, so the attachment and blob exist before processing starts
- Jobs skip stale work if the attachment changed after enqueue
- Cache-backed idempotency locks reduce duplicate in-flight jobs
- Image and video concurrency can be limited independently
- Existing matching derivatives can be reused instead of regenerated
- Replaced blobs are only purged when no other attachment still references them

## Metadata and Savings

Compressed blobs store metadata under the configured `metadata_key`, including:

- `fingerprint`
- `mode`
- `target`
- `source_blob_key`
- `source_byte_size`
- `compressed_byte_size`
- `bytes_saved`
- `percent_saved`
- `processed_at`

That gives you something better than a hunch when you want to prove the gem is saving space.
- Optional concurrency caps protect workers from media-processing spikes
- Large downloads can be rejected with `max_download_bytes`
- Original blobs are only purged after replacement if no other attachments still reference them

Transient job failures retry automatically. If dedupe or metadata checks fail, Compressify logs and continues instead of blocking uploads.

## Measuring Storage Savings

Compressify records savings data in blob metadata under the configured metadata key.

Example metadata fields:

- `source_byte_size`
- `compressed_byte_size`
- `bytes_saved`
- `percent_saved`
- `processed_at`

Console example:

```ruby
blob = Photo.last.image.blob
blob.metadata["compressify"]
```

You can also inspect logs for per-job savings summaries after compression completes.

## Before Adopting in Production

Validate these questions in your app:

- Should the original upload be replaced or preserved?
- Which attachment types should be auto-compressed?
- Which queue handles image work and which queue handles video work?
- What maximum blob size is acceptable for background processing?
- Do you want a storage-first policy or a quality-first policy for specific models?

If you are migrating an existing app, start with one attachment type, measure `bytes_saved`, then expand.

## Compatibility

The gemspec targets:

- Ruby `>= 3.1`
- Active Support `>= 6.1`
- Active Job `>= 6.1`
- Active Storage `>= 6.1`

CI runs the test suite on Ruby `3.1` (separate Rails 7.1 dependency set), `3.2`, `3.3`, and `3.4`.

## Local Development

```bash
bin/setup
bin/test
```

## Why This Instead of Variants

Use Active Storage variants when you need render-time derivatives.

Use Compressify when you want to optimize what gets stored, track byte savings, and automate the process at the model/job layer.
