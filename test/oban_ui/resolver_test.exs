defmodule ObanUI.ResolverTest do
  use ExUnit.Case, async: true

  alias ObanUI.Resolver

  describe "normalize/1" do
    test "all grants every action" do
      caps = Resolver.normalize(:all)
      for action <- Resolver.actions(), do: assert(caps[action] == true)
    end

    test "read_only denies every action" do
      caps = Resolver.normalize(:read_only)
      for action <- Resolver.actions(), do: assert(caps[action] == false)
    end

    test "keyword list merges with defaults of false" do
      caps = Resolver.normalize(retry_jobs: true, cancel_jobs: true)
      assert caps.retry_jobs
      assert caps.cancel_jobs
      refute caps.delete_jobs
      refute caps.pause_queues
    end

    test "bogus input defaults to read-only" do
      caps = Resolver.normalize("nonsense")
      for action <- Resolver.actions(), do: refute(caps[action])
    end
  end

  describe "can?/2" do
    test "all yields true" do
      assert Resolver.can?(:all, :cancel_jobs)
      assert Resolver.can?(:all, :scale_queues)
    end

    test "read_only yields false" do
      refute Resolver.can?(:read_only, :cancel_jobs)
    end

    test "keyword list respects individual flags" do
      assert Resolver.can?([retry_jobs: true], :retry_jobs)
      refute Resolver.can?([retry_jobs: true], :delete_jobs)
    end

    test "unknown action defaults to false" do
      refute Resolver.can?([retry_jobs: true], :imaginary)
    end
  end
end
