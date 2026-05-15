defmodule ObanUI.Queries.Crons do
  @moduledoc """
  Reads the static cron config from `Oban.Plugins.Cron` and pairs each entry
  with its most recent execution from `oban_jobs`.

  Dynamic crons (`Oban.Pro.Plugins.DynamicCron`) are not supported — they
  require Oban Pro. Static crons defined in the host's Oban config are fully
  surfaced.
  """

  import Ecto.Query

  alias ObanUI.Config

  @type cron :: %{
          expression: String.t(),
          worker: String.t(),
          args: term(),
          last_run_at: DateTime.t() | nil,
          next_run_at: DateTime.t() | nil
        }

  @spec list(atom()) :: [cron()]
  def list(oban_name \\ nil) do
    oban_name = Config.oban!(oban_name)
    entries = extract_cron_entries(oban_name)

    if entries == [] do
      []
    else
      workers = Enum.map(entries, & &1.worker) |> Enum.uniq()
      last_runs = last_runs_for(workers)

      Enum.map(entries, fn entry ->
        Map.put(entry, :last_run_at, Map.get(last_runs, entry.worker))
      end)
    end
  end

  defp extract_cron_entries(oban_name) do
    %Oban.Config{plugins: plugins} = Oban.config(oban_name)

    plugins
    |> Enum.flat_map(fn
      {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
      Oban.Plugins.Cron -> []
      _other -> []
    end)
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  defp parse_entry({expression, worker}) when is_binary(expression) and is_atom(worker) do
    %{expression: expression, worker: inspect(worker), args: %{}, next_run_at: nil}
  end

  defp parse_entry({expression, worker, opts}) when is_binary(expression) and is_atom(worker) do
    %{
      expression: expression,
      worker: inspect(worker),
      args: Keyword.get(opts, :args, %{}),
      next_run_at: nil
    }
  end

  defp parse_entry(_), do: nil

  defp last_runs_for(workers) do
    repo = Config.repo()

    rows =
      repo.all(
        from j in Oban.Job,
          where: j.worker in ^workers,
          where: not is_nil(j.attempted_at),
          group_by: j.worker,
          select: {j.worker, max(j.attempted_at)}
      )

    Map.new(rows)
  rescue
    _ -> %{}
  end
end
