defmodule ObanUI.Web.DashboardLive do
  @moduledoc """
  Overview page.

  Renders:

    * State counts (one card per Oban state)
    * Multi-series throughput chart (success / failure / discard) over a
      configurable time range
    * Rolling success rate
    * Top workers and top queues

  The time-range selector picks a window and an appropriate bucket-sample
  density so the chart stays readable regardless of zoom level. Data comes
  from `ObanUI.Stats.Store` (in-memory ETS).
  """

  use Phoenix.LiveView, layout: false

  import ObanUI.Web.Components.Core
  import ObanUI.Web.Components.Layout, only: [shell: 1]

  alias ObanUI.{Notifier, Stats}
  alias ObanUI.Queries.Jobs, as: JobsQuery
  alias ObanUI.Web.Components.{Chart, EmptyState}

  @refresh_ms 5_000
  @ranges %{
    "1h" => 3_600,
    "6h" => 21_600,
    "24h" => 86_400,
    "7d" => 604_800
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok =
        Phoenix.PubSub.subscribe(
          pubsub(),
          Notifier.topic({:overview, socket.assigns.active_oban})
        )

      Process.send_after(self(), :periodic_refresh, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:range, "1h")
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:range, params["range"] || "1h")
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info({:tick, _buffer}, socket), do: {:noreply, load(socket)}
  def handle_info(:leader_changed, socket), do: {:noreply, load(socket)}

  def handle_info(:periodic_refresh, socket) do
    Process.send_after(self(), :periodic_refresh, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("set_range", %{"range" => range}, socket)
      when is_map_key(@ranges, range) do
    {:noreply,
     push_patch(socket,
       to: socket.assigns.base_path <> "/?" <> URI.encode_query(%{"range" => range})
     )}
  end

  def handle_event("set_range", _, socket), do: {:noreply, socket}

  def handle_event("switch_instance", %{"value" => name}, socket) do
    case Enum.find(socket.assigns.oban_names, &(to_string(&1) == name)) do
      nil -> {:noreply, socket}
      atom -> {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/i/#{atom}")}
    end
  end

  defp load(socket) do
    oban = socket.assigns.active_oban
    seconds = Map.get(@ranges, socket.assigns.range, 3600)

    counts = safe(fn -> JobsQuery.count_by_state(%{}) end, %{})
    throughput = safe(fn -> Stats.Store.throughput(oban, seconds) end, [])
    success = safe(fn -> Stats.Store.success_rate(oban, seconds) end, nil)
    workers = safe(fn -> Stats.Store.top_workers(oban, seconds, 5) end, [])
    queues = safe(fn -> Stats.Store.top_queues(oban, seconds, 5) end, [])

    {chart_series, chart_labels} = chart_data(throughput)

    socket
    |> assign(:counts, counts)
    |> assign(:chart_series, chart_series)
    |> assign(:chart_labels, chart_labels)
    |> assign(:success_rate, success)
    |> assign(:top_workers, workers)
    |> assign(:top_queues, queues)
  end

  defp chart_data([]), do: {[], []}

  defp chart_data(throughput) do
    # Downsample to ≤ 120 points so the SVG stays readable.
    sampled = downsample(throughput, 120)

    series = [
      %{label: "success", color: "#22c55e", values: Enum.map(sampled, & &1.success)},
      %{label: "failure", color: "#f59e0b", values: Enum.map(sampled, & &1.failure)},
      %{label: "discard", color: "#ef4444", values: Enum.map(sampled, & &1.discard)}
    ]

    labels =
      sampled
      |> Enum.map(& &1.bucket)
      |> Enum.map(&format_bucket/1)

    {series, labels}
  end

  defp downsample(points, max_points) when length(points) <= max_points, do: points

  defp downsample(points, max_points) do
    chunk = ceil(length(points) / max_points)

    points
    |> Enum.chunk_every(chunk)
    |> Enum.map(fn group ->
      %{
        bucket: List.last(group).bucket,
        success: Enum.sum(Enum.map(group, & &1.success)),
        failure: Enum.sum(Enum.map(group, & &1.failure)),
        discard: Enum.sum(Enum.map(group, & &1.discard))
      }
    end)
  end

  defp format_bucket(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M")
      _ -> ""
    end
  end

  defp pubsub, do: ObanUI.Config.fetch!().pubsub

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell
      base_path={@base_path}
      active={:dashboard}
      oban_names={@oban_names}
      active_oban={@active_oban}
      user_display={@user_display}
    >
      <.page_header title="Dashboard">
        <:actions>
          <.range_picker current={@range} />
        </:actions>
      </.page_header>

      <div class="grid grid-cols-2 sm:grid-cols-4 lg:grid-cols-7 gap-2 mb-4">
        <.card :for={
          state <- ~w(available executing scheduled retryable completed cancelled discarded)
        }>
          <p class="text-xs uppercase text-slate-500">{state}</p>
          <p class="text-2xl font-semibold">{Map.get(@counts, state, 0)}</p>
        </.card>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <.card class="lg:col-span-2">
          <p class="text-sm font-medium mb-2">Throughput · {@range}</p>
          <Chart.render
            :if={@chart_series != []}
            series={@chart_series}
            labels={@chart_labels}
            stacked={true}
          />
          <EmptyState.render :if={@chart_series == []} title="No throughput data yet.">
            Charts populate once jobs complete or fail. If you have just enabled
            persistence, restart your app — the dashboard will hydrate from <code class="font-mono">oban_ui_metrics</code>.
          </EmptyState.render>
        </.card>

        <.card>
          <p class="text-sm font-medium mb-2">Success rate</p>
          <p class="text-3xl font-semibold">{success_rate_display(@success_rate)}</p>
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

  attr :current, :string, required: true

  defp range_picker(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <button
        :for={range <- ~w(1h 6h 24h 7d)}
        type="button"
        phx-click="set_range"
        phx-value-range={range}
        class={[
          "oban-ui-btn-secondary",
          (range == @current && "ring-2 ring-oban-500") || ""
        ]}
      >
        {range}
      </button>
    </div>
    """
  end

  defp success_rate_display(nil), do: "—"
  defp success_rate_display(rate), do: :erlang.float_to_binary(rate * 100, decimals: 1) <> "%"
end
