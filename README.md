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

Recommended production pattern:

- Route image and video jobs to separate queues
- Keep video concurrency lower than image concurrency
- Point `tempfile_dir` at fast local storage if large uploads are common
- Leave dedupe and stale-job protections enabled

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

CI runs the test suite on Ruby `3.1`, `3.2`, and `3.3`.

## Local Development

```bash
bin/setup
bin/test
```

## Why This Instead of Variants

Use Active Storage variants when you need render-time derivatives.

Use Compressify when you want to optimize what gets stored, track byte savings, and automate the process at the model/job layer.
