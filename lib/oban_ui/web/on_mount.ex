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
    oban_names = opts[:oban_names] || [Oban]
    base_path = opts[:base_path] || "/oban"

    user =
      if function_exported?(resolver, :resolve_user, 1) and socket.assigns[:current_user] do
        socket.assigns[:current_user]
      else
        nil
      end

    access =
      if function_exported?(resolver, :resolve_access, 1) do
        resolver.resolve_access(user)
      else
        :all
      end

    capabilities = Resolver.normalize(access)

    instance =
      case params["instance"] do
        nil ->
          hd(oban_names)

        name when is_binary(name) ->
          atom = safe_to_atom(name)
          if atom in oban_names, do: atom, else: hd(oban_names)
      end

    socket =
      socket
      |> assign(:resolver, resolver)
      |> assign(:current_user, user)
      |> assign(:user_display, safe_format_user(resolver, user))
      |> assign(:access, capabilities)
      |> assign(:oban_names, oban_names)
      |> assign(:active_oban, instance)
      |> assign(:base_path, base_path)
      |> assign(:csp_nonce_assign_key, opts[:csp_nonce_assign_key])

    {:cont, socket}
  rescue
    error ->
      socket =
        socket
        |> assign(:access, Resolver.normalize(:read_only))
        |> put_flash(:error, "ObanUI mount failed: #{Exception.message(error)}")

      {:cont, socket}
  end

  defp safe_format_user(resolver, user) do
    if function_exported?(resolver, :format_user, 1) do
      resolver.format_user(user)
    else
      Resolver.Default.format_user(user)
    end
  end

  defp safe_to_atom(name) when is_binary(name) do
    try do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> :__unknown__
    end
  end
end
