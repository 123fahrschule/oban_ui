defmodule ObanUI.Stats.Pruner do
  @moduledoc """
  Periodically removes ETS rows older than the retention window, and — when
  persistence is enabled — also drops rows from `oban_ui_metrics` past a
  longer DB retention window (default 30 days).

  ETS pruning ticks every 30s with a 1h retention. DB pruning ticks every
  10 minutes with a 30-day retention. Both are configurable via the
  `stats:` keyword on the supervisor child spec:

      stats: [
        persist: true,
        db_retention_seconds: 7 * 86_400,
        db_prune_interval: :timer.minutes(15)
      ]
  """

  use GenServer
  require Logger

  alias ObanUI.{Config, Stats}

  @tick_ms 30_000
  @db_tick_ms :timer.minutes(10)
  @db_retention_seconds 30 * 86_400

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, @tick_ms)
    db_interval = Keyword.get(opts, :db_prune_interval, @db_tick_ms)
    db_retention = Keyword.get(opts, :db_retention_seconds, @db_retention_seconds)

    Process.send_after(self(), :prune, interval)
    Process.send_after(self(), :prune_db, db_interval)

    {:ok,
     %{
       interval: interval,
       db_interval: db_interval,
       db_retention: db_retention
     }}
  end

  @impl GenServer
  def handle_info(:prune, state) do
    prune_now()
    Process.send_after(self(), :prune, state.interval)
    {:noreply, state}
  end

  def handle_info(:prune_db, state) do
    if persisted?() do
      case prune_db(state.db_retention) do
        {:ok, n} when n > 0 ->
          Logger.debug("ObanUI.Stats.Pruner removed #{n} rows from oban_ui_metrics")

        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("ObanUI.Stats.Pruner DB prune failed: #{inspect(reason)}")
      end
    end

    Process.send_after(self(), :prune_db, state.db_interval)
    {:noreply, state}
  end

  @doc """
  Runs the ETS prune pass once. Returns the number of rows removed.
  """
  @spec prune_now() :: non_neg_integer()
  def prune_now do
    case :ets.whereis(Stats.table()) do
      :undefined ->
        0

      _ref ->
        cutoff = Stats.current_bucket() - Stats.retention_seconds()

        match_spec = [
          {
            {{:_, :"$1", :_, :_, :_}, :_, :_},
            [{:<, :"$1", cutoff}],
            [true]
          }
        ]

        :ets.select_delete(Stats.table(), match_spec)
    end
  end

  @doc """
  Removes `oban_ui_metrics` rows older than `retention_seconds`. Returns
  `{:ok, deleted_count}` or `{:error, reason}` if persistence isn't
  installed yet.
  """
  @spec prune_db(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune_db(retention_seconds) do
    repo = Config.repo()
    cutoff = Stats.current_bucket() - retention_seconds

    try do
      {n, _} =
        repo.query!("DELETE FROM oban_ui_metrics WHERE bucket < $1", [cutoff])
        |> case do
          %Postgrex.Result{num_rows: n} -> {n, nil}
          other -> {0, other}
        end

      {:ok, n}
    rescue
      error -> {:error, error}
    end
  end

  defp persisted? do
    Map.get(Config.fetch!().stats, :persist, false)
  rescue
    _ -> false
  end
end
