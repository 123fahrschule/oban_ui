defmodule ObanUI.Stats.Recorder do
  @moduledoc """
  Telemetry handler that increments per-bucket counters on every Oban job
  completion or failure.

  Runs as a GenServer so the owned ETS table outlives any individual telemetry
  call. Key layout:

      {oban_name, bucket_unix_seconds, queue, worker, outcome}
      -> {count, total_duration_ms}

  `outcome` is one of `:success | :failure | :discard`. `:failure` covers
  retryable failures; `:discard` covers terminal failures.

  Rows are upserted via `:ets.update_counter/3`, which is atomic and very cheap.
  """

  use GenServer

  alias ObanUI.Stats

  @handler_id "oban_ui_stats_recorder"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    ensure_table()
    attach_telemetry()
    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def ensure_table do
    case :ets.whereis(Stats.table()) do
      :undefined ->
        :ets.new(Stats.table(), [
          :public,
          :named_table,
          :set,
          write_concurrency: true,
          read_concurrency: true,
          decentralized_counters: true
        ])

      _ref ->
        Stats.table()
    end
  end

  defp attach_telemetry do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      [
        [:oban, :job, :stop],
        [:oban, :job, :exception]
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event([:oban, :job, :stop], measurements, metadata, _) do
    record(measurements, metadata, :success)
  end

  def handle_event([:oban, :job, :exception], measurements, metadata, _) do
    outcome = if metadata[:state] == :discard, do: :discard, else: :failure
    record(measurements, metadata, outcome)
  end

  defp record(measurements, %{conf: %{name: oban_name}, job: job}, outcome) do
    bucket = Stats.current_bucket()
    queue = job.queue
    worker = job.worker
    duration_ms = native_to_ms(measurements[:duration] || 0)

    key = {oban_name, bucket, queue, worker, outcome}

    try do
      :ets.update_counter(
        Stats.table(),
        key,
        [
          {2, 1},
          {3, duration_ms}
        ],
        {key, 0, 0}
      )
    catch
      # Table not yet created (e.g. during boot race). Silently drop —
      # losing a couple of events at startup is acceptable.
      :error, :badarg -> :ok
    end

    :ok
  end

  defp record(_measurements, _metadata, _outcome), do: :ok

  defp native_to_ms(0), do: 0

  defp native_to_ms(native) do
    System.convert_time_unit(native, :native, :millisecond)
  end
end
