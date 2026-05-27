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

  # Returns true when every series in the chart consists exclusively of
  # zero values. Drives the "no activity yet" hint underneath the
  # otherwise-empty flat line.
  defp chart_all_zero?(series) when is_list(series) do
    Enum.all?(series, fn s -> Enum.all?(s.values, &(&1 == 0)) end)
  end

  defp chart_all_zero?(_), do: true

  # Builds a deep-link into the jobs list with a pre-applied filter.
  # Honours the multi-instance URL prefix so clicking a tile on a
  # secondary instance's dashboard keeps you on that instance.
  defp jobs_filter_path(base_path, active_oban, oban_names, query) do
    prefix = if length(oban_names) > 1, do: "/i/#{active_oban}", else: ""
    base_path <> prefix <> "/jobs?" <> URI.encode_query(query)
  end

  defp format_bucket(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M")
      _ -> ""
    end
  end

  defp pubsub, do: ObanUI.Config.fetch!().pubsub

  # Wraps a stats / query call. On any failure the caller gets `default`
  # back AND we log the stacktrace at warning level so the underlying
  # issue is discoverable from `heroku logs --tail` instead of silently
  # collapsing the dashboard. We swallow the error rather than re-raising
  # because a single broken widget shouldn't take down the whole page.
  defp safe(fun, default) do
    fun.()
  rescue
    error ->
      require Logger

      Logger.warning(
        "ObanUI.Web.DashboardLive widget failed; using default. " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      default
  catch
    kind, reason ->
      require Logger

      Logger.warning("ObanUI.Web.DashboardLive widget caught #{inspect(kind)} #{inspect(reason)}")

      default
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
        <.link
          :for={state <- ~w(available executing scheduled retryable completed cancelled discarded)}
          navigate={jobs_filter_path(@base_path, @active_oban, @oban_names, %{"state" => state})}
          class="oban-ui-card block hover:ring-2 hover:ring-oban-400 transition"
          title={"Show #{state} jobs"}
        >
          <p class="text-xs uppercase text-slate-500">{state}</p>
          <p class="text-2xl font-semibold">{Map.get(@counts, state, 0)}</p>
        </.link>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <.card class="lg:col-span-2">
          <p class="text-sm font-medium mb-2">Throughput · {@range}</p>
          <%!--
            Render the chart whenever we have at least the zero-filled
            timeline. A flat-line "no activity" chart is more informative
            than a blank empty-state — it makes clear the page is wired up
            and the recorder is alive, just nothing to show yet. The
            empty-state only fires for the genuinely catastrophic case
            where the throughput call itself failed.
          --%>
          <Chart.render
            :if={@chart_series != []}
            series={@chart_series}
            labels={@chart_labels}
            stacked={true}
          />
          <p
            :if={@chart_series != [] and chart_all_zero?(@chart_series)}
            class="text-xs text-slate-500 mt-1"
          >
            No job completions yet in this window. Once jobs run, this chart fills up.
          </p>
          <EmptyState.render :if={@chart_series == []} title="Throughput data unavailable">
            The throughput call raised — check the application log for the
            stack trace. The Stats recorder might not be running, or the
            ETS table was reset.
          </EmptyState.render>
        </.card>

        <.card>
          <p class="text-sm font-medium mb-2">Success rate</p>
          <p class="text-3xl font-semibold">{success_rate_display(@success_rate)}</p>
        </.card>

        <.card>
          <p class="text-sm font-medium mb-2">Top workers</p>
          <ul class="text-sm space-y-1">
            <li :for={w <- @top_workers}>
              <.link
                navigate={
                  jobs_filter_path(@base_path, @active_oban, @oban_names, %{"worker" => w.worker})
                }
                class="flex justify-between rounded px-1 -mx-1 hover:bg-slate-100"
                title={"Show jobs for #{w.worker}"}
              >
                <span class="font-mono truncate">{w.worker}</span>
                <span class="text-slate-500">{w.count}</span>
              </.link>
            </li>
            <li :if={@top_workers == []} class="text-xs text-slate-500">No data yet.</li>
          </ul>
        </.card>

        <.card>
          <p class="text-sm font-medium mb-2">Top queues</p>
          <ul class="text-sm space-y-1">
            <li :for={q <- @top_queues}>
              <.link
                navigate={
                  jobs_filter_path(@base_path, @active_oban, @oban_names, %{"queue" => q.queue})
                }
                class="flex justify-between rounded px-1 -mx-1 hover:bg-slate-100"
                title={"Show jobs in #{q.queue}"}
              >
                <span class="font-mono">{q.queue}</span>
                <span class="text-slate-500">{q.count}</span>
              </.link>
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
