defmodule ObanUI.Crons.Parser do
  @moduledoc """
  Tiny self-contained cron expression parser.

  Supports the canonical 5-field expressions Oban accepts plus the common
  shorthand aliases `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`,
  `@midnight`, `@hourly`. Used in `ObanUI.Web.CronsLive` to compute and
  describe the next-run time without pulling in a heavyweight cron lib.

  We parse expressions into a struct with `MapSet`s of allowed values for
  each field, then sweep forward minute by minute from "now" until the
  first match. Worst case for a `0 0 1 1 *` expression at noon on Jan 2 is
  ~525,000 iterations (one year of minutes), still in the low milliseconds.

  Not supported on purpose:
    * `L`, `W`, `#` modifiers (rarely useful in job scheduling)
    * 6/7-field expressions with seconds/year

  Returns `{:ok, %Spec{}}` or `{:error, reason}`.
  """

  @aliases %{
    "@yearly" => "0 0 1 1 *",
    "@annually" => "0 0 1 1 *",
    "@monthly" => "0 0 1 * *",
    "@weekly" => "0 0 * * 0",
    "@daily" => "0 0 * * *",
    "@midnight" => "0 0 * * *",
    "@hourly" => "0 * * * *"
  }

  defmodule Spec do
    @moduledoc false
    defstruct [:minute, :hour, :day, :month, :weekday, :raw]
  end

  @doc "Parses an expression. Returns `{:ok, spec} | {:error, reason}`."
  @spec parse(String.t()) :: {:ok, %Spec{}} | {:error, term()}
  def parse(expr) when is_binary(expr) do
    expr = String.trim(expr)
    expr = Map.get(@aliases, expr, expr)

    case String.split(expr, ~r/\s+/, trim: true) do
      [m, h, d, mo, w] ->
        with {:ok, minute} <- field(m, 0..59),
             {:ok, hour} <- field(h, 0..23),
             {:ok, day} <- field(d, 1..31),
             {:ok, month} <- field(mo, 1..12),
             {:ok, weekday} <- field(w, 0..6) do
          {:ok, %Spec{minute: minute, hour: hour, day: day, month: month, weekday: weekday, raw: expr}}
        end

      _ ->
        {:error, :invalid_expression}
    end
  rescue
    _ -> {:error, :invalid_expression}
  end

  @doc """
  Returns the next minute-aligned `DateTime` at or after `from` for which
  `spec` matches, or `nil` if not reachable within a year.
  """
  @spec next_run_at(%Spec{}, DateTime.t()) :: DateTime.t() | nil
  def next_run_at(%Spec{} = spec, %DateTime{} = from \\ DateTime.utc_now()) do
    start =
      from
      |> DateTime.truncate(:second)
      |> DateTime.add(60 - Map.get(from, :second), :second)

    # Cap at ~366 days of minutes to avoid pathological infinite loops.
    Enum.reduce_while(0..(525_600 + 1440), start, fn _i, dt ->
      if matches?(spec, dt), do: {:halt, dt}, else: {:cont, DateTime.add(dt, 60, :second)}
    end)
    |> case do
      %DateTime{} = dt -> if matches?(spec, dt), do: dt, else: nil
      _ -> nil
    end
  end

  @doc """
  Human-readable description for the common aliases.
  Falls back to the raw expression for unknown forms.
  """
  @spec describe(String.t() | %Spec{}) :: String.t()
  def describe(%Spec{raw: raw}), do: describe(raw)

  def describe(expr) when is_binary(expr) do
    canonical = Map.get(@aliases, String.trim(expr), expr)

    case canonical do
      "0 0 1 1 *" -> "every year at midnight on Jan 1"
      "0 0 1 * *" -> "every month at midnight on day 1"
      "0 0 * * 0" -> "every Sunday at midnight"
      "0 0 * * *" -> "every day at midnight"
      "0 * * * *" -> "every hour"
      "*/5 * * * *" -> "every 5 minutes"
      "*/10 * * * *" -> "every 10 minutes"
      "*/15 * * * *" -> "every 15 minutes"
      "*/30 * * * *" -> "every 30 minutes"
      "* * * * *" -> "every minute"
      _ -> expr
    end
  end

  # ----- field parser -----

  defp field("*", range), do: {:ok, MapSet.new(range)}

  defp field(value, range) do
    parts = String.split(value, ",", trim: true)

    parts
    |> Enum.reduce_while([], fn part, acc ->
      case parse_part(part, range) do
        {:ok, values} -> {:cont, acc ++ values}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      list -> {:ok, MapSet.new(list)}
    end
  end

  defp parse_part(part, range) do
    cond do
      String.starts_with?(part, "*/") ->
        case Integer.parse(String.replace_leading(part, "*/", "")) do
          {step, ""} when step > 0 -> {:ok, Enum.take_every(Enum.to_list(range), step)}
          _ -> {:error, :invalid_step}
        end

      String.contains?(part, "/") ->
        [base, step] = String.split(part, "/", parts: 2)

        case {parse_part(base, range), Integer.parse(step)} do
          {{:ok, values}, {step, ""}} when step > 0 ->
            {:ok, Enum.take_every(values, step)}

          _ ->
            {:error, :invalid_step}
        end

      String.contains?(part, "-") ->
        [from, to] = String.split(part, "-", parts: 2)

        with {fi, ""} <- Integer.parse(from),
             {ti, ""} <- Integer.parse(to),
             true <- fi in range and ti in range do
          {:ok, Enum.to_list(fi..ti)}
        else
          _ -> {:error, :invalid_range}
        end

      true ->
        case Integer.parse(part) do
          {n, ""} when n in 0..59 ->
            if n in range, do: {:ok, [n]}, else: {:error, :out_of_range}

          _ ->
            {:error, :invalid_value}
        end
    end
  end

  # ----- matching -----

  defp matches?(spec, %DateTime{} = dt) do
    weekday = Date.day_of_week(DateTime.to_date(dt), :sunday) - 1

    MapSet.member?(spec.minute, dt.minute) and
      MapSet.member?(spec.hour, dt.hour) and
      MapSet.member?(spec.day, dt.day) and
      MapSet.member?(spec.month, dt.month) and
      MapSet.member?(spec.weekday, weekday)
  end
end
