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
    <div
      class="oban-ui-layout"
      id="oban-ui-shell"
      phx-hook="KeyboardShortcuts"
      data-base-path={@base_path}
    >
      <aside class="oban-ui-sidebar" aria-label="Primary navigation">
        <div class="px-2 py-3 mb-4 border-b border-oban-800">
          <p class="text-sm font-semibold tracking-wide">Oban UI</p>
          <p :if={@active_oban} class="text-xs text-slate-400 font-mono mt-1">{@active_oban}</p>
        </div>

        <nav class="flex-1 space-y-1" aria-label="Sections">
          <.nav_link path={@base_path <> "/"} label="Dashboard" active={@active == :dashboard} />
          <.nav_link path={@base_path <> "/jobs"} label="Jobs" active={@active == :jobs} />
          <.nav_link path={@base_path <> "/queues"} label="Queues" active={@active == :queues} />
          <.nav_link path={@base_path <> "/crons"} label="Crons" active={@active == :crons} />
        </nav>

        <p class="mt-4 px-3 text-xs text-slate-400">
          <span aria-hidden="true">⌨</span>
          <span class="sr-only">Keyboard shortcuts:</span>
          / search · g+j jobs · g+q queues · esc close
        </p>
      </aside>

      <div class="oban-ui-main">
        <div class="oban-ui-topbar" role="toolbar" aria-label="Account & instance">
          <div class="text-sm flex items-center gap-3">
            <.instance_picker
              :if={length(@oban_names) > 1}
              names={@oban_names}
              active={@active_oban}
            />
            <span
              :if={@user_display && @user_display.name not in [nil, "", "anonymous"]}
              class="text-slate-500"
            >
              {@user_display.name}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <.theme_toggle />
          </div>
        </div>
        <main class="oban-ui-content" id="oban-ui-main" tabindex="-1">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  attr :names, :list, required: true
  attr :active, :atom, required: true

  defp instance_picker(assigns) do
    ~H"""
    <label class="flex items-center gap-1 text-xs text-slate-500">
      <span>Instance</span>
      <select
        class="oban-ui-input text-xs py-1 leading-tight"
        phx-change="switch_instance"
        aria-label="Active Oban instance"
      >
        <option :for={name <- @names} value={name} selected={name == @active}>{name}</option>
      </select>
    </label>
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
