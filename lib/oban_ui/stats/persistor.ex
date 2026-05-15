defmodule ObanUI.Stats.Persistor do
  @moduledoc """
  Periodically flushes the in-memory `ObanUI.Stats` ETS table to the
  `oban_ui_metrics` Postgres table.

  Started by `ObanUI.Supervisor` only when the host opts in via
  `stats: [persist: true]`. Without the migration the table doesn't exist
  and writes raise — the GenServer logs and degrades to a no-op on the
  next interval rather than crashing the supervisor.

  The persistor also hydrates the ETS table at boot from the DB so the
  dashboard has historical data immediately after a BEAM restart.

  Write strategy: `INSERT … ON CONFLICT DO UPDATE` on the
  `(oban_name, bucket, queue, worker, outcome)` unique index so the
  same bucket can be re-flushed harmlessly if it stays "hot" across two
  ticks.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias ObanUI.{Config, Stats}

  @tick_ms 60_000
  @hydrate_seconds 7 * 24 * 3600

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Force a flush. Used by tests."
  def flush_now, do: GenServer.call(__MODULE__, :flush_now, 30_000)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @tick_ms)
    Process.send_after(self(), :hydrate, 0)
    Process.send_after(self(), :flush, interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:hydrate, state) do
    case hydrate() do
      {:ok, count} -> Logger.info("ObanUI.Stats hydrated #{count} buckets from oban_ui_metrics")
      {:error, reason} -> Logger.warning("ObanUI.Stats hydrate skipped: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(:flush, %{interval: interval} = state) do
    case flush() do
      {:ok, _n} -> :ok
      {:error, reason} -> Logger.warning("ObanUI.Stats flush failed: #{inspect(reason)}")
    end

    Process.send_after(self(), :flush, interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush_now, _from, state) do
    result = flush()
    {:reply, result, state}
  end

  # ---------------- write ----------------

  @doc "Snapshot the current ETS table to the metrics table."
  @spec flush() :: {:ok, non_neg_integer()} | {:error, term()}
  def flush do
    case :ets.whereis(Stats.table()) do
      :undefined ->
        {:ok, 0}

      _ref ->
        rows =
          Stats.table()
          |> :ets.tab2list()
          |> Enum.map(fn {{oban, bucket, queue, worker, outcome}, count, total} ->
            %{
              oban_name: Atom.to_string(oban),
              bucket: bucket,
              queue: queue || "",
              worker: worker || "",
              outcome: Atom.to_string(outcome),
              count: count,
              total_duration_ms: total
            }
          end)

        do_insert(rows)
    end
  end

  defp do_insert([]), do: {:ok, 0}

  defp do_insert(rows) do
    repo = Config.repo()

    # Chunk to keep the parameter count under Postgres' 65535 limit
    # (7 columns × 9000 ≈ 63000).
    rows
    |> Enum.chunk_every(2_000)
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, acc} ->
      try do
        {n, _} =
          repo.insert_all("oban_ui_metrics", chunk,
            on_conflict:
              {:replace, [:count, :total_duration_ms]},
            conflict_target: [:oban_name, :bucket, :queue, :worker, :outcome]
          )

        {:cont, {:ok, acc + n}}
      rescue
        error -> {:halt, {:error, error}}
      end
    end)
  end

  # ---------------- hydrate ----------------

  @doc """
  Loads the last `seconds` of buckets from the DB into the ETS table so a
  fresh BEAM has populated stats from the start.
  """
  @spec hydrate(pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def hydrate(seconds \\ @hydrate_seconds) do
    repo =
      try do
        Config.repo()
      rescue
        _ -> nil
      end

    case repo do
      nil ->
        {:error, :no_repo}

      _ ->
        cutoff = Stats.current_bucket() - seconds

        try do
          rows =
            repo.all(
              from m in "oban_ui_metrics",
                where: m.bucket >= ^cutoff,
                select: %{
                  oban_name: m.oban_name,
                  bucket: m.bucket,
                  queue: m.queue,
                  worker: m.worker,
                  outcome: m.outcome,
                  count: m.count,
                  total_duration_ms: m.total_duration_ms
                }
            )

          ensure_table()

          Enum.each(rows, fn r ->
            key = {
              safe_to_atom(r.oban_name),
              r.bucket,
              r.queue,
              r.worker,
              safe_to_atom(r.outcome)
            }

            :ets.update_counter(
              Stats.table(),
              key,
              [{2, r.count}, {3, r.total_duration_ms}],
              {key, 0, 0}
            )
          end)

          {:ok, length(rows)}
        rescue
          error -> {:error, error}
        end
    end
  end

  defp ensure_table do
    case :ets.whereis(Stats.table()) do
      :undefined -> ObanUI.Stats.Recorder.ensure_table()
      _ -> :ok
    end
  end

  defp safe_to_atom(s) when is_binary(s), do: String.to_atom(s)
  defp safe_to_atom(a) when is_atom(a), do: a
end
