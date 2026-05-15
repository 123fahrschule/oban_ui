defmodule ObanUI.Web.Components.Layout do
  @moduledoc """
  Sidebar/topbar shell shared by every ObanUI LiveView.
  """

  use Phoenix.Component

  import ObanUI.Web.Components.Core, only: [theme_toggle: 1]

  attr :base_path, :string, required: true
  attr :active, :atom, required: true, values: ~w(dashboard jobs queues crons)a
  attr :oban_names, :list, required: true
  attr :active_oban, :atom, required: true
  attr :user_display, :map, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="oban-ui-layout">
      <aside class="oban-ui-sidebar">
        <div class="px-2 py-3 mb-4 border-b border-oban-800">
          <p class="text-sm font-semibold tracking-wide">Oban UI</p>
        </div>

        <nav class="flex-1 space-y-1">
          <.nav_link path={@base_path <> "/"} label="Dashboard" active={@active == :dashboard} />
          <.nav_link path={@base_path <> "/jobs"} label="Jobs" active={@active == :jobs} />
          <.nav_link path={@base_path <> "/queues"} label="Queues" active={@active == :queues} />
          <.nav_link path={@base_path <> "/crons"} label="Crons" active={@active == :crons} />
        </nav>

        <div :if={length(@oban_names) > 1} class="mt-4 pt-3 border-t border-oban-800">
          <p class="text-xs uppercase text-slate-400 mb-1 px-3">Instance</p>
          <select
            class="oban-ui-input bg-oban-800 border-oban-700 text-slate-100 text-xs"
            phx-change="switch_instance"
          >
            <option :for={name <- @oban_names} value={name} selected={name == @active_oban}>
              {name}
            </option>
          </select>
        </div>
      </aside>

      <div class="oban-ui-main">
        <div class="oban-ui-topbar">
          <div class="text-sm text-slate-500">
            <span :if={@user_display}>{@user_display.name}</span>
          </div>
          <div class="flex items-center gap-2">
            <.theme_toggle />
          </div>
        </div>
        <main class="oban-ui-content">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class="oban-ui-nav-link"
      aria-current={if @active, do: "page", else: nil}
    >
      {@label}
    </.link>
    """
  end
end
