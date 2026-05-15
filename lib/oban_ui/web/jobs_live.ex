defmodule ObanUI.Web.JobsLive do
  @moduledoc """
  Jobs list + detail drawer. Streams keep the table efficient even with high
  insert rates; live updates arrive via `ObanUI.Notifier` ticks and trigger a
  re-query (not a per-event payload merge).
  """

  use Phoenix.LiveView, layout: false

  import ObanUI.Web.Components.Core
  import ObanUI.Web.Components.Layout, only: [shell: 1]

  alias ObanUI.{Jobs, Notifier}
  alias ObanUI.Queries.Jobs, as: JobsQuery

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(pubsub(), Notifier.topic({:jobs, socket.assigns.active_oban}))
    end

    socket =
      socket
      |> assign(:page_title, "Jobs")
      |> assign(:counts, %{})
      |> assign(:filters, %{})
      |> assign(:cursor, nil)
      |> assign(:next_cursor, nil)
      |> assign(:selected_job, nil)
      |> stream(:jobs, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:live_action, socket.assigns.live_action)
      |> load_jobs()
      |> maybe_load_detail(params)

    {:noreply, socket}
  end

  defp parse_filters(params) do
    %{}
    |> maybe_put(:states, split_param(params["state"]))
    |> maybe_put(:queues, split_param(params["queue"]))
    |> maybe_put(:workers, split_param(params["worker"]))
    |> maybe_put(:tags, split_param(params["tags"]))
    |> maybe_put(:search, present(params["q"]))
  end

  defp split_param(nil), do: nil
  defp split_param(""), do: nil
  defp split_param(value) when is_binary(value), do: String.split(value, ",", trim: true)

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp load_jobs(socket) do
    {jobs, %{next_cursor: next}} =
      JobsQuery.list(socket.assigns.filters, page_size: @page_size)

    counts =
      try do
        JobsQuery.count_by_state(socket.assigns.filters)
      rescue
        _ -> %{}
      end

    socket
    |> stream(:jobs, jobs, reset: true)
    |> assign(:counts, counts)
    |> assign(:next_cursor, next)
  end

  defp maybe_load_detail(%{assigns: %{live_action: :show}} = socket, %{"id" => id}) do
    case Integer.parse(id) do
      {int_id, ""} -> assign(socket, :selected_job, JobsQuery.get(int_id))
      _ -> assign(socket, :selected_job, nil)
    end
  end

  defp maybe_load_detail(socket, _params), do: assign(socket, :selected_job, nil)

  @impl true
  def handle_info({:tick, _buffer}, socket) do
    # Throttle: reload only if no pending throttle is in-flight.
    if socket.assigns[:reload_pending] do
      {:noreply, socket}
    else
      Process.send_after(self(), :reload_now, 200)
      {:noreply, assign(socket, :reload_pending, true)}
    end
  end

  def handle_info(:reload_now, socket) do
    {:noreply,
     socket
     |> assign(:reload_pending, false)
     |> load_jobs()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    query = build_query(params)
    {:noreply, push_patch(socket, to: jobs_path(socket, query))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: jobs_path(socket, %{}))}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    handle_action(socket, :retry, id)
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    handle_action(socket, :cancel, id)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    handle_action(socket, :delete, id)
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, push_patch(socket, to: jobs_path(socket, build_query_from_filters(socket)))}
  end

  def handle_event("switch_instance", %{"value" => name}, socket) do
    case Enum.find(socket.assigns.oban_names, &(to_string(&1) == name)) do
      nil -> {:noreply, socket}
      atom -> {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/i/#{atom}/jobs")}
    end
  end

  defp handle_action(socket, action, id_str) do
    actor = %{access: socket.assigns.access, user: socket.assigns.current_user}
    id = String.to_integer(id_str)

    fun =
      case action do
        :retry -> &Jobs.retry/3
        :cancel -> &Jobs.cancel/3
        :delete -> &Jobs.delete/3
      end

    case fun.(actor, id, socket.assigns.active_oban) do
      {:ok, _result} ->
        {:noreply, load_jobs(socket) |> put_flash(:info, "#{action} ok")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Not permitted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp build_query(params) do
    params
    |> Map.take(~w(state queue worker tags q))
    |> Enum.reject(fn {_k, v} -> v == "" or v == nil end)
    |> Map.new()
  end

  defp build_query_from_filters(socket) do
    Enum.into(socket.assigns.filters, %{}, fn
      {:states, list} -> {"state", Enum.join(list, ",")}
      {:queues, list} -> {"queue", Enum.join(list, ",")}
      {:workers, list} -> {"worker", Enum.join(list, ",")}
      {:tags, list} -> {"tags", Enum.join(list, ",")}
      {:search, value} -> {"q", value}
    end)
  end

  defp jobs_path(socket, query) do
    base = socket.assigns.base_path
    instance_prefix = if length(socket.assigns.oban_names) > 1, do: "/i/#{socket.assigns.active_oban}", else: ""
    path = base <> instance_prefix <> "/jobs"
    if map_size(query) == 0, do: path, else: path <> "?" <> URI.encode_query(query)
  end

  defp pubsub, do: ObanUI.Config.fetch!().pubsub

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      base_path={@base_path}
      active={:jobs}
      oban_names={@oban_names}
      active_oban={@active_oban}
      user_display={@user_display}
    >
      <.page_header title="Jobs">
        <:actions>
          <.button can?={true} phx-click="clear_filters">Clear filters</.button>
        </:actions>
      </.page_header>

      <.flash_bar flash={@flash} />

      <form phx-change="filter" class="grid grid-cols-1 sm:grid-cols-5 gap-2 mb-4">
        <select name="state" class="oban-ui-input">
          <option value="">All states</option>
          <option :for={s <- JobsQuery.states()} value={s} selected={s in (@filters[:states] || [])}>
            {s} ({Map.get(@counts, s, 0)})
          </option>
        </select>
        <input
          name="queue"
          class="oban-ui-input"
          placeholder="queue"
          value={join_list(@filters[:queues])}
        />
        <input
          name="worker"
          class="oban-ui-input"
          placeholder="worker"
          value={join_list(@filters[:workers])}
        />
        <input
          name="tags"
          class="oban-ui-input"
          placeholder="tags (comma)"
          value={join_list(@filters[:tags])}
        />
        <input
          name="q"
          class="oban-ui-input"
          placeholder="search args.path:value"
          value={@filters[:search]}
        />
      </form>

      <table class="oban-ui-table">
        <thead>
          <tr>
            <th>ID</th>
            <th>State</th>
            <th>Queue</th>
            <th>Worker</th>
            <th>Attempt</th>
            <th>Inserted</th>
            <th class="text-right">Actions</th>
          </tr>
        </thead>
        <tbody id="jobs" phx-update="stream">
          <tr :for={{dom_id, job} <- @streams.jobs} id={dom_id}>
            <td class="font-mono">
              <.link patch={detail_path(@socket, @base_path, @oban_names, @active_oban, job.id)}>
                {job.id}
              </.link>
            </td>
            <td><.state_badge state={job.state} /></td>
            <td>{job.queue}</td>
            <td class="font-mono text-xs">{job.worker}</td>
            <td>{job.attempt}/{job.max_attempts}</td>
            <td><.relative_time datetime={job.inserted_at} /></td>
            <td class="text-right space-x-1">
              <.button
                variant="secondary"
                can?={@access.retry_jobs and job.state in ~w(cancelled discarded retryable scheduled completed)}
                phx-click="retry"
                phx-value-id={job.id}
              >Retry</.button>
              <.button
                variant="secondary"
                can?={@access.cancel_jobs and job.state in ~w(available scheduled executing retryable)}
                phx-click="cancel"
                phx-value-id={job.id}
                data-confirm="Cancel this job?"
              >Cancel</.button>
              <.button
                variant="danger"
                can?={@access.delete_jobs}
                phx-click="delete"
                phx-value-id={job.id}
                data-confirm="Permanently delete this job?"
              >Delete</.button>
            </td>
          </tr>
        </tbody>
      </table>

      <.detail_drawer
        :if={@live_action == :show and @selected_job}
        job={@selected_job}
        resolver={@resolver}
        access={@access}
      />
    </.shell>
    """
  end

  defp join_list(nil), do: ""
  defp join_list(list) when is_list(list), do: Enum.join(list, ",")

  defp detail_path(_socket, base, oban_names, active_oban, id) do
    instance_prefix = if length(oban_names) > 1, do: "/i/#{active_oban}", else: ""
    "#{base}#{instance_prefix}/jobs/#{id}"
  end

  defp flash_bar(assigns) do
    ~H"""
    <div :if={Phoenix.Flash.get(@flash, :error)} class="rounded-md bg-red-50 text-red-800 px-3 py-2 mb-3">
      {Phoenix.Flash.get(@flash, :error)}
    </div>
    <div :if={Phoenix.Flash.get(@flash, :info)} class="rounded-md bg-emerald-50 text-emerald-800 px-3 py-2 mb-3">
      {Phoenix.Flash.get(@flash, :info)}
    </div>
    """
  end

  attr :job, :map, required: true
  attr :resolver, :atom, required: true
  attr :access, :map, required: true

  defp detail_drawer(assigns) do
    formatted_args =
      if function_exported?(assigns.resolver, :format_job_args, 1) do
        assigns.resolver.format_job_args(assigns.job.args)
      else
        assigns.job.args
      end

    formatted_meta =
      if function_exported?(assigns.resolver, :format_job_meta, 1) do
        assigns.resolver.format_job_meta(assigns.job.meta)
      else
        assigns.job.meta
      end

    assigns =
      assigns
      |> assign(:formatted_args, formatted_args)
      |> assign(:formatted_meta, formatted_meta)

    ~H"""
    <aside class="oban-ui-drawer p-5">
      <div class="flex items-start justify-between mb-3">
        <div>
          <p class="text-xs text-slate-500">Job #{@job.id}</p>
          <h2 class="text-lg font-semibold">{@job.worker}</h2>
          <p class="text-xs text-slate-500">
            <.state_badge state={@job.state} /> · {@job.queue} · attempt {@job.attempt}/{@job.max_attempts}
          </p>
        </div>
        <button
          type="button"
          class="oban-ui-btn-secondary"
          phx-click="close_detail"
          aria-label="Close"
        >×</button>
      </div>

      <section class="mb-4">
        <h3 class="text-sm font-medium mb-1">Args</h3>
        <.pre content={@formatted_args} />
      </section>

      <section class="mb-4" :if={@formatted_meta not in [nil, %{}, %{"_" => nil}]}>
        <h3 class="text-sm font-medium mb-1">Meta</h3>
        <.pre content={@formatted_meta} />
      </section>

      <section class="mb-4">
        <h3 class="text-sm font-medium mb-1">Timeline</h3>
        <ul class="text-xs space-y-1">
          <li><strong>Inserted</strong>: <.relative_time datetime={@job.inserted_at} /></li>
          <li><strong>Scheduled</strong>: <.relative_time datetime={@job.scheduled_at} /></li>
          <li><strong>Attempted</strong>: <.relative_time datetime={@job.attempted_at} /></li>
          <li><strong>Completed</strong>: <.relative_time datetime={@job.completed_at} /></li>
          <li><strong>Cancelled</strong>: <.relative_time datetime={@job.cancelled_at} /></li>
          <li><strong>Discarded</strong>: <.relative_time datetime={@job.discarded_at} /></li>
        </ul>
      </section>

      <section :if={@job.errors not in [nil, []]} class="mb-4">
        <h3 class="text-sm font-medium mb-1">Errors</h3>
        <div :for={{error, idx} <- Enum.with_index(@job.errors)} class="mb-2">
          <p class="text-xs text-slate-500">Attempt {idx + 1} · {Map.get(error, "at")}</p>
          <.pre content={Map.get(error, "error") || error} />
        </div>
      </section>

      <section class="border-t border-slate-200 pt-3 flex gap-2">
        <.button
          variant="primary"
          can?={@access.retry_jobs}
          phx-click="retry"
          phx-value-id={@job.id}
        >Retry</.button>
        <.button
          variant="secondary"
          can?={@access.cancel_jobs}
          phx-click="cancel"
          phx-value-id={@job.id}
          data-confirm="Cancel this job?"
        >Cancel</.button>
        <.button
          variant="danger"
          can?={@access.delete_jobs}
          phx-click="delete"
          phx-value-id={@job.id}
          data-confirm="Permanently delete this job?"
        >Delete</.button>
      </section>
    </aside>
    """
  end
end
