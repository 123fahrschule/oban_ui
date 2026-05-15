defmodule ObanUI.Web.Layouts do
  @moduledoc false
  use Phoenix.Component

  alias ObanUI.Plug.Assets

  embed_templates "layouts/*"

  @doc false
  def css_url(base_path), do: Path.join([base_path || "/oban", "css", Assets.css_filename()])
  @doc false
  def js_url(base_path), do: Path.join([base_path || "/oban", "js", Assets.js_filename()])
end
