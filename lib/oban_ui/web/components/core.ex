defmodule ObanUI.Web.Components.Core do
  @moduledoc """
  Stateless components used across ObanUI LiveViews.
  """

  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  @doc """
  State badge — small colored pill labelled with the state name.
  """
  attr :state, :string, required: true
  attr :class, :string, default: nil

  def state_badge(assigns) do
    ~H"""
    <span class={["oban-ui-badge", @class]} data-state={@state}>{@state}</span>
    """
  end

  @doc """
  Primary, secondary, or danger button.

  When `can?` is `false`, renders disabled with a tooltip.
  """
  attr :variant, :string, default: "secondary", values: ~w(primary secondary danger)
  attr :type, :string, default: "button"
  attr :can?, :boolean, default: true
  attr :reason, :string, default: "Insufficient permissions"
  attr :rest, :global, include: ~w(phx-click phx-target phx-disable-with data-confirm name value)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={["oban-ui-btn-#{@variant}"]}
      disabled={!@can?}
      aria-disabled={!@can?}
      title={if @can?, do: nil, else: @reason}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Page header bar with a title slot and optional actions slot.
  """
  attr :title, :string, required: true
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="flex items-center justify-between mb-4">
      <h1 class="text-xl font-semibold">{@title}</h1>
      <div class="flex items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  Card container.
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["oban-ui-card", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Pre-formatted block for args/errors. Accepts string or `Inspect`-able term.
  """
  attr :content, :any, required: true
  attr :class, :string, default: nil

  def pre(assigns) do
    assigns =
      assign_new(assigns, :rendered, fn ->
        case assigns.content do
          binary when is_binary(binary) -> binary
          other -> inspect(other, pretty: true, limit: :infinity, printable_limit: :infinity)
        end
      end)

    ~H"""
    <pre class={["oban-ui-pre", @class]}><code>{@rendered}</code></pre>
    """
  end

  @doc """
  Inline sparkline. Pass a list of numbers via `data`.
  """
  attr :data, :list, required: true
  attr :class, :string, default: "h-8 w-32 text-oban-500 inline-block"

  def sparkline(assigns) do
    series = assigns.data |> Enum.map(&to_string/1) |> Enum.join(",")
    assigns = assign(assigns, :series, series)

    ~H"""
    <span
      class={@class}
      phx-hook="Sparkline"
      data-series={@series}
      id={"sl-#{System.unique_integer([:positive])}"}
    >
    </span>
    """
  end

  @doc """
  Theme toggle button (cycles light → dark → system).
  """
  def theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="oban-ui-btn-secondary"
      phx-hook="ThemeToggle"
      id="oban-ui-theme-toggle"
      title="Toggle theme"
    >
      {raw("&#9788;")}
    </button>
    """
  end

  @doc """
  Renders human time difference like "5s ago", "3m ago".
  """
  attr :datetime, :any, required: true
  attr :nil_label, :string, default: "—"

  def relative_time(assigns) do
    ~H"""
    <time datetime={iso(@datetime)} title={iso(@datetime)}>{relative(@datetime, @nil_label)}</time>
    """
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp iso(_), do: nil

  defp relative(nil, nil_label), do: nil_label

  defp relative(%DateTime{} = dt, _) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)
    format_diff(diff)
  end

  defp relative(%NaiveDateTime{} = dt, nil_label) do
    case DateTime.from_naive(dt, "Etc/UTC") do
      {:ok, dt} -> relative(dt, nil_label)
      _ -> nil_label
    end
  end

  defp relative(_, nil_label), do: nil_label

  defp format_diff(diff) when diff < 0, do: "in the future"
  defp format_diff(diff) when diff < 60, do: "#{diff}s ago"
  defp format_diff(diff) when diff < 3600, do: "#{div(diff, 60)}m ago"
  defp format_diff(diff) when diff < 86_400, do: "#{div(diff, 3600)}h ago"
  defp format_diff(diff), do: "#{div(diff, 86_400)}d ago"
end
