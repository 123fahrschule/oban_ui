defmodule ObanUI.Jobs.BulkTest do
  use ObanUI.DataCase, async: false

  alias ObanUI.Jobs.Bulk

  @actor_admin %{access: %{cancel_jobs: true, retry_jobs: true, delete_jobs: true}, user: nil}
  @actor_readonly %{access: %{cancel_jobs: false, retry_jobs: false, delete_jobs: false}, user: nil}

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

  test "filters round-trip via serialise/deserialise" do
    dt = ~U[2025-01-01 00:00:00Z]
    serialised = %{"states" => ["available"], "inserted_after" => DateTime.to_iso8601(dt)}
    decoded = Bulk.deserialise_filters(serialised)

    assert decoded.states == ["available"]
    assert decoded.inserted_after == dt
  end
end
