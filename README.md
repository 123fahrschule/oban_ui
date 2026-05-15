# ObanUI

An open-source Phoenix LiveView dashboard for
[Oban](https://github.com/oban-bg/oban) — an alternative to the commercial
`oban_web` package with parity to its open-source feature set.

- Live jobs list with state tabs, sortable columns, filter chips
  (worker / queue / tags / priority / time range / args path search) and
  cursor pagination.
- Single-job actions: retry, cancel, delete; an inline edit form for
  `priority`, `tags`, `scheduled_at` and `max_attempts` on non-executing
  jobs.
- **Bulk actions** across all filtered jobs with an impact preview;
  ≤1000 affected rows run synchronously, larger sets dispatch to a
  background worker and broadcast progress to a one-shot PubSub topic.
- **Queues** view with per-queue throughput sparklines, a per-node
  executing breakdown, leader info from `oban_peers`, and
  pause / resume / scale / stop controls scoped local or global.
- **Dashboard** with a stacked success / failure / discard chart and
  1h / 6h / 24h / 7d range picker. Top-N worker and queue tallies.
- **Crons** read-only view with friendly descriptions, live next-run
  countdown and last-run timestamp.
- Multi-instance support, dark mode, CSP nonce, keyboard shortcuts,
  focus-trapped detail drawer, screen-reader live regions, and a
  reconnecting-banner when the LiveSocket drops.
- **Optional Postgres persistence** of in-memory throughput rollups so
  charts survive a BEAM restart.

Pro-only features from `oban_web` (Workflows graph, DynamicCron editor,
Recorded Outputs, Smart Engine introspection) are out of scope — see
[Out of scope](#out-of-scope).

## Installation

```elixir
# mix.exs
def deps do
  [
    # While developing alongside this repo:
    {:oban_ui, path: "../oban_ui"}
    # Once published:
    # {:oban_ui, "~> 0.1"}
  ]
end
```

Add to your application's supervision tree, ahead of your `Endpoint`:

```elixir
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Phoenix.PubSub, name: MyApp.PubSub},
    {Oban, oban_config()},
    {ObanUI,
      oban_names: [Oban],
      pubsub: MyApp.PubSub,
      repo: MyApp.Repo,
      stats: [enabled: true, persist: false]
    },
    MyAppWeb.Endpoint
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

Mount the dashboard in your router. The macro emits both the static asset
routes and the `live_session` containing every LiveView:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import ObanUI.Router

  pipeline :admin do
    plug :browser
    plug MyAppWeb.RequireAdmin
  end

  scope "/admin", MyAppWeb do
    pipe_through :admin

    oban_ui_dashboard "/oban",
      resolver: MyAppWeb.ObanUIResolver,
      oban_names: [Oban],
      csp_nonce_assign_key: :csp_nonce
  end
end
```

That's it — the dashboard is now at `/admin/oban`. Pre-built CSS and JS
ship inside the library's `priv/static`, so the host needs **no** Tailwind
or esbuild configuration.

## Resolver

Auth, capability and display formatting all happen in one host-provided
module that implements `ObanUI.Resolver`:

```elixir
defmodule MyAppWeb.ObanUIResolver do
  @behaviour ObanUI.Resolver

  # Plug.Conn -> arbitrary user term you'll see in resolve_access/format_*
  def resolve_user(conn), do: conn.assigns[:current_user]

  # Return :all | :read_only | a keyword list of action permissions.
  def resolve_access(%{role: :admin}), do: :all
  def resolve_access(%{role: :operator}),
    do: [cancel_jobs: true, retry_jobs: true, pause_queues: true]
  def resolve_access(_), do: :read_only

  # Optional pretty name shown in the top bar.
  def format_user(%{name: name, email: email}),
    do: %{name: name, email: email}

  # If your jobs wrap their args in :erlang.term_to_binary (so that Date,
  # Decimal, structs etc. survive without bespoke JSON encoders), unwrap
  # them here for the detail drawer.
  def format_job_args(%{"_term" => bin}) when is_binary(bin) do
    bin
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
    |> inspect(pretty: true, limit: :infinity)
  end

  def format_job_args(args), do: args

  def format_job_meta(meta), do: meta
end
```

Recognised capabilities:

| Action | Effect when disabled |
|---|---|
| `cancel_jobs` | Cancel buttons render disabled with a tooltip |
| `retry_jobs` | Same for retry |
| `delete_jobs` | Same for destructive bulk + per-row delete |
| `pause_queues` | Pause / resume / stop disabled |
| `scale_queues` | Concurrency form disabled |
| `edit_jobs` | Edit button in the detail drawer disabled |
| `insert_jobs` | Reserved for a future "new job" form |

Server-side checks run on every action regardless of the rendered UI, so
forging requests with the dev console doesn't bypass them.

## Persistent metrics (optional)

Without persistence, the dashboard's throughput rollups live in ETS with a
1-hour retention. To keep history across BEAM restarts and out to weeks of
trend data:

```sh
mix oban_ui.gen.migration   # or --repo MyApp.Repo
mix ecto.migrate
```

Then flip the flag:

```elixir
{ObanUI,
  oban_names: [Oban],
  pubsub: MyApp.PubSub,
  stats: [enabled: true, persist: true]
}
```

The `ObanUI.Stats.Persistor` flushes the ETS table into `oban_ui_metrics`
every 60 seconds with `INSERT … ON CONFLICT DO UPDATE`, and re-hydrates
the in-memory store on boot with the last 7 days of buckets. The pruner
removes DB rows older than 30 days (`stats: [db_retention_seconds: ...]`
to tune).

## Multi-instance

If your app runs several named Oban supervisors, list them all:

```elixir
{ObanUI,
  oban_names: [Oban, MyApp.HeavyOban, MyApp.ReportsOban],
  pubsub: MyApp.PubSub
}
```

```elixir
oban_ui_dashboard "/oban",
  oban_names: [Oban, MyApp.HeavyOban, MyApp.ReportsOban],
  resolver: MyAppWeb.ObanUIResolver
```

The dashboard exposes an instance picker in the top bar; switching it
navigates to `/oban/i/<instance>/...` and re-scopes every page.

## Telemetry

Every operator action emits a `[:oban_ui, :action]` event so hosts can
audit-log them through their existing telemetry pipeline:

```elixir
:telemetry.attach("oban_ui_audit", [:oban_ui, :action], fn _evt, _meas, meta, _ ->
  Logger.info("oban_ui action", meta)
end, nil)
```

Metadata always includes `:action`, `:user`, `:oban_name`. Action-specific
fields are merged (`job_id`, `queue`, `limit`, `affected`, `mode`, etc.).

## Local development of the library

```sh
mix deps.get
mix dev   # http://localhost:4000
```

A Postgres role matching `$USER` with permission to create databases is
enough — the dev script creates `oban_ui_dev`, runs Oban migrations and
seeds 40 fixture jobs.

For trying the multi-instance picker:

```sh
OBAN_UI_MULTI=1 mix dev
```

Tests:

```sh
mix test
```

Asset rebuild (only library maintainers ever need this):

```sh
mix assets.build
```

## Out of scope

| Feature | Why |
|---|---|
| Workflows graph | Requires `Oban.Pro.Workflow` and its meta layout |
| DynamicCron editor | Requires `Oban.Pro.Plugins.DynamicCron` |
| Recorded outputs | Requires `Oban.Pro.Worker` |
| Live process diagnostics | Pro-only feature in `oban_web` |
| Smart-engine introspection | Smart engine is Pro |

If you have an Oban Pro licence, `oban_web` covers these. ObanUI focuses
on giving the open-source half a UI that doesn't feel cut down.

## License

MIT
