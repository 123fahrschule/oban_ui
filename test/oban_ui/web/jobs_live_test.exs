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

    {:ok, _view, html} = live(conn, "/oban/jobs")

    assert html =~ "Smoke.Worker"
    assert html =~ "executing"
    assert html =~ Integer.to_string(j.id)
  end

  test "state filter is reflected in the URL and highlights the active tab", %{conn: conn} do
    insert!(%{state: "available"})
    insert!(%{state: "completed"})

    {:ok, view, _html} = live(conn, "/oban/jobs?state=available")

    html = render(view)
    # Active state-tab has the ring style and the matching phx-value-state.
    assert html =~ ~r/phx-value-state="available"[^>]*ring-2 ring-oban-500/
  end

  test "empty state appears when no jobs match", %{conn: conn} do
    # No insert!s — table is empty after sandbox setup
    {:ok, _view, html} = live(conn, "/oban/jobs?state=cancelled")

    assert html =~ "No jobs match"
    refute html =~ ~r/<table[^>]*aria-label="Jobs"/
  end

  test "clearing filters via the empty-state link strips the query", %{conn: conn} do
    insert!(%{state: "available"})

    {:ok, view, _} = live(conn, "/oban/jobs?state=cancelled")
    assert render(view) =~ "No jobs match"

    # Simulate the filter-clear button surfaced in the empty state.
    render_click(view, "clear_filters", %{})
    assert_patched(view, "/oban/jobs")
    refute render(view) =~ "No jobs match"
  end
end
