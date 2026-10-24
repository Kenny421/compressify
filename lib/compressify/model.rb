# frozen_string_literal: true

module Compressify
  # Include this in your model to get `auto_compress` sugar.
  #
  # Example:
  #   class Photo < ApplicationRecord
  #     has_one_attached :image
  #
  #     include Compressify::Model
  #     auto_compress :image, format: :webp, quality: 80, size: "600x600!"
  #   end
  #
  # If you pass attach_to, we keep the original and write compressed output to that attachment.
  # If you don't pass attach_to, we replace the original (and purge the old blob by default).
  module Model
    extend ActiveSupport::Concern

    class_methods do
      # Adds callbacks that enqueue compression when the attachment changes.
      #
      # Options:
      # - attach_to: nil / Symbol / Hash (same as controller helper)
      # - only: :create / :update / [:create, :update] (default: [:create, :update])
      # - if: ->(record) { ... } condition (optional)
      # - unless: ->(record) { ... } condition (optional)
      #
      # Plus all compression options (format/quality/resize_to_limit/video/etc)
      #
      def auto_compress(attachment_name, only: [:create, :update], **options, &block)
        attachment_name = attachment_name.to_sym
        dynamic_opts = block

        # Mark attachment changes during the save transaction so we only enqueue real work.
        after_save do
          begin
            if respond_to?(:attachment_changes) && attachment_changes.is_a?(Hash) && attachment_changes.key?(attachment_name.to_s)
              compressify_mark_attachment_touched!(attachment_name)
            end
          rescue StandardError
            # Don't crash the save because we couldn't be fancy.
          end
        end

        # Wait until commit so Active Storage has finished its paperwork.
        after_commit(on: Array(only)) do
          next unless Compressify.config.enabled

          if_condition = options[:if]
          unless_condition = options[:unless]

          next if if_condition && !if_condition.call(self)
          next if unless_condition && unless_condition.call(self)

          attached = public_send(attachment_name)
          next unless attached.respond_to?(:attached?) && attached.attached?

          # Ignore ordinary record updates. Nobody wants image recompression because a title changed.
          next unless compressify_attachment_touched?(attachment_name)

          opts = options.except(:if, :unless).deep_dup
          opts = compressify_normalize_options(opts)

          if dynamic_opts
            dyn = dynamic_opts.call(self)
            opts = opts.deep_merge(dyn.deep_symbolize_keys) if dyn.is_a?(Hash)
          end

          attachments = Compressify::Processor.normalize_attachments(attached)

          attachments.each do |attachment|
            Compressify::Job.set(queue: Compressify.queue_for_attachment(attachment)).perform_later(
              attachment_id: attachment.id,
              blob_id: attachment.blob_id,
              options: opts
            )
          end

          # Clear the marker before the next save gets any funny ideas.
          compressify_clear_attachment_touch!(attachment_name)
        end
      end
    end

    private

    # Turn friendly options into processor options.
    # Humans like "1200x1200"; Ruby prefers something it can chew without drama.
    def compressify_normalize_options(opts)
      return {} unless opts.is_a?(Hash)

      if opts.key?(:size) || opts.key?("size")
        size_val = opts.delete(:size) || opts.delete("size")
        w, h, force = compressify_parse_size(size_val)

        if force && w && h
          # "600x600!" means force exact dimensions (center-crop to fit).
          opts[:resize_to_fill] ||= [w, h]
        else
          # Only set resize_to_limit if user didn't already set it explicitly.
          opts[:resize_to_limit] ||= ([w, h] if w || h)
        end
      end

      opts
    end

    def compressify_parse_size(val)
      case val
      when Array
        w, h = val
        [w.presence&.to_i, h.presence&.to_i, false]
      when String
        raw = val.downcase.strip
        force = raw.end_with?("!")
        raw = raw.delete_suffix("!") if force
        parts = raw.split("x", 2)
        if parts.length == 2
          w = parts[0].present? ? parts[0].to_i : nil
          h = parts[1].present? ? parts[1].to_i : nil
          [w, h, force]
        else
          [raw.to_i, nil, force]
        end
      when Integer
        [val.to_i, val.to_i, false]
      else
        [nil, nil, false]
      end
    end

    # Reliable marker: we set this during after_save if attachment_changes included the attachment.
    def compressify_mark_attachment_touched!(name)
      @_compressify_touched ||= {}
      @_compressify_touched[name.to_sym] = true
    end

    def compressify_attachment_touched?(name)
      sym = name.to_sym

      # Preferred: did we mark it during after_save?
      return true if @_compressify_touched && @_compressify_touched[sym]

      # Important loop guard:
      # only enqueue when this save transaction explicitly marked the attachment as changed.
      # Otherwise the background job can chase its own tail, which is cute in dogs and bad in jobs.
      false
    rescue StandardError
      false
    end

    def compressify_clear_attachment_touch!(name)
      return unless defined?(@_compressify_touched) && @_compressify_touched.is_a?(Hash)
      @_compressify_touched.delete(name.to_sym)
    end
  end
end
