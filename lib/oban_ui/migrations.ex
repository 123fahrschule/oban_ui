defmodule ObanUI.Migrations do
  @moduledoc """
  Ecto migration helpers for the optional `oban_ui_metrics` table used by
  `ObanUI.Stats.Persistor`.

  Hosts that want stats to survive a BEAM restart (or to keep more history
  than the in-memory 1-hour ETS window) install the migration with
  `mix oban_ui.gen.migration` and enable persistence via:

      {ObanUI, oban_names: [Oban], pubsub: MyApp.PubSub, stats: [persist: true]}

  The table is intentionally minimal: one row per
  `(oban_name, bucket, queue, worker, outcome)` aggregated by the persistor
  every 60 seconds. Pruning is the host's responsibility for now —
  `ObanUI.Stats.Pruner` only manages the ETS half.
  """

  use Ecto.Migration

  @doc """
  Idempotent `up` for the metrics table. Safe to call from
  `mix oban_ui.gen.migration` output.

  Options:
    * `:prefix` — schema prefix, default `"public"`
  """
  def up(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")

    create_if_not_exists table(:oban_ui_metrics, prefix: prefix, primary_key: false) do
      add :oban_name, :string, null: false
      add :bucket, :bigint, null: false
      add :queue, :string, null: false
      add :worker, :string, null: false
      add :outcome, :string, null: false
      add :count, :bigint, null: false, default: 0
      add :total_duration_ms, :bigint, null: false, default: 0
    end

    create_if_not_exists unique_index(
                           :oban_ui_metrics,
                           [:oban_name, :bucket, :queue, :worker, :outcome],
                           name: :oban_ui_metrics_unique_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:oban_ui_metrics, [:bucket], prefix: prefix)
  end

  def down(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")
    drop_if_exists index(:oban_ui_metrics, [:bucket], prefix: prefix)
    drop_if_exists table(:oban_ui_metrics, prefix: prefix)
  end
end
