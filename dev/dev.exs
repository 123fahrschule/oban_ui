# Bootstraps a minimal Phoenix endpoint backed by Oban and ObanUI for local
# development. Run with `mix dev`.

Logger.configure(level: :info)

endpoint_config =
  Application.get_env(:oban_ui, ObanUI.DevApp.Endpoint, [])
  |> Keyword.put_new(:url, host: "localhost")
  |> Keyword.put_new(:http, [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))])
  |> Keyword.put_new(:secret_key_base, String.duplicate("a", 64))
  |> Keyword.put_new(:server, true)
  |> Keyword.put_new(:debug_errors, true)
  |> Keyword.put_new(:check_origin, false)
  |> Keyword.put_new(:pubsub_server, ObanUI.DevApp.PubSub)
  |> Keyword.put_new(:live_view, signing_salt: "oban-ui-dev")

Application.put_env(:oban_ui, ObanUI.DevApp.Endpoint, endpoint_config)
Application.put_env(:oban_ui, :ecto_repos, [ObanUI.DevApp.Repo])

repo_config =
  Application.get_env(:oban_ui, ObanUI.DevApp.Repo, [])
  |> Keyword.put_new(:hostname, System.get_env("POSTGRES_HOST", "localhost"))
  |> Keyword.put_new(:username, System.get_env("POSTGRES_USER") || System.get_env("USER") || "postgres")
  |> Keyword.put_new(:password, System.get_env("POSTGRES_PASSWORD", ""))
  |> Keyword.put_new(:database, System.get_env("POSTGRES_DB", "oban_ui_dev"))
  |> Keyword.put_new(:pool_size, 10)

Application.put_env(:oban_ui, ObanUI.DevApp.Repo, repo_config)

# Phase 1 — start *just* the Repo so we can run migrations before Oban boots.
{:ok, repo_sup} =
  Supervisor.start_link([ObanUI.DevApp.Repo], strategy: :one_for_one, name: ObanUI.DevApp.RepoSup)

case ObanUI.DevApp.Repo.__adapter__().storage_up(ObanUI.DevApp.Repo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
  {:error, reason} ->
    IO.warn("Could not create DB: #{inspect(reason)}")
    :ok
end

ObanUI.DevApp.Migrator.run!()

# Phase 2 — stop the temporary repo supervisor; the main one will own it.
Supervisor.stop(repo_sup)

multi_instance? = System.get_env("OBAN_UI_MULTI") in ~w(1 true yes)

oban_children =
  if multi_instance? do
    [
      {Oban,
       name: Oban,
       repo: ObanUI.DevApp.Repo,
       queues: [default: 5, mailers: 2, media: 1],
       plugins: [
         {Oban.Plugins.Cron,
          crontab: [
            {"@daily", ObanUI.DevApp.NoopWorker}
          ]}
       ]},
      # Second instance shares the same DB and oban_jobs table — Oban
       # disambiguates rows by their queue list. Use this to exercise the
       # multi-instance picker without a second migration.
       {Oban,
       name: ObanUI.DevApp.SecondaryOban,
       repo: ObanUI.DevApp.Repo,
       queues: [reports: 2, exports: 1]}
    ]
  else
    [
      {Oban,
       repo: ObanUI.DevApp.Repo,
       queues: [default: 5, mailers: 2, media: 1],
       plugins: [
         {Oban.Plugins.Cron,
          crontab: [
            {"@daily", ObanUI.DevApp.NoopWorker}
          ]}
       ]}
    ]
  end

oban_names = if multi_instance?, do: [Oban, ObanUI.DevApp.SecondaryOban], else: [Oban]

children =
  [{Phoenix.PubSub, name: ObanUI.DevApp.PubSub}, ObanUI.DevApp.Repo] ++
    oban_children ++
    [
      {ObanUI,
       oban_names: oban_names, pubsub: ObanUI.DevApp.PubSub, repo: ObanUI.DevApp.Repo},
      ObanUI.DevApp.Endpoint
    ]

{:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one, name: ObanUI.DevApp.Supervisor)

ObanUI.DevApp.Seeds.run!()

IO.puts("\n  ObanUI dev app running on http://localhost:#{endpoint_config[:http][:port]}\n")

Process.sleep(:infinity)
