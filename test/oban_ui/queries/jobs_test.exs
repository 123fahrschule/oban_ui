defmodule ObanUI.Queries.JobsTest do
  use ObanUI.DataCase, async: false

  alias ObanUI.Queries.Jobs, as: JobsQuery

  setup do
    # The Config struct is normally written by ObanUI.Supervisor. Tests don't
    # boot it, so populate persistent_term manually.
    ObanUI.Config.put(
      oban_names: [Oban],
      pubsub: :__test_pubsub__,
      repo: ObanUI.DevApp.Repo,
      stats: [enabled: false]
    )

    :ok
  end

  test "list returns inserted jobs newest-first" do
    j1 = insert!(%{worker: "A"})
    Process.sleep(10)
    j2 = insert!(%{worker: "B"})

    {jobs, _meta} = JobsQuery.list()

    assert [%{id: id_first} | _] = jobs
    # ID-based DESC ordering for inserted_at-default
    assert id_first == j2.id
    assert Enum.find(jobs, &(&1.id == j1.id))
  end

  test "filters by state" do
    insert!(%{state: "available"})
    insert!(%{state: "completed"})

    {jobs, _meta} = JobsQuery.list(%{states: ["available"]})
    assert Enum.all?(jobs, &(&1.state == "available"))
    assert length(jobs) == 1
  end

  test "filters by queue" do
    insert!(%{queue: "mailers"})
    insert!(%{queue: "default"})

    {jobs, _meta} = JobsQuery.list(%{queues: ["mailers"]})
    assert length(jobs) == 1
    assert hd(jobs).queue == "mailers"
  end

  test "count_by_state zero-fills every known state" do
    insert!(%{state: "executing"})

    counts = JobsQuery.count_by_state(%{})

    assert counts["executing"] == 1
    assert counts["available"] == 0
    assert counts["completed"] == 0
  end

  test "pagination yields a cursor" do
    for i <- 1..30 do
      insert!(%{worker: "W", args: %{"n" => i}})
    end

    {jobs, %{next_cursor: cursor}} = JobsQuery.list(%{}, page_size: 10)
    assert length(jobs) == 10
    assert cursor != nil

    {jobs2, _} = JobsQuery.list(%{}, page_size: 10, cursor: cursor)
    assert length(jobs2) == 10
    assert MapSet.disjoint?(MapSet.new(jobs, & &1.id), MapSet.new(jobs2, & &1.id))
  end

  test "search.path-syntax matches JSON arg" do
    insert!(%{worker: "A", args: %{"user_id" => 42}})
    insert!(%{worker: "B", args: %{"user_id" => 99}})

    {jobs, _} = JobsQuery.list(%{search: "args.user_id:42"})
    assert length(jobs) == 1
    assert hd(jobs).args == %{"user_id" => 42}
  end
end
