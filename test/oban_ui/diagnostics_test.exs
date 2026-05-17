defmodule ObanUI.DiagnosticsTest do
  use ObanUI.DataCase, async: false

  alias ObanUI.Diagnostics

  setup do
    ObanUI.Config.put(
      oban_names: [Oban],
      pubsub: :__diag_test_pubsub__,
      repo: ObanUI.DevApp.Repo,
      stats: [enabled: false]
    )

    :ok
  end

  test "returns available: false for a non-executing job without raising" do
    job = insert!(%{state: "completed", attempt: 1})
    info = Diagnostics.for_job(Oban, job)

    refute info.available
    assert info.reason =~ ~r/not executing/
  end

  test "returns available: false when no executor matches the job_id" do
    # A job in 'executing' state but no Oban running, so no producer can
    # find it. We boot a minimal Oban purely so the registry exists.
    oban_name = String.to_atom("DiagTestOban#{System.unique_integer([:positive])}")

    {:ok, oban_pid} =
      Oban.start_link(
        name: oban_name,
        repo: ObanUI.DevApp.Repo,
        queues: false,
        plugins: false,
        notifier: Oban.Notifiers.PG,
        testing: :manual
      )

    Ecto.Adapters.SQL.Sandbox.allow(ObanUI.DevApp.Repo, self(), oban_pid)

    on_exit(fn ->
      try do
        if Process.alive?(oban_pid), do: Supervisor.stop(oban_pid, :normal, 2_000)
      catch
        _, _ -> :ok
      end
    end)

    job = insert!(%{state: "executing", queue: "default", attempt: 1})
    info = Diagnostics.for_job(oban_name, job)

    refute info.available
    # Either the producer doesn't exist (queues: false) or there's no
    # matching running entry. Both are reasonable explanations.
    assert info.reason =~ ~r/Producer for queue|No running executor/
  end
end
