defmodule ObanUI.Web.JobsLive do
  @moduledoc """
  Jobs list + detail drawer.

  ## URL state

  All filters and the sort directive are reflected in the query string so the
  page can be deep-linked and refreshed:

      ?state=available,executing&queue=default,media&worker=My.Worker
      &tags=billing,urgent&priority=0,1&q=args.user_id:42
      &from=2025-01-01T00:00:00Z&to=2025-01-02T00:00:00Z
      &sort=worker:asc

  Each "csv" parameter is split on commas and trimmed.

  ## Live updates

  Subscribes to `oban_ui:jobs:<instance>` and re-queries on tick, throttled
  to one reload per ~200ms. Active bulk operations also subscribe to
  `oban_ui:bulk:<ref>` for progress updates.
  """

  use Phoenix.LiveView, layout: false

  import ObanUI.Web.Components.Core
  import ObanUI.Web.Components.Layout, only: [shell: 1]

  alias ObanUI.Notifier
  alias ObanUI.Jobs.Bulk
  alias ObanUI.Jobs.Edit
  alias ObanUI.Queries.Jobs, as: JobsQuery
  alias ObanUI.Queries.Suggestions
  alias ObanUI.Web.Components.Timeline

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
      |> assign(:sort, nil)
      |> assign(:next_cursor, nil)
      |> assign(:selected_job, nil)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:bulk_state, nil)
      |> assign(:edit_form, nil)
      |> assign(:suggestions, %{worker: [], queue: [], tags: [], nodes: []})
      |> stream(:jobs, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)
    sort = parse_sort(params)

    socket =
      socket
      |> assign(:filters, filters)
      |> assign(:sort, sort)
      |> load_jobs()
      |> maybe_load_detail(params)

    {:noreply, socket}
  end

  # ----- filter parsing -----

  defp parse_filters(params) do
    %{}
    |> maybe_put(:states, split_param(params["state"]))
    |> maybe_put(:queues, split_param(params["queue"]))
    |> maybe_put(:workers, split_param(params["worker"]))
    |> maybe_put(:tags, split_param(params["tags"]))
    |> maybe_put(:nodes, split_param(params["node"]))
    |> maybe_put(:priorities, parse_int_list(params["priority"]))
    |> maybe_put(:search, present(params["q"]))
    |> maybe_put(:inserted_after, parse_dt(params["from"]))
    |> maybe_put(:inserted_before, parse_dt(params["to"]))
  end

  defp parse_sort(%{"sort" => raw}) when is_binary(raw) do
    case String.split(raw, ":", parts: 2) do
      [field, dir] ->
        field_atom = safe_field_atom(field)
        dir_atom = if dir == "asc", do: :asc, else: :desc
        if field_atom, do: {field_atom, dir_atom}, else: nil

      _ ->
        nil
    end
  end

  defp parse_sort(_), do: nil

  defp safe_field_atom(name) do
    fields = JobsQuery.sortable_fields()
    Enum.find(fields, &(Atom.to_string(&1) == name))
  end

  defp split_param(nil), do: nil
  defp split_param(""), do: nil

  defp split_param(value) when is_binary(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp parse_int_list(nil), do: nil
  defp parse_int_list(""), do: nil

  defp parse_int_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn s ->
      case Integer.parse(String.trim(s)) do
        {n, ""} -> [n]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      list -> list
    end
  end

  defp parse_dt(nil), do: nil
  defp parse_dt(""), do: nil

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} ->
        dt

      _ ->
        case NaiveDateTime.from_iso8601(s <> ":00") do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(v), do: v

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ----- loading -----

  defp load_jobs(socket) do
    {jobs, %{next_cursor: next}} =
      JobsQuery.list(socket.assigns.filters,
        page_size: @page_size,
        sort: socket.assigns.sort || JobsQuery.default_sort(socket.assigns.filters)
      )

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

  defp maybe_load_detail(socket, _params), do: assign(socket, :selected_job, nil) |> assign(:edit_form, nil)

  # ----- live messages -----

  @impl true
  def handle_info({:tick, _buffer}, socket) do
    if socket.assigns[:reload_pending] do
      {:noreply, socket}
    else
      Process.send_after(self(), :reload_now, 200)
      {:noreply, assign(socket, :reload_pending, true)}
    end
  end

  def handle_info(:reload_now, socket) do
    {:noreply, socket |> assign(:reload_pending, false) |> load_jobs()}
  end

  def handle_info({:bulk_progress, %{ref: ref} = msg}, socket) do
    case socket.assigns.bulk_state do
      %{ref: ^ref} = state -> {:noreply, assign(socket, :bulk_state, Map.merge(state, msg))}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:bulk_completed, %{ref: ref} = msg}, socket) do
    case socket.assigns.bulk_state do
      %{ref: ^ref} ->
        Phoenix.PubSub.unsubscribe(pubsub(), "oban_ui:bulk:#{ref}")

        {:noreply,
         socket
         |> assign(:bulk_state, Map.merge(%{state: :completed}, msg))
         |> load_jobs()
         |> put_flash(:info, "Bulk action finished (#{msg.done}/#{msg.total})")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ----- events: filters / sort / nav -----

  @impl true
  def handle_event("filter", params, socket) do
    query = build_query(params)
    {:noreply, push_patch(socket, to: jobs_path(socket, query))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: jobs_path(socket, %{}))}
  end

  def handle_event("toggle_state", %{"state" => state}, socket) do
    current = socket.assigns.filters[:states] || []

    next_states =
      if state in current, do: List.delete(current, state), else: [state | current]

    query =
      socket
      |> build_query_from_filters()
      |> Map.put("state", Enum.join(next_states, ","))

    {:noreply, push_patch(socket, to: jobs_path(socket, query))}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    field_atom = safe_field_atom(field)

    sort =
      case {field_atom, socket.assigns.sort} do
        {nil, _} -> nil
        {f, {f, :asc}} -> {f, :desc}
        {f, {f, :desc}} -> nil
        {f, _} -> {f, :asc}
      end

    query =
      socket
      |> build_query_from_filters()
      |> put_sort_query(sort)

    {:noreply, push_patch(socket, to: jobs_path(socket, query))}
  end

  def handle_event("suggest", %{"field" => field, "value" => value}, socket) do
    key = String.to_existing_atom(field)

    values =
      case key do
        :worker -> Suggestions.workers(value)
        :queue -> Suggestions.queues(value)
        :tags -> Suggestions.tags(value)
        :node -> Suggestions.nodes(value)
        _ -> []
      end

    {:noreply, assign(socket, :suggestions, Map.put(socket.assigns.suggestions, key, values))}
  end

  # ----- events: single-job actions -----

  def handle_event("retry", %{"id" => id}, socket), do: handle_action(socket, :retry, id)
  def handle_event("cancel", %{"id" => id}, socket), do: handle_action(socket, :cancel, id)
  def handle_event("delete", %{"id" => id}, socket), do: handle_action(socket, :delete, id)

  def handle_event("close_detail", _params, socket) do
    {:noreply, push_patch(socket, to: jobs_path(socket, build_query_from_filters(socket)))}
  end

  # ----- events: selection + bulk -----

  def handle_event("toggle_select", %{"id" => id}, socket) do
    id_int = String.to_integer(id)
    set = socket.assigns.selected_ids

    next =
      if MapSet.member?(set, id_int),
        do: MapSet.delete(set, id_int),
        else: MapSet.put(set, id_int)

    {:noreply, assign(socket, :selected_ids, next)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  def handle_event("bulk_preview", %{"action" => action}, socket) do
    scope = bulk_scope(socket)
    preview = Bulk.preview(scope.filters)
    count = Bulk.count(scope.filters)

    {:noreply,
     assign(socket, :bulk_state, %{
       state: :preview,
       action: action,
       scope: scope.kind,
       count: count,
       preview: preview,
       filters: scope.filters
     })}
  end

  def handle_event("bulk_cancel", _params, socket) do
    {:noreply, assign(socket, :bulk_state, nil)}
  end

  def handle_event("bulk_confirm", _params, socket) do
    case socket.assigns.bulk_state do
      %{state: :preview, action: action, filters: filters} ->
        actor = %{access: socket.assigns.access, user: socket.assigns.current_user}
        action_atom = String.to_existing_atom(action)

        case Bulk.run(actor, action_atom, filters, oban_name: socket.assigns.active_oban) do
          {:ok, :sync, affected} ->
            {:noreply,
             socket
             |> assign(:bulk_state, nil)
             |> assign(:selected_ids, MapSet.new())
             |> load_jobs()
             |> put_flash(:info, "#{action_atom}: #{affected} jobs affected")}

          {:ok, :async, ref, estimate} ->
            :ok = Phoenix.PubSub.subscribe(pubsub(), "oban_ui:bulk:#{ref}")

            {:noreply,
             assign(socket, :bulk_state, %{
               state: :running,
               action: action,
               ref: ref,
               total: estimate,
               done: 0
             })}

          {:error, :forbidden} ->
            {:noreply,
             socket |> assign(:bulk_state, nil) |> put_flash(:error, "Not permitted")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:bulk_state, nil)
             |> put_flash(:error, "Bulk failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ----- events: edit -----

  def handle_event("edit_start", _params, socket) do
    case socket.assigns.selected_job do
      nil ->
        {:noreply, socket}

      %Oban.Job{} = job ->
        form = %{
          "priority" => job.priority,
          "tags" => Enum.join(job.tags || [], ", "),
          "max_attempts" => job.max_attempts,
          "scheduled_at" => format_dt_input(job.scheduled_at),
          "errors" => %{}
        }

        {:noreply, assign(socket, :edit_form, form)}
    end
  end

  def handle_event("edit_change", %{"job" => attrs}, socket) do
    {:noreply,
     assign(socket, :edit_form, Map.merge(socket.assigns.edit_form || %{}, attrs))}
  end

  def handle_event("edit_cancel", _params, socket) do
    {:noreply, assign(socket, :edit_form, nil)}
  end

  def handle_event("edit_save", %{"job" => attrs}, socket) do
    case socket.assigns.selected_job do
      nil ->
        {:noreply, socket}

      %Oban.Job{} = job ->
        actor = %{access: socket.assigns.access, user: socket.assigns.current_user}

        case Edit.update(actor, job, attrs, socket.assigns.active_oban) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:selected_job, updated)
             |> assign(:edit_form, nil)
             |> load_jobs()
             |> put_flash(:info, "Job #{updated.id} updated")}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "Not permitted")}

          {:error, {:not_editable_state, state}} ->
            {:noreply, put_flash(socket, :error, "Cannot edit in state #{state}")}

          {:error, errors} ->
            errors_map = Map.new(errors, fn {k, {msg, _}} -> {k, msg} end)
            {:noreply, assign(socket, :edit_form, Map.put(attrs, "errors", errors_map))}
        end
    end
  end

  # ----- events: instance switch -----

  def handle_event("switch_instance", %{"value" => name}, socket) do
    case Enum.find(socket.assigns.oban_names, &(to_string(&1) == name)) do
      nil -> {:noreply, socket}
      atom -> {:noreply, push_navigate(socket, to: "#{socket.assigns.base_path}/i/#{atom}/jobs")}
    end
  end

  # ----- helpers -----

  defp handle_action(socket, action, id_str) do
    actor = %{access: socket.assigns.access, user: socket.assigns.current_user}
    id = String.to_integer(id_str)

    fun =
      case action do
        :retry -> &ObanUI.Jobs.retry/3
        :cancel -> &ObanUI.Jobs.cancel/3
        :delete -> &ObanUI.Jobs.delete/3
      end

    case fun.(actor, id, socket.assigns.active_oban) do
      {:ok, _result} -> {:noreply, load_jobs(socket) |> put_flash(:info, "#{action} ok")}
      {:error, :forbidden} -> {:noreply, put_flash(socket, :error, "Not permitted")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp bulk_scope(socket) do
    selected = socket.assigns.selected_ids

    if MapSet.size(selected) > 0 do
      %{kind: :selection, filters: %{ids: MapSet.to_list(selected)}}
    else
      %{kind: :filters, filters: socket.assigns.filters}
    end
  end

  defp build_query(params) do
    params
    |> Map.take(~w(state queue worker tags node priority q from to))
    |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
    |> Map.new()
  end

  defp build_query_from_filters(socket) do
    Enum.into(socket.assigns.filters, %{}, fn
      {:states, list} -> {"state", Enum.join(list, ",")}
      {:queues, list} -> {"queue", Enum.join(list, ",")}
      {:workers, list} -> {"worker", Enum.join(list, ",")}
      {:tags, list} -> {"tags", Enum.join(list, ",")}
      {:nodes, list} -> {"node", Enum.join(list, ",")}
      {:priorities, list} -> {"priority", Enum.join(list, ",")}
      {:search, value} -> {"q", value}
      {:inserted_after, dt} -> {"from", DateTime.to_iso8601(dt)}
      {:inserted_before, dt} -> {"to", DateTime.to_iso8601(dt)}
      _ -> {"", ""}
    end)
    |> Map.reject(fn {k, _} -> k == "" end)
    |> put_sort_query(socket.assigns.sort)
  end

  defp put_sort_query(query, nil), do: Map.delete(query, "sort")

  defp put_sort_query(query, {field, dir}),
    do: Map.put(query, "sort", "#{field}:#{dir}")

  defp jobs_path(socket, query) do
    base = socket.assigns.base_path

    instance_prefix =
      if length(socket.assigns.oban_names) > 1,
        do: "/i/#{socket.assigns.active_oban}",
        else: ""

    path = base <> instance_prefix <> "/jobs"
    if map_size(query) == 0, do: path, else: path <> "?" <> URI.encode_query(query)
  end

  defp detail_path(_socket, base, oban_names, active_oban, id) do
    prefix = if length(oban_names) > 1, do: "/i/#{active_oban}", else: ""
    "#{base}#{prefix}/jobs/#{id}"
  end

  defp pubsub, do: ObanUI.Config.fetch!().pubsub

  defp format_dt_input(nil), do: ""

  defp format_dt_input(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/\+.*$/, "")
    |> String.slice(0, 16)
  end

  defp format_dt_input(%NaiveDateTime{} = ndt),
    do: ndt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)

  # ----- render -----

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

      <.state_tabs counts={@counts} active={@filters[:states] || []} />

      <form phx-change="filter" class="grid grid-cols-1 sm:grid-cols-3 lg:grid-cols-6 gap-2 mb-4">
        <input
          name="worker"
          class="oban-ui-input"
          placeholder="worker"
          value={join_list(@filters[:workers])}
          list="oban-ui-suggest-worker"
          phx-debounce="300"
          phx-keyup="suggest"
          phx-value-field="worker"
          phx-value-value=""
        />
        <input
          name="queue"
          class="oban-ui-input"
          placeholder="queue"
          value={join_list(@filters[:queues])}
          list="oban-ui-suggest-queue"
          phx-debounce="300"
        />
        <input
          name="tags"
          class="oban-ui-input"
          placeholder="tags (comma)"
          value={join_list(@filters[:tags])}
          list="oban-ui-suggest-tags"
          phx-debounce="300"
        />
        <input
          name="node"
          class="oban-ui-input"
          placeholder="node"
          value={join_list(@filters[:nodes])}
          list="oban-ui-suggest-node"
          phx-debounce="300"
        />
        <input
          name="priority"
          class="oban-ui-input"
          placeholder="priority (0-9)"
          value={join_list(@filters[:priorities])}
          phx-debounce="300"
        />
        <input
          name="q"
          class="oban-ui-input"
          placeholder="search args.path:value"
          value={@filters[:search]}
          phx-debounce="400"
        />
        <input
          name="from"
          type="datetime-local"
          class="oban-ui-input sm:col-span-2"
          value={format_dt_input(@filters[:inserted_after])}
        />
        <input
          name="to"
          type="datetime-local"
          class="oban-ui-input sm:col-span-2"
          value={format_dt_input(@filters[:inserted_before])}
        />

        <datalist id="oban-ui-suggest-worker">
          <option :for={v <- @suggestions.worker} value={v} />
        </datalist>
        <datalist id="oban-ui-suggest-queue">
          <option :for={v <- @suggestions.queue} value={v} />
        </datalist>
        <datalist id="oban-ui-suggest-tags">
          <option :for={v <- @suggestions.tags} value={v} />
        </datalist>
        <datalist id="oban-ui-suggest-node">
          <option :for={v <- @suggestions.nodes} value={v} />
        </datalist>
      </form>

      <.bulk_bar :if={MapSet.size(@selected_ids) > 0 or filters_present?(@filters)}
        selected={MapSet.size(@selected_ids)}
        access={@access}
      />

      <.bulk_panel :if={@bulk_state} state={@bulk_state} />

      <table class="oban-ui-table" role="table" aria-label="Jobs">
        <caption class="sr-only">List of Oban jobs matching the current filters</caption>
        <thead>
          <tr>
            <th class="w-6" scope="col">
              <input
                type="checkbox"
                disabled={true}
                checked={MapSet.size(@selected_ids) > 0}
                title="Use row checkboxes"
                aria-label="Select all (use per-row checkboxes)"
              />
            </th>
            <.sort_th field={:id} label="ID" sort={@sort} />
            <.sort_th field={:state} label="State" sort={@sort} />
            <.sort_th field={:queue} label="Queue" sort={@sort} />
            <.sort_th field={:worker} label="Worker" sort={@sort} />
            <.sort_th field={:priority} label="Prio" sort={@sort} />
            <th>Attempt</th>
            <.sort_th field={:inserted_at} label="Inserted" sort={@sort} />
            <th class="text-right">Actions</th>
          </tr>
        </thead>
        <tbody id="jobs" phx-update="stream">
          <tr :for={{dom_id, job} <- @streams.jobs} id={dom_id}>
            <td>
              <input
                type="checkbox"
                phx-click="toggle_select"
                phx-value-id={job.id}
                checked={MapSet.member?(@selected_ids, job.id)}
                aria-label={"Select job " <> Integer.to_string(job.id)}
              />
            </td>
            <td class="font-mono">
              <.link patch={detail_path(@socket, @base_path, @oban_names, @active_oban, job.id)}>
                {job.id}
              </.link>
            </td>
            <td><.state_badge state={job.state} /></td>
            <td>{job.queue}</td>
            <td class="font-mono text-xs">{job.worker}</td>
            <td>{job.priority}</td>
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
        edit_form={@edit_form}
      />
    </.shell>
    """
  end

  # ---- sub-components ----

  attr :counts, :map, required: true
  attr :active, :list, required: true

  defp state_tabs(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1 mb-3">
      <button
        :for={state <- ~w(available scheduled executing retryable completed cancelled discarded)}
        type="button"
        phx-click="toggle_state"
        phx-value-state={state}
        class={[
          "oban-ui-badge cursor-pointer transition-opacity",
          state in @active && "ring-2 ring-oban-500" || "opacity-70 hover:opacity-100"
        ]}
        data-state={state}
      >
        {state} ({Map.get(@counts, state, 0)})
      </button>
    </div>
    """
  end

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sort, :any, default: nil

  defp sort_th(assigns) do
    arrow =
      case assigns.sort do
        {field, :asc} when field == assigns.field -> " ↑"
        {field, :desc} when field == assigns.field -> " ↓"
        _ -> ""
      end

    assigns = assign(assigns, :arrow, arrow)

    ~H"""
    <th>
      <button
        type="button"
        phx-click="sort"
        phx-value-field={@field}
        class="hover:underline"
      >{@label}{@arrow}</button>
    </th>
    """
  end

  attr :selected, :integer, required: true
  attr :access, :map, required: true

  defp bulk_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-between rounded-md bg-amber-50 text-amber-900 px-3 py-2 mb-3 text-sm">
      <span :if={@selected > 0}>{@selected} selected</span>
      <span :if={@selected == 0}>Bulk action will apply to <strong>all filtered jobs</strong>.</span>

      <div class="flex gap-2">
        <.button
          variant="secondary"
          can?={@access.retry_jobs}
          phx-click="bulk_preview"
          phx-value-action="retry"
        >Retry…</.button>
        <.button
          variant="secondary"
          can?={@access.cancel_jobs}
          phx-click="bulk_preview"
          phx-value-action="cancel"
        >Cancel…</.button>
        <.button
          variant="danger"
          can?={@access.delete_jobs}
          phx-click="bulk_preview"
          phx-value-action="delete"
        >Delete…</.button>
        <.button
          :if={@selected > 0}
          variant="secondary"
          can?={true}
          phx-click="clear_selection"
        >Clear</.button>
      </div>
    </div>
    """
  end

  attr :state, :map, required: true

  defp bulk_panel(assigns) do
    ~H"""
    <div class="oban-ui-card mb-3 border-amber-300">
      <div :if={@state.state == :preview}>
        <p class="font-medium mb-2">
          Confirm bulk {@state.action} — {@state.count} jobs ({@state.scope})
        </p>

        <ul class="text-xs text-slate-500 mb-3 grid grid-cols-2 sm:grid-cols-4 gap-1">
          <li :for={{state, count} <- @state.preview} :if={count > 0}>
            <span class="oban-ui-badge" data-state={state}>{state}</span>
            <span class="ml-1">{count}</span>
          </li>
        </ul>

        <div class="flex gap-2">
          <.button variant="danger" can?={true} phx-click="bulk_confirm">
            Yes, {@state.action} {@state.count} jobs
          </.button>
          <.button variant="secondary" can?={true} phx-click="bulk_cancel">Cancel</.button>
        </div>
      </div>

      <div :if={@state.state == :running}>
        <p class="font-medium mb-2">
          Running bulk {@state.action} — {@state.done}/{@state.total}
        </p>
        <div class="w-full bg-slate-200 rounded-full h-2">
          <div
            class="bg-oban-500 h-2 rounded-full"
            style={"width: #{progress_pct(@state)}%"}
          ></div>
        </div>
      </div>
    </div>
    """
  end

  defp progress_pct(%{done: d, total: t}) when is_integer(t) and t > 0,
    do: trunc(d / t * 100)

  defp progress_pct(_), do: 0

  defp filters_present?(filters), do: filters != %{}

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

  defp join_list(nil), do: ""
  defp join_list(list) when is_list(list), do: Enum.join(list, ",")

  # ---- detail drawer ----

  attr :job, :map, required: true
  attr :resolver, :atom, required: true
  attr :access, :map, required: true
  attr :edit_form, :any, default: nil

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

    editable? = assigns.job.state in Edit.editable_states()

    assigns =
      assigns
      |> assign(:formatted_args, formatted_args)
      |> assign(:formatted_meta, formatted_meta)
      |> assign(:editable?, editable?)

    ~H"""
    <aside
      class="oban-ui-drawer p-5"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"job-detail-title-" <> Integer.to_string(@job.id)}
      id={"job-detail-drawer-" <> Integer.to_string(@job.id)}
      phx-hook="DrawerFocusTrap"
      tabindex="-1"
    >
      <div class="flex items-start justify-between mb-3">
        <div>
          <p class="text-xs text-slate-500">Job #{@job.id}</p>
          <h2
            id={"job-detail-title-" <> Integer.to_string(@job.id)}
            class="text-lg font-semibold"
          >{@job.worker}</h2>
          <p class="text-xs text-slate-500">
            <.state_badge state={@job.state} /> · {@job.queue} · attempt {@job.attempt}/{@job.max_attempts}
          </p>
        </div>
        <button
          type="button"
          class="oban-ui-btn-secondary"
          phx-click="close_detail"
          aria-label="Close detail"
        >×</button>
      </div>

      <section class="mb-4">
        <h3 class="text-sm font-medium mb-1">Timeline</h3>
        <Timeline.render job={@job} />
      </section>

      <%= if @edit_form do %>
        <.edit_form job={@job} form={@edit_form} />
      <% else %>
        <section class="mb-4">
          <h3 class="text-sm font-medium mb-1">Args
            <span
              class="ml-1 text-xs text-slate-500"
              title="Edit disabled — host serialises args; see resolver.format_job_args/1"
            >(read-only)</span>
          </h3>
          <.pre content={@formatted_args} />
        </section>

        <section class="mb-4" :if={@formatted_meta not in [nil, %{}, %{"_" => nil}]}>
          <h3 class="text-sm font-medium mb-1">Meta</h3>
          <.pre content={@formatted_meta} />
        </section>

        <section :if={@job.errors not in [nil, []]} class="mb-4">
          <h3 class="text-sm font-medium mb-1">Errors</h3>
          <div :for={{error, idx} <- Enum.with_index(@job.errors)} class="mb-2">
            <p class="text-xs text-slate-500">
              Attempt {idx + 1} · {Map.get(error, "at")}
            </p>
            <.pre content={Map.get(error, "error") || error} />
          </div>
        </section>

        <section class="border-t border-slate-200 pt-3 flex flex-wrap gap-2">
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
          <.button
            variant="secondary"
            can?={@access.edit_jobs and @editable?}
            reason={if @editable?, do: "Insufficient permissions", else: "Cannot edit a #{@job.state} job"}
            phx-click="edit_start"
          >Edit</.button>
        </section>
      <% end %>
    </aside>
    """
  end

  attr :job, :map, required: true
  attr :form, :map, required: true

  defp edit_form(assigns) do
    ~H"""
    <form phx-submit="edit_save" phx-change="edit_change" class="space-y-3">
      <div>
        <label class="text-sm font-medium block mb-1">Priority</label>
        <input
          name="job[priority]"
          type="number"
          min="0"
          max="9"
          value={Map.get(@form, "priority")}
          class="oban-ui-input"
        />
      </div>

      <div>
        <label class="text-sm font-medium block mb-1">Tags (comma-separated)</label>
        <input
          name="job[tags]"
          value={Map.get(@form, "tags")}
          class="oban-ui-input"
        />
      </div>

      <div>
        <label class="text-sm font-medium block mb-1">Scheduled at (UTC)</label>
        <input
          name="job[scheduled_at]"
          type="datetime-local"
          value={Map.get(@form, "scheduled_at")}
          class="oban-ui-input"
        />
      </div>

      <div>
        <label class="text-sm font-medium block mb-1">Max attempts</label>
        <input
          name="job[max_attempts]"
          type="number"
          min="1"
          value={Map.get(@form, "max_attempts")}
          class="oban-ui-input"
        />
      </div>

      <ul :if={Map.get(@form, "errors", %{}) != %{}} class="text-xs text-red-700">
        <li :for={{k, msg} <- Map.get(@form, "errors", %{})}>{k}: {msg}</li>
      </ul>

      <div class="flex gap-2 border-t border-slate-200 pt-3">
        <.button variant="primary" can?={true} type="submit">Save</.button>
        <.button variant="secondary" can?={true} phx-click="edit_cancel">Cancel</.button>
      </div>
    </form>
    """
  end
end
