defmodule ObanUI.Web.JobsLive.FilterParser do
  @moduledoc """
  Pure parsing helpers shared between `ObanUI.Web.JobsLive` (which calls them
  in `handle_params`) and the test suite.

  These functions take raw query-string values — always strings or nils — and
  return the typed shapes that `ObanUI.Queries.Jobs.filter()` expects. Every
  function tolerates anything garbage-in-garbage-out style: an unparseable
  value collapses to `nil` so the surrounding URL parser can simply drop it
  rather than rejecting the whole request.
  """

  alias ObanUI.Queries.Jobs, as: JobsQuery

  @doc "Trims and comma-splits the value. Empty/nil → nil."
  @spec split(String.t() | nil) :: [String.t()] | nil
  def split(nil), do: nil
  def split(""), do: nil

  def split(value) when is_binary(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [] -> nil
      list -> list
    end
  end

  def split(_), do: nil

  @doc "Comma-splits and integer-parses each piece. Drops anything non-integer."
  @spec int_list(String.t() | nil) :: [integer()] | nil
  def int_list(nil), do: nil
  def int_list(""), do: nil

  def int_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn s ->
      case Integer.parse(String.trim(s)) do
        {n, ""} -> [n]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      list -> list
    end
  end

  def int_list(_), do: nil

  @doc """
  Returns the same string when non-empty, `nil` otherwise.

  Mostly a helper that lets the surrounding parser stay linear (no nil-checks
  at the call sites).
  """
  @spec present(String.t() | nil) :: String.t() | nil
  def present(nil), do: nil
  def present(""), do: nil
  def present(value) when is_binary(value), do: value
  def present(_), do: nil

  @doc """
  Parses an ISO-8601 datetime *or* a `datetime-local` value
  (`YYYY-MM-DDTHH:MM`) into a `DateTime` in UTC. Returns `nil` on garbage.
  """
  @spec datetime(String.t() | nil) :: DateTime.t() | nil
  def datetime(nil), do: nil
  def datetime(""), do: nil

  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        dt

      _ ->
        case NaiveDateTime.from_iso8601(value <> ":00") do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> nil
        end
    end
  end

  def datetime(_), do: nil

  @doc """
  Parses a sort directive of the form `field:direction` into a tuple suitable
  for `ObanUI.Queries.Jobs.list/2`. Unknown fields or bogus directions yield
  `nil`, which makes the caller fall back to the per-state default.
  """
  @spec sort(String.t() | nil) :: {atom(), :asc | :desc} | nil
  def sort(nil), do: nil
  def sort(""), do: nil

  def sort(raw) when is_binary(raw) do
    case String.split(raw, ":", parts: 2) do
      [field, dir] ->
        case safe_field_atom(field) do
          nil -> nil
          field_atom -> {field_atom, if(dir == "asc", do: :asc, else: :desc)}
        end

      _ ->
        nil
    end
  end

  def sort(_), do: nil

  @doc """
  Builds a complete filters map from a `Plug.Conn` params map. The shape
  matches what `JobsQuery.list/2` accepts, ready to be assigned directly to
  the LiveView socket.
  """
  @spec build(map()) :: ObanUI.Queries.Jobs.filter()
  def build(params) when is_map(params) do
    %{}
    |> maybe_put(:states, split(params["state"]))
    |> maybe_put(:queues, split(params["queue"]))
    |> maybe_put(:workers, split(params["worker"]))
    |> maybe_put(:tags, split(params["tags"]))
    |> maybe_put(:nodes, split(params["node"]))
    |> maybe_put(:priorities, int_list(params["priority"]))
    |> maybe_put(:search, present(params["q"]))
    |> maybe_put(:inserted_after, datetime(params["from"]))
    |> maybe_put(:inserted_before, datetime(params["to"]))
  end

  # `split/1` and `int_list/1` already collapse empty results to nil so we
  # only ever see nil or a populated value here.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp safe_field_atom(name) do
    Enum.find(JobsQuery.sortable_fields(), &(Atom.to_string(&1) == name))
  end
end
