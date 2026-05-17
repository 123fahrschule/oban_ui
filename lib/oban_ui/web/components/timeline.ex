defmodule ObanUI.Web.Components.Timeline do
  @moduledoc """
  Branched state timeline for the job detail drawer.

  Each retry attempt occupies its own lane. The base flow is:

      inserted_at -> scheduled_at -> attempted_at -> (completed_at | discarded_at | cancelled_at)

  Failed attempts branch off to a red error event, and the next attempt
  reuses a fresh lane connected back to the main spine. The whole thing is
  laid out in plain SVG so it round-trips through LiveView without a JS
  hook.

  Coordinates: time goes left-to-right normalised to the [first, last]
  span. Lanes are stacked vertically.
  """

  use Phoenix.Component

  @width 640
  @lane_height 36
  @padding_x 80
  @padding_top 24

  @doc """
  Renders an SVG timeline for `job`.
  """
  attr :job, :map, required: true

  def render(assigns) do
    events = collect_events(assigns.job)
    {min_t, max_t} = bounds(events, assigns.job)

    {plot_w, _h} = {@width - 2 * @padding_x, 0}

    points =
      Enum.map(events, fn ev ->
        x = position(ev.at, min_t, max_t, plot_w)
        Map.put(ev, :x, @padding_x + x)
      end)

    lanes_for_attempt =
      points
      |> Enum.group_by(& &1.attempt)
      |> Map.new(fn {attempt, _} -> {attempt, lane_y(attempt)} end)

    height = max(@padding_top * 2 + 16, (map_size(lanes_for_attempt) + 1) * @lane_height)

    assigns =
      assigns
      |> assign(:points, points)
      |> assign(:lanes_for_attempt, lanes_for_attempt)
      |> assign(:height, height)
      |> assign(:width, @width)
      |> assign(:padding_x, @padding_x)
      |> assign(:min_t, min_t)
      |> assign(:max_t, max_t)

    legend = legend_items(points)
    assigns = assign(assigns, :legend, legend)

    ~H"""
    <div class="oban-ui-timeline">
      <svg
        viewBox={"0 0 #{@width} #{@height}"}
        width="100%"
        height={@height}
        role="img"
        aria-label="Job state timeline"
      >
        <%!-- Axis line per attempt --%>
        <line
          :for={{_attempt, y} <- @lanes_for_attempt}
          x1={@padding_x}
          x2={@width - @padding_x}
          y1={y}
          y2={y}
          stroke="currentColor"
          stroke-opacity="0.15"
          stroke-width="1"
        />

        <%!-- Connectors between consecutive events on the same attempt --%>
        <g :for={attempt <- Map.keys(@lanes_for_attempt)}>
          <% sorted_points =
            Enum.filter(@points, &(&1.attempt == attempt)) |> Enum.sort_by(& &1.at, DateTime) %>
          <line
            :for={[a, b] <- chunks_of_2(sorted_points)}
            x1={a.x}
            x2={b.x}
            y1={Map.fetch!(@lanes_for_attempt, attempt)}
            y2={Map.fetch!(@lanes_for_attempt, attempt)}
            stroke={connector_color(a, b)}
            stroke-width="2"
          />
        </g>

        <%!-- Attempt label --%>
        <text
          :for={{attempt, y} <- @lanes_for_attempt}
          x="8"
          y={y + 4}
          font-size="11"
          fill="currentColor"
          fill-opacity="0.6"
        >
          attempt {attempt}
        </text>

        <%!--
          Event dots only — no inline text labels. Two events at the same
          timestamp (e.g. attempted_at and completed_at on a fast job) used
          to overlap their labels. Colours come from the legend below;
          hovering a dot still surfaces the precise event and time.
        --%>
        <g :for={p <- @points}>
          <circle
            cx={p.x}
            cy={Map.fetch!(@lanes_for_attempt, p.attempt)}
            r="5"
            fill={event_color(p.kind)}
          />
          <title>{event_label(p.kind)} · {Calendar.strftime(p.at, "%Y-%m-%d %H:%M:%S")}</title>
        </g>

        <%!-- X-axis range labels --%>
        <text x={@padding_x} y={@height - 4} font-size="10" fill="currentColor" fill-opacity="0.5">
          {Calendar.strftime(@min_t, "%H:%M:%S")}
        </text>
        <text
          x={@width - @padding_x}
          y={@height - 4}
          font-size="10"
          text-anchor="end"
          fill="currentColor"
          fill-opacity="0.5"
        >
          {Calendar.strftime(@max_t, "%H:%M:%S")}
        </text>
      </svg>

      <ul class="flex flex-wrap gap-3 text-xs text-slate-600 mt-1" aria-label="Event legend">
        <li :for={{label, color} <- @legend} class="inline-flex items-center gap-1">
          <span
            class="inline-block w-2.5 h-2.5 rounded-full"
            style={"background: #{color}"}
            aria-hidden="true"
          >
          </span>
          {label}
        </li>
      </ul>
    </div>
    """
  end

  defp legend_items(points) do
    points
    |> Enum.map(& &1.kind)
    |> Enum.uniq()
    |> Enum.map(fn kind -> {event_label(kind), event_color(kind)} end)
  end

  # ------------- internals -------------

  defp collect_events(job) do
    base =
      [
        ev(:inserted, job.inserted_at, 1),
        ev(:scheduled, job.scheduled_at, 1),
        ev(:attempted, job.attempted_at, max(job.attempt, 1)),
        ev(:completed, job.completed_at, max(job.attempt, 1)),
        ev(:cancelled, job.cancelled_at, max(job.attempt, 1)),
        ev(:discarded, job.discarded_at, max(job.attempt, 1))
      ]
      |> Enum.reject(&is_nil(&1.at))

    errors =
      (job.errors || [])
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {entry, attempt} ->
        case parse_error_at(entry) do
          nil -> []
          dt -> [ev(:error, dt, attempt)]
        end
      end)

    Enum.sort_by(base ++ errors, & &1.at, DateTime)
  end

  defp ev(kind, at, attempt), do: %{kind: kind, at: to_dt(at), attempt: attempt}

  defp to_dt(nil), do: nil
  defp to_dt(%DateTime{} = dt), do: dt

  defp to_dt(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp to_dt(_), do: nil

  defp parse_error_at(%{"at" => at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_error_at(_), do: nil

  defp bounds([], job) do
    fallback = job.inserted_at || DateTime.utc_now()
    fallback = to_dt(fallback) || DateTime.utc_now()
    {fallback, DateTime.add(fallback, 1, :second)}
  end

  defp bounds(events, _job) do
    times = Enum.map(events, & &1.at)
    {Enum.min(times, DateTime), Enum.max(times, DateTime)}
  end

  defp position(at, min_t, max_t, plot_w) do
    span = DateTime.diff(max_t, min_t, :millisecond)
    if span <= 0, do: plot_w / 2, else: DateTime.diff(at, min_t, :millisecond) / span * plot_w
  end

  defp lane_y(attempt) when is_integer(attempt) do
    @padding_top + (attempt - 1) * @lane_height
  end

  defp event_color(:inserted), do: "#3b82f6"
  defp event_color(:scheduled), do: "#a78bfa"
  defp event_color(:attempted), do: "#10b981"
  defp event_color(:completed), do: "#22c55e"
  defp event_color(:error), do: "#ef4444"
  defp event_color(:cancelled), do: "#9ca3af"
  defp event_color(:discarded), do: "#ef4444"
  defp event_color(_), do: "#94a3b8"

  defp event_label(:inserted), do: "inserted"
  defp event_label(:scheduled), do: "scheduled"
  defp event_label(:attempted), do: "attempted"
  defp event_label(:completed), do: "completed"
  defp event_label(:error), do: "error"
  defp event_label(:cancelled), do: "cancelled"
  defp event_label(:discarded), do: "discarded"
  defp event_label(other), do: to_string(other)

  defp connector_color(_a, %{kind: kind}) when kind in [:error, :discarded], do: "#ef4444"
  defp connector_color(_a, %{kind: :cancelled}), do: "#9ca3af"
  defp connector_color(_a, _b), do: "currentColor"

  # Like `Enum.chunk_every(list, 2, 1, :discard)` but spelled out for clarity.
  defp chunks_of_2(list) do
    list
    |> Enum.zip(Enum.drop(list, 1))
    |> Enum.map(fn {a, b} -> [a, b] end)
  end
end
