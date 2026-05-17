defmodule ObanUI.NotifierTest do
  use ExUnit.Case, async: true

  alias ObanUI.Notifier

  describe "topic/1" do
    test "builds well-known topic names" do
      assert Notifier.topic({:overview, :default_oban}) == "oban_ui:overview:default_oban"
      assert Notifier.topic({:queues, :default_oban}) == "oban_ui:queues:default_oban"
      assert Notifier.topic({:jobs, :default_oban}) == "oban_ui:jobs:default_oban"

      assert Notifier.topic({:queue, :default_oban, "media"}) ==
               "oban_ui:queue:default_oban:media"

      assert Notifier.topic({:job, :default_oban, 123}) == "oban_ui:job:default_oban:123"
    end
  end

  describe "ingest + flush" do
    setup do
      pubsub = :"ObanUI.NotifierTest.PubSub-#{System.unique_integer([:positive])}"
      {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: pubsub)

      oban_name = :"test_oban_#{System.unique_integer([:positive])}"
      {:ok, pid} = Notifier.start_link(oban_name: oban_name, pubsub: pubsub, flush_interval: 50)

      :ok = Phoenix.PubSub.subscribe(pubsub, Notifier.topic({:jobs, oban_name}))
      :ok = Phoenix.PubSub.subscribe(pubsub, Notifier.topic({:queue, oban_name, "default"}))

      %{pid: pid, pubsub: pubsub, oban_name: oban_name}
    end

    test "coalesces inserts and emits ticks", %{pid: pid, oban_name: oban_name} do
      send(pid, {:notification, :insert, %{"queue" => "default"}})
      send(pid, {:notification, :insert, %{"queue" => "default"}})
      send(pid, {:notification, :insert, %{"queue" => "default"}})

      Notifier.flush(oban_name)

      assert_receive {:tick, %{inserts: 3}}, 500
      assert_receive :tick, 500
    end

    test "ignores unrecognised channels", %{pid: pid, oban_name: oban_name} do
      send(pid, {:notification, :unknown, %{}})
      Notifier.flush(oban_name)
      refute_receive _msg, 100
    end
  end
end
