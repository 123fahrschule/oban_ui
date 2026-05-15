defmodule ObanUI.DataCase do
  @moduledoc """
  Async-capable ExUnit case that wraps each test in an Ecto SQL sandbox
  transaction.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias ObanUI.DevApp.Repo
      import Ecto.Query
      import ObanUI.JobFactory
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ObanUI.DevApp.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
