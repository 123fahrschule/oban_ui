defmodule ObanUI.SandboxTest do
  use ExUnit.Case, async: true

  alias ObanUI.Sandbox

  test "allow/3 stamps the conn session with a serialised repo and owner pid" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Sandbox.allow(SomeApp.Repo, self())

    cookie = Plug.Conn.get_session(conn, Sandbox.cookie_key())
    assert cookie["repo"] == "Elixir.SomeApp.Repo"
    assert cookie["owner"] =~ ~r/^<.*>$/
  end

  test "allow_from_session/1 is a no-op when the cookie is missing" do
    assert :ok = Sandbox.allow_from_session(%{})
    assert :ok = Sandbox.allow_from_session(%{"other" => "stuff"})
    assert :ok = Sandbox.allow_from_session(nil)
  end

  test "allow_from_session/1 tolerates malformed payloads without raising" do
    assert :ok =
             Sandbox.allow_from_session(%{
               Sandbox.cookie_key() => %{"repo" => "nope", "owner" => "junk"}
             })
  end
end
