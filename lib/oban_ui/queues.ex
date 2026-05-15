defmodule ObanUI.Queues do
  @moduledoc """
  Operator actions for queues. Wraps `Oban.pause_queue/2`, `Oban.resume_queue/2`,
  `Oban.scale_queue/2`. All functions check access and emit audit events.
  """

  alias ObanUI.{Audit, Config, Resolver}

  @type actor :: %{access: %{Resolver.action() => boolean()}, user: term()}

  @doc "Pauses a queue."
  @spec pause(actor(), String.t(), keyword()) :: :ok | {:error, term()}
  def pause(actor, queue, opts \\ []) do
    with :ok <- check(actor, :pause_queues),
         oban <- Config.oban!(opts[:oban_name]),
         queue_atom <- to_atom(queue),
         {:ok, result} <- safe(fn -> Oban.pause_queue(oban, [queue: queue_atom] ++ scope(opts)) end) do
      audit(actor, :pause_queue, oban, %{queue: queue, local_only: opts[:local_only] || false})
      result
    end
  end

  @doc "Resumes a queue."
  @spec resume(actor(), String.t(), keyword()) :: :ok | {:error, term()}
  def resume(actor, queue, opts \\ []) do
    with :ok <- check(actor, :pause_queues),
         oban <- Config.oban!(opts[:oban_name]),
         queue_atom <- to_atom(queue),
         {:ok, result} <- safe(fn -> Oban.resume_queue(oban, [queue: queue_atom] ++ scope(opts)) end) do
      audit(actor, :resume_queue, oban, %{queue: queue, local_only: opts[:local_only] || false})
      result
    end
  end

  @doc "Scales a queue's concurrency limit."
  @spec scale(actor(), String.t(), pos_integer(), keyword()) :: :ok | {:error, term()}
  def scale(actor, queue, limit, opts \\ []) when is_integer(limit) and limit > 0 do
    with :ok <- check(actor, :scale_queues),
         oban <- Config.oban!(opts[:oban_name]),
         queue_atom <- to_atom(queue),
         {:ok, result} <-
           safe(fn ->
             Oban.scale_queue(oban, [queue: queue_atom, limit: limit] ++ scope(opts))
           end) do
      audit(actor, :scale_queue, oban, %{queue: queue, limit: limit})
      result
    end
  end

  defp check(%{access: caps}, action) do
    if Map.get(caps, action, false), do: :ok, else: {:error, :forbidden}
  end

  defp to_atom(queue) when is_atom(queue), do: queue
  defp to_atom(queue) when is_binary(queue), do: String.to_atom(queue)

  defp scope(opts), do: if(opts[:local_only], do: [local_only: true], else: [])

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
