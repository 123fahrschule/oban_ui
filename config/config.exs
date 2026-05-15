import Config

config :phoenix, :json_library, Jason
config :logger, :default_handler, level: :info

if config_env() == :dev do
  config :tailwind,
    version: "3.4.13",
    oban_ui: [
      args:
        ~w(--config=tailwind.config.js --input=css/app.css --output=../priv/static/oban_ui.css),
      cd: Path.expand("../assets", __DIR__)
    ]

  config :esbuild,
    version: "0.21.5",
    oban_ui: [
      args:
        ~w(js/app.js --bundle --target=es2020 --outfile=../priv/static/oban_ui.js --format=iife --global-name=ObanUI),
      cd: Path.expand("../assets", __DIR__)
    ]
end

if File.exists?(Path.join([__DIR__, "#{config_env()}.exs"])) do
  import_config "#{config_env()}.exs"
end
