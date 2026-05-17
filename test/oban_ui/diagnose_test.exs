defmodule ObanUI.DiagnoseTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.ObanUi.Diagnose

  # Captures `info/1` calls so we can inspect what the task printed.
  defmodule TestIO do
    def info(message) do
      send(self_or_owner(), {:io, IO.iodata_to_binary(format(message))})
    end

    defp format(message) when is_list(message) do
      Enum.flat_map(message, fn
        atom when is_atom(atom) -> []
        bin when is_binary(bin) -> [bin]
        other -> [to_string(other)]
      end)
    end

    defp format(message) when is_binary(message), do: [message]
    defp format(other), do: [to_string(other)]

    defp self_or_owner do
      case Process.get(:diagnose_test_io_target) do
        nil -> self()
        pid -> pid
      end
    end
  end

  setup do
    Process.put(:diagnose_test_io_target, self())
    :ok
  end

  defp collect_output do
    Stream.repeatedly(fn ->
      receive do
        {:io, msg} -> msg
      after
        50 -> :stop
      end
    end)
    |> Enum.take_while(&(&1 != :stop))
    |> Enum.join("")
  end

  describe "without a running ObanUI" do
    setup do
      :persistent_term.erase({ObanUI.Config, :runtime})
      :ok
    end

    test "audit returns :error and prints a config failure" do
      assert :error = Diagnose.audit(io: TestIO)
      output = collect_output()

      assert output =~ "[fail]"
      assert output =~ "config"
      assert output =~ "ObanUI is not started"
      # Assets check always runs since it reads from priv/.
      assert output =~ "[ok]"
      assert output =~ "assets"
    end
  end

  describe "with a running ObanUI" do
    setup do
      ObanUI.Config.put(
        oban_names: [Oban],
        pubsub: ObanUI.DiagnoseTest.PubSub,
        repo: ObanUI.DevApp.Repo,
        stats: [enabled: false]
      )

      case Phoenix.PubSub.Supervisor.start_link(name: ObanUI.DiagnoseTest.PubSub) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      :ok
    end

    test "audit prints config OK, pubsub OK, assets OK, but oban fail (not started in tests)" do
      Diagnose.audit(io: TestIO)
      output = collect_output()

      assert output =~ "[ok]"
      assert output =~ "config"
      assert output =~ "pubsub"
      assert output =~ "assets"
      # Oban isn't booted in the test environment so the registry lookup fails.
      assert output =~ "[fail]"
      assert output =~ "oban"
    end

    test "metrics check is skipped when persistence is off" do
      Diagnose.audit(io: TestIO)
      output = collect_output()

      assert output =~ "[skip]"
      assert output =~ "metrics"
      assert output =~ "persistence disabled"
    end
  end
end
