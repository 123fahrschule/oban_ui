defmodule ObanUI.Crons.ParserTest do
  use ExUnit.Case, async: true

  alias ObanUI.Crons.Parser

  describe "parse/1" do
    test "parses aliases" do
      assert {:ok, _} = Parser.parse("@daily")
      assert {:ok, _} = Parser.parse("@hourly")
      assert {:ok, _} = Parser.parse("@yearly")
    end

    test "parses canonical 5-field expressions" do
      assert {:ok, %Parser.Spec{}} = Parser.parse("*/5 * * * *")
      assert {:ok, %Parser.Spec{}} = Parser.parse("0 0 1 1 *")
      assert {:ok, %Parser.Spec{}} = Parser.parse("15,45 * * * *")
      assert {:ok, %Parser.Spec{}} = Parser.parse("0 9-17 * * 1-5")
    end

    test "rejects nonsense" do
      assert {:error, _} = Parser.parse("nonsense")
      assert {:error, _} = Parser.parse("* * * *")
    end
  end

  describe "next_run_at/2" do
    test "@hourly produces a future :00 minute" do
      {:ok, spec} = Parser.parse("@hourly")
      now = ~U[2025-05-15 12:34:56Z]

      dt = Parser.next_run_at(spec, now)

      assert dt.minute == 0
      assert DateTime.compare(dt, now) == :gt
      assert DateTime.diff(dt, now) <= 3600
    end

    test "*/5 returns the next 5-minute aligned minute" do
      {:ok, spec} = Parser.parse("*/5 * * * *")
      now = ~U[2025-05-15 12:34:00Z]

      dt = Parser.next_run_at(spec, now)

      assert dt.minute in [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]
      assert dt.minute == 35
    end

    test "weekday filter is honoured" do
      {:ok, spec} = Parser.parse("0 9 * * 1")
      # 2025-05-15 is a Thursday; next Monday at 09:00 is 2025-05-19 09:00 UTC.
      dt = Parser.next_run_at(spec, ~U[2025-05-15 12:00:00Z])

      assert dt == ~U[2025-05-19 09:00:00Z]
    end
  end

  describe "describe/1" do
    test "renders friendly text for known aliases" do
      assert Parser.describe("@daily") =~ "every day"
      assert Parser.describe("@hourly") =~ "every hour"
      assert Parser.describe("*/5 * * * *") =~ "every 5 minutes"
    end

    test "falls back to raw expression" do
      assert Parser.describe("12 4 1 * 6") == "12 4 1 * 6"
    end
  end
end
