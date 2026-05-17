defmodule ObanUI.DevApp.ErrorView do
  @moduledoc false
  def render("404.html", _), do: "Not found"
  def render("500.html", _), do: "Server error"
  def render(_, _), do: "Error"
end

defmodule ObanUI.DevApp.Endpoint do
  use Phoenix.Endpoint, otp_app: :oban_ui

  @session_options [
    store: :cookie,
    key: "_oban_ui_dev_key",
    signing_salt: "oban-ui-dev-salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Logger

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ObanUI.DevApp.Router
end
