defmodule ObanUI.Supervisor do
  @moduledoc """
  Top-level library supervisor.

  Started by the host application as `{ObanUI, opts}`. Owns the stats recorder,
  pruner, and one notifier per configured Oban instance.
  """

  use Supervisor
  require Logger

  alias ObanUI.Config
  alias ObanUI.Notifier
  alias ObanUI.Stats

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    config = Config.put(opts)

    warn_if_persistence_misconfigured(config)

    children =
      stats_children(config) ++ notifier_specs(config)

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  # When the host opts into persistence but the oban_ui_metrics table is
  # missing, the persistor's first flush silently no-ops and logs a warning
  # — discoverable, but only after the first 60-second tick. Surface the
  # issue right at boot so it's obvious in the startup log.
  defp warn_if_persistence_misconfigured(%Config{stats: %{persist: true}, repo: repo})
       when repo != nil do
    Task.start(fn ->
      # Defer the check so the Repo has a chance to be running; the supervisor's
      # init blocks the host, we don't want to query inside it.
      Process.sleep(2_000)

      try do
        repo.query!("SELECT 1 FROM oban_ui_metrics LIMIT 0", [])
      rescue
        _ ->
          Logger.warning("""
          ObanUI was started with `stats: [persist: true]` but the
          `oban_ui_metrics` table is missing. Stats will still work in-memory
          but won't survive a BEAM restart.

          To fix:

              mix oban_ui.gen.migration
              mix ecto.migrate
          """)
      end
    end)

    :ok
  end

  defp warn_if_persistence_misconfigured(_config), do: :ok

  defp stats_children(%Config{stats: %{enabled: true} = stats}) do
    base = [
      ObanUI.Stats.Recorder,
      {Stats.Pruner, []}
    ]

    if Map.get(stats, :persist, false), do: base ++ [{Stats.Persistor, []}], else: base
  end

  defp stats_children(_), do: []

  defp notifier_specs(%Config{oban_names: names, pubsub: pubsub}) do
    Enum.map(names, fn oban_name ->
      Supervisor.child_spec(
        {Notifier, [oban_name: oban_name, pubsub: pubsub]},
        id: {Notifier, oban_name}
      )
    end)
  end
end
