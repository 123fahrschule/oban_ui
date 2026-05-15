defmodule ObanUI.Supervisor do
  @moduledoc """
  Top-level library supervisor.

  Started by the host application as `{ObanUI, opts}`. Owns the stats recorder,
  pruner, and one notifier per configured Oban instance.
  """

  use Supervisor

  alias ObanUI.Config
  alias ObanUI.Notifier
  alias ObanUI.Stats

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = Config.put(opts)

    children =
      stats_children(config) ++ notifier_specs(config)

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  defp stats_children(%Config{stats: %{enabled: true}}) do
    [
      ObanUI.Stats.Recorder,
      {Stats.Pruner, []}
    ]
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
