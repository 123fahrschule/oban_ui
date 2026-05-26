defmodule ObanUI.Web.Components.ChartTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias ObanUI.Web.Components.Chart

  defp render_chart(series, stacked) do
    assigns = %{__changed__: nil, series: series, stacked: stacked}

    rendered_to_string(~H"""
    <Chart.render series={@series} labels={["a", "b", "c"]} stacked={@stacked} />
    """)
  end

  @series [
    %{label: "success", color: "#22c55e", values: [10, 20, 5]},
    %{label: "failure", color: "#f59e0b", values: [0, 0, 0]},
    %{label: "discard", color: "#ef4444", values: [0, 1, 0]}
  ]

  test "stacked mode renders one filled polygon per series, each in its own colour" do
    html = render_chart(@series, true)

    polygons = Regex.scan(~r/<polygon[^>]*fill="(#[0-9a-fA-F]+)"/, html) |> Enum.map(&List.last/1)

    assert "#22c55e" in polygons
    assert "#f59e0b" in polygons
    assert "#ef4444" in polygons
    # Exactly three bands, no extra blending layers.
    assert length(polygons) == 3
  end

  test "stacked bands do not use translucent fill stacking (no mud)" do
    html = render_chart(@series, true)
    # Fill opacity is a single solid-ish value, not the old 0.25 blend.
    refute html =~ ~s(fill-opacity="0.25")
    assert html =~ ~s(fill-opacity="0.7")
  end

  test "non-stacked mode draws lines without fills" do
    html = render_chart(@series, false)
    refute html =~ "<polygon"
    assert html =~ "<polyline"
  end

  test "the bottom (success) band's polygon reaches the chart baseline" do
    html = render_chart(@series, true)

    # First polygon is the success band; its lower boundary is the baseline.
    # height 200 - padding_bottom 28 - padding_top 12 => plot_h 160, baseline
    # pixel = padding_top 12 + plot_h 160 = 172.
    [success_polygon] =
      Regex.run(~r/<polygon points="([^"]+)" fill="#22c55e"/, html, capture: :all_but_first)

    assert success_polygon =~ "172.0"
  end

  test "empty series doesn't crash" do
    html = render_chart([], true)
    assert is_binary(html)
  end
end
