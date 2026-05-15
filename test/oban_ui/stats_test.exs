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
end
