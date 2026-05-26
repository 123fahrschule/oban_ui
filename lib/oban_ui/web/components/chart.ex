defmodule ObanUI.Web.Components.Chart do
  @moduledoc """
  Minimal multi-series line chart rendered as inline SVG.

  Each series is a `%{label, color, values}` map where `values` is a list of
  numbers aligned to the global x axis (no per-series x values — callers
  align). Renders an x-axis with timestamps if `labels` is provided.

  Picked over an external JS chart library on purpose: zero JS dependency,
  works through LiveView updates (server re-renders the SVG), survives
  reconnects cleanly. For a richer chart later we can add a JS-hook variant
  with the same interface.
  """

  use Phoenix.Component

  @width 720
  @height 200
  @padding_left 40
  @padding_right 8
  @padding_top 12
  @padding_bottom 28

  attr :series, :list,
    required: true,
    doc: "list of %{label: String.t(), color: String.t(), values: [number()]}"

  attr :labels, :list,
    default: [],
    doc: "x-axis labels parallel to series values; same length as :values"

  attr :stacked, :boolean, default: false
  attr :height, :integer, default: @height
  attr :class, :string, default: ""

  def render(assigns) do
    series = Enum.map(assigns.series, &normalise_series/1)

    plot_w = @width - @padding_left - @padding_right
    plot_h = assigns.height - @padding_top - @padding_bottom
    n_points = series |> Enum.map(&length(&1.values)) |> Enum.max(fn -> 0 end)
    step = if n_points > 1, do: plot_w / (n_points - 1), else: 0

    {bands, max_y} =
      if assigns.stacked do
        build_stacked_bands(series, n_points)
      else
        build_line_bands(series)
      end

    # Convert each band's value-lists into pixel polylines/polygons. A band's
    # polygon goes forward along its upper boundary then back along its lower
    # boundary, producing a non-overlapping slice — so the fills tile cleanly
    # instead of three translucent layers blending into mud.
    rendered =
      Enum.map(bands, fn band ->
        upper = to_points(band.upper, max_y, step, plot_h)
        lower = if band.lower, do: to_points(band.lower, max_y, step, plot_h), else: nil

        %{
          color: band.color,
          polygon: lower && polygon_str(upper, lower),
          line: line_str(upper)
        }
      end)

    grid_y =
      for i <- 0..4 do
        v = max_y * (4 - i) / 4
        %{y: @padding_top + plot_h * i / 4, label: round_short(v)}
      end

    assigns =
      assigns
      |> assign(:bands, rendered)
      |> assign(:grid_y, grid_y)
      |> assign(:width, @width)
      |> assign(:padding_left, @padding_left)
      |> assign(:padding_right, @padding_right)
      |> assign(:padding_top, @padding_top)
      |> assign(:plot_h, plot_h)
      |> assign(:plot_w, plot_w)
      |> assign(:n_points, n_points)

    ~H"""
    <div class={"oban-ui-chart " <> @class}>
      <svg viewBox={"0 0 #{@width} #{@height}"} width="100%" height={@height} role="img">
        <%!-- Y grid + labels --%>
        <g>
          <line
            :for={g <- @grid_y}
            x1={@padding_left}
            x2={@width - @padding_right}
            y1={g.y}
            y2={g.y}
            stroke="currentColor"
            stroke-opacity="0.1"
          />
          <text
            :for={g <- @grid_y}
            x={@padding_left - 4}
            y={g.y + 3}
            font-size="10"
            text-anchor="end"
            fill="currentColor"
            fill-opacity="0.6"
          >
            {g.label}
          </text>
        </g>

        <%!-- Series: filled band (stacked) + boundary line --%>
        <g :for={band <- @bands}>
          <polygon
            :if={band.polygon}
            points={band.polygon}
            fill={band.color}
            fill-opacity="0.7"
            stroke="none"
          />
          <polyline points={band.line} fill="none" stroke={band.color} stroke-width="1.5" />
        </g>

        <%!-- X axis line --%>
        <line
          x1={@padding_left}
          x2={@width - @padding_right}
          y1={@padding_top + @plot_h}
          y2={@padding_top + @plot_h}
          stroke="currentColor"
          stroke-opacity="0.3"
        />

        <%!-- X labels (first, middle, last) --%>
        <g :if={@labels != []}>
          <text
            x={@padding_left}
            y={@padding_top + @plot_h + 14}
            font-size="10"
            fill="currentColor"
            fill-opacity="0.6"
          >
            {List.first(@labels)}
          </text>
          <text
            x={(@padding_left + @width - @padding_right) / 2}
            y={@padding_top + @plot_h + 14}
            font-size="10"
            text-anchor="middle"
            fill="currentColor"
            fill-opacity="0.6"
          >
            {middle_label(@labels)}
          </text>
          <text
            x={@width - @padding_right}
            y={@padding_top + @plot_h + 14}
            font-size="10"
            text-anchor="end"
            fill="currentColor"
            fill-opacity="0.6"
          >
            {List.last(@labels)}
          </text>
        </g>
      </svg>

      <%!-- Legend --%>
      <div class="flex flex-wrap gap-3 text-xs mt-1">
        <span :for={s <- @series} class="inline-flex items-center gap-1">
          <span class="inline-block w-3 h-3 rounded-sm" style={"background: #{s.color}"}></span>
          {s.label}
        </span>
      </div>
    </div>
    """
  end

  defp normalise_series(s), do: Map.merge(%{values: [], color: "#3b82f6", label: "series"}, s)

  # Stacked mode: each band's lower boundary is the running cumulative of all
  # series below it, its upper boundary is that cumulative plus this series.
  # max_y is the top of the highest cumulative (the total). Returns
  # {bands, max_y} where each band has %{color, lower, upper}.
  defp build_stacked_bands(series, n_points) do
    zeros = List.duplicate(0, n_points)

    {bands, top} =
      Enum.map_reduce(series, zeros, fn s, lower ->
        vals = pad(s.values, n_points)
        upper = Enum.zip_with([lower, vals], &Enum.sum/1)
        {%{color: s.color, lower: lower, upper: upper}, upper}
      end)

    max_y = top |> Enum.max(fn -> 1 end) |> max(1)
    {bands, max_y}
  end

  # Non-stacked mode: one line per series, no fill, shared max_y.
  defp build_line_bands(series) do
    bands = Enum.map(series, fn s -> %{color: s.color, lower: nil, upper: s.values} end)

    max_y =
      series
      |> Enum.flat_map(& &1.values)
      |> Enum.max(fn -> 1 end)
      |> max(1)

    {bands, max_y}
  end

  defp pad(values, n) when length(values) >= n, do: Enum.take(values, n)
  defp pad(values, n), do: values ++ List.duplicate(0, n - length(values))

  defp to_points(values, max_y, step, plot_h) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {y, i} ->
      x = @padding_left + i * step
      y_pix = @padding_top + plot_h - y / max_y * plot_h
      {Float.round(x, 1), Float.round(y_pix, 1)}
    end)
  end

  defp line_str(points), do: Enum.map_join(points, " ", fn {x, y} -> "#{x},#{y}" end)

  defp polygon_str(upper, lower) do
    (upper ++ Enum.reverse(lower))
    |> Enum.map_join(" ", fn {x, y} -> "#{x},#{y}" end)
  end

  defp middle_label(labels) do
    Enum.at(labels, div(length(labels), 2)) || ""
  end

  # The caller always passes a float (computed via `/` from integers), so
  # we only need to handle that case. Other types would be a bug, not a
  # display problem.
  defp round_short(n) when is_float(n),
    do: n |> Float.round(0) |> trunc() |> Integer.to_string()
end
