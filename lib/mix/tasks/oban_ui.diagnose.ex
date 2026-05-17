defmodule Mix.Tasks.ObanUi.Diagnose do
  @shortdoc "Verifies an ObanUI installation against the running system"

  @moduledoc """
  Runs a series of checks against the host application to surface common
  integration problems before they show up as a blank dashboard or a stuck
  page.

      $ mix oban_ui.diagnose

  Boots `:oban_ui` and any apps it depends on, then verifies — in order:

    * `ObanUI.Config` was populated (i.e. `{ObanUI, opts}` is actually in a
      supervision tree),
    * the configured `Phoenix.PubSub` server is reachable,
    * each Oban instance named in `:oban_names` is registered and currently
      running,
    * `Oban.Notifier.listen/2` works (i.e. `LISTEN`/`NOTIFY` is wired up),
    * the `oban_jobs` table is present and readable,
    * when `stats: [persist: true]`, the `oban_ui_metrics` migration ran,
    * the pre-built CSS and JS bundles ship inside `priv/static`.

  Each line prints `[ok]` / `[warn]` / `[fail]`. The task exits with a
  non-zero status if any check fails, which makes it usable in a release
  pipeline as a smoke test.
  """

  use Mix.Task

  alias ObanUI.Config
  alias ObanUI.Plug.Assets
  alias ObanUI.Stats

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [app: :string])

    # Boot whichever app the host pointed at — defaults to the calling Mix
    # project's app, so `mix oban_ui.diagnose` from inside a Phoenix app
    # "just works" with the standard `mod: {App.Application, _}` callback.
    app =
      case opts[:app] do
        nil -> Keyword.get(Mix.Project.config(), :app, :oban_ui)
        name -> String.to_atom(name)
      end

    Mix.Task.run("app.start")

    case Application.ensure_all_started(app) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Mix.shell().info([
          :yellow,
          "Could not start application #{inspect(app)}: #{inspect(reason)}\n",
          :reset
        ])
    end

    case audit(io: Mix.shell()) do
      :ok -> :ok
      :error -> System.halt(1)
    end
  end

  @doc """
  Runs every check, prints the lines, and returns `:ok` or `:error`.

  Public so tests can call it without invoking `System.halt/1`. The `io`
  option lets tests inject a captured shell.
  """
  @spec audit(keyword()) :: :ok | :error
  def audit(opts \\ []) do
    io = Keyword.get(opts, :io, Mix.shell())

    io.info(IO.ANSI.bright() <> "ObanUI installation diagnose\n" <> IO.ANSI.reset())

    results = [
      check_config(io),
      check_pubsub(io),
      check_oban_instances(io),
      check_notifier(io),
      check_oban_jobs_table(io),
      check_metrics_table(io),
      check_assets(io)
    ]

    failed = Enum.count(results, &match?({:fail, _, _}, &1))
    warned = Enum.count(results, &match?({:warn, _, _}, &1))
    okayed = Enum.count(results, &match?({:ok, _, _}, &1))

    io.info("\n#{okayed} ok, #{warned} warning(s), #{failed} failure(s).\n")

    if failed > 0, do: :error, else: :ok
  end

  # --- individual checks ---

  defp check_config(io) do
    case fetch_config() do
      {:ok, %Config{} = config} ->
        ok(
          io,
          "config",
          "ObanUI supervisor running with #{length(config.oban_names)} instance(s)"
        )

      {:error, reason} ->
        fail(io, "config", """
        ObanUI is not started. Add to your application supervision tree:

            {ObanUI, oban_names: [Oban], pubsub: MyApp.PubSub, repo: MyApp.Repo}

        Underlying error: #{inspect(reason)}
        """)
    end
  end

  defp check_pubsub(io) do
    case fetch_config() do
      {:ok, %Config{pubsub: nil}} ->
        fail(io, "pubsub", "No `:pubsub` configured for ObanUI.")

      {:ok, %Config{pubsub: pubsub}} ->
        if Process.whereis(pubsub) do
          ok(io, "pubsub", "Phoenix.PubSub #{inspect(pubsub)} is running")
        else
          fail(io, "pubsub", "Phoenix.PubSub #{inspect(pubsub)} is configured but not running.")
        end

      _ ->
        skip(io, "pubsub", "config missing — skipped")
    end
  end

  defp check_oban_instances(io) do
    case fetch_config() do
      {:ok, %Config{oban_names: names}} ->
        Enum.map(names, fn name ->
          try do
            %Oban.Config{} = Oban.config(name)
            ok(io, "oban", "instance #{inspect(name)} is registered")
          rescue
            e ->
              fail(io, "oban", """
              Oban instance #{inspect(name)} is not running.
              Make sure `{Oban, name: #{inspect(name)}, ...}` is in your
              application's supervision tree BEFORE `{ObanUI, ...}`.

              Underlying error: #{Exception.message(e)}
              """)
          end
        end)
        |> aggregate("oban")

      _ ->
        skip(io, "oban", "config missing — skipped")
    end
  end

  defp check_notifier(io) do
    case fetch_config() do
      {:ok, %Config{oban_names: names}} ->
        Enum.map(names, fn name ->
          try do
            Oban.Notifier.listen(name, [:insert])
            ok(io, "notifier", "Notifier on #{inspect(name)} accepts subscriptions")
          rescue
            e ->
              warn(io, "notifier", """
              Oban.Notifier.listen/2 raised for #{inspect(name)}: #{Exception.message(e)}

              Live updates will fall back to polling.
              """)
          catch
            kind, reason ->
              warn(
                io,
                "notifier",
                "Notifier on #{inspect(name)} unhealthy: #{inspect({kind, reason})}"
              )
          end
        end)
        |> aggregate("notifier")

      _ ->
        skip(io, "notifier", "config missing — skipped")
    end
  end

  defp check_oban_jobs_table(io) do
    case fetch_config() do
      {:ok, %Config{repo: nil}} ->
        warn(io, "oban_jobs", "ObanUI repo is nil — cannot inspect oban_jobs table")

      {:ok, %Config{repo: repo}} ->
        try do
          %Postgrex.Result{rows: [[count]]} =
            repo.query!("SELECT count(*) FROM oban_jobs", [])

          ok(io, "oban_jobs", "table reachable (#{count} rows)")
        rescue
          e -> fail(io, "oban_jobs", "Could not query oban_jobs: #{Exception.message(e)}")
        end

      _ ->
        skip(io, "oban_jobs", "config missing — skipped")
    end
  end

  defp check_metrics_table(io) do
    case fetch_config() do
      {:ok, %Config{stats: %{persist: true}, repo: repo}} when repo != nil ->
        try do
          repo.query!("SELECT count(*) FROM oban_ui_metrics", [])
          ok(io, "metrics", "oban_ui_metrics table present (persistence enabled)")
        rescue
          _ ->
            fail(io, "metrics", """
            stats: [persist: true] is set but oban_ui_metrics is missing.
            Run:

                mix oban_ui.gen.migration
                mix ecto.migrate
            """)
        end

      {:ok, _config} ->
        skip(io, "metrics", "persistence disabled — skipped")

      _ ->
        skip(io, "metrics", "config missing — skipped")
    end
  end

  defp check_assets(io) do
    css = Application.app_dir(:oban_ui, "priv/static/oban_ui.css")
    js = Application.app_dir(:oban_ui, "priv/static/oban_ui.js")

    cond do
      not File.exists?(css) ->
        fail(io, "assets", "Pre-built CSS bundle is missing at #{css}")

      not File.exists?(js) ->
        fail(io, "assets", "Pre-built JS bundle is missing at #{js}")

      true ->
        ok(
          io,
          "assets",
          "CSS (#{format_size(css)}) and JS (#{format_size(js)}) bundles present; hashes #{Assets.css_hash()} / #{Assets.js_hash()}"
        )
    end
  end

  # --- output helpers ---

  defp ok(io, check, msg), do: print(io, {:ok, check, msg})
  defp fail(io, check, msg), do: print(io, {:fail, check, msg})
  defp warn(io, check, msg), do: print(io, {:warn, check, msg})
  defp skip(io, check, msg), do: print(io, {:skip, check, msg})

  defp print(io, {:ok, check, msg} = entry) do
    io.info([:green, "  [ok]   ", :reset, pad(check), msg])
    entry
  end

  defp print(io, {:fail, check, msg} = entry) do
    io.info([:red, "  [fail] ", :reset, pad(check), indent(msg)])
    entry
  end

  defp print(io, {:warn, check, msg} = entry) do
    io.info([:yellow, "  [warn] ", :reset, pad(check), indent(msg)])
    entry
  end

  defp print(io, {:skip, check, msg} = entry) do
    io.info([:light_black, "  [skip] ", :reset, pad(check), msg])
    entry
  end

  defp pad(check), do: String.pad_trailing(check, 11) <> " "

  defp indent(msg) do
    msg
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.map_join("\n             ", & &1)
  end

  defp aggregate(results, _check) do
    cond do
      Enum.any?(results, &match?({:fail, _, _}, &1)) -> {:fail, "aggregate", ""}
      Enum.any?(results, &match?({:warn, _, _}, &1)) -> {:warn, "aggregate", ""}
      true -> {:ok, "aggregate", ""}
    end
  end

  defp fetch_config do
    {:ok, Config.fetch!()}
  rescue
    e -> {:error, e}
  end

  defp format_size(path) do
    case File.stat(path) do
      {:ok, %{size: n}} -> "#{div(n, 1024)} KB"
      _ -> "?"
    end
  end

  # Silence unused alias warnings — Stats is referenced from the moduledoc.
  _ = Stats
end
