defmodule ObanUI.StatsTest do
  use ExUnit.Case, async: false

  alias ObanUI.Stats

  setup do
    Stats.Recorder.ensure_table()
    :ets.delete_all_objects(Stats.table())
    :ok
  end

  test "current_bucket aligns to bucket_seconds" do
    bucket = Stats.current_bucket()
    assert rem(bucket, Stats.bucket_seconds()) == 0
  end

  test "throughput zero-fills empty windows" do
    points = Stats.Store.throughput(:test_oban, 60)
    # 60s / 10s = 6 buckets
    assert length(points) == 6
    assert Enum.all?(points, &(&1.success == 0 and &1.failure == 0))
  end

  test "rows_since returns recorded events" do
    bucket = Stats.current_bucket()
    key = {:test_oban, bucket, "default", "MyWorker", :success}
    :ets.update_counter(Stats.table(), key, [{2, 5}, {3, 1500}], {key, 0, 0})

    rows = Stats.Store.rows_since(:test_oban, 60)
    assert [row] = rows
    assert row.worker == "MyWorker"
    assert row.count == 5
    assert row.total_duration_ms == 1500
  end

  test "success_rate is nil when no rows" do
    assert Stats.Store.success_rate(:test_oban, 60) == nil
  end

  test "success_rate aggregates by outcome" do
    bucket = Stats.current_bucket()

    for {outcome, count} <- [success: 8, failure: 2] do
      key = {:test_oban, bucket, "default", "W", outcome}
      :ets.update_counter(Stats.table(), key, [{2, count}, {3, 0}], {key, 0, 0})
    end

    assert Stats.Store.success_rate(:test_oban, 60) == 0.8
  end

  # Production crash regression: throughput/3 used to call
  # Stats.current_bucket/0 twice — once inside rows_since and once for
  # the zero-filled base map. If the 10s bucket clock ticked between the
  # two reads, a row sitting at the old cutoff was returned but no key
  # existed in base, and Map.update! crashed the LiveView with KeyError.
  # Insert a row exactly one bucket BEFORE the window the function will
  # build and assert it tolerates the off-by-one without crashing.
  test "throughput tolerates a row one bucket older than the requested window" do
    bucket_size = Stats.bucket_seconds()
    older = Stats.current_bucket() - bucket_size * 7

    key = {:test_oban, older, "default", "W", :success}
    :ets.update_counter(Stats.table(), key, [{2, 5}, {3, 0}], {key, 0, 0})

    # Window is 60s = 6 buckets; the inserted row sits at the older edge.
    # Even if a worker tick happens to land exactly between the two
    # current_bucket reads, this must not raise.
    assert points = Stats.Store.throughput(:test_oban, 60)
    assert is_list(points)
    assert length(points) == 6
  end
end
