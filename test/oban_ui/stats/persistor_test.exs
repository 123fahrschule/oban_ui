defmodule ObanUI.Stats.PersistorTest do
  use ObanUI.DataCase, async: false

  alias ObanUI.Stats
  alias ObanUI.Stats.Persistor

  setup do
    ObanUI.Config.put(
      oban_names: [Oban],
      pubsub: :__test_pubsub__,
      repo: ObanUI.DevApp.Repo,
      stats: [enabled: false]
    )

    Stats.Recorder.ensure_table()
    :ets.delete_all_objects(Stats.table())

    # Create the metrics table for this test transaction so we can exercise
    # the real INSERT path against a host whose migration isn't installed.
    # warm the module
    Ecto.Migration.SchemaMigration

    ObanUI.DevApp.Repo.query!("""
      CREATE TABLE IF NOT EXISTS oban_ui_metrics (
        oban_name varchar NOT NULL,
        bucket bigint NOT NULL,
        queue varchar NOT NULL,
        worker varchar NOT NULL,
        outcome varchar NOT NULL,
        count bigint NOT NULL DEFAULT 0,
        total_duration_ms bigint NOT NULL DEFAULT 0,
        PRIMARY KEY (oban_name, bucket, queue, worker, outcome)
      )
    """)

    on_exit(fn -> :ok end)
    :ok
  end

  test "flush writes ETS rows to oban_ui_metrics" do
    bucket = Stats.current_bucket()
    key = {:test_oban, bucket, "default", "MyWorker", :success}
    :ets.update_counter(Stats.table(), key, [{2, 7}, {3, 1234}], {key, 0, 0})

    assert {:ok, 1} = Persistor.flush()

    rows =
      ObanUI.DevApp.Repo.query!(
        "SELECT count, total_duration_ms FROM oban_ui_metrics WHERE oban_name = 'test_oban'",
        []
      )

    assert rows.rows == [[7, 1234]]
  end

  test "flush is idempotent for the same (oban,bucket,queue,worker,outcome)" do
    bucket = Stats.current_bucket()
    key = {:test_oban_b, bucket, "media", "X", :failure}
    :ets.update_counter(Stats.table(), key, [{2, 3}, {3, 50}], {key, 0, 0})

    assert {:ok, 1} = Persistor.flush()

    # Bump and re-flush
    :ets.update_counter(Stats.table(), key, [{2, 4}, {3, 100}], {key, 0, 0})
    assert {:ok, 1} = Persistor.flush()

    [[count, dur]] =
      ObanUI.DevApp.Repo.query!(
        "SELECT count, total_duration_ms FROM oban_ui_metrics WHERE oban_name = 'test_oban_b'",
        []
      ).rows

    assert count == 7
    assert dur == 150
  end

  test "hydrate populates ETS from the DB" do
    bucket = Stats.current_bucket() - 60

    ObanUI.DevApp.Repo.query!(
      """
      INSERT INTO oban_ui_metrics (oban_name, bucket, queue, worker, outcome, count, total_duration_ms)
      VALUES ('hydrated_oban', $1, 'default', 'Hy.W', 'success', 11, 500)
      """,
      [bucket]
    )

    :ets.delete_all_objects(Stats.table())
    assert {:ok, 1} = Persistor.hydrate(3600)

    rows = ObanUI.Stats.Store.rows_since(:hydrated_oban, 3600)
    assert [row] = rows
    assert row.count == 11
    assert row.total_duration_ms == 500
  end
end
