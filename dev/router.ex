defmodule ObanUI.DevApp.Router do
  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import ObanUI.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  @oban_names if System.get_env("OBAN_UI_MULTI") in ~w(1 true yes),
                do: [Oban, ObanUI.DevApp.SecondaryOban],
                else: [Oban]

  scope "/" do
    pipe_through :browser

    get "/", ObanUI.DevApp.HomeController, :index

    oban_ui_dashboard("/oban", oban_names: @oban_names)
  end
end

defmodule ObanUI.DevApp.HomeController do
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    html(conn, """
    <!DOCTYPE html>
    <html lang="en">
      <head><meta charset="utf-8"><title>ObanUI Dev</title></head>
      <body style="font-family:system-ui;padding:2rem">
        <h1>ObanUI Dev App</h1>
        <p><a href="/oban">Open dashboard</a></p>
      </body>
    </html>
    """)
  end
end
