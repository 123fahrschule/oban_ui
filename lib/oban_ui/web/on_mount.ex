defmodule ObanUI.Web.OnMount do
  @moduledoc """
  LiveView `on_mount` hook. Resolves the current user, computes the access
  capabilities, picks the active Oban instance, and stashes everything on the
  socket assigns.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias ObanUI.Resolver

  @doc false
  def on_mount(:default, params, session, socket) do
    opts = session["oban_ui_opts"] || %{}
    resolver = opts[:resolver] || Resolver.Default
    # Prefer the explicitly mounted list; fall back to whatever the
    # supervisor knows about so hosts that only configure :oban_names in
    # one place still get a working picker.
    oban_names = opts[:oban_names] || runtime_oban_names() || [Oban]
    base_path = opts[:base_path] || "/oban"

    # When the host opts into sandbox-aware mounting (test env) we forward
    # the encoded owner-PID + repo from the session to Ecto's sandbox so
    # the LiveView process can see the test's fixture data. In production
    # the cookie is never set and this is a no-op.
    if opts[:sandbox], do: ObanUI.Sandbox.allow_from_session(session)

    user =
      if Resolver.exported?(resolver, :resolve_user, 1) and socket.assigns[:current_user] do
        socket.assigns[:current_user]
      else
        nil
      end

    capabilities =
      resolver
      |> Resolver.resolve_access(user)
      |> Resolver.normalize()

    instance =
      case params["instance"] do
        nil ->
          hd(oban_names)

        name when is_binary(name) ->
          atom = safe_to_atom(name)
          if atom in oban_names, do: atom, else: hd(oban_names)
      end

    nonce_key = opts[:csp_nonce_assign_key]
    nonce = if nonce_key && is_atom(nonce_key), do: Map.get(socket.assigns, nonce_key), else: nil

    socket =
      socket
      |> assign(:resolver, resolver)
      |> assign(:current_user, user)
      |> assign(:user_display, Resolver.format_user(resolver, user))
      |> assign(:access, capabilities)
      |> assign(:oban_names, oban_names)
      |> assign(:active_oban, instance)
      |> assign(:base_path, base_path)
      |> assign(:csp_nonce_assign_key, nonce_key)
      |> assign(:csp_nonce, nonce)

    {:cont, socket}
  rescue
    error ->
      socket =
        socket
        |> assign(:access, Resolver.normalize(:read_only))
        |> put_flash(:error, "ObanUI mount failed: #{Exception.message(error)}")

      {:cont, socket}
  end

  defp safe_to_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :__unknown__
  end

  defp runtime_oban_names do
    ObanUI.Config.fetch!().oban_names
  rescue
    _ -> nil
  end
end
