defmodule ObanUI.DevApp.NoopWorker do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl true
  def perform(%Oban.Job{args: %{"sleep" => ms}}) when is_integer(ms) do
    Process.sleep(ms)
    :ok
  end

  def perform(_job), do: :ok
end

defmodule ObanUI.DevApp.FlakyWorker do
  @moduledoc false
  use Oban.Worker, queue: :mailers, max_attempts: 5

  @impl true
  def perform(%Oban.Job{args: %{"fail" => true}}), do: {:error, :boom}
  def perform(_job), do: :ok
end

defmodule ObanUI.DevApp.Seeds do
  @moduledoc false

  alias ObanUI.DevApp.Repo

  def run! do
    count = Repo.aggregate(Oban.Job, :count)

    if count == 0 do
      now = DateTime.utc_now()

      jobs =
        Enum.map(1..40, fn i ->
          {worker, args, state, queue} =
            case rem(i, 5) do
              0 -> {"ObanUI.DevApp.NoopWorker", %{"n" => i}, "completed", "default"}
              1 -> {"ObanUI.DevApp.NoopWorker", %{"n" => i, "sleep" => 50}, "available", "default"}
              2 -> {"ObanUI.DevApp.FlakyWorker", %{"n" => i, "fail" => true}, "retryable", "mailers"}
              3 -> {"ObanUI.DevApp.NoopWorker", %{"n" => i}, "scheduled", "media"}
              4 -> {"ObanUI.DevApp.FlakyWorker", %{"n" => i, "fail" => true}, "discarded", "mailers"}
            end

          inserted = DateTime.add(now, -i, :minute)
          scheduled = if state == "scheduled", do: DateTime.add(now, 10 * i, :second)

          attempted =
            if state in ~w(executing retryable completed discarded),
              do: DateTime.add(now, -i + 1, :minute)

          completed = if state == "completed", do: DateTime.add(now, -i + 1, :minute)
          discarded = if state == "discarded", do: DateTime.add(now, -i + 1, :minute)

          %{
            worker: worker,
            args: args,
            state: state,
            queue: queue,
            priority: rem(i, 4),
            attempt: if(state in ~w(completed discarded retryable), do: 1, else: 0),
            max_attempts: 5,
            tags: ["seed", "demo-#{rem(i, 3)}"],
            errors:
              if state in ~w(retryable discarded) do
                [%{at: DateTime.to_iso8601(attempted || now), attempt: 1, error: "** (RuntimeError) boom"}]
              else
                []
              end,
            meta: %{},
            inserted_at: inserted,
            scheduled_at: scheduled || inserted,
            attempted_at: attempted,
            completed_at: completed,
            discarded_at: discarded
          }
        end)

      Repo.insert_all(Oban.Job, jobs, returning: false)
      IO.puts("  seeded #{length(jobs)} jobs")
    else
      IO.puts("  seeds skipped (#{count} jobs already exist)")
    end
  end
end
