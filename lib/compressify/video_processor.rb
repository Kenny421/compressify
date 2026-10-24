# frozen_string_literal: true

module Compressify
  class VideoProcessor
    def initialize(context:, blob:)
      @context = context
      @blob = blob
    end

    def call
      opts = context_send(:merged_video_options)
      return context_send(:log_info, "Video compression disabled; attachment_id=#{context_send(:attachment_id_for_log)}") unless opts[:enabled]

      fp = context_send(:fingerprint_for, blob)

      require "streamio-ffmpeg"

      out_format = opts[:format].to_s.downcase.presence || "mp4"

      # Active Storage already downloads into a verified tempfile. Avoid a second disk copy.
      blob.open(tmpdir: context_send(:tempfile_dir)) do |infile|
        Tempfile.create(["compressify-out-", ".#{out_format}"], context_send(:tempfile_dir)) do |outfile|
          outfile.binmode

          movie = FFMPEG::Movie.new(infile.path)
          transcode_opts = {
            video_codec: opts[:video_codec],
            audio_codec: opts[:audio_codec],
            custom: ffmpeg_custom_args(opts)
          }.compact

          movie.transcode(outfile.path, transcode_opts)

          context_send(
            :attach_output!,
            source_blob: blob,
            outfile: outfile,
            filename: "#{blob.filename.base}.#{out_format}",
            content_type: context_send(:content_type_for, out_format),
            fingerprint: fp,
            mode: :video,
            options_snapshot: opts
          )
        end
      end
    rescue LoadError
      context_send(:log_error, "streamio-ffmpeg not available. Add it to your Gemfile.")
    rescue => e
      context_send(:log_error, "Video failed attachment_id=#{context_send(:attachment_id_for_log)} error=#{e.class}: #{e.message}")
      raise
    end

    def ffmpeg_custom_args(opts)
      args = []
      args += ["-preset", opts[:preset].to_s] if opts[:preset].present?
      args += ["-crf", opts[:crf].to_i.to_s] if opts[:crf].present?
      args += ["-threads", opts[:threads].to_i.to_s] if opts[:threads].to_i.positive?

      scale = build_scale(opts)
      args += ["-vf", scale] if scale.present?

      if opts[:extra_args].is_a?(Array)
        args.concat(opts[:extra_args].map(&:to_s))
      end

      args
    end

    def build_scale(opts)
      w = opts[:max_width].presence && opts[:max_width].to_i
      h = opts[:max_height].presence && opts[:max_height].to_i
      return nil unless w || h

      if w && h
        "scale='min(#{w},iw)':'min(#{h},ih)':force_original_aspect_ratio=decrease"
      elsif w
        "scale='min(#{w},iw)':-2"
      else
        "scale=-2:'min(#{h},ih)'"
      end
    end

    private

    attr_reader :context, :blob

    def context_send(method_name, *args, **kwargs, &block)
      context.send(method_name, *args, **kwargs, &block)
    end
  end
end
