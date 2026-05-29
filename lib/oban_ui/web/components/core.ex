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
  Inline SVG icon set used by the sidebar nav and action menus. Heroicons-
  style outline glyphs, sized via the `class` attr (default 1.25rem square).
  """
  attr :name, :string,
    required: true,
    values: ~w(dashboard jobs queues crons kebab sidebar)

  attr :class, :string, default: "w-5 h-5"

  def icon(assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      {Phoenix.HTML.raw(icon_paths(@name))}
    </svg>
    """
  end

  # squares-2x2
  defp icon_paths("dashboard"),
    do:
      ~s(<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>)

  # list-bullet
  defp icon_paths("jobs"),
    do:
      ~s(<line x1="8" y1="6" x2="20" y2="6"/><line x1="8" y1="12" x2="20" y2="12"/><line x1="8" y1="18" x2="20" y2="18"/><circle cx="4" cy="6" r="1"/><circle cx="4" cy="12" r="1"/><circle cx="4" cy="18" r="1"/>)

  # rectangle-stack
  defp icon_paths("queues"),
    do:
      ~s(<rect x="3" y="4" width="18" height="5" rx="1"/><rect x="3" y="11" width="18" height="5" rx="1"/><path d="M5 18h14"/>)

  # clock
  defp icon_paths("crons"),
    do: ~s(<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>)

  # ellipsis-vertical
  defp icon_paths("kebab"),
    do:
      ~s(<circle cx="12" cy="5" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="12" cy="19" r="1.4"/>)

  # bars-3 (hamburger / collapse toggle)
  defp icon_paths("sidebar"),
    do:
      ~s(<line x1="4" y1="6" x2="20" y2="6"/><line x1="4" y1="12" x2="20" y2="12"/><line x1="4" y1="18" x2="20" y2="18"/>)

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
  A kebab (⋮) trigger that toggles a dropdown of actions. Saves horizontal
  space versus a row of buttons.

  `id` must be unique on the page (e.g. include the job id). The dropdown
  closes on outside-click via `phx-click-away` and on item-click via
  JS.hide. Pass the menu items in the inner block — typically `menu_item/1`.
  """
  attr :id, :string, required: true
  attr :label, :string, default: "Actions"
  slot :inner_block, required: true

  def kebab_menu(assigns) do
    ~H"""
    <div class="relative inline-block text-left" id={@id <> "-wrap"} phx-hook="KebabMenu">
      <button
        type="button"
        class="oban-ui-kebab-trigger"
        data-kebab-trigger=""
        aria-haspopup="true"
        aria-label={@label}
      >
        <.icon name="kebab" class="w-5 h-5" />
      </button>
      <div id={@id} class="oban-ui-kebab-menu hidden" data-kebab-menu="" role="menu">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  A single item inside a `kebab_menu/1`. Renders as a full-width button.
  Disabled when `can?` is false (with a tooltip reason).
  """
  attr :variant, :string, default: "default", values: ~w(default danger)
  attr :can?, :boolean, default: true
  attr :reason, :string, default: "Insufficient permissions"
  attr :rest, :global, include: ~w(phx-click phx-value-id data-confirm)
  slot :inner_block, required: true

  def menu_item(assigns) do
    ~H"""
    <button
      type="button"
      role="menuitem"
      class={["oban-ui-menu-item", @variant == "danger" && "oban-ui-menu-item-danger"]}
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

  # Negative diff = the timestamp is in the future (e.g. a scheduled job's
  # next run time). Format it as "in 12m" rather than a bare "ago".
  defp format_diff(diff) when diff < 0, do: format_future(-diff)
  defp format_diff(diff) when diff < 60, do: "#{diff}s ago"
  defp format_diff(diff) when diff < 3600, do: "#{div(diff, 60)}m ago"
  defp format_diff(diff) when diff < 86_400, do: "#{div(diff, 3600)}h ago"
  defp format_diff(diff), do: "#{div(diff, 86_400)}d ago"

  defp format_future(diff) when diff < 60, do: "in #{diff}s"
  defp format_future(diff) when diff < 3600, do: "in #{div(diff, 60)}m"
  defp format_future(diff) when diff < 86_400, do: "in #{div(diff, 3600)}h"
  defp format_future(diff), do: "in #{div(diff, 86_400)}d"
end
