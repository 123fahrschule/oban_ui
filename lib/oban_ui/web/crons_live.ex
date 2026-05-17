defmodule ObanUI.Web.CronsLive do
  @moduledoc """
  Read-only cron overview. Lists static cron entries configured in
  `Oban.Plugins.Cron` along with each entry's next scheduled run (computed
  by `ObanUI.Crons.Parser`) and the most recent observed execution from
  `oban_jobs`.
  """

  use Phoenix.LiveView, layout: false

  import ObanUI.Web.Components.Core
  import ObanUI.Web.Components.Layout, only: [shell: 1]

  alias ObanUI.Queries.Crons
  alias ObanUI.Web.Components.EmptyState

  @refresh_ms 30_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Crons")
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("switch_instance", %{"value" => name}, socket) do
    case Enum.find(socket.assigns.oban_names, &(to_string(&1) == name)) do
      nil -> {:noreply, socket}
      atom -> {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/i/#{atom}/crons")}
    end
  end

  defp load(socket) do
    crons =
      try do
        Crons.list(socket.assigns.active_oban)
      rescue
        _ -> []
      end

    assign(socket, :crons, crons)
  end

  @impl Phoenix.LiveView
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

      <EmptyState.render :if={@crons == []} title="No cron entries configured.">
        Add <code class="font-mono">Oban.Plugins.Cron</code>
        with a <code class="font-mono">:crontab</code>
        list to your Oban supervisor and they
        will show up here on the next refresh.
      </EmptyState.render>

      <table :if={@crons != []} class="oban-ui-table">
        <thead>
          <tr>
            <th>Expression</th>
            <th>Description</th>
            <th>Worker</th>
            <th>Next run</th>
            <th>Last run</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={cron <- @crons}>
            <td class="font-mono">{cron.expression}</td>
            <td class="text-xs text-slate-500">{cron.description}</td>
            <td class="font-mono text-xs">{cron.worker}</td>
            <td>
              <%= if cron.next_run_at do %>
                <time
                  datetime={DateTime.to_iso8601(cron.next_run_at)}
                  title={DateTime.to_iso8601(cron.next_run_at)}
                >
                  in {countdown(cron.next_run_at)}
                </time>
              <% else %>
                —
              <% end %>
            </td>
            <td><.relative_time datetime={cron.last_run_at} /></td>
          </tr>
        </tbody>
      </table>
    </.shell>
    """
  end

  defp countdown(%DateTime{} = dt) do
    diff = DateTime.diff(dt, DateTime.utc_now(), :second)

    cond do
      diff < 0 -> "now"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
      true -> "#{div(diff, 86_400)}d"
    end
  end
end
