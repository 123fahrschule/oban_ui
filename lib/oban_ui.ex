defmodule ObanUI do
  @moduledoc """
  An open-source LiveView dashboard for Oban.

  ObanUI is started as part of your application's supervision tree and mounted
  in your Phoenix router via the `ObanUI.Router.oban_ui_dashboard/2` macro.

  ## Supervision

      children = [
        MyApp.Repo,
        {Phoenix.PubSub, name: MyApp.PubSub},
        {Oban, oban_config()},
        {ObanUI, oban_names: [Oban], pubsub: MyApp.PubSub, repo: MyApp.Repo},
        MyAppWeb.Endpoint
      ]

  ## Options

    * `:oban_names` - list of Oban instance names (atoms) to manage. Required.
    * `:pubsub` - the `Phoenix.PubSub` server name. Required.
    * `:repo` - the `Ecto.Repo` used to query `oban_jobs`. If omitted, the first
      configured Oban instance's repo is used.
    * `:stats` - keyword list of stats options. `enabled: true | false`,
      `persist: true | false` (default `false`).

  ## Mounting

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import ObanUI.Router

        scope "/admin", MyAppWeb do
          pipe_through [:browser, :require_admin]

          oban_ui_dashboard "/oban",
            resolver: MyAppWeb.ObanUIResolver,
            oban_names: [Oban]
        end
      end
  """

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {ObanUI.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Returns the library version as a string.
  """
  def version, do: Application.spec(:oban_ui, :vsn) |> to_string()
end
