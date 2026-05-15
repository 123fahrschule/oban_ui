defmodule ObanUI.Jobs.Edit do
  @moduledoc """
  Partial in-place edit of a job's safe-to-mutate fields.

  Only jobs in non-terminal, non-executing states are editable:
  `available, scheduled, retryable, cancelled, discarded`. Executing jobs are
  refused outright; completed jobs are read-only too (editing finished work
  is rarely meaningful and almost always a bug).

  Editable fields (gated on the `:edit_jobs` capability):
    * `priority` (0-9)
    * `tags` (list of strings)
    * `scheduled_at` (DateTime)
    * `max_attempts` (positive integer)

  Args and meta are intentionally **not** editable through the UI. Hosts that
  use `:erlang.term_to_binary` to store args would otherwise have to teach the
  UI how to parse user input back to the same binary shape, which gets ugly
  fast. The detail drawer surfaces a tooltip explaining this.
  """

  alias ObanUI.{Audit, Config}

  @editable_states ~w(available scheduled retryable cancelled discarded)
  @editable_fields ~w(priority tags scheduled_at max_attempts)a

  @doc "States this module accepts edits for."
  def editable_states, do: @editable_states

  @doc "Fields that may be passed in the update map."
  def editable_fields, do: @editable_fields

  @doc """
  Updates a job. Returns `{:ok, %Oban.Job{}}` or `{:error, reason}`.
  """
  @spec update(map(), Oban.Job.t() | integer(), map(), atom()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def update(actor, job_or_id, attrs, oban_name \\ nil)

  def update(%{access: caps} = actor, %Oban.Job{} = job, attrs, oban_name) do
    cond do
      not Map.get(caps, :edit_jobs, false) ->
        {:error, :forbidden}

      job.state not in @editable_states ->
        {:error, {:not_editable_state, job.state}}

      true ->
        do_update(actor, job, normalise(attrs), oban_name)
    end
  end

  def update(actor, id, attrs, oban_name) when is_integer(id) do
    repo = Config.repo()

    case repo.get(Oban.Job, id) do
      nil -> {:error, :not_found}
      %Oban.Job{} = job -> update(actor, job, attrs, oban_name)
    end
  end

  defp do_update(actor, job, changes, oban_name) do
    repo = Config.repo()

    changeset =
      job
      |> Ecto.Changeset.cast(changes, @editable_fields)
      |> Ecto.Changeset.validate_inclusion(:priority, 0..9)
      |> Ecto.Changeset.validate_number(:max_attempts, greater_than: 0)
      |> validate_scheduled_at()

    case repo.update(changeset) do
      {:ok, updated} ->
        Audit.record(:edit_job, %{
          user: actor[:user],
          oban_name: Config.oban!(oban_name),
          job_id: updated.id,
          changes: Map.take(changes, Enum.map(@editable_fields, &Atom.to_string/1))
        })

        {:ok, updated}

      {:error, %Ecto.Changeset{errors: errors}} ->
        {:error, errors}
    end
  end

  defp validate_scheduled_at(changeset) do
    case Ecto.Changeset.fetch_change(changeset, :scheduled_at) do
      {:ok, nil} ->
        Ecto.Changeset.add_error(changeset, :scheduled_at, "is required")

      _ ->
        changeset
    end
  end

  # Accept maps with either atom or string keys; coerce comma-separated tags.
  defp normalise(attrs) do
    Enum.reduce(attrs, %{}, fn
      {k, v}, acc when k in [:tags, "tags"] -> Map.put(acc, :tags, parse_tags(v))
      {k, v}, acc when k in [:priority, "priority"] -> Map.put(acc, :priority, to_int(v))
      {k, v}, acc when k in [:max_attempts, "max_attempts"] -> Map.put(acc, :max_attempts, to_int(v))
      {k, v}, acc when k in [:scheduled_at, "scheduled_at"] -> Map.put(acc, :scheduled_at, parse_dt(v))
      _, acc -> acc
    end)
  end

  defp parse_tags(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_tags(""), do: []

  defp parse_tags(binary) when is_binary(binary),
    do: binary |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp parse_tags(_), do: []

  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(_), do: nil

  defp parse_dt(%DateTime{} = dt), do: dt

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} ->
        dt

      _ ->
        # `<input type="datetime-local">` returns `2025-05-15T14:30` (no zone, no seconds).
        case NaiveDateTime.from_iso8601(s <> ":00") do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp parse_dt(_), do: nil
end
