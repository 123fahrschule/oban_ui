defmodule ObanUI.Web.DashboardLiveTest do
  use ObanUI.ConnCase, async: false

  alias ObanUI.Stats

  setup do
    ObanUI.Config.put(
      oban_names: [Oban],
      pubsub: ObanUI.DevApp.PubSub,
      repo: ObanUI.DevApp.Repo,
      stats: [enabled: false]
    )

    case Phoenix.PubSub.Supervisor.start_link(name: ObanUI.DevApp.PubSub) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case ObanUI.DevApp.Endpoint.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Stats.Recorder.ensure_table()
    :ets.delete_all_objects(Stats.table())
    :ok
  end

  defp record(worker, queue, count) do
    bucket = Stats.current_bucket()
    key = {Oban, bucket, queue, worker, :success}
    :ets.update_counter(Stats.table(), key, [{2, count}, {3, 0}], {key, 0, 0})
  end

  test "state count cards deep-link to the jobs list filtered by state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/oban/")

    for state <- ~w(available executing scheduled retryable completed cancelled discarded) do
      assert html =~ "/oban/jobs?state=#{state}"
    end
  end

  test "top workers link to the jobs list filtered by worker", %{conn: conn} do
    record("MyApp.Workers.Sync", "default", 12)

    {:ok, _view, html} = live(conn, "/oban/")

    assert html =~ "MyApp.Workers.Sync"
    assert html =~ "/oban/jobs?worker=MyApp.Workers.Sync"
  end

  test "top queues link to the jobs list filtered by queue", %{conn: conn} do
    record("W", "mailers", 7)

    {:ok, _view, html} = live(conn, "/oban/")

    assert html =~ "/oban/jobs?queue=mailers"
  end
end
