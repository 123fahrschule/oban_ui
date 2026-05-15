defmodule ObanUI.Stats.Store do
  @moduledoc """
  Read-side API for the in-memory stats table populated by
  `ObanUI.Stats.Recorder`.

  All functions are pure ETS reads that aggregate on demand. Buckets are 10s
  wide; queries pick a resolution that fits the requested window.
  """

  alias ObanUI.Stats

  @type outcome :: :success | :failure | :discard
  @type bucket_row :: %{
          bucket: integer(),
          queue: String.t(),
          worker: String.t(),
          outcome: outcome(),
          count: non_neg_integer(),
          total_duration_ms: non_neg_integer()
        }

  @doc """
  Returns all rows for an Oban instance within the last `seconds` seconds.
  """
  @spec rows_since(atom(), pos_integer()) :: [bucket_row()]
  def rows_since(oban_name, seconds) when is_integer(seconds) and seconds > 0 do
    cutoff = Stats.current_bucket() - seconds

    case :ets.whereis(Stats.table()) do
      :undefined ->
        []

      _ ->
        match_spec = [
          {
            {{:"$1", :"$2", :"$3", :"$4", :"$5"}, :"$6", :"$7"},
            [
              {:andalso, {:==, :"$1", oban_name}, {:>=, :"$2", cutoff}}
            ],
            [
              %{
                bucket: :"$2",
                queue: :"$3",
                worker: :"$4",
                outcome: :"$5",
                count: :"$6",
                total_duration_ms: :"$7"
              }
            ]
          }
        ]

        :ets.select(Stats.table(), match_spec)
    end
  end

  @doc """
  Aggregates throughput per bucket over the last `seconds`. Returns a list
  ordered by bucket ascending, with zero-filled gaps so charts can render
  continuously.

  Pass `queue:` to restrict to a single queue.
  """
  @spec throughput(atom(), pos_integer(), keyword()) :: [
          %{
            bucket: integer(),
            success: non_neg_integer(),
            failure: non_neg_integer(),
            discard: non_neg_integer()
          }
        ]
  def throughput(oban_name, seconds, opts \\ []) do
    queue = opts[:queue]

    rows =
      oban_name
      |> rows_since(seconds)
      |> filter_queue(queue)

    bucket_size = Stats.bucket_seconds()
    now = Stats.current_bucket()
    start = now - seconds + bucket_size

    base =
      for b <- start..now//bucket_size, into: %{} do
        {b, %{bucket: b, success: 0, failure: 0, discard: 0}}
      end

    rows
    |> Enum.reduce(base, fn row, acc ->
      Map.update!(acc, row.bucket, fn entry ->
        Map.update!(entry, row.outcome, &(&1 + row.count))
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.bucket)
  end

  defp filter_queue(rows, nil), do: rows
  defp filter_queue(rows, queue), do: Enum.filter(rows, &(&1.queue == queue))

  @doc """
  Computes the rolling success rate over the last `seconds`.
  Returns a value between 0.0 and 1.0, or `nil` if no jobs ran.
  """
  @spec success_rate(atom(), pos_integer()) :: float() | nil
  def success_rate(oban_name, seconds) do
    rows = rows_since(oban_name, seconds)

    totals =
      Enum.reduce(rows, %{success: 0, failure: 0, discard: 0}, fn row, acc ->
        Map.update!(acc, row.outcome, &(&1 + row.count))
      end)

    total = totals.success + totals.failure + totals.discard

    if total == 0, do: nil, else: totals.success / total
  end

  @doc """
  Returns the top `n` workers by total executions in the window.
  """
  @spec top_workers(atom(), pos_integer(), pos_integer()) ::
          [%{worker: String.t(), count: non_neg_integer()}]
  def top_workers(oban_name, seconds, n \\ 10) do
    oban_name
    |> rows_since(seconds)
    |> Enum.group_by(& &1.worker, & &1.count)
    |> Enum.map(fn {worker, counts} -> %{worker: worker, count: Enum.sum(counts)} end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(n)
  end

  @doc """
  Returns the top `n` queues by total executions in the window.
  """
  @spec top_queues(atom(), pos_integer(), pos_integer()) ::
          [%{queue: String.t(), count: non_neg_integer()}]
  def top_queues(oban_name, seconds, n \\ 10) do
    oban_name
    |> rows_since(seconds)
    |> Enum.group_by(& &1.queue, & &1.count)
    |> Enum.map(fn {queue, counts} -> %{queue: queue, count: Enum.sum(counts)} end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(n)
  end
end
