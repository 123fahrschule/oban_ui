defmodule ObanUI.Web.CronsLive do
  @moduledoc """
  Read-only cron overview. Lists static cron entries configured in
  `Oban.Plugins.Cron` plus their last observed execution.
  """

  use Phoenix.LiveView, layout: false

  import ObanUI.Web.Components.Core
  import ObanUI.Web.Components.Layout, only: [shell: 1]

  alias ObanUI.Queries.Crons

  @impl true
  def mount(_params, _session, socket) do
    crons =
      try do
        Crons.list(socket.assigns.active_oban)
      rescue
        _ -> []
      end

    {:ok,
     socket
     |> assign(:page_title, "Crons")
     |> assign(:crons, crons)}
  end

  @impl true
  def handle_event("switch_instance", %{"value" => name}, socket) do
    case Enum.find(socket.assigns.oban_names, &(to_string(&1) == name)) do
      nil -> {:noreply, socket}
      atom -> {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/i/#{atom}/crons")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      base_path={@base_path}
      active={:crons}
      oban_names={@oban_names}
      active_oban={@active_oban}
      user_display={@user_display}
    >
      <.page_header title="Crons" />

      <p :if={@crons == []} class="text-sm text-slate-500">
        No cron entries configured. Add `Oban.Plugins.Cron` with a `:crontab` list
        to your Oban supervisor to see them here.
      </p>

      <table :if={@crons != []} class="oban-ui-table">
        <thead>
          <tr>
            <th>Expression</th>
            <th>Worker</th>
            <th>Last run</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={cron <- @crons}>
            <td class="font-mono">{cron.expression}</td>
            <td class="font-mono text-xs">{cron.worker}</td>
            <td><.relative_time datetime={cron.last_run_at} /></td>
          </tr>
        </tbody>
      </table>
    </.shell>
    """
  end
end
