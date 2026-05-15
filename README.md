# ObanUI

An open-source Phoenix LiveView dashboard for [Oban](https://github.com/oban-bg/oban).

Feature-parity with the open-source side of `oban_web`, built around Postgres
`LISTEN`/`NOTIFY` for live updates and a pluggable resolver for auth and job
argument display.

## Installation

```elixir
# mix.exs
def deps do
  [
    {:oban_ui, "~> 0.1"}
  ]
end
```

Add to your application supervision tree:

```elixir
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Oban, oban_config()},
  {ObanUI, oban_names: [Oban], pubsub: MyApp.PubSub},
  MyAppWeb.Endpoint
]
```

Mount the dashboard in your router:

```elixir
import ObanUI.Router

scope "/admin", MyAppWeb do
  pipe_through [:browser, :require_admin]

  oban_ui_dashboard "/oban",
    resolver: MyAppWeb.ObanUIResolver,
    oban_names: [Oban]
end
```

## Resolver

Implement `ObanUI.Resolver` to wire up auth and formatting:

```elixir
defmodule MyAppWeb.ObanUIResolver do
  @behaviour ObanUI.Resolver

  def resolve_user(conn), do: conn.assigns[:current_user]
  def resolve_access(%{role: :admin}), do: :all
  def resolve_access(_), do: :read_only

  # When jobs use :erlang.term_to_binary args, decode for display
  def format_job_args(%{"_term" => bin}) when is_binary(bin) do
    bin |> Base.decode64!() |> :erlang.binary_to_term([:safe]) |> inspect(pretty: true)
  end
  def format_job_args(args), do: args
end
```

## Local development

```sh
mix deps.get
mix ecto.setup           # creates dev/test DBs, runs migrations
mix dev                  # starts dev app on http://localhost:4000
```

## License

MIT
