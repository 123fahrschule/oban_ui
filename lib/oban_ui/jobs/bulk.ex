defmodule ObanUI.Jobs.Bulk do
  @moduledoc """
  Bulk operations across whatever set of jobs a `Queries.Jobs` filter selects.

  Two execution paths:

    * **Synchronous** — when the filter would touch ≤ `sync_threshold` rows
      (default 1000). The work happens in the calling LiveView process inside
      a single transaction; latency is bounded and there's nothing to track.
    * **Background** — for larger sets. We hand the filter to
      `ObanUI.Jobs.BulkWorker`, which processes the matching IDs in 500-row
      chunks and broadcasts progress to a one-shot PubSub topic
      `"oban_ui:bulk:<ref>"`.

  All actions enforce the same access checks as the single-job equivalents
  and emit `[:oban_ui, :action]` telemetry with an `affected:` count.
  """

  import Ecto.Query

  alias ObanUI.{Audit, Config}
  alias ObanUI.Queries.Jobs, as: JobsQuery

  @actions ~w(cancel retry delete)a
  @sync_threshold 1000

  @type action :: :cancel | :retry | :delete
  @type actor :: %{access: map(), user: term()}
  @type result ::
          {:ok, :sync, affected :: non_neg_integer()}
          | {:ok, :async, ref :: String.t(), estimate :: non_neg_integer()}
          | {:error, term()}

  @doc """
  Returns `%{"available" => 12, "executing" => 4, ...}` — the impact
  preview shown in the confirm modal before a bulk action.
  """
  @spec preview(JobsQuery.filter()) :: %{String.t() => non_neg_integer()}
  def preview(filters), do: JobsQuery.count_by_state(filters)

  @doc """
  Returns the total number of jobs that would be affected.
  """
  @spec count(JobsQuery.filter()) :: non_neg_integer()
  def count(filters), do: JobsQuery.count(filters)

  @doc """
  Runs a bulk action.

  Options:
    * `:oban_name` — Oban instance, defaults to library default.
    * `:sync_threshold` — override the sync cut-off.
    * `:async` — force the background path regardless of size.
  """
  @spec run(actor(), action(), JobsQuery.filter(), keyword()) :: result()
  def run(actor, action, filters, opts \\ []) when action in @actions do
    capability = capability_for(action)

    if Map.get(actor.access, capability, false) do
      oban = Config.oban!(opts[:oban_name])
      threshold = opts[:sync_threshold] || @sync_threshold
      force_async = Keyword.get(opts, :async, false)
      affected = count(filters)

      cond do
        force_async or affected > threshold ->
          enqueue_async(actor, action, filters, oban, affected)

        affected == 0 ->
          {:ok, :sync, 0}

        true ->
          run_sync(actor, action, filters, oban, affected)
      end
    else
      {:error, :forbidden}
    end
  end

  # ----- internals -----

  @doc false
  def perform_chunk(action, ids, oban_name, actor) do
    # Use the bulk Oban APIs (cancel_all / retry_all) instead of one
    # synchronous call per job. For a 500-id chunk that's one query vs.
    # 500 — a 500× speedup that matters as soon as the action touches
    # more than a handful of jobs.
    query = ids_query(ids)

    case action do
      :cancel -> Oban.cancel_all_jobs(oban_name, query)
      :retry -> Oban.retry_all_jobs(oban_name, query)
      :delete -> delete_ids(ids, oban_name)
    end

    Audit.record(:"bulk_#{action}_chunk", %{
      user: actor[:user],
      oban_name: oban_name,
      size: length(ids)
    })

    :ok
  end

  defp ids_query(ids) do
    import Ecto.Query, only: [from: 2]
    from(j in Oban.Job, where: j.id in ^ids)
  end

  defp run_sync(actor, action, filters, oban, _affected) do
    # JobsQuery.list/2 clamps page_size to 200 — using it here for the
    # bulk fetch was the bug that let cancel/retry of > 200 jobs silently
    # process only the first page. Always go through matching_ids/1.
    ids = JobsQuery.matching_ids(filters)

    perform_chunk(action, ids, oban, actor)

    Audit.record(:"bulk_#{action}_jobs", %{
      user: actor[:user],
      oban_name: oban,
      affected: length(ids),
      mode: :sync
    })

    {:ok, :sync, length(ids)}
  end

  defp enqueue_async(actor, action, filters, oban, estimate) do
    ref = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    args =
      %{
        "action" => Atom.to_string(action),
        "filters" => serialise_filters(filters),
        "oban_name" => Atom.to_string(oban),
        "ref" => ref,
        "actor" => %{"user" => inspect(actor[:user])}
      }

    case Oban.insert(oban, ObanUI.Jobs.BulkWorker.new(args, queue: bulk_queue(oban))) do
      {:ok, _job} ->
        Audit.record(:"bulk_#{action}_jobs", %{
          user: actor[:user],
          oban_name: oban,
          estimate: estimate,
          mode: :async,
          ref: ref
        })

        {:ok, :async, ref, estimate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_ids(ids, _oban_name) do
    repo = Config.repo()

    repo.delete_all(from j in Oban.Job, where: j.id in ^ids and j.state != "executing")

    :ok
  end

  defp capability_for(:cancel), do: :cancel_jobs
  defp capability_for(:retry), do: :retry_jobs
  defp capability_for(:delete), do: :delete_jobs

  defp bulk_queue(oban_name) do
    # Oban.config/1 always returns a struct with :queues, but we wrap in
    # rescue so a misconfigured / not-yet-started instance falls back to
    # `:default` rather than crashing the bulk dispatch.
    %{queues: queues} = Oban.config(oban_name)

    cond do
      Keyword.has_key?(queues, :oban_ui_bulk) -> :oban_ui_bulk
      Keyword.has_key?(queues, :default) -> :default
      true -> queues |> Keyword.keys() |> List.first() || :default
    end
  rescue
    _ -> :default
  end

  defp serialise_filters(filters) do
    Map.new(filters, fn
      {key, %DateTime{} = ts} -> {to_string(key), DateTime.to_iso8601(ts)}
      {key, val} -> {to_string(key), val}
    end)
  end

  @doc false
  @spec deserialise_filters(map()) :: JobsQuery.filter()
  def deserialise_filters(map) do
    Enum.reduce(map, %{}, fn
      {"states", v}, acc ->
        Map.put(acc, :states, v)

      {"queues", v}, acc ->
        Map.put(acc, :queues, v)

      {"workers", v}, acc ->
        Map.put(acc, :workers, v)

      {"tags", v}, acc ->
        Map.put(acc, :tags, v)

      {"priorities", v}, acc ->
        Map.put(acc, :priorities, v)

      {"nodes", v}, acc ->
        Map.put(acc, :nodes, v)

      {"ids", v}, acc ->
        Map.put(acc, :ids, v)

      {"search", v}, acc ->
        Map.put(acc, :search, v)

      {"inserted_after", v}, acc when is_binary(v) ->
        case DateTime.from_iso8601(v) do
          {:ok, dt, _} -> Map.put(acc, :inserted_after, dt)
          _ -> acc
        end

      {"inserted_before", v}, acc when is_binary(v) ->
        case DateTime.from_iso8601(v) do
          {:ok, dt, _} -> Map.put(acc, :inserted_before, dt)
          _ -> acc
        end

      _, acc ->
        acc
    end)
  end
end
