defmodule ObanUI.Stats.Pruner do
  @moduledoc """
  Periodically removes ETS rows older than the retention window.

  Default tick: every 30 seconds. The default retention is 1 hour
  (`ObanUI.Stats.retention_seconds/0`).
  """

  use GenServer

  alias ObanUI.Stats

  @tick_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @tick_ms)
    Process.send_after(self(), :prune, interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:prune, %{interval: interval} = state) do
    prune_now()
    Process.send_after(self(), :prune, interval)
    {:noreply, state}
  end

  @doc """
  Runs the prune pass once. Returns the number of rows removed.
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
end
