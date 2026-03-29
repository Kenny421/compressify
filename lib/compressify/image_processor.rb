# frozen_string_literal: true

module Compressify
  class ImageProcessor
    def initialize(context:, blob:)
      @context = context
      @blob = blob
    end

    def call
      opts = context_send(:merged_image_options)
      fp = context_send(:fingerprint_for, blob)

      input_ext = context_send(:blob_extension, blob).presence || context_send(:extension_for_content_type, blob.content_type) || "img"
      out_format = (opts[:format].presence || input_ext).to_s.downcase
      out_format = context_send(:extension_for_content_type, blob.content_type) || "jpg" if out_format.blank? || out_format == "img"
      out_format = "jpg" if out_format == "jpeg"

      Tempfile.create(["compressify-in-", ".#{input_ext}"], context_send(:tempfile_dir)) do |infile|
        context_send(:download_blob_to_tempfile, blob, infile)

        Tempfile.create(["compressify-out-", ".#{out_format}"], context_send(:tempfile_dir)) do |outfile|
          outfile.binmode

          img = Vips::Image.new_from_file(infile.path, access: :sequential)
          img = context_send(:preserve_image_result, img) { |image| image.autorot } if img.respond_to?(:autorot)

          if opts[:resize_to_fill].is_a?(Array)
            w_raw, h_raw = opts[:resize_to_fill]
            w = w_raw.to_i if w_raw.present?
            h = h_raw.to_i if h_raw.present?

            if w.to_i.positive? && h.to_i.positive?
              img = context_send(:resize_to_fill, img, w, h)
            end
          elsif opts[:resize_to_limit].is_a?(Array)
            w_raw, h_raw = opts[:resize_to_limit]
            w = w_raw.to_i if w_raw.present?
            h = h_raw.to_i if h_raw.present?

            if w.to_i.positive? && h.to_i.positive?
              img = context_send(:preserve_image_result, img) { |image| image.thumbnail_image(w, height: h, size: :down) }
            elsif w.to_i.positive?
              img = context_send(:preserve_image_result, img) { |image| image.thumbnail_image(w, size: :down) }
            elsif h.to_i.positive?
              current_h = img.height.to_f
              ratio = current_h.positive? ? (h.to_f / current_h) : 1.0
              if ratio.positive? && ratio < 1.0
                img = context_send(:preserve_image_result, img) { |image| image.resize(ratio) }
              end
            end
          end

          if opts[:strip]
            %w[exif-data exif-ifd0 exif-ifd1 exif-ifd2 iptc-data xmp-data].each do |field|
              if img.get_fields.include?(field)
                img = context_send(:preserve_image_result, img) { |image| image.remove(field) }
              end
            end
          end

          saver_opts = (opts[:saver] || {}).dup
          q = context_send(:adaptive_quality_for, base_quality: opts[:quality].to_i, image: img, blob: blob)
          raise Compressify::Error, "Image pipeline produced nil image" unless img

          case out_format
          when "jpg", "webp", "avif"
            saver_opts[:Q] ||= q
            saver_opts[:strip] ||= true
          end

          img.write_to_file(outfile.path, **context_send(:symbolize_keys, saver_opts))

          context_send(
            :attach_output!,
            source_blob: blob,
            outfile: outfile,
            filename: "#{blob.filename.base}.#{out_format}",
            content_type: context_send(:content_type_for, out_format),
            fingerprint: fp,
            mode: :image,
            options_snapshot: opts
          )
        end
      end
    rescue => e
      context_send(:log_error, "Image failed attachment_id=#{context_send(:attachment_id_for_log)} error=#{e.class}: #{e.message}")
      raise
    end

    private

    attr_reader :context, :blob

    def context_send(method_name, *args, **kwargs, &block)
      context.send(method_name, *args, **kwargs, &block)
    end
  end
end
