defmodule ObanUI.Web.QueuesLive do
  @moduledoc """
  Queues list and detail with pause/resume/scale controls.
  """

  use Phoenix.LiveView, layout: false

  import ObanUI.Web.Components.Core
  import ObanUI.Web.Components.Layout, only: [shell: 1]

  alias ObanUI.{Notifier, Queues}
  alias ObanUI.Queries.Queues, as: QueuesQuery

  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(pubsub(), Notifier.topic({:queues, socket.assigns.active_oban}))
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Queues")
     |> assign(:summaries, [])
     |> assign(:selected, nil)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :selected, params["name"])}
  end

  @impl true
  def handle_info({:tick, _buf}, socket), do: {:noreply, load(socket)}
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, load(socket)}
  end
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("pause", %{"queue" => queue}, socket) do
    do_action(socket, &Queues.pause/3, queue, %{action: :pause})
  end

  def handle_event("resume", %{"queue" => queue}, socket) do
    do_action(socket, &Queues.resume/3, queue, %{action: :resume})
  end

  def handle_event("scale", %{"queue" => queue, "limit" => limit}, socket) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 ->
        actor = %{access: socket.assigns.access, user: socket.assigns.current_user}

        case Queues.scale(actor, queue, n, oban_name: socket.assigns.active_oban) do
          :ok -> {:noreply, load(socket) |> put_flash(:info, "scaled #{queue} to #{n}")}
          {:error, reason} -> {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid limit")}
    end
  end

  def handle_event("switch_instance", %{"value" => name}, socket) do
    case Enum.find(socket.assigns.oban_names, &(to_string(&1) == name)) do
      nil -> {:noreply, socket}
      atom -> {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/i/#{atom}/queues")}
    end
  end

  defp do_action(socket, fun, queue, _meta) do
    actor = %{access: socket.assigns.access, user: socket.assigns.current_user}

    case fun.(actor, queue, oban_name: socket.assigns.active_oban) do
      :ok -> {:noreply, load(socket) |> put_flash(:info, "#{queue}: ok")}
      {:error, :forbidden} -> {:noreply, put_flash(socket, :error, "Not permitted")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp load(socket) do
    summaries =
      try do
        QueuesQuery.summaries(socket.assigns.active_oban)
      rescue
        _ -> []
      end

    assign(socket, :summaries, summaries)
  end

  defp pubsub, do: ObanUI.Config.fetch!().pubsub

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      base_path={@base_path}
      active={:queues}
      oban_names={@oban_names}
      active_oban={@active_oban}
      user_display={@user_display}
    >
      <.page_header title="Queues" />

      <div :if={Phoenix.Flash.get(@flash, :info)} class="rounded-md bg-emerald-50 text-emerald-800 px-3 py-2 mb-3">
        {Phoenix.Flash.get(@flash, :info)}
      </div>
      <div :if={Phoenix.Flash.get(@flash, :error)} class="rounded-md bg-red-50 text-red-800 px-3 py-2 mb-3">
        {Phoenix.Flash.get(@flash, :error)}
      </div>

      <p :if={@summaries == []} class="text-sm text-slate-500">No queues configured.</p>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
        <.card :for={q <- @summaries}>
          <header class="flex items-start justify-between">
            <div>
              <p class="text-sm font-mono">{q.name}</p>
              <p class="text-xs text-slate-500">
                limit {q.limit || "?"} · {if q.paused, do: "paused", else: "running"}
              </p>
            </div>
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

          <div class="mt-3 flex gap-2 items-center">
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
              <.button variant="secondary" type="submit" can?={@access.scale_queues}>
                Scale
              </.button>
            </form>
          </div>
        </.card>
      </div>
    </.shell>
    """
  end
end
