# frozen_string_literal: true

# Compressify global config
Compressify.configure do |config|
  # Enable or disable background compression globally.
  config.enabled = true

  # Default ActiveJob queue.
  config.queue_name = :default
  # Optional media-specific queues. Falls back to queue_name when nil.
  config.image_queue_name = :compressify_images
  config.video_queue_name = :compressify_videos

  # Purge replaced blobs after swap when no other attachment still references them.
  config.purge_original = true
  # Do not replace a smaller source with a larger optimized file.
  config.skip_larger_output = true

  # Safety cap for blob downloads in the job.
  config.max_download_bytes = 100.megabytes
  # Optional fast local tmp directory for processing tempfiles.
  # config.tempfile_dir = "/mnt/fast-ssd/compressify-tmp"
  config.tempfile_dir = ENV["COMPRESSIFY_TMPDIR"]
  # Cache lock TTL for duplicate in-flight job protection.
  config.job_lock_ttl = 10.minutes
  # Optional in-flight caps. Nil disables the cap.
  config.image_max_concurrency = 8
  config.video_max_concurrency = 2
  # Re-enqueue delay when a concurrency cap is hit.
  config.concurrency_retry_delay = 5.seconds
  # Skip tiny images where savings are usually negligible.
  config.image_min_bytes_for_compression = 50.kilobytes
  # Adaptive quality for very large images/files.
  config.adaptive_quality_enabled = true
  config.adaptive_quality_min = 60
  config.adaptive_quality_large_image_pixels = 4_000_000
  config.adaptive_quality_large_file_bytes = 3.megabytes
  # Reuse already generated derivatives for the same source+options when available.
  config.reuse_existing_derivatives = true
  # Enable only after creating the PostgreSQL expression index described in README.
  config.postgres_fingerprint_lookup = false
  # Skip processing when an image already fits resize_to_limit bounds.
  config.skip_if_no_resize_needed = false

  # Default image options.
  config.default_image_options = {
    format: nil,                 # :webp, :jpg, :png, :avif (nil keeps original)
    quality: 80,
    resize_to_limit: nil,        # [w, h] fit within bounds
    resize_to_fill: nil,         # [w, h] exact output size with center-crop
    strip: true,
    saver: {}                    # extra vips saver options
  }

  # Default video options. Requires ffmpeg + streamio-ffmpeg.
  config.default_video_options = {
    enabled: false,              # set true to allow video compression
    format: "mp4",
    video_codec: "libx264",
    audio_codec: "aac",
    crf: 28,
    preset: "medium",
    max_width: nil,
    max_height: nil,
    extra_args: []
  }
end
