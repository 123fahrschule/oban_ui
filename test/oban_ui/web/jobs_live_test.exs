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

    # Click the rendered suggestion element. `element/2` extracts the
    # phx-click handler and phx-value-* attrs from the actual DOM, which is
    # what catches the JS-side "phx-value-value gets clobbered by el.value"
    # bug — a hand-crafted payload via render_click/3 wouldn't.
    view
    |> element(~s|li[phx-value-pick="Acme.Workers.FlakyWorker"]|)
    |> render_click()

    # URL now uses the full module name (URI.encode_www_form escapes dots).
    assert_patched(view, "/oban/jobs?worker=" <> URI.encode_www_form("Acme.Workers.FlakyWorker"))

    # Dropdown is gone.
    html = render(view)
    refute html =~ ~r/role="listbox"/
  end

  test "select-all toggles all visible rows on, then off", %{conn: conn} do
    for n <- 1..3, do: insert!(%{worker: "W#{n}", state: "available"})

    {:ok, view, _} = live(conn, "/oban/jobs")

    # Initially nothing selected; checkbox state is :none
    html = render(view)
    assert html =~ ~r/data-state="none"/

    # Click toggles all visible jobs into the selection.
    view |> element("#oban-ui-select-all") |> render_click()
    html_after = render(view)
    assert html_after =~ ~r/data-state="all"/

    # A second click clears them again.
    view |> element("#oban-ui-select-all") |> render_click()
    html_final = render(view)
    assert html_final =~ ~r/data-state="none"/
  end

  test "load_more appends a second page and pauses live refresh", %{conn: conn} do
    # 30 rows so page 1 has 25, page 2 has 5
    for n <- 1..30, do: insert!(%{worker: "W#{n}", state: "available"})

    {:ok, view, _} = live(conn, "/oban/jobs")
    html = render(view)
    rows_p1 = Regex.scan(~r/id="jobs-\d+"/, html) |> length()
    assert rows_p1 == 25

    # Load-more button is present because there's a next cursor.
    assert html =~ "Load more"

    view |> element("button", "Load more") |> render_click()
    html_after = render(view)
    rows_p2 = Regex.scan(~r/id="jobs-\d+"/, html_after) |> length()
    assert rows_p2 == 30

    # After load-more there is no further cursor, so the button is gone.
    refute html_after =~ "Load more"

    # And the page now shows the "live refresh paused" notice.
    assert html_after =~ "Live refresh paused"
  end

  test "match count above the table reflects the filter", %{conn: conn} do
    for _ <- 1..3, do: insert!(%{state: "available"})
    insert!(%{state: "completed"})

    {:ok, view, _} = live(conn, "/oban/jobs?state=available")
    html = render(view)

    assert html =~ ~r/<strong>3<\/strong>\s*matching job/
  end

  test "row actions render as a kebab menu, not three inline buttons", %{conn: conn} do
    job = insert!(%{worker: "Kebab.Worker", state: "available"})

    {:ok, _view, html} = live(conn, "/oban/jobs")

    # One kebab trigger + dropdown per row, scoped by job id.
    assert html =~ ~s(id="actions-#{job.id}")
    assert html =~ "oban-ui-kebab-trigger"
    # Menu still offers all three actions.
    assert html =~ "Retry"
    assert html =~ "Cancel"
    assert html =~ "Delete"
    # The old space-separated three-button layout is gone.
    refute html =~ "text-right space-x-1"
  end

  test "kebab menu_item dispatches its phx-click to the server", %{conn: conn} do
    insert!(%{worker: "Kebab.Worker", state: "discarded"})

    {:ok, view, _} = live(conn, "/oban/jobs?state=discarded")

    # The menu_item is a normal phx-click button. Clicking it must reach the
    # "delete" handler exactly as the old inline button did. There's no Oban
    # running in the sandbox, so the action errors — but the resulting flash
    # proves the event was dispatched (the wiring works). render_click also
    # bypasses the JS data-confirm.
    html = view |> element(~s(button[phx-click="delete"]), "Delete") |> render_click()
    assert html =~ "Failed" or html =~ "Not permitted"
  end

  test "custom resolver's format_job_args strips keys from list + drawer", %{conn: conn} do
    insert!(%{
      worker: "Stripped.Worker",
      state: "available",
      args: %{
        "__original_args" => "g2wAAAAC-base64-blob",
        "student_id" => "abc-123",
        "metadata" => %{"causation_id" => "x"}
      }
    })

    {:ok, _view, html} = live(conn, "/oban-resolver/jobs")

    # List preview column: encoded blob is gone, real keys remain.
    refute html =~ "__original_args"
    refute html =~ "g2wAAAAC-base64-blob"
    assert html =~ "student_id"

    # Detail drawer: same — open it and re-check.
    job_id =
      html
      |> then(&Regex.run(~r/jobs-(\d+)/, &1))
      |> List.last()

    {:ok, _drawer, drawer_html} = live(conn, "/oban-resolver/jobs/#{job_id}")
    refute drawer_html =~ "__original_args"
    assert drawer_html =~ "student_id"
  end

  test "default resolver leaves args untouched (the wiring control)", %{conn: conn} do
    insert!(%{worker: "Raw.Worker", state: "available", args: %{"__original_args" => "blob"}})

    {:ok, _view, html} = live(conn, "/oban/jobs")

    # /oban mounts WITHOUT a custom resolver → raw args, including the key.
    assert html =~ "__original_args"
  end

  test "scheduled jobs surface their future run time in the list", %{conn: conn} do
    future = DateTime.add(DateTime.utc_now(), 20 * 60, :second)
    insert!(%{worker: "Future.Worker", state: "scheduled", scheduled_at: future})

    {:ok, _view, html} = live(conn, "/oban/jobs?state=scheduled")

    # The State cell appends a relative "runs in Xm" hint (no dedicated column).
    assert html =~ "runs"
    assert html =~ ~r/in \d+m/
  end

  test "scheduled job detail drawer shows the absolute run time", %{conn: conn} do
    future = DateTime.add(DateTime.utc_now(), 20 * 60, :second)
    job = insert!(%{worker: "Future.Worker", state: "scheduled", scheduled_at: future})

    {:ok, _view, html} = live(conn, "/oban/jobs/#{job.id}")

    assert html =~ "Runs"
    # Absolute UTC stamp, e.g. "2026-05-27 19:17:21 UTC".
    assert html =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC/
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
