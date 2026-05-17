defmodule ObanUI.Sandbox do
  @moduledoc """
  Helpers for using ObanUI inside host applications that test through the
  Ecto SQL sandbox.

  ObanUI's LiveViews talk to your repo from their own LiveView process —
  one per browser tab — which by default doesn't hold any connection
  ownership. Sandbox tests therefore see "ownership" errors the moment
  the dashboard tries to query `oban_jobs`.

  ## Test setup

  In `test_helper.exs` or a global support file:

      Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :manual)

  In your `ConnCase` setup:

      setup tags do
        pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: not tags[:async])
        on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

        # Hand the sandbox-owned connection to every LiveView that mounts
        # under this conn. Without this, the LiveView would spawn a fresh
        # process with no ownership and queries would fail.
        conn =
          Phoenix.ConnTest.build_conn()
          |> ObanUI.Sandbox.allow(MyApp.Repo, pid)

        %{conn: conn}
      end

  ## On the wire

  Under the hood, `allow/3` sets a session entry the
  `ObanUI.Sandbox.OnMount` hook reads to call
  `Ecto.Adapters.SQL.Sandbox.allow/3` from inside the LiveView process.

  Hosts that already use `Phoenix.Ecto.SQL.Sandbox` can skip this —
  ObanUI's LiveViews use the host's existing Endpoint, so the sandbox
  plug applies to our routes too.

  ## Wiring the on_mount hook

  ObanUI's `live_session :oban_ui` already runs `ObanUI.Web.OnMount`. To
  pick up the sandbox cookie in tests, also pass `:sandbox` to the
  router macro:

      oban_ui_dashboard "/oban",
        resolver: MyAppWeb.ObanUIResolver,
        sandbox: Mix.env() == :test
  """

  @cookie_key "oban_ui_sandbox_owner"

  @doc """
  Stamps the conn's session with the current sandbox owner PID. The
  encoded PID survives a single round-trip back to the LiveView mount.

  Pass either the connection-owner PID (returned by
  `Ecto.Adapters.SQL.Sandbox.start_owner!/2`) or `self()` if you are
  using the shared mode.
  """
  @spec allow(Plug.Conn.t(), module(), pid()) :: Plug.Conn.t()
  def allow(conn, repo, owner_pid \\ self()) when is_pid(owner_pid) do
    Plug.Conn.put_session(conn, @cookie_key, %{
      "repo" => Atom.to_string(repo),
      "owner" => :erlang.pid_to_list(owner_pid) |> List.to_string()
    })
  end

  @doc """
  Reads the sandbox cookie from a LiveView session and grants the calling
  process access to the owner's connection. Called from
  `ObanUI.Web.OnMount` when the host opts in via `sandbox: true`.

  Returns `:ok` regardless — a missing or malformed cookie is a no-op
  rather than a hard failure so the same code can run in production
  where the cookie is never set.
  """
  @spec allow_from_session(map()) :: :ok
  def allow_from_session(%{} = session) do
    with %{"repo" => repo_string, "owner" => owner_string} <- session[@cookie_key],
         {:ok, repo} <- to_repo(repo_string),
         {:ok, owner} <- to_pid(owner_string) do
      Ecto.Adapters.SQL.Sandbox.allow(repo, owner, self())
      :ok
    else
      _ -> :ok
    end
  end

  def allow_from_session(_), do: :ok

  defp to_repo(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  defp to_pid(string) do
    {:ok, :erlang.list_to_pid(String.to_charlist(string))}
  rescue
    ArgumentError -> :error
  end

  @doc false
  def cookie_key, do: @cookie_key
end
