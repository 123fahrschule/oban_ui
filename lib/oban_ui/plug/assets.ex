defmodule ObanUI.Plug.Assets do
  @moduledoc """
  Serves the pre-compiled CSS and JS bundles shipped with the library.

  The bundles live in `priv/static/oban_ui.{css,js}` and are committed to the
  repository. We compute their SHA-256 fingerprint at compile time so the
  library can emit `<link>`/`<script>` tags with content-hashed URLs of the
  form `/css/oban_ui-<hash>.css`.

  Far-future cache headers are safe because the hash changes on every release.
  """

  import Plug.Conn

  @priv_dir Application.app_dir(:oban_ui, "priv/static")

  @css_path Path.join(@priv_dir, "oban_ui.css")
  @js_path Path.join(@priv_dir, "oban_ui.js")

  @external_resource @css_path
  @external_resource @js_path

  @css_body (if File.exists?(@css_path), do: File.read!(@css_path), else: "/* not built */")
  @js_body (if File.exists?(@js_path), do: File.read!(@js_path), else: "/* not built */")

  @css_hash :crypto.hash(:sha256, @css_body) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  @js_hash :crypto.hash(:sha256, @js_body) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  @doc "Returns the hashed CSS file name (e.g. `oban_ui-abc123.css`)."
  def css_filename, do: "oban_ui-#{@css_hash}.css"
  @doc "Returns the hashed JS file name."
  def js_filename, do: "oban_ui-#{@js_hash}.js"
  @doc false
  def css_hash, do: @css_hash
  @doc false
  def js_hash, do: @js_hash

  def init(kind) when kind in [:css, :js], do: kind

  def call(conn, :css), do: serve(conn, @css_body, "text/css; charset=utf-8", @css_hash)
  def call(conn, :js), do: serve(conn, @js_body, "application/javascript; charset=utf-8", @js_hash)

  defp serve(conn, body, content_type, hash) do
    requested = Map.get(conn.path_params, "file", "")
    expected_hash = extract_hash(requested)

    # Static assets do not need CSRF; without this Plug.CSRFProtection blocks
    # `application/javascript` responses as cross-origin.
    conn = put_private(conn, :plug_skip_csrf_protection, true)

    cond do
      expected_hash == nil ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=60")
        |> send_resp(200, body)

      expected_hash == hash ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_resp_header("etag", "\"#{hash}\"")
        |> send_resp(200, body)

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "not found")
        |> halt()
    end
  end

  # Pulls the 12-char hash out of `oban_ui-<hash>.ext`.
  defp extract_hash(filename) do
    case Regex.run(~r/^oban_ui-([0-9a-f]{12})\.[a-z]+$/, filename) do
      [_, hash] -> hash
      _ -> nil
    end
  end
end
