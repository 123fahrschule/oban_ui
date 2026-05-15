defmodule ObanUI.Jobs.EditTest do
  use ObanUI.DataCase, async: false

  alias ObanUI.Jobs.Edit

  @admin %{access: %{edit_jobs: true}, user: nil}
  @readonly %{access: %{edit_jobs: false}, user: nil}

  setup do
    ObanUI.Config.put(
      oban_names: [Oban],
      pubsub: :__test_pubsub__,
      repo: ObanUI.DevApp.Repo,
      stats: [enabled: false]
    )

    :ok
  end

  test "rejects without capability" do
    job = insert!(%{state: "available"})
    assert {:error, :forbidden} = Edit.update(@readonly, job, %{"priority" => "2"})
  end

  test "rejects non-editable states" do
    job = insert!(%{state: "executing"})
    assert {:error, {:not_editable_state, "executing"}} = Edit.update(@admin, job, %{"priority" => "2"})
  end

  test "updates priority, tags, max_attempts, scheduled_at" do
    job = insert!(%{state: "available", priority: 0, tags: [], max_attempts: 3})
    future = DateTime.utc_now() |> DateTime.add(3600, :second)

    {:ok, updated} =
      Edit.update(@admin, job, %{
        "priority" => "5",
        "tags" => "alpha, beta",
        "max_attempts" => "10",
        "scheduled_at" => DateTime.to_iso8601(future)
      })

    assert updated.priority == 5
    assert updated.tags == ["alpha", "beta"]
    assert updated.max_attempts == 10
    assert DateTime.diff(updated.scheduled_at, future, :second) == 0
  end

  test "validates priority range" do
    job = insert!(%{state: "available"})

    assert {:error, errors} = Edit.update(@admin, job, %{"priority" => "12"})
    assert Keyword.has_key?(errors, :priority)
  end

  test "datetime-local format is parsed (no zone, no seconds)" do
    job = insert!(%{state: "scheduled"})

    {:ok, updated} = Edit.update(@admin, job, %{"scheduled_at" => "2030-01-15T08:30"})

    assert DateTime.truncate(updated.scheduled_at, :second) == ~U[2030-01-15 08:30:00Z]
  end
end
