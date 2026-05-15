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

  test "typing in the worker combobox populates suggestions and applies the filter", %{conn: conn} do
    insert!(%{worker: "MyApp.Workers.FlakyWorker", state: "available"})
    insert!(%{worker: "MyApp.Workers.NoopWorker", state: "available"})

    {:ok, view, _} = live(conn, "/oban/jobs")

    # The form's phx-change fires with the full form payload + a _target
    # path identifying which input changed. The combobox itself just sets
    # the value; the form aggregates it.
    render_change(view, "filter", %{
      "_target" => ["worker"],
      "worker" => "Flaky",
      "queue" => "",
      "tags" => "",
      "node" => "",
      "priority" => "",
      "q" => "",
      "from" => "",
      "to" => ""
    })

    html = render(view)

    # 1. The URL gets the worker filter (URI.encode_query preserves dots, only special chars are encoded)
    assert_patched(view, "/oban/jobs?worker=Flaky")

    # 2. The result set is restricted to FlakyWorker (NoopWorker gone)
    assert html =~ "FlakyWorker"
    refute html =~ "NoopWorker"

    # 3. A suggestion dropdown appears with the full module name
    assert html =~ "MyApp.Workers.FlakyWorker"
    assert html =~ ~r/role="listbox"/
  end

  test "clearing a worker value via filter drops it from the URL", %{conn: conn} do
    insert!(%{worker: "X.Worker", state: "available"})

    # Start with a worker filter in the URL.
    {:ok, view, _} = live(conn, "/oban/jobs?worker=Flaky")

    # User clears the input and the form change fires with worker="".
    render_change(view, "filter", %{
      "_target" => ["worker"],
      "worker" => "",
      "queue" => "",
      "tags" => "",
      "node" => "",
      "priority" => "",
      "q" => "",
      "from" => "",
      "to" => ""
    })

    # The patched URL no longer carries `worker`.
    assert_patched(view, "/oban/jobs")
  end

  test "combobox_pick replaces the worker value and closes the dropdown", %{conn: conn} do
    insert!(%{worker: "Acme.Workers.FlakyWorker", state: "available"})

    {:ok, view, _} = live(conn, "/oban/jobs")

    # Pre-seed a suggestion list by firing a filter change first.
    render_change(view, "filter", %{
      "_target" => ["worker"],
      "worker" => "Flaky",
      "queue" => "",
      "tags" => "",
      "node" => "",
      "priority" => "",
      "q" => "",
      "from" => "",
      "to" => ""
    })

    # Click a suggestion.
    render_click(view, "combobox_pick", %{
      "field" => "worker",
      "value" => "Acme.Workers.FlakyWorker"
    })

    # URL now uses the full module name. URI.encode_query escapes dots as
    # %2E, so we check by inspecting the patched URL via push_patch_to.
    assert_patched(view, "/oban/jobs?worker=" <> URI.encode_www_form("Acme.Workers.FlakyWorker"))

    # Dropdown is gone.
    html = render(view)
    refute html =~ ~r/role="listbox"/
  end

  test "state-tab toggle is preserved across form changes", %{conn: conn} do
    insert!(%{state: "discarded", worker: "X.Worker"})
    insert!(%{state: "completed", worker: "X.Worker"})

    {:ok, view, _} = live(conn, "/oban/jobs?state=discarded")

    # Fire a form change with no worker value — the state filter must survive.
    render_change(view, "filter", %{
      "_target" => ["worker"],
      "worker" => "",
      "queue" => "",
      "tags" => "",
      "node" => "",
      "priority" => "",
      "q" => "",
      "from" => "",
      "to" => ""
    })

    assert_patched(view, "/oban/jobs?state=discarded")
  end
end
