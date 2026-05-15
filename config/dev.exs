import Config

config :oban_ui, ObanUI.DevApp.Repo,
  username: System.get_env("POSTGRES_USER") || System.get_env("USER") || "postgres",
  password: System.get_env("POSTGRES_PASSWORD", ""),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: System.get_env("POSTGRES_DB", "oban_ui_dev"),
  pool_size: 10,
  show_sensitive_data_on_connection_error: true

config :oban_ui, ecto_repos: [ObanUI.DevApp.Repo]

config :oban_ui, ObanUI.DevApp.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "oban-ui-dev"],
  pubsub_server: ObanUI.DevApp.PubSub,
  server: true,
  debug_errors: true,
  check_origin: false,
  watchers: []
