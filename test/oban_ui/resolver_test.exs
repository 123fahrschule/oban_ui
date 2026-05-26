defmodule ObanUI.ResolverTest do
  use ExUnit.Case, async: true

  alias ObanUI.Resolver

  # A host-style resolver that strips an encoded original-args key, mirroring
  # the real Web.ObanUIResolver in the user's app.
  defmodule StrippingResolver do
    @behaviour ObanUI.Resolver
    def format_job_args(%{} = args), do: Map.drop(args, ["__original_args", :__original_args])
    def format_job_args(args), do: args
    def format_job_meta(meta), do: meta
  end

  describe "format_args/2" do
    test "applies the resolver's format_job_args, dropping __original_args" do
      args = %{"__original_args" => "g2w...", "student_id" => "abc", "metadata" => %{}}
      formatted = Resolver.format_args(StrippingResolver, args)

      refute Map.has_key?(formatted, "__original_args")
      assert formatted["student_id"] == "abc"
    end

    test "falls back to raw args for the default resolver" do
      args = %{"__original_args" => "g2w...", "x" => 1}
      # Default resolver passes args through unchanged.
      assert Resolver.format_args(Resolver.Default, args) == args
    end

    test "falls back to raw args when the resolver doesn't implement the callback" do
      defmodule NoFormatResolver do
        def resolve_access(_), do: :all
      end

      args = %{"a" => 1}
      assert Resolver.format_args(NoFormatResolver, args) == args
    end
  end

  describe "exported?/3" do
    test "is true for a loaded module's public function" do
      assert Resolver.exported?(StrippingResolver, :format_job_args, 1)
    end

    test "is false for a missing function" do
      refute Resolver.exported?(StrippingResolver, :nope, 9)
    end
  end

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
