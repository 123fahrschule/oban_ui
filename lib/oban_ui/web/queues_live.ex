defmodule ObanUI.Web.QueuesLive do
  @moduledoc """
  Queues overview + per-queue detail with operator controls.

  `:index` lists every queue ever observed (configured or DB-only) with its
  state counts, configured concurrency limit, a 5-minute throughput
  sparkline and pause/resume/scale/stop buttons.

  `:show` drills into a single queue: timeline sparkline, per-node executing
  breakdown, leader info.

  All control buttons honour the resolver's capabilities (`pause_queues`,
  `scale_queues`) and emit `[:oban_ui, :action]` telemetry. Each control
  exposes a `local_only` toggle so operators on a single node can apply
  changes without broadcasting to the rest of the cluster.
  """

  use Phoenix.LiveView, layout: false

  import ObanUI.Web.Components.Core
  import ObanUI.Web.Components.Layout, only: [shell: 1]

  alias ObanUI.{Notifier, Queues, Stats}
  alias ObanUI.Queries.Queues, as: QueuesQuery
  alias ObanUI.Web.Components.EmptyState

  @refresh_ms 3_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok =
        Phoenix.PubSub.subscribe(pubsub(), Notifier.topic({:queues, socket.assigns.active_oban}))

      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Queues")
     |> assign(:summaries, [])
     |> assign(:throughputs, %{})
     |> assign(:selected, nil)
     |> assign(:detail, nil)
     |> assign(:local_only, false)
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :selected, params["name"])
    {:noreply, maybe_load_detail(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info({:tick, _buf}, socket), do: {:noreply, load(socket) |> maybe_load_detail()}

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket) |> maybe_load_detail()}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("toggle_local", %{"value" => v}, socket) do
    {:noreply, assign(socket, :local_only, v == "true" or v == "on")}
  end

  def handle_event("pause", %{"queue" => queue}, socket),
    do: queue_action(socket, &Queues.pause/3, queue)

  def handle_event("resume", %{"queue" => queue}, socket),
    do: queue_action(socket, &Queues.resume/3, queue)

  def handle_event("stop", %{"queue" => queue}, socket),
    do: queue_action(socket, &Queues.stop/3, queue)

  def handle_event("scale", %{"queue" => queue, "limit" => limit}, socket) do
    case Integer.parse(to_string(limit)) do
      {n, ""} when n > 0 ->
        actor = actor(socket)

        case Queues.scale(actor, queue, n,
               oban_name: socket.assigns.active_oban,
               local_only: socket.assigns.local_only
             ) do
          :ok ->
            {:noreply, socket |> load() |> put_flash(:info, "scaled #{queue} to #{n}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid limit")}
    end
  end

  def handle_event("switch_instance", %{"value" => name}, socket) do
    case Enum.find(socket.assigns.oban_names, &(to_string(&1) == name)) do
      nil ->
        {:noreply, socket}

      atom ->
        {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/i/#{atom}/queues")}
    end
  end

  defp queue_action(socket, fun, queue) do
    actor = actor(socket)

    case fun.(actor, queue,
           oban_name: socket.assigns.active_oban,
           local_only: socket.assigns.local_only
         ) do
      :ok ->
        {:noreply, socket |> load() |> put_flash(:info, "#{queue}: ok")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Not permitted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp actor(socket),
    do: %{access: socket.assigns.access, user: socket.assigns.current_user}

  defp load(socket) do
    summaries = safe(fn -> QueuesQuery.summaries(socket.assigns.active_oban) end, [])
    oban = socket.assigns.active_oban

    throughputs =
      Map.new(summaries, fn s ->
        points = Stats.Store.throughput(oban, 300, queue: s.name)
        {s.name, Enum.map(points, &(&1.success + &1.failure))}
      end)

    socket
    |> assign(:summaries, summaries)
    |> assign(:throughputs, throughputs)
  end

  defp maybe_load_detail(%{assigns: %{live_action: :show, selected: queue}} = socket)
       when is_binary(queue) do
    detail = safe(fn -> QueuesQuery.detail(socket.assigns.active_oban, queue) end, nil)

    throughput =
      Stats.Store.throughput(socket.assigns.active_oban, 1800, queue: queue)
      |> Enum.map(&(&1.success + &1.failure))

    socket
    |> assign(:detail, detail)
    |> assign(:detail_throughput, throughput)
  end

  defp maybe_load_detail(socket), do: assign(socket, :detail, nil)

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
      active={:queues}
      oban_names={@oban_names}
      active_oban={@active_oban}
      user_display={@user_display}
    >
      <%= if @live_action == :show and @detail do %>
        <.detail_view
          detail={@detail}
          throughput={@detail_throughput}
          access={@access}
          base_path={@base_path}
          local_only={@local_only}
        />
      <% else %>
        <.index_view
          summaries={@summaries}
          throughputs={@throughputs}
          access={@access}
          flash={@flash}
          local_only={@local_only}
          base_path={@base_path}
          active_oban={@active_oban}
          oban_names={@oban_names}
        />
      <% end %>
    </.shell>
    """
  end

  attr :summaries, :list, required: true
  attr :throughputs, :map, required: true
  attr :access, :map, required: true
  attr :flash, :map, required: true
  attr :local_only, :boolean, required: true
  attr :base_path, :string, required: true
  attr :active_oban, :atom, required: true
  attr :oban_names, :list, required: true

  defp index_view(assigns) do
    ~H"""
    <.page_header title="Queues">
      <:actions>
        <label class="text-sm flex items-center gap-1">
          <input
            type="checkbox"
            checked={@local_only}
            phx-click="toggle_local"
            phx-value-value={!@local_only}
          /> local-only
        </label>
      </:actions>
    </.page_header>

    <.flash_bar flash={@flash} />

    <EmptyState.render :if={@summaries == []} title="No queues yet." class="mb-4">
      Configure queues in your Oban supervisor child spec, e.g. <code class="font-mono">queues: [default: 10, mailers: 2]</code>.
    </EmptyState.render>

    <div :if={@summaries != []} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
      <.card :for={q <- @summaries}>
        <header class="flex items-start justify-between">
          <div>
            <p class="text-sm font-mono">
              <.link patch={detail_path(@base_path, @oban_names, @active_oban, q.name)}>
                {q.name}
              </.link>
            </p>
            <p class="text-xs text-slate-500">
              limit {q.limit || "?"} · {if q.paused, do: "paused", else: "running"}
            </p>
          </div>
          <.sparkline data={Map.get(@throughputs, q.name, [])} class="h-8 w-32 text-oban-500" />
        </header>

        <dl class="mt-2 grid grid-cols-4 gap-2 text-center text-xs">
          <div>
            <dt class="text-slate-500">exec</dt>
            <dd class="text-base font-semibold">{q.executing}</dd>
          </div>
          <div>
            <dt class="text-slate-500">avail</dt>
            <dd class="text-base font-semibold">{q.available}</dd>
          </div>
          <div>
            <dt class="text-slate-500">sched</dt>
            <dd class="text-base font-semibold">{q.scheduled}</dd>
          </div>
          <div>
            <dt class="text-slate-500">retry</dt>
            <dd class="text-base font-semibold">{q.retryable}</dd>
          </div>
        </dl>

        <div class="mt-3 flex flex-wrap gap-2 items-center">
          <.button
            variant="secondary"
            can?={@access.pause_queues}
            phx-click={if q.paused, do: "resume", else: "pause"}
            phx-value-queue={q.name}
          >
            {if q.paused, do: "Resume", else: "Pause"}
          </.button>

          <form phx-submit="scale" class="flex items-center gap-1">
            <input type="hidden" name="queue" value={q.name} />
            <input
              type="number"
              name="limit"
              min="1"
              value={q.limit || 1}
              class="oban-ui-input w-20"
            />
            <.button variant="secondary" type="submit" can?={@access.scale_queues}>Scale</.button>
          </form>

          <.button
            variant="danger"
            can?={@access.pause_queues}
            phx-click="stop"
            phx-value-queue={q.name}
            data-confirm={"Stop queue #{q.name}? Running jobs will drain."}
          >
            Stop
          </.button>
        </div>
      </.card>
    </div>
    """
  end

  attr :detail, :map, required: true
  attr :throughput, :list, required: true
  attr :access, :map, required: true
  attr :base_path, :string, required: true
  attr :local_only, :boolean, required: true

  defp detail_view(assigns) do
    ~H"""
    <.page_header title={"Queue: " <> @detail.summary.name}>
      <:actions>
        <.link navigate={@base_path <> "/queues"} class="oban-ui-btn-secondary">All queues</.link>
        <label class="text-sm flex items-center gap-1 ml-2">
          <input
            type="checkbox"
            checked={@local_only}
            phx-click="toggle_local"
            phx-value-value={!@local_only}
          /> local-only
        </label>
      </:actions>
    </.page_header>

    <div class="grid grid-cols-1 lg:grid-cols-3 gap-4 mb-4">
      <.card class="lg:col-span-2">
        <p class="text-sm font-medium mb-2">Throughput — last 30 min</p>
        <.sparkline data={@throughput} class="h-16 w-full block text-oban-500" />
        <p :if={@throughput == []} class="text-xs text-slate-500 mt-1">
          No completions recorded yet.
        </p>
      </.card>

      <.card>
        <p class="text-sm font-medium mb-2">Status</p>
        <ul class="text-sm space-y-1">
          <li>State: <strong>{if @detail.summary.paused, do: "paused", else: "running"}</strong></li>
          <li>Limit: <strong>{@detail.summary.limit || "n/a"}</strong></li>
          <li>Executing: <strong>{@detail.summary.executing}</strong></li>
          <li>Available: <strong>{@detail.summary.available}</strong></li>
          <li>Scheduled: <strong>{@detail.summary.scheduled}</strong></li>
          <li>Retryable: <strong>{@detail.summary.retryable}</strong></li>
        </ul>
      </.card>
    </div>

    <.card class="mb-4">
      <p class="text-sm font-medium mb-2">Per-node executing</p>
      <p :if={@detail.nodes == []} class="text-xs text-slate-500">
        No node currently executing jobs in this queue.
      </p>
      <ul class="text-sm space-y-1">
        <li :for={n <- @detail.nodes} class="flex justify-between">
          <span class="font-mono">{n.node}</span>
          <span class="text-slate-500">{n.executing}</span>
        </li>
      </ul>
    </.card>

    <.card :if={@detail.leader} class="mb-4">
      <p class="text-sm font-medium mb-2">Leader</p>
      <ul class="text-xs space-y-1">
        <li>Node: <span class="font-mono">{@detail.leader.leader}</span></li>
        <li>Expires at: {Calendar.strftime(@detail.leader.expires_at, "%Y-%m-%d %H:%M:%S")}</li>
        <li :if={@detail.leader.stale} class="text-amber-700">⚠ leader lease has expired</li>
      </ul>
    </.card>

    <div class="flex flex-wrap gap-2">
      <.button
        variant="secondary"
        can?={@access.pause_queues}
        phx-click={if @detail.summary.paused, do: "resume", else: "pause"}
        phx-value-queue={@detail.summary.name}
      >
        {if @detail.summary.paused, do: "Resume", else: "Pause"}
      </.button>

      <form phx-submit="scale" class="flex items-center gap-1">
        <input type="hidden" name="queue" value={@detail.summary.name} />
        <input
          type="number"
          name="limit"
          min="1"
          value={@detail.summary.limit || 1}
          class="oban-ui-input w-20"
        />
        <.button variant="secondary" type="submit" can?={@access.scale_queues}>Scale</.button>
      </form>

      <.button
        variant="danger"
        can?={@access.pause_queues}
        phx-click="stop"
        phx-value-queue={@detail.summary.name}
        data-confirm={"Stop queue #{@detail.summary.name}? Running jobs will drain."}
      >
        Stop
      </.button>
    </div>
    """
  end

  defp detail_path(base, oban_names, active_oban, name) do
    prefix = if length(oban_names) > 1, do: "/i/#{active_oban}", else: ""
    "#{base}#{prefix}/queues/#{name}"
  end

  defp flash_bar(assigns) do
    ~H"""
    <div aria-live="polite" aria-atomic="true">
      <div
        :if={Phoenix.Flash.get(@flash, :error)}
        role="alert"
        class="rounded-md bg-red-50 text-red-800 px-3 py-2 mb-3"
      >
        {Phoenix.Flash.get(@flash, :error)}
      </div>
      <div
        :if={Phoenix.Flash.get(@flash, :info)}
        role="status"
        class="rounded-md bg-emerald-50 text-emerald-800 px-3 py-2 mb-3"
      >
        {Phoenix.Flash.get(@flash, :info)}
      </div>
    </div>
    """
  end
end
