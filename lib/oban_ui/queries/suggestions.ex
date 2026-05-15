defmodule ObanUI.Queries.Suggestions do
  @moduledoc """
  Autocomplete suggestion helpers for the filter inputs.

  Returns the most frequent values seen in `oban_jobs` for a given column,
  filtered by a case-insensitive prefix. The Postgres planner is happy with
  this against the existing default indexes; for very large tables a partial
  GIN/btree index on the column tightens the latency tail.
  """

  import Ecto.Query

  alias ObanUI.Config

  @limit 20

  @spec workers(String.t() | nil) :: [String.t()]
  def workers(prefix) do
    distinct_prefix_match(:worker, prefix)
  end

  @spec queues(String.t() | nil) :: [String.t()]
  def queues(prefix) do
    distinct_prefix_match(:queue, prefix)
  end

  @doc """
  Tags are stored as a Postgres array — `unnest` and group to surface the
  most-used values matching `prefix`.
  """
  @spec tags(String.t() | nil) :: [String.t()]
  def tags(prefix) do
    repo = Config.repo()
    needle = like_pattern(prefix)

    repo.all(
      from j in Oban.Job,
        cross_join: t in fragment("unnest(?)", j.tags),
        select: %{tag: t, n: count()},
        where: ilike(fragment("?::text", t), ^needle),
        group_by: t,
        order_by: [desc: count(), asc: t],
        limit: ^@limit
    )
    |> Enum.map(& &1.tag)
  rescue
    _ -> []
  end

  @doc """
  All node names that have ever attempted any job, prefix-filtered.

  Oban stores `attempted_by` as a string array, e.g. `["my_app@host", "...]`.
  """
  @spec nodes(String.t() | nil) :: [String.t()]
  def nodes(prefix) do
    repo = Config.repo()
    needle = like_pattern(prefix)

    repo.all(
      from j in Oban.Job,
        cross_join: n in fragment("unnest(?)", j.attempted_by),
        select: %{node: n, c: count()},
        where: not is_nil(j.attempted_by),
        where: ilike(fragment("?::text", n), ^needle),
        group_by: n,
        order_by: [desc: count(), asc: n],
        limit: ^@limit
    )
    |> Enum.map(& &1.node)
  rescue
    _ -> []
  end

  defp distinct_prefix_match(field, prefix) do
    repo = Config.repo()
    needle = like_pattern(prefix)

    repo.all(
      from j in Oban.Job,
        where: ilike(field(j, ^field), ^needle),
        group_by: field(j, ^field),
        select: %{val: field(j, ^field), n: count()},
        order_by: [desc: count()],
        limit: ^@limit
    )
    |> Enum.map(& &1.val)
  rescue
    _ -> []
  end

  defp like_pattern(nil), do: "%"
  defp like_pattern(""), do: "%"

  defp like_pattern(prefix),
    do: prefix |> String.replace(~w(% _), &("\\" <> &1)) |> Kernel.<>("%")
end
