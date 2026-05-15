defmodule ObanUI.Resolver.Default do
  @moduledoc """
  Default resolver used when the host doesn't provide one.

  Grants `:all` access, returns the user verbatim, and passes args/meta through.
  Suitable for development and test setups; production apps should provide
  their own.
  """

  @behaviour ObanUI.Resolver

  @impl true
  def resolve_user(conn), do: Map.get(conn.assigns, :current_user)

  @impl true
  def resolve_access(_user), do: :all

  @impl true
  def format_user(nil), do: %{name: "anonymous", email: nil}

  def format_user(%{name: name} = user),
    do: %{name: name, email: Map.get(user, :email)}

  def format_user(other), do: %{name: inspect(other), email: nil}

  @impl true
  def format_job_args(args), do: args

  @impl true
  def format_job_meta(meta), do: meta
end
