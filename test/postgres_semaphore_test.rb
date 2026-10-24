# frozen_string_literal: true

require "test_helper"

class PostgresSemaphoreTest < Minitest::Test
  class FakeConnection
    attr_reader :queries
    attr_accessor :lock_responses

    def initialize(lock_responses = [true])
      @queries = []
      @lock_responses = lock_responses.dup
    end

    def adapter_name = "PostgreSQL"

    def select_value(sql)
      @queries << sql
      if sql.include?("pg_try_advisory_lock")
        @lock_responses.shift || false
      else
        true
      end
    end
  end

  def test_one_slot_is_acquired_and_released
    connection = FakeConnection.new([true])
    called = false

    result = Compressify::PostgresSemaphore.with_slot(
      scope: "image", limit: 2, connection: connection
    ) { called = true }

    assert_equal true, result
    assert called
    assert_equal 2, connection.queries.count
    assert_match(/pg_try_advisory_lock/, connection.queries.first)
    assert_match(/pg_advisory_unlock/, connection.queries.last)
    assert_equal extract_key(connection.queries.first), extract_key(connection.queries.last)
  end

  def test_busy_slots_do_not_execute_work
    connection = FakeConnection.new([false, false])
    executed = false
    result = Compressify::PostgresSemaphore.with_slot(
      scope: "video", limit: 2, connection: connection
    ) { executed = true }

    assert_equal false, result
    refute executed
    assert_equal 2, connection.queries.size
    refute connection.queries.any? { |q| q.include?("unlock") }
  end

  def test_an_exception_releases_the_shared_lock
    connection = FakeConnection.new([true])
    assert_raises(RuntimeError) do
      Compressify::PostgresSemaphore.with_slot(
        scope: "image", limit: 1, connection: connection
      ) { raise "encoder failed" }
    end
    assert_match(/pg_advisory_unlock/, connection.queries.last)
  end

  def test_different_slot_namespaces_have_different_keys
    first = FakeConnection.new
    second = FakeConnection.new

    Compressify::PostgresSemaphore.with_slot(scope: "video", limit: 1, connection: first, namespace: "app1") {}
    Compressify::PostgresSemaphore.with_slot(scope: "video", limit: 1, connection: second, namespace: "app2") {}

    refute_equal extract_key(first.queries.first), extract_key(second.queries.first)
  end

  private

  def extract_key(query)
    query[/\((-?\d+)\)/, 1]
  end
end
