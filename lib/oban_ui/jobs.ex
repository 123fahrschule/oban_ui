defmodule ObanUI.Jobs do
  @moduledoc """
  Job-level operator actions. Wraps the underlying `Oban` functions to
  enforce access checks, emit audit events, and degrade gracefully when an
  instance is unavailable.

  All functions take an `actor` map (`%{access: capabilities, user: user_term}`)
  and refuse to act if the capability is not granted.
  """

  alias ObanUI.{Audit, Config, Resolver}

  @type actor :: %{access: %{Resolver.action() => boolean()}, user: term()}
  @type result :: {:ok, Oban.Job.t() | :ok | non_neg_integer()} | {:error, term()}

  @doc "Cancels a single job."
  @spec cancel(actor(), Oban.Job.t() | integer(), atom()) :: result()
  def cancel(actor, job_or_id, oban_name \\ nil) do
    with :ok <- check(actor, :cancel_jobs),
         oban <- Config.oban!(oban_name),
         {:ok, result} <- safe(fn -> Oban.cancel_job(oban, id_of(job_or_id)) end) do
      audit(actor, :cancel_job, oban, %{job_id: id_of(job_or_id)})
      {:ok, result}
    end
  end

  @doc "Retries a single job (immediately rescheduling it as available)."
  @spec retry(actor(), Oban.Job.t() | integer(), atom()) :: result()
  def retry(actor, job_or_id, oban_name \\ nil) do
    with :ok <- check(actor, :retry_jobs),
         oban <- Config.oban!(oban_name),
         {:ok, result} <- safe(fn -> Oban.retry_job(oban, id_of(job_or_id)) end) do
      audit(actor, :retry_job, oban, %{job_id: id_of(job_or_id)})
      {:ok, result}
    end
  end

  @doc "Deletes a single job."
  @spec delete(actor(), Oban.Job.t() | integer(), atom()) :: result()
  def delete(actor, job_or_id, oban_name \\ nil) do
    with :ok <- check(actor, :delete_jobs),
         oban <- Config.oban!(oban_name),
         {:ok, result} <- safe(fn -> Oban.delete_job(oban, id_of(job_or_id)) end) do
      audit(actor, :delete_job, oban, %{job_id: id_of(job_or_id)})
      {:ok, result}
    end
  end

  defp check(%{access: caps}, action) do
    if Map.get(caps, action, false), do: :ok, else: {:error, :forbidden}
  end

  defp id_of(%Oban.Job{id: id}), do: id
  defp id_of(id) when is_integer(id), do: id

  defp safe(fun) do
    try do
      {:ok, fun.()}
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp audit(%{user: user}, action, oban, extra) do
    Audit.record(action, Map.merge(%{user: user, oban_name: oban}, extra))
  end
end
