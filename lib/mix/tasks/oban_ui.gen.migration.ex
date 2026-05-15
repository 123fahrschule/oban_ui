defmodule Mix.Tasks.ObanUi.Gen.Migration do
  @shortdoc "Generate a migration that installs the oban_ui_metrics table"

  @moduledoc """
  Generates an Ecto migration that installs the `oban_ui_metrics` table.

  Used by hosts that enable persistence with
  `{ObanUI, stats: [persist: true], ...}`.

      $ mix oban_ui.gen.migration

      $ mix oban_ui.gen.migration --repo MyApp.Repo

      $ mix oban_ui.gen.migration --prefix audit

  After running, `mix ecto.migrate` will create the table; `mix ecto.rollback`
  will drop it.
  """

  use Mix.Task

  @switches [repo: [:string, :keep], prefix: :string]
  @aliases [r: :repo, p: :prefix]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    repos = parse_repos(opts) || ecto_repos_from_config()

    if repos == [] do
      Mix.raise("""
      No Ecto repos found. Either pass --repo MyApp.Repo or configure
      `config :my_app, ecto_repos: [MyApp.Repo]`.
      """)
    end

    prefix = opts[:prefix] || "public"

    Enum.each(repos, fn repo ->
      Code.ensure_loaded?(repo) or Mix.raise("repo #{inspect(repo)} not loaded")

      path = Path.join(["priv", repo_relpath(repo), "migrations"])
      File.mkdir_p!(path)

      file = Path.join(path, "#{timestamp()}_add_oban_ui_metrics.exs")
      File.write!(file, template(repo, prefix))

      Mix.shell().info([:green, "* creating ", :reset, Path.relative_to_cwd(file)])
    end)
  end

  defp ecto_repos_from_config do
    for app <- Application.loaded_applications() |> Enum.map(&elem(&1, 0)),
        repo <- Application.get_env(app, :ecto_repos, []),
        do: repo
  end

  defp repo_relpath(repo) do
    repo
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp parse_repos(opts) do
    case Keyword.get_values(opts, :repo) do
      [] -> nil
      list -> Enum.map(list, &Module.concat([&1]))
    end
  end

  defp template(repo, prefix) do
    """
    defmodule #{inspect(repo)}.Migrations.AddObanUIMetrics do
      use Ecto.Migration

      def up do
        ObanUI.Migrations.up(prefix: #{inspect(prefix)})
      end

      def down do
        ObanUI.Migrations.down(prefix: #{inspect(prefix)})
      end
    end
    """
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()

    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: Integer.to_string(n)
end
