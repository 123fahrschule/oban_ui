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
    Oban.check_queue(oban_name, queue: String.to_existing_atom(queue))
  rescue
    _ -> %{queue: queue, available: false}
  catch
    _, _ -> %{queue: queue, available: false}
  end

  @doc """
  Detail view: combines the row counts from `summaries/1`, the per-node
  breakdown of currently executing jobs (read from `oban_jobs.attempted_by`),
  and basic leader info from `oban_peers`.
  """
  @spec detail(atom(), String.t()) :: map()
  def detail(oban_name, queue) do
    oban_name = Config.oban!(oban_name)

    summary =
      summaries(oban_name)
      |> Enum.find(&(&1.name == queue))
      |> Kernel.||(%{
        name: queue,
        executing: 0,
        available: 0,
        scheduled: 0,
        retryable: 0,
        paused: false,
        limit: nil
      })

    %{
      summary: summary,
      nodes: nodes_for_queue(queue),
      leader: leader_info(oban_name)
    }
  end

  @doc """
  Per-node executing-count for a queue. Oban stores `attempted_by` as a
  text array (e.g. `["my_app@host", "..."]`). We fetch the array column and
  fold in Elixir — the executing set is bounded by the concurrency limit
  per node, so this is small enough to do in-process and avoids a
  Postgres-specific `unnest` join.
  """
  @spec nodes_for_queue(String.t()) :: [%{node: String.t(), executing: non_neg_integer()}]
  def nodes_for_queue(queue) do
    repo = Config.repo()

    repo.all(
      from j in Oban.Job,
        where: j.queue == ^queue and j.state == "executing",
        select: j.attempted_by
    )
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.map(fn {node, count} -> %{node: node, executing: count} end)
    |> Enum.sort_by(& &1.executing, :desc)
  rescue
    _ -> []
  end

  @doc """
  Reads the leader row from `oban_peers` for the given Oban instance.
  Returns `%{leader: node, expires_at: dt, stale: boolean}` or `nil`.
  """
  @spec leader_info(atom()) :: map() | nil
  def leader_info(oban_name) do
    repo = Config.repo()
    name_str = inspect(oban_name)

    row =
      repo.one(
        from p in "oban_peers",
          where: p.name == ^name_str,
          select: %{node: p.node, started_at: p.started_at, expires_at: p.expires_at}
      )

    case row do
      nil ->
        nil

      %{node: node, expires_at: expires_at} = info ->
        stale? = DateTime.compare(expires_at, DateTime.utc_now()) == :lt
        Map.merge(info, %{leader: node, stale: stale?})
    end
  rescue
    _ -> nil
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
