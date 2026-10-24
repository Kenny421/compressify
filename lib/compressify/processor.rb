# frozen_string_literal: true

require "tempfile"
require "digest"
require "json"
require "logger"
require "marcel"
require "time"

module Compressify
  class Processor
    class << self
      # Normalize supported attachment wrappers to Attachment records.
      def normalize_attachments(attached)
        case attached
        when ActiveStorage::Attached::One
          attached.attached? ? [attached.attachment] : []
        when ActiveStorage::Attached::Many
          attached.attachments.to_a
        when ActiveStorage::Attachment
          [attached]
        else
          []
        end
      end
    end

    def initialize(attachment:, options: {})
      @attachment = attachment
      @options = (options || {}).deep_symbolize_keys
    end

    def call
      blob = @attachment.blob
      return unless blob

      max_bytes = Compressify.config.max_download_bytes
      if blob.byte_size && blob.byte_size > max_bytes
        log_warn("Skip: blob too large (#{blob.byte_size} bytes) attachment_id=#{@attachment.id}")
        return
      end

      attach_to = @options[:attach_to]

      if attach_to.is_a?(Hash)
        @target_name = (attach_to[:name] || attach_to["name"] || @attachment.name).to_sym

        # replace_existing can be:
        # - true  => clear ALL existing compressed attachments on the target
        # - :per_source => only replace compressed attachments that came from THIS source blob
        replace_existing = attach_to.key?(:replace_existing) ? attach_to[:replace_existing] : attach_to["replace_existing"]

        @target_replace_existing =
          case replace_existing
          when true
            :all
          when :per_source, "per_source"
            :per_source
          when :per_record, "per_record"
            :per_record
          else
            false
          end
      else
        @target_name = (attach_to.presence || @attachment.name).to_sym
        @target_replace_existing = false
      end

      @replace_mode = @target_name == @attachment.name.to_sym

      if Compressify.config.skip_if_already_compressed && already_compressed_for_target?(blob)
        log_info("Skip: source blob already compressed for target/options attachment_id=#{@attachment.id} target=#{@target_name}")
        return
      end

      if Compressify.config.dedupe_enabled && already_done?(blob)
        log_info("Skip: already compressed for these options attachment_id=#{@attachment.id} target=#{@target_name}")
        return
      end

      if image?(blob)
        image_opts = merged_image_options
        if try_reuse_derivative!(source_blob: blob, mode: :image, options_snapshot: image_opts)
          return
        end

        if skip_if_no_resize_needed?(blob, image_opts)
          log_info("Skip: image already within resize_to_limit bounds attachment_id=#{@attachment.id}")
          return
        end

        if tiny_image?(blob, image_opts)
          log_info("Skip: tiny image (#{blob.byte_size} bytes) attachment_id=#{@attachment.id}")
          return
        end

        process_image(blob)
      elsif video?(blob)
        video_opts = merged_video_options
        if try_reuse_derivative!(source_blob: blob, mode: :video, options_snapshot: video_opts)
          return
        end

        process_video(blob)
      else
        log_info(
          "Skip: unsupported content_type=#{blob.content_type} detected_type=#{detected_content_type(blob)} " \
          "ext=#{blob_extension(blob)} attachment_id=#{@attachment.id}"
        )
      end
    end

    private

    # ----------------------------
    # Type checks
    # ----------------------------

    def image?(blob)
      return true if blob.content_type.to_s.start_with?("image/")
      return true if image_extensions.include?(blob_extension(blob))

      detected_content_type(blob).to_s.start_with?("image/")
    end

    def video?(blob)
      return true if blob.content_type.to_s.start_with?("video/")
      return true if video_extensions.include?(blob_extension(blob))

      detected_content_type(blob).to_s.start_with?("video/")
    end

    # ----------------------------
    # Options + Dedupe
    # ----------------------------

    def merged_image_options
      Compressify.config.default_image_options.deep_merge(
        @options.slice(:format, :quality, :resize_to_limit, :resize_to_fill, :strip, :saver)
      )
    end

    def merged_video_options
      Compressify.config.default_video_options.deep_merge(@options.fetch(:video, {}))
    end

    def fingerprint_for(source_blob)
      payload = {
        v: Compressify::VERSION,
        source_blob_key: source_blob.key,
        target: @target_name.to_s,
        image: merged_image_options,
        video: merged_video_options
      }
      Digest::SHA256.hexdigest(stable_json(payload))
    end

    def already_done?(source_blob)
      fp = fingerprint_for(source_blob)

      if @replace_mode
        meta_fp = compressify_meta(@attachment.blob)&.dig("fingerprint")
        return true if meta_fp == fp
      end

      record = @attachment.record
      return false unless record.respond_to?(@target_name)

      target = active_storage_target_for(record)

      blobs =
        case target
        when ActiveStorage::Attached::One
          target.attached? ? [target.blob] : []
        when ActiveStorage::Attached::Many
          target.attachments.map(&:blob)
        else
          []
        end

      blobs.any? { |b| compressify_meta(b)&.dig("fingerprint") == fp }
    rescue => e
      log_warn("Dedupe check failed (continuing) attachment_id=#{@attachment.id} error=#{e.class}: #{e.message}")
      false
    end

    def already_compressed_for_target?(source_blob)
      meta = compressify_meta(source_blob)
      return false unless meta.is_a?(Hash)
      return false unless meta["target"].to_s == @target_name.to_s

      expected_mode =
        if image?(source_blob)
          "image"
        elsif video?(source_blob)
          "video"
        end
      return false unless expected_mode && meta["mode"].to_s == expected_mode

      prior_options = meta["options"]
      return false unless prior_options.is_a?(Hash)

      current_options =
        if expected_mode == "image"
          merged_image_options
        else
          merged_video_options
        end

      normalized_stable_json(prior_options) == normalized_stable_json(current_options)
    rescue => e
      log_warn("Already-compressed guard failed (continuing) attachment_id=#{@attachment.id} error=#{e.class}: #{e.message}")
      false
    end

    def compressify_meta(blob)
      key = Compressify.config.metadata_key.to_s
      (blob.metadata || {})[key]
    end

    def stable_json(obj)
      JSON.generate(deep_sort(obj))
    end

    def normalized_stable_json(obj)
      stable_json(normalize_values_for_compare(obj))
    end

    def deep_sort(obj)
      case obj
      when Hash
        obj.keys.map(&:to_s).sort.each_with_object({}) do |k, h|
          h[k] = deep_sort(obj[k.to_sym] || obj[k])
        end
      when Array
        obj.map { |v| deep_sort(v) }
      else
        obj
      end
    end

    def normalize_values_for_compare(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), out|
          normalized = normalize_values_for_compare(v)
          next if normalized.nil?

          out[k.to_s] = normalized
        end
      when Array
        obj.map { |v| normalize_values_for_compare(v) }
      when Symbol
        obj.to_s
      else
        obj
      end
    end

    # ----------------------------
    # Image processing (libvips)
    # ----------------------------

    def process_image(blob)
      Compressify::ImageProcessor.new(context: self, blob: blob).call
    end

    # ----------------------------
    # Video processing (ffmpeg)
    # ----------------------------

    def process_video(blob)
      Compressify::VideoProcessor.new(context: self, blob: blob).call
    end

    # Compatibility wrappers for existing tests and internal callers.
    def ffmpeg_custom_args(opts)
      Compressify::VideoProcessor.new(context: self, blob: @attachment.blob).ffmpeg_custom_args(opts)
    end

    def build_scale(opts)
      Compressify::VideoProcessor.new(context: self, blob: @attachment.blob).build_scale(opts)
    end

    # ----------------------------
    # Attaching + metadata
    # ----------------------------

    def attach_output!(source_blob:, outfile:, filename:, content_type:, fingerprint:, mode:, options_snapshot:)
      outfile.rewind
      output_byte_size = File.size(outfile.path)
      source_byte_size = blob_byte_size(source_blob)
      savings = compression_savings(source_bytes: source_byte_size, output_bytes: output_byte_size)

      if @replace_mode && Compressify.config.skip_larger_output &&
          source_byte_size && output_byte_size >= source_byte_size
        log_info(
          "Skip larger output attachment_id=#{attachment_id_for_log} " \
          "source_bytes=#{source_byte_size} output_bytes=#{output_byte_size}"
        )
        return false
      end

      meta_key = Compressify.config.metadata_key.to_s
      new_metadata = (source_blob.metadata || {}).dup
      new_metadata[meta_key] = {
        "fingerprint" => fingerprint,
        "mode" => mode.to_s,
        "target" => @target_name.to_s,
        "source_blob_key" => source_blob.key,
        "record_id" => @attachment.record_id,
        "record_type" => @attachment.record_type,
        "options" => options_snapshot,
        "source_byte_size" => source_byte_size,
        "compressed_byte_size" => output_byte_size,
        "bytes_saved" => savings[:bytes_saved],
        "percent_saved" => savings[:percent_saved],
        "processed_at" => Time.now.utc.iso8601
      }

      new_blob = ActiveStorage::Blob.create_and_upload!(
        io: outfile,
        filename: filename,
        content_type: content_type || source_blob.content_type,
        metadata: new_metadata,
        identify: false
      )

      record = @attachment.record

      if @replace_mode
        old_blob = @attachment.blob
        @attachment.update!(blob: new_blob)

        maybe_purge_old_blob(old_blob) if Compressify.config.purge_original
      else
        unless record.respond_to?(@target_name)
          raise Compressify::Error, "Record #{record.class} does not respond to #{@target_name}"
        end

        target_assoc = active_storage_target_for(record)

        if target_assoc.is_a?(ActiveStorage::Attached::Many) && @target_replace_existing
          case @target_replace_existing
          when :all
            target_assoc.attachments.each(&:purge_later)
          when :per_source
            target_assoc.attachments.each do |att|
              meta = compressify_meta(att.blob)
              next unless meta.is_a?(Hash)
              next unless meta["source_blob_key"].to_s == source_blob.key.to_s

              att.purge_later
            end
          when :per_record
            # Purge compressed attachments for this record and target name.
            record_id = @attachment.record_id.to_s
            record_type = @attachment.record_type.to_s

            target_assoc.attachments.each do |att|
              meta = compressify_meta(att.blob)
              next unless meta.is_a?(Hash)
              next unless meta["record_id"].to_s == record_id
              next unless meta["record_type"].to_s == record_type
              next unless meta["target"].to_s == @target_name.to_s

              att.purge_later
            end
          end
        end

        target_assoc.attach(new_blob)
      end

      log_info(
        "Compressed #{mode} attachment_id=#{attachment_id_for_log} target=#{@target_name} " \
        "source_bytes=#{source_byte_size} compressed_bytes=#{output_byte_size} " \
        "bytes_saved=#{savings[:bytes_saved]} percent_saved=#{savings[:percent_saved]}"
      )
    end

    def maybe_purge_old_blob(old_blob)
      return unless old_blob
      # Only purge if nobody else is using it.
      if old_blob.attachments.reload.none?
        # Delete from storage before destroying the DB record so failures remain retryable.
        Compressify::PurgeOriginalJob.perform_later(blob_id: old_blob.id)
      end
    rescue => e
      log_warn("Could not purge old blob (continuing) old_blob_id=#{old_blob&.id} error=#{e.class}: #{e.message}")
    end

    def try_reuse_derivative!(source_blob:, mode:, options_snapshot:)
      return false unless Compressify.config.reuse_existing_derivatives

      fp = fingerprint_for(source_blob)
      reusable = reusable_blob_for(fingerprint: fp, mode: mode, exclude_blob_id: source_blob.id)
      return false unless reusable

      attach_existing_blob!(source_blob: source_blob, existing_blob: reusable, mode: mode, options_snapshot: options_snapshot, fingerprint: fp)
      log_info("Reuse: attached existing #{mode} derivative attachment_id=#{@attachment.id} reusable_blob_id=#{reusable.id}")
      true
    rescue => e
      log_warn("Reuse check failed (continuing) attachment_id=#{@attachment.id} error=#{e.class}: #{e.message}")
      false
    end

    def reusable_blob_for(fingerprint:, mode:, exclude_blob_id: nil)
      candidates = reusable_blob_candidates(fingerprint)
      candidates = candidates.where.not(id: exclude_blob_id) if exclude_blob_id && candidates.respond_to?(:where)

      candidates.find do |candidate|
        meta = compressify_meta(candidate)
        next false unless meta.is_a?(Hash)

        meta["fingerprint"].to_s == fingerprint.to_s &&
          meta["mode"].to_s == mode.to_s
      end
    end

    def reusable_blob_candidates(fingerprint)
      if Compressify.config.postgres_fingerprint_lookup &&
          ActiveStorage::Blob.connection.adapter_name.to_s.downcase.include?("postgres")
        metadata_key = ActiveStorage::Blob.connection.quote(Compressify.config.metadata_key.to_s)
        # Requires the matching expression index documented in README.md.
        ActiveStorage::Blob.where(
          "(metadata::jsonb -> #{metadata_key} ->> 'fingerprint') = ?",
          fingerprint
        )
      else
        pattern = %("fingerprint":"#{fingerprint}")
        ActiveStorage::Blob.where("metadata LIKE ?", "%#{pattern}%")
      end
    end

    def attach_existing_blob!(source_blob:, existing_blob:, mode:, options_snapshot:, fingerprint:)
      record = @attachment.record

      if @replace_mode
        old_blob = @attachment.blob
        return if old_blob&.id == existing_blob.id

        @attachment.update!(blob: existing_blob)
        maybe_purge_old_blob(old_blob) if Compressify.config.purge_original
      else
        unless record.respond_to?(@target_name)
          raise Compressify::Error, "Record #{record.class} does not respond to #{@target_name}"
        end

        target_assoc = active_storage_target_for(record)
        if target_assoc.is_a?(ActiveStorage::Attached::Many) && @target_replace_existing
          purge_matching_target_attachments(target_assoc, source_blob)
        end

        target_assoc.attach(existing_blob)
      end
    end

    def purge_matching_target_attachments(target_assoc, source_blob)
      case @target_replace_existing
      when :all
        target_assoc.attachments.each(&:purge_later)
      when :per_source
        target_assoc.attachments.each do |att|
          meta = compressify_meta(att.blob)
          next unless meta.is_a?(Hash)
          next unless meta["source_blob_key"].to_s == source_blob.key.to_s

          att.purge_later
        end
      when :per_record
        record_id = @attachment.record_id.to_s
        record_type = @attachment.record_type.to_s

        target_assoc.attachments.each do |att|
          meta = compressify_meta(att.blob)
          next unless meta.is_a?(Hash)
          next unless meta["record_id"].to_s == record_id
          next unless meta["record_type"].to_s == record_type
          next unless meta["target"].to_s == @target_name.to_s

          att.purge_later
        end
      end
    end

    # ----------------------------
    # Helpers
    # ----------------------------

    def content_type_for(ext)
      case ext.to_s.downcase
      when "jpg", "jpeg" then "image/jpeg"
      when "png" then "image/png"
      when "webp" then "image/webp"
      when "avif" then "image/avif"
      when "mp4" then "video/mp4"
      when "mov" then "video/quicktime"
      when "mkv" then "video/x-matroska"
      else nil
      end
    end

    def extension_for_content_type(content_type)
      case content_type.to_s.downcase
      when "image/jpeg" then "jpg"
      when "image/png" then "png"
      when "image/webp" then "webp"
      when "image/avif" then "avif"
      when "image/gif" then "gif"
      when "image/heic" then "heic"
      when "image/heif" then "heif"
      when "image/tiff" then "tiff"
      when "video/mp4" then "mp4"
      when "video/quicktime" then "mov"
      when "video/x-matroska" then "mkv"
      else nil
      end
    end

    def symbolize_keys(hash)
      hash.transform_keys { |k| k.to_sym rescue k }
    end

    def blob_byte_size(blob)
      return nil unless blob.respond_to?(:byte_size)

      blob.byte_size
    rescue StandardError
      nil
    end

    def compression_savings(source_bytes:, output_bytes:)
      return { bytes_saved: nil, percent_saved: nil } unless source_bytes

      source = source_bytes.to_i
      output = output_bytes.to_i
      saved = source - output
      percent =
        if source.positive?
          ((saved.to_f / source) * 100).round(2)
        else
          0.0
        end

      { bytes_saved: saved, percent_saved: percent }
    end

    def blob_extension(blob)
      blob.filename.extension_without_delimiter.to_s.downcase
    rescue StandardError
      ""
    end

    def image_extensions
      @image_extensions ||= %w[jpg jpeg png webp avif gif bmp tif tiff heic heif]
    end

    def video_extensions
      @video_extensions ||= %w[mp4 mov mkv webm avi m4v]
    end

    def detected_content_type(blob)
      return nil unless unknown_content_type?(blob.content_type)

      blob.open do |io|
        Marcel::MimeType.for(io, name: blob.filename.to_s, declared_type: blob.content_type.to_s)
      end
    rescue StandardError => e
      log_warn("Could not detect mime type attachment_id=#{@attachment.id} error=#{e.class}: #{e.message}")
      nil
    end

    def unknown_content_type?(content_type)
      ct = content_type.to_s.strip.downcase
      ct.empty? || ct == "application/octet-stream" || ct == "binary/octet-stream"
    end

    def tiny_image?(blob, opts = {})
      min_bytes = Compressify.config.image_min_bytes_for_compression
      return false unless min_bytes.to_i.positive?
      return false unless blob.byte_size.to_i.positive?
      return false if image_transform_requested?(blob, opts)

      blob.byte_size.to_i < min_bytes.to_i
    end

    def image_transform_requested?(blob, opts)
      return true if opts[:resize_to_limit].is_a?(Array)
      return true if opts[:resize_to_fill].is_a?(Array)

      requested_format = opts[:format].to_s.downcase.presence
      return false unless requested_format

      current_ext = blob_extension(blob)
      current_ext = extension_for_content_type(blob.content_type).to_s.downcase if current_ext.blank?
      current_ext = "jpg" if current_ext == "jpeg"
      requested_format = "jpg" if requested_format == "jpeg"

      requested_format != current_ext
    rescue StandardError
      true
    end

    def skip_if_no_resize_needed?(blob, opts)
      return false unless Compressify.config.skip_if_no_resize_needed
      return false unless opts[:resize_to_limit].is_a?(Array)
      return false if opts[:resize_to_fill].is_a?(Array)

      width, height = image_dimensions_from_metadata(blob)
      return false unless width.to_i.positive? && height.to_i.positive?

      target_w_raw, target_h_raw = opts[:resize_to_limit]
      target_w = target_w_raw.to_i if target_w_raw.present?
      target_h = target_h_raw.to_i if target_h_raw.present?
      return false unless target_w.to_i.positive? || target_h.to_i.positive?

      within_width = !target_w.to_i.positive? || width.to_i <= target_w.to_i
      within_height = !target_h.to_i.positive? || height.to_i <= target_h.to_i
      within_width && within_height
    rescue StandardError
      false
    end

    def image_dimensions_from_metadata(blob)
      meta = blob.metadata || {}
      [meta["width"], meta["height"]]
    rescue StandardError
      [nil, nil]
    end

    def adaptive_quality_for(base_quality:, image:, blob:)
      return base_quality unless Compressify.config.adaptive_quality_enabled

      adjusted = base_quality.to_i
      min_q = Compressify.config.adaptive_quality_min.to_i
      pixels_threshold = Compressify.config.adaptive_quality_large_image_pixels.to_i
      bytes_threshold = Compressify.config.adaptive_quality_large_file_bytes.to_i

      if image && image.respond_to?(:width) && image.respond_to?(:height)
        pixel_count = image.width.to_i * image.height.to_i
        adjusted -= 10 if pixels_threshold.positive? && pixel_count >= pixels_threshold
      end

      adjusted -= 8 if bytes_threshold.positive? && blob.byte_size.to_i >= bytes_threshold
      adjusted = [adjusted, min_q].max if min_q.positive?
      [adjusted, 100].min
    rescue StandardError
      base_quality.to_i
    end

    def download_blob_to_tempfile(blob, tempfile)
      tempfile.binmode
      blob.open do |io|
        IO.copy_stream(io, tempfile)
      end
      tempfile.flush
      tempfile.rewind
    end

    def tempfile_dir
      dir = Compressify.config.tempfile_dir
      return nil if dir.blank?
      return nil unless Dir.exist?(dir)

      dir
    rescue StandardError
      nil
    end

    # Scale to cover target dimensions, then center-crop.
    # Produces exact output dimensions for "size: WxH!" style usage.
    def resize_to_fill(image, width, height)
      iw = image.width.to_f
      ih = image.height.to_f
      return image unless iw.positive? && ih.positive?

      scale = [width.to_f / iw, height.to_f / ih].max
      # Guard against float rounding under target by a pixel.
      if (iw * scale).floor < width || (ih * scale).floor < height
        scale *= 1.001
      end

      scaled = (scale - 1.0).abs < 0.0001 ? image : preserve_image_result(image) { |img| img.resize(scale) }

      left = [(scaled.width - width) / 2, 0].max
      top = [(scaled.height - height) / 2, 0].max
      crop_w = [width, scaled.width].min
      crop_h = [height, scaled.height].min

      preserve_image_result(scaled) { |img| img.extract_area(left, top, crop_w, crop_h) }
    end

    # Some Vips operations can return nil unexpectedly in edge cases.
    # Keep the previous image in those situations so the pipeline remains stable.
    def preserve_image_result(image)
      result = yield(image)
      result || image
    end

    def active_storage_target_for(record)
      target = record.public_send(@target_name)
      return target if target.is_a?(ActiveStorage::Attached::One) || target.is_a?(ActiveStorage::Attached::Many)

      raise Compressify::Error, "Target #{@target_name} on #{record.class} is not an Active Storage attachment"
    end

    def logger
      return Rails.logger if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      @logger ||= Logger.new($stdout)
    end

    def attachment_id_for_log
      return nil unless @attachment&.respond_to?(:id)

      @attachment.id
    rescue StandardError
      nil
    end

    def log_info(msg) = logger.info("[Compressify] #{msg}")
    def log_warn(msg) = logger.warn("[Compressify] #{msg}")
    def log_error(msg) = logger.error("[Compressify] #{msg}")
  end
end
