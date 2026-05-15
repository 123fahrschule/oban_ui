[
  import_deps: [:phoenix, :phoenix_live_view, :ecto, :ecto_sql],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test,dev}/**/*.{ex,exs,heex}"
  ]
]
