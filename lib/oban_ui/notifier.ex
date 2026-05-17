defmodule ObanUI.Notifier do
  @moduledoc """
  Bridges `Oban.Notifier` events into `Phoenix.PubSub` topics consumed by
  LiveViews.

  One `ObanUI.Notifier` runs per configured Oban instance. It listens for
  `:insert`, `:leader`, and `:signal` channels, coalesces bursts inside a small
  flush window (default 100ms), and broadcasts tick messages so LiveViews can
  refresh themselves on their own schedule.

  ## Topics

    * `"oban_ui:overview:<instance>"` — aggregate tick for dashboards
    * `"oban_ui:queues:<instance>"` — queue list view
    * `"oban_ui:queue:<instance>:<queue>"` — per-queue detail
    * `"oban_ui:jobs:<instance>"` — jobs list view
    * `"oban_ui:job:<instance>:<id>"` — individual job detail

  Messages are intentionally lean (no payloads beyond instance/queue/state)
  because consumers re-query for fresh data anyway. This keeps the broadcast
  cost flat regardless of insert rate.
  """

  use GenServer
  require Logger

  @flush_interval_ms 100

  @type instance :: atom()
  @type queue :: String.t()

  defmodule State do
    @moduledoc false
    defstruct [:oban_name, :pubsub, :flush_interval, buffer: %{}, queues: MapSet.new()]
  end

  @doc """
  Builds the topic name for a given subject.

  ## Examples

      iex> ObanUI.Notifier.topic({:jobs, :default_oban})
      "oban_ui:jobs:default_oban"

      iex> ObanUI.Notifier.topic({:queue, :default_oban, "media"})
      "oban_ui:queue:default_oban:media"
  """
  @spec topic({atom(), instance()} | {atom(), instance(), term()}) :: String.t()
  def topic({:overview, oban}), do: "oban_ui:overview:#{oban}"
  def topic({:queues, oban}), do: "oban_ui:queues:#{oban}"
  def topic({:jobs, oban}), do: "oban_ui:jobs:#{oban}"
  def topic({:queue, oban, queue}), do: "oban_ui:queue:#{oban}:#{queue}"
  def topic({:job, oban, id}), do: "oban_ui:job:#{oban}:#{id}"

  def start_link(opts) do
    oban_name = Keyword.fetch!(opts, :oban_name)
    GenServer.start_link(__MODULE__, opts, name: name_for(oban_name))
  end

  @doc "Process name for the notifier of a given Oban instance."
  @spec name_for(instance()) :: atom()
  def name_for(oban_name), do: Module.concat([__MODULE__, oban_name])

  @doc """
  Forces an immediate flush. Mostly for tests and manual diagnostics.
  """
  @spec flush(instance()) :: :ok
  def flush(oban_name), do: GenServer.cast(name_for(oban_name), :flush)

  @impl GenServer
  def init(opts) do
    oban_name = Keyword.fetch!(opts, :oban_name)
    pubsub = Keyword.fetch!(opts, :pubsub)
    interval = Keyword.get(opts, :flush_interval, @flush_interval_ms)

    # Subscribe to Oban's internal notifier channels. We tolerate failures so
    # that an Oban instance which hasn't booted yet doesn't prevent the
    # notifier from starting — Oban will deliver events once available.
    safe_listen(oban_name)

    schedule_flush(interval)

    {:ok,
     %State{
       oban_name: oban_name,
       pubsub: pubsub,
       flush_interval: interval
     }}
  end

  @impl GenServer
  def handle_info({:notification, channel, payload}, state) do
    {:noreply, ingest(state, channel, payload)}
  end

  # Oban.Notifier delivers events as `{:notification, channel, payload}` since
  # 2.17. Older releases used a different shape; we ignore unknown messages.
  def handle_info(:flush, state) do
    state = do_flush(state)
    schedule_flush(state.flush_interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast(:flush, state), do: {:noreply, do_flush(state)}

  defp ingest(state, :insert, %{"queue" => queue}) when is_binary(queue) do
    state
    |> Map.update!(:queues, &MapSet.put(&1, queue))
    |> Map.update!(:buffer, fn buf -> Map.update(buf, :inserts, 1, &(&1 + 1)) end)
  end

  defp ingest(state, :leader, _payload) do
    Phoenix.PubSub.broadcast(state.pubsub, topic({:overview, state.oban_name}), :leader_changed)
    state
  end

  defp ingest(state, :signal, %{"action" => action} = payload)
       when action in ~w(pkill scale resume pause) do
    queue = payload["queue"]
    state = if queue, do: Map.update!(state, :queues, &MapSet.put(&1, queue)), else: state
    Map.update!(state, :buffer, fn buf -> Map.update(buf, :signals, 1, &(&1 + 1)) end)
  end

  defp ingest(state, _channel, _payload), do: state

  defp do_flush(%State{buffer: buffer} = state) when map_size(buffer) == 0 do
    state
  end

  defp do_flush(%State{} = state) do
    %{oban_name: oban, pubsub: pubsub, buffer: buffer, queues: queues} = state

    # Aggregate tick — DashboardLive + JobsLive react to this.
    Phoenix.PubSub.broadcast(pubsub, topic({:overview, oban}), {:tick, buffer})
    Phoenix.PubSub.broadcast(pubsub, topic({:jobs, oban}), {:tick, buffer})
    Phoenix.PubSub.broadcast(pubsub, topic({:queues, oban}), {:tick, buffer})

    Enum.each(queues, fn queue ->
      Phoenix.PubSub.broadcast(pubsub, topic({:queue, oban, queue}), :tick)
    end)

    %{state | buffer: %{}, queues: MapSet.new()}
  end

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)

  defp safe_listen(oban_name) do
    Oban.Notifier.listen(oban_name, [:insert, :leader, :signal])
  catch
    kind, reason ->
      Logger.warning(
        "ObanUI.Notifier could not subscribe to Oban #{inspect(oban_name)}: " <>
          Exception.format(kind, reason)
      )

      :ok
  end
end
