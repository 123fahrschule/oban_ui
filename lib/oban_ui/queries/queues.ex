defmodule ObanUI.Queries.Queues do
  @moduledoc """
  Aggregates queue-level state from `oban_jobs` and `Oban.config/1`.
  """

  import Ecto.Query

  alias ObanUI.Config

  @type queue_summary :: %{
          name: String.t(),
          executing: non_neg_integer(),
          available: non_neg_integer(),
          scheduled: non_neg_integer(),
          retryable: non_neg_integer(),
          paused: boolean(),
          limit: non_neg_integer() | nil
        }

  @doc """
  Returns a summary for each known queue. Combines:

    * configured queues from `Oban.config/1`
    * queues observed in `oban_jobs`

  This way the UI lists empty-but-configured queues too.
  """
  @spec summaries(atom()) :: [queue_summary()]
  def summaries(oban_name \\ nil) do
    oban_name = Config.oban!(oban_name)
    repo = Config.repo()

    configured = configured_queues(oban_name)

    counts =
      repo.all(
        from j in Oban.Job,
          where: j.state in ~w(available scheduled executing retryable),
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id)}
      )

    counts_map =
      Enum.reduce(counts, %{}, fn {queue, state, count}, acc ->
        Map.update(acc, queue, %{state => count}, fn existing ->
          Map.put(existing, state, count)
        end)
      end)

    observed = Map.keys(counts_map)
    all_names = (Map.keys(configured) ++ observed) |> Enum.uniq() |> Enum.sort()

    Enum.map(all_names, fn name ->
      state_counts = Map.get(counts_map, name, %{})
      conf = Map.get(configured, name, %{})

      %{
        name: name,
        executing: Map.get(state_counts, "executing", 0),
        available: Map.get(state_counts, "available", 0),
        scheduled: Map.get(state_counts, "scheduled", 0),
        retryable: Map.get(state_counts, "retryable", 0),
        paused: Map.get(conf, :paused, false),
        limit: Map.get(conf, :limit)
      }
    end)
  end

  @doc """
  Returns the runtime state for a single queue via `Oban.check_queue/2`,
  falling back to DB-only counts if the queue is not registered.
  """
  @spec check(atom(), String.t()) :: map()
  def check(oban_name, queue) when is_binary(queue) do
    try do
      Oban.check_queue(oban_name, queue: String.to_existing_atom(queue))
    rescue
      _ -> %{queue: queue, available: false}
    catch
      _, _ -> %{queue: queue, available: false}
    end
  end

  defp configured_queues(oban_name) do
    %Oban.Config{queues: queues} = Oban.config(oban_name)

    queues
    |> Enum.map(fn
      {name, opts} when is_atom(name) -> {to_string(name), Map.new(opts)}
      {name, opts} when is_binary(name) -> {name, Map.new(opts)}
    end)
    |> Map.new()
  rescue
    _ -> %{}
  end
end
