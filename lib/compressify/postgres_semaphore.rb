# frozen_string_literal: true

require "digest"

module Compressify
  # PostgreSQL session advisory-lock slots shared by all Rails processes using
  # the same app database. Locks release on connection loss, unlike TTL caches.
  #
  # IMPORTANT: the connection must remain checked out for the entire block.
  class PostgresSemaphore
    def self.with_slot(scope:, limit:, connection:, namespace: "compressify")
      limit = Integer(limit)
      raise ArgumentError, "limit must be positive" unless limit.positive?
      unless connection.adapter_name.to_s.downcase.include?("postgres")
        raise ArgumentError, "PostgresSemaphore requires a PostgreSQL connection"
      end

      limit.times do |slot|
        digest = Digest::SHA256.digest("#{namespace}:#{scope}:#{slot}")
        signed_key = digest.unpack1("q>")
        acquired = connection.select_value("SELECT pg_try_advisory_lock(#{signed_key})")
        next unless acquired == true || acquired.to_s == "t"

        begin
          yield
        ensure
          connection.select_value("SELECT pg_advisory_unlock(#{signed_key})")
        end
        return true
      end
      false
    end
  end
end
