defmodule ObanUI.Audit do
  @moduledoc """
  Emits `[:oban_ui, :action]` telemetry events for every operator action.

  Hosts can attach to these for audit logging:

      :telemetry.attach("audit", [:oban_ui, :action], fn _evt, _meas, meta, _ ->
        Logger.info("oban_ui action", meta)
      end, nil)

  Metadata always includes `:action`, `:user`, `:oban_name`. Action-specific
  fields are merged in by callers (e.g. `:job_id`, `:queue`, `:limit`).
  """

  @doc """
  Records an action.

  `action` is an atom like `:cancel_job`, `:bulk_cancel_jobs`, `:pause_queue`.
  """
  @spec record(atom(), map()) :: :ok
  def record(action, metadata \\ %{}) when is_atom(action) and is_map(metadata) do
    :telemetry.execute(
      [:oban_ui, :action],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      Map.put(metadata, :action, action)
    )
  end
end
