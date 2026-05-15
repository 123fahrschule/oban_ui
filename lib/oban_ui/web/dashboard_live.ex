defmodule ObanUI.Web.DashboardLive do
  @moduledoc """
  Overview page — state counts, throughput sparkline, success rate, top
  workers and queues.
  """

  use Phoenix.LiveView, layout: false

  import ObanUI.Web.Components.Core
  import ObanUI.Web.Components.Layout, only: [shell: 1]

  alias ObanUI.Queries.Jobs, as: JobsQuery
  alias ObanUI.{Notifier, Stats}

  @refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(pubsub(), Notifier.topic({:overview, socket.assigns.active_oban}))
      Process.send_after(self(), :periodic_refresh, @refresh_ms)
    end

    {:ok, load(socket)}
  end

  @impl true
  def handle_info({:tick, _buffer}, socket), do: {:noreply, load(socket)}
  def handle_info(:leader_changed, socket), do: {:noreply, load(socket)}

  def handle_info(:periodic_refresh, socket) do
    Process.send_after(self(), :periodic_refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("switch_instance", %{"value" => name}, socket) do
    case Enum.find(socket.assigns.oban_names, &(to_string(&1) == name)) do
      nil -> {:noreply, socket}
      atom -> {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/i/#{atom}")}
    end
  end

  defp load(socket) do
    oban = socket.assigns.active_oban
    counts = safe(fn -> JobsQuery.count_by_state(%{}) end, %{})
    throughput = safe(fn -> Stats.Store.throughput(oban, 600) end, [])
    success = safe(fn -> Stats.Store.success_rate(oban, 3600) end, nil)
    workers = safe(fn -> Stats.Store.top_workers(oban, 3600, 5) end, [])
    queues = safe(fn -> Stats.Store.top_queues(oban, 3600, 5) end, [])

    socket
    |> assign(:counts, counts)
    |> assign(:throughput, Enum.map(throughput, &(&1.success + &1.failure)))
    |> assign(:success_rate, success)
    |> assign(:top_workers, workers)
    |> assign(:top_queues, queues)
  end

  defp pubsub, do: ObanUI.Config.fetch!().pubsub

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      base_path={@base_path}
      active={:dashboard}
      oban_names={@oban_names}
      active_oban={@active_oban}
      user_display={@user_display}
    >
      <.page_header title="Dashboard" />

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 mb-6">
        <.card :for={state <- ~w(available executing scheduled retryable completed cancelled discarded)}>
          <p class="text-xs uppercase text-slate-500">{state}</p>
          <p class="text-2xl font-semibold">{Map.get(@counts, state, 0)}</p>
        </.card>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <.card class="col-span-2">
          <p class="text-sm font-medium mb-2">Throughput (last 10 min)</p>
          <.sparkline data={@throughput} class="h-16 w-full text-oban-500 block" />
          <p :if={@throughput == []} class="text-xs text-slate-500 mt-1">
            No data yet — jobs need to run for stats to populate.
          </p>
        </.card>

        <.card>
          <p class="text-sm font-medium mb-2">Success rate (1h)</p>
          <p class="text-3xl font-semibold">
            {success_rate_display(@success_rate)}
          </p>
        </.card>

        <.card>
          <p class="text-sm font-medium mb-2">Top workers</p>
          <ul class="text-sm space-y-1">
            <li :for={w <- @top_workers} class="flex justify-between">
              <span class="font-mono truncate">{w.worker}</span>
              <span class="text-slate-500">{w.count}</span>
            </li>
            <li :if={@top_workers == []} class="text-xs text-slate-500">No data yet.</li>
          </ul>
        </.card>

        <.card>
          <p class="text-sm font-medium mb-2">Top queues</p>
          <ul class="text-sm space-y-1">
            <li :for={q <- @top_queues} class="flex justify-between">
              <span class="font-mono">{q.queue}</span>
              <span class="text-slate-500">{q.count}</span>
            </li>
            <li :if={@top_queues == []} class="text-xs text-slate-500">No data yet.</li>
          </ul>
        </.card>
      </div>
    </.shell>
    """
  end

  defp success_rate_display(nil), do: "—"
  defp success_rate_display(rate), do: :erlang.float_to_binary(rate * 100, decimals: 1) <> "%"
end
