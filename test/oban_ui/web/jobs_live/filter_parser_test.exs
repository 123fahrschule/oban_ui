defmodule ObanUI.Web.JobsLive.FilterParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ObanUI.Web.JobsLive.FilterParser

  describe "split/1" do
    test "nil and empty collapse to nil" do
      assert FilterParser.split(nil) == nil
      assert FilterParser.split("") == nil
    end

    test "splits comma-separated tokens and trims whitespace" do
      assert FilterParser.split("a, b,c") == ["a", "b", "c"]
    end

    property "round-trips through join when tokens have no whitespace or commas" do
      check all(tokens <- list_of(string([?a..?z, ?A..?Z, ?0..?9], min_length: 1), min_length: 1)) do
        joined = Enum.join(tokens, ",")
        assert FilterParser.split(joined) == tokens
      end
    end

    property "result never contains empty strings" do
      check all(raw <- string(:printable)) do
        case FilterParser.split(raw) do
          nil -> :ok
          list -> assert Enum.all?(list, &(&1 != ""))
        end
      end
    end
  end

  describe "int_list/1" do
    test "extracts only valid integers, dropping junk" do
      assert FilterParser.int_list("1,foo,3, ,5") == [1, 3, 5]
    end

    test "all-junk → nil" do
      assert FilterParser.int_list("foo,bar") == nil
    end

    property "round-trips through join for integer lists" do
      check all(ints <- list_of(integer(), min_length: 1)) do
        joined = Enum.map_join(ints, ",", &Integer.to_string/1)
        assert FilterParser.int_list(joined) == ints
      end
    end

    property "never returns non-integer values" do
      check all(raw <- string(:printable)) do
        case FilterParser.int_list(raw) do
          nil -> :ok
          list -> assert Enum.all?(list, &is_integer/1)
        end
      end
    end
  end

  describe "datetime/1" do
    test "parses ISO-8601" do
      assert FilterParser.datetime("2025-01-15T10:00:00Z") == ~U[2025-01-15 10:00:00Z]
    end

    test "parses HTML datetime-local format" do
      result = FilterParser.datetime("2025-01-15T10:00")
      assert %DateTime{year: 2025, month: 1, day: 15, hour: 10, minute: 0} = result
    end

    property "garbage input always yields nil, never raises" do
      check all(
              raw <- string(:printable, min_length: 1, max_length: 20),
              # skip valid-ish datetime prefixes
              not String.match?(raw, ~r/^\d{4}/)
            ) do
        assert FilterParser.datetime(raw) == nil
      end
    end
  end

  describe "sort/1" do
    test "parses field:direction" do
      assert FilterParser.sort("worker:asc") == {:worker, :asc}
      assert FilterParser.sort("inserted_at:desc") == {:inserted_at, :desc}
    end

    test "unknown field → nil" do
      assert FilterParser.sort("nonsense:asc") == nil
    end

    test "unknown direction defaults to desc" do
      assert FilterParser.sort("worker:bogus") == {:worker, :desc}
    end

    property "garbage never crashes" do
      check all(raw <- string(:printable)) do
        result = FilterParser.sort(raw)
        assert is_nil(result) or (is_tuple(result) and tuple_size(result) == 2)
      end
    end
  end

  describe "build/1" do
    test "ignores keys with no value" do
      assert FilterParser.build(%{}) == %{}
      assert FilterParser.build(%{"state" => "", "worker" => nil}) == %{}
    end

    test "merges every recognised field" do
      filters =
        FilterParser.build(%{
          "state" => "available,executing",
          "worker" => "MyWorker",
          "queue" => "default",
          "priority" => "0,1",
          "q" => "args.user:42",
          "from" => "2025-01-01T00:00:00Z"
        })

      assert filters.states == ["available", "executing"]
      assert filters.workers == ["MyWorker"]
      assert filters.priorities == [0, 1]
      assert filters.search == "args.user:42"
      assert filters.inserted_after == ~U[2025-01-01 00:00:00Z]
    end

    property "build/1 with arbitrary recognised keys never raises" do
      check all(
              values <-
                fixed_map(%{
                  "state" => one_of([nil, string(:ascii)]),
                  "queue" => one_of([nil, string(:ascii)]),
                  "worker" => one_of([nil, string(:ascii)]),
                  "priority" => one_of([nil, string(:ascii)]),
                  "from" => one_of([nil, string(:ascii)])
                })
            ) do
        # The function should always return a map, never raise.
        result = FilterParser.build(values)
        assert is_map(result)
      end
    end
  end
end
