defmodule ObanUI.Diagnostics do
  @moduledoc """
  Read-only live process introspection for executing jobs.

  Walks the Oban supervision tree to find the `Task` PID that's running
  a given job, then collects a small bundle of `Process.info/2` values
  (current stacktrace, memory, message-queue length, status, reductions).

  When a job's `attempted_by` points to a different Erlang node, the
  lookup happens via `:rpc.call/4` so multi-node clusters work too. If
  the node is unreachable or the worker has already finished, the
  function returns `{:ok, %{available: false, reason: …}}` rather than
  raising — the dashboard renders that as "process not found" with an
  explanatory line.

  ## Why this works without Oban Pro

  Oban OSS keeps the running set inside each queue's `Oban.Queue.Producer`
  GenServer in a `running` field shaped like `task_ref => {pid, %Executor{job: …}}`.
  `:sys.get_state/1` is the documented way to read a GenServer's state at
  any point in time. The producer process is registered under
  `{:via, Registry, {Oban.Registry, {oban_name, {:producer, queue_atom}}}}`,
  so we can address it deterministically from the queue + instance name.

  Reading state via `:sys.get_state/1` synchronously blocks the producer
  for the duration of the call — keep this off the hot path. The dashboard
  only invokes it when the user opens a detail drawer for an `executing`
  job, which is the same trigger oban_web uses for the analogous feature.
  """

  require Logger

  @info_keys [
    :status,
    :memory,
    :message_queue_len,
    :reductions,
    :current_stacktrace,
    :current_function
  ]

  @type info :: %{
          available: boolean(),
          node: node() | nil,
          pid: pid() | nil,
          status: atom() | nil,
          memory: non_neg_integer() | nil,
          message_queue_len: non_neg_integer() | nil,
          reductions: non_neg_integer() | nil,
          current_function: tuple() | nil,
          current_stacktrace: list() | nil,
          reason: String.t() | nil
        }

  @doc """
  Returns live diagnostics for an executing job, or an `available: false`
  shape if the process can't be located.
  """
  @spec for_job(atom(), Oban.Job.t()) :: info()
  def for_job(oban_name, %Oban.Job{} = job) do
    cond do
      job.state != "executing" ->
        %{available: false, reason: "Job is not executing (state=#{job.state})."}

      job.queue == nil ->
        %{available: false, reason: "Job has no queue, cannot locate producer."}

      true ->
        target_node = pick_node(job.attempted_by)
        locate(oban_name, job, target_node)
    end
  end

  # ---- internals ----

  defp pick_node([node | _]) when is_binary(node), do: String.to_atom(node)
  defp pick_node(node) when is_binary(node), do: String.to_atom(node)
  defp pick_node(_), do: node()

  defp locate(oban_name, job, target_node) do
    if target_node == node() do
      do_locate(oban_name, job)
    else
      rpc_locate(target_node, oban_name, job)
    end
  end

  defp do_locate(oban_name, job) do
    queue_atom = safe_to_atom(job.queue)
    producer = via(oban_name, {:producer, queue_atom})

    case GenServer.whereis(producer) do
      nil ->
        %{available: false, reason: "Producer for queue #{inspect(queue_atom)} not registered."}

      pid when is_pid(pid) ->
        case find_running_pid(pid, job.id) do
          nil ->
            %{
              available: false,
              reason:
                "No running executor for job #{job.id} on this node — finished or migrated.",
              node: node()
            }

          job_pid ->
            collect_info(job_pid, node())
        end
    end
  rescue
    error ->
      %{available: false, reason: "Lookup failed: #{Exception.message(error)}"}
  end

  defp rpc_locate(target_node, oban_name, job) do
    case :rpc.call(target_node, __MODULE__, :do_locate, [oban_name, job], 5_000) do
      {:badrpc, reason} ->
        %{
          available: false,
          node: target_node,
          reason: "RPC to #{inspect(target_node)} failed: #{inspect(reason)}"
        }

      result when is_map(result) ->
        Map.put_new(result, :node, target_node)
    end
  end

  defp find_running_pid(producer_pid, job_id) do
    state = :sys.get_state(producer_pid, 1_000)

    Enum.find_value(state.running, fn
      {_ref, {pid, %{job: %Oban.Job{id: ^job_id}}}} -> pid
      _ -> nil
    end)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp collect_info(pid, target_node) do
    case Process.info(pid, @info_keys) do
      nil ->
        %{available: false, pid: pid, node: target_node, reason: "Process has exited."}

      info ->
        info
        |> Map.new()
        |> Map.put(:available, true)
        |> Map.put(:pid, pid)
        |> Map.put(:node, target_node)
    end
  end

  defp safe_to_atom(string) when is_binary(string), do: String.to_atom(string)
  defp safe_to_atom(atom) when is_atom(atom), do: atom

  defp via(oban_name, role) do
    {:via, Registry, {Oban.Registry, {oban_name, role}}}
  end
end
