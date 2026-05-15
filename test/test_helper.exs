ExUnit.start()

# Tests run against the dev/ Phoenix endpoint + repo. Boot only the bare
# minimum so we can run LiveView tests without spinning up Oban itself.
Application.put_env(:oban_ui, :ecto_repos, [ObanUI.DevApp.Repo])

case ObanUI.DevApp.Repo.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# Ensure migrations are up. Safe even if DB is fresh.
case ObanUI.DevApp.Repo.__adapter__().storage_up(ObanUI.DevApp.Repo.config()) do
  :ok -> :ok
  {:error, :already_up} -> :ok
  {:error, _} -> :ok
end

ObanUI.DevApp.Migrator.run!()

# Sandbox so each test gets isolation.
Ecto.Adapters.SQL.Sandbox.mode(ObanUI.DevApp.Repo, :manual)
