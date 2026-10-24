# frozen_string_literal: true

require "active_support"
require "active_support/core_ext"
require "active_job"
require "active_storage"
require "image_processing/vips"
require "ruby-vips"

require_relative "compressify/version"
require_relative "compressify/config"
require_relative "compressify/controller"
require_relative "compressify/model"
require_relative "compressify/batch"
require_relative "compressify/statistics"
require_relative "compressify/postgres_semaphore"
require_relative "compressify/job"
require_relative "compressify/purge_original_job"
require_relative "compressify/processor"
require_relative "compressify/image_processor"
require_relative "compressify/video_processor"
require_relative "compressify/railtie" if defined?(Rails::Railtie)

module Compressify
  class Error < StandardError; end

  def self.configure
    yield(config)
  end

  def self.config
    @config ||= Compressify::Config.new
  end

  def self.queue_for_attachment(attachment)
    blob = attachment&.blob
    return config.queue_name unless blob

    if image_blob?(blob)
      config.image_queue_name || config.queue_name
    elsif video_blob?(blob)
      config.video_queue_name || config.queue_name
    else
      config.queue_name
    end
  rescue StandardError
    config.queue_name
  end

  def self.image_blob?(blob)
    return true if blob.content_type.to_s.start_with?("image/")

    image_extensions.include?(blob.filename.extension_without_delimiter.to_s.downcase)
  rescue StandardError
    false
  end

  def self.video_blob?(blob)
    return true if blob.content_type.to_s.start_with?("video/")

    video_extensions.include?(blob.filename.extension_without_delimiter.to_s.downcase)
  rescue StandardError
    false
  end

  def self.image_extensions
    %w[jpg jpeg png webp avif gif bmp tif tiff heic heif]
  end

  def self.video_extensions
    %w[mp4 mov mkv webm avi m4v]
  end
end
