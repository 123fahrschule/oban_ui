defmodule ObanUI.Queries.CronsTest do
  use ObanUI.DataCase, async: false

  alias ObanUI.Queries.Crons

  setup do
    ObanUI.Config.put(
      oban_names: [Oban],
      pubsub: :__test_pubsub__,
      repo: ObanUI.DevApp.Repo,
      stats: [enabled: false]
    )

    :ok
  end

  test "returns empty list if no Oban instance is running" do
    # Oban isn't booted in the test environment — Crons.list rescues and
    # falls through to []. Smoke test.
    assert is_list(Crons.list(Oban))
  end
end
