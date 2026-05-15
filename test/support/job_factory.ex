defmodule ObanUI.JobFactory do
  @moduledoc """
  Helpers for inserting `Oban.Job` rows directly via Ecto. We bypass `Oban.insert`
  because we want full control over `state` / timestamps for fixture data.
  """

  alias ObanUI.DevApp.Repo

  @defaults %{
    worker: "Test.Worker",
    args: %{},
    queue: "default",
    state: "available",
    priority: 0,
    attempt: 0,
    max_attempts: 3,
    tags: [],
    errors: [],
    meta: %{}
  }

  def build(overrides \\ %{}) do
    now = DateTime.utc_now()

    @defaults
    |> Map.merge(%{inserted_at: now, scheduled_at: now})
    |> Map.merge(overrides)
  end

  def insert!(overrides \\ %{}) do
    attrs = build(overrides)
    {1, [job]} = Repo.insert_all(Oban.Job, [attrs], returning: true)
    job
  end
end
