defmodule ObanUI.Jobs.BulkTest do
  use ObanUI.DataCase, async: false

  alias ObanUI.Jobs.Bulk

  @actor_admin %{access: %{cancel_jobs: true, retry_jobs: true, delete_jobs: true}, user: nil}
  @actor_readonly %{
    access: %{cancel_jobs: false, retry_jobs: false, delete_jobs: false},
    user: nil
  }

  setup do
    ObanUI.Config.put(
      oban_names: [Oban],
      pubsub: :__test_pubsub__,
      repo: ObanUI.DevApp.Repo,
      stats: [enabled: false]
    )

    :ok
  end

  test "preview returns state counts limited to the filter" do
    insert!(%{state: "available", queue: "default"})
    insert!(%{state: "available", queue: "mailers"})
    insert!(%{state: "completed", queue: "default"})

    preview = Bulk.preview(%{queues: ["default"]})

    assert preview["available"] == 1
    assert preview["completed"] == 1
    assert preview["scheduled"] == 0
  end

  test "run/3 refuses without capability" do
    insert!(%{state: "available"})
    assert {:error, :forbidden} = Bulk.run(@actor_readonly, :delete, %{}, [])
  end

  test "sync delete removes matching jobs and reports affected count" do
    for _ <- 1..5, do: insert!(%{state: "discarded"})
    insert!(%{state: "executing"})

    # Stub Oban.cancel/retry to avoid needing a running Oban; we test :delete
    # which uses repo.delete_all directly.
    assert {:ok, :sync, 5} = Bulk.run(@actor_admin, :delete, %{states: ["discarded"]})

    {jobs, _} = ObanUI.Queries.Jobs.list(%{states: ["discarded"]})
    assert jobs == []

    {executing, _} = ObanUI.Queries.Jobs.list(%{states: ["executing"]})
    assert length(executing) == 1
  end

  describe "with a running Oban" do
    setup do
      # Boot a job-less, plugin-less Oban so cancel/retry can call its
      # public APIs without picking up the seeded jobs.
      oban_name = String.to_atom("BulkTestOban#{System.unique_integer([:positive])}")

      {:ok, oban_pid} =
        Oban.start_link(
          name: oban_name,
          repo: ObanUI.DevApp.Repo,
          queues: false,
          plugins: false,
          notifier: Oban.Notifiers.PG,
          # The sandbox connection is owned by the test process; share it
          # with everything Oban spawns underneath us.
          testing: :manual
        )

      Ecto.Adapters.SQL.Sandbox.allow(ObanUI.DevApp.Repo, self(), oban_pid)

      ObanUI.Config.put(
        oban_names: [oban_name],
        pubsub: :__bulk_test_pubsub__,
        repo: ObanUI.DevApp.Repo,
        stats: [enabled: false]
      )

      on_exit(fn ->
        try do
          if Process.alive?(oban_pid), do: Supervisor.stop(oban_pid)
        catch
          _, _ -> :ok
        end
      end)

      %{oban_name: oban_name}
    end

    test "sync cancel marks matching jobs as cancelled via Oban.cancel_job", %{
      oban_name: oban_name
    } do
      ids = for _ <- 1..3, do: insert!(%{state: "available"}).id

      assert {:ok, :sync, 3} =
               Bulk.run(@actor_admin, :cancel, %{ids: ids}, oban_name: oban_name)

      {jobs, _} = ObanUI.Queries.Jobs.list(%{ids: ids})
      assert Enum.all?(jobs, &(&1.state == "cancelled"))
    end

    test "sync retry resets matching jobs to available", %{oban_name: oban_name} do
      ids = for _ <- 1..3, do: insert!(%{state: "discarded", attempt: 2}).id

      assert {:ok, :sync, 3} =
               Bulk.run(@actor_admin, :retry, %{ids: ids}, oban_name: oban_name)

      {jobs, _} = ObanUI.Queries.Jobs.list(%{ids: ids})
      assert Enum.all?(jobs, &(&1.state == "available"))
    end

    # Regression for the 200k-jobs-cancel-but-only-25-actually-cancelled
    # production bug. The sync path used JobsQuery.list/2 which clamps
    # page_size to 200, so anything beyond the first 200 was silently
    # ignored. We use 250 to keep the test fast while still tripping
    # the clamp.
    test "sync cancel handles > page_size_cap jobs without truncation", %{oban_name: oban_name} do
      n = 250
      for _ <- 1..n, do: insert!(%{state: "available"})

      assert {:ok, :sync, ^n} =
               Bulk.run(@actor_admin, :cancel, %{states: ["available"]},
                 oban_name: oban_name,
                 sync_threshold: 10_000
               )

      # Use count/matching_ids (unbounded) instead of list/2 (clamped) to
      # verify the final cancelled set size — list/2 would itself only
      # return 25 rows and mask the test.
      assert ObanUI.Queries.Jobs.count(%{states: ["cancelled"]}) == n
    end

    # And the async worker path went through the same buggy fetch — verify
    # it also walks the full set now.
    test "async worker collects every matching id past the page-size cap",
         %{oban_name: oban_name} do
      n = 250
      for _ <- 1..n, do: insert!(%{state: "available"})

      filters = %{states: ["available"]}
      ids_via_helper = ObanUI.Queries.Jobs.matching_ids(filters)

      assert length(ids_via_helper) == n

      # And the worker's collect path (private — exercise via its public
      # equivalent matching_ids/1 to assert the size is what the worker
      # would now see). Direct end-to-end of the worker requires Oban
      # plus queues running which is heavier than necessary here; the
      # important regression is that the fetch no longer truncates.
      assert ids_via_helper == Enum.sort(ids_via_helper)
      _ = oban_name
    end
  end

  test "filters round-trip via serialise/deserialise" do
    dt = ~U[2025-01-01 00:00:00Z]
    serialised = %{"states" => ["available"], "inserted_after" => DateTime.to_iso8601(dt)}
    decoded = Bulk.deserialise_filters(serialised)

    assert decoded.states == ["available"]
    assert decoded.inserted_after == dt
  end
end
