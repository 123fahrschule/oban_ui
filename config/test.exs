import Config

config :oban_ui, ObanUI.DevApp.Repo,
  username: System.get_env("POSTGRES_USER") || System.get_env("USER") || "postgres",
  password: System.get_env("POSTGRES_PASSWORD", ""),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: "oban_ui_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :oban_ui, ecto_repos: [ObanUI.DevApp.Repo]

config :oban_ui, ObanUI.DevApp.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "oban-ui-test"],
  pubsub_server: ObanUI.DevApp.PubSub,
  render_errors: [formats: [html: ObanUI.DevApp.ErrorView], layout: false],
  server: false

# Surface real errors during tests instead of swallowing them in render_errors.
config :phoenix, :stacktrace_depth, 20

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
