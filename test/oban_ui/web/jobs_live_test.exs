defmodule ObanUI.Web.JobsLiveTest do
  use ObanUI.ConnCase, async: false

  setup do
    # Library config; tests don't boot the ObanUI supervisor itself.
    ObanUI.Config.put(
      oban_names: [Oban],
      pubsub: ObanUI.DevApp.PubSub,
      repo: ObanUI.DevApp.Repo,
      stats: [enabled: false]
    )

    # PubSub for the LiveView to subscribe to.
    case Phoenix.PubSub.Supervisor.start_link(name: ObanUI.DevApp.PubSub) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case ObanUI.DevApp.Endpoint.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "renders the jobs page with seeded data", %{conn: conn} do
    j = insert!(%{worker: "Smoke.Worker", state: "executing"})

    conn = Phoenix.ConnTest.build_conn()
    {:ok, _view, html} = live(conn, "/oban/jobs")

    assert html =~ "Smoke.Worker"
    assert html =~ "executing"
    assert html =~ Integer.to_string(j.id)
  end

  test "filter dropdown values are reflected in the URL", %{conn: conn} do
    insert!(%{state: "available"})
    insert!(%{state: "completed"})

    conn = Phoenix.ConnTest.build_conn()
    {:ok, view, _html} = live(conn, "/oban/jobs?state=available")

    assert render(view) =~ ~r/<option[^>]*value="available"[^>]*selected/
  end
end
