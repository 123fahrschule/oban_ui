defmodule ObanUI.Queries.JobsFilterTest do
  use ObanUI.DataCase, async: false

  alias ObanUI.Queries.Jobs, as: JobsQuery

  setup do
    ObanUI.Config.put(
      oban_names: [Oban],
      pubsub: :__test_pubsub__,
      repo: ObanUI.DevApp.Repo,
      stats: [enabled: false]
    )

    :ok
  end

  test "priorities filter" do
    insert!(%{priority: 0})
    insert!(%{priority: 1})
    insert!(%{priority: 9})

    {jobs, _} = JobsQuery.list(%{priorities: [0, 9]})
    assert Enum.map(jobs, & &1.priority) |> Enum.sort() == [0, 9]
  end

  test "tags filter uses array overlap" do
    insert!(%{tags: ["billing", "urgent"]})
    insert!(%{tags: ["billing"]})
    insert!(%{tags: ["other"]})

    {jobs, _} = JobsQuery.list(%{tags: ["urgent"]})
    assert length(jobs) == 1

    {jobs2, _} = JobsQuery.list(%{tags: ["billing"]})
    assert length(jobs2) == 2
  end

  test "time-range filter restricts to a window" do
    old = DateTime.add(DateTime.utc_now(), -3600, :second)
    insert!(%{inserted_at: old})
    insert!(%{inserted_at: DateTime.utc_now()})

    {jobs, _} = JobsQuery.list(%{inserted_after: DateTime.add(DateTime.utc_now(), -60, :second)})
    assert length(jobs) == 1
  end

  test "ids filter selects only those rows" do
    j1 = insert!(%{})
    _j2 = insert!(%{})
    j3 = insert!(%{})

    {jobs, _} = JobsQuery.list(%{ids: [j1.id, j3.id]})
    assert Enum.map(jobs, & &1.id) |> Enum.sort() == Enum.sort([j1.id, j3.id])
  end

  test "custom sort is honoured" do
    insert!(%{worker: "Z.Worker"})
    insert!(%{worker: "A.Worker"})

    {jobs, _} = JobsQuery.list(%{}, sort: {:worker, :asc})
    assert Enum.map(jobs, & &1.worker) |> List.first() == "A.Worker"
  end

  test "default_sort picks attempted_at for executing filter" do
    assert JobsQuery.default_sort(%{states: ["executing"]}) == {:attempted_at, :desc}
    assert JobsQuery.default_sort(%{states: ["scheduled"]}) == {:scheduled_at, :asc}
    assert JobsQuery.default_sort(%{}) == {:inserted_at, :desc}
  end

  test "sortable_fields list includes the columns we render" do
    fields = JobsQuery.sortable_fields()
    assert :id in fields
    assert :worker in fields
    assert :inserted_at in fields
    assert :priority in fields
  end
end
