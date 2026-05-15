defmodule ObanUI.Queries.QueuesTest do
  use ObanUI.DataCase, async: false

  alias ObanUI.Queries.Queues, as: QueuesQuery

  setup do
    ObanUI.Config.put(
      oban_names: [Oban],
      pubsub: :__test_pubsub__,
      repo: ObanUI.DevApp.Repo,
      stats: [enabled: false]
    )

    :ok
  end

  test "nodes_for_queue groups executing jobs by attempted_by entries" do
    insert!(%{state: "executing", queue: "media", attempted_by: ["a@host"]})
    insert!(%{state: "executing", queue: "media", attempted_by: ["a@host"]})
    insert!(%{state: "executing", queue: "media", attempted_by: ["b@host"]})
    insert!(%{state: "available", queue: "media", attempted_by: nil})

    nodes = QueuesQuery.nodes_for_queue("media")

    assert Enum.sort_by(nodes, & &1.node) == [
             %{node: "a@host", executing: 2},
             %{node: "b@host", executing: 1}
           ]
  end

  test "leader_info returns nil when no peer row exists" do
    assert QueuesQuery.leader_info(Oban) == nil
  end

  test "detail/2 merges summary, nodes, and (nil) leader" do
    insert!(%{state: "executing", queue: "default", attempted_by: ["node-1@host"]})
    insert!(%{state: "available", queue: "default"})

    detail = QueuesQuery.detail(Oban, "default")

    assert detail.summary.name == "default"
    assert detail.summary.executing == 1
    assert detail.summary.available == 1
    assert [%{node: "node-1@host", executing: 1}] = detail.nodes
    assert detail.leader == nil
  end
end
