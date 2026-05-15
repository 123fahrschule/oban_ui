defmodule ObanUI.Queries.Jobs do
  @moduledoc """
  Ecto queries over `oban_jobs`.

  Centralises every filter the UI understands and exposes cursor-pagination
  helpers. Designed for read-heavy use: every helper returns plain `%Oban.Job{}`
  structs (or counts) — no host-specific decoding here. Display formatting is
  delegated to the resolver downstream.
  """

  import Ecto.Query

  alias ObanUI.Config

  @type state ::
          :available
          | :scheduled
          | :executing
          | :retryable
          | :completed
          | :cancelled
          | :discarded

  @type filter :: %{
          optional(:states) => [String.t()] | nil,
          optional(:queues) => [String.t()] | nil,
          optional(:workers) => [String.t()] | nil,
          optional(:tags) => [String.t()] | nil,
          optional(:priorities) => [non_neg_integer()] | nil,
          optional(:nodes) => [String.t()] | nil,
          optional(:search) => String.t() | nil,
          optional(:inserted_after) => DateTime.t() | nil,
          optional(:inserted_before) => DateTime.t() | nil,
          optional(:ids) => [integer()] | nil
        }

  @sortable_fields ~w(id worker queue state priority inserted_at scheduled_at attempted_at completed_at)a
  @type sort :: {atom(), :asc | :desc}

  @doc "Returns the list of fields that may be passed in a sort directive."
  @spec sortable_fields() :: [atom()]
  def sortable_fields, do: @sortable_fields

  @default_page_size 25
  @max_page_size 200

  @doc """
  Returns a paginated list of jobs matching `filters`.

  Returns `{[%Oban.Job{}, ...], %{next_cursor: cursor | nil, prev_cursor: cursor | nil}}`.
  """
  @spec list(filter(), keyword()) :: {[Oban.Job.t()], %{next_cursor: term(), prev_cursor: term()}}
  def list(filters \\ %{}, opts \\ []) do
    repo = Config.repo()
    page_size = clamp_page_size(opts[:page_size] || @default_page_size)
    sort = opts[:sort] || default_sort(filters)
    cursor = opts[:cursor]

    base =
      base_query()
      |> apply_filters(filters)
      |> order_by_sort(sort)
      |> apply_cursor(cursor, sort)
      |> limit(^(page_size + 1))

    results = repo.all(base)
    {jobs, next_cursor} = take_with_cursor(results, page_size, sort)

    {jobs, %{next_cursor: next_cursor, prev_cursor: opts[:prev_cursor]}}
  end

  @doc """
  Counts jobs grouped by state, restricted to the given filters.

  Returns a map like `%{"available" => 12, "executing" => 3, ...}` with every
  state present (zero-filled).
  """
  @spec count_by_state(filter()) :: %{String.t() => non_neg_integer()}
  def count_by_state(filters \\ %{}) do
    repo = Config.repo()
    # Strip state filter so counts reflect "what's available regardless".
    filters = Map.delete(filters, :states)

    rows =
      base_query()
      |> apply_filters(filters)
      |> group_by([j], j.state)
      |> select([j], {j.state, count(j.id)})
      |> repo.all()

    rows_map = Map.new(rows)

    Enum.into(states(), %{}, fn state ->
      {state, Map.get(rows_map, state, 0)}
    end)
  end

  @doc """
  Total count for filters. Use sparingly on large tables — Postgres `count(*)`
  is not free.
  """
  @spec count(filter()) :: non_neg_integer()
  def count(filters \\ %{}) do
    repo = Config.repo()

    base_query()
    |> apply_filters(filters)
    |> select([j], count(j.id))
    |> repo.one()
  end

  @doc """
  Fetches a single job by ID, or returns `nil`.
  """
  @spec get(integer()) :: Oban.Job.t() | nil
  def get(id) when is_integer(id) do
    Config.repo().get(Oban.Job, id)
  end

  @doc """
  Returns the distinct list of queue names currently present in the DB.
  Useful for filter dropdowns.
  """
  @spec distinct_queues() :: [String.t()]
  def distinct_queues do
    Config.repo().all(from j in Oban.Job, distinct: true, select: j.queue, order_by: j.queue)
  end

  @doc """
  Returns the top `n` workers by job count.
  """
  @spec top_workers(pos_integer()) :: [{String.t(), non_neg_integer()}]
  def top_workers(n \\ 20) do
    Config.repo().all(
      from j in Oban.Job,
        group_by: j.worker,
        select: {j.worker, count(j.id)},
        order_by: [desc: count(j.id)],
        limit: ^n
    )
  end

  @doc """
  All valid state strings.
  """
  @spec states() :: [String.t()]
  def states,
    do: ~w(available scheduled executing retryable completed cancelled discarded)

  # ---- internals ----

  defp base_query, do: from(j in Oban.Job)

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, &apply_filter/2)
  end

  defp apply_filter({:states, [_ | _] = states}, q),
    do: from(j in q, where: j.state in ^states)

  defp apply_filter({:queues, [_ | _] = queues}, q),
    do: from(j in q, where: j.queue in ^queues)

  defp apply_filter({:workers, [_ | _] = workers}, q),
    do: from(j in q, where: j.worker in ^workers)

  defp apply_filter({:tags, [_ | _] = tags}, q),
    do: from(j in q, where: fragment("? && ?", j.tags, ^tags))

  defp apply_filter({:priorities, [_ | _] = ps}, q),
    do: from(j in q, where: j.priority in ^ps)

  defp apply_filter({:nodes, [_ | _] = nodes}, q),
    do: from(j in q, where: fragment("? && ?", j.attempted_by, ^nodes))

  defp apply_filter({:ids, [_ | _] = ids}, q),
    do: from(j in q, where: j.id in ^ids)

  defp apply_filter({:inserted_after, %DateTime{} = ts}, q),
    do: from(j in q, where: j.inserted_at >= ^ts)

  defp apply_filter({:inserted_before, %DateTime{} = ts}, q),
    do: from(j in q, where: j.inserted_at < ^ts)

  defp apply_filter({:search, term}, q) when is_binary(term) and term != "" do
    # Try a few cheap heuristics:
    # - "args.path:value" => exact JSONB path match
    # - bare token        => OR over worker name and a JSONB existence check
    case parse_search(term) do
      {:path, path, value} ->
        from(j in q, where: fragment("?->>? = ?", j.args, ^path, ^value))

      {:free, token} ->
        like = "%" <> escape_like(token) <> "%"

        from(j in q,
          where:
            ilike(j.worker, ^like) or
              fragment("?::text ILIKE ?", j.args, ^like)
        )
    end
  end

  defp apply_filter(_unsupported, q), do: q

  defp parse_search(term) do
    case String.split(term, ":", parts: 2) do
      ["args." <> path, value] -> {:path, String.trim(path), String.trim(value)}
      [_] -> {:free, term}
      _ -> {:free, term}
    end
  end

  defp escape_like(s),
    do: String.replace(s, ~w(% _), fn ch -> "\\" <> ch end)

  @doc """
  Picks a sensible default sort based on the active state filter.
  """
  @spec default_sort(filter()) :: sort()
  def default_sort(filters) do
    cond do
      "executing" in (filters[:states] || []) -> {:attempted_at, :desc}
      "scheduled" in (filters[:states] || []) -> {:scheduled_at, :asc}
      true -> {:inserted_at, :desc}
    end
  end

  defp order_by_sort(query, {field, dir}) do
    # Always tie-break on id desc for stable cursor pagination.
    from(j in query, order_by: [{^dir, field(j, ^field)}, {:desc, j.id}])
  end

  defp apply_cursor(query, nil, _sort), do: query

  defp apply_cursor(query, {value, id}, {field, :desc}) do
    if value do
      from(j in query,
        where:
          field(j, ^field) < ^value or
            (field(j, ^field) == ^value and j.id < ^id)
      )
    else
      from(j in query, where: j.id < ^id)
    end
  end

  defp apply_cursor(query, {value, id}, {field, :asc}) do
    if value do
      from(j in query,
        where:
          field(j, ^field) > ^value or
            (field(j, ^field) == ^value and j.id < ^id)
      )
    else
      from(j in query, where: j.id < ^id)
    end
  end

  defp clamp_page_size(n) when is_integer(n) and n > 0 and n <= @max_page_size, do: n
  defp clamp_page_size(_), do: @default_page_size

  defp take_with_cursor(results, page_size, {field, _dir}) do
    case Enum.split(results, page_size) do
      {jobs, []} ->
        {jobs, nil}

      {jobs, _overflow} ->
        last = List.last(jobs)
        {jobs, {Map.get(last, field), last.id}}
    end
  end
end
