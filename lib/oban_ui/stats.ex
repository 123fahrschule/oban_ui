defmodule ObanUI.Stats do
  @moduledoc """
  Lightweight in-memory time-series for Oban activity.

  Aggregates `[:oban, :job, :stop]` and `[:oban, :job, :exception]` telemetry
  events into 10-second buckets keyed by `{queue, worker, outcome}`. Buckets
  older than the retention window (default 1 hour) are pruned periodically.

  Designed to be cheap: every event is a single `:ets.update_counter/3` call.

  ## Outcome tags

  Each event is tagged with one of `:success`, `:failure`, or `:discard` to
  drive success-rate charts. `:failure` covers retryable failures;
  `:discard` covers terminally failed jobs.
  """

  @table __MODULE__
  @bucket_seconds 10
  @retention_seconds 3600

  @doc false
  def table, do: @table
  @doc false
  def bucket_seconds, do: @bucket_seconds
  @doc false
  def retention_seconds, do: @retention_seconds

  @doc """
  Returns the bucket key (unix seconds, floored) for a given timestamp.
  """
  @spec bucket_for(integer()) :: integer()
  def bucket_for(unix_seconds) when is_integer(unix_seconds),
    do: unix_seconds - rem(unix_seconds, @bucket_seconds)

  @doc """
  Convenience: current bucket using `System.system_time/1`.
  """
  @spec current_bucket() :: integer()
  def current_bucket, do: bucket_for(System.system_time(:second))
end
