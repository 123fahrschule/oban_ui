defmodule ObanUI.ConnCase do
  @moduledoc """
  ExUnit case template for LiveView / controller tests against the dev
  endpoint. Each test runs in its own Ecto sandbox.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ObanUI.DataCase
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Plug.Conn

      @endpoint ObanUI.DevApp.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
